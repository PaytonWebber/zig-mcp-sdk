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

/// Params for paginated list requests (`tools/list`, `resources/list`,
/// `prompts/list`). The cursor is an opaque token from a previous result's
/// `nextCursor`.
pub const ListParams = struct {
    cursor: ?[]const u8 = null,

    pub fn fromJson(val: @import("std").json.Value) error{InvalidParams}!ListParams {
        const obj = json_utils.asObject(val) orelse return error.InvalidParams;
        const c = obj.get("cursor") orelse return .{};
        return switch (c) {
            .string => |s| .{ .cursor = s },
            .null => .{},
            else => error.InvalidParams,
        };
    }
};

const json_utils = @import("json_utils.zig");

pub const Annotations = struct {
    audience: ?[]const Role = null,
    priority: ?f64 = null,
};
