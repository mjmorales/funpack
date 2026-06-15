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

// CommandGroup is a named command surface tagged with its determinism class.
type CommandGroup struct {
	Class    string   `json:"class"`
	Commands []string `json:"commands"`
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
