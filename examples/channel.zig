/// Simplified Claude Peers: peer discovery and messaging via the channel protocol.
///
/// A self-contained implementation of the claude-peers pattern
/// (github.com/louislva/claude-peers-mcp) demonstrating:
///   - Channel + permission experimental capabilities
///   - onReady lifecycle for context storage
///   - Permission auto-approve
///   - Channel events with structured metadata for message delivery
///   - Peer-style tools: list_peers, send_message, set_summary, check_messages
///
/// Messages are stored in-process; a production implementation would use a
/// broker or filesystem for cross-instance coordination.
const std = @import("std");
const json = std.json;
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const Allocator = std.mem.Allocator;

const Handler = struct {
    allocator: Allocator,
    ctx: ?mcp.Context = null,
    summary: []const u8 = "No summary set",
    inbox: std.ArrayList(Message) = .empty,

    const Message = struct {
        from_id: []const u8,
        text: []const u8,
    };

    pub fn onReady(self: *Handler, ctx: mcp.Context) void {
        self.ctx = ctx;
        ctx.sendChannelEvent(.{ .content = "Channel server ready. Call set_summary to introduce yourself." }) catch {};
    }

    pub fn handlePermissionRequest(_: *Handler, ctx: mcp.Context, params: types.PermissionRequestParams) void {
        ctx.sendPermissionVerdict(.{
            .request_id = params.request_id,
            .behavior = .allow,
        }) catch {};
    }

    pub fn listTools(_: *Handler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{
                    .name = "list_peers",
                    .description = "Discover other Claude Code instances",
                    .inputSchema =
                    \\{"type":"object","properties":{"scope":{"type":"string","enum":["machine","directory","repo"],"description":"Filter scope"}},"required":["scope"]}
                    ,
                },
                .{
                    .name = "send_message",
                    .description = "Send a message to a peer by ID",
                    .inputSchema =
                    \\{"type":"object","properties":{"to_id":{"type":"string","description":"Target peer ID"},"message":{"type":"string","description":"Message text"}},"required":["to_id","message"]}
                    ,
                },
                .{
                    .name = "set_summary",
                    .description = "Advertise what you are working on (1-2 sentences)",
                    .inputSchema =
                    \\{"type":"object","properties":{"summary":{"type":"string","description":"Work summary"}},"required":["summary"]}
                    ,
                },
                .{
                    .name = "check_messages",
                    .description = "Poll for new messages and deliver them as channel events",
                    .inputSchema =
                    \\{"type":"object","properties":{}}
                    ,
                },
                .{
                    .name = "simulate_events",
                    .description = "Push a burst of simulated webhook events through the channel",
                    .inputSchema =
                    \\{"type":"object","properties":{"count":{"type":"integer","description":"Number of events to send (1-10)","default":3}},"required":[]}
                    ,
                },
            },
        };
    }

    pub fn callTool(self: *Handler, allocator: Allocator, params: types.CallToolParams) !types.CallToolResult {
        if (std.mem.eql(u8, params.name, "check_messages"))
            return self.checkMessages(allocator);
        if (std.mem.eql(u8, params.name, "simulate_events"))
            return self.simulateEvents(allocator, params.arguments);

        const args = if (params.arguments) |a| switch (a) {
            .object => |o| o,
            else => return error.InvalidParams,
        } else return error.InvalidParams;

        if (std.mem.eql(u8, params.name, "list_peers"))
            return self.listPeers(allocator);
        if (std.mem.eql(u8, params.name, "send_message"))
            return self.sendMessage(allocator, args);
        if (std.mem.eql(u8, params.name, "set_summary"))
            return self.setSummary(allocator, args);

        return error.ToolNotFound;
    }

    fn listPeers(self: *Handler, allocator: Allocator) !types.CallToolResult {
        var peers = json.Array.init(allocator);
        var peer: json.ObjectMap = .empty;
        try peer.put(allocator, "id", .{ .string = "self" });
        try peer.put(allocator, "summary", .{ .string = self.summary });
        try peer.put(allocator, "status", .{ .string = "active" });
        try peers.append(.{ .object = peer });

        const result = try json.Stringify.valueAlloc(
            allocator,
            json.Value{ .array = peers },
            .{},
        );
        const content = try allocator.alloc(types.Content, 1);
        content[0] = types.Content.text_content(result);
        return .{ .content = content };
    }

    fn sendMessage(self: *Handler, allocator: Allocator, args: json.ObjectMap) !types.CallToolResult {
        const to_id = getString(args, "to_id") orelse return error.InvalidParams;
        const message = getString(args, "message") orelse return error.InvalidParams;

        try self.inbox.append(self.allocator, .{
            .from_id = try self.allocator.dupe(u8, to_id),
            .text = try self.allocator.dupe(u8, message),
        });

        return textResult(allocator, "Message queued for delivery");
    }

    fn setSummary(self: *Handler, allocator: Allocator, args: json.ObjectMap) !types.CallToolResult {
        const summary = getString(args, "summary") orelse return error.InvalidParams;
        self.summary = try self.allocator.dupe(u8, summary);
        return textResult(allocator, "Summary updated");
    }

    const sim_sources = [_][]const u8{ "github", "slack", "linear", "discord", "email" };
    const sim_events = [_][]const u8{
        "PR #42 opened: refactor auth middleware",
        "Message from alice: can you review my PR?",
        "Issue ENG-123 moved to In Progress",
        "bob mentioned you in #engineering",
        "Deploy notification: staging v2.1.0 is live",
    };

    fn simulateEvents(self: *Handler, allocator: Allocator, arguments: ?json.Value) !types.CallToolResult {
        const ctx = self.ctx orelse return error.NotReady;
        const count: usize = blk: {
            const args = if (arguments) |a| switch (a) {
                .object => |o| o,
                else => break :blk 3,
            } else break :blk 3;
            const val = args.get("count") orelse break :blk 3;
            break :blk switch (val) {
                .integer => |i| if (i >= 1 and i <= 10) @intCast(i) else 3,
                else => 3,
            };
        };

        for (0..count) |i| {
            var meta: json.ObjectMap = .empty;
            try meta.put(allocator, "source", .{ .string = sim_sources[i % sim_sources.len] });
            try meta.put(allocator, "event_type", .{ .string = "webhook" });

            ctx.sendChannelEvent(.{
                .content = sim_events[i % sim_events.len],
                .meta = .{ .object = meta },
            }) catch continue;
        }

        const msg = try std.fmt.allocPrint(allocator, "Pushed {d} simulated event(s)", .{count});
        const content = try allocator.alloc(types.Content, 1);
        content[0] = types.Content.text_content(msg);
        return .{ .content = content };
    }

    fn checkMessages(self: *Handler, allocator: Allocator) !types.CallToolResult {
        const ctx = self.ctx orelse return error.NotReady;

        var count: usize = 0;
        while (self.inbox.items.len > 0) {
            const msg = self.inbox.orderedRemove(0);

            var meta: json.ObjectMap = .empty;
            try meta.put(allocator, "from_id", .{ .string = msg.from_id });

            ctx.sendChannelEvent(.{
                .content = msg.text,
                .meta = .{ .object = meta },
            }) catch continue;
            count += 1;
        }

        if (count == 0) return textResult(allocator, "No new messages");

        const result_msg = try std.fmt.allocPrint(allocator, "{d} message(s) delivered", .{count});
        const content = try allocator.alloc(types.Content, 1);
        content[0] = types.Content.text_content(result_msg);
        return .{ .content = content };
    }
};

fn textResult(allocator: Allocator, text: []const u8) !types.CallToolResult {
    const content = try allocator.alloc(types.Content, 1);
    content[0] = types.Content.text_content(text);
    return .{ .content = content };
}

fn getString(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var handler = Handler{ .allocator = allocator };
    var server = mcp.Server(Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "claude-peers", .version = "0.1.0" },
        .capabilities = .{
            .tools = .{},
            .experimental = try types.experimentalCapabilities(allocator, .{ .permission = true }),
        },
        .instructions =
        \\You are connected to the Claude Peers network.
        \\
        \\On startup, call set_summary to advertise what you're working on.
        \\Periodically call check_messages to receive messages from peers.
        \\When you receive a peer message, respond IMMEDIATELY.
        ,
    });

    try server.start(init.io);
}
