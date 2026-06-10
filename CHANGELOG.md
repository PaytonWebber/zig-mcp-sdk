# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Until 1.0.0, minor versions may contain breaking changes.

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

[0.2.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.2.0
[0.1.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.1.0
