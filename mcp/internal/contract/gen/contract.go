package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
)

// Contract is the decoded funpack-api.json — the single source of truth for the
// funpack <-> funpack-mcp boundary. Field tags mirror the on-disk JSON exactly;
// "$comment" keys are ignored.
type Contract struct {
	ContractVersion int             `json:"contract_version"`
	VersionSurface  VersionSurface  `json:"version_surface"`
	Introspect      IntrospectBlock `json:"introspect"`
}

// VersionSurface describes the `funpack version --json` shape plus the MCP's
// accepted version ranges. The on-disk JSON interleaves "$comment" string keys
// among the typed object entries of fields/supported, so those maps decode as
// raw messages and the comment keys are dropped on access.
type VersionSurface struct {
	Argv        []string                   `json:"argv"`
	Fields      map[string]json.RawMessage `json:"fields"`
	SchemaNames []string                   `json:"schema_names"`
	Supported   map[string]json.RawMessage `json:"supported"`
}

// fieldSpecs returns version_surface.fields decoded into FieldSpec, skipping any
// "$comment" key.
func (vs VersionSurface) fieldSpecs() (map[string]FieldSpec, error) {
	return decodeTyped[FieldSpec](vs.Fields)
}

// supportedRanges returns version_surface.supported decoded into VersionRange,
// skipping any "$comment" key.
func (vs VersionSurface) supportedRanges() (map[string]VersionRange, error) {
	return decodeTyped[VersionRange](vs.Supported)
}

// FieldSpec is one entry of version_surface.fields (used for doc comments only).
type FieldSpec struct {
	Type string `json:"type"`
	Doc  string `json:"doc"`
}

// VersionRange is an inclusive [Min, Max] schema-version window the MCP accepts.
type VersionRange struct {
	Min int `json:"min"`
	Max int `json:"max"`
}

// IntrospectBlock is the spec §28 introspection contract (runtime -> agent). The
// envelopes and command_groups maps interleave a "$comment" string key with their
// typed object entries, so they decode as raw messages and drop the comment key
// on access.
type IntrospectBlock struct {
	ProtocolVersion int                        `json:"protocol_version"`
	Transport       string                     `json:"transport"`
	Envelopes       map[string]json.RawMessage `json:"envelopes"`
	CommandGroups   map[string]json.RawMessage `json:"command_groups"`
	Events          []string                   `json:"events"`
}

// envelopeSpecs returns introspect.envelopes decoded into EnvelopeSpec, skipping
// any "$comment" key.
func (in IntrospectBlock) envelopeSpecs() (map[string]EnvelopeSpec, error) {
	return decodeTyped[EnvelopeSpec](in.Envelopes)
}

// commandGroupSpecs returns introspect.command_groups decoded into CommandGroup,
// skipping any "$comment" key.
func (in IntrospectBlock) commandGroupSpecs() (map[string]CommandGroup, error) {
	return decodeTyped[CommandGroup](in.CommandGroups)
}

// EnvelopeSpec is one of the three closed message kinds (request/response/event).
type EnvelopeSpec struct {
	Fields      []string `json:"fields"`
	OneOf       []string `json:"oneof"`
	OpenPayload bool     `json:"open_payload"`
	Doc         string   `json:"doc"`
}

// CommandGroup is a named command surface tagged with its determinism class. Its
// commands are an ORDERED list of CommandSpec — each a §28 wire command name plus
// the arg shape the generator projects into the tools/list input_schema. The list
// order is preserved on-disk so the generated command consts and the Tool_Spec
// table are byte-stable.
type CommandGroup struct {
	Class      string        `json:"class"`
	ToolPrefix string        `json:"tool_prefix"`
	Commands   []CommandSpec `json:"commands"`
}

// toolName projects a command's MCP tool name from the group's tool_prefix: a
// non-empty prefix yields "<prefix>_<command>" (time/inspect/control), an empty
// prefix yields the bare command name (break/self_heal). The contract owns the
// prefix (judgment); this projection is the mechanism.
func (grp CommandGroup) toolName(command string) string {
	if grp.ToolPrefix == "" {
		return command
	}
	return grp.ToolPrefix + "_" + command
}

// CommandSpec is one §28 command: its wire name and the per-arg shape map (the
// object inside a request envelope's `args` field). Args is the hand-authored
// shape the generator projects; an empty map means the command takes only the
// session handle. The map decodes with arbitrary key order, so callers iterate it
// via sortedKeys for byte-stable output.
type CommandSpec struct {
	Name string             `json:"name"`
	Args map[string]ArgSpec `json:"args"`
}

// ArgSpec is the shape of one §28 wire argument: its JSON-Schema type, whether it
// is required, and its schema description. These are the fields the generator
// projects into an MCP input_schema property.
type ArgSpec struct {
	Type     string `json:"type"`
	Required bool   `json:"required"`
	Doc      string `json:"doc"`
}

// ResolvedContract is the fully-decoded contract: every "$comment"-interleaved
// raw map resolved into its typed form. The renderers consume this so they never
// touch json.RawMessage. Ordered fields (argv, schema_names, group commands,
// events) preserve the on-disk order; maps are iterated via sortedKeys for stable
// output.
type ResolvedContract struct {
	ContractVersion int
	VersionSurface  ResolvedVersionSurface
	Introspect      ResolvedIntrospect
}

// ResolvedVersionSurface is VersionSurface with its raw maps decoded.
type ResolvedVersionSurface struct {
	Argv        []string
	Fields      map[string]FieldSpec
	SchemaNames []string
	Supported   map[string]VersionRange
}

// ResolvedIntrospect is IntrospectBlock with its raw maps decoded.
type ResolvedIntrospect struct {
	ProtocolVersion int
	Transport       string
	Envelopes       map[string]EnvelopeSpec
	CommandGroups   map[string]CommandGroup
	Events          []string
}

// loadContract decodes funpack-api.json from path and resolves it into a
// ResolvedContract.
func loadContract(path string) (*ResolvedContract, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Contract
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}

	fields, err := c.VersionSurface.fieldSpecs()
	if err != nil {
		return nil, fmt.Errorf("decode version_surface.fields: %w", err)
	}
	supported, err := c.VersionSurface.supportedRanges()
	if err != nil {
		return nil, fmt.Errorf("decode version_surface.supported: %w", err)
	}
	envelopes, err := c.Introspect.envelopeSpecs()
	if err != nil {
		return nil, fmt.Errorf("decode introspect.envelopes: %w", err)
	}
	groups, err := c.Introspect.commandGroupSpecs()
	if err != nil {
		return nil, fmt.Errorf("decode introspect.command_groups: %w", err)
	}

	return &ResolvedContract{
		ContractVersion: c.ContractVersion,
		VersionSurface: ResolvedVersionSurface{
			Argv:        c.VersionSurface.Argv,
			Fields:      fields,
			SchemaNames: c.VersionSurface.SchemaNames,
			Supported:   supported,
		},
		Introspect: ResolvedIntrospect{
			ProtocolVersion: c.Introspect.ProtocolVersion,
			Transport:       c.Introspect.Transport,
			Envelopes:       envelopes,
			CommandGroups:   groups,
			Events:          c.Introspect.Events,
		},
	}, nil
}

// decodeTyped decodes the typed object entries of a "$comment"-interleaved raw
// map into map[string]T, dropping any "$comment" key.
func decodeTyped[T any](raw map[string]json.RawMessage) (map[string]T, error) {
	out := make(map[string]T, len(raw))
	for k, v := range raw {
		if k == "$comment" {
			continue
		}
		var t T
		if err := json.Unmarshal(v, &t); err != nil {
			return nil, fmt.Errorf("key %q: %w", k, err)
		}
		out[k] = t
	}
	return out, nil
}

// commandNames returns a group's command names in on-disk declaration order — the
// ordered projection the name-surface renderers (Go consts, Odin CMD_* consts)
// consume so the generated taxonomy stays byte-stable.
func commandNames(grp CommandGroup) []string {
	names := make([]string, len(grp.Commands))
	for i, c := range grp.Commands {
		names[i] = c.Name
	}
	return names
}

// sortedKeys returns the keys of m in deterministic ascending order, so that
// generated output over a Go map is byte-stable across runs (the staleness test
// depends on this).
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
