//! Comptime JSON Schema generation from Zig structs.
//!
//! `schemaForStruct(T)` reflects over a struct's fields and produces an MCP
//! tool `inputSchema` string at compile time, so tool authors describe their
//! arguments once as a Zig type instead of hand-writing JSON Schema. The same
//! struct drives `json_utils.parseArgs` for deserialization.
//!
//! Field descriptions come from an optional sibling declaration on the struct:
//!
//!     const GreetArgs = struct {
//!         name: []const u8,
//!         count: u32 = 3,
//!         pub const descriptions = .{
//!             .name = "Name to greet",
//!             .count = "Number of greetings",
//!         };
//!     };
//!
//! A field is `required` when it is neither optional nor has a default value.

const std = @import("std");

/// Build a JSON Schema object string for `T` at comptime.
pub fn schemaForStruct(comptime T: type) []const u8 {
    return "{" ++ objectBody(T) ++ "}";
}

/// The object schema keys for a struct (`"type":"object","properties":{…}`
/// plus `"required":[…]`), without the surrounding braces, so it can be reused
/// both as a top-level schema and as a nested-object property.
fn objectBody(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("schemaForStruct expects a struct, got " ++ @typeName(T));
    const fields = info.@"struct".fields;

    comptime var props: []const u8 = "";
    comptime var required: []const u8 = "";
    comptime var first_prop = true;
    comptime var first_req = true;

    inline for (fields) |field| {
        if (!first_prop) props = props ++ ",";
        first_prop = false;
        props = props ++ "\"" ++ field.name ++ "\":" ++ propertySchema(T, field);

        if (!isOptional(field.type) and field.default_value_ptr == null) {
            if (!first_req) required = required ++ ",";
            first_req = false;
            required = required ++ "\"" ++ field.name ++ "\"";
        }
    }

    const base = "\"type\":\"object\",\"properties\":{" ++ props ++ "}";
    if (first_req) return base; // no required fields
    return base ++ ",\"required\":[" ++ required ++ "]";
}

/// Escape a string for embedding inside a JSON string literal at comptime.
fn jsonEscape(comptime s: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (s) |c| {
        const piece: []const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) std.fmt.comptimePrint("\\u{x:0>4}", .{c}) else &[_]u8{c},
        };
        out = out ++ piece;
    }
    return out;
}

/// Schema object for a single struct field, including its optional
/// `"description"` and `"default"` keys.
fn propertySchema(comptime T: type, comptime field: std.builtin.Type.StructField) []const u8 {
    const ChildType = comptime if (isOptional(field.type)) @typeInfo(field.type).optional.child else field.type;

    comptime var out: []const u8 = "{" ++ typeKeys(ChildType);

    if (comptime descriptionFor(T, field.name)) |desc| {
        out = out ++ ",\"description\":\"" ++ jsonEscape(desc) ++ "\"";
    }
    if (comptime defaultKey(field)) |def| {
        out = out ++ ",\"default\":" ++ def;
    }
    return out ++ "}";
}

/// The `"type"`-bearing keys for a leaf or compound type (no surrounding braces).
fn typeKeys(comptime T: type) []const u8 {
    if (T == []const u8) return "\"type\":\"string\"";

    return switch (@typeInfo(T)) {
        .bool => "\"type\":\"boolean\"",
        .int => "\"type\":\"integer\"",
        .float => "\"type\":\"number\"",
        .@"enum" => |e| blk: {
            comptime var variants: []const u8 = "";
            inline for (e.fields, 0..) |ef, i| {
                if (i != 0) variants = variants ++ ",";
                variants = variants ++ "\"" ++ ef.name ++ "\"";
            }
            break :blk "\"type\":\"string\",\"enum\":[" ++ variants ++ "]";
        },
        .pointer => |p| if (p.size == .slice)
            "\"type\":\"array\",\"items\":{" ++ typeKeys(p.child) ++ "}"
        else
            @compileError("schemaForStruct: unsupported pointer type " ++ @typeName(T)),
        .optional => |o| typeKeys(o.child), // array-of-optional: schema as the inner type
        .@"struct" => objectBody(T), // nested object
        else => @compileError("schemaForStruct: unsupported field type " ++ @typeName(T)),
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn descriptionFor(comptime T: type, comptime name: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "descriptions")) return null;
    const d = T.descriptions;
    if (!@hasField(@TypeOf(d), name)) return null;
    return @field(d, name);
}

/// JSON-encoded default value for a field, or null if it has none.
fn defaultKey(comptime field: std.builtin.Type.StructField) ?[]const u8 {
    const ptr = field.default_value_ptr orelse return null;
    const T = field.type;
    const Child = comptime if (isOptional(T)) @typeInfo(T).optional.child else T;
    const val = @as(*const T, @ptrCast(@alignCast(ptr))).*;

    if (isOptional(T)) {
        // A null default contributes no JSON Schema default.
        if (val == null) return null;
    }
    const v = if (isOptional(T)) val.? else val;

    if (Child == []const u8) return "\"" ++ jsonEscape(v) ++ "\"";
    return switch (@typeInfo(Child)) {
        .bool => if (v) "true" else "false",
        .int => std.fmt.comptimePrint("{d}", .{v}),
        .float => std.fmt.comptimePrint("{d}", .{v}),
        .@"enum" => "\"" ++ @tagName(v) ++ "\"",
        else => null,
    };
}

test "schemaForStruct: required string + defaulted int" {
    const Args = struct {
        name: []const u8,
        count: u32 = 3,
        pub const descriptions = .{ .name = "Name to greet", .count = "Times" };
    };
    const schema = comptime schemaForStruct(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{" ++
            "\"name\":{\"type\":\"string\",\"description\":\"Name to greet\"}," ++
            "\"count\":{\"type\":\"integer\",\"description\":\"Times\",\"default\":3}}," ++
            "\"required\":[\"name\"]}",
        schema,
    );
}

test "schemaForStruct: optional and array fields are not required" {
    const Args = struct {
        query: []const u8,
        tags: ?[]const []const u8 = null,
        limit: i64 = 5,
    };
    const schema = comptime schemaForStruct(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{" ++
            "\"query\":{\"type\":\"string\"}," ++
            "\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}," ++
            "\"limit\":{\"type\":\"integer\",\"default\":5}}," ++
            "\"required\":[\"query\"]}",
        schema,
    );
}

test "schemaForStruct: escapes quotes and backslashes in descriptions and defaults" {
    const Args = struct {
        path: []const u8 = "C:\\tmp",
        pub const descriptions = .{ .path = "A \"quoted\" path" };
    };
    const schema = comptime schemaForStruct(Args);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\\\"quoted\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "C:\\\\tmp") != null);
    // The result must itself be valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    parsed.deinit();
}

test "schemaForStruct: nested struct becomes a nested object schema" {
    const Inner = struct { host: []const u8, port: u16 = 8080 };
    const Args = struct { name: []const u8, server: Inner };
    const schema = comptime schemaForStruct(Args);
    // server is an object with its own properties and required list.
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"server\":{\"type\":\"object\",\"properties\":{\"host\":{\"type\":\"string\"},\"port\":{\"type\":\"integer\",\"default\":8080}},\"required\":[\"host\"]}") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    parsed.deinit();
}

test "schemaForStruct: enum becomes string enum" {
    const Args = struct {
        level: enum { low, high },
    };
    const schema = comptime schemaForStruct(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{" ++
            "\"level\":{\"type\":\"string\",\"enum\":[\"low\",\"high\"]}}," ++
            "\"required\":[\"level\"]}",
        schema,
    );
}
