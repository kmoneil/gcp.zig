//! A subscription's filter, for the in-memory Pub/Sub: read as production
//! read each filter it was shown on 2026-10-12
//! (`_tmp/pubsub-extras/production-fake-1.txt` and `-4.txt`), and tried on
//! a message's attributes as production tried it. Test code only.
//!
//! What production took, this takes: `attributes.key = "value"` and `!=`,
//! `attributes:key`, `hasPrefix(attributes.key, "value")`, `NOT` and a
//! leading `-`, `AND`, `OR`, parentheses, a quoted key, a key with a hyphen
//! or with letters outside ASCII, a tab or a line break where a space may
//! stand, and in a literal `\"`, `\\`, `\n` and `\t`. Keys and values are
//! compared byte for byte. A message without the attribute passes `!=` and
//! fails `=`, an empty literal included.
//!
//! What production refused, this refuses in production's sentence, at the
//! columns the same rule gives. Every kind of refusal here was seen word
//! for word, and the tests hold each filter production was shown. Columns
//! count characters and the limit of 256 counts bytes, as production's do.
//!
//! Where production was not shown a shape, or answered one with an
//! internal error (a minus after a minus), nothing is guessed at: the
//! filter is `not_modelled`, with the reason.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Production's limit, in bytes.
pub const max_len = 256;

/// A filter production would take, ready to try on a message.
pub const Filter = union(enum) {
    all: []const Filter,
    any: []const Filter,
    not: *const Filter,
    /// The attribute is there, with this value.
    equals: Pair,
    /// It is not: missing, or with another value.
    differs: Pair,
    /// It is there, and begins so.
    prefix: Pair,
    /// It is there.
    has: []const u8,

    pub const Pair = struct { key: []const u8, value: []const u8 };

    /// `attributes` is a slice of anything with a `key` and a `value`.
    pub fn matches(f: Filter, attributes: anytype) bool {
        return switch (f) {
            .all => |list| for (list) |one| {
                if (!one.matches(attributes)) break false;
            } else true,
            .any => |list| for (list) |one| {
                if (one.matches(attributes)) break true;
            } else false,
            .not => |one| !one.matches(attributes),
            .equals => |p| if (lookup(attributes, p.key)) |v| std.mem.eql(u8, v, p.value) else false,
            .differs => |p| if (lookup(attributes, p.key)) |v| !std.mem.eql(u8, v, p.value) else true,
            .prefix => |p| if (lookup(attributes, p.key)) |v| std.mem.startsWith(u8, v, p.value) else false,
            .has => |key| lookup(attributes, key) != null,
        };
    }
};

fn lookup(attributes: anytype, key: []const u8) ?[]const u8 {
    for (attributes) |a| {
        if (std.mem.eql(u8, a.key, key)) return a.value;
    }
    return null;
}

pub const Outcome = union(enum) {
    ok: Filter,
    /// Production's refusal, whole: a 400, `INVALID_ARGUMENT`.
    refused: []const u8,
    /// A shape production was not shown, or one it answered with an
    /// internal error: why, in the fake's words.
    not_modelled: []const u8,
};

/// Reads `text`, which is not empty. Everything in the answer is in
/// `arena`, and none of it points into `text`.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Outcome {
    if (text.len > max_len) return .{ .refused = try std.fmt.allocPrint(arena, "Invalid filter expression: length {d} exceeds maximum allowed length of {d}.", .{ text.len, max_len }) };
    var p: Parser = .{ .arena = arena, .text = text };
    const filter = p.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return .{ .refused = p.message },
        error.NotModelled => return .{ .not_modelled = p.message },
    };
    return .{ .ok = filter };
}

/// Bytes of the text: `start` to `end`, the last not included.
const Span = struct { start: usize, end: usize };

const Token = struct {
    tag: Tag,
    span: Span,
    /// White space stands before it.
    spaced: bool,

    const Tag = enum { word, string, open, close, comma, dot, colon, operator, minus, end };
};

/// A name with a key under it, `attributes.kind`, or a literal.
const Operand = struct {
    span: Span,
    kind: union(enum) {
        /// Without its quotes and its escapes.
        literal: []const u8,
        path: []const Segment,
    },
};

/// A name of a path, or a quoted one after a dot, without its quotes.
const Segment = struct { span: Span, text: []const u8 };

/// The filter as it was written, before anything is asked of its sense.
const Expr = struct {
    span: Span,
    kind: union(enum) {
        conjunction: []const Expr,
        disjunction: []const Expr,
        /// Terms side by side, with no operator between them.
        sequence: []const Expr,
        negation: *const Expr,
        group: *const Expr,
        comparison: struct { left: Operand, operator: Span, right: Operand },
        has: struct { left: Operand, right: Operand },
        call: struct { name: Span, args: []const Operand },
        /// An operand alone.
        bare: Operand,
    },
};

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    tokens: []const Token = &.{},
    at: usize = 0,
    /// Why it stopped: production's words, or the fake's.
    message: []const u8 = "",

    const Error = Allocator.Error || error{ Refused, NotModelled };

    fn run(p: *Parser) Error!Filter {
        try p.lex();
        if (p.tokens.len == 1) {
            p.message = "Invalid filter expression: contains only whitespace characters.";
            return error.Refused;
        }
        const whole = try p.expression();
        const after = p.peek();
        if (after.tag != .end) return p.syntaxError(after);
        return p.check(whole);
    }

    // Tokens.

    fn lex(p: *Parser) Error!void {
        var tokens: std.ArrayList(Token) = .empty;
        const text = p.text;
        var i: usize = 0;
        var spaced = false;
        while (i < text.len) {
            const start = i;
            const tag: Token.Tag = switch (text[i]) {
                // Production took a tab and a line break for a space.
                ' ', '\t', '\n' => {
                    i += 1;
                    spaced = true;
                    continue;
                },
                '(' => .open,
                ')' => .close,
                ',' => .comma,
                '.' => .dot,
                ':' => .colon,
                '-' => .minus,
                '=' => .operator,
                '<', '>' => operator: {
                    if (i + 1 < text.len and text[i + 1] == '=') i += 1;
                    break :operator .operator;
                },
                // Alone it is a word to production, and so a term.
                '!' => operator: {
                    if (i + 1 == text.len or text[i + 1] != '=') break :operator .word;
                    i += 1;
                    break :operator .operator;
                },
                '"' => string: {
                    i += 1;
                    while (i < text.len and text[i] != '"') i += if (text[i] == '\\') 2 else 1;
                    // With no closing quote production names the opening one.
                    if (i >= text.len) return p.syntaxError(.{ .tag = .string, .span = .{ .start = start, .end = start + 1 }, .spaced = spaced });
                    break :string .string;
                },
                else => |c| word: {
                    if (!inWord(c)) return p.notModelled("the byte 0x{x:0>2} outside a literal", .{c}, i);
                    while (i + 1 < text.len and inWord(text[i + 1])) i += 1;
                    break :word .word;
                },
            };
            i += 1;
            try tokens.append(p.arena, .{ .tag = tag, .span = .{ .start = start, .end = i }, .spaced = spaced });
            spaced = false;
        }
        try tokens.append(p.arena, .{ .tag = .end, .span = .{ .start = text.len, .end = text.len }, .spaced = spaced });
        p.tokens = tokens.items;
    }

    /// What a word is made of, of what production was shown: letters,
    /// digits, `_`, a hyphen after its first character, a single quote,
    /// and anything outside ASCII.
    fn inWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'' or c >= 0x80;
    }

    fn peek(p: *const Parser) Token {
        return p.tokens[p.at];
    }

    fn slice(p: *const Parser, span: Span) []const u8 {
        return p.text[span.start..span.end];
    }

    fn isWord(p: *const Parser, token: Token, comptime word: []const u8) bool {
        return token.tag == .word and std.mem.eql(u8, p.slice(token.span), word);
    }

    /// `AND` and `OR` in capitals join terms; in any other case they are
    /// words like any other.
    fn startsTerm(p: *const Parser, token: Token) bool {
        return switch (token.tag) {
            .word => !p.isWord(token, "AND") and !p.isWord(token, "OR"),
            .string, .open, .minus => true,
            .close, .comma, .dot, .colon, .operator, .end => false,
        };
    }

    // The grammar.

    /// Terms joined by `AND`, or by `OR`: never by both.
    fn expression(p: *Parser) Error!Expr {
        const first = try p.sequence();
        const joiner = p.peek();
        const conjunction = p.isWord(joiner, "AND");
        if (!conjunction and !p.isWord(joiner, "OR")) return first;
        var list: std.ArrayList(Expr) = .empty;
        try list.append(p.arena, first);
        while (true) {
            const token = p.peek();
            const and_here = p.isWord(token, "AND");
            if (!and_here and !p.isWord(token, "OR")) break;
            // Production names the operator itself when it stands hard
            // against what is before it, when it is of the other kind,
            // and when nothing comes after it.
            if (!token.spaced or and_here != conjunction) return p.syntaxError(token);
            p.at += 1;
            if (p.peek().tag == .end) return p.syntaxError(token);
            try list.append(p.arena, try p.sequence());
        }
        const span: Span = .{ .start = first.span.start, .end = list.items[list.items.len - 1].span.end };
        return .{ .span = span, .kind = if (conjunction) .{ .conjunction = list.items } else .{ .disjunction = list.items } };
    }

    fn sequence(p: *Parser) Error!Expr {
        const first = try p.term();
        if (!p.startsTerm(p.peek())) return first;
        var list: std.ArrayList(Expr) = .empty;
        try list.append(p.arena, first);
        while (p.startsTerm(p.peek())) try list.append(p.arena, try p.term());
        return .{ .span = .{ .start = first.span.start, .end = list.items[list.items.len - 1].span.end }, .kind = .{ .sequence = list.items } };
    }

    fn term(p: *Parser) Error!Expr {
        const token = p.peek();
        switch (token.tag) {
            .minus => {
                p.at += 1;
                const after = p.peek();
                // A minus stands hard against its term.
                if (after.tag == .end) return p.notModelled("a minus with nothing after it", .{}, token.span.start);
                if (after.spaced) return p.spaceError(token.span.end, "a minus before white space other than a space");
                if (after.tag == .minus) return p.notModelled("a minus after a minus, which production answers with an internal error", .{}, after.span.start);
                if (p.isWord(after, "NOT")) return p.notModelled("NOT after a minus", .{}, after.span.start);
                return p.negation(token);
            },
            .word => {
                if (p.isWord(token, "AND") or p.isWord(token, "OR")) return p.keywordError(token);
                if (!p.isWord(token, "NOT")) return p.restriction();
                p.at += 1;
                const after = p.peek();
                // Alone at the end, production names it. Before a second
                // one, the space after that one.
                if (after.tag == .end) return p.syntaxError(token);
                if (!after.spaced) return p.notModelled("NOT hard against what comes after it", .{}, token.span.start);
                if (p.isWord(after, "NOT")) return p.keywordError(after);
                if (after.tag == .minus) return p.notModelled("a minus after NOT", .{}, after.span.start);
                return p.negation(token);
            },
            .string => return p.restriction(),
            .open => {
                p.at += 1;
                const inner = try p.arena.create(Expr);
                inner.* = try p.expression();
                const close = p.peek();
                switch (close.tag) {
                    .close => p.at += 1,
                    .end => return p.positioned("failed to parse (missing token at line 1, column {d}, token '(')", .{p.column(token.span.start)}),
                    else => return p.syntaxError(close),
                }
                return .{ .span = .{ .start = token.span.start, .end = close.span.end }, .kind = .{ .group = inner } };
            },
            .end => return p.notModelled("nothing where a term should begin", .{}, token.span.start),
            .close, .comma, .dot, .colon, .operator => return p.syntaxError(token),
        }
    }

    /// The term after `NOT` or a minus, which are consumed.
    fn negation(p: *Parser, operator: Token) Error!Expr {
        const inner = try p.arena.create(Expr);
        inner.* = try p.term();
        return .{ .span = .{ .start = operator.span.start, .end = inner.span.end }, .kind = .{ .negation = inner } };
    }

    /// An operand and what is asked of it: `=`, `:`, or a call's
    /// arguments. With nothing asked, the operand alone.
    fn restriction(p: *Parser) Error!Expr {
        const left = try p.operand();
        const token = p.peek();
        switch (token.tag) {
            .operator => {
                p.at += 1;
                const right = try p.operand();
                return .{ .span = .{ .start = left.span.start, .end = right.span.end }, .kind = .{ .comparison = .{ .left = left, .operator = token.span, .right = right } } };
            },
            .colon => {
                p.at += 1;
                const right = try p.operand();
                return .{ .span = .{ .start = left.span.start, .end = right.span.end }, .kind = .{ .has = .{ .left = left, .right = right } } };
            },
            .open => {
                // A function's name stands hard against its parenthesis.
                // After a space the name is a term alone, and the
                // parenthesis opens the next.
                if (token.spaced) return .{ .span = left.span, .kind = .{ .bare = left } };
                const name = switch (left.kind) {
                    .path => |segments| if (segments.len == 1) segments[0].span else null,
                    .literal => null,
                } orelse return p.notModelled("a parenthesis hard against what is no function's name", .{}, token.span.start);
                p.at += 1;
                var args: std.ArrayList(Operand) = .empty;
                var close = p.peek();
                if (close.tag == .close) p.at += 1 else while (true) {
                    try args.append(p.arena, try p.operand());
                    close = p.peek();
                    switch (close.tag) {
                        .close => {
                            p.at += 1;
                            break;
                        },
                        .comma => p.at += 1,
                        .end => return p.notModelled("a function's arguments that are not closed", .{}, token.span.start),
                        else => return p.syntaxError(close),
                    }
                }
                return .{ .span = .{ .start = left.span.start, .end = close.span.end }, .kind = .{ .call = .{ .name = name, .args = args.items } } };
            },
            .word, .string, .close, .comma, .dot, .minus, .end => return .{ .span = left.span, .kind = .{ .bare = left } },
        }
    }

    fn operand(p: *Parser) Error!Operand {
        const first = p.peek();
        switch (first.tag) {
            .string => {
                p.at += 1;
                return .{ .span = first.span, .kind = .{ .literal = try p.unquoted(first.span) } };
            },
            .word => {
                p.at += 1;
                var segments: std.ArrayList(Segment) = .empty;
                try segments.append(p.arena, .{ .span = first.span, .text = try p.arena.dupe(u8, p.slice(first.span)) });
                var end = first.span.end;
                while (true) {
                    const dot = p.peek();
                    if (dot.tag != .dot) break;
                    if (dot.spaced) return p.notModelled("white space before a '.'", .{}, dot.span.start);
                    p.at += 1;
                    // A name comes hard after its dot: production names
                    // the space that comes instead.
                    const name = p.peek();
                    if (name.tag != .end and name.spaced) return p.spaceError(dot.span.end, "a '.' before white space other than a space");
                    switch (name.tag) {
                        .word => try segments.append(p.arena, .{ .span = name.span, .text = try p.arena.dupe(u8, p.slice(name.span)) }),
                        .string => try segments.append(p.arena, .{ .span = name.span, .text = try p.unquoted(name.span) }),
                        else => return p.syntaxError(name),
                    }
                    p.at += 1;
                    end = name.span.end;
                }
                return .{ .span = .{ .start = first.span.start, .end = end }, .kind = .{ .path = segments.items } };
            },
            else => return p.syntaxError(first),
        }
    }

    /// A literal's text. Production read `\"`, `\\`, `\n` and `\t`; it
    /// was shown no other escape.
    fn unquoted(p: *Parser, span: Span) Error![]const u8 {
        const inner = p.text[span.start + 1 .. span.end - 1];
        const out = try p.arena.alloc(u8, inner.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            out[n] = inner[i];
            if (inner[i] == '\\') {
                i += 1;
                out[n] = switch (inner[i]) {
                    '"', '\\' => inner[i],
                    'n' => '\n',
                    't' => '\t',
                    else => return p.notModelled("an escape in a literal other than \\\", \\\\, \\n and \\t", .{}, span.start + i),
                };
            }
            n += 1;
        }
        return out[0..n];
    }

    // Its sense, asked in the order it is written.

    fn check(p: *Parser, e: Expr) Error!Filter {
        switch (e.kind) {
            .sequence => return p.refuse("Implicit conjunctions are not permitted. Please use the AND operator explicitly.", .{}, e.span),
            .conjunction => |list| return .{ .all = try p.checkAll(list) },
            .disjunction => |list| return .{ .any = try p.checkAll(list) },
            .negation => |inner| {
                const kept = try p.arena.create(Filter);
                kept.* = try p.check(inner.*);
                return .{ .not = kept };
            },
            .group => |inner| return p.check(inner.*),
            .bare => return p.refuse("Expected either a function call or an expression with an operator", .{}, e.span),
            .comparison => |c| {
                // Of several things wrong, production names the operator
                // before the left side, and the left side before the right.
                const operator = p.slice(c.operator);
                const equal = std.mem.eql(u8, operator, "=");
                if (!equal and !std.mem.eql(u8, operator, "!=")) return p.refuse("Invalid operator", .{}, e.span);
                const key = try p.attribute(c.left);
                const value = switch (c.right.kind) {
                    .literal => |text| text,
                    .path => return p.refuse("Invalid right-hand side operand, expected string literal", .{}, c.right.span),
                };
                const pair: Filter.Pair = .{ .key = key, .value = value };
                return if (equal) .{ .equals = pair } else .{ .differs = pair };
            },
            .has => |h| {
                switch (h.left.kind) {
                    .literal => return p.refuse("Invalid identifier. Did you mean attributes?", .{}, h.left.span),
                    .path => |segments| if (!isAttributes(segments[0])) {
                        if (segments.len > 1) return p.notModelled("a key under a name other than attributes before ':'", .{}, h.left.span.start);
                        return p.refuse("Undefined object '{s}'. Did you mean attributes?", .{segments[0].text}, h.left.span);
                    } else if (segments.len > 1) return p.refuse("Invalid identifier. Did you mean attributes?", .{}, h.left.span),
                }
                return .{ .has = switch (h.right.kind) {
                    .literal => |text| text,
                    .path => |segments| if (segments.len == 1) segments[0].text else return p.refuse("Invalid attribute key", .{}, h.right.span),
                } };
            },
            .call => |c| {
                const name = p.slice(c.name);
                if (!std.mem.eql(u8, name, "hasPrefix")) return p.refuse("Undefined function '{s}'. Did you mean hasPrefix?", .{name}, c.name);
                if (c.args.len != 2) return p.refuse("hasPrefix function expects 2 arguments, but was called with {d} arg{s}", .{ c.args.len, if (c.args.len == 1) "" else "s" }, e.span);
                const key = switch (c.args[0].kind) {
                    .literal => null,
                    .path => |segments| key: {
                        if (segments.len == 1) break :key null;
                        if (segments.len > 2 or !isAttributes(segments[0])) return p.notModelled("hasPrefix of a path that is no attribute", .{}, c.args[0].span.start);
                        break :key segments[1].text;
                    },
                } orelse return p.refuse("Invalid 1st argument passed to hasPrefix function, should be an attribute lookup", .{}, c.args[0].span);
                const value = switch (c.args[1].kind) {
                    .literal => |text| text,
                    .path => return p.refuse("Invalid 2nd argument passed to hasPrefix function, expected string literal", .{}, c.args[1].span),
                };
                return .{ .prefix = .{ .key = key, .value = value } };
            },
        }
    }

    fn checkAll(p: *Parser, list: []const Expr) Error![]const Filter {
        const out = try p.arena.alloc(Filter, list.len);
        for (list, out) |e, *slot| slot.* = try p.check(e);
        return out;
    }

    /// A path begins with a word, so its first name is never a quoted one.
    fn isAttributes(first: Segment) bool {
        return std.mem.eql(u8, first.text, "attributes");
    }

    /// The key of `attributes.key`, on the left of an operator.
    fn attribute(p: *Parser, left: Operand) Error![]const u8 {
        const segments = switch (left.kind) {
            .literal => return p.refuse("Invalid left-hand side operand, should be an attribute lookup", .{}, left.span),
            .path => |segments| segments,
        };
        // A name alone is no lookup, `attributes` itself included.
        if (segments.len == 1) return p.refuse("Invalid left-hand side operand, should be an attribute lookup", .{}, left.span);
        if (!isAttributes(segments[0])) return p.refuse("Undefined object '{s}'. Did you mean attributes?", .{segments[0].text}, segments[0].span);
        if (segments.len > 2) return p.refuse("Attempted to access member of a string value", .{}, segments[2].span);
        return segments[1].text;
    }

    // How it stops.

    /// The column of the character at byte `offset`, from 1. Production's
    /// columns count characters: an `é` is one.
    fn column(p: *const Parser, offset: usize) usize {
        var n: usize = 1;
        for (p.text[0..offset]) |c| n += @intFromBool(c & 0xc0 != 0x80);
        return n;
    }

    /// A refusal that says where. Production was shown none in a filter
    /// of more than one line, where the line would count.
    fn positioned(p: *Parser, comptime words: []const u8, args: anytype) Error {
        if (std.mem.indexOfScalar(u8, p.text, '\n')) |line_break| return p.notModelled("a refusal in a filter of more than one line", .{}, line_break);
        p.message = try std.fmt.allocPrint(p.arena, "Invalid filter expression: " ++ words ++ ".", args);
        return error.Refused;
    }

    /// Production's sentence about a part of the filter, with its columns:
    /// from 1, the last included.
    fn refuse(p: *Parser, comptime words: []const u8, args: anytype, span: Span) Error {
        const said = try std.fmt.allocPrint(p.arena, words, args);
        return p.positioned("{s} (line 1, columns {d} to {d})", .{ said, p.column(span.start), p.column(span.end) - 1 });
    }

    /// A token where the grammar has no place for it. At the end of the
    /// text production gives no column.
    fn syntaxError(p: *Parser, token: Token) Error {
        if (token.tag == .end) return p.positioned("failed to parse (syntax error at line 1, token '<EOF>')", .{});
        return p.positioned("failed to parse (syntax error at line 1, column {d}, token '{s}')", .{ p.column(token.span.start), p.slice(token.span) });
    }

    /// `AND` or `OR` where a term should begin, or a second `NOT`:
    /// production names the space after it.
    fn keywordError(p: *Parser, keyword: Token) Error {
        return p.spaceError(keyword.span.end, "AND, OR or NOT where a term should begin, with no space after it");
    }

    /// The space at byte `at`, where the grammar wants none. Production
    /// was shown a space there, and nothing else.
    fn spaceError(p: *Parser, at: usize, comptime otherwise: []const u8) Error {
        if (at >= p.text.len or p.text[at] != ' ') return p.notModelled(otherwise, .{}, at);
        return p.positioned("failed to parse (syntax error at line 1, column {d}, token ' ')", .{p.column(at)});
    }

    fn notModelled(p: *Parser, comptime what: []const u8, args: anytype, at: usize) Error {
        const said = try std.fmt.allocPrint(p.arena, what, args);
        p.message = try std.fmt.allocPrint(p.arena, "fake: this filter is not modelled: {s}, at column {d}", .{ said, p.column(at) });
        return error.NotModelled;
    }
};

// Tests.

const testing = std.testing;
const test_util = @import("test_util.zig");

const Attribute = struct { key: []const u8, value: []const u8 };

/// `n` of the letter x, for filters of a chosen length.
fn xs(comptime n: usize) [n]u8 {
    return @splat('x');
}

/// `n` times `é`, two bytes each.
fn accented(comptime n: usize) [2 * n]u8 {
    var out: [2 * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[2 * i ..][0..2], "é");
    return out;
}

/// The eight messages production was sent under every filter of the first
/// probe, and the six of the second.
const sent = [8][]const Attribute{
    &.{ .{ .key = "kind", .value = "order" }, .{ .key = "region", .value = "eu" } },
    &.{ .{ .key = "kind", .value = "order" }, .{ .key = "region", .value = "us" } },
    &.{ .{ .key = "kind", .value = "refund" }, .{ .key = "region", .value = "eu" } },
    &.{.{ .key = "region", .value = "us" }},
    &.{.{ .key = "kind", .value = "" }},
    &.{},
    &.{ .{ .key = "kind", .value = "ORDER" }, .{ .key = "KIND", .value = "order" } },
    &.{ .{ .key = "kind", .value = "a\"b" }, .{ .key = "a b", .value = "x" }, .{ .key = "a-b", .value = "x" }, .{ .key = "ké", .value = "é" } },
};
const sent_later = [6][]const Attribute{
    &.{.{ .key = "kind", .value = "order" }},
    &.{.{ .key = "kind", .value = "a\nb" }},
    &.{.{ .key = "kind", .value = "a\\b" }},
    &.{.{ .key = "kind", .value = "a\tb" }},
    &.{.{ .key = "other", .value = "x" }},
    &.{.{ .key = "kind", .value = "a\\nb" }},
};

/// Tries `text` on each of `messages`, and expects it to pass the ones
/// `delivered` names by their number.
fn expectDelivered(text: []const u8, messages: []const []const Attribute, delivered: []const u8) !void {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const filter = switch (try parse(scratch.allocator(), text)) {
        .ok => |f| f,
        .refused, .not_modelled => |why| {
            std.debug.print("{s}: {s}\n", .{ text, why });
            return error.TestUnexpectedResult;
        },
    };
    var got: [8]u8 = undefined;
    var n: usize = 0;
    for (messages, "12345678"[0..messages.len]) |attributes, name| {
        if (!filter.matches(attributes)) continue;
        got[n] = name;
        n += 1;
    }
    testing.expectEqualStrings(delivered, got[0..n]) catch |err| {
        std.debug.print("filter: {s}\n", .{text});
        return err;
    };
}

test "filters production took: each delivers the messages production delivered" {
    // The filter, and which of m1 to m8 production delivered under it.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "attributes.kind = \"order\"", "12" },
        .{ "attributes.kind != \"order\"", "345678" },
        .{ "attributes:kind", "123578" },
        .{ "NOT attributes:kind", "46" },
        .{ "-attributes:kind", "46" },
        .{ "hasPrefix(attributes.kind, \"or\")", "12" },
        .{ "NOT hasPrefix(attributes.kind, \"or\")", "345678" },
        .{ "attributes.kind = \"order\" AND attributes.region = \"eu\"", "1" },
        .{ "attributes.kind = \"order\" OR attributes.kind = \"refund\"", "123" },
        .{ "attributes.kind = \"order\" AND (attributes.region = \"eu\" OR attributes.region = \"us\")", "12" },
        .{ "(attributes.kind = \"order\")", "12" },
        .{ "NOT (attributes.kind = \"order\")", "345678" },
        .{ "attributes.kind=\"order\"", "12" },
        .{ "attributes.kind = \"\"", "5" },
        .{ "attributes.\"a b\" = \"x\"", "8" },
        .{ "attributes.a-b = \"x\"", "8" },
        .{ "attributes.kind = \"a\\\"b\"", "8" },
        .{ "attributes.KIND = \"order\"", "7" },
        .{ "   attributes.kind   =   \"order\"   ", "12" },
        .{ "attributes.kind = \"" ++ comptime xs(233) ++ "\"", "" },
        .{ "attributes.kind = \"" ++ comptime xs(234) ++ "\"", "" },
        .{ "attributes.ké = \"é\"", "8" },
    };
    for (cases) |case| try expectDelivered(case[0], &sent, case[1]);
    // The longest production took was 254 bytes; its limit is 256.
    try testing.expectEqual(254, cases[20][0].len);

    // The second probe's, of its own six messages: parentheses in
    // parentheses, a quoted key after the colon, spaces about the colon,
    // the escapes of a literal, and a tab and a line break for a space.
    const later = [_]struct { []const u8, []const u8 }{
        .{ "((attributes:kind))", "12346" },
        .{ "attributes:\"kind\"", "12346" },
        .{ "attributes : kind", "12346" },
        .{ "attributes.kind = \"a\\nb\"", "2" },
        .{ "attributes.kind = \"a\\\\b\"", "3" },
        .{ "attributes.kind = \"a\\tb\"", "4" },
        .{ "attributes.kind =\t\"order\"", "1" },
        .{ "attributes.kind = \"order\"\nAND attributes:kind", "1" },
    };
    for (later) |case| try expectDelivered(case[0], &sent_later, case[1]);
}

/// Expects production's refusal: `words`, after what begins every one.
fn expectRefusal(text: []const u8, words: []const u8) !void {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    switch (try parse(a, text)) {
        .refused => |why| testing.expectEqualStrings(try std.fmt.allocPrint(a, "Invalid filter expression: {s}", .{words}), why) catch |err| {
            std.debug.print("filter: {s}\n", .{text});
            return err;
        },
        .ok => {
            std.debug.print("taken: {s}\n", .{text});
            return error.TestUnexpectedResult;
        },
        .not_modelled => |why| {
            std.debug.print("{s}: {s}\n", .{ text, why });
            return error.TestUnexpectedResult;
        },
    }
}

test "filters production refused: each in its words, at its columns" {
    // Word for word as production answered on 2026-10-12: sixty-four
    // filters, after "Invalid filter expression: ".
    const implicit = "Implicit conjunctions are not permitted. Please use the AND operator explicitly.";
    const no_operator = "Expected either a function call or an expression with an operator";
    const left_side = "Invalid left-hand side operand, should be an attribute lookup";
    const right_side = "Invalid right-hand side operand, expected string literal";
    const measured = [_]struct { []const u8, []const u8 }{
        // AND and OR.
        .{ "attributes.kind = \"order\" AND attributes.region = \"eu\" OR attributes.region = \"us\"", "failed to parse (syntax error at line 1, column 56, token 'OR')." },
        .{ "attributes:a OR attributes:b AND attributes:c", "failed to parse (syntax error at line 1, column 30, token 'AND')." },
        .{ "attributes.kind = \"order\" AND", "failed to parse (syntax error at line 1, column 27, token 'AND')." },
        .{ "attributes:a OR", "failed to parse (syntax error at line 1, column 14, token 'OR')." },
        .{ "attributes.kind=\"order\"AND attributes:kind", "failed to parse (syntax error at line 1, column 24, token 'AND')." },
        .{ "AND attributes:a", "failed to parse (syntax error at line 1, column 4, token ' ')." },
        .{ "attributes:a AND AND attributes:b", "failed to parse (syntax error at line 1, column 21, token ' ')." },
        // Terms side by side.
        .{ "attributes.kind = \"order\" attributes.region = \"eu\"", implicit ++ " (line 1, columns 1 to 50)." },
        .{ "attributes.kind = \"order\" and attributes.region = \"eu\"", implicit ++ " (line 1, columns 1 to 54)." },
        .{ "(attributes:a) (attributes:b)", implicit ++ " (line 1, columns 1 to 29)." },
        .{ "NOT attributes:a attributes:b", implicit ++ " (line 1, columns 1 to 29)." },
        .{ "attributes.kind ! \"a\"", implicit ++ " (line 1, columns 1 to 21)." },
        // A term with no operator.
        .{ "attributes.kind", no_operator ++ " (line 1, columns 1 to 15)." },
        .{ "order", no_operator ++ " (line 1, columns 1 to 5)." },
        .{ "\"order\"", no_operator ++ " (line 1, columns 1 to 7)." },
        .{ "attributes:a AND order", no_operator ++ " (line 1, columns 18 to 22)." },
        // Operators.
        .{ "attributes.kind > \"a\"", "Invalid operator (line 1, columns 1 to 21)." },
        .{ "attributes.k >= \"a\"", "Invalid operator (line 1, columns 1 to 19)." },
        .{ "attributes.k < \"a\"", "Invalid operator (line 1, columns 1 to 18)." },
        .{ "attributes.k <= \"a\"", "Invalid operator (line 1, columns 1 to 19)." },
        .{ "attributes.kind == \"a\"", "failed to parse (syntax error at line 1, column 18, token '=')." },
        .{ "= \"a\"", "failed to parse (syntax error at line 1, column 1, token '=')." },
        .{ "attributes.kind =", "failed to parse (syntax error at line 1, token '<EOF>')." },
        // The left of an operator.
        .{ "data = \"x\"", left_side ++ " (line 1, columns 1 to 4)." },
        .{ "kind = \"order\"", left_side ++ " (line 1, columns 1 to 4)." },
        .{ "attributes = \"a\"", left_side ++ " (line 1, columns 1 to 10)." },
        .{ "\"kind\" = \"a\"", left_side ++ " (line 1, columns 1 to 6)." },
        .{ "message.kind = \"a\"", "Undefined object 'message'. Did you mean attributes? (line 1, columns 1 to 7)." },
        .{ "attributes.a_b.c = \"x\"", "Attempted to access member of a string value (line 1, columns 16 to 16)." },
        .{ "attributes.a.\"b c\" = \"x\"", "Attempted to access member of a string value (line 1, columns 14 to 18)." },
        .{ "attributes. = \"a\"", "failed to parse (syntax error at line 1, column 12, token ' ')." },
        // The right of one.
        .{ "attributes.kind = 'order'", right_side ++ " (line 1, columns 19 to 25)." },
        .{ "attributes.kind = order", right_side ++ " (line 1, columns 19 to 23)." },
        .{ "attributes.k != attributes.j", right_side ++ " (line 1, columns 17 to 28)." },
        .{ "attributes.kind = \"a", "failed to parse (syntax error at line 1, column 19, token '\"')." },
        // Columns count characters: this `é` is one.
        .{ "attributes.ké = é", right_side ++ " (line 1, columns 17 to 17)." },
        // More than one thing wrong: the operator, then the left side.
        .{ "data > order", "Invalid operator (line 1, columns 1 to 12)." },
        .{ "data = order", left_side ++ " (line 1, columns 1 to 4)." },
        .{ "attributes.kind > order", "Invalid operator (line 1, columns 1 to 23)." },
        .{ "attributes.kind = \"x\" AND attributes.kind > \"a\" AND data = \"x\"", "Invalid operator (line 1, columns 27 to 47)." },
        // The colon.
        .{ "attributes.kind : \"ord\"", "Invalid identifier. Did you mean attributes? (line 1, columns 1 to 15)." },
        .{ "\"attributes\":kind", "Invalid identifier. Did you mean attributes? (line 1, columns 1 to 12)." },
        .{ "kind:x", "Undefined object 'kind'. Did you mean attributes? (line 1, columns 1 to 4)." },
        .{ "attributes:a.b", "Invalid attribute key (line 1, columns 12 to 14)." },
        // Functions.
        .{ "hasPrefix(attributes.kind)", "hasPrefix function expects 2 arguments, but was called with 1 arg (line 1, columns 1 to 26)." },
        .{ "hasPrefix()", "hasPrefix function expects 2 arguments, but was called with 0 args (line 1, columns 1 to 11)." },
        .{ "hasPrefix(attributes.k, \"a\", \"b\")", "hasPrefix function expects 2 arguments, but was called with 3 args (line 1, columns 1 to 33)." },
        .{ "hasPrefix(kind, \"a\")", "Invalid 1st argument passed to hasPrefix function, should be an attribute lookup (line 1, columns 11 to 14)." },
        .{ "hasPrefix(\"kind\", \"a\")", "Invalid 1st argument passed to hasPrefix function, should be an attribute lookup (line 1, columns 11 to 16)." },
        .{ "hasPrefix(attributes.kind, a)", "Invalid 2nd argument passed to hasPrefix function, expected string literal (line 1, columns 28 to 28)." },
        .{ "hasSuffix(attributes.kind, \"er\")", "Undefined function 'hasSuffix'. Did you mean hasPrefix? (line 1, columns 1 to 9)." },
        .{ "foo(attributes.k, \"a\")", "Undefined function 'foo'. Did you mean hasPrefix? (line 1, columns 1 to 3)." },
        .{ "hasprefix(attributes.kind, \"or\")", "Undefined function 'hasprefix'. Did you mean hasPrefix? (line 1, columns 1 to 9)." },
        // A name apart from its parenthesis is a term alone, and the
        // comma is then where no comma goes.
        .{ "hasPrefix (attributes.kind, \"or\")", "failed to parse (syntax error at line 1, column 27, token ',')." },
        // Parentheses.
        .{ "(attributes:a", "failed to parse (missing token at line 1, column 1, token '(')." },
        .{ "attributes:a)", "failed to parse (syntax error at line 1, column 13, token ')')." },
        .{ "()", "failed to parse (syntax error at line 1, column 2, token ')')." },
        // Negation.
        .{ "NOT", "failed to parse (syntax error at line 1, column 1, token 'NOT')." },
        .{ "NOT NOT attributes:kind", "failed to parse (syntax error at line 1, column 8, token ' ')." },
        .{ "- attributes:kind", "failed to parse (syntax error at line 1, column 2, token ' ')." },
        // Nothing, and too much: the limit counts bytes.
        .{ "   ", "contains only whitespace characters." },
        .{ "attributes.k = \"" ++ comptime xs(240) ++ "\"", "length 257 exceeds maximum allowed length of 256." },
        .{ "attributes.k = \"" ++ comptime accented(120) ++ "\"", "length 257 exceeds maximum allowed length of 256." },
        .{ "attributes.k = \"" ++ comptime accented(121) ++ "\"", "length 259 exceeds maximum allowed length of 256." },
    };
    try testing.expectEqual(64, measured.len);
    for (measured) |case| try expectRefusal(case[0], case[1]);

    // The same sentences elsewhere, where the rule those show puts them.
    const by_the_rule = [_]struct { []const u8, []const u8 }{
        .{ "(attributes:a AND attributes:b) OR (attributes:c attributes:d)", implicit ++ " (line 1, columns 37 to 61)." },
        .{ " NOT attributes:a -attributes:b", implicit ++ " (line 1, columns 2 to 31)." },
        .{ "attributes:a AND (attributes.k > \"a\")", "Invalid operator (line 1, columns 19 to 36)." },
        .{ "  attributes.k != attributes.j", right_side ++ " (line 1, columns 19 to 30)." },
        .{ "NOT kind:x", "Undefined object 'kind'. Did you mean attributes? (line 1, columns 5 to 8)." },
        .{ "attributes:a AND startsWith(attributes.k, \"a\")", "Undefined function 'startsWith'. Did you mean hasPrefix? (line 1, columns 18 to 27)." },
        .{ "attributes:a AND OR attributes:b", "failed to parse (syntax error at line 1, column 20, token ' ')." },
        .{ "attributes:a OR NOT NOT attributes:b", "failed to parse (syntax error at line 1, column 24, token ' ')." },
        .{ "attributes:a AND attributes.k =  ", "failed to parse (syntax error at line 1, token '<EOF>')." },
        .{ "attributes:a AND attributes.", "failed to parse (syntax error at line 1, token '<EOF>')." },
        .{ "attributes.= \"a\"", "failed to parse (syntax error at line 1, column 12, token '=')." },
        .{ "attributes:a, attributes:b", "failed to parse (syntax error at line 1, column 13, token ',')." },
        .{ "(attributes:a = \"b\")", "failed to parse (syntax error at line 1, column 15, token '=')." },
        .{ "hasPrefix(attributes.k \"a\")", "failed to parse (syntax error at line 1, column 24, token '\"a\"')." },
        .{ "hasPrefix(attributes, \"a\")", "Invalid 1st argument passed to hasPrefix function, should be an attribute lookup (line 1, columns 11 to 20)." },
        .{ "hasPrefix(attributes.k, attributes.j)", "Invalid 2nd argument passed to hasPrefix function, expected string literal (line 1, columns 25 to 36)." },
        .{ "é:x", "Undefined object 'é'. Did you mean attributes? (line 1, columns 1 to 1)." },
        .{ "attributes.é = \"" ++ comptime accented(3) ++ "\" extra", implicit ++ " (line 1, columns 1 to 26)." },
    };
    for (by_the_rule) |case| try expectRefusal(case[0], case[1]);
}

test "filters production was not shown, or failed on: said so, never taken and never refused in its name" {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        // Production's answer to this one was a 500, an internal error.
        .{ "--attributes:kind", "a minus after a minus, which production answers with an internal error, at column 2" },
        .{ "attributes:a AND -", "a minus with nothing after it, at column 18" },
        .{ "-\tattributes:a", "a minus before white space other than a space, at column 2" },
        .{ "-NOT attributes:a", "NOT after a minus, at column 2" },
        .{ "NOT -attributes:a", "a minus after NOT, at column 5" },
        .{ "NOT(attributes:a)", "NOT hard against what comes after it, at column 1" },
        .{ "attributes:a AND AND", "AND, OR or NOT where a term should begin, with no space after it, at column 21" },
        .{ "OR\tattributes:a", "AND, OR or NOT where a term should begin, with no space after it, at column 3" },
        .{ "attributes:a AND (", "nothing where a term should begin, at column 19" },
        .{ "attributes .kind = \"a\"", "white space before a '.', at column 12" },
        .{ "attributes.\tkind = \"a\"", "a '.' before white space other than a space, at column 12" },
        .{ "attributes.kind = \"a\\rb\"", "an escape in a literal other than \\\", \\\\, \\n and \\t, at column 21" },
        .{ "attributes.kind = \"a\"; attributes:b", "the byte 0x3b outside a literal, at column 22" },
        .{ "attributes.kind\r= \"a\"", "the byte 0x0d outside a literal, at column 16" },
        .{ "hasPrefix(attributes.kind, \"a\"", "a function's arguments that are not closed, at column 10" },
        .{ "attributes.kind(\"a\")", "a parenthesis hard against what is no function's name, at column 16" },
        .{ "message.kind:x", "a key under a name other than attributes before ':', at column 1" },
        .{ "hasPrefix(message.kind, \"a\")", "hasPrefix of a path that is no attribute, at column 11" },
        .{ "hasPrefix(attributes.a.b, \"a\")", "hasPrefix of a path that is no attribute, at column 11" },
        // A refusal on a second line: how production counts there was
        // not seen.
        .{ "attributes.kind = \"order\"\nAND order", "a refusal in a filter of more than one line, at column 26" },
    };
    for (cases) |case| {
        const text, const why = case;
        switch (try parse(a, text)) {
            .not_modelled => |said| testing.expectEqualStrings(try std.fmt.allocPrint(a, "fake: this filter is not modelled: {s}", .{why}), said) catch |err| {
                std.debug.print("filter: {s}\n", .{text});
                return err;
            },
            .ok => {
                std.debug.print("taken: {s}\n", .{text});
                return error.TestUnexpectedResult;
            },
            .refused => |said| {
                std.debug.print("{s}: {s}\n", .{ text, said });
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "a filter: what it reads of escapes, quoted keys and nesting, and that it keeps nothing of the text" {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const text = try a.dupe(u8, "NOT (attributes.\"a \\\\ \\\" b\" != \"c\\\\\\n\\t\" OR -hasPrefix(attributes.d-e, \"\")) AND attributes:\"f g\" AND attributes:h");
    const filter = (try parse(a, text)).ok;
    // The text may go: the filter has its own copies.
    @memset(text, 'x');
    try testing.expectEqual(3, filter.all.len);
    const either = filter.all[0].not.any;
    try testing.expectEqualStrings("a \\ \" b", either[0].differs.key);
    try testing.expectEqualStrings("c\\\n\t", either[0].differs.value);
    try testing.expectEqualStrings("d-e", either[1].not.prefix.key);
    try testing.expectEqualStrings("", either[1].not.prefix.value);
    try testing.expectEqualStrings("f g", filter.all[1].has);
    try testing.expectEqualStrings("h", filter.all[2].has);

    // NOT (differs OR NOT prefix) AND has AND has.
    const pass = [_]Attribute{ .{ .key = "a \\ \" b", .value = "c\\\n\t" }, .{ .key = "d-e", .value = "" }, .{ .key = "f g", .value = "" }, .{ .key = "h", .value = "1" } };
    try testing.expect(filter.matches(&pass));
    // Each of the four attributes carries it: without any one, it fails.
    for (0..pass.len) |without| {
        var rest: [3]Attribute = undefined;
        var n: usize = 0;
        for (pass, 0..) |attribute, i| {
            if (i == without) continue;
            rest[n] = attribute;
            n += 1;
        }
        try testing.expect(!filter.matches(&rest));
    }
    // An empty prefix is begun by any value, and by no missing one.
    const begun = (try parse(a, "hasPrefix(attributes.k, \"\")")).ok;
    try testing.expect(begun.matches(&[_]Attribute{.{ .key = "k", .value = "v" }}));
    try testing.expect(!begun.matches(&[_]Attribute{}));
    // 256 bytes are taken, as the limit says.
    try testing.expect((try parse(a, "attributes.k = \"" ++ comptime xs(239) ++ "\"")) == .ok);
    // An exclamation mark is an operator only before `=`.
    try testing.expect((try parse(a, "attributes.k!=\"v\"")).ok.matches(&[_]Attribute{}));
}

/// Any text is taken, refused or said not to be modelled: never a crash.
/// What is taken can be tried on any attributes.
fn anyText(_: void, input: []const u8) !void {
    // The fuzzer runs this a million times a night, so its memory is on
    // the stack: reading a filter needs little. Leaks are the allocation
    // sweep's to find, below.
    var memory: [128 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const a = fixed.allocator();
    var g: test_util.ByteGen = .init(input);
    // Half the time from the pieces filters are made of, so that the text
    // is often nearly one.
    const pieces = [_][]const u8{ "attributes", ".", "kind", " ", "=", "!=", "\"", "a", "AND", "OR", "NOT", "(", ")", "hasPrefix", ",", ":", "-", "\\", ">", "é", "and", "\t", "\n", "!", "<=", "'", ";", "n" };
    var buf: [300]u8 = undefined;
    var n: usize = 0;
    if (g.boolean()) {
        while (g.pos < g.bytes.len) {
            const piece = pieces[g.intRange(u8, 0, pieces.len - 1)];
            if (n + piece.len > buf.len) break;
            @memcpy(buf[n..][0..piece.len], piece);
            n += piece.len;
        }
    } else {
        const raw = g.rest();
        n = @min(raw.len, buf.len);
        @memcpy(buf[0..n], raw[0..n]);
    }
    if (n == 0) return;
    const text = buf[0..n];
    switch (try parse(a, text)) {
        .ok => |filter| {
            try testing.expect(text.len <= max_len);
            _ = filter.matches(sent[7]);
            _ = filter.matches(sent[5]);
        },
        .refused => |why| {
            try testing.expect(std.mem.startsWith(u8, why, "Invalid filter expression: "));
            try testing.expect(std.mem.endsWith(u8, why, "."));
            // One that says where says so on the one line it was seen on.
            if (std.mem.indexOf(u8, why, "line 1") != null) try testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
        },
        .not_modelled => |why| {
            try testing.expect(text.len <= max_len);
            try testing.expect(std.mem.startsWith(u8, why, "fake: this filter is not modelled: "));
        },
    }
}

test "fuzz fake filter: any text is taken, refused or said not to be modelled, never crashed on" {
    try test_util.fuzzBytes({}, anyText, .{ .corpus = &.{
        "",
        "\x01\x00\x01\x02\x03\x04\x03\x06\x07\x06",
        "\x01\x0a\x03\x0b\x00\x0f\x02\x08\x0d\x00\x01\x02\x05\x06\x07\x06\x0c",
        "\x01\x00\x01\x02\x03\x04\x03\x06\x11\x1b\x06\x16\x08\x03\x00\x0f\x02",
        "\x00attributes.kind = \"order\" AND",
        "\x00hasPrefix(attributes.k, \"\\",
        "\x00NOT NOT -- (attributes. :",
    }, .random_runs = 3000 });
}

/// A filter made up whole, with the answer it should give worked out
/// beside it as it is made.
const Made = struct {
    g: *test_util.ByteGen,
    out: *std.Io.Writer,
    attributes: []const Attribute,

    const keys = [_][]const u8{ "kind", "region", "a-b", "a b", "ké", "none" };
    const values = [_][]const u8{ "order", "or", "", "eu", "a\"b", "x\\y", "l\nm\tn" };

    /// None, or one or two of a space, a tab and a line break.
    fn spaces(m: *Made) !void {
        for (0..m.g.intRange(u8, 0, 2)) |_| try m.out.writeByte(" \t \n"[m.g.intRange(u8, 0, 3)]);
    }

    fn key(m: *Made, text: []const u8) !void {
        const plain = for (text) |c| {
            if (c == ' ') break false;
        } else true;
        if (plain and m.g.boolean()) return m.out.writeAll(text);
        try m.literal(text);
    }

    fn literal(m: *Made, text: []const u8) !void {
        try m.out.writeByte('"');
        for (text) |c| switch (c) {
            '"', '\\' => try m.out.writeAll(&.{ '\\', c }),
            '\n' => try m.out.writeAll("\\n"),
            '\t' => try m.out.writeAll("\\t"),
            else => try m.out.writeByte(c),
        };
        try m.out.writeByte('"');
    }

    /// Writes one term, and answers whether the attributes pass it. Past
    /// a length the terms are plain ones, to stay near production's limit.
    /// A negation is not negated again: production takes no two together.
    fn term(m: *Made, levels: u8, negated: bool) !bool {
        const depth = if (m.out.buffered().len > 150) 0 else levels;
        const k = keys[m.g.intRange(u8, 0, keys.len - 1)];
        const v = values[m.g.intRange(u8, 0, values.len - 1)];
        const held = lookup(m.attributes, k);
        const drawn = m.g.intRange(u8, 0, if (depth == 0) 3 else 7);
        switch (if (negated and drawn == 4) 5 else drawn) {
            0 => {
                try m.out.writeAll("attributes.");
                try m.key(k);
                try m.spaces();
                try m.out.writeAll("=");
                try m.spaces();
                try m.literal(v);
                return if (held) |h| std.mem.eql(u8, h, v) else false;
            },
            1 => {
                try m.out.writeAll("attributes.");
                try m.key(k);
                try m.spaces();
                try m.out.writeAll("!=");
                try m.spaces();
                try m.literal(v);
                return if (held) |h| !std.mem.eql(u8, h, v) else true;
            },
            2 => {
                try m.out.writeAll("attributes");
                try m.spaces();
                try m.out.writeAll(":");
                try m.spaces();
                try m.key(k);
                return held != null;
            },
            3 => {
                try m.out.writeAll("hasPrefix(");
                try m.spaces();
                try m.out.writeAll("attributes.");
                try m.key(k);
                try m.spaces();
                try m.out.writeAll(",");
                try m.spaces();
                try m.literal(v);
                try m.spaces();
                try m.out.writeAll(")");
                return if (held) |h| std.mem.startsWith(u8, h, v) else false;
            },
            4 => {
                try m.out.writeAll(if (m.g.boolean()) "NOT " else "-");
                return !try m.term(depth - 1, true);
            },
            5 => {
                try m.out.writeAll("(");
                try m.spaces();
                const inner = try m.term(depth - 1, false);
                try m.spaces();
                try m.out.writeAll(")");
                return inner;
            },
            else => |which| {
                // Two or three, joined by one operator, in parentheses.
                const conjunction = which == 6;
                var result = conjunction;
                try m.out.writeAll("(");
                for (0..m.g.intRange(u8, 2, 3)) |i| {
                    if (i > 0) try m.out.writeAll(if (conjunction) " AND " else " OR ");
                    const one = try m.term(depth - 1, false);
                    result = if (conjunction) result and one else result or one;
                }
                try m.out.writeAll(")");
                return result;
            },
        }
    }
};

fn madeFilter(_: void, input: []const u8) !void {
    var memory: [128 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const a = fixed.allocator();
    var g: test_util.ByteGen = .init(input);
    // Some of the keys, each with one of the values.
    var attributes: [Made.keys.len]Attribute = undefined;
    var count: usize = 0;
    for (Made.keys[0 .. Made.keys.len - 1]) |key| {
        if (!g.boolean()) continue;
        attributes[count] = .{ .key = key, .value = Made.values[g.intRange(u8, 0, Made.values.len - 1)] };
        count += 1;
    }
    var buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var made: Made = .{ .g = &g, .out = &out, .attributes = attributes[0..count] };
    try made.spaces();
    // At the top two or three may be joined with no parentheses.
    const joined = g.intRange(u8, 1, 3);
    const conjunction = g.boolean();
    var expected = conjunction;
    for (0..joined) |i| {
        if (i > 0) try out.writeAll(if (conjunction) " AND " else " OR ");
        const one = try made.term(2, false);
        expected = if (joined == 1) one else if (conjunction) expected and one else expected or one;
    }
    try made.spaces();
    const text = out.buffered();
    if (text.len > max_len) return;
    switch (try parse(a, text)) {
        .ok => |filter| testing.expectEqual(expected, filter.matches(attributes[0..count])) catch |err| {
            std.debug.print("filter: {s}\n", .{text});
            return err;
        },
        .refused, .not_modelled => |why| {
            std.debug.print("{s}: {s}\n", .{ text, why });
            return error.TestUnexpectedResult;
        },
    }
}

test "fuzz fake filter: a filter made of what production took is taken, and passes exactly the messages it should" {
    try test_util.fuzzBytes({}, madeFilter, .{ .corpus = &.{
        "",
        "\xff\x00\xff\x01\xff\x02\x02\x01\x00\x00\x00\x01\x00\x01\x02\x01\x03\x02\x00\x04",
        "\x01\x00\x01\x00\x00\x00\x00\x01\x00\x06\x04\x01\x05\x00\x00\x07\x01\x02\x03\x01\x02\x03",
        "\x01\x06\x01\x06\x02\x03\x03\x01\x04\x00\x06\x01\x04\x01\x02\x06\x00\x01\x01\x03\x00\x06\x02\x01\x02",
    }, .random_runs = 3000 });
}

/// Memory failing anywhere while a filter is read fails the read, and
/// nothing leaks.
fn parseAllocations(gpa: Allocator) !void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    try testing.expect((try parse(a, "NOT (attributes.\"a b\" != \"c\\n\" OR -hasPrefix(attributes.d, \"e\\\"\")) AND attributes:f")) == .ok);
    try testing.expect((try parse(a, "attributes.kind = \"order\" and attributes:f")) == .refused);
    try testing.expect((try parse(a, "attributes.kind = \"order\" AND")) == .refused);
    try testing.expect((try parse(a, "message.kind = \"order\"")) == .refused);
    try testing.expect((try parse(a, "attributes.kind = \"order")) == .refused);
    try testing.expect((try parse(a, "--attributes:kind")) == .not_modelled);
    try testing.expect((try parse(a, &comptime xs(257))) == .refused);
}

test "allocation failures: reading a filter leaks nothing" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, parseAllocations, .{});
}
