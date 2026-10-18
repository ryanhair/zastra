//! In-memory storage backend (`.storage = .memory`): tests, scripts, and
//! zero-C builds. Thread-safe; data lives until `deinit`.

const std = @import("std");
const storage = @import("storage.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const MemoryStore = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    threads: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    working: std.StringHashMapUnmanaged(storage.Storage.WorkingMemory) = .empty,
    runs: std.StringArrayHashMapUnmanaged(storage.RunRecord) = .empty,

    pub fn init(gpa: Allocator, io: Io) MemoryStore {
        return .{ .gpa = gpa, .io = io };
    }

    /// `App.init` entry point; the path is ignored.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) !MemoryStore {
        _ = path;
        return .init(gpa, io);
    }

    pub fn close(m: *MemoryStore) void {
        m.deinit();
    }

    pub fn deinit(m: *MemoryStore) void {
        var it = m.threads.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |row| m.gpa.free(row);
            e.value_ptr.deinit(m.gpa);
            m.gpa.free(e.key_ptr.*);
        }
        m.threads.deinit(m.gpa);
        var wit = m.working.iterator();
        while (wit.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            m.gpa.free(e.value_ptr.value_json);
        }
        m.working.deinit(m.gpa);
        for (m.runs.keys(), m.runs.values()) |k, r| {
            m.gpa.free(k);
            freeRun(m.gpa, r);
        }
        m.runs.deinit(m.gpa);
    }

    pub fn storageIface(m: *MemoryStore) storage.Storage {
        return .from(MemoryStore, m);
    }

    pub fn appendMessages(m: *MemoryStore, thread: []const u8, resource: ?[]const u8, rows: []const []const u8, now: i64) !void {
        _ = resource;
        _ = now;
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const gop = try m.threads.getOrPut(m.gpa, thread);
        if (!gop.found_existing) {
            gop.key_ptr.* = try m.gpa.dupe(u8, thread);
            gop.value_ptr.* = .empty;
        }
        for (rows) |r| try gop.value_ptr.append(m.gpa, try m.gpa.dupe(u8, r));
    }

    pub fn loadHistory(m: *MemoryStore, arena: Allocator, thread: []const u8, limit: u32) ![]const []const u8 {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const list = m.threads.get(thread) orelse return &.{};
        const start = list.items.len -| limit;
        const out = try arena.alloc([]const u8, list.items.len - start);
        for (list.items[start..], 0..) |r, i| out[i] = try arena.dupe(u8, r);
        return out;
    }

    fn wmKey(gpa: Allocator, resource: []const u8, agent_id: []const u8) ![]u8 {
        return gpa.print("{s}\x00{s}", .{ resource, agent_id });
    }

    pub fn getWorkingMemory(m: *MemoryStore, arena: Allocator, resource: []const u8, agent_id: []const u8) !?storage.Storage.WorkingMemory {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const key = try wmKey(arena, resource, agent_id);
        const v = m.working.get(key) orelse return null;
        return .{ .fingerprint = v.fingerprint, .value_json = try arena.dupe(u8, v.value_json) };
    }

    pub fn putWorkingMemory(m: *MemoryStore, resource: []const u8, agent_id: []const u8, fp: u64, value: []const u8, now: i64) !void {
        _ = now;
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const key = try wmKey(m.gpa, resource, agent_id);
        const gop = try m.working.getOrPut(m.gpa, key);
        if (gop.found_existing) {
            m.gpa.free(key);
            m.gpa.free(gop.value_ptr.value_json);
        }
        gop.value_ptr.* = .{ .fingerprint = fp, .value_json = try m.gpa.dupe(u8, value) };
    }

    fn dupeRun(gpa: Allocator, r: storage.RunRecord) !storage.RunRecord {
        return .{
            .run_id = try gpa.dupe(u8, r.run_id),
            .kind = r.kind,
            .owner_id = try gpa.dupe(u8, r.owner_id),
            .fingerprint = r.fingerprint,
            .status = try gpa.dupe(u8, r.status),
            .suspended_at = if (r.suspended_at) |s| try gpa.dupe(u8, s) else null,
            .state_json = try gpa.dupe(u8, r.state_json),
            .created_at = r.created_at,
            .updated_at = r.updated_at,
        };
    }

    fn freeRun(gpa: Allocator, r: storage.RunRecord) void {
        gpa.free(r.run_id);
        gpa.free(r.owner_id);
        gpa.free(r.status);
        if (r.suspended_at) |s| gpa.free(s);
        gpa.free(r.state_json);
    }

    pub fn saveRun(m: *MemoryStore, run: storage.RunRecord) !void {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const copy = try dupeRun(m.gpa, run);
        const gop = try m.runs.getOrPut(m.gpa, run.run_id);
        if (gop.found_existing) {
            const created = gop.value_ptr.created_at;
            freeRun(m.gpa, gop.value_ptr.*);
            gop.value_ptr.* = copy;
            gop.value_ptr.created_at = created;
        } else {
            gop.key_ptr.* = try m.gpa.dupe(u8, run.run_id);
            gop.value_ptr.* = copy;
        }
    }

    pub fn loadRun(m: *MemoryStore, arena: Allocator, run_id: []const u8) !?storage.RunRecord {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const r = m.runs.get(run_id) orelse return null;
        return try dupeRun(arena, r);
    }

    pub fn listRuns(m: *MemoryStore, arena: Allocator, filter: storage.RunFilter) ![]const storage.RunRecord {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        var out: std.ArrayList(storage.RunRecord) = .empty;
        for (m.runs.values()) |r| {
            if (filter.kind) |k| if (k != r.kind) continue;
            if (filter.owner_id) |w| if (!std.mem.eql(u8, w, r.owner_id)) continue;
            if (filter.status) |st| if (!std.mem.eql(u8, st, r.status)) continue;
            if (out.items.len >= filter.limit) break;
            try out.append(arena, try dupeRun(arena, r));
        }
        return out.items;
    }

    pub fn claimRun(m: *MemoryStore, run_id: []const u8, from: []const u8, to: []const u8, now: i64) !bool {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const r = m.runs.getPtr(run_id) orelse return false;
        if (!std.mem.eql(u8, r.status, from)) return false;
        const status = try m.gpa.dupe(u8, to);
        m.gpa.free(r.status);
        r.status = status;
        r.updated_at = now;
        return true;
    }
};

test MemoryStore {
    var m: MemoryStore = .init(std.testing.allocator, std.testing.io);
    defer m.deinit();
    const s = m.storageIface();
    try s.appendMessages("t1", null, &.{ "a", "b", "c" }, 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const h = try s.loadHistory(arena.allocator(), "t1", 2);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("b", h[0]);
    try s.putWorkingMemory("c1", "support", 7, "{}", 0);
    try s.putWorkingMemory("c1", "support", 7, "{\"x\":1}", 0);
    const w = (try s.getWorkingMemory(arena.allocator(), "c1", "support")).?;
    try std.testing.expectEqualStrings("{\"x\":1}", w.value_json);
}
