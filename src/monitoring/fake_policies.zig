//! FakeMonitoring's alert policies (issue #275): the ones a test puts in,
//! listed, got and enabled or disabled as production answered on
//! 2026-10-20 (milestone 0 of the policies spec, `_tmp/policies-m0/`).
//! `FakeMonitoring` holds the `Store` and routes `alertPolicies` here,
//! under its mutex.
//!
//! - Lists order by name without `orderBy`, carry `totalSize` on every
//!   page with policies, and answer `{}` when none match.
//! - Filters: clauses joined by `AND`, each a field production documents
//!   (`name`, `display_name`, `documentation.content`,
//!   `documentation.mime_type`, `user_labels.k` or `user_labels['k']`,
//!   `conditions.size`, `combiner`, `enabled`, `notification_channels`)
//!   with `=`, `!=`, `:`, or for `conditions.size` `<`, `>`, `<=`, `>=`,
//!   and a quoted string, `true`, `false`, a number, or `starts_with`,
//!   `ends_with` or `has_substring` of a quoted string. Any other field,
//!   `severity` included, and a bare word are production's 400 in its
//!   words; an unclosed quote or bracket is its parse error. `OR`, `NOT`,
//!   brackets and `monitoring.regex.full_match` answer 501.
//! - `orderBy`: `name` and `display_name`, each with `-` for descending,
//!   comma-separated; another documented field answers 501, anything
//!   else production's 400.
//! - A patch takes `updateMask=enabled` alone: an absent `enabled` in the
//!   body reads as true, as production read it, and every patch moves the
//!   mutation record, a repeat included. A patch without a mask, which
//!   production reads as a replacement of the whole policy, and any other
//!   mask answer 501.
//! - A policy nobody has is production's 404: its get names the project
//!   id, its patch the project number (`Options.project_number`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Reply = @import("fake_monitoring.zig").FakeMonitoring.Reply;
const Param = @import("fake_monitoring.zig").Param;
const Method = core.transport.Method;

/// A condition as a test puts one in. Its name is assigned.
pub const PutCondition = struct {
    display_name: []const u8 = "",
    /// Not `.unknown`.
    kind: types.ConditionKind,
    /// Required by threshold, absence and log-match conditions.
    filter: []const u8 = "",
    /// Required by MQL, PromQL and SQL conditions.
    query: []const u8 = "",
    comparison: types.Comparison = .unspecified,
    threshold_value: ?f64 = null,
    duration_s: ?f64 = null,
    aggregations: []const types.Aggregation = &.{},
    trigger: ?types.Trigger = null,
};

/// An alert policy as a test puts one in, standing in for whoever made it.
pub const PutAlertPolicy = struct {
    /// Assigned when null, as production assigns one: digits.
    id: ?[]const u8 = null,
    display_name: []const u8 = "",
    enabled: bool = true,
    severity: types.Severity = .unspecified,
    combiner: types.Combiner = .@"or",
    documentation: types.Documentation = .{},
    user_labels: []const types.Label = &.{},
    /// Full names, `projects/P/notificationChannels/ID`.
    notification_channels: []const []const u8 = &.{},
    conditions: []const PutCondition = &.{},
    /// The fake's clock when null.
    created: ?std.Io.Timestamp = null,
    /// `Options.caller` when empty.
    created_by: []const u8 = "",
};

const Policy = struct {
    name: []const u8,
    id: []const u8,
    display_name: []const u8,
    enabled: bool,
    severity: types.Severity,
    combiner: types.Combiner,
    documentation: types.Documentation,
    user_labels: []const types.Label,
    channels: []const []const u8,
    conditions: []const Stored,
    created_ns: i96,
    created_by: []const u8,
    mutated_ns: i96,
    mutated_by: []const u8,

    const Stored = struct { name: []const u8, c: PutCondition };
};

/// What FakeMonitoring holds for alert policies.
pub const Store = struct {
    /// By id, in the order put in.
    policies: std.StringArrayHashMapUnmanaged(*Policy) = .empty,
    next_id: u64 = 0,

    pub fn deinit(s: *Store, gpa: Allocator) void {
        s.policies.deinit(gpa);
        s.* = undefined;
    }

    pub fn count(s: *const Store) usize {
        return s.policies.count();
    }

    /// Puts a policy in and returns its full name, kept in `keep`.
    /// `error.InvalidEntry`, nothing kept, for an id taken or not one
    /// production could hold, a severity or combiner of `.unknown`, a
    /// condition of `.unknown` kind, or one without the filter or query
    /// its kind needs.
    pub fn put(s: *Store, gpa: Allocator, keep: Allocator, project: []const u8, caller: []const u8, now_ns: i96, p: PutAlertPolicy) error{ OutOfMemory, InvalidEntry }![]const u8 {
        if (p.severity == .unknown or p.combiner == .unknown) return error.InvalidEntry;
        for (p.conditions) |c| switch (c.kind) {
            .threshold, .absence, .log_match => if (c.filter.len == 0) return error.InvalidEntry,
            .mql, .promql, .sql => if (c.query.len == 0) return error.InvalidEntry,
            .unknown => return error.InvalidEntry,
        };
        const id = if (p.id) |given| id: {
            if (!validate.isAlertId(given)) return error.InvalidEntry;
            break :id try keep.dupe(u8, given);
        } else try s.newId(keep);
        if (s.policies.contains(id)) return error.InvalidEntry;
        const name = try std.fmt.allocPrint(keep, "projects/{s}/alertPolicies/{s}", .{ project, id });
        const conditions = try keep.alloc(Policy.Stored, p.conditions.len);
        for (p.conditions, conditions) |c, *dst| dst.* = .{
            .name = try std.fmt.allocPrint(keep, "{s}/conditions/{s}", .{ name, try s.newId(keep) }),
            .c = .{
                .display_name = try keep.dupe(u8, c.display_name),
                .kind = c.kind,
                .filter = try keep.dupe(u8, c.filter),
                .query = try keep.dupe(u8, c.query),
                .comparison = c.comparison,
                .threshold_value = c.threshold_value,
                .duration_s = c.duration_s,
                .aggregations = try dupeAggregations(keep, c.aggregations),
                .trigger = c.trigger,
            },
        };
        const channels = try keep.alloc([]const u8, p.notification_channels.len);
        for (p.notification_channels, channels) |c, *dst| dst.* = try keep.dupe(u8, c);
        const created_ns = if (p.created) |t| t.nanoseconds else now_ns;
        const by = try keep.dupe(u8, if (p.created_by.len > 0) p.created_by else caller);
        const held = try keep.create(Policy);
        held.* = .{
            .name = name,
            .id = id,
            .display_name = try keep.dupe(u8, p.display_name),
            .enabled = p.enabled,
            .severity = p.severity,
            .combiner = p.combiner,
            .documentation = .{
                .content = try keep.dupe(u8, p.documentation.content),
                .mime_type = try keep.dupe(u8, p.documentation.mime_type),
                .subject = try keep.dupe(u8, p.documentation.subject),
            },
            .user_labels = try dupeLabels(keep, p.user_labels),
            .channels = channels,
            .conditions = conditions,
            .created_ns = created_ns,
            .created_by = by,
            .mutated_ns = created_ns,
            .mutated_by = by,
        };
        try s.policies.put(gpa, held.id, held);
        return held.name;
    }

    /// Production's ids are 19 or 20 digits.
    fn newId(s: *Store, keep: Allocator) Allocator.Error![]const u8 {
        s.next_id += 1;
        return std.fmt.allocPrint(keep, "{d}", .{1_000_000_000_000_000_000 + s.next_id});
    }

    /// `rest` is what follows `alertPolicies` and its `/` ("" for the
    /// collection); `query` the parameters, decoded.
    pub fn route(s: *Store, arena: Allocator, ctx: Context, method: Method, rest: []const u8, params: []const Param, body: ?[]const u8) Allocator.Error!Reply {
        if (rest.len == 0) {
            if (method != .GET) return notModelled(arena, "creating an alert policy");
            return s.list(arena, ctx, params);
        }
        const id = try decoded(arena, rest);
        if (std.mem.indexOfScalar(u8, id, '/') != null) return notModelled(arena, "this path under an alert policy");
        const p = s.policies.get(id);
        switch (method) {
            .GET => {
                const policy = p orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Failed to find alert policy {s} in {s}.", .{ id, ctx.project }));
                return render(arena, policy);
            },
            .PATCH => {
                const mask = paramOf(params, "updateMask") orelse
                    return notModelled(arena, "a patch without updateMask, which replaces the whole policy");
                if (!std.mem.eql(u8, mask, "enabled")) return notModelled(arena, "a patch of anything but enabled (updateMask=enabled)");
                const policy = p orelse return fail(arena, 404, "NOT_FOUND", try arena.print("Failed to find alert policy {s} in {s}.", .{ id, ctx.project_number }));
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body orelse "", .{}) catch
                    return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
                const obj = switch (parsed) {
                    .object => |o| o,
                    else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
                };
                // Production read an absent field as true, Google's write
                // default.
                policy.enabled = if (obj.get("enabled")) |e| switch (e) {
                    .bool => |b| b,
                    else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid value at 'alert_policy.enabled' (TYPE_BOOL)."),
                } else true;
                policy.mutated_ns = ctx.now_ns;
                policy.mutated_by = ctx.caller;
                return render(arena, policy);
            },
            .DELETE => return notModelled(arena, "deleting an alert policy"),
            else => return notModelled(arena, "this method on an alert policy"),
        }
    }

    fn list(s: *Store, arena: Allocator, ctx: Context, params: []const Param) Allocator.Error!Reply {
        _ = ctx;
        var clauses: []const Clause = &.{};
        if (paramOf(params, "filter")) |text| switch (try parseFilter(arena, text)) {
            .ok => |c| clauses = c,
            .reply => |r| return r,
        };
        var keys: []const OrderKey = &.{};
        if (paramOf(params, "orderBy")) |text| switch (try parseOrder(arena, text)) {
            .ok => |k| keys = k,
            .reply => |r| return r,
        };
        var matched: std.ArrayList(*Policy) = .empty;
        for (s.policies.values()) |p| {
            if (matches(p, clauses)) try matched.append(arena, p);
        }
        std.mem.sort(*Policy, matched.items, keys, sortsBefore);
        const window = pageOf(params, matched.items.len) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid page token or page size.");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePage(&jw, matched.items[window.from..window.to], window.next, matched.items.len) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }
};

/// What a route needs from the fake around the store.
pub const Context = struct {
    project: []const u8,
    project_number: []const u8,
    caller: []const u8,
    now_ns: i96,
};

fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

fn decoded(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const copy = try arena.dupe(u8, text);
    return std.Uri.percentDecodeInPlace(copy);
}

fn dupeLabels(keep: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
    const out = try keep.alloc(types.Label, labels.len);
    for (labels, out) |l, *o| o.* = .{ .key = try keep.dupe(u8, l.key), .value = try keep.dupe(u8, l.value) };
    return out;
}

fn dupeAggregations(keep: Allocator, aggs: []const types.Aggregation) Allocator.Error![]const types.Aggregation {
    const out = try keep.alloc(types.Aggregation, aggs.len);
    for (aggs, out) |a, *o| {
        o.* = a;
        const fields = try keep.alloc([]const u8, a.group_by.len);
        for (a.group_by, fields) |g, *dst| dst.* = try keep.dupe(u8, g);
        o.group_by = fields;
    }
    return out;
}

// Filters, as production read them.

const Field = enum { name, display_name, documentation_content, documentation_mime_type, user_label, conditions_size, combiner, enabled, notification_channels };

const Op = enum { eq, ne, has, lt, gt, le, ge };

const Want = union(enum) {
    text: []const u8,
    starts_with: []const u8,
    ends_with: []const u8,
    has_substring: []const u8,
    boolean: bool,
    number: i64,
};

const Clause = struct {
    field: Field,
    /// For `user_labels.k`.
    key: []const u8 = "",
    op: Op,
    want: Want,
};

fn Parsed(comptime T: type) type {
    return union(enum) { ok: T, reply: Reply };
}

fn parseFilter(arena: Allocator, filter: []const u8) Allocator.Error!Parsed([]const Clause) {
    if (!balanced(filter)) return .{ .reply = try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Could not parse filter \"{s}\"; syntax error at line 1, token '<EOF>'", .{filter})) };
    var clauses: std.ArrayList(Clause) = .empty;
    var parts = std.mem.splitSequence(u8, filter, " AND ");
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (std.mem.indexOf(u8, part, " OR ") != null or std.mem.startsWith(u8, part, "NOT ") or std.mem.startsWith(u8, part, "(") or std.mem.startsWith(u8, part, "-"))
            return .{ .reply = try notModelled(arena, "a filter with OR, NOT or brackets") };
        const at = operatorAt(part) orelse
            return .{ .reply = try noSuchField(arena, filter, part) };
        const lhs = std.mem.trim(u8, part[0..at.index], " ");
        const rhs = std.mem.trim(u8, part[at.index + at.len ..], " ");
        var clause: Clause = .{ .field = undefined, .op = at.op, .want = undefined };
        if (fieldOf(lhs)) |f| {
            clause.field = f;
        } else if (labelKeyOf(lhs)) |key| {
            clause.field = .user_label;
            clause.key = key;
        } else {
            return .{ .reply = try noSuchField(arena, filter, lhs) };
        }
        clause.want = wantOf(rhs) orelse return .{ .reply = try notModelled(arena, "this filter value") };
        const fits = switch (clause.field) {
            .conditions_size => clause.want == .number,
            .enabled => clause.want == .boolean and (clause.op == .eq or clause.op == .ne),
            else => clause.op == .eq or clause.op == .ne or clause.op == .has,
        };
        if (!fits) return .{ .reply = try notModelled(arena, "this comparison in a filter") };
        try clauses.append(arena, clause);
    }
    return .{ .ok = clauses.items };
}

fn noSuchField(arena: Allocator, filter: []const u8, member: []const u8) Allocator.Error!Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid field \"filter\" [value ==\"{s}\"]; member reference \"{s}\" is not valid; No such field: {s}.", .{ filter, member, member }));
}

/// Quotes closed and brackets matched, outside quotes.
fn balanced(text: []const u8) bool {
    var depth: usize = 0;
    var quote: ?u8 = null;
    for (text) |c| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return quote == null and depth == 0;
}

const At = struct { index: usize, len: usize, op: Op };

/// The first operator outside quotes.
fn operatorAt(part: []const u8) ?At {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < part.len) : (i += 1) {
        const c = part[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        const two = if (i + 1 < part.len) part[i .. i + 2] else "";
        if (std.mem.eql(u8, two, ">=")) return .{ .index = i, .len = 2, .op = .ge };
        if (std.mem.eql(u8, two, "<=")) return .{ .index = i, .len = 2, .op = .le };
        if (std.mem.eql(u8, two, "!=")) return .{ .index = i, .len = 2, .op = .ne };
        switch (c) {
            '=' => return .{ .index = i, .len = 1, .op = .eq },
            ':' => return .{ .index = i, .len = 1, .op = .has },
            '<' => return .{ .index = i, .len = 1, .op = .lt },
            '>' => return .{ .index = i, .len = 1, .op = .gt },
            else => {},
        }
    }
    return null;
}

fn fieldOf(lhs: []const u8) ?Field {
    const map = std.StaticStringMap(Field).initComptime(.{
        .{ "name", .name },
        .{ "display_name", .display_name },
        .{ "documentation.content", .documentation_content },
        .{ "documentation.mime_type", .documentation_mime_type },
        .{ "conditions.size", .conditions_size },
        .{ "combiner", .combiner },
        .{ "enabled", .enabled },
        .{ "notification_channels", .notification_channels },
    });
    return map.get(lhs);
}

/// `user_labels.k`, `user_label.k`, `user_labels['k']` or
/// `user_labels["k"]`: the key.
fn labelKeyOf(lhs: []const u8) ?[]const u8 {
    for ([_][]const u8{ "user_labels.", "user_label." }) |prefix| {
        if (std.mem.startsWith(u8, lhs, prefix) and lhs.len > prefix.len) return lhs[prefix.len..];
    }
    for ([_][]const u8{ "user_labels['", "user_labels[\"" }) |prefix| {
        if (std.mem.startsWith(u8, lhs, prefix) and lhs.len > prefix.len + 2) {
            const close: []const u8 = if (prefix[prefix.len - 1] == '\'') "']" else "\"]";
            if (std.mem.endsWith(u8, lhs, close)) return lhs[prefix.len .. lhs.len - 2];
        }
    }
    return null;
}

fn wantOf(rhs: []const u8) ?Want {
    if (std.mem.eql(u8, rhs, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, rhs, "false")) return .{ .boolean = false };
    if (quotedOf(rhs)) |s| return .{ .text = s };
    inline for (.{ "starts_with", "ends_with", "has_substring" }) |func| {
        if (std.mem.startsWith(u8, rhs, func ++ "(") and std.mem.endsWith(u8, rhs, ")")) {
            const inner = std.mem.trim(u8, rhs[func.len + 1 .. rhs.len - 1], " ");
            if (quotedOf(inner)) |s| return @unionInit(Want, func, s);
        }
    }
    if (std.fmt.parseInt(i64, rhs, 10)) |n| return .{ .number = n } else |_| {}
    return null;
}

fn quotedOf(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;
    const q = text[0];
    if ((q != '"' and q != '\'') or text[text.len - 1] != q) return null;
    const inner = text[1 .. text.len - 1];
    if (std.mem.indexOfScalar(u8, inner, q) != null) return null;
    return inner;
}

fn matches(p: *const Policy, clauses: []const Clause) bool {
    for (clauses) |c| if (!holds(p, c)) return false;
    return true;
}

fn holds(p: *const Policy, c: Clause) bool {
    return switch (c.field) {
        .name => textHolds(p.name, c),
        .display_name => textHolds(p.display_name, c),
        .documentation_content => textHolds(p.documentation.content, c),
        .documentation_mime_type => textHolds(p.documentation.mime_type, c),
        .combiner => textHolds(combinerWire(p.combiner), c),
        .user_label => for (p.user_labels) |l| {
            if (std.mem.eql(u8, l.key, c.key)) break textHolds(l.value, c);
        } else c.op == .ne,
        .enabled => (p.enabled == c.want.boolean) == (c.op == .eq),
        .conditions_size => {
            const n: i64 = @intCast(p.conditions.len);
            const w = c.want.number;
            return switch (c.op) {
                .eq => n == w,
                .ne => n != w,
                .lt => n < w,
                .gt => n > w,
                .le => n <= w,
                .ge => n >= w,
                .has => n == w,
            };
        },
        // Any element for `=` and `:`, none for `!=`.
        .notification_channels => {
            var any = false;
            for (p.channels) |ch| {
                var probe = c;
                if (c.op == .ne) probe.op = .eq;
                if (textHolds(ch, probe)) any = true;
            }
            return if (c.op == .ne) !any else any;
        },
    };
}

fn textHolds(value: []const u8, c: Clause) bool {
    const hit = switch (c.want) {
        .text => |t| if (c.op == .has) std.mem.indexOf(u8, value, t) != null else std.mem.eql(u8, value, t),
        .starts_with => |t| std.mem.startsWith(u8, value, t),
        .ends_with => |t| std.mem.endsWith(u8, value, t),
        .has_substring => |t| std.ascii.findIgnoreCase(value, t) != null,
        .boolean, .number => false,
    };
    return if (c.op == .ne) !hit else hit;
}

// Orders.

const OrderKey = struct { field: enum { name, display_name }, descending: bool };

fn parseOrder(arena: Allocator, text: []const u8) Allocator.Error!Parsed([]const OrderKey) {
    var keys: std.ArrayList(OrderKey) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        const descending = std.mem.startsWith(u8, part, "-");
        const name = if (descending) part[1..] else part;
        if (std.mem.eql(u8, name, "name")) {
            try keys.append(arena, .{ .field = .name, .descending = descending });
        } else if (std.mem.eql(u8, name, "display_name")) {
            try keys.append(arena, .{ .field = .display_name, .descending = descending });
        } else if (fieldOf(name) != null or labelKeyOf(name) != null) {
            return .{ .reply = try notModelled(arena, "an orderBy on this field") };
        } else {
            return .{ .reply = try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Invalid field \"order_by\" [value == \"{s}\"; member reference \"{s}\" is invalid; No such field: {s}.", .{ text, name, name })) };
        }
    }
    return .{ .ok = keys.items };
}

/// By the keys, then by name, production's order without any.
fn sortsBefore(keys: []const OrderKey, a: *Policy, b: *Policy) bool {
    for (keys) |k| {
        const x = if (k.field == .name) a.name else a.display_name;
        const y = if (k.field == .name) b.name else b.display_name;
        switch (std.mem.order(u8, x, y)) {
            .eq => continue,
            .lt => return !k.descending,
            .gt => return k.descending,
        }
    }
    return std.mem.lessThan(u8, a.name, b.name);
}

const Window = struct { from: usize, to: usize, next: ?usize };

/// pageSize 0 answers everything, as production answered six with none.
fn pageOf(params: []const Param, total: usize) ?Window {
    var size = total;
    if (paramOf(params, "pageSize")) |text| {
        const n = std.fmt.parseInt(usize, text, 10) catch return null;
        if (n != 0) size = n;
    }
    var from: usize = 0;
    if (paramOf(params, "pageToken")) |t| {
        if (!std.mem.startsWith(u8, t, "p")) return null;
        from = std.fmt.parseInt(usize, t[1..], 10) catch return null;
        if (from > total) return null;
    }
    const to = @min(total, from + size);
    return .{ .from = from, .to = to, .next = if (to < total) to else null };
}

// Rendering, in production's field order for a threshold policy.

fn render(arena: Allocator, p: *const Policy) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writePolicy(&jw, p) catch return error.OutOfMemory;
    return .{ .status = 200, .body = out.written() };
}

fn writePage(jw: *Stringify, items: []const *Policy, next: ?usize, total: usize) Stringify.Error!void {
    try jw.beginObject();
    if (items.len > 0) {
        try jw.objectField("alertPolicies");
        try jw.beginArray();
        for (items) |p| try writePolicy(jw, p);
        try jw.endArray();
    }
    if (next) |n| {
        try jw.objectField("nextPageToken");
        try jw.print("\"p{d}\"", .{n});
    }
    if (total > 0) {
        try jw.objectField("totalSize");
        try jw.print("{d}", .{total});
    }
    try jw.endObject();
}

fn writePolicy(jw: *Stringify, p: *const Policy) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(p.name);
    if (p.display_name.len > 0) {
        try jw.objectField("displayName");
        try jw.write(p.display_name);
    }
    if (p.combiner != .unspecified) {
        try jw.objectField("combiner");
        try jw.write(combinerWire(p.combiner));
    }
    try writeRecord(jw, "creationRecord", p.created_ns, p.created_by);
    try writeRecord(jw, "mutationRecord", p.mutated_ns, p.mutated_by);
    if (p.conditions.len > 0) {
        try jw.objectField("conditions");
        try jw.beginArray();
        for (p.conditions) |c| try writeCondition(jw, c);
        try jw.endArray();
    }
    const d = p.documentation;
    if (d.content.len > 0 or d.mime_type.len > 0 or d.subject.len > 0) {
        try jw.objectField("documentation");
        try jw.beginObject();
        inline for (.{ .{ "content", "content" }, .{ "mimeType", "mime_type" }, .{ "subject", "subject" } }) |pair| {
            if (@field(d, pair[1]).len > 0) {
                try jw.objectField(pair[0]);
                try jw.write(@field(d, pair[1]));
            }
        }
        try jw.endObject();
    }
    if (p.user_labels.len > 0) {
        try jw.objectField("userLabels");
        try jw.beginObject();
        for (p.user_labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }
    if (p.channels.len > 0) {
        try jw.objectField("notificationChannels");
        try jw.write(p.channels);
    }
    try jw.objectField("enabled");
    try jw.write(p.enabled);
    if (p.severity != .unspecified) {
        try jw.objectField("severity");
        try jw.write(switch (p.severity) {
            .critical => "CRITICAL",
            .@"error" => "ERROR",
            .warning => "WARNING",
            else => unreachable,
        });
    }
    try jw.endObject();
}

fn writeRecord(jw: *Stringify, field: []const u8, ns: i96, by: []const u8) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.objectField(field);
    try jw.beginObject();
    try jw.objectField("mutateTime");
    try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = ns }));
    try jw.objectField("mutatedBy");
    try jw.write(by);
    try jw.endObject();
}

fn writeCondition(jw: *Stringify, s: Policy.Stored) Stringify.Error!void {
    const c = s.c;
    try jw.beginObject();
    try jw.objectField(switch (c.kind) {
        .threshold => "conditionThreshold",
        .absence => "conditionAbsent",
        .log_match => "conditionMatchedLog",
        .mql => "conditionMonitoringQueryLanguage",
        .promql => "conditionPrometheusQueryLanguage",
        .sql => "conditionSql",
        .unknown => unreachable,
    });
    try jw.beginObject();
    if (c.filter.len > 0) {
        try jw.objectField("filter");
        try jw.write(c.filter);
    }
    if (c.query.len > 0) {
        try jw.objectField("query");
        try jw.write(c.query);
    }
    if (c.comparison != .unspecified and c.comparison != .unknown) {
        try jw.objectField("comparison");
        try jw.write(switch (c.comparison) {
            .gt => "COMPARISON_GT",
            .ge => "COMPARISON_GE",
            .lt => "COMPARISON_LT",
            .le => "COMPARISON_LE",
            .eq => "COMPARISON_EQ",
            .ne => "COMPARISON_NE",
            else => unreachable,
        });
    }
    if (c.threshold_value) |v| {
        try jw.objectField("thresholdValue");
        try jw.write(v);
    }
    if (c.duration_s) |secs| {
        var buf: [core.duration.max_len]u8 = undefined;
        try jw.objectField("duration");
        try jw.write(core.duration.format(&buf, .{ .nanoseconds = @intFromFloat(secs * std.time.ns_per_s) }));
    }
    if (c.trigger) |t| {
        try jw.objectField("trigger");
        try jw.beginObject();
        if (t.count) |n| {
            try jw.objectField("count");
            try jw.print("{d}", .{n});
        }
        if (t.percent) |pct| {
            try jw.objectField("percent");
            try jw.write(pct);
        }
        try jw.endObject();
    }
    if (c.aggregations.len > 0) {
        try jw.objectField("aggregations");
        try jw.beginArray();
        for (c.aggregations) |a| {
            try jw.beginObject();
            if (a.alignment_period_s > 0) {
                try jw.objectField("alignmentPeriod");
                try jw.print("\"{d}s\"", .{a.alignment_period_s});
            }
            if (a.aligner != .none) {
                try jw.objectField("perSeriesAligner");
                try jw.write(a.aligner.wire());
            }
            if (a.reducer != .none) {
                try jw.objectField("crossSeriesReducer");
                try jw.write(a.reducer.wire());
            }
            if (a.group_by.len > 0) {
                try jw.objectField("groupByFields");
                try jw.write(a.group_by);
            }
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
    if (c.display_name.len > 0) {
        try jw.objectField("displayName");
        try jw.write(c.display_name);
    }
    try jw.objectField("name");
    try jw.write(s.name);
    try jw.endObject();
}

fn combinerWire(c: types.Combiner) []const u8 {
    return switch (c) {
        .@"and" => "AND",
        .@"or" => "OR",
        .and_with_matching_resource => "AND_WITH_MATCHING_RESOURCE",
        else => "COMBINE_UNSPECIFIED",
    };
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled yet", .{what}));
}

// Tests, held to what production answered in milestone 0.

const testing = std.testing;
const codec = @import("codec.zig");
const production = @import("production_bodies.zig");
const Client = @import("Client.zig");
const FakeMonitoring = @import("fake_monitoring.zig").FakeMonitoring;

const Bench = struct {
    clock: core.testing.FakeClock,
    fake: FakeMonitoring,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench) !void {
        b.* = .{ .clock = .{ .now_ns = ts("2026-10-20T18:56:00Z").nanoseconds }, .fake = undefined, .token = .{ .token = "t" }, .diag = .{}, .client = undefined };
        b.fake = .init(testing.allocator, b.clock.io(), .{ .project_id = "extractctl", .project_number = "82150720798", .caller = "zig-gcp@extractctl.iam.gserviceaccount.com" });
        errdefer b.fake.deinit();
        b.client = try .init(testing.allocator, b.clock.io(), .{
            .project_id = "extractctl",
            .token_provider = b.token.provider(),
            .transport = b.fake.transport(),
            .diagnostics = &b.diag,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    fn raw(b: *Bench, arena: Allocator, method: Method, path: []const u8, body: ?[]const u8) !Reply {
        return b.fake.serve(.{ .method = method, .url = try std.fmt.allocPrint(arena, "https://monitoring.googleapis.com/v3/projects/extractctl/{s}", .{path}), .bearer = "t", .body = body }, arena);
    }

    /// The probe's six policies, with production's ids and display names.
    fn putProbePolicies(b: *Bench) !void {
        const topic = "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" AND resource.type=\"pubsub_topic\"";
        const rate: []const types.Aggregation = &.{.{ .alignment_period_s = 60, .aligner = .rate }};
        const label: []const types.Label = &.{.{ .key = "zigps", .value = "probe" }};
        _ = try b.fake.putAlertPolicy(.{ .id = "9594883664150561401", .display_name = "zigps-d5b8f4-threshold", .severity = .warning, .user_labels = label, .documentation = .{ .content = "Publish rate over 1000/s.", .mime_type = "text/markdown", .subject = "zigps publish rate" }, .conditions = &.{.{ .display_name = "rate over 1000", .kind = .threshold, .filter = topic, .comparison = .gt, .threshold_value = 1000, .duration_s = 60, .aggregations = rate, .trigger = .{ .count = 1 } }} });
        _ = try b.fake.putAlertPolicy(.{ .id = "5575262459168249474", .display_name = "zigps-d5b8f4-absence", .severity = .@"error", .enabled = false, .user_labels = label, .conditions = &.{.{ .display_name = "no publishes", .kind = .absence, .filter = topic, .duration_s = 300, .aggregations = &.{.{ .alignment_period_s = 60, .aligner = .count }}, .trigger = .{ .percent = 50 } }} });
        _ = try b.fake.putAlertPolicy(.{ .id = "3389115242718001746", .display_name = "zigps-d5b8f4-log", .severity = .critical, .user_labels = label, .conditions = &.{.{ .display_name = "probe log line", .kind = .log_match, .filter = "logName=\"projects/extractctl/logs/zigps-d5b8f4\" AND severity>=ERROR" }} });
        _ = try b.fake.putAlertPolicy(.{ .id = "4294582767119635845", .display_name = "zigps-d5b8f4-mql", .user_labels = label, .conditions = &.{.{ .display_name = "mql rate", .kind = .mql, .query = "fetch pubsub_topic | metric 'pubsub.googleapis.com/topic/send_message_operation_count' | align rate(1m) | every 1m | condition val() > 1000 '1/s'", .duration_s = 60, .trigger = .{ .count = 1 } }} });
        _ = try b.fake.putAlertPolicy(.{ .id = "6864678670941340587", .display_name = "zigps-d5b8f4-promql", .user_labels = label, .conditions = &.{.{ .display_name = "promql rate", .kind = .promql, .query = "rate(pubsub_googleapis_com:topic_send_message_operation_count[5m]) > 1000", .duration_s = 60 }} });
        _ = try b.fake.putAlertPolicy(.{ .id = "7136103533907925714", .display_name = "zigps-d5b8f4-two", .combiner = .@"and", .user_labels = label, .conditions = &.{
            .{ .display_name = "rate over 1000", .kind = .threshold, .filter = topic, .comparison = .gt, .threshold_value = 1000, .duration_s = 0, .aggregations = rate },
            .{ .display_name = "rate under 1", .kind = .threshold, .filter = topic, .comparison = .lt, .threshold_value = 1, .duration_s = 0, .aggregations = rate },
        } });
    }

    /// The display names a list answers, in order.
    fn listed(b: *Bench, arena: Allocator, options: types.ListAlertPoliciesOptions) ![]const []const u8 {
        var page = try b.client.listAlertPolicies(options);
        defer page.deinit();
        const out = try arena.alloc([]const u8, page.value.policies.len);
        for (page.value.policies, out) |p, *o| o.* = try arena.dupe(u8, p.display_name["zigps-d5b8f4-".len..]);
        return out;
    }
};

fn ts(text: []const u8) std.Io.Timestamp {
    return core.timestamp.parse(text) catch unreachable;
}

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

/// The message in a refusal's body.
fn messageOf(arena: Allocator, body: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return v.object.get("error").?.object.get("message").?.string;
}

test "the probe's policies put in, read back as production answered them, kind by kind" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.putProbePolicies();
    try testing.expectEqual(6, b.fake.alertPolicyCount());
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    const a = out.allocator();
    for ([_]struct { []const u8, []const u8 }{
        .{ "9594883664150561401", production.policy_threshold },
        .{ "5575262459168249474", production.policy_absence },
        .{ "3389115242718001746", production.policy_log },
        .{ "4294582767119635845", production.policy_mql },
        .{ "6864678670941340587", production.policy_promql },
        .{ "7136103533907925714", production.policy_two },
    }) |pair| {
        const want = try codec.decodeAlertPolicy(a, a, pair[1]);
        var got = try b.client.getAlertPolicy(pair[0]);
        defer got.deinit();
        const g = got.value;
        try testing.expectEqualStrings(want.name, g.name);
        try testing.expectEqualStrings(want.display_name, g.display_name);
        try testing.expectEqual(want.enabled, g.enabled);
        try testing.expectEqual(want.severity, g.severity);
        try testing.expectEqual(want.combiner, g.combiner);
        try testing.expectEqualStrings(want.documentation.content, g.documentation.content);
        try testing.expectEqualStrings(want.documentation.subject, g.documentation.subject);
        try testing.expectEqualStrings(want.userLabel("zigps").?, g.userLabel("zigps").?);
        try testing.expectEqualStrings(want.created.by, g.created.by);
        try testing.expectEqual(want.conditions.len, g.conditions.len);
        for (want.conditions, g.conditions) |wc, gc| {
            try testing.expectEqual(wc.kind, gc.kind);
            try testing.expectEqualStrings(wc.display_name, gc.display_name);
            try testing.expectEqualStrings(wc.filter, gc.filter);
            try testing.expectEqualStrings(wc.query, gc.query);
            try testing.expectEqual(wc.comparison, gc.comparison);
            try testing.expectEqual(wc.threshold_value, gc.threshold_value);
            try testing.expectEqual(wc.duration_s, gc.duration_s);
            try testing.expectEqual(wc.trigger, gc.trigger);
            try testing.expectEqual(wc.aggregations.len, gc.aggregations.len);
            for (wc.aggregations, gc.aggregations) |wa, ga| {
                try testing.expectEqual(wa.aligner, ga.aligner);
                try testing.expectEqual(wa.alignment_period_s, ga.alignment_period_s);
            }
            try testing.expect(std.mem.startsWith(u8, gc.name, g.name));
        }
    }
}

test "filters and orders match what production matched" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.putProbePolicies();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Without an order, by name: production's answer for the probe's ids.
    try expectNames(&.{ "log", "mql", "absence", "promql", "two", "threshold" }, try b.listed(a, .{ .filter = "display_name=starts_with(\"zigps-d5b8f4\")" }));
    try expectNames(&.{ "log", "mql", "absence", "promql", "two", "threshold" }, try b.listed(a, .{ .filter = "display_name:\"zigps-d5b8f4\"" }));
    try expectNames(&.{"absence"}, try b.listed(a, .{ .filter = "enabled=false AND display_name=starts_with(\"zigps-d5b8f4\")" }));
    try expectNames(&.{ "log", "mql", "absence", "promql", "two", "threshold" }, try b.listed(a, .{ .filter = "user_labels.zigps=\"probe\"" }));
    try expectNames(&.{ "log", "mql", "absence", "promql", "two", "threshold" }, try b.listed(a, .{ .filter = "user_labels['zigps']=\"probe\"" }));
    try expectNames(&.{"two"}, try b.listed(a, .{ .filter = "conditions.size>1 AND display_name=starts_with(\"zigps-d5b8f4\")" }));
    try expectNames(&.{"two"}, try b.listed(a, .{ .filter = "combiner=\"AND\" AND display_name=starts_with(\"zigps-d5b8f4\")" }));
    try expectNames(&.{ "absence", "log", "mql", "promql", "threshold", "two" }, try b.listed(a, .{ .filter = "display_name=starts_with(\"zigps-d5b8f4\")", .order_by = "display_name" }));
    try expectNames(&.{ "two", "threshold", "promql", "mql", "log", "absence" }, try b.listed(a, .{ .filter = "display_name=starts_with(\"zigps-d5b8f4\")", .order_by = "-display_name" }));
    // The forms production did not show, answered as the language says.
    try expectNames(&.{ "log", "mql", "promql", "two", "threshold" }, try b.listed(a, .{ .filter = "enabled!=false" }));
    // The subject is not a field the language takes.
    try testing.expectError(error.InvalidArgument, b.listed(a, .{ .filter = "documentation.subject=\"x\" AND enabled=true" }));
    try testing.expect(std.mem.endsWith(u8, b.diag.message(), "No such field: documentation.subject."));
    try expectNames(&.{}, try b.listed(a, .{ .filter = "user_labels.team=\"ingest\"" }));
    try expectNames(&.{ "log", "mql", "absence", "promql", "two", "threshold" }, try b.listed(a, .{ .filter = "user_labels.team!=\"ingest\"" }));
    try expectNames(&.{"threshold"}, try b.listed(a, .{ .filter = "display_name=ends_with(\"hold\")" }));
    try expectNames(&.{"threshold"}, try b.listed(a, .{ .filter = "documentation.content=has_substring(\"RATE OVER\")" }));
}

test "pages: totalSize on every page, a token while more remain, {} for none" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.putProbePolicies();
    var first = try b.client.listAlertPolicies(.{ .filter = "display_name=starts_with(\"zigps-d5b8f4\")", .page_size = 1 });
    defer first.deinit();
    try testing.expectEqual(1, first.value.policies.len);
    try testing.expectEqualStrings("zigps-d5b8f4-log", first.value.policies[0].display_name);
    try testing.expectEqual(6, first.value.total_size.?);
    var second = try b.client.listAlertPolicies(.{ .filter = "display_name=starts_with(\"zigps-d5b8f4\")", .page_size = 1, .page_token = first.value.next_page_token.? });
    defer second.deinit();
    // Production's page 2 was the mql policy, totalSize 6 again.
    try testing.expectEqualStrings("zigps-d5b8f4-mql", second.value.policies[0].display_name);
    try testing.expectEqual(6, second.value.total_size.?);
    var all = try b.client.listAlertPolicies(.{ .page_size = 1001 });
    defer all.deinit();
    try testing.expectEqual(6, all.value.policies.len);
    try testing.expectEqual(null, all.value.next_page_token);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const none = try b.raw(arena.allocator(), .GET, "alertPolicies?filter=enabled%3Dfalse%20AND%20conditions.size%3E1", null);
    try testing.expectEqualStrings("{}", none.body);
}

test "refusals in production's words" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.putProbePolicies();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { types.ListAlertPoliciesOptions, []const u8 }{
        .{ .{ .filter = "severity=\"WARNING\"" }, production.policy_filter_severity },
        .{ .{ .filter = "zigps-d5b8f4" }, production.policy_filter_bare },
        .{ .{ .filter = "display_name=(" }, production.policy_filter_syntax },
        .{ .{ .filter = "display_name=starts_with(\"zigps-d5b8f4\")", .order_by = "display_name desc" }, production.policy_order_desc_word },
    }) |case| {
        try testing.expectError(error.InvalidArgument, b.client.listAlertPolicies(case[0]));
        try testing.expectEqualStrings(try messageOf(a, case[1]), b.diag.message());
    }
    try testing.expectError(error.NotFound, b.client.getAlertPolicy("1234567890"));
    try testing.expectEqualStrings(try messageOf(a, production.policy_unknown), b.diag.message());
    try testing.expectError(error.NotFound, b.client.setAlertPolicyEnabled("1234567890", false));
    try testing.expectEqualStrings(try messageOf(a, production.policy_patch_unknown), b.diag.message());
}

test "disable and enable: the whole policy answered, the mutation record moved each time" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.putProbePolicies();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const want = try codec.decodeAlertPolicy(arena.allocator(), arena.allocator(), production.policy_disabled);

    b.clock.now_ns = ts("2026-10-20T18:56:08Z").nanoseconds;
    var off = try b.client.setAlertPolicyEnabled("9594883664150561401", false);
    defer off.deinit();
    try testing.expectEqual(want.enabled, off.value.enabled);
    try testing.expectEqual(want.conditions.len, off.value.conditions.len);
    try testing.expectEqual(ts("2026-10-20T18:56:08Z").nanoseconds, off.value.mutated.time.?.nanoseconds);
    try testing.expectEqualStrings(want.mutated.by, off.value.mutated.by);
    try testing.expectEqual(ts("2026-10-20T18:56:00Z").nanoseconds, off.value.created.time.?.nanoseconds);

    // A repeat: 200, the record moved again.
    b.clock.now_ns = ts("2026-10-20T18:56:11Z").nanoseconds;
    var again = try b.client.setAlertPolicyEnabled("9594883664150561401", false);
    defer again.deinit();
    try testing.expect(!again.value.enabled);
    try testing.expectEqual(ts("2026-10-20T18:56:11Z").nanoseconds, again.value.mutated.time.?.nanoseconds);
    var listed = try b.client.listAlertPolicies(.{ .filter = "enabled=false" });
    defer listed.deinit();
    try testing.expectEqual(2, listed.value.policies.len);

    // An empty body under the mask reads as true.
    const empty = try b.raw(arena.allocator(), .PATCH, "alertPolicies/9594883664150561401?updateMask=enabled", "{}");
    try testing.expectEqual(200, empty.status);
    try testing.expect(std.mem.indexOf(u8, empty.body, "\"enabled\":true") != null);
}

test "what the fake does not model answers 501; what putAlertPolicy refuses keeps nothing" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.putProbePolicies();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { Method, []const u8 }{
        .{ .POST, "alertPolicies" },
        .{ .DELETE, "alertPolicies/9594883664150561401" },
        .{ .PATCH, "alertPolicies/9594883664150561401" },
        .{ .PATCH, "alertPolicies/9594883664150561401?updateMask=display_name" },
        .{ .GET, "alertPolicies?filter=enabled%3Dtrue%20OR%20enabled%3Dfalse" },
        .{ .GET, "alertPolicies?filter=NOT%20enabled%3Dtrue" },
        .{ .GET, "alertPolicies?filter=display_name%3Dmonitoring.regex.full_match(%22x%22)" },
        .{ .GET, "alertPolicies?orderBy=enabled" },
        .{ .GET, "alertPolicies/9594883664150561401/conditions" },
    }) |c| {
        const reply = try b.raw(a, c[0], c[1], "{\"enabled\":false}");
        try testing.expectEqual(501, reply.status);
    }
    const base: FakeMonitoring.PutAlertPolicy = .{ .display_name = "x" };
    var bad = base;
    bad.id = "9594883664150561401";
    try testing.expectError(error.InvalidEntry, b.fake.putAlertPolicy(bad));
    bad = base;
    bad.id = "a/b";
    try testing.expectError(error.InvalidEntry, b.fake.putAlertPolicy(bad));
    bad = base;
    bad.severity = .unknown;
    try testing.expectError(error.InvalidEntry, b.fake.putAlertPolicy(bad));
    bad = base;
    bad.combiner = .unknown;
    try testing.expectError(error.InvalidEntry, b.fake.putAlertPolicy(bad));
    bad = base;
    bad.conditions = &.{.{ .kind = .unknown, .filter = "x" }};
    try testing.expectError(error.InvalidEntry, b.fake.putAlertPolicy(bad));
    bad = base;
    bad.conditions = &.{.{ .kind = .threshold }};
    try testing.expectError(error.InvalidEntry, b.fake.putAlertPolicy(bad));
    bad = base;
    bad.conditions = &.{.{ .kind = .promql }};
    try testing.expectError(error.InvalidEntry, b.fake.putAlertPolicy(bad));
    try testing.expectEqual(6, b.fake.alertPolicyCount());
    // An id assigned, digits, and a SQL condition written as one.
    const name = try b.fake.putAlertPolicy(.{ .conditions = &.{.{ .kind = .sql, .query = "SELECT 1" }} });
    const id = name["projects/extractctl/alertPolicies/".len..];
    for (id) |ch| try testing.expect(std.ascii.isDigit(ch));
    var got = try b.client.getAlertPolicy(name);
    defer got.deinit();
    try testing.expectEqual(types.ConditionKind.sql, got.value.conditions[0].kind);
}

test "faults on a patch: a dropped one is retried, and answers" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.putProbePolicies();
    b.fake.dropNext(1);
    var off = try b.client.setAlertPolicyEnabled("9594883664150561401", false);
    defer off.deinit();
    try testing.expect(!off.value.enabled);
    try testing.expectEqual(2, b.fake.callCount());
}
