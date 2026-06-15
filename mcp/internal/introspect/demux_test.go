package introspect

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// respLine renders a valid §28 ok-response NDJSON line for id with a trivial
// result, so a test can script a correlated reply without hand-escaping JSON.
func respLine(id int64) string {
	return fmt.Sprintf(`{"v":%d,"id":%d,"ok":true,"cmd":"status","result":{"id":%d}}`,
		contract.ProtocolVersion, id, id)
}

// eventLine renders a valid §28 event NDJSON line for the named async event.
func eventLine(name string) string {
	return fmt.Sprintf(`{"v":%d,"event":%q,"target":1,"value":42}`, contract.ProtocolVersion, name)
}

// demuxOver builds a Demux reading the given NDJSON lines (each already
// newline-free) joined into one scripted stream.
func demuxOver(lines ...string) *Demux {
	body := strings.Join(lines, "\n") + "\n"
	return NewDemux(NewReader(strings.NewReader(body)))
}

// runInBackground starts d.Run on a goroutine and returns a channel that
// carries its terminal error, so a test can assert how the loop stopped without
// racing the loop itself.
func runInBackground(ctx context.Context, d *Demux) <-chan error {
	errc := make(chan error, 1)
	go func() { errc <- d.Run(ctx) }()
	return errc
}

// TestAwaitReceivesCorrelatedResponse covers the core correlation: a response
// with id=N delivered by the read loop unblocks the one caller in Await(N).
func TestAwaitReceivesCorrelatedResponse(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	d := demuxOver(respLine(7))
	errc := runInBackground(ctx, d)

	resp, err := d.Await(ctx, 7)
	if err != nil {
		t.Fatalf("Await(7): %v", err)
	}
	if resp == nil || resp.ID != 7 {
		t.Fatalf("Await(7): got %+v, want response id=7", resp)
	}
	if !resp.Ok {
		t.Errorf("Await(7): want Ok response, got %+v", resp)
	}

	// The stream ends after the one response; the loop must stop cleanly (EOF).
	if err := <-errc; err != nil {
		t.Fatalf("Run after EOF: want nil, got %v", err)
	}
}

// TestEventsLandOnChannel covers the demux's second job: interleaved async
// events are pushed onto Events() in order, NOT mistaken for responses, while a
// correlated response still reaches its awaiter.
func TestEventsLandOnChannel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	d := demuxOver(
		eventLine("breakpoint_hit"),
		respLine(3),
		eventLine("watch_fired"),
	)
	errc := runInBackground(ctx, d)

	if resp, err := d.Await(ctx, 3); err != nil || resp.ID != 3 {
		t.Fatalf("Await(3): resp=%+v err=%v, want id=3 nil", resp, err)
	}

	// Both events must arrive on the channel, in stream order. Events() closes
	// when the loop stops, so draining it to closure also confirms ordering.
	var got []string
	for ev := range d.Events() {
		got = append(got, ev.Name)
	}
	want := []string{"breakpoint_hit", "watch_fired"}
	if len(got) != len(want) {
		t.Fatalf("events: got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("event[%d]: got %q, want %q", i, got[i], want[i])
		}
	}

	if err := <-errc; err != nil {
		t.Fatalf("Run after EOF: want nil, got %v", err)
	}
}

// TestConcurrentAwaitsDistinctIDs covers the pending-by-id map under
// concurrency: two awaits for different ids each get their own response, even
// when the responses arrive out of registration order.
func TestConcurrentAwaitsDistinctIDs(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Responses arrive in reverse id order to prove correlation is by id, not
	// arrival order.
	d := demuxOver(respLine(2), respLine(1))
	errc := runInBackground(ctx, d)

	var wg sync.WaitGroup
	results := make(map[int64]*contract.Response)
	var mu sync.Mutex
	for _, id := range []int64{1, 2} {
		wg.Add(1)
		go func(id int64) {
			defer wg.Done()
			resp, err := d.Await(ctx, id)
			if err != nil {
				t.Errorf("Await(%d): %v", id, err)
				return
			}
			mu.Lock()
			results[id] = resp
			mu.Unlock()
		}(id)
	}
	wg.Wait()

	for _, id := range []int64{1, 2} {
		if r := results[id]; r == nil || r.ID != id {
			t.Errorf("Await(%d): got %+v, want id=%d", id, r, id)
		}
	}

	if err := <-errc; err != nil {
		t.Fatalf("Run after EOF: want nil, got %v", err)
	}
}

// TestProtocolErrorFailsLoopAndUnblocksAwaiters covers the fault path: a
// malformed line fails the read loop with a CategoryProtocol error, and every
// blocked awaiter unblocks with that same protocol error rather than hanging.
func TestProtocolErrorFailsLoopAndUnblocksAwaiters(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// A version-mismatch line is a §28 protocol fault the codec refuses.
	bad := fmt.Sprintf(`{"v":%d,"id":9,"ok":true,"cmd":"status","result":{}}`, contract.ProtocolVersion+1)
	d := demuxOver(bad)
	errc := runInBackground(ctx, d)

	_, err := d.Await(ctx, 9)
	if err == nil {
		t.Fatal("Await: want protocol error, got nil")
	}
	if !IsProtocolError(err) {
		t.Fatalf("Await error: want CategoryProtocol, got %v", err)
	}

	loopErr := <-errc
	if !IsProtocolError(loopErr) {
		t.Fatalf("Run error: want CategoryProtocol, got %v", loopErr)
	}
}

// TestCtxCancelStopsRun covers cooperative shutdown: cancelling the ctx stops
// Run with ctx.Err() even when the stream never ends, and a caller blocked in
// Await unblocks with a session error.
func TestCtxCancelStopsRun(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	// A reader that blocks forever models a live connection with no traffic.
	d := NewDemux(NewReader(blockingReader{}))
	errc := runInBackground(ctx, d)

	awaitErr := make(chan error, 1)
	go func() {
		_, err := d.Await(ctx, 1)
		awaitErr <- err
	}()

	// Give the awaiter time to register, then cancel.
	time.Sleep(20 * time.Millisecond)
	cancel()

	select {
	case err := <-errc:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Run on cancel: want context.Canceled, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Run did not return after ctx cancel")
	}

	select {
	case err := <-awaitErr:
		// The awaiter's own ctx (shared) is cancelled, so it returns ctx.Err();
		// either the ctx error or the session terminal error is an acceptable
		// unblock — both prove it did not hang.
		if err == nil {
			t.Fatal("Await on cancel: want an error, got nil")
		}
		if !errors.Is(err, context.Canceled) && !errors.Is(err, mcperr.New(mcperr.CategorySession, "")) {
			t.Fatalf("Await on cancel: want ctx.Canceled or session error, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Await did not unblock after ctx cancel")
	}
}

// TestAwaitAfterStopFailsFast covers the post-shutdown guard: once Run has
// stopped, a fresh Await must not register-and-block forever — it fails fast
// with the terminal error.
func TestAwaitAfterStopFailsFast(t *testing.T) {
	d := demuxOver(respLine(1))
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}

	_, err := d.Await(context.Background(), 99)
	if err == nil {
		t.Fatal("Await after stop: want terminal error, got nil")
	}
	var de *mcperr.Error
	if !errors.As(err, &de) || de.Code != mcperr.CategorySession {
		t.Fatalf("Await after clean stop: want CategorySession, got %v", err)
	}
}

// blockingReader is an io.Reader that never returns, modeling an idle live
// connection so a ctx-cancel test has a stream Run cannot drain to EOF.
type blockingReader struct{}

func (blockingReader) Read(p []byte) (int, error) {
	select {} // block forever; the test relies on ctx cancel, not this reader.
}

var _ io.Reader = blockingReader{}
