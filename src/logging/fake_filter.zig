//! A filter in the Logging query language, for the in-memory Cloud
//! Logging: a subset, read as production read the filters it was shown on
//! 2026-10-16 (`_tmp/logging-m0/`), and tried on an entry. Test code only.
//!
//! What it reads: comparisons `field op value` with `=`, `!=`, `:`, `<`,
//! `<=`, `>`, `>=`; `NOT` and a leading `-`; `AND`, `OR`, and terms side by
//! side, which AND; parentheses; `--` comments to the end of a line;
//! double-quoted strings with `\"`, `\\`, `\t` and `\uXXXX`, each of which
//! production read; bare values. **The precedence is the language's own,
//! not the usual one: NOT, then OR, then AND**, so `a OR b AND c` is
//! `(a OR b) AND c`, as a Google maintainer verified against the API.
//! Logical operators count only in capitals; lowercase `and`, `or` and
//! `not` are search terms, which are not modelled.
//!
//! Fields: `timestamp` and `receiveTimestamp` (RFC 3339, or a date alone,
//! compared as times), `severity` (by its number, from a name in any case
//! or a number), `logName`, `insertId`, `trace`, `spanId`, `textPayload`,
//! `resource.type`, `resource.labels.KEY`, `labels.KEY`, and
//! `jsonPayload.PATH` to a string, a number or a boolean, with a component
//! in double quotes when it holds a dot or a slash. `log_id("id")` takes the
//! plain id. Strings compare ignoring case, as production matched "caseid"
//! with "CaseID" and "été" with "Été": ASCII's letters and Latin-1's here,
//! where production folds further. `:` is a substring test, and `field:*`
//! that the field is there.
//!
//! A comparison on a field an entry does not have is false, `!=` too, as
//! production answered `labels.missing != "x"` with no entries.
//!
//! What production refused, this refuses in its sentences: "Field not
//! found: 'thud'." for a field no entry has, "Unparseable filter: syntax
//! error at line L, column C, token 'T'" where its parser stopped, "...
//! missing token ..." for an unclosed parenthesis, and "... at line L,
//! token '<EOF>'", with no column, at the end of the text. Whatever else it
//! meets, regular expressions, search terms, other functions, fields an
//! entry has that it does not read, and `!` standing alone (which
//! production took), is `not_modelled`, with the reason, never matched or
//! refused by a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const types = @import("types.zig");

pub const Node = union(enum) {
    /// Every one of them: terms side by side, or joined by AND.
    all: []const Node,
    any: []const Node,
    not: *const Node,
    compare: Compare,
    /// `log_id("...")`, the plain id.
    log_id: []const u8,
};

pub const Field = union(enum) {
    timestamp,
    receive_timestamp,
    severity,
    log_name,
    insert_id,
    trace,
    span_id,
    text_payload,
    resource_type,
    resource_label: []const u8,
    label: []const u8,
    /// The path inside `jsonPayload`.
    json: []const []const u8,
};

pub const Op = enum { eq, ne, has, lt, le, gt, ge };

pub const Compare = struct {
    field: Field,
    op: Op,
    /// As written, unquoted and unescaped.
    value: []const u8,
    /// `field:*`.
    presence: bool = false,
    /// For `timestamp` and `receiveTimestamp`.
    time: ?i96 = null,
    /// For `severity`.
    severity: ?u16 = null,
};

/// What `read` made of a filter.
pub const Read = union(enum) {
    /// An empty filter is `.ok` with `null`: everything passes.
    ok: ?Node,
    /// Production's refusal, in its sentence.
    unparseable: []const u8,
    /// Production's refusal of a filter that parses: "Field not found:
    /// 'thud'.", as measured on 2026-10-16.
    refused: []const u8,
    /// What this fake does not model, and why.
    not_modelled: []const u8,
};

/// Reads `text` into `arena`.
pub fn read(arena: Allocator, text: []const u8) Allocator.Error!Read {
    var p: Parser = .{ .arena = arena, .text = text };
    p.advance() catch |err| return p.outcome(err);
    if (p.current.kind == .end) return .{ .ok = null };
    const node = p.andExpr() catch |err| return p.outcome(err);
    if (p.current.kind != .end) return p.outcome(p.syntaxError());
    return .{ .ok = node };
}

/// What an entry offers a filter. Strings point anywhere; `json` is the
/// parsed payload, or null for an entry with no JSON payload.
pub const Subject = struct {
    timestamp: i96,
    receive_timestamp: i96,
    severity: u16,
    log_name: []const u8,
    log_id: []const u8,
    insert_id: []const u8,
    trace: []const u8,
    span_id: []const u8,
    text_payload: ?[]const u8,
    resource_type: []const u8,
    resource_labels: []const types.Label,
    labels: []const types.Label,
    json: ?std.json.Value,
};

/// Whether `subject` passes, or the reason this fake cannot say.
pub const Verdict = union(enum) { pass: bool, not_modelled: []const u8 };

pub fn matches(node: Node, subject: *const Subject) Verdict {
    switch (node) {
        .all => |list| {
            for (list) |one| switch (matches(one, subject)) {
                .pass => |ok| if (!ok) return .{ .pass = false },
                .not_modelled => |why| return .{ .not_modelled = why },
            };
            return .{ .pass = true };
        },
        .any => |list| {
            for (list) |one| switch (matches(one, subject)) {
                .pass => |ok| if (ok) return .{ .pass = true },
                .not_modelled => |why| return .{ .not_modelled = why },
            };
            return .{ .pass = false };
        },
        .not => |one| return switch (matches(one.*, subject)) {
            .pass => |ok| .{ .pass = !ok },
            .not_modelled => |why| .{ .not_modelled = why },
        },
        .log_id => |id| return .{ .pass = std.mem.eql(u8, id, subject.log_id) },
        .compare => |c| return compare(c, subject),
    }
}

fn compare(c: Compare, s: *const Subject) Verdict {
    switch (c.field) {
        .timestamp, .receive_timestamp => {
            const have: i96 = if (c.field == .timestamp) s.timestamp else s.receive_timestamp;
            return .{ .pass = ordered(i96, have, c.op, c.time.?) };
        },
        .severity => return .{ .pass = ordered(u16, s.severity, c.op, c.severity.?) },
        .log_name => return compareText(c, s.log_name),
        .insert_id => return compareText(c, s.insert_id),
        .trace => return compareText(c, s.trace),
        .span_id => return compareText(c, s.span_id),
        .resource_type => return compareText(c, s.resource_type),
        .text_payload => return textOrMissing(c, s.text_payload),
        .resource_label => |key| return textOrMissing(c, lookup(s.resource_labels, key)),
        .label => |key| return textOrMissing(c, lookup(s.labels, key)),
        .json => |path| {
            var value: std.json.Value = s.json orelse return missing(c);
            for (path) |component| {
                value = switch (value) {
                    .object => |o| o.get(component) orelse return missing(c),
                    else => return missing(c),
                };
            }
            return switch (value) {
                .string => |t| textOrMissing(c, t),
                .number_string, .integer, .float => numeric(c, value),
                .bool => |b| boolean(c, b),
                .null => missing(c),
                .array, .object => .{ .not_modelled = "a comparison with a JSON array or object" },
            };
        },
    }
}

fn ordered(comptime T: type, have: T, op: Op, want: T) bool {
    return switch (op) {
        .eq => have == want,
        .ne => have != want,
        .lt => have < want,
        .le => have <= want,
        .gt => have > want,
        .ge => have >= want,
        // Refused when read.
        .has => unreachable,
    };
}

fn lookup(labels: []const types.Label, key: []const u8) ?[]const u8 {
    for (labels) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
    return null;
}

/// Production answered `labels.missing != "x"` with no entries on
/// 2026-10-16: every comparison on a missing field is false, `!=` too.
fn missing(c: Compare) Verdict {
    _ = c;
    return .{ .pass = false };
}

fn textOrMissing(c: Compare, have: ?[]const u8) Verdict {
    return if (have) |t| compareText(c, t) else missing(c);
}

fn compareText(c: Compare, have: []const u8) Verdict {
    if (c.presence) return .{ .pass = true };
    return switch (c.op) {
        .eq => .{ .pass = foldedEql(have, c.value) },
        .ne => .{ .pass = !foldedEql(have, c.value) },
        .has => .{ .pass = foldedFind(have, c.value) },
        .lt, .le, .gt, .ge => .{ .not_modelled = "an ordering comparison of strings" },
    };
}

/// A character with its case folded, for the letters this fake folds:
/// ASCII's, and Latin-1's accented ones, since production matched "été"
/// with "Été" on 2026-10-16. Production folds more (NFKC_CF); past
/// Latin-1 this fake compares characters exactly.
fn fold(c: u21) u21 {
    return switch (c) {
        'A'...'Z' => c + 0x20,
        0xC0...0xD6, 0xD8...0xDE => c + 0x20,
        else => c,
    };
}

/// The next character of `text` at `i.*`, or a byte that is no UTF-8 as
/// itself.
fn nextChar(text: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i.*]) catch 1;
    if (i.* + len <= text.len) {
        if (std.unicode.utf8Decode(text[i.*..][0..len])) |c| {
            i.* += len;
            return c;
        } else |_| {}
    }
    defer i.* += 1;
    return text[i.*];
}

fn foldedEql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (fold(nextChar(a, &i)) != fold(nextChar(b, &j))) return false;
    }
    return i == a.len and j == b.len;
}

fn foldedFind(haystack: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    while (true) {
        var i = start;
        var j: usize = 0;
        while (i < haystack.len and j < needle.len) {
            if (fold(nextChar(haystack, &i)) != fold(nextChar(needle, &j))) break;
        } else if (j == needle.len) return true;
        if (start >= haystack.len) return false;
        _ = nextChar(haystack, &start);
    }
}

fn numeric(c: Compare, value: std.json.Value) Verdict {
    if (c.presence) return .{ .pass = true };
    const have: f64 = switch (value) {
        .number_string => |t| std.fmt.parseFloat(f64, t) catch return .{ .not_modelled = "a JSON number this fake cannot read" },
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
    const want = std.fmt.parseFloat(f64, c.value) catch return .{ .not_modelled = "a JSON number compared with a value that is no number" };
    if (c.op == .has) return .{ .not_modelled = "':' on a number" };
    return .{ .pass = ordered(f64, have, c.op, want) };
}

fn boolean(c: Compare, have: bool) Verdict {
    if (c.presence) return .{ .pass = true };
    const want = if (std.ascii.eqlIgnoreCase(c.value, "true")) true else if (std.ascii.eqlIgnoreCase(c.value, "false")) false else return .{ .not_modelled = "a JSON boolean compared with a value that is no boolean" };
    return switch (c.op) {
        .eq => .{ .pass = have == want },
        .ne => .{ .pass = have != want },
        else => .{ .not_modelled = "an ordering comparison of booleans" },
    };
}

// The parser.

const Token = struct {
    kind: Kind,
    /// The text: a word as written, or a string unescaped.
    text: []const u8,
    /// Byte offset of the token's first character.
    at: usize,
    /// Whether whitespace or a comment came right before it.
    spaced: bool,

    const Kind = enum { end, lparen, rparen, op, word, string, minus };
};

const Fail = error{ Syntax, NotModelled, Refused, OutOfMemory };

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,
    current: Token = .{ .kind = .end, .text = "", .at = 0, .spaced = false },
    /// The token before `current`.
    prev: Token = .{ .kind = .end, .text = "", .at = 0, .spaced = false },
    /// Why a `NotModelled` or a `Refused` was raised.
    reason: []const u8 = "",
    /// Where a `Syntax` was raised, and how many bytes its token is: 0 for
    /// the one character there.
    fail_at: usize = 0,
    fail_len: usize = 0,
    /// Production says "missing token" for an unclosed parenthesis.
    missing: bool = false,

    fn outcome(p: *Parser, err: Fail) Allocator.Error!Read {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotModelled => .{ .not_modelled = p.reason },
            error.Refused => .{ .refused = p.reason },
            error.Syntax => .{ .unparseable = try p.unparseable() },
        };
    }

    /// Production's sentences, as measured on 2026-10-16: "Unparseable
    /// filter: syntax error at line 1, column 14, token 'AND'", "...
    /// missing token at line 1, column 1, token '('" for an unclosed
    /// parenthesis, and "... syntax error at line 3, token '<EOF>'", with no
    /// column, at the end of the text. Lines and columns count from 1, in
    /// characters.
    fn unparseable(p: *Parser) Allocator.Error![]const u8 {
        var line: usize = 1;
        var column: usize = 1;
        for (p.text[0..@min(p.fail_at, p.text.len)]) |c| {
            if (c == '\n') {
                line += 1;
                column = 1;
            } else if (c & 0xC0 != 0x80) column += 1;
        }
        if (p.fail_at >= p.text.len) return std.fmt.allocPrint(p.arena, "Unparseable filter: syntax error at line {d}, token '<EOF>'", .{line});
        const len = if (p.fail_len > 0) p.fail_len else std.unicode.utf8ByteSequenceLength(p.text[p.fail_at]) catch 1;
        const token = p.text[p.fail_at..][0..@min(len, p.text.len - p.fail_at)];
        const what = if (p.missing) "missing token" else "syntax error";
        return std.fmt.allocPrint(p.arena, "Unparseable filter: {s} at line {d}, column {d}, token '{s}'", .{ what, line, column, token });
    }

    fn notModelled(p: *Parser, reason: []const u8) Fail {
        p.reason = reason;
        return error.NotModelled;
    }

    /// At the current token. Where the text ends straight after a
    /// keyword, production names the keyword ("insertId = x AND" at
    /// column 14, "NOT" at column 1); after a space or a line break, the
    /// end.
    fn syntaxError(p: *Parser) Fail {
        if (p.current.kind == .end and isKeyword(p.prev) and p.prev.at + p.prev.text.len == p.text.len) {
            p.fail_at = p.prev.at;
            p.fail_len = p.prev.text.len;
        } else {
            p.fail_at = p.current.at;
        }
        return error.Syntax;
    }

    fn isKeyword(t: Token) bool {
        if (t.kind != .word) return false;
        return std.mem.eql(u8, t.text, "AND") or std.mem.eql(u8, t.text, "OR") or std.mem.eql(u8, t.text, "NOT");
    }

    fn advance(p: *Parser) Fail!void {
        p.prev = p.current;
        var spaced = false;
        while (p.pos < p.text.len) {
            const c = p.text[p.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.pos += 1;
                spaced = true;
            } else if (c == '-' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '-') {
                while (p.pos < p.text.len and p.text[p.pos] != '\n') p.pos += 1;
                spaced = true;
            } else break;
        }
        const at = p.pos;
        if (p.pos >= p.text.len) {
            p.current = .{ .kind = .end, .text = "", .at = at, .spaced = spaced };
            return;
        }
        const c = p.text[p.pos];
        switch (c) {
            '(' => return p.single(.lparen, at, spaced),
            ')' => return p.single(.rparen, at, spaced),
            '=', '!', '<', '>', ':' => {
                const two = p.pos + 1 < p.text.len and (p.text[p.pos + 1] == '=' or p.text[p.pos + 1] == '~');
                // Production took "insertId ! x" without a refusal.
                if (c == '!' and !two) return p.notModelled("'!' standing alone");
                if (c == ':' or (c != '!' and !two) or (c == '=' and p.text[p.pos + 1] == '=')) {
                    p.pos += 1;
                } else p.pos += 2;
                p.current = .{ .kind = .op, .text = p.text[at..p.pos], .at = at, .spaced = spaced };
            },
            '"' => {
                var out: std.ArrayList(u8) = .empty;
                p.pos += 1;
                while (true) {
                    if (p.pos >= p.text.len) {
                        p.fail_at = at;
                        return error.Syntax;
                    }
                    const s = p.text[p.pos];
                    if (s == '"') break;
                    if (s == '\\') {
                        if (p.pos + 1 >= p.text.len) {
                            p.fail_at = at;
                            return error.Syntax;
                        }
                        // Production read each of these on 2026-10-16.
                        switch (p.text[p.pos + 1]) {
                            '"', '\\' => |e| try out.append(p.arena, e),
                            't' => try out.append(p.arena, '\t'),
                            'u' => {
                                if (p.pos + 6 > p.text.len) return p.notModelled("a \\u escape cut short");
                                const code = std.fmt.parseInt(u21, p.text[p.pos + 2 ..][0..4], 16) catch return p.notModelled("a \\u escape that is not four hex digits");
                                var buf: [4]u8 = undefined;
                                const n = std.unicode.utf8Encode(code, &buf) catch return p.notModelled("a \\u escape of a surrogate");
                                try out.appendSlice(p.arena, buf[0..n]);
                                p.pos += 4;
                            },
                            else => return p.notModelled("an escape other than \\\", \\\\, \\t and \\u in a string"),
                        }
                        p.pos += 2;
                    } else {
                        try out.append(p.arena, s);
                        p.pos += 1;
                    }
                }
                p.pos += 1;
                p.current = .{ .kind = .string, .text = out.items, .at = at, .spaced = spaced };
            },
            '-' => return p.single(.minus, at, spaced),
            else => {
                while (p.pos < p.text.len) : (p.pos += 1) {
                    switch (p.text[p.pos]) {
                        ' ', '\t', '\n', '\r', '(', ')', '=', '!', '<', '>', ':', '"' => break,
                        else => {},
                    }
                }
                p.current = .{ .kind = .word, .text = p.text[at..p.pos], .at = at, .spaced = spaced };
            },
        }
    }

    fn single(p: *Parser, kind: Token.Kind, at: usize, spaced: bool) void {
        p.pos += 1;
        p.current = .{ .kind = kind, .text = p.text[at..p.pos], .at = at, .spaced = spaced };
    }

    fn isWord(p: *const Parser, word: []const u8) bool {
        return p.current.kind == .word and std.mem.eql(u8, p.current.text, word);
    }

    /// Terms side by side, or joined by AND: AND binds loosest.
    fn andExpr(p: *Parser) Fail!Node {
        var list: std.ArrayList(Node) = .empty;
        try list.append(p.arena, try p.orExpr());
        while (true) {
            if (p.isWord("AND")) {
                try p.advance();
            } else if (p.current.kind == .end or p.current.kind == .rparen) break;
            try list.append(p.arena, try p.orExpr());
        }
        return if (list.items.len == 1) list.items[0] else .{ .all = list.items };
    }

    fn orExpr(p: *Parser) Fail!Node {
        var list: std.ArrayList(Node) = .empty;
        try list.append(p.arena, try p.unary());
        while (p.isWord("OR")) {
            try p.advance();
            try list.append(p.arena, try p.unary());
        }
        return if (list.items.len == 1) list.items[0] else .{ .any = list.items };
    }

    fn unary(p: *Parser) Fail!Node {
        if (p.isWord("NOT") or p.current.kind == .minus) {
            try p.advance();
            const inner = try p.arena.create(Node);
            inner.* = try p.unary();
            return .{ .not = inner };
        }
        return p.primary();
    }

    fn primary(p: *Parser) Fail!Node {
        switch (p.current.kind) {
            .lparen => {
                const open_at = p.current.at;
                try p.advance();
                if (p.current.kind == .rparen) return p.syntaxError();
                const inner = try p.andExpr();
                if (p.current.kind != .rparen) {
                    p.fail_at = open_at;
                    p.missing = true;
                    return error.Syntax;
                }
                try p.advance();
                return inner;
            },
            .word => {
                // A keyword where a term should be: production names what
                // follows it ("AND insertId = x" at column 4, a space).
                if (p.isWord("AND") or p.isWord("OR")) {
                    const after = p.current.at + p.current.text.len;
                    if (after >= p.text.len) {
                        p.fail_at = p.current.at;
                        p.fail_len = p.current.text.len;
                    } else p.fail_at = after;
                    return error.Syntax;
                }
                const word_at = p.current.at;
                const name = p.current.text;
                // A function call.
                if (p.pos < p.text.len and p.text[p.pos] == '(') {
                    if (!std.mem.eql(u8, name, "log_id")) return p.notModelled("a function other than log_id()");
                    try p.advance();
                    try p.advance();
                    if (p.current.kind != .string) return p.notModelled("log_id() with anything but one quoted string");
                    const id = p.current.text;
                    try p.advance();
                    if (p.current.kind != .rparen) return p.notModelled("log_id() with anything but one quoted string");
                    try p.advance();
                    return .{ .log_id = id };
                }
                const path = try p.fieldPath();
                if (p.current.kind != .op) {
                    if (path.len == 1) return p.notModelled("a search term with no field");
                    p.fail_at = word_at;
                    return error.Syntax;
                }
                return p.comparison(path);
            },
            .string => return p.notModelled("a search term with no field"),
            .end, .rparen, .op, .minus => return p.syntaxError(),
        }
    }

    /// A field path: words joined by dots, a component in double quotes
    /// where it holds a dot or a slash.
    fn fieldPath(p: *Parser) Fail![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        var expect_more = false;
        while (true) {
            switch (p.current.kind) {
                .word => {
                    var it = std.mem.splitScalar(u8, p.current.text, '.');
                    var first = true;
                    while (it.next()) |piece| {
                        if (piece.len == 0) {
                            // A dot at the start joins to what came before;
                            // one at the end, to a quoted part after.
                            if (first and parts.items.len > 0) {
                                first = false;
                                continue;
                            }
                            if (it.peek() == null) {
                                expect_more = true;
                                break;
                            }
                            // At the second dot, as production said of
                            // "labels..x = 1": column 8.
                            p.fail_at = p.current.at + (@intFromPtr(piece.ptr) - @intFromPtr(p.current.text.ptr));
                            return error.Syntax;
                        }
                        first = false;
                        try parts.append(p.arena, piece);
                        expect_more = false;
                    }
                    if (!std.mem.endsWith(u8, p.current.text, ".")) expect_more = false;
                },
                .string => {
                    if (!expect_more) break;
                    try parts.append(p.arena, p.current.text);
                    expect_more = false;
                },
                else => break,
            }
            try p.advance();
            // The path goes on only with no space before the next part, and
            // only across a dot.
            if (p.current.spaced) break;
            const next_dotted = p.current.kind == .word and std.mem.startsWith(u8, p.current.text, ".");
            if (!(expect_more and p.current.kind == .string) and !next_dotted) break;
        }
        if (expect_more) return p.syntaxError();
        return parts.items;
    }

    fn comparison(p: *Parser, path: []const []const u8) Fail!Node {
        const op_text = p.current.text;
        const op: Op = if (std.mem.eql(u8, op_text, "=")) .eq else if (std.mem.eql(u8, op_text, "!=")) .ne else if (std.mem.eql(u8, op_text, ":")) .has else if (std.mem.eql(u8, op_text, "<")) .lt else if (std.mem.eql(u8, op_text, "<=")) .le else if (std.mem.eql(u8, op_text, ">")) .gt else if (std.mem.eql(u8, op_text, ">=")) .ge else if (std.mem.eql(u8, op_text, "=~") or std.mem.eql(u8, op_text, "!~")) return p.notModelled("a regular expression") else return p.syntaxError();
        try p.advance();
        const value = switch (p.current.kind) {
            .word, .string => p.current.text,
            .minus => return p.notModelled("a value that starts with '-'"),
            else => return p.syntaxError(),
        };
        const presence = p.current.kind == .word and std.mem.eql(u8, value, "*") and op == .has;
        try p.advance();
        var c: Compare = .{ .field = try p.field(path), .op = op, .value = value, .presence = presence };
        switch (c.field) {
            .timestamp, .receive_timestamp => {
                if (op == .has) return p.notModelled("':' on a timestamp");
                c.time = parseTime(value) orelse return p.notModelled("a timestamp this fake cannot read");
            },
            .severity => {
                if (op == .has) return p.notModelled("':' on a severity");
                c.severity = parseSeverity(value) orelse return p.notModelled("a severity that is no name and no number");
            },
            else => {},
        }
        return .{ .compare = c };
    }

    fn field(p: *Parser, path: []const []const u8) Fail!Field {
        const head = path[0];
        if (path.len == 1) {
            const simple = std.StaticStringMap(Field).initComptime(.{
                .{ "timestamp", .timestamp },
                .{ "receiveTimestamp", .receive_timestamp },
                .{ "severity", .severity },
                .{ "logName", .log_name },
                .{ "insertId", .insert_id },
                .{ "trace", .trace },
                .{ "spanId", .span_id },
                .{ "textPayload", .text_payload },
            });
            return simple.get(head) orelse p.unknownField(head);
        }
        if (std.mem.eql(u8, head, "resource")) {
            if (path.len == 2 and std.mem.eql(u8, path[1], "type")) return .resource_type;
            if (path.len == 3 and std.mem.eql(u8, path[1], "labels")) return .{ .resource_label = path[2] };
        } else if (std.mem.eql(u8, head, "labels")) {
            if (path.len == 2) return .{ .label = path[1] };
        } else if (std.mem.eql(u8, head, "jsonPayload")) {
            return .{ .json = path[1..] };
        }
        return p.unknownField(head);
    }

    /// A field outside what this fake reads: one an entry has is not
    /// modelled; any other, production refuses by name.
    fn unknownField(p: *Parser, head: []const u8) Fail {
        const entry_fields = [_][]const u8{
            "logName",           "resource",         "protoPayload", "textPayload", "jsonPayload",
            "timestamp",         "receiveTimestamp", "severity",     "insertId",    "httpRequest",
            "labels",            "operation",        "trace",        "spanId",      "traceSampled",
            "sourceLocation",    "split",            "errorGroups",  "apphub",      "apphubSource",
            "apphubDestination", "otel",
        };
        for (entry_fields) |name| {
            if (std.mem.eql(u8, name, head)) return p.notModelled("a field this fake does not have");
        }
        p.reason = std.fmt.allocPrint(p.arena, "Field not found: '{s}'.", .{head}) catch return error.OutOfMemory;
        return error.Refused;
    }
};

/// RFC 3339, or a date alone, which is its midnight in UTC.
fn parseTime(text: []const u8) ?i96 {
    if (text.len == 10) {
        var buf: [20]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}T00:00:00Z", .{text}) catch return null;
        return (core.timestamp.parse(full) catch return null).nanoseconds;
    }
    return (core.timestamp.parse(text) catch return null).nanoseconds;
}

fn parseSeverity(text: []const u8) ?u16 {
    var upper: [16]u8 = undefined;
    if (text.len <= upper.len) {
        const name = std.ascii.upperString(&upper, text);
        const s = types.Severity.fromName(name);
        if (s != .unknown) return @backingInt(s);
    }
    return std.fmt.parseInt(u16, text, 10) catch null;
}

const testing = std.testing;

fn subjectOf(json: ?std.json.Value) Subject {
    return .{
        .timestamp = 1_792_141_200 * std.time.ns_per_s,
        .receive_timestamp = 1_792_141_201 * std.time.ns_per_s,
        .severity = 400,
        .log_name = "projects/p/logs/run.googleapis.com%2Fstderr",
        .log_id = "run.googleapis.com/stderr",
        .insert_id = "abc",
        .trace = "projects/p/traces/t1",
        .span_id = "s1",
        .text_payload = "Payment FAILED for order 7",
        .resource_type = "cloud_run_revision",
        .resource_labels = &.{.{ .key = "service_name", .value = "api" }},
        .labels = &.{ .{ .key = "env", .value = "prod" }, .{ .key = "compute.googleapis.com/zone", .value = "eu" } },
        .json = json,
    };
}

fn expectPass(arena: Allocator, filter_text: []const u8, subject: *const Subject, want: bool) !void {
    const r = try read(arena, filter_text);
    const node = switch (r) {
        .ok => |n| n,
        .unparseable, .refused => |m| {
            std.debug.print("{s}: {s}\n", .{ filter_text, m });
            return error.TestUnexpectedRefusal;
        },
        .not_modelled => |m| {
            std.debug.print("{s}: not modelled: {s}\n", .{ filter_text, m });
            return error.TestUnexpectedRefusal;
        },
    };
    const got = if (node) |n| switch (matches(n, subject)) {
        .pass => |ok| ok,
        .not_modelled => |m| {
            std.debug.print("{s}: not modelled when tried: {s}\n", .{ filter_text, m });
            return error.TestUnexpectedRefusal;
        },
    } else true;
    if (got != want) {
        std.debug.print("{s}: expected {}, got {}\n", .{ filter_text, want, got });
        return error.TestExpectedEqual;
    }
}

test "comparisons on every field this fake has" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"message\":\"payment failed\",\"order\":{\"id\":7,\"vip\":true},\"latency\":12.5,\"a.b\":\"dotted\",\"n\":null}", .{ .parse_numbers = false });
    const s = subjectOf(payload);
    const cases = [_]struct { []const u8, bool }{
        .{ "", true },
        .{ "timestamp >= \"2026-10-16T09:00:00Z\"", true },
        .{ "timestamp > \"2026-10-16T09:00:00Z\"", false },
        .{ "timestamp < \"2026-10-16T09:00:00.000000001Z\"", true },
        .{ "timestamp >= 2026-10-16", true },
        .{ "timestamp = \"2026-10-16T11:00:00+02:00\"", true },
        .{ "receiveTimestamp > \"2026-10-16T09:00:00Z\"", true },
        .{ "severity >= WARNING", true },
        .{ "severity > warning", false },
        .{ "severity = 400", true },
        .{ "severity < ERROR", true },
        .{ "severity != DEFAULT", true },
        .{ "logName = \"projects/p/logs/run.googleapis.com%2Fstderr\"", true },
        .{ "log_id(\"run.googleapis.com/stderr\")", true },
        .{ "log_id(\"run.googleapis.com%2Fstderr\")", false },
        .{ "insertId = abc", true },
        .{ "insertId = ABC", true },
        .{ "trace = \"projects/p/traces/t1\"", true },
        .{ "spanId = s2", false },
        .{ "textPayload: \"payment failed\"", true },
        .{ "textPayload:missing", false },
        .{ "textPayload:*", true },
        .{ "resource.type = cloud_run_revision", true },
        .{ "resource.labels.service_name = api", true },
        .{ "resource.labels.zone = eu", false },
        .{ "resource.labels.zone:*", false },
        .{ "labels.env = prod", true },
        .{ "labels.\"compute.googleapis.com/zone\" = eu", true },
        .{ "jsonPayload.message = \"Payment Failed\"", true },
        .{ "jsonPayload.order.id = 7", true },
        .{ "jsonPayload.order.id > 6.5", true },
        .{ "jsonPayload.order.vip = true", true },
        .{ "jsonPayload.latency <= 12.5", true },
        .{ "jsonPayload.\"a.b\" = dotted", true },
        .{ "jsonPayload.absent = x", false },
        .{ "jsonPayload.n = x", false },
        .{ "jsonPayload.order.absent:*", false },
    };
    for (cases) |case| try expectPass(a, case[0], &s, case[1]);
}

test "the language's precedence: NOT, then OR, then AND" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = subjectOf(null);
    // (true OR false) AND false: false. The usual precedence would say true.
    try expectPass(a, "insertId = abc OR insertId = x AND insertId = y", &s, false);
    try expectPass(a, "insertId = x AND insertId = y OR insertId = abc", &s, false);
    // The docs' example: "a" OR NOT "b" AND NOT "c" OR "d".
    try expectPass(a, "insertId = x OR NOT insertId = abc AND NOT insertId = abc OR insertId = abc", &s, false);
    try expectPass(a, "insertId = abc OR NOT insertId = x AND NOT insertId = y OR insertId = z", &s, true);
    try expectPass(a, "(insertId = abc OR insertId = x) AND insertId = abc", &s, true);
    // Side by side is AND; a leading minus is NOT.
    try expectPass(a, "insertId = abc spanId = s1", &s, true);
    try expectPass(a, "insertId = abc -spanId = s1", &s, false);
    try expectPass(a, "NOT (insertId = x OR spanId = y)", &s, true);
    // Comments, to the end of a line, and new lines between terms.
    try expectPass(a, "insertId = abc -- AND spanId = nope\n\tAND spanId = s1", &s, true);
    try expectPass(a, "(\ninsertId = abc -- the caller's filter\n)\nAND severity >= INFO", &s, true);
}

test "what it does not model, it says, never guesses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "textPayload =~ \"pay.*\"",
        "textPayload !~ x",
        "\"payment\"",
        "payment",
        "insertId = abc and spanId = s1",
        "SEARCH(\"x\")",
        "sample(insertId, 0.5)",
        "protoPayload.methodName = x",
        "httpRequest.status = 500",

        "resource.labels = x",
        "textPayload = \"a\\nb\"",
        "insertId ! abc",
        "timestamp: 2026",
        "timestamp > yesterday",
        "severity >= LOUD",
        "insertId = -x",
    }) |text_| {
        switch (try read(a, text_)) {
            .not_modelled => {},
            else => |r| {
                std.debug.print("{s}: {any}\n", .{ text_, r });
                return error.TestExpectedNotModelled;
            },
        }
    }
    // When tried: != on a missing field, and comparisons the fake cannot rank.
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"list\":[1],\"n\":5}", .{ .parse_numbers = false });
    const s = subjectOf(payload);
    for ([_][]const u8{ "jsonPayload.list = 1", "insertId > a", "jsonPayload.n = five", "jsonPayload.n: 5" }) |text_| {
        const node = (try read(a, text_)).ok.?;
        try testing.expect(matches(node, &s) == .not_modelled);
    }
}

test "production's measured answers: != and = on a missing field are false, case folds past ASCII, unknown fields are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = subjectOf(null);
    s.text_payload = "MixedCase \u{c9}t\u{e9}";
    // labels.missing != "x" and labels.missing = "x" matched nothing.
    try expectPass(a, "labels.missing != x", &s, false);
    try expectPass(a, "labels.missing = x", &s, false);
    try expectPass(a, "NOT labels.missing = x", &s, true);
    // textPayload = "mixedcase été" matched "MixedCase Été".
    try expectPass(a, "textPayload = \"mixedcase \u{e9}t\u{e9}\"", &s, true);
    try expectPass(a, "textPayload: \"\u{c9}T\u{c9}\"", &s, true);
    try expectPass(a, "textPayload: \"\u{e8}\"", &s, false);
    try expectPass(a, "textPayload: \"\"", &s, true);
    // \t and \u00e9 in a string, as production read them.
    s.text_payload = "a\tb \u{e9}";
    try expectPass(a, "textPayload = \"a\\tb \\u00e9\"", &s, true);
    try expectPass(a, "textPayload = \"atb \\u00e9\"", &s, false);
    try testing.expect((try read(a, "textPayload = \"\\u00\"")) == .not_modelled);
    try testing.expect((try read(a, "textPayload = \"\\ud800\"")) == .not_modelled);
    try testing.expect((try read(a, "textPayload = \"\\uzzzz\"")) == .not_modelled);
    // "thud = 1" was refused by name.
    try testing.expectEqualStrings("Field not found: 'thud'.", (try read(a, "thud = 1")).refused);
    try testing.expectEqualStrings("Field not found: 'thud'.", (try read(a, "thud.x.y = 1")).refused);
    // A field an entry has, but this fake does not read, is not modelled.
    try testing.expect((try read(a, "traceSampled = true")) == .not_modelled);
}

test "what it cannot read is refused in production's sentence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        // Each as production said it on 2026-10-16, but the last, the
        // fake's own position for a case production was not shown.
        .{ "insertId =", "syntax error at line 1, token '<EOF>'" },
        .{ "(insertId = abc", "missing token at line 1, column 1, token '('" },
        .{ "insertId = abc)", "syntax error at line 1, column 15, token ')'" },
        .{ "AND insertId = abc", "syntax error at line 1, column 4, token ' '" },
        .{ "OR insertId = abc", "syntax error at line 1, column 3, token ' '" },
        .{ "insertId = abc AND", "syntax error at line 1, column 16, token 'AND'" },
        .{ "insertId = abc OR", "syntax error at line 1, column 16, token 'OR'" },
        .{ "NOT", "syntax error at line 1, column 1, token 'NOT'" },
        .{ "insertId = b\nAND\n", "syntax error at line 3, token '<EOF>'" },
        .{ "()", "syntax error at line 1, column 2, token ')'" },
        .{ "insertId = \"abc", "syntax error at line 1, column 12, token '\"'" },
        .{ "labels..x = 1", "syntax error at line 1, column 8, token '.'" },
        .{ "labels.x = caf\u{e9})", "syntax error at line 1, column 16, token ')'" },
    };
    for (cases) |case| {
        switch (try read(a, case[0])) {
            .unparseable => |m| {
                try testing.expect(std.mem.startsWith(u8, m, "Unparseable filter: "));
                if (std.mem.indexOf(u8, m, case[1]) == null) {
                    std.debug.print("{s}: {s}\n", .{ case[0], m });
                    return error.TestExpectedEqual;
                }
            },
            else => |r| {
                std.debug.print("{s}: {any}\n", .{ case[0], r });
                return error.TestExpectedUnparseable;
            },
        }
    }
}

test "the module's joined filters read back as the caller's filter AND the clauses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const filter_mod = @import("filter.zig");
    const s = subjectOf(null);
    const joined = (try filter_mod.join(a, .{
        .filter = "insertId = x OR insertId = abc -- either",
        .since = .{ .nanoseconds = 1_792_141_200 * std.time.ns_per_s },
        .min_severity = .warning,
        .log_id = "run.googleapis.com/stderr",
        .resource_type = "cloud_run_revision",
    })).ok;
    try expectPass(a, joined, &s, true);
    const refusing = (try filter_mod.join(a, .{ .filter = "insertId = abc", .min_severity = .@"error" })).ok;
    try expectPass(a, refusing, &s, false);
}

fn clauseValue(g: *core.testing.ByteGen, buf: []u8) []const u8 {
    const picks = [_][]const u8{ "run.googleapis.com/stderr", "cloud_run_revision", "CLOUD_RUN_REVISION", "a\"b", "back\\slash", "caf\u{e9}", "", "x y" };
    if (g.boolean()) return g.pick([]const u8, &picks);
    return g.utf8(buf, 12);
}

fn joinProperty(_: void, input: []const u8) !void {
    const filter_mod = @import("filter.zig");
    var g: core.testing.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(@import("test_util.zig").propertyAllocator());
    defer arena.deinit();
    const a = arena.allocator();
    const callers = [_][]const u8{
        "",
        "insertId = abc",
        "insertId = x OR insertId = abc",
        "insertId = abc -- a trailing comment",
        "NOT spanId = s1",
        "insertId = x OR spanId = s1 AND severity >= ERROR",
        "-- only a comment\ninsertId:a",
        "(insertId = abc)\n",
    };
    const caller = g.pick([]const u8, &callers);
    const base: i96 = 1_792_141_200 * std.time.ns_per_s;
    var log_buf: [64]u8 = undefined;
    var type_buf: [64]u8 = undefined;
    const severities = [_]types.Severity{ .default, .debug, .info, .warning, .@"error", .emergency };
    const parts: filter_mod.Parts = .{
        .filter = caller,
        .since = if (g.boolean()) .{ .nanoseconds = base + (@as(i96, g.intRange(u8, 0, 6)) - 3) } else null,
        .until = if (g.boolean()) .{ .nanoseconds = base + (@as(i96, g.intRange(u8, 0, 6)) - 3) } else null,
        .min_severity = if (g.boolean()) g.pick(types.Severity, &severities) else null,
        .log_id = if (g.boolean()) clauseValue(&g, &log_buf) else null,
        .resource_type = if (g.boolean()) clauseValue(&g, &type_buf) else null,
    };
    const joined = switch (try filter_mod.join(a, parts)) {
        .ok => |text| text,
        // Refused before sending: nothing to read back.
        .refused => return,
    };
    const subject: Subject = .{
        .timestamp = base + (@as(i96, g.intRange(u8, 0, 6)) - 3),
        .receive_timestamp = base,
        .severity = @backingInt(g.pick(types.Severity, &severities)),
        .log_name = "projects/p/logs/x",
        .log_id = g.pick([]const u8, &.{ "run.googleapis.com/stderr", "a\"b", "caf\u{e9}", "" }),
        .insert_id = g.pick([]const u8, &.{ "abc", "x", "ABC" }),
        .trace = "",
        .span_id = g.pick([]const u8, &.{ "s1", "s2" }),
        .text_payload = null,
        .resource_type = g.pick([]const u8, &.{ "cloud_run_revision", "gce_instance", "a\"b", "back\\slash" }),
        .resource_labels = &.{},
        .labels = &.{},
        .json = null,
    };
    // The joined filter means the caller's AND every clause, whatever the
    // caller wrote around it.
    const node = switch (try read(a, joined)) {
        .ok => |n| n,
        else => |r| {
            std.debug.print("joined filter not read: {s}\n{any}\n", .{ joined, r });
            return error.TestJoinedFilterUnread;
        },
    };
    const caller_passes = if ((try read(a, caller)).ok) |n| matches(n, &subject).pass else true;
    var want = caller_passes;
    if (parts.since) |t| want = want and subject.timestamp >= t.nanoseconds;
    if (parts.until) |t| want = want and subject.timestamp < t.nanoseconds;
    if (parts.min_severity) |s| want = want and subject.severity >= @backingInt(s);
    if (parts.log_id) |id| want = want and std.mem.eql(u8, subject.log_id, id);
    if (parts.resource_type) |t| want = want and std.ascii.eqlIgnoreCase(subject.resource_type, t);
    const got = if (node) |n| matches(n, &subject).pass else true;
    if (got != want) {
        std.debug.print("joined: {s}\nwant {}, got {}\n", .{ joined, want, got });
        return error.TestExpectedEqual;
    }
}

test "fuzz filter join: the joined filter reads back as the caller's AND every clause" {
    try core.testing.fuzzBytes({}, joinProperty, .{ .corpus = &.{ "", "\xff\xff\xff\xff\xff\xff\xff\xff", "\x03\x01\x01\x02\x01\x05\x01\x00" } });
}

test "what is not modelled inside AND and OR stops the whole filter; != on a present field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"list\":[1]}", .{ .parse_numbers = false });
    const with_list = subjectOf(listed);
    for ([_][]const u8{ "insertId = abc AND jsonPayload.list = 1", "insertId = x OR jsonPayload.list = 1" }) |text_| {
        const node = (try read(a, text_)).ok.?;
        try testing.expect(matches(node, &with_list) == .not_modelled);
    }
    const s = subjectOf(null);
    try expectPass(a, "spanId != s2", &s, true);
    try expectPass(a, "spanId != S1", &s, false);
    // A quoted part with more path after it.
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"a.b\":{\"c\":1}}", .{ .parse_numbers = false });
    try expectPass(a, "jsonPayload.\"a.b\".c = 1", &subjectOf(payload), true);
}

test "JSON numbers a caller parsed as integers and floats compare too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"i\":7,\"f\":2.5}", .{});
    const s = subjectOf(payload);
    try expectPass(a, "jsonPayload.i >= 7", &s, true);
    try expectPass(a, "jsonPayload.f < 2.5", &s, false);
}

test "more of what it cannot read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "insertId = \"abc\\", "line 1, column 12, token '\"'" },
        .{ "labels.x AND insertId = abc", "line 1, column 1, token 'l'" },
        .{ "labels..x = 1", "line 1, column 8, token '.'" },
        .{ "labels. = 1", "line 1, column 9, token '='" },
    };
    for (cases) |case| {
        const m = (try read(a, case[0])).unparseable;
        if (std.mem.indexOf(u8, m, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[0], m });
            return error.TestExpectedEqual;
        }
    }
}

test "a keyword alone, and text that is not UTF-8" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Unparseable filter: syntax error at line 1, column 1, token 'AND'", (try read(a, "AND")).unparseable);
    var s = subjectOf(null);
    s.text_payload = "a\xffb";
    try expectPass(a, "textPayload = \"a\"", &s, false);
    try expectPass(a, "textPayload: \"b\"", &s, true);
}
