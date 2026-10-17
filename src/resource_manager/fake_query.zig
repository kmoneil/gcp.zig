//! The fake's reader of the project search query language, as milestone 0
//! of the Resource Manager spec measured production on 2026-10-17
//! (`_tmp/rm-m0/`), whatever the reference says:
//!
//! - Two terms side by side mean AND; so does `AND`. `OR`, `NOT`, a
//!   leading `-` and parentheses are read. `OR` binds tighter, as in
//!   AIP-160, but how production reads AND and OR mixed without
//!   parentheses was not measured, so that is refused as not modelled.
//! - `field:value` and `field=value` are the same. Keys and values are
//!   case-insensitive (ASCII). A value may be quoted, and a `*` inside the
//!   quotes still works.
//! - A `*` works only at the end of a value: `name:ext*` matches
//!   "extractctl", `name:ext` does not, and `id:*` matches every project.
//! - Fields: `state` and `lifecycleState`, `id` and `projectId`, `name`
//!   and `displayName`, `projectNumber` (exact), `labels.KEY`, `labels`.
//!
//! What production refuses is refused in its words: an unknown field, a
//! bare word or a lowercase `and` ("contains global restriction"), a
//! non-ASCII value, an escaped quote, `projectNumber` with a `*`, and
//! syntax errors. What production takes but nobody outside Google can
//! model is refused as not modelled, never matched silently: `!=` (taken,
//! and it did not exclude), a leading or inner `*` (matched nothing once),
//! and `parent`, `parent.type` and `parent.id`, which production answers
//! from another index (a parent search returned a public project that the
//! empty search left out). So is a match that depends on how production
//! splits a name into words, which was measured only on one-word names:
//! a value that matches a later word of a name but not its start.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

/// What a query is matched against.
pub const Candidate = struct {
    project_id: []const u8,
    display_name: ?[]const u8,
    number: u64,
    state: types.State,
    labels: []const types.Label,
};

pub const Refusal = struct {
    kind: Kind,
    /// For `.production`, production's whole message; for `.not_modelled`,
    /// what is not.
    message: []const u8,
    /// Which field production's `BadRequest` names: "query", or "filter"
    /// for a query of white space alone.
    field: []const u8 = "query",

    pub const Kind = enum { production, not_modelled };
};

pub const Match = enum { yes, no, unknown };

/// A query read: `root` null matches every project.
pub const Query = struct {
    root: ?*const Node,

    pub fn matches(q: Query, c: Candidate) Match {
        const root = q.root orelse return .yes;
        return eval(root, c);
    }
};

pub const Parsed = union(enum) {
    query: Query,
    refused: Refusal,
};

const Node = union(enum) {
    restriction: Restriction,
    not: *const Node,
    all: []const *const Node,
    any: []const *const Node,
};

const Field = union(enum) {
    state,
    id,
    name,
    number,
    /// A label key, lowercase.
    label: []const u8,
    labels,
};

const Restriction = struct {
    field: Field,
    /// Lowercase, without quotes or the final `*`.
    value: []const u8,
    /// A final `*`: a prefix, or with an empty value, any.
    prefix: bool,
};

const Token = union(enum) {
    lparen,
    rparen,
    and_,
    or_,
    not,
    restriction: Restriction,
};

const syntax = "field [query] has issue [invalid syntax]";
const global = "field [query] has issue [contains global restriction]";
const blank = "field [filter] has issue [Could not parse query]";

/// Reads `text`. Every allocation is in `arena`.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Parsed {
    if (text.len == 0) return .{ .query = .{ .root = null } };
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return refuse(.production, blank, "filter");
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (c == '(') {
            try tokens.append(arena, .lparen);
            i += 1;
            continue;
        }
        if (c == ')') {
            try tokens.append(arena, .rparen);
            i += 1;
            continue;
        }
        if (c == '-' and i + 1 < text.len and text[i + 1] != ' ' and text[i + 1] != '\t') {
            try tokens.append(arena, .not);
            i += 1;
            continue;
        }
        switch (try lexTerm(arena, text, &i)) {
            .token => |t| try tokens.append(arena, t),
            .refused => |r| return .{ .refused = r },
        }
    }
    var p: Parser = .{ .arena = arena, .tokens = tokens.items };
    const root = p.query() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return .{ .refused = p.refusal },
    };
    if (p.at < p.tokens.len) return refuse(.production, syntax, "query");
    return .{ .query = .{ .root = root } };
}

fn refuse(kind: Refusal.Kind, message: []const u8, field: []const u8) Parsed {
    return .{ .refused = .{ .kind = kind, .message = message, .field = field } };
}

const Lexed = union(enum) { token: Token, refused: Refusal };

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn isEnd(c: u8) bool {
    return c == ' ' or c == '\t' or c == ')' or c == '(';
}

fn lexTerm(arena: Allocator, text: []const u8, at: *usize) Allocator.Error!Lexed {
    const start = at.*;
    var i = start;
    while (i < text.len and isKeyChar(text[i])) i += 1;
    const key = text[start..i];
    if (i == text.len or isEnd(text[i])) {
        at.* = i;
        if (std.mem.eql(u8, key, "AND")) return .{ .token = .and_ };
        if (std.mem.eql(u8, key, "OR")) return .{ .token = .or_ };
        if (std.mem.eql(u8, key, "NOT")) return .{ .token = .not };
        // A bare word is a search of everything, which production refuses.
        if (key.len > 0) return .{ .refused = .{ .kind = .production, .message = global } };
    }
    if (key.len == 0) return notModelled("a term that does not start with a field", text, at);
    if (text[i] == '!' and i + 1 < text.len and text[i + 1] == '=') return notModelled("`!=`, which production takes and does not apply", text, at);
    if (text[i] != ':' and text[i] != '=') return notModelled("an operator other than `:` and `=`", text, at);
    i += 1;
    const value_start = i;
    var raw: []const u8 = undefined;
    if (i < text.len and text[i] == '"') {
        i += 1;
        const close = std.mem.indexOfScalarPos(u8, text, i, '"') orelse {
            at.* = text.len;
            return .{ .refused = .{ .kind = .production, .message = syntax } };
        };
        raw = text[i..close];
        i = close + 1;
        if (std.mem.indexOfScalar(u8, raw, '\\') != null) {
            at.* = i;
            return .{ .refused = .{ .kind = .production, .message = try invalidFilter(arena, key, text[value_start..i], true) } };
        }
        if (i < text.len and !isEnd(text[i])) return notModelled("text after a quoted value", text, at);
    } else {
        while (i < text.len and !isEnd(text[i])) i += 1;
        if (i < text.len and text[i] == '(') {
            at.* = text.len;
            return .{ .refused = .{ .kind = .production, .message = syntax } };
        }
        raw = text[value_start..i];
        if (raw.len == 0 or raw[0] == ':' or raw[0] == '=') {
            at.* = i;
            return .{ .refused = .{ .kind = .production, .message = syntax } };
        }
        if (std.mem.indexOfScalar(u8, raw, '"') != null) return notModelled("a quote inside a value", text, at);
    }
    at.* = i;

    const field = try fieldOf(arena, key) orelse
        return .{ .refused = .{ .kind = .production, .message = try invalidFilter(arena, key, text[value_start..i], false) } };
    if (field == .not_modelled) return notModelled("a parent query, which production reads from another index", text, at);
    for (raw) |c| if (c >= 0x80) {
        return .{ .refused = .{ .kind = .production, .message = try invalidFilter(arena, key, text[value_start..i], true) } };
    };
    const star = std.mem.indexOfScalar(u8, raw, '*');
    const prefix = star != null and star.? == raw.len - 1;
    if (star != null and !prefix) return notModelled("a `*` that does not end its value", text, at);
    const value = try std.ascii.allocLowerString(arena, if (prefix) raw[0 .. raw.len - 1] else raw);
    const f = field.field;
    switch (f) {
        .number => {
            if (prefix) return .{ .refused = .{ .kind = .production, .message = try invalidFilter(arena, key, text[value_start..i], false) } };
            for (value) |c| if (!std.ascii.isDigit(c)) return notModelled("a project number that is not digits", text, at);
        },
        .state => if (prefix) return notModelled("a `*` in a state", text, at),
        .label => if (prefix and value.len > 0) return notModelled("a label prefix", text, at),
        .labels => if (prefix) return notModelled("a `*` in a bare label query", text, at),
        .id, .name => {},
    }
    return .{ .token = .{ .restriction = .{ .field = f, .value = value, .prefix = prefix } } };
}

fn notModelled(what: []const u8, text: []const u8, at: *usize) Lexed {
    at.* = text.len;
    return .{ .refused = .{ .kind = .not_modelled, .message = what } };
}

const FieldOf = union(enum) { field: Field, not_modelled };

fn fieldOf(arena: Allocator, key: []const u8) Allocator.Error!?FieldOf {
    const lower = try std.ascii.allocLowerString(arena, key);
    const plain = [_]struct { []const u8, Field }{
        .{ "state", .state },          .{ "lifecyclestate", .state }, .{ "id", .id },
        .{ "projectid", .id },         .{ "name", .name },            .{ "displayname", .name },
        .{ "projectnumber", .number }, .{ "labels", .labels },
    };
    for (plain) |p| if (std.mem.eql(u8, lower, p[0])) return .{ .field = p[1] };
    for ([_][]const u8{ "parent", "parent.type", "parent.id" }) |p| if (std.mem.eql(u8, lower, p)) return .not_modelled;
    if (std.mem.startsWith(u8, lower, "labels.") and lower.len > "labels.".len) return .{ .field = .{ .label = lower["labels.".len..] } };
    return null;
}

/// Production's words for a term it could not turn into its own query:
/// `resourceType="cloudresourcemanager.projects" AND (foo : bar)` for an
/// unknown field, `(name = été)` for a known one. Measured for one term at
/// a time; for more, production quotes the whole query rewritten, which
/// this does not reproduce.
fn invalidFilter(arena: Allocator, key: []const u8, value: []const u8, known: bool) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "field [query] has issue [Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND ({s} {s} {s})]", .{ key, if (known) "=" else ":", value });
}

const Parser = struct {
    arena: Allocator,
    tokens: []const Token,
    at: usize = 0,
    refusal: Refusal = undefined,

    const Error = error{ OutOfMemory, Refused };

    fn peek(p: *const Parser) ?Token {
        return if (p.at < p.tokens.len) p.tokens[p.at] else null;
    }

    fn fail(p: *Parser, kind: Refusal.Kind, message: []const u8) Error {
        p.refusal = .{ .kind = kind, .message = message };
        return error.Refused;
    }

    /// Factors joined by AND, written or not, up to the end or a `)`.
    fn query(p: *Parser) Error!*const Node {
        var factors: std.ArrayList(*const Node) = .empty;
        var bare_or = false;
        while (p.peek()) |t| {
            if (t == .rparen) break;
            if (t == .and_) {
                p.at += 1;
                const next = p.peek() orelse return p.fail(.production, syntax);
                if (factors.items.len == 0 or next == .rparen or next == .and_) return p.fail(.production, syntax);
                continue;
            }
            const factor = try p.alternatives();
            if (factor.bare_or) bare_or = true;
            try factors.append(p.arena, factor.node);
        }
        if (factors.items.len == 0) return p.fail(.not_modelled, "an empty query in parentheses");
        if (factors.items.len == 1) return factors.items[0];
        if (bare_or) return p.fail(.not_modelled, "AND and OR mixed without parentheses");
        return node(p.arena, .{ .all = try factors.toOwnedSlice(p.arena) });
    }

    const Factor = struct { node: *const Node, bare_or: bool };

    /// Unaries joined by OR.
    fn alternatives(p: *Parser) Error!Factor {
        const first = try p.unary();
        if (p.peek() == null or p.peek().? != .or_) return .{ .node = first, .bare_or = false };
        var alts: std.ArrayList(*const Node) = .empty;
        try alts.append(p.arena, first);
        while (p.peek()) |t| {
            if (t != .or_) break;
            p.at += 1;
            const next = p.peek() orelse return p.fail(.production, syntax);
            if (next == .rparen or next == .and_ or next == .or_) return p.fail(.production, syntax);
            try alts.append(p.arena, try p.unary());
        }
        return .{ .node = try node(p.arena, .{ .any = try alts.toOwnedSlice(p.arena) }), .bare_or = true };
    }

    fn unary(p: *Parser) Error!*const Node {
        const t = p.peek() orelse return p.fail(.production, syntax);
        p.at += 1;
        switch (t) {
            .not => {
                const inner = try p.unary();
                return node(p.arena, .{ .not = inner });
            },
            .lparen => {
                const inner = try p.query();
                const close = p.peek() orelse return p.fail(.production, syntax);
                if (close != .rparen) return p.fail(.production, syntax);
                p.at += 1;
                return inner;
            },
            .restriction => |r| return node(p.arena, .{ .restriction = r }),
            .rparen, .and_, .or_ => return p.fail(.production, syntax),
        }
    }
};

fn node(arena: Allocator, n: Node) Allocator.Error!*const Node {
    const out = try arena.create(Node);
    out.* = n;
    return out;
}

fn eval(n: *const Node, c: Candidate) Match {
    switch (n.*) {
        .restriction => |r| return restriction(r, c),
        .not => |inner| return switch (eval(inner, c)) {
            .yes => .no,
            .no => .yes,
            .unknown => .unknown,
        },
        .all => |list| {
            var out: Match = .yes;
            for (list) |item| switch (eval(item, c)) {
                .no => return .no,
                .unknown => out = .unknown,
                .yes => {},
            };
            return out;
        },
        .any => |list| {
            var out: Match = .no;
            for (list) |item| switch (eval(item, c)) {
                .yes => return .yes,
                .unknown => out = .unknown,
                .no => {},
            };
            return out;
        },
    }
}

fn restriction(r: Restriction, c: Candidate) Match {
    switch (r.field) {
        .state => {
            const want: types.State = if (std.mem.eql(u8, r.value, "active"))
                .active
            else if (std.mem.eql(u8, r.value, "delete_requested"))
                .delete_requested
            else
                return .no;
            return if (c.state == want) .yes else .no;
        },
        .number => {
            const n = std.fmt.parseInt(u64, r.value, 10) catch return .no;
            return if (n == c.number) .yes else .no;
        },
        .id => return matchText(c.project_id, r),
        .name => {
            const name = c.display_name orelse return if (r.prefix and r.value.len == 0) .unknown else .no;
            return matchText(name, r);
        },
        .label => |key| {
            for (c.labels) |l| if (std.ascii.eqlIgnoreCase(l.key, key)) {
                if (r.prefix) return .yes;
                return if (std.ascii.eqlIgnoreCase(l.value, r.value)) .yes else .no;
            };
            return .no;
        },
        .labels => return if (c.labels.len == 0) .no else .unknown,
    }
}

/// A project id or display name against a value: whole, or as a prefix of
/// the whole. A value that matches only from a later word is unknown.
fn matchText(t: []const u8, r: Restriction) Match {
    if (r.prefix) {
        if (r.value.len == 0) return .yes;
        if (startsWithIgnoreCase(t, r.value)) return .yes;
    } else if (std.ascii.eqlIgnoreCase(t, r.value)) return .yes;
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        if (std.ascii.isAlphanumeric(t[i - 1]) or !std.ascii.isAlphanumeric(t[i])) continue;
        const rest = t[i..];
        if (r.prefix and startsWithIgnoreCase(rest, r.value)) return .unknown;
        if (!r.prefix and startsWithIgnoreCase(rest, r.value) and (rest.len == r.value.len or !std.ascii.isAlphanumeric(rest[r.value.len]))) return .unknown;
    }
    // A value matching the start of a name made of several words, whole
    // words only, may match there too.
    if (!r.prefix and startsWithIgnoreCase(t, r.value) and r.value.len < t.len and !std.ascii.isAlphanumeric(t[r.value.len])) return .unknown;
    return .no;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

const testing = std.testing;

fn expectMatch(query: []const u8, c: Candidate, want: Match) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), query);
    switch (parsed) {
        .query => |q| {
            const got = q.matches(c);
            if (got != want) {
                std.debug.print("{s}: want {t}, got {t}\n", .{ query, want, got });
                return error.TestExpectedEqual;
            }
        },
        .refused => |r| {
            std.debug.print("{s}: refused, {s}\n", .{ query, r.message });
            return error.TestUnexpectedRefusal;
        },
    }
}

fn expectRefused(query: []const u8, kind: Refusal.Kind, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), query);
    switch (parsed) {
        .query => {
            std.debug.print("{s}: read, not refused\n", .{query});
            return error.TestExpectedRefusal;
        },
        .refused => |r| {
            try testing.expectEqual(kind, r.kind);
            if (std.mem.indexOf(u8, r.message, message) == null) {
                std.debug.print("{s}: {s}\n", .{ query, r.message });
                return error.TestExpectedEqual;
            }
        },
    }
}

const extractctl: Candidate = .{ .project_id = "extractctl", .display_name = "extractctl", .number = 82150720798, .state = .active, .labels = &.{} };

test "production's answers on extractctl, every one measured on 2026-10-17" {
    for ([_]struct { []const u8, Match }{
        .{ "", .yes },                                                    .{ "name:extractctl", .yes },
        .{ "name:EXTRACTCTL", .yes },                                     .{ "NAME:extractctl", .yes },
        .{ "displayName:extractctl", .yes },                              .{ "name:ext*", .yes },
        .{ "name:EXT*", .yes },                                           .{ "name:\"ext*\"", .yes },
        .{ "name:ext", .no },                                             .{ "name:extractctl*", .yes },
        .{ "name:\"extract ctl\"", .no },                                 .{ "displayName:\"extractctl\"", .yes },
        .{ "id:extractctl", .yes },                                       .{ "projectId:extractctl", .yes },
        .{ "projectId:EXTRACTCTL", .yes },                                .{ "id:extr*", .yes },
        .{ "projectId:extr*", .yes },                                     .{ "id:extr", .no },
        .{ "id:extractctl*", .yes },                                      .{ "projectId=extractctl", .yes },
        .{ "projectId:\"extractctl\"", .yes },                            .{ "state:ACTIVE", .yes },
        .{ "state:active", .yes },                                        .{ "lifecycleState:ACTIVE", .yes },
        .{ "state:DELETE_REQUESTED", .no },                               .{ "state:BOGUS", .no },
        .{ "projectId:extractctl state:DELETE_REQUESTED", .no },          .{ "projectId:extractctl state:ACTIVE", .yes },
        .{ "projectId:extractctl projectId:bigquery-public-data", .no },  .{ "projectId:extractctl AND state:DELETE_REQUESTED", .no },
        .{ "projectId:extractctl OR state:DELETE_REQUESTED", .yes },      .{ "NOT state:DELETE_REQUESTED", .yes },
        .{ "projectId:extractctl AND NOT state:DELETE_REQUESTED", .yes }, .{ "(projectId:extractctl)", .yes },
        .{ "(projectId:extractctl OR projectId:zzzz-none)", .yes },       .{ "id:*", .yes },
        .{ "projectNumber:82150720798", .yes },                           .{ "id:82150720798", .no },
        .{ "labels.zigps:*", .no },                                       .{ "labels:zigps", .no },
        .{ "state:ACTIVE OR state:DELETE_REQUESTED", .yes },              .{ "NOT projectId:extractctl", .no },
        .{ "-state:DELETE_REQUESTED", .yes },                             .{ "projectId:extractctl AND (state:ACTIVE OR state:DELETE_REQUESTED)", .yes },
        .{ "projectId:extractctl\tstate:ACTIVE", .yes },                  .{ "projectId:bigquery-public-data", .no },
    }) |case| try expectMatch(case[0], extractctl, case[1]);
}

test "production's refusals, in its words" {
    try expectRefused("foo:bar", .production, "field [query] has issue [Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND (foo : bar)]");
    try expectRefused("name:\u{e9}t\u{e9}", .production, "field [query] has issue [Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND (name = \u{e9}t\u{e9})]");
    try expectRefused("name:\"a\\\"b\"", .production, "Invalid filter query");
    try expectRefused("projectNumber:8215*", .production, "AND (projectNumber : 8215*)]");
    for ([_][]const u8{ "name:(", "name:\"x", "AND", "projectId:", "projectId::extractctl", "id:a AND", "id:a OR", "(id:a", "id:a)", "NOT", "OR id:a", "id:a AND AND id:b" }) |q|
        try expectRefused(q, .production, "field [query] has issue [invalid syntax]");
    for ([_][]const u8{ "extractctl", "projectId:extractctl and state:DELETE_REQUESTED", "id:a b" }) |q|
        try expectRefused(q, .production, "field [query] has issue [contains global restriction]");
    try expectRefused(" ", .production, "field [filter] has issue [Could not parse query]");
    try expectRefused("\t ", .production, "Could not parse query");
}

test "what nobody can model is refused, never matched" {
    for ([_][]const u8{
        "projectId!=extractctl", "name:*ctl",           "id:ex*tl",            "parent:folders/1",
        "parent.type:folder",    "parent.id:1",         "PARENT:folders/1",    "createTime>\"2026-01-01T00:00:00Z\"",
        ":x",                    "id:a OR id:c name:e", "id:a name:e OR id:c", "()",
        "state:ACT*",            "labels.k:v*",         "labels:x*",           "projectNumber:abc",
        "name:\"a\"*",           "name:a\"b\"",
    }) |q| try expectRefused(q, .not_modelled, "");
}

test "names of several words: what may differ is unknown" {
    const c: Candidate = .{ .project_id = "my-project-1", .display_name = "Payments Prod", .number = 1, .state = .active, .labels = &.{} };
    for ([_]struct { []const u8, Match }{
        .{ "name:pay*", .yes },          .{ "name:\"payments prod\"", .yes },
        .{ "name:prod*", .unknown },     .{ "name:prod", .unknown },
        .{ "name:payments", .unknown },  .{ "name:pro", .no },
        .{ "name:xyz*", .no },           .{ "name:*", .yes },
        .{ "id:my-pro*", .yes },         .{ "id:proj*", .unknown },
        .{ "id:project", .unknown },     .{ "id:my-project-1", .yes },
        .{ "id:my", .unknown },          .{ "id:my-project-1 id:my*", .yes },
        .{ "id:proj* OR id:my*", .yes }, .{ "id:proj* id:zz*", .no },
        .{ "id:zz* id:proj*", .no },     .{ "id:zz* OR id:proj*", .unknown },
        .{ "NOT name:prod", .unknown },
    }) |case| try expectMatch(case[0], c, case[1]);
    const nameless: Candidate = .{ .project_id = "a-b", .display_name = null, .number = 2, .state = .delete_requested, .labels = &.{.{ .key = "Team", .value = "Pay" }} };
    for ([_]struct { []const u8, Match }{
        .{ "name:a*", .no },                            .{ "name:*", .unknown },
        .{ "labels.team:pay", .yes },                   .{ "labels.TEAM:*", .yes },
        .{ "labels.team:x", .no },                      .{ "labels.other:*", .no },
        .{ "labels:pay", .unknown },                    .{ "state:delete_requested", .yes },
        .{ "projectNumber:2", .yes },                   .{ "projectNumber:3", .no },
        .{ "projectNumber:99999999999999999999", .no },
    }) |case| try expectMatch(case[0], nameless, case[1]);
}

test "every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try parse(arena.allocator(), "(projectId:a OR name:\"B c\"*) -state:DELETE_REQUESTED NOT labels.k:v");
            _ = try parse(arena.allocator(), "id:a foo:bar");
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

const test_util = @import("test_util.zig");

const fuzz_candidates = [_]Candidate{
    extractctl,
    .{ .project_id = "web", .display_name = "Web", .number = 7, .state = .delete_requested, .labels = &.{.{ .key = "team", .value = "pay" }} },
    .{ .project_id = "payments", .display_name = null, .number = 82150720799, .state = .active, .labels = &.{.{ .key = "env", .value = "prod" }} },
};

/// A random query over terms whose answer nobody disputes, written with a
/// parenthesis around every compound, and its answer for each candidate by
/// a plain model.
fn genQuery(g: *test_util.ByteGen, out: *std.Io.Writer, depth: u32, answers: *[fuzz_candidates.len]bool) !void {
    const kind = if (depth >= 4) 0 else g.intRange(u8, 0, 5);
    switch (kind) {
        0, 1 => {
            const term = g.intRange(u8, 0, 7);
            const case_upper = g.boolean();
            const sep: []const u8 = if (g.boolean()) ":" else "=";
            switch (term) {
                0 => try out.print("{s}{s}{s}", .{ if (case_upper) "PROJECTID" else "id", sep, g.pick([]const u8, &.{ "extractctl", "WEB", "payments", "nope" }) }),
                1 => try out.print("id{s}{s}*", .{ sep, g.pick([]const u8, &.{ "ext", "w", "pay", "", "x" }) }),
                2 => try out.print("state{s}{s}", .{ sep, g.pick([]const u8, &.{ "ACTIVE", "delete_requested", "BOGUS" }) }),
                3 => try out.print("projectNumber{s}{s}", .{ sep, g.pick([]const u8, &.{ "7", "82150720798", "82150720799", "1" }) }),
                4 => try out.print("labels.{s}{s}{s}", .{ g.pick([]const u8, &.{ "team", "env", "TEAM" }), sep, g.pick([]const u8, &.{ "pay", "prod", "*", "x" }) }),
                5 => try out.print("name{s}\"{s}\"", .{ sep, g.pick([]const u8, &.{ "extractctl", "web", "ext*" }) }),
                else => try out.print("displayName{s}{s}", .{ sep, g.pick([]const u8, &.{ "Extractctl", "web", "nope" }) }),
            }
            for (fuzz_candidates, answers) |c, *ans| ans.* = model(out.buffered(), c);
        },
        2 => {
            try out.writeAll(if (g.boolean()) "NOT " else "-");
            var inner: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer inner.deinit();
            var sub: [fuzz_candidates.len]bool = undefined;
            try genQuery(g, &inner.writer, depth + 1, &sub);
            try out.print("({s})", .{inner.written()});
            for (answers, sub) |*a, s| a.* = !s;
        },
        else => {
            const op: []const u8 = switch (kind) {
                3 => " AND ",
                4 => " OR ",
                else => " ",
            };
            var left: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer left.deinit();
            var right: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer right.deinit();
            var l: [fuzz_candidates.len]bool = undefined;
            var r: [fuzz_candidates.len]bool = undefined;
            try genQuery(g, &left.writer, depth + 1, &l);
            try genQuery(g, &right.writer, depth + 1, &r);
            try out.print("({s}{s}{s})", .{ left.written(), op, right.written() });
            for (answers, l, r) |*a, x, y| a.* = if (kind == 4) x or y else x and y;
        },
    }
}

/// One term, judged plainly.
fn model(term: []const u8, c: Candidate) bool {
    const sep = std.mem.indexOfAny(u8, term, ":=").?;
    const key = term[0..sep];
    var value = term[sep + 1 ..];
    if (value.len >= 2 and value[0] == '"') value = value[1 .. value.len - 1];
    const prefix = value.len > 0 and value[value.len - 1] == '*';
    const v = if (prefix) value[0 .. value.len - 1] else value;
    if (std.ascii.eqlIgnoreCase(key, "id") or std.ascii.eqlIgnoreCase(key, "projectid")) {
        return if (prefix) startsWithIgnoreCase(c.project_id, v) else std.ascii.eqlIgnoreCase(c.project_id, v);
    }
    if (std.ascii.eqlIgnoreCase(key, "name") or std.ascii.eqlIgnoreCase(key, "displayname")) {
        const name = c.display_name orelse return false;
        return if (prefix) startsWithIgnoreCase(name, v) else std.ascii.eqlIgnoreCase(name, v);
    }
    if (std.mem.eql(u8, key, "state")) {
        if (std.ascii.eqlIgnoreCase(v, "active")) return c.state == .active;
        if (std.ascii.eqlIgnoreCase(v, "delete_requested")) return c.state == .delete_requested;
        return false;
    }
    if (std.mem.eql(u8, key, "projectNumber")) return std.fmt.parseInt(u64, v, 10) catch unreachable == c.number;
    const label = key["labels.".len..];
    for (c.labels) |l| if (std.ascii.eqlIgnoreCase(l.key, label)) return prefix or std.ascii.eqlIgnoreCase(l.value, v);
    return false;
}

fn modelProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    var want: [fuzz_candidates.len]bool = undefined;
    try genQuery(&g, &text.writer, 0, &want);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const q = switch (try parse(arena.allocator(), text.written())) {
        .query => |q| q,
        .refused => |r| {
            std.debug.print("{s}: refused, {s}\n", .{ text.written(), r.message });
            return error.TestUnexpectedRefusal;
        },
    };
    for (fuzz_candidates, want) |c, w| {
        const got = q.matches(c);
        if (got != (if (w) Match.yes else Match.no)) {
            std.debug.print("{s} on {s}: want {}, got {t}\n", .{ text.written(), c.project_id, w, got });
            return error.TestExpectedEqual;
        }
    }
}

test "fuzz query reader: random queries agree with a plain model of what production did" {
    try test_util.fuzzBytes({}, modelProperty, .{ .corpus = &.{ "", "\x05\x00\x00\x00\x00\x01\x00\x00\x01" } });
}

fn arbitraryQueryProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    switch (try parse(arena.allocator(), input)) {
        .query => |q| for (fuzz_candidates) |c| {
            _ = q.matches(c);
        },
        .refused => |r| try testing.expect(r.message.len > 0),
    }
}

test "fuzz query reader: arbitrary text is read or refused, never a crash" {
    try test_util.fuzzBytes({}, arbitraryQueryProperty, .{ .corpus = &.{ "((((((((((id:a))))))))))", "NOT NOT NOT -id:a", "id:\"", "\"", "-", "- id:a", "id:a OR", "((", "))" } });
}
