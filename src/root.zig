//! Zig MCP SDK — Model Context Protocol implementation.
//!
//! - `json_rpc`: JSON-RPC 2.0 message types, parsing, and serialization.
//! - `types`: MCP protocol types (capabilities, tools, resources, prompts, etc.).
//! - `server`: MCP server with stdio transport.
//! - `http_transport`: Streamable HTTP transport for remote MCP.
pub const json_rpc = @import("json_rpc.zig");
pub const types = @import("types.zig");
pub const server = @import("server.zig");
pub const Server = server.Server;
pub const Context = server.Context;
pub const http_transport = @import("http_transport.zig");
pub const HttpTransport = http_transport.HttpTransport;

test {
    @import("std").testing.refAllDecls(@This());
}
