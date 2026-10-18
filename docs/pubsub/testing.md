[Docs](../README.md) › [Pub/Sub](README.md) › Testing with an in-memory Pub/Sub

# Testing with an in-memory Pub/Sub

`pubsub.testing.FakePubSub` is Pub/Sub in memory. It goes where a
client's transport goes, and from then on topics, subscriptions,
publishes, pulls and acks all happen inside the test process: no
emulator, no JVM, no network, no credentials. It answers and refuses as
**production** did when measured, in production's words, which is where
it parts from the emulator.

> **Experimental.** New in 0.37.0. Its surface is small and may still
> change between minor versions; what it models can only grow.

**On this page:** [A first test](#a-first-test) ·
[Time is the test's](#time-is-the-tests) · [Faults](#faults) ·
[What only production knows](#what-only-production-knows) ·
[What it models](#what-it-models) ·
[What it keeps and does not do](#what-it-keeps-and-does-not-do) ·
[What it does not model](#what-it-does-not-model) ·
[The fake or the emulator](#the-fake-or-the-emulator) ·
[How it is held to production](#how-it-is-held-to-production)

## A first test

<!-- snippet: tests/docs_examples.zig#pubsub-fake -->
```zig
test "a message that is not acknowledged comes again when its lease lapses" {
    var clock: pubsub.testing.FakeClock = .{};
    var fake: pubsub.testing.FakePubSub = .init(std.testing.allocator, clock.io(), .{});
    defer fake.deinit();
    // Any token: the fake checks none.
    var token: pubsub.StaticToken = .{ .token = "unchecked" };
    var client = try pubsub.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var topic = try client.topic("orders").create(.{});
    defer topic.deinit();
    const worker = client.subscription("orders-worker");
    var made = try worker.create(.{ .topic_id = "orders", .ack_deadline_seconds = 30 });
    defer made.deinit();
    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();

    var first = try worker.pull(.{});
    defer first.deinit();
    try std.testing.expectEqualStrings("hello", first.value.messages[0].data);

    // Not acknowledged. Half a minute passes on the test's clock, with no
    // sleep, and the message comes again.
    clock.now_ns += 31 * std.time.ns_per_s;
    var again = try worker.pull(.{});
    defer again.deinit();
    try std.testing.expectEqualStrings("hello", again.value.messages[0].data);
    try worker.ack(&.{again.value.messages[0].ack_id});
    try std.testing.expectEqual(0, fake.backlog("my-project", "orders-worker"));
}
```

- **The client is a production client.** It needs a token provider, and
  any will do: the fake checks no credentials. Leave `endpoint` unset.
  With an emulator endpoint the client would take its emulator-only
  paths, which is not what you want to test.
- **One fake serves any number of clients**, from any number of tasks:
  a `Publisher` and a `Subscriber` can share one. Each takes the same
  `Client.Options`, with `.transport = fake.transport()`.
- **A project is there as soon as it is named.** Topics and
  subscriptions are not: make them, as against production.
- **What a test can ask of it**: `backlog` (messages a subscription has
  not had acknowledged), `outstanding` (of those, the ones out on a
  lease now), `publishedCount` (what a topic was sent) and
  `requestCount` (requests served, by kind). `serve` takes one raw
  request, for what no client would send.

## Time is the test's

The fake's clock is the `Io` it is given. Leases, retry backoffs,
retention and a snapshot's seven days all read it.

- **With `pubsub.testing.FakeClock`** nothing moves until the test moves
  `now_ns`, so "the lease lapses and the message comes again" is one
  line and no sleep, as above. The client's own retry backoffs run on
  the same clock and cost nothing either.
- **With a real `Io`**, `std.testing.io` in a test, it runs in real
  time. A `Subscriber` and a `Publisher` need that: they run tasks of
  their own. Set `Options.empty_pull_hold` to a few milliseconds, so
  that a pull with nothing to give is held as production holds one,
  briefly, and the subscriber's loop does not spin.

A pull returns what it has in no order unless the messages have an
ordering key, as production gives none. `Options.shuffle = false` gives
the order published, which no test should come to lean on.

## Faults

Faults are asked for, never random. Each is for the next `n` requests of
one kind (`.publish`, `.pull`, `.acknowledge`, `.modify_ack_deadline`,
`.admin`, or `.all`):

| Call | What the next `n` requests meet |
| --- | --- |
| `refuseNext(n, status, which)` | answered with that status; nothing changes |
| `refuseNextWithDelay(n, status, which, delay)` | the same, asking the client to wait `delay.ms` in `delay.form`: `.retry_after` (whole seconds), `.retry_after_ms`, `.retry_info`, or `.all`, the default |
| `loseAnswers(n, which)` | carried out, then answered 503: the answer was lost on the way back |
| `dropNext(n, which)` | a broken connection; nothing changes |

<!-- snippet: tests/docs_examples.zig#pubsub-fake-faults -->
```zig
/// Two refusals, then the publish lands, once: what the caller's retries
/// are for.
fn publishThroughAnOutage(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client) !void {
    fake.refuseNext(2, 503, .publish);
    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();
    try std.testing.expectEqual(3, fake.requestCount(.publish));
    try std.testing.expectEqual(1, fake.publishedCount("my-project", "orders"));
}

/// The answer is lost and the publish has landed: sent again, the topic
/// holds the message twice, as production's would.
fn publishTwice(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client) !void {
    const before = fake.publishedCount("my-project", "orders");
    fake.loseAnswers(1, .publish);
    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();
    try std.testing.expectEqual(before + 2, fake.publishedCount("my-project", "orders"));
}

/// A refusal that asks for longer than the client waits: not retried, and
/// the delay is there for the app to schedule its next try by.
fn askedToWait(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client, diag: *const pubsub.Diagnostics) !void {
    const sent = fake.requestCount(.publish);
    fake.refuseNextWithDelay(1, 503, .publish, .{ .ms = 30_000 });
    try std.testing.expectError(error.Unavailable, client.topic("orders").publish(&.{.{ .data = "later" }}, .{}));
    try std.testing.expectEqual(sent + 1, fake.requestCount(.publish));
    try std.testing.expectEqual(30_000, diag.retry_after_ms.?);
}
```

No Google service measured on 2026-10-17 asks for a delay, so a scripted
one is the way to see what an app does with it before production does.

A pull whose answer is lost has leased its messages to nobody: they come
again when those leases lapse, as they would in production.

## What only production knows

The fake has no world outside itself. A table, a bucket, a stream, a
service account and a tag are each taken to be there and allowed, where
production looks and may refuse. What production would then find out by
trying, the test says:

| A test says | With |
| --- | --- |
| whether a BigQuery or Cloud Storage subscription can write | `setExportState(project, subscription, state)` |
| whether an import topic can read its source | `setIngestionState(project, topic, state)` |
| whether a message fits a topic's schema | `Options.fits`, a function; with none, every message fits |
| which account is Pub/Sub's service agent | `Options.service_agent`; then a dead letter is forwarded only once that account may publish to the dead-letter topic and acknowledge on the subscription, as in production |

<!-- snippet: tests/docs_examples.zig#pubsub-fake-state -->
```zig
/// What production would learn by writing rows, the test says: here,
/// that the table is gone.
fn tableGone(fake: *pubsub.testing.FakePubSub, client: *pubsub.Client) !void {
    var made = try client.subscription("orders-rows").create(.{
        .topic_id = "orders",
        .delivery = .{ .bigquery = .{ .table = "my-project.sales.orders" } },
    });
    defer made.deinit();
    fake.setExportState("my-project", "orders-rows", .not_found);

    var read = try client.subscription("orders-rows").get();
    defer read.deinit();
    try std.testing.expectEqual(pubsub.ExportState.not_found, read.value.delivery.bigquery.state);
    try std.testing.expectEqual(.resource_error, read.value.state);
}
```

Production returns no tag on a read, and neither does the fake:
`tagValue(resource, key)` says what a topic, a subscription or a
snapshot was made with.

## What it models

Each as production answered when it was measured, refusals in its words:

| Area | Guide |
| --- | --- |
| Topics and subscriptions: made, read, updated by mask, deleted, listed in pages; their defaults and bounds | [Topics and subscriptions](topics-and-subscriptions.md) |
| Publish, gzip-compressed or not, pull, acknowledge, lease changes and nacks; a lease that lapses | [Overview](README.md), [Publishing](publishing.md#compressed-publishing) |
| Filters, ordering keys, dead letters and delivery attempts, retry policies, retention, exactly-once delivery | [Topics and subscriptions](topics-and-subscriptions.md), [Subscribing](subscribing.md) |
| Snapshots, seeking to a snapshot or a time, detaching, a topic's retention | [Replaying and purging](replay.md) |
| Schemas and their revisions, a topic's schema settings, the attributes on a message | [Schemas](schemas.md) |
| IAM policies on topics, subscriptions, snapshots and schemas, with their etags | [Topics and subscriptions](topics-and-subscriptions.md#iam) |

Some of what it does may surprise, because production does it:

- **An ack takes only while the message is out on a lease.** After a
  lapse or a nack, an ack with the old id is answered and forgotten, and
  the message comes again. (The emulator takes a late ack.)
- **A seek ends no ack id.** One from before it goes on naming its
  message, and acts once the message is out again; with exactly-once
  delivery it is answered for as long as the lease it had runs, and
  refused after ([Replaying](replay.md#what-a-running-subscriber-sees)).
- **With ordering, a key gives nothing more while one of its messages is
  out**, and a nack brings back every later message of the key,
  acknowledged ones included.
- **With exactly-once delivery, a late ack is refused**, id by id.
- **A filter production refuses is refused**, in its words. (The
  emulator answers 500.)

## What it keeps and does not do

What Pub/Sub would do on its own is kept, checked as production checks
it, read back as production reads it back, and **not done**:

- a subscription that pushes, or writes to BigQuery or Cloud Storage,
  holds what it is sent and delivers nothing
  ([Delivery](delivery.md));
- no transform runs: a message goes through as it was published
  ([Message transforms](transforms.md));
- nothing is imported into an import topic
  ([Import topics](import-topics.md)).

## What it does not model

- **What it has no answer for it says**: 501, `error.Unimplemented`,
  with a message that begins `fake:`. It does not guess. Among these: a
  Bigtable subscription, the transforms that are no JavaScript function,
  a filter of a shape production was never shown, and a setting here and
  there that production was never asked about.
- **Production's delays.** A seek that takes seconds to show, a deleted
  topic that still takes a publish for a while, a subscription made
  again under its name that answers as the old one and the new by turns
  for two minutes, the moment before a nacked message comes again: here
  everything holds at once. A test of waiting belongs against
  production.
- **What production forgets.** It counts a message's delivery attempts
  from one again when the message has not come for about two minutes,
  and with exactly-once delivery it takes a second ack by the id that
  acknowledged a message for a time and then refuses it (after two
  minutes at most on a subscription with ordering and dead letters, and
  after three and more on one without). The fake forgets neither.
- **Production's races.** An ack that comes too late is answered and
  forgotten; with a pull right behind it on the same connection,
  production let it acknowledge the message as it went out again. Here
  each call is done before the next begins.
- **Callers and permissions.** There are no accounts: every caller holds
  every permission, and a policy is kept and never enforced, except for
  dead letters when the service agent is named.
- **Quotas, regions and CMEK**: the settings are kept and nothing is
  enforced.

## The fake or the emulator

| | `FakePubSub` | The emulator |
| --- | --- | --- |
| Needs | nothing: it is in the test process | a JVM and a port |
| Whose answers | production's, where the two differ | its own |
| Time | the test's clock, or real time | real time |
| Faults | on request | none |
| Reaches | this library, in Zig | anything that speaks HTTP or gRPC |
| Pub/Sub's own doings (push, exports, transforms, imports) | kept, not done | push is delivered; the rest is kept or refused |

Where the emulator and production part is listed with each feature:
[the overview](README.md#the-emulator-is-not-production),
[replaying](replay.md#what-the-emulator-and-production-do), and the
other guides' own tables.

## How it is held to production

- **Recorded answers.** Its tests hold it to what production answered,
  body for body, in probes run against a real project between
  2026-09-21 and 2026-10-12.
- **A model.** A property test runs random scripts of publishes, pulls,
  acks, nacks, lease changes, clock steps, snapshots and seeks, and
  after every step holds each subscription to what a short reference
  says it should hold.
- **The emulator, where the two agree.** In CI the same random scripts
  of calls go to the fake and to the emulator, and the answers must
  match. Where they did not, production was asked, and settled it:
  twice for the fake, and once against it, which is now fixed.
- **Production, slowly.** The model property's scripts are replayed
  against a real project, with the same reference saying what each
  subscription should hold, and with waits where production answers in
  its own time. The first replay, on 2026-10-13, found the fake wrong
  about ack ids from before a seek, which is fixed, and found what
  production forgets, which is listed above.
  [Development](../development.md#pubsub) says how to run one.
- **This library through it.** A `Publisher` and a `Subscriber` run over
  one fake, with faults on every kind of call, and every message is
  handled, once where delivery is exactly-once. Every guide's code on
  these pages runs against it too.
