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
    /// New `initialize` requests beyond this many live sessions get 503.
    max_sessions: usize = 64,
    /// Seconds between SSE keepalive comments on an open GET stream.
    sse_keepalive_seconds: i64 = 15,
    /// Recent notifications retained per session for SSE delivery: events
    /// sent with no stream open are buffered and replayed when one opens,
    /// and reconnecting clients resume via the `Last-Event-ID` header.
    /// 0 disables buffering and replay.
    sse_replay_events: usize = 64,
    /// Sessions inactive for this many seconds are terminated by a background
    /// reaper. Must exceed `sse_keepalive_seconds` (an open event stream
    /// counts as activity on every keepalive). 0 disables the reaper.
    session_idle_seconds: i64 = 600,
};

/// Ring buffer of recent SSE events with monotonically increasing ids.
/// Powers delivery buffering (events sent with no stream open are replayed
/// when one opens) and `Last-Event-ID` resumability.
pub const EventLog = struct {
    /// Slot for id N is (N-1) % capacity; older entries are evicted as new
    /// ones arrive.
    entries: []?Entry = &.{},
    next_id: u64 = 1,
    /// Highest id written to a live stream; entries above it are undelivered.
    delivered_up_to: u64 = 0,

    pub const Entry = struct {
        id: u64,
        data: []u8,
    };

    pub fn initCapacity(allocator: Allocator, capacity: usize) !EventLog {
        const entries = try allocator.alloc(?Entry, capacity);
        @memset(entries, null);
        return .{ .entries = entries };
    }

    pub fn deinit(log: *EventLog, allocator: Allocator) void {
        for (log.entries) |slot| {
            if (slot) |entry| allocator.free(entry.data);
        }
        allocator.free(log.entries);
        log.* = .{};
    }

    /// Buffer one event and return its id. With zero capacity nothing is
    /// stored but ids still advance.
    pub fn append(log: *EventLog, allocator: Allocator, data: []const u8) !u64 {
        const id = log.next_id;
        log.next_id += 1;
        if (log.entries.len > 0) {
            const slot = &log.entries[@intCast((id - 1) % log.entries.len)];
            if (slot.*) |old| allocator.free(old.data);
            slot.* = null;
            slot.* = .{ .id = id, .data = try allocator.dupe(u8, data) };
        }
        return id;
    }

    /// The retained entry with the lowest id greater than `after`, or null.
    /// Iterate replay as: `while (log.nextAfter(cursor)) |e| { ...; cursor = e.id; }`
    pub fn nextAfter(log: *const EventLog, after: u64) ?Entry {
        if (log.entries.len == 0) return null;
        const newest = log.next_id - 1;
        if (newest == 0 or after >= newest) return null;
        const oldest_retained = if (newest > log.entries.len)
            newest - log.entries.len + 1
        else
            1;
        const id = @max(after + 1, oldest_retained);
        return log.entries[@intCast((id - 1) % log.entries.len)];
    }
};

/// Streamable HTTP transport for an MCP server.
///
/// Wraps a `Server(Handler)` and exposes it over HTTP. JSON-RPC messages
/// arrive as POSTs; an optional GET opens a server-sent-events stream for
/// server-initiated notifications; DELETE terminates a session. Sessions are
/// tracked via `Mcp-Session-Id` headers and multiple sessions may be live at
/// once, each served on concurrently handled connections.
///
/// Thread-safety requirements, since connections are handled concurrently:
/// - the allocator passed to `init` (and to the wrapped `Server`) must be
///   thread-safe (e.g. `std.heap.smp_allocator`), and
/// - `Handler` methods must tolerate concurrent calls.
pub fn HttpTransport(comptime Handler: type) type {
    const ServerType = server_mod.Server(Handler);

    return struct {
        const Self = @This();

        allocator: Allocator,
        server: *ServerType,
        options: HttpOptions,
        sessions: SessionMap = .{},
        group: Io.Group = .init,

        pub const Session = struct {
            id: [32]u8,
            /// The transport's Io handle and allocator, needed by sseSend
            /// (which receives only the type-erased session pointer) to lock
            /// the SSE slot and buffer events.
            io: Io,
            allocator: Allocator,
            state: std.atomic.Value(State),
            /// One reference is held by the session map; each request handler
            /// working with the session holds another for its duration.
            refs: std.atomic.Value(u32),
            terminated: std.atomic.Value(bool),
            /// Monotonic seconds (`.awake` clock) of the last request or
            /// keepalive on this session; read by the idle reaper.
            last_activity: std.atomic.Value(i64),
            sse: SseSlot = .{},
            /// Guarded by `sse.mutex`.
            events: EventLog = .{},

            pub const State = enum(u8) {
                awaiting_initialized,
                ready,
            };
        };

        const SseSlot = struct {
            mutex: Io.Mutex = .init,
            /// Generation of the GET task that owns the stream; 0 = none.
            /// A new GET always takes over (last connection wins): a dead
            /// client is indistinguishable from a quiet one between
            /// keepalives, so refusing a second stream would lock out
            /// reconnecting clients for up to a keepalive interval.
            owner: u64 = 0,
            next_gen: u64 = 0,
            body: ?*http.BodyWriter = null,
        };

        const SessionMap = struct {
            mutex: Io.Mutex = .init,
            map: std.AutoHashMapUnmanaged([32]u8, *Session) = .empty,
        };

        const HeaderInfo = struct {
            accept_json: bool,
            accept_sse: bool,
            content_type_json: bool,
            session_id: ?[]const u8,
            origin: ?[]const u8,
            last_event_id: ?[]const u8,
        };

        pub fn init(allocator: Allocator, server: *ServerType, options: HttpOptions) Self {
            return .{
                .allocator = allocator,
                .server = server,
                .options = options,
            };
        }

        /// Free all session state. Call only after `listen` has returned and
        /// no connection tasks are running.
        pub fn deinit(self: *Self) void {
            var it = self.sessions.map.valueIterator();
            while (it.next()) |session| {
                session.*.events.deinit(self.allocator);
                self.allocator.destroy(session.*);
            }
            self.sessions.map.deinit(self.allocator);
        }

        pub fn listen(self: *Self, io: Io) !void {
            const address = try Io.net.IpAddress.parse(self.options.address, self.options.port);
            var net_server = try address.listen(io, .{ .reuse_address = true });
            defer net_server.deinit(io);
            defer self.group.cancel(io);

            if (self.options.session_idle_seconds > 0) {
                self.group.concurrent(io, reaperTask, .{ self, io }) catch {};
            }

            while (true) {
                const stream = try net_server.accept(io);
                self.group.concurrent(io, connectionTask, .{ self, stream, io }) catch {
                    // No spare unit of concurrency; serve inline rather than drop.
                    connectionTask(self, stream, io) catch |err| switch (err) {
                        error.Canceled => return err,
                    };
                };
            }
        }

        fn connectionTask(self: *Self, stream_const: Io.net.Stream, io: Io) Io.Cancelable!void {
            var stream = stream_const;
            defer stream.close(io);
            self.handleConnection(&stream, io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        }

        fn handleConnection(self: *Self, stream: *Io.net.Stream, io: Io) !void {
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
                self.handleHttpRequest(&parse_arena, &request, io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return err,
                };
            }
        }

        fn handleHttpRequest(self: *Self, parse_arena: *ArenaAllocator, request: *http.Server.Request, io: Io) !void {
            switch (request.head.method) {
                .POST => try self.handlePost(parse_arena, request, io),
                .GET => try self.handleGet(request, io),
                .DELETE => try self.handleDelete(request, io),
                // keep_alive=false: body-bearing methods (e.g. PUT) without a
                // content-length trip an assert in std.http discardBody when
                // the server tries to reuse the connection.
                else => try request.respond("", .{ .status = .method_not_allowed, .keep_alive = false }),
            }
        }

        // =================================================================
        // POST handler
        // =================================================================

        fn handlePost(self: *Self, parse_arena: *ArenaAllocator, request: *http.Server.Request, io: Io) !void {
            defer _ = parse_arena.reset(.retain_capacity);

            // Single pass over headers before reading body (iterateHeaders requires received_head state)
            const headers = extractHeaders(request);

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

            const message = json_rpc.parseMessageWith(parse_arena, body) catch {
                const err_bytes = try json_rpc.serializeError(self.allocator, null, .parse_error, null);
                defer self.allocator.free(err_bytes);
                return request.respond(err_bytes, .{
                    .extra_headers = &.{json_content_type},
                });
            };

            if (headers.session_id) |sid| {
                const session = self.acquireSession(sid, io) orelse {
                    return request.respond(
                        \\{"error":"Session not found"}
                    , .{
                        .status = .not_found,
                        .extra_headers = &.{json_content_type},
                    });
                };
                defer self.releaseSession(session);

                switch (session.state.load(.acquire)) {
                    .awaiting_initialized => try self.handleAwaitingInitialized(message, request, session),
                    .ready => try self.handleReady(message, request, session, headers.accept_sse),
                }
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
                            return self.respondError(request, req.id, .invalid_params);
                        }) catch {
                            return self.respondError(request, req.id, .invalid_params);
                        };

                        const session = self.createSession(io) catch |err| switch (err) {
                            error.TooManySessions => return request.respond(
                                \\{"error":"Too many sessions"}
                            , .{
                                .status = .service_unavailable,
                                .extra_headers = &.{json_content_type},
                            }),
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return request.respond("", .{ .status = .internal_server_error }),
                        };
                        defer self.releaseSession(session);

                        if (comptime @hasDecl(Handler, "onInitialize")) {
                            self.server.handler.onInitialize(params);
                        }

                        // Negotiate locally instead of mutating shared Server
                        // state: sessions initialize concurrently.
                        const result = types.InitializeResult{
                            .protocolVersion = ServerType.negotiateVersion(params.protocolVersion),
                            .capabilities = self.server.capabilities,
                            .serverInfo = self.server.server_info,
                            .instructions = self.server.instructions,
                        };
                        const bytes = try json_rpc.serializeResult(self.allocator, req.id, result);
                        defer self.allocator.free(bytes);

                        return request.respond(bytes, .{
                            .extra_headers = &.{
                                json_content_type,
                                .{ .name = "mcp-session-id", .value = &session.id },
                            },
                        });
                    }

                    if (mem.eql(u8, req.method, "ping")) {
                        return self.respondPing(req.id, request, null);
                    }

                    return self.respondError(request, req.id, .invalid_request);
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
                        session.state.store(.ready, .release);
                        if (comptime @hasDecl(Handler, "onReady")) {
                            self.server.handler.onReady(self.sessionContext(session));
                        }
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

        fn handleReady(self: *Self, msg: json_rpc.Message, request: *http.Server.Request, session: *Session, accept_sse: bool) !void {
            switch (msg) {
                .request => |req| {
                    // tools/call with a context-taking handler streams the
                    // POST response as SSE (progress events, then the result)
                    // when the client accepts text/event-stream.
                    const takes_ctx = comptime @hasDecl(Handler, "callTool") and
                        @typeInfo(@TypeOf(Handler.callTool)).@"fn".params.len == 4;
                    if (takes_ctx and accept_sse and mem.eql(u8, req.method, "tools/call")) {
                        return self.handleStreamedToolCall(req, request, session);
                    }

                    var response_buf: [256 * 1024]u8 = undefined;
                    var writer = Io.Writer.fixed(&response_buf);

                    self.server.handleRequestWithContext(req, &writer, self.sessionContext(session)) catch {
                        // Don't leak internal Zig error names to the client.
                        json_rpc.sendError(req.id, .internal_error, null, &writer) catch {};
                    };

                    const written = response_buf[0..writer.end];
                    const body = mem.trimEnd(u8, written, "\n");

                    return request.respond(body, .{
                        .extra_headers = &.{
                            json_content_type,
                            .{ .name = "mcp-session-id", .value = &session.id },
                        },
                    });
                },
                .notification => |notif| {
                    self.server.handleNotification(notif);
                    return request.respond("", .{
                        .status = .accepted,
                        .extra_headers = &.{.{ .name = "mcp-session-id", .value = &session.id }},
                    });
                },
                else => {
                    return request.respond("", .{ .status = .bad_request });
                },
            }
        }

        /// Stream a tools/call response as SSE on the POST connection:
        /// notifications the handler sends during the call become events,
        /// followed by the JSON-RPC response as the final event.
        fn handleStreamedToolCall(self: *Self, req: json_rpc.Request, request: *http.Server.Request, session: *Session) !void {
            var response_buf: [256 * 1024]u8 = undefined;
            var writer = Io.Writer.fixed(&response_buf);

            var stream_buf: [16 * 1024]u8 = undefined;
            var body_writer = try request.respondStreaming(&stream_buf, .{
                .respond_options = .{
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/event-stream" },
                        .{ .name = "cache-control", .value = "no-cache" },
                        .{ .name = "mcp-session-id", .value = &session.id },
                    },
                },
            });

            // The handler runs synchronously on this task, so the stream
            // needs no lock; the context must not outlive the call.
            var post_stream = PostStream{ .body = &body_writer };
            const ctx = server_mod.Context{ .sink = .{ .custom = .{
                .ptr = &post_stream,
                .allocator = self.allocator,
                .send = postStreamSend,
            } } };

            self.server.handleRequestWithContext(req, &writer, ctx) catch {
                // Don't leak internal Zig error names to the client.
                json_rpc.sendError(req.id, .internal_error, null, &writer) catch {};
            };

            const body = mem.trimEnd(u8, response_buf[0..writer.end], "\n");
            writeEvent(&body_writer, body, null) catch {};
            body_writer.end() catch {};
        }

        const PostStream = struct {
            body: *http.BodyWriter,
        };

        fn postStreamSend(ptr: *anyopaque, message: []const u8) anyerror!void {
            const stream: *PostStream = @ptrCast(@alignCast(ptr));
            try writeEvent(stream.body, mem.trimEnd(u8, message, "\n"), null);
        }

        // =================================================================
        // GET handler: server-sent events stream
        // =================================================================

        fn handleGet(self: *Self, request: *http.Server.Request, io: Io) !void {
            const headers = extractHeaders(request);

            if (!self.originAllowed(headers.origin)) {
                return request.respond("", .{ .status = .forbidden });
            }
            if (!headers.accept_sse) {
                return request.respond(
                    \\{"error":"Accept header must include text/event-stream"}
                , .{
                    .status = .not_acceptable,
                    .extra_headers = &.{json_content_type},
                });
            }
            const sid = headers.session_id orelse {
                return request.respond("", .{ .status = .bad_request });
            };
            const session = self.acquireSession(sid, io) orelse {
                return request.respond("", .{ .status = .not_found });
            };
            defer self.releaseSession(session);

            const my_gen = blk: {
                session.sse.mutex.lockUncancelable(io);
                defer session.sse.mutex.unlock(io);
                session.sse.next_gen += 1;
                session.sse.owner = session.sse.next_gen;
                // Abandon any previous stream; its GET task notices the owner
                // change at its next keepalive tick and exits.
                session.sse.body = null;
                break :blk session.sse.next_gen;
            };
            defer {
                session.sse.mutex.lockUncancelable(io);
                if (session.sse.owner == my_gen) {
                    session.sse.owner = 0;
                    session.sse.body = null;
                }
                session.sse.mutex.unlock(io);
            }

            var stream_buf: [8 * 1024]u8 = undefined;
            var body_writer = try request.respondStreaming(&stream_buf, .{
                .respond_options = .{
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/event-stream" },
                        .{ .name = "cache-control", .value = "no-cache" },
                        .{ .name = "mcp-session-id", .value = &session.id },
                    },
                },
            });
            try body_writer.flush();

            {
                session.sse.mutex.lockUncancelable(io);
                defer session.sse.mutex.unlock(io);

                if (session.sse.owner == my_gen) {
                    // Replay before going live: from Last-Event-ID if the
                    // client is resuming, otherwise everything undelivered.
                    var cursor: u64 = parseLastEventId(headers.last_event_id) orelse
                        session.events.delivered_up_to;
                    while (session.events.nextAfter(cursor)) |entry| {
                        try writeEvent(&body_writer, entry.data, entry.id);
                        cursor = entry.id;
                        if (entry.id > session.events.delivered_up_to) {
                            session.events.delivered_up_to = entry.id;
                        }
                    }

                    session.sse.body = &body_writer;
                }
            }

            // Keep the stream open: notifications are written by sseSend from
            // other tasks; this task sends keepalive comments and watches for
            // termination, takeover by a newer stream, or a dead connection.
            while (true) {
                try io.sleep(.fromSeconds(self.options.sse_keepalive_seconds), .awake);
                if (session.terminated.load(.acquire)) break;
                touch(session, io);

                session.sse.mutex.lockUncancelable(io);
                defer session.sse.mutex.unlock(io);
                if (session.sse.owner != my_gen) break; // newer stream took over
                if (session.sse.body == null) break; // stream died in sseSend
                body_writer.writer.writeAll(": keepalive\n\n") catch break;
                body_writer.writer.flush() catch break;
                body_writer.flush() catch break;
            }

            body_writer.end() catch {};
        }

        /// `Context.Sink.custom` callback for the session's GET stream.
        /// The event is buffered in the session's event log, then delivered
        /// immediately when a stream is open. Buffered events are replayed
        /// when a stream (re)opens, so a closed stream is only an error when
        /// buffering is disabled.
        fn sseSend(ptr: *anyopaque, message: []const u8) anyerror!void {
            const session: *Session = @ptrCast(@alignCast(ptr));
            session.sse.mutex.lockUncancelable(session.io);
            defer session.sse.mutex.unlock(session.io);

            const line = mem.trimEnd(u8, message, "\n");
            const id = try session.events.append(session.allocator, line);

            const body = session.sse.body orelse {
                if (session.events.entries.len == 0) return error.NoEventStream;
                return; // buffered; delivered when a stream opens
            };
            writeEvent(body, line, id) catch {
                // Mark the stream dead so the GET task stops using it; the
                // event stays buffered for replay on reconnect.
                session.sse.body = null;
                return;
            };
            session.events.delivered_up_to = id;
        }

        fn writeEvent(body: *http.BodyWriter, line: []const u8, id: ?u64) !void {
            if (id) |i| try body.writer.print("id: {d}\n", .{i});
            try body.writer.writeAll("data: ");
            try body.writer.writeAll(line);
            try body.writer.writeAll("\n\n");
            // Drain the body buffer through the chunked encoder, then push the
            // encoded bytes to the socket. BodyWriter.flush alone does only
            // the latter.
            try body.writer.flush();
            try body.flush();
        }

        /// Context bound to one session; notifications go to its SSE stream.
        /// Valid until the session terminates (DELETE or transport deinit).
        fn sessionContext(self: *Self, session: *Session) server_mod.Context {
            return .{ .sink = .{ .custom = .{
                .ptr = session,
                .allocator = self.allocator,
                .send = sseSend,
            } } };
        }

        // =================================================================
        // DELETE handler
        // =================================================================

        fn handleDelete(self: *Self, request: *http.Server.Request, io: Io) !void {
            const headers = extractHeaders(request);
            const sid = headers.session_id orelse {
                return request.respond("", .{ .status = .not_found });
            };

            const removed = blk: {
                if (sid.len != 32) break :blk null;
                var key: [32]u8 = undefined;
                @memcpy(&key, sid);
                self.sessions.mutex.lockUncancelable(io);
                defer self.sessions.mutex.unlock(io);
                const kv = self.sessions.map.fetchRemove(key) orelse break :blk null;
                break :blk kv.value;
            };

            if (removed) |session| {
                session.terminated.store(true, .release);
                self.releaseSession(session); // drop the map's reference
                return request.respond("", .{ .status = .ok });
            }
            return request.respond("", .{ .status = .not_found });
        }

        // =================================================================
        // Session lifecycle
        // =================================================================

        fn createSession(self: *Self, io: Io) !*Session {
            const id = try generateSessionId(io);
            const session = try self.allocator.create(Session);
            errdefer self.allocator.destroy(session);
            session.* = .{
                .id = id,
                .io = io,
                .allocator = self.allocator,
                .state = .init(.awaiting_initialized),
                // One reference for the map, one for the creating request.
                .refs = .init(2),
                .terminated = .init(false),
                .last_activity = .init(Io.Timestamp.now(io, .awake).toSeconds()),
                .events = try EventLog.initCapacity(self.allocator, self.options.sse_replay_events),
            };
            errdefer session.events.deinit(self.allocator);

            self.sessions.mutex.lockUncancelable(io);
            defer self.sessions.mutex.unlock(io);
            if (self.sessions.map.count() >= self.options.max_sessions) {
                return error.TooManySessions;
            }
            try self.sessions.map.put(self.allocator, id, session);
            return session;
        }

        fn acquireSession(self: *Self, sid: []const u8, io: Io) ?*Session {
            if (sid.len != 32) return null;
            var key: [32]u8 = undefined;
            @memcpy(&key, sid);

            self.sessions.mutex.lockUncancelable(io);
            defer self.sessions.mutex.unlock(io);
            const session = self.sessions.map.get(key) orelse return null;
            _ = session.refs.fetchAdd(1, .monotonic);
            touch(session, io);
            return session;
        }

        fn releaseSession(self: *Self, session: *Session) void {
            if (session.refs.fetchSub(1, .acq_rel) == 1) {
                session.events.deinit(self.allocator);
                self.allocator.destroy(session);
            }
        }

        /// Background task: terminate sessions with no activity for
        /// `session_idle_seconds`. Spawned by `listen` when enabled.
        fn reaperTask(self: *Self, io: Io) Io.Cancelable!void {
            const idle = self.options.session_idle_seconds;
            const interval = @max(@divTrunc(idle, 4), 1);
            while (true) {
                try io.sleep(.fromSeconds(interval), .awake);
                self.reapIdleSessions(io) catch {};
            }
        }

        fn reapIdleSessions(self: *Self, io: Io) !void {
            const now = Io.Timestamp.now(io, .awake).toSeconds();
            const idle = self.options.session_idle_seconds;

            var expired: std.ArrayList(*Session) = .empty;
            defer expired.deinit(self.allocator);

            {
                self.sessions.mutex.lockUncancelable(io);
                defer self.sessions.mutex.unlock(io);

                var it = self.sessions.map.valueIterator();
                while (it.next()) |entry| {
                    const session = entry.*;
                    if (now - session.last_activity.load(.monotonic) > idle) {
                        try expired.append(self.allocator, session);
                    }
                }
                for (expired.items) |session| {
                    _ = self.sessions.map.remove(session.id);
                }
            }

            for (expired.items) |session| {
                session.terminated.store(true, .release);
                self.releaseSession(session); // drop the map's reference
            }
        }

        // =================================================================
        // Helpers
        // =================================================================

        fn respondError(self: *Self, request: *http.Server.Request, id: json_rpc.Id, code: json_rpc.ErrorCode) !void {
            const bytes = try json_rpc.serializeError(self.allocator, id, code, null);
            defer self.allocator.free(bytes);
            return request.respond(bytes, .{
                .extra_headers = &.{json_content_type},
            });
        }

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
                .accept_sse = false,
                .content_type_json = false,
                .session_id = null,
                .origin = null,
                .last_event_id = null,
            };
            var it = request.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
                    if (mem.indexOf(u8, header.value, "application/json") != null or
                        mem.indexOf(u8, header.value, "*/*") != null)
                    {
                        result.accept_json = true;
                    }
                    if (mem.indexOf(u8, header.value, "text/event-stream") != null or
                        mem.indexOf(u8, header.value, "*/*") != null)
                    {
                        result.accept_sse = true;
                    }
                } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                    if (mem.indexOf(u8, header.value, "application/json") != null) {
                        result.content_type_json = true;
                    }
                } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                    result.session_id = header.value;
                } else if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
                    result.origin = header.value;
                } else if (std.ascii.eqlIgnoreCase(header.name, "last-event-id")) {
                    result.last_event_id = header.value;
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

        fn parseLastEventId(header: ?[]const u8) ?u64 {
            const value = header orelse return null;
            return std.fmt.parseInt(u64, value, 10) catch null;
        }

        fn touch(session: *Session, io: Io) void {
            const now = Io.Timestamp.now(io, .awake).toSeconds();
            session.last_activity.store(now, .monotonic);
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

test "session refcounting: DELETE-while-acquired defers destruction" {
    var handler = NoopHandler{};
    var server = server_mod.Server(NoopHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "t", .version = "0" },
    });
    var transport = TestTransport.init(testing.allocator, &server, .{});
    defer transport.deinit();

    // Create a session directly (bypassing generateSessionId's entropy call).
    const session = try testing.allocator.create(TestTransport.Session);
    session.* = .{
        .id = "0123456789abcdef0123456789abcdef".*,
        .io = testing.io,
        .allocator = testing.allocator,
        .state = .init(.ready),
        .refs = .init(1),
        .terminated = .init(false),
        .last_activity = .init(0),
        .events = try EventLog.initCapacity(testing.allocator, 4),
    };
    try transport.sessions.map.put(testing.allocator, session.id, session);

    // A request acquires the session; then the session is removed (DELETE).
    const acquired = transport.acquireSession(&session.id, testing.io).?;
    try testing.expectEqual(@as(u32, 2), acquired.refs.load(.monotonic));

    const kv = transport.sessions.map.fetchRemove(session.id).?;
    kv.value.terminated.store(true, .release);
    transport.releaseSession(kv.value); // map's ref dropped, request still holds one

    try testing.expectEqual(@as(u32, 1), acquired.refs.load(.monotonic));
    try testing.expect(acquired.terminated.load(.acquire));

    // Request finishes; session is destroyed here (leak checker verifies).
    transport.releaseSession(acquired);
}

test "acquireSession rejects unknown and malformed ids" {
    var handler = NoopHandler{};
    var server = server_mod.Server(NoopHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "t", .version = "0" },
    });
    var transport = TestTransport.init(testing.allocator, &server, .{});
    defer transport.deinit();

    try testing.expect(transport.acquireSession("tooshort", testing.io) == null);
    try testing.expect(transport.acquireSession("0123456789abcdef0123456789abcdef", testing.io) == null);
}

test "EventLog: append assigns sequential ids and evicts oldest at capacity" {
    var log = try EventLog.initCapacity(testing.allocator, 3);
    defer log.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 1), try log.append(testing.allocator, "one"));
    try testing.expectEqual(@as(u64, 2), try log.append(testing.allocator, "two"));
    try testing.expectEqual(@as(u64, 3), try log.append(testing.allocator, "three"));
    try testing.expectEqual(@as(u64, 4), try log.append(testing.allocator, "four")); // evicts "one"

    // Replay from 0: oldest retained is id 2.
    var cursor: u64 = 0;
    var seen: usize = 0;
    var first_id: u64 = 0;
    while (log.nextAfter(cursor)) |entry| {
        if (seen == 0) first_id = entry.id;
        cursor = entry.id;
        seen += 1;
    }
    try testing.expectEqual(@as(u64, 2), first_id);
    try testing.expectEqual(@as(usize, 3), seen);
}

test "EventLog: nextAfter resumes from a given id" {
    var log = try EventLog.initCapacity(testing.allocator, 8);
    defer log.deinit(testing.allocator);

    _ = try log.append(testing.allocator, "a");
    _ = try log.append(testing.allocator, "b");
    _ = try log.append(testing.allocator, "c");

    const entry = log.nextAfter(2) orelse return error.MissingEntry;
    try testing.expectEqual(@as(u64, 3), entry.id);
    try testing.expectEqualStrings("c", entry.data);

    try testing.expect(log.nextAfter(3) == null);
    try testing.expect(log.nextAfter(99) == null);
}

test "EventLog: zero capacity advances ids but stores nothing" {
    var log = EventLog{};
    try testing.expectEqual(@as(u64, 1), try log.append(testing.allocator, "x"));
    try testing.expectEqual(@as(u64, 2), try log.append(testing.allocator, "y"));
    try testing.expect(log.nextAfter(0) == null);
}

test "reapIdleSessions terminates expired sessions and keeps active ones" {
    var handler = NoopHandler{};
    var server = server_mod.Server(NoopHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "t", .version = "0" },
    });
    var transport = TestTransport.init(testing.allocator, &server, .{ .session_idle_seconds = 60 });
    defer transport.deinit();

    const now = Io.Timestamp.now(testing.io, .awake).toSeconds();

    const stale = try testing.allocator.create(TestTransport.Session);
    stale.* = .{
        .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*,
        .io = testing.io,
        .allocator = testing.allocator,
        .state = .init(.ready),
        .refs = .init(1),
        .terminated = .init(false),
        .last_activity = .init(now - 120),
        .events = .{},
    };
    try transport.sessions.map.put(testing.allocator, stale.id, stale);

    const fresh = try testing.allocator.create(TestTransport.Session);
    fresh.* = .{
        .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".*,
        .io = testing.io,
        .allocator = testing.allocator,
        .state = .init(.ready),
        .refs = .init(1),
        .terminated = .init(false),
        .last_activity = .init(now),
        .events = .{},
    };
    try transport.sessions.map.put(testing.allocator, fresh.id, fresh);

    try transport.reapIdleSessions(testing.io);

    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(transport.sessions.map.count())));
    try testing.expect(transport.sessions.map.get(fresh.id) != null);
    try testing.expect(transport.sessions.map.get(stale.id) == null);
}

test "max_sessions caps live sessions" {
    var handler = NoopHandler{};
    var server = server_mod.Server(NoopHandler).init(testing.allocator, &handler, .{
        .server_info = .{ .name = "t", .version = "0" },
    });
    var transport = TestTransport.init(testing.allocator, &server, .{ .max_sessions = 1 });
    defer transport.deinit();

    const first = try testing.allocator.create(TestTransport.Session);
    first.* = .{
        .id = "0123456789abcdef0123456789abcdef".*,
        .io = testing.io,
        .allocator = testing.allocator,
        .state = .init(.ready),
        .refs = .init(1),
        .terminated = .init(false),
        .last_activity = .init(0),
        .events = .{},
    };
    try transport.sessions.map.put(testing.allocator, first.id, first);

    // createSession would exceed the cap; replicate its guarded check.
    transport.sessions.mutex.lockUncancelable(testing.io);
    const at_cap = transport.sessions.map.count() >= transport.options.max_sessions;
    transport.sessions.mutex.unlock(testing.io);
    try testing.expect(at_cap);
}
