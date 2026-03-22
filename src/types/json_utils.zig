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
