//! Agents end to end against scripted models (PLAN.md §6.4, §10).

const std = @import("std");
const z = @import("zastra");
const t = std.testing;

const Db = struct {
    refunds: std.atomic.Value(u32) = .init(0),
    lookups: std.atomic.Value(u32) = .init(0),
};
const Ctx = struct { db: *Db, auto_refund_limit_cents: u32 = 50_00 };

const Order = struct { id: []const u8, total_cents: u32 };

const LookupOrder = struct {
    pub const description = "Look up an order by its ID.";
    pub const Input = struct { order_id: []const u8 };
    pub const Output = Order;
    pub const ModelErrors = error{OrderNotFound};
    pub const error_messages = .{ .OrderNotFound = "No order exists with that ID." };

    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        _ = tc.ctx.db.lookups.fetchAdd(1, .monotonic);
        if (!std.mem.startsWith(u8, in.order_id, "ORD-")) return error.OrderNotFound;
        return .{ .id = try tc.arena.dupe(u8, in.order_id), .total_cents = 90_00 };
    }
};

const IssueRefund = struct {
    pub const description = "Refund all or part of an order.";
    pub const Input = struct { order_id: []const u8, amount_cents: u32 };
    pub const Output = struct { refund_id: []const u8 };

    pub fn needsApproval(tc: *z.ToolCtx(Ctx), in: Input) bool {
        return in.amount_cents > tc.ctx.auto_refund_limit_cents;
    }

    pub fn execute(tc: *z.ToolCtx(Ctx), in: Input) !Output {
        _ = in;
        _ = tc.ctx.db.refunds.fetchAdd(1, .monotonic);
        return .{ .refund_id = "R-1" };
    }
};

const Triage = struct {
    category: enum { refund, shipping, other },
    urgency: u8,
    summary: []const u8,
    pub const constraints = .{ .urgency = .{ .min = 1, .max = 5 } };
};

const Notes = struct { name: ?[]const u8 = null, open_issues: []const []const u8 = &.{} };

const Support = z.Agent(Ctx, .{
    .name = "support",
    .model = "anthropic/claude-sonnet-5-5",
    .instructions = "You are a support agent.",
    .tools = .{ LookupOrder, IssueRefund },
    .memory = .{ .history = .{ .last_messages = 30 }, .working = Notes },
});

const TriageAgent = z.Agent(Ctx, .{
    .name = "triage",
    .model = "openai/gpt-5-mini",
    .instructions = "Classify the ticket.",
    .output = Triage,
    .examples = &.{.{ .in = "Where is my parcel?", .out = Triage{ .category = .shipping, .urgency = 2, .summary = "Parcel status" } }},
});

/// No native structured output on this model: the final_answer tool is used.
const TriageFallback = z.Agent(Ctx, .{
    .name = "triage_fallback",
    .model = z.custom(.{ .provider = .anthropic, .id = "claude-legacy", .supports = .{ .structured_output = false } }),
    .output = Triage,
});

/// Reasoning shown as `.reasoning_delta` events (PLAN.md D37).
const Thinker = z.Agent(Ctx, .{ .name = "thinker", .model = "anthropic/claude-sonnet-4-6", .reasoning = .on, .show_reasoning = true, .tools = .{LookupOrder} });
/// Reasoning on but not shown: no `.reasoning_delta` in the event union.
const QuietThinker = z.Agent(Ctx, .{ .name = "quiet_thinker", .model = "anthropic/claude-sonnet-4-6", .reasoning = .on, .tools = .{LookupOrder} });
const Budgeted = z.Agent(Ctx, .{ .name = "budgeted", .model = "anthropic/claude-sonnet-4-6", .reasoning = .{ .budget = 4_000 } });

/// OpenAI Responses: reasoning summaries shown, encrypted reasoning round-trips (D35, D36).
const OaiThinker = z.Agent(Ctx, .{
    .name = "oai_thinker",
    .model = "openai/gpt-5.4-mini",
    .reasoning = .on,
    .show_reasoning = true,
    .tools = .{LookupOrder},
    .memory = .{ .history = .{ .last_messages = 20 } },
});

const App = z.App(.{ .ctx = Ctx, .agents = .{ Support, TriageAgent, TriageFallback, Thinker, QuietThinker, Budgeted, OaiThinker } });

test "tool loop: call, result, answer" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Support, &.{
        .tool(LookupOrder, .{ .order_id = "ORD-1" }),
        .text("Your order ORD-1 is $90."),
    });
    const r = (try h.agent(Support).generate("Where's ORD-1?", .{ .include_messages = true })).completed;
    try t.expectEqualStrings("Your order ORD-1 is $90.", r.text);
    try t.expectEqual(@as(u32, 2), r.steps);
    try t.expectEqual(@as(u32, 1), db.lookups.load(.monotonic));
    // user, assistant(tool_use), tool(result), assistant(text)
    try t.expectEqual(@as(usize, 4), r.messages.len);
    try t.expectEqualStrings("{\"id\":\"ORD-1\",\"total_cents\":9000}", r.messages[2].content.blocks[0].tool_result.content);
    try t.expect(r.usage.cost_usd > 0);
}

test "ModelErrors go back to the model; the run continues" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Support, &.{
        .tool(LookupOrder, .{ .order_id = "nope" }),
        .text("I couldn't find that order."),
    });
    const r = (try h.agent(Support).generate("Where's nope?", .{ .include_messages = true })).completed;
    const res = r.messages[2].content.blocks[0].tool_result;
    try t.expect(res.is_error);
    try t.expectEqualStrings("No order exists with that ID.", res.content);
    // The error result reached the provider as an is_error tool_result.
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "\"is_error\":true") != null);
}

test "streaming: exhaustive events, typed tool calls and approvals" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Support, &.{
        .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 }),
        .text("Refunded."),
    });
    var stream = try h.agent(Support).stream("Refund ORD-1", .{});
    defer stream.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(t.allocator);
    var approvals: u32 = 0;
    var calls: u32 = 0;
    var finished = false;
    while (try stream.next()) |event| switch (event) {
        .text_delta => |d| try text.appendSlice(t.allocator, d),
        .tool_call => |call| switch (call) {
            .lookup_order => {},
            .issue_refund => |in| {
                try t.expectEqual(@as(u32, 90_00), in.amount_cents);
                calls += 1;
            },
        },
        .tool_result => |r| try t.expectEqualStrings("issue_refund", r.name()),
        .approval_request => |req| switch (req.call) {
            .issue_refund => |in| {
                try t.expectEqualStrings("ORD-1", in.order_id);
                approvals += 1;
                // Not responding yet: next() refuses to continue.
                try t.expectError(error.ApprovalPending, stream.next());
                try stream.respond(req.id, .approve);
            },
        },
        .step_finish => {},
        .finish => |f| {
            try t.expectEqual(z.FinishReason.end_turn, f.reason);
            finished = true;
        },
    };
    try t.expect(finished);
    try t.expectEqual(@as(u32, 1), approvals);
    try t.expectEqual(@as(u32, 1), calls);
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
    try t.expectEqualStrings("Refunded.", text.items);
}

test "denied approvals are reported to the model; on_approval decides inline" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();

    h.script(Support, &.{
        .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 90_00 }),
        .text("I can't refund that."),
    });
    const Deny = struct {
        fn decide(_: ?*anyopaque, call: Support.ApprovalCall) z.Decision {
            _ = call;
            return .{ .deny = "Over limit" };
        }
    };
    const r = (try h.agent(Support).generate("Refund", .{ .on_approval = .{ .decide = Deny.decide } })).completed;
    try t.expectEqualStrings("I can't refund that.", r.text);
    try t.expectEqual(@as(u32, 0), db.refunds.load(.monotonic));
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "The user denied this tool call: Over limit") != null);
}

test "small refunds skip approval" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Support, &.{
        .tool(IssueRefund, .{ .order_id = "ORD-1", .amount_cents = 10_00 }),
        .text("Done."),
    });
    _ = try h.agent(Support).generate("Refund $10", .{});
    try t.expectEqual(@as(u32, 1), db.refunds.load(.monotonic));
}

test "parallel tool calls in one turn" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Support, &.{
        .tools(&.{ .{ .lookup_order = .{ .order_id = "ORD-1" } }, .{ .lookup_order = .{ .order_id = "ORD-2" } }, .{ .lookup_order = .{ .order_id = "ORD-3" } } }),
        .text("Found all three."),
    });
    const r = (try h.agent(Support).generate("Look up three orders", .{ .include_messages = true })).completed;
    try t.expectEqual(@as(u32, 3), db.lookups.load(.monotonic));
    // All results go back in one message, in call order.
    const results = r.messages[2].content.blocks;
    try t.expectEqual(@as(usize, 3), results.len);
    try t.expect(std.mem.indexOf(u8, results[2].tool_result.content, "ORD-3") != null);
}

test "structured output: native, with one repair attempt" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(TriageAgent, &.{.output(.{ .category = .refund, .urgency = 4, .summary = "Broken item" })});
    const r = try h.agent(TriageAgent).generate("My order arrived smashed", .{});
    try t.expectEqual(.refund, r.output.category);
    try t.expectEqual(@as(u8, 4), r.output.urgency);
    // The schema went out as the Responses text format, and the example is in the instructions.
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "\"text\":{\"format\":{\"type\":\"json_schema\"") != null);
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "Output: {\\\"category\\\":\\\"shipping\\\"") != null);

    // Invalid, then valid after the repair message.
    h.script(TriageAgent, &.{
        .raw("{\"category\":\"refund\",\"urgency\":9,\"summary\":\"x\"}"),
        .output(.{ .category = .refund, .urgency = 5, .summary = "x" }),
    });
    const r2 = try h.agent(TriageAgent).generate("Help!", .{});
    try t.expectEqual(@as(u8, 5), r2.output.urgency);
    try t.expect(std.mem.indexOf(u8, h.requests()[2], "$.urgency: must be at most 5, got 9") != null);

    // Invalid twice: OutputInvalid with the raw text in the diagnostic.
    h.script(TriageAgent, &.{ .raw("not json"), .raw("still not json") });
    try t.expectError(error.OutputInvalid, h.agent(TriageAgent).generate("?", .{}));
    try t.expect(std.mem.indexOf(u8, h.rt.lastDiagnostic(), "still not json") != null);
}

test "structured output: final_answer tool fallback" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(TriageFallback, &.{.output(.{ .category = .other, .urgency = 1, .summary = "Question" })});
    const r = try h.agent(TriageFallback).generate("What are your hours?", .{});
    try t.expectEqual(.other, r.output.category);
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "\"name\":\"final_answer\"") != null);
}

test "memory: history across runs and typed working memory" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    const NotesPatch = z.Partial(Notes);
    _ = NotesPatch;
    h.script(Support, &.{.text("Hi Ada!")});
    _ = try h.agent(Support).generate("I'm Ada", .{ .thread = "t1", .resource = "c1" });
    h.script(Support, &.{.text("You said you're Ada.")});
    _ = try h.agent(Support).generate("What's my name?", .{ .thread = "t1", .resource = "c1" });
    // The second request carries the first exchange.
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "I'm Ada") != null);
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "Hi Ada!") != null);
    // A different thread doesn't.
    h.script(Support, &.{.text("Hello.")});
    _ = try h.agent(Support).generate("Hi", .{ .thread = "t2", .resource = "c1" });
    try t.expect(std.mem.indexOf(u8, h.requests()[2], "I'm Ada") == null);
}

test "prefix is byte-identical across calls" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Support, &.{ .text("a"), .text("b") });
    _ = try h.agent(Support).generate("one", .{});
    _ = try h.agent(Support).generate("two", .{});
    try t.expect(std.mem.startsWith(u8, h.requests()[0], Support.prefix.json));
    try t.expect(std.mem.startsWith(u8, h.requests()[1], Support.prefix.json));
}

test "working memory: the update tool merges and persists per resource" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Support, &.{
        .call("update_working_memory", "{\"name\":\"Ada\"}"),
        .text("Nice to meet you, Ada."),
    });
    _ = try h.agent(Support).generate("I'm Ada", .{ .resource = "c1" });
    // The working-memory tool is offered with a Partial(Notes) schema.
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "\"name\":\"update_working_memory\"") != null);

    h.script(Support, &.{
        .call("update_working_memory", "{\"open_issues\":[\"late parcel\"]}"),
        .text("Noted."),
    });
    _ = try h.agent(Support).generate("My parcel is late", .{ .resource = "c1" });
    // The current value is injected into the system suffix of the next request.
    try t.expect(std.mem.indexOf(u8, h.requests()[2], "{\\\"name\\\":\\\"Ada\\\",\\\"open_issues\\\":[]}") != null);

    h.script(Support, &.{.text("Hi again")});
    _ = try h.agent(Support).generate("Hi", .{ .resource = "c1" });
    try t.expect(std.mem.indexOf(u8, h.requests()[4], "{\\\"name\\\":\\\"Ada\\\",\\\"open_issues\\\":[\\\"late parcel\\\"]}") != null);
    // Another customer starts empty.
    h.script(Support, &.{.text("Hello")});
    _ = try h.agent(Support).generate("Hi", .{ .resource = "c2" });
    try t.expect(std.mem.indexOf(u8, h.requests()[5], "{\\\"open_issues\\\":[]}") != null);
}

const SqlApp = z.App(.{ .ctx = Ctx, .agents = .{Support}, .storage = .sqlite });

test "sqlite: a conversation survives a process restart" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(t.io, &path_buf);
    const path = try t.allocator.print("{s}/z.sqlite", .{path_buf[0..dir_len]});
    defer t.allocator.free(path);

    var replay: z.provider.http.Replay = .init(t.allocator, &.{
        .{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_text.sse") },
        .{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_text.sse") },
    });
    defer replay.deinit();
    {
        var rt = try SqlApp.init(t.allocator, t.io, .{ .ctx = &ctx, .storage_path = path, .testing = .{ .replay = &replay } });
        defer rt.deinit();
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        _ = try rt.agent(Support).generate(arena.allocator(), "Remember the word: pineapple", .{ .thread = "persist" });
    }
    {
        var rt = try SqlApp.init(t.allocator, t.io, .{ .ctx = &ctx, .storage_path = path, .testing = .{ .replay = &replay } });
        defer rt.deinit();
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        _ = try rt.agent(Support).generate(arena.allocator(), "What was the word?", .{ .thread = "persist" });
    }
    try t.expect(std.mem.indexOf(u8, replay.requests.items[1], "pineapple") != null);
    try t.expect(std.mem.indexOf(u8, replay.requests.items[1], "Hi there, friend.") != null);
}

const Charge = struct {
    pub const description = "Charge the customer's card.";
    pub const Input = struct { cents: u32 };
    pub const Output = struct { ok: bool };
    pub const effects = .{.spends_money};
    pub fn execute(_: *z.ToolCtx(Ctx), _: Input) !Output {
        return .{ .ok = true };
    }
};
const Biller = z.Agent(Ctx, .{ .name = "biller", .model = "anthropic/claude-sonnet-5-5", .tools = .{Charge} });

test "D8: tools that spend money require approval by default" {
    try t.expect(Biller.has_approvals);
    const App3 = z.App(.{ .ctx = Ctx, .agents = .{Biller} });
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App3, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Biller, &.{.tool(Charge, .{ .cents = 100 })});
    const r = try h.agent(Biller).generate("charge", .{});
    try t.expectEqual(@as(usize, 1), r.suspended.requests.len);
}

test "D30: thinking blocks from earlier runs aren't replayed" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var replay: z.provider.http.Replay = .init(t.allocator, &.{
        .{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_tool.sse") },
        .{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_text.sse") },
        .{ .url_suffix = "/v1/messages", .body = @embedFile("cassettes/anthropic_text.sse") },
    });
    defer replay.deinit();
    var rt = try App.init(t.allocator, t.io, .{ .ctx = &ctx, .testing = .{ .replay = &replay } });
    defer rt.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    _ = try rt.agent(Support).generate(arena.allocator(), "Where is ORD-1042?", .{ .thread = "th" });
    // Within the run, the thinking block went back unchanged.
    try t.expect(std.mem.indexOf(u8, replay.requests.items[1], "\"signature\":\"EqQBCgIYAhIM\"") != null);
    _ = try rt.agent(Support).generate(arena.allocator(), "Thanks", .{ .thread = "th" });
    // In the next run, history is there but its thinking blocks aren't.
    const third = replay.requests.items[2];
    try t.expect(std.mem.indexOf(u8, third, "Let me check.") != null);
    try t.expect(std.mem.indexOf(u8, third, "\"type\":\"thinking\"") == null);
    try t.expect(std.mem.indexOf(u8, third, "redacted_thinking") == null);
}

test "reasoning: shown as events, and sent back with its signature within the run" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(Thinker, &.{
        .withReasoning("Need the order first.", .tool(LookupOrder, .{ .order_id = "ORD-1" })),
        .withReasoning("It's $90.", .text("ORD-1 is $90.")),
    });
    var stream = try h.agent(Thinker).stream("Where's ORD-1?", .{});
    defer stream.deinit();
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(t.allocator);
    while (try stream.next()) |event| switch (event) {
        .reasoning_delta => |d| try reasoning.appendSlice(t.allocator, d),
        else => {},
    };
    try t.expectEqualStrings("Need the order first.It's $90.", reasoning.items);
    // The thinking block and its signature went back unchanged in step 2.
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "{\"type\":\"thinking\",\"thinking\":\"Need the order first.\",\"signature\":\"sig_scripted_1\"}") != null);
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "\"thinking\":{\"type\":\"adaptive\"}") != null);
}

test "reasoning: not shown means no event, but the block still round-trips" {
    comptime {
        std.debug.assert(!@hasField(QuietThinker.Event, "reasoning_delta"));
        std.debug.assert(@hasField(Thinker.Event, "reasoning_delta"));
        std.debug.assert(!@hasField(Support.Event, "reasoning_delta"));
    }
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(QuietThinker, &.{
        .withReasoning("Look it up.", .tool(LookupOrder, .{ .order_id = "ORD-1" })),
        .text("ORD-1 is $90."),
    });
    const r = try h.agent(QuietThinker).generate("Where's ORD-1?", .{});
    try t.expectEqualStrings("ORD-1 is $90.", r.text);
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "\"thinking\":\"Look it up.\"") != null);
}

test "reasoning: a per-run max_tokens must exceed the budget" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    try t.expectError(error.BadRequest, h.agent(Budgeted).generate("Hi", .{ .max_tokens = 2_000 }));
    try t.expectEqualStrings("agent 'budgeted': max_tokens 2000 must be greater than the reasoning budget (4000); the budget counts toward it", h.rt.lastDiagnostic());
}

test "D36: OpenAI reasoning goes back within a run, not across runs" {
    var db: Db = .{};
    var ctx: Ctx = .{ .db = &db };
    var h = try z.testing.harness(App, .{ .ctx = &ctx });
    defer h.deinit();
    h.script(OaiThinker, &.{
        .withReasoning("Need the order first.", .tool(LookupOrder, .{ .order_id = "ORD-1" })),
        .text("ORD-1 is $90."),
        .text("You're welcome."),
    });
    var stream = try h.agent(OaiThinker).stream("Where's ORD-1?", .{ .thread = "oai" });
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(t.allocator);
    while (try stream.next()) |event| switch (event) {
        .reasoning_delta => |d| try reasoning.appendSlice(t.allocator, d),
        else => {},
    };
    stream.deinit();
    try t.expectEqualStrings("Need the order first.", reasoning.items);
    try t.expect(std.mem.indexOf(u8, h.requests()[0], "\"reasoning\":{\"effort\":\"medium\",\"summary\":\"auto\"}") != null);
    // Step 2 of the run: the reasoning item, then the call and its output.
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "{\"type\":\"reasoning\",\"encrypted_content\":\"enc_scripted_") != null);
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "\"summary\":[{\"type\":\"summary_text\",\"text\":\"Need the order first.\"}]},{\"type\":\"function_call\",\"call_id\":") != null);
    try t.expect(std.mem.indexOf(u8, h.requests()[1], "{\"type\":\"function_call_output\",\"call_id\":") != null);

    _ = try h.agent(OaiThinker).generate("Thanks", .{ .thread = "oai" });
    // The next run has the history, without the reasoning item.
    const third = h.requests()[2];
    try t.expect(std.mem.indexOf(u8, third, "ORD-1 is $90.") != null);
    try t.expect(std.mem.indexOf(u8, third, "\"function_call_output\"") != null);
    try t.expect(std.mem.indexOf(u8, third, "\"type\":\"reasoning\"") == null);
}
