const std = @import("std");
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;

// Tool arguments are declared once as structs. The same struct generates the
// MCP `inputSchema` (via `types.schemaForStruct`) and parses incoming arguments
// (via `types.parseArgs`), with no hand-written JSON Schema and no manual unwrapping.
const GreetArgs = struct {
    name: []const u8,
    pub const descriptions = .{ .name = "Name to greet" };
};

const MultiGreetArgs = struct {
    name: []const u8,
    count: u32 = 3,
    pub const descriptions = .{
        .name = "Name to greet",
        .count = "Number of greetings",
    };
};

// A ToolPack turns one declaration per tool into the schema, the tools/list
// entry, name dispatch, and typed argument parsing. Handlers are plain
// functions; the args struct in their signature drives everything.
const Tools = mcp.ToolPack(.{
    .greet = .{
        .description = "Greet someone by name",
        .handler = greet,
    },
    .multi_greet = .{
        .description = "Greet someone multiple times",
        .handler = multiGreet,
    },
});

fn greet(allocator: Allocator, args: GreetArgs) !types.CallToolResult {
    const greeting = try std.fmt.allocPrint(allocator, "Hello, {s}! Welcome to the Zig MCP SDK.", .{args.name});
    return types.CallToolResult.text(allocator, greeting);
}

fn multiGreet(allocator: Allocator, args: MultiGreetArgs) !types.CallToolResult {
    if (args.count < 1 or args.count > 100) {
        return types.CallToolResult.err(allocator, "count must be between 1 and 100");
    }

    const content = try allocator.alloc(types.Content, args.count);
    for (content, 1..) |*item, i| {
        item.* = types.Content.text_content(
            try std.fmt.allocPrint(allocator, "Greeting {d}: Hello, {s}!", .{ i, args.name }),
        );
    }
    return .{ .content = content };
}

// The pack could be the Server handler by itself; embedding it instead shows
// how to combine pack-driven tools with hand-written resources and prompts.
const Handler = struct {
    tools: Tools = .{},

    pub fn listTools(self: *Handler, allocator: Allocator) !types.ListToolsResult {
        return self.tools.listTools(allocator);
    }

    pub fn callTool(self: *Handler, allocator: Allocator, ctx: mcp.Context, params: types.CallToolParams) !types.CallToolResult {
        return self.tools.callTool(allocator, ctx, params);
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
