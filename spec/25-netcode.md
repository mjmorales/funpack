# 25 — Netcode & multiplayer

For funpack, **determinism is the netcode**. Bit-identical simulation from the same inputs + seed
([`01`](01-axioms.md) P1) is the lockstep/rollback substrate, and almost every multiplayer
requirement reduces to a mechanism the spec already has. The user **writes no netcode** — they
annotate realms and emit cross-realm signals; the engine does sync, serialization, prediction, and
reconnection. Multiplayer is reuse: P2P ← determinism; reconciliation ← rewind+replay
([`08`](08-state.md), [`28`](28-introspection.md)); no-server-in-client ← realm-projection closure;
the wire contract ← generated; serialization & deltas ← closure + COW; RPC ← a signal pair.

## 1. Two topologies, one substrate

`net:` is declared **exactly once per game**, in the entrypoint alongside `tick`
([`14`](14-project-config.md)); a game runs one topology and does not mix topologies across matches:

```
entrypoint match { pipeline = Arena, tick = 60hz, net = authoritative }   // | p2p | p2p(rollback)
```

- **`authoritative`** — a canonical server runs the sim; clients send inputs, receive authoritative
  state, **predict locally and reconcile**. The competitive default (the server is the anti-cheat
  authority).
- **`p2p`** — input-lockstep: peers exchange `Input` snapshots and each folds identically; a tick
  advances exactly when all inputs for it are present. The authoritative tick is the truth; the
  input-delay and jitter-buffer windows are fixed engine calibration constants, not spec numbers.
- **`p2p(rollback)`** — predict remote inputs, advance immediately, **rollback + replay** on a
  misprediction (GGPO-style).

Absent `net:`, the game builds single-player (one artifact). All three modes share the **same
rewind+replay substrate**; lockstep is the no-prediction mode. **Fixed-point makes client prediction
bit-exact to the server** — reconciliation corrects only for *unknown remote inputs*, never float
drift.

## 2. Realms — two projections from one source

One source compiles to **two artifacts** — a headless **server** (authority, validation, admin) and
a **client** (render, input, prediction) — plus the netcode contract. Three realms: **shared**
(default — the deterministic sim, runs identically on both), **`@server`** (authoritative validation,
secret state, anti-cheat, DB/HTTP egress), **`@client`** (UI, cosmetic effects, input capture).

**Realm is inferred structurally; annotate only to override** ([`05`](05-directives.md)): render is
implicitly `@client` (it returns `[Draw]`, and a headless server has no `Draw` consumer, so effect
closure proves it); egress/secret reads are `@server` by type; explicit `@server`/`@client` resolves
ambiguity — notably to pin a behavior server-side for authority. **Realm lives only in source, never
in `.fcfg`** ([`14`](14-project-config.md)).

**"No server code leaks into the client" is a closure theorem**: server-only declarations are *not
reachable* from the client projection, so they are **absent and unnameable** — not stripped, not
redacted. Anti-cheat by projection (a cheater cannot read logic that physically is not in the client
binary); a `@client` declaration referencing `@server`-only state is a compile error. **The warranty
gate is realm-scoped**: shared/synced code must be warranted (fixed-point, no non-warranted `extern`,
no float in synced state); realm-private code stays loose.

## 3. The netcode contract & state sync

The **fifth structured contract** (and the first *bidirectional* one): it carries the synced thing
schemas (and projected views), the cross-realm signal/command types, each one's reliability class,
and the realm of every declaration. It is **generated from realm-annotated source, not
hand-authored** (no IDL to drift — better than gRPC/OpenAPI), **versioned exact-match**, and joins the
**session-header handshake** (contract version + seed + mod manifest + runtime identity; a mismatch
refuses the join).

Serialization is free (closure + flat `Ref` id-graph); deltas are the COW structural diff
([`09`](09-runtime.md)). **Reliability is auto-classified by kind** — continuous blackboard `data` →
**unreliable, latest-wins delta**; `Spawn`/`Despawn` and cross-realm signals → **reliable, ordered**.
Send-rate is decoupled from tick rate (deltas coalesce; a 60 Hz sim can sync at 20 Hz). **There is no
state quantization** — a synced field transmits its deterministic fixed-point value at full precision;
bandwidth is managed by delta-coalescing and send-rate decoupling, never by quantizing below
precision (a quantized field would break the bit-exact prediction of § 1).

## 4. The hard parts are already built

- **Prediction/reconciliation = rewind + replay** — receive the authoritative version for tick N; if
  it differs from the predicted N, rewind to N and replay local inputs to the present.
- **Desync / anti-cheat = state-hash comparison** (the `audit{determinism}` check over the wire). In
  `authoritative`, a client sends only inputs and the server is the sole writer, so a modified client
  can only send *bad inputs*, which `@server` validation behaviors clamp or reject.
- **RPC = a reliable cross-realm signal pair** — no dedicated construct (a blocking call would break
  the deterministic tick). A client emits a request signal → a `@server` behavior consumes it → emits
  a result signal carrying `Result[…, E]` next tick → the client matches it exhaustively.
  **gRPC-shaped contract, signal-pair mechanism.**
- **Interest management = a `@server` `query` returning projected views** (default `@spatial`
  proximity); hidden fields are never transmitted, so anti-wallhack falls out, and the query is pure
  so it does not touch the warranty.
- **Connect / reconnect / late-join = one operation** — a handshake + a snapshot transfer (save/load
  over the wire) + resume delta sync.
- **HTTP egress** — `@server`-only IO-as-command: an `HttpRequest` command → the engine's impure
  boundary → a `Result[Response, HttpError]` signal next tick, recorded as input so the server's
  replay stays bit-identical. An external OpenAPI spec can be imported to type it.

## 5. Admin, clustering & open

**Admin + telemetry = the introspection contract on an auth-gated port** ([`28`](28-introspection.md):
observe = telemetry, control = admin, plus health/readiness). **Clustering = horizontal scaling of
independent, serializable matches** — a match is a portable serializable unit, so the engine ships
exact **live migration** (serialize → move → resume) and **failover by replay** (from the nearest
snapshot, not in-sim rollback). The engine ships portable matches + a built-in router + the
telemetry surface; the **operator owns physical placement, autoscaling, and supervision**, and the
**durable storage location of the input log** (the recording that makes replay/failover possible) is
operator infrastructure, not engine doctrine.
