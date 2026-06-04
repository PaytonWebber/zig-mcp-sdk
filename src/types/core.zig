/// MCP protocol version this SDK advertises by default (the latest supported).
pub const protocol_version = "2025-11-25";

/// Protocol versions this SDK can negotiate, newest first. During `initialize`
/// the server echoes the client's requested version if it appears here, and
/// otherwise responds with `protocol_version` (the latest).
pub const supported_protocol_versions = [_][]const u8{
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
};

/// Describes an MCP implementation (client or server). `name` and `version` are
/// required; the rest are optional and omitted from the wire when null.
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    websiteUrl: ?[]const u8 = null,
};

pub const Role = enum {
    user,
    assistant,
};

pub const Annotations = struct {
    audience: ?[]const Role = null,
    priority: ?f64 = null,
};
