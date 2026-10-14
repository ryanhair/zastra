//! `rt.model("provider/id")`: the raw model escape hatch (PLAN.md §3.1).
//! Same provider layer as agents, no tools or memory.

const std = @import("std");
const catalog = @import("catalog/catalog.zig");
const provider = @import("provider/provider.zig");
const runtime = @import("runtime.zig");
const msg = @import("message.zig");
const Allocator = std.mem.Allocator;

pub fn Model(comptime spec: catalog.Spec) type {
    const Impl = provider.Impl(spec.api);
    const prefix = Impl.buildPrefix(.{ .spec = spec });

    return struct {
        const Self = @This();
        st: *runtime.State,

        pub const Options = struct {
            max_tokens: u32 = @min(4096, spec.max_output),
            /// Extra system text (in addition to leading system messages).
            system: ?[]const u8 = null,
        };

        pub const Result = struct {
            text: []const u8,
            message: msg.Message,
            usage: msg.Usage,
            finish_reason: msg.FinishReason,
        };

        pub const Stream = struct {
            inner: Impl.Stream,
            diag: provider.Diagnostic = .{},
            st: *runtime.State,

            /// Deltas, then one `.finish`. Delta slices are valid until the next call.
            pub fn next(s: *Stream) provider.Error!?provider.Event {
                return s.inner.next() catch |err| {
                    s.st.setDiag(&s.diag);
                    return err;
                };
            }

            pub fn deinit(s: *Stream) void {
                s.inner.close();
            }
        };

        pub fn stream(m: Self, arena: Allocator, messages: []const msg.Message, opts: Options) (provider.Error || error{MissingApiKey})!*Stream {
            const s = try arena.create(Stream);
            s.* = .{ .inner = undefined, .st = m.st };
            const key = m.st.apiKey(spec);
            if (spec.api_key_env != null and key == null and !m.st.tag_requests) {
                s.diag.print(0, "{s} is not set (needed for model {s})", .{ spec.api_key_env.?, comptime spec.fullName() });
                m.st.setDiag(&s.diag);
                return error.MissingApiKey;
            }
            s.inner = Impl.Stream.open(arena, &m.st.http, .{
                .base_url = m.st.baseUrl(spec),
                .api_key = key,
                .prefix = prefix,
                .system_suffix = opts.system,
                .messages = messages,
                .max_tokens = opts.max_tokens,
                .max_tokens_field = spec.max_tokens_field,
                .headers = spec.headers,
                .diag = &s.diag,
            }) catch |err| {
                m.st.setDiag(&s.diag);
                return err;
            };
            return s;
        }

        pub fn generate(m: Self, arena: Allocator, messages: []const msg.Message, opts: Options) (provider.Error || error{MissingApiKey})!Result {
            const s = try m.stream(arena, messages, opts);
            defer s.deinit();
            while (try s.next()) |e| switch (e) {
                .delta => {},
                .finish => |f| {
                    var usage = f.usage;
                    usage.cost_usd = spec.costUsd(usage);
                    return .{ .text = try f.message.allText(arena), .message = f.message, .usage = usage, .finish_reason = f.reason };
                },
            };
            return error.StreamInterrupted;
        }
    };
}
