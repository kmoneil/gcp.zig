[Docs](../README.md) › [Pub/Sub](README.md) › Import topics

# Import topics

A topic can fill itself. An **import topic** names a source outside
Pub/Sub, and Pub/Sub reads the source and publishes what it finds: the
lines of a bucket's objects, the records of a Kinesis stream, the
events of an Azure event hub, the messages of a Kafka topic on Amazon
MSK or Confluent Cloud. Subscriptions of it are ordinary subscriptions.

**On this page:** [From a bucket](#from-a-bucket) ·
[From another cloud](#from-another-cloud) ·
[Whether it is importing](#whether-it-is-importing) ·
[Changing and stopping](#changing-and-stopping) ·
[What is checked before sending](#what-is-checked-before-sending) ·
[What the emulator and production do](#what-the-emulator-and-production-do)

## From a bucket

<!-- snippet: tests/docs_examples.zig#pubsub-import-bucket -->
```zig
/// A topic that fills itself from a bucket: each new object's lines
/// become messages. Pub/Sub's service agent must be able to read the
/// bucket, or the create is refused.
fn importUploads(client: *pubsub.Client) !void {
    var topic = try client.topic("uploads").create(.{
        .ingestion = .{ .source = .{ .cloud_storage = .{
            .bucket = "my-uploads",
            .match_glob = "incoming/**.txt",
        } } },
    });
    defer topic.deinit();
}
```

`TopicConfig.ingestion` holds one source and the severity of the logs
Pub/Sub writes about it. For a bucket, `CloudStorageSource`:

| Field | What it says |
| --- | --- |
| `bucket` | The bucket's name alone. Production also takes it with `gs://` before it, and reads it back without. |
| `format` | `.text`, a message a line, or between another `delimiter`, which is one character of one byte, such as a tab; `.avro`, a message a record of an Avro file; `.pubsub_avro`, files as a [Cloud Storage subscription](delivery.md) writes Avro, data and attributes together. Text unless said. |
| `minimum_object_create_time` | Only objects made at or after it. All when null. |
| `match_glob` | Only objects whose names match. All when empty. |

- **What is imported.** Measured on 2026-10-12: every object the glob
  matches, the ones already there when the topic starts importing
  among them, and an object written again is imported again. A last
  line with no newline after it is a message too. Lines that are not
  text arrive as the bytes they were. Messages carry no attributes. The
  first lines arrived 73 seconds after the topic was made to import,
  and a later object's about a minute after its upload.
- **Pub/Sub reads as its own service agent**,
  `service-{project number}@gcp-sa-pubsub.iam.gserviceaccount.com`,
  which needs two things:
  - *To read the bucket*: `storage.buckets.get`, `storage.objects.list`
    and `storage.objects.get`, by Google's description. Without the
    last of them the create was `error.PermissionDenied`, naming the
    permission.
  - *To publish to the topic*: `roles/pubsub.publisher` on it, which
    `Topic.addIamBinding` grants. **Without it the topic is made all the
    same**, reading `.active`, and imports nothing: within minutes its
    state reads `.publish_permission_denied`. So read the state after a
    while, not only the create's answer.
- **The source is checked when the topic is made, and when it is
  changed.** Production connects to it there and then, and a bucket
  that is not there refuses the create or the update as
  `error.NotFound`, naming the bucket.
- **Google's limit** is 50 million objects in a bucket. Past it the
  source's state is `.too_many_objects`, and importing pauses.

## From another cloud

The four other sources read a stream or a Kafka topic that lives on
AWS, Azure or Confluent Cloud. Each is a struct of what that side calls
the thing, and all of each is required:

| Source | Fields |
| --- | --- |
| `.aws_kinesis` (`AwsKinesis`) | `stream_arn`, `consumer_arn`, `aws_role_arn`, `gcp_service_account` |
| `.azure_event_hubs` (`AzureEventHubs`) | `resource_group`, `namespace`, `event_hub`, `client_id`, `tenant_id`, `subscription_id`, `gcp_service_account` |
| `.aws_msk` (`AwsMsk`) | `cluster_arn`, `topic`, `aws_role_arn`, `gcp_service_account` |
| `.confluent_cloud` (`ConfluentCloud`) | `bootstrap_server`, `cluster_id`, `topic`, `identity_pool_id`, `gcp_service_account` |

- **`gcp_service_account`** is the account Pub/Sub presents itself as
  to the other cloud, which must trust it: a role it may assume on AWS,
  an app registration on Azure, an identity pool on Confluent Cloud.
  That side is set up there, by Google's page for each source. The
  caller needs to be able to act as the account.
- **A source Pub/Sub cannot reach refuses the create**, as a bucket
  does. Measured in production with made-up names: a role Pub/Sub may
  not assume is `error.PermissionDenied`, an Event Hubs namespace that
  does not resolve is `error.NotFound`, and a Confluent server it cannot
  reach is `error.InvalidArgument`. No account on another cloud was used
  to test this client, so no import from one has been watched end to
  end.

## Whether it is importing

<!-- snippet: tests/docs_examples.zig#pubsub-import-state -->
```zig
/// Is the topic still importing? `null` for a topic that is not an
/// import topic at all.
fn importing(client: *pubsub.Client) !?pubsub.IngestionState {
    var topic = try client.topic("uploads").get();
    defer topic.deinit();
    const settings = topic.value.ingestion orelse return null;
    return settings.state;
}
```

`TopicInfo.ingestion` is null for a standard topic. For an import topic
it is an `IngestionInfo`: the source as it was given, the log severity,
and the server's word on the source, one `IngestionState` for all five:

| State | Means | Said of |
| --- | --- | --- |
| `.active` | Pub/Sub is importing | every source |
| `.permission_denied` | Pub/Sub may not read the source | every source |
| `.publish_permission_denied` | Pub/Sub's service agent may not publish to the topic | every source |
| `.conflicting_region_constraints` | the region Pub/Sub would import in is one the project's service account is not allowed | every source |
| `.bucket_not_found`, `.too_many_objects` | | a bucket |
| `.stream_not_found`, `.consumer_not_found` | | Kinesis |
| `.namespace_not_found`, `.event_hub_not_found`, `.subscription_not_found`, `.resource_group_not_found` | | Event Hubs |
| `.cluster_not_found`, `.topic_not_found` | | MSK and Confluent Cloud |
| `.unreachable_bootstrap_server` | | Confluent Cloud |
| `.unknown` | a word this client does not know, or none | the emulator sends none |

While the state is anything but `.active`, the topic's own
`TopicInfo.state` is `.ingestion_resource_error`. A source this client
does not model reads as an `IngestionInfo` whose `source` is null: the
topic is an import topic still.

**Logs.** `Ingestion.log_severity` has Pub/Sub write what happens at the
source to Cloud Logging, at that severity and above: `.debug`, `.info`,
`.warning` or `.@"error"`. The default, `.disabled`, writes nothing.

## Changing and stopping

<!-- snippet: tests/docs_examples.zig#pubsub-import-update -->
```zig
/// The same bucket, read as Avro from now on, with warnings logged. The
/// settings are replaced whole, so they name everything they keep.
fn importAvro(client: *pubsub.Client) !void {
    var changed = try client.topic("uploads").update(.{ .ingestion = .{ .set = .{
        .source = .{ .cloud_storage = .{ .bucket = "my-uploads", .format = .avro } },
        .log_severity = .warning,
    } } });
    defer changed.deinit();
}

/// A standard topic again: it keeps what it holds, and imports no more.
fn stopImporting(client: *pubsub.Client) !void {
    var standard = try client.topic("uploads").update(.{ .ingestion = .clear });
    defer standard.deinit();
}
```

- **`.set` replaces the settings whole.** What is left out goes back to
  its default: a source set without a `log_severity` logs nothing,
  whatever it logged before.
- **`.clear` makes a standard topic.** And a standard topic becomes an
  import topic by a `.set`.
- **An import topic takes a publish** like any topic: a message
  published by hand arrives beside the imported ones.

## What is checked before sending

`error.InvalidArgument`, with the reason in `Diagnostics`:

- every field a source requires is there, and is UTF-8;
- a bucket is a name alone, with nothing but `gs://` before it and no
  path after it;
- a text delimiter is one character of one byte;
- an ARN begins `arn:`;
- a `gcp_service_account` has the shape of an address;
- a `minimum_object_create_time` is a time a timestamp can hold;
- the severity is not `.unknown`, which is only ever read.

Two sources at once cannot be written: the source is a union. The rest
is the server's to say, since only it can reach the source.

## What the emulator and production do

Measured on 2026-10-12, in production and with emulator 0.8.36, with a
throwaway bucket the service agent was granted. No account on another
cloud was used, so for those four sources the production column is
what it refuses. The client's own checks catch the ones marked
*checked*.

| Behavior | Emulator | Production |
| --- | --- | --- |
| A source nobody can reach | **kept, and read back as given** | the create or the update is refused: `error.PermissionDenied`, `error.NotFound` or `error.InvalidArgument`, by what failed |
| The source's state | none: reads as `.unknown` | `.active` on create; `.publish_permission_denied` minutes later when the agent is no publisher of the topic |
| Importing | nothing is imported | a bucket's lines arrive, about a minute after an upload |
| A bucket written with `gs://` | kept as written | taken, and read back as the name alone |
| A bucket with a path after it | kept | `error.InvalidArgument`, "not a valid resource name" (*checked*) |
| A Cloud Storage source with no format | `error.InvalidArgument`; the client always sends one | text, a message a line |
| A text delimiter of two characters | `error.InvalidArgument`, "must be a single character" | `error.FailedPrecondition`, which says the same (*checked*) |
| A text delimiter of one wide character, such as `é` | taken | `error.FailedPrecondition`: one byte is all it takes (*checked*) |
| A source with a field left out | `error.InvalidArgument`, naming every one (*checked*) | `error.FailedPrecondition`, naming one (*checked*) |
| An update: another source; no word on logs; a clear | replaced whole; logs off; a standard topic | the same |
| A publish to an import topic | taken | taken |

[Development](../development.md#an-import-topic-against-google) says how
to run the test that watches an import in production.
