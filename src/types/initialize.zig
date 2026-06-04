const std = @import("std");
const json = std.json;
const core = @import("core.zig");
const capabilities = @import("capabilities.zig");
const json_utils = @import("json_utils.zig");

pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: capabilities.ClientCapabilities,
    clientInfo: core.Implementation,

    pub fn fromJson(val: json.Value) error{InvalidParams}!InitializeParams {
        const obj = json_utils.asObject(val) orelse return error.InvalidParams;
        return .{
            .protocolVersion = json_utils.getString(obj, "protocolVersion") orelse return error.InvalidParams,
            .capabilities = .{
                .roots = blk: {
                    const caps = json_utils.asObject(obj.get("capabilities") orelse break :blk null) orelse break :blk null;
                    const roots = json_utils.asObject(caps.get("roots") orelse break :blk null) orelse break :blk null;
                    break :blk .{
                        .listChanged = json_utils.getBool(roots, "listChanged"),
                    };
                },
                .sampling = blk: {
                    const caps = json_utils.asObject(obj.get("capabilities") orelse break :blk null) orelse break :blk null;
                    if (caps.get("sampling") != null) break :blk .{};
                    break :blk null;
                },
            },
            .clientInfo = blk: {
                const info = json_utils.asObject(obj.get("clientInfo") orelse break :blk .{ .name = "unknown", .version = "unknown" }) orelse
                    break :blk .{ .name = "unknown", .version = "unknown" };
                break :blk .{
                    .name = json_utils.getString(info, "name") orelse "unknown",
                    .version = json_utils.getString(info, "version") orelse "unknown",
                    .title = json_utils.getString(info, "title"),
                };
            },
        };
    }
};

pub const InitializeResult = struct {
    protocolVersion: []const u8 = core.protocol_version,
    capabilities: capabilities.ServerCapabilities,
    serverInfo: core.Implementation,
    instructions: ?[]const u8 = null,
};
