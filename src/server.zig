const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;

const json_rpc = @import("json_rpc.zig");
const types = @import("types.zig");

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
///
/// The Allocator passed to each handler is an arena scoped to the request;
/// the handler may allocate freely from it.
pub fn Server(comptime Handler: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        handler: *Handler,
        server_info: types.Implementation,
        capabilities: types.ServerCapabilities,
        instructions: ?[]const u8,
        read_buffer_size: usize,
        write_buffer_size: usize,

        pub fn init(allocator: Allocator, handler: *Handler, options: Options) Self {
            return .{
                .allocator = allocator,
                .handler = handler,
                .server_info = options.server_info,
                .capabilities = options.capabilities,
                .instructions = options.instructions,
                .read_buffer_size = options.read_buffer_size,
                .write_buffer_size = options.write_buffer_size,
            };
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
            try self.handleInitialize(reader, writer);
            try self.waitForInitialized(reader, writer);
            self.messageLoop(reader, writer) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return,
                else => return err,
            };
        }

        // =================================================================
        // Lifecycle phases
        // =================================================================

        fn handleInitialize(self: *Self, reader: *Io.Reader, writer: *Io.Writer) !void {
            while (true) {
                const line = try json_rpc.readLine(reader);
                const parsed = json_rpc.parseMessage(self.allocator, line) catch {
                    try json_rpc.sendError(self.allocator, null, .parse_error, null, writer);
                    continue;
                };
                defer parsed.deinit();

                switch (parsed.value) {
                    .request => |req| {
                        if (mem.eql(u8, req.method, "initialize")) {
                            const result = types.InitializeResult{
                                .capabilities = self.capabilities,
                                .serverInfo = self.server_info,
                                .instructions = self.instructions,
                            };
                            try json_rpc.sendResult(self.allocator, req.id, result, writer);
                            return;
                        } else if (mem.eql(u8, req.method, "ping")) {
                            try json_rpc.sendEmptyResult(self.allocator, req.id, writer);
                        } else {
                            try json_rpc.sendError(self.allocator, req.id, .invalid_request, null, writer);
                        }
                    },
                    .notification => {},
                    else => {},
                }
            }
        }

        fn waitForInitialized(self: *Self, reader: *Io.Reader, writer: *Io.Writer) !void {
            while (true) {
                const line = try json_rpc.readLine(reader);
                const parsed = json_rpc.parseMessage(self.allocator, line) catch continue;
                defer parsed.deinit();

                switch (parsed.value) {
                    .notification => |notif| {
                        if (mem.eql(u8, notif.method, "notifications/initialized")) {
                            return;
                        }
                    },
                    .request => |req| {
                        if (mem.eql(u8, req.method, "ping")) {
                            try json_rpc.sendEmptyResult(self.allocator, req.id, writer);
                        }
                    },
                    else => {},
                }
            }
        }

        fn messageLoop(self: *Self, reader: *Io.Reader, writer: *Io.Writer) !void {
            while (true) {
                const line = try json_rpc.readLine(reader);
                const parsed = json_rpc.parseMessage(self.allocator, line) catch |err| {
                    const code: json_rpc.ErrorCode = switch (err) {
                        error.InvalidJson => .parse_error,
                        else => .invalid_request,
                    };
                    try json_rpc.sendError(self.allocator, null, code, null, writer);
                    continue;
                };
                defer parsed.deinit();

                switch (parsed.value) {
                    .request => |req| {
                        self.handleRequest(req, writer) catch |err| {
                            json_rpc.sendError(self.allocator, req.id, .internal_error, @errorName(err), writer) catch {};
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

        fn handleRequest(self: *Self, req: json_rpc.Request, writer: *Io.Writer) !void {
            if (mem.eql(u8, req.method, "ping")) {
                return json_rpc.sendEmptyResult(self.allocator, req.id, writer);
            }

            // Simple dispatch (no params)
            inline for (.{
                .{ "tools/list", "listTools" },
                .{ "resources/list", "listResources" },
                .{ "prompts/list", "listPrompts" },
            }) |route| {
                if (mem.eql(u8, req.method, route[0])) {
                    if (comptime @hasDecl(Handler, route[1])) {
                        return self.dispatchSimple(req.id, route[1], writer);
                    }
                    return json_rpc.sendError(self.allocator, req.id, .method_not_found, null, writer);
                }
            }

            // Dispatch with params
            inline for (.{
                .{ "resources/read", "readResource", types.ReadResourceParams },
                .{ "prompts/get", "getPrompt", types.GetPromptParams },
            }) |route| {
                if (mem.eql(u8, req.method, route[0])) {
                    if (comptime @hasDecl(Handler, route[1])) {
                        return self.dispatchWithParams(req, route[1], route[2], writer);
                    }
                    return json_rpc.sendError(self.allocator, req.id, .method_not_found, null, writer);
                }
            }

            // Tool call has special error handling (errors become isError=true results)
            if (mem.eql(u8, req.method, "tools/call")) {
                if (comptime @hasDecl(Handler, "callTool")) {
                    return self.dispatchToolCall(req, writer);
                }
                return json_rpc.sendError(self.allocator, req.id, .method_not_found, null, writer);
            }

            return json_rpc.sendError(self.allocator, req.id, .method_not_found, null, writer);
        }

        fn handleNotification(self: *Self, notif: json_rpc.Notification) void {
            _ = self;
            _ = notif;
        }

        // =================================================================
        // Dispatch helpers
        // =================================================================

        fn dispatchSimple(self: *Self, id: json_rpc.Id, comptime method: []const u8, writer: *Io.Writer) !void {
            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const result = @field(Handler, method)(self.handler, arena.allocator()) catch |err| {
                return json_rpc.sendError(self.allocator, id, .internal_error, @errorName(err), writer);
            };
            try json_rpc.sendResult(self.allocator, id, result, writer);
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
                self.allocator,
                req.id,
                .invalid_params,
                null,
                writer,
            )) catch {
                return json_rpc.sendError(self.allocator, req.id, .invalid_params, null, writer);
            };

            const result = @field(Handler, method)(self.handler, arena.allocator(), params) catch |err| {
                return json_rpc.sendError(self.allocator, req.id, .internal_error, @errorName(err), writer);
            };
            try json_rpc.sendResult(self.allocator, req.id, result, writer);
        }

        fn dispatchToolCall(self: *Self, req: json_rpc.Request, writer: *Io.Writer) !void {
            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const params = types.CallToolParams.fromJson(req.params orelse return json_rpc.sendError(
                self.allocator,
                req.id,
                .invalid_params,
                null,
                writer,
            )) catch {
                return json_rpc.sendError(self.allocator, req.id, .invalid_params, null, writer);
            };

            const result = self.handler.callTool(arena.allocator(), params) catch |err| {
                const error_result = types.CallToolResult{
                    .content = &.{types.Content.text_content(@errorName(err))},
                    .isError = true,
                };
                return json_rpc.sendResult(self.allocator, req.id, error_result, writer);
            };
            try json_rpc.sendResult(self.allocator, req.id, result, writer);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestHandler = struct {
    pub fn listTools(_: *TestHandler, _: Allocator) !types.ListToolsResult {
        return .{
            .tools = &.{
                .{ .name = "test_tool", .description = "A test tool" },
            },
        };
    }

    pub fn callTool(_: *TestHandler, _: Allocator, params: types.CallToolParams) !types.CallToolResult {
        if (mem.eql(u8, params.name, "test_tool")) {
            return .{ .content = &.{types.Content.text_content("hello")} };
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
