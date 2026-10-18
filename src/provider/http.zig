//! HTTP for providers (PLAN.md §6.2, D12): `std.http.Client` plus retries,
//! a time-to-headers timeout, an idle timeout while reading the body, eager
//! CA-bundle loading, proxies from the environment, and a replay transport
//! for tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

pub const CaBundle = union(enum) {
    /// Scan the operating system's certificate store.
    system,
    /// PEM text, usually `@embedFile("cacert.pem")`.
    pem: []const u8,
    /// Path to a PEM file.
    path: []const u8,
};

pub const Options = struct {
    ca_bundle: CaBundle = .system,
    /// Time allowed until response headers arrive, per attempt.
    timeout_ms: u32 = 120_000,
    /// Time allowed between bytes of the response body. Anthropic sends
    /// `ping` events, but OpenAI-compatible servers can stay silent while a
    /// reasoning model thinks, so the default is generous. 0 disables it.
    idle_timeout_ms: u32 = 300_000,
    /// Retries after the first attempt, for 408/409/429/5xx and connection errors.
    max_retries: u8 = 2,
    base_backoff_ms: u32 = 500,
    max_backoff_ms: u32 = 20_000,
    /// Record every response body to `<dir>/<n>.sse` (with `<n>.json` holding
    /// the URL and status), to make cassettes from real traffic (PLAN.md §10).
    record_dir: ?[]const u8 = null,
};

pub const Error = error{
    OutOfMemory,
    Canceled,
    /// Couldn't connect, or the connection failed before response headers.
    ConnectionFailed,
    Timeout,
    /// The response stream ended or failed after events were delivered.
    StreamInterrupted,
    NoCaCertificates,
    CaBundleInvalid,
    InvalidUrl,
};

/// One recorded exchange, for `Replay`.
pub const Interaction = struct {
    /// Must be a suffix of the requested URL, e.g. "/v1/messages".
    url_suffix: []const u8,
    status: u16 = 200,
    body: []const u8,
    headers: []const std.http.Header = &.{},
};

/// Test transport: serves canned responses in order and records request
/// bodies so tests can assert on what was sent.
pub const Replay = struct {
    interactions: []const Interaction,
    /// Computes responses instead of `interactions` (the test harness's
    /// scripted models). Returns null for "no scripted response".
    responder: ?Responder = null,
    next: usize = 0,
    requests: std.ArrayList([]u8) = .empty,
    gpa: Allocator,
    mutex: Io.Mutex = .init,

    pub fn init(gpa: Allocator, interactions: []const Interaction) Replay {
        return .{ .gpa = gpa, .interactions = interactions };
    }

    pub fn deinit(r: *Replay) void {
        for (r.requests.items) |b| r.gpa.free(b);
        r.requests.deinit(r.gpa);
    }

    pub const Responder = struct {
        ctx: *anyopaque,
        respond: *const fn (ctx: *anyopaque, url: []const u8, headers: []const std.http.Header, body: []const u8) ?Interaction,
    };

    pub fn remaining(r: *const Replay) usize {
        return r.interactions.len - r.next;
    }
};

pub const Http = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    client: std.http.Client,
    replay: ?*Replay = null,
    proxy_arena: std.heap.ArenaAllocator,
    record_count: std.atomic.Value(u32) = .init(0),

    /// Loads CA certificates now, so a missing store fails at startup rather
    /// than on the first request.
    pub fn init(gpa: Allocator, io: Io, opts: Options, env: ?*const Environ.Map) Error!Http {
        var h: Http = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .client = .{ .allocator = gpa, .io = io },
            .proxy_arena = .init(gpa),
        };
        errdefer h.client.deinit();
        errdefer h.proxy_arena.deinit();
        if (!std.http.Client.disable_tls) try h.loadCaBundle();
        if (env) |e| h.client.initDefaultProxies(h.proxy_arena.allocator(), e) catch {};
        return h;
    }

    /// A client for plain `http://` URLs only: no CA certificates are loaded.
    pub fn initPlain(gpa: Allocator, io: Io, opts: Options, env: ?*const Environ.Map) Http {
        var h: Http = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .client = .{ .allocator = gpa, .io = io },
            .proxy_arena = .init(gpa),
        };
        if (env) |e| h.client.initDefaultProxies(h.proxy_arena.allocator(), e) catch {};
        return h;
    }

    /// A client that serves `replay` instead of touching the network.
    pub fn initReplay(gpa: Allocator, io: Io, replay: *Replay) Http {
        return .{
            .gpa = gpa,
            .io = io,
            .opts = .{ .max_retries = 0 },
            .client = .{ .allocator = gpa, .io = io },
            .replay = replay,
            .proxy_arena = .init(gpa),
        };
    }

    pub fn deinit(h: *Http) void {
        h.client.deinit();
        h.proxy_arena.deinit();
    }

    fn loadCaBundle(h: *Http) Error!void {
        const now = Io.Clock.real.now(h.io);
        const bundle = &h.client.ca_bundle;
        switch (h.opts.ca_bundle) {
            .system => bundle.rescan(h.gpa, h.io, now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NoCaCertificates,
            },
            .pem => |pem| addPem(bundle, h.gpa, pem, now.toSeconds()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CaBundleInvalid,
            },
            .path => |p| bundle.addCertsFromFilePath(h.gpa, h.io, now, Io.Dir.cwd(), p) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CaBundleInvalid,
            },
        }
        if (bundle.map.count() == 0) return error.NoCaCertificates;
        // Tell std.http the bundle is loaded so it doesn't rescan.
        h.client.now = now;
    }

    /// Per-request overrides of `Options`.
    pub const RequestOptions = struct {
        method: std.http.Method = .POST,
        /// Overrides `Options.idle_timeout_ms` (0 disables it, e.g. for
        /// long-lived notification streams).
        idle_timeout_ms: ?u32 = null,
        max_retries: ?u8 = null,
    };

    /// POST `body` to `url`. Retries (before any response body is read) on
    /// connection failures, 408, 409, 429 and 5xx, honoring `Retry-After`.
    /// The returned response may have any status; the caller checks it.
    pub fn post(h: *Http, url: []const u8, headers: []const std.http.Header, body: []const u8) Error!*Response {
        return h.request(url, headers, body, .{});
    }

    /// Like `post`, with a method and per-request options.
    pub fn request(h: *Http, url: []const u8, headers: []const std.http.Header, body: []const u8, ro: RequestOptions) Error!*Response {
        if (h.replay) |r| return h.postReplay(r, url, headers, body);

        const max_retries = ro.max_retries orelse h.opts.max_retries;
        var tries: u8 = 0;
        while (true) : (tries += 1) {
            const last = tries >= max_retries;
            const res = h.attemptOnce(url, headers, body, ro) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory, error.InvalidUrl => |e| return e,
                else => |e| {
                    if (last) return e;
                    try h.backoff(tries, null);
                    continue;
                },
            };
            const retryable = switch (res.status) {
                408, 409, 429, 500...599 => true,
                else => false,
            };
            if (!retryable or last) {
                if (h.opts.record_dir) |dir| h.record(dir, url, res) catch |err| std.log.warn("zastra: recording cassette: {t}", .{err});
                return res;
            }
            const retry_after = res.retry_after_ms;
            res.close();
            try h.backoff(tries, retry_after);
        }
    }

    /// Read the whole body, save it, and replace the response reader with a
    /// fixed reader over the saved bytes.
    fn record(h: *Http, dir_path: []const u8, url: []const u8, res: *Response) !void {
        const body = try res.readAll(h.gpa, 64 << 20);
        const n = h.record_count.fetchAdd(1, .monotonic);
        var dir = try Io.Dir.cwd().createDirPathOpen(h.io, dir_path, .{});
        defer dir.close(h.io);
        var name_buf: [32]u8 = undefined;
        try dir.writeFile(h.io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "{d:0>3}.sse", .{n}), .data = body });
        const meta = try h.gpa.print("{{\"url\":\"{s}\",\"status\":{d}}}\n", .{ url, res.status });
        defer h.gpa.free(meta);
        try dir.writeFile(h.io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "{d:0>3}.json", .{n}), .data = meta });
        res.recorded = body;
        res.fixed = .fixed(body);
        res.reader = &res.fixed;
    }

    fn backoff(h: *Http, n: u8, retry_after_ms: ?u64) Error!void {
        const ms: u64 = retry_after_ms orelse blk: {
            const base = @as(u64, h.opts.base_backoff_ms) << @intCast(@min(n, 10));
            const capped = @min(base, h.opts.max_backoff_ms);
            var r: [8]u8 = undefined;
            h.io.random(&r);
            const jitter = std.mem.readInt(u64, &r, .little) % (capped / 2 + 1);
            break :blk capped / 2 + jitter;
        };
        h.io.sleep(.fromMilliseconds(@intCast(@min(ms, 60_000))), .awake) catch return error.Canceled;
    }

    /// One attempt, bounded by `timeout_ms` until headers arrive.
    fn attemptOnce(h: *Http, url: []const u8, headers: []const std.http.Header, body: []const u8, ro: RequestOptions) Error!*Response {
        if (h.opts.timeout_ms == 0) return h.attemptInner(url, headers, body, ro);
        const Sel = Io.Select(union(enum) {
            done: Error!*Response,
            timeout: Io.Cancelable!void,
        });
        var buf: [2]Sel.Union = undefined;
        var sel: Sel = .init(h.io, &buf);
        sel.concurrent(.done, attemptInner, .{ h, url, headers, body, ro }) catch
            return h.attemptInner(url, headers, body, ro); // no concurrency available: no timeout
        sel.concurrent(.timeout, sleepMs, .{ h.io, h.opts.timeout_ms }) catch {
            // No unit of concurrency for the timer: wait for the request alone.
            const u = sel.await() catch {
                drain(&sel);
                return error.Canceled;
            };
            drain(&sel);
            return u.done;
        };
        const first = sel.await() catch {
            drain(&sel);
            return error.Canceled;
        };
        switch (first) {
            .done => |r| {
                drain(&sel);
                return r;
            },
            .timeout => {
                drain(&sel);
                return error.Timeout;
            },
        }
    }

    /// Cancel the remaining select task; release a response it may have produced.
    fn drain(sel: anytype) void {
        while (sel.cancel()) |u| switch (u) {
            .done => |r| if (r) |res| res.close() else |_| {},
            .timeout => {},
        };
    }

    fn sleepMs(io: Io, ms: u32) Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(ms), .awake);
    }

    fn attemptInner(h: *Http, url: []const u8, headers: []const std.http.Header, body: []const u8, ro: RequestOptions) Error!*Response {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const res = try h.gpa.create(Response);
        errdefer h.gpa.destroy(res);
        res.* = .{ .http = h, .live = undefined };
        res.live.req = h.client.request(ro.method, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
                .user_agent = .{ .override = "zastra/0.1" },
            },
            .extra_headers = headers,
            .keep_alive = true,
            .redirect_behavior = .not_allowed,
        }) catch |err| return mapErr(err);
        errdefer res.live.req.deinit();
        if (ro.method.requestHasBody()) {
            res.live.req.transfer_encoding = .{ .content_length = body.len };
            var bw = res.live.req.sendBodyUnflushed(&.{}) catch |err| return mapErr(err);
            bw.writer.writeAll(body) catch return error.ConnectionFailed;
            bw.end() catch return error.ConnectionFailed;
            res.live.req.connection.?.flush() catch return error.ConnectionFailed;
        } else {
            res.live.req.sendBodiless() catch |err| return mapErr(err);
        }
        const resp = res.live.req.receiveHead(&res.live.redirect_buf) catch |err| return mapErr(err);
        res.status = @backingInt(resp.head.status);
        res.retry_after_ms = retryAfter(resp.head);
        res.headers = try copyHeaders(h.gpa, resp.head);
        res.owns_headers = true;
        res.live.response = resp;
        res.reader = res.live.response.reader(&res.live.transfer_buf);
        const idle_ms = ro.idle_timeout_ms orelse h.opts.idle_timeout_ms;
        if (idle_ms != 0) {
            res.live.idle = .init(h.io, res.reader, idle_ms, &res.live.idle_buf);
            res.reader = &res.live.idle.interface;
        }
        return res;
    }

    fn mapErr(err: anyerror) Error {
        return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => error.InvalidUrl,
            else => error.ConnectionFailed,
        };
    }

    fn postReplay(h: *Http, r: *Replay, url: []const u8, headers: []const std.http.Header, body: []const u8) Error!*Response {
        r.mutex.lockUncancelable(h.io);
        defer r.mutex.unlock(h.io);
        try r.requests.append(r.gpa, try r.gpa.dupe(u8, body));
        if (r.responder) |rs| {
            const ix = rs.respond(rs.ctx, url, headers, body) orelse {
                std.debug.print("zastra replay: no scripted response for request to {s}\n", .{url});
                return error.ConnectionFailed;
            };
            const res = try h.gpa.create(Response);
            res.* = .{ .http = h, .status = ix.status, .replayed = true, .live = undefined, .headers = ix.headers };
            res.fixed = .fixed(ix.body);
            res.reader = &res.fixed;
            return res;
        }
        if (r.next >= r.interactions.len) {
            std.debug.print("zastra replay: unexpected request #{d} to {s}\n", .{ r.next + 1, url });
            return error.ConnectionFailed;
        }
        const ix = r.interactions[r.next];
        r.next += 1;
        if (!std.mem.endsWith(u8, url, ix.url_suffix)) {
            std.debug.print("zastra replay: request to {s}, expected one ending in {s}\n", .{ url, ix.url_suffix });
            return error.ConnectionFailed;
        }
        const res = try h.gpa.create(Response);
        res.* = .{ .http = h, .status = ix.status, .replayed = true, .live = undefined, .headers = ix.headers };
        res.fixed = .fixed(ix.body);
        res.reader = &res.fixed;
        return res;
    }
};

/// Response headers, copied out of the connection buffer (which later body
/// reads reuse).
fn copyHeaders(gpa: Allocator, head: std.http.Client.Response.Head) Allocator.Error![]const std.http.Header {
    var n: usize = 0;
    var size: usize = 0;
    var it = head.iterateHeaders();
    while (it.next()) |hd| {
        n += 1;
        size += hd.name.len + hd.value.len;
    }
    const out = try gpa.alloc(std.http.Header, n);
    errdefer gpa.free(out);
    const bytes = try gpa.alloc(u8, size);
    var at: usize = 0;
    it = head.iterateHeaders();
    var i: usize = 0;
    while (it.next()) |hd| : (i += 1) {
        @memcpy(bytes[at..][0..hd.name.len], hd.name);
        const name = bytes[at..][0..hd.name.len];
        at += hd.name.len;
        @memcpy(bytes[at..][0..hd.value.len], hd.value);
        out[i] = .{ .name = name, .value = bytes[at..][0..hd.value.len] };
        at += hd.value.len;
    }
    return out;
}

fn retryAfter(head: std.http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |hd| {
        if (std.ascii.eqlIgnoreCase(hd.name, "retry-after-ms")) {
            return std.fmt.parseInt(u64, std.mem.trim(u8, hd.value, " "), 10) catch null;
        }
        if (std.ascii.eqlIgnoreCase(hd.name, "retry-after")) {
            const s = std.fmt.parseInt(u64, std.mem.trim(u8, hd.value, " "), 10) catch return null;
            return s * 1000;
        }
    }
    return null;
}

pub const Response = struct {
    http: *Http,
    status: u16 = 0,
    retry_after_ms: ?u64 = null,
    /// The response body. Reading it may block on the network.
    reader: *Io.Reader = undefined,
    replayed: bool = false,
    fixed: Io.Reader = undefined,
    /// Body captured by cassette recording (owned).
    recorded: ?[]u8 = null,
    /// Response headers.
    headers: []const std.http.Header = &.{},
    owns_headers: bool = false,
    live: Live,

    /// The first response header named `name` (case-insensitive).
    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        for (r.headers) |hd| if (std.ascii.eqlIgnoreCase(hd.name, name)) return hd.value;
        return null;
    }

    const Live = struct {
        req: std.http.Client.Request,
        response: std.http.Client.Response,
        redirect_buf: [1024]u8,
        transfer_buf: [16 * 1024]u8,
        idle: IdleReader,
        idle_buf: [16 * 1024]u8,
    };

    pub fn ok(r: *const Response) bool {
        return r.status >= 200 and r.status < 300;
    }

    /// Read the remaining body (for error responses), truncated to `limit`.
    pub fn readAll(r: *Response, gpa: Allocator, limit: usize) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var chunk: [4096]u8 = undefined;
        while (out.items.len < limit) {
            const n = r.reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(gpa, chunk[0..@min(n, limit - out.items.len)]);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Map a body-read failure: a cancel shows up from std.http as
    /// `error.ReadFailed` (M0 spike), so check the task's cancel state.
    pub fn readError(r: *Response) Error {
        r.http.io.checkCancel() catch return error.Canceled;
        if (r.idleTimedOut()) return error.Timeout;
        return error.StreamInterrupted;
    }

    /// True if the body read failed because no bytes arrived within
    /// `idle_timeout_ms`.
    pub fn idleTimedOut(r: *const Response) bool {
        return !r.replayed and r.reader == &r.live.idle.interface and r.live.idle.timed_out;
    }

    pub fn close(r: *Response) void {
        const gpa = r.http.gpa;
        if (r.recorded) |b| gpa.free(b);
        if (r.owns_headers) {
            var size: usize = 0;
            for (r.headers) |hd| size += hd.name.len + hd.value.len;
            if (r.headers.len > 0) gpa.free(@as([*]const u8, r.headers[0].name.ptr)[0..size]);
            gpa.free(r.headers);
        }
        if (!r.replayed) r.live.req.deinit();
        gpa.destroy(r);
    }
};

/// Wraps a body reader so that each network read must produce bytes within
/// `ms`. `std.Io` has no read timeout for TCP streams, so a read that would
/// block runs as a concurrent task raced against a timer, as in
/// `attemptOnce`. On timeout the read is canceled (closing the request then
/// drops the connection) and the reader fails with `timed_out` set.
pub const IdleReader = struct {
    io: Io,
    inner: *Io.Reader,
    ms: u32,
    timed_out: bool = false,
    interface: Io.Reader,

    pub fn init(io: Io, inner: *Io.Reader, ms: u32, buffer: []u8) IdleReader {
        return .{
            .io = io,
            .inner = inner,
            .ms = ms,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *IdleReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.timed_out) return error.ReadFailed;
        // Bytes already buffered by the inner reader don't touch the network.
        if (self.inner.bufferedLen() > 0) return self.inner.stream(w, limit);

        const Sel = Io.Select(union(enum) {
            read: Io.Reader.StreamError!usize,
            timeout: Io.Cancelable!void,
        });
        var buf: [2]Sel.Union = undefined;
        var sel: Sel = .init(self.io, &buf);
        sel.concurrent(.read, Io.Reader.stream, .{ self.inner, w, limit }) catch
            return self.inner.stream(w, limit); // no concurrency available: no timeout
        sel.concurrent(.timeout, Http.sleepMs, .{ self.io, self.ms }) catch {
            const u = sel.await() catch {
                drainIdle(&sel);
                return error.ReadFailed;
            };
            drainIdle(&sel);
            return u.read;
        };
        const first = sel.await() catch {
            drainIdle(&sel);
            return error.ReadFailed;
        };
        drainIdle(&sel);
        switch (first) {
            .read => |n| return n,
            .timeout => {
                self.timed_out = true;
                return error.ReadFailed;
            },
        }
    }

    fn drainIdle(sel: anytype) void {
        while (sel.cancel()) |_| {}
    }
};

/// Parse PEM certificates into the bundle (std only reads them from files).
fn addPem(cb: *std.crypto.Certificate.Bundle, gpa: Allocator, pem: []const u8, now_sec: i64) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start, begin_marker)) |b| {
        const cert_start = b + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse return error.MissingEndCertificateMarker;
        start = cert_end + end_marker.len;
        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const max_len = encoded.len / 4 * 3 + 3;
        try cb.bytes.ensureUnusedCapacity(gpa, max_len);
        const decoded_start: u32 = @intCast(cb.bytes.items.len);
        const dest = cb.bytes.allocatedSlice()[decoded_start..];
        const n = try base64.decode(dest, encoded);
        cb.bytes.items.len += n;
        try cb.parseCert(gpa, decoded_start, now_sec);
    }
}

test "idle timeout fails a stalled body read" {
    const Stall = struct {
        fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
            std.testing.io.sleep(.fromSeconds(30), .awake) catch return error.ReadFailed;
            return 0;
        }
    };
    var inner: Io.Reader = .{ .vtable = &.{ .stream = Stall.stream }, .buffer = &.{}, .seek = 0, .end = 0 };
    var buf: [64]u8 = undefined;
    var idle: IdleReader = .init(std.testing.io, &inner, 20, &buf);
    const t0 = Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(error.ReadFailed, idle.interface.takeByte());
    try std.testing.expect(idle.timed_out);
    const elapsed = t0.untilNow(std.testing.io);
    try std.testing.expect(elapsed.raw.toMilliseconds() < 5_000);
}

test "idle timeout passes data through" {
    var inner: Io.Reader = .fixed("data: hi\n\n");
    var buf: [4]u8 = undefined; // smaller than the data: several reads
    var idle: IdleReader = .init(std.testing.io, &inner, 1_000, &buf);
    var out: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    const n = try idle.interface.streamRemaining(&w);
    try std.testing.expectEqualStrings("data: hi\n\n", out[0..n]);
    try std.testing.expect(!idle.timed_out);
}

test "replay transport" {
    var rp: Replay = .init(std.testing.allocator, &.{
        .{ .url_suffix = "/v1/messages", .body = "hello" },
    });
    defer rp.deinit();
    var h: Http = .initReplay(std.testing.allocator, std.testing.io, &rp);
    defer h.deinit();
    const r = try h.post("https://api.anthropic.com/v1/messages", &.{}, "{}");
    defer r.close();
    const body = try r.readAll(std.testing.allocator, 100);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
    try std.testing.expectEqualStrings("{}", rp.requests.items[0]);
}
