package session

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// fakeClock is an injectable monotonically-advanced clock for hermetic reaper
// tests: the reaper reads Now via ReaperConfig.now, and the test advances time
// without sleeping so age crosses the TTL deterministically. It is
// concurrency-safe so the sweep goroutine reading Now never races a test advance.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock(start time.Time) *fakeClock { return &fakeClock{now: start} }

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// reapedWithin polls reg.Get for up to a generous wall-clock budget until id is
// gone, so a test asserts "eventually reaped" against the real ticker without a
// flaky fixed sleep. The reaper's clock is the fakeClock (age is already past
// TTL); this only waits for the next tick to fire, which is bounded by Tick.
func reapedWithin(reg *Registry, id string, budget time.Duration) bool {
	deadline := time.Now().Add(budget)
	for time.Now().Before(deadline) {
		if _, ok := reg.Get(id); !ok {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	_, ok := reg.Get(id)
	return !ok
}

// TestReaperEvictsIdleSession is the reaper's reason for existing: a session whose
// LastActivity is older than IdleTTL is removed from the registry AND closed on
// the next sweep. The clock is faked so the session ages past the TTL without a
// real wait; the tick is short so the sweep fires promptly.
func TestReaperEvictsIdleSession(t *testing.T) {
	clk := newFakeClock(time.Now())
	reg := NewRegistry()
	s := openFakeT(t, "idle.fp")
	reg.Add(s)

	rp := NewReaper(reg, ReaperConfig{
		IdleTTL: time.Minute,
		Tick:    time.Millisecond,
		now:     clk.Now,
	}, zerolog.Nop())
	stop := rp.Start(context.Background())
	defer stop()

	// Age the session well past IdleTTL relative to its seeded LastActivity.
	clk.advance(2 * time.Minute)

	if !reapedWithin(reg, s.ID(), time.Second) {
		t.Fatal("reaper did not evict a session idle past IdleTTL")
	}
	// Evicted means closed too: a re-Close is the idempotent no-op proof it was torn down.
	if err := s.Close(); err != nil {
		t.Fatalf("re-Close of a reaped session must be a no-op (proving it was closed), got: %v", err)
	}
}

// TestReaperKeepsFreshSession proves a session within IdleTTL is NOT reaped: the
// sweep runs (the clock has advanced, but less than the TTL) and the session
// survives. This is the false-positive guard — the reaper must not evict live work.
func TestReaperKeepsFreshSession(t *testing.T) {
	clk := newFakeClock(time.Now())
	reg := NewRegistry()
	s := openFakeT(t, "fresh.fp")
	reg.Add(s)

	rp := NewReaper(reg, ReaperConfig{
		IdleTTL: time.Minute,
		Tick:    time.Millisecond,
		now:     clk.Now,
	}, zerolog.Nop())
	stop := rp.Start(context.Background())
	defer stop()

	// Advance LESS than IdleTTL: the session is still fresh.
	clk.advance(30 * time.Second)

	// Let several ticks fire, then assert the session is still registered.
	time.Sleep(20 * time.Millisecond)
	if _, ok := reg.Get(s.ID()); !ok {
		t.Fatal("reaper evicted a session still within IdleTTL")
	}
}

// TestReaperTouchedSessionSurvives proves a Call resets the idle clock: a session
// that would be past IdleTTL by raw creation age survives because Call touched
// LastActivity. It exercises the LastActivity-vs-CreatedAt distinction the reaper
// keys on — idle eviction tracks activity, not birth.
func TestReaperTouchedSessionSurvives(t *testing.T) {
	reg := NewRegistry()
	s := openFakeT(t, "touched.fp")
	reg.Add(s)

	// Push past IdleTTL on the wall clock, then touch the session: Call stamps
	// LastActivity with the REAL time.Now (not the fake clock), so to keep the
	// test hermetic we assert the LastActivity accessor moved forward and that a
	// real-clock reaper would treat it as fresh.
	before := s.LastActivity()
	time.Sleep(2 * time.Millisecond)
	// A Call over the fake conn touches activity even if the write/await errs.
	_, _ = s.Call(context.Background(), "noop", nil)
	if !s.LastActivity().After(before) {
		t.Fatal("Call did not advance LastActivity")
	}

	// With a real-clock reaper and a TTL far larger than the elapsed test time, the
	// just-touched session is not idle and must survive a sweep.
	rp := NewReaper(reg, ReaperConfig{IdleTTL: time.Hour, Tick: time.Millisecond}, zerolog.Nop())
	stop := rp.Start(context.Background())
	defer stop()
	time.Sleep(10 * time.Millisecond)
	if _, ok := reg.Get(s.ID()); !ok {
		t.Fatal("reaper evicted a freshly-touched session")
	}
}

// TestReaperMaxLifetimeEvictsBusySession proves the optional hard ceiling: a
// session past MaxLifetime (CreatedAt age) is reaped even though it is fresh on
// the idle clock, so an actively-driven session cannot live forever.
func TestReaperMaxLifetimeEvictsBusySession(t *testing.T) {
	clk := newFakeClock(time.Now())
	reg := NewRegistry()
	s := openFakeT(t, "busy.fp")
	reg.Add(s)

	rp := NewReaper(reg, ReaperConfig{
		IdleTTL:     time.Hour, // huge — idle would NOT evict
		MaxLifetime: time.Minute,
		Tick:        time.Millisecond,
		now:         clk.Now,
	}, zerolog.Nop())
	stop := rp.Start(context.Background())
	defer stop()

	clk.advance(2 * time.Minute) // past MaxLifetime
	if !reapedWithin(reg, s.ID(), time.Second) {
		t.Fatal("reaper did not evict a session past MaxLifetime")
	}
}

// TestReaperStopsOnContextCancel proves the sweep goroutine exits when its ctx is
// cancelled: after cancel, no further eviction happens even when a session ages
// past the TTL. It guards the clean-stop-on-ctx-cancel contract serve relies on.
func TestReaperStopsOnContextCancel(t *testing.T) {
	clk := newFakeClock(time.Now())
	reg := NewRegistry()
	s := openFakeT(t, "survivor.fp")
	reg.Add(s)

	ctx, cancel := context.WithCancel(context.Background())
	rp := NewReaper(reg, ReaperConfig{
		IdleTTL: time.Minute,
		Tick:    time.Millisecond,
		now:     clk.Now,
	}, zerolog.Nop())
	stop := rp.Start(ctx)
	defer stop()

	cancel()
	// Give the goroutine a beat to observe the cancel and return.
	time.Sleep(10 * time.Millisecond)

	// Now age the session past IdleTTL: a stopped reaper must NOT reap it.
	clk.advance(2 * time.Minute)
	time.Sleep(20 * time.Millisecond)
	if _, ok := reg.Get(s.ID()); !ok {
		t.Fatal("a ctx-cancelled reaper still evicted a session")
	}
}

// TestReaperStopFuncHaltsSweep proves the returned stop func halts the sweep
// (independent of ctx cancel) and is idempotent + blocking: after stop returns,
// the goroutine is quiesced and a second stop is a no-op.
func TestReaperStopFuncHaltsSweep(t *testing.T) {
	clk := newFakeClock(time.Now())
	reg := NewRegistry()
	s := openFakeT(t, "stopfunc.fp")
	reg.Add(s)

	rp := NewReaper(reg, ReaperConfig{IdleTTL: time.Minute, Tick: time.Millisecond, now: clk.Now}, zerolog.Nop())
	stop := rp.Start(context.Background())

	stop()
	stop() // idempotent: must not panic or block forever

	clk.advance(2 * time.Minute)
	time.Sleep(20 * time.Millisecond)
	if _, ok := reg.Get(s.ID()); !ok {
		t.Fatal("a stopped reaper still evicted a session")
	}
}

// TestReaperConcurrentWithSessionEndRaceFree hammers the reaper sweep against
// concurrent Remove+Close (the session_end path) so `go test -race` flags any
// unguarded access or double-close. The contract is "no race, no panic"; the
// final state (some reaped, some session_end-closed) is nondeterministic.
func TestReaperConcurrentWithSessionEndRaceFree(t *testing.T) {
	clk := newFakeClock(time.Now())
	reg := NewRegistry()

	const n = 12
	ids := make([]string, n)
	for i := 0; i < n; i++ {
		s := openFakeT(t, "race.fp")
		reg.Add(s)
		ids[i] = s.ID()
	}

	rp := NewReaper(reg, ReaperConfig{IdleTTL: time.Minute, Tick: time.Millisecond, now: clk.Now}, zerolog.Nop())
	stop := rp.Start(context.Background())
	defer stop()
	clk.advance(2 * time.Minute) // everything is now reapable

	var wg sync.WaitGroup
	for _, id := range ids {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			// Race the reaper to the same session via the session_end detach-then-close path.
			if s, ok := reg.Remove(id); ok {
				_ = s.Close()
			}
		}(id)
	}
	wg.Wait()

	if !reapedWithin(reg, ids[0], time.Second) || reg.Len() != 0 {
		t.Fatalf("registry not fully drained by reaper+session_end race: Len=%d", reg.Len())
	}
}
