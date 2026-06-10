const std = @import("std");
const json_utils = @import("json_utils.zig");

pub const log_message_method = "notifications/message";

pub const LoggingLevel = enum {
    emergency,
    alert,
    critical,
    @"error",
    warning,
    notice,
    info,
    debug,
};

/// Params for `logging/setLevel` requests.
pub const SetLevelParams = struct {
    level: LoggingLevel,

    pub fn fromJson(val: std.json.Value) error{InvalidParams}!SetLevelParams {
        const obj = json_utils.asObject(val) orelse return error.InvalidParams;
        const name = json_utils.getString(obj, "level") orelse return error.InvalidParams;
        const level = std.meta.stringToEnum(LoggingLevel, name) orelse return error.InvalidParams;
        return .{ .level = level };
    }
};

/// Params for `notifications/message` log notifications sent to the client.
pub const LogMessageParams = struct {
    level: LoggingLevel,
    logger: ?[]const u8 = null,
    data: std.json.Value,
};

const testing = std.testing;

test "SetLevelParams.fromJson parses a valid level" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"level":"warning"}
    , .{});
    const params = try SetLevelParams.fromJson(val);
    try testing.expectEqual(LoggingLevel.warning, params.level);
}

test "SetLevelParams.fromJson rejects unknown levels and bad shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad_level = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"level":"verbose"}
    , .{});
    try testing.expectError(error.InvalidParams, SetLevelParams.fromJson(bad_level));
    try testing.expectError(error.InvalidParams, SetLevelParams.fromJson(.{ .string = "warning" }));
}
