const std = @import("std");
const json = std.json;

pub fn asObject(val: ?json.Value) ?json.ObjectMap {
    const v = val orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn getString(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(obj: json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// Serialize a struct as a JSON object with a leading `"type"` discriminator field.
/// Remaining fields are written in declaration order, skipping null optionals.
pub fn stringifyWithTypeTag(comptime type_value: []const u8, self: anytype, jw: anytype) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(type_value);
    inline for (@typeInfo(@TypeOf(self)).@"struct".fields) |field| {
        if (field.type == void) continue;
        if (comptime @typeInfo(field.type) == .optional) {
            if (@field(self, field.name)) |val| {
                try jw.objectField(field.name);
                try jw.write(val);
            }
        } else {
            try jw.objectField(field.name);
            try jw.write(@field(self, field.name));
        }
    }
    try jw.endObject();
}

pub const ParseError = error{ InvalidParams, OutOfMemory };

/// Deserialize tool/prompt arguments from a JSON value into a typed struct `T`,
/// the same struct used by `schema.schemaForStruct` to generate the input
/// schema. One type definition drives both the schema and the parse.
///
/// Supported field types: `[]const u8`, `bool`, integers, floats, enums (from
/// their string name), slices of any supported type (`[]const T`), and
/// optionals of any of these. A field is satisfied by, in order: a present
/// non-null value, its struct default, or `null` if optional. A missing
/// required field, or a value of the wrong JSON type, yields `error.InvalidParams`.
///
/// String slices are referenced zero-copy from `args` (which the caller owns for
/// the request's lifetime); container slices are allocated from `allocator`.
pub fn parseArgs(comptime T: type, allocator: std.mem.Allocator, args: ?json.Value) ParseError!T {
    // Absent or null arguments are treated as an empty object so that
    // tools whose fields all have defaults (or none) need no arguments.
    const obj: ?json.ObjectMap = if (args) |a| switch (a) {
        .object => |o| o,
        .null => null,
        else => return error.InvalidParams,
    } else null;

    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const present = if (obj) |o| o.get(field.name) else null;
        if (present == null or present.? == .null) {
            if (field.default_value_ptr) |ptr| {
                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(ptr))).*;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.InvalidParams;
            }
        } else {
            @field(result, field.name) = try parseValue(field.type, allocator, present.?);
        }
    }
    return result;
}

fn parseValue(comptime T: type, allocator: std.mem.Allocator, val: json.Value) ParseError!T {
    if (@typeInfo(T) == .optional) {
        return try parseValue(@typeInfo(T).optional.child, allocator, val);
    }
    if (T == []const u8) {
        return switch (val) {
            .string => |s| s,
            else => error.InvalidParams,
        };
    }
    return switch (@typeInfo(T)) {
        .bool => switch (val) {
            .bool => |b| b,
            else => error.InvalidParams,
        },
        .int => switch (val) {
            .integer => |i| std.math.cast(T, i) orelse error.InvalidParams,
            else => error.InvalidParams,
        },
        .float => switch (val) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => error.InvalidParams,
        },
        .@"enum" => switch (val) {
            .string => |s| std.meta.stringToEnum(T, s) orelse error.InvalidParams,
            else => error.InvalidParams,
        },
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("parseArgs: unsupported pointer type " ++ @typeName(T));
            const arr = switch (val) {
                .array => |a| a,
                else => return error.InvalidParams,
            };
            const out = try allocator.alloc(p.child, arr.items.len);
            for (arr.items, out) |item, *slot| slot.* = try parseValue(p.child, allocator, item);
            break :blk out;
        },
        .@"struct" => parseArgs(T, allocator, val), // nested object
        else => @compileError("parseArgs: unsupported field type " ++ @typeName(T)),
    };
}

/// Parse a struct from a `std.json.Value` object by reflecting on its fields.
/// Handles required `[]const u8` fields and optional `?json.Value` fields.
pub fn parseFromJsonObject(comptime T: type, val: json.Value) error{InvalidParams}!T {
    const obj = asObject(val) orelse return error.InvalidParams;
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type == []const u8) {
            @field(result, field.name) = getString(obj, field.name) orelse return error.InvalidParams;
        } else if (field.type == ?json.Value) {
            @field(result, field.name) = obj.get(field.name);
        } else {
            @compileError("parseFromJsonObject: unsupported field type for '" ++ field.name ++ "'");
        }
    }
    return result;
}

const testing = std.testing;

// Parse into the arena and run parseArgs against it. Zero-copy string slices
// reference arena memory, so the arena must outlive the returned struct. This
// mirrors the request-scoped arena the server hands each handler.
fn parseJson(comptime T: type, arena: std.mem.Allocator, text: []const u8) !T {
    const value = try json.parseFromSliceLeaky(json.Value, arena, text, .{});
    return parseArgs(T, arena, value);
}

test "parseArgs: required string, defaulted int, applies default when absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Args = struct { name: []const u8, count: u32 = 3 };

    const a = try parseJson(Args, arena.allocator(), "{\"name\":\"ada\"}");
    try testing.expectEqualStrings("ada", a.name);
    try testing.expectEqual(@as(u32, 3), a.count);

    const b = try parseJson(Args, arena.allocator(), "{\"name\":\"ada\",\"count\":7}");
    try testing.expectEqual(@as(u32, 7), b.count);
}

test "parseArgs: missing required field is InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Args = struct { name: []const u8 };
    try testing.expectError(error.InvalidParams, parseJson(Args, arena.allocator(), "{}"));
}

test "parseArgs: wrong JSON type is InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Args = struct { count: i64 };
    try testing.expectError(error.InvalidParams, parseJson(Args, arena.allocator(), "{\"count\":\"nope\"}"));
}

test "parseArgs: optional absent becomes null, present is parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Args = struct { tags: ?[]const []const u8 = null };

    const a = try parseJson(Args, arena.allocator(), "{}");
    try testing.expect(a.tags == null);

    const b = try parseJson(Args, arena.allocator(), "{\"tags\":[\"zig\",\"mcp\"]}");
    try testing.expectEqual(@as(usize, 2), b.tags.?.len);
    try testing.expectEqualStrings("mcp", b.tags.?[1]);
}

test "parseArgs: float array (embedding bypass) accepts integers and floats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Args = struct { embedding: []const f32 };

    const a = try parseJson(Args, arena.allocator(), "{\"embedding\":[0.5,1,2.25]}");
    try testing.expectEqual(@as(usize, 3), a.embedding.len);
    try testing.expectEqual(@as(f32, 1.0), a.embedding[1]);
}

test "parseArgs: nested struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Inner = struct { host: []const u8, port: u16 = 80 };
    const Args = struct { name: []const u8, server: Inner };

    const a = try parseJson(Args, arena.allocator(), "{\"name\":\"x\",\"server\":{\"host\":\"h\",\"port\":9000}}");
    try testing.expectEqualStrings("h", a.server.host);
    try testing.expectEqual(@as(u16, 9000), a.server.port);

    // nested default applies when the inner field is absent
    const b = try parseJson(Args, arena.allocator(), "{\"name\":\"x\",\"server\":{\"host\":\"h\"}}");
    try testing.expectEqual(@as(u16, 80), b.server.port);
}

test "parseArgs: enum from string name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Args = struct { level: enum { low, high } = .low };

    const a = try parseJson(Args, arena.allocator(), "{\"level\":\"high\"}");
    try testing.expectEqual(.high, a.level);
}
