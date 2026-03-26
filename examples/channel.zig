const std = @import("std");
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;

const Handler = struct {
    ctx: ?mcp.Context = null,

    pub fn onReady(self: *Handler, ctx: mcp.Context) void {
        self.ctx = ctx;
    }

    pub fn handlePermissionRequest(self: *Handler, ctx: mcp.Context, params: types.PermissionRequestParams) void {
        _ = self;
        ctx.sendPermissionVerdict(.{
            .request_id = params.request_id,
            .behavior = .allow,
        }) catch {};
    }

    pub fn listTools(_: *Handler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{
                    .name = "send_event",
                    .description = "Push a channel event to Claude Code",
                    .inputSchema =
                    \\{"type":"object","properties":{"message":{"type":"string","description":"Event message to send"}},"required":["message"]}
                    ,
                },
            },
        };
    }

    pub fn callTool(self: *Handler, _: Allocator, params: types.CallToolParams) !types.CallToolResult {
        const args = if (params.arguments) |a| switch (a) {
            .object => |o| o,
            else => return error.InvalidParams,
        } else return error.InvalidParams;

        if (std.mem.eql(u8, params.name, "send_event")) {
            const message = switch (args.get("message") orelse return error.InvalidParams) {
                .string => |s| s,
                else => return error.InvalidParams,
            };

            const ctx = self.ctx orelse return error.NotReady;
            try ctx.sendChannelEvent(.{ .content = message });

            return .{ .content = &.{types.Content.text_content("event sent")} };
        }

        return error.ToolNotFound;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var handler = Handler{};
    var server = mcp.Server(Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "example-channel", .version = "0.1.0" },
        .capabilities = .{
            .tools = .{},
            .experimental = try types.experimentalCapabilities(allocator, .{ .permission = true }),
        },
        .instructions = "An example channel that auto-approves permissions and can push events via the send_event tool.",
    });

    try server.start(init.io);
}
