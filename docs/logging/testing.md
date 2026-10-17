[Docs](../README.md) › [Cloud Logging](README.md) › Testing

# Testing

Cloud Logging has no emulator. `logging.testing.FakeLogging` is a Cloud
Logging in memory for your own tests: it goes where a client's transport
goes, and answers as production answered when measured on 2026-10-16.
**Experimental**: new in 0.39.0, and free to change between minor
versions until it has been used for a while.

<!-- snippet: tests/docs_examples.zig#logging-fake -->
```zig
test "the newest error, from a fake" {
    var clock: logging.testing.FakeClock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
    var fake: logging.testing.FakeLogging = .init(std.testing.allocator, clock.io());
    defer fake.deinit();
    const name = try fake.logName(.{ .project = "test" }, "app");
    try fake.write(.{ .log_name = name, .timestamp = .{ .nanoseconds = clock.now_ns - std.time.ns_per_s }, .severity = .@"error", .payload = .{ .text = "boom" } });

    var token: logging.StaticToken = .{ .token = "test" };
    var client = try logging.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "test",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var query = try client.query(.{ .min_severity = .warning });
    defer query.deinit();
    var page = try query.page(null);
    defer page.deinit();
    try std.testing.expectEqualStrings("boom", page.value.entries[0].payload.text);
}
```

## What it models

- **Entries** a test writes with `write`: the envelope, labels, a text
  or JSON payload, the bucket they went to. A global resource reads back
  with `project_id`, as production's did.
- **When an entry is visible.** `receive_timestamp` and `visible_at`
  say when a listing first shows it, on the fake's clock, so an entry
  can arrive after entries stamped later than it, as Logging's do. A
  tail's late arrivals are tested this way.
- **Listing**: scopes, order, `insertId` ties, duplicates removed within
  a result, paging, tokens bound to the filter and order and lasting 24
  hours, and production's refusals of a request, word for word.
- **Filters**: a subset of the query language with its own precedence,
  case folding, escapes and refusals (`fake_filter.zig` lists them).
  What it does not read, regular expressions and searches among them,
  it answers 501 with the reason, never by a guess.
- **Buckets and views**: each parent's `_Default` and `_Required` with
  production's fields, `addBucket`, `addView`, `removeView`,
  `setBucketState`, and `_Default`'s view leaving out data access audit
  logs.
- **Faults**: `refuseNext` (a 429 carries production's quota details),
  `refuseNextWithDelay` for one that asks the client to wait, in any of
  the three forms,
  `dropNext`, `searchingNext` for empty pages with a token, `shortenNext`
  for short ones, `denyBucketList` and `denyViewList` for a 403.

## What it does not

`X-Server-Timeout`, searches, regular expressions, views with filters of
their own, and JSON payloads as production writes them back (the fake
keeps them as written; production's are doubles). A test holds the
fake's refusals to production's verbatim answers, which
`src/logging/production_bodies.zig` keeps.
