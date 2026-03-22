const std = @import("std");
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;

const Handler = struct {
    pub fn listTools(_: *Handler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{
                    .name = "greet",
                    .description = "Greet someone by name",
                    .inputSchema =
                    \\{"type":"object","properties":{"name":{"type":"string","description":"Name to greet"}},"required":["name"]}
                    ,
                },
                .{
                    .name = "multi_greet",
                    .description = "Greet someone multiple times",
                    .inputSchema =
                    \\{"type":"object","properties":{"name":{"type":"string","description":"Name to greet"},"count":{"type":"integer","description":"Number of greetings","default":3}},"required":["name"]}
                    ,
                },
            },
        };
    }

    pub fn callTool(_: *Handler, allocator: Allocator, params: types.CallToolParams) !types.CallToolResult {
        const args = if (params.arguments) |a| switch (a) {
            .object => |o| o,
            else => return error.InvalidParams,
        } else return error.InvalidParams;

        if (std.mem.eql(u8, params.name, "greet")) {
            const name = switch (args.get("name") orelse return error.InvalidParams) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
            const greeting = try std.fmt.allocPrint(allocator, "Hello, {s}! Welcome to the Zig MCP SDK.", .{name});
            const content = try allocator.alloc(types.Content, 1);
            content[0] = types.Content.text_content(greeting);
            return .{ .content = content };
        }

        if (std.mem.eql(u8, params.name, "multi_greet")) {
            const name = switch (args.get("name") orelse return error.InvalidParams) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
            const count: usize = blk: {
                const val = args.get("count") orelse break :blk 3;
                break :blk switch (val) {
                    .integer => |i| if (i >= 1 and i <= 100) @intCast(i) else return error.InvalidParams,
                    else => return error.InvalidParams,
                };
            };

            const content = try allocator.alloc(types.Content, count);
            for (content, 1..) |*item, i| {
                item.* = types.Content.text_content(
                    try std.fmt.allocPrint(allocator, "Greeting {d}: Hello, {s}!", .{ i, name }),
                );
            }
            return .{ .content = content };
        }

        return error.ToolNotFound;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var handler = Handler{};
    var server = mcp.Server(Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "greeter-http", .version = "0.1.0" },
        .capabilities = .{ .tools = .{} },
        .instructions = "A friendly greeter server over HTTP.",
    });

    var transport = mcp.HttpTransport(Handler).init(allocator, &server, .{ .port = 8080 });
    try transport.listen(init.io);
}
