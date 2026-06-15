// reaper.go holds the Reaper: the background sweep that enforces spec §28's
// bounded session lifetime by evicting supervised attach sessions that have gone
// idle (or, optionally, outlived a hard ceiling) from the shared Registry. It is
// the time-driven half of the session lifecycle the cap (TryAdd) is the
// admission-driven half of — together they keep the dev-only debug surface from
// accumulating orphaned funpack children across a long-running MCP session.
//
// CONCURRENCY: the Reaper never holds the registry lock across a Session.Close.
// Each tick snapshots the live set with reg.List (read lock), filters by
// LastActivity/CreatedAt age, then Remove+Close each victim OUTSIDE the lock —
// the same detach-then-close-outside-the-lock contract Remove/CloseAll document.
// A session a concurrent session_end already closed is a safe no-op (Remove
// misses it; Close is idempotent).
//
// SHUTDOWN: the Reaper only evicts the idle/expired; it is NOT the shutdown sweep.
// On server stop the driver cancels the Reaper's ctx (stopping the ticker) AND
// calls reg.CloseAll, which closes EVERY live session's process group regardless
// of age so nothing is orphaned. See Start and the package CloseAll for the two
// halves.
package session

import (
	"context"
	"time"

	"github.com/rs/zerolog"
)

// ReaperConfig parameterizes the sweep. IdleTTL is the only required field; a
// zero MaxLifetime disables the hard-ceiling eviction, and a zero Tick falls back
// to a sensible default so a caller need only set IdleTTL.
type ReaperConfig struct {
	// IdleTTL is the maximum time a session may go without a Call (its
	// LastActivity age) before it is reaped. A session whose LastActivity is older
	// than now-IdleTTL is evicted. A zero IdleTTL disables idle eviction (only the
	// MaxLifetime ceiling, if set, applies).
	IdleTTL time.Duration

	// MaxLifetime, when > 0, is a hard ceiling on total session age (CreatedAt):
	// a session older than this is reaped even if it is actively being driven, so
	// a busy session cannot live forever. Zero disables the ceiling.
	MaxLifetime time.Duration

	// Tick is the sweep interval. Zero falls back to DefaultReaperTick. The
	// eviction granularity is one Tick — a session is reaped on the first tick
	// AFTER it crosses IdleTTL/MaxLifetime, not at the instant it crosses.
	Tick time.Duration

	// now overrides the clock for tests (injectable so a hermetic test drives age
	// past the TTL without sleeping). Nil falls back to time.Now.
	now func() time.Time
}

// DefaultReaperTick is the fallback sweep interval when ReaperConfig.Tick is zero.
const DefaultReaperTick = 30 * time.Second

// Reaper sweeps a Registry on a ticker, evicting sessions past their IdleTTL (and
// optional MaxLifetime). Construct one with NewReaper and drive it with Start; it
// holds no state beyond its config and the registry it sweeps, so a single Reaper
// per Registry is the intended topology.
type Reaper struct {
	reg *Registry
	cfg ReaperConfig
	log zerolog.Logger
}

// NewReaper builds a Reaper over reg with cfg. A zero cfg.Tick is normalized to
// DefaultReaperTick and a nil cfg.now to time.Now here, so Start works against a
// fully-resolved config. The logger receives one debug line per evicted session
// (the opaque id only — never a token or port).
func NewReaper(reg *Registry, cfg ReaperConfig, log zerolog.Logger) *Reaper {
	if cfg.Tick <= 0 {
		cfg.Tick = DefaultReaperTick
	}
	if cfg.now == nil {
		cfg.now = time.Now
	}
	return &Reaper{reg: reg, cfg: cfg, log: log}
}

// Start launches the sweep goroutine and returns a stop func that halts it. The
// goroutine ticks every cfg.Tick, calling sweep, and exits when EITHER ctx is
// cancelled OR the returned stop func is called (whichever fires first). stop is
// idempotent and blocks until the goroutine has returned, so a caller can
// `defer stop()` and know the sweep is fully quiesced before tearing down the
// registry. Start does NOT run an immediate sweep — the first eviction happens on
// the first tick.
func (rp *Reaper) Start(ctx context.Context) (stop func()) {
	ctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})

	go func() {
		defer close(done)
		ticker := time.NewTicker(rp.cfg.Tick)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				rp.sweep()
			}
		}
	}()

	var stopped bool
	return func() {
		// Idempotent: a second stop must not double-cancel-and-wait on a closed
		// channel. The cancel itself is idempotent; the guard protects the wait.
		if stopped {
			return
		}
		stopped = true
		cancel()
		<-done
	}
}

// sweep evicts every session whose idle age exceeds IdleTTL or whose total age
// exceeds MaxLifetime. It snapshots the live set with List (read lock), decides
// victims from the snapshot, then Remove+Close each OUTSIDE the registry lock so
// a slow process-group kill never blocks an unrelated TryAdd/Get. A victim a
// concurrent session_end already removed is a no-op (Remove misses).
func (rp *Reaper) sweep() {
	now := rp.cfg.now()
	for _, info := range rp.reg.List() {
		if !rp.expired(info, now) {
			continue
		}
		sess, ok := rp.reg.Remove(info.ID)
		if !ok {
			// A concurrent session_end already detached it; nothing to close here.
			continue
		}
		reason := "idle"
		if rp.cfg.MaxLifetime > 0 && now.Sub(sess.CreatedAt()) > rp.cfg.MaxLifetime {
			reason = "max_lifetime"
		}
		_ = sess.Close()
		rp.log.Debug().
			Str("session_id", info.ID).
			Str("reason", reason).
			Dur("idle_for", now.Sub(sess.LastActivity())).
			Msg("reaper evicted session")
	}
}

// expired reports whether the session is past IdleTTL (LastActivity age) or
// MaxLifetime (CreatedAt age). It reads LastActivity off the live session (the
// snapshot's CreatedAt suffices for the lifetime check, but idle age must be
// re-read from the session, not the snapshot, since SessionInfo carries no
// activity field). A miss on Get means a concurrent close already removed it —
// not expired-for-our-purposes, the next Remove handles the race.
func (rp *Reaper) expired(info SessionInfo, now time.Time) bool {
	if rp.cfg.MaxLifetime > 0 && now.Sub(info.CreatedAt) > rp.cfg.MaxLifetime {
		return true
	}
	if rp.cfg.IdleTTL > 0 {
		sess, ok := rp.reg.Get(info.ID)
		if !ok {
			return false
		}
		if now.Sub(sess.LastActivity()) > rp.cfg.IdleTTL {
			return true
		}
	}
	return false
}
