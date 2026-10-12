[Docs](../README.md) › [Pub/Sub](README.md) › Schemas

# Schemas

A topic takes any bytes. A **schema** is a contract Pub/Sub holds for
it: an Avro or Protocol Buffer definition, stored in a project under a
name. A topic that names one refuses a publish whose message does not
fit, so every subscriber gets messages it can decode.

**On this page:** [A schema and its topic](#a-schema-and-its-topic) ·
[Asking before publishing](#asking-before-publishing) ·
[Revisions](#revisions) ·
[What a subscriber sees](#what-a-subscriber-sees) ·
[Changing and removing](#changing-and-removing) ·
[Permissions](#permissions) ·
[What the emulator and production do](#what-the-emulator-and-production-do)

## A schema and its topic

<!-- snippet: tests/docs_examples.zig#pubsub-schema-create -->
```zig
/// Stores the contract, and makes a topic that holds every message to it.
fn makeOrders(client: *pubsub.Client, avro_json: []const u8) !void {
    var stored = try client.schema("order").create(.{ .type = .avro, .definition = avro_json });
    defer stored.deinit();
    var topic = try client.topic("orders").create(.{
        .schema = .{ .schema = "order", .encoding = .json },
    });
    defer topic.deinit();
}
```

- **The definition** is the Avro schema as JSON, or a `.proto` source,
  with one top-level type and no imports, of at most 300 KB. Google
  takes Avro 1.11, proto2 and proto3. Pub/Sub parses it, and one that
  does not parse is `error.InvalidArgument` in the server's words.
- **`client.schema(id)` is a handle**, as `client.topic` is, with
  `create`, `get`, `delete`, the calls for [revisions](#revisions),
  `validateMessage` and the five
  [IAM calls](topics-and-subscriptions.md#iam). `Client.listSchemas`
  pages through a project's.
- **The encoding** says how a message's `data` spells what the schema
  describes: `.json` as JSON text, `.binary` in the type's own binary
  form. This client writes neither. Your Avro or Protocol Buffer library
  makes the bytes, and `publish` sends them as it sends any.
- **A message that does not fit** is `error.InvalidArgument`, and the
  refusal is of the whole request: every message of a `Topic.publish`
  call, and every message that shared a
  [`Publisher`'s batch](publishing.md#a-topic-with-a-schema).
- **The schema may lie in another project**: name it in full,
  `projects/{project}/schemas/{id}`. Naming one needs
  `pubsub.schemas.attach` on it.
- **Views.** `get` reads the definition too unless asked for
  `.view = .basic`; the lists leave it out unless asked for `.full`.
- **Limits**, none of which can be raised: 10,000 schemas a project, 20
  revisions a schema, 300 KB a definition.

## Asking before publishing

<!-- snippet: tests/docs_examples.zig#pubsub-schema-validate -->
```zig
/// In a test, or before a deploy: would Pub/Sub store this definition,
/// and would the topic take this message?
fn check(client: *pubsub.Client, avro_json: []const u8, message: []const u8) !void {
    try client.validateSchema(.{ .type = .avro, .definition = avro_json });
    try client.schema("order").validateMessage(message, .json, null);
}
```

Three calls ask Pub/Sub a question and change nothing:

| Call | Asks |
| --- | --- |
| `Client.validateSchema(definition)` | whether the definition parses, as its type |
| `Schema.validateMessage(data, encoding, revision_id)` | whether the bytes fit the stored schema: its latest revision, or the one named |
| `Client.validateMessage(definition, data, encoding)` | the same of a definition that is not stored |

A no is `error.InvalidArgument`, with the server's reason in the
`Diagnostics`. `validateSchema` does not say whether a definition could
become a revision of a schema that is there: only a commit checks one
revision against the others.

## Revisions

<!-- snippet: tests/docs_examples.zig#pubsub-schema-revise -->
```zig
/// A new shape for orders: one more revision. Messages of the old shape
/// are still taken.
fn addField(client: *pubsub.Client, avro_json_v2: []const u8) !void {
    var next = try client.schema("order").commit(.{ .type = .avro, .definition = avro_json_v2 });
    defer next.deinit();
}

/// The new shape was a mistake. The schema's latest is the good one
/// again, and the bad one is gone, so the topic stops taking it.
fn undo(client: *pubsub.Client, good: []const u8, bad: []const u8) !void {
    var back = try client.schema("order").rollback(good);
    defer back.deinit();
    try client.schema("order").deleteRevision(bad);
}
```

A schema is never changed, only revised.

- **`commit`** adds a revision, which `get` then reads. Each has an id
  the server chose, such as `c7cfa2a8`, in `SchemaInfo.revision_id`, and
  `get(.{ .revision_id = ... })` reads one. `listRevisions` pages
  through them.
- **It must be compatible.** Google's rule for Protocol Buffers is that
  optional fields may be added and removed and nothing else changed, and
  for Avro that the new revision can read the old ones and be read by
  them. Pub/Sub checks a commit against the revisions before it.
- **`rollback(revision_id)`** makes a new revision that holds what that
  one held: the latest is then the old definition again, under a new id,
  and the revisions in between stay.
- **`deleteRevision`** removes one, though never a schema's only one:
  delete the schema.
- **A topic takes a message that fits any revision its settings allow**,
  tried from the newest to the oldest. With no bounds, a commit is live
  for the topic at once. `first_revision_id` and `last_revision_id`
  bound the range, as
  [below](#changing-and-removing).
- **A lost answer.** A repeat of a commit or a rollback that landed
  would spend one more of the 20 revisions, so a failed attempt is not
  simply sent again. The client reads the latest revision first, and if
  it already holds what was asked for, it is the answer: the attempt
  landed, and only its answer was lost. That read needs
  `pubsub.schemas.get`. If it fails, the attempt's own error is
  returned, and the diagnostics say that it may have landed.

## What a subscriber sees

<!-- snippet: tests/docs_examples.zig#pubsub-schema-receive -->
```zig
/// A handler's first question: how is this message written, and by which
/// revision? A subscriber that decodes keeps one decoder per revision,
/// each read once with `get(.{ .revision_id = ... })`.
fn describe(message: pubsub.ReceivedMessage, out: *std.Io.Writer) !void {
    const written = message.schema() orelse return out.writeAll("no schema\n");
    try out.print("{s} revision {s}, as {t}\n", .{ written.name, written.revision_id, written.encoding });
}
```

Pub/Sub writes three attributes on each message a schema topic takes:
the schema's name, the revision the message fit, and the encoding.
`ReceivedMessage.schema()` reads them, and is null for a message from a
topic with no schema. A publisher cannot set them itself: an attribute
key that starts with `goog` is refused.

A message is checked when it is published and never again. What a
subscription already holds stays as it was written, whatever is then
committed, rolled back or deleted.

## Changing and removing

<!-- snippet: tests/docs_examples.zig#pubsub-schema-topic -->
```zig
/// Stops taking newer shapes: only revisions up to `last` fit.
fn pin(client: *pubsub.Client, last: []const u8) !void {
    var pinned = try client.topic("orders").update(.{ .schema = .{ .set = .{
        .schema = "order",
        .encoding = .json,
        .last_revision_id = last,
    } } });
    defer pinned.deinit();
}

/// Any bytes again.
fn release(client: *pubsub.Client) !void {
    var plain = try client.topic("orders").update(.{ .schema = .clear });
    defer plain.deinit();
}
```

- **An update replaces the settings whole.** The encoding and the bounds
  are then what was given, and a bound left out is open. `.clear` takes
  the schema off the topic. Google says a change can take a few minutes
  to hold.
- **A deleted revision** at either end of a topic's range moves the
  range one inward. If every revision in the range is gone, the topic
  refuses every publish.
- **A deleted schema** leaves its topics reading `_deleted-schema_`,
  which `SchemaSettings.isDeleted()` answers, and refusing every
  publish. A schema made again under the same id is not the one a topic
  had. So take a schema off its topics before deleting it, and never
  send back what such a topic reads: that name is refused before
  sending.

## Permissions

| Call | Needs |
| --- | --- |
| `Schema.create`, `Client.listSchemas` | `pubsub.schemas.create`, `pubsub.schemas.list`, on the project |
| `Schema.get`, `Schema.listRevisions` | `pubsub.schemas.get`, `pubsub.schemas.listRevisions` |
| `Schema.commit`, `Schema.rollback` | `pubsub.schemas.commit`, `pubsub.schemas.rollback`, and `pubsub.schemas.get` for the read after a failed attempt |
| `Schema.delete`, `Schema.deleteRevision` | `pubsub.schemas.delete` |
| `Client.validateSchema`, both `validateMessage` | `pubsub.schemas.validate`, on the project |
| a topic's `schema` | `pubsub.schemas.attach` on the schema |

`roles/pubsub.editor` can do all of it but write IAM policies.
`roles/pubsub.viewer` can read, list and validate. A publisher and a
subscriber need none of it to publish and to receive; a subscriber that
reads a revision to decode by needs `pubsub.schemas.get`.

## What the emulator and production do

Measured on 2026-10-11, with emulator 0.8.36. The production column is
what Google documents: this project has not measured it yet.

| Behavior | Emulator | Production, as documented |
| --- | --- | --- |
| Avro schemas | served, and messages are checked for real, in both encodings | the same |
| Protocol Buffer schemas | every call that names one is `error.Unimplemented` | served |
| A schema's IAM calls | the read is `error.InvalidArgument` | the policy |
| A revision's time | in January 1970 | when it was made |
| A commit that is not compatible with the revisions before it | taken, if it parses | refused |
| A commit of the definition a schema already has | one more revision | not documented |
| Revisions in a list | oldest first | not documented |
| A list asked for no view | sends definitions; the client always says the view | leaves them out |
| A schema's only revision, deleted | `error.InvalidArgument` | refused |
| A topic's schema in an update | changed and cleared, though its page says topic updates are not supported | changed, within minutes |
| JSON with a field the schema does not have | taken | not documented |
| A publish to a topic whose schema is deleted | `error.NotFound` | fails |
