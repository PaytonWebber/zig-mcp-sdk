const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const http = std.http;

const json_rpc = @import("json_rpc.zig");
const types = @import("types.zig");
const server_mod = @import("server.zig");

const json_content_type: http.Header = .{ .name = "content-type", .value = "application/json" };

pub const HttpOptions = struct {
    port: u16 = 8080,
    address: []const u8 = "127.0.0.1",
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
            session_id: ?[]const u8,
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

            while (true) {
                var request = http_server.receiveHead() catch |err| switch (err) {
                    error.HttpConnectionClosing => return,
                    else => return err,
                };
                self.handleHttpRequest(&request) catch continue;
            }
        }

        fn handleHttpRequest(self: *Self, request: *http.Server.Request) !void {
            switch (request.head.method) {
                .POST => try self.handlePost(request),
                .DELETE => try self.handleDelete(request),
                else => try request.respond("", .{ .status = .method_not_allowed }),
            }
        }

        // =================================================================
        // POST handler
        // =================================================================

        fn handlePost(self: *Self, request: *http.Server.Request) !void {
            // Single pass over headers before reading body (iterateHeaders requires received_head state)
            const headers = extractHeaders(request);

            if (!headers.accept_json) {
                return request.respond(
                    \\{"error":"Accept header must include application/json"}
                , .{
                    .status = .not_acceptable,
                    .extra_headers = &.{json_content_type},
                });
            }

            const session_invalid = self.session != null and
                (headers.session_id == null or !mem.eql(u8, headers.session_id.?, &self.session.?.id));

            // Read body
            var body_buf: [64 * 1024]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buf);
            const body = try body_reader.allocRemaining(self.allocator, Io.Limit.limited(1024 * 1024));
            defer self.allocator.free(body);

            if (session_invalid) {
                return request.respond(
                    \\{"error":"Invalid or missing session ID"}
                , .{
                    .status = .not_found,
                    .extra_headers = &.{json_content_type},
                });
            }

            const parsed = json_rpc.parseMessage(self.allocator, body) catch {
                const err_bytes = try json_rpc.serializeError(self.allocator, null, .parse_error, null);
                defer self.allocator.free(err_bytes);
                return request.respond(err_bytes, .{
                    .extra_headers = &.{json_content_type},
                });
            };
            defer parsed.deinit();

            if (self.session) |*session| {
                switch (session.state) {
                    .awaiting_initialized => try self.handleAwaitingInitialized(parsed.value, request, session),
                    .ready => try self.handleReady(parsed.value, request, &session.id),
                }
            } else if (headers.session_id != null) {
                return request.respond(
                    \\{"error":"Session not found"}
                , .{
                    .status = .not_found,
                    .extra_headers = &.{json_content_type},
                });
            } else {
                try self.handlePreSession(parsed.value, request);
            }
        }

        // =================================================================
        // Session state handlers
        // =================================================================

        fn handlePreSession(self: *Self, msg: json_rpc.Message, request: *http.Server.Request) !void {
            switch (msg) {
                .request => |req| {
                    if (mem.eql(u8, req.method, "initialize")) {
                        const result = self.server.initializeResult();
                        const bytes = try json_rpc.serializeResult(self.allocator, req.id, result);
                        defer self.allocator.free(bytes);

                        self.session = .{
                            .id = generateSessionId(),
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

                    self.server.handleRequest(req, &writer) catch |err| {
                        json_rpc.sendError(self.allocator, req.id, .internal_error, @errorName(err), &writer) catch {};
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
            var result = HeaderInfo{ .accept_json = false, .session_id = null };
            var it = request.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
                    if (mem.indexOf(u8, header.value, "application/json") != null or
                        mem.indexOf(u8, header.value, "*/*") != null)
                    {
                        result.accept_json = true;
                    }
                } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                    result.session_id = header.value;
                }
            }
            return result;
        }

        fn generateSessionId() [32]u8 {
            var bytes: [16]u8 = undefined;
            switch (comptime builtin.os.tag) {
                .linux => _ = std.os.linux.getrandom(&bytes, bytes.len, 0),
                else => @compileError("HttpTransport requires Linux (getrandom syscall)"),
            }
            return std.fmt.bytesToHex(bytes, .lower);
        }
    };
}
