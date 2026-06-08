# zig-mcp-sdk

A [Model Context Protocol](https://modelcontextprotocol.io/) SDK for Zig. Build MCP servers that expose tools, resources, and prompts to AI agents.

Supports both **stdio** (local) and **Streamable HTTP** (remote) transports.

**Requires Zig 0.16.0**.

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

### 2. Define a Handler

A Handler is a struct that implements the MCP methods you want to support. All methods are optional. Implement only what you need.

```zig
const std = @import("std");
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;

const HelloArgs = struct {
    name: []const u8,
    pub const descriptions = .{ .name = "Name to greet" };
};

const MyHandler = struct {
    pub fn listTools(_: *MyHandler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{
                    .name = "hello",
                    .description = "Say hello",
                    .inputSchema = comptime types.schemaForStruct(HelloArgs),
                },
            },
        };
    }

    pub fn callTool(_: *MyHandler, allocator: Allocator, params: types.CallToolParams) !types.CallToolResult {
        if (std.mem.eql(u8, params.name, "hello")) {
            const args = try types.parseArgs(HelloArgs, allocator, params.arguments);
            const msg = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{args.name});
            return types.CallToolResult.text(allocator, msg);
        }

        return error.ToolNotFound;
    }
};
```

### 3. Start the server

**Stdio transport** (for Claude Desktop, Cursor, etc.):

```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var handler = MyHandler{};
    var server = mcp.Server(MyHandler).init(allocator, &handler, .{
        .server_info = .{ .name = "my-server", .version = "0.1.0" },
        .capabilities = .{ .tools = .{} },
    });

    try server.start(init.io);
}
```

**HTTP transport** (for remote/cloud deployment):

```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var handler = MyHandler{};
    var server = mcp.Server(MyHandler).init(allocator, &handler, .{
        .server_info = .{ .name = "my-server", .version = "0.1.0" },
        .capabilities = .{ .tools = .{} },
    });

    var transport = mcp.HttpTransport(MyHandler).init(allocator, &server, .{
        .port = 8080,
    });
    try transport.listen(init.io);
}
```

## Handler Methods

All methods are optional. Implement only what your server supports, and declare matching capabilities in the server options.

| Method | Signature | Capability |
|--------|-----------|------------|
| `listTools` | `fn(*Handler, Allocator) !ListToolsResult` | `.tools = .{}` |
| `callTool` | `fn(*Handler, Allocator, CallToolParams) !CallToolResult` | `.tools = .{}` |
| `listResources` | `fn(*Handler, Allocator) !ListResourcesResult` | `.resources = .{}` |
| `readResource` | `fn(*Handler, Allocator, ReadResourceParams) !ReadResourceResult` | `.resources = .{}` |
| `listPrompts` | `fn(*Handler, Allocator) !ListPromptsResult` | `.prompts = .{}` |
| `getPrompt` | `fn(*Handler, Allocator, GetPromptParams) !GetPromptResult` | `.prompts = .{}` |

The `Allocator` passed to each handler is an **arena scoped to the request**. Allocate freely from it. Memory is released automatically when the response is sent.

If a `callTool` handler returns an error, it is sent to the client as a tool result with `isError: true`, not as a JSON-RPC error. This matches the MCP spec.

## Server Options

```zig
mcp.Server(Handler).init(allocator, &handler, .{
    // Required
    .server_info = .{ .name = "my-server", .version = "1.0.0" },

    // Declare what the server supports (default: nothing)
    .capabilities = .{
        .tools = .{},           // enable tools/list and tools/call
        .resources = .{},       // enable resources/list and resources/read
        .prompts = .{},         // enable prompts/list and prompts/get
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
    .port = 8080,              // default
    .address = "127.0.0.1",   // default, use "0.0.0.0" for all interfaces
});
```

The HTTP transport implements the [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http) protocol:

- `POST /`: JSON-RPC messages (requests and notifications)
- `DELETE /`: terminate session
- Session management via `Mcp-Session-Id` headers
- `Accept: application/json` validation

Currently requires Linux (uses `getrandom` syscall for session IDs).

## Connecting to Clients

### Claude Desktop / Cursor (stdio)

Add to your MCP configuration:

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
```

## Building

```bash
zig build              # compile example servers
zig build test         # run all tests
zig build check        # run tests, format checks, and compile examples
zig build example      # build and run the stdio greeter example
zig build example-http # build and run the HTTP greeter example
```

## Examples

- [`examples/greeter.zig`](examples/greeter.zig): stdio server with tools, resources, and prompts
- [`examples/greeter_http.zig`](examples/greeter_http.zig): HTTP server with tools
- [`examples/channel.zig`](examples/channel.zig): channel protocol example

## License

MIT
