const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// JSON-RPC 2.0 version string.
pub const version = "2.0";

/// JSON-RPC request/response identifier.
/// Per the spec, this can be a string or integer.
/// Null IDs are represented as `?Id`.
pub const Id = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn eql(a: Id, b: Id) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| mem.eql(u8, s, b.string),
            .integer => |i| i == b.integer,
        };
    }

    /// Custom JSON serialization that writes the bare string or integer.
    /// This is used by Zig's standard JSON library.
    pub fn jsonStringify(self: Id, jw: anytype) !void {
        switch (self) {
            .string => |s| try jw.write(s),
            .integer => |i| try jw.write(i),
        }
    }

    /// Parse an Id from the generic `std.json.Value`.
    pub fn fromJsonValue(val: std.json.Value) error{InvalidId}!Id {
        return switch (val) {
            .string => |s| Id{ .string = s },
            .integer => |i| Id{ .integer = i },
            else => error.InvalidId,
        };
    }
};

/// Standard JSON-RPC 2.0 error codes.
pub const ErrorCode = enum(i32) {
    /// Invalid JSON was received by the server.
    parse_error = -32700,
    /// The JSON sent is not a valid Request object.
    invalid_request = -32600,
    /// The method does not exist / is not available.
    method_not_found = -32601,
    /// Invalid method parameter(s).
    invalid_params = -32602,
    /// Internal JSON-RPC error.
    internal_error = -32603,

    /// Returns the standard message for this error code.
    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
        };
    }

    /// Check if a code is in the reserved server error range (-32000 to -32099).
    pub fn isServerError(code: i32) bool {
        return code >= -32099 and code <= -32000;
    }

    /// Check if a code is in any reserved range (-32768 to -32000).
    pub fn isReserved(code: i32) bool {
        return code >= -32768 and code <= -32000;
    }
};

/// JSON-RPC 2.0 error object.
pub const ErrorData = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,

    pub fn fromErrorCode(code: ErrorCode, data: ?std.json.Value) ErrorData {
        return .{
            .code = @intFromEnum(code),
            .message = code.message(),
            .data = data,
        };
    }
};

/// A JSON-RPC 2.0 request (expects a response).
pub const Request = struct {
    id: Id,
    method: []const u8,
    params: ?std.json.Value = null,

    pub fn jsonStringify(self: Request, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(version);
        try jw.objectField("method");
        try jw.write(self.method);
        if (self.params) |p| {
            try jw.objectField("params");
            try jw.write(p);
        }
        try jw.objectField("id");
        try self.id.jsonStringify(jw);
        try jw.endObject();
    }
};

/// A JSON-RPC 2.0 notification (no response expected).
pub const Notification = struct {
    method: []const u8,
    params: ?std.json.Value = null,

    pub fn jsonStringify(self: Notification, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(version);
        try jw.objectField("method");
        try jw.write(self.method);
        if (self.params) |p| {
            try jw.objectField("params");
            try jw.write(p);
        }
        try jw.endObject();
    }
};

/// A successful JSON-RPC 2.0 response.
pub const Response = struct {
    id: Id,
    result: std.json.Value,

    pub fn jsonStringify(self: Response, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(version);
        try jw.objectField("result");
        try jw.write(self.result);
        try jw.objectField("id");
        try self.id.jsonStringify(jw);
        try jw.endObject();
    }
};

/// A JSON-RPC 2.0 error response.
pub const ErrorResponse = struct {
    @"error": ErrorData,
    id: ?Id = null,

    pub fn fromErrorCode(code: ErrorCode, id: ?Id, data: ?std.json.Value) ErrorResponse {
        return .{
            .@"error" = ErrorData.fromErrorCode(code, data),
            .id = id,
        };
    }

    pub fn jsonStringify(self: ErrorResponse, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(version);
        try jw.objectField("error");
        try jw.write(self.@"error");
        try jw.objectField("id");
        if (self.id) |id| {
            try id.jsonStringify(jw);
        } else {
            try jw.write(null);
        }
        try jw.endObject();
    }
};

/// A parsed JSON-RPC 2.0 message (any of the four message types).
pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
    error_response: ErrorResponse,

    pub fn jsonStringify(self: Message, jw: anytype) !void {
        switch (self) {
            inline else => |msg| try msg.jsonStringify(jw),
        }
    }
};

pub const MessageParseError = error{
    InvalidJson,
    InvalidRequest,
    InvalidId,
    InvalidVersion,
    OutOfMemory,
};

/// Parse a single JSON-RPC 2.0 message from a JSON byte string.
/// The returned `Parsed(Message)` owns all referenced memory; call `.deinit()`
/// when finished.
pub fn parseMessage(allocator: Allocator, input: []const u8) MessageParseError!std.json.Parsed(Message) {
    const arena = allocator.create(ArenaAllocator) catch return error.OutOfMemory;
    arena.* = ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        input,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidJson;

    const message = try messageFromValue(value);

    return .{
        .arena = arena,
        .value = message,
    };
}

/// Parse a message into a caller-owned arena. The caller is responsible for
/// resetting or freeing the arena; parsed data borrows from it.
pub fn parseMessageWith(arena: *ArenaAllocator, input: []const u8) MessageParseError!Message {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        input,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidJson;

    return messageFromValue(value);
}

/// Parse a JSON-RPC 2.0 batch (array of messages) from a JSON byte string.
/// Per the spec, an empty array is an invalid request.
pub fn parseBatch(allocator: Allocator, input: []const u8) MessageParseError!std.json.Parsed([]Message) {
    const arena = allocator.create(ArenaAllocator) catch return error.OutOfMemory;
    arena.* = ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        input,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidJson;

    const items = switch (value) {
        .array => |a| a.items,
        else => return error.InvalidRequest,
    };

    if (items.len == 0) return error.InvalidRequest;

    const messages = arena.allocator().alloc(Message, items.len) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        messages[i] = try messageFromValue(item);
    }

    return .{
        .arena = arena,
        .value = messages,
    };
}

/// Extract a `Message` from a parsed `std.json.Value`.
fn messageFromValue(value: std.json.Value) MessageParseError!Message {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };

    // Validate jsonrpc version field
    const jsonrpc_val = obj.get("jsonrpc") orelse return error.InvalidRequest;
    switch (jsonrpc_val) {
        .string => |s| {
            if (!mem.eql(u8, s, version)) return error.InvalidVersion;
        },
        else => return error.InvalidVersion,
    }

    const has_method = obj.get("method") != null;
    const has_result = obj.get("result") != null;
    const has_error = obj.get("error") != null;
    const has_id = obj.get("id") != null;

    if (has_method) {
        // Request or Notification
        const method = switch (obj.get("method").?) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };

        // params must be Object or Array if present (null treated as absent)
        const params: ?std.json.Value = blk: {
            const p = obj.get("params") orelse break :blk null;
            switch (p) {
                .object, .array => break :blk p,
                .null => break :blk null,
                else => return error.InvalidRequest,
            }
        };

        if (has_id) {
            const id = Id.fromJsonValue(obj.get("id").?) catch return error.InvalidId;
            return .{ .request = .{
                .id = id,
                .method = method,
                .params = params,
            } };
        } else {
            return .{ .notification = .{
                .method = method,
                .params = params,
            } };
        }
    } else if (has_result and has_id) {
        // Successful response
        const id = Id.fromJsonValue(obj.get("id").?) catch return error.InvalidId;
        return .{ .response = .{
            .id = id,
            .result = obj.get("result").?,
        } };
    } else if (has_error) {
        // Error response, id is required but may be null.
        const err_val = obj.get("error").?;
        const err_obj = switch (err_val) {
            .object => |o| o,
            else => return error.InvalidRequest,
        };

        const code_val = err_obj.get("code") orelse return error.InvalidRequest;
        const code: i32 = switch (code_val) {
            .integer => |i| std.math.cast(i32, i) orelse return error.InvalidRequest,
            else => return error.InvalidRequest,
        };

        const msg = switch (err_obj.get("message") orelse return error.InvalidRequest) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };

        if (!has_id) return error.InvalidRequest;
        const id_val = obj.get("id").?;
        const id: ?Id = switch (id_val) {
            .null => null,
            else => Id.fromJsonValue(id_val) catch return error.InvalidId,
        };

        return .{ .error_response = .{
            .@"error" = .{
                .code = code,
                .message = msg,
                .data = err_obj.get("data"),
            },
            .id = id,
        } };
    }

    return error.InvalidRequest;
}

// ============================================================================
// Response helpers for serializing typed results
// ============================================================================

const Io = std.Io;

const json_stringify_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// A JSON-RPC 2.0 response with a comptime-known result type.
/// Use for serializing typed results without converting to `std.json.Value`.
pub fn GenericResponse(comptime Result: type) type {
    return struct {
        result: Result,
        id: Id,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("jsonrpc");
            try jw.write(version);
            try jw.objectField("result");
            try jw.write(self.result);
            try jw.objectField("id");
            try self.id.jsonStringify(jw);
            try jw.endObject();
        }
    };
}

/// An empty JSON object result, used for responses like "ping".
pub const EmptyResult = struct {
    pub fn jsonStringify(_: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.endObject();
    }
};

/// A JSON-RPC 2.0 notification with a comptime-known params type.
/// Use for serializing typed notifications without converting to `std.json.Value`.
pub fn GenericNotification(comptime Params: type) type {
    return struct {
        method: []const u8,
        params: Params,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("jsonrpc");
            try jw.write(version);
            try jw.objectField("method");
            try jw.write(self.method);
            try jw.objectField("params");
            try jw.write(self.params);
            try jw.endObject();
        }
    };
}

// ============================================================================
// Serialization helpers produce JSON-RPC response bytes.
// ============================================================================

/// Serialize a JSON-RPC success response to bytes. Caller owns returned memory.
pub fn serializeResult(allocator: Allocator, id: Id, result: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, GenericResponse(@TypeOf(result)){
        .result = result,
        .id = id,
    }, json_stringify_options);
}

/// Serialize a JSON-RPC notification to bytes. Caller owns returned memory.
pub fn serializeNotification(allocator: Allocator, method: []const u8, params: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, GenericNotification(@TypeOf(params)){
        .method = method,
        .params = params,
    }, json_stringify_options);
}

/// Serialize a JSON-RPC error response to bytes. Caller owns returned memory.
pub fn serializeError(allocator: Allocator, id: ?Id, code: ErrorCode, data: ?[]const u8) ![]const u8 {
    const err_resp = ErrorResponse.fromErrorCode(code, id, if (data) |d| .{ .string = d } else null);
    return std.json.Stringify.valueAlloc(allocator, err_resp, json_stringify_options);
}

// ============================================================================
// Transport helpers stream JSON-RPC messages directly to an Io.Writer.
// ============================================================================

/// Write a JSON-RPC success response and flush.
pub fn sendResult(id: Id, result: anytype, writer: *Io.Writer) !void {
    try std.json.Stringify.value(GenericResponse(@TypeOf(result)){
        .result = result,
        .id = id,
    }, json_stringify_options, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Write a JSON-RPC success response with an empty object result.
pub fn sendEmptyResult(id: Id, writer: *Io.Writer) !void {
    return sendResult(id, EmptyResult{}, writer);
}

/// Write a JSON-RPC notification and flush.
pub fn sendNotification(method: []const u8, params: anytype, writer: *Io.Writer) !void {
    try std.json.Stringify.value(GenericNotification(@TypeOf(params)){
        .method = method,
        .params = params,
    }, json_stringify_options, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Write a JSON-RPC error response and flush.
pub fn sendError(id: ?Id, code: ErrorCode, data: ?[]const u8, writer: *Io.Writer) !void {
    const err_resp = ErrorResponse.fromErrorCode(code, id, if (data) |d| .{ .string = d } else null);
    try std.json.Stringify.value(err_resp, json_stringify_options, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Read a single newline-delimited message.
pub fn readLine(reader: *Io.Reader) ![]const u8 {
    return (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
}

// ============================================================================
// Tests
// ============================================================================

test "Id.eql, same type and value" {
    const a = Id{ .integer = 42 };
    const b = Id{ .integer = 42 };
    try testing.expect(a.eql(b));

    const c = Id{ .string = "abc" };
    const d = Id{ .string = "abc" };
    try testing.expect(c.eql(d));
}

test "Id.eql, different value or type" {
    const a = Id{ .integer = 1 };
    const b = Id{ .integer = 2 };
    try testing.expect(!a.eql(b));

    const c = Id{ .integer = 1 };
    const d = Id{ .string = "1" };
    try testing.expect(!c.eql(d));
}

test "ErrorCode messages" {
    try testing.expectEqualStrings("Parse error", ErrorCode.parse_error.message());
    try testing.expectEqualStrings("Invalid Request", ErrorCode.invalid_request.message());
    try testing.expectEqualStrings("Method not found", ErrorCode.method_not_found.message());
    try testing.expectEqualStrings("Invalid params", ErrorCode.invalid_params.message());
    try testing.expectEqualStrings("Internal error", ErrorCode.internal_error.message());
}

test "ErrorCode.isServerError" {
    try testing.expect(ErrorCode.isServerError(-32000));
    try testing.expect(ErrorCode.isServerError(-32050));
    try testing.expect(ErrorCode.isServerError(-32099));
    try testing.expect(!ErrorCode.isServerError(-32100));
    try testing.expect(!ErrorCode.isServerError(-31999));
    try testing.expect(!ErrorCode.isServerError(0));
}

test "ErrorCode.isReserved" {
    try testing.expect(ErrorCode.isReserved(-32700));
    try testing.expect(ErrorCode.isReserved(-32000));
    try testing.expect(ErrorCode.isReserved(-32768));
    try testing.expect(!ErrorCode.isReserved(-31999));
    try testing.expect(!ErrorCode.isReserved(-32769));
}

test "parse request with integer id" {
    const input =
        \\{"jsonrpc":"2.0","method":"subtract","params":{"a":1,"b":2},"id":1}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const req = parsed.value.request;
    try testing.expect(req.id.eql(Id{ .integer = 1 }));
    try testing.expectEqualStrings("subtract", req.method);
    try testing.expect(req.params != null);
}

test "parse request with string id" {
    const input =
        \\{"jsonrpc":"2.0","method":"hello","id":"req-1"}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const req = parsed.value.request;
    try testing.expect(req.id.eql(Id{ .string = "req-1" }));
    try testing.expectEqualStrings("hello", req.method);
    try testing.expect(req.params == null);
}

test "parse request with array params" {
    const input =
        \\{"jsonrpc":"2.0","method":"add","params":[1,2,3],"id":10}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const req = parsed.value.request;
    try testing.expect(req.params.? == .array);
}

test "parse notification, no id" {
    const input =
        \\{"jsonrpc":"2.0","method":"update","params":{"key":"value"}}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const notif = parsed.value.notification;
    try testing.expectEqualStrings("update", notif.method);
    try testing.expect(notif.params != null);
}

test "parse notification without params" {
    const input =
        \\{"jsonrpc":"2.0","method":"ping"}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const notif = parsed.value.notification;
    try testing.expectEqualStrings("ping", notif.method);
    try testing.expect(notif.params == null);
}

test "parse successful response" {
    const input =
        \\{"jsonrpc":"2.0","result":42,"id":1}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const resp = parsed.value.response;
    try testing.expect(resp.id.eql(Id{ .integer = 1 }));
    try testing.expect(resp.result == .integer);
    try testing.expectEqual(@as(i64, 42), resp.result.integer);
}

test "parse error response with id" {
    const input =
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const err = parsed.value.error_response;
    try testing.expectEqual(@as(i32, -32601), err.@"error".code);
    try testing.expectEqualStrings("Method not found", err.@"error".message);
    try testing.expect(err.@"error".data == null);
    try testing.expect(err.id != null);
    try testing.expect(err.id.?.eql(Id{ .integer = 1 }));
}

test "parse error response with null id" {
    const input =
        \\{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"},"id":null}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const err = parsed.value.error_response;
    try testing.expectEqual(@as(i32, -32700), err.@"error".code);
    try testing.expect(err.id == null);
}

test "parse error response with data" {
    const input =
        \\{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error","data":"details"},"id":5}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    const err = parsed.value.error_response;
    try testing.expect(err.@"error".data != null);
    try testing.expectEqualStrings("details", err.@"error".data.?.string);
}

test "reject invalid JSON" {
    try testing.expectError(error.InvalidJson, parseMessage(testing.allocator, "not json"));
}

test "reject missing jsonrpc field" {
    const input =
        \\{"method":"test","id":1}
    ;
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, input));
}

test "reject wrong jsonrpc version" {
    const input =
        \\{"jsonrpc":"1.0","method":"test","id":1}
    ;
    try testing.expectError(error.InvalidVersion, parseMessage(testing.allocator, input));
}

test "reject non-string method" {
    const input =
        \\{"jsonrpc":"2.0","method":123,"id":1}
    ;
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, input));
}

test "reject invalid id type" {
    const input =
        \\{"jsonrpc":"2.0","method":"test","id":true}
    ;
    try testing.expectError(error.InvalidId, parseMessage(testing.allocator, input));
}

test "reject invalid params type" {
    const input =
        \\{"jsonrpc":"2.0","method":"test","params":"not-structured","id":1}
    ;
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, input));
}

test "reject non-object top level" {
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "[]"));
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "\"hello\""));
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "42"));
}

test "reject error response without id field" {
    const input =
        \\{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}
    ;
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, input));
}

test "parse batch" {
    const input =
        \\[
        \\  {"jsonrpc":"2.0","method":"add","params":[1,2],"id":1},
        \\  {"jsonrpc":"2.0","method":"notify"},
        \\  {"jsonrpc":"2.0","result":7,"id":2}
        \\]
    ;
    const parsed = try parseBatch(testing.allocator, input);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 3), parsed.value.len);
    try testing.expect(parsed.value[0] == .request);
    try testing.expect(parsed.value[1] == .notification);
    try testing.expect(parsed.value[2] == .response);
}

test "reject empty batch" {
    try testing.expectError(error.InvalidRequest, parseBatch(testing.allocator, "[]"));
}

test "reject non-array batch" {
    const input =
        \\{"jsonrpc":"2.0","method":"test","id":1}
    ;
    try testing.expectError(error.InvalidRequest, parseBatch(testing.allocator, input));
}

test "serialize request with params" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"a":1}
    , .{});

    const req = Request{
        .id = .{ .integer = 1 },
        .method = "subtract",
        .params = params,
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    // Verify roundtrip by parsing it back
    const parsed = try parseMessage(testing.allocator, json);
    defer parsed.deinit();

    const r = parsed.value.request;
    try testing.expect(r.id.eql(Id{ .integer = 1 }));
    try testing.expectEqualStrings("subtract", r.method);
    try testing.expect(r.params != null);
}

test "serialize request without params" {
    const req = Request{
        .id = .{ .string = "abc" },
        .method = "ping",
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    // params should be omitted, not null
    try testing.expect(mem.indexOf(u8, json, "params") == null);

    const parsed = try parseMessage(testing.allocator, json);
    defer parsed.deinit();
    try testing.expect(parsed.value.request.params == null);
}

test "serialize notification" {
    const notif = Notification{
        .method = "update",
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, notif, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    const parsed = try parseMessage(testing.allocator, json);
    defer parsed.deinit();
    try testing.expect(parsed.value == .notification);
    try testing.expectEqualStrings("update", parsed.value.notification.method);
}

test "serialize response" {
    const resp = Response{
        .id = .{ .integer = 1 },
        .result = .{ .integer = 42 },
    };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, resp, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    const parsed = try parseMessage(testing.allocator, json);
    defer parsed.deinit();
    try testing.expect(parsed.value == .response);
    try testing.expectEqual(@as(i64, 42), parsed.value.response.result.integer);
}

test "serialize error response" {
    const err_resp = ErrorResponse.fromErrorCode(.method_not_found, .{ .integer = 5 }, null);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, err_resp, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    const parsed = try parseMessage(testing.allocator, json);
    defer parsed.deinit();
    const err = parsed.value.error_response;
    try testing.expectEqual(@as(i32, -32601), err.@"error".code);
    try testing.expectEqualStrings("Method not found", err.@"error".message);
    try testing.expect(err.id.?.eql(Id{ .integer = 5 }));
}

test "serialize error response with null id" {
    const err_resp = ErrorResponse.fromErrorCode(.parse_error, null, null);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, err_resp, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    const parsed = try parseMessage(testing.allocator, json);
    defer parsed.deinit();
    try testing.expect(parsed.value.error_response.id == null);
}

test "serialize Message union" {
    const msg = Message{ .notification = .{ .method = "test" } };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, msg, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(json);

    const parsed = try parseMessage(testing.allocator, json);
    defer parsed.deinit();
    try testing.expect(parsed.value == .notification);
}

test "ErrorData.fromErrorCode" {
    const err = ErrorData.fromErrorCode(.internal_error, null);
    try testing.expectEqual(@as(i32, -32603), err.code);
    try testing.expectEqualStrings("Internal error", err.message);
    try testing.expect(err.data == null);
}

test "ErrorResponse.fromErrorCode" {
    const resp = ErrorResponse.fromErrorCode(.parse_error, null, null);
    try testing.expectEqual(@as(i32, -32700), resp.@"error".code);
    try testing.expectEqualStrings("Parse error", resp.@"error".message);
    try testing.expect(resp.id == null);
}

test "params with null value treated as absent" {
    const input =
        \\{"jsonrpc":"2.0","method":"test","params":null,"id":1}
    ;
    const parsed = try parseMessage(testing.allocator, input);
    defer parsed.deinit();

    try testing.expect(parsed.value.request.params == null);
}

test "serializeNotification roundtrip" {
    const TestParams = struct { content: []const u8 };
    const bytes = try serializeNotification(
        testing.allocator,
        "notifications/test",
        TestParams{ .content = "hello" },
    );
    defer testing.allocator.free(bytes);

    const parsed = try parseMessage(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expect(parsed.value == .notification);
    try testing.expectEqualStrings("notifications/test", parsed.value.notification.method);
    try testing.expect(parsed.value.notification.params != null);
}
