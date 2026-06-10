const std = @import("std");
const json = std.json;
const json_utils = @import("json_utils.zig");

pub const cancelled_method = "notifications/cancelled";
pub const progress_method = "notifications/progress";

/// A request id or progress token. The spec allows either a string or an
/// integer wherever these appear.
pub const TokenValue = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn jsonStringify(self: TokenValue, jw: anytype) !void {
        switch (self) {
            .string => |s| try jw.write(s),
            .integer => |i| try jw.write(i),
        }
    }

    pub fn fromJson(val: json.Value) ?TokenValue {
        return switch (val) {
            .string => |s| .{ .string = s },
            .integer => |i| .{ .integer = i },
            else => null,
        };
    }

    pub fn eql(a: TokenValue, b: TokenValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .integer => |i| i == b.integer,
        };
    }
};

/// Params for `notifications/cancelled` sent by the client to cancel an
/// in-flight request. String slices borrow request-scoped memory and are
/// valid only for the duration of the handler callback; copy them to keep them.
pub const CancelledParams = struct {
    requestId: TokenValue,
    reason: ?[]const u8 = null,

    pub fn fromJson(val: json.Value) error{InvalidParams}!CancelledParams {
        const obj = json_utils.asObject(val) orelse return error.InvalidParams;
        const id_val = obj.get("requestId") orelse return error.InvalidParams;
        const id = TokenValue.fromJson(id_val) orelse return error.InvalidParams;
        return .{ .requestId = id, .reason = json_utils.getString(obj, "reason") };
    }
};

/// Params for `notifications/progress` sent by the server during a
/// long-running request. `progressToken` echoes the token the client supplied
/// in the originating request's `_meta.progressToken`.
pub const ProgressParams = struct {
    progressToken: TokenValue,
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,
};

const testing = std.testing;

test "CancelledParams.fromJson accepts string and integer request ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const a = try CancelledParams.fromJson(try json.parseFromSliceLeaky(json.Value, arena.allocator(),
        \\{"requestId":42,"reason":"user aborted"}
    , .{}));
    try testing.expect(a.requestId.eql(.{ .integer = 42 }));
    try testing.expectEqualStrings("user aborted", a.reason.?);

    const b = try CancelledParams.fromJson(try json.parseFromSliceLeaky(json.Value, arena.allocator(),
        \\{"requestId":"req-7"}
    , .{}));
    try testing.expect(b.requestId.eql(.{ .string = "req-7" }));
    try testing.expect(b.reason == null);
}

test "CancelledParams.fromJson rejects missing or malformed requestId" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const missing = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{}", .{});
    try testing.expectError(error.InvalidParams, CancelledParams.fromJson(missing));

    const wrong = try json.parseFromSliceLeaky(json.Value, arena.allocator(),
        \\{"requestId":true}
    , .{});
    try testing.expectError(error.InvalidParams, CancelledParams.fromJson(wrong));
}
