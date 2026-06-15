// registry.go holds the Registry: the concurrency-safe shared map of live
// supervised attach sessions, keyed on each session's opaque id. It is the one
// piece of session-layer state the reaper (which sweeps stale sessions by
// age) and every session-scoped tool (time/inspect/control/self-heal) key on, so
// it lives in the session package beside the Session it tracks rather than in any
// single tool layer.
//
// CONCURRENCY: an RWMutex guards the map — reads (Get/List) take the read lock,
// mutations (Add/Remove/CloseAll) take the write lock. Every public method is
// safe to call from concurrent goroutines (the MCP server fans tool calls out
// across goroutines, and the reaper sweeps on its own clock). The Registry never
// holds the lock across a Session.Close call: Remove detaches under the lock and
// returns the *Session for the CALLER to Close, and CloseAll snapshots the live
// set under the lock then closes outside it — so a slow teardown never blocks an
// unrelated Add/Get.
package session

import (
	"context"
	"net"
	"os/exec"
	"sort"
	"sync"
	"syscall"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/rs/zerolog"
)

// SessionInfo is the non-secret view of a live session the registry reports:
// the opaque id, the negotiated protocol version, the artifact loaded, and the
// creation instant. It deliberately carries NO auth token and NO loopback port —
// session_list and any other surface render only these fields.
type SessionInfo struct {
	ID                string    `json:"id"`
	NegotiatedVersion int       `json:"negotiated_version"`
	Artifact          string    `json:"artifact"`
	CreatedAt         time.Time `json:"created_at"`
}

// Registry is the concurrency-safe set of live supervised attach sessions, keyed
// by opaque session id. The zero value is NOT ready — construct one with
// NewRegistry so the backing map is allocated; the server wires a single shared
// Registry into the session tools and the reaper.
//
// CAPACITY: max bounds the number of concurrently live sessions (spec §28's
// bounded session lifetime). A max of 0 means unbounded — TryAdd never refuses.
// The cap is read/written under the same lock that guards the map, so the
// count-then-insert in TryAdd is atomic against a concurrent TryAdd/Remove.
type Registry struct {
	mu       sync.RWMutex
	sessions map[string]*Session
	max      int
}

// NewRegistry returns an empty, ready, UNBOUNDED Registry (max 0). The server
// constructs exactly one — use NewRegistryWithMax or SetMax to bound it — and
// shares it across the session tools and the reaper.
func NewRegistry() *Registry {
	return &Registry{sessions: make(map[string]*Session)}
}

// NewRegistryWithMax returns an empty, ready Registry capped at max concurrently
// live sessions. A max <= 0 is treated as unbounded. This is the production
// constructor the server uses to enforce spec §28's concurrency cap; tests that
// do not exercise the cap use NewRegistry.
func NewRegistryWithMax(max int) *Registry {
	if max < 0 {
		max = 0
	}
	return &Registry{sessions: make(map[string]*Session), max: max}
}

// SetMax updates the concurrency cap. A max <= 0 makes the registry unbounded.
// Lowering the cap below the current Len does NOT evict existing sessions — it
// only refuses subsequent TryAdds until Remove/reap drains below the new cap.
func (r *Registry) SetMax(max int) {
	if max < 0 {
		max = 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.max = max
}

// Len returns the number of currently live sessions.
func (r *Registry) Len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.sessions)
}

// Add registers a live session under its own id, IGNORING the cap. A second Add
// of the same id overwrites the prior entry (ids are crypto/rand-minted, so a
// collision is not a real case — the overwrite is defined behavior, not a guard).
// Add is the internal/test path that bypasses the cap; the cap-enforcing
// production path is TryAdd, which session_start uses.
func (r *Registry) Add(s *Session) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sessions[s.ID()] = s
}

// TryAdd registers a live session under its own id, REFUSING when the registry is
// at capacity (Len >= max, for a bounded max). On refusal it returns an
// *mcperr.Error of CategorySession ("session cap reached") and does NOT register
// the session — the caller must Close the just-opened session to avoid an orphan.
// The count-and-insert is performed under the write lock so a concurrent TryAdd
// cannot both observe room and overflow the cap. An overwrite of an existing id
// (not a real case for crypto/rand ids) is never a cap breach: a re-Add of a
// present id keeps Len unchanged.
func (r *Registry) TryAdd(s *Session) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.max > 0 {
		if _, present := r.sessions[s.ID()]; !present && len(r.sessions) >= r.max {
			return mcperr.New(mcperr.CategorySession, "session cap reached")
		}
	}
	r.sessions[s.ID()] = s
	return nil
}

// Get returns the live session for id and whether it was present. The returned
// *Session is the live handle; the caller must not assume it stays registered (a
// concurrent Remove or the reaper may detach it).
func (r *Registry) Get(id string) (*Session, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.sessions[id]
	return s, ok
}

// Remove detaches the session for id from the registry and returns it for the
// caller to Close, plus whether it was present. Remove does NOT call Close — it
// only unlinks under the lock, so the (idempotent, potentially slow) teardown
// runs outside the registry lock. An absent id returns (nil, false).
func (r *Registry) Remove(id string) (*Session, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sessions[id]
	if !ok {
		return nil, false
	}
	delete(r.sessions, id)
	return s, true
}

// List returns a non-secret SessionInfo for every live session, sorted by
// CreatedAt (oldest first, id-tiebroken) so the order is stable across calls. The
// slice is a fresh copy — mutating it never touches the registry.
func (r *Registry) List() []SessionInfo {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]SessionInfo, 0, len(r.sessions))
	for _, s := range r.sessions {
		out = append(out, SessionInfo{
			ID:                s.ID(),
			NegotiatedVersion: s.NegotiatedVersion(),
			Artifact:          s.Artifact(),
			CreatedAt:         s.CreatedAt(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].ID < out[j].ID
		}
		return out[i].CreatedAt.Before(out[j].CreatedAt)
	})
	return out
}

// CloseAll detaches every session and closes it — the shutdown sweep the server
// runs on stop so no supervised child group is orphaned. It snapshots the live
// set and clears the map under the lock, then closes each session OUTSIDE the
// lock (Close kills a process group and is not instant), so a slow teardown never
// blocks a concurrent Add/Get. Close is idempotent, so a session a concurrent
// Remove already closed is a safe no-op here.
func (r *Registry) CloseAll() {
	r.mu.Lock()
	snapshot := make([]*Session, 0, len(r.sessions))
	for _, s := range r.sessions {
		snapshot = append(snapshot, s)
	}
	r.sessions = make(map[string]*Session)
	r.mu.Unlock()

	for _, s := range snapshot {
		_ = s.Close()
	}
}

// OpenFake constructs a live *Session WITHOUT a real funpack runtime — a
// cross-package testing seam for any package (the session tools, the reaper)
// that holds a *Session but cannot reach Session's unexported fields. It drives
// the real Open through the same Config seams the in-package tests use: a fake
// long-running child in its own process group, an in-memory loopback conn, and a
// scripted handshake that negotiates contract.ProtocolVersion. Every observable
// edge (ID, NegotiatedVersion, Artifact, CreatedAt, Demux, Conn, Close-kills-the-
// group) behaves exactly as a real session; only the spawn/dial/handshake IO is
// faked. It is NOT a production constructor — production opens through Open.
//
// The caller MUST eventually Close the returned session (or hand it to a Registry
// whose CloseAll/Remove path closes it) so the fake child group is reaped.
func OpenFake(ctx context.Context, artifact string, log zerolog.Logger) (*Session, error) {
	clientConn, serverConn := net.Pipe()
	// A trivial peer the scripted handshake bypasses; the conn just needs to be a
	// live net.Conn the demux can read from until Close. The serverConn closes when
	// the session's Close closes clientConn and the demux loop returns — net.Pipe
	// propagates the close, ending this goroutine's blocked Read.
	go func() {
		_, _ = serverConn.Read(make([]byte, 1))
		_ = serverConn.Close()
	}()

	cfg := Config{
		Log:       log,
		mintToken: func() (string, error) { return "fake-token", nil },
		mintPort:  func() (int, error) { return 1, nil },
		spawn: func(_, _ string, _ int, _ string) *exec.Cmd {
			cmd := exec.Command("/bin/sh", "-c", "sleep 300")
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			return cmd
		},
		dial:      func(context.Context, int) (net.Conn, error) { return clientConn, nil },
		handshake: func(net.Conn, string) (int, error) { return contract.ProtocolVersion, nil },
	}
	return Open(ctx, funpack.Binary{Path: "/bin/sh"}, artifact, cfg)
}
