[Docs](../README.md) › [Cloud Storage](README.md) › Testing

# Testing with the in-memory Cloud Storage

`storage.testing.FakeStorage` is Cloud Storage in memory, behind
`Client.Options.transport`, for tests of code that browses buckets and
reads objects: a bucket browser's tests, or a console's offline demo,
with no network and no project. It answers the calls a browser makes as
production answered them when measured on 2026-11-04, its refusals in
production's words.

`putBucket` and `putObject` stand in for whoever made the bucket and
wrote its objects; `deleteObject` for whoever deleted one.

<!-- snippet: tests/docs_examples.zig#storage-fake -->
```zig
test "a bucket browsed as a console shows it, from the in-memory Cloud Storage" {
    var fake: storage.testing.FakeStorage = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    // Standing in for whoever made the bucket and wrote its objects.
    try fake.putBucket(.{ .name = "my-reports" });
    try fake.putObject(.{ .bucket = "my-reports", .name = "2026/11/summary.csv", .bytes = "day,total\n1,42\n", .content_type = "text/csv" });
    try fake.putObject(.{ .bucket = "my-reports", .name = "2026/12/summary.csv", .bytes = "day,total\n", .content_type = "text/csv" });
    try fake.putObject(.{ .bucket = "my-reports", .name = "README.txt", .bytes = "Monthly reports.\n", .content_type = "text/plain" });

    var token: storage.StaticToken = .{ .token = "none" };
    var client = try storage.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    // The top level: one folder and one object.
    const bucket = client.bucket("my-reports");
    var top = try bucket.listObjects(.{ .delimiter = "/" });
    defer top.deinit();
    try std.testing.expectEqualStrings("2026/", top.value.prefixes[0]);
    try std.testing.expectEqualStrings("README.txt", top.value.objects[0].name);

    // Inside the folder, then a preview of one file's first bytes.
    var months = try bucket.listObjects(.{ .prefix = "2026/", .delimiter = "/" });
    defer months.deinit();
    try std.testing.expectEqual(2, months.value.prefixes.len);
    var preview = try bucket.object("2026/11/summary.csv").downloadAlloc(1024, .{ .range = .{ .offset = 0, .length = 9 } });
    defer preview.deinit();
    try std.testing.expectEqualStrings("day,total", preview.value.data);
}
```

## What it answers, and how

- `Client.listBuckets` sorts by name and pages with the last name as its
  token, as production does.
- `Bucket.listObjects` takes `prefix`, `delimiter`, `match_glob`,
  `versions` and pages. Objects and folders (prefixes) share one sorted
  order and one count: a page of 3 can be two folders and one object.
  The page token is production's own, and `maxResults=0` is an empty
  page, as it was in production. A glob takes `*`, `**` (`**/` also
  matching no folder at all), `?`, `[a-z]`, `[!a-z]`, `{a,b}` and `\`
  escapes; an unclosed `[` or `{` is refused in production's words,
  naming the index. `start_offset` and `end_offset` keep the names from
  one up to the other in byte order, before folders are made, as
  production did on 2026-11-05: a folder is listed when a name under it
  is in range, and a start at or past the end is an empty page.
- An object's metadata carries what production's does, `updated`,
  `md5Hash`, `crc32c`, custom metadata and the rest.
- Media reads, whole or by range: 206 with `Content-Range`, 416 "Request
  range not satisfiable" for a range past the end, the last bytes for
  `bytes=-N`. An object put with `.gzip = true` is stored compressed and
  reads decompressed, the range ignored, unless the request takes gzip
  as sent, as production does.
- Writes land in their own bucket: one-request, resumable and XML
  multipart uploads, deletes, and a bucket's `get`, as the package's own
  tests' fake of transfers serves them.
- A bucket put with `.versioning = true` keeps an object's earlier
  generations when `putObject` replaces it or `deleteObject` deletes it:
  `versions` lists them oldest first, with `timeDeleted`, and a read by
  generation finds them.
- `refuseNext(n, status)` and `dropNext(n)` fail the next calls.

A reader that knows the last name it read lists only what came after,
with no paging through the names before it:

<!-- snippet: tests/docs_examples.zig#storage-offsets -->
```zig
test "a log reader lists only what came after the last name it read" {
    var fake: storage.testing.FakeStorage = .init(std.testing.allocator, std.testing.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    try fake.putBucket(.{ .name = "my-logs" });
    // Named in sequence, zero-padded, so byte order is time order.
    for ([_][]const u8{ "log/000000011998", "log/000000011999", "log/000000012000", "log/000000012001", "log/000000012002" }) |name| {
        try fake.putObject(.{ .bucket = "my-logs", .name = name, .bytes = "entry\n" });
    }
    var token: storage.StaticToken = .{ .token = "none" };
    var client = try storage.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    // The reader stopped after 000000011999: the next page starts there,
    // whatever came before it, with no paging through earlier names.
    var page = try client.bucket("my-logs").listObjects(.{
        .prefix = "log/",
        .start_offset = "log/000000012000",
        .end_offset = "log/000000012002",
    });
    defer page.deinit();
    try std.testing.expectEqual(2, page.value.objects.len);
    try std.testing.expectEqualStrings("log/000000012000", page.value.objects[0].name);
    try std.testing.expectEqualStrings("log/000000012001", page.value.objects[1].name);
}
```

Not modelled, answered 501 with the reason: making or deleting a bucket
through the API, a write to a versioned bucket's objects (only
`putObject` and `deleteObject` keep their history), copies, rewrites and
moves to another bucket, soft-deleted listings, folders as prefixes, a
range of an earlier generation, and project-level calls such as HMAC
keys.

The fake is held to production by a replay: the layout milestone 0 made
in a real bucket, put into the fake, and every listing, glob, page and
media read production answered asked again, each matched.
