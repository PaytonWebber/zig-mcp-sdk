const std = @import("std");

pub const Error = struct {
    code: i16,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const Request = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?std.json.Value = null,
};

pub const Response = struct {
    jsonrpc: []const u8,
    member: ?std.json.Value = null,
    err: Error,
    id: ?std.json.Value,
};
