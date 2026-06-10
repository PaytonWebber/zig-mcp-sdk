# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Until 1.0.0, minor versions may contain breaking changes.

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

[0.1.0]: https://github.com/PaytonWebber/zig-mcp-sdk/releases/tag/v0.1.0
