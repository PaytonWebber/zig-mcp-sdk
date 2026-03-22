/// MCP protocol version supported by this SDK.
pub const protocol_version = "2025-03-26";

/// Describes the name and version of an MCP implementation.
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

pub const Role = enum {
    user,
    assistant,
};

pub const Annotations = struct {
    audience: ?[]const Role = null,
    priority: ?f64 = null,
};
