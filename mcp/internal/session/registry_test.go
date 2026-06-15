package session

import (
	"context"
	"sync"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/rs/zerolog"
)

// openFakeT opens a fake session for a test and registers a Cleanup so the fake
// child group is always reaped even when the test does not Remove/CloseAll it.
func openFakeT(t *testing.T, artifact string) *Session {
	t.Helper()
	s, err := OpenFake(context.Background(), artifact, zerolog.Nop())
	if err != nil {
		t.Fatalf("OpenFake(%q): %v", artifact, err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// TestRegistryAddGetRemoveRoundTrip is the lifecycle spine: an added session is
// gettable by id, a non-member id misses, Remove returns the same handle and
// deregisters it (a subsequent Get and Remove both miss).
func TestRegistryAddGetRemoveRoundTrip(t *testing.T) {
	reg := NewRegistry()
	s := openFakeT(t, "game.fp")

	reg.Add(s)

	got, ok := reg.Get(s.ID())
	if !ok {
		t.Fatal("Get missed a session that was just Added")
	}
	if got != s {
		t.Fatal("Get returned a different *Session than was Added")
	}
	if _, ok := reg.Get("no-such-id"); ok {
		t.Fatal("Get hit on an id that was never registered")
	}

	removed, ok := reg.Remove(s.ID())
	if !ok {
		t.Fatal("Remove missed a registered session")
	}
	if removed != s {
		t.Fatal("Remove returned a different *Session than was registered")
	}
	if _, ok := reg.Get(s.ID()); ok {
		t.Fatal("Get hit after Remove — the session was not deregistered")
	}
	if _, ok := reg.Remove(s.ID()); ok {
		t.Fatal("second Remove of the same id must miss")
	}
}

// TestRegistryListReportsNonSecretInfoSorted asserts List surfaces id + negotiated
// version + artifact for every live session, sorted oldest-first, and carries NO
// secret (the SessionInfo shape has no token/port field by construction; this
// guards the values it does report).
func TestRegistryListReportsNonSecretInfoSorted(t *testing.T) {
	reg := NewRegistry()
	if got := reg.List(); len(got) != 0 {
		t.Fatalf("List on an empty registry returned %d entries, want 0", len(got))
	}

	first := openFakeT(t, "first.fp")
	reg.Add(first)
	second := openFakeT(t, "second.fp")
	reg.Add(second)

	infos := reg.List()
	if len(infos) != 2 {
		t.Fatalf("List returned %d entries, want 2", len(infos))
	}
	// Sorted oldest-first: first was created before second.
	if infos[0].ID != first.ID() || infos[1].ID != second.ID() {
		t.Fatalf("List not sorted oldest-first: got ids [%s, %s], want [%s, %s]",
			infos[0].ID, infos[1].ID, first.ID(), second.ID())
	}
	byID := map[string]SessionInfo{infos[0].ID: infos[0], infos[1].ID: infos[1]}
	if got := byID[first.ID()]; got.Artifact != "first.fp" || got.NegotiatedVersion != contract.ProtocolVersion {
		t.Fatalf("List info for first wrong: %+v", got)
	}
	if byID[first.ID()].CreatedAt.IsZero() {
		t.Fatal("List SessionInfo has a zero CreatedAt")
	}
}

// TestRegistryCloseAllClosesAndClears asserts CloseAll empties the registry and
// closes every member (the fake child groups are reaped), and that a session
// already Removed (and thus closed by the caller) is a safe no-op for CloseAll.
func TestRegistryCloseAllClosesAndClears(t *testing.T) {
	reg := NewRegistry()
	a := openFakeT(t, "a.fp")
	b := openFakeT(t, "b.fp")
	reg.Add(a)
	reg.Add(b)

	reg.CloseAll()

	if got := reg.List(); len(got) != 0 {
		t.Fatalf("List after CloseAll returned %d entries, want 0", len(got))
	}
	if _, ok := reg.Get(a.ID()); ok {
		t.Fatal("Get hit after CloseAll")
	}
	// Close is idempotent, so calling it again on a CloseAll'd session is a no-op.
	if err := a.Close(); err != nil {
		t.Fatalf("re-Close of a CloseAll'd session must be a no-op, got: %v", err)
	}
}

// TestRegistryConcurrentAccessRaceFree hammers Add/Get/Remove/List/CloseAll from
// many goroutines so `go test -race` flags any unguarded map access. It does not
// assert a deterministic final state (the operations interleave nondeterministically);
// its contract is "no data race, no panic".
func TestRegistryConcurrentAccessRaceFree(t *testing.T) {
	reg := NewRegistry()

	const workers = 16
	sessions := make([]*Session, workers)
	for i := range sessions {
		sessions[i] = openFakeT(t, "race.fp")
	}

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(s *Session) {
			defer wg.Done()
			reg.Add(s)
			_, _ = reg.Get(s.ID())
			_ = reg.List()
			if removed, ok := reg.Remove(s.ID()); ok {
				_ = removed
			}
		}(sessions[i])
	}
	// A concurrent reader/sweeper racing the writers above.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 64; i++ {
			_ = reg.List()
		}
	}()
	wg.Wait()

	// Whatever survived the interleave, CloseAll must drain it cleanly.
	reg.CloseAll()
	if got := reg.List(); len(got) != 0 {
		t.Fatalf("registry not empty after the concurrent run + CloseAll: %d entries", len(got))
	}
}
