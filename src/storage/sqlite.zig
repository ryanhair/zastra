//! SQLite storage backend (`.storage = .sqlite`, PLAN.md §6.5, §6.9): the
//! vendored amalgamation, one connection per runtime in WAL mode, guarded by
//! a `std.Io.Mutex`. Migrations are embedded and applied at open.

const std = @import("std");
const storage = @import("storage.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

// ── the small slice of the SQLite C API zastra uses ─────────────────────────
const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
const Destructor = ?*const fn (?*anyopaque) callconv(.c) void;
extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(db: ?*sqlite3) c_int;
extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
extern fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;
extern fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*]const u8, n: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, i: c_int, text: [*]const u8, n: c_int, d: isize) c_int;
extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, i: c_int, v: i64) c_int;
extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, i: c_int) c_int;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, i: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, i: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, i: c_int) i64;
extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, i: c_int) c_int;
extern fn sqlite3_changes(db: ?*sqlite3) c_int;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_NULL = 5;
const SQLITE_OPEN_READWRITE = 0x2;
const SQLITE_OPEN_CREATE = 0x4;
const SQLITE_OPEN_FULLMUTEX = 0x10000;
const SQLITE_TRANSIENT: isize = -1;

const migrations = [_][]const u8{
    @embedFile("migrations/0001_init.sql"),
    @embedFile("migrations/0002_runs.sql"),
};

/// `CorruptSnapshot`: a saved run's status isn't one zastra writes.
pub const Error = error{ SqliteError, OutOfMemory, CorruptSnapshot };

pub const SqliteStore = struct {
    gpa: Allocator,
    io: Io,
    db: ?*sqlite3,
    mutex: Io.Mutex = .init,

    pub fn open(gpa: Allocator, io: Io, path: []const u8) Error!SqliteStore {
        const z_path = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z_path);
        var db: ?*sqlite3 = null;
        if (sqlite3_open_v2(z_path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null) != SQLITE_OK) {
            std.log.err("zastra: sqlite open '{s}': {s}", .{ path, sqlite3_errmsg(db) });
            _ = sqlite3_close_v2(db);
            return error.SqliteError;
        }
        var s: SqliteStore = .{ .gpa = gpa, .io = io, .db = db };
        errdefer s.close();
        _ = sqlite3_busy_timeout(db, 5000);
        try s.exec("PRAGMA journal_mode=WAL;");
        try s.exec("PRAGMA synchronous=NORMAL;");
        try s.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);");
        const current = try s.schemaVersion();
        for (migrations[@min(current, migrations.len)..], current..) |sql, i| {
            try s.exec("BEGIN;");
            errdefer s.exec("ROLLBACK;") catch {};
            const z = try gpa.dupeSentinel(u8, sql, 0);
            defer gpa.free(z);
            try s.exec(z);
            try s.exec("DELETE FROM schema_version;");
            var st = try s.prepare("INSERT INTO schema_version(version) VALUES (?1);");
            defer st.deinit();
            try st.int(1, @intCast(i + 1));
            try st.done();
            try s.exec("COMMIT;");
        }
        return s;
    }

    pub fn close(s: *SqliteStore) void {
        _ = sqlite3_close_v2(s.db);
        s.db = null;
    }

    pub fn storageIface(s: *SqliteStore) storage.Storage {
        return .from(SqliteStore, s);
    }

    fn exec(s: *SqliteStore, sql: [*:0]const u8) Error!void {
        if (sqlite3_exec(s.db, sql, null, null, null) != SQLITE_OK) {
            std.log.err("zastra: sqlite: {s}", .{sqlite3_errmsg(s.db)});
            return error.SqliteError;
        }
    }

    fn schemaVersion(s: *SqliteStore) Error!usize {
        var st = try s.prepare("SELECT version FROM schema_version LIMIT 1;");
        defer st.deinit();
        if (try st.row()) return @intCast(st.colInt(0));
        return 0;
    }

    const Stmt = struct {
        s: *SqliteStore,
        stmt: ?*sqlite3_stmt,

        fn deinit(st: *Stmt) void {
            _ = sqlite3_finalize(st.stmt);
        }
        fn text(st: *Stmt, i: c_int, v: []const u8) Error!void {
            if (sqlite3_bind_text(st.stmt, i, v.ptr, @intCast(v.len), SQLITE_TRANSIENT) != SQLITE_OK) return st.fail();
        }
        fn optText(st: *Stmt, i: c_int, v: ?[]const u8) Error!void {
            if (v) |x| return st.text(i, x);
            if (sqlite3_bind_null(st.stmt, i) != SQLITE_OK) return st.fail();
        }
        fn int(st: *Stmt, i: c_int, v: i64) Error!void {
            if (sqlite3_bind_int64(st.stmt, i, v) != SQLITE_OK) return st.fail();
        }
        fn row(st: *Stmt) Error!bool {
            return switch (sqlite3_step(st.stmt)) {
                SQLITE_ROW => true,
                SQLITE_DONE => false,
                else => st.fail(),
            };
        }
        fn done(st: *Stmt) Error!void {
            if (try st.row()) return;
        }
        fn colText(st: *Stmt, arena: Allocator, i: c_int) Error!?[]const u8 {
            if (sqlite3_column_type(st.stmt, i) == SQLITE_NULL) return null;
            const p = sqlite3_column_text(st.stmt, i) orelse return "";
            const n: usize = @intCast(sqlite3_column_bytes(st.stmt, i));
            return try arena.dupe(u8, p[0..n]);
        }
        fn colInt(st: *Stmt, i: c_int) i64 {
            return sqlite3_column_int64(st.stmt, i);
        }
        fn fail(st: *Stmt) Error {
            std.log.err("zastra: sqlite: {s}", .{sqlite3_errmsg(st.s.db)});
            return error.SqliteError;
        }
    };

    fn prepare(s: *SqliteStore, sql: []const u8) Error!Stmt {
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(s.db, sql.ptr, @intCast(sql.len), &stmt, null) != SQLITE_OK) {
            std.log.err("zastra: sqlite prepare: {s}", .{sqlite3_errmsg(s.db)});
            return error.SqliteError;
        }
        return .{ .s = s, .stmt = stmt };
    }

    fn lock(s: *SqliteStore) void {
        s.mutex.lockUncancelable(s.io);
    }
    fn unlock(s: *SqliteStore) void {
        s.mutex.unlock(s.io);
    }

    // ── Storage methods ──────────────────────────────────────────────────

    pub fn appendMessages(s: *SqliteStore, thread: []const u8, resource: ?[]const u8, rows: []const []const u8, now: i64) Error!void {
        s.lock();
        defer s.unlock();
        try s.exec("BEGIN IMMEDIATE;");
        errdefer s.exec("ROLLBACK;") catch {};
        {
            var st = try s.prepare("INSERT INTO threads(id, resource, created_at, updated_at) VALUES (?1, ?2, ?3, ?3) " ++
                "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, resource = COALESCE(excluded.resource, threads.resource);");
            defer st.deinit();
            try st.text(1, thread);
            try st.optText(2, resource);
            try st.int(3, now);
            try st.done();
        }
        var seq: i64 = 0;
        {
            var st = try s.prepare("SELECT COALESCE(MAX(seq), -1) FROM messages WHERE thread_id = ?1;");
            defer st.deinit();
            try st.text(1, thread);
            if (try st.row()) seq = st.colInt(0) + 1;
        }
        var ins = try s.prepare("INSERT INTO messages(thread_id, seq, role, content_json, created_at) VALUES (?1, ?2, ?3, ?4, ?5);");
        defer ins.deinit();
        for (rows) |r| {
            try ins.text(1, thread);
            try ins.int(2, seq);
            try ins.text(3, roleOf(r));
            try ins.text(4, r);
            try ins.int(5, now);
            try ins.done();
            _ = sqlite3_reset(ins.stmt);
            seq += 1;
        }
        try s.exec("COMMIT;");
    }

    /// Rows are message JSON; pull the role out for the column (diagnostics only).
    fn roleOf(row_json: []const u8) []const u8 {
        const key = "\"role\":\"";
        const i = std.mem.indexOf(u8, row_json, key) orelse return "";
        const rest = row_json[i + key.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
        return rest[0..end];
    }

    pub fn loadHistory(s: *SqliteStore, arena: Allocator, thread: []const u8, limit: u32) Error![]const []const u8 {
        s.lock();
        defer s.unlock();
        var st = try s.prepare("SELECT content_json FROM (SELECT content_json, seq FROM messages WHERE thread_id = ?1 ORDER BY seq DESC LIMIT ?2) ORDER BY seq ASC;");
        defer st.deinit();
        try st.text(1, thread);
        try st.int(2, limit);
        var out: std.ArrayList([]const u8) = .empty;
        while (try st.row()) try out.append(arena, (try st.colText(arena, 0)) orelse "");
        return out.items;
    }

    pub fn getWorkingMemory(s: *SqliteStore, arena: Allocator, resource: []const u8, agent_id: []const u8) Error!?storage.Storage.WorkingMemory {
        s.lock();
        defer s.unlock();
        var st = try s.prepare("SELECT value_json, fingerprint FROM working_memory WHERE resource = ?1 AND agent_id = ?2;");
        defer st.deinit();
        try st.text(1, resource);
        try st.text(2, agent_id);
        if (!try st.row()) return null;
        return .{ .value_json = (try st.colText(arena, 0)) orelse "{}", .fingerprint = @bitCast(st.colInt(1)) };
    }

    pub fn putWorkingMemory(s: *SqliteStore, resource: []const u8, agent_id: []const u8, fp: u64, value: []const u8, now: i64) Error!void {
        s.lock();
        defer s.unlock();
        var st = try s.prepare("INSERT INTO working_memory(resource, agent_id, value_json, fingerprint, updated_at) VALUES (?1, ?2, ?3, ?4, ?5) " ++
            "ON CONFLICT(resource, agent_id) DO UPDATE SET value_json = excluded.value_json, fingerprint = excluded.fingerprint, updated_at = excluded.updated_at;");
        defer st.deinit();
        try st.text(1, resource);
        try st.text(2, agent_id);
        try st.text(3, value);
        try st.int(4, @bitCast(fp));
        try st.int(5, now);
        try st.done();
    }

    pub fn saveRun(s: *SqliteStore, r: storage.RunRecord) Error!void {
        s.lock();
        defer s.unlock();
        var st = try s.prepare("INSERT INTO runs(run_id, owner_id, fingerprint, status, suspended_at, state_json, created_at, updated_at, kind) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) ON CONFLICT(run_id) DO UPDATE SET fingerprint = excluded.fingerprint, status = excluded.status, " ++
            "suspended_at = excluded.suspended_at, state_json = excluded.state_json, updated_at = excluded.updated_at;");
        defer st.deinit();
        try st.text(1, r.run_id);
        try st.text(2, r.owner_id);
        try st.int(3, @bitCast(r.fingerprint));
        try st.text(4, @tagName(r.status));
        try st.optText(5, r.suspended_at);
        try st.text(6, r.state_json);
        try st.int(7, r.created_at);
        try st.int(8, r.updated_at);
        try st.text(9, @tagName(r.kind));
        try st.done();
    }

    fn readRun(st: *Stmt, arena: Allocator) Error!storage.RunRecord {
        return .{
            .run_id = (try st.colText(arena, 0)) orelse "",
            .owner_id = (try st.colText(arena, 1)) orelse "",
            .kind = std.meta.stringToEnum(storage.RunKind, (try st.colText(arena, 8)) orelse "") orelse .workflow,
            .fingerprint = @bitCast(st.colInt(2)),
            .status = std.meta.stringToEnum(storage.RunStatus, (try st.colText(arena, 3)) orelse "") orelse return error.CorruptSnapshot,
            .suspended_at = try st.colText(arena, 4),
            .state_json = (try st.colText(arena, 5)) orelse "",
            .created_at = st.colInt(6),
            .updated_at = st.colInt(7),
        };
    }

    const run_cols = "run_id, owner_id, fingerprint, status, suspended_at, state_json, created_at, updated_at, kind";

    pub fn loadRun(s: *SqliteStore, arena: Allocator, run_id: []const u8) Error!?storage.RunRecord {
        s.lock();
        defer s.unlock();
        var st = try s.prepare("SELECT " ++ run_cols ++ " FROM runs WHERE run_id = ?1;");
        defer st.deinit();
        try st.text(1, run_id);
        if (!try st.row()) return null;
        return try readRun(&st, arena);
    }

    pub fn listRuns(s: *SqliteStore, arena: Allocator, filter: storage.RunFilter) Error![]const storage.RunRecord {
        s.lock();
        defer s.unlock();
        var st = try s.prepare("SELECT " ++ run_cols ++ " FROM runs WHERE (?1 IS NULL OR owner_id = ?1) AND (?2 IS NULL OR status = ?2) AND (?4 IS NULL OR kind = ?4) ORDER BY updated_at DESC LIMIT ?3;");
        defer st.deinit();
        try st.optText(1, filter.owner_id);
        try st.optText(2, if (filter.status) |x| @tagName(x) else null);
        try st.int(3, filter.limit);
        try st.optText(4, if (filter.kind) |k| @tagName(k) else null);
        var out: std.ArrayList(storage.RunRecord) = .empty;
        while (try st.row()) try out.append(arena, try readRun(&st, arena));
        return out.items;
    }

    pub fn claimRun(s: *SqliteStore, run_id: []const u8, from: storage.RunStatus, to: storage.RunStatus, now: i64) Error!bool {
        s.lock();
        defer s.unlock();
        var st = try s.prepare("UPDATE runs SET status = ?3, updated_at = ?4 WHERE run_id = ?1 AND status = ?2;");
        defer st.deinit();
        try st.text(1, run_id);
        try st.text(2, @tagName(from));
        try st.text(3, @tagName(to));
        try st.int(4, now);
        try st.done();
        return sqlite3_changes(s.db) == 1;
    }
};

test SqliteStore {
    var s = try SqliteStore.open(std.testing.allocator, std.testing.io, ":memory:");
    defer s.close();
    const iface = s.storageIface();
    try iface.appendMessages("t1", "c1", &.{ "{\"role\":\"user\"}", "{\"role\":\"assistant\"}", "{\"role\":\"user\",\"n\":3}" }, 1);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const h = try iface.loadHistory(arena.allocator(), "t1", 2);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("{\"role\":\"user\",\"n\":3}", h[1]);
    try iface.putWorkingMemory("c1", "a", 42, "{\"x\":1}", 1);
    try iface.putWorkingMemory("c1", "a", 43, "{\"x\":2}", 2);
    const w = (try iface.getWorkingMemory(arena.allocator(), "c1", "a")).?;
    try std.testing.expectEqual(@as(u64, 43), w.fingerprint);
    try iface.saveRun(.{ .run_id = "r1", .kind = .workflow, .owner_id = "w", .fingerprint = 0xFFFF_FFFF_FFFF_FFFF, .status = .suspended, .suspended_at = "s", .state_json = "{}", .created_at = 1, .updated_at = 1 });
    const r = (try iface.loadRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), r.fingerprint);
    const runs = try iface.listRuns(arena.allocator(), .{ .status = .suspended });
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqual(storage.RunKind.workflow, runs[0].kind);
    try std.testing.expectEqual(@as(usize, 0), (try iface.listRuns(arena.allocator(), .{ .kind = .agent })).len);
    // claimRun is a compare-and-set on the status.
    try std.testing.expect(try iface.claimRun("r1", .suspended, .running, 2));
    try std.testing.expect(!try iface.claimRun("r1", .suspended, .running, 3));
    try std.testing.expect(!try iface.claimRun("nope", .suspended, .running, 3));
}

test "migration 0002 renames workflow_runs and keeps v1 rows" {
    var s = try SqliteStore.open(std.testing.allocator, std.testing.io, ":memory:");
    defer s.close();
    // Rebuild the v1 shape with a row in it, then re-run 0002.
    try s.exec("DROP TABLE runs;");
    try s.exec("CREATE TABLE workflow_runs (run_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, fingerprint INTEGER NOT NULL, status TEXT NOT NULL, " ++
        "suspended_at TEXT, state_json TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);");
    try s.exec("INSERT INTO workflow_runs VALUES ('r0','handle_ticket',1,'suspended','approve','{}',1,1);");
    try s.exec(@embedFile("migrations/0002_runs.sql"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = (try s.storageIface().loadRun(arena.allocator(), "r0")).?;
    try std.testing.expectEqual(storage.RunKind.workflow, r.kind);
    try std.testing.expectEqualStrings("handle_ticket", r.owner_id);
}
