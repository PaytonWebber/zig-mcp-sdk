//! Comptime tool registry: one declaration per tool drives the schema, the
//! `tools/list` entry, name dispatch, and typed argument parsing.
//!
//!     const Tools = mcp.ToolPack(.{
//!         .greet = .{
//!             .args = GreetArgs,
//!             .description = "Greet someone by name",
//!             .handler = greet,
//!         },
//!     });
//!
//! The returned type implements `listTools` and `callTool`, so it can be used
//! directly as a `Server` handler, embedded in a larger handler that also
//! serves resources or prompts, or composed with packs exported by other
//! libraries: `mcp.ToolPack(.{ lib_a.tool_defs, my_defs })`.
//!
//! Tool handlers take one of two forms (detected at comptime):
//!
//!     fn (Allocator, Args) !types.CallToolResult
//!     fn (Allocator, ToolContext, Args) !types.CallToolResult
//!
//! `Args` is any struct: its fields drive both the generated JSON schema and
//! the typed parsing of incoming arguments (see `types.schemaForStruct`). It
//! is read from the handler's signature; a def may name it explicitly with
//! `.args` for documentation. The `ToolContext` form is for tools that report
//! progress or send notifications during the call.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("types.zig");
const server_mod = @import("server.zig");

/// Per-call helper passed to `ToolContext`-form handlers. Wraps the
/// notification context and the raw call params. Valid only for the duration
/// of the call.
pub const ToolContext = struct {
    context: server_mod.Context,
    params: types.CallToolParams,

    pub fn progressToken(self: ToolContext) ?types.TokenValue {
        return self.params.progressToken();
    }

    /// Report progress for this call. A no-op when the client did not send a
    /// progress token, so handlers can call it unconditionally.
    pub fn sendProgress(self: ToolContext, progress: f64, total: ?f64) !void {
        const token = self.progressToken() orelse return;
        try self.context.sendProgress(.{
            .progressToken = token,
            .progress = progress,
            .total = total,
        });
    }

    pub fn sendLogMessage(self: ToolContext, params: types.LogMessageParams) !void {
        try self.context.sendLogMessage(params);
    }

    pub fn sendNotification(self: ToolContext, method: []const u8, params: anytype) !void {
        try self.context.sendNotification(method, params);
    }
};

/// Build a handler type from tool definitions. `defs` is either a struct
/// literal whose field names are tool names, or a tuple of such structs to
/// compose multiple packs. Each definition supports:
///
///   .handler     (required) tool function, see module docs for forms
///   .description (required) what the model reads to decide when to call it
///   .args        (optional) struct type driving schema + parsing; when
///                omitted it is derived from the handler's final parameter
///   .annotations (optional) types.ToolAnnotations
pub fn ToolPack(comptime defs: anytype) type {
    const groups = if (@typeInfo(@TypeOf(defs)).@"struct".is_tuple) defs else .{defs};
    const tools_list = comptime buildToolsList(groups);

    return struct {
        const Self = @This();

        pub fn listTools(_: *Self, _: Allocator) !types.ListToolsResult {
            return .{ .tools = tools_list };
        }

        pub fn callTool(_: *Self, allocator: Allocator, ctx: server_mod.Context, params: types.CallToolParams) !types.CallToolResult {
            inline for (@typeInfo(@TypeOf(groups)).@"struct".fields) |group_field| {
                const group = @field(groups, group_field.name);
                inline for (@typeInfo(@TypeOf(group)).@"struct".fields) |tool_field| {
                    if (mem.eql(u8, params.name, tool_field.name)) {
                        const def = comptime @field(group, tool_field.name);
                        const Args = ArgsOf(def);

                        const args = types.parseArgs(Args, allocator, params.arguments) catch {
                            return types.CallToolResult.err(
                                allocator,
                                "invalid arguments for tool '" ++ tool_field.name ++ "'",
                            );
                        };

                        const handler_params = @typeInfo(@TypeOf(def.handler)).@"fn".params;
                        if (comptime handler_params.len == 3) {
                            const tool_ctx = ToolContext{ .context = ctx, .params = params };
                            return try def.handler(allocator, tool_ctx, args);
                        }
                        return try def.handler(allocator, args);
                    }
                }
            }

            const msg = try std.fmt.allocPrint(allocator, "unknown tool: {s}", .{params.name});
            return types.CallToolResult.err(allocator, msg);
        }
    };
}

/// The tool's argument struct: the def's explicit `.args` if given, otherwise
/// derived from the handler's final parameter, so a plain
/// `fn (Allocator, GreetArgs) !CallToolResult` is a complete tool definition.
fn ArgsOf(comptime def: anytype) type {
    if (@hasField(@TypeOf(def), "args")) return def.args;
    const params = @typeInfo(@TypeOf(def.handler)).@"fn".params;
    return params[params.len - 1].type.?;
}

/// Convert a def's `.annotations` to `types.ToolAnnotations`. Accepts both
/// the proper type and an anonymous literal (which no longer coerces once it
/// is stored as a field of the defs struct).
fn annotationsOf(comptime def: anytype) ?types.ToolAnnotations {
    if (!@hasField(@TypeOf(def), "annotations")) return null;
    const given = def.annotations;
    if (@TypeOf(given) == types.ToolAnnotations) return given;
    var result = types.ToolAnnotations{};
    for (@typeInfo(@TypeOf(given)).@"struct".fields) |field| {
        @field(result, field.name) = @field(given, field.name);
    }
    return result;
}

fn validateDef(comptime name: []const u8, comptime def: anytype) void {
    if (!@hasField(@TypeOf(def), "handler")) {
        @compileError("ToolPack: tool '" ++ name ++ "' is missing .handler");
    }
    if (!@hasField(@TypeOf(def), "description")) {
        @compileError("ToolPack: tool '" ++ name ++ "' is missing .description");
    }
}

/// Comptime construction of the `tools/list` array shared by both pack
/// flavors. The args struct is the handler's final parameter in all forms.
fn buildToolsList(comptime groups: anytype) []const types.Tool {
    var list: []const types.Tool = &.{};
    for (@typeInfo(@TypeOf(groups)).@"struct".fields) |group_field| {
        const group = @field(groups, group_field.name);
        for (@typeInfo(@TypeOf(group)).@"struct".fields) |tool_field| {
            const def = @field(group, tool_field.name);
            validateDef(tool_field.name, def);
            for (list) |existing| {
                if (mem.eql(u8, existing.name, tool_field.name)) {
                    @compileError("ToolPack: duplicate tool name '" ++ tool_field.name ++ "'");
                }
            }
            list = list ++ &[_]types.Tool{.{
                .name = tool_field.name,
                .description = def.description,
                .inputSchema = types.schemaForStruct(ArgsOf(def)),
                .annotations = annotationsOf(def),
            }};
        }
    }
    return list;
}

/// Like `ToolPack`, but for tools that share mutable state (a database
/// handle, a daemon client, configuration). The generated struct holds a
/// `state: *State` field and passes it as the handlers' first parameter:
///
///     fn (*State, Allocator, Args) !types.CallToolResult
///     fn (*State, Allocator, ToolContext, Args) !types.CallToolResult
///
/// Usage:
///
///     const Tools = mcp.StatefulToolPack(Bridge, .{
///         .record = .{ .description = "...", .handler = Bridge.record },
///     });
///     var tools = Tools{ .state = &bridge };
///     var server = mcp.Server(Tools).init(allocator, &tools, .{ ... });
pub fn StatefulToolPack(comptime State: type, comptime defs: anytype) type {
    const groups = if (@typeInfo(@TypeOf(defs)).@"struct".is_tuple) defs else .{defs};
    const tools_list = comptime buildToolsList(groups);

    return struct {
        const Self = @This();

        state: *State,

        pub fn listTools(_: *Self, _: Allocator) !types.ListToolsResult {
            return .{ .tools = tools_list };
        }

        pub fn callTool(self: *Self, allocator: Allocator, ctx: server_mod.Context, params: types.CallToolParams) !types.CallToolResult {
            inline for (@typeInfo(@TypeOf(groups)).@"struct".fields) |group_field| {
                const group = @field(groups, group_field.name);
                inline for (@typeInfo(@TypeOf(group)).@"struct".fields) |tool_field| {
                    if (mem.eql(u8, params.name, tool_field.name)) {
                        const def = comptime @field(group, tool_field.name);
                        const Args = ArgsOf(def);

                        const args = types.parseArgs(Args, allocator, params.arguments) catch {
                            return types.CallToolResult.err(
                                allocator,
                                "invalid arguments for tool '" ++ tool_field.name ++ "'",
                            );
                        };

                        const handler_params = @typeInfo(@TypeOf(def.handler)).@"fn".params;
                        if (comptime handler_params.len == 4) {
                            const tool_ctx = ToolContext{ .context = ctx, .params = params };
                            return try def.handler(self.state, allocator, tool_ctx, args);
                        }
                        return try def.handler(self.state, allocator, args);
                    }
                }
            }

            const msg = try std.fmt.allocPrint(allocator, "unknown tool: {s}", .{params.name});
            return types.CallToolResult.err(allocator, msg);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Io = std.Io;

const EchoArgs = struct {
    text: []const u8,
    repeat: u32 = 1,
    pub const descriptions = .{ .text = "Text to echo" };
};

fn echo(allocator: Allocator, args: EchoArgs) !types.CallToolResult {
    var out: std.ArrayList(u8) = .empty;
    for (0..args.repeat) |_| try out.appendSlice(allocator, args.text);
    return types.CallToolResult.text(allocator, out.items);
}

fn version(allocator: Allocator, _: struct {}) !types.CallToolResult {
    return types.CallToolResult.text(allocator, "1.0");
}

fn slowEcho(allocator: Allocator, tc: ToolContext, args: EchoArgs) !types.CallToolResult {
    try tc.sendProgress(1.0, 1.0);
    return types.CallToolResult.text(allocator, args.text);
}

const TestPack = ToolPack(.{
    .echo = .{
        .args = EchoArgs,
        .description = "Echo text",
        .handler = echo,
        .annotations = .{ .readOnlyHint = true },
    },
    .version = .{
        .description = "Report the version",
        .handler = version,
    },
    .slow_echo = .{
        .args = EchoArgs,
        .description = "Echo with progress",
        .handler = slowEcho,
    },
});

fn callPack(pack: *TestPack, arena: Allocator, out: *Io.Writer, params_json: []const u8) !types.CallToolResult {
    const val = try std.json.parseFromSliceLeaky(std.json.Value, arena, params_json, .{});
    const params = try types.CallToolParams.fromJson(val);
    const ctx = server_mod.Context{ .sink = .{ .writer = out } };
    return pack.callTool(arena, ctx, params);
}

test "ToolPack: listTools carries generated schemas and annotations" {
    var pack = TestPack{};
    const result = try pack.listTools(testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.tools.len);
    try testing.expectEqualStrings("echo", result.tools[0].name);
    try testing.expect(mem.indexOf(u8, result.tools[0].inputSchema.?, "\"text\":{\"type\":\"string\",\"description\":\"Text to echo\"}") != null);
    try testing.expect(mem.indexOf(u8, result.tools[0].inputSchema.?, "\"required\":[\"text\"]") != null);
    try testing.expect(result.tools[0].annotations.?.readOnlyHint.?);

    // No-args tool gets an empty object schema.
    try testing.expectEqualStrings("version", result.tools[1].name);
    try testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", result.tools[1].inputSchema.?);
}

test "ToolPack: dispatches with typed args and defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var pack = TestPack{};

    const result = try callPack(&pack, arena.allocator(), &out,
        \\{"name":"echo","arguments":{"text":"hi","repeat":3}}
    );
    try testing.expectEqualStrings("hihihi", result.content[0].text.text);

    const defaulted = try callPack(&pack, arena.allocator(), &out,
        \\{"name":"echo","arguments":{"text":"x"}}
    );
    try testing.expectEqualStrings("x", defaulted.content[0].text.text);
}

test "ToolPack: no-args tool accepts absent arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var pack = TestPack{};

    const result = try callPack(&pack, arena.allocator(), &out,
        \\{"name":"version"}
    );
    try testing.expectEqualStrings("1.0", result.content[0].text.text);
}

test "ToolPack: ToolContext handler reports progress when a token is present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var pack = TestPack{};

    const result = try callPack(&pack, arena.allocator(), &out,
        \\{"name":"slow_echo","arguments":{"text":"done"},"_meta":{"progressToken":7}}
    );
    try testing.expectEqualStrings("done", result.content[0].text.text);

    const written = out_buf[0..out.end];
    try testing.expect(mem.indexOf(u8, written, "\"method\":\"notifications/progress\"") != null);
    try testing.expect(mem.indexOf(u8, written, "\"progressToken\":7") != null);

    // Without a token, sendProgress is a no-op.
    var out2_buf: [4096]u8 = undefined;
    var out2 = Io.Writer.fixed(&out2_buf);
    _ = try callPack(&pack, arena.allocator(), &out2,
        \\{"name":"slow_echo","arguments":{"text":"quiet"}}
    );
    try testing.expectEqual(@as(usize, 0), out2.end);
}

test "ToolPack: unknown tool and invalid arguments become isError results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var pack = TestPack{};

    const unknown = try callPack(&pack, arena.allocator(), &out,
        \\{"name":"nope"}
    );
    try testing.expect(unknown.isError.?);
    try testing.expect(mem.indexOf(u8, unknown.content[0].text.text, "nope") != null);

    const bad_args = try callPack(&pack, arena.allocator(), &out,
        \\{"name":"echo","arguments":{"text":42}}
    );
    try testing.expect(bad_args.isError.?);
    try testing.expect(mem.indexOf(u8, bad_args.content[0].text.text, "echo") != null);
}

test "ToolPack: composes def groups from a tuple" {
    const extra_defs = .{
        .ping_tool = .{ .description = "Pong", .handler = version },
    };
    const base_defs = .{
        .echo = .{ .args = EchoArgs, .description = "Echo text", .handler = echo },
    };
    const Combined = ToolPack(.{ base_defs, extra_defs });

    var pack = Combined{};
    const result = try pack.listTools(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result.tools.len);
    try testing.expectEqualStrings("echo", result.tools[0].name);
    try testing.expectEqualStrings("ping_tool", result.tools[1].name);
}

const Counter = struct {
    count: u32 = 0,
    label: []const u8,

    fn bump(self: *Counter, allocator: Allocator, args: struct { by: u32 = 1 }) !types.CallToolResult {
        self.count += args.by;
        return types.CallToolResult.text(allocator, try std.fmt.allocPrint(allocator, "{s}: {d}", .{ self.label, self.count }));
    }

    fn bumpWithProgress(self: *Counter, allocator: Allocator, tc: ToolContext, args: struct { by: u32 = 1 }) !types.CallToolResult {
        try tc.sendProgress(1.0, 1.0);
        return self.bump(allocator, .{ .by = args.by });
    }
};

const CounterPack = StatefulToolPack(Counter, .{
    .bump = .{ .description = "Increment the counter", .handler = Counter.bump },
    .bump_loud = .{ .description = "Increment with progress", .handler = Counter.bumpWithProgress },
});

test "StatefulToolPack: handlers receive the shared state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);

    var counter = Counter{ .label = "hits" };
    var pack = CounterPack{ .state = &counter };
    const ctx = server_mod.Context{ .sink = .{ .writer = &out } };

    const val = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"name":"bump","arguments":{"by":2}}
    , .{});
    const params = try types.CallToolParams.fromJson(val);
    const result = try pack.callTool(arena.allocator(), ctx, params);

    try testing.expectEqualStrings("hits: 2", result.content[0].text.text);
    try testing.expectEqual(@as(u32, 2), counter.count);

    // Second call sees the mutated state.
    const again = try pack.callTool(arena.allocator(), ctx, params);
    try testing.expectEqualStrings("hits: 4", again.content[0].text.text);
}

test "StatefulToolPack: ToolContext form and listTools work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);

    var counter = Counter{ .label = "n" };
    var pack = CounterPack{ .state = &counter };

    const listed = try pack.listTools(testing.allocator);
    try testing.expectEqual(@as(usize, 2), listed.tools.len);
    try testing.expect(mem.indexOf(u8, listed.tools[0].inputSchema.?, "\"by\":{\"type\":\"integer\",\"default\":1}") != null);

    const val = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"name":"bump_loud","_meta":{"progressToken":1}}
    , .{});
    const params = try types.CallToolParams.fromJson(val);
    const ctx = server_mod.Context{ .sink = .{ .writer = &out } };
    _ = try pack.callTool(arena.allocator(), ctx, params);

    try testing.expectEqual(@as(u32, 1), counter.count);
    try testing.expect(mem.indexOf(u8, out_buf[0..out.end], "\"method\":\"notifications/progress\"") != null);
}

test "ToolPack: works directly as a Server handler" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"text":"e2e"}},"id":2}
    ++ "\n";

    var pack = TestPack{};
    var server = server_mod.Server(TestPack).init(testing.allocator, &pack, .{
        .server_info = .{ .name = "pack-server", .version = "0" },
        .capabilities = .{ .tools = .{} },
    });

    var reader = Io.Reader.fixed(input);
    var out_buf: [65536]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);

    server.run(&reader, &writer) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };

    try testing.expect(mem.indexOf(u8, out_buf[0..writer.end], "\"text\":\"e2e\"") != null);
}
