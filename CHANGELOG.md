# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Until 1.0.0, minor versions may contain breaking changes.

## [0.5.0] - 2026-06-10

### Added

- `mcp.StatefulToolPack(State, defs)`: tool packs whose handlers share
  mutable state. The generated struct holds `state: *State` and passes it as
  the handlers' first parameter (`fn(*State, Allocator, [ToolContext,] Args)`).
  Motivated by real servers (a daemon client, a database handle) that the
  stateless `ToolPack` could not express without globals.

## [0.4.0] - 2026-06-10

### Added

- `mcp.ToolPack`: comptime tool registry. One declaration per tool
  (`.description` + `.handler`, optional `.args` and `.annotations`) generates
  the JSON Schema, the `tools/list` entry, name dispatch, and typed argument
  parsing from the handler's signature. The generated type implements
  `listTools`/`callTool`, so it works directly as a `Server` handler or
  embedded in a larger one.
- `mcp.ToolContext` for context-taking pack handlers: `sendProgress(i, total)`
  is a no-op when the client sent no progress token, plus access to the
  notification context and raw call params.
- Pack composition: `ToolPack(.{ lib_a.tool_defs, my_defs })` merges def
  groups; duplicate tool names are a compile error.
- `types.parseArgs` now treats absent or null `arguments` as an empty object,
  so tools whose fields all have defaults (or none) need no arguments.
- Both greeter examples rewritten on tool packs.

## [0.3.0] - 2026-06-10

### Added

- POST response streaming: `callTool` may take a per-call `Context`
  (`fn(*Handler, Allocator, Context, CallToolParams)`, arity detected at
  comptime). Over HTTP, notifications sent during the call stream on the
  POST's own SSE response (progress events, then the result) when the client
  accepts `text/event-stream`. Over stdio they interleave on stdout.
- SSE resumability: events carry monotonically increasing ids, undelivered
  notifications are buffered per session (`sse_replay_events` option) and
  replayed when a stream opens, and `Last-Event-ID` resumes after reconnect.
- Session idle timeout: a background reaper terminates sessions inactive for
  `session_idle_seconds` (default 600, 0 disables).
- `Server.handleRequestWithContext` for transports that route notifications
  per request.

### Changed

- **Breaking (behavior):** a second GET stream on a session now takes over
  (last connection wins) instead of receiving 409. A dead client is
  indistinguishable from a quiet one between keepalives, so 409 locked out
  reconnecting clients for up to a keepalive interval.
- Notifications sent with no stream open are now buffered for later delivery
  instead of failing with `NoEventStream` (unless `sse_replay_events = 0`).

## [0.2.0] - 2026-06-10

### Added

- HTTP transport: multiple concurrent sessions (mutex-guarded, refcounted session
  map; `max_sessions` option), connections handled in parallel via `Io.Group`.
- HTTP transport: SSE support. `GET` with `Accept: text/event-stream` opens a
  per-session event stream; server-initiated notifications are delivered as
  `data:` events with periodic keepalives (`sse_keepalive_seconds` option).
- Pagination: list handlers may take `(*Handler, Allocator, types.ListParams)`
  to receive the request cursor; arity detected at comptime, 2-arg handlers
  keep working.
- Cancellation: `notifications/cancelled` routed to an optional
  `onCancelled(*Handler, types.CancelledParams)` handler method.
- Progress: `Context.sendProgress` for `notifications/progress`, plus
  `CallToolParams.progressToken()` to read the client's `_meta.progressToken`.
- HTTP conformance script (`scripts/conformance_http.sh`) run in CI.

### Changed

- **Breaking:** `Context` is now sink-based (`.{ .sink = .{ .writer = w } }`)
  so notifications work over both stdio and HTTP SSE. Handler-facing methods
  (`sendNotification`, `sendLogMessage`, `sendChannelEvent`, ...) are unchanged.
- HTTP transport requires a thread-safe allocator and thread-tolerant handler
  methods, since connections are handled concurrently.
- Per-session protocol version negotiation over HTTP no longer mutates shared
  `Server` state.

### Fixed

- SSE/streamed responses now drain the chunked encoder before flushing the
  socket (events previously never left the buffer).
- Responding 405 to body-bearing methods without a `Content-Length` no longer
  trips a `std.http` assertion.
- The listener sets `reuse_address`, so restarts no longer fail with
  `AddressInUse` during TIME_WAIT.

## [0.1.0] - 2026-06-10

First tagged release.

### Added

- JSON-RPC 2.0 message layer: requests, notifications, responses, errors, batches.
- MCP types for tools, resources, prompts, content, capabilities, initialize, and logging.
- Compile-time JSON Schema generation from Zig structs (`types.schemaForStruct`) and
  typed argument parsing from the same struct (`types.parseArgs`).
- `Server(Handler)`: comptime-generic MCP server over stdio with request-scoped
  arena allocators and full lifecycle handling (initialize handshake, version
  negotiation, message loop).
- `HttpTransport(Handler)`: Streamable HTTP transport with session management,
  Origin validation (DNS rebinding protection), Content-Type/Accept validation,
  and a configurable request body size limit.
- `logging/setLevel` routing to an optional `setLoggingLevel` handler method and
  `Context.sendLogMessage` for `notifications/message`.
- Claude channel support: channel events, permission relay, experimental capabilities.
- Examples: greeter (stdio), greeter (HTTP), channel server.
- MCP stdio conformance script (`scripts/conformance.sh`) run in CI.

[0.5.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.5.0
[0.4.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.4.0
[0.3.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.3.0
[0.2.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.2.0
[0.1.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.1.0
