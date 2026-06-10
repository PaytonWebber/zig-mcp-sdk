const std = @import("std");
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;

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

const Handler = struct {
    pub fn listTools(_: *Handler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{
                    .name = "greet",
                    .description = "Greet someone by name",
                    .inputSchema = comptime types.schemaForStruct(GreetArgs),
                },
                .{
                    .name = "multi_greet",
                    .description = "Greet someone multiple times",
                    .inputSchema = comptime types.schemaForStruct(MultiGreetArgs),
                },
            },
        };
    }

    // The 4-arg form receives a per-call Context: notifications sent during
    // the call stream back on the POST's SSE response (when the client
    // accepts text/event-stream). Valid only for the duration of the call.
    pub fn callTool(_: *Handler, allocator: Allocator, ctx: mcp.Context, params: types.CallToolParams) !types.CallToolResult {
        if (std.mem.eql(u8, params.name, "greet")) {
            const args = try types.parseArgs(GreetArgs, allocator, params.arguments);
            const greeting = try std.fmt.allocPrint(allocator, "Hello, {s}! Welcome to the Zig MCP SDK.", .{args.name});
            return types.CallToolResult.text(allocator, greeting);
        }

        if (std.mem.eql(u8, params.name, "multi_greet")) {
            const args = try types.parseArgs(MultiGreetArgs, allocator, params.arguments);
            if (args.count < 1 or args.count > 100) {
                return types.CallToolResult.err(allocator, "count must be between 1 and 100");
            }

            const content = try allocator.alloc(types.Content, args.count);
            for (content, 1..) |*item, i| {
                item.* = types.Content.text_content(
                    try std.fmt.allocPrint(allocator, "Greeting {d}: Hello, {s}!", .{ i, args.name }),
                );
                if (params.progressToken()) |token| {
                    ctx.sendProgress(.{
                        .progressToken = token,
                        .progress = @floatFromInt(i),
                        .total = @floatFromInt(args.count),
                    }) catch {};
                }
            }
            return .{ .content = content };
        }

        return error.ToolNotFound;
    }

    // Called per session once the client sends notifications/initialized.
    // The context delivers notifications on the session's SSE stream (opened
    // by the client with GET + Accept: text/event-stream).
    pub fn onReady(_: *Handler, ctx: mcp.Context) void {
        ctx.sendLogMessage(.{
            .level = .info,
            .logger = "greeter-http",
            .data = .{ .string = "session ready" },
        }) catch {}; // no SSE stream open yet is fine
    }
};

pub fn main(init: std.process.Init) !void {
    // The HTTP transport handles connections concurrently, so the allocator
    // must be thread-safe (init.arena is not).
    const allocator = std.heap.smp_allocator;

    var handler = Handler{};
    var server = mcp.Server(Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "greeter-http", .version = "0.1.0" },
        .capabilities = .{ .tools = .{}, .logging = .{} },
        .instructions = "A friendly greeter server over HTTP.",
    });

    var transport = mcp.HttpTransport(Handler).init(allocator, &server, .{ .port = 8080 });
    defer transport.deinit();
    try transport.listen(init.io);
}
