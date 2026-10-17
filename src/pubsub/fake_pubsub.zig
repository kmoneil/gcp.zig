//! A Pub/Sub for tests, behind the `Transport` seam: topics and
//! subscriptions kept in memory, and messages that go from a publish to
//! every subscription's pulls, answered and refused as production answered
//! and refused when measured on 2026-10-12
//! (`_tmp/pubsub-extras/production-fake-1.txt` to `-3.txt`). It is written
//! from what production did, not from this library's encoder: it parses
//! request JSON and masks with code of its own, so a body or a mask the
//! encoder gets wrong is refused or misapplied here as production would.
//! Exported as `pubsub.testing.FakePubSub`, experimental, for a caller's
//! own tests: `docs/pubsub/testing.md`.
//!
//! What it models:
//!
//! - Topics: create, get, update, delete, a project's list in pages, and a
//!   topic's list of subscriptions. Labels, message retention, a KMS key
//!   name and a storage policy are kept and read back; nothing is enforced
//!   from the last three.
//! - Subscriptions: create, get, update, delete and the list, with the
//!   defaults production fills in (a 10 second ack deadline, 7 days of
//!   retention, expiry after 31 days), its bounds on each, and the fields
//!   it will not change. A deleted topic leaves its subscriptions reading
//!   `_deleted-topic_`, with what they hold.
//! - Publish: ids, decimal and consecutive; the limits on a request, its
//!   messages, their attributes and their ordering key, each refused in
//!   production's words; one ordering key a request.
//! - Pull, acknowledge and modifyAckDeadline. A subscription gets what is
//!   published after it is made. A pulled message is out on a lease until
//!   its deadline on the fake's clock, then comes again. **An ack takes
//!   only while the message is out on a lease**: after a lapse, or after
//!   a nack, an ack with the old id is answered 200 and forgotten, as
//!   production's was, and once the message is out again an old id
//!   acknowledges it. So an ack id names the message, and the lease
//!   decides.
//! - Order: none without an ordering key. Production returned twelve
//!   messages published one by one as 03, 11, 00, 06 and so on, so a pull
//!   here returns what it has in an order of the fake's choosing, unless
//!   `Options.shuffle` is off.
//! - A subscription's rules, each as production showed it:
//!   - A filter (`fake_filter.zig`). What does not pass is never held: it
//!     is no backlog, and never comes.
//!   - Ordering keys. With `enableMessageOrdering` a key's messages come
//!     in the order published. What a key has waiting comes together, in
//!     one pull, and then **the key gives nothing more while one of its
//!     messages is out**: one published meanwhile waits for the ack.
//!     **A nack or a lapse of one brings back every later message of its
//!     key, the acknowledged ones included**: an acknowledged message can
//!     come a second time. With exactly-once delivery as well, a key
//!     gives one message at a time.
//!   - Dead letters. Every delivery is an attempt, sent as
//!     `deliveryAttempt` with a policy alone. A message released after
//!     its last attempt moves to the dead-letter topic, marked as
//!     production marks one. Production forwards only when its service
//!     agent may publish to that topic and acknowledge on the
//!     subscription, and otherwise goes on delivering. The fake always
//!     forwards, unless `Options.service_agent` names the agent: then it
//!     reads the two policies as production does.
//!   - A retry policy. A message given back, or lapsed, waits the minimum
//!     backoff, doubled with each delivery up to the maximum: the fake's
//!     own rule, inside the delays production showed. With ordering it
//!     holds the later messages of its key behind it.
//!   - Retention. A message older than `messageRetentionDuration` is gone
//!     from the subscription, out on a lease or not.
//!   - Exactly-once delivery. An ack or a lease change that comes after
//!     the lease lapsed is refused, id by id, in production's body, and
//!     so is one with the id of an earlier delivery, then and ever after.
//!     A second ack with the id that acknowledged the message is taken,
//!     and a lease change on an acknowledged message is not.
//! - Replay, as production answered on 2026-10-10:
//!   - Snapshots: create, get, update of the labels, delete, a project's
//!     list and a topic's. One holds what its subscription had not had
//!     acknowledged, and what its topic is sent after. It lasts seven
//!     days from the oldest message its subscription has, and outlives
//!     its subscription and its topic. None is taken of a subscription
//!     whose topic is deleted (measured 2026-10-12).
//!   - Seek. To a snapshot, the subscription holds again what the
//!     snapshot holds, through its own filter. To a time, what was
//!     published before it is acknowledged and what was published from
//!     then on is unacknowledged again, of what the subscription still
//!     has: what it has not had acknowledged; what it retains
//!     acknowledged, if it was there to get it; and what its topic
//!     retains, there or not. **A seek ends no ack id: one from before it
//!     goes on naming its message.** It acts once the message is out
//!     again, and is answered and forgotten until then; with exactly-once
//!     delivery it is answered for as long as the lease it had runs, and
//!     refused after, as production's were.
//!   - Detach. The subscription lets go of what it holds, gets nothing
//!     more, reads `detached`, and refuses all but a read, an update and
//!     a delete.
//!   - A topic's retention, which its subscriptions read as
//!     `topicMessageRetentionDuration`.
//! - Schemas, as production answered on 2026-10-12: create, get, delete,
//!   a project's list, a schema's revisions, commit, rollback,
//!   deleteRevision, validate and validateMessage, with production's
//!   rules for revisions: eight hex digits of id, twenty to a schema, a
//!   rollback that makes a new one, the last that goes only with the
//!   schema. **A definition is kept and not read.** An Avro one must be
//!   JSON, a Protocol Buffer one is taken as text, and a commit is held
//!   against the revision before it in its type alone. A topic's schema
//!   settings are checked and read back as production's, and a message
//!   published to such a topic is marked with the encoding and the
//!   revision it fit. **Whether a message fits is the test's to say**,
//!   through `Options.fits`: with none, every message fits.
//! - What Pub/Sub would do on its own, kept and not done, as production
//!   answered on 2026-10-10 to 2026-10-12:
//!   - A subscription that pushes, or writes to BigQuery or to Cloud
//!     Storage: the config is checked as production checked it and read
//!     back as production read it back, with what production fills in.
//!     **Nothing is delivered**: such a subscription holds what it is
//!     sent, and refuses a pull. `modifyPushConfig`, and an update by
//!     `pushConfig`, `bigqueryConfig` and `cloudStorageConfig`, change
//!     one kind for another.
//!   - Message transforms on a topic and on a subscription. **No function
//!     runs**: a message goes through as it was published.
//!   - An import topic's source. **Nothing is imported.**
//!   - Tags on a topic, a subscription and a snapshot as each is made.
//!     Production returns none on a read, and neither does the fake:
//!     `tagValue` says what was bound.
//!
//!   The fake has no world outside itself. A table, a bucket, a stream, a
//!   service account and a tag are each taken to be there and allowed,
//!   where production looks and may refuse. What production would then
//!   find out by trying, a test says: `setExportState` and
//!   `setIngestionState`.
//! - IAM on a topic, a subscription, a snapshot and a schema, as
//!   production answered on 2026-10-01 and after: a policy that reads
//!   `{"etag":"ACAB"}` until it is written, an etag that every write
//!   moves, a write under an older one refused, and bindings stored as
//!   production stores them. The fake has no accounts and no callers: a
//!   member of good form is taken to be there, and whoever asks holds
//!   every permission.
//! - Faults, on command: `refuseNext`, `loseAnswers`, `dropNext`.
//!
//! Its clock is the `io` it is given: with `core.testing.FakeClock`, a
//! lease lapses when the test moves the clock and not before. It is safe
//! to use from several tasks at once.
//!
//! Not modelled yet, and answered 501 with a message that says so, never
//! guessed at: a Bigtable subscription, and the transforms that are no
//! JavaScript function. A filter of a shape production was not shown,
//! or that production itself fails on, is answered the same way, and so
//! is a setting here and there that production was not shown.
//! Production's delays are not modelled at all: a deleted topic that
//! still takes a publish, the two seconds before a nacked message comes
//! again, the 2 to 50 seconds a seek back took to show, the seven
//! seconds before a detached subscription refused, the minute a deleted
//! schema's topics went on taking publishes. Everything holds at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const core = @import("core");
const tp = core.transport;
const timestamp = core.timestamp;
const fake_filter = @import("fake_filter.zig");
const types = @import("types.zig");

pub const FakePubSub = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    mutex: std.Io.Mutex = .init,
    /// Holds everything stored. What is deleted stays in it until `deinit`.
    store: std.heap.ArenaAllocator,
    /// By full name, `projects/p/topics/id`, in name order.
    topics: std.StringArrayHashMapUnmanaged(*Topic) = .empty,
    /// By full name, in name order.
    subscriptions: std.StringArrayHashMapUnmanaged(*Subscription) = .empty,
    /// By full name, in name order.
    snapshots: std.StringArrayHashMapUnmanaged(*Snapshot) = .empty,
    /// By full name, in name order.
    schemas: std.StringArrayHashMapUnmanaged(*Schema) = .empty,
    /// Deleted schemas, whose revisions are freed at `deinit`.
    old_schemas: std.ArrayList(*Schema) = .empty,
    /// Counts revisions as they are made, of every schema.
    next_revision: u32 = 1,
    next_message_id: u64 = 1,
    next_uid: u64 = 1,
    /// The microsecond the last policy was written at: no two writes
    /// share one.
    last_stamp: u64 = 0,
    prng: std.Random.DefaultPrng = .init(0x5eed),
    faults: [3]Fault = @splat(.{}),
    /// Requests served, by the kind of call, faults included.
    counts: [@typeInfo(Calls).@"enum".field_names.len]usize = @splat(0),
    /// Deleted topics and subscriptions, whose lists are freed at `deinit`.
    orphans: std.ArrayList(*Topic) = .empty,
    dropped: std.ArrayList(*Subscription) = .empty,

    pub const Options = struct {
        /// How long a pull with nothing to give is held. Production holds
        /// one about 20 seconds. Zero: it answers at once.
        empty_pull_hold: std.Io.Duration = .zero,
        /// A pull returns what it has in an order of the fake's choosing,
        /// as production gives no order without an ordering key. Off: in
        /// the order published, which no test should lean on.
        shuffle: bool = true,
        /// Whether a message fits a schema. The fake reads no schema: it
        /// keeps a definition and asks this, of every message published
        /// to a topic that has a schema, for each revision the topic
        /// allows from the newest back, and of a message given to
        /// validateMessage. With none, every message fits.
        fits: ?Fits = null,
        /// Pub/Sub's service agent, as a policy names it:
        /// `serviceAccount:service-123@gcp-sa-pubsub.iam.gserviceaccount.com`.
        /// Production forwards a dead letter only when this account may
        /// publish to the dead-letter topic and acknowledge on the
        /// subscription, and otherwise goes on delivering the message.
        /// With the agent named here the fake does the same, by the
        /// policies of those two resources: it has no project to grant
        /// on. With none, it always forwards.
        service_agent: ?[]const u8 = null,
    };

    pub const Fits = struct {
        context: ?*anyopaque = null,
        /// Null: the message fits. Otherwise why it does not, in the
        /// words production would put after "Invalid data in message: ",
        /// such as "Could not parse binary message.".
        call: *const fn (context: ?*anyopaque, check: SchemaCheck) ?[]const u8,
    };

    /// A message, and the revision of a schema it is tried against.
    pub const SchemaCheck = struct {
        /// The schema's full name. "" for one given whole to
        /// validateMessage, which has no revision either.
        schema: []const u8,
        revision_id: []const u8,
        type: SchemaType,
        definition: []const u8,
        encoding: Encoding,
        data: []const u8,
    };

    pub const SchemaType = enum { avro, protocol_buffer };
    pub const Encoding = enum { json, binary };

    /// The kinds of call a fault or a count can be about.
    pub const Calls = enum { all, publish, pull, acknowledge, modify_ack_deadline, admin };

    const Fault = struct { n: usize = 0, which: Calls = .all, status: u16 = 503, delay: ?core.retry_after.Asked = null };
    const refuse = 0;
    const lose = 1;
    const drop = 2;

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    const Label = struct { key: []const u8, value: []const u8 };

    const Topic = struct {
        name: []const u8,
        labels: []const Label = &.{},
        /// Seconds. Null: the topic keeps nothing itself.
        retention_s: ?i64 = null,
        kms_key_name: ?[]const u8 = null,
        /// As it was sent, re-rendered: nothing reads it but a `get`.
        storage_policy: ?StoragePolicy = null,
        /// Every message published, oldest first.
        messages: std.ArrayList(*const Message) = .empty,
        /// Deleted, and kept for what still points at it: a topic made
        /// again under its name is another topic.
        deleted: bool = false,
        policy: Policy = .{},
        schema: ?SchemaSettings = null,
        /// Kept, and run on nothing.
        transforms: []const Transform = &.{},
        /// An import topic's source. Nothing is imported from it.
        ingestion: ?Ingestion = null,
        /// Bound as the topic was made, and never read back.
        tags: []const Label = &.{},
    };

    const Schema = struct {
        name: []const u8,
        uid: u64,
        type: SchemaType,
        /// Oldest first. Never empty.
        revisions: std.ArrayList(Revision) = .empty,
        /// Deleted, and kept for the topics that still point at it: one
        /// made again under its name is another schema.
        deleted: bool = false,
        policy: Policy = .{},

        fn latest(s: *const Schema) *const Revision {
            return &s.revisions.items[s.revisions.items.len - 1];
        }

        fn revision(s: *const Schema, id: []const u8) ?*const Revision {
            for (s.revisions.items) |*r| {
                if (std.mem.eql(u8, &r.id, id)) return r;
            }
            return null;
        }
    };

    const Revision = struct {
        /// Eight lower-case hex digits, as production's are.
        id: [8]u8,
        /// In the order made, across all schemas.
        number: u32,
        definition: []const u8,
        created: std.Io.Timestamp,
    };

    /// A topic's schema: its messages must fit one of the schema's
    /// revisions, of those from `first` to `last` when a range is set.
    const SchemaSettings = struct {
        schema: *Schema,
        encoding: Encoding,
        first: ?*const Bound = null,
        last: ?*const Bound = null,

        const Bound = struct { id: [8]u8, number: u32 };

        fn allows(s: SchemaSettings, r: Revision) bool {
            if (s.first) |first| {
                if (r.number < first.number) return false;
            }
            if (s.last) |last| {
                if (r.number > last.number) return false;
            }
            return true;
        }
    };

    const StoragePolicy = struct { regions: []const []const u8, enforce_in_transit: bool };

    const Message = struct {
        id: u64,
        data: []const u8,
        attributes: []const Label,
        ordering_key: []const u8,
        publish_time: std.Io.Timestamp,
    };

    const Subscription = struct {
        name: []const u8,
        uid: u64,
        /// Its topic, deleted or not.
        topic: *Topic,
        /// How many messages its topic had been sent when it was made:
        /// it was there for the ones after.
        joined: usize = 0,
        /// Detached from its topic: it holds nothing, gets nothing, and
        /// gives nothing.
        detached: bool = false,
        /// Ack ids of entries numbered below this are from before a seek.
        stale_below: u64 = 1,
        /// What is kept of each entry a seek did away with, by its
        /// number: an ack id goes on naming its message.
        old: std.AutoHashMapUnmanaged(u64, Old) = .empty,
        policy: Policy = .{},
        ack_deadline_s: u32 = 10,
        labels: []const Label = &.{},
        retention_s: i64 = 604_800,
        retain_acked: bool = false,
        /// Seconds. Null: it never expires.
        expiration_ttl_s: ?i64 = 2_678_400,
        /// How its messages would be handed over. Anything but a pull is
        /// kept and not done: the subscription holds what it is sent.
        delivery: Delivery = .pull,
        /// Kept, and run on nothing.
        transforms: []const Transform = &.{},
        /// Bound as the subscription was made, and never read back.
        tags: []const Label = &.{},
        dead_letter: ?DeadLetter = null,
        retry: ?Retry = null,
        /// Messages with an ordering key come in the key's order.
        ordered: bool = false,
        exactly_once: bool = false,
        /// As it was sent. "": none.
        filter_text: []const u8 = "",
        filter: ?fake_filter.Filter = null,
        /// What it has not had acknowledged, by a number of the entry's
        /// own, in the order it arrived.
        entries: std.AutoArrayHashMapUnmanaged(u64, Entry) = .empty,
        next_seq: u64 = 1,
        /// By an entry's number, the delivery whose id acknowledged it,
        /// and the message. With exactly-once delivery that id is taken
        /// a second time, and an id of an earlier delivery is not.
        acknowledged: std.AutoHashMapUnmanaged(u64, Acked) = .empty,

        const Acked = struct { delivery: u32, message: *const Message };

        /// An entry from before a seek.
        const Old = struct {
            message: *const Message,
            /// With exactly-once delivery, the delivery that was out when
            /// the seek came, and until when its lease runs: the seek
            /// does not end it. Null: none was, or its id is done.
            delivery: u32,
            until: ?i96,
        };

        /// Whether, with exactly-once delivery, `id` is the one that
        /// acknowledged its message.
        fn tookIt(s: *const Subscription, id: AckId) bool {
            return if (s.acknowledged.get(id.seq)) |acked| acked.delivery == id.delivery else false;
        }

        /// The entry that holds `message` now, if one does.
        fn entryOf(s: *const Subscription, message: *const Message) ?usize {
            for (s.entries.values(), 0..) |entry, index| {
                if (entry.message == message) return index;
            }
            return null;
        }

        /// Whether a message published to its topic reaches it. Production
        /// tries the filter as the message arrives: what does not pass is
        /// never held, and never comes.
        fn takes(s: *const Subscription, m: *const Message) bool {
            if (s.detached) return false;
            return if (s.filter) |filter| filter.matches(m.attributes) else true;
        }

        /// Whether it still has message `m`, the `index`th its topic was
        /// sent, acknowledged though it is, to give again after a seek to
        /// a time. It has it if it retains acknowledged messages and was
        /// there to get it: one older than it keeps messages is let go
        /// again as any is, when the subscription is next settled. And it
        /// has it as long as its topic retains messages, there or not:
        /// production replayed a topic's two messages to a subscription
        /// made after them.
        fn retains(s: *const Subscription, m: *const Message, index: usize, wall: i96) bool {
            if (s.retain_acked and index >= s.joined) return true;
            const seconds = s.topic.retention_s orelse return false;
            return wall - m.publish_time.nanoseconds < @as(i96, seconds) * std.time.ns_per_s;
        }

        /// Whether the entry's place among the messages of its ordering
        /// key matters here.
        fn keyed(s: *const Subscription, entry: Entry) bool {
            return s.ordered and entry.message.ordering_key.len > 0;
        }

        /// Whether `id` may still act on the entry: the message is out on
        /// a lease, and with exactly-once delivery the id is that
        /// delivery's own. Without it an old id acts on a later delivery,
        /// as production's did. (That an id is one delivery's alone under
        /// exactly-once delivery is Google's documentation, not measured.)
        fn live(s: *const Subscription, index: usize, id: AckId, now: i96) bool {
            const entry = s.entries.values()[index];
            const until = entry.lease_until orelse return false;
            if (until <= now) return false;
            return !s.exactly_once or id.delivery == entry.deliveries;
        }

        /// An acknowledgement that took, by the id of `delivery`. With
        /// ordering, a message of a key is kept, acknowledged, while an
        /// earlier one of its key is not: that one's nack or lapse brings
        /// it back.
        fn take(s: *Subscription, gpa: Allocator, index: usize, delivery: u32) Allocator.Error!void {
            const entry = &s.entries.values()[index];
            try s.acknowledged.put(gpa, s.entries.keys()[index], .{ .delivery = delivery, .message = entry.message });
            if (!s.keyed(entry.*)) return s.entries.orderedRemoveAt(index);
            entry.acked = true;
            entry.lease_until = null;
            s.prune(entry.message.ordering_key);
        }

        /// Lets go of the acknowledged messages of a key that nothing can
        /// bring back: the ones before its first unacknowledged message.
        fn prune(s: *Subscription, key: []const u8) void {
            var i: usize = 0;
            while (i < s.entries.count()) {
                const entry = s.entries.values()[i];
                if (!std.mem.eql(u8, entry.message.ordering_key, key)) {
                    i += 1;
                } else if (entry.acked) {
                    s.entries.orderedRemoveAt(i);
                } else return;
            }
        }
    };

    const Snapshot = struct {
        name: []const u8,
        /// The topic of the subscription it was taken of.
        topic: *Topic,
        labels: []const Label = &.{},
        /// On the wall clock.
        expire: std.Io.Timestamp,
        /// What the subscription had not had acknowledged, oldest first.
        held: []const *const Message,
        /// How many messages the topic had been sent by then: every one
        /// after is the snapshot's too.
        from: usize,
        /// Bound as the snapshot was made, and never read back.
        tags: []const Label = &.{},
        policy: Policy = .{},
    };

    /// An allow policy.
    const Policy = struct {
        /// The microsecond of the write that made it, which is what one
        /// of production's etags holds. Zero: never written.
        stamp: u64 = 0,
        bindings: []const Binding = &.{},

        const Binding = struct { role: []const u8, members: []const []const u8 };

        /// Whether `member` holds one of `roles`.
        fn grants(p: Policy, member: []const u8, roles: []const []const u8) bool {
            for (p.bindings) |binding| {
                const named = for (roles) |role| {
                    if (std.mem.eql(u8, binding.role, role)) break true;
                } else false;
                if (!named) continue;
                for (binding.members) |m| {
                    if (std.ascii.eqlIgnoreCase(m, member)) return true;
                }
            }
            return false;
        }
    };

    const DeadLetter = struct {
        /// The topic's full name. Looked up when a message is forwarded:
        /// it may be deleted in the meantime.
        topic: []const u8,
        max_attempts: u32,
    };

    /// Seconds, each 0 to 600.
    const Retry = struct { min_s: i64, max_s: i64 };

    const Delivery = union(enum) {
        pull,
        push: Push,
        bigquery: BigQuery,
        cloud_storage: CloudStorage,
    };

    const Push = struct {
        endpoint: []const u8,
        /// `x-goog-version`, when the request said one.
        version: ?[]const u8 = null,
        oidc: ?Oidc = null,
        wrapper: Wrapper = .unsaid,

        const Oidc = struct { email: []const u8, audience: []const u8 = "" };
        const Wrapper = union(enum) { unsaid, pubsub, none: struct { write_metadata: bool = false } };
    };

    const BigQuery = struct {
        table: []const u8 = "",
        use_topic_schema: bool = false,
        write_metadata: bool = false,
        drop_unknown_fields: bool = false,
        use_table_schema: bool = false,
        service_account: []const u8 = "",
        /// What production would say of its writes: the test's to set.
        state: types.ExportState = .active,
    };

    const CloudStorage = struct {
        bucket: []const u8 = "",
        prefix: []const u8 = "",
        suffix: []const u8 = "",
        datetime_format: []const u8 = "",
        format: Format = .text,
        /// Five minutes when none is said.
        max_duration_ns: i64 = 300 * std.time.ns_per_s,
        /// 0: no such limit.
        max_bytes: i64 = 0,
        max_messages: i64 = 0,
        service_account: []const u8 = "",
        /// What production would say of its writes: the test's to set.
        state: types.ExportState = .active,

        const Format = union(enum) { text, avro: struct { write_metadata: bool = false, use_topic_schema: bool = false } };
    };

    /// A JavaScript function, which is all a transform here can be.
    const Transform = struct {
        function_name: []const u8 = "",
        code: []const u8 = "",
        enabled: bool = false,
        disabled: bool = false,
    };

    const Ingestion = struct {
        source: Source,
        /// The severity's word, as it was sent. "": none was.
        log_severity: []const u8 = "",
        /// What production would say of the source: the test's to set.
        state: types.IngestionState = .active,

        const Source = union(enum) {
            cloud_storage: Bucket,
            /// One of `outside_sources`, with a value for each of its
            /// fields.
            outside: struct { kind: usize, values: []const []const u8 },
        };

        const Bucket = struct {
            bucket: []const u8 = "",
            format: ?Format = null,
            /// As it reads back. "": none.
            minimum_object_create_time: []const u8 = "",
            match_glob: []const u8 = "",

            /// A text format's delimiter is null when none was said.
            const Format = union(enum) { text: ?[]const u8, avro, pubsub_avro };
        };
    };

    const Entry = struct {
        message: *const Message,
        /// Out on a lease until then, on the awake clock. Null: waiting.
        lease_until: ?i96 = null,
        /// How many times it was delivered.
        deliveries: u32 = 0,
        /// Not to be delivered again before then: a retry policy's backoff.
        not_before: i96 = 0,
        /// Acknowledged, and kept for now: see `Subscription.take`.
        acked: bool = false,
    };

    const AckId = struct { text: []const u8, seq: u64, delivery: u32 };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakePubSub {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakePubSub) void {
        for (f.topics.values()) |t| t.messages.deinit(f.gpa);
        for (f.orphans.items) |t| t.messages.deinit(f.gpa);
        f.orphans.deinit(f.gpa);
        for ([_][]const *Subscription{ f.subscriptions.values(), f.dropped.items }) |list| {
            for (list) |s| {
                s.entries.deinit(f.gpa);
                s.acknowledged.deinit(f.gpa);
                s.old.deinit(f.gpa);
            }
        }
        f.dropped.deinit(f.gpa);
        for ([_][]const *Schema{ f.schemas.values(), f.old_schemas.items }) |list| {
            for (list) |s| s.revisions.deinit(f.gpa);
        }
        f.old_schemas.deinit(f.gpa);
        f.topics.deinit(f.gpa);
        f.subscriptions.deinit(f.gpa);
        f.snapshots.deinit(f.gpa);
        f.schemas.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakePubSub) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    // Faults, each for the next `n` requests that `which` matches.

    /// Answers them with `status` and changes nothing.
    pub fn refuseNext(f: *FakePubSub, n: usize, status: u16, which: Calls) void {
        f.setFault(refuse, .{ .n = n, .which = which, .status = status });
    }

    /// Answers them as `refuseNext` does, and asks the client to wait
    /// `delay.ms` before trying again, in `delay.form`: for a test of how
    /// an app schedules its next try. No Google service measured sends one.
    pub fn refuseNextWithDelay(f: *FakePubSub, n: usize, status: u16, which: Calls, delay: core.retry_after.Asked) void {
        f.setFault(refuse, .{ .n = n, .which = which, .status = status, .delay = delay });
    }

    /// Lets them land, and answers 503: an answer lost on the way back.
    pub fn loseAnswers(f: *FakePubSub, n: usize, which: Calls) void {
        f.setFault(lose, .{ .n = n, .which = which });
    }

    /// Closes their connection before any answer, and changes nothing.
    pub fn dropNext(f: *FakePubSub, n: usize, which: Calls) void {
        f.setFault(drop, .{ .n = n, .which = which });
    }

    fn setFault(f: *FakePubSub, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakePubSub, slot: usize, call: Calls) bool {
        const fault = &f.faults[slot];
        if (fault.n == 0 or (fault.which != .all and fault.which != call)) return false;
        fault.n -= 1;
        return true;
    }

    // What a test asks of it. Each takes a full name, or an id in `project`.

    /// How many messages the subscription has not had acknowledged, out on
    /// a lease or not. Zero for one that is not there.
    pub fn backlog(f: *FakePubSub, project: []const u8, subscription: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        // Out of memory here leaves a dead letter where it was, for the
        // next call to forward.
        f.settleAll(f.awakeNow()) catch {};
        const s = f.findSubscription(project, subscription) orelse return 0;
        var n: usize = 0;
        for (s.entries.values()) |e| n += @intFromBool(!e.acked);
        return n;
    }

    /// Of those, how many are out on a lease now.
    pub fn outstanding(f: *FakePubSub, project: []const u8, subscription: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const now = f.awakeNow();
        f.settleAll(now) catch {};
        const s = f.findSubscription(project, subscription) orelse return 0;
        var n: usize = 0;
        for (s.entries.values()) |e| {
            if (e.lease_until) |until| {
                if (until > now) n += 1;
            }
        }
        return n;
    }

    /// How many messages the topic was sent, the dead letters forwarded to
    /// it included. Zero for one that is not there.
    pub fn publishedCount(f: *FakePubSub, project: []const u8, topic: []const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.settleAll(f.awakeNow()) catch {};
        var buf: [1024]u8 = undefined;
        const name = fullName(&buf, project, "topics", topic) orelse return 0;
        const t = f.topics.get(name) orelse return 0;
        return t.messages.items.len;
    }

    /// Requests served of that kind, the ones a fault answered included.
    pub fn requestCount(f: *FakePubSub, which: Calls) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.counts[@backingInt(which)];
    }

    // What a test tells it: what production would find out on its own.

    /// What a BigQuery or a Cloud Storage subscription reads as the state
    /// of its writes, which production learns by writing and the fake
    /// cannot. While it is anything but `.active` the subscription's own
    /// state reads `RESOURCE_ERROR`, as Google's reference says it does;
    /// `.unknown` reads as no state at all. A new config is `.active`
    /// again. Nothing happens for a subscription that is not there, or
    /// that exports nothing.
    pub fn setExportState(f: *FakePubSub, project: []const u8, subscription: []const u8, state: types.ExportState) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.findSubscription(project, subscription) orelse return;
        switch (s.delivery) {
            .bigquery => |*config| config.state = state,
            .cloud_storage => |*config| config.state = state,
            .pull, .push => {},
        }
    }

    /// What an import topic reads as the state of its source. While it is
    /// anything but `.active` the topic's own state reads
    /// `INGESTION_RESOURCE_ERROR`, as production's did. Nothing happens
    /// for a topic that is not there, or that imports nothing.
    pub fn setIngestionState(f: *FakePubSub, project: []const u8, topic: []const u8, state: types.IngestionState) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        var buf: [1024]u8 = undefined;
        const name = fullName(&buf, project, "topics", topic) orelse return;
        const t = f.topics.get(name) orelse return;
        if (t.ingestion) |*ingestion| ingestion.state = state;
    }

    /// The value of a tag a topic, a subscription or a snapshot was made
    /// with, by the resource's full name. Production returns no tag on a
    /// read, and neither does the fake: this is how a test sees one.
    pub fn tagValue(f: *FakePubSub, resource: []const u8, key: []const u8) ?[]const u8 {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const tags = if (f.topics.get(resource)) |t| t.tags else if (f.subscriptions.get(resource)) |s| s.tags else if (f.snapshots.get(resource)) |s| s.tags else return null;
        for (tags) |tag| {
            if (std.mem.eql(u8, tag.key, key)) return tag.value;
        }
        return null;
    }

    fn findSubscription(f: *FakePubSub, project: []const u8, subscription: []const u8) ?*Subscription {
        var buf: [1024]u8 = undefined;
        const name = fullName(&buf, project, "subscriptions", subscription) orelse return null;
        return f.subscriptions.get(name);
    }

    fn fullName(buf: []u8, project: []const u8, comptime collection: []const u8, name_or_id: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, name_or_id, "projects/")) return name_or_id;
        return std.fmt.bufPrint(buf, "projects/{s}/" ++ collection ++ "/{s}", .{ project, name_or_id }) catch null;
    }

    fn awakeNow(f: *const FakePubSub) i96 {
        return std.Io.Clock.awake.now(f.io).nanoseconds;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakePubSub = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req.method, req.url, req.body orelse "", arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    const Route = struct {
        project: []const u8,
        collection: enum { topics, subscriptions, snapshots, schemas },
        /// Decoded. "" for the collection itself.
        id: []const u8,
        /// As it was sent.
        raw_id: []const u8,
        /// After the id: `:publish`, `/subscriptions`, or "".
        rest: []const u8,
        query: []const u8,
    };

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakePubSub, method: tp.Method, url: []const u8, body: []const u8, arena: Allocator) tp.Error!Reply {
        const route = (try parseUrl(arena, url)) orelse return fail(arena, 404, "NOT_FOUND", "fake: no such route");
        const call = classify(method, route);

        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.counts[@backingInt(Calls.all)] += 1;
        f.counts[@backingInt(call)] += 1;
        if (f.takeFault(drop, call)) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse, call)) {
            const status = f.faults[refuse].status;
            const refused = try fail(arena, status, statusName(status), "The service is currently unavailable.");
            const delay = f.faults[refuse].delay orelse return refused;
            return .{ .status = refused.status, .headers = try delay.headers(arena), .body = try delay.intoBody(arena, refused.body) };
        }
        // What production does on its own, it does here before each call.
        try f.settleAll(f.awakeNow());
        f.expireSnapshots();
        const reply = try f.dispatch(method, route, body, arena);
        if (f.takeFault(lose, call)) return fail(arena, 503, "UNAVAILABLE", "The service is currently unavailable.");
        return reply;
    }

    fn classify(method: tp.Method, route: Route) Calls {
        if (method != .POST) return .admin;
        if (std.mem.eql(u8, route.rest, ":publish")) return .publish;
        if (std.mem.eql(u8, route.rest, ":pull")) return .pull;
        if (std.mem.eql(u8, route.rest, ":acknowledge")) return .acknowledge;
        if (std.mem.eql(u8, route.rest, ":modifyAckDeadline")) return .modify_ack_deadline;
        return .admin;
    }

    fn dispatch(f: *FakePubSub, method: tp.Method, route: Route, body: []const u8, arena: Allocator) tp.Error!Reply {
        const none = route.rest.len == 0;
        if (route.id.len != 0) {
            // Of a schema's revision production was not asked.
            if (route.collection == .schemas and std.mem.indexOfScalar(u8, route.id, '@') != null and std.mem.indexOf(u8, route.rest, "Iam") != null) return notModelled(arena, "IAM on a revision of a schema");
            if (method == .GET and std.mem.eql(u8, route.rest, ":getIamPolicy")) return f.getIamPolicy(arena, route);
            if (method == .POST and std.mem.eql(u8, route.rest, ":setIamPolicy")) return f.setIamPolicy(arena, route, body);
            if (method == .POST and std.mem.eql(u8, route.rest, ":testIamPermissions")) return f.testIamPermissions(arena, route, body);
        }
        switch (route.collection) {
            .topics => {
                if (route.id.len == 0) return if (method == .GET and none) f.listTopics(arena, route) else notModelled(arena, "this call on topics");
                if (none) return switch (method) {
                    .PUT => f.createTopic(arena, route, body),
                    .GET => f.getTopic(arena, route),
                    .PATCH => f.updateTopic(arena, route, body),
                    .DELETE => f.deleteTopic(arena, route),
                    .POST => notModelled(arena, "this call on a topic"),
                };
                if (method == .POST and std.mem.eql(u8, route.rest, ":publish")) return f.publish(arena, route, body);
                if (method == .GET and std.mem.eql(u8, route.rest, "/subscriptions")) return f.listTopicSubscriptions(arena, route);
                if (method == .GET and std.mem.eql(u8, route.rest, "/snapshots")) return f.listTopicSnapshots(arena, route);
                return notModelled(arena, route.rest);
            },
            .subscriptions => {
                if (route.id.len == 0) return if (method == .GET and none) f.listSubscriptions(arena, route) else notModelled(arena, "this call on subscriptions");
                if (none) return switch (method) {
                    .PUT => f.createSubscription(arena, route, body),
                    .GET => f.getSubscription(arena, route),
                    .PATCH => f.updateSubscription(arena, route, body),
                    .DELETE => f.deleteSubscription(arena, route),
                    .POST => notModelled(arena, "this call on a subscription"),
                };
                if (method == .POST and std.mem.eql(u8, route.rest, ":pull")) return f.pull(arena, route, body);
                if (method == .POST and std.mem.eql(u8, route.rest, ":acknowledge")) return f.acknowledge(arena, route, body);
                if (method == .POST and std.mem.eql(u8, route.rest, ":modifyAckDeadline")) return f.modifyAckDeadline(arena, route, body);
                if (method == .POST and std.mem.eql(u8, route.rest, ":seek")) return f.seek(arena, route, body);
                if (method == .POST and std.mem.eql(u8, route.rest, ":detach")) return f.detach(arena, route);
                if (method == .POST and std.mem.eql(u8, route.rest, ":modifyPushConfig")) return f.modifyPushConfig(arena, route, body);
                return notModelled(arena, route.rest);
            },
            .snapshots => {
                if (route.id.len == 0) return if (method == .GET and none) f.listSnapshots(arena, route) else notModelled(arena, "this call on snapshots");
                if (none) return switch (method) {
                    .PUT => f.createSnapshot(arena, route, body),
                    .GET => f.getSnapshot(arena, route),
                    .PATCH => f.updateSnapshot(arena, route, body),
                    .DELETE => f.deleteSnapshot(arena, route),
                    .POST => notModelled(arena, "this call on a snapshot"),
                };
                return notModelled(arena, route.rest);
            },
            .schemas => {
                if (route.id.len == 0) {
                    if (none) return switch (method) {
                        .GET => f.listSchemas(arena, route),
                        .POST => f.createSchema(arena, route, body),
                        .PUT, .PATCH, .DELETE => notModelled(arena, "this call on schemas"),
                    };
                    if (method == .POST and std.mem.eql(u8, route.rest, ":validate")) return f.validateSchema(arena, body);
                    if (method == .POST and std.mem.eql(u8, route.rest, ":validateMessage")) return f.validateMessage(arena, body);
                    return notModelled(arena, route.rest);
                }
                if (none) return switch (method) {
                    .GET => f.getSchema(arena, route),
                    .DELETE => f.deleteSchema(arena, route),
                    .PUT, .PATCH, .POST => notModelled(arena, "this call on a schema"),
                };
                if (method == .POST and std.mem.eql(u8, route.rest, ":commit")) return f.commitSchema(arena, body);
                if (method == .POST and std.mem.eql(u8, route.rest, ":rollback")) return f.rollbackSchema(arena, route, body);
                if (method == .DELETE and std.mem.eql(u8, route.rest, ":deleteRevision")) return f.deleteRevision(arena, route);
                if (method == .GET and std.mem.eql(u8, route.rest, ":listRevisions")) return f.listRevisions(arena, route);
                return notModelled(arena, route.rest);
            },
        }
    }

    // Topics.

    fn createTopic(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        if (!isResourceId(route.id)) return invalidName(arena, name);
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var topic: Topic = .{ .name = name };
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            const value = field.value_ptr.*;
            if (isField(key, "name")) continue;
            if (isField(key, "labels")) {
                topic.labels = switch (try labelsOf(arena, value)) {
                    .ok => |l| l,
                    .refused => |r| return r,
                };
            } else if (isField(key, "messageRetentionDuration")) {
                topic.retention_s = switch (try retentionOf(arena, value)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                };
            } else if (isField(key, "kmsKeyName")) {
                topic.kms_key_name = stringOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "messageStoragePolicy")) {
                topic.storage_policy = (try storagePolicyOf(arena, value)) orelse return badValue(arena, key);
            } else if (isField(key, "schemaSettings")) {
                topic.schema = switch (try f.schemaSettingsOf(arena, name, value, null)) {
                    .ok => |settings| settings,
                    .refused => |r| return r,
                };
            } else if (isField(key, "messageTransforms")) {
                topic.transforms = switch (try transformsOf(arena, value)) {
                    .ok => |list| list,
                    .refused => |r| return r,
                };
            } else if (isField(key, "ingestionDataSourceSettings")) {
                topic.ingestion = switch (try ingestionOf(arena, value)) {
                    .ok => |ingestion| ingestion,
                    .refused => |r| return r,
                };
            } else if (isField(key, "tags")) {
                topic.tags = switch (try tagsOf(arena, value)) {
                    .ok => |tags| tags,
                    .refused => |r| return r,
                };
            } else return unknownName(arena, key);
        }
        if (f.topics.contains(name)) return alreadyExists(arena, route.id);
        const stored = try f.keepTopic(topic);
        try f.insertSorted(Topic, &f.topics, stored);
        return ok(try renderTopic(arena, stored, .created));
    }

    fn getTopic(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        return ok(try renderTopic(arena, topic, .as_read));
    }

    fn deleteTopic(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        const topic = f.topics.get(name) orelse return notFound(arena, route.id);
        try f.orphans.append(f.gpa, topic);
        _ = f.topics.orderedRemove(name);
        // Its subscriptions and its snapshots stay, with what they hold,
        // and read `_deleted-topic_`.
        topic.deleted = true;
        return ok("{}");
    }

    fn updateTopic(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const update = switch (try parseUpdate(arena, body, "topic", "UpdateTopicRequest")) {
            .ok => |u| u,
            .refused => |r| return r,
        };
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        var next = topic.*;
        for (update.paths) |path| {
            const given = fieldOf(update.resource, path);
            if (isPath(path, "name")) {
                return immutable(arena, "UpdateTopicRequest", "name", "Topic");
            } else if (isPath(path, "labels")) {
                next.labels = if (given) |v| switch (try labelsOf(arena, v)) {
                    .ok => |l| try f.keepLabels(l),
                    .refused => |r| return r,
                } else &.{};
            } else if (isPath(path, "messageRetentionDuration")) {
                next.retention_s = if (given) |v| switch (try retentionOf(arena, v)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "kmsKeyName")) {
                next.kms_key_name = if (given) |v| try f.keep(stringOf(v) orelse return badValue(arena, path)) else null;
            } else if (isPath(path, "messageStoragePolicy")) {
                next.storage_policy = if (given) |v| try f.keepPolicy((try storagePolicyOf(arena, v)) orelse return badValue(arena, path)) else null;
            } else if (isPath(path, "schemaSettings")) {
                // The settings whole: with none in the body, the topic has
                // no schema.
                next.schema = if (given) |v| switch (try f.schemaSettingsOf(arena, topic.name, v, null)) {
                    .ok => |settings| settings,
                    .refused => |r| return r,
                } else null;
            } else if (partOf(path, "schemaSettings")) |part| {
                // One of the settings: the others stay as they are.
                const whole = fieldOf(update.resource, "schemaSettings") orelse Value{ .object = .empty };
                next.schema = switch (try f.schemaSettingsOf(arena, topic.name, whole, .{ .part = part, .of = next.schema })) {
                    .ok => |settings| settings,
                    .refused => |r| return r,
                };
            } else if (isPath(path, "messageTransforms")) {
                // The list whole: with none in the body, the topic has none.
                next.transforms = if (given) |v| switch (try transformsOf(arena, v)) {
                    .ok => |list| try f.keepWhole([]const Transform, list),
                    .refused => |r| return r,
                } else &.{};
            } else if (isPath(path, "ingestionDataSourceSettings")) {
                // The settings whole, the logging with them: with none
                // in the body, the topic imports nothing.
                next.ingestion = if (given) |v| switch (try ingestionOf(arena, v)) {
                    .ok => |ingestion| try f.keepWhole(Ingestion, ingestion),
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "tags")) {
                // Production took an update that names them, and changed
                // nothing.
            } else if (partOf(path, "messageTransforms") != null or partOf(path, "ingestionDataSourceSettings") != null) {
                return notModelled(arena, path);
            } else return unknownPath(arena, "UpdateTopicRequest", path, "Topic");
        }
        topic.* = next;
        return ok(try renderTopic(arena, topic, .after_update));
    }

    fn listTopics(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const prefix = try std.fmt.allocPrint(arena, "projects/{s}/topics/", .{route.project});
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.topics.keys(), f.topics.values()) |name, topic| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("topics") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            writeTopic(&jw, topic, .as_read) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    fn listTopicSubscriptions(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.subscriptions.keys(), f.subscriptions.values()) |name, s| {
            // A detached one is its topic's no longer.
            if (s.topic != topic or s.detached) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("subscriptions") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            jw.write(name) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    // Publish.

    fn publish(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        // Production's limit is on the request as it arrives.
        if (body.len > max_publish_bytes) return fail(arena, 400, "INVALID_ARGUMENT", "Request payload size exceeds the limit: 10485760 bytes.");
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        const list: []const Value = if (object.get("messages")) |m| switch (m) {
            .array => |a| a.items,
            else => return badValue(arena, "messages"),
        } else &.{};
        if (list.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "The value for message_count is too small. You passed 0 in the request, but the minimum value is 1.");
        if (list.len > 1000) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for message_count is too large. You passed {d} in the request, but the maximum value is 1000.", .{list.len}));

        const parsed = try arena.alloc(Message, list.len);
        for (list, parsed, 0..) |item, *message, index| {
            const m = switch (item) {
                .object => |o| o,
                else => return badValue(arena, "messages"),
            };
            message.* = .{ .id = 0, .data = "", .attributes = &.{}, .ordering_key = "", .publish_time = undefined };
            var it = m.iterator();
            while (it.next()) |field| {
                const key = field.key_ptr.*;
                const value = field.value_ptr.*;
                if (isField(key, "data")) {
                    const text = stringOf(value) orelse return badValue(arena, "data");
                    message.data = (try decodeBase64(arena, text)) orelse return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid value at 'messages[{d}].data' (TYPE_BYTES), Base64 decoding failed for \"{s}\"", .{ index, text }));
                } else if (isField(key, "attributes")) {
                    message.attributes = (try stringMapOf(arena, value)) orelse return badValue(arena, "attributes");
                } else if (isField(key, "orderingKey")) {
                    message.ordering_key = stringOf(value) orelse return badValue(arena, "orderingKey");
                } else if (isAnyField(key, &.{ "messageId", "publishTime" })) {
                    // Taken and ignored: the server chooses both.
                } else return unknownName(arena, key);
            }
            if (message.data.len == 0 and message.attributes.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "One or more messages in the publish request is empty. Each message must contain either non-empty data, or at least one attribute.");
            if (message.attributes.len > 100) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "There are too many attributes in the request. The request contains {d} attributes, but the maximum allowed is 100. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{message.attributes.len}));
            for (message.attributes) |a| {
                if (a.key.len == 0 or (startsWithGoog(a.key) and !isSchemaAttribute(a.key))) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The request contains an attribute key that is not valid (key={s}). Attribute keys must be non-empty and must not begin with 'goog' (case-insensitive).", .{a.key}));
                // The fake's words, after production's for a value: the
                // probe cut production's own short.
                if (a.key.len > 256) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The attribute \"{s}\" in the request has a key that is too large. The size is {d} bytes, but the maximum allowed is 256. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{ a.key, a.key.len }));
                if (a.value.len > 1024) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The attribute \"{s}\" in the request has a value that is too large. The size is {d} bytes, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{ a.key, a.value.len }));
            }
            if (message.ordering_key.len > 1024) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "An ordering key in the request is too long. The length is {d} characters, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.", .{message.ordering_key.len}));
            if (!std.mem.eql(u8, message.ordering_key, parsed[0].ordering_key)) return fail(arena, 400, "FAILED_PRECONDITION", "In a single publish request, all messages must have no ordering key or they must all have the same ordering key. [code=539b]");
        }

        // A topic with a schema takes a request only if every message of
        // it fits, and marks each with the encoding and the revision it
        // fit, over whatever the publisher wrote there. The schema's name
        // production leaves alone if the publisher wrote one.
        if (topic.schema) |settings| {
            for (parsed) |*message| {
                const revision_id = switch (try f.fit(arena, settings, message.data)) {
                    .ok => |id| id,
                    .refused => |r| return r,
                };
                var marked: std.ArrayList(Label) = .empty;
                var named = false;
                for (message.attributes) |a| {
                    if (std.mem.eql(u8, a.key, "googclient_schemaencoding") or std.mem.eql(u8, a.key, "googclient_schemarevisionid")) continue;
                    named = named or std.mem.eql(u8, a.key, "googclient_schemaname");
                    try marked.append(arena, a);
                }
                if (!named) try marked.append(arena, .{ .key = "googclient_schemaname", .value = settings.schema.name });
                try marked.append(arena, .{ .key = "googclient_schemaencoding", .value = encodingName(settings.encoding) });
                try marked.append(arena, .{ .key = "googclient_schemarevisionid", .value = revision_id });
                message.attributes = marked.items;
            }
        }

        const now = std.Io.Clock.real.now(f.io);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("messageIds") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;
        // Stored first, whole, so that a failure midway leaves nothing.
        const stored = try arena.alloc(*Message, parsed.len);
        for (parsed, stored) |m, *slot| {
            const kept = try f.store.allocator().create(Message);
            kept.* = .{
                .id = 0,
                .data = try f.keep(m.data),
                .attributes = try f.keepLabels(m.attributes),
                .ordering_key = try f.keep(m.ordering_key),
                .publish_time = now,
            };
            slot.* = kept;
        }
        try topic.messages.ensureUnusedCapacity(f.gpa, stored.len);
        for (f.subscriptions.values()) |s| {
            if (s.topic == topic) try s.entries.ensureUnusedCapacity(f.gpa, stored.len);
        }
        for (stored) |kept| {
            const id = f.next_message_id;
            f.next_message_id += 1;
            kept.id = id;
            topic.messages.appendAssumeCapacity(kept);
            for (f.subscriptions.values()) |s| {
                if (s.topic != topic or !s.takes(kept)) continue;
                s.entries.putAssumeCapacity(s.next_seq, .{ .message = kept });
                s.next_seq += 1;
            }
            var buf: [20]u8 = undefined;
            jw.write(std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable) catch return error.OutOfMemory;
        }
        jw.endArray() catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    // Subscriptions.

    fn createSubscription(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        if (!isResourceId(route.id)) return invalidName(arena, name);
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var sub: Subscription = .{ .name = name, .uid = 0, .topic = undefined };
        var topic_name: []const u8 = "";
        var expiration_given = false;
        var deadline_given = false;
        var push: ?Push = null;
        var bigquery: ?BigQuery = null;
        var storage: ?CloudStorage = null;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            const value = field.value_ptr.*;
            if (isField(key, "name")) continue;
            if (isField(key, "topic")) {
                topic_name = stringOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "ackDeadlineSeconds")) {
                const seconds = intOf(value) orelse return badValue(arena, key);
                // 0 is "not said", and gets the default.
                if (seconds != 0) {
                    if (seconds < 10 or seconds > 600) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 10 and 600 seconds.", .{seconds}));
                    sub.ack_deadline_s = @intCast(seconds);
                    deadline_given = true;
                }
            } else if (isField(key, "labels")) {
                sub.labels = switch (try labelsOf(arena, value)) {
                    .ok => |l| l,
                    .refused => |r| return r,
                };
            } else if (isField(key, "messageRetentionDuration")) {
                sub.retention_s = switch (try retentionOf(arena, value)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                };
            } else if (isField(key, "retainAckedMessages")) {
                sub.retain_acked = boolOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "expirationPolicy")) {
                expiration_given = true;
                sub.expiration_ttl_s = switch (try expirationOf(arena, value)) {
                    .ok => |ttl| ttl,
                    .refused => |r| return r,
                };
            } else if (isField(key, "pushConfig")) {
                push = switch (try pushOf(arena, value)) {
                    .ok => |config| config,
                    .refused => |r| return r,
                };
            } else if (isField(key, "bigqueryConfig")) {
                bigquery = switch (try bigQueryOf(arena, value)) {
                    .ok => |config| config,
                    .refused => |r| return r,
                };
            } else if (isField(key, "cloudStorageConfig")) {
                storage = switch (try cloudStorageOf(arena, value)) {
                    .ok => |config| config,
                    .refused => |r| return r,
                };
            } else if (isField(key, "bigtableConfig")) {
                // Production's answer was about its own project: an API
                // not enabled there.
                return notModelled(arena, "a Bigtable subscription");
            } else if (isField(key, "messageTransforms")) {
                sub.transforms = switch (try transformsOf(arena, value)) {
                    .ok => |list| list,
                    .refused => |r| return r,
                };
            } else if (isField(key, "tags")) {
                sub.tags = switch (try tagsOf(arena, value)) {
                    .ok => |tags| tags,
                    .refused => |r| return r,
                };
            } else if (isField(key, "enableMessageOrdering")) {
                sub.ordered = boolOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "enableExactlyOnceDelivery")) {
                sub.exactly_once = boolOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "filter")) {
                sub.filter_text = stringOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "deadLetterPolicy")) {
                sub.dead_letter = switch (try deadLetterOf(arena, value)) {
                    .ok => |policy| policy,
                    .refused => |r| return r,
                };
            } else if (isField(key, "retryPolicy")) {
                sub.retry = switch (try retryOf(arena, value)) {
                    .ok => |policy| policy,
                    .refused => |r| return r,
                };
            } else return unknownName(arena, key);
        }
        if (!isResourceName(topic_name, "topics")) return invalidName(arena, topic_name);
        sub.delivery = switch (try oneDelivery(arena, push, bigquery, storage, sub.exactly_once)) {
            .ok => |delivery| delivery,
            .refused => |r| return r,
        };
        sub.ack_deadline_s = fileDeadline(sub.delivery, sub.ack_deadline_s);
        if (sub.filter_text.len > 0) switch (try fake_filter.parse(arena, sub.filter_text)) {
            // Read again into the store when the subscription is kept.
            .ok => |filter| sub.filter = filter,
            .refused => |words| return fail(arena, 400, "INVALID_ARGUMENT", words),
            .not_modelled => |words| return fail(arena, 501, "UNIMPLEMENTED", words),
        };
        // With exactly-once delivery production's own deadline is a minute.
        if (sub.exactly_once and !deadline_given) sub.ack_deadline_s = 60;
        if (sub.dead_letter) |policy| {
            if (!f.topics.contains(policy.topic)) return notFound(arena, idOf(policy.topic));
        }
        if (expirationRefusal(arena, sub.retention_s, sub.expiration_ttl_s, expiration_given)) |refusal| return try refusal;
        if (f.subscriptions.contains(name)) return alreadyExists(arena, route.id);
        const topic = f.topics.get(topic_name) orelse return notFound(arena, idOf(topic_name));
        sub.topic = topic;
        sub.joined = topic.messages.items.len;
        sub.uid = f.next_uid;
        f.next_uid += 1;
        const stored = try f.keepSubscription(sub);
        try f.insertSorted(Subscription, &f.subscriptions, stored);
        return ok(try renderSubscription(arena, stored, .created));
    }

    /// A subscription's push config by itself: with an endpoint it is a
    /// push subscription, and with none it pulls again.
    fn modifyPushConfig(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        var push: ?Push = null;
        var it = object.iterator();
        while (it.next()) |field| {
            if (!isField(field.key_ptr.*, "pushConfig")) return unknownName(arena, field.key_ptr.*);
            push = switch (try pushOf(arena, field.value_ptr.*)) {
                .ok => |config| config,
                .refused => |r| return r,
            };
        }
        // Production was asked this of subscriptions that push or pull.
        if (sub.delivery == .bigquery or sub.delivery == .cloud_storage) return notModelled(arena, "modifyPushConfig on a subscription that exports");
        sub.delivery = switch (try oneDelivery(arena, push, null, null, sub.exactly_once)) {
            .ok => |delivery| try f.keepWhole(Delivery, delivery),
            .refused => |r| return r,
        };
        return ok("{}");
    }

    fn getSubscription(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        return ok(try renderSubscription(arena, sub, .as_read));
    }

    fn deleteSubscription(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        const sub = f.subscriptions.get(name) orelse return notFound(arena, route.id);
        try f.dropped.append(f.gpa, sub);
        _ = f.subscriptions.orderedRemove(name);
        return ok("{}");
    }

    fn updateSubscription(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const update = switch (try parseUpdate(arena, body, "subscription", "UpdateSubscriptionRequest")) {
            .ok => |u| u,
            .refused => |r| return r,
        };
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        var next = sub.*;
        var expiration_given = false;
        // What the subscription has of each kind of delivery, which a
        // mask path replaces whole or clears.
        var push: ?Push = if (sub.delivery == .push) sub.delivery.push else null;
        var bigquery: ?BigQuery = if (sub.delivery == .bigquery) sub.delivery.bigquery else null;
        var storage: ?CloudStorage = if (sub.delivery == .cloud_storage) sub.delivery.cloud_storage else null;
        for (update.paths) |path| {
            const given = fieldOf(update.resource, path);
            if (isPath(path, "name")) {
                return immutable(arena, "UpdateSubscriptionRequest", "name", "Subscription");
            } else if (isPath(path, "topic")) {
                return immutable(arena, "UpdateSubscriptionRequest", "topic", "Subscription");
            } else if (isPath(path, "filter")) {
                return immutable(arena, "UpdateSubscriptionRequest", "filter", "Subscription");
            } else if (isPath(path, "enableMessageOrdering")) {
                return immutable(arena, "UpdateSubscriptionRequest", "enable_message_ordering", "Subscription");
            } else if (isPath(path, "ackDeadlineSeconds")) {
                const seconds = if (given) |v| intOf(v) orelse return badValue(arena, path) else 10;
                if (seconds < 10 or seconds > 600) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 10 and 600 seconds.", .{seconds}));
                next.ack_deadline_s = @intCast(seconds);
            } else if (isPath(path, "labels")) {
                next.labels = if (given) |v| switch (try labelsOf(arena, v)) {
                    .ok => |l| try f.keepLabels(l),
                    .refused => |r| return r,
                } else &.{};
            } else if (isPath(path, "messageRetentionDuration")) {
                next.retention_s = if (given) |v| switch (try retentionOf(arena, v)) {
                    .ok => |s| s,
                    .refused => |r| return r,
                } else 604_800;
            } else if (isPath(path, "retainAckedMessages")) {
                next.retain_acked = if (given) |v| boolOf(v) orelse return badValue(arena, path) else false;
            } else if (isPath(path, "expirationPolicy")) {
                expiration_given = given != null;
                next.expiration_ttl_s = if (given) |v| switch (try expirationOf(arena, v)) {
                    .ok => |ttl| ttl,
                    .refused => |r| return r,
                } else 2_678_400;
            } else if (isPath(path, "deadLetterPolicy")) {
                next.dead_letter = if (given) |v| switch (try deadLetterOf(arena, v)) {
                    .ok => |policy| policy: {
                        if (!f.topics.contains(policy.topic)) return notFound(arena, idOf(policy.topic));
                        break :policy .{ .topic = try f.keep(policy.topic), .max_attempts = policy.max_attempts };
                    },
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "retryPolicy")) {
                next.retry = if (given) |v| switch (try retryOf(arena, v)) {
                    .ok => |policy| policy,
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "enableExactlyOnceDelivery")) {
                next.exactly_once = if (given) |v| boolOf(v) orelse return badValue(arena, path) else false;
            } else if (isPath(path, "pushConfig")) {
                push = if (given) |v| switch (try pushOf(arena, v)) {
                    .ok => |config| config,
                    .refused => |r| return r,
                } else null;
            } else if (sameField(path, "pushConfig.pushEndpoint")) {
                // The endpoint alone: what else the push config holds
                // stays. With none in the body the subscription pulls.
                const whole = fieldOf(update.resource, "pushConfig") orelse Value{ .object = .empty };
                const endpoint = switch (whole) {
                    .object => |o| if (fieldOf(o, "pushEndpoint")) |v| stringOf(v) orelse return badValue(arena, path) else "",
                    else => return badValue(arena, "pushConfig"),
                };
                if (endpoint.len == 0) {
                    push = null;
                } else {
                    if (!isPushEndpoint(endpoint)) return badEndpoint(arena, endpoint);
                    var config: Push = push orelse .{ .endpoint = "" };
                    config.endpoint = endpoint;
                    push = config;
                }
            } else if (isPath(path, "bigqueryConfig")) {
                bigquery = if (given) |v| switch (try bigQueryOf(arena, v)) {
                    .ok => |config| config,
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "cloudStorageConfig")) {
                storage = if (given) |v| switch (try cloudStorageOf(arena, v)) {
                    .ok => |config| config,
                    .refused => |r| return r,
                } else null;
            } else if (isPath(path, "bigtableConfig")) {
                // Named and not given, production changed nothing.
                if (given != null) return notModelled(arena, "a Bigtable subscription");
            } else if (isPath(path, "messageTransforms")) {
                next.transforms = if (given) |v| switch (try transformsOf(arena, v)) {
                    .ok => |list| try f.keepWhole([]const Transform, list),
                    .refused => |r| return r,
                } else &.{};
            } else if (isPath(path, "tags")) {
                // Of a topic's, production took the update and changed
                // nothing. Of a subscription's it was not asked.
                return notModelled(arena, "an update of a subscription's tags");
            } else if (partOf(path, "pushConfig") != null or partOf(path, "bigqueryConfig") != null or partOf(path, "cloudStorageConfig") != null or partOf(path, "messageTransforms") != null) {
                // Production was shown one path inside a config.
                return notModelled(arena, path);
            } else return unknownPath(arena, "UpdateSubscriptionRequest", path, "Subscription");
        }
        if (expirationRefusal(arena, next.retention_s, next.expiration_ttl_s, expiration_given)) |refusal| return try refusal;
        next.delivery = switch (try oneDelivery(arena, push, bigquery, storage, next.exactly_once)) {
            .ok => |delivery| try f.keepWhole(Delivery, delivery),
            .refused => |r| return r,
        };
        next.ack_deadline_s = fileDeadline(next.delivery, next.ack_deadline_s);
        sub.* = next;
        // Production's answer to an update leaves `detached` out, though
        // a read right after says it.
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeSubscription(&jw, sub, .after_update) catch return error.OutOfMemory;
        return ok(out.written());
    }

    fn listSubscriptions(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const prefix = try std.fmt.allocPrint(arena, "projects/{s}/subscriptions/", .{route.project});
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.subscriptions.keys(), f.subscriptions.values()) |name, sub| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("subscriptions") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            writeSubscription(&jw, sub, .as_read) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    // Pull, acknowledge, and leases.

    fn pull(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) tp.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const name = try resourceName(arena, route);
        if (!f.subscriptions.contains(name)) return notFound(arena, route.id);
        var wanted: i64 = 0;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "maxMessages")) {
                wanted = intOf(field.value_ptr.*) orelse return badValue(arena, key);
            } else if (isField(key, "returnImmediately")) {
                _ = boolOf(field.value_ptr.*) orelse return badValue(arena, key);
            } else return unknownName(arena, key);
        }
        if (wanted <= 0) return fail(arena, 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=max_messages).");
        // Production takes 1001 and more; what it then returns is its own
        // affair, and here it is at most 1000.
        const max: usize = @intCast(@min(wanted, 1000));

        const hold_until = f.awakeNow() + f.options.empty_pull_hold.nanoseconds;
        while (true) {
            // A lease that lapses while the pull is held is settled as at
            // any other time.
            const now = f.awakeNow();
            try f.settleAll(now);
            // Looked up each time round: the subscription may be deleted
            // or detached while a pull is held.
            const sub = f.subscriptions.get(name) orelse return notFound(arena, route.id);
            if (sub.detached) return detachedRefusal(arena);
            if (sub.delivery != .pull) return notThisKind(arena);
            const ready = try f.readyEntries(arena, sub, now);
            if (ready.len > 0) return f.deliver(arena, sub, ready[0..@min(ready.len, max)], now);
            if (now >= hold_until) return ok("{}");
            // Nothing wakes a held pull but time: it looks again shortly,
            // which a test's clock can bring about as well as a real one.
            const step: i96 = @min(hold_until - now, 5 * std.time.ns_per_ms);
            f.mutex.unlock(f.io);
            const slept = f.io.sleep(.{ .nanoseconds = step }, .awake);
            f.mutex.lockUncancelable(f.io);
            slept catch return error.Canceled;
        }
    }

    /// Brings every subscription up to `now`. Leases lapse with time and
    /// nothing else, and what follows a lapse (a dead letter forwarded, a
    /// message past its retention gone) production does without being
    /// asked, so it is done before each request.
    fn settleAll(f: *FakePubSub, now: i96) Allocator.Error!void {
        // By index: a forwarded dead letter may add to another's entries,
        // never to the list of subscriptions.
        var i: usize = 0;
        while (i < f.subscriptions.count()) : (i += 1) try f.settle(f.subscriptions.values()[i], now);
    }

    /// One subscription, brought up to `now`: messages past its retention
    /// go, lapsed leases end, and a message that has had its last attempt
    /// moves to the dead-letter topic.
    fn settle(f: *FakePubSub, sub: *Subscription, now: i96) Allocator.Error!void {
        const wall = std.Io.Clock.real.now(f.io).nanoseconds;
        const keep_ns = @as(i96, sub.retention_s) * std.time.ns_per_s;
        var i: usize = 0;
        while (i < sub.entries.count()) {
            const entry = sub.entries.values()[i];
            if (wall - entry.message.publish_time.nanoseconds >= keep_ns) {
                // An acknowledged one kept behind it is younger, and goes
                // the same way in its turn.
                sub.entries.orderedRemoveAt(i);
                continue;
            }
            if (entry.lease_until) |until| {
                // The backoff runs from the lapse, not from when it was
                // noticed.
                if (until <= now and try f.released(sub, i, until)) continue;
            }
            i += 1;
        }
    }

    /// A delivery that ended without an ack, by a lapse or a nack, at
    /// `at`. After its last attempt the message is forwarded to the
    /// dead-letter topic; otherwise it waits again, as long as the retry
    /// policy says. On a subscription with ordering every later message
    /// of its key is taken back with it, the acknowledged ones included:
    /// production delivered k2 to k5 again after a nack of k2 alone, with
    /// k3 to k5 acknowledged. (That a forwarded one takes them back too
    /// is the fake's own choice.) True when the entry at `index` is gone.
    /// A failure leaves everything as it was.
    fn released(f: *FakePubSub, sub: *Subscription, index: usize, at: i96) Allocator.Error!bool {
        const entry = sub.entries.values()[index];
        var gone = false;
        if (sub.dead_letter) |policy| forwarded: {
            if (entry.deliveries < policy.max_attempts) break :forwarded;
            // Production forwards only when its service agent may publish
            // there and acknowledge here, and otherwise goes on delivering.
            // With no topic to forward to, the fake goes on delivering too.
            const dead = f.topics.get(policy.topic) orelse break :forwarded;
            if (f.options.service_agent) |agent| {
                if (!dead.policy.grants(agent, &.{ "roles/pubsub.publisher", "roles/pubsub.editor", "roles/pubsub.admin", "roles/editor" })) break :forwarded;
                if (!sub.policy.grants(agent, &.{ "roles/pubsub.subscriber", "roles/pubsub.editor", "roles/pubsub.admin", "roles/editor" })) break :forwarded;
            }
            try f.forward(sub, entry, dead);
            sub.entries.orderedRemoveAt(index);
            gone = true;
        }
        if (!gone) {
            const waiting = &sub.entries.values()[index];
            waiting.lease_until = null;
            if (sub.retry) |retry| waiting.not_before = at + backoff(retry, entry.deliveries) * std.time.ns_per_s;
        }
        if (sub.keyed(entry)) {
            // What it remembers of the ids that acknowledged them is
            // written over when they are acknowledged again.
            for (sub.entries.values()[index + @intFromBool(!gone) ..]) |*later| {
                if (!std.mem.eql(u8, later.message.ordering_key, entry.message.ordering_key)) continue;
                later.lease_until = null;
                later.acked = false;
            }
        }
        return gone;
    }

    /// The fake's own rule, inside what production showed: the minimum,
    /// doubling with each delivery, up to the maximum. Production's delays
    /// under a 10 to 20 second policy were 10, 11.5, 17 and 16.5 seconds
    /// after a nack, and 15 and 16 after a lapse.
    fn backoff(retry: Retry, deliveries: u32) i96 {
        const doublings: u6 = @intCast(@min(deliveries -| 1, 20));
        return @min(retry.max_s, retry.min_s << doublings);
    }

    /// A dead letter: the message again, on the dead-letter topic, marked
    /// with where it came from. The first two attributes are as production
    /// wrote them (2026-09-28); the other two are Google's documentation.
    fn forward(f: *FakePubSub, sub: *const Subscription, entry: Entry, dead: *Topic) Allocator.Error!void {
        const store = f.store.allocator();
        const m = entry.message;
        const attributes = try store.alloc(Label, m.attributes.len + 4);
        @memcpy(attributes[0..m.attributes.len], m.attributes);
        var time_buf: [timestamp.max_len]u8 = undefined;
        const rest = idOf(sub.name);
        const project = sub.name["projects/".len .. sub.name.len - "/subscriptions/".len - rest.len];
        attributes[m.attributes.len..][0..4].* = .{
            .{ .key = "CloudPubSubDeadLetterSourceDeliveryCount", .value = try std.fmt.allocPrint(store, "{d}", .{entry.deliveries}) },
            .{ .key = "CloudPubSubDeadLetterSourceSubscription", .value = rest },
            .{ .key = "CloudPubSubDeadLetterSourceSubscriptionProject", .value = project },
            .{ .key = "CloudPubSubDeadLetterSourceTopicPublishTime", .value = try store.dupe(u8, timestamp.format(&time_buf, m.publish_time)) },
        };
        const kept = try store.create(Message);
        kept.* = .{ .id = f.next_message_id, .data = m.data, .attributes = attributes, .ordering_key = m.ordering_key, .publish_time = std.Io.Clock.real.now(f.io) };
        try dead.messages.ensureUnusedCapacity(f.gpa, 1);
        for (f.subscriptions.values()) |s| {
            if (s.topic == dead) try s.entries.ensureUnusedCapacity(f.gpa, 1);
        }
        f.next_message_id += 1;
        dead.messages.appendAssumeCapacity(kept);
        for (f.subscriptions.values()) |s| {
            if (s.topic != dead or !s.takes(kept)) continue;
            s.entries.putAssumeCapacity(s.next_seq, .{ .message = kept });
            s.next_seq += 1;
        }
    }

    /// The numbers of the entries a pull may give at `now`, to which the
    /// subscription is settled: the ones waiting whose backoff, if any,
    /// has run, and that ordering does not hold back. In an order of the
    /// fake's choosing when `shuffle` is on.
    fn readyEntries(f: *FakePubSub, arena: Allocator, sub: *Subscription, now: i96) Allocator.Error![]u64 {
        var ready: std.ArrayList(u64) = .empty;
        // The keys that give nothing more, with ordering. A key with a
        // message out gives none until that one is acknowledged or comes
        // back: production held k2 fourteen seconds behind k1, and gave
        // it a second after k1's ack. What a key has waiting it gives
        // together, in one pull. A message waiting out its backoff holds
        // the later ones of its key behind it. And with exactly-once
        // delivery as well a key gives one message at a time, as
        // production gave m1 alone of three published together.
        var held: std.StringHashMapUnmanaged(void) = .empty;
        if (sub.ordered) for (sub.entries.values()) |entry| {
            if (entry.lease_until != null and sub.keyed(entry)) try held.put(arena, entry.message.ordering_key, {});
        };
        for (sub.entries.keys(), sub.entries.values()) |seq, entry| {
            if (entry.acked or entry.lease_until != null) continue;
            const key = entry.message.ordering_key;
            if (sub.keyed(entry) and held.contains(key)) continue;
            if (entry.not_before > now) {
                if (sub.keyed(entry)) try held.put(arena, key, {});
                continue;
            }
            try ready.append(arena, seq);
            if (sub.keyed(entry) and sub.exactly_once) try held.put(arena, key, {});
        }
        if (f.options.shuffle) try f.mix(arena, sub, ready.items);
        return ready.items;
    }

    /// Puts `ready`, which is in the order published, in an order of the
    /// fake's choosing. On a subscription with ordering each key's
    /// messages still come in their own order, as production's did: the
    /// keys among themselves and the messages without one in any.
    fn mix(f: *FakePubSub, arena: Allocator, sub: *const Subscription, ready: []u64) Allocator.Error!void {
        if (!sub.ordered) return f.prng.random().shuffle(u64, ready);
        const published = try arena.dupe(u64, ready);
        f.prng.random().shuffle(u64, ready);
        // Each key's places in the new order, filled with its messages in
        // the old one.
        const Places = struct { at: std.ArrayList(usize) = .empty, filled: usize = 0 };
        var places: std.StringHashMapUnmanaged(Places) = .empty;
        for (ready, 0..) |seq, at| {
            const key = sub.entries.get(seq).?.message.ordering_key;
            if (key.len == 0) continue;
            const slot = try places.getOrPutValue(arena, key, .{});
            try slot.value_ptr.at.append(arena, at);
        }
        for (published) |seq| {
            const key = sub.entries.get(seq).?.message.ordering_key;
            if (key.len == 0) continue;
            const slot = places.getPtr(key).?;
            ready[slot.at.items[slot.filled]] = seq;
            slot.filled += 1;
        }
    }

    fn deliver(f: *FakePubSub, arena: Allocator, sub: *Subscription, seqs: []const u64, now: i96) Allocator.Error!Reply {
        _ = f;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("receivedMessages") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;
        const until = now + @as(i96, sub.ack_deadline_s) * std.time.ns_per_s;
        for (seqs) |seq| {
            const entry = sub.entries.getPtr(seq).?;
            const m = entry.message;
            jw.beginObject() catch return error.OutOfMemory;
            jw.objectField("ackId") catch return error.OutOfMemory;
            jw.write(try ackId(arena, sub.uid, seq, entry.deliveries + 1)) catch return error.OutOfMemory;
            jw.objectField("message") catch return error.OutOfMemory;
            jw.beginObject() catch return error.OutOfMemory;
            if (m.data.len > 0) {
                jw.objectField("data") catch return error.OutOfMemory;
                const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(m.data.len));
                jw.write(std.base64.standard.Encoder.encode(encoded, m.data)) catch return error.OutOfMemory;
            }
            if (m.attributes.len > 0) {
                jw.objectField("attributes") catch return error.OutOfMemory;
                writeLabels(&jw, m.attributes) catch return error.OutOfMemory;
            }
            var id_buf: [20]u8 = undefined;
            jw.objectField("messageId") catch return error.OutOfMemory;
            jw.write(std.fmt.bufPrint(&id_buf, "{d}", .{m.id}) catch unreachable) catch return error.OutOfMemory;
            var time_buf: [timestamp.max_len]u8 = undefined;
            jw.objectField("publishTime") catch return error.OutOfMemory;
            jw.write(timestamp.format(&time_buf, m.publish_time)) catch return error.OutOfMemory;
            if (m.ordering_key.len > 0) {
                jw.objectField("orderingKey") catch return error.OutOfMemory;
                jw.write(m.ordering_key) catch return error.OutOfMemory;
            }
            jw.endObject() catch return error.OutOfMemory;
            // Sent only with a dead-letter policy, as production sends it.
            if (sub.dead_letter != null) {
                jw.objectField("deliveryAttempt") catch return error.OutOfMemory;
                jw.write(entry.deliveries + 1) catch return error.OutOfMemory;
            }
            jw.endObject() catch return error.OutOfMemory;
        }
        jw.endArray() catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;
        // The answer is whole: only now are the messages out.
        for (seqs) |seq| {
            const entry = sub.entries.getPtr(seq).?;
            entry.lease_until = until;
            entry.deliveries += 1;
        }
        return ok(out.written());
    }

    const AckRequest = struct { ids: []const AckId, seconds: ?i64 };

    /// The ids of an acknowledge or a modifyAckDeadline, each checked as
    /// production checks it, before any is acted on.
    fn ackRequest(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!union(enum) { ok: struct { sub: *Subscription, request: AckRequest }, refused: Reply } {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return .{ .refused = r },
        };
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return .{ .refused = try notFound(arena, route.id) };
        if (sub.detached) return .{ .refused = try detachedRefusal(arena) };
        var ids: []const Value = &.{};
        var seconds: ?i64 = null;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "ackIds")) {
                ids = switch (field.value_ptr.*) {
                    .array => |a| a.items,
                    else => return .{ .refused = try badValue(arena, key) },
                };
            } else if (isField(key, "ackDeadlineSeconds")) {
                seconds = intOf(field.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
            } else return .{ .refused = try unknownName(arena, key) };
        }
        if (ids.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "You have not specified an ack ID in the request.") };
        const parsed_ids = try arena.alloc(AckId, ids.len);
        for (ids, parsed_ids) |id, *slot| {
            const text = stringOf(id) orelse return .{ .refused = try badValue(arena, "ackIds") };
            const parsed = parseAckId(text) orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid ack ID to the service (ack_id={s}).", .{text})) };
            if (parsed.uid != sub.uid) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed a subscription that does not belong to the given ack ID (resource={s}).", .{sub.name})) };
            slot.* = .{ .text = text, .seq = parsed.seq, .delivery = parsed.delivery };
        }
        return .{ .ok = .{ .sub = sub, .request = .{ .ids = parsed_ids, .seconds = seconds } } };
    }

    const Judged = struct {
        /// For each id of the request: the number of the entry it may
        /// act on. Null: none.
        acts: []const ?u64,
        /// The ids an exactly-once refusal names, each once.
        refused: []const []const u8,
    };

    /// What an id is sent to do.
    const Asked = union(enum) {
        ack,
        /// A lease of so many seconds from now. None: a nack.
        lease: i64,
    };

    /// Says of each id of an acknowledge or a modifyAckDeadline whether it
    /// may act, as the request finds things, before any of them acts:
    /// with ordering a nack takes the later messages of its key back, and
    /// their own ids in the same request come no later for that.
    ///
    /// An id that may not act is answered and forgotten: the message is
    /// taken only while it is out, and after a lapse or a nack it comes
    /// again. With exactly-once delivery the id is refused instead, a
    /// lapsed message's and an acknowledged one's alike. Production took
    /// one such: a second ack with the very id that acknowledged the
    /// message. With an id of an earlier delivery of it, it refused.
    ///
    /// A seek ends no id. One from before it goes on naming its message
    /// (all measured 2026-10-13):
    ///
    /// - Without exactly-once delivery the lease decides, as ever: the id
    ///   acts once the message is out again, to acknowledge it and to give
    ///   it back, and is answered and forgotten until then.
    /// - With it, the delivery the id is of goes on being out, on the
    ///   lease it had, through the seek. While that lease runs an ack by
    ///   the id is answered, and acknowledges the message if the message
    ///   is out again; a longer lease is answered, and runs; a nack is
    ///   answered if the message is out again, and gives nothing back,
    ///   and is refused if it is not, and then the id is done. Once the
    ///   lease is over the id is refused, but for an ack by one that was
    ///   answered before. (What a longer lease or a nack by such an id
    ///   does to the message's present delivery was not measured beyond
    ///   that: nothing, here.)
    fn judge(f: *FakePubSub, arena: Allocator, sub: *Subscription, ids: []const AckId, now: i96, asked: Asked) Allocator.Error!Judged {
        const acts = try arena.alloc(?u64, ids.len);
        var refused: std.ArrayList([]const u8) = .empty;
        each: for (ids, acts) |id, *slot| {
            slot.* = null;
            const answered = if (id.seq < sub.stale_below)
                try f.judgeOld(sub, id, now, asked, slot)
            else answered: {
                const index = sub.entries.getIndex(id.seq);
                // Gone, or kept behind an earlier one of its key.
                const acknowledged = if (index) |i| sub.entries.values()[i].acked else true;
                if (!acknowledged and sub.live(index.?, id, now)) slot.* = id.seq;
                break :answered slot.* != null or !sub.exactly_once or (acknowledged and asked == .ack and sub.tookIt(id));
            };
            if (answered) continue;
            for (refused.items) |named| {
                if (std.mem.eql(u8, named, id.text)) continue :each;
            }
            try refused.append(arena, id.text);
        }
        return .{ .acts = acts, .refused = refused.items };
    }

    /// An id from before a seek: whether it is answered, and in `slot`
    /// the entry it acts on, if any. See `judge`.
    fn judgeOld(f: *FakePubSub, sub: *Subscription, id: AckId, now: i96, asked: Asked, slot: *?u64) Allocator.Error!bool {
        const record = sub.old.getPtr(id.seq);
        const message = if (record) |o| o.message else if (sub.acknowledged.get(id.seq)) |acked| acked.message else null;
        const present: ?u64 = present: {
            const index = sub.entryOf(message orelse break :present null) orelse break :present null;
            const entry = sub.entries.values()[index];
            // An acknowledged one that is kept has no lease.
            const out = entry.lease_until != null and entry.lease_until.? > now;
            break :present if (out) sub.entries.keys()[index] else null;
        };
        if (!sub.exactly_once) {
            slot.* = present;
            return true;
        }
        const old = record orelse return asked == .ack and sub.tookIt(id);
        const running = old.delivery == id.delivery and old.until != null and old.until.? > now;
        if (!running) return asked == .ack and sub.tookIt(id);
        switch (asked) {
            .ack => {
                try sub.acknowledged.put(f.gpa, id.seq, .{ .delivery = id.delivery, .message = old.message });
                old.until = null;
                slot.* = present;
            },
            .lease => |seconds| if (seconds > 0) {
                old.until = now + @as(i96, seconds) * std.time.ns_per_s;
            } else if (present == null) {
                old.until = null;
                return false;
            },
        }
        return true;
    }

    fn acknowledge(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const checked = switch (try f.ackRequest(arena, route, body)) {
            .ok => |c| c,
            .refused => |r| return r,
        };
        const sub = checked.sub;
        const judged = try f.judge(arena, sub, checked.request.ids, f.awakeNow(), .ack);
        for (checked.request.ids, judged.acts) |id, acts| {
            const seq = acts orelse continue;
            // Looked up for each: the one before it may have been the
            // same id.
            const index = sub.entries.getIndex(seq) orelse continue;
            // By an id from before a seek, no delivery of this entry
            // acknowledged it.
            if (!sub.entries.values()[index].acked) try sub.take(f.gpa, index, if (seq == id.seq) id.delivery else 0);
        }
        // The ids it does not name were taken.
        if (judged.refused.len > 0) return exactlyOnceRefusal(arena, judged.refused);
        return ok("{}");
    }

    fn modifyAckDeadline(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        // Before its ids are read: production refused a lease change on a
        // push subscription for its kind, and an ack there for its id.
        if (f.subscriptions.get(try resourceName(arena, route))) |sub| {
            if (sub.delivery != .pull and !sub.detached) return notThisKind(arena);
        }
        const checked = switch (try f.ackRequest(arena, route, body)) {
            .ok => |c| c,
            .refused => |r| return r,
        };
        const seconds = checked.request.seconds orelse 0;
        if (seconds < 0 or seconds > 600) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 0 and 600 seconds.", .{seconds}));
        const sub = checked.sub;
        const now = f.awakeNow();
        const judged = try f.judge(arena, sub, checked.request.ids, now, .{ .lease = seconds });
        for (judged.acts) |acts| {
            // Looked up for each: a nack before it may have moved it, or
            // forwarded it, the same id sent twice.
            const index = sub.entries.getIndex(acts orelse continue) orelse continue;
            // Zero gives the message back at once: a nack. One that an
            // earlier nack of the request took back is released all the
            // same: it was out, and it is given back.
            if (seconds == 0) {
                _ = try f.released(sub, index, now);
            } else sub.entries.values()[index].lease_until = now + @as(i96, seconds) * std.time.ns_per_s;
        }
        if (judged.refused.len > 0) return exactlyOnceRefusal(arena, judged.refused);
        return ok("{}");
    }

    // IAM. A policy is read whole, written whole, and guarded by its etag.

    /// The policy of the resource a route names; null when there is none
    /// such.
    fn policyAt(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!?*Policy {
        const name = try resourceName(arena, route);
        return switch (route.collection) {
            .topics => if (f.topics.get(name)) |t| &t.policy else null,
            .subscriptions => if (f.subscriptions.get(name)) |s| &s.policy else null,
            .snapshots => if (f.snapshots.get(name)) |s| &s.policy else null,
            .schemas => if (f.schemas.get(name)) |s| &s.policy else null,
        };
    }

    fn getIamPolicy(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        // Production takes any integer for the version asked for.
        if (try queryValue(arena, route.query, "options.requestedPolicyVersion")) |text| {
            _ = std.fmt.parseInt(i32, text, 10) catch return badValue(arena, "options.requestedPolicyVersion");
        }
        const policy = (try f.policyAt(arena, route)) orelse return notFound(arena, route.id);
        return ok(try renderPolicy(arena, policy.*));
    }

    /// The policy whole: what the request does not hold is gone. With an
    /// etag, only if the policy is still the one that was read. Every
    /// write moves the etag, one that changes nothing included, and the
    /// answer is what a read right after gives.
    fn setIamPolicy(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const policy = (try f.policyAt(arena, route)) orelse return notFound(arena, route.id);
        var given: ?std.json.ObjectMap = null;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "policy")) {
                given = switch (field.value_ptr.*) {
                    .object => |o| o,
                    else => return badValue(arena, key),
                };
            } else if (isField(key, "updateMask")) {
                return notModelled(arena, "a setIamPolicy with an update mask");
            } else return unknownName(arena, key);
        }
        const wanted = given orelse return notModelled(arena, "a setIamPolicy with no policy");
        var etag: []const u8 = "";
        var bindings: []const Value = &.{};
        var parts = wanted.iterator();
        while (parts.next()) |part| {
            const key = part.key_ptr.*;
            if (isField(key, "etag")) {
                etag = stringOf(part.value_ptr.*) orelse return badValue(arena, key);
            } else if (isField(key, "bindings")) {
                bindings = switch (part.value_ptr.*) {
                    .array => |a| a.items,
                    else => return badValue(arena, key),
                };
            } else if (isField(key, "version")) {
                _ = intOf(part.value_ptr.*) orelse return badValue(arena, key);
            } else if (isField(key, "auditConfigs")) {
                return notModelled(arena, "audit configs in a policy");
            } else return unknownName(arena, key);
        }
        // No etag, or an empty one, writes over whatever is there.
        if (etag.len > 0) {
            // As production refuses the bytes of a message that are no
            // base64: its words for an etag were not kept.
            const raw = (try decodeBase64(arena, etag)) orelse return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid value at 'policy.etag' (TYPE_BYTES), Base64 decoding failed for \"{s}\"", .{etag}));
            var buf: [8]u8 = undefined;
            if (!std.mem.eql(u8, raw, etagBytes(&buf, policy.stamp))) {
                // What is no etag at all is never the mismatch.
                if (!isEtag(raw)) return fail(arena, 400, "INVALID_ARGUMENT", "Invalid etag");
                return fail(arena, 409, "ABORTED", "There were concurrent policy changes. Please retry the whole read-modify-write with exponential backoff.");
            }
        }
        const stored = switch (try bindingsOf(arena, route.collection == .subscriptions, bindings)) {
            .ok => |list| try f.keepWhole([]const Policy.Binding, list),
            .refused => |r| return r,
        };
        const wall: u64 = @intCast(@max(0, @divFloor(std.Io.Clock.real.now(f.io).nanoseconds, std.time.ns_per_us)));
        f.last_stamp = @max(f.last_stamp + 1, wall);
        policy.* = .{ .stamp = f.last_stamp, .bindings = stored };
        return ok(try renderPolicy(arena, policy.*));
    }

    /// Which of the permissions asked the caller holds. The fake has no
    /// callers: whoever asks holds every permission of the resource, as
    /// the owner production answered did, and gets them back by name, one
    /// asked twice twice. Production's words for what it refuses here
    /// were not kept: the fake says what production says of an argument
    /// it gives no reason for.
    fn testIamPermissions(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        if ((try f.policyAt(arena, route)) == null) return notFound(arena, route.id);
        var list: []const Value = &.{};
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (!isField(key, "permissions")) return unknownName(arena, key);
            list = switch (field.value_ptr.*) {
                .array => |a| a.items,
                else => return badValue(arena, key),
            };
        }
        const unreasoned = "Request contains an invalid argument.";
        if (list.len == 0 or list.len > 100) return fail(arena, 400, "INVALID_ARGUMENT", unreasoned);
        const names = try arena.alloc([]const u8, list.len);
        for (list, names) |item, *slot| {
            const name = stringOf(item) orelse return badValue(arena, "permissions");
            switch (permissionKind(route.collection, name)) {
                .held => slot.* = name,
                // A wildcard, another service's, or no permission's name.
                .refused => return fail(arena, 400, "INVALID_ARGUMENT", unreasoned),
                // One of Pub/Sub's the fake has no list of, or of
                // another kind of resource.
                .unknown => return notModelled(arena, try std.fmt.allocPrint(arena, "the permission {s} on this resource", .{name})),
            }
        }
        std.mem.sort([]const u8, names, {}, struct {
            fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lessThan);
        return ok(try Stringify.valueAlloc(arena, .{ .permissions = names }, .{}));
    }

    // Schemas. A definition is kept and not read: an Avro one must be
    // JSON, and a Protocol Buffer one is taken as text.

    fn createSchema(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const id = (try queryValue(arena, route.query, "schemaId")) orelse "";
        const name = try std.fmt.allocPrint(arena, "projects/{s}/schemas/{s}", .{ route.project, id });
        if (!isResourceId(id)) return invalidName(arena, name);
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const given = switch (try schemaOf(arena, .{ .object = object })) {
            .ok => |s| s,
            .refused => |r| return r,
        };
        if (f.schemas.contains(name)) return fail(arena, 409, "ALREADY_EXISTS", try std.fmt.allocPrint(arena, "Resource already exists in the project (resource={s}).", .{name}));
        const schema = try f.store.allocator().create(Schema);
        schema.* = .{ .name = try f.keep(name), .uid = f.next_uid, .type = given.type };
        errdefer schema.revisions.deinit(f.gpa);
        const first = try f.addRevision(schema, given.definition);
        try f.insertSorted(Schema, &f.schemas, schema);
        f.next_uid += 1;
        return ok(try renderSchema(arena, schema, first, .{}));
    }

    /// A new revision, the schema's latest.
    fn addRevision(f: *FakePubSub, schema: *Schema, definition: []const u8) Allocator.Error!*const Revision {
        try schema.revisions.ensureUnusedCapacity(f.gpa, 1);
        const kept = try f.keep(definition);
        var id: [8]u8 = undefined;
        // Each its own, and none like the one before, as production's.
        _ = std.fmt.bufPrint(&id, "{x:0>8}", .{f.next_revision *% 0x9e3779b1}) catch unreachable;
        schema.revisions.appendAssumeCapacity(.{ .id = id, .number = f.next_revision, .definition = kept, .created = std.Io.Clock.real.now(f.io) });
        f.next_revision += 1;
        return schema.latest();
    }

    /// The schema a path names, and the revision if it names one after
    /// an `@`. A refusal names the resource as it was asked for.
    fn findSchema(f: *FakePubSub, arena: Allocator, project: []const u8, id: []const u8) Allocator.Error!Parsed(struct { schema: *Schema, revision: ?*const Revision }) {
        const asked = try std.fmt.allocPrint(arena, "projects/{s}/schemas/{s}", .{ project, id });
        const at = std.mem.indexOfScalar(u8, asked, '@');
        const schema = f.schemas.get(asked[0 .. at orelse asked.len]) orelse return .{ .refused = try schemaNotFound(arena, asked) };
        const revision = if (at) |i| schema.revision(asked[i + 1 ..]) orelse return .{ .refused = try schemaNotFound(arena, asked) } else null;
        return .{ .ok = .{ .schema = schema, .revision = revision } };
    }

    fn getSchema(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        // An `@` sent as `%40` production does not read as one.
        if (std.mem.indexOf(u8, route.raw_id, "%40") != null) return schemaNotFound(arena, try std.fmt.allocPrint(arena, "projects/{s}/schemas/{s}", .{ route.project, route.raw_id }));
        const found = switch (try f.findSchema(arena, route.project, route.id)) {
            .ok => |s| s,
            .refused => |r| return r,
        };
        // With no view a get answers the whole of it.
        const basic = switch (try viewOf(arena, route.query)) {
            .ok => |view| view == .basic,
            .refused => |r| return r,
        };
        return ok(try renderSchema(arena, found.schema, found.revision orelse found.schema.latest(), .{ .definition = !basic, .revision_in_name = found.revision != null }));
    }

    fn deleteSchema(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        const schema = f.schemas.get(name) orelse return schemaNotFound(arena, name);
        try f.old_schemas.append(f.gpa, schema);
        _ = f.schemas.orderedRemove(name);
        // The topics that name it read `_deleted-schema_`, and take no
        // publish. (In production both showed up to a minute late.)
        schema.deleted = true;
        return ok("{}");
    }

    /// A project's schemas, each as its latest revision, by name: the
    /// fake's own order, since production's was neither by name nor by
    /// time. With no view a list leaves the definitions out.
    fn listSchemas(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const full = switch (try viewOf(arena, route.query)) {
            .ok => |view| view == .full,
            .refused => |r| return r,
        };
        const prefix = try std.fmt.allocPrint(arena, "projects/{s}/schemas/", .{route.project});
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.schemas.keys(), f.schemas.values()) |name, schema| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("schemas") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            writeSchema(&jw, schema, schema.latest(), .{ .definition = full }) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    /// A schema's revisions, the newest first, each under its own name.
    fn listRevisions(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        const schema = f.schemas.get(name) orelse return schemaNotFound(arena, name);
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const full = switch (try viewOf(arena, route.query)) {
            .ok => |view| view == .full,
            .refused => |r| return r,
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        // A page begins at the revision its token names.
        var reached = page.after == null;
        var i = schema.revisions.items.len;
        while (i > 0) {
            i -= 1;
            const revision = &schema.revisions.items[i];
            reached = reached or std.mem.eql(u8, &revision.id, page.after.?);
            if (!reached) continue;
            if (written == page.size) {
                next = &revision.id;
                break;
            }
            if (written == 0) {
                jw.objectField("schemas") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            writeSchema(&jw, schema, revision, .{ .definition = full, .revision_in_name = true }) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |id| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, id)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    /// Production commits to the schema the body names, whatever the
    /// path says, and refuses a body that names none.
    fn commitSchema(f: *FakePubSub, arena: Allocator, body: []const u8) Allocator.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var inner: Value = .{ .object = .empty };
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "schema")) inner = field.value_ptr.* else if (!isField(key, "name")) return unknownName(arena, key);
        }
        const name = switch (inner) {
            .object => |o| if (o.get("name")) |n| stringOf(n) orelse return badValue(arena, "name") else "",
            else => return badValue(arena, "schema"),
        };
        if (!isResourceName(name, "schemas")) return invalidName(arena, name);
        const schema = f.schemas.get(name) orelse return schemaNotFound(arena, name);
        const given = switch (try schemaOf(arena, inner)) {
            .ok => |s| s,
            .refused => |r| return r,
        };
        // The one way a revision is checked against the one before it
        // here. Production reads both, and refuses a field that changed
        // its type; the fake reads neither.
        if (given.type != schema.type) return fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(arena, "Compatibility checking failed to commit a schema revision for (schema=\"{s}\"). (reason=\"Revision is incompatible with previous revision: {s}. Failed with error: Types do not match). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.", .{ schema.name, &schema.latest().id }));
        if (try revisionsFull(arena, schema)) |refusal| return refusal;
        return ok(try renderSchema(arena, schema, try f.addRevision(schema, given.definition), .{ .revision_in_name = true }));
    }

    /// A rollback makes a new revision that holds an old one's
    /// definition.
    fn rollbackSchema(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var to: []const u8 = "";
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "revisionId")) to = stringOf(field.value_ptr.*) orelse return badValue(arena, key) else if (!isField(key, "name")) return unknownName(arena, key);
        }
        const name = try resourceName(arena, route);
        const schema = f.schemas.get(name) orelse return schemaNotFound(arena, name);
        // For a revision that is not there production names the schema.
        const old = schema.revision(to) orelse return schemaNotFound(arena, name);
        // The recording of these words was cut after "for mor": they end
        // as production's other two of the kind end.
        if (old == schema.latest()) return fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(arena, "Cannot rollback to the latest revision: (schema=\"{s}\"). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.", .{name}));
        if (try revisionsFull(arena, schema)) |refusal| return refusal;
        return ok(try renderSchema(arena, schema, try f.addRevision(schema, old.definition), .{ .revision_in_name = true }));
    }

    fn deleteRevision(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        // The revision goes in the path, after an `@`: the old query
        // parameter production refuses.
        if (std.mem.indexOfScalar(u8, route.id, '@') == null) return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
        const found = switch (try f.findSchema(arena, route.project, route.id)) {
            .ok => |s| s,
            .refused => |r| return r,
        };
        const schema = found.schema;
        const revision = found.revision.?;
        if (schema.revisions.items.len == 1) return fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(arena, "This schema contains only one revision, which can only be deleted by deleting the parent schema: (schema=\"{s}@{s}\"). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.", .{ schema.name, &revision.id }));
        // It answers the revision deleted, without its definition.
        // (Production writes the project's number in that name, and no
        // other; the fake writes its id.)
        const answer = try renderSchema(arena, schema, revision, .{ .definition = false, .revision_in_name = true });
        _ = schema.revisions.orderedRemove(revision - schema.revisions.items.ptr);
        return ok(answer);
    }

    fn validateSchema(f: *FakePubSub, arena: Allocator, body: []const u8) Allocator.Error!Reply {
        _ = f;
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var inner: Value = .{ .object = .empty };
        var it = object.iterator();
        while (it.next()) |field| {
            if (isField(field.key_ptr.*, "schema")) inner = field.value_ptr.* else return unknownName(arena, field.key_ptr.*);
        }
        return switch (try schemaOf(arena, inner)) {
            .ok => ok("{}"),
            .refused => |r| r,
        };
    }

    /// Whether a message fits a schema, named or given whole: the test's
    /// to say, through `Options.fits`.
    fn validateMessage(f: *FakePubSub, arena: Allocator, body: []const u8) Allocator.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var named: ?[]const u8 = null;
        var inline_schema: ?Value = null;
        var data: []const u8 = "";
        var encoding: ?Encoding = null;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            const value = field.value_ptr.*;
            if (isField(key, "name")) {
                named = stringOf(value) orelse return badValue(arena, key);
            } else if (isField(key, "schema")) {
                inline_schema = value;
            } else if (isField(key, "message")) {
                data = (try decodeBase64(arena, stringOf(value) orelse return badValue(arena, key))) orelse return badValue(arena, key);
            } else if (isField(key, "encoding")) {
                encoding = switch (encodingOf(value)) {
                    .ok => |e| e,
                    .bad => return badValue(arena, key),
                };
            } else if (!isField(key, "parent")) return unknownName(arena, key);
        }
        const as = encoding orelse return fail(arena, 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=Invalid message encoding type: ENCODING_UNSPECIFIED).");
        var why: ?[]const u8 = null;
        var of: SchemaType = undefined;
        if (inline_schema) |value| {
            const given = switch (try schemaOf(arena, value)) {
                .ok => |s| s,
                .refused => |r| return r,
            };
            of = given.type;
            why = f.ask(.{ .schema = "", .revision_id = "", .type = given.type, .definition = given.definition, .encoding = as, .data = data });
        } else {
            const name = named orelse return notModelled(arena, "validateMessage with neither a name nor a schema");
            const at = std.mem.indexOfScalar(u8, name, '@');
            if (!isResourceName(name[0 .. at orelse name.len], "schemas")) return invalidName(arena, name);
            const schema = f.schemas.get(name[0 .. at orelse name.len]) orelse return schemaNotFound(arena, name);
            of = schema.type;
            if (at) |i| {
                const revision = schema.revision(name[i + 1 ..]) orelse return schemaNotFound(arena, name);
                why = f.ask(.{ .schema = schema.name, .revision_id = &revision.id, .type = schema.type, .definition = revision.definition, .encoding = as, .data = data });
            } else {
                // Any revision will do, the newest first.
                var i = schema.revisions.items.len;
                while (i > 0) {
                    i -= 1;
                    const revision = &schema.revisions.items[i];
                    why = f.ask(.{ .schema = schema.name, .revision_id = &revision.id, .type = schema.type, .definition = revision.definition, .encoding = as, .data = data });
                    if (why == null) break;
                }
            }
        }
        const words = why orelse return ok("{}");
        return refusalWith(arena, try std.fmt.allocPrint(arena, "Invalid data in message: {s}", .{words}), misfit(of, as), &.{});
    }

    fn ask(f: *const FakePubSub, check: SchemaCheck) ?[]const u8 {
        const fits = f.options.fits orelse return null;
        return fits.call(fits.context, check);
    }

    /// Tries a message published to a topic on the revisions the topic
    /// allows, from the newest back, and answers the id of the first it
    /// fits. With none, production's refusal names the last it tried.
    fn fit(f: *FakePubSub, arena: Allocator, settings: SchemaSettings, data: []const u8) Allocator.Error!Parsed([]const u8) {
        const schema = settings.schema;
        if (schema.deleted) return .{ .refused = try fail(arena, 404, "NOT_FOUND", "The schema associated with the topic has been deleted.") };
        var last: ?struct { id: []const u8, why: []const u8 } = null;
        var i = schema.revisions.items.len;
        while (i > 0) {
            i -= 1;
            const revision = &schema.revisions.items[i];
            if (!settings.allows(revision.*)) continue;
            const why = f.ask(.{ .schema = schema.name, .revision_id = &revision.id, .type = schema.type, .definition = revision.definition, .encoding = settings.encoding, .data = data }) orelse return .{ .ok = &revision.id };
            last = .{ .id = &revision.id, .why = why };
        }
        const words = "Invalid data in message: Message failed schema validation.";
        // Every revision of the topic's range deleted: production said
        // no more than this. The probe did not keep the details.
        const tried = last orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", words) };
        // Production names the schema by the project's number here; the
        // fake has the id. The full stop after the reason is its own,
        // after whatever the reason ends with.
        const info = try std.fmt.allocPrint(arena, "Could not validate message with any schema revision for schema: {s}, last checked revision: revision_id={s} failed with status: Invalid data in message: {s}.", .{ schema.name, tried.id, tried.why });
        return .{ .refused = try refusalWith(arena, words, misfit(schema.type, settings.encoding), &.{ .{ .key = "revisionInfo", .value = info }, .{ .key = "message", .value = "Message failed schema validation" } }) };
    }

    /// A topic's schema settings, from its JSON. With `change`, one of
    /// the settings alone is taken from it, and the others from what the
    /// topic has.
    fn schemaSettingsOf(f: *FakePubSub, arena: Allocator, topic_name: []const u8, value: Value, change: ?struct { part: []const u8, of: ?SchemaSettings }) Allocator.Error!Parsed(SchemaSettings) {
        const object = switch (value) {
            .object => |o| o,
            else => return .{ .refused = try badValue(arena, "schemaSettings") },
        };
        var text: struct { schema: []const u8 = "", encoding: ?Encoding = null, first: []const u8 = "", last: []const u8 = "" } = .{};
        if (change) |c| {
            if (c.of) |now| text = .{
                .schema = now.schema.name,
                .encoding = now.encoding,
                .first = if (now.first) |b| &b.id else "",
                .last = if (now.last) |b| &b.id else "",
            };
        }
        const part: ?[]const u8 = if (change) |c| c.part else null;
        if (part) |p| {
            // What the mask names is taken from the body, or cleared.
            if (sameField(p, "schema")) text.schema = "" else if (sameField(p, "encoding")) text.encoding = null else if (sameField(p, "firstRevisionId")) text.first = "" else if (sameField(p, "lastRevisionId")) text.last = "" else return .{ .refused = try unknownPath(arena, "UpdateTopicRequest", try std.fmt.allocPrint(arena, "schema_settings.{s}", .{p}), "Topic") };
        }
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            const known = isAnyField(key, &.{ "schema", "encoding", "firstRevisionId", "lastRevisionId" });
            if (!known) return .{ .refused = try unknownName(arena, key) };
            if (part) |p| {
                if (!sameField(p, key)) continue;
            }
            if (isField(key, "encoding")) {
                text.encoding = switch (encodingOf(field.value_ptr.*)) {
                    .ok => |e| e,
                    .bad => return .{ .refused = try badValue(arena, key) },
                };
                continue;
            }
            const given = stringOf(field.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
            if (isField(key, "schema")) text.schema = given else if (isField(key, "firstRevisionId")) text.first = given else text.last = given;
        }
        const encoding = text.encoding orelse return .{ .refused = try bothNeeded(arena, topic_name) };
        if (text.schema.len == 0) return .{ .refused = try bothNeeded(arena, topic_name) };
        // A name with a revision after it is no name here.
        if (std.mem.indexOfScalar(u8, text.schema, '@') != null) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.") };
        if (!isResourceName(text.schema, "schemas")) return .{ .refused = try invalidName(arena, text.schema) };
        const schema = f.schemas.get(text.schema) orelse return .{ .refused = try schemaNotFound(arena, text.schema) };
        var settings: SchemaSettings = .{ .schema = schema, .encoding = encoding };
        inline for (.{ "first", "last" }) |end| {
            const id = @field(text, end);
            if (id.len > 0) {
                // Production's words carry a number of its own for the
                // schema, and no space after it; here it is the fake's.
                const revision = schema.revision(id) orelse return .{ .refused = try fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Resource not found (resource=schema_id: {d}revision_id: {s}).", .{ schema.uid, id })) };
                const bound = try f.store.allocator().create(SchemaSettings.Bound);
                bound.* = .{ .id = revision.id, .number = revision.number };
                @field(settings, end) = bound;
            }
        }
        return .{ .ok = settings };
    }

    // Replay: snapshots, seek and detach.

    fn createSnapshot(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const name = try resourceName(arena, route);
        if (!isResourceId(route.id)) return invalidName(arena, name);
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        var of: []const u8 = "";
        var labels: []const Label = &.{};
        var tags: []const Label = &.{};
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "name")) continue;
            if (isField(key, "subscription")) {
                of = stringOf(field.value_ptr.*) orelse return badValue(arena, key);
            } else if (isField(key, "labels")) {
                labels = switch (try labelsOf(arena, field.value_ptr.*)) {
                    .ok => |l| l,
                    .refused => |r| return r,
                };
            } else if (isField(key, "tags")) {
                tags = switch (try tagsOf(arena, field.value_ptr.*)) {
                    .ok => |t| t,
                    .refused => |r| return r,
                };
            } else return unknownName(arena, key);
        }
        if (!isResourceName(of, "subscriptions")) return invalidName(arena, of);
        if (f.snapshots.contains(name)) return alreadyExists(arena, route.id);
        const sub = f.subscriptions.get(of) orelse return notFound(arena, idOf(of));
        if (sub.detached) return detachedRefusal(arena);
        // Production takes none of a subscription whose topic is gone,
        // made again under its name or not (measured 2026-10-12). A seek
        // to one taken before then it still takes.
        if (sub.topic.deleted) return fail(arena, 400, "FAILED_PRECONDITION", "The operation could not be completed because the requested subscription is attached to a deleted topic.");

        // It holds what the subscription has not had acknowledged, and
        // lasts seven days from the oldest message the subscription has:
        // production's was seven days after the oldest it retained, to
        // 3 ms. (Production also counted one acknowledged moments before
        // on a subscription that retains none; the fake does not.)
        const store = f.store.allocator();
        const wall = std.Io.Clock.real.now(f.io).nanoseconds;
        var oldest = wall;
        var held: std.ArrayList(*const Message) = .empty;
        for (sub.entries.values()) |entry| {
            if (entry.acked) continue;
            try held.append(store, entry.message);
            oldest = @min(oldest, entry.message.publish_time.nanoseconds);
        }
        if (sub.retain_acked) for (sub.topic.messages.items[sub.joined..]) |m| {
            if (wall - m.publish_time.nanoseconds < @as(i96, sub.retention_s) * std.time.ns_per_s and sub.takes(m)) oldest = @min(oldest, m.publish_time.nanoseconds);
        };
        const snap = try store.create(Snapshot);
        snap.* = .{
            .name = try f.keep(name),
            .topic = sub.topic,
            .labels = try f.keepLabels(labels),
            .expire = .{ .nanoseconds = oldest + 7 * std.time.ns_per_day },
            .held = held.items,
            .from = sub.topic.messages.items.len,
            .tags = try f.keepLabels(tags),
        };
        try f.insertSorted(Snapshot, &f.snapshots, snap);
        return ok(try renderSnapshot(arena, snap));
    }

    fn getSnapshot(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const snap = f.snapshots.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        return ok(try renderSnapshot(arena, snap));
    }

    fn deleteSnapshot(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        if (!f.snapshots.orderedRemove(try resourceName(arena, route))) return notFound(arena, route.id);
        return ok("{}");
    }

    /// Only its labels change: the set is replaced, and with none in the
    /// body it is cleared.
    fn updateSnapshot(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const update = switch (try parseUpdate(arena, body, "snapshot", "UpdateSnapshotRequest")) {
            .ok => |u| u,
            .refused => |r| return r,
        };
        const snap = f.snapshots.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        var labels = snap.labels;
        for (update.paths) |path| {
            const given = fieldOf(update.resource, path);
            if (isPath(path, "labels")) {
                labels = if (given) |v| switch (try labelsOf(arena, v)) {
                    .ok => |l| try f.keepLabels(l),
                    .refused => |r| return r,
                } else &.{};
            } else if (isPath(path, "name")) {
                return immutable(arena, "UpdateSnapshotRequest", "name", "Snapshot");
            } else if (isPath(path, "topic")) {
                return immutable(arena, "UpdateSnapshotRequest", "topic", "Snapshot");
            } else if (isPath(path, "expireTime")) {
                return immutable(arena, "UpdateSnapshotRequest", "expire_time", "Snapshot");
            } else if (isPath(path, "tags")) {
                return notModelled(arena, "an update of a snapshot's tags");
            } else return unknownPath(arena, "UpdateSnapshotRequest", path, "Snapshot");
        }
        snap.labels = labels;
        return ok(try renderSnapshot(arena, snap));
    }

    fn listSnapshots(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const prefix = try std.fmt.allocPrint(arena, "projects/{s}/snapshots/", .{route.project});
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.snapshots.keys(), f.snapshots.values()) |name, snap| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("snapshots") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            writeSnapshot(&jw, snap) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    /// The names of a topic's snapshots. A deleted topic has no list.
    fn listTopicSnapshots(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const topic = f.topics.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        const page = switch (try pageOf(arena, route.query)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        var written: usize = 0;
        var next: ?[]const u8 = null;
        for (f.snapshots.keys(), f.snapshots.values()) |name, snap| {
            if (snap.topic != topic) continue;
            if (page.after) |after| {
                if (std.mem.order(u8, name, after) == .lt) continue;
            }
            if (written == page.size) {
                next = name;
                break;
            }
            if (written == 0) {
                jw.objectField("snapshots") catch return error.OutOfMemory;
                jw.beginArray() catch return error.OutOfMemory;
            }
            jw.write(name) catch return error.OutOfMemory;
            written += 1;
        }
        if (written > 0) jw.endArray() catch return error.OutOfMemory;
        if (next) |name| {
            jw.objectField("nextPageToken") catch return error.OutOfMemory;
            jw.write(try pageToken(arena, name)) catch return error.OutOfMemory;
        }
        jw.endObject() catch return error.OutOfMemory;
        return ok(out.written());
    }

    /// A snapshot past its time is gone, as if deleted.
    fn expireSnapshots(f: *FakePubSub) void {
        const wall = std.Io.Clock.real.now(f.io).nanoseconds;
        var i: usize = 0;
        while (i < f.snapshots.count()) {
            if (f.snapshots.values()[i].expire.nanoseconds <= wall) f.snapshots.orderedRemoveAt(i) else i += 1;
        }
    }

    /// A seek acts on what the subscription holds when it runs, and at
    /// once. (Production's took 2 to 50 seconds to show, and a seek ahead
    /// did not stop what was already on its way.) To a snapshot, the
    /// subscription holds again what the snapshot holds. To a time, what
    /// was published before it is acknowledged, and what was published
    /// from then on is unacknowledged again, of what the subscription
    /// still has: without retention, nothing acknowledged comes back.
    fn seek(f: *FakePubSub, arena: Allocator, route: Route, body: []const u8) Allocator.Error!Reply {
        const object = switch (try parseObject(arena, body)) {
            .ok => |o| o,
            .refused => |r| return r,
        };
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        const Target = union(enum) { snapshot: []const u8, time: std.Io.Timestamp };
        var target: ?Target = null;
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            const snapshot = isField(key, "snapshot");
            if (!snapshot and !isField(key, "time")) return unknownName(arena, key);
            if (target != null) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid value (oneof), oneof field 'target' is already set. Cannot set '{s}'", .{key}));
            const text = stringOf(field.value_ptr.*) orelse return badValue(arena, key);
            target = if (snapshot) .{ .snapshot = text } else .{ .time = timestamp.parse(text) catch return fail(arena, 400, "INVALID_ARGUMENT", "Invalid value at 'time' (type.googleapis.com/google.protobuf.Timestamp), Field 'time', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.") };
        }
        const to = target orelse return fail(arena, 400, "INVALID_ARGUMENT", "No target was specified in the SeekRequest. Must specify either a time or a snapshot.");
        if (sub.detached) return detachedRefusal(arena);

        var fresh: std.ArrayList(*const Message) = .empty;
        switch (to) {
            .snapshot => |snapshot_name| {
                if (!isResourceName(snapshot_name, "snapshots")) return invalidName(arena, snapshot_name);
                const snap = f.snapshots.get(snapshot_name) orelse return notFound(arena, idOf(snapshot_name));
                if (snap.topic != sub.topic) return fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(arena, "The subscription's topic ({s}) is different from that of the snapshot ({s}); they must match in order for Seek work. Note that if a topic is deleted and then re-created with the same name, it is considered a distinct topic for these purposes.", .{ topicName(sub.topic), topicName(snap.topic) }));
                // A snapshot serves a subscription that was not there when
                // it was taken, with that subscription's own filter.
                for (snap.held) |m| {
                    if (sub.takes(m)) try fresh.append(arena, m);
                }
                for (sub.topic.messages.items[snap.from..]) |m| {
                    if (sub.takes(m)) try fresh.append(arena, m);
                }
            },
            .time => |time| {
                var unacknowledged: std.AutoHashMapUnmanaged(*const Message, void) = .empty;
                for (sub.entries.values()) |entry| {
                    if (!entry.acked) try unacknowledged.put(arena, entry.message, {});
                }
                const wall = std.Io.Clock.real.now(f.io).nanoseconds;
                for (sub.topic.messages.items, 0..) |m, index| {
                    if (m.publish_time.nanoseconds < time.nanoseconds) continue;
                    if (unacknowledged.contains(m) or (sub.takes(m) and sub.retains(m, index, wall))) try fresh.append(arena, m);
                }
            },
        }

        // The subscription has its messages afresh: none out, none
        // counted as delivered, and every ack id it gave before stale.
        // Each goes on naming its message, and with exactly-once
        // delivery what was out goes on being so, by its id: see `judge`.
        var entries: std.AutoArrayHashMapUnmanaged(u64, Entry) = .empty;
        try entries.ensureTotalCapacity(f.gpa, fresh.items.len);
        errdefer entries.deinit(f.gpa);
        try sub.old.ensureUnusedCapacity(f.gpa, @intCast(sub.entries.count()));
        for (sub.entries.keys(), sub.entries.values()) |seq, entry| {
            sub.old.putAssumeCapacity(seq, .{ .message = entry.message, .delivery = entry.deliveries, .until = if (sub.exactly_once) entry.lease_until else null });
        }
        sub.stale_below = sub.next_seq;
        for (fresh.items) |m| {
            entries.putAssumeCapacity(sub.next_seq, .{ .message = m });
            sub.next_seq += 1;
        }
        sub.entries.deinit(f.gpa);
        sub.entries = entries;
        return ok("{}");
    }

    /// Cuts a subscription from its topic: it lets go of what it holds,
    /// gets nothing more, and refuses everything but a read, an update
    /// and a delete. (Production took 7 seconds to refuse; the fake
    /// refuses at once.)
    fn detach(f: *FakePubSub, arena: Allocator, route: Route) Allocator.Error!Reply {
        const sub = f.subscriptions.get(try resourceName(arena, route)) orelse return notFound(arena, route.id);
        if (sub.detached) return detachedRefusal(arena);
        sub.detached = true;
        sub.entries.clearRetainingCapacity();
        return ok("{}");
    }

    // Keeping what a request held, past the request.

    fn keep(f: *FakePubSub, text: []const u8) Allocator.Error![]const u8 {
        return f.store.allocator().dupe(u8, text);
    }

    fn keepLabels(f: *FakePubSub, labels: []const Label) Allocator.Error![]const Label {
        const kept = try f.store.allocator().alloc(Label, labels.len);
        for (labels, kept) |l, *slot| slot.* = .{ .key = try f.keep(l.key), .value = try f.keep(l.value) };
        return kept;
    }

    fn keepPolicy(f: *FakePubSub, policy: StoragePolicy) Allocator.Error!StoragePolicy {
        const regions = try f.store.allocator().alloc([]const u8, policy.regions.len);
        for (policy.regions, regions) |r, *slot| slot.* = try f.keep(r);
        return .{ .regions = regions, .enforce_in_transit = policy.enforce_in_transit };
    }

    fn keepTopic(f: *FakePubSub, topic: Topic) Allocator.Error!*Topic {
        const kept = try f.store.allocator().create(Topic);
        kept.* = topic;
        kept.name = try f.keep(topic.name);
        kept.labels = try f.keepLabels(topic.labels);
        if (topic.kms_key_name) |k| kept.kms_key_name = try f.keep(k);
        if (topic.storage_policy) |p| kept.storage_policy = try f.keepPolicy(p);
        kept.transforms = try f.keepWhole([]const Transform, topic.transforms);
        kept.ingestion = try f.keepWhole(?Ingestion, topic.ingestion);
        kept.tags = try f.keepLabels(topic.tags);
        return kept;
    }

    /// A copy of `value` in the store, with every text and list it holds.
    fn keepWhole(f: *FakePubSub, comptime T: type, value: T) Allocator.Error!T {
        switch (@typeInfo(T)) {
            .pointer => |p| if (p.child == u8) {
                return f.keep(value);
            } else {
                const out = try f.store.allocator().alloc(p.child, value.len);
                for (value, out) |item, *slot| slot.* = try f.keepWhole(p.child, item);
                return out;
            },
            .optional => |o| return if (value) |v| try f.keepWhole(o.child, v) else null,
            .@"struct" => |s| {
                var out = value;
                inline for (s.field_names) |name| @field(out, name) = try f.keepWhole(@FieldType(T, name), @field(value, name));
                return out;
            },
            .@"union" => switch (value) {
                inline else => |payload, which| return @unionInit(T, @tagName(which), try f.keepWhole(@TypeOf(payload), payload)),
            },
            else => return value,
        }
    }

    fn keepSubscription(f: *FakePubSub, sub: Subscription) Allocator.Error!*Subscription {
        const kept = try f.store.allocator().create(Subscription);
        kept.* = sub;
        kept.name = try f.keep(sub.name);
        kept.labels = try f.keepLabels(sub.labels);
        if (sub.dead_letter) |policy| kept.dead_letter = .{ .topic = try f.keep(policy.topic), .max_attempts = policy.max_attempts };
        kept.delivery = try f.keepWhole(Delivery, sub.delivery);
        kept.transforms = try f.keepWhole([]const Transform, sub.transforms);
        kept.tags = try f.keepLabels(sub.tags);
        kept.filter_text = try f.keep(sub.filter_text);
        if (sub.filter != null) kept.filter = switch (try fake_filter.parse(f.store.allocator(), kept.filter_text)) {
            .ok => |filter| filter,
            // It was read once already, and reads the same again.
            .refused, .not_modelled => unreachable,
        };
        return kept;
    }

    /// Lists come back in name order, as production's did.
    fn insertSorted(f: *FakePubSub, comptime T: type, map: *std.StringArrayHashMapUnmanaged(*T), item: *T) Allocator.Error!void {
        try map.put(f.gpa, item.name, item);
        const Sorter = struct {
            keys: []const []const u8,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, ctx.keys[a], ctx.keys[b]) == .lt;
            }
        };
        map.sortUnstable(Sorter{ .keys = map.keys() });
    }
};

/// The size of a publish request production takes, counted on the request
/// as it arrives.
const max_publish_bytes = 10 * 1024 * 1024;

// Requests: the URL, the body, and what a field of it holds.

fn parseUrl(arena: Allocator, url: []const u8) Allocator.Error!?FakePubSub.Route {
    const marker = "/v1/projects/";
    const at = std.mem.indexOf(u8, url, marker) orelse return null;
    var path = url[at + marker.len ..];
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path, '?')) |q| {
        query = path[q + 1 ..];
        path = path[0..q];
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    const project = try percentDecode(arena, parts.next() orelse return null);
    // A method on a collection itself follows its name after a colon:
    // `schemas:validate`.
    const collection_part = parts.next() orelse return null;
    const colon_at = std.mem.indexOfScalar(u8, collection_part, ':') orelse collection_part.len;
    const collection_text = collection_part[0..colon_at];
    const method_on_all = collection_part[colon_at..];
    const collection: @FieldType(FakePubSub.Route, "collection") = if (std.mem.eql(u8, collection_text, "topics"))
        .topics
    else if (std.mem.eql(u8, collection_text, "subscriptions"))
        .subscriptions
    else if (std.mem.eql(u8, collection_text, "snapshots"))
        .snapshots
    else if (std.mem.eql(u8, collection_text, "schemas"))
        .schemas
    else
        return null;
    const id_part = parts.next() orelse return .{ .project = project, .collection = collection, .id = "", .raw_id = "", .rest = method_on_all, .query = query };
    if (method_on_all.len != 0) return null;
    const after = parts.rest();
    // A method follows the id after a colon: an id holds none.
    if (std.mem.indexOfScalar(u8, id_part, ':')) |colon| {
        if (after.len != 0) return null;
        return .{ .project = project, .collection = collection, .id = try percentDecode(arena, id_part[0..colon]), .raw_id = id_part[0..colon], .rest = id_part[colon..], .query = query };
    }
    const rest = if (after.len == 0) "" else try std.fmt.allocPrint(arena, "/{s}", .{after});
    return .{ .project = project, .collection = collection, .id = try percentDecode(arena, id_part), .raw_id = id_part, .rest = rest, .query = query };
}

/// The value of one query parameter, decoded; null when it is not there.
fn queryValue(arena: Allocator, query: []const u8, comptime key: []const u8) Allocator.Error!?[]const u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, key ++ "=")) return try percentDecode(arena, part[key.len + 1 ..]);
    }
    return null;
}

fn percentDecode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(arena, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, text[i]);
    }
    return out.items;
}

fn resourceName(arena: Allocator, route: FakePubSub.Route) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "projects/{s}/{t}/{s}", .{ route.project, route.collection, route.id });
}

/// The id at the end of a full name.
fn idOf(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[slash + 1 ..];
}

/// 3 to 255 characters from `[A-Za-z0-9-_.~+%]`, the first a letter, and
/// not beginning `goog` in any case.
fn isResourceId(id: []const u8) bool {
    if (id.len < 3 or id.len > 255) return false;
    if (!std.ascii.isAlphabetic(id[0])) return false;
    if (startsWithGoog(id)) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.~+%", c) == null) return false;
    }
    return true;
}

fn isResourceName(name: []const u8, comptime collection: []const u8) bool {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    const middle = "/" ++ collection ++ "/";
    const at = std.mem.indexOf(u8, rest, middle) orelse return false;
    if (at == 0) return false;
    return isResourceId(rest[at + middle.len ..]);
}

fn startsWithGoog(text: []const u8) bool {
    return text.len >= 4 and std.ascii.eqlIgnoreCase(text[0..4], "goog");
}

/// The three keys a schema topic writes, which production takes from any
/// publisher.
fn isSchemaAttribute(key: []const u8) bool {
    for ([_][]const u8{ "googclient_schemaname", "googclient_schemaencoding", "googclient_schemarevisionid" }) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

fn Parsed(comptime T: type) type {
    return union(enum) { ok: T, refused: FakePubSub.Reply };
}

fn parseObject(arena: Allocator, body: []const u8) Allocator.Error!Parsed(std.json.ObjectMap) {
    const text = if (std.mem.trim(u8, body, " \t\r\n").len == 0) "{}" else body;
    const value = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Production says where the text went wrong; the fake only that
        // it did.
        else => return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") },
    };
    return switch (value) {
        .object => |o| .{ .ok = o },
        else => .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.") },
    };
}

const Update = struct { resource: std.json.ObjectMap, paths: []const []const u8 };

/// A patch's body: the resource under `field`, and the mask's paths.
fn parseUpdate(arena: Allocator, body: []const u8, comptime field: []const u8, comptime request: []const u8) Allocator.Error!Parsed(Update) {
    const object = switch (try parseObject(arena, body)) {
        .ok => |o| o,
        .refused => |r| return .{ .refused = r },
    };
    var resource: std.json.ObjectMap = .empty;
    var mask: []const u8 = "";
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isField(key, field)) {
            resource = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return .{ .refused = try badValue(arena, key) },
            };
        } else if (isField(key, "updateMask")) {
            mask = stringOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        } else return .{ .refused = try unknownName(arena, key) };
    }
    var paths: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, mask, ',');
    while (parts.next()) |part| {
        const path = std.mem.trim(u8, part, " ");
        if (path.len > 0) try paths.append(arena, path);
    }
    if (paths.items.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "The update_mask in the " ++ request ++ " must be set, and must contain a non-empty paths list.") };
    return .{ .ok = .{ .resource = resource, .paths = paths.items } };
}

/// A JSON name in either of the spellings proto3 takes: `ackDeadlineSeconds`
/// or `ack_deadline_seconds`.
fn isField(key: []const u8, comptime camel: []const u8) bool {
    return std.mem.eql(u8, key, camel) or std.mem.eql(u8, key, comptime snakeOf(camel));
}

fn isAnyField(key: []const u8, comptime camels: []const []const u8) bool {
    inline for (camels) |camel| if (isField(key, camel)) return true;
    return false;
}

/// A mask path, which production takes in either spelling too.
const isPath = isField;
const isAnyPath = isAnyField;

fn snakeOf(comptime camel: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (camel) |c| {
            if (std.ascii.isUpper(c)) {
                out = out ++ "_" ++ [_]u8{std.ascii.toLower(c)};
            } else out = out ++ [_]u8{c};
        }
        return out;
    }
}

/// What the resource in a patch holds under a mask path, in either
/// spelling; null when it holds nothing there, which clears the field.
fn fieldOf(resource: std.json.ObjectMap, path: []const u8) ?Value {
    var it = resource.iterator();
    while (it.next()) |entry| {
        if (sameField(entry.key_ptr.*, path)) return switch (entry.value_ptr.*) {
            .null => null,
            else => entry.value_ptr.*,
        };
    }
    return null;
}

/// Two spellings of one field: compared with underscores dropped and case
/// ignored.
fn sameField(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and a[i] == '_') i += 1;
        while (j < b.len and b[j] == '_') j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn stringOf(value: Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn boolOf(value: Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

/// An integer, as a number or as the string proto3 JSON also takes.
fn intOf(value: Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn stringMapOf(arena: Allocator, value: Value) Allocator.Error!?[]const FakePubSub.Label {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const out = try arena.alloc(FakePubSub.Label, object.count());
    var it = object.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .key = entry.key_ptr.*, .value = stringOf(entry.value_ptr.*) orelse return null };
    }
    return out;
}

fn storagePolicyOf(arena: Allocator, value: Value) Allocator.Error!?FakePubSub.StoragePolicy {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };
    var policy: FakePubSub.StoragePolicy = .{ .regions = &.{}, .enforce_in_transit = false };
    var it = object.iterator();
    while (it.next()) |entry| {
        if (isField(entry.key_ptr.*, "allowedPersistenceRegions")) {
            const list = switch (entry.value_ptr.*) {
                .array => |a| a.items,
                else => return null,
            };
            const regions = try arena.alloc([]const u8, list.len);
            for (list, regions) |item, *slot| slot.* = stringOf(item) orelse return null;
            policy.regions = regions;
        } else if (isField(entry.key_ptr.*, "enforceInTransit")) {
            policy.enforce_in_transit = boolOf(entry.value_ptr.*) orelse return null;
        } else return null;
    }
    return policy;
}

/// Standard base64, or the URL-safe alphabet, with or without padding, as
/// proto3 JSON reads bytes.
fn decodeBase64(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    const normal = try arena.dupe(u8, trimmed);
    for (normal) |*c| switch (c.*) {
        '-' => c.* = '+',
        '_' => c.* = '/',
        else => {},
    };
    const decoder = std.base64.standard_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(normal) catch return null;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, normal) catch return null;
    return out;
}

// Rules of production's, each in its words.

/// At most 64; a key of 1 to 63 lowercase letters, digits, `_` and `-`,
/// beginning with a letter; a value of up to 63 of the same. Any
/// character outside ASCII counts as a lowercase letter here.
fn labelsOf(arena: Allocator, value: Value) Allocator.Error!Parsed([]const FakePubSub.Label) {
    const labels = (try stringMapOf(arena, value)) orelse return .{ .refused = try badValue(arena, "labels") };
    if (labels.len > 64) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; at most 64 entries allowed but found {d}).", .{labels.len})) };
    for (labels) |label| {
        if (!isLabelText(label.key, true)) {
            // Production's words for a first character in capitals; for
            // the other ways a key can be wrong, the fake's own after them.
            const first_upper = label.key.len > 0 and std.ascii.isUpper(label.key[0]);
            const why = if (first_upper)
                try std.fmt.allocPrint(arena, "first character \"{c}\" is not a non-uppercased letter (Unicode character class Ll or Lo)", .{label.key[0]})
            else
                "fake: the key is empty, too long, or holds a character outside the expression";
            return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; key \"{s}\" does not conform to regular expression \"[\\p{{Ll}}\\p{{Lo}}][\\p{{Ll}}\\p{{Lo}}\\p{{N}}_-]{{0,62}}\"; {s}).", .{ label.key, why })) };
        }
        if (!isLabelText(label.value, false)) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; value \"{s}\" does not conform to regular expression \"[\\p{{Ll}}\\p{{Lo}}\\p{{N}}_-]{{0,63}}\"; fake: the value is too long or holds a character outside the expression).", .{label.value})) };
    }
    return .{ .ok = labels };
}

fn isLabelText(text: []const u8, is_key: bool) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    var count: usize = 0;
    while (view.nextCodepoint()) |cp| : (count += 1) {
        const letter = cp >= 0x80 or (cp >= 'a' and cp <= 'z');
        const later = letter or (cp >= '0' and cp <= '9') or cp == '_' or cp == '-';
        if (is_key and count == 0) {
            if (!letter) return false;
        } else if (!later) return false;
    }
    return if (is_key) count >= 1 and count <= 63 else count <= 63;
}

/// A duration as proto3 JSON writes one, in whole seconds: `600s`.
fn secondsOf(value: Value) ?i64 {
    const text = stringOf(value) orelse return null;
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    const number = text[0 .. text.len - 1];
    const whole = if (std.mem.indexOfScalar(u8, number, '.')) |dot| number[0..dot] else number;
    return std.fmt.parseInt(i64, whole, 10) catch null;
}

/// 10 minutes to 31 days, for a topic's retention and a subscription's.
fn retentionOf(arena: Allocator, value: Value) Allocator.Error!Parsed(i64) {
    const seconds = secondsOf(value) orelse return .{ .refused = try badValue(arena, "messageRetentionDuration") };
    if (seconds < 600 or seconds > 2_678_400) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for message retention duration is out of bounds. You passed {s} in the request, but the value must be between 10m and 744h.", .{try goDuration(arena, seconds)})) };
    return .{ .ok = seconds };
}

/// `{}` never expires; a `ttl` is a day at least.
fn expirationOf(arena: Allocator, value: Value) Allocator.Error!Parsed(?i64) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "expirationPolicy") },
    };
    const ttl = object.get("ttl") orelse return .{ .ok = null };
    const seconds = secondsOf(ttl) orelse return .{ .refused = try badValue(arena, "ttl") };
    if (seconds < 86_400) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for expiration duration is too small. You passed {s} in the request, but the minimum value is 24h.", .{try goDuration(arena, seconds)})) };
    return .{ .ok = seconds };
}

/// A dead-letter policy: a topic by its full name, and 5 to 100 delivery
/// attempts, 5 when none is said.
fn deadLetterOf(arena: Allocator, value: Value) Allocator.Error!Parsed(FakePubSub.DeadLetter) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "deadLetterPolicy") },
    };
    var topic: []const u8 = "";
    var attempts: i64 = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isField(key, "deadLetterTopic")) {
            topic = stringOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        } else if (isField(key, "maxDeliveryAttempts")) {
            attempts = intOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        } else return .{ .refused = try unknownName(arena, key) };
    }
    if (!isResourceName(topic, "topics")) return .{ .refused = try invalidName(arena, topic) };
    if (attempts == 0) attempts = 5;
    if (attempts < 5) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for max_delivery_attempts is too small. You passed {d} in the request, but the minimum value is 5.", .{attempts})) };
    if (attempts > 100) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for max_delivery_attempts is too large. You passed {d} in the request, but the maximum value is 100.", .{attempts})) };
    return .{ .ok = .{ .topic = topic, .max_attempts = @intCast(attempts) } };
}

/// A retry policy: each backoff 0 to 600 seconds, 10 and 600 when not
/// said, and the minimum no greater than the maximum.
fn retryOf(arena: Allocator, value: Value) Allocator.Error!Parsed(FakePubSub.Retry) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "retryPolicy") },
    };
    var policy: FakePubSub.Retry = .{ .min_s = 10, .max_s = 600 };
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const minimum = isField(key, "minimumBackoff");
        if (!minimum and !isField(key, "maximumBackoff")) return .{ .refused = try unknownName(arena, key) };
        const seconds = secondsOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        if (seconds < 0 or seconds > 600) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for {s} is out of bounds. You passed {s} in the request, but the value must be between 0 and 10m.", .{ if (minimum) "minimum_backoff" else "maximum_backoff", try goDuration(arena, seconds) })) };
        if (minimum) policy.min_s = seconds else policy.max_s = seconds;
    }
    if (policy.max_s < policy.min_s) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The specified maximum_backoff {s} cannot be smaller than minimum_backoff {s}.", .{ try goDuration(arena, policy.max_s), try goDuration(arena, policy.min_s) })) };
    return .{ .ok = policy };
}

/// A subscription cannot keep messages past its own expiry. Production
/// holds a create and an update to that when the expiry was given.
fn expirationRefusal(arena: Allocator, retention_s: i64, ttl_s: ?i64, given: bool) ?Allocator.Error!FakePubSub.Reply {
    const ttl = ttl_s orelse return null;
    if (!given or retention_s <= ttl) return null;
    const message = std.fmt.allocPrint(arena, "The subscription's message retention duration ({d} seconds) cannot be greater than the TTL in the subscription's expiration policy ({d} seconds), since messages cannot be retained past subscription expiration.", .{ retention_s, ttl }) catch return error.OutOfMemory;
    return fail(arena, 400, "INVALID_ARGUMENT", message);
}

fn goDuration(arena: Allocator, seconds: i64) Allocator.Error![]const u8 {
    return durationWords(arena, @as(i128, seconds) * std.time.ns_per_s);
}

/// A duration as production's refusals write one: `9m59s`, `744h1s`, `1h`,
/// `59.999s`, and `0` for none at all. (That a part of a second alone is
/// written the same way, `0.5s`, is the fake's own.)
fn durationWords(arena: Allocator, ns: i128) Allocator.Error![]const u8 {
    if (ns == 0) return "0";
    var out: std.ArrayList(u8) = .empty;
    if (ns < 0) try out.append(arena, '-');
    const whole = @abs(ns) / std.time.ns_per_s;
    const part = @abs(ns) % std.time.ns_per_s;
    const h = whole / 3600;
    const m = whole % 3600 / 60;
    const s = whole % 60;
    if (h > 0) try out.print(arena, "{d}h", .{h});
    if (m > 0) try out.print(arena, "{d}m", .{m});
    if (s > 0 or part > 0) {
        try out.print(arena, "{d}", .{s});
        if (part > 0) {
            var digits: [9]u8 = undefined;
            _ = std.fmt.bufPrint(&digits, "{d:0>9}", .{part}) catch unreachable;
            try out.print(arena, ".{s}", .{std.mem.trimEnd(u8, &digits, "0")});
        }
        try out.append(arena, 's');
    }
    return out.items;
}

/// A duration as proto3 JSON writes one, `90s` or `59.999s`, in
/// nanoseconds.
fn durationOf(value: Value) ?i128 {
    const text = stringOf(value) orelse return null;
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    const negative = text[0] == '-';
    const number = text[@intFromBool(negative) .. text.len - 1];
    const dot = std.mem.indexOfScalar(u8, number, '.') orelse number.len;
    const whole = std.fmt.parseInt(u64, number[0..dot], 10) catch return null;
    var ns: i128 = @as(i128, whole) * std.time.ns_per_s;
    if (dot < number.len) {
        const fraction = number[dot + 1 ..];
        if (fraction.len == 0 or fraction.len > 9) return null;
        var scale: i128 = std.time.ns_per_s / 10;
        for (fraction) |c| {
            if (!std.ascii.isDigit(c)) return null;
            ns += (c - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    return if (negative) -ns else ns;
}

const Page = struct { size: usize, after: ?[]const u8 };

/// A list's page: `pageSize` of 0 to 1000, where 0 and none are the
/// default, and a `pageToken` this fake gave.
fn pageOf(arena: Allocator, query: []const u8) Allocator.Error!Parsed(Page) {
    var page: Page = .{ .size = 100, .after = null };
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = try percentDecode(arena, part[eq + 1 ..]);
        if (std.mem.eql(u8, key, "pageSize")) {
            const size = std.fmt.parseInt(i64, value, 10) catch return .{ .refused = try badValue(arena, "pageSize") };
            if (size < 0 or size > 1000) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for page_size is out of bounds. You passed {d} in the request, but the value must be between 0 and 1000.", .{size})) };
            if (size > 0) page.size = @intCast(size);
        } else if (std.mem.eql(u8, key, "pageToken")) {
            if (value.len == 0) continue;
            page.after = (try nameOfToken(arena, value)) orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid page token given (token={s}).", .{value})) };
        }
    }
    return .{ .ok = page };
}

const token_prefix = "fake-";

/// A page token says which name the next page begins with, in a form no
/// test should read.
fn pageToken(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, token_prefix.len + encoder.calcSize(name.len));
    @memcpy(out[0..token_prefix.len], token_prefix);
    _ = encoder.encode(out[token_prefix.len..], name);
    return out;
}

fn nameOfToken(arena: Allocator, token: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.startsWith(u8, token, token_prefix)) return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const text = token[token_prefix.len..];
    const size = decoder.calcSizeForSlice(text) catch return null;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, text) catch return null;
    return out;
}

const ack_prefix = "FAKE";

/// An ack id names the subscription, the message's place in it and which
/// delivery it was, in a form no test should read.
fn ackId(arena: Allocator, uid: u64, seq: u64, delivery: u32) Allocator.Error![]const u8 {
    var plain: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&plain, "{d}:{d}:{d}", .{ uid, seq, delivery }) catch unreachable;
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, ack_prefix.len + encoder.calcSize(text.len));
    @memcpy(out[0..ack_prefix.len], ack_prefix);
    _ = encoder.encode(out[ack_prefix.len..], text);
    return out;
}

fn parseAckId(id: []const u8) ?struct { uid: u64, seq: u64, delivery: u32 } {
    if (!std.mem.startsWith(u8, id, ack_prefix)) return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const text = id[ack_prefix.len..];
    var plain: [64]u8 = undefined;
    const size = decoder.calcSizeForSlice(text) catch return null;
    if (size > plain.len) return null;
    decoder.decode(plain[0..size], text) catch return null;
    var parts = std.mem.splitScalar(u8, plain[0..size], ':');
    const uid = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const seq = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const delivery = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return .{ .uid = uid, .seq = seq, .delivery = delivery };
}

// Answers.

fn ok(body: []const u8) FakePubSub.Reply {
    return .{ .status = 200, .body = body };
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakePubSub.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

fn statusName(code: u16) []const u8 {
    return switch (code) {
        400 => "INVALID_ARGUMENT",
        401 => "UNAUTHENTICATED",
        403 => "PERMISSION_DENIED",
        404 => "NOT_FOUND",
        409 => "ABORTED",
        429 => "RESOURCE_EXHAUSTED",
        500 => "INTERNAL",
        504 => "DEADLINE_EXCEEDED",
        else => "UNAVAILABLE",
    };
}

fn notFound(arena: Allocator, id: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Resource not found (resource={s}).", .{id}));
}

fn alreadyExists(arena: Allocator, id: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 409, "ALREADY_EXISTS", try std.fmt.allocPrint(arena, "Resource already exists in the project (resource={s}).", .{id}));
}

fn invalidName(arena: Allocator, name: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid resource name given (name={s}). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.", .{name}));
}

fn unknownName(arena: Allocator, name: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid JSON payload received. Unknown name \"{s}\": Cannot find field.", .{name}));
}

/// A field of the wrong JSON type. Production's words name the type it
/// wanted; the fake's only the field.
fn badValue(arena: Allocator, name: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid value at '{s}'", .{name}));
}

fn unknownPath(arena: Allocator, comptime request: []const u8, path: []const u8, comptime resource: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid update_mask provided in the " ++ request ++ ": '{s}' is not a known " ++ resource ++ " field. Note that field paths must be of the form 'push_config' rather than 'pushConfig'.", .{path}));
}

fn immutable(arena: Allocator, comptime request: []const u8, comptime field: []const u8, comptime resource: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "Invalid update_mask provided in the " ++ request ++ ": the '" ++ field ++ "' field in the " ++ resource ++ " is not mutable.");
}

/// Production's refusal of ack ids on a subscription with exactly-once
/// delivery, whole, as it answered on 2026-09-27: each id it did not
/// take, and why.
fn exactlyOnceRefusal(arena: Allocator, ids: []const []const u8) Allocator.Error!FakePubSub.Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeExactlyOnceRefusal(&jw, ids) catch return error.OutOfMemory;
    return .{ .status = 400, .body = out.written() };
}

fn writeExactlyOnceRefusal(jw: *Stringify, ids: []const []const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(400);
    try jw.objectField("message");
    try jw.write("Some acknowledgement ids in the request were invalid. This could be because the acknowledgement ids have expired or the acknowledgement ids were malformed.");
    try jw.objectField("status");
    try jw.write("INVALID_ARGUMENT");
    try jw.objectField("details");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("@type");
    try jw.write("type.googleapis.com/google.rpc.ErrorInfo");
    try jw.objectField("reason");
    try jw.write("EXACTLY_ONCE_ACKID_FAILURE");
    try jw.objectField("domain");
    try jw.write("pubsub.googleapis.com");
    try jw.objectField("metadata");
    try jw.beginObject();
    for (ids) |id| {
        try jw.objectField(id);
        try jw.write("PERMANENT_FAILURE_INVALID_ACK_ID");
    }
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
}

/// A schema that is not there, or a revision of one: production names
/// the whole of what was asked for, where for a topic it names the id.
fn schemaNotFound(arena: Allocator, asked: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Resource not found (resource={s}).", .{asked}));
}

fn bothNeeded(arena: Allocator, topic_name: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Schema settings for the topic {s} must include both the name and the encoding.", .{topic_name}));
}

/// A schema holds twenty revisions: production refused the next.
fn revisionsFull(arena: Allocator, schema: *const FakePubSub.Schema) Allocator.Error!?FakePubSub.Reply {
    if (schema.revisions.items.len < 20) return null;
    return try fail(arena, 429, "RESOURCE_EXHAUSTED", try std.fmt.allocPrint(arena, "You have exceeded your revisions per schema quota (schema=\"{s}\"). Refer to https://cloud.google.com/pubsub/quotas for more information.", .{schema.name}));
}

/// The reason production gives for a message that fits no revision.
fn misfit(of: FakePubSub.SchemaType, as: FakePubSub.Encoding) []const u8 {
    return switch (of) {
        .avro => if (as == .json) "INVALID_JSON_AVRO_MESSAGE" else "INVALID_BINARY_AVRO_MESSAGE",
        .protocol_buffer => if (as == .json) "INVALID_JSON_PROTO_MESSAGE" else "INVALID_BINARY_PROTO_MESSAGE",
    };
}

fn encodingName(encoding: FakePubSub.Encoding) []const u8 {
    return if (encoding == .json) "JSON" else "BINARY";
}

/// An encoding as JSON names it. None, and the one that says none, are
/// null.
fn encodingOf(value: Value) union(enum) { ok: ?FakePubSub.Encoding, bad } {
    const text = stringOf(value) orelse return .bad;
    if (std.mem.eql(u8, text, "JSON")) return .{ .ok = .json };
    if (std.mem.eql(u8, text, "BINARY")) return .{ .ok = .binary };
    if (std.mem.eql(u8, text, "ENCODING_UNSPECIFIED")) return .{ .ok = null };
    return .bad;
}

/// The part of a mask path under `parent`: `encoding` of
/// `schemaSettings.encoding`, in either spelling.
fn partOf(path: []const u8, comptime parent: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;
    return if (sameField(path[0..dot], parent)) path[dot + 1 ..] else null;
}

/// How much of a schema a read asks for.
fn viewOf(arena: Allocator, query: []const u8) Allocator.Error!Parsed(enum { unsaid, basic, full }) {
    const text = (try queryValue(arena, query, "view")) orelse return .{ .ok = .unsaid };
    if (std.mem.eql(u8, text, "BASIC")) return .{ .ok = .basic };
    if (std.mem.eql(u8, text, "FULL")) return .{ .ok = .full };
    if (std.mem.eql(u8, text, "SCHEMA_VIEW_UNSPECIFIED")) return .{ .ok = .unsaid };
    return .{ .refused = try badValue(arena, "view") };
}

const GivenSchema = struct { type: FakePubSub.SchemaType, definition: []const u8 };

/// A schema as a create, a commit, a validate or a validateMessage gives
/// one, checked as far as the fake reads one: its type, its size, and
/// that an Avro definition is JSON.
fn schemaOf(arena: Allocator, value: Value) Allocator.Error!Parsed(GivenSchema) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "schema") },
    };
    var kind: ?FakePubSub.SchemaType = null;
    var definition: []const u8 = "";
    var it = object.iterator();
    while (it.next()) |field| {
        const key = field.key_ptr.*;
        if (isField(key, "type")) {
            const text = stringOf(field.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
            kind = if (std.mem.eql(u8, text, "AVRO")) .avro else if (std.mem.eql(u8, text, "PROTOCOL_BUFFER")) .protocol_buffer else if (std.mem.eql(u8, text, "TYPE_UNSPECIFIED")) null else return .{ .refused = try badValue(arena, key) };
        } else if (isField(key, "definition")) {
            definition = stringOf(field.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
        } else if (!isAnyField(key, &.{ "name", "revisionId", "revisionCreateTime" })) return .{ .refused = try unknownName(arena, key) };
    }
    const of = kind orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "The schema's type must be specified.") };
    // 307,200 bytes were taken, and one more refused in these words.
    if (definition.len > 307_200) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.") };
    if (of == .avro) {
        if (definition.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid schema definition: Avro schema did not specify a text definition: .") };
        if (!(std.json.validate(arena, definition) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        })) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "AVRO schema definition is not valid: Tried to parse invalid JSON.") };
    }
    return .{ .ok = .{ .type = of, .definition = definition } };
}

/// A refusal with production's `ErrorInfo` beside it: a reason, and what
/// it has to say of it.
fn refusalWith(arena: Allocator, message: []const u8, reason: []const u8, metadata: []const FakePubSub.Label) Allocator.Error!FakePubSub.Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeRefusalWith(&jw, message, reason, metadata) catch return error.OutOfMemory;
    return .{ .status = 400, .body = out.written() };
}

fn writeRefusalWith(jw: *Stringify, message: []const u8, reason: []const u8, metadata: []const FakePubSub.Label) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(400);
    try jw.objectField("message");
    try jw.write(message);
    try jw.objectField("status");
    try jw.write("INVALID_ARGUMENT");
    try jw.objectField("details");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("@type");
    try jw.write("type.googleapis.com/google.rpc.ErrorInfo");
    try jw.objectField("reason");
    try jw.write(reason);
    try jw.objectField("domain");
    try jw.write("pubsub.googleapis.com");
    if (metadata.len > 0) {
        try jw.objectField("metadata");
        try writeLabels(jw, metadata);
    }
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
}

const SchemaShown = struct { definition: bool = true, revision_in_name: bool = false };

fn renderSchema(arena: Allocator, schema: *const FakePubSub.Schema, revision: *const FakePubSub.Revision, shown: SchemaShown) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSchema(&jw, schema, revision, shown) catch return error.OutOfMemory;
    return out.written();
}

/// One revision of a schema, in the order production writes the fields.
fn writeSchema(jw: *Stringify, schema: *const FakePubSub.Schema, revision: *const FakePubSub.Revision, shown: SchemaShown) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    if (shown.revision_in_name) {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        try jw.writer.writeAll(schema.name);
        try jw.writer.writeByte('@');
        try jw.writer.writeAll(&revision.id);
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    } else try jw.write(schema.name);
    try jw.objectField("type");
    try jw.write(if (schema.type == .avro) "AVRO" else "PROTOCOL_BUFFER");
    if (shown.definition) {
        try jw.objectField("definition");
        try jw.write(revision.definition);
    }
    try jw.objectField("revisionId");
    try jw.write(&revision.id);
    var time_buf: [timestamp.max_len]u8 = undefined;
    try jw.objectField("revisionCreateTime");
    try jw.write(timestamp.format(&time_buf, revision.created));
    try jw.endObject();
}

/// An etag's bytes: `00 20 01` for a policy never written, which reads
/// `ACAB`, and after a write a 7 and the microsecond of the write in
/// seven bytes, which is how production's `BwZdpJFCzTA=` reads.
fn etagBytes(buf: *[8]u8, stamp: u64) []const u8 {
    if (stamp == 0) {
        buf[0..3].* = .{ 0x00, 0x20, 0x01 };
        return buf[0..3];
    }
    std.mem.writeInt(u64, buf, stamp, .big);
    buf[0] = 0x07;
    return buf;
}

/// Whether bytes have the form of one of the two. (Production said only
/// that an etag which is none is "Invalid etag", never the mismatch: what
/// it takes for one is the fake's reading.)
fn isEtag(raw: []const u8) bool {
    return (raw.len == 3 and std.mem.eql(u8, raw, &.{ 0x00, 0x20, 0x01 })) or (raw.len == 8 and raw[0] == 0x07);
}

fn renderPolicy(arena: Allocator, policy: FakePubSub.Policy) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writePolicy(&jw, policy) catch return error.OutOfMemory;
    return out.written();
}

/// In production's order: the version, the etag, the bindings. A policy
/// never written is its etag alone. (That one written empty still says
/// its version is the fake's own: production's was not recorded.)
fn writePolicy(jw: *Stringify, policy: FakePubSub.Policy) Stringify.Error!void {
    var raw: [8]u8 = undefined;
    var text: [12]u8 = undefined;
    try jw.beginObject();
    if (policy.stamp != 0) {
        try jw.objectField("version");
        try jw.write(1);
    }
    try jw.objectField("etag");
    try jw.write(std.base64.standard.Encoder.encode(&text, etagBytes(&raw, policy.stamp)));
    if (policy.bindings.len > 0) {
        try jw.objectField("bindings");
        try jw.beginArray();
        for (policy.bindings) |binding| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write(binding.role);
            try jw.objectField("members");
            try jw.write(binding.members);
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
}

/// A policy's bindings as production stores them: a binding with no
/// members is dropped, a member named twice is kept once, two bindings of
/// one role are one, and an address is in lower case. (In what order it
/// then reads them back was not recorded: here, the request's.)
fn bindingsOf(arena: Allocator, of_subscription: bool, list: []const Value) Allocator.Error!Parsed([]const FakePubSub.Policy.Binding) {
    const Building = struct { role: []const u8, members: std.ArrayList([]const u8) = .empty };
    var building: std.ArrayList(Building) = .empty;
    for (list) |item| {
        const object = switch (item) {
            .object => |o| o,
            else => return .{ .refused = try badValue(arena, "bindings") },
        };
        var role: []const u8 = "";
        var members: []const Value = &.{};
        var it = object.iterator();
        while (it.next()) |field| {
            const key = field.key_ptr.*;
            if (isField(key, "role")) {
                role = stringOf(field.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
            } else if (isField(key, "members")) {
                members = switch (field.value_ptr.*) {
                    .array => |a| a.items,
                    else => return .{ .refused = try badValue(arena, key) },
                };
            } else if (isField(key, "condition")) {
                // Its status word was not recorded: 400's usual one.
                if (field.value_ptr.* != .null) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Can't set conditional policy on this resource") };
            } else return .{ .refused = try unknownName(arena, key) };
        }
        switch (roleKind(of_subscription, role)) {
            .taken => {},
            .refused => return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Role {s} is not supported for this resource.", .{role})) },
            .unknown => return .{ .refused = try notModelled(arena, try std.fmt.allocPrint(arena, "the role {s} on this resource", .{role})) },
        }
        const slot = for (building.items) |*b| {
            if (std.mem.eql(u8, b.role, role)) break b;
        } else new: {
            try building.append(arena, .{ .role = role });
            break :new &building.items[building.items.len - 1];
        };
        each: for (members) |m| {
            const member = switch (try memberOf(arena, stringOf(m) orelse return .{ .refused = try badValue(arena, "members") })) {
                .ok => |text| text,
                .refused => |r| return .{ .refused = r },
            };
            for (slot.members.items) |have| {
                if (std.mem.eql(u8, have, member)) continue :each;
            }
            try slot.members.append(arena, member);
        }
    }
    var out: std.ArrayList(FakePubSub.Policy.Binding) = .empty;
    for (building.items) |b| {
        if (b.members.items.len > 0) try out.append(arena, .{ .role = b.role, .members = b.members.items });
    }
    return .{ .ok = out.items };
}

/// Whether a resource takes a role. Topics and subscriptions took
/// Pub/Sub's own roles and the basic `roles/viewer` and `roles/editor`,
/// and a subscription refused the topic's `roles/pubsub.publisher`, in
/// the words the fake gives every role it refuses: another service's,
/// and text that is no role. A custom role the fake cannot look up, and
/// takes. Of `roles/owner`, and of a Pub/Sub role not among the five,
/// production was not asked. Snapshots and schemas, whose policies it was
/// never asked to write, are held to the topic's rule.
fn roleKind(of_subscription: bool, role: []const u8) enum { taken, refused, unknown } {
    for ([_][]const u8{ "projects/", "organizations/" }) |prefix| {
        if (!std.mem.startsWith(u8, role, prefix)) continue;
        const rest = role[prefix.len..];
        const cut = std.mem.indexOf(u8, rest, "/roles/") orelse return .refused;
        return if (cut > 0 and rest.len > cut + "/roles/".len) .taken else .refused;
    }
    if (std.mem.eql(u8, role, "roles/pubsub.publisher")) return if (of_subscription) .refused else .taken;
    for ([_][]const u8{ "roles/pubsub.admin", "roles/pubsub.editor", "roles/pubsub.subscriber", "roles/pubsub.viewer", "roles/viewer", "roles/editor" }) |known| {
        if (std.mem.eql(u8, role, known)) return .taken;
    }
    if (std.mem.eql(u8, role, "roles/owner") or std.mem.startsWith(u8, role, "roles/pubsub.")) return .unknown;
    return .refused;
}

/// A member as production stores one: its prefix as written, and an
/// address in lower case. A prefix in another case, and Cloud Storage's
/// `projectOwner:` and its kin, production refuses; its words were not
/// kept, and these are the fake's. Whether a principal is there the fake
/// cannot know, and takes it to be.
fn memberOf(arena: Allocator, text: []const u8) Allocator.Error!Parsed([]const u8) {
    if (std.mem.eql(u8, text, "allUsers") or std.mem.eql(u8, text, "allAuthenticatedUsers")) return .{ .ok = text };
    for ([_][]const u8{ "user:", "serviceAccount:", "group:", "domain:" }) |prefix| {
        if (!std.mem.startsWith(u8, text, prefix) or text.len == prefix.len) continue;
        const stored = try arena.dupe(u8, text);
        _ = std.ascii.lowerString(stored[prefix.len..], text[prefix.len..]);
        return .{ .ok = stored };
    }
    for ([_][]const u8{ "principal://", "principalSet://" }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix) and text.len > prefix.len) return .{ .ok = text };
    }
    // IAM's own record of a principal that was deleted: the fake deletes
    // none, and production was not asked to write one.
    if (std.mem.startsWith(u8, text, "deleted:")) return .{ .refused = try notModelled(arena, "a deleted: member") };
    return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid member (member={s}).", .{text})) };
}

/// The permissions of each kind of resource that the fake knows by name.
const permissions = [_]struct { of: @FieldType(FakePubSub.Route, "collection"), names: []const []const u8 }{
    .{ .of = .topics, .names = &.{ "attachSubscription", "delete", "detachSubscription", "get", "getIamPolicy", "publish", "setIamPolicy", "update" } },
    .{ .of = .subscriptions, .names = &.{ "consume", "delete", "get", "getIamPolicy", "setIamPolicy", "update" } },
    .{ .of = .snapshots, .names = &.{ "delete", "get", "getIamPolicy", "seek", "setIamPolicy", "update" } },
    .{ .of = .schemas, .names = &.{ "attach", "commit", "delete", "get", "getIamPolicy", "listRevisions", "rollback", "setIamPolicy", "validate" } },
};

/// What a test of `name` on a resource of `collection` comes to: held,
/// when it is one of that kind of resource's that the fake knows;
/// refused, a wildcard, another service's, or no permission's name; and
/// unknown, one of Pub/Sub's that is another kind's or not on the list.
fn permissionKind(collection: @FieldType(FakePubSub.Route, "collection"), name: []const u8) enum { held, refused, unknown } {
    const prefix = "pubsub.";
    if (!std.mem.startsWith(u8, name, prefix)) return .refused;
    const rest = name[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return .refused;
    if (dot == 0 or dot + 1 == rest.len) return .refused;
    for (rest) |c| {
        if (!std.ascii.isAlphabetic(c) and c != '.') return .refused;
    }
    for (permissions) |known| {
        if (known.of != collection or !std.mem.eql(u8, @tagName(known.of), rest[0..dot])) continue;
        for (known.names) |verb| {
            if (std.mem.eql(u8, verb, rest[dot + 1 ..])) return .held;
        }
    }
    return .unknown;
}

fn detachedRefusal(arena: Allocator) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "FAILED_PRECONDITION", "This method is not supported on detached subscriptions.");
}

// What Pub/Sub would do on its own, and the fake keeps: where a
// subscription's messages go, what runs on them, and where a topic's come
// from. Each is checked as production checked it, one fault at a time: of
// several in one request, which is named is the fake's own. The fake has
// no world outside itself, so a table, a bucket, a stream, a service
// account and a tag are each taken to be there, and to be allowed.

/// Production's answer to a pull, or to a lease change, on a subscription
/// that pushes. That one that exports answers the same is the fake's own:
/// production was not asked.
fn notThisKind(arena: Allocator) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "FAILED_PRECONDITION", "This method is not supported for this subscription type.");
}

/// A refusal with the detail production gives a field it could not read.
fn badRequest(arena: Allocator, field: []const u8, message: []const u8) Allocator.Error!FakePubSub.Reply {
    return .{ .status = 400, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = 400,
        .message = message,
        .status = "INVALID_ARGUMENT",
        .details = .{.{
            .@"@type" = "type.googleapis.com/google.rpc.BadRequest",
            .fieldViolations = .{.{ .field = field, .description = message }},
        }},
    } }, .{}) };
}

/// A second member of a oneof, named as the request spelled it.
/// Production's detail is recorded for an import topic's two sources; the
/// probes of the other two kept the message alone.
fn oneofRefusal(arena: Allocator, comptime field: []const u8, comptime oneof: []const u8, second: []const u8) Allocator.Error!FakePubSub.Reply {
    return badRequest(arena, field, try std.fmt.allocPrint(arena, "Invalid value at '" ++ field ++ "' (oneof), oneof field '" ++ oneof ++ "' is already set. Cannot set '{s}'", .{second}));
}

/// One kind of delivery at most, and none beside exactly-once delivery.
/// (All three at once production was not shown.)
fn oneDelivery(arena: Allocator, push: ?FakePubSub.Push, bigquery: ?FakePubSub.BigQuery, storage: ?FakePubSub.CloudStorage, exactly_once: bool) Allocator.Error!Parsed(FakePubSub.Delivery) {
    const kinds = @as(u8, @intFromBool(push != null)) + @intFromBool(bigquery != null) + @intFromBool(storage != null);
    if (kinds == 3) return .{ .refused = try notModelled(arena, "a subscription with all three kinds of delivery") };
    if (kinds == 2) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Cannot create a subscription with multiple configurations. Only at most one of {s}, {s} can be specified.", .{
        if (push != null) "PushConfig" else "BigQueryConfig",
        if (storage != null) "CloudStorageConfig" else "BigQueryConfig",
    })) };
    if (kinds == 1 and exactly_once) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "A subscription cannot have {s} config set with exactly once delivery configured.", .{
        if (push != null) "push" else if (bigquery != null) "bigquery" else "cloud storage",
    })) };
    if (push) |config| return .{ .ok = .{ .push = config } };
    if (bigquery) |config| return .{ .ok = .{ .bigquery = config } };
    if (storage) |config| return .{ .ok = .{ .cloud_storage = config } };
    return .{ .ok = .pull };
}

/// A subscription that writes files has an ack deadline no shorter than
/// a file is kept open: production raised 10 seconds to 60, to 300 and to
/// 600 with the file's duration, and left it there when the subscription
/// went on to push. (It was given the deadline and the config together;
/// that a later update of the deadline alone is held to this too is the
/// fake's own.)
fn fileDeadline(delivery: FakePubSub.Delivery, seconds: u32) u32 {
    return switch (delivery) {
        .cloud_storage => |config| @max(seconds, @as(u32, @intCast(@divFloor(config.max_duration_ns + std.time.ns_per_s - 1, std.time.ns_per_s)))),
        .pull, .push, .bigquery => seconds,
    };
}

/// A `pushConfig`. Null: it names no endpoint, which is what a
/// subscription that pulls has, whatever else it holds. (Production was
/// shown `{}`, and answers an update with a version and no endpoint.)
fn pushOf(arena: Allocator, value: Value) Allocator.Error!Parsed(?FakePubSub.Push) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "pushConfig") },
    };
    var push: FakePubSub.Push = .{ .endpoint = "" };
    var other_attribute = false;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const given = entry.value_ptr.*;
        if (isField(key, "pushEndpoint")) {
            push.endpoint = stringOf(given) orelse return .{ .refused = try badValue(arena, key) };
        } else if (isField(key, "attributes")) {
            const attributes = (try stringMapOf(arena, given)) orelse return .{ .refused = try badValue(arena, key) };
            for (attributes) |a| {
                if (std.mem.eql(u8, a.key, "x-goog-version")) push.version = a.value else other_attribute = true;
            }
        } else if (isField(key, "oidcToken")) {
            const token = switch (given) {
                .object => |o| o,
                else => return .{ .refused = try badValue(arena, key) },
            };
            var oidc: FakePubSub.Push.Oidc = .{ .email = "" };
            var parts = token.iterator();
            while (parts.next()) |part| {
                const name = part.key_ptr.*;
                const text = stringOf(part.value_ptr.*) orelse return .{ .refused = try badValue(arena, name) };
                if (isField(name, "serviceAccountEmail")) oidc.email = text else if (isField(name, "audience")) oidc.audience = text else return .{ .refused = try unknownName(arena, name) };
            }
            push.oidc = oidc;
        } else if (isAnyField(key, &.{ "pubsubWrapper", "noWrapper" })) {
            if (push.wrapper != .unsaid) return .{ .refused = try oneofRefusal(arena, "push_config", "wrapper", key) };
            const wrapper = switch (given) {
                .object => |o| o,
                else => return .{ .refused = try badValue(arena, key) },
            };
            push.wrapper = if (isField(key, "pubsubWrapper")) .pubsub else .{ .none = .{} };
            var parts = wrapper.iterator();
            while (parts.next()) |part| {
                const name = part.key_ptr.*;
                if (push.wrapper != .none or !isField(name, "writeMetadata")) return .{ .refused = try unknownName(arena, name) };
                push.wrapper.none.write_metadata = boolOf(part.value_ptr.*) orelse return .{ .refused = try badValue(arena, name) };
            }
        } else return .{ .refused = try unknownName(arena, key) };
    }
    if (push.endpoint.len == 0) return .{ .ok = null };
    if (!isPushEndpoint(push.endpoint)) return .{ .refused = try badEndpoint(arena, push.endpoint) };
    if (push.version) |version| {
        if (!std.mem.eql(u8, version, "v1") and !std.mem.eql(u8, version, "v1beta1")) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid push endpoint version given in push config (version={s}).", .{version})) };
    }
    // Production was shown another attribute only beside a version it
    // refused.
    if (other_attribute) return .{ .refused = try notModelled(arena, "a push attribute other than x-goog-version") };
    if (push.oidc) |token| {
        // An account that is not there, production refuses so; the fake
        // knows of none, and only that no address is no account.
        if (token.email.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=PushConfig::oidc_token::service_account_email).") };
    }
    return .{ .ok = push };
}

/// Production takes an `https://` URL and refused `http://` and text that
/// is no URL. The fake's reading of the rest: something after the scheme,
/// and no space or control character.
fn isPushEndpoint(endpoint: []const u8) bool {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, endpoint, scheme) or endpoint.len == scheme.len) return false;
    for (endpoint) |c| {
        if (c <= ' ' or c == 0x7f) return false;
    }
    return true;
}

fn badEndpoint(arena: Allocator, endpoint: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid push endpoint given (endpoint={s}). Refer to https://cloud.google.com/pubsub/subscriber#create for more information.", .{endpoint}));
}

/// A `bigqueryConfig`. A `state` in it is production's to say, and is
/// taken and ignored.
fn bigQueryOf(arena: Allocator, value: Value) Allocator.Error!Parsed(FakePubSub.BigQuery) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "bigqueryConfig") },
    };
    var config: FakePubSub.BigQuery = .{};
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const given = entry.value_ptr.*;
        if (isField(key, "state")) continue;
        if (isAnyField(key, &.{ "table", "serviceAccountEmail" })) {
            const text = stringOf(given) orelse return .{ .refused = try badValue(arena, key) };
            if (isField(key, "table")) config.table = text else config.service_account = text;
            continue;
        }
        const flag: *bool = if (isField(key, "useTopicSchema"))
            &config.use_topic_schema
        else if (isField(key, "writeMetadata"))
            &config.write_metadata
        else if (isField(key, "dropUnknownFields"))
            &config.drop_unknown_fields
        else if (isField(key, "useTableSchema"))
            &config.use_table_schema
        else
            return .{ .refused = try unknownName(arena, key) };
        flag.* = boolOf(given) orelse return .{ .refused = try badValue(arena, key) };
    }
    switch (tableForm(config.table)) {
        .ok => {},
        .malformed => return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.") },
        .too_many => return .{ .refused = try fail(arena, 404, "NOT_FOUND", "Requested entity was not found.") },
    }
    if (config.use_table_schema and config.use_topic_schema) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "The options use_table_schema and use_topic_schema cannot both be set to 'true' when creating a BigQuery subscription.") };
    return .{ .ok = config };
}

/// `project.dataset.table`, or `project:dataset.table`. Production said
/// "invalid argument" to fewer parts and to an empty one, and "not found"
/// to four with dots. The colon form it was shown well formed alone, and
/// is held here to the same rule.
fn tableForm(table: []const u8) enum { ok, malformed, too_many } {
    var rest = table;
    var wanted: usize = 3;
    if (std.mem.indexOfScalar(u8, table, ':')) |colon| {
        if (colon == 0) return .malformed;
        rest = table[colon + 1 ..];
        wanted = 2;
    }
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, rest, '.');
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return .malformed;
    }
    if (count < wanted) return .malformed;
    return if (count > wanted) .too_many else .ok;
}

/// A `cloudStorageConfig`, with the format and the five minutes
/// production fills in when none is said.
fn cloudStorageOf(arena: Allocator, value: Value) Allocator.Error!Parsed(FakePubSub.CloudStorage) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "cloudStorageConfig") },
    };
    var config: FakePubSub.CloudStorage = .{};
    var format_said = false;
    var duration: ?i128 = null;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const given = entry.value_ptr.*;
        if (isField(key, "state")) continue;
        if (isAnyField(key, &.{ "textConfig", "avroConfig" })) {
            if (format_said) return .{ .refused = try oneofRefusal(arena, "cloud_storage_config", "output_format", key) };
            format_said = true;
            const inner = switch (given) {
                .object => |o| o,
                else => return .{ .refused = try badValue(arena, key) },
            };
            if (isField(key, "avroConfig")) config.format = .{ .avro = .{} };
            var parts = inner.iterator();
            while (parts.next()) |part| {
                const name = part.key_ptr.*;
                if (config.format != .avro or !isAnyField(name, &.{ "writeMetadata", "useTopicSchema" })) return .{ .refused = try unknownName(arena, name) };
                const flag = boolOf(part.value_ptr.*) orelse return .{ .refused = try badValue(arena, name) };
                if (isField(name, "writeMetadata")) config.format.avro.write_metadata = flag else config.format.avro.use_topic_schema = flag;
            }
        } else if (isField(key, "maxDuration")) {
            duration = durationOf(given) orelse return .{ .refused = try badValue(arena, key) };
        } else if (isAnyField(key, &.{ "maxBytes", "maxMessages" })) {
            const n = intOf(given) orelse return .{ .refused = try badValue(arena, key) };
            if (isField(key, "maxBytes")) config.max_bytes = n else config.max_messages = n;
        } else {
            const text: *[]const u8 = if (isField(key, "bucket"))
                &config.bucket
            else if (isField(key, "filenamePrefix"))
                &config.prefix
            else if (isField(key, "filenameSuffix"))
                &config.suffix
            else if (isField(key, "filenameDatetimeFormat"))
                &config.datetime_format
            else if (isField(key, "serviceAccountEmail"))
                &config.service_account
            else
                return .{ .refused = try unknownName(arena, key) };
            text.* = stringOf(given) orelse return .{ .refused = try badValue(arena, key) };
        }
    }
    // A bucket of no form, `gs://` before it included, production
    // answers as an outage.
    if (config.bucket.len == 0 or std.mem.indexOfScalar(u8, config.bucket, '/') != null) return .{ .refused = try fail(arena, 503, "UNAVAILABLE", "The service was unable to fulfill your request. Please try again. [code=8a75]") };
    const naming = "Refer to https://cloud.google.com/storage/docs/objects#naming for more information.";
    // Production refused a line break in the prefix. That it refuses the
    // other control characters, and the suffix alike, is the fake's own.
    inline for (.{ "prefix", "suffix" }) |part| {
        for (@field(config, part)) |c| {
            if (c < ' ' or c == 0x7f) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid Cloud Storage filename " ++ part ++ " given (value={s}): Disallowed unicode characters present. " ++ naming, .{@field(config, part)})) };
        }
    }
    if (std.mem.endsWith(u8, config.suffix, "/")) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid Cloud Storage filename suffix given (value={s}): Ends with invalid character '/'. " ++ naming, .{config.suffix})) };
    const length = charCount(config.prefix) + charCount(config.suffix);
    if (length > 992) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The sum of the lengths of the Cloud Storage subscription's filename prefix and suffix is {d} characters, but the maximum allowed is 992.", .{length})) };
    if (try datetimeFault(arena, config.datetime_format)) |why| return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid Cloud Storage filename datetime format given (value={s}): {s}", .{ config.datetime_format, why })) };
    if (duration) |ns| {
        if (ns < 60 * std.time.ns_per_s or ns > 600 * std.time.ns_per_s) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for Cloud Storage file batching duration is out of bounds. You passed {s} in the request, but the value must be between 1m and 10m.", .{try durationWords(arena, ns)})) };
        config.max_duration_ns = @intCast(ns);
    }
    // 0 is "not said": no such limit.
    if (config.max_bytes != 0 and (config.max_bytes < 1000 or config.max_bytes > 10_737_418_240)) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for Cloud Storage file batching bytes is out of bounds. You passed {d} in the request, but the value must be between 1000 and 10737418240.", .{config.max_bytes})) };
    if (config.max_messages != 0 and config.max_messages < 1000) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The value for Cloud Storage file batching messages is too small. You passed {d} in the request, but the minimum value is 1000.", .{config.max_messages})) };
    return .{ .ok = config };
}

fn charCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// What production says is wrong with a filename datetime format, or
/// null: each of a year (`YYYY` or `YY`), `MM`, `DD`, `hh`, `mm` and `ss`
/// once; at most one `T`, and at most one of `Z` and `+00:00`; between
/// them only `-`, `_`, `:` and `/`. None at all is production's default.
///
/// Production's words are recorded for a year, an `hh` and an `ss` that
/// is missing, for a second year, `ss`, `T`, `Z` and offset, and for a
/// character it does not take; and it named a missing one before a
/// second one, and either before a character. That `MM`, `DD` and `mm`
/// are named so, and the order beyond that, are the fake's own.
fn datetimeFault(arena: Allocator, format: []const u8) Allocator.Error!?[]const u8 {
    if (format.len == 0) return null;
    const matchers = [_]struct { []const u8, usize }{
        .{ "YYYY", 0 }, .{ "YY", 0 }, .{ "MM", 1 }, .{ "DD", 2 }, .{ "hh", 3 },
        .{ "mm", 4 },   .{ "ss", 5 }, .{ "T", 6 },  .{ "Z", 7 },  .{ "+00:00", 8 },
    };
    const names = [_][]const u8{ "year", "MM", "DD", "hh", "mm", "ss", "T", "Z" };
    var counts: [9]usize = @splat(0);
    var stray: ?[]const u8 = null;
    var i: usize = 0;
    scan: while (i < format.len) {
        for (matchers) |matcher| {
            if (std.mem.startsWith(u8, format[i..], matcher[0])) {
                counts[matcher[1]] += 1;
                i += matcher[0].len;
                continue :scan;
            }
        }
        const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
        const char = format[i..@min(format.len, i + len)];
        if (stray == null and std.mem.indexOfScalar(u8, "-_:/", format[i]) == null) stray = char;
        i += char.len;
    }
    for (names[0..6], counts[0..6]) |name, count| {
        if (count == 0) return try std.fmt.allocPrint(arena, "Required {s} matcher not present.", .{name});
    }
    for (names, counts[0..8]) |name, count| {
        if (count > 1) return try std.fmt.allocPrint(arena, "More than one {s} matcher present.", .{name});
    }
    if (counts[7] + counts[8] > 1) return "More than one timezone offset matcher present.";
    if (stray) |char| return try std.fmt.allocPrint(arena, "Contains disallowed characters ({s}).", .{char});
    return null;
}

/// A `messageTransforms` list: JavaScript functions, kept and never run.
/// At most five that are not disabled, no name twice, and no code over
/// 20,480 bytes. The fake reads no JavaScript: code that is none at all
/// cannot hold the function, which is what production said of it, and
/// any other is taken.
fn transformsOf(arena: Allocator, value: Value) Allocator.Error!Parsed([]const FakePubSub.Transform) {
    const list = switch (value) {
        .array => |a| a.items,
        else => return .{ .refused = try badValue(arena, "messageTransforms") },
    };
    const out = try arena.alloc(FakePubSub.Transform, list.len);
    var enabled: usize = 0;
    for (list, out, 0..) |item, *slot, index| {
        const object = switch (item) {
            .object => |o| o,
            else => return .{ .refused = try badValue(arena, "messageTransforms") },
        };
        var transform: FakePubSub.Transform = .{};
        var is_function = false;
        var it = object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const given = entry.value_ptr.*;
            if (isField(key, "enabled")) {
                transform.enabled = boolOf(given) orelse return .{ .refused = try badValue(arena, key) };
                continue;
            }
            if (isField(key, "disabled")) {
                transform.disabled = boolOf(given) orelse return .{ .refused = try badValue(arena, key) };
                continue;
            }
            const inner = switch (given) {
                .object => |o| o,
                else => return .{ .refused = if (isAnyField(key, &.{ "javascriptUdf", "aiInference", "compression" })) try badValue(arena, key) else try unknownName(arena, key) },
            };
            if (isField(key, "javascriptUdf")) {
                is_function = true;
                var parts = inner.iterator();
                while (parts.next()) |part| {
                    const name = part.key_ptr.*;
                    const text = stringOf(part.value_ptr.*) orelse return .{ .refused = try badValue(arena, name) };
                    if (isField(name, "functionName")) transform.function_name = text else if (isField(name, "code")) transform.code = text else return .{ .refused = try unknownName(arena, name) };
                }
            } else if (isField(key, "aiInference")) {
                // The two other kinds production refused empty, in these
                // words. One with something in it the fake has no answer
                // for.
                if (inner.count() == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "The request contains an AI Inference SMT without a set endpoint.") };
                return .{ .refused = try notModelled(arena, "an AI inference transform") };
            } else if (isField(key, "compression")) {
                if (inner.count() == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Compression algorithm is required for Compression message transform.") };
                return .{ .refused = try notModelled(arena, "a compression transform") };
            } else return .{ .refused = try unknownName(arena, key) };
        }
        if (!is_function) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "The request contains a MessageTransform with a missing message transform type.") };
        if (transform.function_name.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "The request contains a JavaScript UDF with an empty function name. Function names must be non-empty.") };
        if (transform.code.len > 20_480) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The `code` field of a JavaScript UDF exceeded the maximum allowed size of 20480 bytes. Code size: {d}. Function name: {s}.", .{ transform.code.len, transform.function_name })) };
        // A name twice is refused whether or not either is disabled.
        for (out[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.function_name, transform.function_name)) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The request contains multiple JavaScript UDFs with the function name: {s}. Each JavaScript UDF must have a unique function name.", .{transform.function_name})) };
        }
        // `enabled` counts for nothing: production ran a function sent
        // with `enabled: false`, and counted what is not disabled.
        enabled += @intFromBool(!transform.disabled);
        slot.* = transform;
    }
    if (enabled > 5) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "The request exceeds the maximum number of enabled message transforms. Maximum enabled transforms: 5. Enabled transforms: {d}.", .{enabled})) };
    for (out) |transform| {
        if (transform.code.len == 0) return .{ .refused = try fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(arena, "Provided message transform configuration is invalid: Failed to create JavaScript UDF: `{s}`. Failed to find function in provided code", .{transform.function_name})) };
    }
    return .{ .ok = out };
}

/// The four sources outside Google, each with its fields in the order the
/// service numbers them, and the word it has for being refused there.
/// Production refused every one the probes could offer, for what was at
/// the other end, so how it reads one back was never seen: the fake
/// writes them as it saw a Cloud Storage source written, the state first.
const outside_sources = [_]struct { name: []const u8, fields: []const []const u8, denied: []const u8 }{
    .{ .name = "awsKinesis", .fields = &.{ "streamArn", "consumerArn", "awsRoleArn", "gcpServiceAccount" }, .denied = "KINESIS_PERMISSION_DENIED" },
    .{ .name = "azureEventHubs", .fields = &.{ "resourceGroup", "namespace", "eventHub", "clientId", "tenantId", "subscriptionId", "gcpServiceAccount" }, .denied = "EVENT_HUBS_PERMISSION_DENIED" },
    .{ .name = "awsMsk", .fields = &.{ "clusterArn", "topic", "awsRoleArn", "gcpServiceAccount" }, .denied = "MSK_PERMISSION_DENIED" },
    .{ .name = "confluentCloud", .fields = &.{ "bootstrapServer", "clusterId", "topic", "identityPoolId", "gcpServiceAccount" }, .denied = "CONFLUENT_CLOUD_PERMISSION_DENIED" },
};

/// A topic's `ingestionDataSourceSettings`: one source, and what Pub/Sub
/// would log of it.
fn ingestionOf(arena: Allocator, value: Value) Allocator.Error!Parsed(FakePubSub.Ingestion) {
    const object = switch (value) {
        .object => |o| o,
        else => return .{ .refused = try badValue(arena, "ingestionDataSourceSettings") },
    };
    var severity: []const u8 = "";
    // The source is read once it is known to be the only one: production
    // refused a second before it looked into the first.
    var named: ?struct { kind: ?usize, object: std.json.ObjectMap } = null;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const inner = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return .{ .refused = try badValue(arena, key) },
        };
        if (isField(key, "platformLogsSettings")) {
            var parts = inner.iterator();
            while (parts.next()) |part| {
                if (!isField(part.key_ptr.*, "severity")) return .{ .refused = try unknownName(arena, part.key_ptr.*) };
                severity = stringOf(part.value_ptr.*) orelse return .{ .refused = try badValue(arena, "severity") };
                if (!isSeverity(severity)) return .{ .refused = try badValue(arena, "severity") };
            }
            continue;
        }
        const kind: ?usize = if (isField(key, "cloudStorage")) null else for (outside_sources, 0..) |source, index| {
            if (sameField(key, source.name)) break index;
        } else return .{ .refused = try unknownName(arena, key) };
        if (named != null) return .{ .refused = try oneofRefusal(arena, "ingestion_data_source_settings", "source", key) };
        named = .{ .kind = kind, .object = inner };
    }
    const source = named orelse return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Cloud Pub/Sub received invalid argument/s for the ingestion data source: The request's IngestionDataSourceSettings is missing a data source type.") };
    const kind = source.kind orelse return switch (try bucketSourceOf(arena, source.object)) {
        .ok => |bucket| .{ .ok = .{ .source = .{ .cloud_storage = bucket }, .log_severity = severity } },
        .refused => |r| .{ .refused = r },
    };
    return switch (try outsideSourceOf(arena, kind, source.object)) {
        .ok => |values| .{ .ok = .{ .source = .{ .outside = .{ .kind = kind, .values = values } }, .log_severity = severity } },
        .refused => |r| .{ .refused = r },
    };
}

/// The severities the service names. Production was shown `DEBUG` and
/// `WARNING`.
fn isSeverity(word: []const u8) bool {
    for ([_][]const u8{ "SEVERITY_UNSPECIFIED", "DISABLED", "DEBUG", "INFO", "WARNING", "ERROR" }) |known| {
        if (std.mem.eql(u8, word, known)) return true;
    }
    return false;
}

/// A bucket to import from. `gs://` before its name is taken and dropped.
fn bucketSourceOf(arena: Allocator, object: std.json.ObjectMap) Allocator.Error!Parsed(FakePubSub.Ingestion.Bucket) {
    const settings = "ingestion_data_source_settings.cloud_storage";
    var source: FakePubSub.Ingestion.Bucket = .{};
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const given = entry.value_ptr.*;
        if (isField(key, "state")) continue;
        if (isAnyField(key, &.{ "textFormat", "avroFormat", "pubsubAvroFormat" })) {
            // Two formats production was not shown: this is how it
            // refused two sources, and two formats of a subscription's
            // files.
            if (source.format != null) return .{ .refused = try oneofRefusal(arena, settings, "input_format", key) };
            const inner = switch (given) {
                .object => |o| o,
                else => return .{ .refused = try badValue(arena, key) },
            };
            source.format = if (isField(key, "textFormat")) .{ .text = null } else if (isField(key, "avroFormat")) .avro else .pubsub_avro;
            var parts = inner.iterator();
            while (parts.next()) |part| {
                const name = part.key_ptr.*;
                if (source.format.? != .text or !isField(name, "delimiter")) return .{ .refused = try unknownName(arena, name) };
                const delimiter = stringOf(part.value_ptr.*) orelse return .{ .refused = try badValue(arena, name) };
                // One byte: production took a tab, a NUL and a DEL, and
                // refused none at all, two, and one character of two
                // bytes.
                if (delimiter.len != 1) return .{ .refused = try fail(arena, 400, "FAILED_PRECONDITION", "The ingestion data source state and/or configuration is not sufficient for ingestion: IngestionDataSourceSettings::Gcs::text_format::delimiter must be a single character.") };
                source.format = .{ .text = delimiter };
            }
        } else if (isField(key, "minimumObjectCreateTime")) {
            const text = stringOf(given) orelse return .{ .refused = try badValue(arena, key) };
            const time = timestamp.parse(text) catch return .{ .refused = try badRequest(arena, settings ++ ".minimum_object_create_time", "Invalid value at '" ++ settings ++ ".minimum_object_create_time' (type.googleapis.com/google.protobuf.Timestamp), Field 'minimumObjectCreateTime', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.") };
            var buf: [timestamp.max_len]u8 = undefined;
            source.minimum_object_create_time = try arena.dupe(u8, timestamp.format(&buf, time));
        } else if (isField(key, "bucket")) {
            source.bucket = stringOf(given) orelse return .{ .refused = try badValue(arena, key) };
        } else if (isField(key, "matchGlob")) {
            source.match_glob = stringOf(given) orelse return .{ .refused = try badValue(arena, key) };
        } else return .{ .refused = try unknownName(arena, key) };
    }
    if (std.mem.startsWith(u8, source.bucket, "gs://")) source.bucket = source.bucket["gs://".len..];
    if (std.mem.indexOfScalar(u8, source.bucket, '/') != null) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Cloud Pub/Sub received invalid argument/s for the ingestion data source: projects/-/buckets/{s} is not a valid resource name..", .{source.bucket})) };
    // Production looked for the bucket before either of these, and was
    // shown no bucket that was there without them.
    if (source.bucket.len == 0) return .{ .refused = try notModelled(arena, "a Cloud Storage source with no bucket") };
    if (source.format == null) return .{ .refused = try notModelled(arena, "a Cloud Storage source with no format") };
    return .{ .ok = source };
}

/// One of the four sources outside Google: a text for each of its fields.
/// A Kinesis source with nothing in it production refused for its first
/// field, in these words; that its other three are asked for in turn is
/// the fake's own, and the other sources' fields are not asked for at
/// all, since production's name for them was never seen.
fn outsideSourceOf(arena: Allocator, kind: usize, object: std.json.ObjectMap) Allocator.Error!Parsed([]const []const u8) {
    const fields = outside_sources[kind].fields;
    const values = try arena.alloc([]const u8, fields.len);
    @memset(values, "");
    var it = object.iterator();
    each: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isField(key, "state")) continue;
        for (fields, values) |field, *slot| {
            if (!sameField(key, field)) continue;
            slot.* = stringOf(entry.value_ptr.*) orelse return .{ .refused = try badValue(arena, key) };
            continue :each;
        }
        return .{ .refused = try unknownName(arena, key) };
    }
    if (kind == 0) for (fields, values) |field, text| {
        if (text.len > 0) continue;
        var snake: std.ArrayList(u8) = .empty;
        for (field) |c| {
            if (std.ascii.isUpper(c)) try snake.append(arena, '_');
            try snake.append(arena, std.ascii.toLower(c));
        }
        return .{ .refused = try fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(arena, "The ingestion data source state and/or configuration is not sufficient for ingestion: Missing a required field - IngestionDataSourceSettings::AwsKinesis::{s}..", .{snake.items})) };
    };
    return .{ .ok = values };
}

/// The tags of a create: Resource Manager's keys and values, each pair
/// by name (`project/key` and the value's short name) or by id
/// (`tagKeys/1` and `tagValues/2`), in production's words where the form
/// is wrong. A key or a value that is not there production refuses with
/// 403; the fake has no Resource Manager, and takes any of good form.
fn tagsOf(arena: Allocator, value: Value) Allocator.Error!Parsed([]const FakePubSub.Label) {
    const tags = (try stringMapOf(arena, value)) orelse return .{ .refused = try badValue(arena, "tags") };
    const same_format = "field [tags.tagValue] has issue [Both TagKey and TagValue must be provided in the same format.]";
    for (tags) |tag| {
        const key_by_id = isTagId(tag.key, "tagKeys/");
        const slash = std.mem.indexOfScalar(u8, tag.key, '/');
        const key_by_name = if (slash) |at| at > 0 and at + 1 < tag.key.len and std.mem.indexOfScalarPos(u8, tag.key, at + 1, '/') == null else false;
        if (!key_by_id and !key_by_name) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "INVALID_ARGUMENT: field [tags.tagKey] has issue [Invalid tag key specified. Please specify a valid tag key in the format <tag namespace>/<tag key name> where the tag namespace is the ID of the organization or name of the project that the tag key is defined in or tagKeys/<tag_key_id>. For example: \"123/environment\", or \"my-project/env\", or \"tagKeys/123\".]") };
        if (tag.value.len == 0) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "INVALID_ARGUMENT: field [tags.tagValue] has issue [The TagValue field must be populated for an entry in the Tags map.]\n" ++ same_format) };
        const value_by_id = isTagId(tag.value, "tagValues/");
        if (!value_by_id and std.mem.indexOfScalar(u8, tag.value, '/') != null) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "INVALID_ARGUMENT: field [tags.tagValue] has issue [Invalid tag value specified. Please specify a valid tag value. This must be the name of the value created under the specified tag key. For example: \"production\", or \"tagValues/456\".]\n" ++ same_format) };
        if (key_by_id != value_by_id) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "INVALID_ARGUMENT: " ++ same_format) };
    }
    return .{ .ok = tags };
}

fn isTagId(text: []const u8, comptime prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, text, prefix) or text.len == prefix.len) return false;
    return std.mem.indexOfScalar(u8, text[prefix.len..], '/') == null;
}

/// What this fake has no answer for: said, never guessed at.
fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!FakePubSub.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try std.fmt.allocPrint(arena, "fake: {s} is not modelled yet", .{what}));
}

/// Production's answer to a create, a read, and an update each write a
/// thing or two their own way.
const Answer = enum { created, as_read, after_update };

fn renderTopic(arena: Allocator, topic: *const FakePubSub.Topic, how: Answer) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeTopic(&jw, topic, how) catch return error.OutOfMemory;
    return out.written();
}

/// In the order production writes the fields, which is the order the
/// service numbers them in: where production was never seen to write a
/// field, the number says where it goes.
fn writeTopic(jw: *Stringify, topic: *const FakePubSub.Topic, how: Answer) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(topic.name);
    if (topic.labels.len > 0) {
        try jw.objectField("labels");
        try writeLabels(jw, topic.labels);
    }
    if (topic.storage_policy) |policy| {
        try jw.objectField("messageStoragePolicy");
        try jw.beginObject();
        try jw.objectField("allowedPersistenceRegions");
        try jw.write(policy.regions);
        if (policy.enforce_in_transit) {
            try jw.objectField("enforceInTransit");
            try jw.write(true);
        }
        try jw.endObject();
    }
    if (topic.kms_key_name) |key| {
        try jw.objectField("kmsKeyName");
        try jw.write(key);
    }
    if (topic.schema) |settings| {
        try jw.objectField("schemaSettings");
        try jw.beginObject();
        try jw.objectField("schema");
        try jw.write(if (settings.schema.deleted) "_deleted-schema_" else settings.schema.name);
        try jw.objectField("encoding");
        try jw.write(encodingName(settings.encoding));
        if (settings.first) |bound| {
            try jw.objectField("firstRevisionId");
            try jw.write(&bound.id);
        }
        if (settings.last) |bound| {
            try jw.objectField("lastRevisionId");
            try jw.write(&bound.id);
        }
        try jw.endObject();
    }
    if (topic.retention_s) |seconds| {
        try jw.objectField("messageRetentionDuration");
        try writeSeconds(jw, seconds);
    }
    if (topic.ingestion) |ingestion| {
        // An import topic reads a state of its own, and only reads it:
        // the answer to a create or an update has none.
        if (how == .as_read) {
            try jw.objectField("state");
            try jw.write(if (ingestion.state == .active or ingestion.state == .unknown) "ACTIVE" else "INGESTION_RESOURCE_ERROR");
        }
        try jw.objectField("ingestionDataSourceSettings");
        try jw.beginObject();
        switch (ingestion.source) {
            .cloud_storage => |source| {
                try jw.objectField("cloudStorage");
                try jw.beginObject();
                try writeState(jw, ingestionWord(ingestion));
                try jw.objectField("bucket");
                try jw.write(source.bucket);
                switch (source.format.?) {
                    .text => |delimiter| {
                        try jw.objectField("textFormat");
                        try jw.beginObject();
                        // With none said it is a line break, which the
                        // answer to an update alone leaves out.
                        const filled: ?[]const u8 = if (how == .after_update) null else "\n";
                        if (delimiter orelse filled) |d| {
                            try jw.objectField("delimiter");
                            try jw.write(d);
                        }
                        try jw.endObject();
                    },
                    .avro => {
                        try jw.objectField("avroFormat");
                        try writeNothing(jw);
                    },
                    .pubsub_avro => {
                        try jw.objectField("pubsubAvroFormat");
                        try writeNothing(jw);
                    },
                }
                if (source.minimum_object_create_time.len > 0) {
                    try jw.objectField("minimumObjectCreateTime");
                    try jw.write(source.minimum_object_create_time);
                }
                if (source.match_glob.len > 0) {
                    try jw.objectField("matchGlob");
                    try jw.write(source.match_glob);
                }
                try jw.endObject();
            },
            .outside => |source| {
                try jw.objectField(outside_sources[source.kind].name);
                try jw.beginObject();
                try writeState(jw, ingestionWord(ingestion));
                for (outside_sources[source.kind].fields, source.values) |field, text| {
                    if (text.len == 0) continue;
                    try jw.objectField(field);
                    try jw.write(text);
                }
                try jw.endObject();
            },
        }
        if (ingestion.log_severity.len > 0) {
            try jw.objectField("platformLogsSettings");
            try jw.beginObject();
            try jw.objectField("severity");
            try jw.write(ingestion.log_severity);
            try jw.endObject();
        }
        try jw.endObject();
    }
    try writeTransforms(jw, topic.transforms);
    try jw.endObject();
}

/// An object with nothing in it.
fn writeNothing(jw: *Stringify) Stringify.Error!void {
    try jw.beginObject();
    try jw.endObject();
}

fn writeState(jw: *Stringify, word: ?[]const u8) Stringify.Error!void {
    if (word) |w| {
        try jw.objectField("state");
        try jw.write(w);
    }
}

/// The state of an import topic's source, as the service spells it. Each
/// source has a word of its own for being refused at the source.
fn ingestionWord(ingestion: FakePubSub.Ingestion) ?[]const u8 {
    return switch (ingestion.state) {
        .unknown => null,
        .permission_denied => switch (ingestion.source) {
            .cloud_storage => "CLOUD_STORAGE_PERMISSION_DENIED",
            .outside => |source| outside_sources[source.kind].denied,
        },
        inline else => |state| comptime upperOf(@tagName(state)),
    };
}

/// The state of an export subscription's writes, as the service spells
/// it. Production was seen to say `ACTIVE` alone.
fn exportWord(state: types.ExportState) ?[]const u8 {
    return switch (state) {
        .unknown => null,
        .location_restriction => "IN_TRANSIT_LOCATION_RESTRICTION",
        inline else => |s| comptime upperOf(@tagName(s)),
    };
}

fn upperOf(comptime text: []const u8) []const u8 {
    comptime {
        var out: [text.len]u8 = undefined;
        _ = std.ascii.upperString(&out, text);
        const final = out;
        return &final;
    }
}

fn writeTransforms(jw: *Stringify, transforms: []const FakePubSub.Transform) Stringify.Error!void {
    if (transforms.len == 0) return;
    try jw.objectField("messageTransforms");
    try jw.beginArray();
    for (transforms) |transform| {
        try jw.beginObject();
        try jw.objectField("javascriptUdf");
        try jw.beginObject();
        try jw.objectField("functionName");
        try jw.write(transform.function_name);
        try jw.objectField("code");
        try jw.write(transform.code);
        try jw.endObject();
        // Each only when true: `enabled: false` reads back as nothing.
        if (transform.enabled) {
            try jw.objectField("enabled");
            try jw.write(true);
        }
        if (transform.disabled) {
            try jw.objectField("disabled");
            try jw.write(true);
        }
        try jw.endObject();
    }
    try jw.endArray();
}

/// A topic's name as a subscription or a snapshot of it reads it.
fn topicName(topic: *const FakePubSub.Topic) []const u8 {
    return if (topic.deleted) "_deleted-topic_" else topic.name;
}

fn renderSnapshot(arena: Allocator, snap: *const FakePubSub.Snapshot) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSnapshot(&jw, snap) catch return error.OutOfMemory;
    return out.written();
}

fn writeSnapshot(jw: *Stringify, snap: *const FakePubSub.Snapshot) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(snap.name);
    try jw.objectField("topic");
    try jw.write(topicName(snap.topic));
    var time_buf: [timestamp.max_len]u8 = undefined;
    try jw.objectField("expireTime");
    try jw.write(timestamp.format(&time_buf, snap.expire));
    if (snap.labels.len > 0) {
        try jw.objectField("labels");
        try writeLabels(jw, snap.labels);
    }
    try jw.endObject();
}

fn renderSubscription(arena: Allocator, sub: *const FakePubSub.Subscription, how: Answer) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSubscription(&jw, sub, how) catch return error.OutOfMemory;
    return out.written();
}

/// `pushConfig`, which every subscription reads. Production's answer to
/// the create of a push subscription, and to any update of any
/// subscription, fills in `x-goog-version`; a read shows none. (A read of
/// a version the request did say production was not asked for: here it
/// shows.)
fn writePushConfig(jw: *Stringify, delivery: FakePubSub.Delivery, how: Answer) Stringify.Error!void {
    const push: ?FakePubSub.Push = switch (delivery) {
        .push => |config| config,
        .pull, .bigquery, .cloud_storage => null,
    };
    const said: ?[]const u8 = if (push) |config| config.version else null;
    const version: ?[]const u8 = switch (how) {
        .as_read => said,
        .created => if (push != null) said orelse "v1" else null,
        .after_update => said orelse "v1",
    };
    try jw.beginObject();
    if (push) |config| {
        try jw.objectField("pushEndpoint");
        try jw.write(config.endpoint);
    }
    if (version) |v| {
        try jw.objectField("attributes");
        try jw.beginObject();
        try jw.objectField("x-goog-version");
        try jw.write(v);
        try jw.endObject();
    }
    if (push) |config| {
        if (config.oidc) |token| {
            try jw.objectField("oidcToken");
            try jw.beginObject();
            try jw.objectField("serviceAccountEmail");
            try jw.write(token.email);
            if (token.audience.len > 0) {
                try jw.objectField("audience");
                try jw.write(token.audience);
            }
            try jw.endObject();
        }
        switch (config.wrapper) {
            .unsaid => {},
            .pubsub => {
                try jw.objectField("pubsubWrapper");
                try writeNothing(jw);
            },
            .none => |wrapper| {
                try jw.objectField("noWrapper");
                try jw.beginObject();
                if (wrapper.write_metadata) {
                    try jw.objectField("writeMetadata");
                    try jw.write(true);
                }
                try jw.endObject();
            },
        }
    }
    try jw.endObject();
}

fn writeFlag(jw: *Stringify, comptime name: []const u8, flag: bool) Stringify.Error!void {
    if (!flag) return;
    try jw.objectField(name);
    try jw.write(true);
}

fn writeText(jw: *Stringify, comptime name: []const u8, text: []const u8) Stringify.Error!void {
    if (text.len == 0) return;
    try jw.objectField(name);
    try jw.write(text);
}

/// A 64-bit count, which proto3 JSON writes as a string.
fn writeCount(jw: *Stringify, comptime name: []const u8, count: i64) Stringify.Error!void {
    if (count == 0) return;
    var buf: [24]u8 = undefined;
    try jw.objectField(name);
    try jw.write(std.fmt.bufPrint(&buf, "{d}", .{count}) catch unreachable);
}

/// In the order production writes the fields, which is the order the
/// service numbers them in: where production was never seen to write a
/// field, the number says where it goes.
fn writeSubscription(jw: *Stringify, sub: *const FakePubSub.Subscription, how: Answer) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(sub.name);
    try jw.objectField("topic");
    try jw.write(topicName(sub.topic));
    try jw.objectField("pushConfig");
    try writePushConfig(jw, sub.delivery, how);
    try jw.objectField("ackDeadlineSeconds");
    try jw.write(sub.ack_deadline_s);
    if (sub.retain_acked) {
        try jw.objectField("retainAckedMessages");
        try jw.write(true);
    }
    try jw.objectField("messageRetentionDuration");
    try writeSeconds(jw, sub.retention_s);
    if (sub.labels.len > 0) {
        try jw.objectField("labels");
        try writeLabels(jw, sub.labels);
    }
    if (sub.ordered) {
        try jw.objectField("enableMessageOrdering");
        try jw.write(true);
    }
    try jw.objectField("expirationPolicy");
    try jw.beginObject();
    if (sub.expiration_ttl_s) |ttl| {
        try jw.objectField("ttl");
        try writeSeconds(jw, ttl);
    }
    try jw.endObject();
    if (sub.filter_text.len > 0) {
        try jw.objectField("filter");
        try jw.write(sub.filter_text);
    }
    if (sub.dead_letter) |policy| {
        try jw.objectField("deadLetterPolicy");
        try jw.beginObject();
        try jw.objectField("deadLetterTopic");
        try jw.write(policy.topic);
        try jw.objectField("maxDeliveryAttempts");
        try jw.write(policy.max_attempts);
        try jw.endObject();
    }
    if (sub.retry) |policy| {
        try jw.objectField("retryPolicy");
        try jw.beginObject();
        try jw.objectField("minimumBackoff");
        try writeSeconds(jw, policy.min_s);
        try jw.objectField("maximumBackoff");
        try writeSeconds(jw, policy.max_s);
        try jw.endObject();
    }
    if (sub.detached and how == .as_read) {
        try jw.objectField("detached");
        try jw.write(true);
    }
    if (sub.exactly_once) {
        try jw.objectField("enableExactlyOnceDelivery");
        try jw.write(true);
    }
    if (sub.topic.retention_s) |seconds| {
        if (!sub.topic.deleted) {
            try jw.objectField("topicMessageRetentionDuration");
            try writeSeconds(jw, seconds);
        }
    }
    // While an export cannot write, the subscription's own state says so.
    var working = true;
    switch (sub.delivery) {
        .bigquery => |config| {
            working = config.state == .active or config.state == .unknown;
            try jw.objectField("bigqueryConfig");
            try jw.beginObject();
            try jw.objectField("table");
            try jw.write(config.table);
            try writeFlag(jw, "useTopicSchema", config.use_topic_schema);
            try writeFlag(jw, "writeMetadata", config.write_metadata);
            try writeFlag(jw, "dropUnknownFields", config.drop_unknown_fields);
            try writeState(jw, exportWord(config.state));
            try writeFlag(jw, "useTableSchema", config.use_table_schema);
            try writeText(jw, "serviceAccountEmail", config.service_account);
            try jw.endObject();
        },
        .cloud_storage => |config| working = config.state == .active or config.state == .unknown,
        .pull, .push => {},
    }
    try jw.objectField("state");
    try jw.write(if (working) "ACTIVE" else "RESOURCE_ERROR");
    switch (sub.delivery) {
        .cloud_storage => |config| {
            try jw.objectField("cloudStorageConfig");
            try jw.beginObject();
            try jw.objectField("bucket");
            try jw.write(config.bucket);
            try writeText(jw, "filenamePrefix", config.prefix);
            try writeText(jw, "filenameSuffix", config.suffix);
            switch (config.format) {
                .text => {
                    try jw.objectField("textConfig");
                    try writeNothing(jw);
                },
                .avro => |avro| {
                    try jw.objectField("avroConfig");
                    try jw.beginObject();
                    try writeFlag(jw, "writeMetadata", avro.write_metadata);
                    try writeFlag(jw, "useTopicSchema", avro.use_topic_schema);
                    try jw.endObject();
                },
            }
            try jw.objectField("maxDuration");
            try writeDuration(jw, config.max_duration_ns);
            try writeCount(jw, "maxBytes", config.max_bytes);
            try writeCount(jw, "maxMessages", config.max_messages);
            try writeState(jw, exportWord(config.state));
            try writeText(jw, "filenameDatetimeFormat", config.datetime_format);
            try writeText(jw, "serviceAccountEmail", config.service_account);
            try jw.endObject();
        },
        .pull, .push, .bigquery => {},
    }
    try writeTransforms(jw, sub.transforms);
    try jw.endObject();
}

/// A duration as proto3 JSON writes one: whole seconds, or with three,
/// six or nine digits after the point.
fn writeDuration(jw: *Stringify, ns: i64) Stringify.Error!void {
    var buf: [40]u8 = undefined;
    const whole = @divTrunc(ns, std.time.ns_per_s);
    const part: u64 = @intCast(@mod(ns, std.time.ns_per_s));
    const text = if (part == 0)
        std.fmt.bufPrint(&buf, "{d}s", .{whole})
    else if (part % 1_000_000 == 0)
        std.fmt.bufPrint(&buf, "{d}.{d:0>3}s", .{ whole, part / 1_000_000 })
    else if (part % 1000 == 0)
        std.fmt.bufPrint(&buf, "{d}.{d:0>6}s", .{ whole, part / 1000 })
    else
        std.fmt.bufPrint(&buf, "{d}.{d:0>9}s", .{ whole, part });
    try jw.write(text catch unreachable);
}

fn writeLabels(jw: *Stringify, labels: []const FakePubSub.Label) Stringify.Error!void {
    try jw.beginObject();
    for (labels) |label| {
        try jw.objectField(label.key);
        try jw.write(label.value);
    }
    try jw.endObject();
}

fn writeSeconds(jw: *Stringify, seconds: i64) Stringify.Error!void {
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}s", .{seconds}) catch unreachable);
}

// Tests.

const testing = std.testing;
const test_util = @import("test_util.zig");
const Client = @import("Client.zig");

/// A fake, a clock the test moves, and a client of production's kind over
/// both.
const Bench = struct {
    clock: test_util.FakeClock,
    fake: FakePubSub,
    tokens: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(b: *Bench, options: FakePubSub.Options) !void {
        return b.initIn(testing.allocator, options);
    }

    fn initIn(b: *Bench, gpa: Allocator, options: FakePubSub.Options) !void {
        b.clock = .{};
        b.fake = .init(gpa, b.clock.io(), options);
        errdefer b.fake.deinit();
        b.tokens = .{};
        b.diag = .{};
        b.client = try .init(gpa, b.clock.io(), .{
            .project_id = "p",
            .token_provider = b.tokens.provider(),
            .transport = b.fake.transport(),
            .diagnostics = &b.diag,
        });
    }

    fn deinit(b: *Bench) void {
        b.client.deinit();
        b.fake.deinit();
    }

    fn advance(b: *Bench, seconds: i64) void {
        b.clock.now_ns += @as(i96, seconds) * std.time.ns_per_s;
    }

    /// One raw request, for what no client would send.
    fn raw(b: *Bench, arena: Allocator, method: tp.Method, path: []const u8, body: []const u8) !FakePubSub.Reply {
        const url = try std.fmt.allocPrint(arena, "https://pubsub.googleapis.com/v1/{s}", .{path});
        return b.fake.serve(method, url, body, arena);
    }
};

test "a message goes from a publish to a pull, and an ack takes it away" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var topic = try b.client.topic("orders").create(.{});
    defer topic.deinit();
    try testing.expectEqualStrings("projects/p/topics/orders", topic.value.name);
    var sub = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
    defer sub.deinit();
    try testing.expectEqual(10, sub.value.ack_deadline_seconds);
    try testing.expectEqual(std.Io.Duration.fromSeconds(604_800), sub.value.message_retention.?);

    var sent = try b.client.topic("orders").publish(&.{.{ .data = "hello", .attributes = &.{.{ .key = "k", .value = "v" }} }}, .{});
    defer sent.deinit();
    try testing.expectEqualStrings("1", sent.value.message_ids[0]);
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));

    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqual(1, got.value.messages.len);
    try testing.expectEqualStrings("hello", got.value.messages[0].data);
    try testing.expectEqualStrings("v", got.value.messages[0].attribute("k").?);
    try testing.expectEqualStrings("1", got.value.messages[0].message_id);
    try testing.expectEqual(1, b.fake.outstanding("p", "worker"));

    try b.client.subscription("worker").ack(&.{got.value.messages[0].ack_id});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    var none = try b.client.subscription("worker").pull(.{ .return_immediately = true });
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
}

/// `n` of the letter x, for text of a chosen length.
fn xs(comptime n: usize) [n]u8 {
    return @splat('x');
}

/// Asserts a refusal's HTTP code, status and words.
fn expectRefused(reply: FakePubSub.Reply, code: u16, status: []const u8, message: []const u8) !void {
    try testing.expectEqual(code, reply.status);
    const parsed = try std.json.parseFromSlice(struct { @"error": struct { code: u16, message: []const u8, status: []const u8 } }, testing.allocator, reply.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(code, parsed.value.@"error".code);
    try testing.expectEqualStrings(status, parsed.value.@"error".status);
    try testing.expectEqualStrings(message, parsed.value.@"error".message);
}

test "topics: made, read, changed and deleted, and refused in production's words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    // Production's answers, 2026-10-12.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-a\"}", (try b.raw(a, .PUT, "projects/p/topics/zigps-a", "{}")).body);
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-a", "{}"), 409, "ALREADY_EXISTS", "Resource already exists in the project (resource=zigps-a).");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x", "{\"nonsense\":1}"), 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field.");
    try testing.expectEqual(400, (try b.raw(a, .PUT, "projects/p/topics/zigps-x", "{")).status);
    // A name in the body is ignored: the path names the topic.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-x3\"}", (try b.raw(a, .PUT, "projects/p/topics/zigps-x3", "{\"name\":\"projects/p/topics/other\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"env":"test"},"messageRetentionDuration":"600s"}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-b", "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"600s\"}")).body);
    for ([_]tp.Method{ .GET, .DELETE }) |method| {
        try expectRefused(try b.raw(a, method, "projects/p/topics/zigps-nope", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    }
    try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-nope", "{\"topic\":{\"labels\":{\"a\":\"b\"}},\"updateMask\":\"labels\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");

    // Updates: a mask is required, names fields in either spelling, and a
    // field outside it is ignored.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"env":"prod","team":"x"},"messageRetentionDuration":"600s"}
    , (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"labels\":{\"env\":\"prod\",\"team\":\"x\"}},\"updateMask\":\"labels\"}")).body);
    for ([_][]const u8{ "{\"topic\":{\"labels\":{\"a\":\"b\"}}}", "{\"topic\":{\"labels\":{\"a\":\"b\"}},\"updateMask\":\"\"}" }) |body| {
        try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-b", body), 400, "INVALID_ARGUMENT", "The update_mask in the UpdateTopicRequest must be set, and must contain a non-empty paths list.");
    }
    try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{},\"updateMask\":\"nonsense\"}"), 400, "INVALID_ARGUMENT", "Invalid update_mask provided in the UpdateTopicRequest: 'nonsense' is not a known Topic field. Note that field paths must be of the form 'push_config' rather than 'pushConfig'.");
    try expectRefused(try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"name\":\"projects/p/topics/other\"},\"updateMask\":\"name\"}"), 400, "INVALID_ARGUMENT", "Invalid update_mask provided in the UpdateTopicRequest: the 'name' field in the Topic is not mutable.");
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"only":"this"},"messageRetentionDuration":"600s"}
    , (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"labels\":{\"only\":\"this\"},\"messageRetentionDuration\":\"1200s\"},\"updateMask\":\"labels\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-b","labels":{"only":"this"},"messageRetentionDuration":"1200s"}
    , (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{\"messageRetentionDuration\":\"1200s\"},\"updateMask\":\"message_retention_duration\"}")).body);
    // A path the body leaves out clears its field.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-b\"}", (try b.raw(a, .PATCH, "projects/p/topics/zigps-b", "{\"topic\":{},\"updateMask\":\"labels,messageRetentionDuration\"}")).body);

    // Bounds and names.
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x4", "{\"messageRetentionDuration\":\"599s\"}"), 400, "INVALID_ARGUMENT", "The value for message retention duration is out of bounds. You passed 9m59s in the request, but the value must be between 10m and 744h.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x5", "{\"messageRetentionDuration\":\"2678401s\"}"), 400, "INVALID_ARGUMENT", "The value for message retention duration is out of bounds. You passed 744h1s in the request, but the value must be between 10m and 744h.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x6", "{\"labels\":{\"Env\":\"x\"}}"), 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; key \"Env\" does not conform to regular expression \"[\\p{Ll}\\p{Lo}][\\p{Ll}\\p{Lo}\\p{N}_-]{0,62}\"; first character \"E\" is not a non-uppercased letter (Unicode character class Ll or Lo)).");
    var many: std.Io.Writer.Allocating = .init(a);
    try many.writer.writeAll("{\"labels\":{");
    for (0..65) |i| try many.writer.print("{s}\"k{d}\":\"v\"", .{ if (i == 0) "" else ",", i });
    try many.writer.writeAll("}}");
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-x7", many.written()), 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=Invalid labels: Invalid field \"labels\"; at most 64 entries allowed but found 65).");
    for ([_][]const u8{ "ab", "1zigps", "googzigps", "GOOGzigps", "zigps!x" }) |id| {
        const path = try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{id});
        const reply = try b.raw(a, .PUT, path, "{}");
        try expectRefused(reply, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(a, "Invalid resource name given (name=projects/p/topics/{s}). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.", .{id}));
    }
    const long_id = try a.alloc(u8, 256);
    @memset(long_id, 'b');
    long_id[0] = 'a';
    try testing.expectEqual(400, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{long_id}), "{}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{long_id[0..255]}), "{}")).status);
    // An id with the characters a path must encode reaches it decoded.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/a%b+c~d.e\"}", (try b.raw(a, .PUT, "projects/p/topics/a%25b%2Bc~d.e", "{}")).body);

    // Through the client: what it sends is what the fake keeps.
    var made = try b.client.topic("orders").create(.{
        .labels = &.{.{ .key = "env", .value = "test" }},
        .message_retention = .fromSeconds(3600),
        .kms_key_name = "projects/p/locations/l/keyRings/r/cryptoKeys/k",
        .message_storage_policy = .{ .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" }, .enforce_in_transit = true },
    });
    defer made.deinit();
    var read = try b.client.topic("orders").get();
    defer read.deinit();
    try testing.expectEqualStrings("test", read.value.label("env").?);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), read.value.message_retention.?);
    try testing.expectEqualStrings("projects/p/locations/l/keyRings/r/cryptoKeys/k", read.value.kms_key_name.?);
    try testing.expectEqual(2, read.value.message_storage_policy.?.allowed_persistence_regions.len);
    try testing.expect(read.value.message_storage_policy.?.enforce_in_transit);
    var changed = try b.client.topic("orders").update(.{ .labels = &.{}, .message_retention = .clear, .kms_key_name = .clear, .message_storage_policy = .clear });
    defer changed.deinit();
    try testing.expectEqual(0, changed.value.labels.len);
    try testing.expectEqual(null, changed.value.message_retention);
    try testing.expectEqual(null, changed.value.kms_key_name);
    try testing.expectEqual(null, changed.value.message_storage_policy);
    try testing.expectError(error.AlreadyExists, b.client.topic("orders").create(.{}));
    try testing.expectEqualStrings("Resource already exists in the project (resource=orders).", b.diag.message());
    try b.client.topic("orders").delete();
    try testing.expectError(error.NotFound, b.client.topic("orders").get());
    try testing.expectEqualStrings("Resource not found (resource=orders).", b.diag.message());
    // What is not modelled yet says so, and guesses nothing.
    try expectRefused(try b.raw(a, .POST, "projects/p/topics/zigps-b", "{}"), 501, "UNIMPLEMENTED", "fake: this call on a topic is not modelled yet");
}

test "lists: in name order, in pages, with tokens only this fake gave" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    // An empty project answers `{}`.
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/topics", "")).body);
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/subscriptions?pageSize=2", "")).body);
    for ([_][]const u8{ "delta", "alpha", "echo", "charlie", "bravo" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    // Another project's topics are no part of this one's list.
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/other/topics/aardvark", "{}")).status);

    var names: std.ArrayList([]const u8) = .empty;
    var token: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        var page = try b.client.listTopics(.{ .page_size = 2, .page_token = token });
        defer page.deinit();
        try testing.expect(page.value.topics.len <= 2);
        for (page.value.topics) |t| try names.append(a, try a.dupe(u8, t.name));
        token = try a.dupe(u8, page.value.next_page_token orelse break);
    }
    try testing.expectEqual(2, pages);
    try testing.expectEqual(5, names.items.len);
    for ([_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" }, names.items) |id, name| {
        try testing.expect(std.mem.endsWith(u8, name, id));
    }
    // No page size, or 0, is the default: all five.
    var all = try b.client.listTopics(.{});
    defer all.deinit();
    try testing.expectEqual(5, all.value.topics.len);
    try testing.expectEqual(null, all.value.next_page_token);

    try expectRefused(try b.raw(a, .GET, "projects/p/topics?pageSize=-1", ""), 400, "INVALID_ARGUMENT", "The value for page_size is out of bounds. You passed -1 in the request, but the value must be between 0 and 1000.");
    try expectRefused(try b.raw(a, .GET, "projects/p/topics?pageSize=1001", ""), 400, "INVALID_ARGUMENT", "The value for page_size is out of bounds. You passed 1001 in the request, but the value must be between 0 and 1000.");
    try expectRefused(try b.raw(a, .GET, "projects/p/topics?pageToken=not-a-token", ""), 400, "INVALID_ARGUMENT", "Invalid page token given (token=not-a-token).");
    try testing.expectEqual(200, (try b.raw(a, .GET, "projects/p/topics?pageSize=1000", "")).status);

    // Subscriptions, and the ones of a topic, by name.
    for ([_][]const u8{ "s-two", "s-one", "s-three" }) |id| {
        var made = try b.client.subscription(id).create(.{ .topic_id = if (std.mem.eql(u8, id, "s-two")) "bravo" else "alpha" });
        made.deinit();
    }
    var subs = try b.client.listSubscriptions(.{ .page_size = 2 });
    defer subs.deinit();
    try testing.expectEqual(2, subs.value.subscriptions.len);
    try testing.expectEqualStrings("projects/p/subscriptions/s-one", subs.value.subscriptions[0].name);
    try testing.expectEqualStrings("projects/p/subscriptions/s-three", subs.value.subscriptions[1].name);
    var rest = try b.client.listSubscriptions(.{ .page_size = 2, .page_token = subs.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqual(1, rest.value.subscriptions.len);
    try testing.expectEqual(null, rest.value.next_page_token);
    var attached = try b.client.topic("alpha").listSubscriptions(.{ .page_size = 1 });
    defer attached.deinit();
    try testing.expectEqualStrings("projects/p/subscriptions/s-one", attached.value.names[0]);
    var attached_rest = try b.client.topic("alpha").listSubscriptions(.{ .page_token = attached.value.next_page_token.? });
    defer attached_rest.deinit();
    try testing.expectEqual(1, attached_rest.value.names.len);
    try testing.expectEqualStrings("projects/p/subscriptions/s-three", attached_rest.value.names[0]);
    var nothing = try b.client.topic("echo").listSubscriptions(.{});
    defer nothing.deinit();
    try testing.expectEqual(0, nothing.value.names.len);
    try testing.expectError(error.NotFound, b.client.topic("missing").listSubscriptions(.{}));

    // With no page size, or 0, a page is a hundred: the fake's own number,
    // which production was not asked for. This client always says one.
    for (0..96) |i| {
        var made = try b.client.topic(try std.fmt.allocPrint(a, "t{d:0>3}", .{i})).create(.{});
        made.deinit();
    }
    for ([_][]const u8{ "projects/p/topics", "projects/p/topics?pageSize=0" }) |path| {
        const page = (try b.raw(a, .GET, path, "")).body;
        try testing.expectEqual(100, std.mem.count(u8, page, "\"name\""));
        try testing.expect(std.mem.indexOf(u8, page, "\"nextPageToken\"") != null);
    }
    try testing.expectEqual(101, std.mem.count(u8, (try b.raw(a, .GET, "projects/p/topics?pageSize=1000", "")).body, "\"name\""));
}

test "publish: ids in order, and every refusal in production's words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const path = "projects/p/topics/orders:publish";

    try testing.expectEqualStrings("{\"messageIds\":[\"1\"]}", (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"aGVsbG8=\",\"attributes\":{\"k\":\"v\"}}]}")).body);
    try testing.expectEqualStrings("{\"messageIds\":[\"2\",\"3\",\"4\"]}", (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"orderingKey\":\"k\"},{\"data\":\"Yg==\",\"orderingKey\":\"k\"},{\"data\":\"Yw==\",\"orderingKey\":\"k\"}]}")).body);
    // Attributes alone are a message; an id and a time given are ignored.
    try testing.expectEqual(200, (try b.raw(a, .POST, path, "{\"messages\":[{\"attributes\":{\"k\":\"v\"}}]}")).status);
    try testing.expectEqualStrings("{\"messageIds\":[\"6\"]}", (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"messageId\":\"7\",\"publishTime\":\"2020-01-01T00:00:00Z\"}]}")).body);
    try testing.expectEqual(6, b.fake.publishedCount("p", "orders"));

    try expectRefused(try b.raw(a, .POST, "projects/p/topics/nope:publish", "{\"messages\":[{\"data\":\"eA==\"}]}"), 404, "NOT_FOUND", "Resource not found (resource=nope).");
    for ([_][]const u8{ "{\"messages\":[]}", "{}" }) |body| {
        try expectRefused(try b.raw(a, .POST, path, body), 400, "INVALID_ARGUMENT", "The value for message_count is too small. You passed 0 in the request, but the minimum value is 1.");
    }
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{}]}"), 400, "INVALID_ARGUMENT", "One or more messages in the publish request is empty. Each message must contain either non-empty data, or at least one attribute.");
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"!!!\"}]}"), 400, "INVALID_ARGUMENT", "Invalid value at 'messages[0].data' (TYPE_BYTES), Base64 decoding failed for \"!!!\"");
    for ([_][]const u8{
        "{\"messages\":[{\"data\":\"YQ==\",\"orderingKey\":\"k1\"},{\"data\":\"Yg==\",\"orderingKey\":\"k2\"}]}",
        "{\"messages\":[{\"data\":\"YQ==\",\"orderingKey\":\"k1\"},{\"data\":\"Yg==\"}]}",
    }) |body| {
        try expectRefused(try b.raw(a, .POST, path, body), 400, "FAILED_PRECONDITION", "In a single publish request, all messages must have no ordering key or they must all have the same ordering key. [code=539b]");
    }
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"\":\"v\"}}]}"), 400, "INVALID_ARGUMENT", "The request contains an attribute key that is not valid (key=). Attribute keys must be non-empty and must not begin with 'goog' (case-insensitive).");
    try expectRefused(try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"GooGx\":\"v\"}}]}"), 400, "INVALID_ARGUMENT", "The request contains an attribute key that is not valid (key=GooGx). Attribute keys must be non-empty and must not begin with 'goog' (case-insensitive).");
    // The three keys a schema topic writes are taken from any publisher.
    try testing.expectEqual(200, (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"googclient_schemaname\":\"x\"}}]}")).status);
    const long_value = try a.alloc(u8, 1025);
    @memset(long_value, 'v');
    try expectRefused(try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"k\":\"{s}\"}}}}]}}", .{long_value})), 400, "INVALID_ARGUMENT", "The attribute \"k\" in the request has a value that is too large. The size is 1025 bytes, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.");
    try testing.expectEqual(200, (try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"k\":\"{s}\"}}}}]}}", .{long_value[0..1024]}))).status);
    try testing.expectEqual(400, (try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"{s}\":\"v\"}}}}]}}", .{long_value[0..257]}))).status);
    try testing.expectEqual(200, (try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"attributes\":{{\"{s}\":\"v\"}}}}]}}", .{long_value[0..256]}))).status);
    try expectRefused(try b.raw(a, .POST, path, try std.fmt.allocPrint(a, "{{\"messages\":[{{\"data\":\"YQ==\",\"orderingKey\":\"{s}\"}}]}}", .{long_value})), 400, "INVALID_ARGUMENT", "An ordering key in the request is too long. The length is 1025 characters, but the maximum allowed is 1024. Refer to https://cloud.google.com/pubsub/quotas for more information.");
    var attrs: std.Io.Writer.Allocating = .init(a);
    try attrs.writer.writeAll("{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{");
    for (0..101) |i| try attrs.writer.print("{s}\"k{d}\":\"v\"", .{ if (i == 0) "" else ",", i });
    try attrs.writer.writeAll("}}]}");
    try expectRefused(try b.raw(a, .POST, path, attrs.written()), 400, "INVALID_ARGUMENT", "There are too many attributes in the request. The request contains 101 attributes, but the maximum allowed is 100. Refer to https://cloud.google.com/pubsub/quotas for more information.");
    var bulk: std.Io.Writer.Allocating = .init(a);
    try bulk.writer.writeAll("{\"messages\":[");
    for (0..1001) |i| try bulk.writer.print("{s}{{\"data\":\"YQ==\"}}", .{if (i == 0) "" else ","});
    try bulk.writer.writeAll("]}");
    try expectRefused(try b.raw(a, .POST, path, bulk.written()), 400, "INVALID_ARGUMENT", "The value for message_count is too large. You passed 1001 in the request, but the maximum value is 1000.");
    // A refused request stores nothing, whichever message was at fault.
    const before = b.fake.publishedCount("p", "orders");
    try testing.expectEqual(400, (try b.raw(a, .POST, path, "{\"messages\":[{\"data\":\"YQ==\"},{}]}")).status);
    try testing.expectEqual(before, b.fake.publishedCount("p", "orders"));
    // The request's own limit, on the body as it arrives.
    const big = try a.alloc(u8, max_publish_bytes + 1);
    @memset(big, ' ');
    try expectRefused(try b.raw(a, .POST, path, big), 400, "INVALID_ARGUMENT", "Request payload size exceeds the limit: 10485760 bytes.");
}

test "subscriptions: production's defaults, its bounds, what an update may change, and a topic deleted under one" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_][]const u8{ "zigps-a", "zigps-b" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const topic = "\"topic\":\"projects/p/topics/zigps-a\"";

    // Production's answers, 2026-10-12, with its defaults filled in.
    const fresh =
        \\{"name":"projects/p/subscriptions/zigps-s","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    ;
    try testing.expectEqualStrings(fresh, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-s", "{" ++ topic ++ "}")).body);
    try testing.expectEqualStrings(fresh, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-s", "")).body);
    for ([_][]const u8{ "zigps-a", "zigps-b" }) |other| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-s", try std.fmt.allocPrint(a, "{{\"topic\":\"projects/p/topics/{s}\"}}", .{other})), 409, "ALREADY_EXISTS", "Resource already exists in the project (resource=zigps-s).");
    }
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-x1", "{\"topic\":\"projects/p/topics/zigps-nope\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-x2", "{}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-x3", "{\"topic\":\"orders\"}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=orders). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    for ([_]tp.Method{ .GET, .DELETE }) |method| {
        try expectRefused(try b.raw(a, method, "projects/p/subscriptions/zigps-nope", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    }
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"expirationPolicy":{"ttl":"86400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-full", "{" ++ topic ++ ",\"ackDeadlineSeconds\":60,\"messageRetentionDuration\":\"1200s\",\"retainAckedMessages\":true,\"expirationPolicy\":{\"ttl\":\"86400s\"},\"labels\":{\"env\":\"test\"}}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-never","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-never", "{" ++ topic ++ ",\"expirationPolicy\":{}}")).body);

    // Bounds, each in production's words.
    for ([_]struct { []const u8, []const u8 }{
        .{ "\"ackDeadlineSeconds\":9", "Invalid ack deadline given (ack_deadline=9). The ack deadline must be between 10 and 600 seconds." },
        .{ "\"ackDeadlineSeconds\":601", "Invalid ack deadline given (ack_deadline=601). The ack deadline must be between 10 and 600 seconds." },
        .{ "\"messageRetentionDuration\":\"540s\"", "The value for message retention duration is out of bounds. You passed 9m in the request, but the value must be between 10m and 744h." },
        .{ "\"messageRetentionDuration\":\"2764800s\"", "The value for message retention duration is out of bounds. You passed 768h in the request, but the value must be between 10m and 744h." },
        .{ "\"expirationPolicy\":{\"ttl\":\"3600s\"}", "The value for expiration duration is too small. You passed 1h in the request, but the minimum value is 24h." },
        .{ "\"messageRetentionDuration\":\"172800s\",\"expirationPolicy\":{\"ttl\":\"86400s\"}", "The subscription's message retention duration (172800 seconds) cannot be greater than the TTL in the subscription's expiration policy (86400 seconds), since messages cannot be retained past subscription expiration." },
    }) |case| {
        const setting, const words = case;
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{setting})), 400, "INVALID_ARGUMENT", words);
    }
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);
    // A deadline of 0 is one not said, and exactly 10 and 600 are taken.
    for ([_]u32{ 0, 10, 600 }, 0..) |seconds, i| {
        const reply = try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/zigps-d{d}", .{i}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"ackDeadlineSeconds\":{d}}}", .{seconds}));
        try testing.expectEqual(200, reply.status);
        try testing.expect(std.mem.indexOf(u8, reply.body, try std.fmt.allocPrint(a, "\"ackDeadlineSeconds\":{d},", .{if (seconds == 0) 10 else seconds})) != null);
    }

    // Updates. After any, production writes `pushConfig` another way.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-s","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":30,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-s", "{\"subscription\":{\"ackDeadlineSeconds\":30},\"updateMask\":\"ackDeadlineSeconds\"}")).body);
    for ([_]struct { []const u8, []const u8 }{
        .{ "{\"subscription\":{\"filter\":\"attributes.k = \\\"v\\\"\"},\"updateMask\":\"filter\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: the 'filter' field in the Subscription is not mutable." },
        .{ "{\"subscription\":{\"topic\":\"projects/p/topics/zigps-b\"},\"updateMask\":\"topic\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: the 'topic' field in the Subscription is not mutable." },
        .{ "{\"subscription\":{\"enableMessageOrdering\":true},\"updateMask\":\"enableMessageOrdering\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: the 'enable_message_ordering' field in the Subscription is not mutable." },
        .{ "{\"subscription\":{\"ackDeadlineSeconds\":30}}", "The update_mask in the UpdateSubscriptionRequest must be set, and must contain a non-empty paths list." },
        .{ "{\"subscription\":{},\"updateMask\":\"nonsense\"}", "Invalid update_mask provided in the UpdateSubscriptionRequest: 'nonsense' is not a known Subscription field. Note that field paths must be of the form 'push_config' rather than 'pushConfig'." },
    }) |case| {
        const body, const words = case;
        try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-s", body), 400, "INVALID_ARGUMENT", words);
    }
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-nope", "{\"subscription\":{\"ackDeadlineSeconds\":30},\"updateMask\":\"ackDeadlineSeconds\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    // A path the body leaves out goes back to production's default.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"expirationPolicy\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"messageRetentionDuration,retain_acked_messages,labels\"}")).body);
    // A refused update changes nothing.
    try testing.expectEqual(400, (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"ackDeadlineSeconds\":30,\"messageRetentionDuration\":\"1s\"},\"updateMask\":\"ackDeadlineSeconds,messageRetentionDuration\"}")).status);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-full", "")).body, "\"ackDeadlineSeconds\":60,") != null);

    // Through the client.
    var made = try b.client.subscription("worker").create(.{
        .topic_id = "zigps-b",
        .ack_deadline_seconds = 45,
        .message_retention = .fromSeconds(3600),
        .retain_acked_messages = true,
        .expiration = .never,
        .labels = &.{.{ .key = "env", .value = "test" }},
    });
    defer made.deinit();
    try testing.expectEqual(45, made.value.ack_deadline_seconds);
    try testing.expectEqual(types.Expiration.never, made.value.expiration);
    try testing.expect(made.value.retain_acked_messages);
    try testing.expectEqualStrings("test", made.value.label("env").?);
    var changed = try b.client.subscription("worker").update(.{ .ack_deadline_seconds = 20, .expiration = .{ .after = .fromSeconds(172_800) }, .labels = &.{} });
    defer changed.deinit();
    try testing.expectEqual(20, changed.value.ack_deadline_seconds);
    try testing.expectEqual(std.Io.Duration.fromSeconds(172_800), changed.value.expiration.after);
    try testing.expectEqual(0, changed.value.labels.len);
    try testing.expectEqual(types.DeliveryInfo.pull, changed.value.delivery);
    // What is not modelled yet says so.
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/tabled", "{\"topic\":\"projects/p/topics/zigps-b\",\"bigtableConfig\":{\"table\":\"projects/p/instances/i/tables/t\"}}"), 501, "UNIMPLEMENTED", "fake: a Bigtable subscription is not modelled yet");

    // A topic deleted under its subscription leaves it, and what it holds.
    var sent = try b.client.topic("zigps-b").publish(&.{.{ .data = "kept" }}, .{});
    sent.deinit();
    try b.client.topic("zigps-b").delete();
    var orphan = try b.client.subscription("worker").get();
    defer orphan.deinit();
    try testing.expectEqualStrings("_deleted-topic_", orphan.value.topic);
    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqualStrings("kept", got.value.messages[0].data);
    // A topic made again under the name is another topic: nothing reaches
    // the old subscription.
    var again = try b.client.topic("zigps-b").create(.{});
    again.deinit();
    var later = try b.client.topic("zigps-b").publish(&.{.{ .data = "new" }}, .{});
    later.deinit();
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    try b.client.subscription("worker").delete();
    try testing.expectError(error.NotFound, b.client.subscription("worker").pull(.{}));
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
}

test "leases: a message out on one comes again when it lapses, and an ack takes only while it is out" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    var early = try b.client.topic("orders").publish(&.{.{ .data = "early" }}, .{});
    early.deinit();
    const worker = b.client.subscription("worker");
    var subscribed = try worker.create(.{ .topic_id = "orders" });
    subscribed.deinit();
    // A subscription gets what is published after it is made.
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();

    var first = try worker.pull(.{});
    defer first.deinit();
    const old = first.value.messages[0].ack_id;
    // Out on a lease: a second pull has nothing.
    var none = try worker.pull(.{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
    b.advance(9);
    var still_none = try worker.pull(.{});
    defer still_none.deinit();
    try testing.expectEqual(0, still_none.value.messages.len);
    try testing.expectEqual(1, b.fake.outstanding("p", "worker"));

    // The lease lapses at 10 seconds. An ack with the old id is then
    // answered and forgotten, as production's was: the message comes again.
    b.advance(1);
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    try worker.ack(&.{old});
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    var second = try worker.pull(.{});
    defer second.deinit();
    try testing.expectEqualStrings("m", second.value.messages[0].data);
    try testing.expect(!std.mem.eql(u8, old, second.value.messages[0].ack_id));
    // Out again, the old id does acknowledge it: the id names the message,
    // and the lease decides.
    try worker.ack(&.{old});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    // A second ack of it, and a lease change on it, are taken and forgotten.
    try worker.ack(&.{ old, second.value.messages[0].ack_id });
    try worker.modifyAckDeadline(&.{old}, 30);

    // An extension moves the deadline from now.
    var more = try b.client.topic("orders").publish(&.{.{ .data = "n" }}, .{});
    more.deinit();
    var third = try worker.pull(.{});
    defer third.deinit();
    b.advance(8);
    try worker.modifyAckDeadline(&.{third.value.messages[0].ack_id}, 30);
    b.advance(29);
    try testing.expectEqual(1, b.fake.outstanding("p", "worker"));
    b.advance(1);
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));

    // A nack gives it back at once, and an ack after the nack is forgotten.
    var fourth = try worker.pull(.{});
    defer fourth.deinit();
    try worker.nack(&.{fourth.value.messages[0].ack_id});
    try worker.ack(&.{fourth.value.messages[0].ack_id});
    var fifth = try worker.pull(.{});
    defer fifth.deinit();
    try testing.expectEqualStrings("n", fifth.value.messages[0].data);
    try worker.ack(&.{fifth.value.messages[0].ack_id});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
}

test "ack ids and pulls: what production refuses, in its words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    for ([_][]const u8{ "sub-a", "sub-b" }) |id| {
        var s = try b.client.subscription(id).create(.{ .topic_id = "orders" });
        s.deinit();
    }
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "x", .attributes = &.{.{ .key = "k", .value = "v" }} }}, .{ .ordering_key = "o" });
    sent.deinit();
    const ack_a = "projects/p/subscriptions/sub-a:acknowledge";
    const mod_a = "projects/p/subscriptions/sub-a:modifyAckDeadline";

    // A pulled message, as production writes one.
    const pulled = (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:pull", "{\"maxMessages\":5,\"returnImmediately\":true}")).body;
    const Wire = struct { receivedMessages: []const struct { ackId: []const u8, message: struct { data: []const u8, attributes: struct { k: []const u8 }, messageId: []const u8, publishTime: []const u8, orderingKey: []const u8 } } };
    const message = try std.json.parseFromSliceLeaky(Wire, a, pulled, .{});
    try testing.expectEqualStrings("eA==", message.receivedMessages[0].message.data);
    try testing.expectEqualStrings("v", message.receivedMessages[0].message.attributes.k);
    try testing.expectEqualStrings("1", message.receivedMessages[0].message.messageId);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", message.receivedMessages[0].message.publishTime);
    try testing.expectEqualStrings("o", message.receivedMessages[0].message.orderingKey);
    const from_b = message.receivedMessages[0].ackId;
    // Nothing to give answers `{}`.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:pull", "{\"maxMessages\":5}")).body);

    try expectRefused(try b.raw(a, .POST, ack_a, "{\"ackIds\":[\"not-an-ack-id\"]}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=not-an-ack-id).");
    try expectRefused(try b.raw(a, .POST, mod_a, "{\"ackIds\":[\"not-an-ack-id\"],\"ackDeadlineSeconds\":30}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=not-an-ack-id).");
    try expectRefused(try b.raw(a, .POST, mod_a, "{\"ackIds\":[\"x\"]}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=x).");
    for ([_][]const u8{ "{\"ackIds\":[]}", "{}" }) |body| {
        try expectRefused(try b.raw(a, .POST, ack_a, body), 400, "INVALID_ARGUMENT", "You have not specified an ack ID in the request.");
    }
    // An id another subscription gave is refused, and that message stays
    // with the other subscription.
    try expectRefused(try b.raw(a, .POST, ack_a, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{from_b})), 400, "INVALID_ARGUMENT", "You have passed a subscription that does not belong to the given ack ID (resource=projects/p/subscriptions/sub-a).");
    try testing.expectEqual(1, b.fake.backlog("p", "sub-b"));
    for ([_]i32{ 601, -1 }) |seconds| {
        try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/sub-b:modifyAckDeadline", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"],\"ackDeadlineSeconds\":{d}}}", .{ from_b, seconds })), 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(a, "Invalid ack deadline given (ack_deadline={d}). The ack deadline must be between 0 and 600 seconds.", .{seconds}));
    }
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:modifyAckDeadline", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"],\"ackDeadlineSeconds\":600}}", .{from_b}))).body);
    // One bad id refuses the request whole: the good one is not taken.
    try testing.expectEqual(400, (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:acknowledge", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"nope\"]}}", .{from_b}))).status);
    try testing.expectEqual(1, b.fake.backlog("p", "sub-b"));
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/sub-b:acknowledge", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{from_b}))).body);
    try testing.expectEqual(0, b.fake.backlog("p", "sub-b"));

    for ([_][]const u8{ "{\"maxMessages\":0,\"returnImmediately\":true}", "{\"returnImmediately\":true}", "{\"maxMessages\":-1}" }) |body| {
        try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/sub-a:pull", body), 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=max_messages).");
    }
    // 1001 is taken, as production takes it, and gives a thousand at most.
    var bulk: std.Io.Writer.Allocating = .init(a);
    try bulk.writer.writeAll("{\"messages\":[");
    for (0..1000) |i| try bulk.writer.print("{s}{{\"data\":\"YQ==\"}}", .{if (i == 0) "" else ","});
    try bulk.writer.writeAll("]}");
    for (0..2) |_| try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/orders:publish", bulk.written())).status);
    const thousand = try b.raw(a, .POST, "projects/p/subscriptions/sub-a:pull", "{\"maxMessages\":1001}");
    try testing.expectEqual(200, thousand.status);
    try testing.expectEqual(1000, std.mem.count(u8, thousand.body, "\"ackId\""));
    try testing.expectEqual(1000, b.fake.outstanding("p", "sub-a"));
    try testing.expectEqual(2001, b.fake.backlog("p", "sub-a"));
    for ([_][]const u8{ ":pull", ":acknowledge", ":modifyAckDeadline" }) |call| {
        try expectRefused(try b.raw(a, .POST, try std.fmt.allocPrint(a, "projects/p/subscriptions/nope{s}", .{call}), "{\"maxMessages\":1,\"ackIds\":[\"x\"]}"), 404, "NOT_FOUND", "Resource not found (resource=nope).");
    }
    // An id from a subscription deleted and made again under the name is
    // not that subscription's.
    var more = try b.client.topic("orders").publish(&.{.{ .data = "y" }}, .{});
    more.deinit();
    var got = try b.client.subscription("sub-b").pull(.{});
    defer got.deinit();
    try b.client.subscription("sub-b").delete();
    var remade = try b.client.subscription("sub-b").create(.{ .topic_id = "orders" });
    remade.deinit();
    try testing.expectError(error.InvalidArgument, b.client.subscription("sub-b").ack(&.{got.value.messages[0].ack_id}));
    // Routes this fake has not got.
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/sub-a:streamingPull", "{}"), 501, "UNIMPLEMENTED", "fake: :streamingPull is not modelled yet");
    try testing.expectEqual(501, (try b.raw(a, .POST, "projects/p/snapshots/snap", "{}")).status);
    // A call of IAM's by the wrong method is no call of IAM's.
    try testing.expectEqual(501, (try b.raw(a, .POST, "projects/p/subscriptions/sub-a:getIamPolicy", "{}")).status);
    try expectRefused(try b.raw(a, .GET, "projects/p/subscriptions/sub-a:setIamPolicy", ""), 501, "UNIMPLEMENTED", "fake: :setIamPolicy is not modelled yet");
    try testing.expectEqual(501, (try b.raw(a, .GET, "projects/p/subscriptions/sub-a:testIamPermissions", "")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/buckets", "")).status);
}

test "order: none without an ordering key, so a pull's is the fake's own unless asked for the published one" {
    for ([_]bool{ true, false }) |shuffle| {
        var b: Bench = undefined;
        try b.init(.{ .shuffle = shuffle });
        defer b.deinit();
        var made = try b.client.topic("orders").create(.{});
        made.deinit();
        var subscribed = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
        subscribed.deinit();
        for (0..12) |i| {
            var buf: [2]u8 = undefined;
            var sent = try b.client.topic("orders").publish(&.{.{ .data = try std.fmt.bufPrint(&buf, "{d:0>2}", .{i}) }}, .{});
            sent.deinit();
        }
        var seen: [12]bool = @splat(false);
        var in_order = true;
        var last: i32 = -1;
        var pulls: usize = 0;
        while (b.fake.backlog("p", "worker") > 0) : (pulls += 1) {
            // An ack that did not take would have this go round for ever.
            try testing.expect(pulls < 3);
            var got = try b.client.subscription("worker").pull(.{ .max_messages = 5 });
            defer got.deinit();
            try testing.expect(got.value.messages.len <= 5);
            for (got.value.messages) |m| {
                const n = try std.fmt.parseInt(u8, m.data, 10);
                try testing.expect(!seen[n]);
                seen[n] = true;
                if (n < last) in_order = false;
                last = n;
                try b.client.subscription("worker").ack(&.{m.ack_id});
            }
        }
        try testing.expectEqual(3, pulls);
        for (seen) |s| try testing.expect(s);
        try testing.expectEqual(!shuffle, in_order);
    }
}

test "faults: a refusal changes nothing, a lost answer lands, a drop is a broken connection, each on the calls asked for" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    // One attempt a call, so that each fault is seen as it is.
    b.client.retry.max_attempts = 1;
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    var subscribed = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
    subscribed.deinit();

    b.fake.refuseNext(2, 503, .publish);
    try testing.expectError(error.Unavailable, b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{}));
    // Another kind of call is not the fault's to answer.
    var read = try b.client.topic("orders").get();
    read.deinit();
    try testing.expectError(error.Unavailable, b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{}));
    try testing.expectEqual(0, b.fake.publishedCount("p", "orders"));
    var taken = try b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{});
    taken.deinit();
    try testing.expectEqual(1, b.fake.publishedCount("p", "orders"));

    // A lost answer: the publish landed, and the caller was told 503.
    b.fake.loseAnswers(1, .publish);
    try testing.expectError(error.Unavailable, b.client.topic("orders").publish(&.{.{ .data = "b" }}, .{}));
    try testing.expectEqual(2, b.fake.publishedCount("p", "orders"));
    try testing.expectEqual(2, b.fake.backlog("p", "worker"));

    b.fake.dropNext(1, .pull);
    try testing.expectError(error.ConnectionResetByPeer, b.client.subscription("worker").pull(.{}));
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqual(2, got.value.messages.len);

    // A lost ack still acknowledged; a refused one did not.
    b.fake.loseAnswers(1, .acknowledge);
    try testing.expectError(error.Unavailable, b.client.subscription("worker").ack(&.{got.value.messages[0].ack_id}));
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    b.fake.refuseNext(1, 429, .acknowledge);
    try testing.expectError(error.ResourceExhausted, b.client.subscription("worker").ack(&.{got.value.messages[1].ack_id}));
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    b.fake.refuseNext(1, 500, .modify_ack_deadline);
    try testing.expectError(error.Internal, b.client.subscription("worker").nack(&.{got.value.messages[1].ack_id}));
    b.fake.refuseNext(1, 503, .all);
    try testing.expectError(error.Unavailable, b.client.subscription("worker").get());
    b.fake.refuseNext(1, 403, .admin);
    try testing.expectError(error.PermissionDenied, b.client.subscription("worker").delete());
    var still = try b.client.subscription("worker").get();
    still.deinit();

    // With the client's retries on, a fault or two is ridden out.
    b.client.retry.max_attempts = 3;
    b.fake.refuseNext(2, 503, .acknowledge);
    try b.client.subscription("worker").ack(&.{got.value.messages[1].ack_id});
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));

    try testing.expectEqual(4, b.fake.requestCount(.publish));
    try testing.expectEqual(2, b.fake.requestCount(.pull));
    try testing.expectEqual(5, b.fake.requestCount(.acknowledge));
    try testing.expectEqual(1, b.fake.requestCount(.modify_ack_deadline));
    try testing.expectEqual(6, b.fake.requestCount(.admin));
    try testing.expectEqual(18, b.fake.requestCount(.all));
}

test "faults: a refusal can ask for a delay in each form, and the client waits it or stops" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    for ([_]core.retry_after.Asked.Form{ .retry_after, .retry_after_ms, .retry_info, .all }) |form| {
        const before = b.clock.sleep_count;
        b.fake.refuseNextWithDelay(1, 503, .all, .{ .ms = 1_500, .form = form });
        var read = try b.client.topic("orders").get();
        read.deinit();
        // `Retry-After` is whole seconds, so 1.5 s is sent as 2.
        try testing.expectEqual(before + 1, b.clock.sleep_count);
        try testing.expectEqual(@as(i64, if (form == .retry_after or form == .all) 2_000 else 1_500), b.clock.sleepMs(before));
    }
    // Past the client's cap: one attempt, and the delay kept for the app's
    // own schedule.
    const before = b.clock.sleep_count;
    b.fake.refuseNextWithDelay(1, 503, .all, .{ .ms = 60_000 });
    try testing.expectError(error.Unavailable, b.client.topic("orders").get());
    try testing.expectEqual(before, b.clock.sleep_count);
    try testing.expectEqual(60_000, b.diag.retry_after_ms.?);
}

test "a pull with nothing to give is held as long as asked, on the fake's clock" {
    var b: Bench = undefined;
    try b.init(.{ .empty_pull_hold = .fromSeconds(20) });
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    var subscribed = try b.client.subscription("worker").create(.{ .topic_id = "orders" });
    subscribed.deinit();
    const before = b.clock.now_ns;
    var none = try b.client.subscription("worker").pull(.{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
    try testing.expectEqual(20 * std.time.ns_per_s, b.clock.now_ns - before);
    // With a message waiting it answers at once.
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();
    const then = b.clock.now_ns;
    var got = try b.client.subscription("worker").pull(.{});
    defer got.deinit();
    try testing.expectEqual(1, got.value.messages.len);
    try testing.expectEqual(then, b.clock.now_ns);
    // A held pull gives a lapsed message when its lease runs out.
    var again = try b.client.subscription("worker").pull(.{});
    defer again.deinit();
    try testing.expectEqual(1, again.value.messages.len);
    try testing.expectEqual(10 * std.time.ns_per_s, b.clock.now_ns - then);
    // A canceled wait is a canceled call.
    b.clock.cancel_sleep = true;
    try testing.expectError(error.Canceled, b.client.subscription("worker").pull(.{}));
}

/// Pulls with nothing to give, and says so.
fn expectNothing(sub: anytype) !void {
    var got = try sub.pull(.{ .return_immediately = true });
    defer got.deinit();
    try testing.expectEqual(0, got.value.messages.len);
}

test "a subscription's rules: read back as production reads them back, and refused in its words" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_][]const u8{ "zigps-a", "zigps-b" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const topic = "\"topic\":\"projects/p/topics/zigps-a\"";
    const dead = "\"deadLetterTopic\":\"projects/p/topics/zigps-b\"";

    // Production's answers, 2026-10-12, in the order it writes the fields.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"86400s"},"filter":"attributes.k = \"v\"","deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/zigps-b","maxDeliveryAttempts":7},"retryPolicy":{"minimumBackoff":"5s","maximumBackoff":"60s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-full", "{" ++ topic ++ ",\"ackDeadlineSeconds\":60,\"enableMessageOrdering\":true,\"filter\":\"attributes.k = \\\"v\\\"\",\"retryPolicy\":{\"minimumBackoff\":\"5s\",\"maximumBackoff\":\"60s\"},\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":7},\"retainAckedMessages\":true,\"messageRetentionDuration\":\"1200s\",\"labels\":{\"env\":\"test\"},\"expirationPolicy\":{\"ttl\":\"86400s\"}}")).body);
    // With exactly-once delivery its own deadline is a minute.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-eo","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"enableExactlyOnceDelivery":true,"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-eo", "{" ++ topic ++ ",\"enableExactlyOnceDelivery\":true}")).body);
    // Five attempts when none is said.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-dl","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/zigps-b","maxDeliveryAttempts":5},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-dl", "{" ++ topic ++ ",\"deadLetterPolicy\":{" ++ dead ++ "}}")).body);
    // Dead letters to its own topic are taken.
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-own", "{" ++ topic ++ ",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-a\"}}")).status);
    // A retry policy with nothing in it is 10 seconds to 600.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-rp","topic":"projects/p/topics/zigps-a","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"retryPolicy":{"minimumBackoff":"10s","maximumBackoff":"600s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-rp", "{" ++ topic ++ ",\"retryPolicy\":{}}")).body);

    // Its refusals, each in its words.
    for ([_]struct { []const u8, []const u8 }{
        .{ "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":4}", "The value for max_delivery_attempts is too small. You passed 4 in the request, but the minimum value is 5." },
        .{ "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":101}", "The value for max_delivery_attempts is too large. You passed 101 in the request, but the maximum value is 100." },
        .{ "\"retryPolicy\":{\"minimumBackoff\":\"30s\",\"maximumBackoff\":\"10s\"}", "The specified maximum_backoff 10s cannot be smaller than minimum_backoff 30s." },
        .{ "\"retryPolicy\":{\"minimumBackoff\":\"1s\",\"maximumBackoff\":\"601s\"}", "The value for maximum_backoff is out of bounds. You passed 10m1s in the request, but the value must be between 0 and 10m." },
        .{ "\"filter\":\"attributes.k = \\\"" ++ comptime xs(240) ++ "\\\"\"", "Invalid filter expression: length 257 exceeds maximum allowed length of 256." },
        .{ "\"filter\":\"attributes.kind > \\\"a\\\"\"", "Invalid filter expression: Invalid operator (line 1, columns 1 to 21)." },
    }) |case| {
        const setting, const words = case;
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{setting})), 400, "INVALID_ARGUMENT", words);
    }
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-nope\"}}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    // The fake's own words where production was not asked: a minimum out
    // of bounds, after production's for the maximum.
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"retryPolicy\":{\"minimumBackoff\":\"601s\",\"maximumBackoff\":\"600s\"}}"), 400, "INVALID_ARGUMENT", "The value for minimum_backoff is out of bounds. You passed 10m1s in the request, but the value must be between 0 and 10m.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"filter\":\"attributes.kind\"}"), 400, "INVALID_ARGUMENT", "Invalid filter expression: Expected either a function call or an expression with an operator (line 1, columns 1 to 15).");
    // A filter of a shape production was not shown, or one it failed on
    // itself, is not guessed at.
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"filter\":\"--attributes:kind\"}"), 501, "UNIMPLEMENTED", "fake: this filter is not modelled: a minus after a minus, which production answers with an internal error, at column 2");
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);
    // The bounds themselves are taken: 5 and 100 attempts, 0 and 600 seconds.
    for ([_][]const u8{ "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":5}", "\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":100}", "\"retryPolicy\":{\"minimumBackoff\":\"0s\",\"maximumBackoff\":\"0s\"}", "\"retryPolicy\":{\"minimumBackoff\":\"600s\",\"maximumBackoff\":\"600s\"}" }, 0..) |setting, i| {
        try testing.expectEqual(200, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/zigps-edge{d}", .{i}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{setting}))).status);
    }

    // Updates, as production answered them: a path the body leaves out
    // goes back to its default, and a policy that way is gone.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"1200s","labels":{"env":"test"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"2678400s"},"filter":"attributes.k = \"v\"","deadLetterPolicy":{"deadLetterTopic":"projects/p/topics/zigps-b","maxDeliveryAttempts":7},"retryPolicy":{"minimumBackoff":"5s","maximumBackoff":"60s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"expirationPolicy\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-full","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"retainAckedMessages":true,"messageRetentionDuration":"604800s","labels":{"env":"test"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"2678400s"},"filter":"attributes.k = \"v\"","state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{},\"updateMask\":\"messageRetentionDuration,retryPolicy,deadLetterPolicy\"}")).body);
    // Set by an update, each is checked as on a create, and a refused
    // update changes nothing.
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":6},\"retryPolicy\":{\"maximumBackoff\":\"30s\"}},\"updateMask\":\"deadLetterPolicy,retryPolicy\"}")).status);
    const policies = "\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-b\",\"maxDeliveryAttempts\":6},\"retryPolicy\":{\"minimumBackoff\":\"10s\",\"maximumBackoff\":\"30s\"},\"state\"";
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-full", "")).body, policies) != null);
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-nope\"}},\"updateMask\":\"deadLetterPolicy\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"deadLetterPolicy\":{" ++ dead ++ ",\"maxDeliveryAttempts\":4}},\"updateMask\":\"deadLetterPolicy\"}"), 400, "INVALID_ARGUMENT", "The value for max_delivery_attempts is too small. You passed 4 in the request, but the minimum value is 5.");
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-full", "{\"subscription\":{\"ackDeadlineSeconds\":30,\"retryPolicy\":{\"minimumBackoff\":\"30s\",\"maximumBackoff\":\"10s\"}},\"updateMask\":\"ackDeadlineSeconds,retryPolicy\"}"), 400, "INVALID_ARGUMENT", "The specified maximum_backoff 10s cannot be smaller than minimum_backoff 30s.");
    const kept = (try b.raw(a, .GET, "projects/p/subscriptions/zigps-full", "")).body;
    try testing.expect(std.mem.indexOf(u8, kept, policies) != null);
    try testing.expect(std.mem.indexOf(u8, kept, "\"ackDeadlineSeconds\":60,") != null);
    // Exactly-once delivery is turned on and off by an update, and the
    // deadline stays what it was.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-eo","topic":"projects/p/topics/zigps-a","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-eo", "{\"subscription\":{},\"updateMask\":\"enableExactlyOnceDelivery\"}")).body);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-dl", "{\"subscription\":{\"enableExactlyOnceDelivery\":true},\"updateMask\":\"enable_exactly_once_delivery\"}")).body, "\"ackDeadlineSeconds\":10,\"messageRetentionDuration\":\"604800s\",\"expirationPolicy\":{\"ttl\":\"2678400s\"},\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/zigps-b\",\"maxDeliveryAttempts\":5},\"enableExactlyOnceDelivery\":true,\"state\"") != null);
    // A deadline that is said is kept with exactly-once delivery too.
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-eo10", "{" ++ topic ++ ",\"ackDeadlineSeconds\":10,\"enableExactlyOnceDelivery\":true}")).body, "\"ackDeadlineSeconds\":10,") != null);

    // Through the client.
    var made = try b.client.subscription("worker").create(.{
        .topic_id = "zigps-a",
        .enable_message_ordering = true,
        .enable_exactly_once_delivery = true,
        .filter = "attributes:k",
        .dead_letter_policy = .{ .topic = "zigps-b", .max_delivery_attempts = 9 },
        .retry_policy = .{ .minimum = .fromSeconds(1), .maximum = .fromSeconds(2) },
    });
    defer made.deinit();
    try testing.expect(made.value.enable_message_ordering);
    try testing.expect(made.value.enable_exactly_once_delivery);
    try testing.expectEqualStrings("attributes:k", made.value.filter);
    try testing.expectEqualStrings("projects/p/topics/zigps-b", made.value.dead_letter_policy.?.topic);
    try testing.expectEqual(9, made.value.dead_letter_policy.?.max_delivery_attempts);
    try testing.expectEqual(std.Io.Duration.fromSeconds(1), made.value.retry_policy.?.minimum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(2), made.value.retry_policy.?.maximum);
    try testing.expectEqual(60, made.value.ack_deadline_seconds);
    try testing.expectError(error.InvalidArgument, b.client.subscription("mixed").create(.{ .topic_id = "zigps-a", .filter = "attributes:a AND attributes:b OR attributes:c" }));
    try testing.expectEqualStrings("Invalid filter expression: failed to parse (syntax error at line 1, column 31, token 'OR').", b.diag.message());
    try testing.expectError(error.InvalidArgument, b.client.subscription("bare").create(.{ .topic_id = "zigps-a", .filter = "order" }));
    try testing.expectError(error.Unimplemented, b.client.subscription("twice").create(.{ .topic_id = "zigps-a", .filter = "--attributes:k" }));
}

test "a filter: a subscription holds what passes it, of what is published and of what is forwarded to its topic" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    for ([_][]const u8{ "orders", "dead" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "everything", .{ .topic_id = "orders" } },
        .{ "eu-orders", .{ .topic_id = "orders", .filter = "attributes.kind = \"order\" AND attributes.region = \"eu\"" } },
        .{ "not-orders", .{ .topic_id = "orders", .filter = "NOT attributes.kind = \"order\"" } },
        .{ "poison", .{ .topic_id = "orders", .filter = "hasPrefix(attributes.kind, \"ref\")", .dead_letter_policy = .{ .topic = "dead" } } },
        .{ "dead-refunds", .{ .topic_id = "dead", .filter = "attributes.CloudPubSubDeadLetterSourceDeliveryCount = \"5\" AND attributes.kind = \"refund\"" } },
        .{ "dead-orders", .{ .topic_id = "dead", .filter = "attributes.kind = \"order\"" } },
    }) |case| {
        var made = try b.client.subscription(case[0]).create(case[1]);
        made.deinit();
    }
    // The eight messages production was sent under each of its filters.
    const sent = [_]types.Message{
        .{ .data = "m1", .attributes = &.{ .{ .key = "kind", .value = "order" }, .{ .key = "region", .value = "eu" } } },
        .{ .data = "m2", .attributes = &.{ .{ .key = "kind", .value = "order" }, .{ .key = "region", .value = "us" } } },
        .{ .data = "m3", .attributes = &.{ .{ .key = "kind", .value = "refund" }, .{ .key = "region", .value = "eu" } } },
        .{ .data = "m4", .attributes = &.{.{ .key = "region", .value = "us" }} },
        .{ .data = "m5", .attributes = &.{.{ .key = "kind", .value = "" }} },
        .{ .data = "m6" },
        .{ .data = "m7", .attributes = &.{ .{ .key = "kind", .value = "ORDER" }, .{ .key = "KIND", .value = "order" } } },
        .{ .data = "m8", .attributes = &.{ .{ .key = "kind", .value = "a\"b" }, .{ .key = "a b", .value = "x" } } },
    };
    var published = try b.client.topic("orders").publish(&sent, .{});
    published.deinit();
    try testing.expectEqual(8, b.fake.publishedCount("p", "orders"));
    // What does not pass is never held: it is no backlog, and never comes.
    try testing.expectEqual(8, b.fake.backlog("p", "everything"));
    try testing.expectEqual(1, b.fake.backlog("p", "eu-orders"));
    try testing.expectEqual(6, b.fake.backlog("p", "not-orders"));
    try testing.expectEqual(1, b.fake.backlog("p", "poison"));
    var got = try b.client.subscription("eu-orders").pull(.{});
    defer got.deinit();
    try testing.expectEqual(1, got.value.messages.len);
    try testing.expectEqualStrings("m1", got.value.messages[0].data);
    var others = try b.client.subscription("not-orders").pull(.{});
    defer others.deinit();
    try testing.expectEqual(6, others.value.messages.len);
    for (others.value.messages, [_][]const u8{ "m3", "m4", "m5", "m6", "m7", "m8" }) |m, data| try testing.expectEqualStrings(data, m.data);

    // A dead letter is a message to the dead-letter topic like any other:
    // its subscriptions' filters are tried on it, the attributes that mark
    // it included.
    for (0..5) |_| {
        var refund = try b.client.subscription("poison").pull(.{});
        defer refund.deinit();
        try testing.expectEqualStrings("m3", refund.value.messages[0].data);
        try b.client.subscription("poison").nack(&.{refund.value.messages[0].ack_id});
    }
    try testing.expectEqual(0, b.fake.backlog("p", "poison"));
    try testing.expectEqual(1, b.fake.publishedCount("p", "dead"));
    try testing.expectEqual(1, b.fake.backlog("p", "dead-refunds"));
    try testing.expectEqual(0, b.fake.backlog("p", "dead-orders"));
}

test "ordering keys: a key gives what it has waiting together and in order, and no more until that is acknowledged or comes back" {
    for ([_]bool{ true, false }) |shuffle| {
        var b: Bench = undefined;
        try b.init(.{ .shuffle = shuffle });
        defer b.deinit();
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const orders = b.client.topic("orders");
        var made = try orders.create(.{});
        made.deinit();
        const ordered = b.client.subscription("ordered");
        const plain = b.client.subscription("plain");
        var first_made = try ordered.create(.{ .topic_id = "orders", .enable_message_ordering = true });
        first_made.deinit();
        var second_made = try plain.create(.{ .topic_id = "orders" });
        second_made.deinit();
        var published: usize = 0;

        // As production was put to it on 2026-10-12: one of a key out,
        // and then a second published. The second waited fourteen seconds
        // behind the first, and came a second after the first's ack.
        var k1 = try orders.publish(&.{.{ .data = "k1" }}, .{ .ordering_key = "k" });
        k1.deinit();
        var first = try ordered.pull(.{});
        defer first.deinit();
        try testing.expectEqualStrings("k1", first.value.messages[0].data);
        try testing.expectEqualStrings("k", first.value.messages[0].ordering_key);
        var k2 = try orders.publish(&.{.{ .data = "k2" }}, .{ .ordering_key = "k" });
        k2.deinit();
        try expectNothing(ordered);
        // Another key, and a message with none, wait for nothing.
        var j1 = try orders.publish(&.{.{ .data = "j1" }}, .{ .ordering_key = "j" });
        j1.deinit();
        var free1 = try orders.publish(&.{.{ .data = "free1" }}, .{});
        free1.deinit();
        {
            var others = try ordered.pull(.{});
            defer others.deinit();
            try testing.expectEqual(2, others.value.messages.len);
            for (others.value.messages) |m| {
                try testing.expect(m.data[0] != 'k');
                try ordered.ack(&.{m.ack_id});
            }
        }
        b.advance(9);
        try expectNothing(ordered);
        try testing.expectEqual(2, b.fake.backlog("p", "ordered"));
        try ordered.ack(&.{first.value.messages[0].ack_id});
        {
            var second = try ordered.pull(.{});
            defer second.deinit();
            try testing.expectEqual(1, second.value.messages.len);
            try testing.expectEqualStrings("k2", second.value.messages[0].data);
            try ordered.ack(&.{second.value.messages[0].ack_id});
        }
        published += 4;

        // Three of a key published together came together, in order. With
        // the first acknowledged and the second given back, the second and
        // the third came again together: the third was out, and was taken
        // back with the second.
        var three = try orders.publish(&.{ .{ .data = "m1" }, .{ .data = "m2" }, .{ .data = "m3" } }, .{ .ordering_key = "m" });
        three.deinit();
        published += 3;
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(3, got.value.messages.len);
            for (got.value.messages, [_][]const u8{ "m1", "m2", "m3" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try ordered.ack(&.{got.value.messages[0].ack_id});
            try expectNothing(ordered);
            try ordered.nack(&.{got.value.messages[1].ack_id});
            try testing.expectEqual(2, b.fake.backlog("p", "ordered"));
            try testing.expectEqual(0, b.fake.outstanding("p", "ordered"));
            var again = try ordered.pull(.{});
            defer again.deinit();
            try testing.expectEqual(2, again.value.messages.len);
            for (again.value.messages, [_][]const u8{ "m2", "m3" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try ordered.ack(&.{ again.value.messages[0].ack_id, again.value.messages[1].ack_id });
            try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
        }

        // Production's first case: five of a key, all acknowledged but the
        // second, and the second nacked. It came again with the third,
        // fourth and fifth, acknowledged though they were.
        var five = try orders.publish(&.{ .{ .data = "n1" }, .{ .data = "n2" }, .{ .data = "n3" }, .{ .data = "n4" }, .{ .data = "n5" } }, .{ .ordering_key = "n" });
        five.deinit();
        published += 5;
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(5, got.value.messages.len);
            const ids = got.value.messages;
            try ordered.ack(&.{ ids[4].ack_id, ids[0].ack_id, ids[2].ack_id, ids[3].ack_id });
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            try testing.expectEqual(1, b.fake.outstanding("p", "ordered"));
            try ordered.nack(&.{ids[1].ack_id});
            try testing.expectEqual(4, b.fake.backlog("p", "ordered"));
            try testing.expectEqual(0, b.fake.outstanding("p", "ordered"));
            var again = try ordered.pull(.{});
            defer again.deinit();
            try testing.expectEqual(4, again.value.messages.len);
            for (again.value.messages, [_][]const u8{ "n2", "n3", "n4", "n5" }) |m, data| try testing.expectEqualStrings(data, m.data);
            // Acknowledged behind one that is not, the later ones are kept
            // back, and not counted.
            const later = again.value.messages;
            try ordered.ack(&.{ later[3].ack_id, later[1].ack_id, later[2].ack_id });
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            // A second ack of one of those, and a lease change, are
            // answered and forgotten.
            try ordered.ack(&.{later[2].ack_id});
            try ordered.modifyAckDeadline(&.{later[2].ack_id}, 30);
            try ordered.nack(&.{later[3].ack_id});
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            // With the second acknowledged all four are gone.
            try ordered.ack(&.{later[0].ack_id});
            try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
            b.advance(700);
            try expectNothing(ordered);
        }

        // A lapse does as a nack does: all three of a key came again in
        // production, none acknowledged.
        var more = try orders.publish(&.{ .{ .data = "k6" }, .{ .data = "k7" }, .{ .data = "k8" } }, .{ .ordering_key = "k" });
        more.deinit();
        published += 3;
        for (0..2) |_| {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(3, got.value.messages.len);
            for (got.value.messages, [_][]const u8{ "k6", "k7", "k8" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try expectNothing(ordered);
            b.advance(10);
        }
        // With the later two acknowledged, the lapse of the first brings
        // all three: an acknowledged message is given a second time.
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try ordered.ack(&.{ got.value.messages[2].ack_id, got.value.messages[1].ack_id });
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
            b.advance(10);
            try testing.expectEqual(3, b.fake.backlog("p", "ordered"));
        }
        {
            // The first, acknowledged, is gone for good. Of the two left,
            // the lapse of the earlier takes the later back out of a
            // longer lease.
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(3, got.value.messages.len);
            try ordered.ack(&.{got.value.messages[0].ack_id});
            try testing.expectEqual(2, b.fake.backlog("p", "ordered"));
            try ordered.modifyAckDeadline(&.{got.value.messages[2].ack_id}, 600);
            b.advance(10);
            try testing.expectEqual(0, b.fake.outstanding("p", "ordered"));
            var both = try ordered.pull(.{});
            defer both.deinit();
            try testing.expectEqual(2, both.value.messages.len);
            for (both.value.messages, [_][]const u8{ "k7", "k8" }) |m, data| try testing.expectEqualStrings(data, m.data);
            // The other way about, a later one's lapse leaves the earlier
            // out, and the later one waits behind it.
            try ordered.modifyAckDeadline(&.{both.value.messages[0].ack_id}, 600);
            b.advance(10);
            try testing.expectEqual(1, b.fake.outstanding("p", "ordered"));
            try expectNothing(ordered);
            try ordered.ack(&.{both.value.messages[0].ack_id});
            var last = try ordered.pull(.{});
            defer last.deinit();
            try testing.expectEqual(1, last.value.messages.len);
            try testing.expectEqualStrings("k8", last.value.messages[0].data);
            try ordered.ack(&.{last.value.messages[0].ack_id});
            try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
        }

        // A pull's limit may cut a key's messages short. The rest wait
        // until every one of those given is acknowledged.
        var cut = try orders.publish(&.{ .{ .data = "q1" }, .{ .data = "q2" }, .{ .data = "q3" } }, .{ .ordering_key = "q" });
        cut.deinit();
        published += 3;
        {
            var got = try ordered.pull(.{ .max_messages = 2 });
            defer got.deinit();
            try testing.expectEqual(2, got.value.messages.len);
            for (got.value.messages, [_][]const u8{ "q1", "q2" }) |m, data| try testing.expectEqualStrings(data, m.data);
            try expectNothing(ordered);
            try ordered.ack(&.{got.value.messages[0].ack_id});
            try expectNothing(ordered);
            try ordered.ack(&.{got.value.messages[1].ack_id});
            var rest = try ordered.pull(.{});
            defer rest.deinit();
            try testing.expectEqual(1, rest.value.messages.len);
            try testing.expectEqualStrings("q3", rest.value.messages[0].data);
            try ordered.ack(&.{rest.value.messages[0].ack_id});
        }

        // Among themselves the keys have no order, nor have the messages
        // with none: one pull gives all nine in an order of the fake's
        // own, each key's still in theirs.
        const Sent = struct { ?[]const u8, []const types.Message };
        for ([_]Sent{
            .{ null, &.{ .{ .data = "f1" }, .{ .data = "f2" }, .{ .data = "f3" } } },
            .{ "x", &.{ .{ .data = "x1" }, .{ .data = "x2" }, .{ .data = "x3" } } },
            .{ "y", &.{ .{ .data = "y1" }, .{ .data = "y2" }, .{ .data = "y3" } } },
        }) |request| {
            var sent = try orders.publish(request[1], .{ .ordering_key = request[0] });
            sent.deinit();
        }
        published += 9;
        {
            var got = try ordered.pull(.{});
            defer got.deinit();
            try testing.expectEqual(9, got.value.messages.len);
            var order: std.ArrayList(u8) = .empty;
            for (got.value.messages) |m| try order.appendSlice(a, m.data);
            for ([_][]const u8{ "x1x2x3", "y1y2y3" }) |key_order| {
                var seen: std.ArrayList(u8) = .empty;
                for (got.value.messages) |m| {
                    if (m.data[0] == key_order[0]) try seen.appendSlice(a, m.data);
                }
                try testing.expectEqualStrings(key_order, seen.items);
            }
            try testing.expectEqual(!shuffle, std.mem.eql(u8, order.items, "f1f2f3x1x2x3y1y2y3"));
            // A message with no key is on its own, with ordering too: its
            // nack brings back no other.
            for (got.value.messages) |m| {
                if (!std.mem.eql(u8, m.data, "f2")) try ordered.ack(&.{m.ack_id});
            }
            for (got.value.messages) |m| {
                if (std.mem.eql(u8, m.data, "f2")) try ordered.nack(&.{m.ack_id});
            }
            try testing.expectEqual(1, b.fake.backlog("p", "ordered"));
        }

        // Without ordering a key means nothing: all come at once, a nack
        // brings back the one message, and what was acknowledged stays so.
        {
            var got = try plain.pull(.{});
            defer got.deinit();
            try testing.expectEqual(published, got.value.messages.len);
            var nacked: []const u8 = "";
            for (got.value.messages) |m| {
                if (std.mem.eql(u8, m.data, "n2")) nacked = m.ack_id else try plain.ack(&.{m.ack_id});
            }
            try plain.nack(&.{nacked});
            try testing.expectEqual(1, b.fake.backlog("p", "plain"));
            var again = try plain.pull(.{});
            defer again.deinit();
            try testing.expectEqual(1, again.value.messages.len);
            try testing.expectEqualStrings("n2", again.value.messages[0].data);
        }
    }
}

test "ordering with exactly-once delivery: a key gives one message at a time, the next after an ack" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const orders = b.client.topic("orders");
    var made = try orders.create(.{});
    made.deinit();
    const strict = b.client.subscription("strict");
    var subscribed = try strict.create(.{ .topic_id = "orders", .enable_message_ordering = true, .enable_exactly_once_delivery = true });
    subscribed.deinit();

    // As production did on 2026-10-12, of three published together: the
    // first alone, the second after the first's ack, the second again
    // after its nack, and the third after the second's ack.
    var three = try orders.publish(&.{ .{ .data = "m1" }, .{ .data = "m2" }, .{ .data = "m3" } }, .{ .ordering_key = "m" });
    three.deinit();
    var free = try orders.publish(&.{ .{ .data = "free1" }, .{ .data = "free2" } }, .{});
    free.deinit();
    var other = try orders.publish(&.{ .{ .data = "j1" }, .{ .data = "j2" } }, .{ .ordering_key = "j" });
    other.deinit();
    var held: []const u8 = "";
    {
        // The first of each key, and every message with none.
        var got = try strict.pull(.{});
        defer got.deinit();
        try testing.expectEqual(4, got.value.messages.len);
        for (got.value.messages) |m| {
            if (std.mem.eql(u8, m.data, "m1")) {
                held = try testing.allocator.dupe(u8, m.ack_id);
            } else {
                try testing.expect(std.mem.eql(u8, m.data, "j1") or m.data[0] == 'f');
                if (m.data[0] == 'f') try strict.ack(&.{m.ack_id});
            }
        }
    }
    defer testing.allocator.free(held);
    try testing.expectEqual(5, b.fake.backlog("p", "strict"));
    try testing.expectEqual(2, b.fake.outstanding("p", "strict"));
    b.advance(30);
    try expectNothing(strict);
    try strict.ack(&.{held});
    for ([_][]const u8{ "m2", "m2", "m3" }, 0..) |data, round| {
        var got = try strict.pull(.{});
        defer got.deinit();
        try testing.expectEqual(1, got.value.messages.len);
        try testing.expectEqualStrings(data, got.value.messages[0].data);
        try expectNothing(strict);
        if (round == 0) try strict.nack(&.{got.value.messages[0].ack_id}) else try strict.ack(&.{got.value.messages[0].ack_id});
    }
    // The other key's first lapses, and comes again alone.
    try testing.expectEqual(2, b.fake.backlog("p", "strict"));
    b.advance(30);
    var again = try strict.pull(.{});
    defer again.deinit();
    try testing.expectEqual(1, again.value.messages.len);
    try testing.expectEqualStrings("j1", again.value.messages[0].data);
}

test "dead letters: every delivery is an attempt, sent with a policy alone, and after the last the message moves to the dead-letter topic" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_][]const u8{ "orders", "dead", "ring" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const worker = b.client.subscription("worker");
    const morgue = b.client.subscription("morgue");
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "worker", .{ .topic_id = "orders", .dead_letter_policy = .{ .topic = "dead" } } },
        .{ "plain", .{ .topic_id = "orders" } },
        .{ "morgue", .{ .topic_id = "dead" } },
        .{ "loop", .{ .topic_id = "ring", .dead_letter_policy = .{ .topic = "ring", .max_delivery_attempts = 6 } } },
    }) |case| {
        var made = try b.client.subscription(case[0]).create(case[1]);
        made.deinit();
    }
    b.advance(40);
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "poison", .attributes = &.{.{ .key = "kind", .value = "order" }} }}, .{ .ordering_key = "o" });
    sent.deinit();
    b.advance(2);

    // Nacked each time, as production counted them: 1 to 5. With no
    // policy no attempt is sent at all.
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .POST, "projects/p/subscriptions/plain:pull", "{\"maxMessages\":1}")).body, "deliveryAttempt") == null);
    for (1..6) |attempt| {
        try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    // After the fifth it is forwarded, and comes here no more.
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try expectNothing(worker);
    try testing.expectEqual(1, b.fake.publishedCount("p", "dead"));
    {
        // As production marked one: a new id, its own data and attributes,
        // and where it came from.
        var got = try morgue.pull(.{});
        defer got.deinit();
        const m = got.value.messages[0];
        try testing.expectEqualStrings("poison", m.data);
        try testing.expectEqualStrings("2", m.message_id);
        try testing.expectEqualStrings("o", m.ordering_key);
        try testing.expectEqual(5, m.attributes.len);
        try testing.expectEqualStrings("order", m.attribute("kind").?);
        try testing.expectEqualStrings("5", m.attribute("CloudPubSubDeadLetterSourceDeliveryCount").?);
        try testing.expectEqualStrings("worker", m.attribute("CloudPubSubDeadLetterSourceSubscription").?);
        try testing.expectEqualStrings("p", m.attribute("CloudPubSubDeadLetterSourceSubscriptionProject").?);
        try testing.expectEqualStrings("1970-01-01T00:00:40Z", m.attribute("CloudPubSubDeadLetterSourceTopicPublishTime").?);
        // Published when it was forwarded, and delivered like any other.
        try testing.expectEqualStrings("1970-01-01T00:00:42Z", m.publish_time);
        try testing.expectEqual(0, m.delivery_attempt);
        try morgue.ack(&.{m.ack_id});
    }

    // A lapse is an attempt as a nack is: the fifth lease to run out
    // forwards the message, at the moment it runs out.
    var slow = try b.client.topic("orders").publish(&.{.{ .data = "slow" }}, .{});
    slow.deinit();
    for (1..6) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        b.advance(9);
        try testing.expectEqual(1, b.fake.backlog("p", "worker"));
        try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
        b.advance(1);
    }
    // Whatever is asked first after the lapse finds it forwarded.
    try testing.expectEqual(2, b.fake.publishedCount("p", "dead"));
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(1, b.fake.backlog("p", "morgue"));
    // An ack in time ends it: four attempts and an ack forward nothing.
    var fine = try b.client.topic("orders").publish(&.{.{ .data = "fine" }}, .{});
    fine.deinit();
    for (1..5) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        if (attempt < 4) try worker.nack(&.{got.value.messages[0].ack_id}) else try worker.ack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(2, b.fake.publishedCount("p", "dead"));

    // What time has done is done before a request is served: a publish
    // that comes after the last lapse gets an id after the dead letter's.
    var slower = try b.client.topic("orders").publish(&.{.{ .data = "slower" }}, .{});
    defer slower.deinit();
    for (1..6) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        b.advance(10);
    }
    var next = try b.client.topic("orders").publish(&.{.{ .data = "next" }}, .{});
    defer next.deinit();
    try testing.expectEqual(try std.fmt.parseInt(u64, slower.value.message_ids[0], 10) + 2, try std.fmt.parseInt(u64, next.value.message_ids[0], 10));
    {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqualStrings("next", got.value.messages[0].data);
        try worker.ack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(3, b.fake.publishedCount("p", "dead"));

    // With the dead-letter topic gone the message goes on coming, as
    // production's did for want of the grants: a sixth time, a seventh.
    try b.client.topic("dead").delete();
    var stuck = try b.client.topic("orders").publish(&.{.{ .data = "stuck" }}, .{});
    stuck.deinit();
    for (1..8) |attempt| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    // A policy names its topic: one made again under the name gets the
    // next that is released. The old one's subscription gets nothing.
    var remade = try b.client.topic("dead").create(.{});
    remade.deinit();
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(8, got.value.messages[0].delivery_attempt);
        b.advance(10);
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(1, b.fake.publishedCount("p", "dead"));
    try testing.expectEqual(2, b.fake.backlog("p", "morgue"));

    // A policy set by an update counts the deliveries made before it, and
    // one taken away sends no more attempts.
    var late = try b.client.topic("orders").publish(&.{.{ .data = "late" }}, .{});
    late.deinit();
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/worker", "{\"subscription\":{},\"updateMask\":\"deadLetterPolicy\"}")).status);
    for (0..6) |_| {
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(0, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/worker", "{\"subscription\":{\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\",\"maxDeliveryAttempts\":8}},\"updateMask\":\"deadLetterPolicy\"}")).status);
    for (7..9) |attempt| {
        try testing.expectEqual(1, b.fake.backlog("p", "worker"));
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try worker.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(2, b.fake.publishedCount("p", "dead"));

    // Dead letters to its own topic, which production takes: the message
    // comes round again as a new one, counted from one.
    var round = try b.client.topic("ring").publish(&.{.{ .data = "round" }}, .{});
    defer round.deinit();
    const loop = b.client.subscription("loop");
    for (1..7) |attempt| {
        var got = try loop.pull(.{});
        defer got.deinit();
        try testing.expectEqualStrings(round.value.message_ids[0], got.value.messages[0].message_id);
        try testing.expectEqual(attempt, got.value.messages[0].delivery_attempt);
        try loop.nack(&.{got.value.messages[0].ack_id});
    }
    try testing.expectEqual(2, b.fake.publishedCount("p", "ring"));
    try testing.expectEqual(1, b.fake.backlog("p", "loop"));
    var returned = try loop.pull(.{});
    defer returned.deinit();
    try testing.expect(!std.mem.eql(u8, round.value.message_ids[0], returned.value.messages[0].message_id));
    try testing.expectEqualStrings("round", returned.value.messages[0].data);
    try testing.expectEqual(1, returned.value.messages[0].delivery_attempt);
    try testing.expectEqualStrings("6", returned.value.messages[0].attribute("CloudPubSubDeadLetterSourceDeliveryCount").?);
    try testing.expectEqualStrings("loop", returned.value.messages[0].attribute("CloudPubSubDeadLetterSourceSubscription").?);
}

test "a retry policy: a message given back or lapsed waits out its backoff, and with ordering holds its key behind it" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const slow = b.client.subscription("slow");
    const fast = b.client.subscription("fast");
    const none = b.client.subscription("none");
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "slow", .{ .topic_id = "orders", .retry_policy = .{ .minimum = .fromSeconds(10), .maximum = .fromSeconds(20) } } },
        .{ "fast", .{ .topic_id = "orders", .retry_policy = .{ .minimum = .zero, .maximum = .fromSeconds(600) } } },
        .{ "none", .{ .topic_id = "orders" } },
    }) |case| {
        var subscribed = try b.client.subscription(case[0]).create(case[1]);
        subscribed.deinit();
    }
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();

    // Without a policy, and with one of no seconds, it comes again at
    // once. (Production's came about two seconds on, its own delay.)
    for ([_]@TypeOf(none){ none, fast }) |sub| {
        for (0..3) |_| {
            var got = try sub.pull(.{});
            defer got.deinit();
            try testing.expectEqual(1, got.value.messages.len);
            try sub.nack(&.{got.value.messages[0].ack_id});
        }
    }

    // 10 to 20 seconds: the minimum after the first delivery, twice that
    // after the second, and no more than the maximum after the third.
    for ([_]i64{ 10, 20, 20 }) |backoff| {
        var got = try slow.pull(.{});
        defer got.deinit();
        try testing.expectEqual(1, got.value.messages.len);
        try slow.nack(&.{got.value.messages[0].ack_id});
        try expectNothing(slow);
        b.advance(backoff - 1);
        try expectNothing(slow);
        // Waiting, it is held and not out.
        try testing.expectEqual(1, b.fake.backlog("p", "slow"));
        try testing.expectEqual(0, b.fake.outstanding("p", "slow"));
        b.advance(1);
    }
    // After a lapse the backoff runs from the lapse, whenever that is
    // noticed: a 10 second lease, then 20 seconds more.
    {
        var got = try slow.pull(.{});
        defer got.deinit();
        try testing.expectEqual(1, got.value.messages.len);
        b.advance(29);
        try expectNothing(slow);
        b.advance(1);
        var again = try slow.pull(.{});
        defer again.deinit();
        try testing.expectEqual(1, again.value.messages.len);
        // An ack with an id of an earlier delivery ends it all the same.
        try slow.ack(&.{got.value.messages[0].ack_id});
        try testing.expectEqual(0, b.fake.backlog("p", "slow"));
    }

    // With ordering, a message waiting out its backoff holds the later
    // ones of its key behind it, and no other.
    const ordered = b.client.subscription("ordered");
    var subscribed = try ordered.create(.{ .topic_id = "orders", .enable_message_ordering = true, .retry_policy = .{ .minimum = .fromSeconds(10), .maximum = .fromSeconds(20) } });
    subscribed.deinit();
    var keyed = try b.client.topic("orders").publish(&.{ .{ .data = "r1" }, .{ .data = "r2" } }, .{ .ordering_key = "r" });
    keyed.deinit();
    {
        var got = try ordered.pull(.{});
        defer got.deinit();
        try testing.expectEqual(2, got.value.messages.len);
        try ordered.nack(&.{got.value.messages[0].ack_id});
        // r2 was taken back with r1, and is not given past it.
        try expectNothing(ordered);
        var other = try b.client.topic("orders").publish(&.{.{ .data = "s1" }}, .{ .ordering_key = "s" });
        other.deinit();
        var free = try b.client.topic("orders").publish(&.{.{ .data = "free" }}, .{});
        free.deinit();
        var unheld = try ordered.pull(.{});
        defer unheld.deinit();
        try testing.expectEqual(2, unheld.value.messages.len);
        try testing.expectEqualStrings("s1", unheld.value.messages[0].data);
        try testing.expectEqualStrings("free", unheld.value.messages[1].data);
        b.advance(9);
        try expectNothing(ordered);
        b.advance(1);
        var again = try ordered.pull(.{});
        defer again.deinit();
        try testing.expectEqual(2, again.value.messages.len);
        try testing.expectEqualStrings("r1", again.value.messages[0].data);
        try testing.expectEqualStrings("r2", again.value.messages[1].data);
    }
}

test "a retry policy: a held pull waits a backoff out on the fake's clock" {
    var b: Bench = undefined;
    try b.init(.{ .empty_pull_hold = .fromSeconds(30) });
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const slow = b.client.subscription("slow");
    var subscribed = try slow.create(.{ .topic_id = "orders", .retry_policy = .{ .minimum = .fromSeconds(10), .maximum = .fromSeconds(20) }, .dead_letter_policy = .{ .topic = "orders" } });
    subscribed.deinit();
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "m" }}, .{});
    sent.deinit();
    var got = try slow.pull(.{});
    defer got.deinit();
    try slow.nack(&.{got.value.messages[0].ack_id});
    const before = b.clock.now_ns;
    var again = try slow.pull(.{});
    defer again.deinit();
    try testing.expectEqual(1, again.value.messages.len);
    try testing.expectEqual(2, again.value.messages[0].delivery_attempt);
    try testing.expectEqual(10 * std.time.ns_per_s, b.clock.now_ns - before);
    // A lease that lapses while a pull is held is settled as at any other
    // time: its backoff runs from the lapse, 10 seconds in and 20 long.
    const then = b.clock.now_ns;
    var third = try slow.pull(.{});
    defer third.deinit();
    try testing.expectEqual(1, third.value.messages.len);
    try testing.expectEqual(3, third.value.messages[0].delivery_attempt);
    try testing.expectEqual(30 * std.time.ns_per_s, b.clock.now_ns - then);
}

test "retention: a message older than the subscription keeps messages is gone, out on a lease or not" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const brief = b.client.subscription("brief");
    var first_made = try brief.create(.{ .topic_id = "orders", .message_retention = .fromSeconds(600) });
    first_made.deinit();
    var second_made = try b.client.subscription("week").create(.{ .topic_id = "orders" });
    second_made.deinit();
    var first = try b.client.topic("orders").publish(&.{.{ .data = "a" }}, .{});
    first.deinit();
    b.advance(300);
    var second = try b.client.topic("orders").publish(&.{.{ .data = "b" }}, .{});
    second.deinit();

    var got = try brief.pull(.{});
    defer got.deinit();
    try testing.expectEqual(2, got.value.messages.len);
    const a_first: usize = if (std.mem.eql(u8, got.value.messages[0].data, "a")) 0 else 1;
    try brief.modifyAckDeadline(&.{ got.value.messages[0].ack_id, got.value.messages[1].ack_id }, 600);
    b.advance(299);
    try testing.expectEqual(2, b.fake.backlog("p", "brief"));
    // Ten minutes after it was published the first is gone, though out.
    b.advance(1);
    try testing.expectEqual(1, b.fake.backlog("p", "brief"));
    try testing.expectEqual(1, b.fake.outstanding("p", "brief"));
    // An ack of it, and a nack, are answered and forgotten.
    try brief.ack(&.{got.value.messages[a_first].ack_id});
    try brief.nack(&.{got.value.messages[a_first].ack_id});
    try testing.expectEqual(1, b.fake.backlog("p", "brief"));
    // The second, given back, waits; and at its ten minutes is gone too.
    try brief.nack(&.{got.value.messages[1 - a_first].ack_id});
    b.advance(299);
    try testing.expectEqual(1, b.fake.backlog("p", "brief"));
    b.advance(1);
    try testing.expectEqual(0, b.fake.backlog("p", "brief"));
    try expectNothing(brief);
    // The other subscription keeps its own time: seven days.
    try testing.expectEqual(2, b.fake.backlog("p", "week"));
    b.advance(604_800 - 900 - 1);
    try testing.expectEqual(2, b.fake.backlog("p", "week"));
    b.advance(1);
    try testing.expectEqual(1, b.fake.backlog("p", "week"));
    b.advance(300);
    try testing.expectEqual(0, b.fake.backlog("p", "week"));

    // With ordering, a message acknowledged and kept behind an earlier
    // one of its key stays acknowledged when the earlier one grows too
    // old and goes: it does not come again.
    const kept = b.client.subscription("kept");
    var kept_made = try kept.create(.{ .topic_id = "orders", .enable_message_ordering = true, .message_retention = .fromSeconds(600) });
    kept_made.deinit();
    var k1 = try b.client.topic("orders").publish(&.{.{ .data = "k1" }}, .{ .ordering_key = "k" });
    k1.deinit();
    b.advance(300);
    var k2 = try b.client.topic("orders").publish(&.{.{ .data = "k2" }}, .{ .ordering_key = "k" });
    k2.deinit();
    var pair = try kept.pull(.{});
    defer pair.deinit();
    try testing.expectEqual(2, pair.value.messages.len);
    try kept.modifyAckDeadline(&.{pair.value.messages[0].ack_id}, 600);
    try kept.ack(&.{pair.value.messages[1].ack_id});
    try testing.expectEqual(1, b.fake.backlog("p", "kept"));
    b.advance(300);
    try testing.expectEqual(0, b.fake.backlog("p", "kept"));
    try expectNothing(kept);
}

test "exactly-once delivery: an ack or a lease change that comes too late is refused, id by id, in production's words" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("orders").create(.{});
    made.deinit();
    const once = b.client.subscription("once");
    var subscribed = try once.create(.{ .topic_id = "orders", .ack_deadline_seconds = 10, .enable_exactly_once_delivery = true });
    subscribed.deinit();
    var sent = try b.client.topic("orders").publish(&.{ .{ .data = "a" }, .{ .data = "b" } }, .{});
    sent.deinit();
    const ack = "projects/p/subscriptions/once:acknowledge";
    const modack = "projects/p/subscriptions/once:modifyAckDeadline";
    // Production's refusal, whole, 2026-09-27.
    const refusal = "{{\"error\":{{\"code\":400,\"message\":\"Some acknowledgement ids in the request were invalid. This could be because the acknowledgement ids have expired or the acknowledgement ids were malformed.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"EXACTLY_ONCE_ACKID_FAILURE\",\"domain\":\"pubsub.googleapis.com\",\"metadata\":{{\"{s}\":\"PERMANENT_FAILURE_INVALID_ACK_ID\"}}}}]}}}}";

    var got = try once.pull(.{});
    defer got.deinit();
    const id_a = got.value.messages[0].ack_id;
    const id_b = got.value.messages[1].ack_id;
    // In time, every call is taken.
    try once.modifyAckDeadline(&.{id_a}, 600);
    b.advance(10);
    // One live id and one lapsed in one ack: refused naming the lapsed
    // one alone, and the live one was taken.
    const mixed = try b.raw(a, .POST, ack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ id_a, id_b }));
    try testing.expectEqual(400, mixed.status);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{id_b}), mixed.body);
    try testing.expectEqual(1, b.fake.backlog("p", "once"));
    // A second ack of an acknowledged message is taken.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, ack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{id_a}))).body);
    // A lease change is not: on an acknowledged message, or on a lapsed
    // one, to extend it or to give it back.
    for ([_]struct { []const u8, u32 }{ .{ id_a, 30 }, .{ id_b, 30 }, .{ id_b, 0 } }) |case| {
        const late = try b.raw(a, .POST, modack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"],\"ackDeadlineSeconds\":{d}}}", .{ case[0], case[1] }));
        try testing.expectEqual(400, late.status);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{case[0]}), late.body);
    }
    // An id that is none is refused in the plain words, with no details.
    try expectRefused(try b.raw(a, .POST, ack, "{\"ackIds\":[\"garbage\"]}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=garbage).");
    try testing.expectEqual(1, b.fake.backlog("p", "once"));

    // The message comes again under a new id, and the old one is no
    // longer its id, out though the message is: the client is told which
    // of its ids were taken.
    var again = try once.pull(.{});
    defer again.deinit();
    try testing.expectEqualStrings("b", again.value.messages[0].data);
    try testing.expectError(error.InvalidArgument, once.ack(&.{id_b}));
    try testing.expectError(error.InvalidArgument, once.modifyAckDeadline(&.{id_b}, 30));
    try testing.expectError(error.InvalidArgument, once.nack(&.{id_b}));
    try testing.expectEqual(1, b.fake.outstanding("p", "once"));
    var results: [2]types.AckResult = undefined;
    try once.ackWithResults(&.{ id_b, again.value.messages[0].ack_id }, &results);
    try testing.expectEqual(types.AckResult.invalid_ack_id, results[0]);
    try testing.expectEqual(types.AckResult.ok, results[1]);
    try testing.expectEqual(0, b.fake.backlog("p", "once"));
    // Acknowledged, the id that acknowledged it is taken again, and the
    // id of the earlier delivery is refused as before: production's
    // answers to both, 2026-10-12.
    try once.ack(&.{again.value.messages[0].ack_id});
    try testing.expectError(error.InvalidArgument, once.ack(&.{id_b}));
    try once.ackWithResults(&.{ again.value.messages[0].ack_id, id_b }, &results);
    try testing.expectEqual(types.AckResult.ok, results[0]);
    try testing.expectEqual(types.AckResult.invalid_ack_id, results[1]);

    // An id twice in a request is named once.
    var third = try b.client.topic("orders").publish(&.{.{ .data = "c" }}, .{});
    third.deinit();
    var pulled = try once.pull(.{});
    defer pulled.deinit();
    const id_c = pulled.value.messages[0].ack_id;
    try once.nack(&.{id_c});
    const twice = try b.raw(a, .POST, ack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ id_c, id_c }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{id_c}), twice.body);
    const twice_more = try b.raw(a, .POST, modack, try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"],\"ackDeadlineSeconds\":5}}", .{ id_c, id_c }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, refusal, .{id_c}), twice_more.body);

    // Without exactly-once delivery the same late calls are answered and
    // forgotten, as ever.
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/subscriptions/once", "{\"subscription\":{},\"updateMask\":\"enableExactlyOnceDelivery\"}")).status);
    try once.ack(&.{id_c});
    try once.modifyAckDeadline(&.{id_c}, 30);
    try testing.expectEqual(1, b.fake.backlog("p", "once"));
    try testing.expectEqual(0, b.fake.outstanding("p", "once"));
}

test "snapshots: made, read, changed, listed and deleted, as production answers, and gone at their time" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_][]const u8{ "zigps-t", "zigps-t2" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "zigps-s", .{ .topic_id = "zigps-t", .retain_acked_messages = true, .message_retention = .fromSeconds(600) } },
        .{ "zigps-plain", .{ .topic_id = "zigps-t" } },
        .{ "zigps-s2", .{ .topic_id = "zigps-t2" } },
    }) |case| {
        var made = try b.client.subscription(case[0]).create(case[1]);
        made.deinit();
    }
    b.advance(100);
    var sent = try b.client.topic("zigps-t").publish(&.{ .{ .data = "a" }, .{ .data = "b" }, .{ .data = "c" } }, .{});
    sent.deinit();
    {
        var got = try b.client.subscription("zigps-s").pull(.{});
        defer got.deinit();
        for (got.value.messages) |m| try b.client.subscription("zigps-s").ack(&.{m.ack_id});
    }
    b.advance(20);
    const of_s = "\"subscription\":\"projects/p/subscriptions/zigps-s\"";

    // Production's answers, 2026-10-10. It lasts seven days from the
    // oldest message its subscription has, acknowledged ones it retains
    // included: here the three published at 100 seconds.
    const snap =
        \\{"name":"projects/p/snapshots/zigps-snap","topic":"projects/p/topics/zigps-t","expireTime":"1970-01-08T00:01:40Z","labels":{"k":"v"}}
    ;
    try testing.expectEqualStrings(snap, (try b.raw(a, .PUT, "projects/p/snapshots/zigps-snap", "{" ++ of_s ++ ",\"labels\":{\"k\":\"v\"}}")).body);
    try testing.expectEqualStrings(snap, (try b.raw(a, .GET, "projects/p/snapshots/zigps-snap", "")).body);
    try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/zigps-snap", "{" ++ of_s ++ "}"), 409, "ALREADY_EXISTS", "Resource already exists in the project (resource=zigps-snap).");
    try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/zigps-nosub", "{}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/zigps-missing", "{\"subscription\":\"projects/p/subscriptions/zigps-nope\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/1bad", "{" ++ of_s ++ "}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=projects/p/snapshots/1bad). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    try testing.expectEqual(400, (try b.raw(a, .PUT, "projects/p/snapshots/zigps-label", "{" ++ of_s ++ ",\"labels\":{\"K\":\"v\"}}")).status);
    for ([_]tp.Method{ .GET, .DELETE }) |method| {
        try expectRefused(try b.raw(a, method, "projects/p/snapshots/zigps-nope", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    }
    try expectRefused(try b.raw(a, .PATCH, "projects/p/snapshots/zigps-nope", "{\"snapshot\":{},\"updateMask\":\"labels\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    try testing.expectEqualStrings("{\"snapshots\":[" ++ snap ++ "]}", (try b.raw(a, .GET, "projects/p/snapshots", "")).body);
    try testing.expectEqualStrings("{\"snapshots\":[\"projects/p/snapshots/zigps-snap\"]}", (try b.raw(a, .GET, "projects/p/topics/zigps-t/snapshots", "")).body);
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/topics/zigps-t2/snapshots", "")).body);

    // Updates: the labels are replaced whole, and nothing else changes.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/snapshots/zigps-snap","topic":"projects/p/topics/zigps-t","expireTime":"1970-01-08T00:01:40Z","labels":{"k2":"v2"}}
    , (try b.raw(a, .PATCH, "projects/p/snapshots/zigps-snap", "{\"snapshot\":{\"labels\":{\"k2\":\"v2\"}},\"updateMask\":\"labels\"}")).body);
    for ([_]struct { []const u8, []const u8 }{
        .{ "{\"snapshot\":{\"expireTime\":\"1970-01-02T00:00:00Z\"},\"updateMask\":\"expireTime\"}", "Invalid update_mask provided in the UpdateSnapshotRequest: the 'expire_time' field in the Snapshot is not mutable." },
        .{ "{\"snapshot\":{\"topic\":\"projects/p/topics/zigps-t2\"},\"updateMask\":\"topic\"}", "Invalid update_mask provided in the UpdateSnapshotRequest: the 'topic' field in the Snapshot is not mutable." },
        .{ "{\"snapshot\":{\"labels\":{\"k\":\"v\"}}}", "The update_mask in the UpdateSnapshotRequest must be set, and must contain a non-empty paths list." },
    }) |case| {
        try expectRefused(try b.raw(a, .PATCH, "projects/p/snapshots/zigps-snap", case[0]), 400, "INVALID_ARGUMENT", case[1]);
    }
    try testing.expectEqual(400, (try b.raw(a, .PATCH, "projects/p/snapshots/zigps-snap", "{\"snapshot\":{\"labels\":{\"K\":\"v\"}},\"updateMask\":\"labels\"}")).status);
    try testing.expectEqual(400, (try b.raw(a, .PATCH, "projects/p/snapshots/zigps-snap", "{\"snapshot\":{},\"updateMask\":\"nonsense\"}")).status);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/snapshots/zigps-snap", "")).body, "{\"k2\":\"v2\"}") != null);
    // With none in the body the labels are cleared, and none are written.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/snapshots/zigps-snap","topic":"projects/p/topics/zigps-t","expireTime":"1970-01-08T00:01:40Z"}
    , (try b.raw(a, .PATCH, "projects/p/snapshots/zigps-snap", "{\"snapshot\":{},\"updateMask\":\"labels\"}")).body);

    // Through the client, and in pages by name. Of a subscription that
    // holds the three unacknowledged, it lasts seven days from them too.
    var made = try b.client.snapshot("zigps-other").create(.{ .subscription = "zigps-plain", .labels = &.{.{ .key = "env", .value = "test" }} });
    defer made.deinit();
    try testing.expectEqualStrings("projects/p/snapshots/zigps-other", made.value.name);
    try testing.expectEqualStrings("projects/p/topics/zigps-t", made.value.topic);
    try testing.expectEqualStrings("test", made.value.label("env").?);
    try testing.expectEqual(std.Io.Timestamp{ .nanoseconds = (100 + 7 * 86_400) * std.time.ns_per_s }, made.value.expire_time);
    var changed = try b.client.snapshot("zigps-other").update(.{ .labels = &.{} });
    defer changed.deinit();
    try testing.expectEqual(0, changed.value.labels.len);
    var page = try b.client.listSnapshots(.{ .page_size = 1 });
    defer page.deinit();
    try testing.expectEqual(1, page.value.snapshots.len);
    try testing.expectEqualStrings("projects/p/snapshots/zigps-other", page.value.snapshots[0].name);
    var rest = try b.client.listSnapshots(.{ .page_size = 1, .page_token = page.value.next_page_token.? });
    defer rest.deinit();
    try testing.expectEqualStrings("projects/p/snapshots/zigps-snap", rest.value.snapshots[0].name);
    try testing.expectEqual(null, rest.value.next_page_token);
    var of_topic = try b.client.topic("zigps-t").listSnapshots(.{ .page_size = 1 });
    defer of_topic.deinit();
    try testing.expectEqualStrings("projects/p/snapshots/zigps-other", of_topic.value.names[0]);
    var of_topic_rest = try b.client.topic("zigps-t").listSnapshots(.{ .page_token = of_topic.value.next_page_token.? });
    defer of_topic_rest.deinit();
    try testing.expectEqual(1, of_topic_rest.value.names.len);
    try testing.expectError(error.NotFound, b.client.topic("zigps-nope").listSnapshots(.{}));

    // Of a subscription that holds nothing and retains nothing, it lasts
    // seven days from when it is taken.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/snapshots/zigps-empty","topic":"projects/p/topics/zigps-t2","expireTime":"1970-01-08T00:02:00Z"}
    , (try b.raw(a, .PUT, "projects/p/snapshots/zigps-empty", "{\"subscription\":\"projects/p/subscriptions/zigps-s2\"}")).body);
    try b.client.snapshot("zigps-empty").delete();

    // Deleted, it is gone.
    try b.client.snapshot("zigps-other").delete();
    try testing.expectError(error.NotFound, b.client.snapshot("zigps-other").delete());
    try testing.expectError(error.NotFound, b.client.subscription("zigps-plain").seek(.{ .snapshot = "zigps-other" }));

    // It outlives its subscription, and its topic, which it then reads as
    // deleted. The deleted topic has no list of snapshots.
    try b.client.subscription("zigps-s").delete();
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/snapshots/zigps-snap", "")).body, "\"topic\":\"projects/p/topics/zigps-t\"") != null);
    try b.client.topic("zigps-t").delete();
    try testing.expectEqualStrings(
        \\{"name":"projects/p/snapshots/zigps-snap","topic":"_deleted-topic_","expireTime":"1970-01-08T00:01:40Z"}
    , (try b.raw(a, .GET, "projects/p/snapshots/zigps-snap", "")).body);
    try expectRefused(try b.raw(a, .GET, "projects/p/topics/zigps-t/snapshots", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-t).");
    // A topic made again under the name is another: the snapshot is not
    // among its own.
    var again = try b.client.topic("zigps-t").create(.{});
    again.deinit();
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/topics/zigps-t/snapshots", "")).body);

    // At its time it is gone, to the second.
    b.advance(7 * 86_400 - 21);
    try testing.expectEqual(200, (try b.raw(a, .GET, "projects/p/snapshots/zigps-snap", "")).status);
    b.advance(1);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/snapshots/zigps-snap", "")).status);
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/snapshots", "")).body);

    // What a subscription retained and has let go for its age does not
    // count: of one that holds nothing and retains nothing still, a
    // snapshot lasts seven days from when it is taken.
    const brief = b.client.subscription("zigps-brief");
    var brief_made = try brief.create(.{ .topic_id = "zigps-t", .retain_acked_messages = true, .message_retention = .fromSeconds(600) });
    brief_made.deinit();
    var old = try b.client.topic("zigps-t").publish(&.{.{ .data = "x" }}, .{});
    old.deinit();
    try expectPulled(brief, &.{"x"}, true);
    b.advance(600);
    var late = try b.client.snapshot("zigps-late").create(.{ .subscription = "zigps-brief" });
    defer late.deinit();
    try testing.expectEqual(std.Io.Timestamp{ .nanoseconds = (604_900 + 600 + 7 * 86_400) * std.time.ns_per_s }, late.value.expire_time);
}

test "a snapshot of a subscription with ordering holds what is not acknowledged, and not what is acknowledged and kept" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    const topic = b.client.topic("orders");
    var topic_made = try topic.create(.{});
    topic_made.deinit();
    const ordered = b.client.subscription("ordered");
    var made = try ordered.create(.{ .topic_id = "orders", .enable_message_ordering = true });
    made.deinit();
    var sent = try topic.publish(&.{ .{ .data = "k1" }, .{ .data = "k2" } }, .{ .ordering_key = "k" });
    sent.deinit();
    var got = try ordered.pull(.{});
    defer got.deinit();
    // The second is acknowledged, and kept behind the first, which is not.
    try ordered.ack(&.{got.value.messages[1].ack_id});
    var taken = try b.client.snapshot("first-only").create(.{ .subscription = "ordered" });
    taken.deinit();
    try ordered.ack(&.{got.value.messages[0].ack_id});
    try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
    try ordered.seek(.{ .snapshot = "first-only" });
    try expectPulled(ordered, &.{"k1"}, true);
    try testing.expectEqual(0, b.fake.backlog("p", "ordered"));
}

/// Pulls everything the subscription has ready and expects exactly these,
/// in this order: with `Options.shuffle` off, the order published.
fn expectPulled(sub: anytype, datas: []const []const u8, ack: bool) !void {
    var got = try sub.pull(.{ .return_immediately = true });
    defer got.deinit();
    try testing.expectEqual(datas.len, got.value.messages.len);
    for (got.value.messages, datas) |m, data| {
        try testing.expectEqualStrings(data, m.data);
        if (ack) try sub.ack(&.{m.ack_id});
    }
}

test "seek to a snapshot: the subscription holds again what the snapshot holds, and what came after" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const topic = b.client.topic("orders");
    for ([_][]const u8{ "orders", "other" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const worker = b.client.subscription("worker");
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "worker", .{ .topic_id = "orders" } },
        .{ "elsewhere", .{ .topic_id = "other" } },
        .{ "once", .{ .topic_id = "orders", .ack_deadline_seconds = 10, .enable_exactly_once_delivery = true } },
    }) |case| {
        var made = try b.client.subscription(case[0]).create(case[1]);
        made.deinit();
    }

    // As production was put to it: three acknowledged, two more
    // published and not yet acknowledged when the snapshot is taken, a
    // sixth after it.
    var first = try topic.publish(&.{ .{ .data = "a" }, .{ .data = "b" }, .{ .data = "c" } }, .{});
    first.deinit();
    try expectPulled(worker, &.{ "a", "b", "c" }, true);
    var second = try topic.publish(&.{ .{ .data = "d", .attributes = &.{.{ .key = "kind", .value = "order" }} }, .{ .data = "e" } }, .{});
    second.deinit();
    var taken = try b.client.snapshot("before").create(.{ .subscription = "worker" });
    taken.deinit();
    try expectPulled(worker, &.{ "d", "e" }, true);
    var third = try topic.publish(&.{.{ .data = "f" }}, .{});
    third.deinit();
    try expectPulled(worker, &.{"f"}, true);
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));

    // The seek brought back d, e and f, each of them acknowledged since.
    try worker.seek(.{ .snapshot = "before" });
    try testing.expectEqual(3, b.fake.backlog("p", "worker"));
    try expectPulled(worker, &.{ "d", "e", "f" }, false);
    // The snapshot stays, to be sought again: what is out comes back, and
    // an id from before the seek is answered and forgotten.
    try expectNothing(worker);
    b.advance(10);
    var before_seek = try worker.pull(.{});
    defer before_seek.deinit();
    try testing.expectEqual(3, before_seek.value.messages.len);
    try worker.seek(.{ .snapshot = "before" });
    try testing.expectEqual(3, b.fake.backlog("p", "worker"));
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    try worker.ack(&.{before_seek.value.messages[0].ack_id});
    try worker.modifyAckDeadline(&.{before_seek.value.messages[1].ack_id}, 30);
    try worker.nack(&.{before_seek.value.messages[2].ack_id});
    try testing.expectEqual(3, b.fake.backlog("p", "worker"));
    try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    try expectPulled(worker, &.{ "d", "e", "f" }, true);
    try testing.expectEqual(200, (try b.raw(a, .GET, "projects/p/snapshots/before", "")).status);

    // With exactly-once delivery too an id from before a seek is taken,
    // to acknowledge and to change a lease, while the lease it had runs,
    // as production took them: the message comes again all the same.
    const once = b.client.subscription("once");
    var stale = try once.pull(.{});
    defer stale.deinit();
    try testing.expectEqual(6, stale.value.messages.len);
    try once.seek(.{ .snapshot = "before" });
    try once.ack(&.{stale.value.messages[0].ack_id});
    try once.modifyAckDeadline(&.{stale.value.messages[5].ack_id}, 30);
    try testing.expectEqual(3, b.fake.backlog("p", "once"));
    try testing.expectEqual(0, b.fake.outstanding("p", "once"));
    // One given since the seek is judged as ever.
    var fresh = try once.pull(.{});
    defer fresh.deinit();
    try testing.expectEqual(3, fresh.value.messages.len);
    b.advance(10);
    try testing.expectError(error.InvalidArgument, once.ack(&.{fresh.value.messages[0].ack_id}));

    // A snapshot serves a subscription that was not there when it was
    // taken, through that subscription's own filter.
    const late = b.client.subscription("late");
    var late_made = try late.create(.{ .topic_id = "orders", .filter = "attributes:kind" });
    late_made.deinit();
    try expectNothing(late);
    try late.seek(.{ .snapshot = "before" });
    try expectPulled(late, &.{"d"}, true);

    // What it refuses, in production's words.
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/elsewhere:seek", "{\"snapshot\":\"projects/p/snapshots/before\"}"), 400, "FAILED_PRECONDITION", "The subscription's topic (projects/p/topics/other) is different from that of the snapshot (projects/p/topics/orders); they must match in order for Seek work. Note that if a topic is deleted and then re-created with the same name, it is considered a distinct topic for these purposes.");
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/worker:seek", "{\"snapshot\":\"projects/p/snapshots/nope\"}"), 404, "NOT_FOUND", "Resource not found (resource=nope).");
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/nope:seek", "{\"snapshot\":\"projects/p/snapshots/before\"}"), 404, "NOT_FOUND", "Resource not found (resource=nope).");
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/worker:seek", "{}"), 400, "INVALID_ARGUMENT", "No target was specified in the SeekRequest. Must specify either a time or a snapshot.");
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/worker:seek", "{\"snapshot\":\"projects/p/snapshots/before\",\"time\":\"1970-01-01T00:00:00Z\"}"), 400, "INVALID_ARGUMENT", "Invalid value (oneof), oneof field 'target' is already set. Cannot set 'time'");
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/worker:seek", "{\"time\":\"1970-01-01T00:00:00Z\",\"snapshot\":\"projects/p/snapshots/before\"}"), 400, "INVALID_ARGUMENT", "Invalid value (oneof), oneof field 'target' is already set. Cannot set 'snapshot'");
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/worker:seek", "{\"snapshot\":\"before\"}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=before). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    try testing.expectEqual(400, (try b.raw(a, .POST, "projects/p/subscriptions/worker:seek", "{\"subscription\":\"x\"}")).status);
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));

    // A topic made again under the name is another topic, to a seek too.
    try topic.delete();
    var remade = try topic.create(.{});
    remade.deinit();
    var newer = try b.client.subscription("newer").create(.{ .topic_id = "orders" });
    newer.deinit();
    try testing.expectError(error.FailedPrecondition, b.client.subscription("newer").seek(.{ .snapshot = "before" }));
    // The old topic's subscription is still that topic's, and seeks.
    try worker.seek(.{ .snapshot = "before" });
    try testing.expectEqual(3, b.fake.backlog("p", "worker"));
}

test "an ack id from before a seek goes on naming its message, and with exactly-once delivery its delivery goes on being out" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var made_topic = try b.client.topic("orders").create(.{});
    made_topic.deinit();
    const Step = struct {
        /// Every message the subscription has ready, its ack ids kept.
        fn pull(sub: anytype, a: Allocator, count: usize) ![]const []const u8 {
            var got = try sub.pull(.{ .return_immediately = true });
            defer got.deinit();
            try testing.expectEqual(count, got.value.messages.len);
            const ids = try a.alloc([]const u8, count);
            for (ids, got.value.messages) |*id, m| id.* = try a.dupe(u8, m.ack_id);
            return ids;
        }
    };
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const refused = error.InvalidArgument;

    // Without exactly-once delivery the lease decides, as ever. As
    // production was put to it on 2026-10-13: four messages, a snapshot,
    // all pulled, a seek to the snapshot, all pulled again on leases of
    // ten minutes.
    const plain = b.client.subscription("plain");
    var made_plain = try plain.create(.{ .topic_id = "orders", .ack_deadline_seconds = 600 });
    made_plain.deinit();
    var sent = try b.client.topic("orders").publish(&.{ .{ .data = "x0" }, .{ .data = "x1" }, .{ .data = "x2" }, .{ .data = "x3" } }, .{});
    sent.deinit();
    var taken = try b.client.snapshot("all").create(.{ .subscription = "plain" });
    taken.deinit();
    const before = try Step.pull(plain, a, 4);
    try plain.seek(.{ .snapshot = "all" });
    // Not out: an id from before the seek is answered and forgotten.
    try plain.ack(&.{before[2]});
    try testing.expectEqual(4, b.fake.backlog("p", "plain"));
    const after = try Step.pull(plain, a, 4);
    // Out again: an ack by x0's old id acknowledges it, and a nack by
    // x1's gives it back, as production's did.
    try plain.ack(&.{before[0]});
    try plain.nack(&.{before[1]});
    try plain.ack(&.{after[3]});
    try testing.expectEqual(2, b.fake.backlog("p", "plain"));
    try testing.expectEqual(1, b.fake.outstanding("p", "plain"));
    try expectPulled(plain, &.{"x1"}, true);
    // A longer lease by an old id is the message's too.
    b.advance(590);
    try plain.modifyAckDeadline(&.{before[2]}, 600);
    b.advance(20);
    try expectNothing(plain);
    // And once that has run out the message is not out: an ack by the
    // old id is answered and forgotten again.
    b.advance(600);
    try plain.ack(&.{before[2]});
    try testing.expectEqual(1, b.fake.backlog("p", "plain"));
    try expectPulled(plain, &.{"x2"}, false);
    try plain.ack(&.{before[2]});
    try testing.expectEqual(0, b.fake.backlog("p", "plain"));

    // With exactly-once delivery, and none of them pulled again: the
    // delivery an id is of goes on being out, on the lease it had.
    const once = b.client.subscription("once");
    var made_once = try once.create(.{ .topic_id = "orders", .ack_deadline_seconds = 30, .enable_exactly_once_delivery = true });
    made_once.deinit();
    try once.seek(.{ .snapshot = "all" });
    const old = try Step.pull(once, a, 4);
    try once.seek(.{ .snapshot = "all" });
    b.advance(3);
    // A nack is refused, and the id is done: an ack by it and a longer
    // lease are refused though the lease it had would still run.
    try testing.expectError(refused, once.nack(&.{old[0]}));
    try testing.expectError(refused, once.ack(&.{old[0]}));
    try testing.expectError(refused, once.modifyAckDeadline(&.{old[0]}, 60));
    // An ack is answered, and again; a longer lease by an id that was
    // answered an ack is not.
    try once.ack(&.{old[1]});
    try once.ack(&.{old[1]});
    try testing.expectError(refused, once.modifyAckDeadline(&.{old[1]}, 60));
    // A longer lease is answered, and runs: past the lease the id had,
    // an ack by it is answered. One whose lease was left alone is refused
    // by then, to acknowledge and to lengthen, and the one that was
    // answered before is answered still.
    try once.modifyAckDeadline(&.{old[2]}, 60);
    b.advance(30);
    try testing.expectError(refused, once.ack(&.{old[3]}));
    try testing.expectError(refused, once.modifyAckDeadline(&.{old[3]}, 60));
    try once.ack(&.{old[2]});
    try once.ack(&.{old[1]});
    // A longer lease, and then a nack: refused, and the id done.
    try once.seek(.{ .snapshot = "all" });
    const again = try Step.pull(once, a, 4);
    try once.seek(.{ .snapshot = "all" });
    try once.modifyAckDeadline(&.{again[0]}, 60);
    try testing.expectError(refused, once.nack(&.{again[0]}));
    try testing.expectError(refused, once.ack(&.{again[0]}));
    // And every one of them comes again: none of that acknowledged a
    // message, which was not out.
    try testing.expectEqual(4, b.fake.backlog("p", "once"));
    try testing.expectEqual(0, b.fake.outstanding("p", "once"));

    // Pulled again after the seek, on leases of ten minutes, as
    // production was put to it: an ack by x0's old id is answered and
    // acknowledges it, so that a nack by its new id is refused; a nack by
    // x1's old id is answered and gives nothing back.
    const long = b.client.subscription("long");
    var made_long = try long.create(.{ .topic_id = "orders", .ack_deadline_seconds = 600, .enable_exactly_once_delivery = true });
    made_long.deinit();
    try long.seek(.{ .snapshot = "all" });
    const first = try Step.pull(long, a, 4);
    try long.seek(.{ .snapshot = "all" });
    b.advance(60);
    const second = try Step.pull(long, a, 4);
    try long.ack(&.{first[0]});
    try long.nack(&.{first[1]});
    try long.ack(&.{second[3]});
    // Nor is a lease by the old id the message's: x2 stays out on the
    // ten minutes it has, past the ten seconds its old id is given.
    try long.modifyAckDeadline(&.{first[2]}, 10);
    b.advance(15);
    try testing.expectEqual(2, b.fake.outstanding("p", "long"));
    try expectNothing(long);
    try testing.expectError(refused, long.nack(&.{second[0]}));
    try testing.expectError(refused, long.ack(&.{second[0]}));
    try long.nack(&.{second[2]});
    try testing.expectEqual(2, b.fake.backlog("p", "long"));
    try testing.expectEqual(1, b.fake.outstanding("p", "long"));
    try expectPulled(long, &.{"x2"}, true);
    // The old id that acknowledged x0 is answered again.
    try long.ack(&.{first[0]});
    // An id from before two seeks is no other.
    try long.seek(.{ .snapshot = "all" });
    _ = try Step.pull(long, a, 4);
    try long.ack(&.{second[1]});
    try testing.expectEqual(3, b.fake.backlog("p", "long"));
    try long.nack(&.{first[3]});
    try testing.expectEqual(3, b.fake.outstanding("p", "long"));
    // The one whose lease was cut to ten seconds is over.
    try testing.expectError(refused, long.nack(&.{first[2]}));
}

test "seek to a time: what was published from then on comes again, of what the subscription or its topic retains" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const topic = b.client.topic("orders");
    var topic_made = try topic.create(.{});
    topic_made.deinit();
    const keeper = b.client.subscription("keeper");
    const plain = b.client.subscription("plain");
    for ([_]struct { []const u8, types.SubscriptionConfig }{
        .{ "keeper", .{ .topic_id = "orders", .retain_acked_messages = true, .message_retention = .fromSeconds(600) } },
        .{ "plain", .{ .topic_id = "orders" } },
        .{ "ordered", .{ .topic_id = "orders", .retain_acked_messages = true, .enable_message_ordering = true } },
    }) |case| {
        var made = try b.client.subscription(case[0]).create(case[1]);
        made.deinit();
    }
    const at = struct {
        fn seconds(s: i64) std.Io.Timestamp {
            return .{ .nanoseconds = @as(i96, s) * std.time.ns_per_s };
        }
    }.seconds;

    // a, b and c at 100 seconds, d and e at 110, f at 120: all pulled and
    // acknowledged by both.
    for ([_]struct { i64, []const types.Message }{
        .{ 100, &.{ .{ .data = "a" }, .{ .data = "b" }, .{ .data = "c" } } },
        .{ 10, &.{ .{ .data = "d" }, .{ .data = "e" } } },
        .{ 10, &.{.{ .data = "f" }} },
    }) |step| {
        b.advance(step[0]);
        var sent = try topic.publish(step[1], .{ .ordering_key = "k" });
        sent.deinit();
    }
    b.advance(5);
    try expectPulled(keeper, &.{ "a", "b", "c", "d", "e", "f" }, true);

    // Back to before everything: a subscription that retains its
    // acknowledged messages has all six again, as production's had.
    try keeper.seek(.{ .time = at(0) });
    try testing.expectEqual(6, b.fake.backlog("p", "keeper"));
    try expectPulled(keeper, &.{ "a", "b", "c", "d", "e", "f" }, false);
    // To a time between: what was published at that time and after. The
    // ones out are out no more.
    try keeper.seek(.{ .time = at(110) });
    try testing.expectEqual(0, b.fake.outstanding("p", "keeper"));
    try expectPulled(keeper, &.{ "d", "e", "f" }, false);
    try keeper.seek(.{ .time = .{ .nanoseconds = 110 * std.time.ns_per_s + 1 } });
    try expectPulled(keeper, &.{"f"}, false);
    // To now, and ahead: everything it holds is acknowledged, pulled or
    // not. A seek ahead is no standing filter: what is published after
    // it, though before its time, comes.
    try keeper.seek(.{ .time = at(0) });
    try keeper.seek(.{ .time = at(125) });
    try testing.expectEqual(0, b.fake.backlog("p", "keeper"));
    var g = try topic.publish(&.{.{ .data = "g" }}, .{});
    g.deinit();
    try keeper.seek(.{ .time = at(125 + 3600) });
    try testing.expectEqual(0, b.fake.backlog("p", "keeper"));
    var h = try topic.publish(&.{.{ .data = "h" }}, .{});
    h.deinit();
    try expectPulled(keeper, &.{"h"}, true);
    // Times production took: 1970, one with an offset, and one from
    // before what the subscription retains.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/keeper:seek", "{\"time\":\"1970-01-01T02:01:50+02:00\"}")).body);
    try expectPulled(keeper, &.{ "d", "e", "f", "g", "h" }, true);
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/keeper:seek", "{\"time\":\"1969-12-24T00:00:00Z\"}")).body);
    try testing.expectEqual(8, b.fake.backlog("p", "keeper"));
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/keeper:seek", "{\"time\":\"yesterday\"}"), 400, "INVALID_ARGUMENT", "Invalid value at 'time' (type.googleapis.com/google.protobuf.Timestamp), Field 'time', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.");
    try testing.expectEqual(8, b.fake.backlog("p", "keeper"));

    // It retains them ten minutes. Past that, held or acknowledged, the
    // first three are gone, and a seek brings back the rest.
    try expectPulled(keeper, &.{ "a", "b", "c", "d", "e", "f", "g", "h" }, true);
    b.advance(600 - 25);
    try keeper.seek(.{ .time = at(0) });
    try expectPulled(keeper, &.{ "d", "e", "f", "g", "h" }, true);

    // With ordering a seek back gives a key's messages in order again.
    const ordered = b.client.subscription("ordered");
    try expectPulled(ordered, &.{ "a", "b", "c", "d", "e", "f", "g", "h" }, true);
    try ordered.seek(.{ .time = at(105) });
    try expectPulled(ordered, &.{ "d", "e", "f", "g", "h" }, true);

    // A subscription that retains nothing, on a topic that retains
    // nothing: a seek back brings back nothing acknowledged. What it has
    // not had acknowledged it still has, out no more.
    var got = try plain.pull(.{});
    defer got.deinit();
    try testing.expectEqual(8, got.value.messages.len);
    for (got.value.messages) |m| {
        if (!std.mem.eql(u8, m.data, "e")) try plain.ack(&.{m.ack_id});
    }
    try testing.expectEqual(1, b.fake.outstanding("p", "plain"));
    try plain.seek(.{ .time = at(0) });
    try testing.expectEqual(1, b.fake.backlog("p", "plain"));
    try testing.expectEqual(0, b.fake.outstanding("p", "plain"));
    // Its ack from before the seek is answered and forgotten.
    try plain.ack(&.{got.value.messages[4].ack_id});
    try expectPulled(plain, &.{"e"}, false);
    // And a seek to after it acknowledges it.
    try plain.seek(.{ .time = at(111) });
    try testing.expectEqual(0, b.fake.backlog("p", "plain"));

    // A subscription retains what it was there to get. One made now, that
    // retains what is acknowledged, has nothing from before it was made;
    // of what comes after, it has again what it acknowledged.
    const newcomer = b.client.subscription("newcomer");
    var newcomer_made = try newcomer.create(.{ .topic_id = "orders", .retain_acked_messages = true });
    newcomer_made.deinit();
    try newcomer.seek(.{ .time = at(0) });
    try testing.expectEqual(0, b.fake.backlog("p", "newcomer"));
    var later = try topic.publish(&.{.{ .data = "i" }}, .{});
    later.deinit();
    try expectPulled(newcomer, &.{"i"}, true);
    try newcomer.seek(.{ .time = at(0) });
    try expectPulled(newcomer, &.{"i"}, true);

    // A seek gives a subscription its messages afresh: their deliveries
    // are counted from one again. (The fake's own choice: production was
    // not asked.)
    const counted = b.client.subscription("counted");
    var counted_made = try counted.create(.{ .topic_id = "orders", .dead_letter_policy = .{ .topic = "orders" } });
    counted_made.deinit();
    var j = try topic.publish(&.{.{ .data = "j" }}, .{});
    j.deinit();
    for (1..4) |attempt| {
        var counted_got = try counted.pull(.{});
        defer counted_got.deinit();
        try testing.expectEqual(attempt, counted_got.value.messages[0].delivery_attempt);
        try counted.nack(&.{counted_got.value.messages[0].ack_id});
    }
    try counted.seek(.{ .time = at(0) });
    var afresh = try counted.pull(.{});
    defer afresh.deinit();
    try testing.expectEqual(1, afresh.value.messages[0].delivery_attempt);
}

test "a topic that retains messages: its subscriptions read how long, and seek back into it, to before they were made" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-keep","messageRetentionDuration":"600s"}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-keep", "{\"messageRetentionDuration\":\"600s\"}")).body);
    // Production's answer, 2026-10-10.
    const kept_body =
        \\{"name":"projects/p/subscriptions/zigps-kept","topic":"projects/p/topics/zigps-keep","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"topicMessageRetentionDuration":"600s","state":"ACTIVE"}
    ;
    try testing.expectEqualStrings(kept_body, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-kept", "{\"topic\":\"projects/p/topics/zigps-keep\"}")).body);
    try testing.expectEqualStrings(kept_body, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-kept", "")).body);
    const kept = b.client.subscription("zigps-kept");
    const topic = b.client.topic("zigps-keep");
    b.advance(50);
    var sent = try topic.publish(&.{ .{ .data = "k1", .attributes = &.{.{ .key = "kind", .value = "order" }} }, .{ .data = "k2" } }, .{});
    sent.deinit();
    try expectPulled(kept, &.{ "k1", "k2" }, true);

    // Acknowledged, they are kept by the topic alone, and a seek back
    // brings them.
    try kept.seek(.{ .time = .{ .nanoseconds = 0 } });
    try expectPulled(kept, &.{ "k1", "k2" }, true);

    // A subscription made after them has nothing, until it seeks back to
    // before it was made: then it has what its filter passes of them.
    b.advance(10);
    const late = b.client.subscription("zigps-late");
    var late_made = try late.create(.{ .topic_id = "zigps-keep", .filter = "attributes:kind" });
    defer late_made.deinit();
    try testing.expectEqual(std.Io.Duration.fromSeconds(600), late_made.value.topic_message_retention.?);
    try expectNothing(late);
    try late.seek(.{ .time = .{ .nanoseconds = 0 } });
    try expectPulled(late, &.{"k1"}, true);
    // A seek to after them brings nothing.
    try late.seek(.{ .time = .{ .nanoseconds = 51 * std.time.ns_per_s } });
    try testing.expectEqual(0, b.fake.backlog("p", "zigps-late"));

    // The topic keeps them ten minutes, and to the second.
    b.advance(600 - 11);
    try kept.seek(.{ .time = .{ .nanoseconds = 0 } });
    try testing.expectEqual(2, b.fake.backlog("p", "zigps-kept"));
    try expectPulled(kept, &.{ "k1", "k2" }, true);
    b.advance(1);
    try kept.seek(.{ .time = .{ .nanoseconds = 0 } });
    try testing.expectEqual(0, b.fake.backlog("p", "zigps-kept"));

    // How long is the topic's to say: changed there, or taken away, the
    // subscription reads what the topic now has.
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/topics/zigps-keep", "{\"topic\":{\"messageRetentionDuration\":\"1200s\"},\"updateMask\":\"messageRetentionDuration\"}")).status);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-kept", "")).body, "\"topicMessageRetentionDuration\":\"1200s\",\"state\"") != null);
    try kept.seek(.{ .time = .{ .nanoseconds = 0 } });
    try testing.expectEqual(2, b.fake.backlog("p", "zigps-kept"));
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/topics/zigps-keep", "{\"topic\":{},\"updateMask\":\"messageRetentionDuration\"}")).status);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-kept", "")).body, "topicMessageRetentionDuration") == null);
    // The two it holds, unacknowledged, it still has.
    try kept.seek(.{ .time = .{ .nanoseconds = 0 } });
    try testing.expectEqual(2, b.fake.backlog("p", "zigps-kept"));
    try expectPulled(kept, &.{ "k1", "k2" }, true);
    try kept.seek(.{ .time = .{ .nanoseconds = 0 } });
    try testing.expectEqual(0, b.fake.backlog("p", "zigps-kept"));
    // Deleted, the topic says nothing of it.
    try testing.expectEqual(200, (try b.raw(a, .PATCH, "projects/p/topics/zigps-keep", "{\"topic\":{\"messageRetentionDuration\":\"600s\"},\"updateMask\":\"messageRetentionDuration\"}")).status);
    try topic.delete();
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-kept", "")).body, "\"topic\":\"_deleted-topic_\",\"pushConfig\":{},\"ackDeadlineSeconds\":10,\"messageRetentionDuration\":\"604800s\",\"expirationPolicy\":{\"ttl\":\"2678400s\"},\"state\"") != null);
}

test "detach: the subscription lets go of what it holds, gets nothing more, and refuses all but a read, an update and a delete" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const topic = b.client.topic("zigps-t");
    var topic_made = try topic.create(.{});
    topic_made.deinit();
    const plain = b.client.subscription("zigps-plain");
    for ([_][]const u8{ "zigps-plain", "zigps-s" }) |id| {
        var made = try b.client.subscription(id).create(.{ .topic_id = "zigps-t" });
        made.deinit();
    }
    var sent = try topic.publish(&.{ .{ .data = "z1" }, .{ .data = "z2" } }, .{});
    sent.deinit();
    var held = try plain.pull(.{ .max_messages = 1 });
    defer held.deinit();
    const words = "This method is not supported on detached subscriptions.";

    // Production's answers, 2026-10-10.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/zigps-plain:detach", "")).body);
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/zigps-plain:detach", ""), 400, "FAILED_PRECONDITION", words);
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/zigps-nope:detach", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    // It reads as detached, with its topic's name still.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-plain","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"detached":true,"state":"ACTIVE"}
    , (try b.raw(a, .GET, "projects/p/subscriptions/zigps-plain", "")).body);
    // What it held is gone, and what is published does not reach it.
    try testing.expectEqual(0, b.fake.backlog("p", "zigps-plain"));
    var more = try topic.publish(&.{.{ .data = "z3" }}, .{});
    more.deinit();
    try testing.expectEqual(0, b.fake.backlog("p", "zigps-plain"));
    try testing.expectEqual(3, b.fake.backlog("p", "zigps-s"));
    // A pull, an ack, a lease change, a seek and a snapshot of it are
    // refused in detach's words. (Production took seven seconds to; the
    // fake refuses at once.)
    const id = held.value.messages[0].ack_id;
    for ([_]struct { []const u8, []const u8 }{
        .{ ":pull", "{\"maxMessages\":1}" },
        .{ ":acknowledge", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"]}}", .{id}) },
        .{ ":modifyAckDeadline", try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\"],\"ackDeadlineSeconds\":30}}", .{id}) },
        .{ ":seek", "{\"time\":\"1970-01-01T00:00:00Z\"}" },
    }) |call| {
        try expectRefused(try b.raw(a, .POST, try std.fmt.allocPrint(a, "projects/p/subscriptions/zigps-plain{s}", .{call[0]}), call[1]), 400, "FAILED_PRECONDITION", words);
    }
    try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/zigps-ofdetached", "{\"subscription\":\"projects/p/subscriptions/zigps-plain\"}"), 400, "FAILED_PRECONDITION", words);
    try testing.expectError(error.FailedPrecondition, plain.pull(.{}));
    // It is its topic's no longer, and still the project's.
    try testing.expectEqualStrings("{\"subscriptions\":[\"projects/p/subscriptions/zigps-s\"]}", (try b.raw(a, .GET, "projects/p/topics/zigps-t/subscriptions", "")).body);
    var all = try b.client.listSubscriptions(.{});
    defer all.deinit();
    try testing.expectEqual(2, all.value.subscriptions.len);
    try testing.expect(all.value.subscriptions[0].detached);
    try testing.expect(!all.value.subscriptions[1].detached);

    // An update is taken. Its answer leaves `detached` out, as
    // production's did, though a read right after says it.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-plain","topic":"projects/p/topics/zigps-t","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":20,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-plain", "{\"subscription\":{\"ackDeadlineSeconds\":20},\"updateMask\":\"ackDeadlineSeconds\"}")).body);
    var read = try plain.get();
    defer read.deinit();
    try testing.expect(read.value.detached);
    try testing.expectEqual(20, read.value.ack_deadline_seconds);

    // Deleted, its name is free, and one made under it is attached.
    try plain.delete();
    var again = try plain.create(.{ .topic_id = "zigps-t" });
    defer again.deinit();
    try testing.expect(!again.value.detached);
    var last = try topic.publish(&.{.{ .data = "z4" }}, .{});
    last.deinit();
    try testing.expectEqual(1, b.fake.backlog("p", "zigps-plain"));

    // Through the client, with the answer lost on the way back: its
    // retry is refused, as a second detach is, so it reads the
    // subscription, finds it detached, and has done what was asked.
    b.fake.loseAnswers(1, .admin);
    try b.client.subscription("zigps-s").detach();
    var other = try b.client.subscription("zigps-s").get();
    defer other.deinit();
    try testing.expect(other.value.detached);
    try testing.expectEqual(0, b.fake.backlog("p", "zigps-s"));
    try testing.expectError(error.FailedPrecondition, b.client.subscription("zigps-s").detach());

    // With exactly-once delivery it reads `detached` before that, the
    // order of the fields' numbers, which production's answers follow.
    var once = try b.client.subscription("zigps-once").create(.{ .topic_id = "zigps-t", .enable_exactly_once_delivery = true });
    once.deinit();
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, "projects/p/subscriptions/zigps-once:detach", "")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-once","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"detached":true,"enableExactlyOnceDelivery":true,"state":"ACTIVE"}
    , (try b.raw(a, .GET, "projects/p/subscriptions/zigps-once", "")).body);
}

test "ids of one request: each is judged as the request finds it, before any of them acts" {
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false });
    defer b.deinit();
    for ([_][]const u8{ "orders", "dead" }) |id| {
        var made = try b.client.topic(id).create(.{});
        made.deinit();
    }
    const worker = b.client.subscription("worker");
    var worker_made = try worker.create(.{ .topic_id = "orders", .enable_message_ordering = true, .dead_letter_policy = .{ .topic = "dead" } });
    worker_made.deinit();
    var morgue_made = try b.client.subscription("morgue").create(.{ .topic_id = "dead" });
    morgue_made.deinit();

    // Two of a key nacked in one request, as production took them: the
    // nack of the first takes the second back with it, and the second's
    // own nack comes no later for that. Each is counted as given back, so
    // that after five rounds both have had their attempts, and both move
    // to the dead-letter topic.
    var pair = try b.client.topic("orders").publish(&.{ .{ .data = "q1" }, .{ .data = "q2" } }, .{ .ordering_key = "q" });
    pair.deinit();
    for (1..6) |attempt| {
        try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
        var got = try worker.pull(.{});
        defer got.deinit();
        try testing.expectEqual(2, got.value.messages.len);
        for (got.value.messages, [_][]const u8{ "q1", "q2" }) |m, data| {
            try testing.expectEqualStrings(data, m.data);
            try testing.expectEqual(attempt, m.delivery_attempt);
        }
        // The first id a second time changes nothing.
        try worker.nack(&.{ got.value.messages[0].ack_id, got.value.messages[1].ack_id, got.value.messages[0].ack_id });
        try testing.expectEqual(0, b.fake.outstanding("p", "worker"));
    }
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(2, b.fake.backlog("p", "morgue"));
}

/// A stand-in for reading schemas, for `Options.fits`: a message fits a
/// revision when its data is written somewhere in the revision's
/// definition. It says why not in words production used, and keeps count
/// of what it was asked.
const Judge = struct {
    asked: usize = 0,
    last_revision: [8]u8 = @splat(' '),
    last_schema_len: usize = 0,

    fn fits(j: *Judge) FakePubSub.Fits {
        return .{ .context = j, .call = call };
    }

    fn call(context: ?*anyopaque, check: FakePubSub.SchemaCheck) ?[]const u8 {
        const j: *Judge = @ptrCast(@alignCast(context.?));
        j.asked += 1;
        j.last_schema_len = check.schema.len;
        if (check.revision_id.len == 8) j.last_revision = check.revision_id[0..8].*;
        if (check.data.len == 0) return "Tried to parse invalid JSON.";
        if (std.mem.indexOf(u8, check.definition, check.data) != null) return null;
        return switch (check.encoding) {
            .json => "JSON object with type string does not match schema which expected number_integer.",
            .binary => if (check.type == .avro) "Invalid length: -62." else "Could not parse binary message.",
        };
    }
};

const two_fields = "{\"type\": \"record\", \"name\": \"M\", \"fields\": [{\"name\": \"name\", \"type\": \"string\"}, {\"name\": \"age\", \"type\": \"int\"}]}";
const three_fields = "{\"type\": \"record\", \"name\": \"M\", \"fields\": [{\"name\": \"name\", \"type\": \"string\"}, {\"name\": \"age\", \"type\": \"int\"}, {\"name\": \"note\", \"type\": \"string\", \"default\": \"\"}]}";

/// A schema as a request gives one: its type, and its definition as the
/// JSON string it is.
fn schemaBody(a: Allocator, kind: []const u8, definition: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"type\":\"{s}\",\"definition\":{s}}}", .{ kind, try Stringify.valueAlloc(a, definition, .{}) });
}

/// The `revisionId` of a schema in an answer.
fn revisionOf(a: Allocator, body: []const u8) ![]const u8 {
    const Shape = struct { revisionId: []const u8 };
    return (try std.json.parseFromSliceLeaky(Shape, a, body, .{ .ignore_unknown_fields = true })).revisionId;
}

test "schemas: made, read, listed and deleted, as production answers" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    b.advance(39);
    const quoted = try Stringify.valueAlloc(a, two_fields, .{});

    // Production's answer, 2026-10-12, in the order it writes the fields.
    // A revision's id is eight hex digits.
    const made = (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-avro", try schemaBody(a, "AVRO", two_fields))).body;
    const first = try revisionOf(a, made);
    try testing.expectEqual(8, first.len);
    for (first) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    const whole = try std.fmt.allocPrint(a, "{{\"name\":\"projects/p/schemas/zigps-avro\",\"type\":\"AVRO\",\"definition\":{s},\"revisionId\":\"{s}\",\"revisionCreateTime\":\"1970-01-01T00:00:39Z\"}}", .{ quoted, first });
    const basic = try std.fmt.allocPrint(a, "{{\"name\":\"projects/p/schemas/zigps-avro\",\"type\":\"AVRO\",\"revisionId\":\"{s}\",\"revisionCreateTime\":\"1970-01-01T00:00:39Z\"}}", .{first});
    try testing.expectEqualStrings(whole, made);
    // A get with no view answers the whole of it; a list does not.
    try testing.expectEqualStrings(whole, (try b.raw(a, .GET, "projects/p/schemas/zigps-avro", "")).body);
    try testing.expectEqualStrings(whole, (try b.raw(a, .GET, "projects/p/schemas/zigps-avro?view=FULL", "")).body);
    try testing.expectEqualStrings(basic, (try b.raw(a, .GET, "projects/p/schemas/zigps-avro?view=BASIC", "")).body);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{{\"schemas\":[{s}]}}", .{basic}), (try b.raw(a, .GET, "projects/p/schemas", "")).body);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{{\"schemas\":[{s}]}}", .{whole}), (try b.raw(a, .GET, "projects/p/schemas?view=FULL&pageSize=5", "")).body);
    try testing.expectEqual(400, (try b.raw(a, .GET, "projects/p/schemas?view=EVERYTHING", "")).status);
    // Named with its revision, it reads under that name.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"name\":\"projects/p/schemas/zigps-avro@{s}\",\"type\":\"AVRO\",\"definition\":{s},\"revisionId\":\"{s}\",\"revisionCreateTime\":\"1970-01-01T00:00:39Z\"}}", .{ first, quoted, first }),
        (try b.raw(a, .GET, try std.fmt.allocPrint(a, "projects/p/schemas/zigps-avro@{s}?view=FULL", .{first}), "")).body,
    );

    // What a create refuses, in production's words. A schema that is
    // there, or not, is named whole, where a topic is named by its id.
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-avro", try schemaBody(a, "AVRO", two_fields)), 409, "ALREADY_EXISTS", "Resource already exists in the project (resource=projects/p/schemas/zigps-avro).");
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas", "{\"name\":\"projects/p/schemas/zigps-x\",\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\"}"), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=projects/p/schemas/). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    for ([_]struct { []const u8, []const u8 }{ .{ "ab", "ab" }, .{ "1abc", "1abc" }, .{ "goog-x", "goog-x" }, .{ "a%20b", "a b" }, .{ "a%2Fb", "a/b" }, .{ "a%40b", "a@b" } }) |id| {
        try expectRefused(
            try b.raw(a, .POST, try std.fmt.allocPrint(a, "projects/p/schemas?schemaId={s}", .{id[0]}), try schemaBody(a, "AVRO", two_fields)),
            400,
            "INVALID_ARGUMENT",
            try std.fmt.allocPrint(a, "Invalid resource name given (name=projects/p/schemas/{s}). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.", .{id[1]}),
        );
    }
    for ([_][]const u8{ "{\"definition\":\"\\\"string\\\"\"}", "{\"type\":\"TYPE_UNSPECIFIED\",\"definition\":\"\\\"string\\\"\"}" }) |body| {
        try expectRefused(try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-bad", body), 400, "INVALID_ARGUMENT", "The schema's type must be specified.");
    }
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-bad", "{\"type\":\"AVRO\"}"), 400, "INVALID_ARGUMENT", "Invalid schema definition: Avro schema did not specify a text definition: .");
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-bad", "{\"type\":\"AVRO\",\"definition\":\"{nope\"}"), 400, "INVALID_ARGUMENT", "AVRO schema definition is not valid: Tried to parse invalid JSON.");
    try testing.expectEqual(400, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-bad", "{\"type\":\"THRIFT\",\"definition\":\"x\"}")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/schemas/zigps-bad", "")).status);
    // Production took 307,200 bytes of definition, and no more.
    const most = try a.alloc(u8, 307_200);
    @memset(most, 'x');
    most[0] = '"';
    most[most.len - 1] = '"';
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-most", try schemaBody(a, "AVRO", most))).status);
    const over = try a.alloc(u8, 307_201);
    @memset(over, 'x');
    over[0] = '"';
    over[over.len - 1] = '"';
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-over", try schemaBody(a, "AVRO", over)), 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
    // An Avro definition is JSON, and one word of it will do. A Protocol
    // Buffer one is kept as text, and not read: production refused this
    // one, which does not parse.
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-word", "{\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\"}")).status);
    try testing.expect(std.mem.startsWith(u8, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-proto", "{\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"message {\"}")).body,
        \\{"name":"projects/p/schemas/zigps-proto","type":"PROTOCOL_BUFFER","definition":"message {","revisionId":"
    ));

    // One that is not there, by its name or by a revision of it.
    try expectRefused(try b.raw(a, .GET, "projects/p/schemas/zigps-absent", ""), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-absent).");
    try expectRefused(try b.raw(a, .GET, "projects/p/schemas/zigps-avro@deadbeef", ""), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-avro@deadbeef).");
    // The `@` sent as `%40` production does not read as one.
    try expectRefused(try b.raw(a, .GET, try std.fmt.allocPrint(a, "projects/p/schemas/zigps-avro%40{s}?view=BASIC", .{first}), ""), 404, "NOT_FOUND", try std.fmt.allocPrint(a, "Resource not found (resource=projects/p/schemas/zigps-avro%40{s}).", .{first}));

    // Through the client, and in pages, by name.
    var created = try b.client.schema("orders-v1").create(.{ .type = .protocol_buffer, .definition = "syntax = \"proto3\";\nmessage M {\n  string name = 1;\n}\n" });
    defer created.deinit();
    try testing.expectEqualStrings("projects/p/schemas/orders-v1", created.value.name);
    try testing.expectEqual(types.SchemaType.protocol_buffer, created.value.type);
    try testing.expectEqualStrings("syntax = \"proto3\";\nmessage M {\n  string name = 1;\n}\n", created.value.definition);
    try testing.expectEqual(std.Io.Timestamp{ .nanoseconds = 39 * std.time.ns_per_s }, created.value.revision_create_time.?);
    var read = try b.client.schema("orders-v1").get(.{ .view = .basic });
    defer read.deinit();
    try testing.expectEqualStrings("", read.value.definition);
    try testing.expectEqualStrings(created.value.revision_id, read.value.revision_id);
    var page = try b.client.listSchemas(.{ .page = .{ .page_size = 2 } });
    defer page.deinit();
    try testing.expectEqual(2, page.value.schemas.len);
    try testing.expectEqualStrings("projects/p/schemas/orders-v1", page.value.schemas[0].name);
    try testing.expectEqualStrings("projects/p/schemas/zigps-avro", page.value.schemas[1].name);
    var rest = try b.client.listSchemas(.{ .page = .{ .page_size = 2, .page_token = page.value.next_page_token.? }, .view = .full });
    defer rest.deinit();
    try testing.expectEqualStrings("projects/p/schemas/zigps-most", rest.value.schemas[0].name);
    try testing.expectEqual(307_200, rest.value.schemas[0].definition.len);

    // Deleted, it is gone, and its id is free: one made under it is new.
    try testing.expectEqualStrings("{}", (try b.raw(a, .DELETE, "projects/p/schemas/zigps-avro", "")).body);
    try expectRefused(try b.raw(a, .DELETE, "projects/p/schemas/zigps-avro", ""), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-avro).");
    try testing.expectError(error.NotFound, b.client.schema("zigps-avro").get(.{}));
    const again = (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-avro", try schemaBody(a, "AVRO", two_fields))).body;
    try testing.expect(!std.mem.eql(u8, first, try revisionOf(a, again)));
    try b.client.schema("orders-v1").delete();
    try testing.expectError(error.NotFound, b.client.schema("orders-v1").delete());
}

test "schema revisions: committed, rolled back, deleted and listed, with production's rules for each" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const name = "projects/p/schemas/zigps-rev";
    const r1 = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-rev", try schemaBody(a, "AVRO", two_fields))).body);
    b.advance(4);
    const commit = try std.fmt.allocPrint(a, "{{\"schema\":{{\"name\":\"{s}\",\"type\":\"AVRO\",\"definition\":{s}}}}}", .{ name, try Stringify.valueAlloc(a, three_fields, .{}) });

    // A commit answers the new revision, under its own name.
    const second = (try b.raw(a, .POST, "projects/p/schemas/zigps-rev:commit", commit)).body;
    const r2 = try revisionOf(a, second);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"name\":\"{s}@{s}\",\"type\":\"AVRO\",\"definition\":{s},\"revisionId\":\"{s}\",\"revisionCreateTime\":\"1970-01-01T00:00:04Z\"}}", .{ name, r2, try Stringify.valueAlloc(a, three_fields, .{}), r2 }),
        second,
    );
    // The definition the schema already has makes one more revision.
    const r3 = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas/zigps-rev:commit", commit)).body);
    try testing.expect(!std.mem.eql(u8, r2, r3) and !std.mem.eql(u8, r1, r3) and !std.mem.eql(u8, r1, r2));

    // Production commits to the schema the body names, whatever the path
    // says, and refuses a body that names none.
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-other", try schemaBody(a, "AVRO", two_fields))).status);
    const elsewhere = (try b.raw(a, .POST, "projects/p/schemas/zigps-other:commit", commit)).body;
    try testing.expect(std.mem.startsWith(u8, elsewhere, "{\"name\":\"projects/p/schemas/zigps-rev@"));
    const r4 = try revisionOf(a, elsewhere);
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas/zigps-rev:commit", try std.fmt.allocPrint(a, "{{\"schema\":{s}}}", .{try schemaBody(a, "AVRO", three_fields)})), 400, "INVALID_ARGUMENT", "Invalid resource name given (name=). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information.");
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas/zigps-absent:commit", "{\"schema\":{\"name\":\"projects/p/schemas/zigps-absent\",\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\"}}"), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-absent).");
    // A revision of another type is refused against the one before it,
    // in production's words, its unclosed quote and all. A definition
    // that does not read is refused as on a create.
    try expectRefused(
        try b.raw(a, .POST, "projects/p/schemas/zigps-rev:commit", "{\"schema\":{\"name\":\"" ++ name ++ "\",\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"syntax = \\\"proto3\\\";\"}}"),
        400,
        "FAILED_PRECONDITION",
        try std.fmt.allocPrint(a, "Compatibility checking failed to commit a schema revision for (schema=\"{s}\"). (reason=\"Revision is incompatible with previous revision: {s}. Failed with error: Types do not match). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.", .{ name, r4 }),
    );
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas/zigps-rev:commit", "{\"schema\":{\"name\":\"" ++ name ++ "\",\"type\":\"AVRO\",\"definition\":\"{nope\"}}"), 400, "INVALID_ARGUMENT", "AVRO schema definition is not valid: Tried to parse invalid JSON.");

    // Its revisions, the newest first, each under its own name, with no
    // definition unless asked; in pages.
    const Listed = struct { schemas: []const struct { name: []const u8, revisionId: []const u8, definition: []const u8 = "" }, nextPageToken: []const u8 = "" };
    const listed = try std.json.parseFromSliceLeaky(Listed, a, (try b.raw(a, .GET, "projects/p/schemas/zigps-rev:listRevisions", "")).body, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(4, listed.schemas.len);
    for (listed.schemas, [_][]const u8{ r4, r3, r2, r1 }) |entry, id| {
        try testing.expectEqualStrings(id, entry.revisionId);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}@{s}", .{ name, id }), entry.name);
        try testing.expectEqualStrings("", entry.definition);
    }
    var token: []const u8 = "";
    for ([_][]const u8{ r4, r3, r2, r1 }, 0..) |id, i| {
        const one = try std.json.parseFromSliceLeaky(Listed, a, (try b.raw(a, .GET, try std.fmt.allocPrint(a, "projects/p/schemas/zigps-rev:listRevisions?view=FULL&pageSize=1&pageToken={s}", .{token}), "")).body, .{ .ignore_unknown_fields = true });
        try testing.expectEqual(1, one.schemas.len);
        try testing.expectEqualStrings(id, one.schemas[0].revisionId);
        try testing.expectEqualStrings(if (i == 3) two_fields else three_fields, one.schemas[0].definition);
        // The last page has no token.
        try testing.expectEqual(i == 3, one.nextPageToken.len == 0);
        token = one.nextPageToken;
    }
    try expectRefused(try b.raw(a, .GET, "projects/p/schemas/zigps-absent:listRevisions", ""), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-absent).");
    // By its bare name a schema reads as its latest revision, and a
    // project's list holds it as that one.
    try testing.expectEqualStrings(r4, try revisionOf(a, (try b.raw(a, .GET, "projects/p/schemas/zigps-rev", "")).body));
    const of_project = try std.json.parseFromSliceLeaky(Listed, a, (try b.raw(a, .GET, "projects/p/schemas?view=FULL", "")).body, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(2, of_project.schemas.len);
    try testing.expectEqualStrings(name, of_project.schemas[1].name);
    try testing.expectEqualStrings(r4, of_project.schemas[1].revisionId);
    try testing.expectEqualStrings(three_fields, of_project.schemas[1].definition);

    // A rollback makes a new revision that holds the old definition.
    b.advance(1);
    const back = (try b.raw(a, .POST, "projects/p/schemas/zigps-rev:rollback", try std.fmt.allocPrint(a, "{{\"revisionId\":\"{s}\"}}", .{r1}))).body;
    const r5 = try revisionOf(a, back);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"name\":\"{s}@{s}\",\"type\":\"AVRO\",\"definition\":{s},\"revisionId\":\"{s}\",\"revisionCreateTime\":\"1970-01-01T00:00:05Z\"}}", .{ name, r5, try Stringify.valueAlloc(a, two_fields, .{}), r5 }),
        back,
    );
    // To one that is not there, production names the schema; to the
    // latest, it refuses.
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas/zigps-rev:rollback", "{\"revisionId\":\"deadbeef\"}"), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-rev).");
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas/zigps-absent:rollback", "{\"revisionId\":\"deadbeef\"}"), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-absent).");
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas/zigps-rev:rollback", try std.fmt.allocPrint(a, "{{\"revisionId\":\"{s}\"}}", .{r5})), 400, "FAILED_PRECONDITION", "Cannot rollback to the latest revision: (schema=\"projects/p/schemas/zigps-rev\"). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.");

    // A revision deleted is answered without its definition. Then it is
    // gone, to a second delete and to a read.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"name\":\"{s}@{s}\",\"type\":\"AVRO\",\"revisionId\":\"{s}\",\"revisionCreateTime\":\"1970-01-01T00:00:04Z\"}}", .{ name, r2, r2 }),
        (try b.raw(a, .DELETE, try std.fmt.allocPrint(a, "projects/p/schemas/zigps-rev@{s}:deleteRevision", .{r2}), "")).body,
    );
    for ([_]tp.Method{ .DELETE, .GET }) |method| {
        try expectRefused(try b.raw(a, method, try std.fmt.allocPrint(a, "projects/p/schemas/zigps-rev@{s}{s}", .{ r2, if (method == .DELETE) ":deleteRevision" else "" }), ""), 404, "NOT_FOUND", try std.fmt.allocPrint(a, "Resource not found (resource={s}@{s}).", .{ name, r2 }));
    }
    try testing.expectEqual(4, std.mem.count(u8, (try b.raw(a, .GET, "projects/p/schemas/zigps-rev:listRevisions", "")).body, "\"revisionId\""));
    // The revision goes in the path: with none there, production refuses.
    for ([_][]const u8{ "projects/p/schemas/zigps-rev:deleteRevision", "projects/p/schemas/zigps-rev:deleteRevision?revisionId=deadbeef" }) |path| {
        try expectRefused(try b.raw(a, .DELETE, path, ""), 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
    }
    // A schema's only revision goes with the schema, and no other way.
    const only = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-one", try schemaBody(a, "AVRO", two_fields))).body);
    try expectRefused(
        try b.raw(a, .DELETE, try std.fmt.allocPrint(a, "projects/p/schemas/zigps-one@{s}:deleteRevision", .{only}), ""),
        400,
        "FAILED_PRECONDITION",
        try std.fmt.allocPrint(a, "This schema contains only one revision, which can only be deleted by deleting the parent schema: (schema=\"projects/p/schemas/zigps-one@{s}\"). Refer to https://cloud.google.com/pubsub/docs/schemas for more information.", .{only}),
    );

    // A schema holds twenty revisions: the twenty-first is refused, by a
    // commit and by a rollback, until one is deleted.
    const twenty = b.client.schema("zigps-twenty");
    var first_of_twenty = try twenty.create(.{ .type = .avro, .definition = "\"string\"" });
    defer first_of_twenty.deinit();
    for (0..19) |_| {
        var more = try twenty.commit(.{ .type = .avro, .definition = "\"string\"" });
        more.deinit();
    }
    try expectRefused(try b.raw(a, .POST, "projects/p/schemas/zigps-twenty:commit", "{\"schema\":{\"name\":\"projects/p/schemas/zigps-twenty\",\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\"}}"), 429, "RESOURCE_EXHAUSTED", "You have exceeded your revisions per schema quota (schema=\"projects/p/schemas/zigps-twenty\"). Refer to https://cloud.google.com/pubsub/quotas for more information.");
    try testing.expectError(error.ResourceExhausted, twenty.rollback(first_of_twenty.value.revision_id));
    try twenty.deleteRevision(first_of_twenty.value.revision_id);
    var one_more = try twenty.commit(.{ .type = .avro, .definition = "\"string\"" });
    defer one_more.deinit();
    var revisions = try twenty.listRevisions(.{});
    defer revisions.deinit();
    try testing.expectEqual(20, revisions.value.schemas.len);
    try testing.expectEqualStrings(one_more.value.revision_id, revisions.value.schemas[0].revision_id);
}

test "validate and validateMessage: a definition is checked as far as the fake reads one, and whether a message fits is the test's to say" {
    var judge: Judge = .{};
    var b: Bench = undefined;
    try b.init(.{ .fits = judge.fits() });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const validate = "projects/p/schemas:validate";
    const message = "projects/p/schemas:validateMessage";

    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, validate, try std.fmt.allocPrint(a, "{{\"schema\":{s}}}", .{try schemaBody(a, "AVRO", two_fields)}))).body);
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, validate, "{\"schema\":{\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"syntax = \\\"proto3\\\";\\nmessage M { string name = 1; }\\n\"}}")).body);
    try expectRefused(try b.raw(a, .POST, validate, "{\"schema\":{\"type\":\"AVRO\",\"definition\":\"{nope\"}}"), 400, "INVALID_ARGUMENT", "AVRO schema definition is not valid: Tried to parse invalid JSON.");
    try expectRefused(try b.raw(a, .POST, validate, "{\"schema\":{\"definition\":\"\\\"string\\\"\"}}"), 400, "INVALID_ARGUMENT", "The schema's type must be specified.");
    try expectRefused(try b.raw(a, .POST, validate, "{}"), 400, "INVALID_ARGUMENT", "The schema's type must be specified.");
    try testing.expectEqual(0, judge.asked);
    // Nothing is kept of a schema that was only looked at.
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, "projects/p/schemas", "")).body);

    const r1 = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-avro", try schemaBody(a, "AVRO", two_fields))).body);
    const r2 = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas/zigps-avro:commit", try std.fmt.allocPrint(a, "{{\"schema\":{{\"name\":\"projects/p/schemas/zigps-avro\",\"type\":\"AVRO\",\"definition\":{s}}}}}", .{try Stringify.valueAlloc(a, three_fields, .{})}))).body);
    // A method on all schemas takes no id after it.
    try expectRefused(try b.raw(a, .GET, "projects/p/schemas:validate/zigps-avro", ""), 404, "NOT_FOUND", "fake: no such route");
    const named = "\"name\":\"projects/p/schemas/zigps-avro\"";
    // "age" is in both revisions: the newest is asked, and that is all.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, message, "{" ++ named ++ ",\"message\":\"YWdl\",\"encoding\":\"JSON\"}")).body);
    try testing.expectEqual(1, judge.asked);
    try testing.expectEqualStrings(r2, &judge.last_revision);
    // "int\"}]" ends the first alone: the newest is asked, then the older.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, message, "{" ++ named ++ ",\"message\":\"aW50In1d\",\"encoding\":\"BINARY\"}")).body);
    try testing.expectEqual(3, judge.asked);
    try testing.expectEqualStrings(r1, &judge.last_revision);
    // One that fits none is refused in production's body, with the
    // reason its type and its encoding give.
    try testing.expectEqualStrings(
        \\{"error":{"code":400,"message":"Invalid data in message: JSON object with type string does not match schema which expected number_integer.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"INVALID_JSON_AVRO_MESSAGE","domain":"pubsub.googleapis.com"}]}}
    , (try b.raw(a, .POST, message, "{" ++ named ++ ",\"message\":\"b25l\",\"encoding\":\"JSON\"}")).body);
    try testing.expectEqualStrings(
        \\{"error":{"code":400,"message":"Invalid data in message: Invalid length: -62.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"INVALID_BINARY_AVRO_MESSAGE","domain":"pubsub.googleapis.com"}]}}
    , (try b.raw(a, .POST, message, "{" ++ named ++ ",\"message\":\"b25l\",\"encoding\":\"BINARY\"}")).body);

    // Against one revision, named after an `@`.
    judge.asked = 0;
    try testing.expectEqual(400, (try b.raw(a, .POST, message, try std.fmt.allocPrint(a, "{{\"name\":\"projects/p/schemas/zigps-avro@{s}\",\"message\":\"bm90ZQ==\",\"encoding\":\"JSON\"}}", .{r1}))).status);
    try testing.expectEqual(200, (try b.raw(a, .POST, message, try std.fmt.allocPrint(a, "{{\"name\":\"projects/p/schemas/zigps-avro@{s}\",\"message\":\"bm90ZQ==\",\"encoding\":\"JSON\"}}", .{r2}))).status);
    try testing.expectEqual(2, judge.asked);
    try expectRefused(try b.raw(a, .POST, message, "{\"name\":\"projects/p/schemas/zigps-avro@deadbeef\",\"message\":\"YWdl\",\"encoding\":\"JSON\"}"), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-avro@deadbeef).");
    try expectRefused(try b.raw(a, .POST, message, "{\"name\":\"projects/p/schemas/zigps-absent\",\"message\":\"YWdl\",\"encoding\":\"JSON\"}"), 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-absent).");
    try testing.expectEqual(400, (try b.raw(a, .POST, message, "{\"name\":\"zigps-avro\",\"message\":\"YWdl\",\"encoding\":\"JSON\"}")).status);
    // Against a schema given whole, which has no name and no revision.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, message, "{\"schema\":{\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"message M { string name = 1; }\"},\"message\":\"bmFtZQ==\",\"encoding\":\"BINARY\"}")).body);
    try testing.expectEqual(0, judge.last_schema_len);
    try testing.expectEqualStrings(
        \\{"error":{"code":400,"message":"Invalid data in message: Could not parse binary message.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"INVALID_BINARY_PROTO_MESSAGE","domain":"pubsub.googleapis.com"}]}}
    , (try b.raw(a, .POST, message, "{\"schema\":{\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"message M { string name = 1; }\"},\"message\":\"////\",\"encoding\":\"BINARY\"}")).body);
    try expectRefused(try b.raw(a, .POST, message, "{\"schema\":{\"type\":\"AVRO\",\"definition\":\"{nope\"},\"message\":\"YWdl\",\"encoding\":\"JSON\"}"), 400, "INVALID_ARGUMENT", "AVRO schema definition is not valid: Tried to parse invalid JSON.");
    // No encoding, or the one that says none.
    for ([_][]const u8{ "", ",\"encoding\":\"ENCODING_UNSPECIFIED\"" }) |encoding| {
        try expectRefused(try b.raw(a, .POST, message, try std.fmt.allocPrint(a, "{{" ++ named ++ ",\"message\":\"YWdl\"{s}}}", .{encoding})), 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=Invalid message encoding type: ENCODING_UNSPECIFIED).");
    }
    try testing.expectEqual(501, (try b.raw(a, .POST, message, "{\"message\":\"YWdl\",\"encoding\":\"JSON\"}")).status);

    // Through the client. And with nothing to ask, every message fits.
    try b.client.validateSchema(.{ .type = .avro, .definition = two_fields });
    try testing.expectError(error.InvalidArgument, b.client.validateSchema(.{ .type = .avro, .definition = "{nope" }));
    try b.client.schema("zigps-avro").validateMessage("note", .json, null);
    try testing.expectError(error.InvalidArgument, b.client.schema("zigps-avro").validateMessage("note", .json, r1));
    try testing.expectError(error.InvalidArgument, b.client.schema("zigps-avro").validateMessage("one", .json, null));
    try b.client.validateMessage(.{ .type = .avro, .definition = two_fields }, "age", .binary);
    var plain: Bench = undefined;
    try plain.init(.{});
    defer plain.deinit();
    var made = try plain.client.schema("anything").create(.{ .type = .avro, .definition = "\"string\"" });
    made.deinit();
    try plain.client.schema("anything").validateMessage("whatever", .binary, null);
}

test "a topic's schema: its settings as production reads and refuses them, and its messages marked with the revision they fit" {
    var judge: Judge = .{};
    var b: Bench = undefined;
    try b.init(.{ .shuffle = false, .fits = judge.fits() });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r1 = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-avro", try schemaBody(a, "AVRO", two_fields))).body);
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-proto", "{\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"message M { string name = 1; }\"}")).status);
    const avro = "\"schema\":\"projects/p/schemas/zigps-avro\"";

    // Production's answers, 2026-10-12.
    const as_json =
        \\{"name":"projects/p/topics/zigps-json","schemaSettings":{"schema":"projects/p/schemas/zigps-avro","encoding":"JSON"}}
    ;
    try testing.expectEqualStrings(as_json, (try b.raw(a, .PUT, "projects/p/topics/zigps-json", "{\"schemaSettings\":{" ++ avro ++ ",\"encoding\":\"JSON\"}}")).body);
    try testing.expectEqualStrings(as_json, (try b.raw(a, .GET, "projects/p/topics/zigps-json", "")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-pbin","schemaSettings":{"schema":"projects/p/schemas/zigps-proto","encoding":"BINARY"}}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-pbin", "{\"schemaSettings\":{\"schema\":\"projects/p/schemas/zigps-proto\",\"encoding\":\"BINARY\"}}")).body);
    // A range of revisions, in the order production writes the four. The
    // settings come after the key, and before the retention.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"name\":\"projects/p/topics/zigps-range\",\"kmsKeyName\":\"k\",\"schemaSettings\":{{\"schema\":\"projects/p/schemas/zigps-avro\",\"encoding\":\"JSON\",\"firstRevisionId\":\"{s}\",\"lastRevisionId\":\"{s}\"}},\"messageRetentionDuration\":\"600s\"}}", .{ r1, r1 }),
        (try b.raw(a, .PUT, "projects/p/topics/zigps-range", try std.fmt.allocPrint(a, "{{\"messageRetentionDuration\":\"600s\",\"kmsKeyName\":\"k\",\"schemaSettings\":{{" ++ avro ++ ",\"encoding\":\"JSON\",\"firstRevisionId\":\"{s}\",\"lastRevisionId\":\"{s}\"}}}}", .{ r1, r1 }))).body,
    );
    // What a create refuses.
    const both = "Schema settings for the topic projects/p/topics/zigps-bad must include both the name and the encoding.";
    for ([_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ "{" ++ avro ++ "}", 400, "INVALID_ARGUMENT", both },
        .{ "{\"encoding\":\"JSON\"}", 400, "INVALID_ARGUMENT", both },
        .{ "{" ++ avro ++ ",\"encoding\":\"ENCODING_UNSPECIFIED\"}", 400, "INVALID_ARGUMENT", both },
        .{ "{\"schema\":\"projects/p/schemas/zigps-absent\",\"encoding\":\"JSON\"}", 404, "NOT_FOUND", "Resource not found (resource=projects/p/schemas/zigps-absent)." },
        .{ "{\"schema\":\"zigps-avro\",\"encoding\":\"JSON\"}", 400, "INVALID_ARGUMENT", "Invalid resource name given (name=zigps-avro). Refer to https://cloud.google.com/pubsub/docs/pubsub-basics#resource_names for more information." },
        .{ try std.fmt.allocPrint(a, "{{\"schema\":\"projects/p/schemas/zigps-avro@{s}\",\"encoding\":\"JSON\"}}", .{r1}), 400, "INVALID_ARGUMENT", "Request contains an invalid argument." },
        // Production names the schema here by a number of its own, with
        // no space after it. The fake's number is its own too.
        .{ "{" ++ avro ++ ",\"encoding\":\"JSON\",\"firstRevisionId\":\"deadbeef\"}", 404, "NOT_FOUND", "Resource not found (resource=schema_id: 1revision_id: deadbeef)." },
        .{ "{" ++ avro ++ ",\"encoding\":\"JSON\",\"lastRevisionId\":\"deadbeef\"}", 404, "NOT_FOUND", "Resource not found (resource=schema_id: 1revision_id: deadbeef)." },
    }) |case| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-bad", try std.fmt.allocPrint(a, "{{\"schemaSettings\":{s}}}", .{case[0]})), case[1], case[2], case[3]);
    }
    try testing.expectEqual(400, (try b.raw(a, .PUT, "projects/p/topics/zigps-bad", "{\"schemaSettings\":{" ++ avro ++ ",\"encoding\":\"XML\"}}")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/topics/zigps-bad", "")).status);

    // Updates. The settings whole, in either spelling of the mask.
    const patch = "projects/p/topics/zigps-json";
    const as_binary =
        \\{"name":"projects/p/topics/zigps-json","schemaSettings":{"schema":"projects/p/schemas/zigps-avro","encoding":"BINARY"}}
    ;
    try testing.expectEqualStrings(as_binary, (try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{" ++ avro ++ ",\"encoding\":\"BINARY\"}},\"updateMask\":\"schemaSettings\"}")).body);
    // One of them: the rest stays, whatever the body holds beside it.
    try testing.expectEqualStrings(as_json, (try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{\"schema\":\"projects/p/schemas/zigps-proto\",\"encoding\":\"JSON\"}},\"updateMask\":\"schemaSettings.encoding\"}")).body);
    try testing.expectEqualStrings(as_binary, (try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{" ++ avro ++ ",\"encoding\":\"BINARY\"}},\"updateMask\":\"schema_settings\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-json","schemaSettings":{"schema":"projects/p/schemas/zigps-proto","encoding":"BINARY"}}
    , (try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{\"schema\":\"projects/p/schemas/zigps-proto\"}},\"updateMask\":\"schema_settings.schema\"}")).body);
    // A refused update changes nothing.
    try expectRefused(try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{" ++ avro ++ "}},\"updateMask\":\"schemaSettings\"}"), 400, "INVALID_ARGUMENT", "Schema settings for the topic projects/p/topics/zigps-json must include both the name and the encoding.");
    try expectRefused(try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{}},\"updateMask\":\"schemaSettings.encoding\"}"), 400, "INVALID_ARGUMENT", "Schema settings for the topic projects/p/topics/zigps-json must include both the name and the encoding.");
    try testing.expectEqual(400, (try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{}},\"updateMask\":\"schemaSettings.nonsense\"}")).status);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, patch, "")).body, "zigps-proto\",\"encoding\":\"BINARY\"") != null);
    // With none in the body the topic has no schema, and takes one again.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-json\"}", (try b.raw(a, .PATCH, patch, "{\"topic\":{},\"updateMask\":\"schemaSettings\"}")).body);
    try testing.expectEqualStrings(as_json, (try b.raw(a, .PATCH, patch, "{\"topic\":{\"schemaSettings\":{" ++ avro ++ ",\"encoding\":\"JSON\"}},\"updateMask\":\"schemaSettings\"}")).body);

    // Publishing. Two more revisions: the third holds a field the first
    // has not.
    const commit = "{{\"schema\":{{\"name\":\"projects/p/schemas/zigps-avro\",\"type\":\"AVRO\",\"definition\":{s}}}}}";
    const r2 = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas/zigps-avro:commit", try std.fmt.allocPrint(a, commit, .{try Stringify.valueAlloc(a, two_fields, .{})}))).body);
    const r3 = try revisionOf(a, (try b.raw(a, .POST, "projects/p/schemas/zigps-avro:commit", try std.fmt.allocPrint(a, commit, .{try Stringify.valueAlloc(a, three_fields, .{})}))).body);
    const reader = b.client.subscription("reader");
    var subscribed = try reader.create(.{ .topic_id = "zigps-json" });
    subscribed.deinit();
    var as_sent = try b.client.subscription("as-sent").create(.{ .topic_id = "zigps-json" });
    as_sent.deinit();
    const topic = b.client.topic("zigps-json");
    judge.asked = 0;
    // The first fits every revision, and is marked with the newest. The
    // second fits the third alone. The third fits the two older, and is
    // marked with the newer of those. What the publisher wrote of the
    // encoding and the revision is written over; a name it wrote is kept.
    // (This client lets no attribute through that begins `goog`, so the
    // request is written out.)
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/zigps-json:publish", "{\"messages\":[" ++
        "{\"data\":\"YWdl\",\"attributes\":{\"k\":\"v\",\"googclient_schemaencoding\":\"BINARY\",\"googclient_schemarevisionid\":\"forged\"}}," ++
        "{\"data\":\"bm90ZQ==\"}," ++
        "{\"data\":\"aW50In1d\",\"attributes\":{\"googclient_schemaname\":\"forged\"}}]}")).status);
    try testing.expectEqual(1 + 1 + 2, judge.asked);
    {
        // As sent: each of the three once a message, with nothing left of
        // an encoding or a revision the publisher wrote.
        const sent = (try b.raw(a, .POST, "projects/p/subscriptions/as-sent:pull", "{\"maxMessages\":10}")).body;
        try testing.expectEqual(3, std.mem.count(u8, sent, "\"googclient_schemaencoding\":\"JSON\""));
        try testing.expectEqual(3, std.mem.count(u8, sent, "\"googclient_schemaencoding\""));
        try testing.expectEqual(3, std.mem.count(u8, sent, "\"googclient_schemarevisionid\""));
        try testing.expectEqual(3, std.mem.count(u8, sent, "\"googclient_schemaname\""));
    }
    {
        var got = try reader.pull(.{});
        defer got.deinit();
        try testing.expectEqual(3, got.value.messages.len);
        const first, const second, const third = got.value.messages[0..3].*;
        try testing.expectEqual(4, first.attributes.len);
        try testing.expectEqualStrings("v", first.attribute("k").?);
        try testing.expectEqualStrings("JSON", first.attribute("googclient_schemaencoding").?);
        try testing.expectEqualStrings("projects/p/schemas/zigps-avro", first.attribute("googclient_schemaname").?);
        try testing.expectEqualStrings(r3, first.attribute("googclient_schemarevisionid").?);
        try testing.expectEqual(3, second.attributes.len);
        try testing.expectEqualStrings(r3, second.attribute("googclient_schemarevisionid").?);
        try testing.expectEqual(3, third.attributes.len);
        try testing.expectEqualStrings("forged", third.attribute("googclient_schemaname").?);
        try testing.expectEqualStrings("JSON", third.attribute("googclient_schemaencoding").?);
        try testing.expectEqualStrings(r2, third.attribute("googclient_schemarevisionid").?);
        for (got.value.messages) |m| try reader.ack(&.{m.ack_id});
    }
    // One that fits none is refused in production's body, which names
    // the last revision tried, the oldest. (Production names the schema
    // there by the project's number.) Nothing of the request is taken,
    // the message that fits included.
    const before = b.fake.publishedCount("p", "zigps-json");
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"error\":{{\"code\":400,\"message\":\"Invalid data in message: Message failed schema validation.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"INVALID_JSON_AVRO_MESSAGE\",\"domain\":\"pubsub.googleapis.com\",\"metadata\":{{\"revisionInfo\":\"Could not validate message with any schema revision for schema: projects/p/schemas/zigps-avro, last checked revision: revision_id={s} failed with status: Invalid data in message: JSON object with type string does not match schema which expected number_integer..\",\"message\":\"Message failed schema validation\"}}}}]}}}}", .{r1}),
        (try b.raw(a, .POST, "projects/p/topics/zigps-json:publish", "{\"messages\":[{\"data\":\"YWdl\"},{\"data\":\"b25l\"}]}")).body,
    );
    // Attributes and no data: to production that is no JSON.
    const empty = (try b.raw(a, .POST, "projects/p/topics/zigps-json:publish", "{\"messages\":[{\"attributes\":{\"k\":\"v\"}}]}")).body;
    try testing.expect(std.mem.indexOf(u8, empty, "failed with status: Invalid data in message: Tried to parse invalid JSON..\"") != null);
    try testing.expectEqual(before, b.fake.publishedCount("p", "zigps-json"));
    try testing.expectError(error.InvalidArgument, topic.publish(&.{.{ .data = "one" }}, .{}));
    // The reason follows the schema's type and the topic's encoding.
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .POST, "projects/p/topics/zigps-pbin:publish", "{\"messages\":[{\"data\":\"////\"}]}")).body, "\"reason\":\"INVALID_BINARY_PROTO_MESSAGE\"") != null);

    // A topic held to a range is tried on the range alone.
    judge.asked = 0;
    try testing.expectEqual(400, (try b.raw(a, .POST, "projects/p/topics/zigps-range:publish", "{\"messages\":[{\"data\":\"bm90ZQ==\"}]}")).status);
    try testing.expectEqual(1, judge.asked);
    try testing.expectEqualStrings(r1, &judge.last_revision);
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/zigps-range:publish", "{\"messages\":[{\"data\":\"YWdl\"}]}")).status);
    // With the range's one revision deleted nothing fits. (Production
    // took a minute to say so, and said no more than this.)
    try testing.expectEqual(200, (try b.raw(a, .DELETE, try std.fmt.allocPrint(a, "projects/p/schemas/zigps-avro@{s}:deleteRevision", .{r1}), "")).status);
    try expectRefused(try b.raw(a, .POST, "projects/p/topics/zigps-range:publish", "{\"messages\":[{\"data\":\"YWdl\"}]}"), 400, "INVALID_ARGUMENT", "Invalid data in message: Message failed schema validation.");
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/topics/zigps-range", "")).body, try std.fmt.allocPrint(a, "\"firstRevisionId\":\"{s}\",\"lastRevisionId\":\"{s}\"", .{ r1, r1 })) != null);

    // A topic with no schema keeps the three attributes as written.
    var plain_made = try b.client.topic("plain").create(.{});
    plain_made.deinit();
    var plain_sub = try b.client.subscription("plain-reader").create(.{ .topic_id = "plain" });
    plain_sub.deinit();
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/plain:publish", "{\"messages\":[{\"data\":\"eA==\",\"attributes\":{\"googclient_schemaencoding\":\"JSON\",\"googclient_schemaname\":\"forged\",\"googclient_schemarevisionid\":\"forged\"}}]}")).status);
    {
        var got = try b.client.subscription("plain-reader").pull(.{});
        defer got.deinit();
        try testing.expectEqual(3, got.value.messages[0].attributes.len);
        try testing.expectEqualStrings("forged", got.value.messages[0].attribute("googclient_schemarevisionid").?);
    }

    // Its schema deleted, a topic reads `_deleted-schema_` and keeps its
    // encoding, and a publish is refused. (Production showed both up to
    // a minute late.) A schema made again under the id is another.
    try b.client.schema("zigps-avro").delete();
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-json","schemaSettings":{"schema":"_deleted-schema_","encoding":"JSON"}}
    , (try b.raw(a, .GET, "projects/p/topics/zigps-json", "")).body);
    try expectRefused(try b.raw(a, .POST, "projects/p/topics/zigps-json:publish", "{\"messages\":[{\"data\":\"YWdl\"}]}"), 404, "NOT_FOUND", "The schema associated with the topic has been deleted.");
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/schemas?schemaId=zigps-avro", try schemaBody(a, "AVRO", two_fields))).status);
    try testing.expectError(error.NotFound, topic.publish(&.{.{ .data = "age" }}, .{}));
    var read = try topic.get();
    defer read.deinit();
    try testing.expectEqualStrings(types.SchemaSettings.deleted, read.value.schema.?.schema);
    try testing.expectEqual(types.SchemaEncoding.json, read.value.schema.?.encoding);
    // Cleared, the topic takes anything again.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-json\"}", (try b.raw(a, .PATCH, patch, "{\"topic\":{},\"updateMask\":\"schemaSettings\"}")).body);
    var free = try topic.publish(&.{.{ .data = "one" }}, .{});
    free.deinit();

    // Through the client: a topic made with a schema, and given another.
    var typed = try b.client.topic("typed").create(.{ .schema = .{ .schema = "zigps-proto", .encoding = .binary } });
    defer typed.deinit();
    try testing.expectEqualStrings("projects/p/schemas/zigps-proto", typed.value.schema.?.schema);
    try testing.expectEqual(types.SchemaEncoding.binary, typed.value.schema.?.encoding);
}

/// What a resource's JSON holds between two places in it.
fn between(body: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, body, from) orelse return "") + from.len;
    const len = std.mem.indexOf(u8, body[start..], to) orelse return "";
    return body[start..][0..len];
}

/// What it holds from there on.
fn tailOf(body: []const u8, comptime from: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, body, from) orelse return "";
    return body[at + from.len ..];
}

fn pushConfigOf(body: []const u8) []const u8 {
    return between(body, "\"pushConfig\":", ",\"ackDeadlineSeconds\"");
}

/// `n` times `é`, two bytes each.
fn accented(comptime n: usize) [2 * n]u8 {
    var out: [2 * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[2 * i ..][0..2], "é");
    return out;
}

test "push subscriptions: kept and read back as production's, refused in its words, and never pushed to" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("zigps-t").create(.{});
    made.deinit();
    const topic = "\"topic\":\"projects/p/topics/zigps-t\"";
    const end = "https://example.com/zigps-push";
    const version = "\"attributes\":{\"x-goog-version\":\"v1\"}";
    const push = "projects/p/subscriptions/zigps-push";

    // The answer to a create fills in the version. A read shows none.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-push","topic":"projects/p/topics/zigps-t","pushConfig":{"pushEndpoint":"https://example.com/zigps-push","attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, push, "{" ++ topic ++ ",\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\"}}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-push","topic":"projects/p/topics/zigps-t","pushConfig":{"pushEndpoint":"https://example.com/zigps-push"},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .GET, push, "")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-push-ord","topic":"projects/p/topics/zigps-t","pushConfig":{"pushEndpoint":"https://example.com/zigps-push","attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","enableMessageOrdering":true,"expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-push-ord", "{" ++ topic ++ ",\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\"},\"enableMessageOrdering\":true}")).body);

    // What a push config may hold, as the answer to the create writes it.
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "zigps-attr", "{\"pushEndpoint\":\"" ++ end ++ "\",\"attributes\":{\"x-goog-version\":\"v1beta1\"}}", "{\"pushEndpoint\":\"" ++ end ++ "\",\"attributes\":{\"x-goog-version\":\"v1beta1\"}}" },
        .{ "zigps-nowrap", "{\"pushEndpoint\":\"" ++ end ++ "\",\"noWrapper\":{\"writeMetadata\":true}}", "{\"pushEndpoint\":\"" ++ end ++ "\"," ++ version ++ ",\"noWrapper\":{\"writeMetadata\":true}}" },
        .{ "zigps-wrap", "{\"pushEndpoint\":\"" ++ end ++ "\",\"pubsubWrapper\":{}}", "{\"pushEndpoint\":\"" ++ end ++ "\"," ++ version ++ ",\"pubsubWrapper\":{}}" },
        .{ "zigps-oidc", "{\"pushEndpoint\":\"" ++ end ++ "\",\"oidcToken\":{\"serviceAccountEmail\":\"zig-gcp@p.iam.gserviceaccount.com\",\"audience\":\"zigps\"}}", "{\"pushEndpoint\":\"" ++ end ++ "\"," ++ version ++ ",\"oidcToken\":{\"serviceAccountEmail\":\"zig-gcp@p.iam.gserviceaccount.com\",\"audience\":\"zigps\"}}" },
        .{ "zigps-oidc-wrap", "{\"noWrapper\":{},\"oidcToken\":{\"serviceAccountEmail\":\"zig-gcp@p.iam.gserviceaccount.com\"},\"push_endpoint\":\"" ++ end ++ "\"}", "{\"pushEndpoint\":\"" ++ end ++ "\"," ++ version ++ ",\"oidcToken\":{\"serviceAccountEmail\":\"zig-gcp@p.iam.gserviceaccount.com\"},\"noWrapper\":{}}" },
        // With no endpoint it is a subscription that pulls, whatever else
        // the config holds.
        .{ "zigps-empty", "{}", "{}" },
        .{ "zigps-version-alone", "{" ++ version ++ ",\"noWrapper\":{}}", "{}" },
    }) |case| {
        const body = (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/{s}", .{case[0]}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"pushConfig\":{s}}}", .{case[1]}))).body;
        try testing.expectEqualStrings(case[2], pushConfigOf(body));
    }
    // A version the request said, a read shows: the fake's own.
    try testing.expectEqualStrings("{\"pushEndpoint\":\"" ++ end ++ "\",\"attributes\":{\"x-goog-version\":\"v1beta1\"}}", pushConfigOf((try b.raw(a, .GET, "projects/p/subscriptions/zigps-attr", "")).body));
    try testing.expectEqualStrings("{\"pushEndpoint\":\"" ++ end ++ "\",\"noWrapper\":{\"writeMetadata\":true}}", pushConfigOf((try b.raw(a, .GET, "projects/p/subscriptions/zigps-nowrap", "")).body));

    // What a create refuses. The last production was shown only beside a
    // version it refused.
    const no_exactly_once = "A subscription cannot have push config set with exactly once delivery configured.";
    for ([_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ "\"pushConfig\":{\"pushEndpoint\":\"http://example.com/zigps-push\"}", 400, "INVALID_ARGUMENT", "Invalid push endpoint given (endpoint=http://example.com/zigps-push). Refer to https://cloud.google.com/pubsub/subscriber#create for more information." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"not a url\"}", 400, "INVALID_ARGUMENT", "Invalid push endpoint given (endpoint=not a url). Refer to https://cloud.google.com/pubsub/subscriber#create for more information." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"https://\"}", 400, "INVALID_ARGUMENT", "Invalid push endpoint given (endpoint=https://). Refer to https://cloud.google.com/pubsub/subscriber#create for more information." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"https://example.com/a b\"}", 400, "INVALID_ARGUMENT", "Invalid push endpoint given (endpoint=https://example.com/a b). Refer to https://cloud.google.com/pubsub/subscriber#create for more information." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\",\"attributes\":{\"x-goog-version\":\"v2\",\"other\":\"x\"}}", 400, "INVALID_ARGUMENT", "Invalid push endpoint version given in push config (version=v2)." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\",\"pubsubWrapper\":{},\"noWrapper\":{}}", 400, "INVALID_ARGUMENT", "Invalid value at 'push_config' (oneof), oneof field 'wrapper' is already set. Cannot set 'noWrapper'" },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\",\"noWrapper\":{},\"pubsubWrapper\":{}}", 400, "INVALID_ARGUMENT", "Invalid value at 'push_config' (oneof), oneof field 'wrapper' is already set. Cannot set 'pubsubWrapper'" },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\",\"oidcToken\":{\"audience\":\"zigps\"}}", 400, "INVALID_ARGUMENT", "You have passed an invalid argument to the service (argument=PushConfig::oidc_token::service_account_email)." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\"},\"enableExactlyOnceDelivery\":true", 400, "INVALID_ARGUMENT", no_exactly_once },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\",\"pubsubWrapper\":{\"writeMetadata\":true}}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"writeMetadata\": Cannot find field." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\",\"noWrapper\":{\"nonsense\":true}}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\",\"attributes\":{\"other\":\"x\"}}", 501, "UNIMPLEMENTED", "fake: a push attribute other than x-goog-version is not modelled yet" },
    }) |case| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{case[0]})), case[1], case[2], case[3]);
    }
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);

    // It holds what it is sent, and gives none of it: nothing is pushed.
    var sent = try b.client.topic("zigps-t").publish(&.{ .{ .data = "one" }, .{ .data = "two" } }, .{});
    sent.deinit();
    try testing.expectEqual(2, b.fake.backlog("p", "zigps-push"));
    const not_this_kind = "This method is not supported for this subscription type.";
    try expectRefused(try b.raw(a, .POST, push ++ ":pull", "{\"maxMessages\":1,\"returnImmediately\":true}"), 400, "FAILED_PRECONDITION", not_this_kind);
    try expectRefused(try b.raw(a, .POST, push ++ ":modifyAckDeadline", "{\"ackIds\":[\"x\"],\"ackDeadlineSeconds\":10}"), 400, "FAILED_PRECONDITION", not_this_kind);
    try testing.expectError(error.FailedPrecondition, b.client.subscription("zigps-push").pull(.{ .return_immediately = true }));
    // An ack production refused for its id, as on any subscription.
    try expectRefused(try b.raw(a, .POST, push ++ ":acknowledge", "{\"ackIds\":[\"x\"]}"), 400, "INVALID_ARGUMENT", "You have passed an invalid ack ID to the service (ack_id=x).");
    // A seek and a snapshot are taken as on any subscription.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, push ++ ":seek", "{\"time\":\"1970-01-01T00:00:00Z\"}")).body);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/snapshots/zigps-snap", "{\"subscription\":\"" ++ push ++ "\"}")).status);
    try testing.expectEqual(2, b.fake.backlog("p", "zigps-push"));
    try testing.expectEqual(0, b.fake.outstanding("p", "zigps-push"));

    // modifyPushConfig replaces the config whole, and answers nothing.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, push ++ ":modifyPushConfig", "{\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "2\"}}")).body);
    try testing.expectEqualStrings("{\"pushEndpoint\":\"" ++ end ++ "2\"}", pushConfigOf((try b.raw(a, .GET, push, "")).body));
    // So does an update by the mask `pushConfig`, and its answer fills in
    // the version again.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-push","topic":"projects/p/topics/zigps-t","pushConfig":{"pushEndpoint":"https://example.com/zigps-push3","attributes":{"x-goog-version":"v1"},"noWrapper":{}},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, push, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "3\",\"noWrapper\":{}}},\"updateMask\":\"pushConfig\"}")).body);
    // By `pushConfig.pushEndpoint` the endpoint alone changes: the
    // wrapper stays.
    try testing.expectEqualStrings("{\"pushEndpoint\":\"" ++ end ++ "4\"," ++ version ++ ",\"noWrapper\":{}}", pushConfigOf((try b.raw(a, .PATCH, push, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "4\"}},\"updateMask\":\"pushConfig.pushEndpoint\"}")).body));
    try testing.expectEqualStrings("{\"pushEndpoint\":\"" ++ end ++ "4\",\"noWrapper\":{}}", pushConfigOf((try b.raw(a, .GET, push, "")).body));
    // An endpoint of no form is refused there too, and changes nothing.
    try expectRefused(try b.raw(a, .PATCH, push, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"http://example.com\"}},\"updateMask\":\"push_config.push_endpoint\"}"), 400, "INVALID_ARGUMENT", "Invalid push endpoint given (endpoint=http://example.com). Refer to https://cloud.google.com/pubsub/subscriber#create for more information.");
    try expectRefused(try b.raw(a, .PATCH, push, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"http://example.com\"}},\"updateMask\":\"pushConfig\"}"), 400, "INVALID_ARGUMENT", "Invalid push endpoint given (endpoint=http://example.com). Refer to https://cloud.google.com/pubsub/subscriber#create for more information.");
    try testing.expectEqualStrings("{\"pushEndpoint\":\"" ++ end ++ "4\",\"noWrapper\":{}}", pushConfigOf((try b.raw(a, .GET, push, "")).body));
    // Any other path inside the config production was not shown.
    try expectRefused(try b.raw(a, .PATCH, push, "{\"subscription\":{},\"updateMask\":\"pushConfig.noWrapper\"}"), 501, "UNIMPLEMENTED", "fake: pushConfig.noWrapper is not modelled yet");

    // With no endpoint it pulls again, and here at once: production went
    // on refusing a pull for a moment.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, push ++ ":modifyPushConfig", "{\"pushConfig\":{}}")).body);
    try testing.expectEqualStrings("{}", pushConfigOf((try b.raw(a, .GET, push, "")).body));
    try testing.expectEqual(200, (try b.raw(a, .POST, push ++ ":pull", "{\"maxMessages\":10}")).status);
    try testing.expectEqual(2, b.fake.outstanding("p", "zigps-push"));
    // Back to push by the endpoint's own path, which finds no config to
    // keep; then the mask alone, whose answer has a version and no
    // endpoint, where a read has neither.
    try testing.expectEqualStrings("{\"pushEndpoint\":\"" ++ end ++ "\"," ++ version ++ "}", pushConfigOf((try b.raw(a, .PATCH, push, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\"}},\"updateMask\":\"pushConfig.pushEndpoint\"}")).body));
    try testing.expectEqualStrings("{" ++ version ++ "}", pushConfigOf((try b.raw(a, .PATCH, push, "{\"subscription\":{},\"updateMask\":\"pushConfig\"}")).body));
    try testing.expectEqualStrings("{}", pushConfigOf((try b.raw(a, .GET, push, "")).body));
    // The endpoint's own path with no endpoint in the body: it pulls.
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, push ++ ":modifyPushConfig", "{\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\"}}")).body);
    try testing.expectEqualStrings("{" ++ version ++ "}", pushConfigOf((try b.raw(a, .PATCH, push, "{\"subscription\":{\"pushConfig\":{}},\"updateMask\":\"pushConfig.pushEndpoint\"}")).body));
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, push ++ ":modifyPushConfig", "{}")).body);
    try expectRefused(try b.raw(a, .POST, "projects/p/subscriptions/zigps-nope:modifyPushConfig", "{\"pushConfig\":{}}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    try expectRefused(try b.raw(a, .POST, push ++ ":modifyPushConfig", "{\"pushConfig\":{\"pushEndpoint\":\"http://example.com\"}}"), 400, "INVALID_ARGUMENT", "Invalid push endpoint given (endpoint=http://example.com). Refer to https://cloud.google.com/pubsub/subscriber#create for more information.");
    try testing.expectEqual(400, (try b.raw(a, .POST, push ++ ":modifyPushConfig", "{\"push\":{}}")).status);

    // Exactly-once delivery and a push config never meet, whichever
    // comes second.
    const ord = "projects/p/subscriptions/zigps-push-ord";
    try expectRefused(try b.raw(a, .PATCH, ord, "{\"subscription\":{\"enableExactlyOnceDelivery\":true},\"updateMask\":\"enableExactlyOnceDelivery\"}"), 400, "INVALID_ARGUMENT", no_exactly_once);
    try expectRefused(try b.raw(a, .PATCH, push, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\"},\"enableExactlyOnceDelivery\":true},\"updateMask\":\"pushConfig,enableExactlyOnceDelivery\"}"), 400, "INVALID_ARGUMENT", no_exactly_once);
    try testing.expectEqual(200, (try b.raw(a, .PATCH, push, "{\"subscription\":{\"enableExactlyOnceDelivery\":true},\"updateMask\":\"enableExactlyOnceDelivery\"}")).status);
    try expectRefused(try b.raw(a, .POST, push ++ ":modifyPushConfig", "{\"pushConfig\":{\"pushEndpoint\":\"" ++ end ++ "\"}}"), 400, "INVALID_ARGUMENT", no_exactly_once);
    try testing.expectEqualStrings("{}", pushConfigOf((try b.raw(a, .GET, push, "")).body));

    // Through the client: made, read, and changed to pull, which this
    // client asks for by naming all three kinds and giving none.
    var hook = try b.client.subscription("hook").create(.{ .topic_id = "zigps-t", .delivery = .{ .push = .{
        .endpoint = end,
        .oidc_token = .{ .service_account_email = "zig-gcp@p.iam.gserviceaccount.com", .audience = "zigps" },
        .body = .{ .unwrapped = .{ .write_metadata = true } },
    } } });
    defer hook.deinit();
    try testing.expectEqualStrings(end, hook.value.delivery.push.endpoint);
    try testing.expectEqualStrings("zigps", hook.value.delivery.push.oidc_token.?.audience);
    try testing.expect(hook.value.delivery.push.body.unwrapped.write_metadata);
    var pulls = try b.client.subscription("hook").update(.{ .delivery = .pull });
    defer pulls.deinit();
    try testing.expectEqual(types.DeliveryInfo.pull, pulls.value.delivery);
    var pushes = try b.client.subscription("hook").update(.{ .delivery = .{ .push = .{ .endpoint = end ++ "5" } } });
    defer pushes.deinit();
    try testing.expectEqualStrings(end ++ "5", pushes.value.delivery.push.endpoint);
    try testing.expectEqual(types.PushConfig.Body.wrapped, pushes.value.delivery.push.body);
    var kept = try b.client.subscription("kept").create(.{ .topic_id = "zigps-t", .delivery = .{ .push = .{ .endpoint = end, .oidc_token = .{ .service_account_email = "zig-gcp@p.iam.gserviceaccount.com" } } } });
    kept.deinit();
    for ([_][]const u8{ "hook", "kept" }, [_][]const u8{ end ++ "5", end }) |id, endpoint| {
        var read = try b.client.subscription(id).get();
        defer read.deinit();
        try testing.expectEqualStrings(endpoint, read.value.delivery.push.endpoint);
    }

    // A detached subscription says so first, of whatever kind: the fake's
    // own, production was not asked.
    try testing.expectEqual(200, (try b.raw(a, .POST, ord ++ ":detach", "")).status);
    try expectRefused(try b.raw(a, .POST, ord ++ ":pull", "{\"maxMessages\":1}"), 400, "FAILED_PRECONDITION", "This method is not supported on detached subscriptions.");
    try expectRefused(try b.raw(a, .POST, ord ++ ":modifyAckDeadline", "{\"ackIds\":[\"x\"],\"ackDeadlineSeconds\":10}"), 400, "FAILED_PRECONDITION", "This method is not supported on detached subscriptions.");
}

test "BigQuery subscriptions: kept and read back as production's, with a state the test sets" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("zigps-t").create(.{});
    made.deinit();
    const topic = "\"topic\":\"projects/p/topics/zigps-t\"";
    const bq = "projects/p/subscriptions/zigps-bq";

    // A create's answer and a read are the same: the state is there at
    // once, and before the subscription's own.
    const as_made =
        \\{"name":"projects/p/subscriptions/zigps-bq","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"bigqueryConfig":{"table":"p.zigps_d.msgs","writeMetadata":true,"state":"ACTIVE"},"state":"ACTIVE"}
    ;
    try testing.expectEqualStrings(as_made, (try b.raw(a, .PUT, bq, "{" ++ topic ++ ",\"bigqueryConfig\":{\"table\":\"p.zigps_d.msgs\",\"writeMetadata\":true}}")).body);
    try testing.expectEqualStrings(as_made, (try b.raw(a, .GET, bq, "")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-bq-schema","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"bigqueryConfig":{"table":"p.zigps_d.msgs","useTopicSchema":true,"state":"ACTIVE"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bq-schema", "{" ++ topic ++ ",\"bigqueryConfig\":{\"table\":\"p.zigps_d.msgs\",\"useTopicSchema\":true}}")).body);
    // Every setting, in the order the service numbers them: the two
    // above are all production was seen to write. A table's two forms,
    // and a dataset with a hyphen, production took for well formed.
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "zigps-bq-all", "{\"serviceAccountEmail\":\"writer@p.iam.gserviceaccount.com\",\"dropUnknownFields\":true,\"writeMetadata\":true,\"useTopicSchema\":true,\"state\":\"NOT_FOUND\",\"table\":\"p:zigps_d.msgs\"}", "\"table\":\"p:zigps_d.msgs\",\"useTopicSchema\":true,\"writeMetadata\":true,\"dropUnknownFields\":true,\"state\":\"ACTIVE\",\"serviceAccountEmail\":\"writer@p.iam.gserviceaccount.com\"" },
        .{ "zigps-bq-table", "{\"table\":\"p.zigps-d.msgs\",\"use_table_schema\":true}", "\"table\":\"p.zigps-d.msgs\",\"state\":\"ACTIVE\",\"useTableSchema\":true" },
    }) |case| {
        const body = (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/{s}", .{case[0]}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"bigqueryConfig\":{s}}}", .{case[1]}))).body;
        try testing.expectEqualStrings(case[2], between(body, "\"bigqueryConfig\":{", "},\"state\""));
    }

    // What a create refuses. The fake has no tables: one that is not
    // there, which production refuses with 403, is taken here.
    const malformed = "Request contains an invalid argument.";
    const one_kind = "Cannot create a subscription with multiple configurations. Only at most one of ";
    for ([_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ "\"bigqueryConfig\":{\"table\":\"nonsense\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\"zigps_d.t\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\"p.zigps_d\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\".zigps_d.t\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\"p..t\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\"p.d.\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\":d.t\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\"p:t\"}", 400, "INVALID_ARGUMENT", malformed },
        .{ "\"bigqueryConfig\":{\"table\":\"a.b.c.d\"}", 404, "NOT_FOUND", "Requested entity was not found." },
        .{ "\"bigqueryConfig\":{\"table\":\"p.d.t\",\"useTopicSchema\":true,\"useTableSchema\":true}", 400, "INVALID_ARGUMENT", "The options use_table_schema and use_topic_schema cannot both be set to 'true' when creating a BigQuery subscription." },
        .{ "\"bigqueryConfig\":{\"table\":\"p.d.t\"},\"enableExactlyOnceDelivery\":true", 400, "INVALID_ARGUMENT", "A subscription cannot have bigquery config set with exactly once delivery configured." },
        .{ "\"bigqueryConfig\":{\"table\":\"p.d.t\"},\"pushConfig\":{\"pushEndpoint\":\"https://example.com/zigps-push\"}", 400, "INVALID_ARGUMENT", one_kind ++ "PushConfig, BigQueryConfig can be specified." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\"},\"bigqueryConfig\":{\"table\":\"p.d.t\"}", 400, "INVALID_ARGUMENT", one_kind ++ "BigQueryConfig, CloudStorageConfig can be specified." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\"},\"pushConfig\":{\"pushEndpoint\":\"https://example.com/zigps-push\"}", 400, "INVALID_ARGUMENT", one_kind ++ "PushConfig, CloudStorageConfig can be specified." },
        .{ "\"bigqueryConfig\":{\"table\":\"p.d.t\",\"writeMetadata\":\"yes\"}", 400, "INVALID_ARGUMENT", "Invalid value at 'writeMetadata'" },
        .{ "\"bigqueryConfig\":{\"table\":\"p.d.t\",\"nonsense\":true}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        // All three production was not shown.
        .{ "\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\"},\"bigqueryConfig\":{\"table\":\"p.d.t\"},\"pushConfig\":{\"pushEndpoint\":\"https://example.com/zigps-push\"}", 501, "UNIMPLEMENTED", "fake: a subscription with all three kinds of delivery is not modelled yet" },
    }) |case| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{case[0]})), case[1], case[2], case[3]);
    }
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);
    // A push config with no endpoint is no second kind.
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bq-pull", "{" ++ topic ++ ",\"pushConfig\":{},\"bigqueryConfig\":{\"table\":\"p.d.t\"}}")).status);

    // It holds what it is sent and gives none of it. That a pull is
    // refused as on a subscription that pushes is the fake's own.
    var sent = try b.client.topic("zigps-t").publish(&.{.{ .data = "row" }}, .{});
    sent.deinit();
    try testing.expectEqual(1, b.fake.backlog("p", "zigps-bq"));
    try expectRefused(try b.raw(a, .POST, bq ++ ":pull", "{\"maxMessages\":1}"), 400, "FAILED_PRECONDITION", "This method is not supported for this subscription type.");
    try expectRefused(try b.raw(a, .POST, bq ++ ":modifyAckDeadline", "{\"ackIds\":[\"x\"],\"ackDeadlineSeconds\":10}"), 400, "FAILED_PRECONDITION", "This method is not supported for this subscription type.");
    try expectRefused(try b.raw(a, .POST, bq ++ ":modifyPushConfig", "{\"pushConfig\":{}}"), 501, "UNIMPLEMENTED", "fake: modifyPushConfig on a subscription that exports is not modelled yet");

    // What production learns by writing rows, the test says. While it is
    // anything but active the subscription's own state says so too.
    b.fake.setExportState("p", "zigps-bq", .permission_denied);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-bq","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"bigqueryConfig":{"table":"p.zigps_d.msgs","writeMetadata":true,"state":"PERMISSION_DENIED"},"state":"RESOURCE_ERROR"}
    , (try b.raw(a, .GET, bq, "")).body);
    {
        var read = try b.client.subscription("zigps-bq").get();
        defer read.deinit();
        try testing.expectEqual(types.ExportState.permission_denied, read.value.delivery.bigquery.state);
        try testing.expectEqual(types.SubscriptionInfo.State.resource_error, read.value.state);
        try testing.expect(read.value.delivery.bigquery.config.write_metadata);
    }
    for ([_]struct { types.ExportState, []const u8 }{
        .{ .not_found, "\"state\":\"NOT_FOUND\"},\"state\":\"RESOURCE_ERROR\"}" },
        .{ .schema_mismatch, "\"state\":\"SCHEMA_MISMATCH\"},\"state\":\"RESOURCE_ERROR\"}" },
        .{ .location_restriction, "\"state\":\"IN_TRANSIT_LOCATION_RESTRICTION\"},\"state\":\"RESOURCE_ERROR\"}" },
        // No word at all, as an emulator says none.
        .{ .unknown, "\"writeMetadata\":true},\"state\":\"ACTIVE\"}" },
        .{ .active, "\"state\":\"ACTIVE\"},\"state\":\"ACTIVE\"}" },
    }) |case| {
        b.fake.setExportState("projects/p", bq, case[0]);
        try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .GET, bq, "")).body, case[1]));
    }
    // Said of a subscription that exports nothing, or of none, it is
    // nothing.
    b.fake.setExportState("p", "zigps-bq-pull-nope", .not_found);
    var plain = try b.client.subscription("plain").create(.{ .topic_id = "zigps-t" });
    plain.deinit();
    b.fake.setExportState("p", "plain", .not_found);
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .GET, "projects/p/subscriptions/plain", "")).body, "\"state\":\"ACTIVE\"}"));

    // An update replaces the config whole, and the new one is active
    // again. Its answer has the version every update's has.
    b.fake.setExportState("p", "zigps-bq", .not_found);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-bq","topic":"projects/p/topics/zigps-t","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"bigqueryConfig":{"table":"p.zigps_d.other","state":"ACTIVE"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, bq, "{\"subscription\":{\"bigqueryConfig\":{\"table\":\"p.zigps_d.other\"}},\"updateMask\":\"bigqueryConfig\"}")).body);
    // A refused one changes nothing, and neither does another update.
    try expectRefused(try b.raw(a, .PATCH, bq, "{\"subscription\":{\"bigqueryConfig\":{\"table\":\"nonsense\"}},\"updateMask\":\"bigquery_config\"}"), 400, "INVALID_ARGUMENT", malformed);
    try expectRefused(try b.raw(a, .PATCH, bq, "{\"subscription\":{},\"updateMask\":\"bigqueryConfig.table\"}"), 501, "UNIMPLEMENTED", "fake: bigqueryConfig.table is not modelled yet");
    b.fake.setExportState("p", "zigps-bq", .schema_mismatch);
    try testing.expectEqual(200, (try b.raw(a, .PATCH, bq, "{\"subscription\":{\"ackDeadlineSeconds\":20},\"updateMask\":\"ackDeadlineSeconds\"}")).status);
    try testing.expectEqualStrings("\"table\":\"p.zigps_d.other\",\"state\":\"SCHEMA_MISMATCH\"", between((try b.raw(a, .GET, bq, "")).body, "\"bigqueryConfig\":{", "},\"state\""));

    // Through the client.
    var rows = try b.client.subscription("rows").create(.{ .topic_id = "zigps-t", .delivery = .{ .bigquery = .{ .table = "p.d.t", .schema = .topic, .drop_unknown_fields = true, .service_account_email = "writer@p.iam.gserviceaccount.com" } } });
    defer rows.deinit();
    try testing.expectEqualStrings("p.d.t", rows.value.delivery.bigquery.config.table);
    try testing.expectEqual(types.BigQueryConfig.Schema.topic, rows.value.delivery.bigquery.config.schema);
    try testing.expect(rows.value.delivery.bigquery.config.drop_unknown_fields);
    try testing.expectEqualStrings("writer@p.iam.gserviceaccount.com", rows.value.delivery.bigquery.config.service_account_email.?);
    try testing.expectEqual(types.ExportState.active, rows.value.delivery.bigquery.state);
    try testing.expectError(error.FailedPrecondition, b.client.subscription("rows").pull(.{ .return_immediately = true }));
    var read = try b.client.subscription("rows").get();
    defer read.deinit();
    try testing.expectEqualStrings("p.d.t", read.value.delivery.bigquery.config.table);
    try testing.expectEqualStrings("writer@p.iam.gserviceaccount.com", read.value.delivery.bigquery.config.service_account_email.?);
}

test "Cloud Storage subscriptions: what production fills in, its bounds on a file, and its rules for a file's name" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made = try b.client.topic("zigps-t").create(.{});
    made.deinit();
    const topic = "\"topic\":\"projects/p/topics/zigps-t\"";
    const gcs = "projects/p/subscriptions/zigps-gcs";

    // Filled in: the text format, and an ack deadline as long as a file
    // is kept open. The config is written after the subscription's
    // state.
    const as_made =
        \\{"name":"projects/p/subscriptions/zigps-gcs","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE","cloudStorageConfig":{"bucket":"zigps-bucket","filenamePrefix":"zigps/","textConfig":{},"maxDuration":"60s","state":"ACTIVE"}}
    ;
    try testing.expectEqualStrings(as_made, (try b.raw(a, .PUT, gcs, "{" ++ topic ++ ",\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\",\"filenamePrefix\":\"zigps/\",\"maxDuration\":\"60s\"}}")).body);
    try testing.expectEqualStrings(as_made, (try b.raw(a, .GET, gcs, "")).body);
    // A deadline that was said is raised all the same, not refused.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-gcs-dur","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":600,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE","cloudStorageConfig":{"bucket":"zigps-bucket","textConfig":{},"maxDuration":"600s","state":"ACTIVE"}}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-gcs-dur", "{" ++ topic ++ ",\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\",\"maxDuration\":\"600s\"},\"ackDeadlineSeconds\":10}")).body);
    // Every setting, in the order the service numbers them, which is the
    // order of the two above. A longer deadline stays; with no duration
    // said a file is kept open five minutes.
    for ([_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "zigps-gcs-all", "{\"serviceAccountEmail\":\"writer@p.iam.gserviceaccount.com\",\"maxMessages\":1000,\"maxBytes\":\"1000\",\"maxDuration\":\"90.5s\",\"avroConfig\":{\"useTopicSchema\":true,\"writeMetadata\":true},\"filenameDatetimeFormat\":\"YYYY-MM-DD/hh_mm_ssZ\",\"filenameSuffix\":\".avro\",\"filenamePrefix\":\"a/b/\",\"state\":\"NOT_FOUND\",\"bucket\":\"ZIGPS-BUCKET\"}", "91", "\"bucket\":\"ZIGPS-BUCKET\",\"filenamePrefix\":\"a/b/\",\"filenameSuffix\":\".avro\",\"avroConfig\":{\"writeMetadata\":true,\"useTopicSchema\":true},\"maxDuration\":\"90.500s\",\"maxBytes\":\"1000\",\"maxMessages\":\"1000\",\"state\":\"ACTIVE\",\"filenameDatetimeFormat\":\"YYYY-MM-DD/hh_mm_ssZ\",\"serviceAccountEmail\":\"writer@p.iam.gserviceaccount.com\"}}" },
        .{ "zigps-gcs-avro", "{\"bucket\":\"zigps-bucket\",\"avroConfig\":{},\"maxDuration\":\"60.000001s\"},\"ackDeadlineSeconds\":600", "600", "\"bucket\":\"zigps-bucket\",\"avroConfig\":{},\"maxDuration\":\"60.000001s\",\"state\":\"ACTIVE\"}}" },
        .{ "zigps-gcs-plain", "{\"bucket\":\"zigps-bucket\",\"textConfig\":{},\"maxBytes\":10737418240,\"maxMessages\":\"9223372036854775807\"}", "300", "\"bucket\":\"zigps-bucket\",\"textConfig\":{},\"maxDuration\":\"300s\",\"maxBytes\":\"10737418240\",\"maxMessages\":\"9223372036854775807\",\"state\":\"ACTIVE\"}}" },
        .{ "zigps-gcs-nanos", "{\"bucket\":\"zigps-bucket\",\"maxDuration\":\"61.000000001s\",\"maxBytes\":0,\"maxMessages\":0}", "62", "\"bucket\":\"zigps-bucket\",\"textConfig\":{},\"maxDuration\":\"61.000000001s\",\"state\":\"ACTIVE\"}}" },
    }) |case| {
        const body = (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/{s}", .{case[0]}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"cloudStorageConfig\":{s}}}", .{case[1]}))).body;
        try testing.expectEqualStrings(case[2], between(body, "\"ackDeadlineSeconds\":", ","));
        try testing.expectEqualStrings(case[3], tailOf(body, "\"cloudStorageConfig\":{"));
    }

    // What a create refuses. A bucket of no form production answers as
    // an outage; one that is not there, which it refuses, is taken here.
    const outage = "The service was unable to fulfill your request. Please try again. [code=8a75]";
    const duration = "The value for Cloud Storage file batching duration is out of bounds. You passed {s} in the request, but the value must be between 1m and 10m.";
    const naming = " Refer to https://cloud.google.com/storage/docs/objects#naming for more information.";
    for ([_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ "\"cloudStorageConfig\":{\"bucket\":\"gs://zigps-bucket\"}", 503, "UNAVAILABLE", outage },
        .{ "\"cloudStorageConfig\":{}", 503, "UNAVAILABLE", outage },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket/logs\"}", 503, "UNAVAILABLE", outage },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"30s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"30s"}) },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"660s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"11m"}) },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"59.999s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"59.999s"}) },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"0s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"0"}) },
        // By the same rule, not shown to production.
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"600.001s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"10m0.001s"}) },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"3661s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"1h1m1s"}) },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"-90s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"-1m30s"}) },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"0.25s\"}", 400, "INVALID_ARGUMENT", comptime std.fmt.comptimePrint(duration, .{"0.25s"}) },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"60\"}", 400, "INVALID_ARGUMENT", "Invalid value at 'maxDuration'" },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"60.s\"}", 400, "INVALID_ARGUMENT", "Invalid value at 'maxDuration'" },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"60.0000000001s\"}", 400, "INVALID_ARGUMENT", "Invalid value at 'maxDuration'" },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"60.5xs\"}", 400, "INVALID_ARGUMENT", "Invalid value at 'maxDuration'" },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxBytes\":\"999\"}", 400, "INVALID_ARGUMENT", "The value for Cloud Storage file batching bytes is out of bounds. You passed 999 in the request, but the value must be between 1000 and 10737418240." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxBytes\":\"10737418241\"}", 400, "INVALID_ARGUMENT", "The value for Cloud Storage file batching bytes is out of bounds. You passed 10737418241 in the request, but the value must be between 1000 and 10737418240." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxMessages\":\"999\"}", 400, "INVALID_ARGUMENT", "The value for Cloud Storage file batching messages is too small. You passed 999 in the request, but the minimum value is 1000." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"textConfig\":{},\"avroConfig\":{}}", 400, "INVALID_ARGUMENT", "Invalid value at 'cloud_storage_config' (oneof), oneof field 'output_format' is already set. Cannot set 'avroConfig'" },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"textConfig\":{\"writeMetadata\":true}}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"writeMetadata\": Cannot find field." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"avroConfig\":{\"nonsense\":true}}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenameSuffix\":\"logs/\"}", 400, "INVALID_ARGUMENT", "Invalid Cloud Storage filename suffix given (value=logs/): Ends with invalid character '/'." ++ naming },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenamePrefix\":\"a\\nb\"}", 400, "INVALID_ARGUMENT", "Invalid Cloud Storage filename prefix given (value=a\nb): Disallowed unicode characters present." ++ naming },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenameSuffix\":\"a\\u007fb\"}", 400, "INVALID_ARGUMENT", "Invalid Cloud Storage filename suffix given (value=a\x7fb): Disallowed unicode characters present." ++ naming },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenamePrefix\":\"" ++ comptime xs(1100) ++ "\"}", 400, "INVALID_ARGUMENT", "The sum of the lengths of the Cloud Storage subscription's filename prefix and suffix is 1100 characters, but the maximum allowed is 992." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenamePrefix\":\"" ++ comptime xs(990) ++ "\",\"filenameSuffix\":\"abc\"}", 400, "INVALID_ARGUMENT", "The sum of the lengths of the Cloud Storage subscription's filename prefix and suffix is 993 characters, but the maximum allowed is 992." },
        .{ "\"cloudStorageConfig\":{\"bucket\":\"b\"},\"enableExactlyOnceDelivery\":true", 400, "INVALID_ARGUMENT", "A subscription cannot have cloud storage config set with exactly once delivery configured." },
    }) |case| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",{s}}}", .{case[0]})), case[1], case[2], case[3]);
    }
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);
    // No time at all is `0` in every refusal of this kind: the fake's
    // reading of the others, from the one production wrote.
    try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", "{" ++ topic ++ ",\"messageRetentionDuration\":\"0s\"}"), 400, "INVALID_ARGUMENT", "The value for message retention duration is out of bounds. You passed 0 in the request, but the value must be between 10m and 744h.");
    // What production let through to its look for the bucket: a slash
    // inside a suffix, a prefix that ends in one, the bounds themselves,
    // and characters counted, not bytes, toward the 992.
    for ([_][]const u8{
        "\"filenameSuffix\":\"a/b\"",                                                  "\"filenameSuffix\":\".txt\",\"filenamePrefix\":\"a/b/\"",
        "\"maxDuration\":\"60s\"",                                                     "\"maxDuration\":\"600s\"",
        "\"maxBytes\":\"1000\"",                                                       "\"maxMessages\":\"1000\"",
        "\"filenamePrefix\":\"" ++ comptime xs(990) ++ "\",\"filenameSuffix\":\"ab\"", "\"filenamePrefix\":\"" ++ comptime accented(992) ++ "\"",
    }, 0..) |settings, i| {
        try testing.expectEqual(200, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/zigps-ok-{d}", .{i}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"cloudStorageConfig\":{{\"bucket\":\"b\",{s}}}}}", .{settings}))).status);
    }

    // A file's date and time in its name: production's verdict on every
    // format it was shown, and its words for each it refused.
    for ([_][]const u8{ "YYYY-MM-DD/hh_mm_ssZ", "YYYYMMDDhhmmss", "YYYY-MM-DDThh:mm:ss+00:00", "YYYY-MM-DDThh:mm:ssZ", "YYYY/MM/DD/hh/mm/ss", "YYYY-MM-DD-hh-mm-ss-", "-YYYY-MM-DD-hh-mm-ss", "ssmmhhDDMMYYYY", "", "YY-MM-DDThh:mm:ssZ" }, 0..) |format, i| {
        try testing.expectEqual(200, (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/subscriptions/zigps-dated-{d}", .{i}), try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"cloudStorageConfig\":{{\"bucket\":\"b\",\"filenameDatetimeFormat\":\"{s}\"}}}}", .{format}))).status);
    }
    for ([_]struct { []const u8, []const u8 }{
        .{ "nonsense", "Required year matcher not present." },
        .{ "YY-MM-DD hh:mm:ss", "Contains disallowed characters ( )." },
        .{ "YYYY-MM-DD", "Required hh matcher not present." },
        .{ "hh:mm:ss", "Required year matcher not present." },
        .{ "YYYY-MM-DD-hh-mm", "Required ss matcher not present." },
        .{ "YYYY-YYYY-MM-DD-hh-mm-ss", "More than one year matcher present." },
        .{ "YYYY-MM-DD-hh-mm-ss-ss", "More than one ss matcher present." },
        .{ "YYYY.MM.DD.hh.mm.ss", "Contains disallowed characters (.)." },
        .{ "yyyy-mm-dd-hh-mm-ss", "Required year matcher not present." },
        .{ "YYYY-MM-DDThh:mm:ssZZ", "More than one Z matcher present." },
        .{ "YYYY-MM-DDTThh:mm:ss", "More than one T matcher present." },
        .{ "YYYY-MM-DD_hh:mm:ss_x", "Contains disallowed characters (x)." },
        .{ "YYYY-MM-DD hh:mm:ssZ+00:00", "More than one timezone offset matcher present." },
        // By the rule, and in the fake's own words for these matchers.
        .{ "YYYY-DD-hh-mm-ss", "Required MM matcher not present." },
        .{ "YYYY-MM-hh-mm-ss", "Required DD matcher not present." },
        .{ "YYYY-MM-DD-hh-ss", "Required mm matcher not present." },
        .{ "YYYY-MM-MM-DD-hh-mm-ss", "More than one MM matcher present." },
        .{ "YYYY-MM-DD-DD-hh-mm-ss", "More than one DD matcher present." },
        .{ "YYYY-MM-DD-hh-hh-mm-ss", "More than one hh matcher present." },
        .{ "YYYY-MM-DD-hh-mm-mm-ss", "More than one mm matcher present." },
        .{ "YYYY-YY-MM-DD-hh-mm-ss", "More than one year matcher present." },
        .{ "YYYY-MM-DDThh:mm:ss+00:00+00:00", "More than one timezone offset matcher present." },
        .{ "YYY-MM-DDThh:mm:ssZ", "Contains disallowed characters (Y)." },
        .{ "YYYY-MM-DD-hh-mm-ss-é-x", "Contains disallowed characters (é)." },
        .{ "YYYY-MM-DD-hh-mm-ss+00:0", "Contains disallowed characters (+)." },
    }) |case| {
        try expectRefused(
            try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ topic ++ ",\"cloudStorageConfig\":{{\"bucket\":\"b\",\"filenameDatetimeFormat\":\"{s}\"}}}}", .{case[0]})),
            400,
            "INVALID_ARGUMENT",
            try std.fmt.allocPrint(a, "Invalid Cloud Storage filename datetime format given (value={s}): {s}", .{ case[0], case[1] }),
        );
    }

    // One update that names every kind, as production was put through:
    // what it gives is the subscription's delivery, whole.
    var plain = try b.client.subscription("zigps-all").create(.{ .topic_id = "zigps-t" });
    plain.deinit();
    const all = "projects/p/subscriptions/zigps-all";
    const kinds = ",\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}";
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-all","topic":"projects/p/topics/zigps-t","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"bigqueryConfig":{"table":"p.zigps_d.msgs","writeMetadata":true,"state":"ACTIVE"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, all, "{\"subscription\":{\"bigqueryConfig\":{\"table\":\"p.zigps_d.msgs\",\"writeMetadata\":true}}" ++ kinds)).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-all","topic":"projects/p/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"bigqueryConfig":{"table":"p.zigps_d.msgs","writeMetadata":true,"state":"ACTIVE"},"state":"ACTIVE"}
    , (try b.raw(a, .GET, all, "")).body);
    // Replaced whole: what the new one does not say is gone.
    try testing.expectEqualStrings("\"table\":\"p.zigps_d.msgs\",\"state\":\"ACTIVE\"", between((try b.raw(a, .PATCH, all, "{\"subscription\":{\"bigqueryConfig\":{\"table\":\"p.zigps_d.msgs\"}}" ++ kinds)).body, "\"bigqueryConfig\":{", "},\"state\""));
    // To Cloud Storage: the deadline goes up to the five minutes filled
    // in, and the BigQuery config is gone.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-all","topic":"projects/p/topics/zigps-t","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":300,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE","cloudStorageConfig":{"bucket":"zigps-bucket","textConfig":{},"maxDuration":"300s","state":"ACTIVE"}}
    , (try b.raw(a, .PATCH, all, "{\"subscription\":{\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\"}}" ++ kinds)).body);
    // What production learns by writing files, the test says.
    b.fake.setExportState("p", "zigps-all", .not_found);
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .GET, all, "")).body, "\"state\":\"RESOURCE_ERROR\",\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\",\"textConfig\":{},\"maxDuration\":\"300s\",\"state\":\"NOT_FOUND\"}}"));
    {
        var read = try b.client.subscription("zigps-all").get();
        defer read.deinit();
        try testing.expectEqual(types.ExportState.not_found, read.value.delivery.cloud_storage.state);
        try testing.expectEqual(types.SubscriptionInfo.State.resource_error, read.value.state);
    }
    b.fake.setExportState("p", "zigps-all", .unknown);
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .GET, all, "")).body, "\"state\":\"ACTIVE\",\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\",\"textConfig\":{},\"maxDuration\":\"300s\"}}"));
    // A pull is refused there as well: the fake's own. Its push config
    // by itself production was not asked to change.
    try expectRefused(try b.raw(a, .POST, all ++ ":pull", "{\"maxMessages\":1}"), 400, "FAILED_PRECONDITION", "This method is not supported for this subscription type.");
    try expectRefused(try b.raw(a, .POST, all ++ ":modifyPushConfig", "{\"pushConfig\":{}}"), 501, "UNIMPLEMENTED", "fake: modifyPushConfig on a subscription that exports is not modelled yet");
    // The deadline is held to the file's duration by a later update too:
    // the fake's own.
    try testing.expectEqualStrings("300", between((try b.raw(a, .PATCH, all, "{\"subscription\":{\"ackDeadlineSeconds\":10},\"updateMask\":\"ackDeadlineSeconds\"}")).body, "\"ackDeadlineSeconds\":", ","));
    // To push: the deadline stays where it was.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-all","topic":"projects/p/topics/zigps-t","pushConfig":{"pushEndpoint":"https://example.com/zigps-push","attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":300,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, all, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/zigps-push\"}}" ++ kinds)).body);
    // Two kinds given are refused, and nothing changes.
    try expectRefused(try b.raw(a, .PATCH, all, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/zigps-push\"},\"cloudStorageConfig\":{\"bucket\":\"zigps-bucket\"}}" ++ kinds), 400, "INVALID_ARGUMENT", "Cannot create a subscription with multiple configurations. Only at most one of PushConfig, CloudStorageConfig can be specified.");
    // A kind the mask does not name stays, and a second beside it is
    // refused the same way: the fake's own, production was not asked.
    try expectRefused(try b.raw(a, .PATCH, all, "{\"subscription\":{\"bigqueryConfig\":{\"table\":\"p.d.t\"}},\"updateMask\":\"bigqueryConfig\"}"), 400, "INVALID_ARGUMENT", "Cannot create a subscription with multiple configurations. Only at most one of PushConfig, BigQueryConfig can be specified.");
    try testing.expectEqualStrings("{\"pushEndpoint\":\"https://example.com/zigps-push\"}", pushConfigOf((try b.raw(a, .GET, all, "")).body));
    // The mask in the other spelling.
    try testing.expectEqualStrings("{\"pushEndpoint\":\"https://example.com/zigps-push4\",\"attributes\":{\"x-goog-version\":\"v1\"}}", pushConfigOf((try b.raw(a, .PATCH, all, "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/zigps-push4\"}},\"updateMask\":\"push_config,bigquery_config,cloud_storage_config\"}")).body));
    // A Bigtable config named and not given changes nothing; one given
    // the fake has no answer for.
    try testing.expectEqualStrings("{\"pushEndpoint\":\"https://example.com/zigps-push4\",\"attributes\":{\"x-goog-version\":\"v1\"}}", pushConfigOf((try b.raw(a, .PATCH, all, "{\"subscription\":{},\"updateMask\":\"bigtableConfig\"}")).body));
    try testing.expectEqual(501, (try b.raw(a, .PATCH, all, "{\"subscription\":{\"bigtableConfig\":{}},\"updateMask\":\"bigtableConfig\"}")).status);
    try expectRefused(try b.raw(a, .PATCH, all, "{\"subscription\":{},\"updateMask\":\"cloudStorageConfig.bucket\"}"), 501, "UNIMPLEMENTED", "fake: cloudStorageConfig.bucket is not modelled yet");
    // None given: it pulls.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-all","topic":"projects/p/topics/zigps-t","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":300,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PATCH, all, "{\"subscription\":{}" ++ kinds)).body);
    try testing.expectEqualStrings("{}", pushConfigOf((try b.raw(a, .GET, all, "")).body));
    // A refused config changes nothing.
    try expectRefused(try b.raw(a, .PATCH, all, "{\"subscription\":{\"cloudStorageConfig\":{\"bucket\":\"gs://b\"}},\"updateMask\":\"cloud_storage_config\"}"), 503, "UNAVAILABLE", outage);
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .GET, all, "")).body, "\"state\":\"ACTIVE\"}"));

    // Through the client.
    var files = try b.client.subscription("files").create(.{ .topic_id = "zigps-t", .delivery = .{ .cloud_storage = .{ .bucket = "zigps-bucket", .filename_prefix = "in/", .format = .{ .avro = .{ .write_metadata = true } }, .max_duration = .fromSeconds(120), .max_bytes = 2000 } } });
    defer files.deinit();
    const config = files.value.delivery.cloud_storage.config;
    try testing.expectEqualStrings("zigps-bucket", config.bucket);
    try testing.expectEqualStrings("in/", config.filename_prefix);
    try testing.expect(config.format.avro.write_metadata);
    try testing.expectEqual(std.Io.Duration.fromSeconds(120), config.max_duration.?);
    try testing.expectEqual(2000, config.max_bytes);
    try testing.expectEqual(120, files.value.ack_deadline_seconds);
    try testing.expectEqual(types.ExportState.active, files.value.delivery.cloud_storage.state);
    {
        var read = try b.client.subscription("files").get();
        defer read.deinit();
        try testing.expectEqualStrings("zigps-bucket", read.value.delivery.cloud_storage.config.bucket);
        try testing.expectEqualStrings("in/", read.value.delivery.cloud_storage.config.filename_prefix);
    }
    var rows = try b.client.subscription("files").update(.{ .delivery = .{ .bigquery = .{ .table = "p.d.t" } } });
    defer rows.deinit();
    try testing.expectEqualStrings("p.d.t", rows.value.delivery.bigquery.config.table);
}

const upper_code = "function upper(message, metadata) { message.data = message.data.toUpperCase(); message.attributes['seen'] = 'yes'; return message; }";
const upper_function = "\"javascriptUdf\":{\"functionName\":\"upper\",\"code\":\"" ++ upper_code ++ "\"}";

/// A list of transforms `f0`, `f1` and so on, the last `disabled` of them
/// disabled.
fn functionList(a: Allocator, enabled: usize, disabled: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (0..enabled + disabled) |i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{{\"javascriptUdf\":{{\"functionName\":\"f{d}\",\"code\":\"function f{d}(message, metadata) {{ return message; }}\"}}{s}}}", .{ i, i, if (i < enabled) "" else ",\"disabled\":true" });
    }
    try out.append(a, ']');
    return out.items;
}

test "message transforms: kept on a topic and a subscription as production reads them back, and run on nothing" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const t1 = "projects/p/topics/zigps-t1";

    // Read back as written, by a create and by a read.
    const as_made = "{\"name\":\"projects/p/topics/zigps-t1\",\"messageTransforms\":[{" ++ upper_function ++ "}]}";
    try testing.expectEqualStrings(as_made, (try b.raw(a, .PUT, t1, "{\"messageTransforms\":[{" ++ upper_function ++ "}]}")).body);
    try testing.expectEqualStrings(as_made, (try b.raw(a, .GET, t1, "")).body);
    // `disabled` and `enabled` are each read back when true, in that
    // order whatever the request's; `enabled: false` reads back as
    // nothing.
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "zigps-t12", ",\"disabled\":true", ",\"disabled\":true" },
        .{ "zigps-t11", ",\"enabled\":false", "" },
        .{ "zigps-t13", ",\"enabled\":true,\"disabled\":true", ",\"enabled\":true,\"disabled\":true" },
        .{ "zigps-t14", ",\"disabled\":true,\"enabled\":true", ",\"enabled\":true,\"disabled\":true" },
        .{ "zigps-t15", ",\"disabled\":false,\"enabled\":true", ",\"enabled\":true" },
    }) |case| {
        const body = (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{case[0]}), try std.mem.concat(a, u8, &.{ "{\"messageTransforms\":[{" ++ upper_function, case[1], "}]}" }))).body;
        try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "{\"name\":\"projects/p/topics/", case[0], "\",\"messageTransforms\":[{" ++ upper_function, case[2], "}]}" }), body);
    }
    // On a subscription they are written last, after its state.
    try testing.expectEqualStrings(
        "{\"name\":\"projects/p/subscriptions/zigps-s22\",\"topic\":\"projects/p/topics/zigps-t1\",\"pushConfig\":{},\"ackDeadlineSeconds\":10,\"messageRetentionDuration\":\"604800s\",\"expirationPolicy\":{\"ttl\":\"2678400s\"},\"state\":\"ACTIVE\",\"messageTransforms\":[{" ++ upper_function ++ "}]}",
        (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-s22", "{\"topic\":\"projects/p/topics/zigps-t1\",\"messageTransforms\":[{" ++ upper_function ++ "}]}")).body,
    );

    // Five that are not disabled, and as many more that are.
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/zigps-five", try std.fmt.allocPrint(a, "{{\"messageTransforms\":{s}}}", .{try functionList(a, 5, 0)}))).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/zigps-twelve", try std.fmt.allocPrint(a, "{{\"messageTransforms\":{s}}}", .{try functionList(a, 5, 7)}))).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/zigps-none", "{\"messageTransforms\":[]}")).status);
    // Code of 20,480 bytes, and no more.
    const big = "function big(message, metadata) { return message; }//";
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/zigps-big", "{\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"big\",\"code\":\"" ++ big ++ comptime xs(20_480 - big.len) ++ "\"}}]}")).status);

    // What a create refuses, of a topic and of a subscription alike.
    const not_found = "Provided message transform configuration is invalid: Failed to create JavaScript UDF: `upper`. Failed to find function in provided code";
    const twice = "The request contains multiple JavaScript UDFs with the function name: upper. Each JavaScript UDF must have a unique function name.";
    for ([_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ try functionList(a, 6, 0), 400, "INVALID_ARGUMENT", "The request exceeds the maximum number of enabled message transforms. Maximum enabled transforms: 5. Enabled transforms: 6." },
        .{ try functionList(a, 7, 2), 400, "INVALID_ARGUMENT", "The request exceeds the maximum number of enabled message transforms. Maximum enabled transforms: 5. Enabled transforms: 7." },
        // A name twice, disabled or not.
        .{ "[{" ++ upper_function ++ "},{" ++ upper_function ++ "}]", 400, "INVALID_ARGUMENT", twice },
        .{ "[{" ++ upper_function ++ ",\"disabled\":true},{" ++ upper_function ++ "}]", 400, "INVALID_ARGUMENT", twice },
        .{ "[{" ++ upper_function ++ ",\"disabled\":true},{" ++ upper_function ++ ",\"disabled\":true}]", 400, "INVALID_ARGUMENT", twice },
        .{ "[{\"javascriptUdf\":{\"code\":\"" ++ upper_code ++ "\"}}]", 400, "INVALID_ARGUMENT", "The request contains a JavaScript UDF with an empty function name. Function names must be non-empty." },
        .{ "[{}]", 400, "INVALID_ARGUMENT", "The request contains a MessageTransform with a missing message transform type." },
        .{ "[{\"disabled\":true}]", 400, "INVALID_ARGUMENT", "The request contains a MessageTransform with a missing message transform type." },
        .{ "[{\"javascriptUdf\":{\"functionName\":\"big\",\"code\":\"" ++ big ++ comptime xs(20_481 - big.len) ++ "\"}}]", 400, "INVALID_ARGUMENT", "The `code` field of a JavaScript UDF exceeded the maximum allowed size of 20480 bytes. Code size: 20481. Function name: big." },
        // The fake reads no JavaScript: code that is none at all cannot
        // hold the function, and that much it says as production did.
        .{ "[{\"javascriptUdf\":{\"functionName\":\"upper\"}}]", 400, "FAILED_PRECONDITION", not_found },
        .{ "[{\"javascriptUdf\":{\"functionName\":\"upper\",\"code\":\"\"},\"disabled\":true}]", 400, "FAILED_PRECONDITION", not_found },
        // The two other kinds, empty as production was shown them; with
        // something in them the fake has no answer.
        .{ "[{\"aiInference\":{}}]", 400, "INVALID_ARGUMENT", "The request contains an AI Inference SMT without a set endpoint." },
        .{ "[{\"compression\":{}}]", 400, "INVALID_ARGUMENT", "Compression algorithm is required for Compression message transform." },
        .{ "[{\"aiInference\":{\"endpoint\":\"e\"}}]", 501, "UNIMPLEMENTED", "fake: an AI inference transform is not modelled yet" },
        .{ "[{\"compression\":{\"gzip\":{}}}]", 501, "UNIMPLEMENTED", "fake: a compression transform is not modelled yet" },
        .{ "[{\"javascriptUdf\":{\"functionName\":\"f\",\"code\":\"x\",\"nonsense\":\"x\"}}]", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "[{\"nonsense\":{}}]", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "[{\"javascriptUdf\":\"upper\"}]", 400, "INVALID_ARGUMENT", "Invalid value at 'javascriptUdf'" },
        .{ "[{\"nonsense\":1}]", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "{}", 400, "INVALID_ARGUMENT", "Invalid value at 'messageTransforms'" },
    }) |case| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-bad", try std.fmt.allocPrint(a, "{{\"messageTransforms\":{s}}}", .{case[0]})), case[1], case[2], case[3]);
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{\"topic\":\"projects/p/topics/zigps-t1\",\"messageTransforms\":{s}}}", .{case[0]})), case[1], case[2], case[3]);
    }
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/topics/zigps-bad", "")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);

    // An update replaces the list whole, and with none in the body
    // clears it.
    const drop = "{\"javascriptUdf\":{\"functionName\":\"drop\",\"code\":\"function drop(message, metadata) { if (message.data === 'drop') return null; return message; }\"}}";
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-t1\",\"messageTransforms\":[" ++ drop ++ "]}", (try b.raw(a, .PATCH, t1, "{\"topic\":{\"messageTransforms\":[" ++ drop ++ "]},\"updateMask\":\"messageTransforms\"}")).body);
    // A refused one changes nothing.
    try expectRefused(try b.raw(a, .PATCH, t1, "{\"topic\":{\"messageTransforms\":[{}]},\"updateMask\":\"message_transforms\"}"), 400, "INVALID_ARGUMENT", "The request contains a MessageTransform with a missing message transform type.");
    try expectRefused(try b.raw(a, .PATCH, t1, "{\"topic\":{},\"updateMask\":\"messageTransforms.disabled\"}"), 501, "UNIMPLEMENTED", "fake: messageTransforms.disabled is not modelled yet");
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-t1\",\"messageTransforms\":[" ++ drop ++ "]}", (try b.raw(a, .GET, t1, "")).body);

    // No function runs: what this one would drop goes through, as it is.
    {
        var sent = try b.client.topic("zigps-t1").publish(&.{.{ .data = "drop", .attributes = &.{.{ .key = "k", .value = "v" }} }}, .{});
        sent.deinit();
        var got = try b.client.subscription("zigps-s22").pull(.{ .return_immediately = true });
        defer got.deinit();
        try testing.expectEqual(1, got.value.messages.len);
        try testing.expectEqualStrings("drop", got.value.messages[0].data);
        try testing.expectEqual(1, got.value.messages[0].attributes.len);
    }
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-t1\"}", (try b.raw(a, .PATCH, t1, "{\"topic\":{},\"updateMask\":\"messageTransforms\"}")).body);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-t1\"}", (try b.raw(a, .GET, t1, "")).body);

    // A subscription's, by the mask in either spelling.
    const s22 = "projects/p/subscriptions/zigps-s22";
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .PATCH, s22, "{\"subscription\":{\"messageTransforms\":[" ++ drop ++ "]},\"updateMask\":\"messageTransforms\"}")).body, ",\"state\":\"ACTIVE\",\"messageTransforms\":[" ++ drop ++ "]}"));
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .PATCH, s22, "{\"subscription\":{\"messageTransforms\":[{" ++ upper_function ++ ",\"disabled\":true}]},\"updateMask\":\"message_transforms\"}")).body, ",\"state\":\"ACTIVE\",\"messageTransforms\":[{" ++ upper_function ++ ",\"disabled\":true}]}"));
    try expectRefused(try b.raw(a, .PATCH, s22, "{\"subscription\":{\"messageTransforms\":" ++ "[{" ++ upper_function ++ "},{" ++ upper_function ++ "}]" ++ "},\"updateMask\":\"messageTransforms\"}"), 400, "INVALID_ARGUMENT", twice);
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .GET, s22, "")).body, ",\"messageTransforms\":[{" ++ upper_function ++ ",\"disabled\":true}]}"));
    try expectRefused(try b.raw(a, .PATCH, s22, "{\"subscription\":{},\"updateMask\":\"messageTransforms.disabled\"}"), 501, "UNIMPLEMENTED", "fake: messageTransforms.disabled is not modelled yet");
    try testing.expect(std.mem.endsWith(u8, (try b.raw(a, .PATCH, s22, "{\"subscription\":{},\"updateMask\":\"messageTransforms\"}")).body, ",\"state\":\"ACTIVE\"}"));

    // Through the client.
    var typed = try b.client.topic("typed").create(.{ .message_transforms = &.{
        .{ .kind = .{ .javascript_udf = .{ .function_name = "same", .code = "function same(message, metadata) { return message; }" } } },
        .{ .kind = .{ .javascript_udf = .{ .function_name = "off", .code = "function off(message, metadata) { return null; }" } }, .disabled = true },
    } });
    defer typed.deinit();
    try testing.expectEqual(2, typed.value.message_transforms.len);
    try testing.expectEqualStrings("same", typed.value.message_transforms[0].kind.javascript_udf.function_name);
    try testing.expect(!typed.value.message_transforms[0].disabled);
    try testing.expect(typed.value.message_transforms[1].disabled);
    {
        var read = try b.client.topic("typed").get();
        defer read.deinit();
        try testing.expectEqualStrings("same", read.value.message_transforms[0].kind.javascript_udf.function_name);
        try testing.expectEqualStrings("function off(message, metadata) { return null; }", read.value.message_transforms[1].kind.javascript_udf.code);
    }
    var cleared = try b.client.topic("typed").update(.{ .message_transforms = &.{} });
    defer cleared.deinit();
    try testing.expectEqual(0, cleared.value.message_transforms.len);
    var worker = try b.client.subscription("worker").create(.{ .topic_id = "typed", .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{ .function_name = "same", .code = "function same(message, metadata) { return message; }" } } }} });
    worker.deinit();
    var changed = try b.client.subscription("worker").update(.{ .message_transforms = &.{.{ .kind = .{ .javascript_udf = .{ .function_name = "other", .code = "function other(message, metadata) { return message; }" } }, .disabled = true }} });
    changed.deinit();
    var read = try b.client.subscription("worker").get();
    defer read.deinit();
    try testing.expectEqual(1, read.value.message_transforms.len);
    try testing.expectEqualStrings("other", read.value.message_transforms[0].kind.javascript_udf.function_name);
    try testing.expect(read.value.message_transforms[0].disabled);
}

test "import topics: a source kept and read back as production's, with a state the test sets, and nothing imported" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const settings = "\"ingestionDataSourceSettings\":";

    // The source's state is the first thing it holds.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-i1","ingestionDataSourceSettings":{"cloudStorage":{"state":"ACTIVE","bucket":"zigps-g","textFormat":{"delimiter":"|"}}}}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-i1", "{" ++ settings ++ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"|\"}}}}")).body);
    // A delimiter is one byte, whatever byte.
    const Read = struct { ingestionDataSourceSettings: struct { cloudStorage: struct { textFormat: struct { delimiter: []const u8 } } } };
    for ([_][]const u8{ "\\t", "\\r", "\\u0000", "\\u007f", " " }, [_][]const u8{ "\t", "\r", "\x00", "\x7f", " " }, 0..) |sent, delimiter, i| {
        const body = (try b.raw(a, .PUT, try std.fmt.allocPrint(a, "projects/p/topics/zigps-d{d}", .{i}), try std.fmt.allocPrint(a, "{{" ++ settings ++ "{{\"cloudStorage\":{{\"bucket\":\"zigps-g\",\"textFormat\":{{\"delimiter\":\"{s}\"}}}}}}}}", .{sent}))).body;
        try testing.expectEqualStrings(delimiter, (try std.json.parseFromSliceLeaky(Read, a, body, .{ .ignore_unknown_fields = true })).ingestionDataSourceSettings.cloudStorage.textFormat.delimiter);
    }

    // With none said the delimiter is a line break, which a create's
    // answer fills in. A read has the topic's own state as well, right
    // after its name; the answer to a create has none.
    const i8_ = "projects/p/topics/zigps-i8";
    const source = "{\"cloudStorage\":{\"state\":\"ACTIVE\",\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"\\n\"},\"matchGlob\":\"zigps/**\"},\"platformLogsSettings\":{\"severity\":\"DEBUG\"}}";
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-i8\"," ++ settings ++ source ++ "}", (try b.raw(a, .PUT, i8_, "{" ++ settings ++ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{},\"matchGlob\":\"zigps/**\"},\"platformLogsSettings\":{\"severity\":\"DEBUG\"}}}")).body);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-i8\",\"state\":\"ACTIVE\"," ++ settings ++ source ++ "}", (try b.raw(a, .GET, i8_, "")).body);
    // A project's list reads as a read does: the fake's own.
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/topics", "")).body, "{\"name\":\"projects/p/topics/zigps-i8\",\"state\":\"ACTIVE\"," ++ settings ++ source ++ "}") != null);

    // What production finds at the source, the test says: here what it
    // said four minutes on, of a topic its service agent could not
    // publish to.
    b.fake.setIngestionState("p", "zigps-i8", .publish_permission_denied);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-i8","state":"INGESTION_RESOURCE_ERROR","ingestionDataSourceSettings":{"cloudStorage":{"state":"PUBLISH_PERMISSION_DENIED","bucket":"zigps-g","textFormat":{"delimiter":"\n"},"matchGlob":"zigps/**"},"platformLogsSettings":{"severity":"DEBUG"}}}
    , (try b.raw(a, .GET, i8_, "")).body);
    {
        var read = try b.client.topic("zigps-i8").get();
        defer read.deinit();
        try testing.expectEqual(types.TopicInfo.State.ingestion_resource_error, read.value.state);
        try testing.expectEqual(types.IngestionState.publish_permission_denied, read.value.ingestion.?.state);
        try testing.expectEqual(types.Ingestion.LogSeverity.debug, read.value.ingestion.?.log_severity);
        try testing.expectEqualStrings("zigps/**", read.value.ingestion.?.source.?.cloud_storage.match_glob);
    }
    for ([_]struct { types.IngestionState, []const u8 }{
        .{ .permission_denied, "\"state\":\"INGESTION_RESOURCE_ERROR\"," ++ settings ++ "{\"cloudStorage\":{\"state\":\"CLOUD_STORAGE_PERMISSION_DENIED\"," },
        .{ .bucket_not_found, "\"state\":\"INGESTION_RESOURCE_ERROR\"," ++ settings ++ "{\"cloudStorage\":{\"state\":\"BUCKET_NOT_FOUND\"," },
        .{ .too_many_objects, "\"state\":\"INGESTION_RESOURCE_ERROR\"," ++ settings ++ "{\"cloudStorage\":{\"state\":\"TOO_MANY_OBJECTS\"," },
        .{ .conflicting_region_constraints, "\"state\":\"INGESTION_RESOURCE_ERROR\"," ++ settings ++ "{\"cloudStorage\":{\"state\":\"CONFLICTING_REGION_CONSTRAINTS\"," },
        // No word at all, as an emulator says none.
        .{ .unknown, "\"state\":\"ACTIVE\"," ++ settings ++ "{\"cloudStorage\":{\"bucket\":" },
        .{ .active, "\"state\":\"ACTIVE\"," ++ settings ++ "{\"cloudStorage\":{\"state\":\"ACTIVE\"," },
    }) |case| {
        b.fake.setIngestionState("p", "projects/p/topics/zigps-i8", case[0]);
        try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, i8_, "")).body, case[1]) != null);
    }
    // Said of a topic that imports nothing, or of none, it is nothing.
    b.fake.setIngestionState("p", "zigps-nope", .bucket_not_found);
    var plain = try b.client.topic("plain").create(.{});
    plain.deinit();
    b.fake.setIngestionState("p", "plain", .bucket_not_found);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/plain\"}", (try b.raw(a, .GET, "projects/p/topics/plain", "")).body);

    // `gs://` before a bucket's name is taken, and read back without. A
    // time reads back as proto3 writes one.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-i10","ingestionDataSourceSettings":{"cloudStorage":{"state":"ACTIVE","bucket":"zigps-g","avroFormat":{},"minimumObjectCreateTime":"2030-01-01T00:00:00Z"}}}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-i10", "{" ++ settings ++ "{\"cloudStorage\":{\"bucket\":\"gs://zigps-g\",\"avroFormat\":{},\"minimumObjectCreateTime\":\"2030-01-01T00:00:00Z\"}}}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-i11","ingestionDataSourceSettings":{"cloudStorage":{"state":"ACTIVE","bucket":"zigps-g","pubsubAvroFormat":{},"minimumObjectCreateTime":"2029-12-31T23:00:00.500Z","matchGlob":"**"},"platformLogsSettings":{"severity":"WARNING"}}}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-i11", "{" ++ settings ++ "{\"platform_logs_settings\":{\"severity\":\"WARNING\"},\"cloud_storage\":{\"match_glob\":\"**\",\"minimum_object_create_time\":\"2030-01-01T00:00:00.5+01:00\",\"pubsub_avro_format\":{},\"state\":\"BUCKET_NOT_FOUND\",\"bucket\":\"zigps-g\"}}}")).body);

    // An update replaces the settings whole, the logging with them, and
    // what is new is active again. Its answer has no state for the topic.
    b.fake.setIngestionState("p", "zigps-i8", .bucket_not_found);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-i8","ingestionDataSourceSettings":{"cloudStorage":{"state":"ACTIVE","bucket":"zigps-g","pubsubAvroFormat":{}}}}
    , (try b.raw(a, .PATCH, i8_, "{\"topic\":{" ++ settings ++ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"pubsubAvroFormat\":{}}}},\"updateMask\":\"ingestionDataSourceSettings\"}")).body);
    // With no delimiter said, the answer to an update leaves it out,
    // where a read says it.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-i8","ingestionDataSourceSettings":{"cloudStorage":{"state":"ACTIVE","bucket":"zigps-g","textFormat":{},"matchGlob":"zigps/**"}}}
    , (try b.raw(a, .PATCH, i8_, "{\"topic\":{" ++ settings ++ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{},\"matchGlob\":\"zigps/**\"}}},\"updateMask\":\"ingestion_data_source_settings\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-i8","state":"ACTIVE","ingestionDataSourceSettings":{"cloudStorage":{"state":"ACTIVE","bucket":"zigps-g","textFormat":{"delimiter":"\n"},"matchGlob":"zigps/**"}}}
    , (try b.raw(a, .GET, i8_, "")).body);
    // A refused one changes nothing.
    try testing.expectEqual(400, (try b.raw(a, .PATCH, i8_, "{\"topic\":{" ++ settings ++ "{}},\"updateMask\":\"ingestionDataSourceSettings\"}")).status);
    try expectRefused(try b.raw(a, .PATCH, i8_, "{\"topic\":{},\"updateMask\":\"ingestionDataSourceSettings.cloudStorage\"}"), 501, "UNIMPLEMENTED", "fake: ingestionDataSourceSettings.cloudStorage is not modelled yet");
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, i8_, "")).body, "\"matchGlob\":\"zigps/**\"") != null);
    // With none in the body the topic imports nothing, as any topic; and
    // a topic that imported nothing takes a source.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-i8\"}", (try b.raw(a, .PATCH, i8_, "{\"topic\":{},\"updateMask\":\"ingestionDataSourceSettings\"}")).body);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-i8\"}", (try b.raw(a, .GET, i8_, "")).body);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/plain\"}", (try b.raw(a, .PATCH, "projects/p/topics/plain", "{\"topic\":{},\"updateMask\":\"ingestionDataSourceSettings\"}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/plain","ingestionDataSourceSettings":{"cloudStorage":{"state":"ACTIVE","bucket":"zigps-g","textFormat":{"delimiter":"\n"}}}}
    , (try b.raw(a, .PATCH, "projects/p/topics/plain", "{\"topic\":{" ++ settings ++ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"\\n\"}}}},\"updateMask\":\"ingestionDataSourceSettings\"}")).body);

    // What a create refuses. The fake has no buckets: one that is not
    // there, or that Pub/Sub may not read, is taken here.
    const delimiter = "The ingestion data source state and/or configuration is not sufficient for ingestion: IngestionDataSourceSettings::Gcs::text_format::delimiter must be a single character.";
    const no_source = "Cloud Pub/Sub received invalid argument/s for the ingestion data source: The request's IngestionDataSourceSettings is missing a data source type.";
    const kinesis = "The ingestion data source state and/or configuration is not sufficient for ingestion: Missing a required field - IngestionDataSourceSettings::AwsKinesis::";
    for ([_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"ab\"}}}", 400, "FAILED_PRECONDITION", delimiter },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"\"}}}", 400, "FAILED_PRECONDITION", delimiter },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"€\"}}}", 400, "FAILED_PRECONDITION", delimiter },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"é\"}}}", 400, "FAILED_PRECONDITION", delimiter },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"\\r\\n\"}}}", 400, "FAILED_PRECONDITION", delimiter },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g/logs\",\"textFormat\":{}}}", 400, "INVALID_ARGUMENT", "Cloud Pub/Sub received invalid argument/s for the ingestion data source: projects/-/buckets/zigps-g/logs is not a valid resource name.." },
        .{ "{\"cloudStorage\":{\"bucket\":\"gs://zigps-g/logs\",\"textFormat\":{}}}", 400, "INVALID_ARGUMENT", "Cloud Pub/Sub received invalid argument/s for the ingestion data source: projects/-/buckets/zigps-g/logs is not a valid resource name.." },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{},\"minimumObjectCreateTime\":\"yesterday\"}}", 400, "INVALID_ARGUMENT", "Invalid value at 'ingestion_data_source_settings.cloud_storage.minimum_object_create_time' (type.googleapis.com/google.protobuf.Timestamp), Field 'minimumObjectCreateTime', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset." },
        .{ "{\"platformLogsSettings\":{\"severity\":\"WARNING\"}}", 400, "INVALID_ARGUMENT", no_source },
        .{ "{}", 400, "INVALID_ARGUMENT", no_source },
        .{ "{\"awsKinesis\":{}}", 400, "FAILED_PRECONDITION", kinesis ++ "stream_arn.." },
        // Its other fields in turn: the fake's own.
        .{ "{\"awsKinesis\":{\"streamArn\":\"s\",\"awsRoleArn\":\"r\"}}", 400, "FAILED_PRECONDITION", kinesis ++ "consumer_arn.." },
        .{ "{\"awsKinesis\":{\"streamArn\":\"s\",\"consumerArn\":\"c\",\"awsRoleArn\":\"r\"}}", 400, "FAILED_PRECONDITION", kinesis ++ "gcp_service_account.." },
        // Two formats, as two sources are refused: by the rule.
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{},\"avroFormat\":{}}}", 400, "INVALID_ARGUMENT", "Invalid value at 'ingestion_data_source_settings.cloud_storage' (oneof), oneof field 'input_format' is already set. Cannot set 'avroFormat'" },
        // What production looked for the bucket before it would say.
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\"}}", 501, "UNIMPLEMENTED", "fake: a Cloud Storage source with no format is not modelled yet" },
        .{ "{\"cloudStorage\":{\"textFormat\":{}}}", 501, "UNIMPLEMENTED", "fake: a Cloud Storage source with no bucket is not modelled yet" },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"avroFormat\":{\"delimiter\":\"|\"}}}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"delimiter\": Cannot find field." },
        .{ "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{}},\"platformLogsSettings\":{\"severity\":\"LOUD\"}}", 400, "INVALID_ARGUMENT", "Invalid value at 'severity'" },
        .{ "{\"nonsense\":{}}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "{\"awsMsk\":{\"nonsense\":\"x\"}}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "{\"cloudStorage\":\"zigps-g\"}", 400, "INVALID_ARGUMENT", "Invalid value at 'cloudStorage'" },
    }) |case| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-bad", try std.fmt.allocPrint(a, "{{" ++ settings ++ "{s}}}", .{case[0]})), case[1], case[2], case[3]);
    }
    // Two sources, in production's whole body: refused before either is
    // looked into, and the second named.
    try testing.expectEqualStrings(
        \\{"error":{"code":400,"message":"Invalid value at 'ingestion_data_source_settings' (oneof), oneof field 'source' is already set. Cannot set 'cloudStorage'","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"ingestion_data_source_settings","description":"Invalid value at 'ingestion_data_source_settings' (oneof), oneof field 'source' is already set. Cannot set 'cloudStorage'"}]}]}}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-bad", "{" ++ settings ++ "{\"awsKinesis\":{},\"cloudStorage\":{\"bucket\":\"b\",\"textFormat\":{}}}}")).body);
    try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-bad", "{" ++ settings ++ "{\"cloudStorage\":{\"bucket\":\"b\",\"textFormat\":{}},\"confluentCloud\":{}}}"), 400, "INVALID_ARGUMENT", "Invalid value at 'ingestion_data_source_settings' (oneof), oneof field 'source' is already set. Cannot set 'confluentCloud'");
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/topics/zigps-bad", "")).status);

    // A source outside Google is kept as it is given. Production refused
    // each the probes could offer, for what was at the other end, so how
    // it reads one back is the fake's own: as it reads a bucket back.
    try testing.expectEqualStrings(
        \\{"name":"projects/p/topics/zigps-kinesis","ingestionDataSourceSettings":{"awsKinesis":{"state":"ACTIVE","streamArn":"arn:aws:kinesis:us-east-1:111111111111:stream/zigps","consumerArn":"arn:aws:kinesis:us-east-1:111111111111:stream/zigps/consumer/c:1","awsRoleArn":"arn:aws:iam::111111111111:role/zigps","gcpServiceAccount":"zig-gcp@p.iam.gserviceaccount.com"}}}
    , (try b.raw(a, .PUT, "projects/p/topics/zigps-kinesis", "{" ++ settings ++ "{\"aws_kinesis\":{\"gcp_service_account\":\"zig-gcp@p.iam.gserviceaccount.com\",\"aws_role_arn\":\"arn:aws:iam::111111111111:role/zigps\",\"consumer_arn\":\"arn:aws:kinesis:us-east-1:111111111111:stream/zigps/consumer/c:1\",\"stream_arn\":\"arn:aws:kinesis:us-east-1:111111111111:stream/zigps\",\"state\":\"STREAM_NOT_FOUND\"}}}")).body);
    b.fake.setIngestionState("p", "zigps-kinesis", .permission_denied);
    try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, "projects/p/topics/zigps-kinesis", "")).body, "\"state\":\"INGESTION_RESOURCE_ERROR\"," ++ settings ++ "{\"awsKinesis\":{\"state\":\"KINESIS_PERMISSION_DENIED\",\"streamArn\"") != null);
    // The fields of the other three are not asked for: production's name
    // for them was never seen.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-msk\"," ++ settings ++ "{\"awsMsk\":{\"state\":\"ACTIVE\"}}}", (try b.raw(a, .PUT, "projects/p/topics/zigps-msk", "{" ++ settings ++ "{\"awsMsk\":{}}}")).body);
    // Each of the four through the client, whose decoder is no kin of
    // the fake's writer, with the word each has for being refused there.
    {
        var hubs = try b.client.topic("hubs").create(.{ .ingestion = .{ .source = .{ .azure_event_hubs = .{ .resource_group = "rg", .namespace = "ns", .event_hub = "eh", .client_id = "c", .tenant_id = "t", .subscription_id = "s", .gcp_service_account = "a@p.iam.gserviceaccount.com" } }, .log_severity = .info } });
        defer hubs.deinit();
        const source_read = hubs.value.ingestion.?.source.?.azure_event_hubs;
        try testing.expectEqualStrings("rg", source_read.resource_group);
        try testing.expectEqualStrings("ns", source_read.namespace);
        try testing.expectEqualStrings("eh", source_read.event_hub);
        try testing.expectEqualStrings("c", source_read.client_id);
        try testing.expectEqualStrings("t", source_read.tenant_id);
        try testing.expectEqualStrings("s", source_read.subscription_id);
        try testing.expectEqualStrings("a@p.iam.gserviceaccount.com", source_read.gcp_service_account);
        try testing.expectEqual(types.Ingestion.LogSeverity.info, hubs.value.ingestion.?.log_severity);
        try testing.expectEqual(types.IngestionState.active, hubs.value.ingestion.?.state);
        var msk = try b.client.topic("msk").create(.{ .ingestion = .{ .source = .{ .aws_msk = .{ .cluster_arn = "arn:c", .topic = "t", .aws_role_arn = "arn:r", .gcp_service_account = "a@p.iam.gserviceaccount.com" } } } });
        defer msk.deinit();
        try testing.expectEqualStrings("arn:c", msk.value.ingestion.?.source.?.aws_msk.cluster_arn);
        try testing.expectEqualStrings("t", msk.value.ingestion.?.source.?.aws_msk.topic);
        try testing.expectEqualStrings("arn:r", msk.value.ingestion.?.source.?.aws_msk.aws_role_arn);
        var confluent = try b.client.topic("confluent").create(.{ .ingestion = .{ .source = .{ .confluent_cloud = .{ .bootstrap_server = "pkc.example:9092", .cluster_id = "lkc", .topic = "t", .identity_pool_id = "pool", .gcp_service_account = "a@p.iam.gserviceaccount.com" } } } });
        defer confluent.deinit();
        try testing.expectEqualStrings("pkc.example:9092", confluent.value.ingestion.?.source.?.confluent_cloud.bootstrap_server);
        try testing.expectEqualStrings("lkc", confluent.value.ingestion.?.source.?.confluent_cloud.cluster_id);
        try testing.expectEqualStrings("pool", confluent.value.ingestion.?.source.?.confluent_cloud.identity_pool_id);
        for ([_]struct { []const u8, []const u8 }{ .{ "hubs", "EVENT_HUBS_PERMISSION_DENIED" }, .{ "msk", "MSK_PERMISSION_DENIED" }, .{ "confluent", "CONFLUENT_CLOUD_PERMISSION_DENIED" } }) |case| {
            b.fake.setIngestionState("p", case[0], .permission_denied);
            try testing.expect(std.mem.indexOf(u8, (try b.raw(a, .GET, try std.fmt.allocPrint(a, "projects/p/topics/{s}", .{case[0]}), "")).body, try std.fmt.allocPrint(a, "{{\"state\":\"{s}\",", .{case[1]})) != null);
            var read = try b.client.topic(case[0]).get();
            defer read.deinit();
            try testing.expectEqual(types.IngestionState.permission_denied, read.value.ingestion.?.state);
        }
    }

    // Nothing is imported, and a publish by hand is taken as on any
    // topic.
    var reader = try b.client.subscription("reader").create(.{ .topic_id = "zigps-i1" });
    reader.deinit();
    try testing.expectEqual(0, b.fake.publishedCount("p", "zigps-i1"));
    var sent = try b.client.topic("zigps-i1").publish(&.{.{ .data = "by hand" }}, .{});
    sent.deinit();
    try expectPulled(b.client.subscription("reader"), &.{"by hand"}, true);

    // Through the client.
    var imported = try b.client.topic("imported").create(.{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "zigps-g", .format = .{ .text = .{ .delimiter = "|" } }, .match_glob = "in/**" } }, .log_severity = .debug } });
    defer imported.deinit();
    try testing.expectEqualStrings("zigps-g", imported.value.ingestion.?.source.?.cloud_storage.bucket);
    try testing.expectEqualStrings("|", imported.value.ingestion.?.source.?.cloud_storage.format.text.delimiter);
    try testing.expectEqual(types.IngestionState.active, imported.value.ingestion.?.state);
    {
        var read = try b.client.topic("imported").get();
        defer read.deinit();
        try testing.expectEqualStrings("zigps-g", read.value.ingestion.?.source.?.cloud_storage.bucket);
        try testing.expectEqualStrings("in/**", read.value.ingestion.?.source.?.cloud_storage.match_glob);
        var again = try b.client.topic("hubs").get();
        defer again.deinit();
        try testing.expectEqualStrings("rg", again.value.ingestion.?.source.?.azure_event_hubs.resource_group);
        try testing.expectEqualStrings("a@p.iam.gserviceaccount.com", again.value.ingestion.?.source.?.azure_event_hubs.gcp_service_account);
    }
    var standard = try b.client.topic("imported").update(.{ .ingestion = .clear });
    defer standard.deinit();
    try testing.expect(standard.value.ingestion == null);
}

test "tags: bound as a resource is made, in production's words where their form is wrong, and never read back" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const tagged = "projects/p/topics/zigps-tagged";

    // By names and by ids. No answer has a tag in it, to a create or to
    // a read: the fake says what it bound when a test asks.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-tagged\"}", (try b.raw(a, .PUT, tagged, "{\"tags\":{\"p/env\":\"prod\",\"p/team\":\"data\"}}")).body);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-tagged\"}", (try b.raw(a, .GET, tagged, "")).body);
    try testing.expectEqualStrings("prod", b.fake.tagValue(tagged, "p/env").?);
    try testing.expectEqualStrings("data", b.fake.tagValue(tagged, "p/team").?);
    try testing.expect(b.fake.tagValue(tagged, "p/other") == null);
    try testing.expect(b.fake.tagValue(tagged, "p/dev") == null);
    try testing.expect(b.fake.tagValue("projects/p/topics/zigps-nope", "p/env") == null);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-by-id\"}", (try b.raw(a, .PUT, "projects/p/topics/zigps-by-id", "{\"tags\":{\"tagKeys/281477090942061\":\"tagValues/281479426154315\"}}")).body);
    try testing.expectEqualStrings("tagValues/281479426154315", b.fake.tagValue("projects/p/topics/zigps-by-id", "tagKeys/281477090942061").?);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-none\"}", (try b.raw(a, .PUT, "projects/p/topics/zigps-none", "{\"tags\":{}}")).body);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/subscriptions/zigps-s51","topic":"projects/p/topics/zigps-tagged","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","expirationPolicy":{"ttl":"2678400s"},"state":"ACTIVE"}
    , (try b.raw(a, .PUT, "projects/p/subscriptions/zigps-s51", "{\"topic\":\"projects/p/topics/zigps-tagged\",\"tags\":{\"p/env\":\"test\"}}")).body);
    try testing.expectEqualStrings("test", b.fake.tagValue("projects/p/subscriptions/zigps-s51", "p/env").?);
    try testing.expectEqualStrings(
        \\{"name":"projects/p/snapshots/zigps-n52","topic":"projects/p/topics/zigps-tagged","expireTime":"1970-01-08T00:00:00Z"}
    , (try b.raw(a, .PUT, "projects/p/snapshots/zigps-n52", "{\"subscription\":\"projects/p/subscriptions/zigps-s51\",\"tags\":{\"p/env\":\"dev\"}}")).body);
    try testing.expectEqualStrings("dev", b.fake.tagValue("projects/p/snapshots/zigps-n52", "p/env").?);

    // An update that names a topic's tags is taken, and changes nothing.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-tagged\"}", (try b.raw(a, .PATCH, tagged, "{\"topic\":{\"tags\":{}},\"updateMask\":\"tags\"}")).body);
    try testing.expectEqualStrings("prod", b.fake.tagValue(tagged, "p/env").?);
    // Of a subscription's and a snapshot's production was not asked.
    try expectRefused(try b.raw(a, .PATCH, "projects/p/subscriptions/zigps-s51", "{\"subscription\":{},\"updateMask\":\"tags\"}"), 501, "UNIMPLEMENTED", "fake: an update of a subscription's tags is not modelled yet");
    try expectRefused(try b.raw(a, .PATCH, "projects/p/snapshots/zigps-n52", "{\"snapshot\":{},\"updateMask\":\"tags\"}"), 501, "UNIMPLEMENTED", "fake: an update of a snapshot's tags is not modelled yet");

    // What a create refuses, of each of the three. The fake has no
    // Resource Manager: a key or a value that is not there, which
    // production refuses with 403, is taken here.
    const key = "INVALID_ARGUMENT: field [tags.tagKey] has issue [Invalid tag key specified. Please specify a valid tag key in the format <tag namespace>/<tag key name> where the tag namespace is the ID of the organization or name of the project that the tag key is defined in or tagKeys/<tag_key_id>. For example: \"123/environment\", or \"my-project/env\", or \"tagKeys/123\".]";
    const same_format = "field [tags.tagValue] has issue [Both TagKey and TagValue must be provided in the same format.]";
    const bad_value = "INVALID_ARGUMENT: field [tags.tagValue] has issue [Invalid tag value specified. Please specify a valid tag value. This must be the name of the value created under the specified tag key. For example: \"production\", or \"tagValues/456\".]\n" ++ same_format;
    for ([_]struct { []const u8, []const u8 }{
        .{ "{\"env\":\"prod\"}", key },
        .{ "{\"p/zigps/extra\":\"v\"}", key },
        .{ "{\"/env\":\"v\"}", key },
        .{ "{\"p/\":\"v\"}", key },
        .{ "{\"tagKeys/1/2\":\"v\"}", key },
        .{ "{\"p/env\":\"a/b\"}", bad_value },
        .{ "{\"p/env\":\"p/env/v\"}", bad_value },
        .{ "{\"p/env\":\"tagValues/\"}", bad_value },
        .{ "{\"p/env\":\"\"}", "INVALID_ARGUMENT: field [tags.tagValue] has issue [The TagValue field must be populated for an entry in the Tags map.]\n" ++ same_format },
        .{ "{\"p/env\":\"tagValues/281475995920187\"}", "INVALID_ARGUMENT: " ++ same_format },
        .{ "{\"tagKeys/281483349499811\":\"v\"}", "INVALID_ARGUMENT: " ++ same_format },
        // One tag of good form does not carry another.
        .{ "{\"p/env\":\"prod\",\"team\":\"data\"}", key },
    }) |case| {
        try expectRefused(try b.raw(a, .PUT, "projects/p/topics/zigps-bad", try std.fmt.allocPrint(a, "{{\"tags\":{s}}}", .{case[0]})), 400, "INVALID_ARGUMENT", case[1]);
        try expectRefused(try b.raw(a, .PUT, "projects/p/subscriptions/zigps-bad", try std.fmt.allocPrint(a, "{{\"topic\":\"projects/p/topics/zigps-tagged\",\"tags\":{s}}}", .{case[0]})), 400, "INVALID_ARGUMENT", case[1]);
        try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/zigps-bad", try std.fmt.allocPrint(a, "{{\"subscription\":\"projects/p/subscriptions/zigps-s51\",\"tags\":{s}}}", .{case[0]})), 400, "INVALID_ARGUMENT", case[1]);
    }
    try testing.expectEqual(400, (try b.raw(a, .PUT, "projects/p/topics/zigps-bad", "{\"tags\":[\"p/env\"]}")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/topics/zigps-bad", "")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/subscriptions/zigps-bad", "")).status);
    try testing.expectEqual(404, (try b.raw(a, .GET, "projects/p/snapshots/zigps-bad", "")).status);

    // Through the client, each of the three.
    var topic = try b.client.topic("client-topic").create(.{ .tags = &.{.{ .key = "p/env", .value = "prod" }} });
    topic.deinit();
    var sub = try b.client.subscription("client-sub").create(.{ .topic_id = "client-topic", .tags = &.{.{ .key = "tagKeys/1", .value = "tagValues/2" }} });
    sub.deinit();
    var snap = try b.client.snapshot("client-snap").create(.{ .subscription = "client-sub", .tags = &.{.{ .key = "p/env", .value = "dev" }} });
    snap.deinit();
    try testing.expectEqualStrings("prod", b.fake.tagValue("projects/p/topics/client-topic", "p/env").?);
    try testing.expectEqualStrings("tagValues/2", b.fake.tagValue("projects/p/subscriptions/client-sub", "tagKeys/1").?);
    try testing.expectEqualStrings("dev", b.fake.tagValue("projects/p/snapshots/client-snap", "p/env").?);
}

test "what a request gives is kept apart from the request's own memory" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const function = "{\"javascriptUdf\":{\"functionName\":\"f\",\"code\":\"function f(message, metadata) { return message; }\"},\"disabled\":true}";
    const source = "{\"cloudStorage\":{\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"|\"},\"minimumObjectCreateTime\":\"2030-01-01T00:00:00Z\",\"matchGlob\":\"in/**\"},\"platformLogsSettings\":{\"severity\":\"DEBUG\"}}";
    const push = "{\"pushEndpoint\":\"https://example.com/hook\",\"attributes\":{\"x-goog-version\":\"v1beta1\"},\"oidcToken\":{\"serviceAccountEmail\":\"a@p.iam.gserviceaccount.com\",\"audience\":\"aud\"}}";
    const files = "{\"bucket\":\"zigps-b\",\"filenamePrefix\":\"in/\",\"filenameSuffix\":\".txt\",\"filenameDatetimeFormat\":\"YYYY-MM-DD/hh_mm_ssZ\",\"serviceAccountEmail\":\"w@p.iam.gserviceaccount.com\"}";
    const steps = [_]struct { tp.Method, []const u8, []const u8 }{
        .{ .PUT, "projects/p/topics/made", "{\"messageTransforms\":[" ++ function ++ "],\"ingestionDataSourceSettings\":" ++ source ++ ",\"tags\":{\"p/env\":\"prod\"}}" },
        .{ .PUT, "projects/p/topics/changed", "{}" },
        .{ .PATCH, "projects/p/topics/changed", "{\"topic\":{\"messageTransforms\":[" ++ function ++ "],\"ingestionDataSourceSettings\":{\"awsMsk\":{\"clusterArn\":\"arn:c\",\"topic\":\"t\",\"awsRoleArn\":\"arn:r\",\"gcpServiceAccount\":\"a@p.iam.gserviceaccount.com\"}}},\"updateMask\":\"messageTransforms,ingestionDataSourceSettings\"}" },
        .{ .PUT, "projects/p/subscriptions/made", "{\"topic\":\"projects/p/topics/made\",\"pushConfig\":" ++ push ++ ",\"messageTransforms\":[" ++ function ++ "],\"tags\":{\"p/env\":\"test\"}}" },
        .{ .PUT, "projects/p/subscriptions/changed", "{\"topic\":\"projects/p/topics/made\"}" },
        .{ .PATCH, "projects/p/subscriptions/changed", "{\"subscription\":{\"cloudStorageConfig\":" ++ files ++ ",\"messageTransforms\":[" ++ function ++ "]},\"updateMask\":\"cloudStorageConfig,messageTransforms\"}" },
        .{ .PUT, "projects/p/subscriptions/rows", "{\"topic\":\"projects/p/topics/made\",\"bigqueryConfig\":{\"table\":\"p.d.t\",\"serviceAccountEmail\":\"w@p.iam.gserviceaccount.com\"}}" },
        .{ .PUT, "projects/p/subscriptions/pulls", "{\"topic\":\"projects/p/topics/made\"}" },
        .{ .POST, "projects/p/subscriptions/pulls:modifyPushConfig", "{\"pushConfig\":" ++ push ++ "}" },
        .{ .PUT, "projects/p/snapshots/made", "{\"subscription\":\"projects/p/subscriptions/changed\",\"tags\":{\"p/env\":\"dev\"}}" },
        .{ .POST, "projects/p/topics/made:setIamPolicy", "{\"policy\":{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:Reader@X.com\",\"group:g@x.com\"]}]}}" },
        .{ .POST, "projects/p/snapshots/made:setIamPolicy", "{\"policy\":{\"bindings\":[{\"role\":\"projects/p/roles/custom\",\"members\":[\"allUsers\"]}]}}" },
    };
    {
        // Each request in memory of its own, body and all, that is gone
        // before the next: under the testing allocator, written over.
        for (steps) |step| {
            var short: std.heap.ArenaAllocator = .init(testing.allocator);
            defer short.deinit();
            const method, const path, const body = step;
            try testing.expectEqual(200, (try b.raw(short.allocator(), method, try short.allocator().dupe(u8, path), try short.allocator().dupe(u8, body))).status);
        }
    }
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const read_source = "{\"cloudStorage\":{\"state\":\"ACTIVE\",\"bucket\":\"zigps-g\",\"textFormat\":{\"delimiter\":\"|\"},\"minimumObjectCreateTime\":\"2030-01-01T00:00:00Z\",\"matchGlob\":\"in/**\"},\"platformLogsSettings\":{\"severity\":\"DEBUG\"}}";
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/made\",\"state\":\"ACTIVE\",\"ingestionDataSourceSettings\":" ++ read_source ++ ",\"messageTransforms\":[" ++ function ++ "]}", (try b.raw(a, .GET, "projects/p/topics/made", "")).body);
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/changed\",\"state\":\"ACTIVE\",\"ingestionDataSourceSettings\":{\"awsMsk\":{\"state\":\"ACTIVE\",\"clusterArn\":\"arn:c\",\"topic\":\"t\",\"awsRoleArn\":\"arn:r\",\"gcpServiceAccount\":\"a@p.iam.gserviceaccount.com\"}},\"messageTransforms\":[" ++ function ++ "]}", (try b.raw(a, .GET, "projects/p/topics/changed", "")).body);
    try testing.expectEqualStrings(push, pushConfigOf((try b.raw(a, .GET, "projects/p/subscriptions/made", "")).body));
    try testing.expectEqualStrings(push, pushConfigOf((try b.raw(a, .GET, "projects/p/subscriptions/pulls", "")).body));
    try testing.expectEqualStrings("[" ++ function ++ "]}", tailOf((try b.raw(a, .GET, "projects/p/subscriptions/made", "")).body, "\"messageTransforms\":"));
    try testing.expectEqualStrings("\"bucket\":\"zigps-b\",\"filenamePrefix\":\"in/\",\"filenameSuffix\":\".txt\",\"textConfig\":{},\"maxDuration\":\"300s\",\"state\":\"ACTIVE\",\"filenameDatetimeFormat\":\"YYYY-MM-DD/hh_mm_ssZ\",\"serviceAccountEmail\":\"w@p.iam.gserviceaccount.com\"},\"messageTransforms\":[" ++ function ++ "]}", tailOf((try b.raw(a, .GET, "projects/p/subscriptions/changed", "")).body, "\"cloudStorageConfig\":{"));
    try testing.expectEqualStrings("\"table\":\"p.d.t\",\"state\":\"ACTIVE\",\"serviceAccountEmail\":\"w@p.iam.gserviceaccount.com\"", between((try b.raw(a, .GET, "projects/p/subscriptions/rows", "")).body, "\"bigqueryConfig\":{", "},\"state\""));
    try testing.expectEqualStrings("prod", b.fake.tagValue("projects/p/topics/made", "p/env").?);
    try testing.expectEqualStrings("test", b.fake.tagValue("projects/p/subscriptions/made", "p/env").?);
    try testing.expectEqualStrings("dev", b.fake.tagValue("projects/p/snapshots/made", "p/env").?);
    try testing.expectEqualStrings("[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:reader@x.com\",\"group:g@x.com\"]}]}", tailOf((try b.raw(a, .GET, "projects/p/topics/made:getIamPolicy", "")).body, "\"bindings\":"));
    try testing.expectEqualStrings("[{\"role\":\"projects/p/roles/custom\",\"members\":[\"allUsers\"]}]}", tailOf((try b.raw(a, .GET, "projects/p/snapshots/made:getIamPolicy", "")).body, "\"bindings\":"));
}

/// The client's own check of a filename datetime format was written from
/// the same recordings by other hands: the two must give one verdict.
fn datetimeProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const pieces = [_][]const u8{ "YYYY", "YY", "MM", "DD", "hh", "mm", "ss", "T", "Z", "+00:00", "-", "_", ":", "/", "Y", "+", "0", " ", ".", "x", "é" };
    while (g.pos < g.bytes.len and len + 6 <= buf.len) {
        const piece = pieces[g.intRange(u8, 0, pieces.len - 1)];
        @memcpy(buf[len..][0..piece.len], piece);
        len += piece.len;
    }
    const format = buf[0..len];
    var scratch: [512]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const fault = try datetimeFault(fixed.allocator(), format);
    const taken = if (client_checks.filenameDatetimeFormat(format, null)) |_| true else |_| false;
    try testing.expectEqual(taken, fault == null);
}

test "fake property: a filename datetime format is taken or refused as the client's own check of it says" {
    try test_util.fuzzBytes({}, datetimeProperty, .{ .corpus = &.{ "", "\x00\x02\x03\x04\x05\x06", "\x00\x02\x03\x0a\x04\x05\x06\x07\x08\x09", "\x01\x02\x03\x04\x05\x06\x11\x14" }, .random_runs = 2000 });
}

const client_checks = @import("validate.zig");

test "a topic deleted under a subscription and its snapshot: what production then takes and refuses" {
    // As production answered on 2026-10-12, step for step
    // (`production-fake-7.txt`).
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const t = "projects/p/topics/zigps-t";
    const s = "projects/p/subscriptions/zigps-s";
    var made = try b.client.topic("zigps-t").create(.{});
    made.deinit();
    const sub = b.client.subscription("zigps-s");
    var made_sub = try sub.create(.{ .topic_id = "zigps-t" });
    made_sub.deinit();
    var sent = try b.client.topic("zigps-t").publish(&.{.{ .data = "x1" }}, .{});
    sent.deinit();
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/snapshots/zigps-na", "{\"subscription\":\"" ++ s ++ "\"}")).status);
    try b.client.topic("zigps-t").delete();

    // Both read the topic as deleted.
    const gone_from_sub = "{\"name\":\"projects/p/subscriptions/zigps-s\",\"topic\":\"_deleted-topic_\",\"pushConfig\":{},\"ackDeadlineSeconds\":10,\"messageRetentionDuration\":\"604800s\",\"expirationPolicy\":{\"ttl\":\"2678400s\"},\"state\":\"ACTIVE\"}";
    const gone_from_snapshot = "{\"name\":\"projects/p/snapshots/zigps-na\",\"topic\":\"_deleted-topic_\",\"expireTime\":\"1970-01-08T00:00:00Z\"}";
    try testing.expectEqualStrings(gone_from_sub, (try b.raw(a, .GET, s, "")).body);
    try testing.expectEqualStrings(gone_from_snapshot, (try b.raw(a, .GET, "projects/p/snapshots/zigps-na", "")).body);

    // A snapshot of a subscription whose topic is gone is refused, and
    // none is made.
    const attached = "The operation could not be completed because the requested subscription is attached to a deleted topic.";
    try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/zigps-nb", "{\"subscription\":\"" ++ s ++ "\"}"), 400, "FAILED_PRECONDITION", attached);
    try expectRefused(try b.raw(a, .GET, "projects/p/snapshots/zigps-nb", ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nb).");
    try testing.expectError(error.FailedPrecondition, b.client.snapshot("zigps-nb").create(.{ .subscription = "zigps-s" }));

    // The subscription still gives what it holds, and still seeks to the
    // snapshot that was taken of it before: the message comes again.
    try expectPulled(sub, &.{"x1"}, false);
    b.advance(11);
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, s ++ ":seek", "{\"snapshot\":\"projects/p/snapshots/zigps-na\"}")).body);
    try expectPulled(sub, &.{"x1"}, false);
    try expectRefused(try b.raw(a, .POST, s ++ ":seek", "{\"snapshot\":\"projects/p/snapshots/zigps-nb\"}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nb).");

    // A topic made again under the name is another topic: nothing of the
    // old one's is its own, and nothing of the above changes.
    try testing.expectEqualStrings("{\"name\":\"projects/p/topics/zigps-t\"}", (try b.raw(a, .PUT, t, "{}")).body);
    try testing.expectEqualStrings(gone_from_sub, (try b.raw(a, .GET, s, "")).body);
    try testing.expectEqualStrings(gone_from_snapshot, (try b.raw(a, .GET, "projects/p/snapshots/zigps-na", "")).body);
    try expectRefused(try b.raw(a, .PUT, "projects/p/snapshots/zigps-nc", "{\"subscription\":\"" ++ s ++ "\"}"), 400, "FAILED_PRECONDITION", attached);
    try testing.expectEqualStrings("{}", (try b.raw(a, .POST, s ++ ":seek", "{\"snapshot\":\"projects/p/snapshots/zigps-na\"}")).body);
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, t ++ "/subscriptions", "")).body);
    try testing.expectEqualStrings("{}", (try b.raw(a, .GET, t ++ "/snapshots", "")).body);
}

/// A policy's etag, as its JSON has it.
fn etagOf(a: Allocator, body: []const u8) ![]const u8 {
    const Shape = struct { etag: []const u8 };
    return (try std.json.parseFromSliceLeaky(Shape, a, body, .{ .ignore_unknown_fields = true })).etag;
}

test "IAM: a policy read, written whole and guarded by its etag, on each of the four resources" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var made_topic = try b.client.topic("zigps-t").create(.{});
    made_topic.deinit();
    var made_sub = try b.client.subscription("zigps-s").create(.{ .topic_id = "zigps-t" });
    made_sub.deinit();
    var made_snap = try b.client.snapshot("zigps-n").create(.{ .subscription = "zigps-s" });
    made_snap.deinit();
    var made_schema = try b.client.schema("zigps-a").create(.{ .type = .avro, .definition = "\"string\"" });
    made_schema.deinit();
    const t = "projects/p/topics/zigps-t";
    const s = "projects/p/subscriptions/zigps-s";
    const resources = [_][]const u8{ t, s, "projects/p/snapshots/zigps-n", "projects/p/schemas/zigps-a" };

    // Never written, a policy is its etag alone, whatever version is
    // asked for: production takes any integer there.
    for (resources) |resource| {
        try testing.expectEqualStrings("{\"etag\":\"ACAB\"}", (try b.raw(a, .GET, try std.fmt.allocPrint(a, "{s}:getIamPolicy", .{resource}), "")).body);
        try testing.expectEqualStrings("{\"etag\":\"ACAB\"}", (try b.raw(a, .GET, try std.fmt.allocPrint(a, "{s}:getIamPolicy?options.requestedPolicyVersion=3", .{resource}), "")).body);
    }
    try testing.expectEqualStrings("{\"etag\":\"ACAB\"}", (try b.raw(a, .GET, t ++ ":getIamPolicy?options.requestedPolicyVersion=77", "")).body);
    try testing.expectEqual(400, (try b.raw(a, .GET, t ++ ":getIamPolicy?options.requestedPolicyVersion=three", "")).status);

    // A write with no etag, as production answered one on a new topic:
    // the version, a new etag, the bindings. Production's etag then was
    // `BwZdpJFCzTA=`, a 7 and the microsecond it was written at in seven
    // bytes. Here the clock says a second, a million of them.
    const agent = "serviceAccount:service-82150720798@gcp-sa-pubsub.iam.gserviceaccount.com";
    const publisher = "\"bindings\":[{\"role\":\"roles/pubsub.publisher\",\"members\":[\"" ++ agent ++ "\"]}]";
    b.advance(1);
    const written = (try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{" ++ publisher ++ "}}")).body;
    try testing.expectEqualStrings("{\"version\":1,\"etag\":\"BwAAAAAPQkA=\"," ++ publisher ++ "}", written);
    // The answer to a write is what a read right after gives.
    try testing.expectEqualStrings(written, (try b.raw(a, .GET, t ++ ":getIamPolicy", "")).body);
    // Every write moves the etag, one that changes nothing included.
    const again = (try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{\"etag\":\"BwAAAAAPQkA=\"," ++ publisher ++ "}}")).body;
    try testing.expectEqualStrings("{\"version\":1,\"etag\":\"BwAAAAAPQkE=\"," ++ publisher ++ "}", again);
    // So the same write sent twice is refused the second time, though the
    // first landed: a write under an older etag, in production's words.
    const concurrent = "There were concurrent policy changes. Please retry the whole read-modify-write with exponential backoff.";
    try expectRefused(try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{\"etag\":\"BwAAAAAPQkA=\"," ++ publisher ++ "}}"), 409, "ABORTED", concurrent);
    try expectRefused(try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{\"etag\":\"ACAB\"}}"), 409, "ABORTED", concurrent);
    // What is no etag at all is never the mismatch.
    for ([_][]const u8{ "AAAA", "BwAAAAAPQg==", "CAAAAAAPQkE=", "ACABAA==" }) |etag| {
        try expectRefused(try b.raw(a, .POST, t ++ ":setIamPolicy", try std.fmt.allocPrint(a, "{{\"policy\":{{\"etag\":\"{s}\"}}}}", .{etag})), 400, "INVALID_ARGUMENT", "Invalid etag");
    }
    try expectRefused(try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{\"etag\":\"***\"}}"), 400, "INVALID_ARGUMENT", "Invalid value at 'policy.etag' (TYPE_BYTES), Base64 decoding failed for \"***\"");
    // None of which wrote anything.
    try testing.expectEqualStrings(again, (try b.raw(a, .GET, t ++ ":getIamPolicy", "")).body);
    // An empty etag, as none, writes over whatever is there, and a policy
    // with no bindings empties it.
    try testing.expectEqualStrings("{\"version\":1,\"etag\":\"BwAAAAAPQkI=\"}", (try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{\"etag\":\"\"}}")).body);
    try testing.expectEqualStrings("{\"version\":1,\"etag\":\"BwAAAAAPQkM=\"}", (try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{\"etag\":\"BwAAAAAPQkI=\",\"bindings\":[]}}")).body);
    // When the clock has moved, the etag is the clock's.
    b.advance(1);
    try testing.expectEqualStrings("BwAAAAAehIA=", try etagOf(a, (try b.raw(a, .POST, t ++ ":setIamPolicy", "{\"policy\":{}}")).body));

    // Stored as production stores a policy: a binding with no members
    // dropped, a member named twice kept once, two bindings of one role
    // made one, and an address in lower case, under the etag of a policy
    // never written. A custom role the fake cannot look up, and takes.
    const stored = (try b.raw(a, .POST, s ++ ":setIamPolicy", "{\"policy\":{\"etag\":\"ACAB\",\"version\":3,\"bindings\":[" ++
        "{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"user:KEVIN@ONEIL.CM\",\"user:kevin@oneil.cm\",\"group:Ops@Example.com\"]}," ++
        "{\"role\":\"roles/pubsub.viewer\",\"members\":[]}," ++
        "{\"members\":[\"serviceAccount:Reader@P.iam.gserviceaccount.com\",\"user:kevin@oneil.cm\"],\"condition\":null,\"role\":\"roles/pubsub.subscriber\"}," ++
        "{\"role\":\"projects/p/roles/custom\",\"members\":[\"domain:Example.COM\",\"allUsers\",\"allAuthenticatedUsers\",\"principal://iam.googleapis.com/locations/global/workforcePools/Pool/subject/Kevin\",\"principalSet://iam.googleapis.com/Pool\"]}," ++
        "{\"role\":\"organizations/1/roles/custom\",\"members\":[\"user:a@x.com\"]}," ++
        "{\"role\":\"roles/editor\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/viewer\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/pubsub.admin\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/pubsub.editor\",\"members\":[\"user:a@x.com\"]}" ++
        "]}}")).body;
    try testing.expectEqualStrings("[" ++
        "{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"user:kevin@oneil.cm\",\"group:ops@example.com\",\"serviceAccount:reader@p.iam.gserviceaccount.com\"]}," ++
        "{\"role\":\"projects/p/roles/custom\",\"members\":[\"domain:example.com\",\"allUsers\",\"allAuthenticatedUsers\",\"principal://iam.googleapis.com/locations/global/workforcePools/Pool/subject/Kevin\",\"principalSet://iam.googleapis.com/Pool\"]}," ++
        "{\"role\":\"organizations/1/roles/custom\",\"members\":[\"user:a@x.com\"]}," ++
        "{\"role\":\"roles/editor\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/viewer\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/pubsub.admin\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/pubsub.editor\",\"members\":[\"user:a@x.com\"]}" ++
        "]}", tailOf(stored, "\"bindings\":"));
    try testing.expectEqualStrings(stored, (try b.raw(a, .GET, s ++ ":getIamPolicy", "")).body);

    // What a write refuses. A subscription takes no publisher, which is a
    // topic's; another service's role, and text that is no role, the fake
    // refuses in the same words. Production's words for a member of no
    // form were not kept: these are the fake's.
    const one = "\"members\":[\"user:a@x.com\"]";
    for ([_]struct { []const u8, u16, []const u8, []const u8 }{
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.publisher\"," ++ one ++ "}]}", 400, "INVALID_ARGUMENT", "Role roles/pubsub.publisher is not supported for this resource." },
        .{ "{\"bindings\":[{\"role\":\"roles/storage.admin\"," ++ one ++ "}]}", 400, "INVALID_ARGUMENT", "Role roles/storage.admin is not supported for this resource." },
        .{ "{\"bindings\":[{\"role\":\"viewer\"," ++ one ++ "}]}", 400, "INVALID_ARGUMENT", "Role viewer is not supported for this resource." },
        .{ "{\"bindings\":[{" ++ one ++ "}]}", 400, "INVALID_ARGUMENT", "Role  is not supported for this resource." },
        .{ "{\"bindings\":[{\"role\":\"projects/p/roles/\"," ++ one ++ "}]}", 400, "INVALID_ARGUMENT", "Role projects/p/roles/ is not supported for this resource." },
        .{ "{\"bindings\":[{\"role\":\"projects//roles/custom\"," ++ one ++ "}]}", 400, "INVALID_ARGUMENT", "Role projects//roles/custom is not supported for this resource." },
        .{ "{\"bindings\":[{\"role\":\"organizations/custom\"," ++ one ++ "}]}", 400, "INVALID_ARGUMENT", "Role organizations/custom is not supported for this resource." },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\"," ++ one ++ ",\"condition\":{\"title\":\"t\",\"expression\":\"true\"}}]}", 400, "INVALID_ARGUMENT", "Can't set conditional policy on this resource" },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"ServiceAccount:a@p.iam.gserviceaccount.com\"]}]}", 400, "INVALID_ARGUMENT", "Invalid member (member=ServiceAccount:a@p.iam.gserviceaccount.com)." },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"allusers\"]}]}", 400, "INVALID_ARGUMENT", "Invalid member (member=allusers)." },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"projectOwner:p\"]}]}", 400, "INVALID_ARGUMENT", "Invalid member (member=projectOwner:p)." },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:\"]}]}", 400, "INVALID_ARGUMENT", "Invalid member (member=user:)." },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"principal://\"]}]}", 400, "INVALID_ARGUMENT", "Invalid member (member=principal://)." },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\",\"kevin@oneil.cm\"]}]}", 400, "INVALID_ARGUMENT", "Invalid member (member=kevin@oneil.cm)." },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[7]}]}", 400, "INVALID_ARGUMENT", "Invalid value at 'members'" },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\"," ++ one ++ ",\"nonsense\":1}]}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "{\"nonsense\":1}", 400, "INVALID_ARGUMENT", "Invalid JSON payload received. Unknown name \"nonsense\": Cannot find field." },
        .{ "{\"version\":\"three\"}", 400, "INVALID_ARGUMENT", "Invalid value at 'version'" },
        // What production was not asked.
        .{ "{\"bindings\":[{\"role\":\"roles/owner\"," ++ one ++ "}]}", 501, "UNIMPLEMENTED", "fake: the role roles/owner on this resource is not modelled yet" },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.serviceAgent\"," ++ one ++ "}]}", 501, "UNIMPLEMENTED", "fake: the role roles/pubsub.serviceAgent on this resource is not modelled yet" },
        .{ "{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"deleted:user:a@x.com?uid=1\"]}]}", 501, "UNIMPLEMENTED", "fake: a deleted: member is not modelled yet" },
        .{ "{\"auditConfigs\":[]}", 501, "UNIMPLEMENTED", "fake: audit configs in a policy is not modelled yet" },
    }) |case| {
        try expectRefused(try b.raw(a, .POST, s ++ ":setIamPolicy", try std.fmt.allocPrint(a, "{{\"policy\":{s}}}", .{case[0]})), case[1], case[2], case[3]);
    }
    try expectRefused(try b.raw(a, .POST, s ++ ":setIamPolicy", "{\"policy\":{},\"updateMask\":\"bindings\"}"), 501, "UNIMPLEMENTED", "fake: a setIamPolicy with an update mask is not modelled yet");
    try expectRefused(try b.raw(a, .POST, s ++ ":setIamPolicy", "{}"), 501, "UNIMPLEMENTED", "fake: a setIamPolicy with no policy is not modelled yet");
    try testing.expectEqual(400, (try b.raw(a, .POST, s ++ ":setIamPolicy", "{\"policy\":[]}")).status);
    try testing.expectEqual(400, (try b.raw(a, .POST, s ++ ":setIamPolicy", "{\"nonsense\":{}}")).status);
    // A refused write writes nothing, and moves no etag.
    try testing.expectEqualStrings(stored, (try b.raw(a, .GET, s ++ ":getIamPolicy", "")).body);
    // A topic takes the publisher a subscription refuses, and a snapshot
    // and a schema are held to the topic's rule: the fake's own.
    for ([_][]const u8{ t, "projects/p/snapshots/zigps-n", "projects/p/schemas/zigps-a" }) |resource| {
        try testing.expectEqual(200, (try b.raw(a, .POST, try std.fmt.allocPrint(a, "{s}:setIamPolicy", .{resource}), "{\"policy\":{" ++ publisher ++ "}}")).status);
    }

    // What is not there is 404 to all three calls, a test of permissions
    // too, where Google's page promises an empty answer.
    for ([_][]const u8{ "topics", "subscriptions", "snapshots", "schemas" }) |collection| {
        const nope = try std.fmt.allocPrint(a, "projects/p/{s}/zigps-nope", .{collection});
        try expectRefused(try b.raw(a, .GET, try std.fmt.allocPrint(a, "{s}:getIamPolicy", .{nope}), ""), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
        try expectRefused(try b.raw(a, .POST, try std.fmt.allocPrint(a, "{s}:setIamPolicy", .{nope}), "{\"policy\":{}}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
        try expectRefused(try b.raw(a, .POST, try std.fmt.allocPrint(a, "{s}:testIamPermissions", .{nope}), "{\"permissions\":[\"pubsub.topics.get\"]}"), 404, "NOT_FOUND", "Resource not found (resource=zigps-nope).");
    }
    try expectRefused(try b.raw(a, .GET, "projects/p/schemas/zigps-a@9e3779b1:getIamPolicy", ""), 501, "UNIMPLEMENTED", "fake: IAM on a revision of a schema is not modelled yet");
    // A detached subscription still reads its policy.
    var loose = try b.client.subscription("zigps-loose").create(.{ .topic_id = "zigps-t" });
    loose.deinit();
    try b.client.subscription("zigps-loose").detach();
    try testing.expectEqualStrings("{\"etag\":\"ACAB\"}", (try b.raw(a, .GET, "projects/p/subscriptions/zigps-loose:getIamPolicy", "")).body);

    // A test of permissions answers what the caller holds, by name: not
    // in the order asked, and one asked twice twice.
    try testing.expectEqualStrings(
        \\{"permissions":["pubsub.snapshots.delete","pubsub.snapshots.seek","pubsub.snapshots.update"]}
    , (try b.raw(a, .POST, "projects/p/snapshots/zigps-n:testIamPermissions", "{\"permissions\":[\"pubsub.snapshots.seek\",\"pubsub.snapshots.delete\",\"pubsub.snapshots.update\"]}")).body);
    try testing.expectEqualStrings(
        \\{"permissions":["pubsub.schemas.commit","pubsub.schemas.get"]}
    , (try b.raw(a, .POST, "projects/p/schemas/zigps-a:testIamPermissions", "{\"permissions\":[\"pubsub.schemas.get\",\"pubsub.schemas.commit\"]}")).body);
    try testing.expectEqualStrings(
        \\{"permissions":["pubsub.topics.get","pubsub.topics.publish","pubsub.topics.publish"]}
    , (try b.raw(a, .POST, t ++ ":testIamPermissions", "{\"permissions\":[\"pubsub.topics.publish\",\"pubsub.topics.get\",\"pubsub.topics.publish\"]}")).body);
    try testing.expectEqualStrings(
        \\{"permissions":["pubsub.subscriptions.consume"]}
    , (try b.raw(a, .POST, s ++ ":testIamPermissions", "{\"permissions\":[\"pubsub.subscriptions.consume\"]}")).body);
    // A hundred at most, and one at least. Production's words for these
    // refusals were not kept.
    var many: std.ArrayList(u8) = .empty;
    for (0..101) |i| try many.print(a, "{s}\"pubsub.topics.get\"", .{if (i == 0) "" else ","});
    try testing.expectEqual(200, (try b.raw(a, .POST, t ++ ":testIamPermissions", try std.fmt.allocPrint(a, "{{\"permissions\":[{s}]}}", .{many.items[0 .. many.items.len - "\"pubsub.topics.get\",".len]}))).status);
    const unreasoned = "Request contains an invalid argument.";
    try expectRefused(try b.raw(a, .POST, t ++ ":testIamPermissions", try std.fmt.allocPrint(a, "{{\"permissions\":[{s}]}}", .{many.items})), 400, "INVALID_ARGUMENT", unreasoned);
    for ([_][]const u8{ "{\"permissions\":[]}", "{}", "{\"permissions\":[\"pubsub.topics.*\"]}", "{\"permissions\":[\"pubsub.*\"]}", "{\"permissions\":[\"storage.buckets.get\"]}", "{\"permissions\":[\"pubsub\"]}", "{\"permissions\":[\"pubsub.topics\"]}", "{\"permissions\":[\"pubsub.topics.\"]}", "{\"permissions\":[\"pubsub..get\"]}", "{\"permissions\":[\"pubsub.topics.get it\"]}", "{\"permissions\":[\"pubsub.topics.get\",\"\"]}" }) |body| {
        try expectRefused(try b.raw(a, .POST, t ++ ":testIamPermissions", body), 400, "INVALID_ARGUMENT", unreasoned);
    }
    try testing.expectEqual(400, (try b.raw(a, .POST, t ++ ":testIamPermissions", "{\"permissions\":\"pubsub.topics.get\"}")).status);
    try testing.expectEqual(400, (try b.raw(a, .POST, t ++ ":testIamPermissions", "{\"permissions\":[7]}")).status);
    try testing.expectEqual(400, (try b.raw(a, .POST, t ++ ":testIamPermissions", "{\"permission\":[]}")).status);
    // One of Pub/Sub's that is another kind of resource's, or that the
    // fake has no name for, it does not answer for.
    try expectRefused(try b.raw(a, .POST, s ++ ":testIamPermissions", "{\"permissions\":[\"pubsub.topics.publish\"]}"), 501, "UNIMPLEMENTED", "fake: the permission pubsub.topics.publish on this resource is not modelled yet");
    try expectRefused(try b.raw(a, .POST, t ++ ":testIamPermissions", "{\"permissions\":[\"pubsub.topics.fly\"]}"), 501, "UNIMPLEMENTED", "fake: the permission pubsub.topics.fly on this resource is not modelled yet");
    try expectRefused(try b.raw(a, .POST, t ++ ":testIamPermissions", "{\"permissions\":[\"pubsub.subscriptions.get\"]}"), 501, "UNIMPLEMENTED", "fake: the permission pubsub.subscriptions.get on this resource is not modelled yet");

    // Through the client, on each of the four: a policy never written, a
    // grant, the same again in other letters, which writes nothing, a
    // revoke, and the same again.
    var made_worker = try b.client.subscription("zigps-w").create(.{ .topic_id = "zigps-t" });
    made_worker.deinit();
    inline for (.{ b.client.topic("zigps-t"), b.client.subscription("zigps-w"), b.client.snapshot("zigps-n"), b.client.schema("zigps-a") }, .{ "roles/pubsub.editor", "roles/pubsub.subscriber", "roles/pubsub.viewer", "roles/pubsub.admin" }, .{ "pubsub.topics.publish", "pubsub.subscriptions.consume", "pubsub.snapshots.seek", "pubsub.schemas.commit" }) |handle, role, permission| {
        var granted = try handle.addIamBinding(role, "user:Kevin@Oneil.CM");
        defer granted.deinit();
        try testing.expect(granted.value.grants(role, "user:kevin@oneil.cm"));
        var same = try handle.addIamBinding(role, "user:KEVIN@ONEIL.CM");
        defer same.deinit();
        try testing.expectEqualStrings(granted.value.etag.?, same.value.etag.?);
        var read = try handle.iamPolicy();
        defer read.deinit();
        try testing.expectEqualStrings(granted.value.etag.?, read.value.etag.?);
        var found = false;
        for (read.value.bindings) |binding| {
            if (!std.mem.eql(u8, binding.role, role)) continue;
            try testing.expectEqual(1, binding.members.len);
            try testing.expectEqualStrings("user:kevin@oneil.cm", binding.members[0]);
            found = true;
        }
        try testing.expect(found);
        var revoked = try handle.removeIamBinding(role, "user:kevin@oneil.cm");
        defer revoked.deinit();
        try testing.expect(!revoked.value.grants(role, "user:kevin@oneil.cm"));
        try testing.expect(!std.mem.eql(u8, granted.value.etag.?, revoked.value.etag.?));
        var gone = try handle.removeIamBinding(role, "user:kevin@oneil.cm");
        defer gone.deinit();
        try testing.expectEqualStrings(revoked.value.etag.?, gone.value.etag.?);
        var held = try handle.testIamPermissions(&.{permission});
        defer held.deinit();
        try testing.expectEqual(1, held.value.len);
        try testing.expectEqualStrings(permission, held.value[0]);
    }
    // Each of the four has a policy of its own, a snapshot and a
    // subscription apart from their topic.
    for (resources, 0..) |resource, i| {
        try testing.expectEqual(200, (try b.raw(a, .POST, try std.fmt.allocPrint(a, "{s}:setIamPolicy", .{resource}), try std.fmt.allocPrint(a, "{{\"policy\":{{\"bindings\":[{{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:u{d}@x.com\"]}}]}}}}", .{i}))).status);
    }
    for (resources, 0..) |resource, i| {
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "[{{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:u{d}@x.com\"]}}]}}", .{i}), tailOf((try b.raw(a, .GET, try std.fmt.allocPrint(a, "{s}:getIamPolicy", .{resource}), "")).body, "\"bindings\":"));
    }
    // A write under an etag another write has made stale is `Aborted`,
    // and so is one whose answer was lost and which was sent again: it
    // landed the first time.
    const worker = b.client.subscription("zigps-s");
    var before = try worker.iamPolicy();
    defer before.deinit();
    try testing.expectEqual(200, (try b.raw(a, .POST, s ++ ":setIamPolicy", "{\"policy\":{}}")).status);
    try testing.expectError(error.Aborted, worker.setIamPolicy(.{ .etag = before.value.etag, .bindings = &.{.{ .role = "roles/pubsub.viewer", .members = &.{"user:a@x.com"} }} }));
    var now = try worker.iamPolicy();
    defer now.deinit();
    try testing.expectEqual(0, now.value.bindings.len);
    b.fake.loseAnswers(1, .admin);
    try testing.expectError(error.Aborted, worker.setIamPolicy(.{ .etag = now.value.etag, .bindings = &.{.{ .role = "roles/pubsub.viewer", .members = &.{"user:a@x.com"} }} }));
    var landed = try worker.iamPolicy();
    defer landed.deinit();
    try testing.expect(landed.value.grants("roles/pubsub.viewer", "user:a@x.com"));
}

test "dead letters with the service agent named: forwarded only once it may publish there and acknowledge here" {
    const agent = "serviceAccount:service-1@gcp-sa-pubsub.iam.gserviceaccount.com";
    var b: Bench = undefined;
    // Named in letters of either case: a policy stores an address in
    // lower case.
    try b.init(.{ .service_agent = "serviceAccount:Service-1@GCP-SA-PubSub.iam.gserviceaccount.com" });
    defer b.deinit();
    for ([_][]const u8{ "orders", "dead", "other" }) |id| {
        var topic = try b.client.topic(id).create(.{});
        topic.deinit();
    }
    const worker = b.client.subscription("worker");
    var made = try worker.create(.{ .topic_id = "orders", .dead_letter_policy = .{ .topic = "dead" } });
    made.deinit();
    const morgue = b.client.subscription("morgue");
    var made_morgue = try morgue.create(.{ .topic_id = "dead" });
    made_morgue.deinit();
    var sent = try b.client.topic("orders").publish(&.{.{ .data = "poison" }}, .{});
    sent.deinit();

    // Without the grants a message is never forwarded: production's went
    // on to a sixth attempt and a seventh.
    var attempt: u32 = 0;
    const Step = struct {
        /// One more delivery, given back.
        fn nack(sub: anytype, count: *u32) !void {
            count.* += 1;
            var got = try sub.pull(.{ .return_immediately = true });
            defer got.deinit();
            try testing.expectEqual(1, got.value.messages.len);
            try testing.expectEqual(count.*, got.value.messages[0].delivery_attempt);
            try sub.nack(&.{got.value.messages[0].ack_id});
        }
    };
    for (0..7) |_| try Step.nack(worker, &attempt);
    try testing.expectEqual(1, b.fake.backlog("p", "worker"));
    try testing.expectEqual(0, b.fake.backlog("p", "morgue"));

    // That the agent may publish to the dead-letter topic is half of it,
    // and a grant on another topic, or to another account, none.
    var publisher = try b.client.topic("dead").addIamBinding("roles/pubsub.publisher", agent);
    publisher.deinit();
    try Step.nack(worker, &attempt);
    try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
    var elsewhere = try b.client.topic("other").addIamBinding("roles/pubsub.publisher", agent);
    elsewhere.deinit();
    var another = try worker.addIamBinding("roles/pubsub.subscriber", "serviceAccount:service-2@gcp-sa-pubsub.iam.gserviceaccount.com");
    another.deinit();
    var lesser = try worker.addIamBinding("roles/pubsub.viewer", agent);
    lesser.deinit();
    try Step.nack(worker, &attempt);
    try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
    // With the right to acknowledge on the subscription too, the message
    // goes when it is next given back.
    var subscriber = try worker.addIamBinding("roles/pubsub.subscriber", "serviceAccount:SERVICE-1@gcp-sa-pubsub.iam.gserviceaccount.com");
    subscriber.deinit();
    try Step.nack(worker, &attempt);
    try testing.expectEqual(0, b.fake.backlog("p", "worker"));
    try testing.expectEqual(1, b.fake.backlog("p", "morgue"));
    try expectPulled(morgue, &.{"poison"}, true);

    // The subscriber's grant alone is the other half, and no more, with
    // a viewer's on the topic or without.
    var no_publisher = try b.client.topic("dead").removeIamBinding("roles/pubsub.publisher", agent);
    no_publisher.deinit();
    var viewer = try b.client.topic("dead").addIamBinding("roles/pubsub.viewer", agent);
    viewer.deinit();
    var second = try b.client.topic("orders").publish(&.{.{ .data = "second" }}, .{});
    second.deinit();
    attempt = 0;
    for (0..6) |_| try Step.nack(worker, &attempt);
    try testing.expectEqual(0, b.fake.backlog("p", "morgue"));
    // A wider role holds the narrower one's rights: Pub/Sub's editor and
    // admin, and the basic editor. A viewer's holds neither.
    inline for (.{ "roles/pubsub.editor", "roles/pubsub.admin", "roles/editor" }, .{ "roles/editor", "roles/pubsub.editor", "roles/pubsub.admin" }, 0..) |on_topic, on_subscription, round| {
        var set_topic = try b.client.topic("dead").setIamPolicy(.{ .bindings = &.{.{ .role = on_topic, .members = &.{agent} }} });
        set_topic.deinit();
        var set_sub = try worker.setIamPolicy(.{ .bindings = &.{.{ .role = "roles/pubsub.viewer", .members = &.{agent} }} });
        set_sub.deinit();
        try Step.nack(worker, &attempt);
        try testing.expectEqual(round, b.fake.backlog("p", "morgue"));
        var widened = try worker.setIamPolicy(.{ .bindings = &.{.{ .role = on_subscription, .members = &.{agent} }} });
        widened.deinit();
        try Step.nack(worker, &attempt);
        try testing.expectEqual(round + 1, b.fake.backlog("p", "morgue"));
        // The next, one delivery short of its last.
        var next = try b.client.topic("orders").publish(&.{.{ .data = "next" }}, .{});
        next.deinit();
        attempt = 0;
        for (0..4) |_| try Step.nack(worker, &attempt);
    }
}

/// What each subscription should hold, said again in as few lines as it
/// takes: the fake is held to this after every step of a script. Three
/// subscriptions, each with rules of its own. The first retains what is
/// acknowledged. The second has ordering, a filter that passes what has
/// no `skip`, and a retry policy of 5 to 20 seconds. The third has
/// ordering, exactly-once delivery, and dead letters to the first topic
/// after five attempts. Of the two topics the second retains messages,
/// ten minutes.
///
/// `production_replay.zig` holds production to it as well, which is why
/// it is public.
pub const Reference = struct {
    pub const Held = struct { id: u64, lease_until: ?i96 = null, deliveries: u32 = 0, not_before: i96 = 0, acked: bool = false };
    /// What the rules ask of a message: its ordering key, 0 for none,
    /// whether the second subscription's filter stops it, and which
    /// topic, of which making, it came to, and when.
    pub const Sent = struct { key: u8 = 0, skip: bool = false, topic: u8 = 0, made: u32 = 0, time: i96 = 0 };
    /// A topic, as one making of it: made again, it is another.
    pub const Topic = struct { topic: u8, made: u32 };
    /// A snapshot: what its subscription had not had acknowledged, and
    /// the id from which every message to its topic is its own too.
    pub const Taken = struct { of: Topic, held: [max_held]u64 = undefined, count: usize = 0, from: u64 };
    pub const max_held = 256;
    pub const topic_retention_s = [2]?i64{ null, 600 };
    pub const deadline_s = [3]u32{ 10, 20, 10 };
    pub const ordered = [3]bool{ false, true, true };
    pub const max_attempts = 5;

    held: [3][max_held]Held = undefined,
    counts: [3]usize = @splat(0),
    /// Which topic a subscription listens to, and which making of it.
    on: [3]Topic = .{ .{ .topic = 0, .made = 0 }, .{ .topic = 0, .made = 0 }, .{ .topic = 1, .made = 0 } },
    /// How many times each topic has been made again.
    made: [2]u32 = .{ 0, 0 },
    /// The first message id a subscription was there for.
    joined: [3]u64 = .{ 1, 1, 1 },
    taken: [3]?Taken = .{ null, null, null },
    /// The fake's clock, as the script moves it.
    clock: i96 = 0,
    /// By message id.
    sent: [2 * max_held]Sent = undefined,
    /// By message id: which delivery's id acknowledged it on the third
    /// subscription. 0: none has.
    acknowledged_by: [2 * max_held]u32 = @splat(0),
    next_id: u64 = 1,
    /// Whether a message that has had its last attempt moves on to the
    /// dead-letter topic. Not when the service agent lacks its grants:
    /// the message then stays where it is and its attempts go on being
    /// counted (measured 2026-10-12).
    forwards: bool = true,
    /// Whether a backoff doubles from the retry policy's minimum to its
    /// maximum with each delivery, which is the fake's own rule.
    /// Production's is somewhere between the two (measured 2026-10-12),
    /// so what holds production to this asks for the minimum alone.
    doubles: bool = true,

    /// A message comes to a topic, published or forwarded, and gets the
    /// next id. The subscriptions of the topic as it is now made get it.
    pub fn arrive(r: *Reference, topic: u8, key_of: u8, skip: bool) u64 {
        const id = r.next_id;
        r.next_id += 1;
        r.sent[id] = .{ .key = key_of, .skip = skip, .topic = topic, .made = r.made[topic], .time = r.clock };
        for (0..3) |s| {
            if (r.on[s].topic == topic and r.on[s].made == r.made[topic] and r.passes(s, id)) r.put(s, id);
        }
        return id;
    }

    pub fn put(r: *Reference, s: usize, id: u64) void {
        r.held[s][r.counts[s]] = .{ .id = id };
        r.counts[s] += 1;
    }

    /// The second subscription's filter.
    pub fn passes(r: *const Reference, s: usize, id: u64) bool {
        return s != 1 or !r.sent[id].skip;
    }

    /// Whether a message was sent to the topic a subscription is of.
    pub fn sameTopic(r: *const Reference, of: Topic, id: u64) bool {
        return r.sent[id].topic == of.topic and r.sent[id].made == of.made;
    }

    /// Takes snapshot `slot` of subscription `s`.
    pub fn take(r: *Reference, slot: usize, s: usize) void {
        r.taken[slot] = .{ .of = r.on[s], .from = r.next_id };
        const taken = &r.taken[slot].?;
        for (r.all(s)) |h| {
            if (h.acked) continue;
            taken.held[taken.count] = h.id;
            taken.count += 1;
        }
    }

    /// A seek to snapshot `slot`. False when its topic is another.
    pub fn seekTo(r: *Reference, s: usize, slot: usize) bool {
        const taken = r.taken[slot].?;
        if (taken.of.topic != r.on[s].topic or taken.of.made != r.on[s].made) return false;
        r.counts[s] = 0;
        for (taken.held[0..taken.count]) |id| {
            if (r.passes(s, id)) r.put(s, id);
        }
        for (taken.from..r.next_id) |id| {
            if (r.sameTopic(r.on[s], id) and r.passes(s, id)) r.put(s, id);
        }
        return true;
    }

    /// A seek to a time: of what the subscription still has, what was
    /// published from then on. It has what is not acknowledged; the
    /// first subscription what it was there for, a week; and any what its
    /// topic retains.
    pub fn seekAt(r: *Reference, s: usize, time: i96) void {
        var unacknowledged: [2 * max_held]bool = @splat(false);
        for (r.all(s)) |h| unacknowledged[h.id] = !h.acked;
        r.counts[s] = 0;
        for (1..r.next_id) |id| {
            const m = r.sent[id];
            if (!r.sameTopic(r.on[s], id) or m.time < time) continue;
            const age = r.clock - m.time;
            const kept = (s == 0 and id >= r.joined[0] and age < 604_800 * std.time.ns_per_s) or
                if (topic_retention_s[m.topic]) |seconds| age < seconds * std.time.ns_per_s else false;
            if (unacknowledged[id] or (kept and r.passes(s, id))) r.put(s, id);
        }
    }

    pub fn all(r: *Reference, s: usize) []Held {
        return r.held[s][0..r.counts[s]];
    }

    pub fn indexOf(r: *Reference, s: usize, id: u64) ?usize {
        for (r.all(s), 0..) |h, i| {
            if (h.id == id) return i;
        }
        return null;
    }

    /// The key that orders it on subscription `s`, or 0.
    pub fn key(r: *const Reference, s: usize, h: Held) u8 {
        return if (ordered[s]) r.sent[h.id].key else 0;
    }

    pub fn remove(r: *Reference, s: usize, index: usize) void {
        const held = r.all(s);
        std.mem.copyForwards(Held, held[index .. held.len - 1], held[index + 1 ..]);
        r.counts[s] -= 1;
    }

    /// A delivery over with no ack, by a nack or a lapse, at `at`. True
    /// when the message moved on to the dead-letter topic.
    pub fn release(r: *Reference, s: usize, index: usize, at: i96) bool {
        const h = r.held[s][index];
        const gone = r.forwards and s == 2 and h.deliveries >= max_attempts;
        if (gone) {
            r.remove(s, index);
            _ = r.arrive(0, r.sent[h.id].key, r.sent[h.id].skip);
        } else {
            r.held[s][index].lease_until = null;
            const doublings: u5 = if (r.doubles) @intCast(@min(h.deliveries - 1, 3)) else 0;
            if (s == 1) r.held[s][index].not_before = at + @as(i96, @min(20, @as(u32, 5) << doublings)) * std.time.ns_per_s;
        }
        // The later ones of its key come back with it.
        const k = r.key(s, h);
        if (k != 0) for (r.all(s)[index + @intFromBool(!gone) ..]) |*later| {
            if (r.key(s, later.*) != k) continue;
            later.lease_until = null;
            later.acked = false;
        };
        return gone;
    }

    /// Ends every lease that has run out by `now`: the subscriptions by
    /// name, each one's messages as they came.
    pub fn settle(r: *Reference, now: i96) void {
        for (0..3) |s| {
            var i: usize = 0;
            while (i < r.counts[s]) {
                if (r.held[s][i].lease_until) |until| {
                    if (until <= now and r.release(s, i, until)) continue;
                }
                i += 1;
            }
        }
    }

    /// Whether a pull may give it at `now`, to which all is settled.
    pub fn ready(r: *Reference, s: usize, index: usize, now: i96) bool {
        const h = r.held[s][index];
        if (h.acked or h.lease_until != null or h.not_before > now) return false;
        const k = r.key(s, h);
        if (k == 0) return true;
        // A key gives nothing while one of its messages is out.
        for (r.all(s)) |e| {
            if (r.key(s, e) == k and e.lease_until != null) return false;
        }
        // Nor does one come past an earlier one of its key that waits out
        // a backoff. With exactly-once delivery, the third subscription's,
        // none comes past an earlier one at all.
        for (r.all(s)[0..index]) |e| {
            if (r.key(s, e) == k and !e.acked and (s == 2 or e.not_before > now)) return false;
        }
        return true;
    }

    /// Which of subscription `s` a pull may give at `now`, and how many.
    pub fn readySet(r: *Reference, s: usize, now: i96, set: *[max_held]bool) usize {
        var n: usize = 0;
        for (0..r.counts[s]) |i| {
            set[i] = r.ready(s, i, now);
            n += @intFromBool(set[i]);
        }
        return n;
    }

    pub fn backlog(r: *Reference, s: usize) usize {
        var n: usize = 0;
        for (r.all(s)) |h| n += @intFromBool(!h.acked);
        return n;
    }

    pub fn outstanding(r: *Reference, s: usize) usize {
        var n: usize = 0;
        for (r.all(s)) |h| n += @intFromBool(h.lease_until != null);
        return n;
    }

    /// Whether the id of delivery `attempt` may still act on it: it is
    /// out, and with exactly-once delivery this is that delivery.
    pub fn live(s: usize, h: Held, attempt: u32) bool {
        return h.lease_until != null and (s != 2 or attempt == h.deliveries);
    }

    /// An ack. False when the subscription refuses it.
    pub fn ack(r: *Reference, s: usize, id: u64, attempt: u32) bool {
        // Gone: with exactly-once delivery taken again only with the id
        // that acknowledged it.
        const index = r.indexOf(s, id) orelse return s != 2 or r.acknowledged_by[id] == attempt;
        const h = &r.held[s][index];
        if (h.acked) return true;
        if (!live(s, h.*, attempt)) return s != 2;
        if (s == 2) r.acknowledged_by[id] = attempt;
        const k = r.key(s, h.*);
        if (k == 0) {
            r.remove(s, index);
            return true;
        }
        // Kept while an earlier one of its key is not acknowledged.
        h.acked = true;
        h.lease_until = null;
        var i: usize = 0;
        while (i < r.counts[s]) {
            const e = r.held[s][i];
            if (r.key(s, e) != k) {
                i += 1;
            } else if (e.acked) r.remove(s, i) else break;
        }
        return true;
    }

    /// A lease change, a nack when `seconds` is 0. False when refused.
    pub fn modify(r: *Reference, s: usize, id: u64, attempt: u32, seconds: u32, now: i96) bool {
        const index = r.indexOf(s, id) orelse return s != 2;
        const h = &r.held[s][index];
        if (h.acked or !live(s, h.*, attempt)) return s != 2;
        if (seconds == 0) {
            _ = r.release(s, index, now);
        } else h.lease_until = now + @as(i96, seconds) * std.time.ns_per_s;
        return true;
    }
};

const sub_ids = [3][]const u8{ "sub0", "sub1", "sub2" };
const topic_ids = [2][]const u8{ "top0", "top1" };
pub const key_names = [3]?[]const u8{ null, "a", "b" };

const snapshot_ids = [3][]const u8{ "snap0", "snap1", "snap2" };

/// How topic `topic` of the model is made.
pub fn modelTopic(topic: u8) types.TopicConfig {
    return .{ .message_retention = if (Reference.topic_retention_s[topic]) |seconds| .fromSeconds(seconds) else null };
}

/// The rules subscription `s` of the model is made with, on the topic of
/// that id, its dead letters going to the model's first topic.
pub fn modelSubscription(s: usize, topic_id: []const u8, first_topic_id: []const u8) types.SubscriptionConfig {
    return switch (s) {
        0 => .{ .topic_id = topic_id, .ack_deadline_seconds = Reference.deadline_s[0], .retain_acked_messages = true },
        1 => .{
            .topic_id = topic_id,
            .ack_deadline_seconds = Reference.deadline_s[1],
            .enable_message_ordering = true,
            .filter = "NOT attributes:skip",
            .retry_policy = .{ .minimum = .fromSeconds(5), .maximum = .fromSeconds(20) },
        },
        else => .{
            .topic_id = topic_id,
            .ack_deadline_seconds = Reference.deadline_s[2],
            .enable_message_ordering = true,
            .enable_exactly_once_delivery = true,
            .dead_letter_policy = .{ .topic = first_topic_id, .max_delivery_attempts = Reference.max_attempts },
        },
    };
}

fn makeModelTopic(b: *Bench, topic: u8) !void {
    var made = try b.client.topic(topic_ids[topic]).create(modelTopic(topic));
    made.deinit();
}

/// Makes subscription `s` of the model on `topic`, with its rules.
fn makeModelSubscription(b: *Bench, s: usize, topic: u8) !void {
    var made = try b.client.subscription(sub_ids[s]).create(modelSubscription(s, topic_ids[topic], topic_ids[0]));
    made.deinit();
}

/// One pull of the model: as many as the reference has ready, up to
/// `max`, each of them ready, and a key's in their order. Marks them out.
fn modelPull(b: *Bench, ref: *Reference, s: usize, max: u32, deliveries: *std.ArrayList(ModelDelivery), a: Allocator, incarnation: u32) !usize {
    const now = b.clock.now_ns;
    var was_ready: [Reference.max_held]bool = undefined;
    const ready = ref.readySet(s, now, &was_ready);
    var got = try b.client.subscription(sub_ids[s]).pull(.{ .max_messages = max });
    defer got.deinit();
    // No fewer than it has ready, up to what was asked.
    try testing.expectEqual(@min(max, ready), got.value.messages.len);
    for (got.value.messages) |m| {
        const id = try std.fmt.parseInt(u64, m.message_id, 10);
        // Never one it does not hold, and never one that is out,
        // acknowledged, waiting out a backoff, or behind another of its
        // key.
        const index = ref.indexOf(s, id) orelse return error.TestUnexpectedMessage;
        try testing.expect(was_ready[index]);
        const held = &ref.held[s][index];
        try testing.expectEqual(null, held.lease_until);
        // In its key's order: every earlier one of the key that was ready
        // came before it in this pull.
        const k = ref.key(s, held.*);
        if (k != 0) for (ref.all(s)[0..index], was_ready[0..index]) |e, e_ready| {
            if (ref.key(s, e) == k and e_ready) try testing.expect(e.lease_until != null);
        };
        held.lease_until = now + @as(i96, Reference.deadline_s[s]) * std.time.ns_per_s;
        held.deliveries += 1;
        // The attempt is sent with a dead-letter policy alone.
        try testing.expectEqual(if (s == 2) held.deliveries else 0, m.delivery_attempt);
        try testing.expectEqualStrings(key_names[ref.sent[id].key] orelse "", m.ordering_key);
        try testing.expectEqual(ref.sent[id].skip, m.attribute("skip") != null);
        try deliveries.append(a, .{ .sub = s, .incarnation = incarnation, .id = id, .attempt = held.deliveries, .ack_id = try a.dupe(u8, m.ack_id) });
    }
    return got.value.messages.len;
}

/// The service agent a script may name. It holds no grant on anything.
pub const model_agent = "serviceAccount:service-1@gcp-sa-pubsub.iam.gserviceaccount.com";

/// Every delivery's ack id, with the subscription's incarnation then and
/// which delivery of the message it was. With exactly-once delivery, and
/// once a seek has come: until when the lease it had then runs, and
/// whether an ack by its id has been answered.
const ModelDelivery = struct { sub: usize, incarnation: u32, id: u64, attempt: u32, ack_id: []const u8, until: ?i96 = null, answered: bool = false };

fn modelProperty(_: void, input: []const u8) !void {
    _ = try modelRun(input);
}

/// What a script came to, step by step: its steps, by kind.
const ModelRun = struct {
    steps: usize = 0,
    published: usize = 0,
    pulls: usize = 0,
    acks: usize = 0,
    nacks: usize = 0,
    leases: usize = 0,
    waits: usize = 0,
    remade: usize = 0,
    snapshots: usize = 0,
    seeks: usize = 0,
};

fn modelRun(input: []const u8) !ModelRun {
    var ran: ModelRun = .{};
    var g: test_util.ByteGen = .init(input);
    // A run is a whole session of calls. The fuzzer makes tens of
    // thousands a night, and the allocator that looks for leaks, which
    // records where each allocation was made, was most of a run's cost:
    // under the fuzzer the session has a plain one. The corpus and the
    // random runs of every test run keep the one that looks.
    const gpa = if (@import("builtin").fuzz) std.heap.smp_allocator else testing.allocator;
    // The first byte: the order of the fake's pulls, and whether Pub/Sub's
    // service agent is named, with no grant, so that nothing is forwarded.
    const first = g.byte();
    const granted = first & 2 == 0;
    var b: Bench = undefined;
    try b.initIn(gpa, .{ .shuffle = first & 1 == 1, .service_agent = if (granted) null else model_agent });
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    var ref: Reference = .{ .forwards = granted };
    for (0..2) |topic| try makeModelTopic(&b, @intCast(topic));
    for (0..3) |s| try makeModelSubscription(&b, s, ref.on[s].topic);
    var deliveries: std.ArrayList(ModelDelivery) = .empty;
    var incarnation: [3]u32 = @splat(0);
    // Deliveries before this one are from before a seek of the
    // subscription: their ids are answered and forgotten.
    var stale_before: [3]usize = @splat(0);
    var published: usize = 0;

    var steps: usize = 0;
    while (steps < 60 and g.pos < g.bytes.len) : (steps += 1) {
        const now = b.clock.now_ns;
        ref.clock = now;
        switch (g.intRange(u8, 0, 11)) {
            0, 1 => {
                const topic = g.intRange(u8, 0, 1);
                const count = g.intRange(u8, 1, 3);
                // One ordering key a request, as production has it.
                const k = g.intRange(u8, 0, 2);
                if (published + count > Reference.max_held / 2) continue;
                ran.published += count;
                var messages: [3]types.Message = undefined;
                var bufs: [3][8]u8 = undefined;
                var skips: [3]bool = undefined;
                for (messages[0..count], bufs[0..count], skips[0..count]) |*m, *buf, *skip| {
                    skip.* = g.boolean();
                    m.* = .{ .data = try std.fmt.bufPrint(buf, "m{d}", .{published}), .attributes = if (skip.*) &.{.{ .key = "skip", .value = "1" }} else &.{} };
                    published += 1;
                }
                var sent = try b.client.topic(topic_ids[topic]).publish(messages[0..count], .{ .ordering_key = key_names[k] });
                defer sent.deinit();
                // Ids in order, the dead letters' among them.
                for (sent.value.message_ids, skips[0..count]) |text, skip| {
                    try testing.expectEqual(ref.arrive(topic, k, skip), try std.fmt.parseInt(u64, text, 10));
                }
            },
            2, 3, 4 => {
                const s = g.intRange(u8, 0, 2);
                _ = try modelPull(&b, &ref, s, g.intRange(u8, 1, 4), &deliveries, a, incarnation[s]);
                ran.pulls += 1;
            },
            5, 6, 7 => |op| {
                if (deliveries.items.len == 0) continue;
                const which = g.intRange(u16, 0, @intCast(deliveries.items.len - 1));
                const d = &deliveries.items[which];
                const sub = b.client.subscription(sub_ids[d.sub]);
                switch (op) {
                    5 => ran.acks += 1,
                    6 => ran.nacks += 1,
                    else => ran.leases += 1,
                }
                // How long is asked of a lease change alone: an ack that
                // took a byte for it too left every script written by
                // hand a byte out after its first ack.
                const seconds: u32 = switch (op) {
                    7 => ([_]u32{ 5, 30, 600 })[g.intRange(u8, 0, 2)],
                    else => 0,
                };
                const result = if (op == 5) sub.ack(&.{d.ack_id}) else sub.modifyAckDeadline(&.{d.ack_id}, seconds);
                // An id from before the subscription was made again is
                // not this subscription's.
                if (d.incarnation != incarnation[d.sub]) {
                    try testing.expectError(error.InvalidArgument, result);
                    continue;
                }
                // One from before a seek goes on naming its message.
                // Without exactly-once delivery it is judged as any is.
                // With it, the delivery it is of goes on being out, on
                // the lease it had, through the seek.
                if (which < stale_before[d.sub] and d.sub == 2) {
                    const out = if (ref.indexOf(2, d.id)) |index| ref.held[2][index].lease_until != null else false;
                    const running = d.until != null and d.until.? > now;
                    const answered = if (!running) op == 5 and d.answered else switch (op) {
                        // An ack is answered, and acknowledges the
                        // message if it is out again, by no delivery of
                        // its own.
                        5 => answered: {
                            d.answered = true;
                            d.until = null;
                            if (out) {
                                try testing.expect(ref.ack(2, d.id, ref.held[2][ref.indexOf(2, d.id).?].deliveries));
                                ref.acknowledged_by[d.id] = 0;
                            }
                            break :answered true;
                        },
                        // A longer lease is answered, and runs.
                        7 => answered: {
                            d.until = now + @as(i96, seconds) * std.time.ns_per_s;
                            break :answered true;
                        },
                        // A nack gives nothing back: answered if the
                        // message is out again, and if not refused, and
                        // the id done.
                        else => answered: {
                            if (!out) d.until = null;
                            break :answered out;
                        },
                    };
                    if (answered) try result else try testing.expectError(error.InvalidArgument, result);
                    continue;
                }
                // Refused only with exactly-once delivery, when it comes
                // too late.
                const taken = if (op == 5) ref.ack(d.sub, d.id, d.attempt) else ref.modify(d.sub, d.id, d.attempt, seconds, now);
                if (taken) try result else try testing.expectError(error.InvalidArgument, result);
            },
            8 => {
                ran.waits += 1;
                b.advance(g.intRange(u8, 1, 15));
                ref.clock = b.clock.now_ns;
                ref.settle(b.clock.now_ns);
            },
            // A snapshot taken, in place of the one of its name.
            10 => {
                ran.snapshots += 1;
                const slot = g.intRange(u8, 0, 2);
                const s = g.intRange(u8, 0, 2);
                const snapshot = b.client.snapshot(snapshot_ids[slot]);
                if (ref.taken[slot] != null) try snapshot.delete() else try testing.expectError(error.NotFound, snapshot.delete());
                ref.taken[slot] = null;
                // None is taken of a subscription whose topic is gone.
                if (ref.on[s].made != ref.made[ref.on[s].topic]) {
                    try testing.expectError(error.FailedPrecondition, snapshot.create(.{ .subscription = sub_ids[s] }));
                    continue;
                }
                var made = try snapshot.create(.{ .subscription = sub_ids[s] });
                made.deinit();
                ref.take(slot, s);
            },
            // A seek: to a snapshot, to a time some way back, or ahead.
            11 => {
                ran.seeks += 1;
                const s = g.intRange(u8, 0, 2);
                const sub = b.client.subscription(sub_ids[s]);
                const choice = g.intRange(u8, 0, 4);
                // What is out, by which delivery, and which id has
                // acknowledged its message: asked of the reference before
                // the seek does away with it.
                const Before = struct { until: ?i96, answered: bool };
                const before = try a.alloc(Before, deliveries.items.len - stale_before[s]);
                for (before, deliveries.items[stale_before[s]..]) |*slot, d| {
                    slot.* = .{ .until = null, .answered = false };
                    if (d.sub != s or d.incarnation != incarnation[s]) continue;
                    slot.answered = ref.acknowledged_by[d.id] == d.attempt;
                    const held = ref.held[s][ref.indexOf(s, d.id) orelse continue];
                    if (held.deliveries == d.attempt and !held.acked) slot.until = held.lease_until;
                }
                if (choice < 3) {
                    const result = sub.seek(.{ .snapshot = snapshot_ids[choice] });
                    if (ref.taken[choice] == null) {
                        try testing.expectError(error.NotFound, result);
                        continue;
                    }
                    if (!ref.seekTo(s, choice)) {
                        try testing.expectError(error.FailedPrecondition, result);
                        continue;
                    }
                    try result;
                } else {
                    const back = @as(i96, g.intRange(u8, 0, 60)) * 20 * std.time.ns_per_s;
                    const time: i96 = if (choice == 3) @max(0, now - back) else now + back;
                    try sub.seek(.{ .time = .{ .nanoseconds = time } });
                    ref.seekAt(s, time);
                }
                for (before, deliveries.items[stale_before[s]..]) |was, *d| {
                    if (d.sub != s or d.incarnation != incarnation[s]) continue;
                    d.until = was.until;
                    d.answered = was.answered;
                }
                stale_before[s] = deliveries.items.len;
                if (s == 2) ref.acknowledged_by = @splat(0);
            },
            else => switch (g.intRange(u8, 0, 3)) {
                // A subscription deleted and made again: it holds nothing.
                0, 1 => {
                    ran.remade += 1;
                    const s = g.intRange(u8, 0, 2);
                    const topic = g.intRange(u8, 0, 1);
                    try b.client.subscription(sub_ids[s]).delete();
                    try makeModelSubscription(&b, s, topic);
                    ref.counts[s] = 0;
                    ref.on[s] = .{ .topic = topic, .made = ref.made[topic] };
                    ref.joined[s] = ref.next_id;
                    incarnation[s] += 1;
                },
                // A topic deleted and made again: its subscriptions keep
                // what they hold, and get nothing more. Dead letters go
                // to the one that has the name now.
                else => {
                    ran.remade += 1;
                    const topic = g.intRange(u8, 0, 1);
                    try b.client.topic(topic_ids[topic]).delete();
                    try makeModelTopic(&b, topic);
                    ref.made[topic] += 1;
                },
            },
        }
        for (sub_ids, 0..) |id, s| {
            try testing.expectEqual(ref.backlog(s), b.fake.backlog("p", id));
            try testing.expectEqual(ref.outstanding(s), b.fake.outstanding("p", id));
        }
    }

    // In the end: every lease lapses, of 600 seconds at most, and then
    // every backoff runs out, of 20. Each subscription gives exactly what
    // it should hold, a key's in their order, each acknowledged as it
    // comes, until it holds nothing.
    b.advance(600 + 20 + 1);
    ref.clock = b.clock.now_ns;
    ref.settle(b.clock.now_ns);
    for (sub_ids, 0..) |id, s| {
        const sub = b.client.subscription(id);
        try testing.expectEqual(ref.counts[s], b.fake.backlog("p", id));
        while (ref.counts[s] > 0) {
            const before = deliveries.items.len;
            // Each round takes at least one away: with exactly-once
            // delivery a key gives one message a round.
            try testing.expect(try modelPull(&b, &ref, s, 1000, &deliveries, a, incarnation[s]) > 0);
            for (deliveries.items[before..]) |d| {
                try sub.ack(&.{d.ack_id});
                try testing.expect(ref.ack(s, d.id, d.attempt));
            }
        }
        try testing.expectEqual(0, b.fake.backlog("p", id));
        try expectNothing(sub);
    }
    ran.steps = steps;
    return ran;
}

// A script is bytes, and what its bytes mean is the property's to say: a
// change there moves every script written by hand to mean something else,
// and none of them fails for it. One did: an ack took a byte for a
// lease's length, so that every script was a byte out after its first
// ack, from the day the property was written until a replay against
// production printed what the scripts did (2026-10-13).
test "the model property's scripts written by hand do what is said of them" {
    const said = [model_corpus.len]ModelRun{
        .{},
        // Publish, pull, let the lease lapse, ack late, pull again, ack.
        .{ .steps = 6, .published = 1, .pulls = 2, .waits = 1, .acks = 2 },
        // Five nacks, then a pull of the first subscription and an ack.
        .{ .steps = 13, .published = 1, .pulls = 6, .nacks = 5, .acks = 1 },
        // Three of a key, the third acknowledged and the first nacked,
        // a pull, five seconds, a pull.
        .{ .steps = 7, .published = 3, .pulls = 3, .acks = 1, .nacks = 1, .waits = 1 },
        // A late ack, the message again, its old id, its new one, and a
        // lease change.
        .{ .steps = 8, .published = 1, .pulls = 2, .waits = 1, .acks = 3, .leases = 1 },
        // Two of a key, four pulls, two acks and a nack between them.
        .{ .steps = 8, .published = 2, .pulls = 4, .acks = 2, .nacks = 1 },
        // A second of a key published while the first is out.
        .{ .steps = 6, .published = 2, .pulls = 3, .acks = 1 },
        // Two messages, and a pull of each of two subscriptions.
        .{ .steps = 3, .published = 2, .pulls = 2 },
        // A subscription made again, an old id, and a message after.
        .{ .steps = 6, .published = 2, .pulls = 2, .remade = 1, .acks = 1 },
        // The dead-letter topic made again, five nacks, then the other.
        .{ .steps = 16, .published = 2, .pulls = 7, .nacks = 5, .remade = 2 },
        // A snapshot of two that are out, both acknowledged, a seek, both
        // again, and an id from before the seek.
        .{ .steps = 9, .published = 2, .pulls = 3, .snapshots = 1, .acks = 3, .seeks = 1 },
        // An ack, a seek back, a pull, a seek ahead, a pull.
        .{ .steps = 8, .published = 1, .pulls = 3, .acks = 1, .waits = 1, .seeks = 2 },
        // An ack, a seek back, the old id, the message again, its ack.
        .{ .steps = 7, .published = 1, .pulls = 2, .acks = 3, .seeks = 1 },
        // Two snapshots, four seeks, and a topic made again.
        .{ .steps = 7, .snapshots = 2, .seeks = 4, .remade = 1 },
        // Found by the random runs.
        .{ .steps = 11, .pulls = 3, .waits = 1, .remade = 2, .snapshots = 1, .seeks = 1 },
        // Seven nacks with no grant, a pull of the first subscription,
        // an eighth delivery and its ack.
        .{ .steps = 18, .published = 1, .pulls = 9, .nacks = 7, .acks = 1 },
    };
    for (model_corpus, said) |script, expected| try testing.expectEqual(expected, try modelRun(script));
}

/// The scripts the model property always runs, each a case someone
/// thought of or a random run once found. `production_replay.zig` runs
/// them too.
pub const model_corpus = [_][]const u8{
    "",
    // Publish, pull, let the lease lapse, ack late, pull again, ack.
    "\x00\x00\x00\x00\x00\x00\x02\x00\x03\x08\x0b\x05\x00\x00\x02\x00\x03\x05\x00\x00",
    // Dead letters: one message to the third subscription, nacked
    // five times, then pulled from the first and acknowledged.
    "\x00\x00\x01\x00\x01\x00\x02\x02\x00\x06\x00\x00\x02\x02\x00\x06\x00\x01\x02\x02\x00\x06\x00\x02\x02\x02\x00\x06\x00\x03\x02\x02\x00\x06\x00\x04\x02\x00\x03\x05\x00\x05",
    // Ordering with a backoff: three of a key to the second
    // subscription, the third acknowledged and the first nacked,
    // nothing for five seconds, then all three again.
    "\x00\x00\x00\x02\x02\x00\x00\x00\x02\x01\x03\x05\x00\x02\x06\x00\x00\x02\x01\x03\x08\x04\x02\x01\x03",
    // Exactly-once: a late ack refused, the message again, its old
    // id refused and its new one taken, then a lease change on it.
    "\x00\x00\x01\x00\x00\x00\x02\x02\x00\x08\x09\x05\x00\x00\x02\x02\x00\x05\x00\x00\x05\x00\x01\x07\x00\x01\x00",
    // Ordering with exactly-once: of two of a key the second comes
    // only when the first is acknowledged, and again when nacked.
    "\x00\x00\x01\x01\x01\x00\x00\x02\x02\x03\x02\x02\x03\x05\x00\x00\x02\x02\x03\x06\x00\x01\x02\x02\x03\x05\x00\x02",
    // Ordering alone: a second of a key, published while the first
    // is out, waits for the first's ack.
    "\x00\x00\x00\x00\x02\x00\x02\x01\x00\x00\x00\x00\x02\x00\x02\x01\x03\x05\x00\x00\x02\x01\x03",
    // A filter: of two messages the second subscription gets one.
    "\x01\x00\x00\x01\x00\x01\x00\x02\x01\x03\x02\x00\x03",
    // A subscription made again, then an old id.
    "\x00\x00\x00\x00\x00\x00\x02\x00\x00\x09\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00",
    // The dead-letter topic made again: five nacks forward to the
    // new one, where no subscription of the old listens. Then the
    // other topic made again under the third subscription.
    "\x00\x00\x01\x00\x00\x00\x09\x02\x00\x02\x02\x00\x06\x00\x00\x02\x02\x00\x06\x00\x01\x02\x02\x00\x06\x00\x02\x02\x02\x00\x06\x00\x03\x02\x02\x00\x06\x00\x04\x02\x00\x03\x09\x02\x01\x00\x01\x00\x00\x00\x02\x02\x03",
    // A snapshot of two that are out, both acknowledged, and a
    // seek back to it: both again, and an id from before the
    // seek forgotten.
    "\x00\x00\x00\x01\x00\x00\x00\x02\x00\x03\x0a\x00\x00\x05\x00\x00\x05\x00\x01\x0b\x00\x00\x02\x00\x03\x05\x00\x00\x02\x00\x03",
    // The subscription that retains what is acknowledged, sought
    // back in time: its message again. Then ahead: none.
    "\x00\x00\x00\x00\x00\x00\x02\x00\x00\x05\x00\x00\x08\x04\x0b\x00\x03\x01\x02\x00\x03\x0b\x00\x04\x01\x02\x00\x03",
    // The topic that retains messages: acknowledged with
    // exactly-once delivery, a message comes again after a seek
    // back, and its old id is forgotten, not refused.
    "\x00\x00\x01\x00\x00\x00\x02\x02\x00\x05\x00\x00\x0b\x02\x03\x01\x05\x00\x00\x02\x02\x03\x05\x00\x01",
    // A snapshot of another topic's subscription refuses the
    // seek, and one never taken is not found.
    "\x00\x0a\x01\x02\x0b\x00\x01\x0b\x00\x02\x09\x02\x01\x0a\x02\x02\x0b\x02\x02\x0b\x02\x01",
    // Found by the random runs: a backoff still running when the
    // last lease has lapsed, with later messages of its key behind.
    "\x00\x33\xa2\x88\xe9\x5a\xc3\xa6\x7a\xa3\xb1\x6b\x59\xd6\xa7\x86\xf8\x48\x15\xae\x08\x17\xbe\xdf\xb0\xc2\x11\x8f",
    // The service agent without its grants: nothing is forwarded, and
    // the message comes a sixth time, a seventh and an eighth, the last
    // acknowledged. The first subscription never has it.
    "\x02\x00\x01\x00\x01\x00\x02\x02\x00\x06\x00\x00\x02\x02\x00\x06\x00\x01\x02\x02\x00\x06\x00\x02\x02\x02\x00\x06\x00\x03\x02\x02\x00\x06\x00\x04\x02\x02\x00\x06\x00\x05\x02\x02\x00\x06\x00\x06\x02\x00\x03\x02\x02\x00\x05\x00\x07",
};

// These two are named apart from the `fuzz` properties on purpose. A run
// of the model property is a whole session of calls: under the fuzzer,
// on its plain allocator, the two together cost about 0.6 ms a run
// (measured 2026-10-12), several times what a codec's property does.
// They have a nightly job of their own, sized on its own.

test "fake property: after any script of calls each subscription holds exactly what a reference says" {
    try test_util.fuzzBytes({}, modelProperty, .{
        // A script is a byte for the order of pulls (its first bit) and
        // for the service agent named without a grant (its second), and
        // then steps: a
        // publish (0, topic, count less one, key, a byte a message for
        // `skip`), a pull (2, subscription, most less one), an ack, a
        // nack or a lease change of a delivery made so far (5, 6 or 7,
        // two bytes of which, and for 7 how long), the clock moved (8,
        // seconds less one), a subscription made again (9, 0, which, on
        // which topic) or a topic (9, 2, which), a snapshot taken (10,
        // its slot, of which subscription), and a seek (11, which
        // subscription, then a slot, or 3 and how far back in steps of
        // 20 seconds, or 4 and how far ahead).
        .corpus = &model_corpus,
        .random_runs = 400,
        .max_len = 240,
    });
}

/// Any bytes on any route: an answer, never a crash and never a leak.
fn arbitraryRequest(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // As the model property: a plain allocator under the fuzzer.
    const gpa = if (@import("builtin").fuzz) std.heap.smp_allocator else testing.allocator;
    var b: Bench = undefined;
    try b.initIn(gpa, .{});
    defer b.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/orders", "{}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/worker", "{\"topic\":\"projects/p/topics/orders\"}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/rules", "{\"topic\":\"projects/p/topics/orders\",\"enableMessageOrdering\":true,\"enableExactlyOnceDelivery\":true,\"filter\":\"attributes:k OR NOT attributes:k\",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/orders\"},\"retryPolicy\":{}}")).status);
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/topics/orders:publish", "{\"messages\":[{\"data\":\"eA==\",\"orderingKey\":\"o\"}]}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/snapshots/snap", "{\"subscription\":\"projects/p/subscriptions/worker\"}")).status);
    try testing.expectEqual(200, (try b.raw(a, .POST, "projects/p/schemas?schemaId=order", "{\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\"}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/typed", "{\"schemaSettings\":{\"schema\":\"projects/p/schemas/order\",\"encoding\":\"JSON\"}}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/subscriptions/pushed", "{\"topic\":\"projects/p/topics/orders\",\"pushConfig\":{\"pushEndpoint\":\"https://example.com/hook\"}}")).status);
    try testing.expectEqual(200, (try b.raw(a, .PUT, "projects/p/topics/imported", "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"textFormat\":{}}}}")).status);
    const paths = [_][]const u8{
        "projects/p/topics",                                  "projects/p/topics/orders",
        "projects/p/topics/orders:publish",                   "projects/p/topics/orders/subscriptions",
        "projects/p/subscriptions",                           "projects/p/subscriptions/worker",
        "projects/p/subscriptions/worker:pull",               "projects/p/subscriptions/worker:acknowledge",
        "projects/p/subscriptions/worker:modifyAckDeadline",  "projects/p/topics/new",
        "projects/p/subscriptions/new",                       "projects/p/topics?pageSize=1&pageToken=",
        "projects/p/subscriptions/rules",                     "projects/p/subscriptions/rules:pull",
        "projects/p/subscriptions/rules:acknowledge",         "projects/p/subscriptions/rules:modifyAckDeadline",
        "projects/p/snapshots",                               "projects/p/snapshots/snap",
        "projects/p/snapshots/new",                           "projects/p/topics/orders/snapshots",
        "projects/p/subscriptions/worker:seek",               "projects/p/subscriptions/rules:seek",
        "projects/p/subscriptions/worker:detach",             "projects/p/snapshots?pageSize=1&pageToken=",
        "projects/p/schemas",                                 "projects/p/schemas?schemaId=newer",
        "projects/p/schemas/order",                           "projects/p/schemas/order:commit",
        "projects/p/schemas/order:rollback",                  "projects/p/schemas/order:listRevisions",
        "projects/p/schemas:validate",                        "projects/p/schemas:validateMessage",
        "projects/p/schemas/order@9e3779b1",                  "projects/p/schemas/order@9e3779b1:deleteRevision",
        "projects/p/topics/typed",                            "projects/p/topics/typed:publish",
        "projects/p/subscriptions/pushed",                    "projects/p/subscriptions/pushed:modifyPushConfig",
        "projects/p/subscriptions/pushed:pull",               "projects/p/subscriptions/worker:modifyPushConfig",
        "projects/p/topics/imported",                         "projects/p/subscriptions/pushed:modifyAckDeadline",
        "projects/p/topics/orders:getIamPolicy",              "projects/p/topics/orders:setIamPolicy",
        "projects/p/topics/orders:testIamPermissions",        "projects/p/subscriptions/worker:setIamPolicy",
        "projects/p/subscriptions/worker:testIamPermissions", "projects/p/snapshots/snap:setIamPolicy",
        "projects/p/schemas/order:setIamPolicy",              "projects/p/schemas/order:testIamPermissions",
        "projects/p/snapshots/snap:getIamPolicy",             "projects/p/topics/orders:getIamPolicy?options.requestedPolicyVersion=",
    };
    const bodies = [_][]const u8{
        "{\"messages\":[{\"data\":\"",                                                                                                       "{\"topic\":\"projects/p/topics/orders\",",
        "{\"subscription\":{",                                                                                                               "{\"topic\":{",
        "{\"ackIds\":[\"",                                                                                                                   "{\"maxMessages\":",
        "{\"updateMask\":\"",                                                                                                                "",
        "{\"topic\":\"projects/p/topics/orders\",\"filter\":\"",                                                                             "{\"topic\":\"projects/p/topics/orders\",\"deadLetterPolicy\":{",
        "{\"topic\":\"projects/p/topics/orders\",\"retryPolicy\":{",                                                                         "{\"maxMessages\":3}",
        "{\"messages\":[{\"orderingKey\":\"o\",\"attributes\":{\"k\":\"",                                                                    "{\"ackIds\":[\"FAKE",
        "{\"subscription\":\"projects/p/subscriptions/worker\",",                                                                            "{\"snapshot\":\"projects/p/snapshots/snap\"}",
        "{\"time\":\"1970-01-01T00:00:0",                                                                                                    "{\"snapshot\":{\"labels\":{",
        "{\"type\":\"AVRO\",\"definition\":\"",                                                                                              "{\"schema\":{\"name\":\"projects/p/schemas/order\",\"type\":\"AVRO\",\"definition\":\"1\"},",
        "{\"revisionId\":\"",                                                                                                                "{\"name\":\"projects/p/schemas/order\",\"encoding\":\"JSON\",\"message\":\"",
        "{\"topic\":{\"schemaSettings\":{\"schema\":\"projects/p/schemas/",                                                                  "{\"schemaSettings\":{\"encoding\":\"BINARY\",",
        "{\"pushConfig\":{\"pushEndpoint\":\"https://e.x/",                                                                                  "{\"topic\":\"projects/p/topics/orders\",\"pushConfig\":{",
        "{\"topic\":\"projects/p/topics/orders\",\"bigqueryConfig\":{\"table\":\"p.d.",                                                      "{\"topic\":\"projects/p/topics/orders\",\"cloudStorageConfig\":{\"bucket\":\"b\",",
        "{\"topic\":\"projects/p/topics/orders\",\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenameDatetimeFormat\":\"YYYY-MM-DDThh:mm:ss", "{\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"f\",\"code\":\"",
        "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"textFormat\":{\"delimiter\":\"",                             "{\"ingestionDataSourceSettings\":{\"awsKinesis\":{\"streamArn\":\"",
        "{\"tags\":{\"p/k\":\"",                                                                                                             "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"https://e.x\"}},\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\",",
        "{\"policy\":{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\",\"",                                     "{\"policy\":{\"etag\":\"",
        "{\"policy\":{\"bindings\":[{\"role\":\"",                                                                                           "{\"permissions\":[\"pubsub.topics.get\",\"pubsub.",
        "{\"subscription\":{\"cloudStorageConfig\":{\"bucket\":\"b\"}},\"updateMask\":\"cloudStorageConfig\"}",                              "{\"topic\":{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"avroFormat\":{}}}},\"updateMask\":\"ingestionDataSourceSettings,messageTransforms\"}",
    };
    for (0..8) |_| {
        const method = g.pick(tp.Method, &.{ .GET, .PUT, .POST, .PATCH, .DELETE });
        const tail = g.slice(40);
        const path = try std.fmt.allocPrint(a, "{s}{s}", .{ g.pick([]const u8, &paths), if (g.boolean()) tail else "" });
        // A body that starts as a real one would and ends anywhere.
        const body = try std.fmt.allocPrint(a, "{s}{s}", .{ g.pick([]const u8, &bodies), g.slice(120) });
        const reply = try b.fake.serve(method, try std.fmt.allocPrint(a, "https://pubsub.googleapis.com/v1/{s}", .{path}), body, a);
        // 503 is production's own answer to a bucket of no form.
        try testing.expect(reply.status == 200 or reply.status == 400 or reply.status == 404 or reply.status == 409 or reply.status == 501 or reply.status == 503);
        // Every answer is JSON, a refusal with its code inside.
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, reply.body, .{});
        if (reply.status != 200) try testing.expectEqual(@as(i64, reply.status), parsed.object.get("error").?.object.get("code").?.integer);
    }
}

test "fake property: arbitrary requests on every route are answered, never crashed on" {
    try test_util.fuzzBytes({}, arbitraryRequest, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x7d\x7d\x7d\x7d",
        "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x01\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x03\x31\x7d",
    }, .random_runs = 300 });
}

/// A session of every kind of call, with the fake's own memory failing
/// anywhere: the call fails or is answered, and nothing leaks.
fn sessionAllocations(gpa: Allocator) !void {
    var clock: test_util.FakeClock = .{};
    var fake: FakePubSub = .init(gpa, clock.io(), .{});
    defer fake.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const base = "https://pubsub.googleapis.com/v1/projects/p/";
    const steps = [_]struct { tp.Method, []const u8, []const u8 }{
        .{ .PUT, "topics/orders", "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"600s\",\"kmsKeyName\":\"k\",\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"europe-west1\"]}}" },
        .{ .PUT, "topics/other", "{}" },
        .{ .PUT, "subscriptions/worker", "{\"topic\":\"projects/p/topics/orders\",\"labels\":{\"a\":\"b\"},\"expirationPolicy\":{}}" },
        .{ .PUT, "subscriptions/second", "{\"topic\":\"projects/p/topics/orders\"}" },
        .{ .PATCH, "topics/orders", "{\"topic\":{\"labels\":{\"env\":\"prod\"},\"kmsKeyName\":\"k2\"},\"updateMask\":\"labels,kmsKeyName,messageStoragePolicy\"}" },
        .{ .PATCH, "subscriptions/worker", "{\"subscription\":{\"labels\":{\"c\":\"d\"},\"ackDeadlineSeconds\":30},\"updateMask\":\"labels,ackDeadlineSeconds\"}" },
        .{ .POST, "topics/orders:publish", "{\"messages\":[{\"data\":\"aGVsbG8=\",\"attributes\":{\"k\":\"v\"},\"orderingKey\":\"o\"},{\"data\":\"eA==\",\"orderingKey\":\"o\"}]}" },
        .{ .GET, "topics?pageSize=1", "" },
        .{ .GET, "subscriptions", "" },
        .{ .GET, "topics/orders/subscriptions?pageSize=1", "" },
        .{ .POST, "subscriptions/worker:pull", "{\"maxMessages\":5}" },
        .{ .DELETE, "topics/other", "" },
        .{ .DELETE, "subscriptions/second", "" },
        .{ .GET, "topics/nope", "" },
        .{ .PUT, "topics/bad", "{\"labels\":{\"Env\":\"x\"}}" },
    };
    for (steps) |step| {
        const method, const path, const body = step;
        const reply = try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a);
        try testing.expect(reply.status < 500);
        if (std.mem.endsWith(u8, path, ":pull")) {
            const Wire = struct { receivedMessages: []const struct { ackId: []const u8 } = &.{} };
            const got = try std.json.parseFromSliceLeaky(Wire, a, reply.body, .{ .ignore_unknown_fields = true });
            try testing.expectEqual(2, got.receivedMessages.len);
            const ids = try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"],\"ackDeadlineSeconds\":20}}", .{ got.receivedMessages[0].ackId, got.receivedMessages[1].ackId });
            try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/worker:modifyAckDeadline", ids, a)).status);
            try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/worker:acknowledge", ids, a)).status);
        }
    }
    try testing.expectEqual(0, fake.backlog("p", "worker"));

    // A subscription with every rule: a filter read and kept, a key's
    // messages pulled in order, and five nacks that make dead letters.
    const rules = [_]struct { tp.Method, []const u8, []const u8 }{
        .{ .PUT, "topics/dead", "{}" },
        .{ .PUT, "subscriptions/rules", "{\"topic\":\"projects/p/topics/orders\",\"enableMessageOrdering\":true,\"filter\":\"attributes:k OR NOT (hasPrefix(attributes.\\\"a b\\\", \\\"c\\\\n\\\") AND attributes.d != \\\"e\\\")\",\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\"},\"retryPolicy\":{\"minimumBackoff\":\"0s\"}}" },
        .{ .PUT, "subscriptions/morgue", "{\"topic\":\"projects/p/topics/dead\",\"filter\":\"attributes.CloudPubSubDeadLetterSourceSubscription = \\\"rules\\\"\"}" },
        .{ .PUT, "subscriptions/bad", "{\"topic\":\"projects/p/topics/orders\",\"filter\":\"attributes.k = \\\"v\\\" AND\"}" },
        .{ .PATCH, "subscriptions/rules", "{\"subscription\":{\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\",\"maxDeliveryAttempts\":5},\"retryPolicy\":{\"maximumBackoff\":\"0s\",\"minimumBackoff\":\"0s\"}},\"updateMask\":\"deadLetterPolicy,retryPolicy,enableExactlyOnceDelivery\"}" },
        .{ .POST, "topics/orders:publish", "{\"messages\":[{\"data\":\"YQ==\",\"attributes\":{\"k\":\"v\"},\"orderingKey\":\"o\"},{\"data\":\"Yg==\",\"orderingKey\":\"o\"}]}" },
    };
    for (rules) |step| {
        const method, const path, const body = step;
        const reply = try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a);
        try testing.expectEqual(@as(u16, if (std.mem.endsWith(u8, path, "/bad")) 400 else 200), reply.status);
    }
    var last: []const u8 = "";
    for (0..5) |_| {
        const reply = try fake.serve(.POST, base ++ "subscriptions/rules:pull", "{\"maxMessages\":5}", a);
        const Wire = struct { receivedMessages: []const struct { ackId: []const u8 } = &.{} };
        const got = try std.json.parseFromSliceLeaky(Wire, a, reply.body, .{ .ignore_unknown_fields = true });
        try testing.expectEqual(2, got.receivedMessages.len);
        // With no seconds said, a nack.
        last = try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ got.receivedMessages[0].ackId, got.receivedMessages[1].ackId });
        try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/rules:modifyAckDeadline", last, a)).status);
    }
    // Forwarded, both.
    try testing.expectEqual(0, fake.backlog("p", "rules"));
    try testing.expectEqual(2, fake.backlog("p", "morgue"));
    // With exactly-once delivery: an ack that takes, the same again, and
    // a lease change on what is gone, which is refused, id by id.
    try testing.expectEqual(200, (try fake.serve(.PATCH, base ++ "subscriptions/morgue", "{\"subscription\":{\"enableExactlyOnceDelivery\":true},\"updateMask\":\"enableExactlyOnceDelivery\"}", a)).status);
    const dead = try fake.serve(.POST, base ++ "subscriptions/morgue:pull", "{\"maxMessages\":5}", a);
    const Dead = struct { receivedMessages: []const struct { ackId: []const u8 } };
    const letters = try std.json.parseFromSliceLeaky(Dead, a, dead.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(2, letters.receivedMessages.len);
    const both = try std.fmt.allocPrint(a, "{{\"ackIds\":[\"{s}\",\"{s}\"]}}", .{ letters.receivedMessages[0].ackId, letters.receivedMessages[1].ackId });
    for (0..2) |_| try testing.expectEqual(200, (try fake.serve(.POST, base ++ "subscriptions/morgue:acknowledge", both, a)).status);
    try testing.expectEqual(400, (try fake.serve(.POST, base ++ "subscriptions/morgue:modifyAckDeadline", both, a)).status);
    try testing.expectEqual(0, fake.backlog("p", "morgue"));

    // Replay: a snapshot made, read, changed and listed, a seek to it and
    // to a time, and a detach.
    try testing.expectEqual(200, (try fake.serve(.POST, base ++ "topics/dead:publish", "{\"messages\":[{\"data\":\"YQ==\"},{\"data\":\"Yg==\",\"attributes\":{\"CloudPubSubDeadLetterSourceSubscription\":\"rules\"}}]}", a)).status);
    const replay = [_]struct { tp.Method, []const u8, []const u8 }{
        .{ .PUT, "snapshots/taken", "{\"subscription\":\"projects/p/subscriptions/morgue\",\"labels\":{\"env\":\"test\"}}" },
        .{ .GET, "snapshots/taken", "" },
        .{ .PATCH, "snapshots/taken", "{\"snapshot\":{\"labels\":{\"env\":\"prod\",\"a\":\"b\"}},\"updateMask\":\"labels\"}" },
        .{ .GET, "snapshots?pageSize=1", "" },
        .{ .GET, "topics/dead/snapshots", "" },
        .{ .POST, "subscriptions/morgue:pull", "{\"maxMessages\":5}" },
        .{ .POST, "subscriptions/morgue:seek", "{\"time\":\"1970-01-01T00:00:00Z\"}" },
        .{ .POST, "subscriptions/morgue:seek", "{\"snapshot\":\"projects/p/snapshots/taken\"}" },
        .{ .POST, "subscriptions/morgue:detach", "" },
        .{ .GET, "subscriptions/morgue", "" },
        .{ .DELETE, "snapshots/taken", "" },
    };
    for (replay) |step| {
        const method, const path, const body = step;
        try testing.expectEqual(200, (try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a)).status);
        if (std.mem.endsWith(u8, path, ":seek")) try testing.expectEqual(1, fake.backlog("p", "morgue"));
    }
    try testing.expectEqual(0, fake.backlog("p", "morgue"));

    // Schemas: one made, given two more revisions, read every way, looked
    // at, set on a topic that is published to, and deleted.
    const made = try fake.serve(.POST, base ++ "schemas?schemaId=order", "{\"type\":\"AVRO\",\"definition\":\"{\\\"type\\\":\\\"string\\\"}\"}", a);
    const Made = struct { revisionId: []const u8 };
    const first = (try std.json.parseFromSliceLeaky(Made, a, made.body, .{ .ignore_unknown_fields = true })).revisionId;
    const schemas = [_]struct { tp.Method, []const u8, []const u8, u16 }{
        .{ .POST, "schemas/order:commit", "{\"schema\":{\"name\":\"projects/p/schemas/order\",\"type\":\"AVRO\",\"definition\":\"\\\"string\\\"\"}}", 200 },
        .{ .POST, "schemas/order:commit", "{\"schema\":{\"name\":\"projects/p/schemas/order\",\"type\":\"PROTOCOL_BUFFER\",\"definition\":\"x\"}}", 400 },
        .{ .POST, "schemas/order:rollback", try std.fmt.allocPrint(a, "{{\"revisionId\":\"{s}\"}}", .{first}), 200 },
        .{ .GET, try std.fmt.allocPrint(a, "schemas/order@{s}?view=BASIC", .{first}), "", 200 },
        .{ .GET, "schemas?view=FULL&pageSize=1", "", 200 },
        .{ .GET, "schemas/order:listRevisions?pageSize=2", "", 200 },
        .{ .POST, "schemas:validate", "{\"schema\":{\"type\":\"AVRO\",\"definition\":\"{nope\"}}", 400 },
        .{ .POST, "schemas:validateMessage", "{\"name\":\"projects/p/schemas/order\",\"message\":\"eA==\",\"encoding\":\"JSON\"}", 200 },
        .{ .PUT, "topics/typed", try std.fmt.allocPrint(a, "{{\"schemaSettings\":{{\"schema\":\"projects/p/schemas/order\",\"encoding\":\"JSON\",\"firstRevisionId\":\"{s}\"}}}}", .{first}), 200 },
        .{ .PUT, "subscriptions/reader", "{\"topic\":\"projects/p/topics/typed\"}", 200 },
        .{ .POST, "topics/typed:publish", "{\"messages\":[{\"data\":\"eA==\",\"attributes\":{\"googclient_schemaencoding\":\"BINARY\",\"k\":\"v\"}}]}", 200 },
        .{ .PATCH, "topics/typed", "{\"topic\":{\"schemaSettings\":{\"encoding\":\"BINARY\"}},\"updateMask\":\"schemaSettings.encoding\"}", 200 },
        .{ .DELETE, try std.fmt.allocPrint(a, "schemas/order@{s}:deleteRevision", .{first}), "", 200 },
        // The range has no end: the later revisions are still its own.
        .{ .POST, "topics/typed:publish", "{\"messages\":[{\"data\":\"eA==\"}]}", 200 },
        .{ .DELETE, "schemas/order", "", 200 },
        .{ .POST, "topics/typed:publish", "{\"messages\":[{\"data\":\"eA==\"}]}", 404 },
        .{ .GET, "topics/typed", "", 200 },
    };
    for (schemas) |step| {
        const method, const path, const body, const status = step;
        try testing.expectEqual(status, (try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a)).status);
    }
    try testing.expectEqual(2, fake.backlog("p", "reader"));

    // What is kept and not done: a subscription that pushes and is given
    // each other kind in turn, transforms, an import topic, tags.
    const function = "{\"javascriptUdf\":{\"functionName\":\"f\",\"code\":\"function f(message, metadata) { return message; }\"}";
    const kept = [_]struct { tp.Method, []const u8, []const u8, u16 }{
        .{ .PUT, "subscriptions/pushed", "{\"topic\":\"projects/p/topics/orders\",\"pushConfig\":{\"pushEndpoint\":\"https://example.com/hook\",\"attributes\":{\"x-goog-version\":\"v1beta1\"},\"oidcToken\":{\"serviceAccountEmail\":\"a@p.iam.gserviceaccount.com\",\"audience\":\"x\"},\"noWrapper\":{\"writeMetadata\":true}},\"messageTransforms\":[" ++ function ++ ",\"disabled\":true}],\"tags\":{\"p/env\":\"prod\"}}", 200 },
        .{ .GET, "subscriptions/pushed", "", 200 },
        .{ .POST, "subscriptions/pushed:pull", "{\"maxMessages\":1}", 400 },
        .{ .POST, "subscriptions/pushed:modifyPushConfig", "{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/other\",\"pubsubWrapper\":{}}}", 200 },
        .{ .PATCH, "subscriptions/pushed", "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/third\"}},\"updateMask\":\"pushConfig.pushEndpoint\"}", 200 },
        .{ .PATCH, "subscriptions/pushed", "{\"subscription\":{\"bigqueryConfig\":{\"table\":\"p.d.t\",\"useTopicSchema\":true,\"serviceAccountEmail\":\"a@p.iam.gserviceaccount.com\"}},\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}", 200 },
        .{ .PATCH, "subscriptions/pushed", "{\"subscription\":{\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenamePrefix\":\"a/\",\"filenameSuffix\":\".avro\",\"filenameDatetimeFormat\":\"YYYY-MM-DD/hh_mm_ssZ\",\"avroConfig\":{\"writeMetadata\":true},\"maxDuration\":\"90.5s\",\"maxBytes\":\"1000\",\"maxMessages\":\"1000\",\"serviceAccountEmail\":\"a@p.iam.gserviceaccount.com\"}},\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}", 200 },
        .{ .PATCH, "subscriptions/pushed", "{\"subscription\":{\"cloudStorageConfig\":{\"bucket\":\"b\",\"filenameDatetimeFormat\":\"YYYY\"}},\"updateMask\":\"cloudStorageConfig\"}", 400 },
        .{ .PATCH, "subscriptions/pushed", "{\"subscription\":{\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"59.5s\"}},\"updateMask\":\"cloudStorageConfig\"}", 400 },
        .{ .PATCH, "subscriptions/pushed", "{\"subscription\":{\"messageTransforms\":[" ++ function ++ "}]},\"updateMask\":\"messageTransforms\"}", 200 },
        .{ .PATCH, "subscriptions/pushed", "{\"subscription\":{\"messageTransforms\":[" ++ function ++ "}," ++ function ++ "}]},\"updateMask\":\"messageTransforms\"}", 400 },
        .{ .GET, "subscriptions", "", 200 },
        .{ .PUT, "topics/imported", "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"gs://b\",\"textFormat\":{\"delimiter\":\"|\"},\"minimumObjectCreateTime\":\"2030-01-01T00:00:00+01:00\",\"matchGlob\":\"a/**\"},\"platformLogsSettings\":{\"severity\":\"DEBUG\"}},\"messageTransforms\":[" ++ function ++ "}],\"tags\":{\"tagKeys/1\":\"tagValues/2\"}}", 200 },
        .{ .GET, "topics/imported", "", 200 },
        .{ .PATCH, "topics/imported", "{\"topic\":{\"ingestionDataSourceSettings\":{\"awsKinesis\":{\"streamArn\":\"s\",\"consumerArn\":\"c\",\"awsRoleArn\":\"r\",\"gcpServiceAccount\":\"a\"}}},\"updateMask\":\"ingestionDataSourceSettings,messageTransforms\"}", 200 },
        .{ .PATCH, "topics/imported", "{\"topic\":{\"ingestionDataSourceSettings\":{\"awsKinesis\":{}}},\"updateMask\":\"ingestionDataSourceSettings\"}", 400 },
        .{ .PATCH, "topics/imported", "{\"topic\":{\"ingestionDataSourceSettings\":{\"awsKinesis\":{},\"cloudStorage\":{}}},\"updateMask\":\"ingestionDataSourceSettings\"}", 400 },
        .{ .PATCH, "topics/imported", "{\"topic\":{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"avroFormat\":{},\"minimumObjectCreateTime\":\"then\"}}},\"updateMask\":\"ingestionDataSourceSettings\"}", 400 },
        .{ .GET, "topics", "", 200 },
        .{ .PUT, "snapshots/tagged", "{\"subscription\":\"projects/p/subscriptions/worker\",\"tags\":{\"p/env\":\"prod\"}}", 200 },
        .{ .PUT, "topics/untagged", "{\"tags\":{\"env\":\"prod\"}}", 400 },
        .{ .PUT, "subscriptions/exports", "{\"topic\":\"projects/p/topics/orders\",\"bigqueryConfig\":{\"table\":\"p.d.t\"}}", 200 },
    };
    for (kept) |step| {
        const method, const path, const body, const status = step;
        try testing.expectEqual(status, (try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a)).status);
    }
    fake.setExportState("p", "exports", .not_found);
    fake.setIngestionState("p", "imported", .permission_denied);
    try testing.expect(std.mem.indexOf(u8, (try fake.serve(.GET, base ++ "subscriptions/exports", "", a)).body, "\"RESOURCE_ERROR\"") != null);
    try testing.expect(std.mem.indexOf(u8, (try fake.serve(.GET, base ++ "topics/imported", "", a)).body, "\"KINESIS_PERMISSION_DENIED\"") != null);
    try testing.expectEqualStrings("prod", fake.tagValue("projects/p/snapshots/tagged", "p/env").?);
    try testing.expectEqualStrings("prod", fake.tagValue("projects/p/subscriptions/pushed", "p/env").?);
    try testing.expectEqualStrings("tagValues/2", fake.tagValue("projects/p/topics/imported", "tagKeys/1").?);

    // IAM: a policy written, read, written over under its etag and under
    // an older one, permissions tested, and a dead letter that waits for
    // the service agent's two grants.
    const agent = "serviceAccount:service-1@gcp-sa-pubsub.iam.gserviceaccount.com";
    const grant = "{\"policy\":{\"bindings\":[{\"role\":\"roles/pubsub.editor\",\"members\":[\"" ++ agent ++ "\",\"user:A@X.com\",\"user:a@x.com\"]},{\"role\":\"roles/pubsub.viewer\",\"members\":[]},{\"role\":\"roles/pubsub.editor\",\"members\":[\"group:g@x.com\"]}]}}";
    const iam = [_]struct { tp.Method, []const u8, []const u8, u16 }{
        .{ .GET, "topics/dead:getIamPolicy?options.requestedPolicyVersion=3", "", 200 },
        .{ .POST, "topics/dead:setIamPolicy", grant, 200 },
        .{ .POST, "topics/dead:setIamPolicy", "{\"policy\":{\"etag\":\"ACAB\"}}", 409 },
        .{ .POST, "topics/dead:setIamPolicy", "{\"policy\":{\"etag\":\"AAAA\"}}", 400 },
        .{ .POST, "topics/dead:setIamPolicy", "{\"policy\":{\"bindings\":[{\"role\":\"roles/storage.admin\",\"members\":[\"user:a@x.com\"]}]}}", 400 },
        .{ .POST, "topics/dead:setIamPolicy", "{\"policy\":{\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\",\"nobody\"]}]}}", 400 },
        .{ .GET, "topics/dead:getIamPolicy", "", 200 },
        .{ .POST, "subscriptions/rules:setIamPolicy", grant, 200 },
        .{ .POST, "subscriptions/rules:testIamPermissions", "{\"permissions\":[\"pubsub.subscriptions.update\",\"pubsub.subscriptions.consume\",\"pubsub.subscriptions.update\"]}", 200 },
        .{ .POST, "subscriptions/rules:testIamPermissions", "{\"permissions\":[\"pubsub.subscriptions.*\"]}", 400 },
        .{ .POST, "snapshots/tagged:setIamPolicy", grant, 200 },
        .{ .POST, "schemas/gone:setIamPolicy", grant, 404 },
    };
    for (iam) |step| {
        const method, const path, const body, const status = step;
        try testing.expectEqual(status, (try fake.serve(method, try std.fmt.allocPrint(a, "{s}{s}", .{ base, path }), body, a)).status);
    }
    try testing.expect(std.mem.indexOf(u8, (try fake.serve(.GET, base ++ "subscriptions/rules:getIamPolicy", "", a)).body, "\"members\":[\"" ++ agent ++ "\",\"user:a@x.com\",\"group:g@x.com\"]") != null);
}

test "allocation failures: a session of every call leaks nothing and breaks nothing" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, sessionAllocations, .{});
}

test "many tasks at once: every message published is pulled and acknowledged exactly once" {
    const io = testing.io;
    var fake: FakePubSub = .init(testing.allocator, io, .{});
    defer fake.deinit();
    var tokens: test_util.FakeTokenProvider = .{};
    var client = try Client.init(testing.allocator, io, .{ .project_id = "p", .token_provider = tokens.provider(), .transport = fake.transport() });
    defer client.deinit();
    var made = try client.topic("orders").create(.{});
    made.deinit();
    var subscribed = try client.subscription("worker").create(.{ .topic_id = "orders", .ack_deadline_seconds = 600 });
    subscribed.deinit();

    const publishers = 4;
    const each = 60;
    const Tasks = struct {
        fn publish(c: *Client, task: usize) !void {
            for (0..each) |i| {
                var buf: [16]u8 = undefined;
                var sent = try c.topic("orders").publish(&.{.{ .data = try std.fmt.bufPrint(&buf, "{d}-{d}", .{ task, i }) }}, .{});
                sent.deinit();
            }
        }

        fn consume(c: *Client, f: *FakePubSub, seen: *std.atomic.Value(usize)) !void {
            while (seen.load(.monotonic) < publishers * each) {
                var got = try c.subscription("worker").pull(.{ .max_messages = 7, .return_immediately = true });
                defer got.deinit();
                for (got.value.messages) |m| {
                    try c.subscription("worker").ack(&.{m.ack_id});
                    _ = seen.fetchAdd(1, .monotonic);
                }
                if (got.value.messages.len == 0 and f.publishedCount("p", "orders") == publishers * each and f.backlog("p", "worker") == 0) return;
            }
        }
    };
    var seen: std.atomic.Value(usize) = .init(0);
    var sending: [publishers]std.Io.Future(@typeInfo(@TypeOf(Tasks.publish)).@"fn".return_type.?) = undefined;
    for (&sending, 0..) |*task, t| task.* = try io.concurrent(Tasks.publish, .{ &client, t });
    var pulling: [3]std.Io.Future(@typeInfo(@TypeOf(Tasks.consume)).@"fn".return_type.?) = undefined;
    for (&pulling) |*task| task.* = try io.concurrent(Tasks.consume, .{ &client, &fake, &seen });
    for (&sending) |*task| try task.await(io);
    for (&pulling) |*task| try task.await(io);
    // 600 second leases: none lapsed, so none was delivered twice.
    try testing.expectEqual(publishers * each, seen.load(.monotonic));
    try testing.expectEqual(publishers * each, fake.publishedCount("p", "orders"));
    try testing.expectEqual(0, fake.backlog("p", "worker"));
}
