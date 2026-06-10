const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const http = std.http;

const ArenaAllocator = std.heap.ArenaAllocator;

const json_rpc = @import("json_rpc.zig");
const types = @import("types.zig");
const server_mod = @import("server.zig");

const json_content_type: http.Header = .{ .name = "content-type", .value = "application/json" };

pub const HttpOptions = struct {
    port: u16 = 8080,
    address: []const u8 = "127.0.0.1",
    /// Largest accepted POST body. Oversized requests get 413 and the
    /// connection is closed.
    max_body_size: usize = 1024 * 1024,
    /// Origins allowed in addition to localhost (DNS rebinding protection).
    /// Requests without an Origin header (non-browser clients) always pass.
    allowed_origins: []const []const u8 = &.{},
};

/// Streamable HTTP transport for an MCP server (Phase A: POST + JSON only).
///
/// Wraps a `Server(Handler)` and exposes it over HTTP. Each JSON-RPC message
/// arrives as an HTTP POST; responses are `application/json`. Session state
/// is tracked via `Mcp-Session-Id` headers.
pub fn HttpTransport(comptime Handler: type) type {
    const ServerType = server_mod.Server(Handler);

    return struct {
        const Self = @This();

        allocator: Allocator,
        server: *ServerType,
        options: HttpOptions,
        session: ?Session = null,

        pub const Session = struct {
            id: [32]u8,
            state: State,

            pub const State = enum {
                awaiting_initialized,
                ready,
            };
        };

        const HeaderInfo = struct {
            accept_json: bool,
            content_type_json: bool,
            session_id: ?[]const u8,
            origin: ?[]const u8,
        };

        pub fn init(allocator: Allocator, server: *ServerType, options: HttpOptions) Self {
            return .{
                .allocator = allocator,
                .server = server,
                .options = options,
            };
        }

        pub fn listen(self: *Self, io: Io) !void {
            const address = try Io.net.IpAddress.parse(self.options.address, self.options.port);
            var net_server = try address.listen(io, .{});
            defer net_server.deinit(io);

            while (true) {
                var stream = try net_server.accept(io);
                defer stream.close(io);
                self.handleConnection(stream, io) catch continue;
            }
        }

        fn handleConnection(self: *Self, stream: Io.net.Stream, io: Io) !void {
            const read_buf = try self.allocator.alloc(u8, 64 * 1024);
            defer self.allocator.free(read_buf);
            const write_buf = try self.allocator.alloc(u8, 64 * 1024);
            defer self.allocator.free(write_buf);

            var stream_reader = stream.reader(io, read_buf);
            var stream_writer = stream.writer(io, write_buf);
            var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

            var parse_arena = ArenaAllocator.init(self.allocator);
            defer parse_arena.deinit();

            while (true) {
                var request = http_server.receiveHead() catch |err| switch (err) {
                    error.HttpConnectionClosing => return,
                    else => return err,
                };
                // Errors mid-request leave the connection in an unknown state;
                // close it rather than parse leftover bytes as the next request.
                self.handleHttpRequest(&parse_arena, &request, io) catch return;
            }
        }

        fn handleHttpRequest(self: *Self, parse_arena: *ArenaAllocator, request: *http.Server.Request, io: Io) !void {
            switch (request.head.method) {
                .POST => try self.handlePost(parse_arena, request, io),
                .DELETE => try self.handleDelete(request),
                else => try request.respond("", .{ .status = .method_not_allowed }),
            }
        }

        // =================================================================
        // POST handler
        // =================================================================

        fn handlePost(self: *Self, parse_arena: *ArenaAllocator, request: *http.Server.Request, io: Io) !void {
            defer _ = parse_arena.reset(.retain_capacity);

            // Single pass over headers before reading body (iterateHeaders requires received_head state)
            const headers = extractHeaders(request);

            const session_invalid = self.session != null and
                (headers.session_id == null or !mem.eql(u8, headers.session_id.?, &self.session.?.id));

            // Read the body before any validation response so rejected requests
            // don't leave unread bytes on a keep-alive connection.
            var body_buf: [64 * 1024]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buf);
            const body = body_reader.allocRemaining(self.allocator, Io.Limit.limited(self.options.max_body_size)) catch |err| switch (err) {
                error.StreamTooLong => {
                    try request.respond(
                        \\{"error":"Request body too large"}
                    , .{
                        .status = .payload_too_large,
                        .extra_headers = &.{json_content_type},
                    });
                    return error.BodyTooLarge;
                },
                else => return err,
            };
            defer self.allocator.free(body);

            if (!self.originAllowed(headers.origin)) {
                return request.respond(
                    \\{"error":"Origin not allowed"}
                , .{
                    .status = .forbidden,
                    .extra_headers = &.{json_content_type},
                });
            }

            if (!headers.accept_json) {
                return request.respond(
                    \\{"error":"Accept header must include application/json"}
                , .{
                    .status = .not_acceptable,
                    .extra_headers = &.{json_content_type},
                });
            }

            if (!headers.content_type_json) {
                return request.respond(
                    \\{"error":"Content-Type must be application/json"}
                , .{
                    .status = .unsupported_media_type,
                    .extra_headers = &.{json_content_type},
                });
            }

            if (session_invalid) {
                return request.respond(
                    \\{"error":"Invalid or missing session ID"}
                , .{
                    .status = .not_found,
                    .extra_headers = &.{json_content_type},
                });
            }

            const message = json_rpc.parseMessageWith(parse_arena, body) catch {
                const err_bytes = try json_rpc.serializeError(self.allocator, null, .parse_error, null);
                defer self.allocator.free(err_bytes);
                return request.respond(err_bytes, .{
                    .extra_headers = &.{json_content_type},
                });
            };

            if (self.session) |*session| {
                switch (session.state) {
                    .awaiting_initialized => try self.handleAwaitingInitialized(message, request, session),
                    .ready => try self.handleReady(message, request, &session.id),
                }
            } else if (headers.session_id != null) {
                return request.respond(
                    \\{"error":"Session not found"}
                , .{
                    .status = .not_found,
                    .extra_headers = &.{json_content_type},
                });
            } else {
                try self.handlePreSession(message, request, io);
            }
        }

        // =================================================================
        // Session state handlers
        // =================================================================

        fn handlePreSession(self: *Self, msg: json_rpc.Message, request: *http.Server.Request, io: Io) !void {
            switch (msg) {
                .request => |req| {
                    if (mem.eql(u8, req.method, "initialize")) {
                        const params = types.InitializeParams.fromJson(req.params orelse {
                            const bytes = try json_rpc.serializeError(self.allocator, req.id, .invalid_params, null);
                            defer self.allocator.free(bytes);
                            return request.respond(bytes, .{
                                .extra_headers = &.{json_content_type},
                            });
                        }) catch {
                            const bytes = try json_rpc.serializeError(self.allocator, req.id, .invalid_params, null);
                            defer self.allocator.free(bytes);
                            return request.respond(bytes, .{
                                .extra_headers = &.{json_content_type},
                            });
                        };
                        const session_id = generateSessionId(io) catch {
                            return request.respond("", .{ .status = .internal_server_error });
                        };

                        self.server.applyInitializeParams(params);
                        const result = self.server.initializeResult();
                        const bytes = try json_rpc.serializeResult(self.allocator, req.id, result);
                        defer self.allocator.free(bytes);

                        self.session = .{
                            .id = session_id,
                            .state = .awaiting_initialized,
                        };

                        return request.respond(bytes, .{
                            .extra_headers = &.{
                                json_content_type,
                                .{ .name = "mcp-session-id", .value = &self.session.?.id },
                            },
                        });
                    }

                    if (mem.eql(u8, req.method, "ping")) {
                        return self.respondPing(req.id, request, null);
                    }

                    const bytes = try json_rpc.serializeError(self.allocator, req.id, .invalid_request, null);
                    defer self.allocator.free(bytes);
                    return request.respond(bytes, .{
                        .extra_headers = &.{json_content_type},
                    });
                },
                .notification => {
                    return request.respond("", .{ .status = .accepted });
                },
                else => {
                    return request.respond("", .{ .status = .bad_request });
                },
            }
        }

        fn handleAwaitingInitialized(self: *Self, msg: json_rpc.Message, request: *http.Server.Request, session: *Session) !void {
            switch (msg) {
                .notification => |notif| {
                    if (mem.eql(u8, notif.method, "notifications/initialized")) {
                        session.state = .ready;
                    }
                    return request.respond("", .{
                        .status = .accepted,
                        .extra_headers = &.{.{ .name = "mcp-session-id", .value = &session.id }},
                    });
                },
                .request => |req| {
                    if (mem.eql(u8, req.method, "ping")) {
                        return self.respondPing(req.id, request, &session.id);
                    }
                    const bytes = try json_rpc.serializeError(self.allocator, req.id, .invalid_request, null);
                    defer self.allocator.free(bytes);
                    return request.respond(bytes, .{
                        .extra_headers = &.{
                            json_content_type,
                            .{ .name = "mcp-session-id", .value = &session.id },
                        },
                    });
                },
                else => {
                    return request.respond("", .{ .status = .bad_request });
                },
            }
        }

        fn handleReady(self: *Self, msg: json_rpc.Message, request: *http.Server.Request, session_id: *const [32]u8) !void {
            switch (msg) {
                .request => |req| {
                    var response_buf: [256 * 1024]u8 = undefined;
                    var writer = Io.Writer.fixed(&response_buf);

                    self.server.handleRequest(req, &writer) catch {
                        // Don't leak internal Zig error names to the client.
                        json_rpc.sendError(req.id, .internal_error, null, &writer) catch {};
                    };

                    const written = response_buf[0..writer.end];
                    const body = if (written.len > 0 and written[written.len - 1] == '\n')
                        written[0 .. written.len - 1]
                    else
                        written;

                    return request.respond(body, .{
                        .extra_headers = &.{
                            json_content_type,
                            .{ .name = "mcp-session-id", .value = session_id },
                        },
                    });
                },
                .notification => |notif| {
                    self.server.handleNotification(notif);
                    return request.respond("", .{
                        .status = .accepted,
                        .extra_headers = &.{.{ .name = "mcp-session-id", .value = session_id }},
                    });
                },
                else => {
                    return request.respond("", .{ .status = .bad_request });
                },
            }
        }

        // =================================================================
        // DELETE handler
        // =================================================================

        fn handleDelete(self: *Self, request: *http.Server.Request) !void {
            const headers = extractHeaders(request);
            if (self.session) |session| {
                if (headers.session_id != null and mem.eql(u8, headers.session_id.?, &session.id)) {
                    self.session = null;
                    return request.respond("", .{ .status = .ok });
                }
            }
            return request.respond("", .{ .status = .not_found });
        }

        // =================================================================
        // Helpers
        // =================================================================

        fn respondPing(self: *Self, id: json_rpc.Id, request: *http.Server.Request, session_id: ?*const [32]u8) !void {
            const bytes = try json_rpc.serializeResult(self.allocator, id, json_rpc.EmptyResult{});
            defer self.allocator.free(bytes);
            if (session_id) |sid| {
                return request.respond(bytes, .{
                    .extra_headers = &.{
                        json_content_type,
                        .{ .name = "mcp-session-id", .value = sid },
                    },
                });
            }
            return request.respond(bytes, .{
                .extra_headers = &.{json_content_type},
            });
        }

        fn extractHeaders(request: *const http.Server.Request) HeaderInfo {
            var result = HeaderInfo{
                .accept_json = false,
                .content_type_json = false,
                .session_id = null,
                .origin = null,
            };
            var it = request.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
                    if (mem.indexOf(u8, header.value, "application/json") != null or
                        mem.indexOf(u8, header.value, "*/*") != null)
                    {
                        result.accept_json = true;
                    }
                } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                    if (mem.indexOf(u8, header.value, "application/json") != null) {
                        result.content_type_json = true;
                    }
                } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                    result.session_id = header.value;
                } else if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
                    result.origin = header.value;
                }
            }
            return result;
        }

        /// DNS rebinding protection (required by the MCP spec). Requests
        /// without an Origin header come from non-browser clients and pass.
        /// Browser requests must originate from localhost or an entry in
        /// `allowed_origins`.
        fn originAllowed(self: *const Self, origin: ?[]const u8) bool {
            const o = origin orelse return true;
            for (self.options.allowed_origins) |allowed| {
                if (std.ascii.eqlIgnoreCase(o, allowed)) return true;
            }
            return isLocalOrigin(o);
        }

        fn isLocalOrigin(origin: []const u8) bool {
            const scheme_end = mem.indexOf(u8, origin, "://") orelse return false;
            const rest = origin[scheme_end + 3 ..];
            const host = if (rest.len > 0 and rest[0] == '[')
                rest[0 .. (mem.indexOfScalar(u8, rest, ']') orelse return false) + 1]
            else if (mem.indexOfScalar(u8, rest, ':')) |colon|
                rest[0..colon]
            else
                rest;
            return std.ascii.eqlIgnoreCase(host, "localhost") or
                mem.eql(u8, host, "127.0.0.1") or
                mem.eql(u8, host, "[::1]");
        }

        fn generateSessionId(io: Io) ![32]u8 {
            var bytes: [16]u8 = undefined;
            try io.randomSecure(&bytes);
            return std.fmt.bytesToHex(bytes, .lower);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const NoopHandler = struct {};

const TestTransport = HttpTransport(NoopHandler);

test "isLocalOrigin accepts localhost variants and rejects others" {
    try testing.expect(TestTransport.isLocalOrigin("http://localhost"));
    try testing.expect(TestTransport.isLocalOrigin("http://localhost:8080"));
    try testing.expect(TestTransport.isLocalOrigin("https://LOCALHOST:3000"));
    try testing.expect(TestTransport.isLocalOrigin("http://127.0.0.1:8080"));
    try testing.expect(TestTransport.isLocalOrigin("http://[::1]"));
    try testing.expect(TestTransport.isLocalOrigin("http://[::1]:8080"));

    try testing.expect(!TestTransport.isLocalOrigin("http://evil.example"));
    try testing.expect(!TestTransport.isLocalOrigin("http://localhost.evil.example"));
    try testing.expect(!TestTransport.isLocalOrigin("http://127.0.0.1.evil.example"));
    try testing.expect(!TestTransport.isLocalOrigin("localhost"));
}

test "originAllowed honors the allowlist and missing Origin" {
    var handler = NoopHandler{};
    var server = server_mod.Server(NoopHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "t", .version = "0" },
    });
    var transport = TestTransport.init(testing.allocator, &server, .{
        .allowed_origins = &.{"https://app.example.com"},
    });

    try testing.expect(transport.originAllowed(null));
    try testing.expect(transport.originAllowed("http://localhost:8080"));
    try testing.expect(transport.originAllowed("https://app.example.com"));
    try testing.expect(!transport.originAllowed("https://evil.example.com"));
}
