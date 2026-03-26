const std = @import("std");
const json = std.json;
const json_utils = @import("json_utils.zig");
const Allocator = std.mem.Allocator;

pub const channel_event_method = "notifications/claude/channel";
pub const permission_request_method = "notifications/claude/channel/permission_request";
pub const permission_verdict_method = "notifications/claude/channel/permission";

pub const ChannelEventParams = struct {
    content: []const u8,
    meta: ?json.Value = null,
};

pub const PermissionBehavior = enum {
    allow,
    deny,
};

pub const PermissionRequestParams = struct {
    request_id: []const u8,
    tool_name: []const u8,
    description: []const u8,
    input_preview: []const u8,

    pub fn fromJson(val: json.Value) error{InvalidParams}!PermissionRequestParams {
        return json_utils.parseFromJsonObject(PermissionRequestParams, val);
    }
};

pub const PermissionVerdictParams = struct {
    request_id: []const u8,
    behavior: PermissionBehavior,
};

/// Build the `experimental` capability value for channel servers.
/// Pass `permission = true` to also declare permission relay support.
pub fn experimentalCapabilities(allocator: Allocator, opts: struct { permission: bool = false }) !json.Value {
    var map = json.ObjectMap.init(allocator);
    errdefer map.deinit();

    const channel_obj = json.ObjectMap.init(allocator);
    try map.put("claude/channel", .{ .object = channel_obj });

    if (opts.permission) {
        const perm_obj = json.ObjectMap.init(allocator);
        try map.put("claude/channel/permission", .{ .object = perm_obj });
    }

    return .{ .object = map };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ChannelEventParams serializes with content and meta" {
    var meta = json.ObjectMap.init(testing.allocator);
    defer meta.deinit();
    try meta.put("source", .{ .string = "test" });
    try meta.put("severity", .{ .string = "high" });

    const params = ChannelEventParams{
        .content = "build failed",
        .meta = .{ .object = meta },
    };

    const bytes = try std.json.Stringify.valueAlloc(
        testing.allocator,
        params,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"content\":\"build failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"source\":\"test\"") != null);
}

test "ChannelEventParams serializes without meta" {
    const params = ChannelEventParams{ .content = "hello" };

    const bytes = try std.json.Stringify.valueAlloc(
        testing.allocator,
        params,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"content\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "meta") == null);
}

test "PermissionVerdictParams serializes correctly" {
    const params = PermissionVerdictParams{
        .request_id = "abcde",
        .behavior = .allow,
    };

    const bytes = try std.json.Stringify.valueAlloc(
        testing.allocator,
        params,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"request_id\":\"abcde\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"behavior\":\"allow\"") != null);
}

test "PermissionVerdictParams deny serializes correctly" {
    const params = PermissionVerdictParams{
        .request_id = "fghij",
        .behavior = .deny,
    };

    const bytes = try std.json.Stringify.valueAlloc(
        testing.allocator,
        params,
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"behavior\":\"deny\"") != null);
}

test "PermissionRequestParams.fromJson parses valid input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input =
        \\{"request_id":"abcde","tool_name":"Bash","description":"Run a command","input_preview":"{\"command\":\"ls\"}"}
    ;

    const val = try std.json.parseFromSliceLeaky(json.Value, arena.allocator(), input, .{ .allocate = .alloc_always });
    const params = try PermissionRequestParams.fromJson(val);

    try testing.expectEqualStrings("abcde", params.request_id);
    try testing.expectEqualStrings("Bash", params.tool_name);
    try testing.expectEqualStrings("Run a command", params.description);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", params.input_preview);
}

test "PermissionRequestParams.fromJson rejects missing fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input =
        \\{"request_id":"abcde","tool_name":"Bash"}
    ;

    const val = try std.json.parseFromSliceLeaky(json.Value, arena.allocator(), input, .{ .allocate = .alloc_always });
    try testing.expectError(error.InvalidParams, PermissionRequestParams.fromJson(val));
}

test "experimentalCapabilities without permission" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const val = try experimentalCapabilities(arena.allocator(), .{});
    const obj = val.object;

    try testing.expect(obj.get("claude/channel") != null);
    try testing.expect(obj.get("claude/channel/permission") == null);
}

test "experimentalCapabilities with permission" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const val = try experimentalCapabilities(arena.allocator(), .{ .permission = true });
    const obj = val.object;

    try testing.expect(obj.get("claude/channel") != null);
    try testing.expect(obj.get("claude/channel/permission") != null);
}
