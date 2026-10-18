//! Public data types: messages, call options, results and configs. Results
//! come wrapped in core's `Owned`, re-exported here.

const std = @import("std");

pub const Owned = @import("core").Owned;

pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

/// A message to publish. It needs non-empty `data` or at least one attribute.
pub const Message = struct {
    /// Raw bytes. The library does the base64.
    data: []const u8 = "",
    /// Keys must be unique. Keys and values must be valid UTF-8.
    attributes: []const Attribute = &.{},
};

pub const PublishOptions = struct {
    /// Messages with the same key reach subscriptions that enable message
    /// ordering in publish order. Every message in one call shares the key.
    ordering_key: ?[]const u8 = null,
    /// Null sends the request body as it is.
    compression: ?Compression = null,
};

/// gzip for publish requests, as Google's own clients offer it. Pub/Sub
/// bills the messages uncompressed, so this saves bandwidth between the
/// publisher and Google, not Pub/Sub's charges, at some CPU: about 10 ms
/// per MB of JSON body at level 6 in ReleaseFast, the check included.
pub const Compression = struct {
    /// 1 (fastest) to 9 (smallest).
    level: u4 = 6,
    /// Request bodies shorter than this go as they are. Google's libraries
    /// compress from 240 bytes of messages; this counts the JSON body,
    /// which base64 makes a third bigger.
    min_bytes: u32 = 240,
};

pub const PublishResult = struct {
    /// Server-assigned ids, in the order of the published messages.
    message_ids: []const []const u8,
};

/// The request `Topic.publish` sends, built without sending it: see
/// `Topic.publishRequest`.
pub const PublishRequest = struct {
    /// Always POST.
    method: @import("core").transport.Method,
    /// The whole URL, the client's endpoint included.
    url: []const u8,
    /// The JSON body before any compression: byte for byte what `publish`
    /// sends uncompressed, and what a compressed one decompresses to.
    body: []const u8,
    /// Whether `publish` sends `body` gzip-compressed, with
    /// `Content-Encoding: gzip`: compression asked for, and a body of at
    /// least its `min_bytes`.
    gzip: bool,
};

pub const PageOptions = struct {
    /// Results per page. 0 lets the server choose.
    page_size: u32 = 100,
    /// `next_page_token` from the previous page; null for the first page.
    page_token: ?[]const u8 = null,
};

pub const PullOptions = struct {
    /// Clamped to 1..1000.
    max_messages: u32 = 100,
    /// Return at once when no messages are available. Otherwise the server may
    /// hold an empty pull open for a while (about 90 seconds on the emulator).
    /// Google discourages setting this in production because it hurts
    /// delivery throughput.
    return_immediately: bool = false,
};

pub const PullResult = struct {
    messages: []const ReceivedMessage,
};

pub const ReceivedMessage = struct {
    /// Opaque. Pass it to `ack`, `nack` or `modifyAckDeadline` byte for byte.
    ack_id: []const u8,
    message_id: []const u8,
    /// Already decoded from base64.
    data: []const u8,
    /// In the order the server sent them.
    attributes: []const Attribute,
    /// RFC 3339, as sent by the server. `pubsub.parseTimestamp` converts it.
    publish_time: []const u8,
    /// "" when the message has none.
    ordering_key: []const u8,
    /// 0 when the server omits it, which it does unless the subscription has
    /// a dead-letter policy.
    delivery_attempt: u32,

    /// The value of the attribute named `key`, or null.
    pub fn attribute(self: ReceivedMessage, key: []const u8) ?[]const u8 {
        for (self.attributes) |a| {
            if (std.mem.eql(u8, a.key, key)) return a.value;
        }
        return null;
    }

    /// What a topic with a schema wrote on the message when it took it:
    /// the schema, the revision the message fit, and the encoding, which
    /// says how to decode `data`. Null when the message has no such
    /// attributes, as one from a topic with no schema has none.
    ///
    /// They are attributes, and only as trustworthy as the topic. This
    /// client refuses to publish a key that starts with `goog`, but
    /// Pub/Sub takes the three `googclient_schema...` keys from any
    /// publisher (measured 2026-10-12): on a topic with no schema they
    /// arrive as the publisher wrote them, and on a topic with one the
    /// encoding and the revision are overwritten and the name is not. So
    /// rely on this for a topic known to have a schema, and take the
    /// schema's name from the topic, not from the message.
    pub fn schema(self: ReceivedMessage) ?MessageSchema {
        const encoding = self.attribute("googclient_schemaencoding") orelse return null;
        return .{
            .name = self.attribute("googclient_schemaname") orelse "",
            .revision_id = self.attribute("googclient_schemarevisionid") orelse "",
            .encoding = if (std.mem.eql(u8, encoding, "JSON"))
                .json
            else if (std.mem.eql(u8, encoding, "BINARY"))
                .binary
            else
                .unknown,
        };
    }
};

/// What `ReceivedMessage.schema` reads.
pub const MessageSchema = struct {
    /// `projects/{project}/schemas/{id}`.
    name: []const u8,
    /// The revision the message was found to fit: read it with
    /// `Schema.get(.{ .revision_id = ... })` to decode the message as it
    /// was written.
    revision_id: []const u8,
    encoding: SchemaEncoding,
};

/// A label on a topic, subscription or snapshot.
pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// What an update does to a setting that can be taken away: `.keep`,
/// `.set`, or `.clear`, which takes it away or puts back Pub/Sub's
/// default, as each field says. Core's, shared with the other modules.
pub const Change = @import("core").Change;

/// Where a topic's messages may be stored.
pub const MessageStoragePolicy = struct {
    /// Region ids, such as `europe-west1`. At least one.
    allowed_persistence_regions: []const []const u8,
    /// Refuse publishes and pulls in other regions instead of routing them.
    enforce_in_transit: bool = false,
};

/// Topic settings.
pub const TopicConfig = struct {
    /// At most 64. Keys: 1 to 63 characters, lowercase letters, digits,
    /// `_`, `-` or international characters, starting with a letter or an
    /// international character. Values: up to 63 of the same.
    labels: []const Label = &.{},
    /// Keep every message, acknowledged or not, for 10 minutes to 31 days,
    /// so subscriptions can replay them. Null: none.
    message_retention: ?std.Io.Duration = null,
    /// `projects/{p}/locations/{l}/keyRings/{r}/cryptoKeys/{k}`: encrypt
    /// messages with this Cloud KMS key. Null: Google's own keys.
    kms_key_name: ?[]const u8 = null,
    /// Null: the organization's policy.
    message_storage_policy: ?MessageStoragePolicy = null,
    /// Every message published to the topic must fit this schema. Null:
    /// the topic takes any bytes.
    schema: ?SchemaSettings = null,
    /// Run on every message published to the topic, in this order, before
    /// its schema is checked and before it is stored. At most 5 that are
    /// not disabled.
    message_transforms: []const MessageTransform = &.{},
    /// Makes an import topic: one that fills itself from a source outside
    /// Pub/Sub. Production connects to the source when the topic is made,
    /// and refuses the create if it cannot. Null: a standard topic.
    ingestion: ?Ingestion = null,
    /// Resource Manager tags to bind as the topic is made. At most 50.
    tags: []const Tag = &.{},
};

pub const TopicInfo = struct {
    /// Full resource name: `projects/{project}/topics/{id}`.
    name: []const u8,
    labels: []const Label = &.{},
    message_retention: ?std.Io.Duration = null,
    kms_key_name: ?[]const u8 = null,
    message_storage_policy: ?MessageStoragePolicy = null,
    /// Null: the topic has no schema.
    schema: ?SchemaSettings = null,
    /// In the order they run.
    message_transforms: []const MessageTransform = &.{},
    /// Null: a standard topic.
    ingestion: ?IngestionInfo = null,
    state: State = .active,

    /// An unrecognized value from the server is `.unknown`.
    pub const State = enum { active, ingestion_resource_error, unknown };

    /// The value of the label named `key`, or null.
    pub fn label(self: TopicInfo, key: []const u8) ?[]const u8 {
        return findLabel(self.labels, key);
    }
};

/// What `Topic.update` changes. A field left at its default stays as it is.
pub const TopicUpdate = struct {
    /// Replaces every label; `&.{}` removes them all.
    labels: ?[]const Label = null,
    /// `.clear`: the topic keeps nothing itself.
    message_retention: Change(std.Io.Duration) = .keep,
    /// `.clear`: back to Google's own keys. Messages already stored keep
    /// the key they were written with.
    kms_key_name: Change([]const u8) = .keep,
    /// `.clear`: back to the organization's policy.
    message_storage_policy: Change(MessageStoragePolicy) = .keep,
    /// `.set` replaces the settings whole: the encoding and the revisions
    /// are then what is given, and a bound left null is open. `.clear`:
    /// the topic takes any bytes again.
    schema: Change(SchemaSettings) = .keep,
    /// Replaces the whole list; `&.{}` removes every transform. Pub/Sub
    /// says a change takes a few minutes to hold.
    message_transforms: ?[]const MessageTransform = null,
    /// `.set` replaces the settings whole: what is left out goes back to
    /// its default. `.clear`: a standard topic again.
    ingestion: Change(Ingestion) = .keep,
};

pub const TopicPage = struct {
    topics: []const TopicInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// Where a message goes after too many deliveries.
pub const DeadLetterPolicy = struct {
    /// A topic id in this project, or `projects/{project}/topics/{id}` for
    /// another project's. It must exist, and Pub/Sub's service agent must
    /// be allowed to publish to it and to acknowledge on this subscription,
    /// or nothing is forwarded (see docs/pubsub/topics-and-subscriptions.md).
    topic: []const u8,
    /// 5 to 100.
    max_delivery_attempts: u8 = 5,
};

/// Pub/Sub's retry policy, named apart from `pubsub.RetryPolicy`, which is
/// this client's own: how long Pub/Sub waits before delivering a message
/// again after a release or a lapsed deadline.
pub const Backoff = struct {
    /// 0 to 600 seconds.
    minimum: std.Io.Duration = .fromSeconds(10),
    /// `minimum` to 600 seconds.
    maximum: std.Io.Duration = .fromSeconds(600),
};

/// When a subscription nobody uses is deleted.
pub const Expiration = union(enum) {
    /// After 31 days, Pub/Sub's default.
    default,
    never,
    /// At least a day, and at least the subscription's message retention.
    after: std.Io.Duration,
};

/// How a subscription's messages are handed over: the subscriber pulls, or
/// Pub/Sub itself POSTs each message to an endpoint, writes it as a row of
/// a BigQuery table, or batches messages into files in a Cloud Storage
/// bucket. One kind at a time, chosen at creation and changeable by update.
pub const Delivery = union(enum) {
    /// The subscriber asks for messages, as `pull` and `Subscriber` do.
    pull,
    push: PushConfig,
    bigquery: BigQueryConfig,
    cloud_storage: CloudStorageConfig,
};

pub const PushConfig = struct {
    /// Where each message is POSTed: an `https://` URL. On an emulator
    /// endpoint `http://` works too, which is how a push is tested locally.
    endpoint: []const u8,
    /// Signs each request as this service account, which the endpoint
    /// can verify. Null sends no `Authorization` header.
    oidc_token: ?OidcToken = null,
    body: Body = .wrapped,

    pub const Body = union(enum) {
        /// Pub/Sub's JSON envelope around the message.
        wrapped,
        /// The message's data alone.
        unwrapped: struct {
            /// Its id, publish time, ordering key and attributes as
            /// `x-goog-pubsub-*` headers.
            write_metadata: bool = false,
        },
    };
};

pub const OidcToken = struct {
    /// An account in the subscription's project. The caller needs
    /// `iam.serviceAccounts.actAs` on it.
    service_account_email: []const u8,
    /// What the token is for. Empty: the endpoint's URL.
    audience: []const u8 = "",
};

pub const BigQueryConfig = struct {
    /// `project.dataset.table`, or with `:` after the project.
    table: []const u8,
    /// `.none` needs the table to have a `data` column.
    schema: Schema = .none,
    /// Write the message's id, publish time, ordering key and attributes
    /// into columns of their own.
    write_metadata: bool = false,
    /// With `.topic`: fields the table lacks are dropped rather than
    /// refused.
    drop_unknown_fields: bool = false,
    /// Writes as this account in place of Pub/Sub's service agent.
    service_account_email: ?[]const u8 = null,

    pub const Schema = enum { none, topic, table };
};

pub const CloudStorageConfig = struct {
    /// The bucket's name alone, no `gs://`.
    bucket: []const u8,
    filename_prefix: []const u8 = "",
    /// Must not end in `/`.
    filename_suffix: []const u8 = "",
    /// Such as `YYYY-MM-DD/hh_mm_ssZ`. Empty: Pub/Sub's default.
    filename_datetime_format: []const u8 = "",
    format: Format = .text,
    /// A file is closed after this long, 1 to 10 minutes. Null: 5.
    max_duration: ?std.Io.Duration = null,
    /// Or at this many bytes, 1,000 to 10 GiB. 0: no such limit.
    max_bytes: u64 = 0,
    /// Or at this many messages, 1,000 or more. 0: no such limit.
    max_messages: u64 = 0,
    /// Writes as this account in place of Pub/Sub's service agent.
    service_account_email: ?[]const u8 = null,

    pub const Format = union(enum) {
        /// Messages as they are, newline-separated.
        text,
        avro: struct { write_metadata: bool = false, use_topic_schema: bool = false },
    };
};

/// What `SubscriptionInfo.delivery` reads: the config and, for the export
/// kinds, the server's word on whether it can write. When an export
/// cannot, the subscription's own `state` reads `.resource_error` and its
/// messages wait in the backlog.
pub const DeliveryInfo = union(enum) {
    pull,
    push: PushConfig,
    bigquery: struct { config: BigQueryConfig, state: ExportState },
    cloud_storage: struct { config: CloudStorageConfig, state: ExportState },
    /// A kind this client does not model, such as a Bigtable subscription.
    other,
};

/// `.unknown` when the server says nothing, as the emulator does, or says
/// something new.
pub const ExportState = enum { active, permission_denied, not_found, schema_mismatch, location_restriction, unknown };

pub const SubscriptionConfig = struct {
    /// Id of a topic in the same project.
    topic_id: []const u8,
    /// Any kind but `.pull` refuses exactly-once delivery, and only
    /// `.pull` answers `pull` and lease calls.
    delivery: Delivery = .pull,
    /// 10 to 600 seconds, or 0 for Pub/Sub's default: 10, or 60 with
    /// exactly-once delivery.
    ack_deadline_seconds: u32 = 0,
    enable_message_ordering: bool = false,
    /// A message acknowledged before its deadline is never delivered
    /// again, and an acknowledgement that comes too late is refused rather
    /// than taken, so a subscriber can tell which of its acks held. Pull
    /// subscriptions only.
    enable_exactly_once_delivery: bool = false,
    /// Delivers only messages whose attributes match, such as
    /// `attributes.kind = "order"`; the rest are acknowledged unseen. At
    /// most 256 bytes; "" delivers everything. Fixed once created.
    filter: []const u8 = "",
    dead_letter_policy: ?DeadLetterPolicy = null,
    /// Null delivers again as soon as possible.
    retry_policy: ?Backoff = null,
    /// How long unacknowledged messages are kept: 10 minutes to 31 days.
    /// Null means Pub/Sub's default, 7 days.
    message_retention: ?std.Io.Duration = null,
    /// Keep acknowledged messages for the retention too, for replay.
    retain_acked_messages: bool = false,
    expiration: Expiration = .default,
    /// As for `TopicConfig.labels`.
    labels: []const Label = &.{},
    /// Run on every message on its way to a subscriber, in this order,
    /// after the filter. At most 5 that are not disabled.
    message_transforms: []const MessageTransform = &.{},
    /// Resource Manager tags to bind as the subscription is made. At most
    /// 50.
    tags: []const Tag = &.{},
};

pub const SubscriptionInfo = struct {
    /// Full resource name: `projects/{project}/subscriptions/{id}`.
    name: []const u8,
    /// Full topic name, or `_deleted-topic_` after the topic was deleted.
    topic: []const u8,
    delivery: DeliveryInfo = .pull,
    ack_deadline_seconds: u32,
    enable_message_ordering: bool,
    enable_exactly_once_delivery: bool = false,
    /// "" when there is none.
    filter: []const u8 = "",
    /// Its topic is a full name.
    dead_letter_policy: ?DeadLetterPolicy = null,
    retry_policy: ?Backoff = null,
    /// Null when the server says nothing, as the emulator may not.
    message_retention: ?std.Io.Duration = null,
    retain_acked_messages: bool = false,
    expiration: Expiration = .default,
    labels: []const Label = &.{},
    /// Detached from its topic: pulls fail and nothing more is delivered.
    detached: bool = false,
    state: State = .active,
    /// Set when the topic keeps messages itself.
    topic_message_retention: ?std.Io.Duration = null,
    /// In the order they run.
    message_transforms: []const MessageTransform = &.{},

    /// An unrecognized value from the server is `.unknown`.
    pub const State = enum { active, resource_error, unknown };

    /// The value of the label named `key`, or null.
    pub fn label(self: SubscriptionInfo, key: []const u8) ?[]const u8 {
        return findLabel(self.labels, key);
    }
};

/// What `Subscription.update` changes. A field left at its default stays as
/// it is. The topic, the ordering and the filter cannot be changed.
pub const SubscriptionUpdate = struct {
    /// Replaces the delivery whole, whatever it was: one request, no read
    /// first, and `.pull` clears any kind. On an emulator only push and
    /// pull work: the emulator refuses the export kinds' mask paths, so a
    /// change to or from one is refused here before sending.
    delivery: ?Delivery = null,
    /// 10 to 600.
    ack_deadline_seconds: ?u32 = null,
    enable_exactly_once_delivery: ?bool = null,
    /// `.clear`: no dead-lettering.
    dead_letter_policy: Change(DeadLetterPolicy) = .keep,
    /// `.clear`: deliver again as soon as possible.
    retry_policy: Change(Backoff) = .keep,
    /// `.clear`: back to 7 days.
    message_retention: Change(std.Io.Duration) = .keep,
    retain_acked_messages: ?bool = null,
    expiration: ?Expiration = null,
    /// Replaces every label; `&.{}` removes them all.
    labels: ?[]const Label = null,
    /// Replaces the whole list; `&.{}` removes every transform. Pub/Sub
    /// says a change takes a few minutes to hold.
    message_transforms: ?[]const MessageTransform = null,
};

fn findLabel(labels: []const Label, key: []const u8) ?[]const u8 {
    for (labels) |l| {
        if (std.mem.eql(u8, l.key, key)) return l.value;
    }
    return null;
}

/// What became of one ack id sent to `acknowledge` or `modifyAckDeadline`.
pub const AckResult = enum {
    /// The server took it.
    ok,
    /// Refused for good: the lease had lapsed, the message was already
    /// acknowledged, or the id is not one this subscription gave. Only a
    /// subscription with exactly-once delivery refuses these; the message
    /// may be delivered again.
    invalid_ack_id,
    /// Refused for now, and still refused when the call's retries ran out.
    /// Sending it again later may succeed.
    transient,
    /// Refused for another reason, or its request failed as a whole with an
    /// answer that says nothing about single ids. `Diagnostics` has the
    /// server's words.
    other,
};

/// What a `Subscriber.Delivery`'s ack or release came to, as the server
/// answered it.
pub const AckOutcome = enum {
    /// The server took it. With exactly-once delivery, an acknowledged
    /// message is not delivered again.
    taken,
    /// Refused for good: the lease had lapsed, or the server had refused to
    /// extend it. The message may come again.
    refused,
    /// No answer said either: refusals for now outlasted the retries, the
    /// request failed in a way that names no message, or the subscriber
    /// stopped first. The message may come again.
    unknown,
};

pub const SubscriptionPage = struct {
    subscriptions: []const SubscriptionInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// Where `Subscription.seek` takes a subscription.
pub const SeekTarget = union(enum) {
    /// The messages the subscription holds that were published before
    /// this time become acknowledged, and those published after it
    /// unacknowledged. A time ahead of now purges what it holds.
    time: std.Io.Timestamp,
    /// A snapshot of the subscription's topic: an id in the client's
    /// project, or `projects/{project}/snapshots/{id}`.
    snapshot: []const u8,
};

/// What `Snapshot.create` keeps, and under which labels.
pub const SnapshotConfig = struct {
    /// The subscription whose backlog the snapshot keeps: an id in the
    /// client's project, or `projects/{project}/subscriptions/{id}`.
    subscription: []const u8,
    /// The emulator keeps none.
    labels: []const Label = &.{},
    /// Resource Manager tags to bind as the snapshot is made. At most 50.
    tags: []const Tag = &.{},
};

/// A snapshot as the server describes it.
pub const SnapshotInfo = struct {
    /// `projects/{project}/snapshots/{id}`.
    name: []const u8,
    /// The topic whose messages it keeps, in full. `_deleted-topic_` once
    /// that topic is deleted, which the snapshot outlives.
    topic: []const u8,
    /// The snapshot is there until then: at most 7 days from its creation,
    /// less the age of the oldest message its subscription held.
    expire_time: std.Io.Timestamp,
    labels: []const Label = &.{},

    /// The value of the label named `key`, or null.
    pub fn label(self: SnapshotInfo, key: []const u8) ?[]const u8 {
        return findLabel(self.labels, key);
    }
};

/// What `Snapshot.update` changes: the labels, which are all Pub/Sub lets
/// a snapshot change.
pub const SnapshotUpdate = struct {
    /// Replaces every label; `&.{}` removes them all.
    labels: ?[]const Label = null,
};

pub const SnapshotPage = struct {
    snapshots: []const SnapshotInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// One page of full resource names, such as
/// `projects/{project}/subscriptions/{id}`. What is attached to a topic
/// may lie in another project than the topic.
pub const NamePage = struct {
    names: []const []const u8,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// The language a schema is written in. An unrecognized value from the
/// server is `.unknown`, which is only ever read.
pub const SchemaType = enum { avro, protocol_buffer, unknown };

/// A schema as it is written: what `Schema.create` stores and
/// `Client.validateSchema` checks.
pub const SchemaDefinition = struct {
    type: SchemaType,
    /// The Avro schema as JSON, or the `.proto` source, which must begin
    /// with a `syntax` or `edition` statement and hold one top-level
    /// message and no imports. Valid UTF-8, at most 300 KB.
    definition: []const u8,
};

/// One revision of a schema, as the server describes it.
pub const SchemaInfo = struct {
    /// `projects/{project}/schemas/{id}`: the schema's own name, without
    /// the `@revision` production writes after it in some answers.
    name: []const u8,
    type: SchemaType,
    /// "" in the basic view.
    definition: []const u8,
    /// Eight characters the server chose, such as `c7cfa2a8`. "" when it
    /// sends none.
    revision_id: []const u8,
    /// Null when the server sends none. The emulator's is in January 1970.
    revision_create_time: ?std.Io.Timestamp,
};

/// How much of a schema an answer carries.
pub const SchemaView = enum {
    /// Without the definition.
    basic,
    full,
};

pub const SchemaGetOptions = struct {
    /// Null: the latest revision.
    revision_id: ?[]const u8 = null,
    view: SchemaView = .full,
};

pub const SchemaListOptions = struct {
    page: PageOptions = .{},
    view: SchemaView = .basic,
};

pub const SchemaPage = struct {
    schemas: []const SchemaInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// How a message's bytes spell what its schema describes: as JSON text, or
/// in the schema type's own binary form. An unrecognized value from the
/// server is `.unknown`, which is only ever read.
pub const SchemaEncoding = enum { json, binary, unknown };

/// A topic's schema: on create, on read and in an update. A message is
/// taken when it fits a revision the settings allow, tried from the newest
/// to the oldest.
pub const SchemaSettings = struct {
    /// A schema id in the client's project, or
    /// `projects/{project}/schemas/{id}`, which may lie in another
    /// project. Read back in full, or as `_deleted-schema_`.
    schema: []const u8,
    encoding: SchemaEncoding,
    /// The oldest revision a message may fit. Null: any.
    first_revision_id: ?[]const u8 = null,
    /// The newest. Null: any, those committed later included.
    last_revision_id: ?[]const u8 = null,

    /// What `schema` reads once the schema is deleted.
    pub const deleted = "_deleted-schema_";

    /// The schema the topic named is deleted, and the topic refuses every
    /// publish until its settings are set again or cleared. A schema made
    /// again under the old id is not the one the topic had.
    pub fn isDeleted(self: SchemaSettings) bool {
        return std.mem.eql(u8, self.schema, deleted);
    }
};

/// One step a topic or a subscription runs each message through: Google
/// calls it a single message transform. Pub/Sub runs it. An emulator keeps
/// it and runs nothing, so a message goes through one untouched there.
pub const MessageTransform = struct {
    kind: Kind,
    /// Kept in the list, and not run.
    disabled: bool = false,

    pub const Kind = union(enum) {
        javascript_udf: JavaScriptUdf,
        /// A kind this client does not model, such as AI inference. Only
        /// ever read: a list that holds one is refused before sending,
        /// since a list is replaced whole and would lose it.
        other,
    };
};

/// A JavaScript function Pub/Sub calls with each message.
pub const JavaScriptUdf = struct {
    /// The function in `code` to call: `function name(message, metadata)`,
    /// where `message.data` is a string and `message.attributes` a map of
    /// strings. No two functions of a list share a name.
    function_name: []const u8,
    /// At most 20,480 bytes. The function returns the message, changed or
    /// not; returns null to drop it; or throws to refuse it.
    code: []const u8,
};

/// Where an import topic fills itself from, and what Pub/Sub logs about
/// it. Each source needs grants outside Pub/Sub, and the caller must be
/// able to act as the source's `gcp_service_account`, where it has one.
pub const Ingestion = struct {
    source: Source,
    /// Pub/Sub writes what happens at the source to Cloud Logging, at this
    /// severity and above. `.disabled`: nothing.
    log_severity: LogSeverity = .disabled,

    pub const Source = union(enum) {
        aws_kinesis: AwsKinesis,
        cloud_storage: CloudStorageSource,
        azure_event_hubs: AzureEventHubs,
        aws_msk: AwsMsk,
        confluent_cloud: ConfluentCloud,
    };

    /// `.unknown` is only ever read.
    pub const LogSeverity = enum { disabled, debug, info, warning, @"error", unknown };
};

/// A Kinesis data stream, read through a consumer of it.
pub const AwsKinesis = struct {
    stream_arn: []const u8,
    /// The consumer, in enhanced fan-out mode, that Pub/Sub reads as.
    consumer_arn: []const u8,
    /// The AWS role Pub/Sub assumes, as `gcp_service_account`.
    aws_role_arn: []const u8,
    gcp_service_account: []const u8,
};

/// A bucket's objects, each one read once as messages.
pub const CloudStorageSource = struct {
    /// The bucket's name alone. Production also takes it with `gs://`
    /// before it, and reads it back without. Pub/Sub's service agent must
    /// be able to read the bucket, and to publish to the topic.
    bucket: []const u8,
    format: Format = .{ .text = .{} },
    /// Only objects made at or after this. Null: all.
    minimum_object_create_time: ?std.Io.Timestamp = null,
    /// Only objects whose names match. "": all.
    match_glob: []const u8 = "",

    pub const Format = union(enum) {
        /// One message a line, or between `delimiter`s: one character of
        /// one byte, such as a tab or a bar. Production refuses anything
        /// longer (measured 2026-10-12).
        text: struct { delimiter: []const u8 = "\n" },
        /// One message a record of an Avro file.
        avro,
        /// As a Cloud Storage subscription writes Avro: the data, and the
        /// attributes with it.
        pubsub_avro,
    };
};

/// An event hub of an Azure Event Hubs namespace.
pub const AzureEventHubs = struct {
    resource_group: []const u8,
    namespace: []const u8,
    event_hub: []const u8,
    /// The app registration Pub/Sub signs in as, through
    /// `gcp_service_account`.
    client_id: []const u8,
    tenant_id: []const u8,
    subscription_id: []const u8,
    gcp_service_account: []const u8,
};

/// A topic of an Amazon MSK cluster.
pub const AwsMsk = struct {
    cluster_arn: []const u8,
    topic: []const u8,
    /// The AWS role Pub/Sub assumes, as `gcp_service_account`.
    aws_role_arn: []const u8,
    gcp_service_account: []const u8,
};

/// A topic of a Confluent Cloud cluster.
pub const ConfluentCloud = struct {
    /// `host:port`.
    bootstrap_server: []const u8,
    cluster_id: []const u8,
    topic: []const u8,
    /// The identity pool Pub/Sub signs in to, as `gcp_service_account`.
    identity_pool_id: []const u8,
    gcp_service_account: []const u8,
};

/// An import topic's settings as read, with the server's word on whether
/// it can read the source.
pub const IngestionInfo = struct {
    /// Null: a source this client does not model.
    source: ?Ingestion.Source,
    log_severity: Ingestion.LogSeverity,
    /// `.unknown` when the server says nothing, as an emulator does not.
    state: IngestionState,
};

/// A Resource Manager tag, bound to a topic, a subscription or a snapshot
/// as it is made: for policies and billing, where a label is only a note.
/// The key and the value must already be there, and the caller needs the
/// Tag User role on the value. Tags are given once: production returns
/// none of them on a read (an emulator echoes them, measured 2026-10-12),
/// and binding or removing one afterwards is Resource Manager's API.
pub const Tag = struct {
    /// `{organization id or project id}/{key name}`, or `tagKeys/{id}`.
    key: []const u8,
    /// The value's short name, with a key by name; `tagValues/{id}`, with
    /// a key by id. Production refuses one of each.
    value: []const u8,
};

/// What Pub/Sub says of an import topic's source. One enum for the five
/// sources: what all can say, what each alone can, and each one's own
/// permission error as `.permission_denied`. While it is anything but
/// `.active`, the topic's own state is `.ingestion_resource_error`.
pub const IngestionState = enum {
    active,
    /// Pub/Sub's service agent may not publish to the topic.
    publish_permission_denied,
    /// The region Pub/Sub would import in is one the project's service
    /// account is not allowed.
    conflicting_region_constraints,
    /// Pub/Sub may not read the source.
    permission_denied,
    stream_not_found,
    consumer_not_found,
    bucket_not_found,
    /// The bucket holds more objects than an import topic reads: 50 million.
    too_many_objects,
    namespace_not_found,
    event_hub_not_found,
    subscription_not_found,
    resource_group_not_found,
    cluster_not_found,
    topic_not_found,
    unreachable_bootstrap_server,
    unknown,
};

test "ReceivedMessage.attribute finds the first match" {
    const m: ReceivedMessage = .{
        .ack_id = "a",
        .message_id = "1",
        .data = "",
        .attributes = &.{
            .{ .key = "origin", .value = "zig" },
            .{ .key = "", .value = "empty key" },
            .{ .key = "origin", .value = "second" },
        },
        .publish_time = "",
        .ordering_key = "",
        .delivery_attempt = 0,
    };
    try std.testing.expectEqualStrings("zig", m.attribute("origin").?);
    try std.testing.expectEqualStrings("empty key", m.attribute("").?);
    try std.testing.expectEqual(null, m.attribute("missing"));
}

test "compression is off unless asked for, and asks for level 6 from 240 bytes" {
    try std.testing.expectEqual(null, (PublishOptions{}).compression);
    const c: Compression = .{};
    try std.testing.expectEqual(6, c.level);
    try std.testing.expectEqual(240, c.min_bytes);
}

test "ReceivedMessage.schema reads what a schema topic wrote, and is null without it" {
    const base: ReceivedMessage = .{ .ack_id = "a", .message_id = "1", .data = "{}", .attributes = &.{}, .publish_time = "", .ordering_key = "", .delivery_attempt = 0 };
    try std.testing.expectEqual(null, base.schema());

    // As the emulator delivered one on 2026-10-11, beside an attribute of
    // the publisher's own.
    var written = base;
    written.attributes = &.{
        .{ .key = "origin", .value = "zig" },
        .{ .key = "googclient_schemaencoding", .value = "JSON" },
        .{ .key = "googclient_schemaname", .value = "projects/test/schemas/order-v1" },
        .{ .key = "googclient_schemarevisionid", .value = "3566a360" },
    };
    const s = written.schema().?;
    try std.testing.expectEqualStrings("projects/test/schemas/order-v1", s.name);
    try std.testing.expectEqualStrings("3566a360", s.revision_id);
    try std.testing.expectEqual(SchemaEncoding.json, s.encoding);

    var binary = base;
    binary.attributes = &.{.{ .key = "googclient_schemaencoding", .value = "BINARY" }};
    try std.testing.expectEqual(SchemaEncoding.binary, binary.schema().?.encoding);
    // The encoding alone makes it a schema topic's message: the rest reads
    // as empty, and an encoding not yet known as `.unknown`.
    try std.testing.expectEqualStrings("", binary.schema().?.name);
    try std.testing.expectEqualStrings("", binary.schema().?.revision_id);
    var later = base;
    later.attributes = &.{.{ .key = "googclient_schemaencoding", .value = "CBOR" }};
    try std.testing.expectEqual(SchemaEncoding.unknown, later.schema().?.encoding);
    // The name and the revision without the encoding are not enough.
    var half = base;
    half.attributes = &.{.{ .key = "googclient_schemaname", .value = "projects/test/schemas/order-v1" }};
    try std.testing.expectEqual(null, half.schema());

    const gone: SchemaSettings = .{ .schema = "_deleted-schema_", .encoding = .binary };
    try std.testing.expect(gone.isDeleted());
    try std.testing.expect(!(SchemaSettings{ .schema = "projects/p/schemas/order-v1", .encoding = .json }).isDeleted());
}
