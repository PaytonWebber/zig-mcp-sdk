const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;

const json_rpc = @import("json_rpc.zig");
const types = @import("types.zig");

/// Handle for sending server-initiated notifications (channel events, permission verdicts).
///
/// Passed to handler callbacks like `onReady` and `handlePermissionRequest`.
/// Handlers may store this value for later use (e.g. to push channel events).
pub const Context = struct {
    writer: *Io.Writer,

    pub fn sendChannelEvent(self: Context, params: types.ChannelEventParams) !void {
        try json_rpc.sendNotification(types.channel_event_method, params, self.writer);
    }

    pub fn sendPermissionVerdict(self: Context, params: types.PermissionVerdictParams) !void {
        try json_rpc.sendNotification(types.permission_verdict_method, params, self.writer);
    }

    pub fn sendNotification(self: Context, method: []const u8, params: anytype) !void {
        try json_rpc.sendNotification(method, params, self.writer);
    }

    /// Send a `notifications/message` log entry to the client.
    /// Declare `.logging = .{}` in the server capabilities when using this.
    pub fn sendLogMessage(self: Context, params: types.LogMessageParams) !void {
        try json_rpc.sendNotification(types.log_message_method, params, self.writer);
    }
};

/// Options for creating an MCP server.
pub const Options = struct {
    server_info: types.Implementation,
    capabilities: types.ServerCapabilities = .{},
    instructions: ?[]const u8 = null,
    read_buffer_size: usize = 64 * 1024,
    write_buffer_size: usize = 64 * 1024,
};

/// An MCP server that dispatches requests to a comptime-known Handler type.
///
/// The Handler struct may implement any of these methods:
///
///   fn listTools(*Handler, Allocator) !types.ListToolsResult
///   fn callTool(*Handler, Allocator, types.CallToolParams) !types.CallToolResult
///   fn listResources(*Handler, Allocator) !types.ListResourcesResult
///   fn readResource(*Handler, Allocator, types.ReadResourceParams) !types.ReadResourceResult
///   fn listPrompts(*Handler, Allocator) !types.ListPromptsResult
///   fn getPrompt(*Handler, Allocator, types.GetPromptParams) !types.GetPromptResult
///   fn setLoggingLevel(*Handler, types.LoggingLevel) void
///
/// Lifecycle hook (optional), called after a successful `initialize` with the
/// parsed client params (negotiated version, client capabilities, client info):
///
///   fn onInitialize(*Handler, types.InitializeParams) void
///
/// Channel methods (for Claude Code channel servers):
///
///   fn onReady(*Handler, Context) void
///   fn handlePermissionRequest(*Handler, Context, types.PermissionRequestParams) void
///
/// The Allocator passed to each handler is an arena scoped to the request;
/// the handler may allocate freely from it.
pub fn Server(comptime Handler: type) type {
    return struct {
        const Self = @This();

        // Hot fields, accessed on every request dispatch.
        handler: *Handler,
        context: ?Context = null,
        capabilities: types.ServerCapabilities,

        // Warm fields, accessed during initialization and response.
        server_info: types.Implementation,
        instructions: ?[]const u8,

        // Negotiated during `initialize` (valid only after the handshake).
        negotiated_version: []const u8 = types.protocol_version,
        client_capabilities: types.ClientCapabilities = .{},
        client_info: ?types.Implementation = null,

        // Cold fields, read once at startup.
        allocator: Allocator,
        read_buffer_size: usize,
        write_buffer_size: usize,

        pub fn init(allocator: Allocator, handler: *Handler, options: Options) Self {
            return .{
                .handler = handler,
                .capabilities = options.capabilities,
                .server_info = options.server_info,
                .instructions = options.instructions,
                .allocator = allocator,
                .read_buffer_size = options.read_buffer_size,
                .write_buffer_size = options.write_buffer_size,
            };
        }

        /// Negotiate the protocol version: echo the client's requested version
        /// if this SDK supports it, otherwise the latest version we support
        /// (per the spec's lifecycle rule).
        fn negotiateVersion(requested: []const u8) []const u8 {
            for (types.supported_protocol_versions) |v| {
                if (std.mem.eql(u8, v, requested)) return v;
            }
            return types.protocol_version;
        }

        /// Returns the server context for sending notifications, or null if the
        /// server is not yet running.
        pub fn getContext(self: *const Self) ?Context {
            return self.context;
        }

        pub fn initializeResult(self: *const Self) types.InitializeResult {
            return .{
                .protocolVersion = self.negotiated_version,
                .capabilities = self.capabilities,
                .serverInfo = self.server_info,
                .instructions = self.instructions,
            };
        }

        pub fn applyInitializeParams(self: *Self, params: types.InitializeParams) void {
            self.negotiated_version = negotiateVersion(params.protocolVersion);
            self.client_capabilities = params.capabilities;
            self.client_info = params.clientInfo;
            if (comptime @hasDecl(Handler, "onInitialize")) {
                self.handler.onInitialize(params);
            }
        }

        /// Run the server over stdio. Blocks until stdin is closed.
        pub fn start(self: *Self, io: Io) !void {
            const read_buf = try self.allocator.alloc(u8, self.read_buffer_size);
            defer self.allocator.free(read_buf);
            const write_buf = try self.allocator.alloc(u8, self.write_buffer_size);
            defer self.allocator.free(write_buf);

            var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), io, read_buf);
            var stdout_writer: Io.File.Writer = .init(.stdout(), io, write_buf);
            try self.run(&stdin_reader.interface, &stdout_writer.interface);
        }

        /// Run the server with arbitrary reader/writer (useful for testing).
        pub fn run(self: *Self, reader: *Io.Reader, writer: *Io.Writer) !void {
            self.context = .{ .writer = writer };
            defer self.context = null;

            var parse_arena = ArenaAllocator.init(self.allocator);
            defer parse_arena.deinit();

            try self.handleInitialize(&parse_arena, reader, writer);
            try self.waitForInitialized(&parse_arena, reader, writer);

            if (comptime @hasDecl(Handler, "onReady")) {
                self.handler.onReady(self.context.?);
            }

            self.messageLoop(&parse_arena, reader, writer) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return,
                else => return err,
            };
        }

        // =================================================================
        // Lifecycle phases
        // =================================================================

        fn handleInitialize(self: *Self, parse_arena: *ArenaAllocator, reader: *Io.Reader, writer: *Io.Writer) !void {
            while (true) {
                defer _ = parse_arena.reset(.retain_capacity);

                const line = try json_rpc.readLine(reader);
                const message = json_rpc.parseMessageWith(parse_arena, line) catch {
                    try json_rpc.sendError(null, .parse_error, null, writer);
                    continue;
                };

                switch (message) {
                    .request => |req| {
                        const h = methodHash(req.method);
                        if (h == comptime methodHash("initialize")) {
                            const params = types.InitializeParams.fromJson(req.params orelse {
                                try json_rpc.sendError(req.id, .invalid_params, null, writer);
                                continue;
                            }) catch {
                                try json_rpc.sendError(req.id, .invalid_params, null, writer);
                                continue;
                            };
                            self.applyInitializeParams(params);
                            try json_rpc.sendResult(req.id, self.initializeResult(), writer);
                            return;
                        } else if (h == comptime methodHash("ping")) {
                            try json_rpc.sendEmptyResult(req.id, writer);
                        } else {
                            // Before initialize, only ping (and initialize) are
                            // allowed; anything else is method_not_found.
                            try json_rpc.sendError(req.id, .method_not_found, null, writer);
                        }
                    },
                    .notification => {},
                    else => {},
                }
            }
        }

        fn waitForInitialized(_: *Self, parse_arena: *ArenaAllocator, reader: *Io.Reader, writer: *Io.Writer) !void {
            while (true) {
                defer _ = parse_arena.reset(.retain_capacity);

                const line = try json_rpc.readLine(reader);
                const message = json_rpc.parseMessageWith(parse_arena, line) catch continue;

                switch (message) {
                    .notification => |notif| {
                        if (methodHash(notif.method) == comptime methodHash("notifications/initialized")) {
                            return;
                        }
                    },
                    .request => |req| {
                        if (methodHash(req.method) == comptime methodHash("ping")) {
                            try json_rpc.sendEmptyResult(req.id, writer);
                        }
                    },
                    else => {},
                }
            }
        }

        fn messageLoop(self: *Self, parse_arena: *ArenaAllocator, reader: *Io.Reader, writer: *Io.Writer) !void {
            while (true) {
                defer _ = parse_arena.reset(.retain_capacity);

                const line = try json_rpc.readLine(reader);
                const message = json_rpc.parseMessageWith(parse_arena, line) catch |err| {
                    const code: json_rpc.ErrorCode = switch (err) {
                        error.InvalidJson => .parse_error,
                        else => .invalid_request,
                    };
                    try json_rpc.sendError(null, code, null, writer);
                    continue;
                };

                switch (message) {
                    .request => |req| {
                        self.handleRequest(req, writer) catch {
                            // Don't leak internal Zig error names to the client.
                            json_rpc.sendError(req.id, .internal_error, null, writer) catch {};
                        };
                    },
                    .notification => |notif| {
                        self.handleNotification(notif);
                    },
                    else => {},
                }
            }
        }

        // =================================================================
        // Request routing
        // =================================================================

        fn methodHash(name: []const u8) u64 {
            return std.hash.Wyhash.hash(0, name);
        }

        pub fn handleRequest(self: *Self, req: json_rpc.Request, writer: *Io.Writer) !void {
            const hash = methodHash(req.method);

            if (hash == comptime methodHash("ping")) {
                return json_rpc.sendEmptyResult(req.id, writer);
            }

            inline for (.{
                .{ "tools/list", "listTools" },
                .{ "resources/list", "listResources" },
                .{ "prompts/list", "listPrompts" },
            }) |route| {
                if (hash == comptime methodHash(route[0])) {
                    if (comptime @hasDecl(Handler, route[1])) {
                        return self.dispatchSimple(req.id, route[1], writer);
                    }
                    return json_rpc.sendError(req.id, .method_not_found, null, writer);
                }
            }

            inline for (.{
                .{ "resources/read", "readResource", types.ReadResourceParams },
                .{ "prompts/get", "getPrompt", types.GetPromptParams },
            }) |route| {
                if (hash == comptime methodHash(route[0])) {
                    if (comptime @hasDecl(Handler, route[1])) {
                        return self.dispatchWithParams(req, route[1], route[2], writer);
                    }
                    return json_rpc.sendError(req.id, .method_not_found, null, writer);
                }
            }

            if (hash == comptime methodHash("tools/call")) {
                if (comptime @hasDecl(Handler, "callTool")) {
                    return self.dispatchToolCall(req, writer);
                }
                return json_rpc.sendError(req.id, .method_not_found, null, writer);
            }

            if (hash == comptime methodHash("logging/setLevel")) {
                if (comptime @hasDecl(Handler, "setLoggingLevel")) {
                    return self.dispatchSetLevel(req, writer);
                }
                return json_rpc.sendError(req.id, .method_not_found, null, writer);
            }

            return json_rpc.sendError(req.id, .method_not_found, null, writer);
        }

        pub fn handleNotification(self: *Self, notif: json_rpc.Notification) void {
            if (comptime @hasDecl(Handler, "handlePermissionRequest")) {
                if (methodHash(notif.method) == comptime methodHash(types.permission_request_method)) {
                    const ctx = self.context orelse return;
                    const params = types.PermissionRequestParams.fromJson(notif.params orelse return) catch return;
                    self.handler.handlePermissionRequest(ctx, params);
                    return;
                }
            }
        }

        // =================================================================
        // Dispatch helpers
        // =================================================================

        fn dispatchSimple(self: *Self, id: json_rpc.Id, comptime method: []const u8, writer: *Io.Writer) !void {
            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const result = @field(Handler, method)(self.handler, arena.allocator()) catch {
                return json_rpc.sendError(id, .internal_error, null, writer);
            };
            try json_rpc.sendResult(id, result, writer);
        }

        fn dispatchWithParams(
            self: *Self,
            req: json_rpc.Request,
            comptime method: []const u8,
            comptime Params: type,
            writer: *Io.Writer,
        ) !void {
            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const params = Params.fromJson(req.params orelse return json_rpc.sendError(
                req.id,
                .invalid_params,
                null,
                writer,
            )) catch {
                return json_rpc.sendError(req.id, .invalid_params, null, writer);
            };

            const result = @field(Handler, method)(self.handler, arena.allocator(), params) catch {
                return json_rpc.sendError(req.id, .internal_error, null, writer);
            };
            try json_rpc.sendResult(req.id, result, writer);
        }

        fn dispatchSetLevel(self: *Self, req: json_rpc.Request, writer: *Io.Writer) !void {
            const params = types.SetLevelParams.fromJson(req.params orelse return json_rpc.sendError(
                req.id,
                .invalid_params,
                null,
                writer,
            )) catch {
                return json_rpc.sendError(req.id, .invalid_params, null, writer);
            };

            self.handler.setLoggingLevel(params.level);
            try json_rpc.sendEmptyResult(req.id, writer);
        }

        fn dispatchToolCall(self: *Self, req: json_rpc.Request, writer: *Io.Writer) !void {
            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const params = types.CallToolParams.fromJson(req.params orelse return json_rpc.sendError(
                req.id,
                .invalid_params,
                null,
                writer,
            )) catch {
                return json_rpc.sendError(req.id, .invalid_params, null, writer);
            };

            const result = self.handler.callTool(arena.allocator(), params) catch {
                const error_result = types.CallToolResult{
                    .content = &.{types.Content.text_content("tool execution failed")},
                    .isError = true,
                };
                return json_rpc.sendResult(req.id, error_result, writer);
            };
            try json_rpc.sendResult(req.id, result, writer);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const EchoArgs = struct {
    name: []const u8 = "world",
    pub const descriptions = .{ .name = "Who to greet" };
};

const TestHandler = struct {
    pub fn listTools(_: *TestHandler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{
                    .name = "test_tool",
                    .description = "A test tool",
                    .inputSchema = comptime types.schemaForStruct(EchoArgs),
                },
            },
        };
    }

    pub fn callTool(_: *TestHandler, allocator: Allocator, params: types.CallToolParams) !types.CallToolResult {
        if (mem.eql(u8, params.name, "test_tool")) {
            const args = try types.parseArgs(EchoArgs, allocator, params.arguments);
            return types.CallToolResult.text(allocator, try std.fmt.allocPrint(allocator, "hello {s}", .{args.name}));
        }
        return error.ToolNotFound;
    }
};

const TestOutput = struct {
    buf: [65536]u8 = undefined,
    len: usize = 0,

    fn slice(self: *TestOutput) []const u8 {
        return self.buf[0..self.len];
    }
};

fn runTestServer(input: []const u8) !TestOutput {
    var handler = TestHandler{};
    var s = Server(TestHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "test-server", .version = "0.1.0" },
        .capabilities = .{ .tools = .{} },
    });

    var reader = Io.Reader.fixed(input);
    var result: TestOutput = .{};
    var writer = Io.Writer.fixed(&result.buf);

    s.run(&reader, &writer) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    result.len = writer.end;
    return result;
}

fn getResponseLine(output: []const u8, n: usize) ?[]const u8 {
    var iter = mem.splitScalar(u8, output, '\n');
    var i: usize = 0;
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (i == n) return line;
        i += 1;
    }
    return null;
}

test "server handles initialize and tools/list" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"tools/list","id":2}
    ++ "\n";

    var result = try runTestServer(input);
    const output = result.slice();

    const init_line = getResponseLine(output, 0) orelse return error.MissingOutput;
    const init_parsed = try json_rpc.parseMessage(testing.allocator, init_line);
    defer init_parsed.deinit();
    try testing.expect(init_parsed.value == .response);
    try testing.expect(init_parsed.value.response.id.eql(.{ .integer = 1 }));

    const tools_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const tools_parsed = try json_rpc.parseMessage(testing.allocator, tools_line);
    defer tools_parsed.deinit();
    try testing.expect(tools_parsed.value == .response);
    try testing.expect(tools_parsed.value.response.id.eql(.{ .integer = 2 }));
}

test "server handles tools/call" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"test_tool"},"id":3}
    ++ "\n";

    var result = try runTestServer(input);
    const output = result.slice();

    const call_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const call_parsed = try json_rpc.parseMessage(testing.allocator, call_line);
    defer call_parsed.deinit();
    try testing.expect(call_parsed.value == .response);
    try testing.expect(call_parsed.value.response.id.eql(.{ .integer = 3 }));
}

test "server emits comptime-generated schema and parses typed args" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"tools/list","id":2}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"test_tool","arguments":{"name":"ada"}},"id":3}
    ++ "\n";

    var result = try runTestServer(input);
    const output = result.slice();

    // tools/list carries the schema generated from EchoArgs at comptime.
    const tools_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    try testing.expect(mem.indexOf(u8, tools_line, "\"name\":{\"type\":\"string\",\"description\":\"Who to greet\",\"default\":\"world\"}") != null);

    // tools/call routed the typed argument through parseArgs.
    const call_line = getResponseLine(output, 2) orelse return error.MissingOutput;
    try testing.expect(mem.indexOf(u8, call_line, "hello ada") != null);
}

test "server handles tool call error as result" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"unknown_tool"},"id":4}
    ++ "\n";

    var result = try runTestServer(input);
    const output = result.slice();

    const call_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const call_parsed = try json_rpc.parseMessage(testing.allocator, call_line);
    defer call_parsed.deinit();
    try testing.expect(call_parsed.value == .response);
}

test "server handles ping" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"ping","id":99}
    ++ "\n";

    var result = try runTestServer(input);
    const output = result.slice();

    const ping_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const ping_parsed = try json_rpc.parseMessage(testing.allocator, ping_line);
    defer ping_parsed.deinit();
    try testing.expect(ping_parsed.value == .response);
    try testing.expect(ping_parsed.value.response.id.eql(.{ .integer = 99 }));
}

test "server returns method_not_found for unknown methods" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"nonexistent/method","id":5}
    ++ "\n";

    var result = try runTestServer(input);
    const output = result.slice();

    const err_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const err_parsed = try json_rpc.parseMessage(testing.allocator, err_line);
    defer err_parsed.deinit();
    try testing.expect(err_parsed.value == .error_response);
    try testing.expectEqual(@as(i32, -32601), err_parsed.value.error_response.@"error".code);
}

test "server echoes a supported requested protocol version" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}},"id":1}
    ++ "\n";
    var result = try runTestServer(input);
    const line = getResponseLine(result.slice(), 0) orelse return error.MissingOutput;
    try testing.expect(mem.indexOf(u8, line, "\"protocolVersion\":\"2025-06-18\"") != null);
}

test "server falls back to its latest version for an unsupported request" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"1.0.0","capabilities":{},"clientInfo":{"name":"t","version":"1"}},"id":1}
    ++ "\n";
    var result = try runTestServer(input);
    const line = getResponseLine(result.slice(), 0) orelse return error.MissingOutput;
    try testing.expect(mem.indexOf(u8, line, "\"protocolVersion\":\"2025-11-25\"") != null);
}

test "initialize without params is invalid_params" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","id":1}
    ++ "\n";
    var result = try runTestServer(input);
    const line = getResponseLine(result.slice(), 0) orelse return error.MissingOutput;
    const parsed = try json_rpc.parseMessage(testing.allocator, line);
    defer parsed.deinit();
    try testing.expect(parsed.value == .error_response);
    try testing.expectEqual(@as(i32, -32602), parsed.value.error_response.@"error".code);
}

test "server handles invalid json gracefully" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        "not valid json\n" ++
        \\{"jsonrpc":"2.0","method":"ping","id":10}
    ++ "\n";

    var result = try runTestServer(input);
    const output = result.slice();

    const err_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const err_parsed = try json_rpc.parseMessage(testing.allocator, err_line);
    defer err_parsed.deinit();
    try testing.expect(err_parsed.value == .error_response);
    try testing.expectEqual(@as(i32, -32700), err_parsed.value.error_response.@"error".code);

    const ping_line = getResponseLine(output, 2) orelse return error.MissingOutput;
    const ping_parsed = try json_rpc.parseMessage(testing.allocator, ping_line);
    defer ping_parsed.deinit();
    try testing.expect(ping_parsed.value == .response);
}

test "server without setLoggingLevel returns method_not_found" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"debug"},"id":6}
    ++ "\n";

    var result = try runTestServer(input);
    const line = getResponseLine(result.slice(), 1) orelse return error.MissingOutput;
    const parsed = try json_rpc.parseMessage(testing.allocator, line);
    defer parsed.deinit();
    try testing.expect(parsed.value == .error_response);
    try testing.expectEqual(@as(i32, -32601), parsed.value.error_response.@"error".code);
}

const LoggingHandler = struct {
    level: ?types.LoggingLevel = null,

    pub fn setLoggingLevel(self: *LoggingHandler, level: types.LoggingLevel) void {
        self.level = level;
    }
};

test "server routes logging/setLevel to the handler" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"warning"},"id":7}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"nope"},"id":8}
    ++ "\n";

    var handler = LoggingHandler{};
    var s = Server(LoggingHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "test-logging", .version = "0.1.0" },
        .capabilities = .{ .logging = .{} },
    });

    var reader = Io.Reader.fixed(input);
    var result: TestOutput = .{};
    var writer = Io.Writer.fixed(&result.buf);

    s.run(&reader, &writer) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    result.len = writer.end;
    const output = result.slice();

    try testing.expectEqual(types.LoggingLevel.warning, handler.level.?);

    const ok_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const ok_parsed = try json_rpc.parseMessage(testing.allocator, ok_line);
    defer ok_parsed.deinit();
    try testing.expect(ok_parsed.value == .response);

    const bad_line = getResponseLine(output, 2) orelse return error.MissingOutput;
    const bad_parsed = try json_rpc.parseMessage(testing.allocator, bad_line);
    defer bad_parsed.deinit();
    try testing.expect(bad_parsed.value == .error_response);
    try testing.expectEqual(@as(i32, -32602), bad_parsed.value.error_response.@"error".code);
}

// ============================================================================
// Channel tests
// ============================================================================

const ChannelTestHandler = struct {
    permission_request_received: bool = false,
    ready_called: bool = false,
    stored_ctx: ?Context = null,

    pub fn onReady(self: *ChannelTestHandler, ctx: Context) void {
        self.ready_called = true;
        self.stored_ctx = ctx;
    }

    pub fn handlePermissionRequest(self: *ChannelTestHandler, ctx: Context, params: types.PermissionRequestParams) void {
        self.permission_request_received = true;
        ctx.sendPermissionVerdict(.{
            .request_id = params.request_id,
            .behavior = .allow,
        }) catch {};
    }
};

const InitHookHandler = struct {
    initialized: bool = false,
    requested_version: []const u8 = "",

    pub fn onInitialize(self: *InitHookHandler, params: types.InitializeParams) void {
        self.initialized = true;
        self.requested_version = params.protocolVersion;
    }
};

test "applyInitializeParams negotiates version and calls hook" {
    var handler = InitHookHandler{};
    var s = Server(InitHookHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "test-init", .version = "0.1.0" },
    });

    s.applyInitializeParams(.{
        .protocolVersion = "2025-06-18",
        .capabilities = .{},
        .clientInfo = .{ .name = "client", .version = "1.0.0" },
    });

    try testing.expect(handler.initialized);
    try testing.expectEqualStrings("2025-06-18", handler.requested_version);
    try testing.expectEqualStrings("2025-06-18", s.negotiated_version);
    try testing.expectEqualStrings("client", s.client_info.?.name);
}

test "server calls onReady after initialization" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n";

    var handler = ChannelTestHandler{};
    var s = Server(ChannelTestHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "test-channel", .version = "0.1.0" },
    });

    var reader = Io.Reader.fixed(input);
    var out_buf: [65536]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);

    s.run(&reader, &writer) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };

    try testing.expect(handler.ready_called);
    try testing.expect(handler.stored_ctx != null);
}

test "server dispatches permission request to handler" {
    const input =
        \\{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":"Bash","description":"Run ls","input_preview":"{}"}}
    ++ "\n";

    var handler = ChannelTestHandler{};
    var s = Server(ChannelTestHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "test-channel", .version = "0.1.0" },
    });

    var reader = Io.Reader.fixed(input);
    var result: TestOutput = .{};
    var writer = Io.Writer.fixed(&result.buf);

    s.run(&reader, &writer) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    result.len = writer.end;
    const output = result.slice();

    try testing.expect(handler.permission_request_received);

    // Verify the verdict was sent (line after initialize response)
    const verdict_line = getResponseLine(output, 1) orelse return error.MissingOutput;
    const verdict_parsed = try json_rpc.parseMessage(testing.allocator, verdict_line);
    defer verdict_parsed.deinit();
    try testing.expect(verdict_parsed.value == .notification);
    try testing.expectEqualStrings(types.permission_verdict_method, verdict_parsed.value.notification.method);
}
