package session

import (
	"errors"
	"sync"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// TestTryAddRefusesAtCapacity is the cap's reason for existing: a bounded registry
// admits exactly max sessions via TryAdd, then refuses the next with a structured
// CategorySession error. The refused session is NOT registered (the caller, e.g.
// session_start, must Close it to avoid an orphan — proven by the unchanged Len).
func TestTryAddRefusesAtCapacity(t *testing.T) {
	const max = 2
	reg := NewRegistryWithMax(max)

	for i := 0; i < max; i++ {
		s := openFakeT(t, "cap.fp")
		if err := reg.TryAdd(s); err != nil {
			t.Fatalf("TryAdd #%d under cap should succeed, got: %v", i, err)
		}
	}
	if reg.Len() != max {
		t.Fatalf("Len after filling to cap: got %d, want %d", reg.Len(), max)
	}

	overflow := openFakeT(t, "overflow.fp")
	err := reg.TryAdd(overflow)
	if err == nil {
		t.Fatal("TryAdd at capacity must refuse, got nil error")
	}
	// Structured CategorySession error the model can read.
	if !errors.Is(err, mcperr.New(mcperr.CategorySession, "")) {
		t.Fatalf("TryAdd refusal must be CategorySession, got: %v", err)
	}
	var me *mcperr.Error
	if !errors.As(err, &me) || me.Message != "session cap reached" {
		t.Fatalf("TryAdd refusal message: got %+v, want \"session cap reached\"", err)
	}
	// The refused session was not registered — Len unchanged, Get misses.
	if reg.Len() != max {
		t.Fatalf("a refused TryAdd changed Len: got %d, want %d", reg.Len(), max)
	}
	if _, ok := reg.Get(overflow.ID()); ok {
		t.Fatal("a refused TryAdd registered the session anyway")
	}
}

// TestTryAddRoomAfterRemove proves the cap is dynamic: removing a session frees a
// slot, so a TryAdd that would have been refused now succeeds.
func TestTryAddRoomAfterRemove(t *testing.T) {
	reg := NewRegistryWithMax(1)
	first := openFakeT(t, "first.fp")
	if err := reg.TryAdd(first); err != nil {
		t.Fatalf("first TryAdd: %v", err)
	}

	second := openFakeT(t, "second.fp")
	if err := reg.TryAdd(second); err == nil {
		t.Fatal("second TryAdd at cap 1 should refuse")
	}

	// Free the slot, then the second admits.
	if s, ok := reg.Remove(first.ID()); ok {
		_ = s.Close()
	}
	if err := reg.TryAdd(second); err != nil {
		t.Fatalf("TryAdd after Remove freed a slot should succeed, got: %v", err)
	}
}

// TestUnboundedRegistryNeverRefuses proves NewRegistry (max 0) and SetMax(0) leave
// TryAdd unbounded — admission is never refused regardless of count.
func TestUnboundedRegistryNeverRefuses(t *testing.T) {
	reg := NewRegistry() // max 0 == unbounded
	for i := 0; i < 5; i++ {
		if err := reg.TryAdd(openFakeT(t, "unb.fp")); err != nil {
			t.Fatalf("unbounded TryAdd #%d refused: %v", i, err)
		}
	}
	if reg.Len() != 5 {
		t.Fatalf("unbounded Len: got %d, want 5", reg.Len())
	}

	// SetMax(0) on a populated bounded registry makes it unbounded again.
	capped := NewRegistryWithMax(1)
	_ = capped.TryAdd(openFakeT(t, "c.fp"))
	capped.SetMax(0)
	if err := capped.TryAdd(openFakeT(t, "c2.fp")); err != nil {
		t.Fatalf("SetMax(0) did not lift the cap: %v", err)
	}
}

// TestTryAddCapRaceFree hammers TryAdd from more goroutines than the cap allows so
// `go test -race` flags any count-then-insert race AND asserts the cap held: at
// most max sessions are ever admitted concurrently. The losers (refused) are
// closed so no fake child group leaks.
func TestTryAddCapRaceFree(t *testing.T) {
	const max = 4
	const workers = 32
	reg := NewRegistryWithMax(max)

	sessions := make([]*Session, workers)
	for i := range sessions {
		sessions[i] = openFakeT(t, "race.fp")
	}

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(s *Session) {
			defer wg.Done()
			if err := reg.TryAdd(s); err != nil {
				_ = s.Close() // refused: the caller closes to avoid an orphan
			}
		}(sessions[i])
	}
	wg.Wait()

	if got := reg.Len(); got > max {
		t.Fatalf("cap breached under concurrency: Len=%d > max=%d", got, max)
	}
	if got := reg.Len(); got != max {
		t.Fatalf("with %d workers and cap %d, exactly max should be admitted: got %d", workers, max, got)
	}
}
