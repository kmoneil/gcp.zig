//! A query's rows, decoded against its schema, and written back.
//!
//! Every scalar arrives as a JSON string (`{"v":"1"}`), an array as a
//! list of cells, a record as `{"f":[...]}` in its schema's order, and
//! NULL as `null` (measured). A `Cell` keeps the wire text beside its
//! value, so a table can show production's own form. A value that does
//! not fit its column's type is `error.InvalidResponse`; a type this
//! library does not know decodes as `.string`, its text kept, so a new
//! type does not break a results table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ OutOfMemory, InvalidResponse };

/// A NUMERIC or BIGNUMERIC, exact: the decimal text as answered
/// (production drops trailing zeros: `1.5`, measured). BIGNUMERIC holds
/// 76 digits, more than any float.
pub const Decimal = struct {
    text: []const u8,

    /// The nearest `f64`, for a chart; not exact.
    pub fn toF64(self: Decimal) f64 {
        return std.fmt.parseFloat(f64, self.text) catch std.math.nan(f64);
    }
};

/// A DATE: 0001-01-01 to 9999-12-31.
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

/// A TIME: 00:00:00 to 23:59:59.999999.
pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32 = 0,
};

/// A DATETIME: a date and a time of day, in no time zone.
pub const DateTime = struct {
    date: Date,
    time: Time,
};

/// An INTERVAL, in the three parts BigQuery holds it in, each signed on
/// its own: `1-2 3 4:5:6` is 14 months, 3 days and 4 h 5 min 6 s.
pub const Interval = struct {
    months: i32 = 0,
    days: i32 = 0,
    microseconds: i64 = 0,
};

/// One end of a RANGE, of the range's element type.
pub const RangeBound = union(enum) {
    date: Date,
    datetime: DateTime,
    timestamp: std.Io.Timestamp,
};

/// A RANGE: `[start, end)`, each end null when unbounded.
pub const Range = struct {
    start: ?RangeBound,
    end: ?RangeBound,
};

pub const Value = union(enum) {
    null,
    int64: i64,
    /// NaN and the infinities too.
    float64: f64,
    numeric: Decimal,
    bignumeric: Decimal,
    boolean: bool,
    string: []const u8,
    /// Decoded from base64.
    bytes: []const u8,
    date: Date,
    time: Time,
    datetime: DateTime,
    /// To the microsecond.
    timestamp: std.Io.Timestamp,
    /// Well-known text, as answered: `POINT(-122.35 47.62)`.
    geography: []const u8,
    /// The JSON text, as answered: compact, keys sorted (measured).
    json: []const u8,
    interval: Interval,
    range: Range,
    /// A REPEATED column's elements, each of the column's type.
    array: []const Cell,
    /// A RECORD's fields, in its schema's order.
    record: []const Cell,

    /// Writes the value as BigQuery's console shows it: a timestamp as
    /// `2026-10-21 13:14:15.123456 UTC`, NULL as `NULL`, an array as
    /// `[1, 2]`, a record as `{1, "y"}`; every other scalar in its wire
    /// form, bytes in base64.
    pub fn format(self: Value, w: *Writer) Writer.Error!void {
        switch (self) {
            .null => try w.writeAll("NULL"),
            .timestamp => |ts| try writeTimestampUtc(w, ts),
            .array => |cells| {
                try w.writeByte('[');
                for (cells, 0..) |cell, i| {
                    if (i > 0) try w.writeAll(", ");
                    try cell.value.format(w);
                }
                try w.writeByte(']');
            },
            .record => |cells| {
                try w.writeByte('{');
                for (cells, 0..) |cell, i| {
                    if (i > 0) try w.writeAll(", ");
                    try cell.value.format(w);
                }
                try w.writeByte('}');
            },
            else => try writeText(w, self),
        }
    }
};

pub const Cell = struct {
    value: Value,
    /// A scalar's wire text, as answered; "" for NULL, an array or a
    /// record.
    text: []const u8 = "",
};

pub const Row = struct {
    cells: []const Cell,
};

/// Rows as a query page or a table read carries them,
/// `[{"f":[{"v":...}, ...]}, ...]`, against `schema`.
pub fn decodeRows(out: Allocator, schema: []const types.Field, rows: std.json.Array) DecodeError![]const Row {
    const result = try out.alloc(Row, rows.items.len);
    for (rows.items, result) |item, *row| row.* = .{ .cells = try recordCells(out, schema, item) };
    return result;
}

/// `{"f":[...]}`: one cell per field, in order.
fn recordCells(out: Allocator, fields: []const types.Field, v: std.json.Value) DecodeError![]const Cell {
    if (v != .object) return error.InvalidResponse;
    const list = v.object.get("f") orelse return error.InvalidResponse;
    if (list != .array or list.array.items.len != fields.len) return error.InvalidResponse;
    const cells = try out.alloc(Cell, fields.len);
    for (fields, list.array.items, cells) |f, item, *c| c.* = try cellOf(out, f, item, f.mode == .repeated);
    return cells;
}

/// `{"v": ...}`.
fn cellOf(out: Allocator, field: types.Field, item: std.json.Value, repeated: bool) DecodeError!Cell {
    if (item != .object) return error.InvalidResponse;
    const v = item.object.get("v") orelse return error.InvalidResponse;
    if (v == .null) return .{ .value = .null };
    if (repeated) {
        if (v != .array) return error.InvalidResponse;
        const cells = try out.alloc(Cell, v.array.items.len);
        for (v.array.items, cells) |element, *c| c.* = try cellOf(out, field, element, false);
        return .{ .value = .{ .array = cells } };
    }
    if (field.type == .record) return .{ .value = .{ .record = try recordCells(out, field.fields, v) } };
    if (v != .string) return error.InvalidResponse;
    const text = try out.dupe(u8, v.string);
    return .{ .value = try scalar(out, field, text), .text = text };
}

/// A scalar of `field`'s type from its wire text, which `out` owns.
pub fn scalar(out: Allocator, field: types.Field, text: []const u8) DecodeError!Value {
    return switch (field.type) {
        .int64 => .{ .int64 = std.fmt.parseInt(i64, text, 10) catch return error.InvalidResponse },
        .float64 => .{ .float64 = try float(text) },
        .numeric => .{ .numeric = try decimal(text) },
        .bignumeric => .{ .bignumeric = try decimal(text) },
        .boolean => .{ .boolean = if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else return error.InvalidResponse },
        .string => .{ .string = text },
        .bytes => .{ .bytes = try base64(out, text) },
        .date => .{ .date = try date(text) },
        .time => .{ .time = try time(text) },
        .datetime => .{ .datetime = try dateTime(text) },
        .timestamp => .{ .timestamp = try timestamp(text) },
        .geography => .{ .geography = text },
        .json => .{ .json = text },
        .interval => .{ .interval = try interval(text) },
        .range => .{ .range = try range(field.range_element orelse return error.InvalidResponse, text) },
        // A record is an object, never text.
        .record => error.InvalidResponse,
        .unknown => .{ .string = text },
    };
}

/// A FLOAT64: decimal, with an exponent or without, or `NaN`,
/// `Infinity`, `-Infinity` (measured).
fn float(text: []const u8) DecodeError!f64 {
    if (std.mem.eql(u8, text, "NaN")) return std.math.nan(f64);
    if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(f64);
    if (!isDecimal(text, true)) return error.InvalidResponse;
    return std.fmt.parseFloat(f64, text) catch error.InvalidResponse;
}

/// `-?digits(.digits)?`, and an exponent when `exponent` allows it.
fn isDecimal(text: []const u8, exponent: bool) bool {
    var i: usize = 0;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) i += 1;
    const whole = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    var digit_count = i - whole;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const frac = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        digit_count += i - frac;
    }
    if (digit_count == 0) return false;
    if (exponent and i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '-' or text[i] == '+')) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
    }
    return i == text.len;
}

fn decimal(text: []const u8) DecodeError!Decimal {
    if (!isDecimal(text, true)) return error.InvalidResponse;
    return .{ .text = text };
}

fn base64(out: Allocator, text: []const u8) DecodeError![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(text) catch return error.InvalidResponse;
    const bytes = try out.alloc(u8, len);
    decoder.decode(bytes, text) catch return error.InvalidResponse;
    return bytes;
}

/// Exactly `n` digits.
fn fixed(text: []const u8, n: usize) DecodeError!u32 {
    if (text.len != n) return error.InvalidResponse;
    var v: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidResponse;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// `YYYY-MM-DD`.
pub fn date(text: []const u8) DecodeError!Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidResponse;
    const year = try fixed(text[0..4], 4);
    const month = try fixed(text[5..7], 2);
    const day = try fixed(text[8..10], 2);
    if (year < 1 or month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return error.InvalidResponse;
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

/// `HH:MM:SS`, then `.` and 1 to 6 digits when the second has a
/// fraction (production writes 6, measured).
pub fn time(text: []const u8) DecodeError!Time {
    if (text.len < 8 or text[2] != ':' or text[5] != ':') return error.InvalidResponse;
    const hour = try fixed(text[0..2], 2);
    const minute = try fixed(text[3..5], 2);
    const second = try fixed(text[6..8], 2);
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidResponse;
    return .{
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .microsecond = try fraction(text[8..]),
    };
}

/// "" or `.` and 1 to 6 digits, as microseconds.
fn fraction(text: []const u8) DecodeError!u32 {
    if (text.len == 0) return 0;
    if (text[0] != '.' or text.len < 2 or text.len > 7) return error.InvalidResponse;
    var v: u32 = 0;
    for (text[1..]) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidResponse;
        v = v * 10 + (c - '0');
    }
    return v * std.math.pow(u32, 10, @intCast(7 - text.len));
}

/// A date, `T` (or a space), a time.
pub fn dateTime(text: []const u8) DecodeError!DateTime {
    if (text.len < 19 or (text[10] != 'T' and text[10] != ' ')) return error.InvalidResponse;
    return .{ .date = try date(text[0..10]), .time = try time(text[11..]) };
}

/// The smallest and largest TIMESTAMP, in microseconds since the epoch:
/// 0001-01-01 00:00:00 and 9999-12-31 23:59:59.999999 UTC.
pub const min_timestamp_us: i64 = -62_135_596_800_000_000;
pub const max_timestamp_us: i64 = 253_402_300_799_999_999;

/// A TIMESTAMP in any form production writes: microseconds since the
/// epoch (`formatOptions.useInt64Timestamp`, which this library asks),
/// seconds as a decimal (the default, `1.792588455123456E9`, and inside
/// a RANGE, `1704067200.000000`), or RFC 3339 in UTC
/// (`2026-10-21T13:14:15.123456Z`, the ISO option). The decimal is read
/// exactly, never through a float.
pub fn timestamp(text: []const u8) DecodeError!std.Io.Timestamp {
    if (text.len >= 20 and text[4] == '-') {
        const ts = core.timestamp.parse(text) catch return error.InvalidResponse;
        return checkedTimestamp(@divFloor(ts.nanoseconds, std.time.ns_per_us), @mod(ts.nanoseconds, std.time.ns_per_us));
    }
    if (std.fmt.parseInt(i64, text, 10)) |us| {
        return checkedTimestamp(us, 0);
    } else |_| {}
    return checkedTimestamp(try decimalSeconds(text), 0);
}

fn checkedTimestamp(us: i96, rest_ns: i96) DecodeError!std.Io.Timestamp {
    // Finer than a microsecond, BigQuery holds no such time.
    if (rest_ns != 0 or us < min_timestamp_us or us > max_timestamp_us) return error.InvalidResponse;
    return .{ .nanoseconds = us * std.time.ns_per_us };
}

/// Seconds as `-?digits(.digits)?(E-?digits)?`, to whole microseconds,
/// exactly; a finer fraction is refused.
fn decimalSeconds(text: []const u8) DecodeError!i64 {
    if (!isDecimal(text, true)) return error.InvalidResponse;
    var i: usize = 0;
    var negative = false;
    if (text[0] == '-' or text[0] == '+') {
        negative = text[0] == '-';
        i = 1;
    }
    // The digits as one integer, and the power of ten it is scaled by.
    var mantissa: i128 = 0;
    var power: i32 = 0;
    var seen_point = false;
    var significant: usize = 0;
    while (i < text.len and text[i] != 'e' and text[i] != 'E') : (i += 1) {
        if (text[i] == '.') {
            seen_point = true;
            continue;
        }
        if (seen_point) power -= 1;
        if (mantissa == 0 and text[i] == '0') continue;
        significant += 1;
        if (significant > 30) return error.InvalidResponse;
        mantissa = mantissa * 10 + (text[i] - '0');
    }
    if (i < text.len) {
        const exponent = std.fmt.parseInt(i32, text[i + 1 ..], 10) catch return error.InvalidResponse;
        if (exponent < -40 or exponent > 40) return error.InvalidResponse;
        power += exponent;
    }
    // Seconds to microseconds.
    power += 6;
    while (power > 0) : (power -= 1) {
        mantissa = std.math.mul(i128, mantissa, 10) catch return error.InvalidResponse;
        if (mantissa > max_timestamp_us + 1) return error.InvalidResponse;
    }
    while (power < 0) : (power += 1) {
        if (@rem(mantissa, 10) != 0) return error.InvalidResponse;
        mantissa = @divTrunc(mantissa, 10);
    }
    if (negative) mantissa = -mantissa;
    if (mantissa < min_timestamp_us or mantissa > max_timestamp_us) return error.InvalidResponse;
    return @intCast(mantissa);
}

/// `Y-M D H:M:S[.F]`, the year-month part, the days and the time each
/// signed on its own (`0-0 -3 0:0:0`, `-1-2 0 0:0:0`), as production
/// writes it (`1-0 2 3:0:0`, `0-0 0 0:0:0.250`, measured).
pub fn interval(text: []const u8) DecodeError!Interval {
    var parts = std.mem.splitScalar(u8, text, ' ');
    const ym = parts.next() orelse return error.InvalidResponse;
    const d = parts.next() orelse return error.InvalidResponse;
    const hms = parts.next() orelse return error.InvalidResponse;
    if (parts.next() != null) return error.InvalidResponse;

    const ym_negative, const ym_body = signed(ym);
    const dash = std.mem.indexOfScalar(u8, ym_body, '-') orelse return error.InvalidResponse;
    const years = try unsigned(ym_body[0..dash], 10_000);
    const month_part = try unsigned(ym_body[dash + 1 ..], 11);
    var months: i64 = years * 12 + month_part;
    if (ym_negative) months = -months;

    const d_negative, const d_body = signed(d);
    var days: i64 = try unsigned(d_body, 3_660_000);
    if (d_negative) days = -days;

    const t_negative, const t_body = signed(hms);
    var fields = std.mem.splitScalar(u8, t_body, ':');
    const h = try unsigned(fields.next() orelse return error.InvalidResponse, 87_840_000);
    const m = try unsigned(fields.next() orelse return error.InvalidResponse, 59);
    const s_text = fields.next() orelse return error.InvalidResponse;
    if (fields.next() != null) return error.InvalidResponse;
    const point = std.mem.indexOfScalar(u8, s_text, '.') orelse s_text.len;
    const s = try unsigned(s_text[0..point], 59);
    const us = try fraction(s_text[point..]);
    var micros: i64 = ((h * 60 + m) * 60 + s) * std.time.us_per_s + us;
    if (t_negative) micros = -micros;
    return .{ .months = @intCast(months), .days = @intCast(days), .microseconds = micros };
}

fn signed(text: []const u8) struct { bool, []const u8 } {
    if (text.len > 0 and text[0] == '-') return .{ true, text[1..] };
    return .{ false, text };
}

/// Digits, 1 to 9 of them, at most `max`.
fn unsigned(text: []const u8, max: i64) DecodeError!i64 {
    if (text.len == 0 or text.len > 9) return error.InvalidResponse;
    var v: i64 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidResponse;
        v = v * 10 + (c - '0');
    }
    if (v > max) return error.InvalidResponse;
    return v;
}

/// `[start, end)`, either end `UNBOUNDED` (measured).
pub fn range(element: types.FieldType, text: []const u8) DecodeError!Range {
    if (text.len < 2 or text[0] != '[' or text[text.len - 1] != ')') return error.InvalidResponse;
    const inner = text[1 .. text.len - 1];
    const comma = std.mem.indexOf(u8, inner, ", ") orelse return error.InvalidResponse;
    return .{
        .start = try bound(element, inner[0..comma]),
        .end = try bound(element, inner[comma + 2 ..]),
    };
}

fn bound(element: types.FieldType, text: []const u8) DecodeError!?RangeBound {
    if (std.mem.eql(u8, text, "UNBOUNDED")) return null;
    return switch (element) {
        .date => .{ .date = try date(text) },
        .datetime => .{ .datetime = try dateTime(text) },
        .timestamp => .{ .timestamp = try timestamp(text) },
        else => error.InvalidResponse,
    };
}

fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

// Writing values back: the fake answers with these, and the round-trip
// property holds the decode to them.

/// Writes `rows` as a query page carries them.
pub fn writeRows(w: *Writer, schema: []const types.Field, rows: []const Row) Writer.Error!void {
    try w.writeByte('[');
    for (rows, 0..) |row, i| {
        if (i > 0) try w.writeByte(',');
        try writeRecord(w, schema, row.cells);
    }
    try w.writeByte(']');
}

/// One row as a query page carries it, `{"f":[...]}`. The row must
/// `fit` the schema.
pub fn writeRow(w: *Writer, schema: []const types.Field, row: Row) Writer.Error!void {
    return writeRecord(w, schema, row.cells);
}

/// Whether `row` has a cell for each field of `schema`, each a value of
/// its field's type: an array of them for a REPEATED field, its fields'
/// for a RECORD, NULL only where the field is NULLABLE, never inside an
/// array (BigQuery has no NULL element), and a range's ends of its
/// element type. What a value holds is not checked here: a written row
/// that decodes is one production could have sent.
pub fn fits(schema: []const types.Field, row: Row) bool {
    return recordFits(schema, row.cells);
}

fn recordFits(fields: []const types.Field, cells: []const Cell) bool {
    if (fields.len != cells.len) return false;
    for (fields, cells) |f, cell| if (!valueFits(f, cell.value, false)) return false;
    return true;
}

fn valueFits(field: types.Field, value: Value, element: bool) bool {
    if (value == .null) return field.mode == .nullable and !element;
    if (field.mode == .repeated and !element) {
        if (value != .array) return false;
        for (value.array) |cell| if (!valueFits(field, cell.value, true)) return false;
        return true;
    }
    return switch (field.type) {
        .record => value == .record and recordFits(field.fields, value.record),
        .range => value == .range and boundFits(field.range_element, value.range.start) and boundFits(field.range_element, value.range.end),
        .unknown => value == .string,
        inline else => |t| value == @field(std.meta.Tag(Value), @tagName(t)),
    };
}

fn boundFits(element: ?types.FieldType, b: ?RangeBound) bool {
    const bound_value = b orelse return true;
    const e = element orelse return false;
    return switch (bound_value) {
        .date => e == .date,
        .datetime => e == .datetime,
        .timestamp => e == .timestamp,
    };
}

fn writeRecord(w: *Writer, fields: []const types.Field, cells: []const Cell) Writer.Error!void {
    try w.writeAll("{\"f\":[");
    for (fields, cells, 0..) |f, cell, i| {
        if (i > 0) try w.writeByte(',');
        try writeCell(w, f, cell.value, f.mode == .repeated);
    }
    try w.writeAll("]}");
}

fn writeCell(w: *Writer, field: types.Field, value: Value, repeated: bool) Writer.Error!void {
    try w.writeAll("{\"v\":");
    switch (value) {
        .null => try w.writeAll("null"),
        .array => |cells| {
            try w.writeByte('[');
            for (cells, 0..) |cell, i| {
                if (i > 0) try w.writeByte(',');
                try writeCell(w, field, cell.value, false);
            }
            try w.writeByte(']');
        },
        .record => |cells| {
            std.debug.assert(!repeated);
            try writeRecord(w, field.fields, cells);
        },
        else => {
            try w.writeByte('"');
            switch (value) {
                .string, .geography, .json => |s| try std.json.Stringify.encodeJsonStringChars(s, .{}, w),
                // Digits, signs, letters and base64: nothing to escape.
                else => try writeText(w, value),
            }
            try w.writeByte('"');
        },
    }
    try w.writeByte('}');
}

/// A scalar's wire text, as production writes it: a timestamp as
/// microseconds since the epoch, as this library asks.
pub fn writeText(w: *Writer, value: Value) Writer.Error!void {
    switch (value) {
        .null, .array, .record => {},
        .int64 => |n| try w.print("{d}", .{n}),
        .float64 => |f| {
            if (std.math.isNan(f)) return w.writeAll("NaN");
            if (std.math.isInf(f)) return w.writeAll(if (f > 0) "Infinity" else "-Infinity");
            try w.print("{d}", .{f});
        },
        .numeric, .bignumeric => |d| try w.writeAll(d.text),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .string, .geography, .json => |s| try w.writeAll(s),
        .bytes => |b| try std.base64.standard.Encoder.encodeWriter(w, b),
        .date => |d| try writeDate(w, d),
        .time => |t| try writeTime(w, t),
        .datetime => |dt| try writeDateTime(w, dt),
        .timestamp => |ts| try w.print("{d}", .{@divFloor(ts.nanoseconds, std.time.ns_per_us)}),
        .interval => |iv| try writeInterval(w, iv),
        .range => |r| {
            try w.writeByte('[');
            try writeBound(w, r.start);
            try w.writeAll(", ");
            try writeBound(w, r.end);
            try w.writeByte(')');
        },
    }
}

fn writeBound(w: *Writer, b: ?RangeBound) Writer.Error!void {
    switch (b orelse return w.writeAll("UNBOUNDED")) {
        .date => |d| try writeDate(w, d),
        .datetime => |dt| try writeDateTime(w, dt),
        .timestamp => |ts| try w.print("{d}", .{@divFloor(ts.nanoseconds, std.time.ns_per_us)}),
    }
}

fn writeDate(w: *Writer, d: Date) Writer.Error!void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

/// `HH:MM:SS`, and six fractional digits when there is a fraction, as
/// production writes them.
fn writeTime(w: *Writer, t: Time) Writer.Error!void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.microsecond != 0) try w.print(".{d:0>6}", .{t.microsecond});
}

fn writeDateTime(w: *Writer, dt: DateTime) Writer.Error!void {
    try writeDate(w, dt.date);
    try w.writeByte('T');
    try writeTime(w, dt.time);
}

/// `Y-M D H:M:S[.F]`, unpadded, the fraction in three digits when it is
/// whole milliseconds and six otherwise (`0-0 0 0:0:0.250`, measured).
fn writeInterval(w: *Writer, iv: Interval) Writer.Error!void {
    const months = @abs(@as(i64, iv.months));
    if (iv.months < 0) try w.writeByte('-');
    try w.print("{d}-{d} {d} ", .{ months / 12, months % 12, iv.days });
    const us = @abs(iv.microseconds);
    if (iv.microseconds < 0) try w.writeByte('-');
    const seconds = us / std.time.us_per_s;
    try w.print("{d}:{d}:{d}", .{ seconds / 3600, seconds / 60 % 60, seconds % 60 });
    const frac = us % std.time.us_per_s;
    if (frac == 0) return;
    if (frac % 1000 == 0) return w.print(".{d:0>3}", .{frac / 1000});
    try w.print(".{d:0>6}", .{frac});
}

/// `2026-10-21 13:14:15.123456 UTC`, as BigQuery's console shows a
/// timestamp: six fractional digits when there is a fraction.
fn writeTimestampUtc(w: *Writer, ts: std.Io.Timestamp) Writer.Error!void {
    const us: i64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_us));
    const seconds = @divFloor(us, std.time.us_per_s);
    const days = @divFloor(seconds, std.time.s_per_day);
    const of_day: u64 = @intCast(@mod(seconds, std.time.s_per_day));
    const civil = core.timestamp.civilFromDays(days);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(civil.year)), @as(u64, @intCast(civil.month)), @as(u64, @intCast(civil.day)),
        of_day / 3600,                  of_day / 60 % 60,                of_day % 60,
    });
    const frac: u64 = @intCast(@mod(us, std.time.us_per_s));
    if (frac != 0) try w.print(".{d:0>6}", .{frac});
    try w.writeAll(" UTC");
}

/// Where in a query an error points: BigQuery ends a query error's
/// message with `at [line:column]`, both from 1 (`Syntax error:
/// Unexpected keyword WHERE at [2:3]`, measured).
pub const Position = struct {
    line: u32,
    column: u32,
};

/// The position a query error's message names, or null when it names
/// none.
pub fn errorPosition(message: []const u8) ?Position {
    const start = std.mem.lastIndexOf(u8, message, "at [") orelse return null;
    const rest = message[start + 4 ..];
    const end = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    const colon = std.mem.indexOfScalar(u8, rest[0..end], ':') orelse return null;
    const line = std.fmt.parseInt(u32, rest[0..colon], 10) catch return null;
    const column = std.fmt.parseInt(u32, rest[colon + 1 .. end], 10) catch return null;
    if (line == 0 or column == 0) return null;
    return .{ .line = line, .column = column };
}

const testing = std.testing;
const codec = @import("codec.zig");
const production = @import("production_bodies.zig");
const test_util = @import("test_util.zig");

/// The schema and rows of a query page body.
const Page = struct { schema: []const types.Field, rows: []const Row };

fn decodePage(out: Allocator, scratch: Allocator, body: []const u8) !Page {
    const obj = try codec.object(try codec.parse(scratch, body));
    const schema = try codec.fieldList(out, try codec.field(obj, "schema", .object) orelse return error.InvalidResponse);
    const rows = try codec.field(obj, "rows", .array) orelse return error.InvalidResponse;
    return .{ .schema = schema, .rows = try decodeRows(out, schema, rows) };
}

fn cellNamed(page: Page, name: []const u8) Cell {
    for (page.schema, page.rows[0].cells) |f, c| if (std.mem.eql(u8, f.name, name)) return c;
    unreachable;
}

fn atMicros(n: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, n) * std.time.ns_per_us };
}

test "milestone 0's every-type row, every cell, timestamps as microseconds" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const page = try decodePage(out.allocator(), scratch.allocator(), production.query_every_type);
    try testing.expectEqual(1, page.rows.len);
    try testing.expectEqual(page.schema.len, page.rows[0].cells.len);

    try testing.expectEqual(1, cellNamed(page, "int64").value.int64);
    try testing.expectEqualStrings("1", cellNamed(page, "int64").text);
    try testing.expectEqual(std.math.minInt(i64), cellNamed(page, "int64_min").value.int64);
    try testing.expectEqual(1.5, cellNamed(page, "float64").value.float64);
    try testing.expect(std.math.isNan(cellNamed(page, "nan").value.float64));
    try testing.expectEqual(std.math.inf(f64), cellNamed(page, "inf").value.float64);
    try testing.expectEqual(-std.math.inf(f64), cellNamed(page, "ninf").value.float64);
    try testing.expectEqualStrings("123.456", cellNamed(page, "numeric").value.numeric.text);
    try testing.expectEqual(123.456, cellNamed(page, "numeric").value.numeric.toF64());
    try testing.expectEqualStrings("1.23456789012345678901234567890123456789", cellNamed(page, "bignumeric").value.bignumeric.text);
    try testing.expectEqualStrings("1.5", cellNamed(page, "numeric_trailing").value.numeric.text);
    try testing.expectEqual(true, cellNamed(page, "bool").value.boolean);
    try testing.expectEqual(false, cellNamed(page, "bool_false").value.boolean);
    try testing.expectEqualStrings("h\u{e9}llo \"q\"", cellNamed(page, "string").value.string);
    try testing.expectEqualSlices(u8, "\x00\xffab", cellNamed(page, "bytes").value.bytes);
    try testing.expectEqualStrings("AP9hYg==", cellNamed(page, "bytes").text);
    try testing.expectEqual(Date{ .year = 2026, .month = 10, .day = 21 }, cellNamed(page, "date").value.date);
    try testing.expectEqual(Time{ .hour = 13, .minute = 14, .second = 15, .microsecond = 123456 }, cellNamed(page, "time").value.time);
    try testing.expectEqual(Time{ .hour = 1, .minute = 2, .second = 3 }, cellNamed(page, "time_whole").value.time);
    try testing.expectEqual(DateTime{ .date = .{ .year = 2026, .month = 10, .day = 21 }, .time = .{ .hour = 13, .minute = 14, .second = 15, .microsecond = 123456 } }, cellNamed(page, "datetime").value.datetime);
    try testing.expectEqual(atMicros(1_792_588_455_123_456), cellNamed(page, "timestamp").value.timestamp);
    try testing.expectEqualStrings("POINT(-122.35 47.62)", cellNamed(page, "geography").value.geography);
    try testing.expectEqualStrings("POLYGON((1 1, 0 1, 0 0, 1 1))", cellNamed(page, "polygon").value.geography);
    try testing.expectEqualStrings("{\"a\":[1,2],\"b\":null}", cellNamed(page, "json").value.json);
    try testing.expectEqualStrings("{\"a\":10000000000000000000,\"s\":\"x\",\"z\":1.0}", cellNamed(page, "json_numbers").value.json);
    try testing.expectEqual(Interval{ .months = 12, .days = 2, .microseconds = 3 * 3600 * std.time.us_per_s }, cellNamed(page, "interval_sum").value.interval);
    try testing.expectEqual(Interval{ .months = 14, .days = 3, .microseconds = (4 * 3600 + 5 * 60 + 6) * std.time.us_per_s }, cellNamed(page, "interval_full").value.interval);
    try testing.expectEqual(Interval{ .days = -3 }, cellNamed(page, "interval_negative").value.interval);
    try testing.expectEqual(Interval{ .microseconds = 250_000 }, cellNamed(page, "interval_fraction").value.interval);
    try testing.expectEqualDeep(Range{ .start = .{ .date = .{ .year = 2024, .month = 1, .day = 1 } }, .end = .{ .date = .{ .year = 2024, .month = 2, .day = 1 } } }, cellNamed(page, "range_date").value.range);
    try testing.expectEqualDeep(Range{ .start = .{ .timestamp = atMicros(1_704_067_200_000_000) }, .end = null }, cellNamed(page, "range_ts_open").value.range);
    try testing.expectEqualDeep(Range{
        .start = .{ .datetime = .{ .date = .{ .year = 2024, .month = 1, .day = 1 }, .time = .{ .hour = 1, .minute = 2, .second = 3, .microsecond = 500_000 } } },
        .end = .{ .datetime = .{ .date = .{ .year = 2024, .month = 1, .day = 2 }, .time = .{ .hour = 0, .minute = 0, .second = 0 } } },
    }, cellNamed(page, "range_datetime").value.range);

    const array = cellNamed(page, "array_int").value.array;
    try testing.expectEqual(3, array.len);
    try testing.expectEqual(3, array[2].value.int64);
    try testing.expectEqual(0, cellNamed(page, "array_empty").value.array.len);
    const record = cellNamed(page, "record").value.record;
    try testing.expectEqual(1, record[0].value.int64);
    try testing.expectEqualStrings("y", record[1].value.string);
    try testing.expectEqual(2, record[2].value.array[0].value.record[0].value.int64);
    const records = cellNamed(page, "array_record").value.array;
    try testing.expectEqual(2, records[1].value.record[0].value.int64);
    try testing.expectEqual(Value.null, cellNamed(page, "null_int").value);
    try testing.expectEqualStrings("", cellNamed(page, "null_int").text);
    try testing.expectEqual(Value.null, cellNamed(page, "null_record").value);
}

test "the default and ISO timestamp forms read the same instants, exactly" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const exact = try decodePage(out.allocator(), scratch.allocator(), production.query_every_type);
    inline for (.{ production.query_every_type_float, production.query_every_type_iso }) |body| {
        const page = try decodePage(out.allocator(), scratch.allocator(), body);
        try testing.expectEqual(cellNamed(exact, "timestamp").value.timestamp, cellNamed(page, "timestamp").value.timestamp);
        try testing.expectEqualDeep(cellNamed(exact, "range_ts_open").value.range, cellNamed(page, "range_ts_open").value.range);
    }
    try testing.expectEqualStrings("1.792588455123456E9", cellNamed(try decodePage(out.allocator(), scratch.allocator(), production.query_every_type_float), "timestamp").text);
}

test "writeRows writes production's row back, byte for byte once both are compact" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const page = try decodePage(a, s, production.query_every_type);
    var written: Writer.Allocating = .init(a);
    try writeRows(&written.writer, page.schema, page.rows);

    const obj = try codec.object(try codec.parse(s, production.query_every_type));
    const original = obj.get("rows").?;
    const reread = try codec.parse(s, written.written());
    try testing.expectEqualStrings(
        try std.json.Stringify.valueAlloc(s, original, .{}),
        try std.json.Stringify.valueAlloc(s, reread, .{}),
    );
}

test "a value that does not fit its column's type is InvalidResponse" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    const a = out.allocator();
    const Case = struct { types.FieldType, []const u8 };
    for ([_]Case{
        .{ .int64, "1.5" },
        .{ .int64, "9223372036854775808" },
        .{ .int64, "" },
        .{ .float64, "abc" },
        .{ .float64, "nan" },
        .{ .float64, "0x1p3" },
        .{ .float64, "1e" },
        .{ .numeric, "1.2.3" },
        .{ .numeric, "" },
        .{ .numeric, "-" },
        .{ .bignumeric, "1e" },
        .{ .boolean, "TRUE" },
        .{ .boolean, "1" },
        .{ .bytes, "!!!" },
        .{ .bytes, "AP9hYg=" },
        .{ .bytes, "AP9h!g==" },
        .{ .date, "2026-02-29" },
        .{ .date, "2024-13-01" },
        .{ .date, "1900-02-29" },
        .{ .date, "0000-01-01" },
        .{ .date, "2026-1-01" },
        .{ .date, "20261021" },
        .{ .time, "24:00:00" },
        .{ .time, "01:60:00" },
        .{ .time, "01:02:60" },
        .{ .time, "01:02:03." },
        .{ .time, "01:02:03.1234567" },
        .{ .time, "01:02:03,5" },
        .{ .time, "1:02:03" },
        .{ .datetime, "2026-10-21X01:02:03" },
        .{ .datetime, "2026-10-21" },
        .{ .timestamp, "1.0000001" },
        .{ .timestamp, "1.5E-6" },
        .{ .timestamp, "253402300800000000" },
        .{ .timestamp, "-62135596800000001" },
        .{ .timestamp, "2026-10-21T13:14:15.1234567Z" },
        .{ .timestamp, "1e400" },
        .{ .timestamp, "soon" },
        .{ .interval, "1-12 0 0:0:0" },
        .{ .interval, "1-0 2" },
        .{ .interval, "1-0 2 3:0:0 4" },
        .{ .interval, "1 2 3:0:0" },
        .{ .interval, "0-0 0 0:60:0" },
        .{ .interval, "0-0 0 0:0:0.1234567" },
        .{ .interval, "0-0 0 0:0" },
        .{ .interval, "0-0 0 1:2:3:4" },
        .{ .interval, "+1-0 0 0:0:0" },
        .{ .interval, "10001-0 0 0:0:0" },
        .{ .range, "[2024-01-01, 2024-02-01]" },
        .{ .range, "[2024-01-01,2024-02-01)" },
        .{ .range, "(2024-01-01, 2024-02-01)" },
        .{ .range, "[soon, UNBOUNDED)" },
        .{ .record, "x" },
    }) |case| {
        const f: types.Field = .{ .name = "c", .type = case[0], .range_element = if (case[0] == .range) .date else null };
        if (scalar(a, f, case[1])) |v| {
            std.debug.print("{t} {s} decoded as {any}\n", .{ case[0], case[1], v });
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
    // A RANGE without its element type, or of one that is no range's.
    try testing.expectError(error.InvalidResponse, scalar(a, .{ .name = "r", .type = .range }, "[UNBOUNDED, UNBOUNDED)"));
    try testing.expectError(error.InvalidResponse, scalar(a, .{ .name = "r", .type = .range, .range_element = .int64 }, "[1, 2)"));
}

test "the edges every type takes" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    const a = out.allocator();
    const Case = struct { types.FieldType, []const u8, Value };
    for ([_]Case{
        .{ .int64, "9223372036854775807", .{ .int64 = std.math.maxInt(i64) } },
        .{ .float64, "-0", .{ .float64 = -0.0 } },
        .{ .float64, "1.0E300", .{ .float64 = 1e300 } },
        .{ .float64, "5e-324", .{ .float64 = 5e-324 } },
        .{ .numeric, "-0.000000001", .{ .numeric = .{ .text = "-0.000000001" } } },
        .{ .numeric, "1E-9", .{ .numeric = .{ .text = "1E-9" } } },
        .{ .bytes, "", .{ .bytes = "" } },
        .{ .date, "0001-01-01", .{ .date = .{ .year = 1, .month = 1, .day = 1 } } },
        .{ .date, "9999-12-31", .{ .date = .{ .year = 9999, .month = 12, .day = 31 } } },
        .{ .date, "2024-02-29", .{ .date = .{ .year = 2024, .month = 2, .day = 29 } } },
        .{ .date, "2000-02-29", .{ .date = .{ .year = 2000, .month = 2, .day = 29 } } },
        .{ .time, "23:59:59.999999", .{ .time = .{ .hour = 23, .minute = 59, .second = 59, .microsecond = 999_999 } } },
        .{ .time, "00:00:00.5", .{ .time = .{ .hour = 0, .minute = 0, .second = 0, .microsecond = 500_000 } } },
        .{ .datetime, "2026-10-21 13:14:15", .{ .datetime = .{ .date = .{ .year = 2026, .month = 10, .day = 21 }, .time = .{ .hour = 13, .minute = 14, .second = 15 } } } },
        .{ .timestamp, "-62135596800000000", .{ .timestamp = atMicros(min_timestamp_us) } },
        .{ .timestamp, "253402300799999999", .{ .timestamp = atMicros(max_timestamp_us) } },
        .{ .timestamp, "-1.5", .{ .timestamp = atMicros(-1_500_000) } },
        .{ .timestamp, "1E-6", .{ .timestamp = atMicros(1) } },
        .{ .timestamp, "0.000001", .{ .timestamp = atMicros(1) } },
        .{ .timestamp, "1969-12-31T23:59:59.999999Z", .{ .timestamp = atMicros(-1) } },
        .{ .timestamp, "2026-10-21T13:14:15+02:00", .{ .timestamp = atMicros(1_792_581_255_000_000) } },
        .{ .interval, "-1-2 -3 -4:5:6.000001", .{ .interval = .{ .months = -14, .days = -3, .microseconds = -((4 * 3600 + 5 * 60 + 6) * std.time.us_per_s + 1) } } },
        .{ .interval, "10000-0 3660000 87840000:0:0", .{ .interval = .{ .months = 120_000, .days = 3_660_000, .microseconds = 87_840_000 * 3600 * std.time.us_per_s } } },
        .{ .unknown, "anything", .{ .string = "anything" } },
    }) |case| {
        const f: types.Field = .{ .name = "c", .type = case[0] };
        try testing.expectEqualDeep(case[2], try scalar(a, f, case[1]));
    }
}

test "rows that do not fit their schema are InvalidResponse" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = out.allocator();
    const s = scratch.allocator();
    const schema = [_]types.Field{
        .{ .name = "n", .type = .int64 },
        .{ .name = "xs", .type = .int64, .mode = .repeated },
        .{ .name = "r", .type = .record, .fields = &.{.{ .name = "q", .type = .string }} },
    };
    for ([_][]const u8{
        "[{\"f\":[{\"v\":\"1\"},{\"v\":[]}]}]",
        "[{\"f\":[{\"v\":\"1\"},{\"v\":[]},{\"v\":null},{\"v\":null}]}]",
        "[{\"f\":[{\"v\":1},{\"v\":[]},{\"v\":null}]}]",
        "[{\"f\":[{\"v\":\"1\"},{\"v\":\"2\"},{\"v\":null}]}]",
        "[{\"f\":[{\"v\":\"1\"},{\"v\":[\"2\"]},{\"v\":null}]}]",
        "[{\"f\":[{\"v\":\"1\"},{\"v\":[]},{\"v\":{\"f\":[]}}]}]",
        "[{\"f\":[{\"v\":\"1\"},{\"v\":[]},{\"v\":\"q\"}]}]",
        "[{\"f\":[{},{\"v\":[]},{\"v\":null}]}]",
        "[{\"g\":[]}]",
        "[[]]",
    }) |body| {
        const rows = (try codec.parse(s, body)).array;
        try testing.expectError(error.InvalidResponse, decodeRows(a, &schema, rows));
    }
    const ok = try decodeRows(a, &schema, (try codec.parse(s, "[{\"f\":[{\"v\":null},{\"v\":[{\"v\":\"2\"},{\"v\":null}]},{\"v\":{\"f\":[{\"v\":\"q\"}]}}]}]")).array);
    try testing.expectEqual(Value.null, ok[0].cells[0].value);
    try testing.expectEqual(Value.null, ok[0].cells[1].value.array[1].value);
    try testing.expectEqualStrings("q", ok[0].cells[2].value.record[0].text);
}

test "format: as BigQuery's console shows a value" {
    const Case = struct { Value, []const u8 };
    const cells = [_]Cell{ .{ .value = .{ .int64 = 1 } }, .{ .value = .null } };
    for ([_]Case{
        .{ .null, "NULL" },
        .{ .{ .int64 = -7 }, "-7" },
        .{ .{ .float64 = std.math.nan(f64) }, "NaN" },
        .{ .{ .float64 = -std.math.inf(f64) }, "-Infinity" },
        .{ .{ .float64 = 0.1 }, "0.1" },
        .{ .{ .boolean = true }, "true" },
        .{ .{ .bytes = "\x00\xffab" }, "AP9hYg==" },
        .{ .{ .timestamp = atMicros(1_792_588_455_123_456) }, "2026-10-21 13:14:15.123456 UTC" },
        .{ .{ .timestamp = atMicros(0) }, "1970-01-01 00:00:00 UTC" },
        .{ .{ .timestamp = atMicros(-1) }, "1969-12-31 23:59:59.999999 UTC" },
        .{ .{ .timestamp = atMicros(min_timestamp_us) }, "0001-01-01 00:00:00 UTC" },
        .{ .{ .date = .{ .year = 1, .month = 2, .day = 3 } }, "0001-02-03" },
        .{ .{ .time = .{ .hour = 1, .minute = 2, .second = 3, .microsecond = 4 } }, "01:02:03.000004" },
        .{ .{ .interval = .{ .months = -14, .days = 3, .microseconds = 250_000 } }, "-1-2 3 0:0:0.250" },
        .{ .{ .interval = .{ .microseconds = -1 } }, "0-0 0 -0:0:0.000001" },
        .{ .{ .range = .{ .start = null, .end = .{ .date = .{ .year = 2024, .month = 2, .day = 1 } } } }, "[UNBOUNDED, 2024-02-01)" },
        .{ .{ .array = &cells }, "[1, NULL]" },
        .{ .{ .record = &cells }, "{1, NULL}" },
        .{ .{ .array = &.{} }, "[]" },
    }) |case| {
        var buf: [96]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try case[0].format(&w);
        try testing.expectEqualStrings(case[1], w.buffered());
    }
}

test "format is {f} for print" {
    const cells = [_]Cell{ .{ .value = .{ .string = "a" } }, .{ .value = .{ .timestamp = atMicros(0) } } };
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("row [a, 1970-01-01 00:00:00 UTC]", try std.fmt.bufPrint(&buf, "row {f}", .{Value{ .array = &cells }}));
}

test "every allocation failure in a row's decode is OutOfMemory without leaks" {
    const Run = struct {
        fn decode(gpa: Allocator) !void {
            var out: std.heap.ArenaAllocator = .init(gpa);
            defer out.deinit();
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const page = try decodePage(out.allocator(), scratch.allocator(), production.query_every_type);
            // An allocating writer fails only for want of memory.
            var written: Writer.Allocating = .init(out.allocator());
            writeRows(&written.writer, page.schema, page.rows) catch return error.OutOfMemory;
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.decode, .{});
}

test "errorPosition reads a query error's at [line:column]" {
    try testing.expectEqual(Position{ .line = 2, .column = 3 }, errorPosition("Syntax error: Unexpected keyword WHERE at [2:3]").?);
    try testing.expectEqual(Position{ .line = 1, .column = 8 }, errorPosition("Unrecognized name: x; Did you mean y? at [1:8]").?);
    // The last one, where a message quotes another.
    try testing.expectEqual(Position{ .line = 4, .column = 1 }, errorPosition("Function not found: f at [1:2] at [4:1]").?);
    try testing.expectEqual(null, errorPosition("division by zero: 1 / 0"));
    try testing.expectEqual(null, errorPosition("at [0:1]"));
    try testing.expectEqual(null, errorPosition("at [1:0]"));
    try testing.expectEqual(null, errorPosition("at [1:2"));
    try testing.expectEqual(null, errorPosition("at [a:b]"));
    try testing.expectEqual(null, errorPosition("at [12]"));
    try testing.expectEqual(null, errorPosition(""));
}

test "fits: a cell per field, each of its type, NULL where nullable" {
    const schema = [_]types.Field{
        .{ .name = "n", .type = .int64, .mode = .required },
        .{ .name = "xs", .type = .string, .mode = .repeated },
        .{ .name = "r", .type = .record, .fields = &.{.{ .name = "d", .type = .date }} },
        .{ .name = "span", .type = .range, .range_element = .timestamp },
        .{ .name = "u", .type = .unknown, .type_name = "UUID" },
    };
    const d: Date = .{ .year = 2026, .month = 10, .day = 21 };
    const ok = [_]Cell{
        .{ .value = .{ .int64 = 1 } },
        .{ .value = .{ .array = &.{.{ .value = .{ .string = "a" } }} } },
        .{ .value = .{ .record = &.{.{ .value = .{ .date = d } }} } },
        .{ .value = .{ .range = .{ .start = .{ .timestamp = atMicros(0) }, .end = null } } },
        .{ .value = .{ .string = "x" } },
    };
    try testing.expect(fits(&schema, .{ .cells = &ok }));
    var cells = ok;
    cells[2] = .{ .value = .null };
    try testing.expect(fits(&schema, .{ .cells = &cells }));
    const Case = struct { usize, Value };
    for ([_]Case{
        .{ 0, .null },
        .{ 0, .{ .float64 = 1 } },
        .{ 1, .{ .string = "a" } },
        .{ 1, .{ .array = &.{.{ .value = .null }} } },
        .{ 1, .{ .array = &.{.{ .value = .{ .int64 = 1 } }} } },
        .{ 2, .{ .record = &.{} } },
        .{ 2, .{ .record = &.{.{ .value = .{ .string = "2026-10-21" } }} } },
        .{ 3, .{ .range = .{ .start = .{ .date = d }, .end = null } } },
        .{ 4, .{ .int64 = 1 } },
    }) |case| {
        cells = ok;
        cells[case[0]] = .{ .value = case[1] };
        try testing.expect(!fits(&schema, .{ .cells = &cells }));
    }
    try testing.expect(!fits(&schema, .{ .cells = ok[0..4] }));
    // A range without its element type fits only unbounded.
    const loose = [_]types.Field{.{ .name = "r", .type = .range }};
    try testing.expect(fits(&loose, .{ .cells = &.{.{ .value = .{ .range = .{ .start = null, .end = null } } }} }));
    try testing.expect(!fits(&loose, .{ .cells = &.{.{ .value = .{ .range = .{ .start = .{ .date = d }, .end = null } } }} }));
}

test "Decimal.toF64 is the nearest float, and NaN for none" {
    try testing.expectEqual(1.5, (Decimal{ .text = "1.5" }).toF64());
    try testing.expectEqual(-1e-9, (Decimal{ .text = "-1E-9" }).toF64());
    try testing.expect(std.math.isNan((Decimal{ .text = "x" }).toF64()));
}

// The round-trip property: any value the writer writes, for any schema,
// decodes back to itself.

const max_depth = 3;

fn genField(g: *test_util.ByteGen, a: Allocator, depth: u8) Allocator.Error!types.Field {
    const scalars = [_]types.FieldType{ .string, .bytes, .int64, .float64, .numeric, .bignumeric, .boolean, .timestamp, .date, .time, .datetime, .geography, .json, .interval, .range };
    var f: types.Field = .{ .name = "c", .type = if (depth < max_depth and g.intRange(u8, 0, 5) == 0) .record else g.pick(types.FieldType, &scalars) };
    f.mode = g.pick(types.FieldMode, &.{ .nullable, .required, .repeated });
    if (f.type == .range) f.range_element = g.pick(types.FieldType, &.{ .date, .datetime, .timestamp });
    if (f.type == .record) {
        const fields = try a.alloc(types.Field, g.intRange(u8, 1, 3));
        for (fields) |*sub| sub.* = try genField(g, a, depth + 1);
        f.fields = fields;
    }
    return f;
}

fn genDate(g: *test_util.ByteGen) Date {
    const year = g.intRange(u16, 1, 9999);
    const month = g.intRange(u8, 1, 12);
    return .{ .year = year, .month = month, .day = g.intRange(u8, 1, @intCast(daysInMonth(year, month))) };
}

fn genTime(g: *test_util.ByteGen) Time {
    return .{
        .hour = g.intRange(u8, 0, 23),
        .minute = g.intRange(u8, 0, 59),
        .second = g.intRange(u8, 0, 59),
        .microsecond = if (g.boolean()) 0 else g.intRange(u32, 0, 999_999),
    };
}

fn genTimestamp(g: *test_util.ByteGen) std.Io.Timestamp {
    const span: u64 = @intCast(max_timestamp_us - min_timestamp_us);
    return atMicros(min_timestamp_us + @as(i64, @intCast(g.int(u64) % (span + 1))));
}

fn genDecimal(g: *test_util.ByteGen, a: Allocator) Allocator.Error!Decimal {
    var w: Writer.Allocating = .init(a);
    if (g.boolean()) w.writer.writeByte('-') catch return error.OutOfMemory;
    w.writer.print("{d}", .{g.int(u64)}) catch return error.OutOfMemory;
    if (g.boolean()) w.writer.print(".{d}", .{g.int(u32)}) catch return error.OutOfMemory;
    return .{ .text = w.written() };
}

fn genScalar(g: *test_util.ByteGen, a: Allocator, f: types.Field) Allocator.Error!Value {
    return switch (f.type) {
        .int64 => .{ .int64 = @bitCast(g.int(u64)) },
        .float64 => .{ .float64 = switch (g.intRange(u8, 0, 7)) {
            0 => std.math.nan(f64),
            1 => std.math.inf(f64),
            2 => -std.math.inf(f64),
            else => blk: {
                const x: f64 = @bitCast(g.int(u64));
                break :blk if (std.math.isNan(x) or std.math.isInf(x)) 0 else x;
            },
        } },
        .numeric => .{ .numeric = try genDecimal(g, a) },
        .bignumeric => .{ .bignumeric = try genDecimal(g, a) },
        .boolean => .{ .boolean = g.boolean() },
        .string => .{ .string = try a.dupe(u8, g.utf8(try a.alloc(u8, 24), 24)) },
        .bytes => .{ .bytes = try a.dupe(u8, g.slice(16)) },
        .date => .{ .date = genDate(g) },
        .time => .{ .time = genTime(g) },
        .datetime => .{ .datetime = .{ .date = genDate(g), .time = genTime(g) } },
        .timestamp => .{ .timestamp = genTimestamp(g) },
        .geography => .{ .geography = "POINT(1 2)" },
        .json => .{ .json = "{\"a\":[1,\"\\u00e9\"]}" },
        .interval => .{ .interval = .{
            .months = @as(i32, @intCast(g.intRange(u32, 0, 120_000))) * if (g.boolean()) @as(i32, -1) else 1,
            .days = @as(i32, @intCast(g.intRange(u32, 0, 3_660_000))) * if (g.boolean()) @as(i32, -1) else 1,
            .microseconds = @as(i64, @intCast(g.int(u64) % (87_840_000 * 3600 * std.time.us_per_s + 1))) * if (g.boolean()) @as(i64, -1) else 1,
        } },
        .range => .{ .range = .{ .start = try genBound(g, f.range_element.?), .end = try genBound(g, f.range_element.?) } },
        .record, .unknown => unreachable,
    };
}

fn genBound(g: *test_util.ByteGen, element: types.FieldType) Allocator.Error!?RangeBound {
    if (g.intRange(u8, 0, 3) == 0) return null;
    return switch (element) {
        .date => .{ .date = genDate(g) },
        .datetime => .{ .datetime = .{ .date = genDate(g), .time = genTime(g) } },
        .timestamp => .{ .timestamp = genTimestamp(g) },
        else => unreachable,
    };
}

fn genValue(g: *test_util.ByteGen, a: Allocator, f: types.Field, element: bool) Allocator.Error!Value {
    if (f.mode == .repeated and !element) {
        const cells = try a.alloc(Cell, g.intRange(u8, 0, 3));
        for (cells) |*c| c.* = .{ .value = try genValue(g, a, f, true) };
        return .{ .array = cells };
    }
    if (f.mode == .nullable and !element and g.intRange(u8, 0, 4) == 0) return .null;
    if (f.type == .record) {
        const cells = try a.alloc(Cell, f.fields.len);
        for (f.fields, cells) |sub, *c| c.* = .{ .value = try genValue(g, a, sub, false) };
        return .{ .record = cells };
    }
    return genScalar(g, a, f);
}

/// Equal as decoded values: NaN equals NaN, and a cell's text is not
/// compared (the writer's input carries none).
fn sameValue(x: Value, y: Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .float64 => |f| (std.math.isNan(f) and std.math.isNan(y.float64)) or (f == y.float64 and std.math.signbit(f) == std.math.signbit(y.float64)),
        .numeric, .bignumeric => |d| std.mem.eql(u8, d.text, switch (y) {
            .numeric, .bignumeric => |e| e.text,
            else => unreachable,
        }),
        .string, .bytes, .geography, .json => |s| std.mem.eql(u8, s, switch (y) {
            .string, .bytes, .geography, .json => |t| t,
            else => unreachable,
        }),
        .array, .record => |cells| blk: {
            const other = switch (y) {
                .array, .record => |c| c,
                else => unreachable,
            };
            if (cells.len != other.len) break :blk false;
            for (cells, other) |c, d| if (!sameValue(c.value, d.value)) break :blk false;
            break :blk true;
        },
        else => std.meta.eql(x, y),
    };
}

fn roundTripProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    const schema = try a.alloc(types.Field, g.intRange(u8, 1, 4));
    for (schema) |*f| f.* = try genField(&g, a, 0);
    const rows = try a.alloc(Row, g.intRange(u8, 0, 3));
    for (rows) |*row| {
        const cells = try a.alloc(Cell, schema.len);
        for (schema, cells) |f, *c| c.* = .{ .value = try genValue(&g, a, f, false) };
        row.* = .{ .cells = cells };
    }
    var written: Writer.Allocating = .init(a);
    try writeRows(&written.writer, schema, rows);
    const parsed = try codec.parse(a, written.written());
    const decoded = try decodeRows(a, schema, parsed.array);
    try testing.expectEqual(rows.len, decoded.len);
    for (rows, decoded) |want, got| for (want.cells, got.cells) |w, d| {
        if (!sameValue(w.value, d.value)) {
            std.debug.print("wrote {s}\n", .{written.written()});
            return error.TestUnexpectedResult;
        }
    };
}

test "fuzz values: any value written for any schema decodes back to itself" {
    try test_util.fuzzBytes({}, roundTripProperty, .{});
}

fn rowsProperty(_: void, input: []const u8) !void {
    var out: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(test_util.propertyAllocator());
    defer scratch.deinit();
    if (decodePage(out.allocator(), scratch.allocator(), input)) |_| {} else |err| switch (err) {
        error.InvalidResponse => {},
        else => return err,
    }
}

test "fuzz rows: any query page decodes or is InvalidResponse, never a crash or a leak" {
    try test_util.fuzzBytes({}, rowsProperty, .{ .corpus = &.{
        production.query_every_type,
        production.query_every_type_float,
        production.query_every_type_iso,
    } });
}
