//! A reusable tool package (PLAN.md §5.13). `SendEmail` works with any App
//! whose Ctx has a `mailer: *notify.Mailer` field; the App checks that at
//! comptime.

const std = @import("std");

pub const Mailer = struct {
    sent: std.atomic.Value(u32) = .init(0),
    from: []const u8 = "support@acme.example",

    pub fn send(m: *Mailer, to: []const u8, subject: []const u8, body: []const u8) void {
        _ = m.sent.fetchAdd(1, .monotonic);
        std.log.info("email from {s} to {s}: {s}\n{s}", .{ m.from, to, subject, body });
    }
};

pub const SendEmail = struct {
    pub const description = "Send an email to the customer.";
    pub const Input = struct {
        to: []const u8,
        subject: []const u8,
        body: []const u8,
        pub const constraints = .{ .subject = .{ .max_len = 120 } };
    };
    pub const Output = struct { sent: bool };
    pub const effects = .{ .network, .writes };

    /// Generic over the App's context: anything with `mailer: *Mailer`.
    pub const Requires = struct { mailer: *Mailer };

    pub fn execute(t: anytype, in: Input) !Output {
        t.require(.mailer).send(in.to, in.subject, in.body);
        return .{ .sent = true };
    }
};
