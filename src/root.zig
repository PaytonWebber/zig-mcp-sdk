//! Zig MCP SDK — Model Context Protocol implementation.
//!
//! - `json_rpc`: JSON-RPC 2.0 message types, parsing, and serialization.
//! - `types`: MCP protocol types (capabilities, tools, resources, prompts, etc.).
//! - `server`: MCP server with stdio transport.
pub const json_rpc = @import("json_rpc.zig");
pub const types = @import("types.zig");
pub const server = @import("server.zig");
pub const Server = server.Server;

test {
    @import("std").testing.refAllDecls(@This());
}
