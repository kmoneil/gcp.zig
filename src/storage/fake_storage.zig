//! Cloud Storage in memory, for tests of code that browses buckets and
//! reads objects: behind `Client.Options.transport`, it answers the calls
//! a bucket browser makes as production answered them when measured on
//! 2026-11-04 (issue #337), in production's words.
//!
//! - Buckets and objects are put in by the test (`putBucket`,
//!   `putObject`), standing in for whoever made them.
//! - `Client.listBuckets` sorts by name and pages with the last name as
//!   its token, as production does.
//! - `Bucket.listObjects` takes `prefix`, `delimiter`, `match_glob`,
//!   `versions` and pages: objects and prefixes share one sorted order and
//!   one count, a page token is production's (a protobuf of the last name,
//!   and its generation under `versions`, in base64), `maxResults=0` is an
//!   empty page, and the default page is 1000. A glob takes `*`, `**`
//!   (`**/` also matching no folder), `?`, `[a-z]`, `[!a-z]`, `{a,b}` and
//!   `\` escapes, and an unclosed `[` or `{` is refused in production's
//!   words. A glob's literal start folds prefixes as a `prefix` does.
//! - Everything else a bucket's objects take, the fake serves as the
//!   package's own tests' fake of uploads, reads and deletes does, one per
//!   bucket: metadata reads, media reads whole or by range (206, 416
//!   "Request range not satisfiable"), gzip objects read decompressed with
//!   the range ignored unless the request takes gzip, uploads (one
//!   request, resumable, XML multipart), deletes, and a bucket's `get`.
//! - A bucket put with `versioning` keeps an object's earlier generations
//!   when `putObject` replaces it: listed under `versions` with
//!   `timeDeleted`, and read by generation.
//! - Refused in production's words: a bucket nobody put (404 "The
//!   specified bucket does not exist."), a page token the fake did not
//!   make (400 "Next page token not valid: ..."), an unclosed glob class or
//!   brace.
//! - Faults a test asks for: refusals and dropped connections.
//!
//! Not modelled, answered 501 with the reason: making or deleting a bucket
//! through the API (put one instead), a write to a versioned bucket's
//! objects (only `putObject` keeps their history), copies, rewrites and
//! moves across buckets, soft-deleted listings, folders as prefixes, a
//! range of an earlier generation, and project-level calls (HMAC keys,
//! the service agent).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const Header = tp.Header;
const FakeMultipart = @import("fake_multipart.zig").FakeMultipart;
const rfc3339 = @import("fake_multipart.zig").rfc3339;

pub const FakeStorage = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Names and earlier generations, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// By name, sorted on read.
    buckets: std.StringArrayHashMapUnmanaged(*Entry) = .empty,
    faults: [2]Fault = .{ .{}, .{} },
    calls: usize = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;

    pub const Options = struct {
        /// The project buckets are put in, and listed for.
        project_id: []const u8 = "my-project",
    };

    pub const Label = struct { key: []const u8, value: []const u8 };

    pub const PutBucket = struct {
        /// Lowercase letters, digits, `-`, `_` and `.`, 3 to 63 characters.
        name: []const u8,
        location: []const u8 = "US-CENTRAL1",
        storage_class: []const u8 = "STANDARD",
        /// Keeps the earlier generations `putObject` replaces.
        versioning: bool = false,
        labels: []const Label = &.{},
    };

    pub const PutObject = struct {
        bucket: []const u8,
        name: []const u8,
        bytes: []const u8,
        content_type: []const u8 = "application/octet-stream",
        /// Stored gzip-compressed, as an upload with `Content-Encoding:
        /// gzip` leaves it; `bytes` are the plain bytes.
        gzip: bool = false,
        /// Custom metadata, as `x-goog-meta-` headers set it; names are
        /// lowercased, as Cloud Storage keeps them.
        metadata: []const Label = &.{},
    };

    pub const PutError = Allocator.Error || error{
        /// A bucket name Cloud Storage refuses, a bucket put twice, or an
        /// object in a bucket not put.
        InvalidPut,
    };

    const Entry = struct {
        inner: FakeMultipart,
        versioned: bool,
        /// Earlier generations, in the order they were replaced.
        noncurrent: std.ArrayList(Noncurrent) = .empty,
    };

    const Noncurrent = struct {
        name: []const u8,
        generation: u64,
        /// Its metadata as a read answered it, with `timeDeleted`.
        json: []const u8,
        bytes: []const u8,
        content_type: []const u8,
    };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeStorage {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeStorage) void {
        for (f.buckets.values()) |e| {
            e.inner.deinit();
            e.noncurrent.deinit(f.gpa);
            f.gpa.destroy(e);
        }
        f.buckets.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeStorage) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`.
    pub fn refuseNext(f: *FakeStorage, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeStorage, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    fn setFault(f: *FakeStorage, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeStorage, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeStorage) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    // What a test puts in.

    pub fn putBucket(f: *FakeStorage, bucket: PutBucket) PutError!void {
        if (!isBucketName(bucket.name)) return error.InvalidPut;
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (f.buckets.contains(bucket.name)) return error.InvalidPut;
        const entry = try f.gpa.create(Entry);
        errdefer f.gpa.destroy(entry);
        entry.* = .{ .inner = .init(f.gpa, f.io), .versioned = bucket.versioning };
        errdefer entry.inner.deinit();
        var body: std.Io.Writer.Allocating = .init(f.gpa);
        defer body.deinit();
        var jw: Stringify = .{ .writer = &body.writer };
        writeBucketBody(&jw, bucket) catch return error.OutOfMemory;
        entry.inner.buckets.seed(f.options.project_id, body.written()) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidPut,
        };
        try f.buckets.put(f.gpa, try f.store.allocator().dupe(u8, bucket.name), entry);
    }

    fn writeBucketBody(jw: *Stringify, bucket: PutBucket) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(bucket.name);
        try jw.objectField("location");
        try jw.write(bucket.location);
        try jw.objectField("storageClass");
        try jw.write(bucket.storage_class);
        if (bucket.versioning) {
            try jw.objectField("versioning");
            try jw.write(.{ .enabled = true });
        }
        if (bucket.labels.len > 0) {
            try jw.objectField("labels");
            try jw.beginObject();
            for (bucket.labels) |l| {
                try jw.objectField(l.key);
                try jw.write(l.value);
            }
            try jw.endObject();
        }
        try jw.endObject();
    }

    /// Adds an object with a new generation, replacing the live one of its
    /// name (kept as an earlier generation in a versioned bucket).
    pub fn putObject(f: *FakeStorage, object: PutObject) PutError!void {
        if (object.name.len == 0) return error.InvalidPut;
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const entry = f.buckets.get(object.bucket) orelse return error.InvalidPut;
        if (entry.versioned) try f.keepNoncurrent(entry, object.bucket, object.name);
        const inner = &entry.inner;
        if (object.gzip) try inner.putGzipped(object.name, object.bytes) else try inner.put(object.name, object.bytes);
        const stored = &inner.objects.items[inner.objects.items.len - 1];
        const content_type = try f.gpa.dupe(u8, object.content_type);
        f.gpa.free(stored.content_type);
        stored.content_type = content_type;
        const metadata = try f.gpa.alloc(Header, object.metadata.len);
        var filled: usize = 0;
        errdefer {
            for (metadata[0..filled]) |h| {
                f.gpa.free(h.name);
                f.gpa.free(h.value);
            }
            f.gpa.free(metadata);
        }
        for (object.metadata, metadata) |m, *h| {
            const name = try std.ascii.allocLowerString(f.gpa, m.key);
            errdefer f.gpa.free(name);
            h.* = .{ .name = name, .value = try f.gpa.dupe(u8, m.value) };
            filled += 1;
        }
        for (stored.metadata) |h| {
            f.gpa.free(h.name);
            f.gpa.free(h.value);
        }
        f.gpa.free(stored.metadata);
        stored.metadata = metadata;
    }

    /// Deletes the live object of `name`, as another writer would; in a
    /// versioned bucket it stays, as an earlier generation.
    pub fn deleteObject(f: *FakeStorage, bucket: []const u8, name: []const u8) PutError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const entry = f.buckets.get(bucket) orelse return error.InvalidPut;
        if (entry.inner.object(name) == null) return error.InvalidPut;
        if (entry.versioned) try f.keepNoncurrent(entry, bucket, name);
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const res = entry.inner.transport().send(.{ .method = .DELETE, .url = try objectUrl(a, bucket, name, ""), .bearer = "fake" }, a) catch return error.OutOfMemory;
        if (res.status != 204) return error.InvalidPut;
    }

    /// Before a replace in a versioned bucket: the live object of `name`,
    /// as a read answers it, with `timeDeleted` now.
    fn keepNoncurrent(f: *FakeStorage, entry: *Entry, bucket: []const u8, name: []const u8) PutError!void {
        const live = entry.inner.object(name) orelse return;
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const res = entry.inner.transport().send(.{ .method = .GET, .url = try objectUrl(a, bucket, name, ""), .bearer = "fake" }, a) catch return error.OutOfMemory;
        var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{}) catch return error.OutOfMemory;
        try parsed.object.put(a, "timeDeleted", .{ .string = try rfc3339(a, std.Io.Clock.awake.now(f.io).nanoseconds) });
        const s = f.store.allocator();
        try entry.noncurrent.append(f.gpa, .{
            .name = try s.dupe(u8, name),
            .generation = live.generation,
            .json = try Stringify.valueAlloc(s, parsed, .{}),
            .bytes = try s.dupe(u8, live.served orelse live.bytes),
            .content_type = try s.dupe(u8, live.content_type),
        });
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeStorage = @ptrCast(@alignCast(ptr));
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);

        switch (try f.route(arena, req.method, req.url)) {
            .reply => |r| return r,
            .forward => |fw| {
                var forwarded = req;
                forwarded.url = fw.url;
                const res = try fw.entry.inner.transport().send(forwarded, arena);
                return .{ .status = res.status, .headers = try fw.rewriteSession(arena, res.headers), .body = res.body };
            },
        }
    }

    fn sendStream(ptr: *anyopaque, req: tp.StreamRequest, arena: Allocator) tp.StreamError!tp.StreamResponse {
        const f: *FakeStorage = @ptrCast(@alignCast(ptr));
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        const own: tp.Response = own: {
            if (f.takeFault(refuse)) |fault| break :own try refusal(arena, fault.status);

            switch (try f.route(arena, req.method, req.url)) {
                .reply => |r| break :own r,
                .forward => |fw| {
                    var forwarded = req;
                    forwarded.url = fw.url;
                    var res = try fw.entry.inner.transport().sendStream(forwarded, arena);
                    res.headers = try fw.rewriteSession(arena, res.headers);
                    if (req.head_out) |out| out.* = .{ .status = res.status, .headers = res.headers };
                    return res;
                },
            }
        };
        if (req.head_out) |out| out.* = .{ .status = own.status, .headers = own.headers };
        if (req.sink == .writer and own.status >= 200 and own.status < 300) {
            req.sink.writer.writeAll(own.body) catch return error.WriteFailed;
            return .{ .status = own.status, .headers = own.headers, .bytes_streamed = own.body.len };
        }
        return .{ .status = own.status, .headers = own.headers, .body = own.body };
    }

    const Forward = struct {
        entry: *Entry,
        url: []const u8,
        /// The bucket a resumable session's URL must carry, so a later
        /// request to it finds the bucket's own fake.
        bucket: []const u8,

        fn rewriteSession(fw: Forward, arena: Allocator, headers: []const Header) Allocator.Error![]const Header {
            const marker = "/upload/session/";
            const out = try arena.dupe(Header, headers);
            for (out) |*h| {
                if (!std.ascii.eqlIgnoreCase(h.name, "location")) continue;
                const at = std.mem.indexOf(u8, h.value, marker) orelse continue;
                h.value = try std.mem.concat(arena, u8, &.{ h.value[0 .. at + marker.len], fw.bucket, "/", h.value[at + marker.len ..] });
            }
            return out;
        }
    };

    const Routed = union(enum) { reply: tp.Response, forward: Forward };

    fn route(f: *FakeStorage, arena: Allocator, method: tp.Method, url: []const u8) Allocator.Error!Routed {
        const parts = splitUrl(url);
        if (std.mem.eql(u8, parts.path, "/storage/v1/b")) {
            if (method != .GET) return .{ .reply = try notModelled(arena, "making a bucket through the API (put one with putBucket)") };
            return .{ .reply = try f.listBuckets(arena, parts.query) };
        }
        if (std.mem.startsWith(u8, parts.path, "/upload/session/")) return f.routeSession(arena, url, parts);
        if (std.mem.startsWith(u8, parts.path, "/storage/v1/projects/")) return .{ .reply = try notModelled(arena, "a project-level call (HMAC keys, the service agent)") };
        const api = for ([_][]const u8{ "/storage/v1/b/", "/upload/storage/v1/b/", "/download/storage/v1/b/" }) |p| {
            if (std.mem.startsWith(u8, parts.path, p)) break p;
        } else null;
        // The XML API names the bucket first: /{bucket}/{object}.
        const after = if (api) |p| parts.path[p.len..] else if (parts.path.len > 1) parts.path[1..] else return .{ .reply = try notModelled(arena, "this path") };
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const bucket = try decode(arena, after[0..end]);
        const entry = f.buckets.get(bucket) orelse return .{ .reply = try jsonError(arena, 404, "notFound", "The specified bucket does not exist.") };
        const rest = after[end..];
        if (api != null and std.mem.eql(u8, api.?, "/storage/v1/b/")) {
            if (rest.len == 0 and method == .DELETE) return .{ .reply = try notModelled(arena, "deleting a bucket through the API") };
            if (std.mem.eql(u8, rest, "/o") and method == .GET) return .{ .reply = try listObjects(arena, bucket, entry, parts.query) };
            if (crossBucket(rest, bucket)) return .{ .reply = try notModelled(arena, "a copy, rewrite or move to another bucket") };
            if (method == .GET) if (try noncurrentRead(arena, entry, rest, parts.query)) |r| return .{ .reply = r };
        }
        if (entry.versioned and method != .GET) return .{ .reply = try notModelled(arena, "a write to a versioned bucket's objects (only putObject keeps their history)") };
        return .{ .forward = .{ .entry = entry, .url = url, .bucket = bucket } };
    }

    fn routeSession(f: *FakeStorage, arena: Allocator, url: []const u8, parts: Url) Allocator.Error!Routed {
        const after = parts.path["/upload/session/".len..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return .{ .reply = try jsonError(arena, 404, "notFound", "No such upload session.") };
        const bucket = after[0..slash];
        const entry = f.buckets.get(bucket) orelse return .{ .reply = try jsonError(arena, 404, "notFound", "No such upload session.") };
        const path_at = std.mem.indexOf(u8, url, parts.path).?;
        const inner_url = try std.mem.concat(arena, u8, &.{ url[0..path_at], "/upload/session/", url[path_at + "/upload/session/".len + slash + 1 ..] });
        return .{ .forward = .{ .entry = entry, .url = inner_url, .bucket = bucket } };
    }

    fn crossBucket(rest: []const u8, bucket: []const u8) bool {
        inline for (.{ "/copyTo/b/", "/rewriteTo/b/", "/moveTo/b/" }) |verb| {
            if (std.mem.indexOf(u8, rest, verb)) |at| {
                const dst = rest[at + verb.len ..];
                const end = std.mem.indexOfScalar(u8, dst, '/') orelse dst.len;
                if (!std.mem.eql(u8, dst[0..end], bucket)) return true;
            }
        }
        return false;
    }

    /// A read of an earlier generation, which only this fake holds.
    fn noncurrentRead(arena: Allocator, entry: *Entry, rest: []const u8, query: []const u8) Allocator.Error!?tp.Response {
        if (!std.mem.startsWith(u8, rest, "/o/") or entry.noncurrent.items.len == 0) return null;
        const name = try decode(arena, rest["/o/".len..]);
        const generation = std.fmt.parseInt(u64, paramOf(query, "generation") orelse return null, 10) catch return null;
        for (entry.noncurrent.items) |n| {
            if (n.generation != generation or !std.mem.eql(u8, n.name, name)) continue;
            const media = if (paramOf(query, "alt")) |alt| std.mem.eql(u8, alt, "media") else false;
            if (!media) return .{ .status = 200, .body = n.json };
            return .{ .status = 200, .headers = try arena.dupe(Header, &.{
                .{ .name = "Content-Type", .value = n.content_type },
                .{ .name = "x-goog-generation", .value = try arena.print("{d}", .{n.generation}) },
            }), .body = n.bytes };
        }
        return null;
    }

    // Lists.

    fn listBuckets(f: *FakeStorage, arena: Allocator, query: []const u8) Allocator.Error!tp.Response {
        const prefix = (try paramDecoded(arena, query, "prefix")) orelse "";
        const after = try paramDecoded(arena, query, "pageToken");
        // 0 reads as the default here, where an object list answers an
        // empty page (measured).
        const asked = pageSize(query, 1000) orelse return notModelled(arena, "a maxResults that is not a number");
        const size = if (asked == 0) 1000 else asked;
        const names = try sortedKeys(arena, f.buckets.keys());
        var picked: std.ArrayList([]const u8) = .empty;
        var more = false;
        for (names) |name| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (after) |t| if (std.mem.order(u8, name, t) != .gt) continue;
            if (picked.items.len == size) {
                more = true;
                break;
            }
            try picked.append(arena, name);
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        f.writeBucketList(&jw, arena, picked.items, more) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeBucketList(f: *FakeStorage, jw: *Stringify, arena: Allocator, names: []const []const u8, more: bool) (Stringify.Error || Allocator.Error)!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("storage#buckets");
        if (more) {
            try jw.objectField("nextPageToken");
            try jw.write(names[names.len - 1]);
        }
        if (names.len > 0) {
            try jw.objectField("items");
            try jw.beginArray();
            for (names) |name| {
                const res = f.buckets.get(name).?.inner.transport().send(.{ .method = .GET, .url = try std.mem.concat(arena, u8, &.{ "https://storage.googleapis.com/storage/v1/b/", name }), .bearer = "fake" }, arena) catch return error.OutOfMemory;
                try jw.print("{s}", .{res.body});
            }
            try jw.endArray();
        }
        try jw.endObject();
    }

    /// One listed thing: an object generation, or a prefix.
    const Listed = struct {
        key: []const u8,
        generation: u64 = 0,
        /// Its metadata, or null for a prefix.
        json: ?[]const u8,
    };

    fn listObjects(arena: Allocator, bucket: []const u8, entry: *Entry, query: []const u8) Allocator.Error!tp.Response {
        if (paramOf(query, "softDeleted") != null) return notModelled(arena, "listing soft-deleted objects");
        if (paramOf(query, "includeFoldersAsPrefixes") != null) return notModelled(arena, "folders as prefixes");
        const ask: Ask = .{
            .prefix = (try paramDecoded(arena, query, "prefix")) orelse "",
            .delimiter = try paramDecoded(arena, query, "delimiter"),
            .glob = try paramDecoded(arena, query, "matchGlob"),
            .versions = if (paramOf(query, "versions")) |v| std.mem.eql(u8, v, "true") else false,
            .full = if (paramOf(query, "projection")) |p| std.mem.eql(u8, p, "full") else false,
        };
        if (ask.glob) |g| if (try globProblem(arena, g)) |message| return jsonError(arena, 400, "invalid", message);
        const size = pageSize(query, 1000) orelse return notModelled(arena, "a maxResults that is not a number");
        const token_text = try paramDecoded(arena, query, "pageToken");
        const resume_at: ?Token = if (token_text) |t| decodeToken(arena, t) orelse
            return jsonError(arena, 400, "invalid", try arena.print("Next page token not valid: {s}", .{t})) else null;
        if (size == 0) return .{ .status = 200, .body = "{\"kind\":\"storage#objects\"}" };
        const listed = try collect(arena, bucket, entry, ask);
        return writeObjectList(arena, listed, resume_at, size, ask.versions);
    }

    const Ask = struct {
        prefix: []const u8,
        delimiter: ?[]const u8,
        glob: ?[]const u8,
        versions: bool,
        full: bool,
    };

    /// Every object generation and prefix the ask lists, in one sorted
    /// order: by key, then oldest generation first.
    fn collect(arena: Allocator, bucket: []const u8, entry: *Entry, ask: Ask) Allocator.Error![]Listed {
        var list: std.ArrayList(Listed) = .empty;
        var prefixes: std.StringHashMapUnmanaged(void) = .empty;
        // A glob's literal start folds prefixes as a `prefix` does.
        const head = if (ask.glob) |g| literalHead(g) else "";
        const fold_from = if (std.mem.startsWith(u8, head, ask.prefix)) head.len else ask.prefix.len;
        for (entry.inner.objects.items) |o| {
            if (!try keep(arena, &list, &prefixes, ask, fold_from, o.name, o.generation)) continue;
            const res = entry.inner.transport().send(.{ .method = .GET, .url = try objectUrl(arena, bucket, o.name, if (ask.full) "?projection=full" else ""), .bearer = "fake" }, arena) catch return error.OutOfMemory;
            list.items[list.items.len - 1].json = res.body;
        }
        if (ask.versions) for (entry.noncurrent.items) |n| {
            if (!try keep(arena, &list, &prefixes, ask, fold_from, n.name, n.generation)) continue;
            list.items[list.items.len - 1].json = n.json;
        };
        std.mem.sortUnstable(Listed, list.items, {}, listedLess);
        return list.items;
    }

    /// Adds `name`'s entry, or its prefix once; true when an object entry
    /// was added, whose metadata the caller fills in.
    fn keep(arena: Allocator, list: *std.ArrayList(Listed), prefixes: *std.StringHashMapUnmanaged(void), ask: Ask, fold_from: usize, name: []const u8, generation: u64) Allocator.Error!bool {
        if (!std.mem.startsWith(u8, name, ask.prefix)) return false;
        if (ask.glob) |g| if (!try globMatch(arena, g, name)) return false;
        if (ask.delimiter) |d| if (d.len > 0 and fold_from <= name.len) {
            if (std.mem.indexOf(u8, name[fold_from..], d)) |at| {
                const p = name[0 .. fold_from + at + d.len];
                const slot = try prefixes.getOrPut(arena, p);
                if (!slot.found_existing) try list.append(arena, .{ .key = p, .json = null });
                return false;
            }
        };
        try list.append(arena, .{ .key = name, .generation = generation, .json = "" });
        return true;
    }

    fn listedLess(_: void, a: Listed, b: Listed) bool {
        return switch (std.mem.order(u8, a.key, b.key)) {
            .lt => true,
            .gt => false,
            .eq => a.generation < b.generation,
        };
    }

    fn writeObjectList(arena: Allocator, listed: []const Listed, resume_at: ?Token, size: usize, versions: bool) Allocator.Error!tp.Response {
        var start: usize = 0;
        if (resume_at) |t| {
            while (start < listed.len and !isPast(listed[start], t)) start += 1;
        }
        const end = @min(listed.len, start + size);
        const page = listed[start..end];
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePage(&jw, arena, page, end < listed.len, versions) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn isPast(l: Listed, t: Token) bool {
        return switch (std.mem.order(u8, l.key, t.key)) {
            .gt => true,
            .lt => false,
            .eq => t.generation != null and l.json != null and l.generation > t.generation.?,
        };
    }

    fn writePage(jw: *Stringify, arena: Allocator, page: []const Listed, more: bool, versions: bool) (Stringify.Error || Allocator.Error)!void {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("storage#objects");
        if (more) {
            const last = page[page.len - 1];
            try jw.objectField("nextPageToken");
            try jw.write(try encodeToken(arena, last.key, if (versions and last.json != null) last.generation else null));
        }
        var n_prefixes: usize = 0;
        for (page) |l| n_prefixes += @intFromBool(l.json == null);
        if (n_prefixes > 0) {
            try jw.objectField("prefixes");
            try jw.beginArray();
            for (page) |l| if (l.json == null) try jw.write(l.key);
            try jw.endArray();
        }
        if (n_prefixes < page.len) {
            try jw.objectField("items");
            try jw.beginArray();
            for (page) |l| if (l.json) |j| try jw.print("{s}", .{j});
            try jw.endArray();
        }
        try jw.endObject();
    }
};

// Page tokens, as production makes them: a protobuf whose field 1 is the
// last name or prefix a page held and, under `versions`, field 2 its
// generation, in base64.

const Token = struct { key: []const u8, generation: ?u64 };

fn encodeToken(arena: Allocator, key: []const u8, generation: ?u64) Allocator.Error![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    try raw.append(arena, 0x0a);
    try appendVarint(arena, &raw, key.len);
    try raw.appendSlice(arena, key);
    if (generation) |g| {
        try raw.append(arena, 0x10);
        try appendVarint(arena, &raw, g);
    }
    const out = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(raw.items.len));
    return std.base64.standard.Encoder.encode(out, raw.items);
}

fn appendVarint(arena: Allocator, raw: *std.ArrayList(u8), value: u64) Allocator.Error!void {
    var v = value;
    while (true) {
        const low: u8 = @truncate(v & 0x7f);
        v >>= 7;
        try raw.append(arena, if (v == 0) low else low | 0x80);
        if (v == 0) return;
    }
}

fn decodeToken(arena: Allocator, text: []const u8) ?Token {
    const len = std.base64.standard.Decoder.calcSizeForSlice(text) catch return null;
    const raw = arena.alloc(u8, len) catch return null;
    std.base64.standard.Decoder.decode(raw, text) catch return null;
    var i: usize = 0;
    if (raw.len < 2 or raw[0] != 0x0a) return null;
    i = 1;
    const key_len = readVarint(raw, &i) orelse return null;
    if (i + key_len > raw.len) return null;
    const key = raw[i .. i + key_len];
    i += @intCast(key_len);
    if (i == raw.len) return .{ .key = key, .generation = null };
    if (raw[i] != 0x10) return null;
    i += 1;
    const generation = readVarint(raw, &i) orelse return null;
    if (i != raw.len) return null;
    return .{ .key = key, .generation = generation };
}

fn readVarint(raw: []const u8, i: *usize) ?u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (i.* < raw.len) {
        const b = raw[i.*];
        i.* += 1;
        value |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return value;
        if (shift >= 57) return null;
        shift += 7;
    }
    return null;
}

// Globs, as `matchGlob` takes them.

/// Why production refuses `pattern`, in its words, or null.
fn globProblem(arena: Allocator, pattern: []const u8) Allocator.Error!?[]const u8 {
    var i: usize = 0;
    var braces: std.ArrayList(usize) = .empty;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => i = classEnd(pattern, i) orelse return try arena.print(
                "Glob pattern character class has no closing ']' for opening '[' at index {d}. Either add a closing ']' or use '\\[' to match a literal '['.",
                .{i},
            ),
            '{' => try braces.append(arena, i),
            '}' => _ = braces.pop(),
            else => {},
        }
    }
    if (braces.items.len > 0) return try arena.print(
        "Glob pattern brace expansion opening '{{' at index {d} has no closing '}}'. Use '\\{{' to match a literal '{{'.",
        .{braces.items[0]},
    );
    return null;
}

/// The index of the `]` closing the class that opens at `open`, or null.
fn classEnd(pattern: []const u8, open: usize) ?usize {
    var j = open + 1;
    if (j < pattern.len and pattern[j] == '!') j += 1;
    if (j < pattern.len and pattern[j] == ']') j += 1;
    while (j < pattern.len) : (j += 1) {
        if (pattern[j] == '\\') {
            j += 1;
            continue;
        }
        if (pattern[j] == ']') return j;
    }
    return null;
}

/// What a glob starts with before its first special character: the part
/// that acts as a prefix.
fn literalHead(pattern: []const u8) []const u8 {
    const special = std.mem.indexOfAny(u8, pattern, "*?[{\\") orelse pattern.len;
    return pattern[0..special];
}

/// Whether `name` matches `pattern`, braces expanded first.
fn globMatch(arena: Allocator, pattern: []const u8, name: []const u8) Allocator.Error!bool {
    var expanded: std.ArrayList([]const u8) = .empty;
    try expand(arena, pattern, &expanded, 0);
    for (expanded.items) |p| if (matchAt(p, name)) return true;
    return false;
}

/// Every pattern `{a,b}` braces make, at most 256, nested braces included.
fn expand(arena: Allocator, pattern: []const u8, out: *std.ArrayList([]const u8), depth: u8) Allocator.Error!void {
    if (out.items.len >= 256 or depth > 8) return;
    const open = firstBrace(pattern) orelse return out.append(arena, pattern);
    var level: usize = 0;
    var start = open + 1;
    var j = open;
    var alternatives: std.ArrayList([]const u8) = .empty;
    const close = while (j < pattern.len) : (j += 1) {
        switch (pattern[j]) {
            '\\' => j += 1,
            '{' => level += 1,
            '}' => {
                level -= 1;
                if (level == 0) break j;
            },
            ',' => if (level == 1) {
                try alternatives.append(arena, pattern[start..j]);
                start = j + 1;
            },
            else => {},
        }
    } else return out.append(arena, pattern);
    try alternatives.append(arena, pattern[start..close]);
    for (alternatives.items) |alt| {
        try expand(arena, try std.mem.concat(arena, u8, &.{ pattern[0..open], alt, pattern[close + 1 ..] }), out, depth + 1);
    }
}

fn firstBrace(pattern: []const u8) ?usize {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => i = classEnd(pattern, i) orelse return null,
            '{' => return i,
            else => {},
        }
    }
    return null;
}

/// A brace-free glob against a name: `*` within a segment, `**` across
/// them (`**/` also matching no segment), `?` one character, classes.
fn matchAt(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    return switch (p[0]) {
        '*' => if (p.len > 1 and p[1] == '*') matchAnyDepth(p[2..], s) else matchSegment(p[1..], s),
        '?' => s.len > 0 and s[0] != '/' and matchAt(p[1..], s[charLen(s)..]),
        '[' => matchClass(p, s),
        '\\' => p.len >= 2 and s.len > 0 and s[0] == p[1] and matchAt(p[2..], s[1..]),
        else => s.len > 0 and s[0] == p[0] and matchAt(p[1..], s[1..]),
    };
}

/// `**` then `rest`: any run of characters, `/` included; `**/` also
/// matches no segment at all.
fn matchAnyDepth(rest: []const u8, s: []const u8) bool {
    if (rest.len > 0 and rest[0] == '/' and matchAt(rest[1..], s)) return true;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) if (matchAt(rest, s[i..])) return true;
    return false;
}

/// `*` then `rest`: any run within one segment.
fn matchSegment(rest: []const u8, s: []const u8) bool {
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (matchAt(rest, s[i..])) return true;
        if (i < s.len and s[i] == '/') return false;
    }
    return false;
}

/// A class at the start of `p`, then the rest.
fn matchClass(p: []const u8, s: []const u8) bool {
    const close = classEnd(p, 0) orelse return false;
    if (s.len == 0 or s[0] == '/') return false;
    const n = charLen(s);
    return inClass(p[1..close], s[0..n]) and matchAt(p[close + 1 ..], s[n..]);
}

/// The bytes of the UTF-8 character `s` starts with, at least 1.
fn charLen(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 1;
    return @min(n, s.len);
}

/// Whether one character is in the class between `[` and `]`.
fn inClass(class: []const u8, char: []const u8) bool {
    var body = class;
    const negated = body.len > 0 and body[0] == '!';
    if (negated) body = body[1..];
    const c = std.unicode.utf8Decode(char) catch char[0];
    var i: usize = 0;
    var found = false;
    while (i < body.len) {
        const lo_len = charLen(body[i..]);
        const lo = std.unicode.utf8Decode(body[i .. i + lo_len]) catch body[i];
        i += lo_len;
        if (i + 1 < body.len and body[i] == '-') {
            const hi_len = charLen(body[i + 1 ..]);
            const hi = std.unicode.utf8Decode(body[i + 1 .. i + 1 + hi_len]) catch body[i + 1];
            i += 1 + hi_len;
            if (c >= lo and c <= hi) found = true;
        } else if (c == lo) found = true;
    }
    return found != negated;
}

// Small things.

/// Bucket names Cloud Storage takes: 3 to 63 lowercase letters, digits,
/// `-`, `_` and `.`, starting and ending with a letter or digit.
fn isBucketName(name: []const u8) bool {
    if (name.len < 3 or name.len > 63) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return std.ascii.isAlphanumeric(name[0]) and std.ascii.isAlphanumeric(name[name.len - 1]);
}

const Url = struct { path: []const u8, query: []const u8 };

fn splitUrl(url: []const u8) Url {
    const scheme = std.mem.indexOf(u8, url, "://");
    const rest = if (scheme) |s| url[s + 3 ..] else url;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ .path = "/", .query = "" };
    const path_q = rest[slash..];
    const q = std.mem.indexOfScalar(u8, path_q, '?');
    return .{ .path = path_q[0 .. q orelse path_q.len], .query = if (q) |i| path_q[i + 1 ..] else "" };
}

fn decode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, text));
}

fn paramOf(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn paramDecoded(arena: Allocator, query: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    const raw = paramOf(query, name) orelse return null;
    return try decode(arena, raw);
}

/// `maxResults`: absent is `default`, as production; null when it is not a
/// number.
fn pageSize(query: []const u8, default: usize) ?usize {
    const text = paramOf(query, "maxResults") orelse return default;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

fn objectUrl(arena: Allocator, bucket: []const u8, name: []const u8, query: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("https://storage.googleapis.com/storage/v1/b/") catch return error.OutOfMemory;
    core.query.writeStrictSegment(w, bucket) catch return error.OutOfMemory;
    w.writeAll("/o/") catch return error.OutOfMemory;
    core.query.writeStrictSegment(w, name) catch return error.OutOfMemory;
    w.writeAll(query) catch return error.OutOfMemory;
    return out.written();
}

fn sortedKeys(arena: Allocator, keys: []const []const u8) Allocator.Error![]const []const u8 {
    const sorted = try arena.dupe([]const u8, keys);
    std.mem.sortUnstable([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return sorted;
}

/// A JSON API error, as Cloud Storage writes one.
fn jsonError(arena: Allocator, code: u16, reason: []const u8, message: []const u8) Allocator.Error!tp.Response {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .errors = &[_]struct { message: []const u8, domain: []const u8, reason: []const u8 }{.{ .message = message, .domain = "global", .reason = reason }},
    } }, .{}) };
}


fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!tp.Response {
    return jsonError(arena, 501, "notImplemented", try arena.print("fake: {s} is not modelled yet", .{what}));
}

fn refusal(arena: Allocator, status: u16) Allocator.Error!tp.Response {
    return jsonError(arena, status, "fake", "fake: refused as the test asked");
}


// Tests, held to what production answered in milestone 0.

const testing = std.testing;
const m0 = @import("fake_storage_m0.zig");

/// The layout milestone 0 made in production (run 04848f): bucket -a
/// flat, bucket -v versioned, every object `text/plain`.
fn putMilestone0(f: *FakeStorage) !void {
    const a = "zigps-sfm0-04848f-a";
    const v = "zigps-sfm0-04848f-v";
    try f.putBucket(.{ .name = a });
    try f.putBucket(.{ .name = v, .versioning = true });
    const names = [_][]const u8{ "top.txt", "top2.txt", "empty.txt", "a/1.txt", "a/2.log", "a/b/3.txt", "a/b/c/4.txt", "a/b/c/5.csv", "a b/space name.txt", "pct%25/x.txt", "hash#/y.txt", "ünï/zé.txt", "z/last.txt", "z/z/deeper.txt", "logs/2026/11/04/app.log", "logs/2026/11/05/app.log", "logs/2026/12/01/app.log", "img/cat.png", "img/dog.jpg" };
    var buf: [128]u8 = undefined;
    for (names) |n| {
        const bytes = if (std.mem.eql(u8, n, "empty.txt")) "" else try std.fmt.bufPrint(&buf, "contents of {s}\n", .{n});
        try f.putObject(.{ .bucket = a, .name = n, .bytes = bytes, .content_type = "text/plain" });
    }
    for (0..20) |i| {
        var name_buf: [16]u8 = undefined;
        const n = try std.fmt.bufPrint(&name_buf, "many/{d:0>2}.txt", .{i});
        try f.putObject(.{ .bucket = a, .name = n, .bytes = try std.fmt.bufPrint(&buf, "contents of {s}\n", .{n}), .content_type = "text/plain" });
    }
    try f.putObject(.{ .bucket = a, .name = "big.txt", .bytes = core.testing.repeat("0123456789", 100), .content_type = "text/plain" });
    try f.putObject(.{ .bucket = a, .name = "zipped.txt", .bytes = core.testing.repeat("hello gzip world\n", 10), .content_type = "text/plain", .gzip = true });
    for (0..3) |g| try f.putObject(.{ .bucket = v, .name = "doc.txt", .bytes = try std.fmt.bufPrint(&buf, "generation {d}\n", .{g}), .content_type = "text/plain" });
    try f.putObject(.{ .bucket = v, .name = "other.txt", .bytes = "other\n", .content_type = "text/plain" });
    try f.deleteObject(v, "other.txt");
}

fn askPlain(f: *FakeStorage, arena: Allocator, target: []const u8, headers: []const Header) !tp.Response {
    const url = try std.mem.concat(arena, u8, &.{ "https://storage.googleapis.com", target });
    return f.transport().send(.{ .method = .GET, .url = url, .bearer = "t", .headers = headers }, arena);
}

fn headerOf(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

test "held to production: every listing milestone 0 read, as production answered it" {
    var f: FakeStorage = .init(testing.allocator, testing.io, .{});
    defer f.deinit();
    try putMilestone0(&f);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (m0.listings) |case| {
        const res = try askPlain(&f, a, case.target, &.{});
        errdefer std.debug.print("case {s}: {d} {s}\n", .{ case.target, res.status, res.body[0..@min(res.body.len, 400)] });
        try testing.expectEqual(case.status, res.status);
        const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
        if (case.message) |message| {
            try testing.expectEqualStrings(message, doc.object.get("error").?.object.get("message").?.string);
            continue;
        }
        const prefixes = if (doc.object.get("prefixes")) |p| p.array.items else &.{};
        try testing.expectEqual(case.prefixes.len, prefixes.len);
        for (case.prefixes, prefixes) |want, got| try testing.expectEqualStrings(want, got.string);
        const items = if (doc.object.get("items")) |i| i.array.items else &.{};
        try testing.expectEqual(case.names.len, items.len);
        for (case.names, items) |want, got| try testing.expectEqualStrings(want, got.object.get("name").?.string);
        if (case.token) |want| try testing.expectEqualStrings(want, doc.object.get("nextPageToken").?.string);
    }
}

test "held to production: media reads, ranges and gzip, as production answered them" {
    var f: FakeStorage = .init(testing.allocator, testing.io, .{});
    defer f.deinit();
    try putMilestone0(&f);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (m0.media) |case| {
        var headers: std.ArrayList(Header) = .empty;
        if (case.range) |r| try headers.append(a, .{ .name = "Range", .value = r });
        if (case.accept_gzip) try headers.append(a, .{ .name = "Accept-Encoding", .value = "gzip" });
        // The buffered transport takes gzip as sent only by asking: the
        // fake's internals read Accept-Encoding from the stream request.
        const res = if (case.accept_gzip) try askStream(&f, a, case.target, headers.items) else try askPlain(&f, a, case.target, headers.items);
        errdefer std.debug.print("case {s} {?s}: {d} {s}\n", .{ case.target, case.range, res.status, res.body[0..@min(res.body.len, 200)] });
        try testing.expectEqual(case.status, res.status);
        if (case.content_range) |want| try testing.expectEqualStrings(want, headerOf(res.headers, "Content-Range").?);
        if (case.body) |want| try testing.expectEqualStrings(want, res.body);
        if (case.accept_gzip) try testing.expectEqualStrings("gzip", headerOf(res.headers, "Content-Encoding").?);
    }
}

fn askStream(f: *FakeStorage, arena: Allocator, target: []const u8, headers: []const Header) !tp.Response {
    const url = try std.mem.concat(arena, u8, &.{ "https://storage.googleapis.com", target });
    const res = try f.transport().sendStream(.{ .method = .GET, .url = url, .bearer = "t", .headers = headers, .accept_encoding = .gzip_as_sent }, arena);
    return .{ .status = res.status, .headers = res.headers, .body = res.body };
}

const Client = @import("Client.zig");

fn testClient(f: *FakeStorage, token: *core.StaticToken) !Client {
    return Client.init(testing.allocator, testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = f.transport(),
    });
}

test "a bucket browser through the client: buckets, folders, objects, a preview and an earlier generation" {
    var f: FakeStorage = .init(testing.allocator, testing.io, .{});
    defer f.deinit();
    try putMilestone0(&f);
    try f.putObject(.{ .bucket = "zigps-sfm0-04848f-a", .name = "tagged.txt", .bytes = "x", .content_type = "text/plain", .metadata = &.{.{ .key = "Owner", .value = "ops" }} });
    var token: core.StaticToken = .{ .token = "t" };
    var client = try testClient(&f, &token);
    defer client.deinit();

    var buckets = try client.listBuckets(.{});
    defer buckets.deinit();
    try testing.expectEqual(2, buckets.value.buckets.len);
    try testing.expectEqualStrings("zigps-sfm0-04848f-a", buckets.value.buckets[0].name);
    var first = try client.listBuckets(.{ .page_size = 1 });
    defer first.deinit();
    try testing.expectEqualStrings("zigps-sfm0-04848f-a", first.value.next_page_token.?);

    const bucket = client.bucket("zigps-sfm0-04848f-a");
    var info = try bucket.get();
    defer info.deinit();
    try testing.expectEqualStrings("zigps-sfm0-04848f-a", info.value.name);

    // One folder level, as a browser shows it.
    var top = try bucket.listObjects(.{ .delimiter = "/" });
    defer top.deinit();
    try testing.expectEqual(9, top.value.prefixes.len);
    try testing.expectEqualStrings("a b/", top.value.prefixes[0]);
    try testing.expectEqualStrings("big.txt", top.value.objects[0].name);
    var under_a = try bucket.listObjects(.{ .prefix = "a/", .delimiter = "/" });
    defer under_a.deinit();
    try testing.expectEqualStrings("a/b/", under_a.value.prefixes[0]);
    try testing.expectEqual(2, under_a.value.objects.len);

    // An object as a details pane shows it.
    var meta = try bucket.object("tagged.txt").get(.{});
    defer meta.deinit();
    try testing.expectEqual(1, meta.value.size);
    try testing.expectEqualStrings("text/plain", meta.value.content_type);
    try testing.expect(meta.value.updated.len > 0 and meta.value.time_created.len > 0);
    try testing.expectEqualStrings("owner", meta.value.metadata[0].key);
    try testing.expectEqualStrings("ops", meta.value.metadata[0].value);

    // A preview: the first bytes, then the whole of a gzip object decompressed.
    var preview = try bucket.object("big.txt").downloadAlloc(1 << 20, .{ .range = .{ .offset = 0, .length = 10 } });
    defer preview.deinit();
    try testing.expectEqualStrings("0123456789", preview.value.data);
    var unzipped = try bucket.object("zipped.txt").downloadAlloc(1 << 20, .{});
    defer unzipped.deinit();
    try testing.expectEqualStrings(core.testing.repeat("hello gzip world\n", 10), unzipped.value.data);

    // The versioned bucket: three generations of doc.txt, oldest first, and
    // the first one read back by its generation.
    const versioned = client.bucket("zigps-sfm0-04848f-v");
    var history = try versioned.listObjects(.{ .versions = true });
    defer history.deinit();
    try testing.expectEqual(4, history.value.objects.len);
    const oldest = history.value.objects[0];
    try testing.expectEqualStrings("doc.txt", oldest.name);
    try testing.expect(oldest.generation < history.value.objects[1].generation);
    var old_bytes = try versioned.object("doc.txt").downloadAlloc(1 << 20, .{ .generation = oldest.generation });
    defer old_bytes.deinit();
    try testing.expectEqualStrings("generation 0\n", old_bytes.value.data);
    var live = try versioned.listObjects(.{});
    defer live.deinit();
    try testing.expectEqual(1, live.value.objects.len);
}

test "writes the fake models through the client, and the ones it answers 501" {
    var f: FakeStorage = .init(testing.allocator, testing.io, .{});
    defer f.deinit();
    try putMilestone0(&f);
    var token: core.StaticToken = .{ .token = "t" };
    var client = try testClient(&f, &token);
    defer client.deinit();

    // An upload and a delete in a flat bucket land in that bucket alone.
    const flat = client.bucket("zigps-sfm0-04848f-a");
    var uploaded = try flat.object("new/one.txt").upload("hello", .{ .content_type = "text/plain" });
    defer uploaded.deinit();
    var listed = try flat.listObjects(.{ .prefix = "new/" });
    defer listed.deinit();
    try testing.expectEqual(1, listed.value.objects.len);
    var other = try client.bucket("zigps-sfm0-04848f-v").listObjects(.{ .prefix = "new/" });
    defer other.deinit();
    try testing.expectEqual(0, other.value.objects.len);
    try flat.object("new/one.txt").delete(.{});
    try testing.expectError(error.NotFound, flat.object("new/one.txt").get(.{}));

    // What the fake leaves to production.
    try testing.expectError(error.NotFound, client.bucket("zigps-nobody").listObjects(.{}));
    try testing.expectError(error.Unimplemented, client.bucket("zigps-sfm0-04848f-v").object("doc.txt").delete(.{}));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const made = try f.transport().send(.{ .method = .POST, .url = "https://storage.googleapis.com/storage/v1/b?project=my-project", .bearer = "t", .body = "{\"name\":\"x\"}" }, arena.allocator());
    try testing.expectEqual(501, made.status);
    const across = try f.transport().send(.{ .method = .POST, .url = "https://storage.googleapis.com/storage/v1/b/zigps-sfm0-04848f-a/o/top.txt/rewriteTo/b/zigps-sfm0-04848f-v/o/top.txt", .bearer = "t", .body = "{}" }, arena.allocator());
    try testing.expectEqual(501, across.status);

    // Faults.
    f.refuseNext(1, 503);
    var retried = try flat.listObjects(.{ .prefix = "a/" });
    defer retried.deinit();
    try testing.expectEqual(5, retried.value.objects.len);
    try testing.expectError(error.InvalidPut, f.putBucket(.{ .name = "zigps-sfm0-04848f-a" }));
    try testing.expectError(error.InvalidPut, f.putBucket(.{ .name = "Bad Name" }));
    try testing.expectError(error.InvalidPut, f.putObject(.{ .bucket = "zigps-nobody", .name = "x", .bytes = "" }));
}

test "globs: escapes, nested braces, classes over non-ASCII, and the refusals' indices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "a\\*b", "a*b", true },
        .{ "a\\*b", "axb", false },
        .{ "{a,b{c,d}}/x", "bd/x", true },
        .{ "{a,b{c,d}}/x", "b/x", false },
        .{ "[ü]*", "ünï", true },
        .{ "[!a-z]*", "Zed", true },
        .{ "[!a-z]*", "zed", false },
        .{ "?", "ü", true },
        .{ "*", "a/b", false },
        .{ "**", "a/b", true },
        .{ "a/**/z", "a/z", true },
        .{ "a/**/z", "a/b/c/z", true },
        .{ "[]a]", "]", true },
    };
    for (cases) |c| {
        errdefer std.debug.print("{s} against {s}\n", .{ c[0], c[1] });
        try testing.expectEqual(c[2], try globMatch(a, c[0], c[1]));
    }
    try testing.expectEqual(null, try globProblem(a, "a\\[b"));
    try testing.expectEqual(null, try globProblem(a, "{a,{b,c}}"));
    try testing.expect(std.mem.indexOf(u8, (try globProblem(a, "x{y,{z}")).?, "at index 1") != null);
    try testing.expect(std.mem.indexOf(u8, (try globProblem(a, "ab[")).?, "at index 2") != null);
    try testing.expectEqualStrings("logs/2026/1", literalHead("logs/2026/1[12]/**"));
}

fn pagesProperty(_: void, input: []const u8) !void {
    // A plain allocator under the fuzzer, where the leak checker's record
    // of every allocation is most of a run's cost; the checking one in a
    // plain test run.
    const gpa = if (@import("builtin").fuzz) std.heap.smp_allocator else testing.allocator;
    var g: core.testing.ByteGen = .init(input);
    var clock: core.testing.FakeClock = .{};
    var f: FakeStorage = .init(gpa, clock.io(), .{});
    defer f.deinit();
    try f.putBucket(.{ .name = "pages" });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Up to 24 names over a small alphabet, so prefixes and folders repeat.
    var names: std.ArrayList([]const u8) = .empty;
    const n = g.intRange(usize, 0, 24);
    for (0..n) |_| {
        const len = g.intRange(usize, 1, 6);
        const name = try a.alloc(u8, len);
        for (name) |*c| c.* = "ab/."[g.intRange(usize, 0, 3)];
        try f.putObject(.{ .bucket = "pages", .name = name, .bytes = "x" });
        try names.append(a, name);
    }
    const prefix: []const u8 = if (g.boolean() and names.items.len > 0) names.items[0][0..g.intRange(usize, 0, names.items[0].len)] else "";
    const delimiter: ?[]const u8 = switch (g.intRange(u8, 0, 2)) {
        0 => null,
        1 => "/",
        else => "b",
    };
    const size = g.intRange(usize, 1, 5);
    // The model: each distinct name under the prefix, or its folder.
    var want: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (names.items) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const key = if (delimiter) |d| if (std.mem.indexOf(u8, name[prefix.len..], d)) |at| name[0 .. prefix.len + at + d.len] else name else name;
        try want.put(a, key, {});
    }
    const expected = try sortedKeys(a, want.keys());
    // Every page, through the transport.
    var got: std.ArrayList([]const u8) = .empty;
    var token: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        try testing.expect(pages <= expected.len + 1);
        var target: std.Io.Writer.Allocating = .init(a);
        try target.writer.print("/storage/v1/b/pages/o?maxResults={d}", .{size});
        if (prefix.len > 0) try target.writer.print("&prefix={s}", .{prefix});
        if (delimiter) |d| try target.writer.print("&delimiter={s}", .{d});
        if (token) |t| {
            try target.writer.writeAll("&pageToken=");
            try core.query.writeValue(&target.writer, t);
        }
        const res = try askPlain(&f, a, target.written(), &.{});
        try testing.expectEqual(200, res.status);
        const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
        var on_page: usize = 0;
        // Prefixes and objects come apart in the body; merge them back in
        // order to compare with the model.
        var page_keys: std.ArrayList([]const u8) = .empty;
        if (doc.object.get("prefixes")) |p| for (p.array.items) |v| try page_keys.append(a, v.string);
        if (doc.object.get("items")) |i| for (i.array.items) |v| try page_keys.append(a, v.object.get("name").?.string);
        on_page = page_keys.items.len;
        try testing.expect(on_page <= size);
        std.mem.sortUnstable([]const u8, page_keys.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        try got.appendSlice(a, page_keys.items);
        const next = doc.object.get("nextPageToken") orelse break;
        try testing.expectEqual(size, on_page);
        token = next.string;
    }
    try testing.expectEqual(expected.len, got.items.len);
    for (expected, got.items) |w, x| try testing.expectEqualStrings(w, x);
}

// Not "fuzz": about 1 ms a run, so its own nightly job (fake-storage), as
// fake-pubsub's fake properties have.
test "fake property FakeStorage pages: every page walk sees each name or folder once, in order, whatever the size" {
    try core.testing.fuzzBytes({}, pagesProperty, .{ .corpus = &.{
        "\x0c\x03\x00\x01\x02\x03\x01\x02\x03\x00\x02\x01\x00\x03\x01\x02\x01\x00\x01\x03\x02\x02\x01\x01\x00\x03\x02",
        "\x18\x05\x00\x02\x00\x02\x01\x01\x02\x03\x02\x00\x02\x01\x02\x03\x02\x00\x02\x01\x02\x03\x02\x00\x02\x01\x02\x03\x01\x01\x02",
    } });
}

test "a resumable upload's session finds its own bucket, in each of two" {
    var f: FakeStorage = .init(testing.allocator, testing.io, .{});
    defer f.deinit();
    try f.putBucket(.{ .name = "first-bucket" });
    try f.putBucket(.{ .name = "second-bucket" });
    var token: core.StaticToken = .{ .token = "t" };
    // A small single-request limit, so these uploads go resumable: each
    // bucket's own fake numbers its sessions from 1.
    var client = try Client.init(testing.allocator, testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = f.transport(),
        .single_request_limit = 256 * 1024,
        .chunk_size = 256 * 1024,
    });
    defer client.deinit();
    const big = try testing.allocator.alloc(u8, 600 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    inline for (.{ "first-bucket", "second-bucket" }) |name| {
        var up = try client.bucket(name).object("big.bin").upload(big, .{});
        defer up.deinit();
        try testing.expectEqual(big.len, up.value.size);
    }
    var back = try client.bucket("second-bucket").object("big.bin").downloadAlloc(1 << 20, .{});
    defer back.deinit();
    try testing.expectEqualSlices(u8, big, back.value.data);
    var first = try client.bucket("first-bucket").listObjects(.{});
    defer first.deinit();
    try testing.expectEqual(1, first.value.objects.len);
}

test "an object's ETag is production's: its generation and metageneration, as a protobuf in base64" {
    var f: FakeStorage = .init(testing.allocator, testing.io, .{});
    defer f.deinit();
    try f.putBucket(.{ .name = "etags" });
    try f.putObject(.{ .bucket = "etags", .name = "a.txt", .bytes = "a" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const res = try askPlain(&f, a, "/storage/v1/b/etags/o/a.txt", &.{});
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
    const etag = doc.object.get("etag").?.string;
    const generation = try std.fmt.parseInt(u64, doc.object.get("generation").?.string, 10);
    const raw = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(etag));
    try std.base64.standard.Decoder.decode(raw, etag);
    var i: usize = 1;
    try testing.expectEqual(0x08, raw[0]);
    try testing.expectEqual(generation, readVarint(raw, &i).?);
    try testing.expectEqual(0x10, raw[i]);
    i += 1;
    try testing.expectEqual(1, readVarint(raw, &i).?);
    try testing.expectEqual(raw.len, i);
    // Production's own, for generation 1793830237429211: the same shape.
    const prod = "CNu727Cq75cDEAE=";
    const prod_raw = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(prod));
    try std.base64.standard.Decoder.decode(prod_raw, prod);
    var j: usize = 1;
    try testing.expectEqual(1793830237429211, readVarint(prod_raw, &j).?);
}
