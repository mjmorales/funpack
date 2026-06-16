package introspect

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// isEOF reports whether err is the clean end-of-stream signal Decode returns.
// (*Reader).Decode returns io.EOF bare on a clean end; any framing/contract
// fault is an *mcperr.Error of CategoryProtocol instead, so an EOF here is
// unambiguously a graceful close, not a truncation.
func isEOF(err error) bool { return errors.Is(err, io.EOF) }

// Demux is the read-side multiplexer over a §28 duplex introspection stream. It
// runs a single read loop over a *Reader and SEPARATES the two classes of
// inbound traffic the protocol interleaves on one connection:
//
//   - responses are CORRELATED to a pending request by Response.ID and handed to
//     the one caller blocked in Await(id);
//   - events are PUSHED onto a buffered channel the session layer drains via
//     Events(), since an async event (breakpoint_hit, watch_fired, paused,
//     reload_result, diverged) is correlated by name, not by an outstanding id.
//
// Demux does NOT own the socket. Spawn/attach/dial land in a later §28 task;
// this type consumes a *Reader someone else opened, so the same loop drives a
// real loopback connection or a scripted in-memory stream identically.
//
// Concurrency model: a mutex guards the pending-by-id map; Await registers a
// one-shot buffered channel under the lock, then blocks outside it; Run is the
// single goroutine that reads, so response delivery never races a second
// reader. The loop terminates on ctx cancel, clean EOF, or a protocol/decode
// fault from Decode — in every case it closes done (recording the terminal
// error once) so every blocked Await unblocks instead of leaking.
type Demux struct {
	r *Reader

	events chan *contract.Event

	mu      sync.Mutex
	pending map[int64]chan *contract.Response // id -> one-shot response slot

	// done closes exactly once when Run returns; err holds the terminal error
	// (nil on a clean ctx-cancel/EOF stop, the protocol fault otherwise). Await
	// reads err only after observing done closed, so the closeOnce write
	// happens-before any read.
	done     chan struct{}
	doneOnce sync.Once
	err      error
}

// eventsBuffer sizes the events channel. A handful of async events can land
// between session-layer drains (a watch firing while a control command is
// in flight); the buffer absorbs that burst so Run never blocks the read loop
// on a slow consumer until the buffer is genuinely saturated.
const eventsBuffer = 64

// NewDemux builds a demux over r. It does not start reading; call Run.
func NewDemux(r *Reader) *Demux {
	return &Demux{
		r:       r,
		events:  make(chan *contract.Event, eventsBuffer),
		pending: make(map[int64]chan *contract.Response),
		done:    make(chan struct{}),
	}
}

// Events returns the receive end of the async-event channel. The session layer
// ranges over it (or selects on it alongside ctx); it is closed when Run
// returns, so a range loop terminates with the stream.
func (d *Demux) Events() <-chan *contract.Event { return d.events }

// Run is the read loop. It reads one decoded message per iteration and routes
// it: a response to its pending awaiter, an event to Events(). It returns when
//
//   - ctx is cancelled (returns ctx.Err()),
//   - the stream reaches a clean EOF (returns nil), or
//   - Decode reports a protocol/decode fault (returns that *mcperr.Error).
//
// On return it finalizes once: records the terminal error, closes the events
// channel, and unblocks every pending Await with the terminal error. Run is
// single-call; a second concurrent invocation would double-read the stream and
// is a caller bug, not a supported mode.
func (d *Demux) Run(ctx context.Context) error {
	// reads runs the blocking Decode on its own goroutine so the loop can also
	// honor ctx cancel — a bufio.Scanner read does not observe a context.
	type decodeResult struct {
		dec Decoded
		err error
	}
	results := make(chan decodeResult)
	go func() {
		for {
			dec, err := d.r.Decode()
			select {
			case results <- decodeResult{dec: dec, err: err}:
			case <-ctx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return d.finish(ctx.Err())
		case res := <-results:
			if res.err != nil {
				if isEOF(res.err) {
					return d.finish(nil)
				}
				return d.finish(res.err)
			}
			d.route(res.dec)
		}
	}
}

// route delivers one decoded message. A response goes to its pending slot (and
// is dropped if no awaiter is registered — a late or duplicate response is not
// a fault for the demux to fail on). An event is pushed onto Events(); a
// request inbound on this stream is not part of the read-side contract and is
// ignored.
func (d *Demux) route(dec Decoded) {
	switch dec.Kind {
	case KindResponse:
		d.deliver(dec.Response)
	case KindEvent:
		d.events <- dec.Event
	case KindRequest:
		// The MCP side never receives requests on the introspection stream;
		// ignore rather than fail the loop.
	}
}

// deliver hands resp to the awaiter registered for its id, consuming the slot so
// a second response for the same id is dropped. A response with no awaiter is
// dropped silently.
func (d *Demux) deliver(resp *contract.Response) {
	d.mu.Lock()
	slot, ok := d.pending[resp.ID]
	if ok {
		delete(d.pending, resp.ID)
	}
	d.mu.Unlock()
	if ok {
		slot <- resp // buffered cap 1: never blocks the read loop
	}
}

// Await registers interest in the response carrying id and blocks until it
// arrives. It returns:
//
//   - the response, once Run delivers it;
//   - a structured CategorySession error naming the reason (deadline vs cancel),
//     if the passed ctx is cancelled while waiting — never the bare "context
//     canceled" string (the registration is reclaimed so a later response for id
//     is dropped rather than delivered to a gone caller);
//   - the loop's terminal error, if Run stops while the caller is blocked — a
//     clean EOF/cancel surfaces as a CategorySession error, a protocol fault
//     surfaces as the original *mcperr.Error of CategoryProtocol.
//
// Await is concurrency-safe: many goroutines may await distinct ids
// simultaneously, each on its own slot.
func (d *Demux) Await(ctx context.Context, id int64) (*contract.Response, error) {
	slot := make(chan *contract.Response, 1)

	d.mu.Lock()
	// If Run has already stopped, do not register — fail fast with the terminal
	// error so a post-shutdown Await never blocks forever.
	select {
	case <-d.done:
		d.mu.Unlock()
		return nil, d.terminalErr()
	default:
	}
	d.pending[id] = slot
	d.mu.Unlock()

	select {
	case resp := <-slot:
		return resp, nil
	case <-ctx.Done():
		d.reclaim(id)
		return nil, waitContextErr(ctx.Err(), id)
	case <-d.done:
		d.reclaim(id)
		return nil, d.terminalErr()
	}
}

// waitContextErr maps a per-request wait's context error into a structured,
// human-and-model-legible session error so a cancelled or expired Await never
// surfaces as the bare "context canceled" string a caller cannot act on. A
// deadline (the runtime did not answer in time) and a cancel (the caller/SDK
// abandoned the request) are named distinctly. A non-context error — there is
// none on this branch today, but the guard keeps the mapping total — passes
// through unchanged.
func waitContextErr(err error, id int64) error {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return mcperr.Wrap(mcperr.CategorySession,
			fmt.Sprintf("introspection request id %d: the runtime did not answer before the request deadline", id), err)
	case errors.Is(err, context.Canceled):
		return mcperr.Wrap(mcperr.CategorySession,
			fmt.Sprintf("introspection request id %d: the request was cancelled before the runtime answered", id), err)
	default:
		return err
	}
}

// isContextErr reports whether err is one of the two standard context
// terminations, so a deliberate read-loop stop is named rather than leaked raw.
func isContextErr(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

// reclaim removes the slot for id if it is still registered. Called when an
// awaiter abandons its wait (ctx cancel or loop shutdown) so the map does not
// retain a dead slot.
func (d *Demux) reclaim(id int64) {
	d.mu.Lock()
	delete(d.pending, id)
	d.mu.Unlock()
}

// finish records the terminal error once, closes the events channel, and
// unblocks every pending awaiter. It is idempotent via doneOnce, so the ctx
// branch and the decode branch racing to finalize resolve to a single
// terminal state. It returns the (possibly nil) terminal error so Run can
// return it directly.
func (d *Demux) finish(err error) error {
	d.doneOnce.Do(func() {
		d.err = err

		d.mu.Lock()
		pending := d.pending
		d.pending = nil
		d.mu.Unlock()

		// Closing done unblocks every awaiter currently selecting on it; the
		// nil-out above stops route from delivering into a now-dead slot.
		close(d.done)
		close(d.events)
		_ = pending // slots are abandoned; awaiters wake via the done close.
	})
	return d.err
}

// terminalErr maps the loop's recorded terminal error into the error an Await
// returns. A protocol fault is surfaced verbatim (it is already an
// *mcperr.Error of CategoryProtocol). A clean stop (nil err, from EOF or ctx
// cancel) is reported as a CategorySession error, since to a blocked caller a
// closed stream is a session-lifecycle failure: the request will never be
// answered.
func (d *Demux) terminalErr() error {
	if d.err != nil {
		// A context-cancel terminal means the read loop was deliberately stopped
		// (Close cancels the session's run ctx). To a blocked caller that is a
		// session-lifecycle end, not the opaque "context canceled" the bare ctx
		// error stringifies to — name it as a session-category failure so the model
		// reads "the session was closed", not an internal cancel.
		if isContextErr(d.err) {
			return mcperr.Wrap(mcperr.CategorySession,
				"the introspection stream stopped before the response arrived (the session was closed)", d.err)
		}
		return d.err
	}
	return mcperr.New(mcperr.CategorySession, "introspection stream closed before response arrived")
}
