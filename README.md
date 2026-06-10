# zig-mcp-sdk

[![CI](https://github.com/PaytonWebber/zig-mcp-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/PaytonWebber/zig-mcp-sdk/actions/workflows/ci.yml)

Define a Zig struct, get an MCP tool schema at compile time. No JSON schema strings, no runtime reflection cost.

```zig
const HelloArgs = struct {
    name: []const u8,
    pub const descriptions = .{ .name = "Name to greet" };
};

fn hello(allocator: Allocator, args: HelloArgs) !types.CallToolResult {
    const msg = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{args.name});
    return types.CallToolResult.text(allocator, msg);
}

const MyTools = mcp.ToolPack(.{
    .hello = .{ .description = "Say hello", .handler = hello },
});
```

That is a complete tool server. The JSON Schema, the `tools/list` entry, name dispatch, and typed argument parsing are all generated at compile time from the handler's signature, so the schema and the parser cannot drift apart.

The schema the model sees, baked into the binary from `HelloArgs`:

```json
{"type":"object","properties":{"name":{"type":"string","description":"Name to greet"}},"required":["name"]}
```

A [Model Context Protocol](https://modelcontextprotocol.io/) SDK for Zig. Build servers that expose tools, resources, and prompts to AI agents over **stdio** (local) or **Streamable HTTP** (remote).

- Request-scoped arena allocators: allocate freely in handlers, freed after the response
- Zero-copy strings: parsed slices point into arena memory, no duplication
- Handler methods resolved at comptime via `@hasDecl`, no vtables
- Concurrent multi-session HTTP with server-sent events for notifications
- No dependencies beyond the Zig standard library
- Conformance-tested in CI over both transports

Requires Zig 0.16.0. [API documentation](https://paytonwebber.github.io/zig-mcp-sdk/) is generated from source on every push.

## What you ship

[sqlite-mcp](https://github.com/PaytonWebber/sqlite-mcp) is a complete server built with this SDK: read-only SQLite access with tools, schema resources, and all of SQLite compiled in. Measured against the reference Python server and the most-used npm equivalent: same machine, same database, same three-message session (initialize, initialized notification, one SELECT), three warm runs each.

| | sqlite-mcp (this SDK) | mcp-server-sqlite (Python 3.14) | mcp-sqlite (Node 22) |
|---|---|---|---|
| What you install | one **1.0 MB** static binary | 33.5 MB venv, plus Python | 25.2 MB node_modules, plus Node.js |
| Full session, cold process | **2 ms** | 410 ms | 210 ms |
| Peak resident memory | **2.9 MB** | 64 MB | 84 MB |

The stripped `ReleaseSmall` x86_64-linux build. Users download one file and run `claude mcp add`; there is nothing else to install.

**When to use this.** If your tools are already Python or TypeScript, use the official SDKs; they are mature and their ecosystems are bigger. This SDK is for when the server itself should be a small, fast artifact: a tool you distribute to end users as one file, run in constrained environments, or start often enough that runtime startup matters.

## Quick Start

### 1. Add the dependency

```bash
zig fetch --save git+https://github.com/PaytonWebber/zig-mcp-sdk.git
```

Then in your `build.zig`:

```zig
const mcp_dep = b.dependency("zig_mcp_sdk", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zig_mcp_sdk", mcp_dep.module("zig_mcp_sdk"));
```

### 2. Define your tools

The snippet at the top of this page is the complete handler. It needs these imports:

```zig
const std = @import("std");
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;
```

A `ToolPack` implements `listTools` and `callTool`, so it can serve as the handler by itself. Servers that also expose resources or prompts write a handler struct and embed the pack; see [`examples/greeter.zig`](examples/greeter.zig).

### 3. Start the server

Stdio transport (Claude Desktop, Claude Code, Cursor):

```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var tools = MyTools{};
    var server = mcp.Server(MyTools).init(allocator, &tools, .{
        .server_info = .{ .name = "my-server", .version = "0.1.0" },
        .capabilities = .{ .tools = .{} },
    });

    try server.start(init.io);
}
```

HTTP transport (remote or cloud deployment). Connections are handled concurrently, so use a thread-safe allocator:

```zig
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;

    var tools = MyTools{};
    var server = mcp.Server(MyTools).init(allocator, &tools, .{
        .server_info = .{ .name = "my-server", .version = "0.1.0" },
        .capabilities = .{ .tools = .{} },
    });

    var transport = mcp.HttpTransport(MyTools).init(allocator, &server, .{
        .port = 8080,
    });
    defer transport.deinit();
    try transport.listen(init.io);
}
```

## Tool Packs

`mcp.ToolPack` generates `listTools` and `callTool` from one declaration per tool. Each def takes a `.description` and a `.handler`; the handler's args struct drives the schema and the parsing. Optional fields: `.args` to name the struct explicitly, `.annotations` for `types.ToolAnnotations`.

Handlers come in two forms, detected at compile time:

```zig
fn simple(allocator: Allocator, args: MyArgs) !types.CallToolResult
fn withContext(allocator: Allocator, tc: mcp.ToolContext, args: MyArgs) !types.CallToolResult
```

`ToolContext` carries the per-call notification context. `tc.sendProgress(i, total)` reports progress and is a no-op when the client did not send a progress token, so handlers call it unconditionally. Over HTTP, progress streams on the POST's own SSE response.

Packs compose. A library can export its defs, and an application mounts several at once:

```zig
// in a library:
pub const tool_defs = .{
    .search = .{ .description = "Search the index", .handler = search },
};

// in the application:
const Tools = mcp.ToolPack(.{ some_lib.tool_defs, my_defs });
```

Duplicate tool names across packs are a compile error. Unknown tool names and arguments that fail validation are returned to the client as `isError` results.

Tools that share mutable state (a database handle, a client connection) use `mcp.StatefulToolPack(State, defs)`: the pack holds a `state: *State` and passes it as the handlers' first parameter:

```zig
fn record(self: *Bridge, allocator: Allocator, args: RecordArgs) !types.CallToolResult
```

## Handler Methods

Implement only what your server supports and declare the matching capabilities.

| Method | Signature | Capability |
|--------|-----------|------------|
| `listTools` | `fn(*Handler, Allocator) !ListToolsResult` | `.tools = .{}` |
| `callTool` | `fn(*Handler, Allocator, CallToolParams) !CallToolResult` | `.tools = .{}` |
| `listResources` | `fn(*Handler, Allocator) !ListResourcesResult` | `.resources = .{}` |
| `readResource` | `fn(*Handler, Allocator, ReadResourceParams) !ReadResourceResult` | `.resources = .{}` |
| `listPrompts` | `fn(*Handler, Allocator) !ListPromptsResult` | `.prompts = .{}` |
| `getPrompt` | `fn(*Handler, Allocator, GetPromptParams) !GetPromptResult` | `.prompts = .{}` |
| `setLoggingLevel` | `fn(*Handler, LoggingLevel) void` | `.logging = .{}` |
| `onCancelled` | `fn(*Handler, CancelledParams) void` | none |

List handlers may instead take `(*Handler, Allocator, ListParams)` to receive the pagination cursor, and `callTool` may instead take `(*Handler, Allocator, Context, CallToolParams)` to send notifications during the call; the arity is detected at compile time. Return `nextCursor` in list results to signal more pages.

The `Allocator` passed to each handler is an arena scoped to the request. Allocate freely from it; memory is released after the response is sent. Slices in params are request-scoped too: copy them if you keep them past the handler call.

If `callTool` returns an error, the client receives a tool result with `isError: true` rather than a JSON-RPC error, as the MCP spec requires.

### Server-initiated notifications

Handlers that declare `onReady(*Handler, mcp.Context)` receive a `Context` once the client completes the handshake. Use it to push notifications:

```zig
ctx.sendLogMessage(.{ .level = .info, .data = .{ .string = "ready" } });
ctx.sendProgress(.{ .progressToken = token, .progress = 0.5, .total = 1.0 });
ctx.sendNotification("notifications/tools/list_changed", .{});
```

For progress during a tool call, use the 4-arg `callTool` form and echo the token from `CallToolParams.progressToken()` (sent by the client in `_meta.progressToken`):

```zig
pub fn callTool(_: *H, allocator: Allocator, ctx: mcp.Context, params: types.CallToolParams) !types.CallToolResult {
    if (params.progressToken()) |token| {
        try ctx.sendProgress(.{ .progressToken = token, .progress = 1.0, .total = 10.0 });
    }
    // ...
}
```

Over stdio, notifications interleave with responses on stdout. Over HTTP, notifications sent during a tool call stream on the POST's own SSE response (when the client accepts `text/event-stream`); session-level notifications are delivered on the session's GET stream.

### Schema generation

`schemaForStruct` reflects on a struct at compile time and emits a JSON Schema string. `parseArgs` parses incoming arguments into the same struct, so the schema and the parser cannot drift apart. Supported field types: strings, bools, integers, floats, enums, slices, nested structs, and optionals of any of these.

Struct defaults become schema defaults and make fields optional; a `pub const descriptions` declaration adds per-field descriptions. This struct:

```zig
const SearchArgs = struct {
    query: []const u8,
    limit: u32 = 10,
    pub const descriptions = .{ .query = "Search query", .limit = "Max results" };
};
```

emits this schema (and `parseArgs` fills `limit` with 10 when absent):

```json
{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"limit":{"type":"integer","description":"Max results","default":10}},"required":["query"]}
```

## Server Options

```zig
mcp.Server(Handler).init(allocator, &handler, .{
    .server_info = .{ .name = "my-server", .version = "1.0.0" },

    // What the server supports (default: nothing)
    .capabilities = .{
        .tools = .{},
        .resources = .{},
        .prompts = .{},
        .logging = .{},
    },

    // Optional instructions shown to the client
    .instructions = "A helpful description of this server.",

    // Stdio buffer sizes (default 64KB each)
    .read_buffer_size = 64 * 1024,
    .write_buffer_size = 64 * 1024,
});
```

## HTTP Transport Options

```zig
mcp.HttpTransport(Handler).init(allocator, &server, .{
    .port = 8080,                 // default
    .address = "127.0.0.1",       // default, use "0.0.0.0" for all interfaces
    .max_body_size = 1024 * 1024, // reject larger POST bodies with 413
    .allowed_origins = &.{},      // extra origins beyond localhost
    .max_sessions = 64,           // new initialize beyond this gets 503
    .sse_keepalive_seconds = 15,  // keepalive interval on SSE streams
    .sse_replay_events = 64,      // buffered events for replay/resume, 0 disables
    .session_idle_seconds = 600,  // reap inactive sessions, 0 disables
});
```

The HTTP transport implements the [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http) protocol:

- `POST /` for JSON-RPC messages, `GET /` with `Accept: text/event-stream` for the server-to-client event stream, `DELETE /` to terminate the session
- Multiple concurrent sessions, each negotiating its own protocol version, with connections handled in parallel
- Session management via `Mcp-Session-Id` headers, IDs from the OS CSPRNG
- Tool calls stream their response as SSE when the client accepts it: progress notifications first, then the result
- Resumable event streams: events carry ids, undelivered events are buffered and replayed when a stream opens, and `Last-Event-ID` resumes after a reconnect. A new GET takes over the stream (last connection wins).
- Idle sessions are reaped by a background task after `session_idle_seconds` of inactivity
- `Content-Type` and `Accept` validation
- Origin header validation against localhost plus `allowed_origins`, which blocks DNS rebinding attacks. Non-browser clients that send no Origin header always pass.

Connections are handled concurrently, so the allocator passed to `init` (and to the `Server`) must be thread-safe, and handler methods must tolerate concurrent calls. `std.heap.smp_allocator` works well; per-request arenas are still created for you.

## Connecting to Clients

### Claude Code (stdio)

```bash
claude mcp add my-server /path/to/my-server
```

### Claude Desktop / Cursor (stdio)

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/my-server"
    }
  }
}
```

### VS Code (HTTP)

```json
{
  "mcp": {
    "servers": {
      "my-server": {
        "type": "http",
        "url": "http://localhost:8080"
      }
    }
  }
}
```

### curl (HTTP)

```bash
# Initialize
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'

# Send initialized notification (use session ID from previous response header)
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Call a tool
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"hello","arguments":{"name":"World"}},"id":2}'

# Open the SSE stream for server-initiated notifications
curl -N http://localhost:8080 \
  -H "Accept: text/event-stream" \
  -H "Mcp-Session-Id: <session-id>"
```

## Building

```bash
zig build              # compile example servers
zig build test         # run all tests
zig build check        # tests + format checks + compile examples
zig build examples     # install example binaries to zig-out/bin
zig build example      # build and run the stdio greeter example
zig build example-http # build and run the HTTP greeter example
```

CI runs `zig build check` plus two conformance scripts: [`scripts/conformance.sh`](scripts/conformance.sh) drives the greeter binary through a full stdio session (handshake, ping, tool calls, resources, prompts, error codes, parse-error recovery), and [`scripts/conformance_http.sh`](scripts/conformance_http.sh) exercises the HTTP transport with curl (concurrent sessions, SSE event delivery, security rejections, session termination).

## Versioning

- Tracks the latest stable Zig release, currently 0.16.0. New stable Zig releases are adopted within a few weeks.
- Semantic versioning, see [CHANGELOG.md](CHANGELOG.md). Until 1.0.0, minor versions may contain breaking changes.

## Examples

- [`examples/greeter.zig`](examples/greeter.zig): stdio server with tools, resources, and prompts
- [`examples/greeter_http.zig`](examples/greeter_http.zig): HTTP server with tools and SSE log notifications
- [`examples/channel.zig`](examples/channel.zig): Claude channel protocol example

Built with this SDK:

- [sqlite-mcp](https://github.com/PaytonWebber/sqlite-mcp): read-only SQLite access for AI agents in a single ~1 MB static binary
- [agent-waymark](https://github.com/PaytonWebber/agent-waymark): durable shared working-state for agent orchestration; a daemon-backed MCP server (via `StatefulToolPack`) plus hooks that inject decisions, findings, and todos into every session

## License

MIT
