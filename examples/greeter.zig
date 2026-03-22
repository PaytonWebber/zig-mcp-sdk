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

    pub fn listResources(_: *Handler, _: Allocator) !types.ListResourcesResult {
        return .{
            .resources = &.{
                .{
                    .uri = "greeting://instructions",
                    .name = "Greeting Instructions",
                    .description = "How to use the greeter server",
                    .mimeType = "text/plain",
                },
            },
        };
    }

    pub fn readResource(_: *Handler, _: Allocator, params: types.ReadResourceParams) !types.ReadResourceResult {
        if (std.mem.eql(u8, params.uri, "greeting://instructions")) {
            return .{
                .contents = &.{.{ .text = .{
                    .uri = "greeting://instructions",
                    .mimeType = "text/plain",
                    .text =
                    \\Welcome to the Greeter MCP Server!
                    \\
                    \\Available tools:
                    \\  - greet: Say hello to someone (pass a "name" argument)
                    \\  - multi_greet: Say hello multiple times (pass "name" and optional "count")
                    \\
                    \\Available prompts:
                    \\  - greeting_template: Generate a greeting message for a given name
                    ,
                } }},
            };
        }
        return error.ResourceNotFound;
    }

    pub fn listPrompts(_: *Handler, _: Allocator) !types.ListPromptsResult {
        return .{
            .prompts = &.{
                .{
                    .name = "greeting_template",
                    .description = "Generate a friendly greeting message",
                    .arguments = &.{
                        .{ .name = "name", .description = "Name of the person to greet", .required = true },
                    },
                },
            },
        };
    }

    pub fn getPrompt(_: *Handler, allocator: Allocator, params: types.GetPromptParams) !types.GetPromptResult {
        if (std.mem.eql(u8, params.name, "greeting_template")) {
            const args = if (params.arguments) |a| switch (a) {
                .object => |o| o,
                else => return error.InvalidParams,
            } else return error.InvalidParams;

            const name = switch (args.get("name") orelse return error.InvalidParams) {
                .string => |s| s,
                else => return error.InvalidParams,
            };

            const text = try std.fmt.allocPrint(
                allocator,
                "Please greet {s} warmly and make them feel welcome.",
                .{name},
            );
            const messages = try allocator.alloc(types.PromptMessage, 1);
            messages[0] = .{
                .role = .user,
                .content = types.Content.text_content(text),
            };

            return .{
                .description = "A greeting prompt",
                .messages = messages,
            };
        }
        return error.PromptNotFound;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var handler = Handler{};
    var server = mcp.Server(Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "greeter", .version = "0.1.0" },
        .capabilities = .{
            .tools = .{},
            .resources = .{},
            .prompts = .{},
        },
        .instructions = "A friendly greeter server demonstrating the Zig MCP SDK.",
    });

    try server.start(init.io);
}
