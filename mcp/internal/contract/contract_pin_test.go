package contract

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"
)

// The Odin side of the contract is authored under funpack/ and runtime/ and is
// OUT of this module's write scope. These pins are READ-ONLY: they fail loudly on
// Odin<->contract drift (a schema bump, a renamed command, a new event) so the
// drift is caught at the boundary without this module ever editing an Odin file.

// odinConstInt extracts an Odin `NAME :: <int>` declaration's integer value from
// source. Odin distinguishes a constant (`::`) from a variable (`:=`); the schema
// stamps are constants, so this matches `::` only.
func odinConstInt(t *testing.T, src, name string) int {
	t.Helper()
	re := regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(name) + `\s*::\s*(-?\d+)\b`)
	m := re.FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("Odin constant %s :: <int> not found", name)
	}
	v, err := strconv.Atoi(m[1])
	if err != nil {
		t.Fatalf("parse %s value %q: %v", name, m[1], err)
	}
	return v
}

// readOdin reads an Odin source file relative to the repo root.
func readOdin(t *testing.T, root, rel string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(raw)
}

// TestOdinSchemaVersionsWithinSupported pins the Odin schema-version constants
// inside the contract's Supported ranges. The contract owns the RANGE; the Odin
// constant owns the VALUE. A funpack schema bump that lands without widening the
// matching range here trips this — the deliberate "bump the range, never silently
// drift" gate.
func TestOdinSchemaVersionsWithinSupported(t *testing.T) {
	root := repoRootFromTest(t)

	artifactSrc := readOdin(t, root, filepath.Join("funpack", "artifact_format.odin"))
	indexSrc := readOdin(t, root, filepath.Join("funpack", "index_contract.odin"))
	introspectSrc := readOdin(t, root, filepath.Join("runtime", "introspect.odin"))

	cases := []struct {
		schema    string
		constName string
		src       string
	}{
		{SchemaArtifact, "ARTIFACT_SCHEMA_VERSION", artifactSrc},
		{SchemaIndex, "INDEX_SCHEMA_VERSION", indexSrc},
		{SchemaIntrospect, "INTROSPECT_PROTOCOL_VERSION", introspectSrc},
	}
	for _, c := range cases {
		rng, ok := Supported[c.schema]
		if !ok {
			t.Fatalf("contract Supported has no range for schema %q", c.schema)
		}
		got := odinConstInt(t, c.src, c.constName)
		if !rng.Contains(got) {
			t.Errorf("Odin %s = %d is outside contract Supported[%q] range [%d,%d] — bump the range in contract/funpack-api.json or revert the Odin bump",
				c.constName, got, c.schema, rng.Min, rng.Max)
		}
	}
}

// TestIntrospectProtocolVersionMatches pins the Odin INTROSPECT_PROTOCOL_VERSION
// to the contract's ProtocolVersion exactly (§28 envelopes are exact-match
// versioned, so this is equality, not a range).
func TestIntrospectProtocolVersionMatches(t *testing.T) {
	root := repoRootFromTest(t)
	src := readOdin(t, root, filepath.Join("runtime", "introspect.odin"))
	got := odinConstInt(t, src, "INTROSPECT_PROTOCOL_VERSION")
	if got != ProtocolVersion {
		t.Errorf("Odin INTROSPECT_PROTOCOL_VERSION = %d, contract ProtocolVersion = %d — §28 requires exact match", got, ProtocolVersion)
	}
}

// TestFunpackIntrospectMirrorMatches pins funpack's compile-time MIRROR of the
// introspect protocol version (funpack/version.odin INTROSPECT_SCHEMA_VERSION,
// what `funpack version` reports) to the contract's ProtocolVersion. The funpack
// compiler package cannot import runtime (SDL link / -no-entry-point topology), so
// it owns its own copy, exactly as it owns ARTIFACT_SCHEMA_VERSION. Pinning the
// mirror to the contract — which TestIntrospectProtocolVersionMatches also pins the
// runtime constant to — makes the two copies provably equal without a direct
// cross-package reference, so `funpack version` can never mis-report §28 compat.
func TestFunpackIntrospectMirrorMatches(t *testing.T) {
	root := repoRootFromTest(t)
	src := readOdin(t, root, filepath.Join("funpack", "version.odin"))
	got := odinConstInt(t, src, "INTROSPECT_SCHEMA_VERSION")
	if got != ProtocolVersion {
		t.Errorf("funpack INTROSPECT_SCHEMA_VERSION = %d, contract ProtocolVersion = %d — funpack's version-report mirror drifted from runtime/the contract", got, ProtocolVersion)
	}
}

// knownPendingOdin lists contract command names the Odin runtime does not yet
// route as a quoted dispatch literal. Each is a deliberate, recorded gap; the test
// asserts each is STILL absent so that when Odin starts routing it, the entry goes
// stale and forces its own pruning (append-only-with-supersession discipline — the
// allowlist is self-expiring, never a silent permanent exclusion).
//
// Currently EMPTY: ADR 2026-06-15-28-introspect-surface-gaps (open-spec-rulings)
// resolved every standing command gap — `despawn` is now implemented in
// control_request, so the contract keeps it and the runtime routes it, and `inspect`
// (bare) was dropped from §28 and the contract as the redundant umbrella-as-member of
// its own group. The machinery stays for the next time a contract command leads the
// runtime.
var knownPendingOdin = map[Command]string{}

// odinCommandSources are the Odin files whose quoted string literals collectively
// realize the §28 command surface (the dispatch switch plus the per-command
// response sites). Searched as a union so a command counts as present if it
// appears in ANY of them.
var odinCommandSources = []string{
	filepath.Join("runtime", "introspect.odin"),
}

// odinEventSources are the Odin files that emit the §28 async events as quoted
// `"event":"<name>"` pushes. Events come from the probe / audit / session-driver
// layer, not the introspect dispatch switch, so the pin searches that union rather
// than introspect.odin alone.
var odinEventSources = []string{
	filepath.Join("runtime", "introspect.odin"),
	filepath.Join("runtime", "introspect_audit.odin"),
	filepath.Join("runtime", "probes.odin"),
	filepath.Join("runtime", "session_driver.odin"),
}

// knownPendingOdinEvents lists contract event names the Odin runtime does not yet
// EMIT as a quoted push. Self-expiring, exactly like knownPendingOdin: the test
// asserts each is still absent so wiring the emission forces pruning this list.
//
// Currently EMPTY: ADR 2026-06-15-28-introspect-surface-gaps dropped `paused` and
// `reload_result` from the contract — the synchronous fold reports the pause/reload
// outcome in the command RESPONSE, not as an async push — so the contract's event
// set (breakpoint_hit, watch_fired, diverged) is exactly what the runtime emits.
var knownPendingOdinEvents = map[EventName]string{}

// quotedLiteral reports whether the quoted form "name" appears in any of the given
// Odin source files under root.
func quotedLiteral(t *testing.T, root string, files []string, name string) bool {
	t.Helper()
	needle := `"` + name + `"`
	for _, rel := range files {
		if regexp.MustCompile(regexp.QuoteMeta(needle)).MatchString(readOdin(t, root, rel)) {
			return true
		}
	}
	return false
}

// TestEveryContractCommandPresentInOdin asserts every §28 command name in the
// contract appears as a quoted dispatch literal in the Odin runtime sources,
// EXCEPT the deliberately-tracked knownPendingOdin gaps. For each pending entry it
// asserts the name is STILL absent, so the allowlist self-expires once Odin routes
// the command — catching both "contract gained a command Odin lacks" and "Odin
// caught up, prune the allowlist" drift directions.
func TestEveryContractCommandPresentInOdin(t *testing.T) {
	root := repoRootFromTest(t)

	for _, cmd := range Commands {
		present := quotedLiteral(t, root, odinCommandSources, string(cmd))
		if reason, pending := knownPendingOdin[cmd]; pending {
			if present {
				t.Errorf("command %q is now routed in Odin — remove it from knownPendingOdin (was tracked: %s)", cmd, reason)
			}
			continue
		}
		if !present {
			t.Errorf("contract command %q not found as a quoted literal in Odin runtime sources %v — Odin<->contract drift", cmd, odinCommandSources)
		}
	}
}

// TestEveryContractEventPresentInOdin asserts every §28 event name in the contract
// is emitted as a quoted literal in the Odin event sources, EXCEPT the
// deliberately-tracked knownPendingOdinEvents gaps. For each pending entry it
// asserts the name is STILL absent, so the allowlist self-expires once Odin emits
// the event.
func TestEveryContractEventPresentInOdin(t *testing.T) {
	root := repoRootFromTest(t)

	for _, ev := range Events {
		present := quotedLiteral(t, root, odinEventSources, string(ev))
		if reason, pending := knownPendingOdinEvents[ev]; pending {
			if present {
				t.Errorf("event %q is now emitted in Odin — remove it from knownPendingOdinEvents (was tracked: %s)", ev, reason)
			}
			continue
		}
		if !present {
			t.Errorf("contract event %q not found as a quoted literal in Odin event sources %v — Odin<->contract drift", ev, odinEventSources)
		}
	}
}
