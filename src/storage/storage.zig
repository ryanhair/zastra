//! The storage interface (PLAN.md §6.9).
//!
//! The backend is chosen at comptime in `z.App(.{ .storage = ... })`, so only
//! that backend is compiled in. Inside the runtime it is reached through this
//! small vtable, because agent and workflow code is generic over the agent or
//! workflow, not over the App.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { memory, sqlite };

pub const RunRecord = struct {
    run_id: []const u8,
    workflow_id: []const u8,
    fingerprint: u64,
    status: []const u8,
    suspended_at: ?[]const u8,
    state_json: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const RunFilter = struct {
    workflow_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    limit: u32 = 100,
};

pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        appendMessages: *const fn (ptr: *anyopaque, thread: []const u8, resource: ?[]const u8, messages_json: []const []const u8, now: i64) anyerror!void,
        /// The last `limit` messages of `thread`, oldest first, as JSON.
        loadHistory: *const fn (ptr: *anyopaque, arena: Allocator, thread: []const u8, limit: u32) anyerror![]const []const u8,
        getWorkingMemory: *const fn (ptr: *anyopaque, arena: Allocator, resource: []const u8, agent_id: []const u8) anyerror!?WorkingMemory,
        putWorkingMemory: *const fn (ptr: *anyopaque, resource: []const u8, agent_id: []const u8, fingerprint: u64, value_json: []const u8, now: i64) anyerror!void,
        saveRun: *const fn (ptr: *anyopaque, run: RunRecord) anyerror!void,
        loadRun: *const fn (ptr: *anyopaque, arena: Allocator, run_id: []const u8) anyerror!?RunRecord,
        listRuns: *const fn (ptr: *anyopaque, arena: Allocator, filter: RunFilter) anyerror![]const RunRecord,
    };

    pub const WorkingMemory = struct { fingerprint: u64, value_json: []const u8 };

    pub fn appendMessages(s: Storage, thread: []const u8, resource: ?[]const u8, messages_json: []const []const u8, now: i64) !void {
        return s.vtable.appendMessages(s.ptr, thread, resource, messages_json, now);
    }
    pub fn loadHistory(s: Storage, arena: Allocator, thread: []const u8, limit: u32) ![]const []const u8 {
        return s.vtable.loadHistory(s.ptr, arena, thread, limit);
    }
    pub fn getWorkingMemory(s: Storage, arena: Allocator, resource: []const u8, agent_id: []const u8) !?WorkingMemory {
        return s.vtable.getWorkingMemory(s.ptr, arena, resource, agent_id);
    }
    pub fn putWorkingMemory(s: Storage, resource: []const u8, agent_id: []const u8, fingerprint: u64, value_json: []const u8, now: i64) !void {
        return s.vtable.putWorkingMemory(s.ptr, resource, agent_id, fingerprint, value_json, now);
    }
    pub fn saveRun(s: Storage, run: RunRecord) !void {
        return s.vtable.saveRun(s.ptr, run);
    }
    pub fn loadRun(s: Storage, arena: Allocator, run_id: []const u8) !?RunRecord {
        return s.vtable.loadRun(s.ptr, arena, run_id);
    }
    pub fn listRuns(s: Storage, arena: Allocator, filter: RunFilter) ![]const RunRecord {
        return s.vtable.listRuns(s.ptr, arena, filter);
    }

    /// Build a `Storage` from a backend type with matching methods.
    pub fn from(comptime B: type, b: *B) Storage {
        const gen = struct {
            const vtable: VTable = .{
                .appendMessages = appendMessagesImpl,
                .loadHistory = loadHistoryImpl,
                .getWorkingMemory = getWorkingMemoryImpl,
                .putWorkingMemory = putWorkingMemoryImpl,
                .saveRun = saveRunImpl,
                .loadRun = loadRunImpl,
                .listRuns = listRunsImpl,
            };
            fn cast(p: *anyopaque) *B {
                return @ptrCast(@alignCast(p));
            }
            fn appendMessagesImpl(p: *anyopaque, thread: []const u8, resource: ?[]const u8, m: []const []const u8, now: i64) anyerror!void {
                return cast(p).appendMessages(thread, resource, m, now);
            }
            fn loadHistoryImpl(p: *anyopaque, arena: Allocator, thread: []const u8, limit: u32) anyerror![]const []const u8 {
                return cast(p).loadHistory(arena, thread, limit);
            }
            fn getWorkingMemoryImpl(p: *anyopaque, arena: Allocator, resource: []const u8, agent_id: []const u8) anyerror!?WorkingMemory {
                return cast(p).getWorkingMemory(arena, resource, agent_id);
            }
            fn putWorkingMemoryImpl(p: *anyopaque, resource: []const u8, agent_id: []const u8, fp: u64, v: []const u8, now: i64) anyerror!void {
                return cast(p).putWorkingMemory(resource, agent_id, fp, v, now);
            }
            fn saveRunImpl(p: *anyopaque, run: RunRecord) anyerror!void {
                return cast(p).saveRun(run);
            }
            fn loadRunImpl(p: *anyopaque, arena: Allocator, run_id: []const u8) anyerror!?RunRecord {
                return cast(p).loadRun(arena, run_id);
            }
            fn listRunsImpl(p: *anyopaque, arena: Allocator, filter: RunFilter) anyerror![]const RunRecord {
                return cast(p).listRuns(arena, filter);
            }
        };
        return .{ .ptr = b, .vtable = &gen.vtable };
    }
};
