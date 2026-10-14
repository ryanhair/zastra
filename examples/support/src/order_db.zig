//! The example's order store: an in-memory table seeded with a few orders.
//! Thread-safe, since tools in one step may run concurrently.

const std = @import("std");
const Order = @import("app.zig").Order;

pub const OrderDb = struct {
    orders: []const Order,
    refunds: std.ArrayList(Refund) = .empty,
    gpa: ?std.mem.Allocator = null,
    io: ?std.Io = null,
    mutex: std.Io.Mutex = .init,

    const Refund = struct { key: []const u8, order_id: []const u8, amount_cents: u32 };

    pub const seed = [_]Order{
        .{ .id = "ORD-1042", .status = .delivered, .total_cents = 129_00, .items = &.{.{ .sku = "BLENDER-X2", .qty = 1 }} },
        .{ .id = "ORD-1043", .status = .shipped, .total_cents = 24_50, .items = &.{.{ .sku = "SPATULA-SET", .qty = 2 }} },
        .{ .id = "ORD-1044", .status = .pending, .total_cents = 45_00, .items = &.{.{ .sku = "KNIFE-8IN", .qty = 1 }} },
    };

    /// Open the store. The example keeps orders in memory; `path` is where a
    /// real app would point at its database.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !OrderDb {
        _ = path;
        return .{ .orders = &seed, .gpa = gpa, .io = io };
    }

    /// For tests.
    pub fn fake(orders: []const Order) OrderDb {
        return .{ .orders = orders };
    }

    pub fn close(db: *OrderDb) void {
        if (db.gpa) |gpa| {
            for (db.refunds.items) |r| {
                gpa.free(r.key);
                gpa.free(r.order_id);
            }
            db.refunds.deinit(gpa);
        }
    }

    fn lock(db: *OrderDb) void {
        if (db.io) |io| db.mutex.lockUncancelable(io);
    }
    fn unlock(db: *OrderDb) void {
        if (db.io) |io| db.mutex.unlock(io);
    }

    pub fn findOrder(db: *OrderDb, arena: std.mem.Allocator, id: []const u8) !?Order {
        _ = arena;
        for (db.orders) |o| if (std.ascii.eqlIgnoreCase(o.id, id)) return o;
        return null;
    }

    /// Issue a refund; returns the refund id.
    pub fn refund(db: *OrderDb, arena: std.mem.Allocator, order_id: []const u8, amount_cents: u32) ![]const u8 {
        return db.refundOnce(arena, "", order_id, amount_cents);
    }

    /// Idempotent refund: a second call with the same key is a no-op
    /// (workflow steps run at least once, PLAN.md D16).
    pub fn refundOnce(db: *OrderDb, arena: std.mem.Allocator, key: []const u8, order_id: []const u8, amount_cents: u32) ![]const u8 {
        db.lock();
        defer db.unlock();
        if (key.len > 0) for (db.refunds.items, 0..) |r, i| if (std.mem.eql(u8, r.key, key))
            return std.fmt.allocPrint(arena, "RF-{d}", .{i + 1});
        const gpa = db.gpa orelse std.heap.page_allocator;
        try db.refunds.append(gpa, .{ .key = try gpa.dupe(u8, key), .order_id = try gpa.dupe(u8, order_id), .amount_cents = amount_cents });
        return std.fmt.allocPrint(arena, "RF-{d}", .{db.refunds.items.len});
    }

    pub fn refundCount(db: *OrderDb) usize {
        return db.refunds.items.len;
    }
};
