//! Working-memory migrations (PLAN.md §18.2, D48).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Ctx = struct {};

const NotesV1 = struct { name: ?[]const u8 = null, contact: ?[]const u8 = null };
const NotesV2 = struct { first: ?[]const u8 = null, last: ?[]const u8 = null, contact: ?[]const u8 = null };
const Notes = struct {
    first: ?[]const u8 = null,
    last: ?[]const u8 = null,
    preferred_contact: ?Contact = null,

    pub const Contact = enum { email, sms };
    pub const migrations = .{ z.migrate(NotesV1, fromV1), z.migrate(NotesV2, fromV2) };

    fn fromV1(_: std.mem.Allocator, old: NotesV1) !NotesV2 {
        const name = old.name orelse return .{ .contact = old.contact };
        const sp = std.mem.indexOfScalar(u8, name, ' ') orelse return .{ .first = name, .contact = old.contact };
        return .{ .first = name[0..sp], .last = name[sp + 1 ..], .contact = old.contact };
    }
    fn fromV2(_: std.mem.Allocator, old: NotesV2) !Notes {
        const c = old.contact orelse return .{ .first = old.first, .last = old.last };
        const contact = std.meta.stringToEnum(Contact, c) orelse return error.UnknownContact;
        return .{ .first = old.first, .last = old.last, .preferred_contact = contact };
    }
};

const Ping = struct {
    pub const description = "Ping someone.";
    pub const Input = struct { who: []const u8 };
    pub const Output = struct { ok: bool };
    pub const needs_approval = true;
    pub fn execute(_: *z.ToolCtx(Ctx), _: Input) !Output {
        return .{ .ok = true };
    }
};

fn Keeper(comptime W: type) type {
    return z.Agent(Ctx, .{
        .name = "keeper",
        .model = "anthropic/claude-sonnet-4-6",
        .instructions = "You remember customers.",
        .tools = .{Ping},
        .memory = .{ .working = W },
    });
}
const KeeperV1 = Keeper(NotesV1);
const KeeperV3 = Keeper(Notes);

const MemApp = z.App(.{ .ctx = Ctx, .agents = .{KeeperV3} });
const SqlApp = z.App(.{ .ctx = Ctx, .agents = .{KeeperV3}, .storage = .sqlite });
const SqlAppV1 = z.App(.{ .ctx = Ctx, .agents = .{KeeperV1}, .storage = .sqlite });

fn tmpDb(buf: []u8, name: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrint(buf, ".zig-cache/tmp/zastra-{s}-{d}.sqlite", .{ name, std.Io.Clock.real.now(t.io).nanoseconds });
    std.Io.Dir.cwd().createDirPath(t.io, ".zig-cache/tmp") catch {};
    return path;
}

fn cleanup(path: []const u8) void {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "", "-wal", "-shm" }) |sfx| {
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, sfx }) catch continue;
        std.Io.Dir.cwd().deleteFile(t.io, p) catch {};
    }
}

fn expectMigrates(comptime AppT: type, storage_path: []const u8) !void {
    var ctx: Ctx = .{};
    var h = try z.testing.harness(AppT, .{ .ctx = &ctx, .storage_path = storage_path });
    defer h.deinit();
    const store = h.rt.state().storage.?;
    const a = h.arena.allocator();

    // A V1 value goes through both steps and is saved back as V3.
    try store.putWorkingMemory("c1", "keeper", KeeperV1.working_fingerprint, "{\"name\":\"Ada Lovelace\",\"contact\":\"sms\"}", 1);
    h.script(KeeperV3, &.{.text("Hi Ada.")});
    _ = try h.agent(KeeperV3).generate("Hello", .{ .resource = "c1" });
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "\\\"first\\\":\\\"Ada\\\",\\\"last\\\":\\\"Lovelace\\\",\\\"preferred_contact\\\":\\\"sms\\\"") != null);
    const saved = (try store.getWorkingMemory(a, "c1", "keeper")).?;
    try t.expectEqual(KeeperV3.working_fingerprint, saved.fingerprint);
    try t.expect(std.mem.indexOf(u8, saved.value_json, "\"last\":\"Lovelace\"") != null);

    // A V2 value starts partway along the chain.
    try store.putWorkingMemory("c2", "keeper", comptime z.migrate(NotesV2, Notes.fromV2).from_fingerprint, "{\"first\":\"Grace\",\"contact\":\"email\"}", 1);
    h.script(KeeperV3, &.{.text("Hi Grace.")});
    _ = try h.agent(KeeperV3).generate("Hello", .{ .resource = "c2" });
    try t.expectEqual(KeeperV3.working_fingerprint, (try store.getWorkingMemory(a, "c2", "keeper")).?.fingerprint);

    // A migration that fails fails the run, and the stored value is untouched.
    try store.putWorkingMemory("c3", "keeper", KeeperV1.working_fingerprint, "{\"name\":\"Bo\",\"contact\":\"pigeon\"}", 1);
    try t.expectError(error.MigrationFailed, h.agent(KeeperV3).generate("Hello", .{ .resource = "c3" }));
    try t.expect(std.mem.indexOf(u8, h.rt.lastDiagnostic(), "UnknownContact") != null);
    try t.expectEqual(KeeperV1.working_fingerprint, (try store.getWorkingMemory(a, "c3", "keeper")).?.fingerprint);

    // No migration covers the shape: defaults, with a warning.
    t.log_level = .err;
    defer t.log_level = .warn;
    try store.putWorkingMemory("c4", "keeper", 42, "{\"whatever\":1}", 1);
    h.script(KeeperV3, &.{.text("Hello stranger.")});
    _ = try h.agent(KeeperV3).generate("Hello", .{ .resource = "c4" });
    try t.expectEqual(@as(usize, 0), h.remaining(KeeperV3));
}

test "working memory: values migrate through the chain (memory storage)" {
    try expectMigrates(MemApp, ":memory:");
}

test "working memory: values migrate through the chain (sqlite)" {
    var buf: [256]u8 = undefined;
    const path = try tmpDb(&buf, "wm-migrate");
    defer cleanup(path);
    try expectMigrates(SqlApp, path);
}

test "working memory: a run suspended under V1 resumes under V3" {
    var buf: [256]u8 = undefined;
    const path = try tmpDb(&buf, "wm-resume");
    defer cleanup(path);
    var ctx: Ctx = .{};
    var run_id_buf: [64]u8 = undefined;
    var req_id_buf: [64]u8 = undefined;
    var run_id: []const u8 = "";
    var req_id: []const u8 = "";
    {
        var h = try z.testing.harness(SqlAppV1, .{ .ctx = &ctx, .storage_path = path });
        defer h.deinit();
        try h.rt.state().storage.?.putWorkingMemory("c1", "keeper", KeeperV1.working_fingerprint, "{\"name\":\"Ada Lovelace\",\"contact\":\"email\"}", 1);
        h.script(KeeperV1, &.{.tool(Ping, .{ .who = "Ada" })});
        const s = (try h.agent(KeeperV1).generate("Ping Ada", .{ .resource = "c1" })).suspended;
        run_id = try std.fmt.bufPrint(&run_id_buf, "{s}", .{s.run_id});
        req_id = try std.fmt.bufPrint(&req_id_buf, "{s}", .{s.requests[0].id});
    }
    var h = try z.testing.harness(SqlApp, .{ .ctx = &ctx, .storage_path = path });
    defer h.deinit();
    h.script(KeeperV3, &.{.text("Pinged.")});
    const r = try h.agent(KeeperV3).resumeRun(run_id, &.{.{ .id = req_id, .decision = .approve }});
    try t.expectEqualStrings("Pinged.", r.completed.text);
    // The continued request carries the migrated value.
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "\\\"preferred_contact\\\":\\\"email\\\"") != null);
}
