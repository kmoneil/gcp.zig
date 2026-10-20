//! FakeMonitoring's alert policies and snoozes (issue #275): policies a
//! test puts in, listed, got and enabled or disabled, and snoozes made,
//! listed, got and ended through the API, as production answered on
//! 2026-10-20 (milestone 0 of the policies spec, `_tmp/policies-m0/`).
//! `FakeMonitoring` holds the `Store` and routes `alertPolicies` and
//! `snoozes` here, under its mutex.
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
//!
//! Snoozes:
//!
//! - A create is checked in production's order and words: a start more
//!   than 15 s in the past, more than 16 policies, a filter without
//!   exactly one policy, no display name, under a minute long. Policies
//!   need not exist, as production did not check. The answer carries
//!   the times as sent; reads after keep whole seconds. None can be
//!   deleted. A filter is resource labels joined by AND; another form,
//!   and a snooze of no policies, answer 501.
//! - Lists order by start, newest first, a later-made one first on a
//!   tie. Filters take `interval.start_time` and `interval.end_time`
//!   with `>=` and `<=`, joined by AND; `>`, `<`, `=`, `OR`, another
//!   field and an unquoted time are refused with production's reasons.
//!   Production wrote its own parse tree into those messages where this
//!   writes the filter: the reason after the last `": ` is production's.
//! - Ending: an active snooze's end moved at least a minute after its
//!   start, or to its start (cancelled); an upcoming one cancelled with
//!   both times now (15 s of skew); anything shorter, and any change to
//!   an ended or cancelled snooze, refused in production's words. A
//!   display name can be changed while a snooze is not ended. Moving an
//!   active snooze's start answers 501.
//! - An active snooze closes the open alerts of its policies at its start
//!   (production's closed within a second, its close time the next
//!   second) and keeps `putAlert` from opening one for them.
//! - Where it differs: a new snooze lists at once, where production's
//!   lists showed one anywhere from at once to 91 s after its create (a
//!   get, at once, as here).

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

const Snooze = struct {
    name: []const u8,
    id: []const u8,
    display_name: []const u8,
    policies: []const []const u8,
    filter: []const u8,
    /// The filter's resource labels.
    labels: []const types.Label,
    start_ns: i96,
    end_ns: i96,
    /// Its place in the order made, for ties in a list.
    made: u64,
    /// Cancelled before its start: it never held.
    never_held: bool = false,

    fn names(z: *const Snooze, policy: []const u8, resource_labels: []const types.Label) bool {
        for (z.policies) |p| {
            if (std.mem.eql(u8, p, policy)) return labelsMeet(z.labels, resource_labels);
        }
        return false;
    }

    fn ended(z: *const Snooze, now_ns: i96) bool {
        return z.start_ns == z.end_ns or z.end_ns <= now_ns;
    }

    /// Whether it held at `t`: from its start until its end, and at its
    /// start alone for one cancelled once running.
    fn heldAt(z: *const Snooze, t: i96) bool {
        if (z.never_held or t < z.start_ns) return false;
        return t < @max(z.end_ns, z.start_ns + 1);
    }
};

/// What FakeMonitoring holds for alert policies and snoozes.
pub const Store = struct {
    /// By id, in the order put in.
    policies: std.StringArrayHashMapUnmanaged(*Policy) = .empty,
    next_id: u64 = 0,
    /// By id, in the order made.
    snoozes: std.StringArrayHashMapUnmanaged(*Snooze) = .empty,
    next_snooze: u64 = 0,

    pub fn deinit(s: *Store, gpa: Allocator) void {
        s.policies.deinit(gpa);
        s.snoozes.deinit(gpa);
        s.* = undefined;
    }

    pub fn count(s: *const Store) usize {
        return s.policies.count();
    }

    pub fn snoozeCount(s: *const Store) usize {
        return s.snoozes.count();
    }

    /// Whether a snooze naming `policy`, whose filter (if any) the
    /// resource labels meet, holds at `t`.
    pub fn holdsAt(s: *const Store, policy: []const u8, resource_labels: []const types.Label, t: i96) bool {
        for (s.snoozes.values()) |z| {
            if (z.heldAt(t) and z.names(policy, resource_labels)) return true;
        }
        return false;
    }

    /// When an alert of `policy` opened at `open_ns` is closed by the
    /// snoozes begun by `now_ns`: at the start of the first whose window
    /// it was open in, or when it opened if that came later; null when
    /// none has closed it. Production closed one within a second of a
    /// snooze's start, so this holds whenever the fake is asked.
    pub fn closesAt(s: *const Store, policy: []const u8, resource_labels: []const types.Label, open_ns: i96, now_ns: i96) ?i96 {
        var first: ?i96 = null;
        for (s.snoozes.values()) |z| {
            if (z.never_held or z.start_ns > now_ns or !z.names(policy, resource_labels)) continue;
            if (open_ns >= @max(z.end_ns, z.start_ns + 1)) continue;
            const at = @max(z.start_ns, open_ns);
            if (first == null or at < first.?) first = at;
        }
        return first;
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

    /// `rest` is what follows `snoozes` and its `/` ("" for the
    /// collection).
    pub fn snoozeRoute(s: *Store, gpa: Allocator, keep: Allocator, arena: Allocator, ctx: Context, method: Method, rest: []const u8, params: []const Param, body: ?[]const u8) Allocator.Error!Reply {
        if (rest.len == 0) return switch (method) {
            .POST => s.createSnooze(gpa, keep, arena, ctx, body orelse ""),
            .GET => s.listSnoozes(arena, params),
            else => notModelled(arena, "this method on snoozes"),
        };
        const id = try decoded(arena, rest);
        if (std.mem.indexOfScalar(u8, id, '/') != null) return notModelled(arena, "this path under a snooze");
        switch (method) {
            .GET => {
                const z = s.snoozes.get(id) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("The snooze (with id {s}) was not found.", .{id}));
                return renderSnooze(arena, z, null);
            },
            .PATCH => return s.patchSnooze(keep, arena, ctx, id, params, body orelse ""),
            .DELETE => return notModelled(arena, "deleting a snooze, which production has no method for"),
            else => return notModelled(arena, "this method on a snooze"),
        }
    }

    fn createSnooze(s: *Store, gpa: Allocator, keep: Allocator, arena: Allocator, ctx: Context, body: []const u8) Allocator.Error!Reply {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
            return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        const obj = switch (v) {
            .object => |o| o,
            else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
        };
        const display_name = stringIn(obj, "displayName") orelse "";
        var policies: []const []const u8 = &.{};
        var filter: []const u8 = "";
        if (objectIn(obj, "criteria")) |c| {
            filter = stringIn(c, "filter") orelse "";
            if (c.get("policies")) |given| switch (given) {
                .array => |items| {
                    const out = try arena.alloc([]const u8, items.items.len);
                    for (items.items, out) |p, *o| o.* = switch (p) {
                        .string => |text| text,
                        else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
                    };
                    policies = out;
                },
                else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
            };
        }
        const interval = objectIn(obj, "interval") orelse return notModelled(arena, "a snooze without an interval");
        const start = timeIn(interval, "startTime") orelse return notModelled(arena, "a snooze without a start time");
        const end = timeIn(interval, "endTime") orelse return notModelled(arena, "a snooze without an end time");
        // Production's checks, in the order the fake asks them.
        if (start.nanoseconds < ctx.now_ns - skew_ns) return fail(arena, 400, "INVALID_ARGUMENT", "The Snooze cannot start in the past.");
        if (policies.len > validate.max_snooze_policies) return fail(arena, 400, "INVALID_ARGUMENT", "The criteria cannot have more than 16 policies that the Snooze applies to.");
        if (filter.len > 0 and policies.len != 1) return fail(arena, 400, "INVALID_ARGUMENT", "The criteria must have exactly one policy given a non-empty filter.");
        if (display_name.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "The Snooze must have a display name.");
        const start_s = wholeSecondsNs(start.nanoseconds);
        const end_s = wholeSecondsNs(end.nanoseconds);
        if (end_s - start_s < min_snooze_ns) return fail(arena, 400, "INVALID_ARGUMENT", "The snooze duration must be >= 1m.");
        if (policies.len == 0) return notModelled(arena, "a snooze of no policies");
        const labels = labelsOfFilter(arena, filter) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotModelled => return notModelled(arena, "a snooze filter other than resource labels joined by AND"),
        };

        s.next_snooze += 1;
        const id = try std.fmt.allocPrint(keep, "{d}", .{@as(u128, 100_000_000_000_000_000_000_000_000_000_000_000) + s.next_snooze});
        const held = try keep.create(Snooze);
        const kept_policies = try keep.alloc([]const u8, policies.len);
        for (policies, kept_policies) |p, *o| o.* = try keep.dupe(u8, p);
        held.* = .{
            .name = try std.fmt.allocPrint(keep, "projects/{s}/snoozes/{s}", .{ ctx.project, id }),
            .id = id,
            .display_name = try keep.dupe(u8, display_name),
            .policies = kept_policies,
            .filter = try keep.dupe(u8, filter),
            .labels = try dupeLabels(keep, labels),
            .start_ns = start_s,
            .end_ns = end_s,
            .made = s.next_snooze,
        };
        try s.snoozes.put(gpa, held.id, held);
        // The answer carries the times as sent, as production's did.
        return renderSnooze(arena, held, .{ start.nanoseconds, end.nanoseconds });
    }

    fn listSnoozes(s: *Store, arena: Allocator, params: []const Param) Allocator.Error!Reply {
        var bounds: []const Bound = &.{};
        if (paramOf(params, "filter")) |text| switch (try parseSnoozeFilter(arena, text)) {
            .ok => |b| bounds = b,
            .reply => |r| return r,
        };
        var matched: std.ArrayList(*Snooze) = .empty;
        for (s.snoozes.values()) |z| {
            if (meetsBounds(z, bounds)) try matched.append(arena, z);
        }
        std.mem.sort(*Snooze, matched.items, {}, struct {
            fn before(_: void, a: *Snooze, b: *Snooze) bool {
                if (a.start_ns != b.start_ns) return a.start_ns > b.start_ns;
                return a.made > b.made;
            }
        }.before);
        const window = pageOf(params, matched.items.len) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid page token or page size.");
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        write: {
            jw.beginObject() catch break :write;
            if (window.to > window.from) {
                jw.objectField("snoozes") catch break :write;
                jw.beginArray() catch break :write;
                for (matched.items[window.from..window.to]) |z| writeSnooze(&jw, z, null) catch break :write;
                jw.endArray() catch break :write;
            }
            if (window.next) |n| {
                jw.objectField("nextPageToken") catch break :write;
                jw.print("\"p{d}\"", .{n}) catch break :write;
            }
            jw.endObject() catch break :write;
            return .{ .status = 200, .body = out.written() };
        }
        return error.OutOfMemory;
    }

    fn patchSnooze(s: *Store, keep: Allocator, arena: Allocator, ctx: Context, id: []const u8, params: []const Param, body: []const u8) Allocator.Error!Reply {
        const z = s.snoozes.get(id) orelse return fail(arena, 404, "NOT_FOUND", try arena.print("The snooze to update (with id {s}) was not found.", .{id}));
        if (z.ended(ctx.now_ns)) return fail(arena, 400, "FAILED_PRECONDITION", "Cannot update a snooze that already ended, or that was canceled.");
        const mask = paramOf(params, "updateMask") orelse return notModelled(arena, "a snooze patch without updateMask");
        var set_name = false;
        var set_start = false;
        var set_end = false;
        var fields = std.mem.splitScalar(u8, mask, ',');
        while (fields.next()) |raw| {
            const f = std.mem.trim(u8, raw, " ");
            if (std.mem.eql(u8, f, "display_name")) {
                set_name = true;
            } else if (std.mem.eql(u8, f, "interval.start_time")) {
                set_start = true;
            } else if (std.mem.eql(u8, f, "interval.end_time")) {
                set_end = true;
            } else return notModelled(arena, "a snooze patch of a field other than display_name and the interval's times");
        }
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
            return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
        const obj = switch (v) {
            .object => |o| o,
            else => return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received."),
        };
        var start = z.start_ns;
        var end = z.end_ns;
        if (set_start or set_end) {
            const interval = objectIn(obj, "interval") orelse return notModelled(arena, "an interval patch without an interval");
            if (set_start) start = wholeSecondsNs((timeIn(interval, "startTime") orelse return notModelled(arena, "a start patch without a start")).nanoseconds);
            if (set_end) end = wholeSecondsNs((timeIn(interval, "endTime") orelse return notModelled(arena, "an end patch without an end")).nanoseconds);
        }
        const upcoming = ctx.now_ns < z.start_ns;
        if (set_start or set_end) {
            if (upcoming) {
                if (end == start) {
                    // Production cancels an upcoming snooze only with both
                    // times set to now.
                    const now_s = wholeSecondsNs(ctx.now_ns);
                    if (!set_start or @abs(start - now_s) > skew_ns) return fail(arena, 400, "INVALID_ARGUMENT", "An upcoming snooze's start and end time must be set to the current time to cancel it.");
                    z.never_held = true;
                } else if (end - start < min_snooze_ns) {
                    return fail(arena, 400, "INVALID_ARGUMENT", "The snooze duration must be >= 1m, unless the snooze is being canceled, in which case it should be of length 0.");
                }
            } else {
                if (start != z.start_ns) return notModelled(arena, "moving an active snooze's start");
                if (end != start and end - start < min_snooze_ns) return fail(arena, 400, "INVALID_ARGUMENT", "The snooze duration must be >= 1m, unless the snooze is being canceled, in which case it should be of length 0.");
            }
        }
        if (set_name) {
            const name = stringIn(obj, "displayName") orelse "";
            if (name.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "The Snooze must have a display name.");
            z.display_name = try keep.dupe(u8, name);
        }
        z.start_ns = start;
        z.end_ns = end;
        return renderSnooze(arena, z, null);
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

/// Production allows a snooze's start 15 s of clock skew.
const skew_ns: i96 = 15 * std.time.ns_per_s;
const min_snooze_ns: i96 = @as(i96, validate.min_snooze_seconds) * std.time.ns_per_s;

fn wholeSecondsNs(ns: i96) i96 {
    return @divFloor(ns, std.time.ns_per_s) * std.time.ns_per_s;
}

fn stringIn(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn objectIn(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    return switch (obj.get(name) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn timeIn(obj: std.json.ObjectMap, name: []const u8) ?std.Io.Timestamp {
    return core.timestamp.parse(stringIn(obj, name) orelse return null) catch null;
}

/// A snooze filter's resource labels: `resource.labels.k="v"`, joined
/// by AND. "" is none.
fn labelsOfFilter(arena: Allocator, filter: []const u8) error{ OutOfMemory, NotModelled }![]const types.Label {
    var labels: std.ArrayList(types.Label) = .empty;
    if (filter.len == 0) return labels.items;
    var parts = std.mem.splitSequence(u8, filter, " AND ");
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        const prefix = "resource.labels.";
        if (!std.mem.startsWith(u8, part, prefix)) return error.NotModelled;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.NotModelled;
        const key = std.mem.trim(u8, part[prefix.len..eq], " ");
        const value = quotedOf(std.mem.trim(u8, part[eq + 1 ..], " ")) orelse return error.NotModelled;
        if (key.len == 0) return error.NotModelled;
        try labels.append(arena, .{ .key = key, .value = value });
    }
    return labels.items;
}

fn labelsMeet(want: []const types.Label, have: []const types.Label) bool {
    for (want) |w| {
        for (have) |h| {
            if (std.mem.eql(u8, w.key, h.key) and std.mem.eql(u8, w.value, h.value)) break;
        } else return false;
    }
    return true;
}

const Bound = struct { start: bool, at_most: bool, t: i96 };

fn parseSnoozeFilter(arena: Allocator, filter: []const u8) Allocator.Error!Parsed([]const Bound) {
    if (std.mem.indexOf(u8, filter, " OR ") != null) return .{ .reply = try snoozeFilterRefusal(arena, filter, "Only restrictions and conjunctions are supported.") };
    var bounds: std.ArrayList(Bound) = .empty;
    var parts = std.mem.splitSequence(u8, filter, " AND ");
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        const at = operatorAt(part) orelse return .{ .reply = try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field filter had an invalid value of \"{s}\": Invalid filter syntax.", .{filter})) };
        const lhs = std.mem.trim(u8, part[0..at.index], " ");
        const rhs = std.mem.trim(u8, part[at.index + at.len ..], " ");
        const text = quotedOf(rhs) orelse return .{ .reply = try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field filter had an invalid value of \"{s}\": Invalid filter syntax.", .{filter})) };
        const is_start = std.mem.eql(u8, lhs, "interval.start_time");
        if (!is_start and !std.mem.eql(u8, lhs, "interval.end_time")) {
            if (std.mem.startsWith(u8, lhs, "interval.")) return .{ .reply = try snoozeFilterRefusal(arena, filter, try arena.print("Not a valid left-hand value: \"{s}\"; expecting one of {{interval.start_time, interval.end_time}}.", .{lhs})) };
            return .{ .reply = try snoozeFilterRefusal(arena, filter, try arena.print("Unrecognized filter property: {s}", .{lhs})) };
        }
        switch (at.op) {
            .ge, .le => {},
            // Production refused `=` on a time as it does a property it
            // does not know.
            .eq => return .{ .reply = try snoozeFilterRefusal(arena, filter, try arena.print("Unrecognized filter property: {s}", .{lhs})) },
            else => return .{ .reply = try snoozeFilterRefusal(arena, filter, "Only equality, greater than or equals comparison and less than or equals comparison restrictions are supported.") },
        }
        const t = core.timestamp.parse(text) catch return .{ .reply = try fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field filter had an invalid value of \"{s}\": Invalid filter syntax.", .{filter})) };
        try bounds.append(arena, .{ .start = is_start, .at_most = at.op == .le, .t = t.nanoseconds });
    }
    return .{ .ok = bounds.items };
}

/// Production wrote its parse tree where this writes the filter; the
/// reason after it is production's.
fn snoozeFilterRefusal(arena: Allocator, filter: []const u8, reason: []const u8) Allocator.Error!Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("Field filter had an invalid value of \"{s}\": {s}", .{ filter, reason }));
}

fn meetsBounds(z: *const Snooze, bounds: []const Bound) bool {
    for (bounds) |b| {
        const v = if (b.start) z.start_ns else z.end_ns;
        if (b.at_most and v > b.t) return false;
        if (!b.at_most and v < b.t) return false;
    }
    return true;
}

fn renderSnooze(arena: Allocator, z: *const Snooze, sent: ?[2]i96) Allocator.Error!Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSnooze(&jw, z, sent) catch return error.OutOfMemory;
    return .{ .status = 200, .body = out.written() };
}

/// In production's field order. `sent` is a create's times as sent,
/// which its answer carries in place of the whole seconds kept.
fn writeSnooze(jw: *Stringify, z: *const Snooze, sent: ?[2]i96) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(z.name);
    try jw.objectField("criteria");
    try jw.beginObject();
    try jw.objectField("policies");
    try jw.write(z.policies);
    if (z.filter.len > 0) {
        try jw.objectField("filter");
        try jw.write(z.filter);
    }
    try jw.endObject();
    try jw.objectField("interval");
    try jw.beginObject();
    try jw.objectField("startTime");
    try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = if (sent) |t| t[0] else z.start_ns }));
    try jw.objectField("endTime");
    try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = if (sent) |t| t[1] else z.end_ns }));
    try jw.endObject();
    try jw.objectField("displayName");
    try jw.write(z.display_name);
    try jw.endObject();
}

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

// Snoozes, held to what production answered in milestone 0.

fn snoozeBody(arena: Allocator, name: []const u8, policies: []const u8, start: []const u8, end: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"displayName\":\"{s}\",\"criteria\":{{\"policies\":{s}}},\"interval\":{{\"startTime\":\"{s}\",\"endTime\":\"{s}\"}}}}", .{ name, policies, start, end });
}

test "snoozes: made with the times as sent, read back in whole seconds, listed newest start first" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    b.clock.now_ns = ts("2026-10-20T18:56:15Z").nanoseconds;
    const made = try b.raw(a, .POST, "snoozes", try snoozeBody(a, "zigps-d5b8f4-active", "[\"projects/extractctl/alertPolicies/9594883664150561401\"]", "2026-10-20T18:56:34.868813Z", "2026-10-20T18:58:34.868813Z"));
    try testing.expectEqual(200, made.status);
    const want = try codec.decodeSnooze(a, a, production.snooze_created_micros);
    const got = try codec.decodeSnooze(a, a, made.body);
    try testing.expectEqual(want.start.nanoseconds, got.start.nanoseconds);
    try testing.expectEqual(want.end.nanoseconds, got.end.nanoseconds);
    try testing.expectEqualStrings(want.display_name, got.display_name);
    try testing.expectEqualStrings(want.policies[0], got.policies[0]);
    var read = try b.client.getSnooze(got.id);
    defer read.deinit();
    const want_read = try codec.decodeSnooze(a, a, production.snooze_read);
    try testing.expectEqual(want_read.start.nanoseconds, read.value.start.nanoseconds);
    try testing.expectEqual(want_read.end.nanoseconds, read.value.end.nanoseconds);

    // A policy nobody has is taken, as production took it.
    var nobody = try b.client.createSnooze(.{ .display_name = "zigps-d5b8f4-nobody", .policies = &.{"1234567890"}, .start = ts("2026-10-20T19:11:14Z"), .end = ts("2026-10-20T19:12:14Z") });
    nobody.deinit();
    var upcoming = try b.client.createSnooze(.{ .display_name = "zigps-d5b8f4-upcoming", .policies = &.{ "9594883664150561401", "4294582767119635845" }, .start = ts("2026-10-20T19:06:14Z"), .end = ts("2026-10-20T19:07:14Z") });
    upcoming.deinit();
    // Ninety seconds long: production has no whole-minutes rule.
    var odd = try b.client.createSnooze(.{ .display_name = "zigps-d5b8f4-odd", .policies = &.{"9594883664150561401"}, .start = ts("2026-10-20T19:11:14Z"), .end = ts("2026-10-20T19:12:44Z") });
    odd.deinit();
    try testing.expectEqual(4, b.fake.snoozeCount());
    // Production's order: start, newest first; a later-made one first on
    // a tie (odd made after nobody, both at 19:11:14).
    var page = try b.client.listSnoozes(.{});
    defer page.deinit();
    const order = [_][]const u8{ "zigps-d5b8f4-odd", "zigps-d5b8f4-nobody", "zigps-d5b8f4-upcoming", "zigps-d5b8f4-active" };
    try testing.expectEqual(order.len, page.value.snoozes.len);
    for (order, page.value.snoozes) |w, g| try testing.expectEqualStrings(w, g.display_name);
    const want_page = try codec.decodeSnoozePage(a, a, production.snooze_page);
    for (want_page.snoozes, page.value.snoozes) |w, g| try testing.expectEqualStrings(w.display_name, g.display_name);
    var paged = try b.client.listSnoozes(.{ .page_size = 1 });
    defer paged.deinit();
    try testing.expect(paged.value.next_page_token != null);
}

test "snoozes: creation refused in production's words" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    b.clock.now_ns = ts("2026-10-20T18:56:15Z").nanoseconds;
    const one = "[\"projects/extractctl/alertPolicies/9594883664150561401\"]";
    var seventeen: std.Io.Writer.Allocating = .init(a);
    try seventeen.writer.writeByte('[');
    for (0..17) |i| try seventeen.writer.print("{s}\"projects/extractctl/alertPolicies/9594883664150561401\"", .{if (i == 0) "" else ","});
    try seventeen.writer.writeByte(']');
    for ([_]struct { []const u8, []const u8 }{
        .{ try snoozeBody(a, "zigps-d5b8f4-past", one, "2026-10-20T18:54:15Z", "2026-10-20T18:58:15Z"), production.snooze_past_start },
        .{ try snoozeBody(a, "zigps-d5b8f4-17", seventeen.written(), "2026-10-20T19:11:15Z", "2026-10-20T19:12:15Z"), production.snooze_seventeen },
        .{ "{\"displayName\":\"zigps-d5b8f4-filter\",\"criteria\":{\"policies\":[\"a\",\"b\"],\"filter\":\"resource.labels.topic_id=\\\"x\\\"\"},\"interval\":{\"startTime\":\"2026-10-20T19:11:15Z\",\"endTime\":\"2026-10-20T19:12:15Z\"}}", production.snooze_filter_two },
        .{ "{\"criteria\":{\"policies\":[\"a\"]},\"interval\":{\"startTime\":\"2026-10-20T19:11:15Z\",\"endTime\":\"2026-10-20T19:12:15Z\"}}", production.snooze_no_name },
        .{ try snoozeBody(a, "zigps-d5b8f4-backwards", one, "2026-10-20T19:12:15Z", "2026-10-20T19:11:15Z"), production.snooze_backwards },
        // Under a minute, the same words: the rule production named.
        .{ try snoozeBody(a, "zigps-d5b8f4-short", one, "2026-10-20T19:11:15Z", "2026-10-20T19:12:14Z"), production.snooze_backwards },
    }) |case| {
        const reply = try b.raw(a, .POST, "snoozes", case[0]);
        try testing.expectEqual(400, reply.status);
        try testing.expectEqualStrings(try messageOf(a, case[1]), try messageOf(a, reply.body));
    }
    try testing.expectEqual(0, b.fake.snoozeCount());
    // 15 s of skew are allowed.
    try testing.expectEqual(200, (try b.raw(a, .POST, "snoozes", try snoozeBody(a, "zigps-skew", one, "2026-10-20T18:56:01Z", "2026-10-20T18:58:01Z"))).status);
    // What the fake does not model.
    try testing.expectEqual(501, (try b.raw(a, .POST, "snoozes", try snoozeBody(a, "none", "[]", "2026-10-20T19:11:15Z", "2026-10-20T19:12:15Z"))).status);
    try testing.expectEqual(501, (try b.raw(a, .POST, "snoozes", "{\"displayName\":\"f\",\"criteria\":{\"policies\":[\"a\"],\"filter\":\"metric.type=\\\"x\\\"\"},\"interval\":{\"startTime\":\"2026-10-20T19:11:15Z\",\"endTime\":\"2026-10-20T19:12:15Z\"}}")).status);
    try testing.expectEqual(501, (try b.raw(a, .DELETE, "snoozes/1", null)).status);
}

test "snoozes: list filters as production took them, and refused them" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    b.clock.now_ns = ts("2026-10-20T18:58:29Z").nanoseconds;
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "late", "2026-10-20T19:28:29Z", "2026-10-20T19:29:29Z" },
        .{ "early", "2026-10-20T19:18:29Z", "2026-10-20T19:19:29Z" },
        .{ "active", "2026-10-20T18:58:49Z", "2026-10-20T19:08:29Z" },
        .{ "young", "2026-10-20T18:58:49Z", "2026-10-20T19:08:29Z" },
    }) |s| {
        var made = try b.client.createSnooze(.{ .display_name = s[0], .policies = &.{"1234567890"}, .start = ts(s[1]), .end = ts(s[2]) });
        made.deinit();
    }
    b.clock.now_ns = ts("2026-10-20T18:58:55Z").nanoseconds;
    const Case = struct { ?[]const u8, ?std.Io.Timestamp, []const []const u8 };
    for ([_]Case{
        .{ null, ts("2026-10-20T18:58:55Z"), &.{ "young", "active" } },
        .{ "interval.end_time >= \"2026-10-20T18:58:55Z\"", null, &.{ "late", "early", "young", "active" } },
        .{ "interval.start_time >= \"2026-10-20T18:58:55Z\"", null, &.{ "late", "early" } },
        .{ "interval.end_time >= \"2026-10-20T13:58:55-05:00\"", null, &.{ "late", "early", "young", "active" } },
    }) |case| {
        var page = try b.client.listSnoozes(.{ .filter = case[0], .active_at = case[1] });
        defer page.deinit();
        try testing.expectEqual(case[2].len, page.value.snoozes.len);
        for (case[2], page.value.snoozes) |w, g| try testing.expectEqualStrings(w, g.display_name);
    }
    for ([_]struct { []const u8, []const u8 }{
        .{ "interval.end_time > \"2026-10-20T18:56:41.506362Z\"", production.snooze_filter_greater },
        .{ "interval.start_time >= \"2026-10-20T18:58:55Z\" OR interval.end_time <= \"2026-10-20T18:58:55Z\"", production.snooze_filter_or },
        .{ "display_name = \"zigps-d5b8f4-active\"", production.snooze_filter_display_name },
    }) |case| {
        try testing.expectError(error.InvalidArgument, b.client.listSnoozes(.{ .filter = case[0] }));
        const want = try messageOf(a, case[1]);
        // The reason after production's parse tree is production's.
        const reason = want[std.mem.lastIndexOf(u8, want, "\": ").? + 3 ..];
        try testing.expect(std.mem.endsWith(u8, b.diag.message(), reason));
    }
    try testing.expectError(error.InvalidArgument, b.client.listSnoozes(.{ .filter = "interval.end_time >= 2026-10-20T18:58:55Z" }));
    try testing.expectEqualStrings(try messageOf(a, production.snooze_filter_unquoted), b.diag.message());
    try testing.expectError(error.InvalidArgument, b.client.listSnoozes(.{ .filter = "interval.endTime >= \"2026-10-20T18:58:55Z\"" }));
    try testing.expect(std.mem.endsWith(u8, b.diag.message(), "Not a valid left-hand value: \"interval.endTime\"; expecting one of {interval.start_time, interval.end_time}."));
    try testing.expectError(error.InvalidArgument, b.client.listSnoozes(.{ .filter = "interval.end_time = \"2026-10-20T19:29:29Z\"" }));
    try testing.expect(std.mem.endsWith(u8, b.diag.message(), "Unrecognized filter property: interval.end_time"));
}

test "snoozes: ended in each of production's forms, and every change after refused" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    b.clock.now_ns = ts("2026-10-20T18:58:29Z").nanoseconds;
    var active = try b.client.createSnooze(.{ .display_name = "active", .policies = &.{"1"}, .start = ts("2026-10-20T18:58:49Z"), .end = ts("2026-10-20T19:08:29Z") });
    defer active.deinit();
    var young = try b.client.createSnooze(.{ .display_name = "young", .policies = &.{"1"}, .start = ts("2026-10-20T18:58:49Z"), .end = ts("2026-10-20T19:08:29Z") });
    defer young.deinit();
    var upcoming = try b.client.createSnooze(.{ .display_name = "late", .policies = &.{"1"}, .start = ts("2026-10-20T19:28:29Z"), .end = ts("2026-10-20T19:29:29Z") });
    defer upcoming.deinit();

    // Under a minute old, the end moved to now: production's 400.
    b.clock.now_ns = ts("2026-10-20T18:58:58Z").nanoseconds;
    const young_path = try std.fmt.allocPrint(a, "snoozes/{s}?updateMask=interval.end_time", .{young.value.id});
    const short = try b.raw(a, .PATCH, young_path, "{\"interval\":{\"endTime\":\"2026-10-20T18:58:58Z\"}}");
    try testing.expectEqualStrings(try messageOf(a, production.snooze_too_short), try messageOf(a, short.body));
    // The client cancels it instead: its end its start.
    var cancelled = try b.client.endSnooze(young.value, std.Io.Clock.real.now(b.clock.io()));
    defer cancelled.deinit();
    const want_cancelled = try codec.decodeSnooze(a, a, production.snooze_cancelled_active);
    try testing.expect(cancelled.value.cancelled());
    try testing.expectEqual(want_cancelled.start.nanoseconds, cancelled.value.end.nanoseconds);

    // Upcoming: the end alone moved to the start is refused; both now
    // cancels it.
    const late_path = try std.fmt.allocPrint(a, "snoozes/{s}?updateMask=interval.end_time", .{upcoming.value.id});
    const end_only = try b.raw(a, .PATCH, late_path, "{\"interval\":{\"endTime\":\"2026-10-20T19:28:29Z\"}}");
    try testing.expectEqualStrings(try messageOf(a, production.snooze_cancel_upcoming_end_only), try messageOf(a, end_only.body));
    var late_cancelled = try b.client.endSnooze(upcoming.value, std.Io.Clock.real.now(b.clock.io()));
    defer late_cancelled.deinit();
    try testing.expect(late_cancelled.value.cancelled());
    try testing.expectEqual(ts("2026-10-20T18:58:58Z").nanoseconds, late_cancelled.value.start.nanoseconds);

    // Over a minute old: its end now. A display name can change first.
    b.clock.now_ns = ts("2026-10-20T19:00:03Z").nanoseconds;
    const active_name_path = try std.fmt.allocPrint(a, "snoozes/{s}?updateMask=display_name", .{active.value.id});
    const renamed = try b.raw(a, .PATCH, active_name_path, "{\"displayName\":\"renamed\"}");
    try testing.expectEqual(200, renamed.status);
    var ended = try b.client.endSnooze(active.value, std.Io.Clock.real.now(b.clock.io()));
    defer ended.deinit();
    const want_ended = try codec.decodeSnooze(a, a, production.snooze_ended);
    try testing.expectEqual(want_ended.end.nanoseconds, ended.value.end.nanoseconds);
    try testing.expectEqualStrings("renamed", ended.value.display_name);

    // Every change after: production's FAILED_PRECONDITION, a repeat
    // included.
    b.clock.now_ns = ts("2026-10-20T19:00:07Z").nanoseconds;
    for ([_][]const u8{ active.value.id, young.value.id, upcoming.value.id }) |id| {
        const again = try b.raw(a, .PATCH, try std.fmt.allocPrint(a, "snoozes/{s}?updateMask=interval.end_time", .{id}), "{\"interval\":{\"endTime\":\"2026-10-20T19:00:03Z\"}}");
        try testing.expectEqual(400, again.status);
        try testing.expectEqualStrings(try messageOf(a, production.snooze_already_ended), try messageOf(a, again.body));
    }
    // Nobody's: production's 404 for a get and for a patch.
    try testing.expectError(error.NotFound, b.client.getSnooze("1234567890"));
    try testing.expectEqualStrings(try messageOf(a, production.snooze_unknown), b.diag.message());
    const unknown = try b.raw(a, .PATCH, "snoozes/1234567890?updateMask=interval.end_time", "{\"interval\":{\"endTime\":\"2026-10-20T19:00:03Z\"}}");
    try testing.expectEqualStrings(try messageOf(a, production.snooze_patch_unknown), try messageOf(a, unknown.body));
    // Not modelled: another field, moving an active one's start.
    b.clock.now_ns = ts("2026-10-20T19:10:00Z").nanoseconds;
    var running = try b.client.createSnooze(.{ .display_name = "running", .policies = &.{"1"}, .start = ts("2026-10-20T19:10:00Z"), .end = ts("2026-10-20T19:20:00Z") });
    defer running.deinit();
    b.clock.now_ns = ts("2026-10-20T19:12:00Z").nanoseconds;
    try testing.expectEqual(501, (try b.raw(a, .PATCH, try std.fmt.allocPrint(a, "snoozes/{s}?updateMask=criteria", .{running.value.id}), "{}")).status);
    try testing.expectEqual(501, (try b.raw(a, .PATCH, try std.fmt.allocPrint(a, "snoozes/{s}?updateMask=interval.start_time", .{running.value.id}), "{\"interval\":{\"startTime\":\"2026-10-20T19:11:00Z\"}}")).status);
}

test "an active snooze closes its policies' open alerts at its start, and opens none until it ends" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const policy = "projects/extractctl/alertPolicies/42";
    b.clock.now_ns = ts("2026-10-20T19:04:19Z").nanoseconds;
    const open = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:04:19Z"), .policy = .{ .name = policy, .display_name = "zigps-snooze" } });
    const other = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:04:19Z"), .policy = .{ .name = "projects/extractctl/alertPolicies/7", .display_name = "other" } });
    var snooze = try b.client.createSnooze(.{ .display_name = "zigps-snooze", .policies = &.{"42"}, .start = ts("2026-10-20T19:04:39Z"), .end = ts("2026-10-20T19:14:39Z") });
    defer snooze.deinit();
    // Before the start, still open.
    var before = try b.client.getAlert(open);
    defer before.deinit();
    try testing.expectEqual(types.AlertState.open, before.value.state);
    b.clock.now_ns = ts("2026-10-20T19:04:41Z").nanoseconds;
    var closed = try b.client.getAlert(open);
    defer closed.deinit();
    try testing.expectEqual(types.AlertState.closed, closed.value.state);
    try testing.expectEqual(ts("2026-10-20T19:04:39Z").nanoseconds, closed.value.close_time.?.nanoseconds);
    var untouched = try b.client.getAlert(other);
    defer untouched.deinit();
    try testing.expectEqual(types.AlertState.open, untouched.value.state);
    // None opens while it holds.
    try testing.expectError(error.InvalidEntry, b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:05:00Z"), .policy = .{ .name = policy } }));
    // Ended a minute in: the policy's alerts open again.
    b.clock.now_ns = ts("2026-10-20T19:05:58Z").nanoseconds;
    var ended = try b.client.endSnooze(snooze.value, std.Io.Clock.real.now(b.clock.io()));
    ended.deinit();
    _ = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:07:15Z"), .policy = .{ .name = policy } });
    b.clock.now_ns = ts("2026-10-20T19:07:16Z").nanoseconds;
    var open_now = try b.client.listAlerts(.{ .open_only = true });
    defer open_now.deinit();
    try testing.expectEqual(2, open_now.value.alerts.len);
}

test "a snooze with a filter closes only the alerts whose resource labels meet it" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    const policy = "projects/extractctl/alertPolicies/42";
    b.clock.now_ns = ts("2026-10-20T19:00:00Z").nanoseconds;
    const a_zone = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:00:00Z"), .policy = .{ .name = policy }, .resource_labels = &.{.{ .key = "zone", .value = "us-central1-a" }} });
    const b_zone = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:00:00Z"), .policy = .{ .name = policy }, .resource_labels = &.{.{ .key = "zone", .value = "us-central1-b" }} });
    var snooze = try b.client.createSnooze(.{ .display_name = "zone a", .policies = &.{"42"}, .filter = "resource.labels.zone=\"us-central1-a\"", .start = ts("2026-10-20T19:00:10Z"), .end = ts("2026-10-20T20:00:00Z") });
    defer snooze.deinit();
    try testing.expectEqualStrings("resource.labels.zone=\"us-central1-a\"", snooze.value.filter);
    b.clock.now_ns = ts("2026-10-20T19:00:11Z").nanoseconds;
    var x = try b.client.getAlert(a_zone);
    defer x.deinit();
    try testing.expectEqual(types.AlertState.closed, x.value.state);
    var y = try b.client.getAlert(b_zone);
    defer y.deinit();
    try testing.expectEqual(types.AlertState.open, y.value.state);
}

test "regression: a snooze that starts and ends between two requests still closed the alert it held over" {
    // The fake closed alerts only for a snooze holding at a request, so
    // one that began and ended between two left its policy's alert open,
    // where production would have closed it within a second of the start.
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    const policy = "projects/extractctl/alertPolicies/42";
    b.clock.now_ns = ts("2026-10-20T19:00:00Z").nanoseconds;
    const held = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:00:00Z"), .policy = .{ .name = policy } });
    var snooze = try b.client.createSnooze(.{ .display_name = "brief", .policies = &.{"42"}, .start = ts("2026-10-20T19:01:00Z"), .end = ts("2026-10-20T19:02:00Z") });
    snooze.deinit();
    // The next request comes after the snooze has ended.
    b.clock.now_ns = ts("2026-10-20T19:30:00Z").nanoseconds;
    var got = try b.client.getAlert(held);
    defer got.deinit();
    try testing.expectEqual(types.AlertState.closed, got.value.state);
    try testing.expectEqual(ts("2026-10-20T19:01:00Z").nanoseconds, got.value.close_time.?.nanoseconds);
    // An alert opened after it ended is untouched.
    const later = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:03:00Z"), .policy = .{ .name = policy } });
    var after = try b.client.getAlert(later);
    defer after.deinit();
    try testing.expectEqual(types.AlertState.open, after.value.state);
}

test "an upcoming snooze cancelled before its start never held, and closes nothing" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    const policy = "projects/extractctl/alertPolicies/42";
    b.clock.now_ns = ts("2026-10-20T19:00:00Z").nanoseconds;
    const open = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:00:00Z"), .policy = .{ .name = policy } });
    var snooze = try b.client.createSnooze(.{ .display_name = "later", .policies = &.{"42"}, .start = ts("2026-10-20T19:30:00Z"), .end = ts("2026-10-20T19:40:00Z") });
    defer snooze.deinit();
    b.clock.now_ns = ts("2026-10-20T19:10:00Z").nanoseconds;
    var cancelled = try b.client.endSnooze(snooze.value, std.Io.Clock.real.now(b.clock.io()));
    defer cancelled.deinit();
    try testing.expect(cancelled.value.cancelled());
    b.clock.now_ns = ts("2026-10-20T19:50:00Z").nanoseconds;
    var got = try b.client.getAlert(open);
    defer got.deinit();
    try testing.expectEqual(types.AlertState.open, got.value.state);
    // And it keeps none from opening.
    _ = try b.fake.putAlert(.{ .open_time = ts("2026-10-20T19:10:00Z"), .policy = .{ .name = policy } });
}

/// What the property holds the fake to: one policy's snoozes and alerts,
/// written apart from the fake, as production moved them.
const SnoozeModel = struct {
    const max = 24;
    enabled: bool = true,
    snoozes: [max]Z = undefined,
    snooze_count: usize = 0,
    alerts: [max]A = undefined,
    alert_count: usize = 0,

    const Z = struct { id: []const u8, start: i96, end: i96, never_held: bool = false };
    const A = struct { id: []const u8, open: i96, closed: ?i96 = null };

    fn heldAt(z: Z, t: i96) bool {
        return !z.never_held and z.start <= t and t < @max(z.end, z.start + 1);
    }

    /// Every open alert a snooze begun by `now` held over, closed at its
    /// start or its opening, whichever came later.
    fn settle(m: *SnoozeModel, now: i96) void {
        for (m.alerts[0..m.alert_count]) |*a| {
            if (a.closed != null) continue;
            var first: ?i96 = null;
            for (m.snoozes[0..m.snooze_count]) |z| {
                if (z.never_held or z.start > now or a.open >= @max(z.end, z.start + 1)) continue;
                const at = @max(z.start, a.open);
                if (first == null or at < first.?) first = at;
            }
            a.closed = first;
        }
    }
};

fn snoozesProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var clock: core.testing.FakeClock = .{ .now_ns = ts("2026-10-20T19:00:00Z").nanoseconds };
    var fake: FakeMonitoring = .init(gpa, clock.io(), .{ .project_id = "p" });
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "t" };
    var diag: core.Diagnostics = .{};
    var client = try Client.init(gpa, clock.io(), .{ .project_id = "p", .token_provider = token.provider(), .transport = fake.transport(), .diagnostics = &diag });
    defer client.deinit();
    const policy = "projects/p/alertPolicies/42";
    _ = try fake.putAlertPolicy(.{ .id = "42", .display_name = "watched" });
    var m: SnoozeModel = .{};

    for (0..g.intRange(usize, 0, 40)) |_| {
        const now = clock.now_ns;
        switch (g.intRange(u8, 0, 6)) {
            0 => if (m.snooze_count < SnoozeModel.max) {
                const start = now + (@as(i96, g.intRange(u32, 0, 630)) - 30) * std.time.ns_per_s;
                const end = start + @as(i96, g.intRange(u32, 0, 900)) * std.time.ns_per_s;
                // The fake settles at every request it serves, before
                // the request: a create the client sends included.
                if (end - start >= 60 * std.time.ns_per_s) m.settle(now);
                const made = client.createSnooze(.{ .display_name = "z", .policies = &.{"42"}, .start = .{ .nanoseconds = start }, .end = .{ .nanoseconds = end } });
                if (end - start < 60 * std.time.ns_per_s) {
                    try testing.expectError(error.InvalidOptions, made);
                } else if (start < now - 15 * std.time.ns_per_s) {
                    try testing.expectError(error.InvalidArgument, made);
                } else {
                    var z = try made;
                    defer z.deinit();
                    m.snoozes[m.snooze_count] = .{ .id = try a.dupe(u8, z.value.id), .start = start, .end = end };
                    m.snooze_count += 1;
                }
            },
            1 => if (m.snooze_count > 0) {
                const z = &m.snoozes[g.intRange(usize, 0, m.snooze_count - 1)];
                const value: types.Snooze = .{ .name = try std.fmt.allocPrint(a, "projects/p/snoozes/{s}", .{z.id}), .id = z.id, .start = .{ .nanoseconds = z.start }, .end = .{ .nanoseconds = z.end } };
                // Refused before sending when it has ended: nothing served.
                if (!(z.start == z.end or z.end <= now)) m.settle(now);
                const ended = client.endSnooze(value, .{ .nanoseconds = now });
                if (z.start == z.end or z.end <= now) {
                    try testing.expectError(error.InvalidOptions, ended);
                } else {
                    var answer = try ended;
                    defer answer.deinit();
                    if (now < z.start) {
                        z.start = now;
                        z.end = now;
                        z.never_held = true;
                    } else if (now - z.start < 60 * std.time.ns_per_s) {
                        z.end = z.start;
                    } else {
                        z.end = now;
                    }
                    try testing.expectEqual(z.start, answer.value.start.nanoseconds);
                    try testing.expectEqual(z.end, answer.value.end.nanoseconds);
                }
            },
            2 => {
                m.settle(now);
                var page = try client.listSnoozes(.{ .active_at = .{ .nanoseconds = now } });
                defer page.deinit();
                var want: usize = 0;
                for (m.snoozes[0..m.snooze_count]) |z| want += @intFromBool(z.start <= now and z.end >= now);
                try testing.expectEqual(want, page.value.snoozes.len);
            },
            3 => clock.now_ns += @as(i96, g.intRange(u32, 0, 120)) * std.time.ns_per_s,
            4 => if (m.alert_count < SnoozeModel.max) {
                const put = fake.putAlert(.{ .open_time = .{ .nanoseconds = now }, .policy = .{ .name = policy } });
                var held = false;
                for (m.snoozes[0..m.snooze_count]) |z| held = held or SnoozeModel.heldAt(z, now);
                if (held) {
                    try testing.expectError(error.InvalidEntry, put);
                } else {
                    m.alerts[m.alert_count] = .{ .id = try a.dupe(u8, try put), .open = now };
                    m.alert_count += 1;
                }
            },
            5 => {
                m.settle(now);
                for (m.alerts[0..m.alert_count]) |want| {
                    var got = try client.getAlert(want.id);
                    defer got.deinit();
                    try testing.expectEqual(want.closed == null, got.value.state == .open);
                    if (want.closed) |c| try testing.expectEqual(c, got.value.close_time.?.nanoseconds);
                }
            },
            else => {
                m.settle(now);
                m.enabled = g.boolean();
                var p = try client.setAlertPolicyEnabled("42", m.enabled);
                defer p.deinit();
                try testing.expectEqual(m.enabled, p.value.enabled);
                try testing.expectEqual(now, p.value.mutated.time.?.nanoseconds);
            },
        }
    }
}

const test_util = @import("test_util.zig");

test "slow property policies: snoozes made, ended, listed and holding over alerts as production moved them" {
    try test_util.fuzzBytes({}, snoozesProperty, .{
        .corpus = &.{
            // A snooze from now for two minutes, an alert, a minute, a read,
            // the end, another alert.
            "\x00\x1e\x00\x78\x00\x04\x03\x3c\x05\x01\x00\x03\x50\x04\x05",
            // An upcoming snooze cancelled, then an alert.
            "\x00\xff\xff\x40\x00\x01\x00\x04\x05\x02",
            "",
        },
    });
}
