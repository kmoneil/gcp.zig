[Docs](../README.md) › [Pub/Sub](README.md) › Delivery

# Delivery

A subscription normally waits to be asked: something pulls, handles,
acknowledges. Pub/Sub can also do the delivering itself. A **push**
subscription POSTs each message to an HTTPS endpoint. A **BigQuery**
subscription writes each message as a row of a table. A **Cloud
Storage** subscription batches messages into files in a bucket.

`SubscriptionConfig.delivery` chooses, one kind at a time: `.pull` (the
default, and nothing to configure), `.push`, `.bigquery` or
`.cloud_storage`. The union makes "two at once" unwritable, which
production refuses anyway.

<!-- snippet: tests/docs_examples.zig#pubsub-delivery-create -->
```zig
/// Each message of `orders` as a row of `sales.orders`, with its id,
/// publish time, ordering key and attributes in columns of their own.
fn tableOfOrders(client: *pubsub.Client) !void {
    var rows = try client.subscription("orders-to-warehouse").create(.{
        .topic_id = "orders",
        .delivery = .{ .bigquery = .{ .table = "my-project.sales.orders", .write_metadata = true } },
    });
    defer rows.deinit();
}

/// Each message POSTed to the shop's webhook, signed as its service
/// account, the data alone as the body and the metadata in headers.
fn pushToWebhook(client: *pubsub.Client) !void {
    var hook = try client.subscription("orders-hook").create(.{
        .topic_id = "orders",
        .delivery = .{ .push = .{
            .endpoint = "https://shop.example/pubsub",
            .oidc_token = .{ .service_account_email = "pusher@my-project.iam.gserviceaccount.com" },
            .body = .{ .unwrapped = .{ .write_metadata = true } },
        } },
    });
    defer hook.deinit();
}
```

On a subscription that does not pull, `pull` and the lease calls are
`error.FailedPrecondition`, and a [`Subscriber`](subscribing.md) running
on one stops with that error and the server's words. Exactly-once
delivery is pull's alone: any other kind beside it is refused before
sending, as production refuses the pair. Ordering, filters, retry
policies and dead-letter topics work with every kind.

**On this page:** [Push](#push) · [BigQuery](#bigquery) ·
[Cloud Storage](#cloud-storage) · [Reading it back](#reading-it-back) ·
[Changing it](#changing-it) · [Checked before sending](#checked-before-sending) ·
[Permissions](#permissions) ·
[What the emulator and production do](#what-the-emulator-and-production-do)

## Push

`PushConfig` names a publicly reachable `https://` endpoint with a
certificate a public authority signed; no proof of owning the domain is
asked. Against an emulator `http://` is taken too, which is how a push
is tested locally.

- **Acknowledging.** The endpoint answers 102, 200, 201, 202 or 204 to
  acknowledge; any other status is a negative acknowledgment. The ack
  deadline is the request's timeout. Pub/Sub ramps deliveries up and
  down with the endpoint's answers; there are no lease calls to make.
- **The body**, with `.wrapped` (the default), is Pub/Sub's JSON
  envelope: a `message` object holding base64 `data`, `attributes`,
  `messageId` and `publishTime`, beside the full `subscription` name.
  With `.unwrapped` the body is the message's data alone, and
  `write_metadata` puts the id, publish time, ordering key and
  attributes into `x-goog-pubsub-*` headers.
- **`oidc_token`** signs each request as a service account, which the
  endpoint can verify from the `Authorization` header. The account must
  be in the subscription's project, the caller needs
  `iam.serviceAccounts.actAs` on it, and Pub/Sub's service agent must be
  allowed to mint its tokens. `audience` defaults to the endpoint's URL.

## BigQuery

`BigQueryConfig` names a table as `project.dataset.table` (a colon after
the project works too). Each message becomes a row; one that cannot be
written is nacked and retried, and a dead-letter policy catches what
never fits.

- **`schema`**: `.none` (the default) writes the message's data into a
  `data` column, which the table must have. `.topic` writes fields by
  the topic's schema, `.table` by the table's.
- **`write_metadata`** adds the subscription's name and the message's
  id, publish time, ordering key and attributes as columns.
- **`drop_unknown_fields`**, with `.topic`: fields the table lacks are
  dropped rather than refused.
- **`service_account_email`** writes as that account in place of
  Pub/Sub's service agent.

## Cloud Storage

`CloudStorageConfig` names a bucket, bare: no `gs://` and no path. A
file collects messages until a limit closes it; then the next begins.

- **Files are named** `<prefix><UTC date-time>_<uuid><suffix>`.
  `filename_datetime_format` reshapes the date-time part: each of a year
  (`YYYY` or `YY`), `MM`, `DD`, `hh`, `mm` and `ss` exactly once, in any
  order, with at most one `T`, at most one of `Z` and `+00:00`, and only
  `-`, `_`, `:` and `/` between them, so `YYYY-MM-DD/hh_mm_ssZ` makes a
  folder a day. A suffix must not end in `/`, and prefix and suffix
  together hold at most 992 characters.
- **A file closes** after `max_duration` (1 to 10 minutes, 5 by
  default), at `max_bytes` (1,000 bytes to 10 GiB) or at `max_messages`
  (1,000 or more), whichever comes first; 0 means no such limit.
- **`format`**: `.text` (the default) writes messages as they are,
  newline-separated. `.avro` writes Avro records, with `write_metadata`
  and `use_topic_schema` as for BigQuery.
- **`service_account_email`**, as for BigQuery.

## Reading it back

`SubscriptionInfo.delivery` is a `DeliveryInfo`: the same choices, and
for the export kinds also the server's word on whether it can write.

- **`ExportState`**: `.active`, or why not: `.permission_denied`,
  `.not_found`, `.schema_mismatch` or `.location_restriction`. The
  subscription's own `state` reads `.resource_error` meanwhile, and its
  messages wait in the backlog. The emulator never sends a state, which
  reads `.unknown`.
- **`.other`** is a kind this client does not model, a Bigtable
  subscription today: it lists and reads without failing, and
  [Changing it](#changing-it) can still turn it into a kind this client
  knows.

## Changing it

`SubscriptionUpdate.delivery` replaces the delivery whole, whatever the
subscription was: one request, no read first. `.pull` clears whichever
kind was set.

<!-- snippet: tests/docs_examples.zig#pubsub-delivery-update -->
```zig
/// Stop pushing, and pull instead. Google says the switch away from
/// push can take minutes to settle.
fn pullInstead(client: *pubsub.Client) !void {
    var pulled = try client.subscription("orders-hook").update(.{ .delivery = .pull });
    defer pulled.deinit();
}

/// Rotate the webhook's address. The config is replaced whole, so it
/// names everything it keeps, the token among it.
fn moveWebhook(client: *pubsub.Client) !void {
    var moved = try client.subscription("orders-hook").update(.{ .delivery = .{ .push = .{
        .endpoint = "https://shop2.example/pubsub",
        .oidc_token = .{ .service_account_email = "pusher@my-project.iam.gserviceaccount.com" },
    } } });
    defer moved.deinit();
}
```

A config is replaced, never merged: an update that names only the
endpoint also clears the token and the body option. Setting a delivery
beside `enable_exactly_once_delivery = true` in one update is refused
before sending; to leave exactly-once, one update can do both, since
`.pull` is where exactly-once is allowed. On an emulator only push and
pull can be set: see
[the table below](#what-the-emulator-and-production-do).

## Checked before sending

The emulator checks almost none of this, so the client holds code tested
against it to production's measured rules (2026-10-10), failing with
`error.InvalidArgument` and the reason in `Diagnostics`:

- a push endpoint that is not `https://`, or `http://` only against an
  emulator;
- any kind but `.pull` beside exactly-once delivery, on create or set
  together in one update;
- a BigQuery table that is not `project.dataset.table` or
  `project:dataset.table`;
- a bucket with a scheme, a slash or whitespace. Production answers such
  a name as a **503 outage**, which a client would retry and then report
  as `error.Unavailable` with nothing naming the true cause;
- a filename suffix ending in `/`, control characters in either part,
  prefix and suffix over 992 characters together, and a datetime format
  off the rules above;
- file batching bounds outside 1 to 10 minutes, 1,000 bytes to 10 GiB,
  or under 1,000 messages;
- a service account not of the shape of an address.

Whether the table, the bucket or the account exists, what the service
agent may do, and whether a schema fits are the server's alone: those
answers come back as `error.PermissionDenied` (BigQuery says no more
than "the caller does not have permission" for a missing table),
`error.FailedPrecondition` (Cloud Storage names the service agent and
the two roles it wants) or `error.InvalidArgument`.

## Permissions

| Doing | Needs |
| --- | --- |
| Creating or changing a delivery | `pubsub.subscriptions.create` or `.update`, as for any subscription |
| Push with `oidc_token` | `iam.serviceAccounts.actAs` on the account, for the caller; `roles/iam.serviceAccountTokenCreator` on it, for Pub/Sub's service agent |
| BigQuery writes | `roles/bigquery.dataEditor` on the table, for the service agent (or for `service_account_email`) |
| Cloud Storage writes | `roles/storage.objectCreator` and `roles/storage.legacyBucketReader` on the bucket, likewise |

Pub/Sub's service agent is
`service-{project number}@gcp-sa-pubsub.iam.gserviceaccount.com`. A
grant missing at create time refuses a Cloud Storage create outright,
and shows up on a BigQuery subscription as its `state`.

## What the emulator and production do

Measured on 2026-10-10, with emulator 0.8.36. The client's own checks
catch the ones marked *checked*.

| Behavior | Emulator | Production |
| --- | --- | --- |
| An `http://` push endpoint | taken, and its page advises it for local tests | refused (*checked*: taken only against an emulator) |
| A push subscription delivers | yes, to a loopback listener too, wrapped and unwrapped alike | yes |
| An OIDC account that is not there | taken | refused |
| Any kind but pull with exactly-once delivery | taken | refused (*checked*) |
| Two kinds in one create | taken, both kept | refused (*checked*: the union cannot write it) |
| A malformed table, datetime format or batching bound | taken | refused (*checked*) |
| A bucket named with `gs://` or a slash | taken | **503 UNAVAILABLE**, as an outage (*checked*) |
| An export kind | stored and read back; nothing is delivered | delivered |
| An export config's `state` | never sent: `.unknown` | `ACTIVE`, or why not |
| `pull` on a push subscription | 200 and nothing, forever | `error.FailedPrecondition` |
| Updating the delivery | push and pull only: the export kinds' mask paths are "not a known Subscription field" (*checked*: refused before sending, a read first catching a change away from one) | any kind to any kind, replaced whole |
| A Bigtable subscription | 400, an unknown field | reads as `.other` |
