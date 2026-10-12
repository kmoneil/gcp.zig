//! Pub/Sub request paths: the resource path every call builds on, the list
//! query, and the resource name that goes inside bodies. The percent-encoding
//! rules, and the measurements behind them, live in `core.query`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const query = @import("core").query;

pub const Collection = enum {
    topics,
    subscriptions,
    snapshots,
    schemas,
};

/// `/v1/projects/{project}/{collection}/{id}{suffix}`, with `project` and `id`
/// encoded. `suffix` is a literal method such as `:publish`, or "".
pub fn resourcePath(
    arena: Allocator,
    project: []const u8,
    collection: Collection,
    id: []const u8,
    suffix: []const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeResourcePath(w, project, collection, id, suffix) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeResourcePath(
    w: *Writer,
    project: []const u8,
    collection: Collection,
    id: []const u8,
    suffix: []const u8,
) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try query.writeSegment(w, project);
    try w.print("/{t}/", .{collection});
    try query.writeSegment(w, id);
    try w.writeAll(suffix);
}

/// `/v1/projects/{project}/{collection}?pageSize=N&pageToken=T` for list calls.
/// A zero `page_size` and a null or empty token are left out.
pub fn listPath(
    arena: Allocator,
    project: []const u8,
    collection: Collection,
    page_size: u32,
    page_token: ?[]const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeListPath(&out.writer, project, collection, page_size, page_token) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeListPath(
    w: *Writer,
    project: []const u8,
    collection: Collection,
    page_size: u32,
    page_token: ?[]const u8,
) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try query.writeSegment(w, project);
    try w.print("/{t}", .{collection});
    var params: query.Params = .init(w);
    try params.addNonZero("pageSize", page_size);
    try params.addOptional("pageToken", page_token);
}

/// `/v1/projects/{project}/topics/{topic}/{kind}?pageSize=N&pageToken=T`: what
/// is attached to a topic, its `.subscriptions` or its `.snapshots`.
pub fn attachedPath(
    arena: Allocator,
    project: []const u8,
    topic: []const u8,
    kind: Collection,
    page_size: u32,
    page_token: ?[]const u8,
) Allocator.Error![]u8 {
    std.debug.assert(kind != .topics);
    var out: Writer.Allocating = .init(arena);
    writeAttachedPath(&out.writer, project, topic, kind, page_size, page_token) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeAttachedPath(
    w: *Writer,
    project: []const u8,
    topic: []const u8,
    kind: Collection,
    page_size: u32,
    page_token: ?[]const u8,
) Writer.Error!void {
    try writeResourcePath(w, project, .topics, topic, "");
    try w.print("/{t}", .{kind});
    var params: query.Params = .init(w);
    try params.addNonZero("pageSize", page_size);
    try params.addOptional("pageToken", page_token);
}

/// `/v1/projects/{project}/schemas?schemaId={id}`: where a schema is made.
/// Its id goes in the query, not the path.
pub fn schemaCreatePath(arena: Allocator, project: []const u8, id: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeSchemaCreatePath(&out.writer, project, id) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSchemaCreatePath(w: *Writer, project: []const u8, id: []const u8) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try query.writeSegment(w, project);
    try w.writeAll("/schemas");
    var params: query.Params = .init(w);
    try params.add("schemaId", id);
}

/// `/v1/projects/{project}/schemas/{id}{suffix}`, or with `@{revision}`
/// after the id for one revision of the schema. `suffix` is a literal
/// method or query, such as `:rollback` or `?view=FULL`, or "".
pub fn schemaPath(
    arena: Allocator,
    project: []const u8,
    id: []const u8,
    revision_id: ?[]const u8,
    suffix: []const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeSchemaPath(&out.writer, project, id, revision_id, suffix) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSchemaPath(
    w: *Writer,
    project: []const u8,
    id: []const u8,
    revision_id: ?[]const u8,
    suffix: []const u8,
) Writer.Error!void {
    try writeResourcePath(w, project, .schemas, id, "");
    if (revision_id) |revision| {
        // The `@` is the API's own separator, and goes as it is.
        try w.writeByte('@');
        try query.writeSegment(w, revision);
    }
    try w.writeAll(suffix);
}

/// `/v1/projects/{project}/schemas?view=V&pageSize=N&pageToken=T`. `view`
/// is the wire's word, `BASIC` or `FULL`, and is always sent.
pub fn schemaListPath(
    arena: Allocator,
    project: []const u8,
    view: []const u8,
    page_size: u32,
    page_token: ?[]const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeSchemaListPath(&out.writer, project, view, page_size, page_token) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSchemaListPath(
    w: *Writer,
    project: []const u8,
    view: []const u8,
    page_size: u32,
    page_token: ?[]const u8,
) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try query.writeSegment(w, project);
    try w.writeAll("/schemas");
    var params: query.Params = .init(w);
    try params.add("view", view);
    try params.addNonZero("pageSize", page_size);
    try params.addOptional("pageToken", page_token);
}

/// `/v1/projects/{project}/schemas{method}`: a call on the project's
/// schemas as a whole, `:validate` or `:validateMessage`.
pub fn schemasMethodPath(arena: Allocator, project: []const u8, method: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeSchemasMethodPath(&out.writer, project, method) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSchemasMethodPath(w: *Writer, project: []const u8, method: []const u8) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try query.writeSegment(w, project);
    try w.writeAll("/schemas");
    try w.writeAll(method);
}

/// The unencoded resource name, `projects/{project}/{collection}/{id}`, as it
/// appears inside JSON bodies.
pub fn resourceName(
    arena: Allocator,
    project: []const u8,
    collection: Collection,
    id: []const u8,
) Allocator.Error![]u8 {
    return arena.print("projects/{s}/{t}/{s}", .{ project, collection, id });
}

const testing = std.testing;

test "resourcePath encodes ids and keeps the method suffix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "/v1/projects/test/topics/orders:publish",
        try resourcePath(a, "test", .topics, "orders", ":publish"),
    );
    // Regressions: `%` is encoded so the server's decoding restores it, and
    // `+` stays literal, because production does not decode `%2B`.
    try testing.expectEqualStrings(
        "/v1/projects/test/subscriptions/a%2541b+c~d.e_f-g",
        try resourcePath(a, "test", .subscriptions, "a%41b+c~d.e_f-g", ""),
    );
    // Domain-scoped project ids keep their colon, as Google's clients send it.
    try testing.expectEqualStrings(
        "/v1/projects/example.com:proj/topics/t",
        try resourcePath(a, "example.com:proj", .topics, "t", ""),
    );
    // Bytes that can never be in a valid id are still encoded, never passed raw.
    try testing.expectEqualStrings(
        "/v1/projects/p/topics/a%2Fb%20c%3Fd%23e%C3%A9",
        try resourcePath(a, "p", .topics, "a/b c?d#e\xc3\xa9", ""),
    );
}

test "listPath builds the query" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1/projects/p/topics", try listPath(a, "p", .topics, 0, null));
    try testing.expectEqualStrings("/v1/projects/p/topics?pageSize=100", try listPath(a, "p", .topics, 100, null));
    try testing.expectEqualStrings("/v1/projects/p/topics?pageSize=2", try listPath(a, "p", .topics, 2, ""));
    // Page tokens are opaque and may hold `/`, `+` and `=`.
    try testing.expectEqualStrings(
        "/v1/projects/p/subscriptions?pageSize=2&pageToken=projects%2Fp%2Ftopics%2Fx%2B%3D",
        try listPath(a, "p", .subscriptions, 2, "projects/p/topics/x+="),
    );
    try testing.expectEqualStrings(
        "/v1/projects/p/topics?pageToken=abc",
        try listPath(a, "p", .topics, 0, "abc"),
    );
}

test "resourceName is not encoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "projects/test/topics/a%41",
        try resourceName(arena.allocator(), "test", .topics, "a%41"),
    );
}

test "attachedPath names what is attached to a topic, with the page options" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "/v1/projects/test/topics/orders/subscriptions?pageSize=100",
        try attachedPath(a, "test", "orders", .subscriptions, 100, null),
    );
    // The topic's id is encoded as every id is, and the token as every token.
    try testing.expectEqualStrings(
        "/v1/projects/test/topics/a%2541b/snapshots?pageSize=2&pageToken=n%2F1",
        try attachedPath(a, "test", "a%41b", .snapshots, 2, "n/1"),
    );
    try testing.expectEqualStrings("/v1/projects/test/topics/orders/snapshots", try attachedPath(a, "test", "orders", .snapshots, 0, ""));
}

test "snapshots are a collection as topics and subscriptions are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1/projects/test/snapshots/before", try resourcePath(a, "test", .snapshots, "before", ""));
    try testing.expectEqualStrings("/v1/projects/test/snapshots?pageSize=5", try listPath(a, "test", .snapshots, 5, null));
    try testing.expectEqualStrings("projects/test/snapshots/before", try resourceName(a, "test", .snapshots, "before"));
}

test "schema paths: the id in the query on create, a revision after an @, the view on a list, and the two calls on the collection" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1/projects/test/schemas?schemaId=order-v1", try schemaCreatePath(a, "test", "order-v1"));
    // A `%` in an id is encoded in the query as it is in a path.
    try testing.expectEqualStrings("/v1/projects/test/schemas?schemaId=a%2541b%2Bc", try schemaCreatePath(a, "test", "a%41b+c"));

    try testing.expectEqualStrings("/v1/projects/test/schemas/order-v1", try schemaPath(a, "test", "order-v1", null, ""));
    try testing.expectEqualStrings("/v1/projects/test/schemas/order-v1?view=FULL", try schemaPath(a, "test", "order-v1", null, "?view=FULL"));
    try testing.expectEqualStrings("/v1/projects/test/schemas/order-v1@c7cfa2a8?view=BASIC", try schemaPath(a, "test", "order-v1", "c7cfa2a8", "?view=BASIC"));
    try testing.expectEqualStrings("/v1/projects/test/schemas/a%2541b@c7cfa2a8:deleteRevision", try schemaPath(a, "test", "a%41b", "c7cfa2a8", ":deleteRevision"));
    // What could never be in a revision id is still encoded, never passed raw.
    try testing.expectEqualStrings("/v1/projects/test/schemas/s-1@a%2Fb%3Fc", try schemaPath(a, "test", "s-1", "a/b?c", ""));

    try testing.expectEqualStrings("/v1/projects/test/schemas?view=BASIC&pageSize=100", try schemaListPath(a, "test", "BASIC", 100, null));
    try testing.expectEqualStrings("/v1/projects/test/schemas?view=FULL", try schemaListPath(a, "test", "FULL", 0, ""));
    try testing.expectEqualStrings("/v1/projects/test/schemas?view=FULL&pageSize=2&pageToken=n%2F1", try schemaListPath(a, "test", "FULL", 2, "n/1"));

    try testing.expectEqualStrings("/v1/projects/test/schemas:validate", try schemasMethodPath(a, "test", ":validate"));
    try testing.expectEqualStrings("/v1/projects/example.com:proj/schemas:validateMessage", try schemasMethodPath(a, "example.com:proj", ":validateMessage"));
    try testing.expectEqualStrings("projects/test/schemas/order-v1", try resourceName(a, "test", .schemas, "order-v1"));
}
