//! JSON and base64: request bodies out, response bodies in.
//!
//! Zig field names are snake_case and the wire uses the API's camelCase. The
//! private `Wire*` structs mirror the wire exactly and never leave this file.
//! Every response field is optional, `null` counts as absent (the proto3 JSON
//! rule), and unknown fields are ignored, so new server fields never break
//! old clients.
//!
//! Encoders assume validated input: `validate.zig` has already rejected
//! invalid UTF-8, which `std.json.Stringify` would otherwise copy through
//! as invalid JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const base64 = @import("core").base64;
const duration = @import("core").duration;
const timestamp = @import("core").timestamp;
const types = @import("types.zig");
const test_util = @import("test_util.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// The `topics.publish` body. An empty ordering key is left out.
pub fn encodePublish(
    arena: Allocator,
    messages: []const types.Message,
    ordering_key: ?[]const u8,
) Allocator.Error![]u8 {
    return render(arena, PublishBody{ .messages = messages, .ordering_key = ordering_key });
}

const PublishBody = struct {
    messages: []const types.Message,
    ordering_key: ?[]const u8,

    fn write(self: PublishBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("messages");
        try jw.beginArray();
        for (self.messages) |m| try writeMessage(jw, m, self.ordering_key);
        try jw.endArray();
        try jw.endObject();
    }
};

/// What a publish body holds before its first message and after its last.
/// A body is `publish_body_head`, then the messages `encodeMessage` writes,
/// joined by commas, then `publish_body_tail`: byte for byte what
/// `encodePublish` writes for the same messages.
pub const publish_body_head = "{\"messages\":[";
pub const publish_body_tail = "]}";

/// One message of a publish body, as `encodePublish` writes it. A publisher
/// builds a request from these one message at a time. Caller owns the result.
pub fn encodeMessage(gpa: Allocator, message: types.Message, ordering_key: ?[]const u8) Allocator.Error![]u8 {
    return render(gpa, MessageBody{ .message = message, .ordering_key = ordering_key });
}

const MessageBody = struct {
    message: types.Message,
    ordering_key: ?[]const u8,

    fn write(self: MessageBody, jw: *Stringify) Stringify.Error!void {
        try writeMessage(jw, self.message, self.ordering_key);
    }
};

fn writeMessage(jw: *Stringify, m: types.Message, ordering_key: ?[]const u8) Stringify.Error!void {
    try jw.beginObject();
    if (m.data.len > 0) {
        try jw.objectField("data");
        try base64.writeJsonString(jw, m.data);
    }
    if (m.attributes.len > 0) {
        try jw.objectField("attributes");
        try jw.beginObject();
        for (m.attributes) |a| {
            try jw.objectField(a.key);
            try jw.write(a.value);
        }
        try jw.endObject();
    }
    if (ordering_key) |key| if (key.len > 0) {
        try jw.objectField("orderingKey");
        try jw.write(key);
    };
    try jw.endObject();
}

/// The `subscriptions.pull` body. `max_messages` must already be clamped.
pub fn encodePull(arena: Allocator, max_messages: u32, return_immediately: bool) Allocator.Error![]u8 {
    return render(arena, PullBody{ .max_messages = max_messages, .return_immediately = return_immediately });
}

const PullBody = struct {
    max_messages: u32,
    return_immediately: bool,

    fn write(self: PullBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("maxMessages");
        try jw.write(self.max_messages);
        if (self.return_immediately) {
            try jw.objectField("returnImmediately");
            try jw.write(true);
        }
        try jw.endObject();
    }
};

/// The `acknowledge` body, or the `modifyAckDeadline` body when
/// `deadline_seconds` is set.
pub fn encodeAckIds(arena: Allocator, ack_ids: []const []const u8, deadline_seconds: ?u32) Allocator.Error![]u8 {
    return render(arena, AckBody{ .ack_ids = ack_ids, .deadline_seconds = deadline_seconds });
}

const AckBody = struct {
    ack_ids: []const []const u8,
    deadline_seconds: ?u32,

    fn write(self: AckBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("ackIds");
        try jw.write(self.ack_ids);
        if (self.deadline_seconds) |seconds| {
            try jw.objectField("ackDeadlineSeconds");
            try jw.write(seconds);
        }
        try jw.endObject();
    }
};

/// The `subscriptions.create` body. `topic_name` is the full resource name,
/// and so is `dead_letter_topic`, which the caller resolves from the
/// policy's id or name.
pub fn encodeSubscription(
    arena: Allocator,
    topic_name: []const u8,
    config: types.SubscriptionConfig,
    dead_letter_topic: ?[]const u8,
) Allocator.Error![]u8 {
    return render(arena, SubscriptionBody{ .topic_name = topic_name, .config = config, .dead_letter_topic = dead_letter_topic });
}

const SubscriptionBody = struct {
    topic_name: []const u8,
    config: types.SubscriptionConfig,
    dead_letter_topic: ?[]const u8,

    fn write(self: SubscriptionBody, jw: *Stringify) Stringify.Error!void {
        const c = self.config;
        try jw.beginObject();
        try jw.objectField("topic");
        try jw.write(self.topic_name);
        // Left out, 0 lets Pub/Sub choose: 10 s, or 60 s with exactly-once
        // delivery, which a 10 sent here would override.
        if (c.ack_deadline_seconds != 0) {
            try jw.objectField("ackDeadlineSeconds");
            try jw.write(c.ack_deadline_seconds);
        }
        try jw.objectField("enableMessageOrdering");
        try jw.write(c.enable_message_ordering);
        if (c.enable_exactly_once_delivery) {
            try jw.objectField("enableExactlyOnceDelivery");
            try jw.write(true);
        }
        try writeDelivery(jw, c.delivery);
        if (c.filter.len > 0) {
            try jw.objectField("filter");
            try jw.write(c.filter);
        }
        if (c.dead_letter_policy) |policy| {
            try jw.objectField("deadLetterPolicy");
            try writeDeadLetter(jw, self.dead_letter_topic.?, policy.max_delivery_attempts);
        }
        if (c.retry_policy) |b| {
            try jw.objectField("retryPolicy");
            try writeBackoff(jw, b);
        }
        if (c.message_retention) |r| {
            try jw.objectField("messageRetentionDuration");
            try writeDuration(jw, r);
        }
        if (c.retain_acked_messages) {
            try jw.objectField("retainAckedMessages");
            try jw.write(true);
        }
        if (c.expiration != .default) {
            try jw.objectField("expirationPolicy");
            try writeExpiration(jw, c.expiration);
        }
        if (c.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabels(jw, c.labels);
        }
        if (c.message_transforms.len > 0) {
            try jw.objectField("messageTransforms");
            try writeTransforms(jw, c.message_transforms);
        }
        try jw.endObject();
    }
};

/// The `subscriptions.patch` body: the fields `update` sets, and a mask
/// naming them, and the ones it clears, which the body leaves out. Only
/// top-level fields are named; a policy is replaced whole. A delivery
/// masks every kind and sends the one given, so whatever the subscription
/// was, it is then what was asked; on an emulator, which refuses the
/// export kinds' mask paths, the push config alone is masked.
pub fn encodeSubscriptionUpdate(
    arena: Allocator,
    update: types.SubscriptionUpdate,
    dead_letter_topic: ?[]const u8,
    emulator: bool,
) Allocator.Error![]u8 {
    return render(arena, SubscriptionUpdateBody{ .update = update, .dead_letter_topic = dead_letter_topic, .emulator = emulator });
}

const SubscriptionUpdateBody = struct {
    update: types.SubscriptionUpdate,
    dead_letter_topic: ?[]const u8,
    emulator: bool,

    fn write(self: SubscriptionUpdateBody, jw: *Stringify) Stringify.Error!void {
        const u = self.update;
        var mask: Mask = .{};
        try jw.beginObject();
        try jw.objectField("subscription");
        try jw.beginObject();
        if (u.delivery) |d| {
            mask.add("pushConfig");
            if (!self.emulator) {
                mask.add("bigqueryConfig");
                mask.add("cloudStorageConfig");
            }
            try writeDelivery(jw, d);
        }
        if (u.ack_deadline_seconds) |s| {
            mask.add("ackDeadlineSeconds");
            try jw.objectField("ackDeadlineSeconds");
            try jw.write(s);
        }
        if (u.enable_exactly_once_delivery) |on| {
            mask.add("enableExactlyOnceDelivery");
            try jw.objectField("enableExactlyOnceDelivery");
            try jw.write(on);
        }
        switch (u.dead_letter_policy) {
            .keep => {},
            .clear => mask.add("deadLetterPolicy"),
            .set => |policy| {
                mask.add("deadLetterPolicy");
                try jw.objectField("deadLetterPolicy");
                try writeDeadLetter(jw, self.dead_letter_topic.?, policy.max_delivery_attempts);
            },
        }
        switch (u.retry_policy) {
            .keep => {},
            .clear => mask.add("retryPolicy"),
            .set => |b| {
                mask.add("retryPolicy");
                try jw.objectField("retryPolicy");
                try writeBackoff(jw, b);
            },
        }
        switch (u.message_retention) {
            .keep => {},
            .clear => mask.add("messageRetentionDuration"),
            .set => |r| {
                mask.add("messageRetentionDuration");
                try jw.objectField("messageRetentionDuration");
                try writeDuration(jw, r);
            },
        }
        if (u.retain_acked_messages) |on| {
            mask.add("retainAckedMessages");
            try jw.objectField("retainAckedMessages");
            try jw.write(on);
        }
        if (u.expiration) |e| {
            mask.add("expirationPolicy");
            // The default is named and left out, which restores it.
            if (e != .default) {
                try jw.objectField("expirationPolicy");
                try writeExpiration(jw, e);
            }
        }
        if (u.labels) |labels| {
            mask.add("labels");
            try jw.objectField("labels");
            try writeLabels(jw, labels);
        }
        if (u.message_transforms) |list| try writeTransformsUpdate(jw, &mask, list);
        try jw.endObject();
        try jw.objectField("updateMask");
        try mask.write(jw);
        try jw.endObject();
    }
};

/// The `topics.create` body: `{}` when nothing is set.
pub fn encodeTopic(arena: Allocator, config: types.TopicConfig) Allocator.Error![]u8 {
    return render(arena, TopicBody{ .config = config });
}

const TopicBody = struct {
    config: types.TopicConfig,

    fn write(self: TopicBody, jw: *Stringify) Stringify.Error!void {
        const c = self.config;
        try jw.beginObject();
        if (c.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabels(jw, c.labels);
        }
        if (c.message_retention) |r| {
            try jw.objectField("messageRetentionDuration");
            try writeDuration(jw, r);
        }
        if (c.kms_key_name) |k| {
            try jw.objectField("kmsKeyName");
            try jw.write(k);
        }
        if (c.message_storage_policy) |policy| {
            try jw.objectField("messageStoragePolicy");
            try writeStoragePolicy(jw, policy);
        }
        if (c.schema) |settings| {
            try jw.objectField("schemaSettings");
            try writeSchemaSettings(jw, settings);
        }
        if (c.message_transforms.len > 0) {
            try jw.objectField("messageTransforms");
            try writeTransforms(jw, c.message_transforms);
        }
        if (c.ingestion) |settings| {
            try jw.objectField("ingestionDataSourceSettings");
            try writeIngestion(jw, settings);
        }
        try jw.endObject();
    }
};

/// An import topic's settings: one source, and the log severity unless it
/// is the default. A Cloud Storage source always carries a format, which
/// an emulator requires, and a time and a glob only when given. A state
/// is the server's to say, and is never sent. The severity must be one
/// the wire names: the checks refuse `.unknown` first.
fn writeIngestion(jw: *Stringify, settings: types.Ingestion) Stringify.Error!void {
    try jw.beginObject();
    switch (settings.source) {
        .aws_kinesis => |k| {
            try jw.objectField("awsKinesis");
            try jw.beginObject();
            try writeField(jw, "streamArn", k.stream_arn);
            try writeField(jw, "consumerArn", k.consumer_arn);
            try writeField(jw, "awsRoleArn", k.aws_role_arn);
            try writeField(jw, "gcpServiceAccount", k.gcp_service_account);
            try jw.endObject();
        },
        .cloud_storage => |s| {
            try jw.objectField("cloudStorage");
            try jw.beginObject();
            try writeField(jw, "bucket", s.bucket);
            switch (s.format) {
                .text => |t| {
                    try jw.objectField("textFormat");
                    try jw.beginObject();
                    try writeField(jw, "delimiter", t.delimiter);
                    try jw.endObject();
                },
                .avro => {
                    try jw.objectField("avroFormat");
                    try jw.beginObject();
                    try jw.endObject();
                },
                .pubsub_avro => {
                    try jw.objectField("pubsubAvroFormat");
                    try jw.beginObject();
                    try jw.endObject();
                },
            }
            if (s.minimum_object_create_time) |t| {
                var buf: [timestamp.max_len]u8 = undefined;
                try writeField(jw, "minimumObjectCreateTime", timestamp.format(&buf, t));
            }
            if (s.match_glob.len > 0) try writeField(jw, "matchGlob", s.match_glob);
            try jw.endObject();
        },
        .azure_event_hubs => |e| {
            try jw.objectField("azureEventHubs");
            try jw.beginObject();
            try writeField(jw, "resourceGroup", e.resource_group);
            try writeField(jw, "namespace", e.namespace);
            try writeField(jw, "eventHub", e.event_hub);
            try writeField(jw, "clientId", e.client_id);
            try writeField(jw, "tenantId", e.tenant_id);
            try writeField(jw, "subscriptionId", e.subscription_id);
            try writeField(jw, "gcpServiceAccount", e.gcp_service_account);
            try jw.endObject();
        },
        .aws_msk => |m| {
            try jw.objectField("awsMsk");
            try jw.beginObject();
            try writeField(jw, "clusterArn", m.cluster_arn);
            try writeField(jw, "topic", m.topic);
            try writeField(jw, "awsRoleArn", m.aws_role_arn);
            try writeField(jw, "gcpServiceAccount", m.gcp_service_account);
            try jw.endObject();
        },
        .confluent_cloud => |c| {
            try jw.objectField("confluentCloud");
            try jw.beginObject();
            try writeField(jw, "bootstrapServer", c.bootstrap_server);
            try writeField(jw, "clusterId", c.cluster_id);
            try writeField(jw, "topic", c.topic);
            try writeField(jw, "identityPoolId", c.identity_pool_id);
            try writeField(jw, "gcpServiceAccount", c.gcp_service_account);
            try jw.endObject();
        },
    }
    if (logSeverityName(settings.log_severity)) |severity| {
        try jw.objectField("platformLogsSettings");
        try jw.beginObject();
        try writeField(jw, "severity", severity);
        try jw.endObject();
    }
    try jw.endObject();
}

fn writeField(jw: *Stringify, name: []const u8, value: []const u8) Stringify.Error!void {
    try jw.objectField(name);
    try jw.write(value);
}

/// The wire's word for a severity, or null for what is left out: the
/// default, which is no logs, and `.unknown`, which has no word.
fn logSeverityName(severity: types.Ingestion.LogSeverity) ?[]const u8 {
    return switch (severity) {
        .disabled, .unknown => null,
        .debug => "DEBUG",
        .info => "INFO",
        .warning => "WARNING",
        .@"error" => "ERROR",
    };
}

/// A list of transforms, in the order they run. `disabled` is written only
/// when set, and the deprecated `enabled` never. A kind this client does
/// not model has nothing to write and is written as a transform of no
/// kind, which the server refuses: the checks refuse such a list first.
fn writeTransforms(jw: *Stringify, list: []const types.MessageTransform) Stringify.Error!void {
    try jw.beginArray();
    for (list) |transform| {
        try jw.beginObject();
        switch (transform.kind) {
            .javascript_udf => |udf| {
                try jw.objectField("javascriptUdf");
                try jw.beginObject();
                try jw.objectField("functionName");
                try jw.write(udf.function_name);
                try jw.objectField("code");
                try jw.write(udf.code);
                try jw.endObject();
            },
            .other => {},
        }
        if (transform.disabled) {
            try jw.objectField("disabled");
            try jw.write(true);
        }
        try jw.endObject();
    }
    try jw.endArray();
}

/// An update's transforms: the list is masked whole, so what is given is
/// all that holds afterwards. An empty list is named and left out, which
/// clears it, on topics and subscriptions alike (measured in production
/// and on an emulator, 2026-10-12).
fn writeTransformsUpdate(jw: *Stringify, mask: *Mask, list: []const types.MessageTransform) Stringify.Error!void {
    mask.add("messageTransforms");
    if (list.len == 0) return;
    try jw.objectField("messageTransforms");
    try writeTransforms(jw, list);
}

/// A topic's `schemaSettings`. The schema must already be a full name:
/// `Topic` resolves an id before encoding. A bound left null is left out,
/// which the server reads as open.
fn writeSchemaSettings(jw: *Stringify, s: types.SchemaSettings) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("schema");
    try jw.write(s.schema);
    try jw.objectField("encoding");
    try jw.write(schemaEncodingName(s.encoding));
    if (s.first_revision_id) |revision| {
        try jw.objectField("firstRevisionId");
        try jw.write(revision);
    }
    if (s.last_revision_id) |revision| {
        try jw.objectField("lastRevisionId");
        try jw.write(revision);
    }
    try jw.endObject();
}

/// The `topics.patch` body, as for subscriptions.
pub fn encodeTopicUpdate(arena: Allocator, update: types.TopicUpdate) Allocator.Error![]u8 {
    return render(arena, TopicUpdateBody{ .update = update });
}

const TopicUpdateBody = struct {
    update: types.TopicUpdate,

    fn write(self: TopicUpdateBody, jw: *Stringify) Stringify.Error!void {
        const u = self.update;
        var mask: Mask = .{};
        try jw.beginObject();
        try jw.objectField("topic");
        try jw.beginObject();
        if (u.labels) |labels| {
            mask.add("labels");
            try jw.objectField("labels");
            try writeLabels(jw, labels);
        }
        switch (u.message_retention) {
            .keep => {},
            .clear => mask.add("messageRetentionDuration"),
            .set => |r| {
                mask.add("messageRetentionDuration");
                try jw.objectField("messageRetentionDuration");
                try writeDuration(jw, r);
            },
        }
        switch (u.kms_key_name) {
            .keep => {},
            .clear => mask.add("kmsKeyName"),
            .set => |k| {
                mask.add("kmsKeyName");
                try jw.objectField("kmsKeyName");
                try jw.write(k);
            },
        }
        switch (u.message_storage_policy) {
            .keep => {},
            .clear => mask.add("messageStoragePolicy"),
            .set => |policy| {
                mask.add("messageStoragePolicy");
                try jw.objectField("messageStoragePolicy");
                try writeStoragePolicy(jw, policy);
            },
        }
        // The settings are masked whole, so what is given is all that
        // holds afterwards, and nothing given is no schema.
        switch (u.schema) {
            .keep => {},
            .clear => mask.add("schemaSettings"),
            .set => |settings| {
                mask.add("schemaSettings");
                try jw.objectField("schemaSettings");
                try writeSchemaSettings(jw, settings);
            },
        }
        if (u.message_transforms) |list| try writeTransformsUpdate(jw, &mask, list);
        // Masked whole, as the schema's settings are: what is given is
        // all that holds afterwards, and nothing given is a standard topic.
        switch (u.ingestion) {
            .keep => {},
            .clear => mask.add("ingestionDataSourceSettings"),
            .set => |settings| {
                mask.add("ingestionDataSourceSettings");
                try jw.objectField("ingestionDataSourceSettings");
                try writeIngestion(jw, settings);
            },
        }
        try jw.endObject();
        try jw.objectField("updateMask");
        try mask.write(jw);
        try jw.endObject();
    }
};

/// The `subscriptions.seek` body: exactly one target, a time as the server
/// writes one or a snapshot by its full name, which `snapshot_name` is when
/// the target is one. The time must be one `timestamp.format` can write.
pub fn encodeSeek(arena: Allocator, target: types.SeekTarget, snapshot_name: ?[]const u8) Allocator.Error![]u8 {
    return render(arena, SeekBody{ .target = target, .snapshot_name = snapshot_name });
}

const SeekBody = struct {
    target: types.SeekTarget,
    snapshot_name: ?[]const u8,

    fn write(self: SeekBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        switch (self.target) {
            .time => |t| {
                var buf: [timestamp.max_len]u8 = undefined;
                try jw.objectField("time");
                try jw.write(timestamp.format(&buf, t));
            },
            .snapshot => {
                try jw.objectField("snapshot");
                try jw.write(self.snapshot_name.?);
            },
        }
        try jw.endObject();
    }
};

/// The `snapshots.create` body: the subscription by its full name, and the
/// labels when there are any.
pub fn encodeSnapshot(arena: Allocator, subscription_name: []const u8, config: types.SnapshotConfig) Allocator.Error![]u8 {
    return render(arena, SnapshotBody{ .subscription_name = subscription_name, .config = config });
}

const SnapshotBody = struct {
    subscription_name: []const u8,
    config: types.SnapshotConfig,

    fn write(self: SnapshotBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("subscription");
        try jw.write(self.subscription_name);
        if (self.config.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabels(jw, self.config.labels);
        }
        try jw.endObject();
    }
};

/// The `snapshots.patch` body, as for topics. Production takes labels and
/// refuses every other field as "not mutable" (measured 2026-10-10).
pub fn encodeSnapshotUpdate(arena: Allocator, update: types.SnapshotUpdate) Allocator.Error![]u8 {
    return render(arena, SnapshotUpdateBody{ .update = update });
}

const SnapshotUpdateBody = struct {
    update: types.SnapshotUpdate,

    fn write(self: SnapshotUpdateBody, jw: *Stringify) Stringify.Error!void {
        var mask: Mask = .{};
        try jw.beginObject();
        try jw.objectField("snapshot");
        try jw.beginObject();
        if (self.update.labels) |labels| {
            mask.add("labels");
            try jw.objectField("labels");
            try writeLabels(jw, labels);
        }
        try jw.endObject();
        try jw.objectField("updateMask");
        try mask.write(jw);
        try jw.endObject();
    }
};

/// The `schemas.create` body: the type and the definition. The id goes in
/// the query, and a name in the body would be ignored.
pub fn encodeSchema(arena: Allocator, definition: types.SchemaDefinition) Allocator.Error![]u8 {
    return render(arena, SchemaBody{ .definition = definition });
}

const SchemaBody = struct {
    definition: types.SchemaDefinition,

    fn write(self: SchemaBody, jw: *Stringify) Stringify.Error!void {
        try writeSchema(jw, self.definition);
    }
};

/// The `schemas.validate` body: the schema as `encodeSchema` writes it,
/// under `schema`.
pub fn encodeValidateSchema(arena: Allocator, definition: types.SchemaDefinition) Allocator.Error![]u8 {
    return render(arena, ValidateSchemaBody{ .definition = definition });
}

const ValidateSchemaBody = struct {
    definition: types.SchemaDefinition,

    fn write(self: ValidateSchemaBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("schema");
        try writeSchema(jw, self.definition);
        try jw.endObject();
    }
};

/// The `schemas.commit` body: the new revision under `schema`, with the
/// schema's full name beside its type and definition. The name is not
/// decoration: production commits to the schema the body names, whatever
/// the path says, and refuses a body without one (measured 2026-10-12).
/// The emulator ignores it.
pub fn encodeCommit(arena: Allocator, name: []const u8, definition: types.SchemaDefinition) Allocator.Error![]u8 {
    return render(arena, CommitBody{ .name = name, .definition = definition });
}

const CommitBody = struct {
    name: []const u8,
    definition: types.SchemaDefinition,

    fn write(self: CommitBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("schema");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("type");
        try jw.write(schemaTypeName(self.definition.type));
        try jw.objectField("definition");
        try jw.write(self.definition.definition);
        try jw.endObject();
        try jw.endObject();
    }
};

/// The `schemas.rollback` body: the revision to go back to.
pub fn encodeRollback(arena: Allocator, revision_id: []const u8) Allocator.Error![]u8 {
    return render(arena, RollbackBody{ .revision_id = revision_id });
}

const RollbackBody = struct {
    revision_id: []const u8,

    fn write(self: RollbackBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("revisionId");
        try jw.write(self.revision_id);
        try jw.endObject();
    }
};

/// What a message is checked against: a stored schema by its full name,
/// with `@revision` after it for one revision, or a definition not stored.
pub const SchemaRef = union(enum) {
    name: []const u8,
    definition: types.SchemaDefinition,
};

/// The `schemas.validateMessage` body. The message goes as base64, and an
/// empty one as "".
pub fn encodeValidateMessage(
    arena: Allocator,
    against: SchemaRef,
    data: []const u8,
    encoding: types.SchemaEncoding,
) Allocator.Error![]u8 {
    return render(arena, ValidateMessageBody{ .against = against, .data = data, .encoding = encoding });
}

const ValidateMessageBody = struct {
    against: SchemaRef,
    data: []const u8,
    encoding: types.SchemaEncoding,

    fn write(self: ValidateMessageBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        switch (self.against) {
            .name => |name| {
                try jw.objectField("name");
                try jw.write(name);
            },
            .definition => |definition| {
                try jw.objectField("schema");
                try writeSchema(jw, definition);
            },
        }
        try jw.objectField("message");
        try base64.writeJsonString(jw, self.data);
        try jw.objectField("encoding");
        try jw.write(schemaEncodingName(self.encoding));
        try jw.endObject();
    }
};

fn writeSchema(jw: *Stringify, definition: types.SchemaDefinition) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(schemaTypeName(definition.type));
    try jw.objectField("definition");
    try jw.write(definition.definition);
    try jw.endObject();
}

/// The wire's word for a schema type. `.unknown`, which `validate` refuses
/// first, goes as the value the server refuses.
pub fn schemaTypeName(t: types.SchemaType) []const u8 {
    return switch (t) {
        .avro => "AVRO",
        .protocol_buffer => "PROTOCOL_BUFFER",
        .unknown => "TYPE_UNSPECIFIED",
    };
}

/// The wire's word for an encoding, as `schemaTypeName` is for a type.
pub fn schemaEncodingName(e: types.SchemaEncoding) []const u8 {
    return switch (e) {
        .json => "JSON",
        .binary => "BINARY",
        .unknown => "ENCODING_UNSPECIFIED",
    };
}

/// The wire's word for a view, as the `view` query parameter takes it.
pub fn schemaViewName(v: types.SchemaView) []const u8 {
    return switch (v) {
        .basic => "BASIC",
        .full => "FULL",
    };
}

/// An update mask: the camelCase paths an update names, comma-separated in
/// one JSON string, as the REST API takes a `FieldMask`.
const Mask = struct {
    paths: [12][]const u8 = undefined,
    len: usize = 0,

    fn add(m: *Mask, path: []const u8) void {
        m.paths[m.len] = path;
        m.len += 1;
    }

    fn write(m: *const Mask, jw: *Stringify) Stringify.Error!void {
        // Paths are fixed ASCII names, so the string needs no escaping.
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        for (m.paths[0..m.len], 0..) |path, i| {
            if (i > 0) try jw.writer.writeByte(',');
            try jw.writer.writeAll(path);
        }
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }
};

fn writeDuration(jw: *Stringify, d: std.Io.Duration) Stringify.Error!void {
    var buf: [duration.max_len]u8 = undefined;
    try jw.write(duration.format(&buf, d));
}

fn writeLabels(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
    try jw.beginObject();
    for (labels) |l| {
        try jw.objectField(l.key);
        try jw.write(l.value);
    }
    try jw.endObject();
}

fn writeDeadLetter(jw: *Stringify, topic_name: []const u8, attempts: u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("deadLetterTopic");
    try jw.write(topic_name);
    try jw.objectField("maxDeliveryAttempts");
    try jw.write(attempts);
    try jw.endObject();
}

fn writeBackoff(jw: *Stringify, b: types.Backoff) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("minimumBackoff");
    try writeDuration(jw, b.minimum);
    try jw.objectField("maximumBackoff");
    try writeDuration(jw, b.maximum);
    try jw.endObject();
}

/// `{}` never expires; a ttl expires after it. The default is left out
/// entirely by the caller: absent and `{}` differ on the wire.
fn writeExpiration(jw: *Stringify, e: types.Expiration) Stringify.Error!void {
    try jw.beginObject();
    switch (e) {
        .default, .never => {},
        .after => |ttl| {
            try jw.objectField("ttl");
            try writeDuration(jw, ttl);
        },
    }
    try jw.endObject();
}

/// The delivery's one config object. `.pull` writes nothing: with none of
/// the kinds set, a subscription pulls.
fn writeDelivery(jw: *Stringify, delivery: types.Delivery) Stringify.Error!void {
    switch (delivery) {
        .pull => {},
        .push => |p| {
            try jw.objectField("pushConfig");
            try writePushConfig(jw, p);
        },
        .bigquery => |b| {
            try jw.objectField("bigqueryConfig");
            try writeBigQueryConfig(jw, b);
        },
        .cloud_storage => |s| {
            try jw.objectField("cloudStorageConfig");
            try writeCloudStorageConfig(jw, s);
        },
    }
}

fn writePushConfig(jw: *Stringify, p: types.PushConfig) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("pushEndpoint");
    try jw.write(p.endpoint);
    if (p.oidc_token) |t| {
        try jw.objectField("oidcToken");
        try jw.beginObject();
        try jw.objectField("serviceAccountEmail");
        try jw.write(t.service_account_email);
        if (t.audience.len > 0) {
            try jw.objectField("audience");
            try jw.write(t.audience);
        }
        try jw.endObject();
    }
    switch (p.body) {
        // Left out: the wrapped envelope is the wire's default.
        .wrapped => {},
        .unwrapped => |u| {
            try jw.objectField("noWrapper");
            try jw.beginObject();
            if (u.write_metadata) {
                try jw.objectField("writeMetadata");
                try jw.write(true);
            }
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn writeBigQueryConfig(jw: *Stringify, b: types.BigQueryConfig) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("table");
    try jw.write(b.table);
    switch (b.schema) {
        .none => {},
        .topic => {
            try jw.objectField("useTopicSchema");
            try jw.write(true);
        },
        .table => {
            try jw.objectField("useTableSchema");
            try jw.write(true);
        },
    }
    if (b.write_metadata) {
        try jw.objectField("writeMetadata");
        try jw.write(true);
    }
    if (b.drop_unknown_fields) {
        try jw.objectField("dropUnknownFields");
        try jw.write(true);
    }
    if (b.service_account_email) |email| {
        try jw.objectField("serviceAccountEmail");
        try jw.write(email);
    }
    try jw.endObject();
}

fn writeCloudStorageConfig(jw: *Stringify, s: types.CloudStorageConfig) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("bucket");
    try jw.write(s.bucket);
    if (s.filename_prefix.len > 0) {
        try jw.objectField("filenamePrefix");
        try jw.write(s.filename_prefix);
    }
    if (s.filename_suffix.len > 0) {
        try jw.objectField("filenameSuffix");
        try jw.write(s.filename_suffix);
    }
    if (s.filename_datetime_format.len > 0) {
        try jw.objectField("filenameDatetimeFormat");
        try jw.write(s.filename_datetime_format);
    }
    switch (s.format) {
        // Left out: newline-separated text is the wire's default.
        .text => {},
        .avro => |a| {
            try jw.objectField("avroConfig");
            try jw.beginObject();
            if (a.write_metadata) {
                try jw.objectField("writeMetadata");
                try jw.write(true);
            }
            if (a.use_topic_schema) {
                try jw.objectField("useTopicSchema");
                try jw.write(true);
            }
            try jw.endObject();
        },
    }
    if (s.max_duration) |d| {
        try jw.objectField("maxDuration");
        try writeDuration(jw, d);
    }
    if (s.max_bytes != 0) {
        try jw.objectField("maxBytes");
        try writeInt64(jw, s.max_bytes);
    }
    if (s.max_messages != 0) {
        try jw.objectField("maxMessages");
        try writeInt64(jw, s.max_messages);
    }
    if (s.service_account_email) |email| {
        try jw.objectField("serviceAccountEmail");
        try jw.write(email);
    }
    try jw.endObject();
}

/// Proto JSON carries an int64 as a string, and the server echoes it as one.
fn writeInt64(jw: *Stringify, n: u64) Stringify.Error!void {
    var buf: [20]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
}

fn writeStoragePolicy(jw: *Stringify, policy: types.MessageStoragePolicy) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("allowedPersistenceRegions");
    try jw.write(policy.allowed_persistence_regions);
    if (policy.enforce_in_transit) {
        try jw.objectField("enforceInTransit");
        try jw.write(true);
    }
    try jw.endObject();
}

/// Runs `body.write` into a fresh buffer. The only way an allocating writer
/// fails is running out of memory, and then nothing is left behind, so a
/// general-purpose allocator is as safe here as an arena.
fn render(allocator: Allocator, body: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw: Stringify = .{ .writer = &out.writer };
    body.write(&jw) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The exact length of `encodePublish(messages, ordering_key)`, computed
/// without encoding anything.
pub fn publishBodyLen(messages: []const types.Message, ordering_key: ?[]const u8) usize {
    const key = ordering_key orelse "";
    // Parenthesized: `a + b -| 1` would parse as `(a + b) -| 1`.
    var n: usize = "{\"messages\":[]}".len + (messages.len -| 1); // commas between messages
    for (messages) |m| {
        var fields: usize = 0;
        n += "{}".len;
        if (m.data.len > 0) {
            n += "\"data\":\"\"".len + base64.encodedLen(m.data.len);
            fields += 1;
        }
        if (m.attributes.len > 0) {
            n += "\"attributes\":{}".len + m.attributes.len - 1; // commas between pairs
            for (m.attributes) |a| n += jsonStringLen(a.key) + ":".len + jsonStringLen(a.value);
            fields += 1;
        }
        if (key.len > 0) {
            n += "\"orderingKey\":".len + jsonStringLen(key);
            fields += 1;
        }
        n += fields -| 1; // commas between fields
    }
    return n;
}

/// The bytes `text` takes as a JSON string, quotes included, exactly as
/// `std.json.Stringify` writes it.
pub fn jsonStringLen(text: []const u8) usize {
    var n: usize = 2;
    for (text) |c| n += switch (c) {
        '"', '\\', 0x08, 0x0C, '\n', '\r', '\t' => 2,
        0x00...0x07, 0x0B, 0x0E...0x1F => 6,
        else => 1,
    };
    return n;
}

/// Splits ack ids into request-sized groups: each group's body is at most
/// `max_bytes` and holds at most `max_ids` ids. Groups are greedy and keep
/// the input order.
pub const AckChunks = struct {
    ids: []const []const u8,
    /// Body bytes besides the ids: `{"ackIds":[]}` plus any deadline field.
    fixed_bytes: usize,
    max_bytes: usize,
    max_ids: usize,
    pos: usize = 0,

    /// The next group, or null when done. `error.InvalidArgument` when a
    /// single id cannot fit in a request on its own.
    pub fn next(it: *AckChunks) error{InvalidArgument}!?[]const []const u8 {
        if (it.pos >= it.ids.len) return null;
        var size = it.fixed_bytes;
        var end = it.pos;
        while (end < it.ids.len and end - it.pos < it.max_ids) : (end += 1) {
            const comma: usize = @intFromBool(end > it.pos);
            const add = jsonStringLen(it.ids[end]) + comma;
            if (size + add > it.max_bytes) break;
            size += add;
        }
        if (end == it.pos) return error.InvalidArgument;
        defer it.pos = end;
        return it.ids[it.pos..end];
    }
};

// Responses

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    // Proto3 JSON parsers keep the last duplicate rather than failing.
    .duplicate_field_behavior = .use_last,
    // Unescaped strings point into the body instead of being copied.
    .allocate = .alloc_if_needed,
};

const WireStoragePolicy = struct {
    allowedPersistenceRegions: ?[]const []const u8 = null,
    enforceInTransit: ?bool = null,
};

const WireTopic = struct {
    name: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
    messageRetentionDuration: ?[]const u8 = null,
    kmsKeyName: ?[]const u8 = null,
    messageStoragePolicy: ?WireStoragePolicy = null,
    schemaSettings: ?WireSchemaSettings = null,
    messageTransforms: ?[]const WireTransform = null,
    ingestionDataSourceSettings: ?WireIngestion = null,
    state: ?[]const u8 = null,
};

const WireIngestion = struct {
    awsKinesis: ?struct {
        streamArn: ?[]const u8 = null,
        consumerArn: ?[]const u8 = null,
        awsRoleArn: ?[]const u8 = null,
        gcpServiceAccount: ?[]const u8 = null,
        state: ?[]const u8 = null,
    } = null,
    cloudStorage: ?struct {
        bucket: ?[]const u8 = null,
        textFormat: ?struct { delimiter: ?[]const u8 = null } = null,
        avroFormat: ?struct {} = null,
        pubsubAvroFormat: ?struct {} = null,
        minimumObjectCreateTime: ?[]const u8 = null,
        matchGlob: ?[]const u8 = null,
        state: ?[]const u8 = null,
    } = null,
    azureEventHubs: ?struct {
        resourceGroup: ?[]const u8 = null,
        namespace: ?[]const u8 = null,
        eventHub: ?[]const u8 = null,
        clientId: ?[]const u8 = null,
        tenantId: ?[]const u8 = null,
        subscriptionId: ?[]const u8 = null,
        gcpServiceAccount: ?[]const u8 = null,
        state: ?[]const u8 = null,
    } = null,
    awsMsk: ?struct {
        clusterArn: ?[]const u8 = null,
        topic: ?[]const u8 = null,
        awsRoleArn: ?[]const u8 = null,
        gcpServiceAccount: ?[]const u8 = null,
        state: ?[]const u8 = null,
    } = null,
    confluentCloud: ?struct {
        bootstrapServer: ?[]const u8 = null,
        clusterId: ?[]const u8 = null,
        topic: ?[]const u8 = null,
        identityPoolId: ?[]const u8 = null,
        gcpServiceAccount: ?[]const u8 = null,
        state: ?[]const u8 = null,
    } = null,
    platformLogsSettings: ?struct { severity: ?[]const u8 = null } = null,
};

/// `enabled`, which is deprecated, is not read: production keeps whatever
/// it is given there, beside a `disabled` that says the opposite.
const WireTransform = struct {
    javascriptUdf: ?struct { functionName: ?[]const u8 = null, code: ?[]const u8 = null } = null,
    disabled: ?bool = null,
};

const WireSchemaSettings = struct {
    schema: ?[]const u8 = null,
    encoding: ?[]const u8 = null,
    firstRevisionId: ?[]const u8 = null,
    lastRevisionId: ?[]const u8 = null,
};

const WireTopicList = struct {
    topics: ?[]const WireTopic = null,
    nextPageToken: ?[]const u8 = null,
};

const WireDeadLetter = struct {
    deadLetterTopic: ?[]const u8 = null,
    maxDeliveryAttempts: ?u32 = null,
};

const WireBackoff = struct {
    minimumBackoff: ?[]const u8 = null,
    maximumBackoff: ?[]const u8 = null,
};

const WireExpiration = struct {
    ttl: ?[]const u8 = null,
};

const WireOidcToken = struct {
    serviceAccountEmail: ?[]const u8 = null,
    audience: ?[]const u8 = null,
};

const WirePushConfig = struct {
    pushEndpoint: ?[]const u8 = null,
    oidcToken: ?WireOidcToken = null,
    noWrapper: ?struct { writeMetadata: ?bool = null } = null,
};

const WireBigQueryConfig = struct {
    table: ?[]const u8 = null,
    useTopicSchema: ?bool = null,
    useTableSchema: ?bool = null,
    writeMetadata: ?bool = null,
    dropUnknownFields: ?bool = null,
    serviceAccountEmail: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

const WireCloudStorageConfig = struct {
    bucket: ?[]const u8 = null,
    filenamePrefix: ?[]const u8 = null,
    filenameSuffix: ?[]const u8 = null,
    filenameDatetimeFormat: ?[]const u8 = null,
    avroConfig: ?struct { writeMetadata: ?bool = null, useTopicSchema: ?bool = null } = null,
    maxDuration: ?[]const u8 = null,
    maxBytes: ?u64 = null,
    maxMessages: ?u64 = null,
    serviceAccountEmail: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

const WireSubscription = struct {
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    pushConfig: ?WirePushConfig = null,
    bigqueryConfig: ?WireBigQueryConfig = null,
    cloudStorageConfig: ?WireCloudStorageConfig = null,
    /// Presence alone: a kind this client does not model.
    bigtableConfig: ?struct {} = null,
    ackDeadlineSeconds: ?u32 = null,
    enableMessageOrdering: ?bool = null,
    enableExactlyOnceDelivery: ?bool = null,
    filter: ?[]const u8 = null,
    deadLetterPolicy: ?WireDeadLetter = null,
    retryPolicy: ?WireBackoff = null,
    messageRetentionDuration: ?[]const u8 = null,
    retainAckedMessages: ?bool = null,
    expirationPolicy: ?WireExpiration = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
    detached: ?bool = null,
    state: ?[]const u8 = null,
    topicMessageRetentionDuration: ?[]const u8 = null,
    messageTransforms: ?[]const WireTransform = null,
};

const WireSubscriptionList = struct {
    subscriptions: ?[]const WireSubscription = null,
    nextPageToken: ?[]const u8 = null,
};

const WireSnapshot = struct {
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    expireTime: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
};

const WireSnapshotList = struct {
    snapshots: ?[]const WireSnapshot = null,
    nextPageToken: ?[]const u8 = null,
};

const WireSchema = struct {
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    definition: ?[]const u8 = null,
    revisionId: ?[]const u8 = null,
    revisionCreateTime: ?[]const u8 = null,
};

const WireSchemaList = struct {
    schemas: ?[]const WireSchema = null,
    nextPageToken: ?[]const u8 = null,
};

/// What is attached to a topic: names alone, under the key of their kind.
const WireNameList = struct {
    subscriptions: ?[]const []const u8 = null,
    snapshots: ?[]const []const u8 = null,
    nextPageToken: ?[]const u8 = null,
};

const WirePublishResponse = struct {
    messageIds: ?[]const []const u8 = null,
};

const WireMessage = struct {
    data: ?[]const u8 = null,
    attributes: ?std.json.ArrayHashMap(?[]const u8) = null,
    messageId: ?[]const u8 = null,
    publishTime: ?[]const u8 = null,
    orderingKey: ?[]const u8 = null,
};

const WireReceivedMessage = struct {
    ackId: ?[]const u8 = null,
    message: ?WireMessage = null,
    deliveryAttempt: ?u32 = null,
};

const WirePullResponse = struct {
    receivedMessages: ?[]const WireReceivedMessage = null,
};

/// Parses `body` into `T`. A blank body counts as `{}`: a pull with no
/// messages may return nothing at all.
fn parseWire(comptime T: type, arena: Allocator, body: []const u8) DecodeError!T {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const text = if (trimmed.len == 0) "{}" else trimmed;
    return std.json.parseFromSliceLeaky(T, arena, text, parse_options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (t.len == 0) null else t;
}

fn topicFromWire(arena: Allocator, w: WireTopic) DecodeError!types.TopicInfo {
    return .{
        .name = w.name orelse "",
        .labels = try labelsFromWire(arena, w.labels),
        .message_retention = try optionalDuration(w.messageRetentionDuration),
        .kms_key_name = nonEmpty(w.kmsKeyName),
        .message_storage_policy = if (w.messageStoragePolicy) |policy| .{
            .allowed_persistence_regions = policy.allowedPersistenceRegions orelse &.{},
            .enforce_in_transit = policy.enforceInTransit orelse false,
        } else null,
        .schema = schemaSettingsFromWire(w.schemaSettings),
        .message_transforms = try transformsFromWire(arena, w.messageTransforms),
        .ingestion = try ingestionFromWire(w.ingestionDataSourceSettings),
        .state = topicState(w.state),
    };
}

/// An import topic's settings as read. Settings that hold none of the five
/// sources are of a source this client does not model, and are kept as
/// such: the topic is still an import topic. Should an answer hold two,
/// the first in this fixed order wins. A Cloud Storage source with no
/// format reads as text split at newlines, which is what production
/// makes of one sent without.
fn ingestionFromWire(wire: ?WireIngestion) DecodeError!?types.IngestionInfo {
    const w = wire orelse return null;
    const severity = logSeverity(if (w.platformLogsSettings) |logs| logs.severity else null);
    if (w.awsKinesis) |k| return .{
        .source = .{ .aws_kinesis = .{
            .stream_arn = k.streamArn orelse "",
            .consumer_arn = k.consumerArn orelse "",
            .aws_role_arn = k.awsRoleArn orelse "",
            .gcp_service_account = k.gcpServiceAccount orelse "",
        } },
        .log_severity = severity,
        .state = ingestionState(k.state),
    };
    if (w.cloudStorage) |s| return .{
        .source = .{ .cloud_storage = .{
            .bucket = s.bucket orelse "",
            .format = if (s.avroFormat != null)
                .avro
            else if (s.pubsubAvroFormat != null)
                .pubsub_avro
            else
                .{ .text = .{ .delimiter = if (s.textFormat) |t| nonEmpty(t.delimiter) orelse "\n" else "\n" } },
            .minimum_object_create_time = if (nonEmpty(s.minimumObjectCreateTime)) |text|
                timestamp.parse(text) catch return error.InvalidResponse
            else
                null,
            .match_glob = s.matchGlob orelse "",
        } },
        .log_severity = severity,
        .state = ingestionState(s.state),
    };
    if (w.azureEventHubs) |e| return .{
        .source = .{ .azure_event_hubs = .{
            .resource_group = e.resourceGroup orelse "",
            .namespace = e.namespace orelse "",
            .event_hub = e.eventHub orelse "",
            .client_id = e.clientId orelse "",
            .tenant_id = e.tenantId orelse "",
            .subscription_id = e.subscriptionId orelse "",
            .gcp_service_account = e.gcpServiceAccount orelse "",
        } },
        .log_severity = severity,
        .state = ingestionState(e.state),
    };
    if (w.awsMsk) |m| return .{
        .source = .{ .aws_msk = .{
            .cluster_arn = m.clusterArn orelse "",
            .topic = m.topic orelse "",
            .aws_role_arn = m.awsRoleArn orelse "",
            .gcp_service_account = m.gcpServiceAccount orelse "",
        } },
        .log_severity = severity,
        .state = ingestionState(m.state),
    };
    if (w.confluentCloud) |c| return .{
        .source = .{ .confluent_cloud = .{
            .bootstrap_server = c.bootstrapServer orelse "",
            .cluster_id = c.clusterId orelse "",
            .topic = c.topic orelse "",
            .identity_pool_id = c.identityPoolId orelse "",
            .gcp_service_account = c.gcpServiceAccount orelse "",
        } },
        .log_severity = severity,
        .state = ingestionState(c.state),
    };
    return .{ .source = null, .log_severity = severity, .state = .unknown };
}

/// No settings, and the wire's unspecified, are no logs.
fn logSeverity(text: ?[]const u8) types.Ingestion.LogSeverity {
    const s = text orelse return .disabled;
    if (std.mem.eql(u8, s, "DISABLED") or std.mem.eql(u8, s, "SEVERITY_UNSPECIFIED")) return .disabled;
    if (std.mem.eql(u8, s, "DEBUG")) return .debug;
    if (std.mem.eql(u8, s, "INFO")) return .info;
    if (std.mem.eql(u8, s, "WARNING")) return .warning;
    if (std.mem.eql(u8, s, "ERROR")) return .@"error";
    return .unknown;
}

/// The five sources' states as one: each source's own permission error is
/// `.permission_denied`, and a word not yet known, or none, is `.unknown`.
fn ingestionState(text: ?[]const u8) types.IngestionState {
    const s = text orelse return .unknown;
    const words = [_]struct { []const u8, types.IngestionState }{
        .{ "ACTIVE", .active },
        .{ "PUBLISH_PERMISSION_DENIED", .publish_permission_denied },
        .{ "CONFLICTING_REGION_CONSTRAINTS", .conflicting_region_constraints },
        .{ "KINESIS_PERMISSION_DENIED", .permission_denied },
        .{ "CLOUD_STORAGE_PERMISSION_DENIED", .permission_denied },
        .{ "EVENT_HUBS_PERMISSION_DENIED", .permission_denied },
        .{ "MSK_PERMISSION_DENIED", .permission_denied },
        .{ "CONFLUENT_CLOUD_PERMISSION_DENIED", .permission_denied },
        .{ "STREAM_NOT_FOUND", .stream_not_found },
        .{ "CONSUMER_NOT_FOUND", .consumer_not_found },
        .{ "BUCKET_NOT_FOUND", .bucket_not_found },
        .{ "TOO_MANY_OBJECTS", .too_many_objects },
        .{ "NAMESPACE_NOT_FOUND", .namespace_not_found },
        .{ "EVENT_HUB_NOT_FOUND", .event_hub_not_found },
        .{ "SUBSCRIPTION_NOT_FOUND", .subscription_not_found },
        .{ "RESOURCE_GROUP_NOT_FOUND", .resource_group_not_found },
        .{ "CLUSTER_NOT_FOUND", .cluster_not_found },
        .{ "TOPIC_NOT_FOUND", .topic_not_found },
        .{ "UNREACHABLE_BOOTSTRAP_SERVER", .unreachable_bootstrap_server },
    };
    for (words) |word| {
        if (std.mem.eql(u8, s, word[0])) return word[1];
    }
    return .unknown;
}

/// Each transform, in the server's order. One with no JavaScript function
/// is of a kind this client does not model, AI inference today, and is
/// kept as `.other` so that the list's length and order are the server's.
fn transformsFromWire(arena: Allocator, wire: ?[]const WireTransform) Allocator.Error![]const types.MessageTransform {
    const list = wire orelse return &.{};
    const transforms = try arena.alloc(types.MessageTransform, list.len);
    for (list, transforms) |w, *out| out.* = .{
        .kind = if (w.javascriptUdf) |udf| .{ .javascript_udf = .{
            .function_name = udf.functionName orelse "",
            .code = udf.code orelse "",
        } } else .other,
        .disabled = w.disabled orelse false,
    };
    return transforms;
}

/// Settings that name no schema are none: a topic without one may read as
/// `{}`.
fn schemaSettingsFromWire(wire: ?WireSchemaSettings) ?types.SchemaSettings {
    const w = wire orelse return null;
    return .{
        .schema = nonEmpty(w.schema) orelse return null,
        .encoding = schemaEncoding(w.encoding),
        .first_revision_id = nonEmpty(w.firstRevisionId),
        .last_revision_id = nonEmpty(w.lastRevisionId),
    };
}

fn schemaEncoding(text: ?[]const u8) types.SchemaEncoding {
    const s = text orelse return .unknown;
    if (std.mem.eql(u8, s, "JSON")) return .json;
    if (std.mem.eql(u8, s, "BINARY")) return .binary;
    return .unknown;
}

pub fn decodeTopic(arena: Allocator, body: []const u8) DecodeError!types.TopicInfo {
    return topicFromWire(arena, try parseWire(WireTopic, arena, body));
}

pub fn decodeTopicPage(arena: Allocator, body: []const u8) DecodeError!types.TopicPage {
    const wire = try parseWire(WireTopicList, arena, body);
    const list = wire.topics orelse &.{};
    const topics = try arena.alloc(types.TopicInfo, list.len);
    for (list, topics) |t, *out| out.* = try topicFromWire(arena, t);
    return .{ .topics = topics, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn subscriptionFromWire(arena: Allocator, w: WireSubscription) DecodeError!types.SubscriptionInfo {
    return .{
        .name = w.name orelse "",
        .topic = w.topic orelse "",
        .delivery = try deliveryFromWire(w),
        .ack_deadline_seconds = w.ackDeadlineSeconds orelse 0,
        .enable_message_ordering = w.enableMessageOrdering orelse false,
        .enable_exactly_once_delivery = w.enableExactlyOnceDelivery orelse false,
        .filter = w.filter orelse "",
        .dead_letter_policy = if (w.deadLetterPolicy) |policy| .{
            .topic = policy.deadLetterTopic orelse "",
            // 0 means Pub/Sub's default, which is 5.
            .max_delivery_attempts = switch (policy.maxDeliveryAttempts orelse 0) {
                0 => 5,
                1...std.math.maxInt(u8) => |n| @intCast(n),
                else => return error.InvalidResponse,
            },
        } else null,
        // Each bound the server leaves out is its default.
        .retry_policy = if (w.retryPolicy) |b| .{
            .minimum = if (b.minimumBackoff) |text| try parseDuration(text) else .fromSeconds(10),
            .maximum = if (b.maximumBackoff) |text| try parseDuration(text) else .fromSeconds(600),
        } else null,
        .message_retention = try optionalDuration(w.messageRetentionDuration),
        .retain_acked_messages = w.retainAckedMessages orelse false,
        // Absent is the 31-day default; `{}` never expires.
        .expiration = if (w.expirationPolicy) |e|
            (if (e.ttl) |ttl| .{ .after = try parseDuration(ttl) } else .never)
        else
            .default,
        .labels = try labelsFromWire(arena, w.labels),
        .detached = w.detached orelse false,
        .state = subscriptionState(w.state),
        .topic_message_retention = try optionalDuration(w.topicMessageRetentionDuration),
        .message_transforms = try transformsFromWire(arena, w.messageTransforms),
    };
}

/// Production sends at most one kind, and reads a pull subscription as a
/// `pushConfig` with no endpoint. The emulator can hold two kinds at once;
/// the first in this fixed order wins: push, BigQuery, Cloud Storage.
fn deliveryFromWire(w: WireSubscription) DecodeError!types.DeliveryInfo {
    if (w.pushConfig) |p| {
        if (nonEmpty(p.pushEndpoint)) |endpoint| return .{ .push = .{
            .endpoint = endpoint,
            .oidc_token = if (p.oidcToken) |t| .{
                .service_account_email = t.serviceAccountEmail orelse "",
                .audience = t.audience orelse "",
            } else null,
            .body = if (p.noWrapper) |n|
                .{ .unwrapped = .{ .write_metadata = n.writeMetadata orelse false } }
            else
                .wrapped,
        } };
    }
    if (w.bigqueryConfig) |b| return .{ .bigquery = .{ .config = .{
        .table = b.table orelse "",
        .schema = if (b.useTopicSchema orelse false)
            .topic
        else if (b.useTableSchema orelse false)
            .table
        else
            .none,
        .write_metadata = b.writeMetadata orelse false,
        .drop_unknown_fields = b.dropUnknownFields orelse false,
        .service_account_email = nonEmpty(b.serviceAccountEmail),
    }, .state = exportState(b.state) } };
    if (w.cloudStorageConfig) |s| return .{ .cloud_storage = .{ .config = .{
        .bucket = s.bucket orelse "",
        .filename_prefix = s.filenamePrefix orelse "",
        .filename_suffix = s.filenameSuffix orelse "",
        .filename_datetime_format = s.filenameDatetimeFormat orelse "",
        .format = if (s.avroConfig) |a| .{ .avro = .{
            .write_metadata = a.writeMetadata orelse false,
            .use_topic_schema = a.useTopicSchema orelse false,
        } } else .text,
        .max_duration = try optionalDuration(s.maxDuration),
        .max_bytes = s.maxBytes orelse 0,
        .max_messages = s.maxMessages orelse 0,
        .service_account_email = nonEmpty(s.serviceAccountEmail),
    }, .state = exportState(s.state) } };
    if (w.bigtableConfig != null) return .other;
    return .pull;
}

fn exportState(text: ?[]const u8) types.ExportState {
    const s = text orelse return .unknown;
    if (std.mem.eql(u8, s, "ACTIVE")) return .active;
    if (std.mem.eql(u8, s, "PERMISSION_DENIED")) return .permission_denied;
    if (std.mem.eql(u8, s, "NOT_FOUND")) return .not_found;
    if (std.mem.eql(u8, s, "SCHEMA_MISMATCH")) return .schema_mismatch;
    if (std.mem.eql(u8, s, "IN_TRANSIT_LOCATION_RESTRICTION")) return .location_restriction;
    return .unknown;
}

pub fn decodeSubscription(arena: Allocator, body: []const u8) DecodeError!types.SubscriptionInfo {
    return subscriptionFromWire(arena, try parseWire(WireSubscription, arena, body));
}

pub fn decodeSubscriptionPage(arena: Allocator, body: []const u8) DecodeError!types.SubscriptionPage {
    const wire = try parseWire(WireSubscriptionList, arena, body);
    const list = wire.subscriptions orelse &.{};
    const subscriptions = try arena.alloc(types.SubscriptionInfo, list.len);
    for (list, subscriptions) |s, *out| out.* = try subscriptionFromWire(arena, s);
    return .{ .subscriptions = subscriptions, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn snapshotFromWire(arena: Allocator, w: WireSnapshot) DecodeError!types.SnapshotInfo {
    return .{
        .name = w.name orelse "",
        .topic = w.topic orelse "",
        // Production and the emulator send one for every snapshot. Without
        // it there is no true time to give, so the answer is no snapshot.
        .expire_time = timestamp.parse(w.expireTime orelse return error.InvalidResponse) catch return error.InvalidResponse,
        .labels = try labelsFromWire(arena, w.labels),
    };
}

pub fn decodeSnapshot(arena: Allocator, body: []const u8) DecodeError!types.SnapshotInfo {
    return snapshotFromWire(arena, try parseWire(WireSnapshot, arena, body));
}

pub fn decodeSnapshotPage(arena: Allocator, body: []const u8) DecodeError!types.SnapshotPage {
    const wire = try parseWire(WireSnapshotList, arena, body);
    const list = wire.snapshots orelse &.{};
    const snapshots = try arena.alloc(types.SnapshotInfo, list.len);
    for (list, snapshots) |s, *out| out.* = try snapshotFromWire(arena, s);
    return .{ .snapshots = snapshots, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn schemaFromWire(w: WireSchema) DecodeError!types.SchemaInfo {
    // Every answer names its schema. Without a name it is none.
    const name = schemaOf(w.name orelse return error.InvalidResponse);
    if (name.len == 0) return error.InvalidResponse;
    return .{
        .name = name,
        .type = schemaType(w.type),
        // The basic view leaves it out, and so does a schema made from a
        // compiled descriptor set, which this client does not model.
        .definition = w.definition orelse "",
        .revision_id = w.revisionId orelse "",
        .revision_create_time = if (nonEmpty(w.revisionCreateTime)) |text|
            timestamp.parse(text) catch return error.InvalidResponse
        else
            null,
    };
}

/// A schema's name without the `@revision` production writes after it in
/// the answers that are about one revision: a commit's, a rollback's, a
/// read of one and a list of them (measured 2026-10-12). A create's answer
/// and a plain read carry none, and neither does the emulator's, ever. The
/// revision has a field of its own, so the name is always the schema's.
fn schemaOf(name: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, name, '@') orelse return name;
    return name[0..at];
}

fn schemaType(text: ?[]const u8) types.SchemaType {
    const s = text orelse return .unknown;
    if (std.mem.eql(u8, s, "AVRO")) return .avro;
    if (std.mem.eql(u8, s, "PROTOCOL_BUFFER")) return .protocol_buffer;
    return .unknown;
}

pub fn decodeSchema(arena: Allocator, body: []const u8) DecodeError!types.SchemaInfo {
    return schemaFromWire(try parseWire(WireSchema, arena, body));
}

pub fn decodeSchemaPage(arena: Allocator, body: []const u8) DecodeError!types.SchemaPage {
    const wire = try parseWire(WireSchemaList, arena, body);
    const list = wire.schemas orelse &.{};
    const schemas = try arena.alloc(types.SchemaInfo, list.len);
    for (list, schemas) |s, *out| out.* = try schemaFromWire(s);
    return .{ .schemas = schemas, .next_page_token = nonEmpty(wire.nextPageToken) };
}

/// Which of a topic's two lists of names an answer holds.
pub const NameList = enum { subscriptions, snapshots };

pub fn decodeNamePage(arena: Allocator, body: []const u8, list: NameList) DecodeError!types.NamePage {
    const wire = try parseWire(WireNameList, arena, body);
    const names = switch (list) {
        .subscriptions => wire.subscriptions,
        .snapshots => wire.snapshots,
    };
    return .{ .names = names orelse &.{}, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn parseDuration(text: []const u8) DecodeError!std.Io.Duration {
    return duration.parse(text) catch error.InvalidResponse;
}

fn optionalDuration(text: ?[]const u8) DecodeError!?std.Io.Duration {
    return if (text) |t| try parseDuration(t) else null;
}

fn labelsFromWire(arena: Allocator, wire: ?std.json.ArrayHashMap(?[]const u8)) Allocator.Error![]const types.Label {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Label, map.count());
    for (map.keys(), map.values(), out) |k, v, *l| l.* = .{ .key = k, .value = v orelse "" };
    return out;
}

fn topicState(text: ?[]const u8) types.TopicInfo.State {
    const s = text orelse return .active;
    if (std.mem.eql(u8, s, "ACTIVE") or std.mem.eql(u8, s, "STATE_UNSPECIFIED")) return .active;
    if (std.mem.eql(u8, s, "INGESTION_RESOURCE_ERROR")) return .ingestion_resource_error;
    return .unknown;
}

fn subscriptionState(text: ?[]const u8) types.SubscriptionInfo.State {
    const s = text orelse return .active;
    if (std.mem.eql(u8, s, "ACTIVE") or std.mem.eql(u8, s, "STATE_UNSPECIFIED")) return .active;
    if (std.mem.eql(u8, s, "RESOURCE_ERROR")) return .resource_error;
    return .unknown;
}

/// The publish response must hold one id per published message.
pub fn decodePublish(arena: Allocator, body: []const u8, message_count: usize) DecodeError!types.PublishResult {
    const wire = try parseWire(WirePublishResponse, arena, body);
    const ids = wire.messageIds orelse &.{};
    if (ids.len != message_count) return error.InvalidResponse;
    return .{ .message_ids = ids };
}

pub fn decodePull(arena: Allocator, body: []const u8) DecodeError!types.PullResult {
    const wire = try parseWire(WirePullResponse, arena, body);
    const list = wire.receivedMessages orelse &.{};
    const messages = try arena.alloc(types.ReceivedMessage, list.len);
    for (list, messages) |r, *out| {
        const m = r.message orelse WireMessage{};
        out.* = .{
            .ack_id = r.ackId orelse "",
            .message_id = m.messageId orelse "",
            .data = decodeBase64(arena, m.data orelse "") catch |err| switch (err) {
                error.InvalidBase64 => return error.InvalidResponse,
                error.OutOfMemory => return error.OutOfMemory,
            },
            .attributes = try attributesFromWire(arena, m.attributes),
            .publish_time = m.publishTime orelse "",
            .ordering_key = m.orderingKey orelse "",
            .delivery_attempt = r.deliveryAttempt orelse 0,
        };
    }
    return .{ .messages = messages };
}

fn attributesFromWire(
    arena: Allocator,
    wire: ?std.json.ArrayHashMap(?[]const u8),
) Allocator.Error![]const types.Attribute {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Attribute, map.count());
    for (map.keys(), map.values(), out) |k, v, *a| a.* = .{ .key = k, .value = v orelse "" };
    return out;
}

/// Base64: the same rules for every Google JSON API, so core owns them.
pub const Base64Error = base64.Error;
pub const decodeBase64 = base64.decode;

// Tests

const testing = std.testing;
const ByteGen = test_util.ByteGen;

test "golden: publish body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        \\{"messages":[{"data":"aGVsbG8=","attributes":{"origin":"zig"},"orderingKey":"user-42"}]}
    , try encodePublish(a, &.{
        .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} },
    }, "user-42"));

    // Empty data and empty attributes are left out; so is an empty key.
    try testing.expectEqualStrings(
        \\{"messages":[{"attributes":{"k":""}},{"data":"AA=="}]}
    , try encodePublish(a, &.{
        .{ .attributes = &.{.{ .key = "k", .value = "" }} },
        .{ .data = "\x00" },
    }, ""));

    // Strings are escaped; non-ASCII UTF-8 passes through unchanged.
    try testing.expectEqualStrings(
        \\{"messages":[{"data":"eA==","attributes":{"q\"b\\":"\n\u0001é"}}]}
    , try encodePublish(a, &.{
        .{ .data = "x", .attributes = &.{.{ .key = "q\"b\\", .value = "\n\x01é" }} },
    }, null));
}

test "golden: pull, ack, modifyAckDeadline, create bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("{\"maxMessages\":10}", try encodePull(a, 10, false));
    try testing.expectEqualStrings(
        "{\"maxMessages\":1000,\"returnImmediately\":true}",
        try encodePull(a, 1000, true),
    );
    try testing.expectEqualStrings(
        "{\"ackIds\":[\"projects/p/subscriptions/s:1\",\"x\"]}",
        try encodeAckIds(a, &.{ "projects/p/subscriptions/s:1", "x" }, null),
    );
    try testing.expectEqualStrings(
        "{\"ackIds\":[\"a\"],\"ackDeadlineSeconds\":0}",
        try encodeAckIds(a, &.{"a"}, 0),
    );
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t%41\",\"ackDeadlineSeconds\":30,\"enableMessageOrdering\":true}",
        try encodeSubscription(a, "projects/p/topics/t%41", .{
            .topic_id = "t%41",
            .ack_deadline_seconds = 30,
            .enable_message_ordering = true,
        }, null),
    );
    // The defaults leave the deadline to Pub/Sub; exactly-once is sent only when on.
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t\",\"enableMessageOrdering\":false}",
        try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t" }, null),
    );
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t\",\"enableMessageOrdering\":false,\"enableExactlyOnceDelivery\":true}",
        try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .enable_exactly_once_delivery = true }, null),
    );
    try testing.expectEqualStrings("{}", try encodeTopic(a, .{}));
}

test "decode pull: full emulator response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Captured from the emulator, plus a deliveryAttempt.
    const body =
        \\{
        \\  "receivedMessages": [{
        \\    "ackId": "projects/test/subscriptions/smoke-sub:1",
        \\    "message": {
        \\      "data": "aGVsbG8=",
        \\      "attributes": {
        \\        "origin": "zig"
        \\      },
        \\      "messageId": "1",
        \\      "publishTime": "2026-09-18T23:12:18.388Z"
        \\    },
        \\    "deliveryAttempt": 2
        \\  }, {
        \\    "ackId": "projects/test/subscriptions/smoke-sub:2",
        \\    "message": {
        \\      "attributes": {
        \\        "only": "attr"
        \\      },
        \\      "messageId": "2",
        \\      "publishTime": "2026-09-18T23:12:18.388Z",
        \\      "orderingKey": "k1"
        \\    }
        \\  }]
        \\}
    ;
    const result = try decodePull(arena.allocator(), body);
    try testing.expectEqual(2, result.messages.len);
    const first = result.messages[0];
    try testing.expectEqualStrings("projects/test/subscriptions/smoke-sub:1", first.ack_id);
    try testing.expectEqualStrings("1", first.message_id);
    try testing.expectEqualStrings("hello", first.data);
    try testing.expectEqualStrings("zig", first.attribute("origin").?);
    try testing.expectEqualStrings("2026-09-18T23:12:18.388Z", first.publish_time);
    try testing.expectEqualStrings("", first.ordering_key);
    try testing.expectEqual(2, first.delivery_attempt);
    const second = result.messages[1];
    try testing.expectEqualStrings("", second.data);
    try testing.expectEqualStrings("attr", second.attribute("only").?);
    try testing.expectEqualStrings("k1", second.ordering_key);
    try testing.expectEqual(0, second.delivery_attempt);
}

test "decode pull: empty, blank, missing and null fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "  \n", "{}", "{\n}\n", "{\"receivedMessages\":[]}", "{\"receivedMessages\":null}" }) |body| {
        try testing.expectEqual(0, (try decodePull(a, body)).messages.len);
    }
    const sparse = try decodePull(a,
        \\{"receivedMessages":[{},{"message":null,"ackId":null},{"message":{"attributes":{"k":null}}}]}
    );
    try testing.expectEqual(3, sparse.messages.len);
    for (sparse.messages) |m| {
        try testing.expectEqualStrings("", m.ack_id);
        try testing.expectEqualStrings("", m.data);
    }
    try testing.expectEqualStrings("", sparse.messages[2].attribute("k").?);
}

test "decode pull: unknown fields are ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(),
        \\{"receivedMessages":[{"ackId":"a","futureField":{"x":[1,2,{"y":null}]},
        \\"message":{"data":"eA==","schemaRevision":"r1","nested":{"deep":true}}}],"extra":1}
    );
    try testing.expectEqualStrings("x", result.messages[0].data);
}

test "decode pull: base64 without padding and URL-safe" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(),
        \\{"receivedMessages":[{"message":{"data":"aGk"}},{"message":{"data":"-_-_"}},{"message":{"data":"+/+/"}}]}
    );
    try testing.expectEqualStrings("hi", result.messages[0].data);
    try testing.expectEqualSlices(u8, "\xfb\xff\xbf", result.messages[1].data);
    try testing.expectEqualSlices(u8, "\xfb\xff\xbf", result.messages[2].data);
}

test "decode pull: escaped strings are unescaped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(),
        \\{"receivedMessages":[{"ackId":"a\/b\u0041","message":{"attributes":{"k\"":"v\n\u00e9"}}}]}
    );
    const m = result.messages[0];
    try testing.expectEqualStrings("a/bA", m.ack_id);
    try testing.expectEqualStrings("v\né", m.attribute("k\"").?);
}

test "decode pull: malformed bodies are InvalidResponse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "<html>502</html>",
        "{",
        "[]",
        "null",
        "{\"receivedMessages\":{}}",
        "{\"receivedMessages\":[{\"message\":{\"data\":\"!!!!\"}}]}",
        "{\"receivedMessages\":[{\"message\":{\"data\":\"a\"}}]}",
        "{\"receivedMessages\":[{\"deliveryAttempt\":-1}]}",
        "{\"receivedMessages\":[{\"deliveryAttempt\":4294967296}]}",
        "{} trailing",
    };
    for (bad) |body| {
        if (decodePull(a, body)) |_| {
            std.debug.print("accepted malformed body: {s}\n", .{body});
            return error.TestUnexpectedSuccess;
        } else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "decode pull: deliveryAttempt as a string is accepted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(), "{\"receivedMessages\":[{\"deliveryAttempt\":\"5\"}]}");
    try testing.expectEqual(5, result.messages[0].delivery_attempt);
}

test "decode topics, subscriptions and pages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("projects/test/topics/smoke", (try decodeTopic(a, "{\n  \"name\": \"projects/test/topics/smoke\"\n}\n")).name);

    const page = try decodeTopicPage(a,
        \\{"topics":[{"name":"projects/test/topics/page-1"},{"name":"projects/test/topics/page-2"}],
        \\"nextPageToken":"projects/test/topics/page-3"}
    );
    try testing.expectEqual(2, page.topics.len);
    try testing.expectEqualStrings("projects/test/topics/page-2", page.topics[1].name);
    try testing.expectEqualStrings("projects/test/topics/page-3", page.next_page_token.?);

    const last = try decodeTopicPage(a, "{\"topics\":[{\"name\":\"x\"}],\"nextPageToken\":\"\"}");
    try testing.expectEqual(null, last.next_page_token);
    try testing.expectEqual(0, (try decodeTopicPage(a, "{}")).topics.len);

    const sub = try decodeSubscription(a,
        \\{"name":"projects/test/subscriptions/smoke-sub","topic":"projects/test/topics/smoke",
        \\"pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s"}
    );
    try testing.expectEqualStrings("projects/test/subscriptions/smoke-sub", sub.name);
    try testing.expectEqualStrings("projects/test/topics/smoke", sub.topic);
    try testing.expectEqual(10, sub.ack_deadline_seconds);
    try testing.expectEqual(false, sub.enable_message_ordering);
    try testing.expectEqual(false, sub.enable_exactly_once_delivery);

    // As production answers for an exactly-once subscription made without
    // a deadline: 60 s, its default.
    const exactly_once = try decodeSubscription(a,
        \\{"name":"projects/p/subscriptions/eod","topic":"projects/p/topics/t","pushConfig":{},
        \\"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","enableExactlyOnceDelivery":true,"state":"ACTIVE"}
    );
    try testing.expect(exactly_once.enable_exactly_once_delivery);
    try testing.expectEqual(60, exactly_once.ack_deadline_seconds);

    const subs = try decodeSubscriptionPage(a,
        \\{"subscriptions":[{"name":"n","enableMessageOrdering":true}],"nextPageToken":"t"}
    );
    try testing.expect(subs.subscriptions[0].enable_message_ordering);
    try testing.expectEqualStrings("t", subs.next_page_token.?);
}

test "decode publish: ids must match the message count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try decodePublish(a, "{\n  \"messageIds\": [\"7\", \"8\"]\n}", 2);
    try testing.expectEqualStrings("8", ok.message_ids[1]);
    try testing.expectError(error.InvalidResponse, decodePublish(a, "{\"messageIds\":[\"7\"]}", 2));
    try testing.expectError(error.InvalidResponse, decodePublish(a, "{}", 1));
    try testing.expectError(error.InvalidResponse, decodePublish(a, "{\"messageIds\":[null]}", 1));
}

test "jsonStringLen matches Stringify" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const s = "a\"\\\x00\x08\x0c\n\r\t\x1f\x7fé/";
    try Stringify.encodeJsonString(s, .{}, &w);
    try testing.expectEqual(w.buffered().len, jsonStringLen(s));
}

test "AckChunks splits by size and count, in order" {
    const ids = [_][]const u8{ "aaaa", "bbbb", "cccc", "dd", "e" };
    // `{"ackIds":[]}` is 13 bytes; "aaaa" adds 6, each later id adds a comma.
    var it: AckChunks = .{ .ids = &ids, .fixed_bytes = 13, .max_bytes = 26, .max_ids = 10 };
    try testing.expectEqual(2, (try it.next()).?.len); // 13 + 6 + 7 = 26
    try testing.expectEqual(2, (try it.next()).?.len); // 13 + 6 + 5 = 24; + "e" = 28
    try testing.expectEqual(1, (try it.next()).?.len);
    try testing.expectEqual(null, try it.next());

    var by_count: AckChunks = .{ .ids = &ids, .fixed_bytes = 13, .max_bytes = 1000, .max_ids = 2 };
    try testing.expectEqual(2, (try by_count.next()).?.len);
    try testing.expectEqual(2, (try by_count.next()).?.len);
    try testing.expectEqual(1, (try by_count.next()).?.len);

    var too_big: AckChunks = .{ .ids = &ids, .fixed_bytes = 13, .max_bytes = 18, .max_ids = 10 };
    try testing.expectError(error.InvalidArgument, too_big.next());

    var none: AckChunks = .{ .ids = &.{}, .fixed_bytes = 13, .max_bytes = 18, .max_ids = 10 };
    try testing.expectEqual(null, try none.next());
}

// Fuzz properties

fn decodeArbitrary(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every decoder either succeeds or reports InvalidResponse; none may crash.
    inline for (.{ decodePull, decodeTopic, decodeTopicPage, decodeSubscription, decodeSubscriptionPage }) |decode| {
        _ = decode(a, input) catch |err| switch (err) {
            error.InvalidResponse => {},
            else => return err,
        };
    }
    _ = decodePublish(a, input, 1) catch |err| switch (err) {
        error.InvalidResponse => {},
        else => return err,
    };
}

test "fuzz decoders: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeArbitrary, .{ .corpus = &.{
        "{\"receivedMessages\":[{\"ackId\":\"a\",\"message\":{\"data\":\"aGk=\",\"attributes\":{\"k\":\"v\"},\"messageId\":\"1\",\"publishTime\":\"2026-09-18T23:12:18.388Z\",\"orderingKey\":\"o\"},\"deliveryAttempt\":1}]}",
        "{\"topics\":[{\"name\":\"projects/p/topics/t\"}],\"nextPageToken\":\"n\"}",
        "{\"subscriptions\":[{\"name\":\"s\",\"topic\":\"t\",\"ackDeadlineSeconds\":10,\"enableMessageOrdering\":true}]}",
        "{\"messageIds\":[\"1\"]}",
        "{\"error\":{\"code\":404,\"message\":\"m\",\"status\":\"NOT_FOUND\"}}",
        "{\"a\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}",
        "{\"receivedMessages\":[{\"message\":{\"attributes\":{\"k\":\"\\ud800\"}}}]}",
    } });
}

/// Random messages with valid, unique attribute keys, as the validator admits.
fn genMessages(g: *ByteGen, arena: Allocator) ![]types.Message {
    const count = g.intRange(usize, 1, 4);
    const messages = try arena.alloc(types.Message, count);
    for (messages) |*m| {
        const data = try arena.dupe(u8, g.slice(48));
        var attrs: std.ArrayList(types.Attribute) = .empty;
        for (0..g.intRange(usize, 0, 4)) |_| {
            var key_buf: [24]u8 = undefined;
            var value_buf: [32]u8 = undefined;
            const key = try arena.dupe(u8, g.utf8(&key_buf, 24));
            const value = try arena.dupe(u8, g.utf8(&value_buf, 32));
            for (attrs.items) |a| {
                if (std.mem.eql(u8, a.key, key)) break;
            } else try attrs.append(arena, .{ .key = key, .value = value });
        }
        m.* = .{ .data = data, .attributes = attrs.items };
    }
    return messages;
}

fn publishRoundTrip(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    var key_buf: [24]u8 = undefined;
    const ordering_key: ?[]const u8 = if (g.boolean()) g.utf8(&key_buf, 24) else null;
    const messages = try genMessages(&g, a);

    const body = try encodePublish(a, messages, ordering_key);
    // Whatever we send must be valid JSON that says exactly what we meant.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const sent = root.object.get("messages").?.array.items;
    try testing.expectEqual(messages.len, sent.len);
    for (messages, sent) |m, value| {
        const obj = value.object;
        const data = if (obj.get("data")) |d| try decodeBase64(a, d.string) else "";
        try testing.expectEqualSlices(u8, m.data, data);
        const attrs = obj.get("attributes");
        try testing.expectEqual(m.attributes.len, if (attrs) |v| v.object.count() else 0);
        if (attrs) |v| for (m.attributes, v.object.keys(), v.object.values()) |want, key, got| {
            try testing.expectEqualStrings(want.key, key);
            try testing.expectEqualStrings(want.value, got.string);
        };
        const want_key = ordering_key orelse "";
        const got_key = if (obj.get("orderingKey")) |k| k.string else "";
        try testing.expectEqualStrings(want_key, got_key);
    }
}

test "fuzz publish encoding: arbitrary messages encode to the JSON we meant" {
    try test_util.fuzzBytes({}, publishRoundTrip, .{ .corpus = &.{
        "\x01\x08\x02\x10\x00\x00\x00\x00\x00\x00\x00\x03abc",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x01\x40\x07\xff\xff\xff\xff\x01\x02\x03",
    } });
}

/// Writes a pull response the way the server does, for decode round trips.
fn writePullResponse(arena: Allocator, messages: []const types.ReceivedMessage) ![]u8 {
    const Body = struct {
        messages: []const types.ReceivedMessage,
        fn write(self: @This(), jw: *Stringify) Stringify.Error!void {
            try jw.beginObject();
            try jw.objectField("receivedMessages");
            try jw.beginArray();
            for (self.messages) |m| {
                try jw.beginObject();
                try jw.objectField("ackId");
                try jw.write(m.ack_id);
                try jw.objectField("message");
                try jw.beginObject();
                if (m.data.len > 0) {
                    try jw.objectField("data");
                    try base64.writeJsonString(jw, m.data);
                }
                if (m.attributes.len > 0) {
                    try jw.objectField("attributes");
                    try jw.beginObject();
                    for (m.attributes) |attr| {
                        try jw.objectField(attr.key);
                        try jw.write(attr.value);
                    }
                    try jw.endObject();
                }
                try jw.objectField("messageId");
                try jw.write(m.message_id);
                try jw.objectField("publishTime");
                try jw.write(m.publish_time);
                if (m.ordering_key.len > 0) {
                    try jw.objectField("orderingKey");
                    try jw.write(m.ordering_key);
                }
                try jw.endObject();
                if (m.delivery_attempt != 0) {
                    try jw.objectField("deliveryAttempt");
                    try jw.write(m.delivery_attempt);
                }
                try jw.endObject();
            }
            try jw.endArray();
            try jw.endObject();
        }
    };
    return render(arena, Body{ .messages = messages });
}

fn pullRoundTrip(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    const published = try genMessages(&g, a);
    const want = try a.alloc(types.ReceivedMessage, published.len);
    for (published, want) |p, *w| {
        var ack_buf: [40]u8 = undefined;
        var key_buf: [16]u8 = undefined;
        w.* = .{
            .ack_id = try a.dupe(u8, g.utf8(&ack_buf, 40)),
            .message_id = try a.print("{d}", .{g.int(u64)}),
            .data = p.data,
            .attributes = p.attributes,
            .publish_time = "2026-09-18T23:12:18.388Z",
            .ordering_key = try a.dupe(u8, g.utf8(&key_buf, 16)),
            .delivery_attempt = g.int(u32),
        };
    }
    const body = try writePullResponse(a, want);
    const got = (try decodePull(a, body)).messages;
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, r| {
        try testing.expectEqualStrings(w.ack_id, r.ack_id);
        try testing.expectEqualStrings(w.message_id, r.message_id);
        try testing.expectEqualSlices(u8, w.data, r.data);
        try testing.expectEqual(w.attributes.len, r.attributes.len);
        for (w.attributes, r.attributes) |wa, ra| {
            try testing.expectEqualStrings(wa.key, ra.key);
            try testing.expectEqualStrings(wa.value, ra.value);
        }
        try testing.expectEqualStrings(w.publish_time, r.publish_time);
        try testing.expectEqualStrings(w.ordering_key, r.ordering_key);
        try testing.expectEqual(w.delivery_attempt, r.delivery_attempt);
    }
}

test "fuzz pull decoding: server-shaped responses decode exactly" {
    try test_util.fuzzBytes({}, pullRoundTrip, .{ .corpus = &.{
        "\x02\x05hello\x01\x04key1\x03val",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}

test "decodePull: every allocation failure is OutOfMemory without leaks" {
    // 12 KiB of data, so decoding it needs an allocation of its own rather
    // than space left over in the arena.
    const body = "{\"receivedMessages\":[{\"ackId\":\"a1\",\"message\":{\"data\":\"" ++ test_util.repeat("QUFB", 4096) ++
        "\",\"attributes\":{\"k\":\"v\"},\"messageId\":\"1\",\"publishTime\":\"2026-09-19T00:00:00Z\"},\"deliveryAttempt\":1}]}";
    const Run = struct {
        fn decode(gpa: Allocator, text: []const u8) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const result = try decodePull(arena.allocator(), text);
            try testing.expectEqual(3 * 4096, result.messages[0].data.len);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.decode, .{@as([]const u8, body)});
}

fn stringLenProperty(_: void, input: []const u8) !void {
    var buf: [6 * test_util.max_fuzz_input + 2]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Stringify.encodeJsonString(input, .{}, &w);
    try testing.expectEqual(w.buffered().len, jsonStringLen(input));
}

fn publishLenProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    var key_buf: [24]u8 = undefined;
    const ordering_key: ?[]const u8 = switch (g.intRange(u8, 0, 2)) {
        0 => null,
        1 => "",
        else => g.utf8(&key_buf, 24),
    };
    const all = try genMessages(&g, a);
    // Include the empty list: the precedence bug fixed above only showed there.
    const messages = all[0..g.intRange(usize, 0, all.len)];
    try testing.expectEqual((try encodePublish(a, messages, ordering_key)).len, publishBodyLen(messages, ordering_key));
}

test "fuzz publishBodyLen: always equals the encoded length" {
    try test_util.fuzzBytes({}, publishLenProperty, .{ .corpus = &.{
        "\x00\x01\x08\x02\x10\x00\x00\x00\x00\x00\x00\x00\x03abc",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x02\x05\x01\x40\x07\xff\xff\xff\xff\x01\x02\x03",
    } });
}

fn assembledBodyProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    var key_buf: [24]u8 = undefined;
    const ordering_key: ?[]const u8 = switch (g.intRange(u8, 0, 2)) {
        0 => null,
        1 => "",
        else => g.utf8(&key_buf, 24),
    };
    const all = try genMessages(&g, a);
    const messages = all[0..g.intRange(usize, 0, all.len)];

    // A publisher's body, one message at a time.
    var assembled: std.ArrayList(u8) = .empty;
    try assembled.appendSlice(a, publish_body_head);
    for (messages, 0..) |m, i| {
        if (i > 0) try assembled.append(a, ',');
        const one = try encodeMessage(testing.allocator, m, ordering_key);
        defer testing.allocator.free(one);
        try assembled.appendSlice(a, one);
    }
    try assembled.appendSlice(a, publish_body_tail);

    try testing.expectEqualStrings(try encodePublish(a, messages, ordering_key), assembled.items);
    try testing.expectEqual(publishBodyLen(messages, ordering_key), assembled.items.len);
}

test "fuzz encodeMessage: a body built one message at a time is the body encodePublish writes" {
    try test_util.fuzzBytes({}, assembledBodyProperty, .{ .corpus = &.{
        "\x00\x01\x08\x02\x10\x00\x00\x00\x00\x00\x00\x00\x03abc",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x02\x05\x01\x40\x07\xff\xff\xff\xff\x01\x02\x03",
    } });
}

test "encodeMessage: each field, and an empty key left out" {
    const gpa = testing.allocator;
    const cases = [_]struct { types.Message, ?[]const u8, []const u8 }{
        .{ .{ .data = "hi" }, null, "{\"data\":\"aGk=\"}" },
        .{ .{ .data = "hi" }, "", "{\"data\":\"aGk=\"}" },
        .{ .{ .attributes = &.{.{ .key = "k", .value = "v\"" }} }, "user-42", "{\"attributes\":{\"k\":\"v\\\"\"},\"orderingKey\":\"user-42\"}" },
    };
    for (cases) |c| {
        const got = try encodeMessage(gpa, c[0], c[1]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}

test "publishBodyLen: empty publish and each field" {
    try testing.expectEqual("{\"messages\":[]}".len, publishBodyLen(&.{}, null));
    try testing.expectEqual("{\"messages\":[{}]}".len, publishBodyLen(&.{.{}}, null));
    try testing.expectEqual(
        "{\"messages\":[{\"data\":\"aGk=\",\"orderingKey\":\"k\"},{\"orderingKey\":\"k\"}]}".len,
        publishBodyLen(&.{ .{ .data = "hi" }, .{} }, "k"),
    );
}

test "fuzz jsonStringLen: always equals Stringify's output length" {
    try test_util.fuzzBytes({}, stringLenProperty, .{ .corpus = &.{ "", "\x00\x1f\"\\", "é€😀" } });
}

fn ackChunksProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    const deadline: ?u32 = if (g.boolean()) g.intRange(u32, 0, 600) else null;
    const max_bytes = g.intRange(usize, 20, 400);
    const max_ids = g.intRange(usize, 1, 8);
    const ids = try a.alloc([]const u8, g.intRange(usize, 0, 30));
    for (ids) |*id| {
        var buf: [40]u8 = undefined;
        id.* = try a.dupe(u8, g.utf8(&buf, 40));
    }
    const fixed_bytes = (try encodeAckIds(a, &.{}, deadline)).len;
    var it: AckChunks = .{ .ids = ids, .fixed_bytes = fixed_bytes, .max_bytes = max_bytes, .max_ids = max_ids };
    var covered: usize = 0;
    while (true) {
        const chunk = it.next() catch |err| {
            // Only when the next id cannot fit on its own.
            try testing.expectEqual(error.InvalidArgument, err);
            try testing.expect(fixed_bytes + jsonStringLen(ids[covered]) > max_bytes);
            return;
        } orelse break;
        // Chunks are contiguous, in order, within both limits...
        try testing.expect(chunk.ptr == ids[covered..].ptr);
        try testing.expect(chunk.len >= 1 and chunk.len <= max_ids);
        const body = try encodeAckIds(a, chunk, deadline);
        try testing.expect(body.len <= max_bytes);
        covered += chunk.len;
        // ...and greedy: one more id would break a limit.
        if (covered < ids.len and chunk.len < max_ids) {
            const bigger = try encodeAckIds(a, ids[covered - chunk.len .. covered + 1], deadline);
            try testing.expect(bigger.len > max_bytes);
        }
    }
    try testing.expectEqual(ids.len, covered);
}

test "fuzz AckChunks: covers every id, respects limits, stays greedy" {
    try test_util.fuzzBytes({}, ackChunksProperty, .{ .corpus = &.{
        "\x01\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x05",
        "\x00",
    } });
}

test "golden: subscription create body with every setting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/orders\",\"ackDeadlineSeconds\":20,\"enableMessageOrdering\":true," ++
            "\"enableExactlyOnceDelivery\":true,\"filter\":\"attributes.kind = \\\"a\\\"\"," ++
            "\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\",\"maxDeliveryAttempts\":7}," ++
            "\"retryPolicy\":{\"minimumBackoff\":\"1.500s\",\"maximumBackoff\":\"600s\"}," ++
            "\"messageRetentionDuration\":\"1200s\",\"retainAckedMessages\":true," ++
            "\"expirationPolicy\":{\"ttl\":\"86400s\"},\"labels\":{\"team\":\"zig\",\"env\":\"prod\"}}",
        try encodeSubscription(a, "projects/p/topics/orders", .{
            .topic_id = "orders",
            .ack_deadline_seconds = 20,
            .enable_message_ordering = true,
            .enable_exactly_once_delivery = true,
            .filter = "attributes.kind = \"a\"",
            .dead_letter_policy = .{ .topic = "dead", .max_delivery_attempts = 7 },
            .retry_policy = .{ .minimum = .fromMilliseconds(1500) },
            .message_retention = .fromSeconds(1200),
            .retain_acked_messages = true,
            .expiration = .{ .after = .fromSeconds(86400) },
            .labels = &.{ .{ .key = "team", .value = "zig" }, .{ .key = "env", .value = "prod" } },
        }, "projects/p/topics/dead"),
    );
    // Never expiring is `{}`, where the default is left out.
    try testing.expectEqualStrings(
        "{\"topic\":\"t\",\"enableMessageOrdering\":false,\"expirationPolicy\":{}}",
        try encodeSubscription(a, "t", .{ .topic_id = "t", .expiration = .never }, null),
    );
}

test "golden: subscription update bodies name what they set and what they clear" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"subscription\":{\"ackDeadlineSeconds\":30,\"enableExactlyOnceDelivery\":false," ++
            "\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/o/topics/dead\",\"maxDeliveryAttempts\":5}," ++
            "\"retainAckedMessages\":true,\"expirationPolicy\":{},\"labels\":{}}," ++
            "\"updateMask\":\"ackDeadlineSeconds,enableExactlyOnceDelivery,deadLetterPolicy,retryPolicy,messageRetentionDuration,retainAckedMessages,expirationPolicy,labels\"}",
        try encodeSubscriptionUpdate(a, .{
            .ack_deadline_seconds = 30,
            .enable_exactly_once_delivery = false,
            .dead_letter_policy = .{ .set = .{ .topic = "projects/o/topics/dead" } },
            .retry_policy = .clear,
            .message_retention = .clear,
            .retain_acked_messages = true,
            .expiration = .never,
            .labels = &.{},
        }, "projects/o/topics/dead", false),
    );
    // Back to the default expiration: named, and left out.
    try testing.expectEqualStrings(
        "{\"subscription\":{\"retryPolicy\":{\"minimumBackoff\":\"0s\",\"maximumBackoff\":\"2s\"}},\"updateMask\":\"retryPolicy,expirationPolicy\"}",
        try encodeSubscriptionUpdate(a, .{
            .retry_policy = .{ .set = .{ .minimum = .zero, .maximum = .fromSeconds(2) } },
            .expiration = .default,
        }, null, false),
    );

    // A delivery masks every kind and sends the one given: whatever the
    // subscription was, it is then what was asked. `.pull` sends none.
    try testing.expectEqualStrings(
        "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/hook\"}}," ++
            "\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}",
        try encodeSubscriptionUpdate(a, .{ .delivery = .{ .push = .{ .endpoint = "https://example.com/hook" } } }, null, false),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":{},\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}",
        try encodeSubscriptionUpdate(a, .{ .delivery = .pull }, null, false),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":{\"bigqueryConfig\":{\"table\":\"p.d.t\",\"writeMetadata\":true}}," ++
            "\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}",
        try encodeSubscriptionUpdate(a, .{ .delivery = .{ .bigquery = .{ .table = "p.d.t", .write_metadata = true } } }, null, false),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":{\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxBytes\":\"1000\"}}," ++
            "\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig\"}",
        try encodeSubscriptionUpdate(a, .{ .delivery = .{ .cloud_storage = .{ .bucket = "b", .max_bytes = 1000 } } }, null, false),
    );
    // On an emulator the push config alone is masked, since the emulator
    // refuses the other two paths as unknown fields; the delivery still
    // rides beside other changes.
    try testing.expectEqualStrings(
        "{\"subscription\":{\"pushConfig\":{\"pushEndpoint\":\"http://127.0.0.1:9/hook\"},\"ackDeadlineSeconds\":30}," ++
            "\"updateMask\":\"pushConfig,ackDeadlineSeconds\"}",
        try encodeSubscriptionUpdate(a, .{
            .delivery = .{ .push = .{ .endpoint = "http://127.0.0.1:9/hook" } },
            .ack_deadline_seconds = 30,
        }, null, true),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":{},\"updateMask\":\"pushConfig\"}",
        try encodeSubscriptionUpdate(a, .{ .delivery = .pull }, null, true),
    );
}

test "golden: topic create and update bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"3600s\"," ++
            "\"kmsKeyName\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k\"," ++
            "\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"europe-west1\",\"europe-west4\"],\"enforceInTransit\":true}}",
        try encodeTopic(a, .{
            .labels = &.{.{ .key = "env", .value = "test" }},
            .message_retention = .fromSeconds(3600),
            .kms_key_name = "projects/p/locations/l/keyRings/r/cryptoKeys/k",
            .message_storage_policy = .{ .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" }, .enforce_in_transit = true },
        }),
    );
    try testing.expectEqualStrings(
        "{\"topic\":{\"labels\":{\"env\":\"prod\"},\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"us-east1\"]}}," ++
            "\"updateMask\":\"labels,messageRetentionDuration,kmsKeyName,messageStoragePolicy\"}",
        try encodeTopicUpdate(a, .{
            .labels = &.{.{ .key = "env", .value = "prod" }},
            .message_retention = .clear,
            .kms_key_name = .clear,
            .message_storage_policy = .{ .set = .{ .allowed_persistence_regions = &.{"us-east1"} } },
        }),
    );
    // The arms the update above leaves out: retention and key set, the
    // storage policy cleared, which is mask-only.
    try testing.expectEqualStrings(
        "{\"topic\":{\"messageRetentionDuration\":\"3600s\"," ++
            "\"kmsKeyName\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k\"}," ++
            "\"updateMask\":\"messageRetentionDuration,kmsKeyName,messageStoragePolicy\"}",
        try encodeTopicUpdate(a, .{
            .message_retention = .{ .set = .fromSeconds(3600) },
            .kms_key_name = .{ .set = "projects/p/locations/l/keyRings/r/cryptoKeys/k" },
            .message_storage_policy = .clear,
        }),
    );
}

test "decode a subscription with every setting, as the emulator echoes it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try decodeSubscription(arena.allocator(),
        \\{"name":"projects/test/subscriptions/full","topic":"projects/test/topics/t","pushConfig":{},
        \\"ackDeadlineSeconds":20,"retainAckedMessages":true,"messageRetentionDuration":"1200s",
        \\"labels":{"team":"zig"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"86400s"},
        \\"filter":"attributes.kind = \"a\"","deadLetterPolicy":{"deadLetterTopic":"projects/test/topics/dlt","maxDeliveryAttempts":5},
        \\"retryPolicy":{"minimumBackoff":"1.500s","maximumBackoff":"2s"},"enableExactlyOnceDelivery":true,
        \\"state":"ACTIVE","detached":false,"topicMessageRetentionDuration":"3600s"}
    );
    try testing.expectEqual(20, s.ack_deadline_seconds);
    try testing.expect(s.retain_acked_messages);
    try testing.expectEqual(std.Io.Duration.fromSeconds(1200), s.message_retention.?);
    try testing.expectEqualStrings("zig", s.label("team").?);
    try testing.expectEqual(null, s.label("absent"));
    try testing.expect(s.enable_message_ordering and s.enable_exactly_once_delivery);
    try testing.expectEqual(std.Io.Duration.fromSeconds(86400), s.expiration.after);
    try testing.expectEqualStrings("attributes.kind = \"a\"", s.filter);
    try testing.expectEqualStrings("projects/test/topics/dlt", s.dead_letter_policy.?.topic);
    try testing.expectEqual(5, s.dead_letter_policy.?.max_delivery_attempts);
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), s.retry_policy.?.minimum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(2), s.retry_policy.?.maximum);
    try testing.expectEqual(.active, s.state);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), s.topic_message_retention.?);
}

test "decode subscription settings: absent, empty and odd values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Absent: the defaults. The expiration default and `{}` differ.
    const bare = try decodeSubscription(a, "{\"name\":\"n\"}");
    try testing.expectEqual(.default, std.meta.activeTag(bare.expiration));
    try testing.expectEqual(null, bare.retry_policy);
    try testing.expectEqual(null, bare.dead_letter_policy);
    try testing.expectEqual(null, bare.message_retention);
    try testing.expectEqualStrings("", bare.filter);
    try testing.expectEqual(0, bare.labels.len);
    const never = try decodeSubscription(a, "{\"expirationPolicy\":{},\"retryPolicy\":{},\"deadLetterPolicy\":{\"deadLetterTopic\":\"d\"}}");
    try testing.expectEqual(.never, std.meta.activeTag(never.expiration));
    // Bounds left out are Pub/Sub's defaults, 10 s and 600 s; attempts 5.
    try testing.expectEqual(std.Io.Duration.fromSeconds(10), never.retry_policy.?.minimum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(600), never.retry_policy.?.maximum);
    try testing.expectEqual(5, never.dead_letter_policy.?.max_delivery_attempts);
    // A state this client does not know, and one it does.
    try testing.expectEqual(.unknown, (try decodeSubscription(a, "{\"state\":\"SOMETHING_NEW\"}")).state);
    try testing.expectEqual(.resource_error, (try decodeSubscription(a, "{\"state\":\"RESOURCE_ERROR\"}")).state);
    try testing.expect((try decodeSubscription(a, "{\"detached\":true}")).detached);
    // What cannot be a duration, or attempts, is an invalid response.
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"messageRetentionDuration\":\"7 days\"}"));
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"expirationPolicy\":{\"ttl\":\"1\"}}"));
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"retryPolicy\":{\"minimumBackoff\":10}}"));
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"deadLetterPolicy\":{\"maxDeliveryAttempts\":256}}"));
}

test "golden: create bodies for each delivery kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Push, with everything. The wrapped envelope is the default and is
    // left out; `noWrapper` says unwrapped.
    try testing.expectEqualStrings(
        \\{"topic":"projects/p/topics/t","enableMessageOrdering":false,"pushConfig":{"pushEndpoint":"https://example.com/hook","oidcToken":{"serviceAccountEmail":"sa@p.iam.gserviceaccount.com","audience":"zigps"},"noWrapper":{"writeMetadata":true}}}
    , try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .delivery = .{ .push = .{
        .endpoint = "https://example.com/hook",
        .oidc_token = .{ .service_account_email = "sa@p.iam.gserviceaccount.com", .audience = "zigps" },
        .body = .{ .unwrapped = .{ .write_metadata = true } },
    } } }, null));
    // And with the least: an empty audience goes as the endpoint's URL.
    try testing.expectEqualStrings(
        \\{"topic":"projects/p/topics/t","enableMessageOrdering":false,"pushConfig":{"pushEndpoint":"https://e.x/h","oidcToken":{"serviceAccountEmail":"sa@p.iam.gserviceaccount.com"}}}
    , try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .delivery = .{ .push = .{
        .endpoint = "https://e.x/h",
        .oidc_token = .{ .service_account_email = "sa@p.iam.gserviceaccount.com" },
    } } }, null));

    // BigQuery, with everything and with the least.
    try testing.expectEqualStrings(
        \\{"topic":"projects/p/topics/t","enableMessageOrdering":false,"bigqueryConfig":{"table":"p.d.t","useTopicSchema":true,"writeMetadata":true,"dropUnknownFields":true,"serviceAccountEmail":"w@p.iam.gserviceaccount.com"}}
    , try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .delivery = .{ .bigquery = .{
        .table = "p.d.t",
        .schema = .topic,
        .write_metadata = true,
        .drop_unknown_fields = true,
        .service_account_email = "w@p.iam.gserviceaccount.com",
    } } }, null));
    try testing.expectEqualStrings(
        \\{"topic":"projects/p/topics/t","enableMessageOrdering":false,"bigqueryConfig":{"table":"p.d.t","useTableSchema":true}}
    , try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .delivery = .{ .bigquery = .{ .table = "p.d.t", .schema = .table } } }, null));

    // Cloud Storage, with everything: an int64 travels as a string, and
    // text, the default format, is left out.
    try testing.expectEqualStrings(
        \\{"topic":"projects/p/topics/t","enableMessageOrdering":false,"cloudStorageConfig":{"bucket":"zigps-b","filenamePrefix":"logs/","filenameSuffix":".txt","filenameDatetimeFormat":"YYYY-MM-DD/hh_mm_ssZ","avroConfig":{"writeMetadata":true,"useTopicSchema":true},"maxDuration":"300s","maxBytes":"10737418240","maxMessages":"1000","serviceAccountEmail":"w@p.iam.gserviceaccount.com"}}
    , try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .delivery = .{ .cloud_storage = .{
        .bucket = "zigps-b",
        .filename_prefix = "logs/",
        .filename_suffix = ".txt",
        .filename_datetime_format = "YYYY-MM-DD/hh_mm_ssZ",
        .format = .{ .avro = .{ .write_metadata = true, .use_topic_schema = true } },
        .max_duration = .fromSeconds(300),
        .max_bytes = 10 * 1024 * 1024 * 1024,
        .max_messages = 1000,
        .service_account_email = "w@p.iam.gserviceaccount.com",
    } } }, null));
    try testing.expectEqualStrings(
        \\{"topic":"projects/p/topics/t","enableMessageOrdering":false,"cloudStorageConfig":{"bucket":"b"}}
    , try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .delivery = .{ .cloud_storage = .{ .bucket = "b" } } }, null));
}

test "decode a subscription's delivery: each kind, from captured answers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Production reads a pull subscription as a pushConfig with no
    // endpoint, attributes and all (2026-10-10).
    const pull = try decodeSubscription(a, "{\"name\":\"n\",\"pushConfig\":{\"attributes\":{\"x-goog-version\":\"v1\"}}}");
    try testing.expectEqual(.pull, std.meta.activeTag(pull.delivery));
    try testing.expectEqual(.pull, std.meta.activeTag((try decodeSubscription(a, "{\"pushConfig\":{}}")).delivery));
    try testing.expectEqual(.pull, std.meta.activeTag((try decodeSubscription(a, "{}")).delivery));

    // A push as production creates one, and unwrapped as the emulator
    // holds it (noWrapper {}).
    const push = try decodeSubscription(a,
        \\{"name":"projects/extractctl/subscriptions/zigps-x","topic":"projects/extractctl/topics/zigps-t","pushConfig":{"pushEndpoint":"https://example.com/zigps-push","attributes":{"x-goog-version":"v1"},"oidcToken":{"serviceAccountEmail":"sa@extractctl.iam.gserviceaccount.com","audience":"zigps"}},"ackDeadlineSeconds":10}
    );
    try testing.expectEqualStrings("https://example.com/zigps-push", push.delivery.push.endpoint);
    try testing.expectEqualStrings("sa@extractctl.iam.gserviceaccount.com", push.delivery.push.oidc_token.?.service_account_email);
    try testing.expectEqualStrings("zigps", push.delivery.push.oidc_token.?.audience);
    try testing.expectEqual(.wrapped, std.meta.activeTag(push.delivery.push.body));
    const unwrapped = try decodeSubscription(a, "{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/p3\",\"noWrapper\":{}}}");
    try testing.expectEqual(null, unwrapped.delivery.push.oidc_token);
    try testing.expect(!unwrapped.delivery.push.body.unwrapped.write_metadata);
    const meta = try decodeSubscription(a, "{\"pushConfig\":{\"pushEndpoint\":\"https://example.com/p3\",\"noWrapper\":{\"writeMetadata\":true}}}");
    try testing.expect(meta.delivery.push.body.unwrapped.write_metadata);

    // BigQuery, as the emulator echoes a create.
    const bq = try decodeSubscription(a,
        \\{"name":"projects/test/subscriptions/zigps-x-bq","topic":"projects/test/topics/zigps-t","pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s","bigqueryConfig":{"table":"test.d.t","useTopicSchema":true,"writeMetadata":true,"dropUnknownFields":true,"serviceAccountEmail":"w@p.iam.gserviceaccount.com"}}
    );
    try testing.expectEqualStrings("test.d.t", bq.delivery.bigquery.config.table);
    try testing.expectEqual(.topic, bq.delivery.bigquery.config.schema);
    try testing.expect(bq.delivery.bigquery.config.write_metadata);
    try testing.expect(bq.delivery.bigquery.config.drop_unknown_fields);
    try testing.expectEqualStrings("w@p.iam.gserviceaccount.com", bq.delivery.bigquery.config.service_account_email.?);
    // The emulator sends no state; production says ACTIVE.
    try testing.expectEqual(.unknown, bq.delivery.bigquery.state);
    try testing.expectEqual(.active, (try decodeSubscription(a, "{\"bigqueryConfig\":{\"table\":\"p.d.t\",\"state\":\"ACTIVE\"}}")).delivery.bigquery.state);

    // A production PATCH answer (2026-10-11): an update to an export kind
    // echoes a pushConfig holding attributes alone beside the config, and
    // the state is ACTIVE right away.
    const patched = try decodeSubscription(a,
        \\{"name":"projects/extractctl/subscriptions/zigps-x-all","topic":"projects/extractctl/topics/zigps-t","pushConfig":{"attributes":{"x-goog-version":"v1"}},"ackDeadlineSeconds":10,"bigqueryConfig":{"table":"extractctl.zigps_x.msgs","writeMetadata":true,"state":"ACTIVE"},"state":"ACTIVE"}
    );
    try testing.expectEqualStrings("extractctl.zigps_x.msgs", patched.delivery.bigquery.config.table);
    try testing.expect(patched.delivery.bigquery.config.write_metadata);
    try testing.expectEqual(.active, patched.delivery.bigquery.state);

    // Cloud Storage: int64s come as strings from the server, and as
    // numbers from a fake; both are taken.
    const gcs = try decodeSubscription(a,
        \\{"cloudStorageConfig":{"bucket":"zigps-b","filenamePrefix":"logs/","filenameSuffix":".txt","filenameDatetimeFormat":"YYYY-MM-DD/hh_mm_ssZ","avroConfig":{"writeMetadata":true},"maxDuration":"300s","maxBytes":"1000","maxMessages":1000,"state":"PERMISSION_DENIED"}}
    );
    try testing.expectEqualStrings("zigps-b", gcs.delivery.cloud_storage.config.bucket);
    try testing.expectEqualStrings("logs/", gcs.delivery.cloud_storage.config.filename_prefix);
    try testing.expectEqualStrings(".txt", gcs.delivery.cloud_storage.config.filename_suffix);
    try testing.expectEqualStrings("YYYY-MM-DD/hh_mm_ssZ", gcs.delivery.cloud_storage.config.filename_datetime_format);
    try testing.expect(gcs.delivery.cloud_storage.config.format.avro.write_metadata);
    try testing.expect(!gcs.delivery.cloud_storage.config.format.avro.use_topic_schema);
    try testing.expectEqual(std.Io.Duration.fromSeconds(300), gcs.delivery.cloud_storage.config.max_duration.?);
    try testing.expectEqual(1000, gcs.delivery.cloud_storage.config.max_bytes);
    try testing.expectEqual(1000, gcs.delivery.cloud_storage.config.max_messages);
    try testing.expectEqual(.permission_denied, gcs.delivery.cloud_storage.state);
    const bare = (try decodeSubscription(a, "{\"cloudStorageConfig\":{\"bucket\":\"b\"}}")).delivery.cloud_storage;
    try testing.expectEqual(.text, std.meta.activeTag(bare.config.format));
    try testing.expectEqual(null, bare.config.max_duration);
    try testing.expectEqual(0, bare.config.max_bytes);
    try testing.expectEqual(null, bare.config.service_account_email);

    // Each state, and one not yet known.
    for ([_]struct { []const u8, types.ExportState }{
        .{ "NOT_FOUND", .not_found },
        .{ "SCHEMA_MISMATCH", .schema_mismatch },
        .{ "IN_TRANSIT_LOCATION_RESTRICTION", .location_restriction },
        .{ "STATE_UNSPECIFIED", .unknown },
        .{ "SOMETHING_NEW", .unknown },
    }) |case| {
        const body = try a.print("{{\"bigqueryConfig\":{{\"table\":\"p.d.t\",\"state\":\"{s}\"}}}}", .{case[0]});
        try testing.expectEqual(case[1], (try decodeSubscription(a, body)).delivery.bigquery.state);
    }

    // A malformed maxDuration spoils the read, as every other duration does.
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"cloudStorageConfig\":{\"bucket\":\"b\",\"maxDuration\":\"5 minutes\"}}"));
}

test "decode a subscription's delivery: kinds this client does not model, and two at once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A Bigtable subscription lists without failing.
    const bigtable = try decodeSubscription(a, "{\"name\":\"n\",\"pushConfig\":{},\"bigtableConfig\":{\"table\":\"projects/p/instances/i/tables/t\",\"state\":\"ACTIVE\"}}");
    try testing.expectEqual(.other, std.meta.activeTag(bigtable.delivery));

    // Production cannot send two kinds; the emulator keeps both. The first
    // of a fixed order wins: push, BigQuery, Cloud Storage.
    const both = try decodeSubscription(a,
        \\{"pushConfig":{"pushEndpoint":"https://example.com/p"},"bigqueryConfig":{"table":"test.d.t"},"cloudStorageConfig":{"bucket":"b"}}
    );
    try testing.expectEqualStrings("https://example.com/p", both.delivery.push.endpoint);
    const exports = try decodeSubscription(a,
        \\{"pushConfig":{},"bigqueryConfig":{"table":"test.d.t"},"cloudStorageConfig":{"bucket":"b"}}
    );
    try testing.expectEqualStrings("test.d.t", exports.delivery.bigquery.config.table);
    // A modeled kind wins over one that is not: the read still says what
    // this client can say.
    const mixed = try decodeSubscription(a, "{\"cloudStorageConfig\":{\"bucket\":\"b\"},\"bigtableConfig\":{}}");
    try testing.expectEqualStrings("b", mixed.delivery.cloud_storage.config.bucket);
}

test "decode a topic with every setting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try decodeTopic(a,
        \\{"name":"projects/p/topics/t","labels":{"env":"test","empty":""},"messageRetentionDuration":"3600s",
        \\"kmsKeyName":"projects/p/locations/l/keyRings/r/cryptoKeys/k",
        \\"messageStoragePolicy":{"allowedPersistenceRegions":["europe-west1"],"enforceInTransit":true},
        \\"state":"INGESTION_RESOURCE_ERROR","satisfiesPzs":false}
    );
    try testing.expectEqualStrings("test", t.label("env").?);
    try testing.expectEqualStrings("", t.label("empty").?);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), t.message_retention.?);
    try testing.expectEqualStrings("projects/p/locations/l/keyRings/r/cryptoKeys/k", t.kms_key_name.?);
    try testing.expectEqualStrings("europe-west1", t.message_storage_policy.?.allowed_persistence_regions[0]);
    try testing.expect(t.message_storage_policy.?.enforce_in_transit);
    try testing.expectEqual(.ingestion_resource_error, t.state);
    const bare = try decodeTopic(a, "{\"name\":\"n\",\"kmsKeyName\":\"\"}");
    try testing.expectEqual(null, bare.kms_key_name);
    try testing.expectEqual(null, bare.message_storage_policy);
    try testing.expectEqual(.active, bare.state);
    // A state this client does not know, like the subscription twin.
    try testing.expectEqual(.unknown, (try decodeTopic(a, "{\"state\":\"SOMETHING_NEW\"}")).state);
}

/// Draws a delivery the checks accept.
fn genDelivery(g: *ByteGen) types.Delivery {
    switch (g.intRange(u8, 0, 3)) {
        0 => return .pull,
        1 => {
            var p: types.PushConfig = .{ .endpoint = g.pick([]const u8, &.{
                "https://example.com/push",
                "https://h.example/a?b=c",
                "https://x.test/é",
            }) };
            if (g.boolean()) p.oidc_token = .{
                .service_account_email = "sa@p.iam.gserviceaccount.com",
                .audience = g.pick([]const u8, &.{ "", "zigps" }),
            };
            if (g.boolean()) p.body = .{ .unwrapped = .{ .write_metadata = g.boolean() } };
            return .{ .push = p };
        },
        2 => return .{ .bigquery = .{
            .table = g.pick([]const u8, &.{ "p.d.t", "example.com:p.d.t", "a.b.c.d" }),
            .schema = g.pick(types.BigQueryConfig.Schema, &.{ .none, .topic, .table }),
            .write_metadata = g.boolean(),
            .drop_unknown_fields = g.boolean(),
            .service_account_email = if (g.boolean()) "sa@p.iam.gserviceaccount.com" else null,
        } },
        else => {
            var s: types.CloudStorageConfig = .{ .bucket = g.pick([]const u8, &.{ "b", "zigps-bucket", "UPPER.name" }) };
            s.filename_prefix = g.pick([]const u8, &.{ "", "a/b/", "é" });
            s.filename_suffix = g.pick([]const u8, &.{ "", ".txt", "_done" });
            s.filename_datetime_format = g.pick([]const u8, &.{ "", "YYYY-MM-DD/hh_mm_ssZ", "ssmmhhDDMMYYYY", "YYYY-MM-DDThh:mm:ss+00:00" });
            if (g.boolean()) s.format = .{ .avro = .{ .write_metadata = g.boolean(), .use_topic_schema = g.boolean() } };
            if (g.boolean()) s.max_duration = .fromSeconds(g.intRange(u16, 60, 600));
            if (g.boolean()) s.max_bytes = g.intRange(u64, 1000, 10 * 1024 * 1024 * 1024);
            if (g.boolean()) s.max_messages = g.intRange(u64, 1000, 1 << 40);
            if (g.boolean()) s.service_account_email = "sa@p.iam.gserviceaccount.com";
            return .{ .cloud_storage = s };
        },
    }
}

/// `want` as `decodeSubscription` must read it back: the same settings,
/// with the export state `.unknown`, since a create body carries none.
fn expectDeliveryMatches(want: types.Delivery, have: types.DeliveryInfo) !void {
    switch (want) {
        .pull => try testing.expectEqual(.pull, std.meta.activeTag(have)),
        .push => |p| {
            try testing.expectEqualStrings(p.endpoint, have.push.endpoint);
            try testing.expectEqual(p.oidc_token == null, have.push.oidc_token == null);
            if (p.oidc_token) |t| {
                try testing.expectEqualStrings(t.service_account_email, have.push.oidc_token.?.service_account_email);
                try testing.expectEqualStrings(t.audience, have.push.oidc_token.?.audience);
            }
            switch (p.body) {
                .wrapped => try testing.expectEqual(.wrapped, std.meta.activeTag(have.push.body)),
                .unwrapped => |u| try testing.expectEqual(u.write_metadata, have.push.body.unwrapped.write_metadata),
            }
        },
        .bigquery => |b| {
            const got = have.bigquery;
            try testing.expectEqualStrings(b.table, got.config.table);
            try testing.expectEqual(b.schema, got.config.schema);
            try testing.expectEqual(b.write_metadata, got.config.write_metadata);
            try testing.expectEqual(b.drop_unknown_fields, got.config.drop_unknown_fields);
            try expectEqualOptionalStrings(b.service_account_email, got.config.service_account_email);
            try testing.expectEqual(.unknown, got.state);
        },
        .cloud_storage => |s| {
            const got = have.cloud_storage;
            try testing.expectEqualStrings(s.bucket, got.config.bucket);
            try testing.expectEqualStrings(s.filename_prefix, got.config.filename_prefix);
            try testing.expectEqualStrings(s.filename_suffix, got.config.filename_suffix);
            try testing.expectEqualStrings(s.filename_datetime_format, got.config.filename_datetime_format);
            switch (s.format) {
                .text => try testing.expectEqual(.text, std.meta.activeTag(got.config.format)),
                .avro => |a| try testing.expectEqual(a, got.config.format.avro),
            }
            try testing.expectEqual(s.max_duration, got.config.max_duration);
            try testing.expectEqual(s.max_bytes, got.config.max_bytes);
            try testing.expectEqual(s.max_messages, got.config.max_messages);
            try expectEqualOptionalStrings(s.service_account_email, got.config.service_account_email);
            try testing.expectEqual(.unknown, got.state);
        },
    }
}

fn expectEqualOptionalStrings(want: ?[]const u8, have: ?[]const u8) !void {
    try testing.expectEqual(want == null, have == null);
    if (want) |w| try testing.expectEqualStrings(w, have.?);
}

/// Draws settings the checks accept, as a caller might write them.
fn genSubscriptionConfig(g: *ByteGen, arena: Allocator) !types.SubscriptionConfig {
    var config: types.SubscriptionConfig = .{ .topic_id = "t" };
    config.delivery = genDelivery(g);
    config.ack_deadline_seconds = if (g.boolean()) 0 else g.intRange(u32, 10, 600);
    config.enable_message_ordering = g.boolean();
    // Exactly-once works only when the subscriber pulls.
    config.enable_exactly_once_delivery = config.delivery == .pull and g.boolean();
    if (g.boolean()) {
        var buf: [256]u8 = undefined;
        config.filter = try arena.dupe(u8, g.utf8(&buf, 256));
    }
    if (g.boolean()) config.dead_letter_policy = .{ .topic = "projects/p/topics/dead", .max_delivery_attempts = g.intRange(u8, 5, 100) };
    if (g.boolean()) {
        const lo: i64 = g.intRange(u16, 0, 600);
        config.retry_policy = .{
            .minimum = .fromMilliseconds(lo * 1000 - @as(i64, if (lo > 0) g.intRange(u16, 0, 999) else 0)),
            .maximum = .fromSeconds(g.intRange(u16, @intCast(lo), 600)),
        };
    }
    const retention_s: ?i64 = if (g.boolean()) g.intRange(u32, 600, 31 * 24 * 3600) else null;
    if (retention_s) |r| config.message_retention = .fromSeconds(r);
    config.expiration = switch (g.intRange(u8, 0, 2)) {
        0 => .default,
        1 => .never,
        else => .{ .after = .fromSeconds(@max(retention_s orelse 0, 86400) + g.intRange(u32, 0, 1_000_000)) },
    };
    const labels = try arena.alloc(types.Label, g.intRange(u8, 0, 4));
    for (labels, 0..) |*l, i| l.* = .{
        .key = try arena.print("k{d}{s}", .{ i, g.pick([]const u8, &.{ "", "_x", "-y", "z9" }) }),
        .value = g.pick([]const u8, &.{ "", "v", "prod", "a-b_c" }),
    };
    config.labels = labels;
    return config;
}

fn subscriptionRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try genSubscriptionConfig(&g, a);
    try @import("validate.zig").subscriptionConfig(config, false, null);
    // The create body is a subscription resource: read back as one, it
    // says what was asked.
    const dead: ?[]const u8 = if (config.dead_letter_policy) |p| p.topic else null;
    const info = try decodeSubscription(a, try encodeSubscription(a, "projects/p/topics/t", config, dead));
    try testing.expectEqualStrings("projects/p/topics/t", info.topic);
    try testing.expectEqual(config.ack_deadline_seconds, info.ack_deadline_seconds);
    try testing.expectEqual(config.enable_message_ordering, info.enable_message_ordering);
    try testing.expectEqual(config.enable_exactly_once_delivery, info.enable_exactly_once_delivery);
    try expectDeliveryMatches(config.delivery, info.delivery);
    try testing.expectEqualStrings(config.filter, info.filter);
    try testing.expectEqual(config.dead_letter_policy == null, info.dead_letter_policy == null);
    if (config.dead_letter_policy) |p| {
        try testing.expectEqualStrings(p.topic, info.dead_letter_policy.?.topic);
        try testing.expectEqual(p.max_delivery_attempts, info.dead_letter_policy.?.max_delivery_attempts);
    }
    try testing.expectEqual(config.retry_policy, info.retry_policy);
    try testing.expectEqual(config.message_retention, info.message_retention);
    try testing.expectEqual(config.retain_acked_messages, info.retain_acked_messages);
    try testing.expectEqual(config.expiration, info.expiration);
    try testing.expectEqual(config.labels.len, info.labels.len);
    for (config.labels, info.labels) |want, have| {
        try testing.expectEqualStrings(want.key, have.key);
        try testing.expectEqualStrings(want.value, have.value);
    }
}

test "fuzz subscription settings: a create body reads back as the settings it was made from" {
    try test_util.fuzzBytes({}, subscriptionRoundTrip, .{ .corpus = &.{ "", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" } });
}

fn updateMaskProperty(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u: types.SubscriptionUpdate = .{};
    var want: std.ArrayList([]const u8) = .empty;
    var body_fields: std.ArrayList([]const u8) = .empty;
    switch (g.intRange(u8, 0, 4)) {
        0 => {},
        1 => u.delivery = .pull,
        2 => {
            u.delivery = .{ .push = .{ .endpoint = "https://e.x/h" } };
            try body_fields.append(a, "pushConfig");
        },
        3 => {
            u.delivery = .{ .bigquery = .{ .table = "p.d.t" } };
            try body_fields.append(a, "bigqueryConfig");
        },
        else => {
            u.delivery = .{ .cloud_storage = .{ .bucket = "b" } };
            try body_fields.append(a, "cloudStorageConfig");
        },
    }
    // `update` never sends an export kind to an emulator, so the encoder
    // is never asked to.
    const emulator = switch (u.delivery orelse .pull) {
        .pull, .push => g.boolean(),
        .bigquery, .cloud_storage => false,
    };
    if (u.delivery != null) {
        // The mask names every kind exactly when the update sets a
        // delivery; on an emulator, the push config alone.
        try want.append(a, "pushConfig");
        if (!emulator) {
            try want.append(a, "bigqueryConfig");
            try want.append(a, "cloudStorageConfig");
        }
    }
    if (g.boolean()) {
        u.ack_deadline_seconds = g.intRange(u32, 10, 600);
        try want.append(a, "ackDeadlineSeconds");
        try body_fields.append(a, "ackDeadlineSeconds");
    }
    if (g.boolean()) {
        u.enable_exactly_once_delivery = g.boolean();
        try want.append(a, "enableExactlyOnceDelivery");
        try body_fields.append(a, "enableExactlyOnceDelivery");
    }
    switch (g.intRange(u8, 0, 2)) {
        0 => {},
        1 => {
            u.dead_letter_policy = .clear;
            try want.append(a, "deadLetterPolicy");
        },
        else => {
            u.dead_letter_policy = .{ .set = .{ .topic = "d" } };
            try want.append(a, "deadLetterPolicy");
            try body_fields.append(a, "deadLetterPolicy");
        },
    }
    switch (g.intRange(u8, 0, 2)) {
        0 => {},
        1 => {
            u.retry_policy = .clear;
            try want.append(a, "retryPolicy");
        },
        else => {
            u.retry_policy = .{ .set = .{} };
            try want.append(a, "retryPolicy");
            try body_fields.append(a, "retryPolicy");
        },
    }
    switch (g.intRange(u8, 0, 2)) {
        0 => {},
        1 => {
            u.message_retention = .clear;
            try want.append(a, "messageRetentionDuration");
        },
        else => {
            u.message_retention = .{ .set = .fromSeconds(3600) };
            try want.append(a, "messageRetentionDuration");
            try body_fields.append(a, "messageRetentionDuration");
        },
    }
    if (g.boolean()) {
        u.retain_acked_messages = g.boolean();
        try want.append(a, "retainAckedMessages");
        try body_fields.append(a, "retainAckedMessages");
    }
    switch (g.intRange(u8, 0, 3)) {
        0 => {},
        1 => {
            u.expiration = .default;
            try want.append(a, "expirationPolicy");
        },
        2 => {
            u.expiration = .never;
            try want.append(a, "expirationPolicy");
            try body_fields.append(a, "expirationPolicy");
        },
        else => {
            u.expiration = .{ .after = .fromSeconds(86400) };
            try want.append(a, "expirationPolicy");
            try body_fields.append(a, "expirationPolicy");
        },
    }
    if (g.boolean()) {
        u.labels = if (g.boolean()) &.{} else &.{.{ .key = "k", .value = "v" }};
        try want.append(a, "labels");
        try body_fields.append(a, "labels");
    }
    const body = try encodeSubscriptionUpdate(a, u, "projects/p/topics/d", emulator);
    const Parsed = struct { subscription: std.json.ArrayHashMap(std.json.Value), updateMask: []const u8 };
    const parsed = try std.json.parseFromSliceLeaky(Parsed, a, body, .{});
    // The mask names exactly what the update sets or clears, and the body
    // carries exactly what it sets.
    var mask: std.ArrayList([]const u8) = .empty;
    if (parsed.updateMask.len > 0) {
        var it = std.mem.splitScalar(u8, parsed.updateMask, ',');
        while (it.next()) |path| try mask.append(a, path);
    }
    try testing.expectEqual(want.items.len, mask.items.len);
    for (want.items, mask.items) |w, m| try testing.expectEqualStrings(w, m);
    try testing.expectEqual(body_fields.items.len, parsed.subscription.map.count());
    for (body_fields.items) |field| try testing.expect(parsed.subscription.map.contains(field));
}

test "fuzz subscription update: the mask names what the update sets or clears, and the body carries what it sets" {
    try test_util.fuzzBytes({}, updateMaskProperty, .{ .corpus = &.{ "", "\x01\x1f\x01\x01\x02\x02\x02\x01\x01\x03\x01\x00" } });
}

test "decode snapshots, their pages, and a topic's lists of names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Production's answer to a create, 2026-10-10.
    const s = try decodeSnapshot(a,
        \\{"name":"projects/extractctl/snapshots/zigps-snap","topic":"projects/extractctl/topics/zigps-t","expireTime":"2026-10-17T13:46:36.836Z","labels":{"k":"v"}}
    );
    try testing.expectEqualStrings("projects/extractctl/snapshots/zigps-snap", s.name);
    try testing.expectEqualStrings("projects/extractctl/topics/zigps-t", s.topic);
    try testing.expectEqual(try timestamp.parse("2026-10-17T13:46:36.836Z"), s.expire_time);
    try testing.expectEqualStrings("v", s.label("k").?);
    try testing.expectEqual(null, s.label("missing"));
    // And to a read after its topic was deleted.
    const orphan = try decodeSnapshot(a, "{\"name\":\"projects/p/snapshots/s\",\"topic\":\"_deleted-topic_\",\"expireTime\":\"2026-10-17T13:46:36Z\"}");
    try testing.expectEqualStrings("_deleted-topic_", orphan.topic);
    try testing.expectEqual(0, orphan.labels.len);
    // An expiry in any form a timestamp takes: nine digits, or an offset.
    const fine = try decodeSnapshot(a, "{\"expireTime\":\"2026-10-17T13:46:36.123456789Z\"}");
    try testing.expectEqual(123_456_789, @mod(fine.expire_time.nanoseconds, std.time.ns_per_s));
    try testing.expectEqual(fine.expire_time, (try decodeSnapshot(a, "{\"expireTime\":\"2026-10-17T15:46:36.123456789+02:00\"}")).expire_time);
    // A snapshot has an expiry: without one, or with one that is no time,
    // the answer is no snapshot.
    try testing.expectError(error.InvalidResponse, decodeSnapshot(a, "{\"name\":\"projects/p/snapshots/s\"}"));
    try testing.expectError(error.InvalidResponse, decodeSnapshot(a, "{\"expireTime\":\"next week\"}"));
    try testing.expectError(error.InvalidResponse, decodeSnapshot(a, "{\"expireTime\":17}"));

    const page = try decodeSnapshotPage(a,
        \\{"snapshots":[{"name":"projects/p/snapshots/a","topic":"projects/p/topics/t","expireTime":"2026-10-17T13:46:36.836Z"},
        \\{"name":"projects/p/snapshots/b","topic":"projects/p/topics/t","expireTime":"2026-10-17T13:46:36.839Z"}],"nextPageToken":"n"}
    );
    try testing.expectEqual(2, page.snapshots.len);
    try testing.expectEqualStrings("projects/p/snapshots/b", page.snapshots[1].name);
    try testing.expectEqualStrings("n", page.next_page_token.?);
    try testing.expectEqual(0, (try decodeSnapshotPage(a, "{}")).snapshots.len);
    try testing.expectEqual(null, (try decodeSnapshotPage(a, "{\"nextPageToken\":\"\"}")).next_page_token);
    // One that is no snapshot spoils its page.
    try testing.expectError(error.InvalidResponse, decodeSnapshotPage(a, "{\"snapshots\":[{\"name\":\"x\"}]}"));

    // A topic's lists hold names alone, under the key of what was asked for,
    // and production's page token is no name.
    const body =
        \\{"subscriptions":["projects/p/subscriptions/s","projects/other/subscriptions/far"],"nextPageToken":"enhhcGpTGwQLRFJ7VwwbBVEOGA"}
    ;
    const subs = try decodeNamePage(a, body, .subscriptions);
    try testing.expectEqual(2, subs.names.len);
    try testing.expectEqualStrings("projects/other/subscriptions/far", subs.names[1]);
    try testing.expectEqualStrings("enhhcGpTGwQLRFJ7VwwbBVEOGA", subs.next_page_token.?);
    try testing.expectEqual(0, (try decodeNamePage(a, body, .snapshots)).names.len);
    const snaps = try decodeNamePage(a, "{\"snapshots\":[\"projects/p/snapshots/a\"]}", .snapshots);
    try testing.expectEqualStrings("projects/p/snapshots/a", snaps.names[0]);
    try testing.expectEqual(null, snaps.next_page_token);
    try testing.expectEqual(0, (try decodeNamePage(a, "", .subscriptions)).names.len);
    try testing.expectError(error.InvalidResponse, decodeNamePage(a, "{\"subscriptions\":[{\"name\":\"x\"}]}", .subscriptions));
}

test "golden: snapshot create and update bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"subscription\":\"projects/p/subscriptions/orders\"}",
        try encodeSnapshot(a, "projects/p/subscriptions/orders", .{ .subscription = "orders" }),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":\"projects/p/subscriptions/orders\",\"labels\":{\"env\":\"test\",\"team\":\"\"}}",
        try encodeSnapshot(a, "projects/p/subscriptions/orders", .{
            .subscription = "orders",
            .labels = &.{ .{ .key = "env", .value = "test" }, .{ .key = "team", .value = "" } },
        }),
    );
    try testing.expectEqualStrings(
        "{\"snapshot\":{\"labels\":{\"env\":\"prod\"}},\"updateMask\":\"labels\"}",
        try encodeSnapshotUpdate(a, .{ .labels = &.{.{ .key = "env", .value = "prod" }} }),
    );
    // An empty set clears: the mask names the labels, and the body holds none.
    try testing.expectEqualStrings(
        "{\"snapshot\":{\"labels\":{}},\"updateMask\":\"labels\"}",
        try encodeSnapshotUpdate(a, .{ .labels = &.{} }),
    );
}

fn snapshotRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const labels = try a.alloc(types.Label, g.intRange(u8, 0, 4));
    for (labels, 0..) |*l, i| l.* = .{
        .key = try a.print("k{d}{s}", .{ i, g.pick([]const u8, &.{ "", "_x", "-y", "z9" }) }),
        .value = g.pick([]const u8, &.{ "", "v", "prod", "a-b_c" }),
    };
    const config: types.SnapshotConfig = .{
        .subscription = g.pick([]const u8, &.{ "orders", "a%41+b", "projects/other/subscriptions/far" }),
        .labels = labels,
    };
    try @import("validate.zig").snapshotConfig(config, null);

    // The create body names the subscription it is given, and labels only
    // when there are some.
    const body = try encodeSnapshot(a, "projects/p/subscriptions/s", config);
    const sent = try std.json.parseFromSliceLeaky(struct {
        subscription: []const u8,
        labels: ?std.json.ArrayHashMap([]const u8) = null,
    }, a, body, .{});
    try testing.expectEqualStrings("projects/p/subscriptions/s", sent.subscription);
    try testing.expectEqual(labels.len == 0, sent.labels == null);
    // With the name and expiry the server adds, it reads back as the
    // snapshot that was asked for.
    const info = try decodeSnapshot(a, try a.print("{{\"name\":\"projects/p/snapshots/x\",\"expireTime\":\"2026-10-17T13:46:36.836Z\",{s}", .{body[1..]}));
    try testing.expectEqual(labels.len, info.labels.len);
    for (labels, info.labels) |want, have| {
        try testing.expectEqualStrings(want.key, have.key);
        try testing.expectEqualStrings(want.value, have.value);
    }
    // An update to the same labels names them in its mask, and carries them.
    const update = try std.json.parseFromSliceLeaky(struct {
        snapshot: struct { labels: std.json.ArrayHashMap([]const u8) },
        updateMask: []const u8,
    }, a, try encodeSnapshotUpdate(a, .{ .labels = labels }), .{});
    try testing.expectEqualStrings("labels", update.updateMask);
    try testing.expectEqual(labels.len, update.snapshot.labels.map.count());
    for (labels) |want| try testing.expectEqualStrings(want.value, update.snapshot.labels.map.get(want.key).?);
}

test "fuzz snapshot settings: a create body reads back as the snapshot asked for, and an update names its labels" {
    try test_util.fuzzBytes({}, snapshotRoundTrip, .{ .corpus = &.{ "", "\x04\x01\x02\x03\x00\x01\x02\x03\x02", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" } });
}

test "golden: seek bodies hold one target, a time as the server writes one or a snapshot's name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"time\":\"2026-10-10T13:46:36.839Z\"}",
        try encodeSeek(a, .{ .time = try timestamp.parse("2026-10-10T13:46:36.839Z") }, null),
    );
    // Whole seconds carry no fraction, and an offset becomes UTC.
    try testing.expectEqualStrings(
        "{\"time\":\"2026-10-10T13:46:36Z\"}",
        try encodeSeek(a, .{ .time = try timestamp.parse("2026-10-10T15:46:36+02:00") }, null),
    );
    try testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000000001Z\"}",
        try encodeSeek(a, .{ .time = .{ .nanoseconds = 1 } }, null),
    );
    try testing.expectEqualStrings(
        "{\"snapshot\":\"projects/p/snapshots/before\"}",
        try encodeSeek(a, .{ .snapshot = "before" }, "projects/p/snapshots/before"),
    );
}

fn seekBodyProperty(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Sent = struct { time: ?[]const u8 = null, snapshot: ?[]const u8 = null };
    if (g.boolean()) {
        // Any time a timestamp can hold, drawn across the whole range or
        // close to now, goes out as text that reads back as itself.
        const span = timestamp.max.nanoseconds - timestamp.min.nanoseconds;
        const drawn = @as(i128, g.int(u64)) * 4_294_967_311 + g.int(u32);
        const wide = timestamp.min.nanoseconds + @as(i96, @intCast(@mod(drawn, @as(i128, span) + 1)));
        const near = 1_791_000_000 * std.time.ns_per_s + @as(i96, g.int(u32)) * g.pick(i96, &.{ 1, std.time.ns_per_us, std.time.ns_per_ms, std.time.ns_per_s });
        const t: std.Io.Timestamp = .{ .nanoseconds = if (g.boolean()) wide else near };
        try @import("validate.zig").seekTarget(.{ .time = t }, null);
        const sent = try std.json.parseFromSliceLeaky(Sent, a, try encodeSeek(a, .{ .time = t }, null), .{});
        try testing.expectEqual(null, sent.snapshot);
        try testing.expectEqual(t, try timestamp.parse(sent.time.?));
        try testing.expect(std.mem.endsWith(u8, sent.time.?, "Z"));
    } else {
        const name = g.pick([]const u8, &.{ "projects/p/snapshots/before", "projects/other/snapshots/a%41+b" });
        const sent = try std.json.parseFromSliceLeaky(Sent, a, try encodeSeek(a, .{ .snapshot = "before" }, name), .{});
        try testing.expectEqual(null, sent.time);
        try testing.expectEqualStrings(name, sent.snapshot.?);
    }
}

test "fuzz seek bodies: one target, and a time that reads back as itself" {
    try test_util.fuzzBytes({}, seekBodyProperty, .{ .corpus = &.{ "", "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01", "\x01\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\x02", "\x00\x01" } });
}

test "golden: a schema's create body, the two validation bodies, and the wire's words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const avro: types.SchemaDefinition = .{ .type = .avro, .definition = "{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}" };
    try testing.expectEqualStrings(
        \\{"type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}"}
    , try encodeSchema(a, avro));
    // A `.proto` source keeps its line breaks and quotes, escaped.
    try testing.expectEqualStrings(
        \\{"type":"PROTOCOL_BUFFER","definition":"syntax = \"proto3\";\nmessage M { string name = 1; }\n"}
    , try encodeSchema(a, .{ .type = .protocol_buffer, .definition = "syntax = \"proto3\";\nmessage M { string name = 1; }\n" }));
    try testing.expectEqualStrings(
        \\{"schema":{"type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}"}}
    , try encodeValidateSchema(a, avro));

    try testing.expectEqualStrings(
        \\{"name":"projects/p/schemas/order-v1","message":"eyJuYW1lIjoiYSJ9","encoding":"JSON"}
    , try encodeValidateMessage(a, .{ .name = "projects/p/schemas/order-v1" }, "{\"name\":\"a\"}", .json));
    try testing.expectEqualStrings(
        \\{"name":"projects/p/schemas/order-v1@c7cfa2a8","message":"AmEC","encoding":"BINARY"}
    , try encodeValidateMessage(a, .{ .name = "projects/p/schemas/order-v1@c7cfa2a8" }, "\x02a\x02", .binary));
    // No message is an empty string, which the server then judges.
    try testing.expectEqualStrings(
        \\{"schema":{"type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}"},"message":"","encoding":"JSON"}
    , try encodeValidateMessage(a, .{ .definition = avro }, "", .json));

    try testing.expectEqualStrings(
        \\{"schema":{"name":"projects/p/schemas/order-v1","type":"AVRO","definition":"{\"type\":\"record\",\"name\":\"M\",\"fields\":[]}"}}
    , try encodeCommit(a, "projects/p/schemas/order-v1", avro));
    try testing.expectEqualStrings("{\"revisionId\":\"c7cfa2a8\"}", try encodeRollback(a, "c7cfa2a8"));

    // What `validate` refuses first still has a word, one the server refuses.
    try testing.expectEqualStrings("TYPE_UNSPECIFIED", schemaTypeName(.unknown));
    try testing.expectEqualStrings("ENCODING_UNSPECIFIED", schemaEncodingName(.unknown));
    try testing.expectEqualStrings("BASIC", schemaViewName(.basic));
    try testing.expectEqualStrings("FULL", schemaViewName(.full));
}

test "decode: a schema in both views, from the emulator and without what an answer may leave out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The emulator's answer to a create, 2026-10-11: its revision time is
    // in January 1970, and it still parses.
    const made = try decodeSchema(a,
        \\{
        \\  "name": "projects/test/schemas/zigps-s-cc18a1-avro",
        \\  "type": "AVRO",
        \\  "definition": "{\"type\": \"record\", \"name\": \"M\", \"fields\": [{\"name\": \"name\", \"type\": \"string\"}, {\"name\": \"age\", \"type\": \"int\"}]}",
        \\  "revisionId": "1b46a16a",
        \\  "revisionCreateTime": "1970-01-17T11:51:58.663505750Z"
        \\}
    );
    try testing.expectEqualStrings("projects/test/schemas/zigps-s-cc18a1-avro", made.name);
    try testing.expectEqual(types.SchemaType.avro, made.type);
    try testing.expectEqualStrings("{\"type\": \"record\", \"name\": \"M\", \"fields\": [{\"name\": \"name\", \"type\": \"string\"}, {\"name\": \"age\", \"type\": \"int\"}]}", made.definition);
    try testing.expectEqualStrings("1b46a16a", made.revision_id);
    try testing.expectEqual(try timestamp.parse("1970-01-17T11:51:58.663505750Z"), made.revision_create_time.?);

    // Its basic view: no definition.
    const basic = try decodeSchema(a, "{\"name\":\"projects/test/schemas/s\",\"type\":\"AVRO\",\"revisionId\":\"1b46a16a\",\"revisionCreateTime\":\"1970-01-17T11:51:58.663505750Z\"}");
    try testing.expectEqualStrings("", basic.definition);
    try testing.expectEqualStrings("1b46a16a", basic.revision_id);

    // A name and a type alone, as Google's text describes the basic view; a
    // type not yet known; a schema from a compiled descriptor set, whose
    // extra field is read past; and nulls, which count as absent.
    const bare = try decodeSchema(a, "{\"name\":\"projects/p/schemas/s\",\"type\":\"PROTOCOL_BUFFER\"}");
    try testing.expectEqual(types.SchemaType.protocol_buffer, bare.type);
    try testing.expectEqualStrings("", bare.revision_id);
    try testing.expectEqual(null, bare.revision_create_time);
    try testing.expectEqual(types.SchemaType.unknown, (try decodeSchema(a, "{\"name\":\"projects/p/schemas/s\",\"type\":\"THRIFT\"}")).type);
    try testing.expectEqual(types.SchemaType.unknown, (try decodeSchema(a, "{\"name\":\"projects/p/schemas/s\"}")).type);
    const compiled = try decodeSchema(a, "{\"name\":\"projects/p/schemas/s\",\"type\":\"PROTOCOL_BUFFER\",\"compiledProtoSchema\":{\"rootMessage\":\"M\",\"compiledBytes\":\"CgA=\"},\"revisionId\":\"c7cfa2a8\"}");
    try testing.expectEqualStrings("", compiled.definition);
    const nulls = try decodeSchema(a, "{\"name\":\"projects/p/schemas/s\",\"type\":null,\"definition\":null,\"revisionId\":null,\"revisionCreateTime\":null}");
    try testing.expectEqual(null, nulls.revision_create_time);

    // Production's answer to a commit, 2026-10-12: the name carries the
    // revision, which is read off it, and the time is a real one.
    const committed = try decodeSchema(a,
        \\{ "name": "projects/extractctl/schemas/zigps-s-cc3f82-avro@904e53f2", "type": "AVRO", "definition": "{\"type\": \"record\", \"name\": \"M\", \"fields\": []}", "revisionId": "904e53f2", "revisionCreateTime": "2026-10-12T02:01:43.283Z" }
    );
    try testing.expectEqualStrings("projects/extractctl/schemas/zigps-s-cc3f82-avro", committed.name);
    try testing.expectEqualStrings("904e53f2", committed.revision_id);
    try testing.expectEqual(try timestamp.parse("2026-10-12T02:01:43.283Z"), committed.revision_create_time.?);
    // And its list of revisions, in the basic view: each named with its
    // own, the newest first.
    const revisions = try decodeSchemaPage(a,
        \\{ "schemas": [ { "name": "projects/extractctl/schemas/zigps-s-cc3f82-avro@1f505a20", "type": "AVRO", "revisionId": "1f505a20", "revisionCreateTime": "2026-10-12T02:01:43.471Z" }, { "name": "projects/extractctl/schemas/zigps-s-cc3f82-avro@904e53f2", "type": "AVRO", "revisionId": "904e53f2", "revisionCreateTime": "2026-10-12T02:01:43.283Z" } ] }
    );
    for (revisions.schemas) |r| try testing.expectEqualStrings("projects/extractctl/schemas/zigps-s-cc3f82-avro", r.name);
    try testing.expectEqualStrings("1f505a20", revisions.schemas[0].revision_id);
    // A name that is a revision and nothing before it names no schema.
    try testing.expectError(error.InvalidResponse, decodeSchema(a, "{\"name\":\"@904e53f2\",\"type\":\"AVRO\"}"));

    // No name is no schema, and a time that is none is not guessed at.
    try testing.expectError(error.InvalidResponse, decodeSchema(a, "{}"));
    try testing.expectError(error.InvalidResponse, decodeSchema(a, "{\"name\":\"\",\"type\":\"AVRO\"}"));
    try testing.expectError(error.InvalidResponse, decodeSchema(a, "{\"name\":\"projects/p/schemas/s\",\"revisionCreateTime\":\"last week\"}"));
    try testing.expectError(error.InvalidResponse, decodeSchema(a, "{\"name\":\"projects/p/schemas/s\",\"definition\":17}"));
    try testing.expectError(error.InvalidResponse, decodeSchema(a, "[]"));

    const page = try decodeSchemaPage(a,
        \\{"schemas":[{"name":"projects/p/schemas/a","type":"AVRO"},
        \\{"name":"projects/p/schemas/b","type":"PROTOCOL_BUFFER","definition":"message M {}","revisionId":"c7cfa2a8"}],
        \\"nextPageToken":"next"}
    );
    try testing.expectEqual(2, page.schemas.len);
    try testing.expectEqualStrings("projects/p/schemas/a", page.schemas[0].name);
    try testing.expectEqualStrings("message M {}", page.schemas[1].definition);
    try testing.expectEqualStrings("next", page.next_page_token.?);
    try testing.expectEqual(0, (try decodeSchemaPage(a, "{}")).schemas.len);
    try testing.expectEqual(null, (try decodeSchemaPage(a, "{\"nextPageToken\":\"\"}")).next_page_token);
    // One entry that is no schema spoils the page.
    try testing.expectError(error.InvalidResponse, decodeSchemaPage(a, "{\"schemas\":[{\"type\":\"AVRO\"}]}"));
}

fn schemaRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [512]u8 = undefined;
    var text = g.utf8(&buf, buf.len);
    if (text.len == 0) text = "{}";
    const definition: types.SchemaDefinition = .{
        .type = g.pick(types.SchemaType, &.{ .avro, .protocol_buffer }),
        .definition = text,
    };
    try @import("validate.zig").schemaDefinition(definition, null);

    // The create body is the type and the definition, whatever the
    // definition holds, and a validation carries the same under `schema`.
    const Sent = struct { type: []const u8, definition: []const u8 };
    const body = try encodeSchema(a, definition);
    const sent = try std.json.parseFromSliceLeaky(Sent, a, body, .{});
    try testing.expectEqualStrings(schemaTypeName(definition.type), sent.type);
    try testing.expectEqualStrings(text, sent.definition);
    const wrapped = try std.json.parseFromSliceLeaky(struct { schema: Sent }, a, try encodeValidateSchema(a, definition), .{});
    try testing.expectEqualStrings(schemaTypeName(definition.type), wrapped.schema.type);
    try testing.expectEqualStrings(text, wrapped.schema.definition);
    // A commit carries it too, beside the schema's name.
    const committed = try std.json.parseFromSliceLeaky(struct {
        schema: struct { name: []const u8, type: []const u8, definition: []const u8 },
    }, a, try encodeCommit(a, "projects/p/schemas/x", definition), .{});
    try testing.expectEqualStrings("projects/p/schemas/x", committed.schema.name);
    try testing.expectEqualStrings(schemaTypeName(definition.type), committed.schema.type);
    try testing.expectEqualStrings(text, committed.schema.definition);

    // With the name and the revision the server adds, it reads back as the
    // schema that was written.
    const info = try decodeSchema(a, try a.print(
        "{{\"name\":\"projects/p/schemas/x\",\"revisionId\":\"c7cfa2a8\",\"revisionCreateTime\":\"2026-10-11T23:15:46.447Z\",{s}",
        .{body[1..]},
    ));
    try testing.expectEqual(definition.type, info.type);
    try testing.expectEqualStrings(text, info.definition);
    try testing.expectEqualStrings("c7cfa2a8", info.revision_id);

    // A message to check survives its base64, against a name or a
    // definition, and the body names exactly one of the two.
    const data = g.slice(64);
    const encoding = g.pick(types.SchemaEncoding, &.{ .json, .binary });
    const against: SchemaRef = if (g.boolean()) .{ .name = "projects/p/schemas/x@c7cfa2a8" } else .{ .definition = definition };
    const check = try std.json.parseFromSliceLeaky(struct {
        name: ?[]const u8 = null,
        schema: ?Sent = null,
        message: []const u8,
        encoding: []const u8,
    }, a, try encodeValidateMessage(a, against, data, encoding), .{});
    try testing.expectEqualSlices(u8, data, try decodeBase64(a, check.message));
    try testing.expectEqualStrings(schemaEncodingName(encoding), check.encoding);
    try testing.expectEqual(against == .name, check.name != null);
    try testing.expectEqual(against == .definition, check.schema != null);
    if (check.schema) |s| try testing.expectEqualStrings(text, s.definition);
}

test "fuzz schema bodies: a definition reads back as it was written, and a message to check survives its base64" {
    try test_util.fuzzBytes({}, schemaRoundTrip, .{ .corpus = &.{
        "",
        "\x20\x02{\x02}\x01\x00\x03abc\x01\x01",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        "\x08\x01\x00\x01\x01\x00\x00\x00\x01\x02\x03\x04\x05",
    } });
}

test "golden: a topic's schema settings on create and in an update, set whole and cleared" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        \\{"schemaSettings":{"schema":"projects/p/schemas/order-v1","encoding":"JSON"}}
    , try encodeTopic(a, .{ .schema = .{ .schema = "projects/p/schemas/order-v1", .encoding = .json } }));
    try testing.expectEqualStrings(
        \\{"labels":{"env":"test"},"schemaSettings":{"schema":"projects/other/schemas/order-v1","encoding":"BINARY","firstRevisionId":"1b46a16a","lastRevisionId":"6f0519a4"}}
    , try encodeTopic(a, .{
        .labels = &.{.{ .key = "env", .value = "test" }},
        .schema = .{ .schema = "projects/other/schemas/order-v1", .encoding = .binary, .first_revision_id = "1b46a16a", .last_revision_id = "6f0519a4" },
    }));
    // One bound alone: the other stays open.
    try testing.expectEqualStrings(
        \\{"schemaSettings":{"schema":"projects/p/schemas/order-v1","encoding":"JSON","lastRevisionId":"6f0519a4"}}
    , try encodeTopic(a, .{ .schema = .{ .schema = "projects/p/schemas/order-v1", .encoding = .json, .last_revision_id = "6f0519a4" } }));

    try testing.expectEqualStrings(
        \\{"topic":{"schemaSettings":{"schema":"projects/p/schemas/order-v1","encoding":"BINARY"}},"updateMask":"schemaSettings"}
    , try encodeTopicUpdate(a, .{ .schema = .{ .set = .{ .schema = "projects/p/schemas/order-v1", .encoding = .binary } } }));
    try testing.expectEqualStrings(
        \\{"topic":{},"updateMask":"schemaSettings"}
    , try encodeTopicUpdate(a, .{ .schema = .clear }));
    try testing.expectEqualStrings(
        \\{"topic":{"labels":{},"schemaSettings":{"schema":"projects/p/schemas/order-v1","encoding":"JSON","firstRevisionId":"1b46a16a"}},"updateMask":"labels,schemaSettings"}
    , try encodeTopicUpdate(a, .{ .labels = &.{}, .schema = .{ .set = .{ .schema = "projects/p/schemas/order-v1", .encoding = .json, .first_revision_id = "1b46a16a" } } }));
}

test "decode: a topic with a schema, with a range, with its schema deleted, and with none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The emulator's answers, 2026-10-11.
    const plain = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/t", "schemaSettings": { "schema": "projects/test/schemas/order-v1", "encoding": "JSON" } }
    )).schema.?;
    try testing.expectEqualStrings("projects/test/schemas/order-v1", plain.schema);
    try testing.expectEqual(types.SchemaEncoding.json, plain.encoding);
    try testing.expectEqual(null, plain.first_revision_id);
    try testing.expectEqual(null, plain.last_revision_id);
    try testing.expect(!plain.isDeleted());

    const ranged = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/t", "schemaSettings": { "schema": "projects/test/schemas/order-v1", "encoding": "JSON", "firstRevisionId": "1b46a16a", "lastRevisionId": "1b46a16a" } }
    )).schema.?;
    try testing.expectEqualStrings("1b46a16a", ranged.first_revision_id.?);
    try testing.expectEqualStrings("1b46a16a", ranged.last_revision_id.?);

    const gone = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/t", "schemaSettings": { "schema": "_deleted-schema_", "encoding": "BINARY" } }
    )).schema.?;
    try testing.expect(gone.isDeleted());
    try testing.expectEqual(types.SchemaEncoding.binary, gone.encoding);

    // No settings, empty ones, a null and ones that name no schema are no
    // schema; an encoding not yet known, or left out, is `.unknown`; an
    // empty bound is an open one.
    try testing.expectEqual(null, (try decodeTopic(a, "{\"name\":\"projects/p/topics/t\"}")).schema);
    try testing.expectEqual(null, (try decodeTopic(a, "{\"name\":\"projects/p/topics/t\",\"schemaSettings\":{}}")).schema);
    try testing.expectEqual(null, (try decodeTopic(a, "{\"name\":\"projects/p/topics/t\",\"schemaSettings\":null}")).schema);
    try testing.expectEqual(null, (try decodeTopic(a, "{\"name\":\"projects/p/topics/t\",\"schemaSettings\":{\"schema\":\"\",\"encoding\":\"JSON\"}}")).schema);
    try testing.expectEqual(types.SchemaEncoding.unknown, (try decodeTopic(a, "{\"schemaSettings\":{\"schema\":\"projects/p/schemas/s\",\"encoding\":\"CBOR\"}}")).schema.?.encoding);
    try testing.expectEqual(types.SchemaEncoding.unknown, (try decodeTopic(a, "{\"schemaSettings\":{\"schema\":\"projects/p/schemas/s\"}}")).schema.?.encoding);
    try testing.expectEqual(null, (try decodeTopic(a, "{\"schemaSettings\":{\"schema\":\"projects/p/schemas/s\",\"encoding\":\"JSON\",\"firstRevisionId\":\"\"}}")).schema.?.first_revision_id);
    try testing.expectError(error.InvalidResponse, decodeTopic(a, "{\"schemaSettings\":\"order-v1\"}"));

    // In a list, each topic with its own.
    const page = try decodeTopicPage(a,
        \\{"topics":[{"name":"projects/p/topics/a"},{"name":"projects/p/topics/b","schemaSettings":{"schema":"projects/p/schemas/s","encoding":"BINARY"}}]}
    );
    try testing.expectEqual(null, page.topics[0].schema);
    try testing.expectEqual(types.SchemaEncoding.binary, page.topics[1].schema.?.encoding);
}

fn topicSchemaRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const revisions = [_]?[]const u8{ null, "1b46a16a", "6f0519a4", "a-b_c.d~e", "0" };
    const settings: types.SchemaSettings = .{
        .schema = g.pick([]const u8, &.{ "projects/p/schemas/order-v1", "projects/example.com:proj/schemas/a%41+b", "projects/other/schemas/abc" }),
        .encoding = g.pick(types.SchemaEncoding, &.{ .json, .binary }),
        .first_revision_id = revisions[g.intRange(u8, 0, revisions.len - 1)],
        .last_revision_id = revisions[g.intRange(u8, 0, revisions.len - 1)],
    };
    try @import("validate.zig").schemaSettings(settings, null);

    // What a create sends, a read gives back.
    const created = try decodeTopic(a, try encodeTopic(a, .{ .schema = settings }));
    const have = created.schema.?;
    try testing.expectEqualStrings(settings.schema, have.schema);
    try testing.expectEqual(settings.encoding, have.encoding);
    try expectEqualOptionalStrings(settings.first_revision_id, have.first_revision_id);
    try expectEqualOptionalStrings(settings.last_revision_id, have.last_revision_id);

    // An update names `schemaSettings` in its mask exactly when it sets or
    // clears them, and carries them exactly when it sets them.
    const change: types.Change(types.SchemaSettings) = switch (g.intRange(u8, 0, 2)) {
        0 => .keep,
        1 => .clear,
        else => .{ .set = settings },
    };
    const with_labels = g.boolean();
    if (change == .keep and !with_labels) return;
    const update = try std.json.parseFromSliceLeaky(struct {
        topic: struct { schemaSettings: ?WireSchemaSettings = null, labels: ?std.json.Value = null },
        updateMask: []const u8,
    }, a, try encodeTopicUpdate(a, .{ .labels = if (with_labels) &.{} else null, .schema = change }), .{});
    var named = false;
    var paths = std.mem.splitScalar(u8, update.updateMask, ',');
    while (paths.next()) |path| {
        if (std.mem.eql(u8, path, "schemaSettings")) named = true;
    }
    try testing.expectEqual(change != .keep, named);
    try testing.expectEqual(change == .set, update.topic.schemaSettings != null);
    if (update.topic.schemaSettings) |sent| {
        try testing.expectEqualStrings(settings.schema, sent.schema.?);
        try testing.expectEqualStrings(schemaEncodingName(settings.encoding), sent.encoding.?);
        try expectEqualOptionalStrings(settings.first_revision_id, sent.firstRevisionId);
        try expectEqualOptionalStrings(settings.last_revision_id, sent.lastRevisionId);
    }
}

test "fuzz topic schema settings: what a create sends a read gives back, and an update's mask names them exactly when it changes them" {
    try test_util.fuzzBytes({}, topicSchemaRoundTrip, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x01\x02\x02\x01",
        "\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
    } });
}

const upper_udf: types.MessageTransform = .{ .kind = .{ .javascript_udf = .{
    .function_name = "upper",
    .code = "function upper(message, metadata) { message.data = message.data.toUpperCase(); return message; }",
} } };

test "golden: message transforms on create and in an update: a list, a disabled one, and an empty list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const upper_json =
        \\{"javascriptUdf":{"functionName":"upper","code":"function upper(message, metadata) { message.data = message.data.toUpperCase(); return message; }"}}
    ;
    // In the order given, code escaped as any string is, and `disabled`
    // only when set.
    const two = [_]types.MessageTransform{
        .{ .kind = .{ .javascript_udf = .{ .function_name = "a", .code = "function a(m) {\n  return m;\n}" } } },
        .{ .kind = .{ .javascript_udf = .{ .function_name = "b", .code = "function b(m) { m.attributes[\"k\"] = 'v'; return m; }" } }, .disabled = true },
    };
    const two_json =
        \\[{"javascriptUdf":{"functionName":"a","code":"function a(m) {\n  return m;\n}"}},{"javascriptUdf":{"functionName":"b","code":"function b(m) { m.attributes[\"k\"] = 'v'; return m; }"},"disabled":true}]
    ;

    try testing.expectEqualStrings("{\"messageTransforms\":[" ++ upper_json ++ "]}", try encodeTopic(a, .{ .message_transforms = &.{upper_udf} }));
    try testing.expectEqualStrings(
        "{\"labels\":{\"env\":\"test\"},\"messageTransforms\":" ++ two_json ++ "}",
        try encodeTopic(a, .{ .labels = &.{.{ .key = "env", .value = "test" }}, .message_transforms = &two }),
    );
    // None is no field at all.
    try testing.expectEqualStrings("{}", try encodeTopic(a, .{}));
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t\",\"enableMessageOrdering\":false,\"messageTransforms\":" ++ two_json ++ "}",
        try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .message_transforms = &two }, null),
    );
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t\",\"enableMessageOrdering\":false}",
        try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t" }, null),
    );

    // An update names the list and carries it; an empty one is named and
    // left out, which clears it.
    try testing.expectEqualStrings(
        "{\"topic\":{\"messageTransforms\":[" ++ upper_json ++ "]},\"updateMask\":\"messageTransforms\"}",
        try encodeTopicUpdate(a, .{ .message_transforms = &.{upper_udf} }),
    );
    try testing.expectEqualStrings(
        "{\"topic\":{},\"updateMask\":\"messageTransforms\"}",
        try encodeTopicUpdate(a, .{ .message_transforms = &.{} }),
    );
    try testing.expectEqualStrings(
        "{\"topic\":{\"labels\":{},\"messageTransforms\":" ++ two_json ++ "},\"updateMask\":\"labels,schemaSettings,messageTransforms\"}",
        try encodeTopicUpdate(a, .{ .labels = &.{}, .schema = .clear, .message_transforms = &two }),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":{\"messageTransforms\":[" ++ upper_json ++ "]},\"updateMask\":\"messageTransforms\"}",
        try encodeSubscriptionUpdate(a, .{ .message_transforms = &.{upper_udf} }, null, false),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":{},\"updateMask\":\"messageTransforms\"}",
        try encodeSubscriptionUpdate(a, .{ .message_transforms = &.{} }, null, true),
    );
    // Everything a subscription update can name, at once: twelve paths.
    try testing.expectEqualStrings(
        "{\"subscription\":{\"ackDeadlineSeconds\":30,\"enableExactlyOnceDelivery\":false,\"retainAckedMessages\":false,\"labels\":{}}," ++
            "\"updateMask\":\"pushConfig,bigqueryConfig,cloudStorageConfig,ackDeadlineSeconds,enableExactlyOnceDelivery,deadLetterPolicy," ++
            "retryPolicy,messageRetentionDuration,retainAckedMessages,expirationPolicy,labels,messageTransforms\"}",
        try encodeSubscriptionUpdate(a, .{
            .delivery = .pull,
            .ack_deadline_seconds = 30,
            .enable_exactly_once_delivery = false,
            .dead_letter_policy = .clear,
            .retry_policy = .clear,
            .message_retention = .clear,
            .retain_acked_messages = false,
            .expiration = .default,
            .labels = &.{},
            .message_transforms = &.{},
        }, null, false),
    );

    // A kind this client does not model has nothing to write: it goes as a
    // transform of no kind, which the server refuses. The checks refuse
    // such a list before it is ever encoded.
    try testing.expectEqualStrings(
        "{\"messageTransforms\":[{},{\"disabled\":true}]}",
        try encodeTopic(a, .{ .message_transforms = &.{ .{ .kind = .other }, .{ .kind = .other, .disabled = true } } }),
    );
}

fn expectUdf(want_name: []const u8, want_code: []const u8, want_disabled: bool, have: types.MessageTransform) !void {
    try testing.expectEqualStrings(want_name, have.kind.javascript_udf.function_name);
    try testing.expectEqualStrings(want_code, have.kind.javascript_udf.code);
    try testing.expectEqual(want_disabled, have.disabled);
}

test "decode: message transforms from production's answers, a kind not modelled, and what an answer may leave out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const upper_code = "function upper(message, metadata) { message.data = message.data.toUpperCase(); message.attributes['seen'] = 'yes'; return message; }";

    // Production's answers, 2026-10-12.
    const topic = try decodeTopic(a,
        \\{ "name": "projects/extractctl/topics/zigps-x-cc4711-t1", "messageTransforms": [ { "javascriptUdf": { "functionName": "upper", "code": "function upper(message, metadata) { message.data = message.data.toUpperCase(); message.attributes['seen'] = 'yes'; return message; }" } } ] }
    );
    try testing.expectEqual(1, topic.message_transforms.len);
    try expectUdf("upper", upper_code, false, topic.message_transforms[0]);

    const off = try decodeTopic(a,
        \\{ "name": "projects/extractctl/topics/zigps-x-cc4711-t12", "messageTransforms": [ { "javascriptUdf": { "functionName": "upper", "code": "function upper(message, metadata) { message.data = message.data.toUpperCase(); message.attributes['seen'] = 'yes'; return message; }" }, "disabled": true } ] }
    );
    try expectUdf("upper", upper_code, true, off.message_transforms[0]);

    // Production keeps the deprecated `enabled` beside a `disabled` that
    // says the opposite. `disabled` alone is read.
    const both = try decodeTopic(a,
        \\{ "name": "projects/extractctl/topics/zigps-x-cc4711-t13", "messageTransforms": [ { "javascriptUdf": { "functionName": "upper", "code": "function upper(message, metadata) { message.data = message.data.toUpperCase(); message.attributes['seen'] = 'yes'; return message; }" }, "enabled": true, "disabled": true } ] }
    );
    try expectUdf("upper", upper_code, true, both.message_transforms[0]);
    const only_enabled = try decodeTopic(a, "{\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"f\",\"code\":\"c\"},\"enabled\":false}]}");
    try expectUdf("f", "c", false, only_enabled.message_transforms[0]);

    const subscription = try decodeSubscription(a,
        \\{ "name": "projects/extractctl/subscriptions/zigps-x-cc4711-s23", "topic": "projects/extractctl/topics/zigps-x-cc4711-t21", "pushConfig": {}, "ackDeadlineSeconds": 10, "messageRetentionDuration": "604800s", "expirationPolicy": { "ttl": "2678400s" }, "state": "ACTIVE", "messageTransforms": [ { "javascriptUdf": { "functionName": "drop", "code": "function drop(message, metadata) { if (message.data === 'drop') return null; return message; }" } } ] }
    );
    try testing.expectEqual(1, subscription.message_transforms.len);
    try expectUdf("drop", "function drop(message, metadata) { if (message.data === 'drop') return null; return message; }", false, subscription.message_transforms[0]);
    try testing.expectEqual(types.DeliveryInfo.pull, subscription.delivery);

    // A kind this client does not model keeps its place in the list, and
    // its switch. The shapes are the discovery document's.
    const mixed = try decodeTopic(a,
        \\{"messageTransforms":[
        \\  {"javascriptUdf":{"functionName":"a","code":"function a(m) { return m; }"}},
        \\  {"aiInference":{"endpoint":"projects/p/locations/us-central1/endpoints/e","unstructuredInference":{"parameters":{}}}},
        \\  {"compression":{"compressionType":"GZIP"},"disabled":true},
        \\  {"javascriptUdf":{"functionName":"b","code":"function b(m) { return m; }"},"disabled":true},
        \\  {}
        \\]}
    );
    try testing.expectEqual(5, mixed.message_transforms.len);
    try expectUdf("a", "function a(m) { return m; }", false, mixed.message_transforms[0]);
    try testing.expect(mixed.message_transforms[1].kind == .other);
    try testing.expect(!mixed.message_transforms[1].disabled);
    try testing.expect(mixed.message_transforms[2].kind == .other);
    try testing.expect(mixed.message_transforms[2].disabled);
    try expectUdf("b", "function b(m) { return m; }", true, mixed.message_transforms[3]);
    try testing.expect(mixed.message_transforms[4].kind == .other);

    // No list, an empty one and a null are none; a function with a part
    // left out reads as "" there.
    try testing.expectEqual(0, (try decodeTopic(a, "{\"name\":\"projects/p/topics/t\"}")).message_transforms.len);
    try testing.expectEqual(0, (try decodeTopic(a, "{\"messageTransforms\":[]}")).message_transforms.len);
    try testing.expectEqual(0, (try decodeTopic(a, "{\"messageTransforms\":null}")).message_transforms.len);
    try testing.expectEqual(0, (try decodeSubscription(a, "{\"name\":\"projects/p/subscriptions/s\"}")).message_transforms.len);
    try expectUdf("", "", false, (try decodeTopic(a, "{\"messageTransforms\":[{\"javascriptUdf\":{}}]}")).message_transforms[0]);
    try expectUdf("f", "", false, (try decodeSubscription(a, "{\"messageTransforms\":[{\"javascriptUdf\":{\"functionName\":\"f\"}}]}")).message_transforms[0]);
    try testing.expectError(error.InvalidResponse, decodeTopic(a, "{\"messageTransforms\":{}}"));
    try testing.expectError(error.InvalidResponse, decodeTopic(a, "{\"messageTransforms\":[null]}"));
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"messageTransforms\":[{\"javascriptUdf\":\"upper\"}]}"));

    // In a list, each resource with its own.
    const topics = try decodeTopicPage(a,
        \\{"topics":[{"name":"projects/p/topics/a"},{"name":"projects/p/topics/b","messageTransforms":[{"javascriptUdf":{"functionName":"f","code":"c"}}]}]}
    );
    try testing.expectEqual(0, topics.topics[0].message_transforms.len);
    try expectUdf("f", "c", false, topics.topics[1].message_transforms[0]);
    const subscriptions = try decodeSubscriptionPage(a,
        \\{"subscriptions":[{"name":"projects/p/subscriptions/a","messageTransforms":[{"aiInference":{}}]},{"name":"projects/p/subscriptions/b"}]}
    );
    try testing.expect(subscriptions.subscriptions[0].message_transforms[0].kind == .other);
    try testing.expectEqual(0, subscriptions.subscriptions[1].message_transforms.len);
}

/// A list the checks pass: up to seven transforms, at most five of them
/// not disabled, each a function of its own name with code of any UTF-8.
fn genTransforms(g: *ByteGen, arena: Allocator) ![]types.MessageTransform {
    const list = try arena.alloc(types.MessageTransform, g.intRange(u8, 0, 7));
    var enabled: usize = 0;
    for (list, 0..) |*transform, i| {
        const code = try arena.alloc(u8, 48);
        const text = g.utf8(code, 48);
        const disabled = g.boolean() or enabled == 5;
        if (!disabled) enabled += 1;
        transform.* = .{
            .kind = .{ .javascript_udf = .{
                .function_name = try std.fmt.allocPrint(arena, "{s}{d}", .{ g.pick([]const u8, &.{ "f", "redact_", "$", "\u{e9}t\u{e9}" }), i }),
                .code = if (text.len == 0) "function f(m) { return m; }" else text,
            } },
            .disabled = disabled,
        };
    }
    return list;
}

fn expectTransformsEqual(want: []const types.MessageTransform, have: []const types.MessageTransform) !void {
    try testing.expectEqual(want.len, have.len);
    for (want, have) |w, h| try expectUdf(w.kind.javascript_udf.function_name, w.kind.javascript_udf.code, w.disabled, h);
}

fn transformsRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try genTransforms(&g, a);
    try @import("validate.zig").messageTransforms(list, null);

    // What a create sends, a read gives back, on a topic and on a
    // subscription.
    const topic = try decodeTopic(a, try encodeTopic(a, .{ .message_transforms = list }));
    try expectTransformsEqual(list, topic.message_transforms);
    const subscription = try decodeSubscription(a, try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .message_transforms = list }, null));
    try expectTransformsEqual(list, subscription.message_transforms);

    // An update names `messageTransforms` in its mask exactly when a list
    // is given, an empty one included, and carries it exactly when it
    // holds something.
    const given: ?[]const types.MessageTransform = switch (g.intRange(u8, 0, 2)) {
        0 => null,
        1 => &.{},
        else => list,
    };
    const with_labels = g.boolean();
    if (given == null and !with_labels) return;
    const labels: ?[]const types.Label = if (with_labels) &.{} else null;
    const Sent = struct { messageTransforms: ?[]const WireTransform = null, labels: ?std.json.Value = null };
    const topic_update = try std.json.parseFromSliceLeaky(
        struct { topic: Sent, updateMask: []const u8 },
        a,
        try encodeTopicUpdate(a, .{ .labels = labels, .message_transforms = given }),
        .{},
    );
    const subscription_update = try std.json.parseFromSliceLeaky(
        struct { subscription: Sent, updateMask: []const u8 },
        a,
        try encodeSubscriptionUpdate(a, .{ .labels = labels, .message_transforms = given }, null, g.boolean()),
        .{},
    );
    for ([_]struct { Sent, []const u8 }{
        .{ topic_update.topic, topic_update.updateMask },
        .{ subscription_update.subscription, subscription_update.updateMask },
    }) |update| {
        const sent, const mask = update;
        var named: usize = 0;
        var paths = std.mem.splitScalar(u8, mask, ',');
        while (paths.next()) |path| {
            if (std.mem.eql(u8, path, "messageTransforms")) named += 1;
        }
        try testing.expectEqual(@intFromBool(given != null), named);
        const carried = given != null and given.?.len > 0;
        try testing.expectEqual(carried, sent.messageTransforms != null);
        if (carried) try expectTransformsEqual(given.?, try transformsFromWire(a, sent.messageTransforms));
    }
}

test "fuzz message transforms: what a create sends a read gives back, and an update's mask names the list exactly when one is given" {
    try test_util.fuzzBytes({}, transformsRoundTrip, .{
        .corpus = &.{
            "",
            // One function, given in an update beside labels.
            "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x01\x00",
            // Seven, so the sixth and seventh are disabled; an empty list given.
            "\x07" ++ &@as([7 * 17]u8, @splat(0)) ++ "\x01\x00\x01",
            "\x03\x00\x00\x00\x00\x00\x00\x00\x08\x01\x22\x02\x41\x04\x00\x00\x00\xe9\x01\x00\x00\x00\x00\x00\x00\x00\x01\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    });
}

const kinesis: types.Ingestion.Source = .{ .aws_kinesis = .{
    .stream_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/orders",
    .consumer_arn = "arn:aws:kinesis:us-east-1:111111111111:stream/orders/consumer/c:1",
    .aws_role_arn = "arn:aws:iam::111111111111:role/pubsub",
    .gcp_service_account = "importer@my-project.iam.gserviceaccount.com",
} };
const event_hubs: types.Ingestion.Source = .{ .azure_event_hubs = .{
    .resource_group = "rg",
    .namespace = "ns",
    .event_hub = "eh",
    .client_id = "11111111-1111-1111-1111-111111111111",
    .tenant_id = "22222222-2222-2222-2222-222222222222",
    .subscription_id = "33333333-3333-3333-3333-333333333333",
    .gcp_service_account = "importer@my-project.iam.gserviceaccount.com",
} };
const msk: types.Ingestion.Source = .{ .aws_msk = .{
    .cluster_arn = "arn:aws:kafka:us-east-1:111111111111:cluster/orders/abc",
    .topic = "orders",
    .aws_role_arn = "arn:aws:iam::111111111111:role/pubsub",
    .gcp_service_account = "importer@my-project.iam.gserviceaccount.com",
} };
const confluent: types.Ingestion.Source = .{ .confluent_cloud = .{
    .bootstrap_server = "pkc-xxxx.us-east-1.aws.confluent.cloud:9092",
    .cluster_id = "lkc-xxxx",
    .topic = "orders",
    .identity_pool_id = "pool-xxxx",
    .gcp_service_account = "importer@my-project.iam.gserviceaccount.com",
} };

test "golden: an import topic's settings on create, for each source, and in an update, set whole and cleared" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kinesis_json =
        \\{"awsKinesis":{"streamArn":"arn:aws:kinesis:us-east-1:111111111111:stream/orders","consumerArn":"arn:aws:kinesis:us-east-1:111111111111:stream/orders/consumer/c:1","awsRoleArn":"arn:aws:iam::111111111111:role/pubsub","gcpServiceAccount":"importer@my-project.iam.gserviceaccount.com"}}
    ;
    try testing.expectEqualStrings(
        "{\"ingestionDataSourceSettings\":" ++ kinesis_json ++ "}",
        try encodeTopic(a, .{ .ingestion = .{ .source = kinesis } }),
    );

    // A bucket with nothing else said: text, a message a line. The format
    // is always sent, which an emulator requires, and no time and no glob.
    try testing.expectEqualStrings(
        \\{"ingestionDataSourceSettings":{"cloudStorage":{"bucket":"my-uploads","textFormat":{"delimiter":"\n"}}}}
    , try encodeTopic(a, .{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "my-uploads" } } } }));
    // Every option, beside other settings, with logs.
    try testing.expectEqualStrings(
        \\{"labels":{"env":"test"},"ingestionDataSourceSettings":{"cloudStorage":{"bucket":"my-uploads","textFormat":{"delimiter":"\t"},"minimumObjectCreateTime":"2026-10-12T02:33:53.500Z","matchGlob":"logs/**.txt"},"platformLogsSettings":{"severity":"WARNING"}}}
    , try encodeTopic(a, .{
        .labels = &.{.{ .key = "env", .value = "test" }},
        .ingestion = .{
            .source = .{ .cloud_storage = .{
                .bucket = "my-uploads",
                .format = .{ .text = .{ .delimiter = "\t" } },
                .minimum_object_create_time = try timestamp.parse("2026-10-12T02:33:53.5Z"),
                .match_glob = "logs/**.txt",
            } },
            .log_severity = .warning,
        },
    }));
    try testing.expectEqualStrings(
        \\{"ingestionDataSourceSettings":{"cloudStorage":{"bucket":"b","avroFormat":{}},"platformLogsSettings":{"severity":"DEBUG"}}}
    , try encodeTopic(a, .{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "b", .format = .avro } }, .log_severity = .debug } }));
    try testing.expectEqualStrings(
        \\{"ingestionDataSourceSettings":{"cloudStorage":{"bucket":"b","pubsubAvroFormat":{}},"platformLogsSettings":{"severity":"INFO"}}}
    , try encodeTopic(a, .{ .ingestion = .{ .source = .{ .cloud_storage = .{ .bucket = "b", .format = .pubsub_avro } }, .log_severity = .info } }));

    try testing.expectEqualStrings(
        \\{"ingestionDataSourceSettings":{"azureEventHubs":{"resourceGroup":"rg","namespace":"ns","eventHub":"eh","clientId":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","subscriptionId":"33333333-3333-3333-3333-333333333333","gcpServiceAccount":"importer@my-project.iam.gserviceaccount.com"},"platformLogsSettings":{"severity":"ERROR"}}}
    , try encodeTopic(a, .{ .ingestion = .{ .source = event_hubs, .log_severity = .@"error" } }));
    try testing.expectEqualStrings(
        \\{"ingestionDataSourceSettings":{"awsMsk":{"clusterArn":"arn:aws:kafka:us-east-1:111111111111:cluster/orders/abc","topic":"orders","awsRoleArn":"arn:aws:iam::111111111111:role/pubsub","gcpServiceAccount":"importer@my-project.iam.gserviceaccount.com"}}}
    , try encodeTopic(a, .{ .ingestion = .{ .source = msk } }));
    try testing.expectEqualStrings(
        \\{"ingestionDataSourceSettings":{"confluentCloud":{"bootstrapServer":"pkc-xxxx.us-east-1.aws.confluent.cloud:9092","clusterId":"lkc-xxxx","topic":"orders","identityPoolId":"pool-xxxx","gcpServiceAccount":"importer@my-project.iam.gserviceaccount.com"}}}
    , try encodeTopic(a, .{ .ingestion = .{ .source = confluent } }));
    // No logs is the default, and is left out; `.unknown` has no word, and
    // the checks refuse it before it is ever encoded.
    try testing.expectEqualStrings(
        "{\"ingestionDataSourceSettings\":" ++ kinesis_json ++ "}",
        try encodeTopic(a, .{ .ingestion = .{ .source = kinesis, .log_severity = .unknown } }),
    );

    // An update masks the settings whole and carries them; a clear is the
    // mask alone.
    try testing.expectEqualStrings(
        "{\"topic\":{\"ingestionDataSourceSettings\":" ++ kinesis_json ++ "},\"updateMask\":\"ingestionDataSourceSettings\"}",
        try encodeTopicUpdate(a, .{ .ingestion = .{ .set = .{ .source = kinesis } } }),
    );
    try testing.expectEqualStrings(
        "{\"topic\":{},\"updateMask\":\"ingestionDataSourceSettings\"}",
        try encodeTopicUpdate(a, .{ .ingestion = .clear }),
    );
    // Everything a topic update can name, at once.
    try testing.expectEqualStrings(
        "{\"topic\":{\"labels\":{},\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"avroFormat\":{}}}}," ++
            "\"updateMask\":\"labels,messageRetentionDuration,kmsKeyName,messageStoragePolicy,schemaSettings,messageTransforms,ingestionDataSourceSettings\"}",
        try encodeTopicUpdate(a, .{
            .labels = &.{},
            .message_retention = .clear,
            .kms_key_name = .clear,
            .message_storage_policy = .clear,
            .schema = .clear,
            .message_transforms = &.{},
            .ingestion = .{ .set = .{ .source = .{ .cloud_storage = .{ .bucket = "b", .format = .avro } } } },
        }),
    );
}

test "decode: an import topic's settings, each source as the emulator echoes it, each state, and what an answer may leave out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The emulator's answers, 2026-10-12. It sends no state.
    const k = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/zigps-x-cc470e-t25", "ingestionDataSourceSettings": { "awsKinesis": { "streamArn": "arn:aws:kinesis:us-east-1:111111111111:stream/zigps", "consumerArn": "arn:aws:kinesis:us-east-1:111111111111:stream/zigps/consumer/c:1", "awsRoleArn": "arn:aws:iam::111111111111:role/zigps", "gcpServiceAccount": "zig-gcp@test.iam.gserviceaccount.com" } } }
    )).ingestion.?;
    try testing.expectEqualStrings("arn:aws:kinesis:us-east-1:111111111111:stream/zigps", k.source.?.aws_kinesis.stream_arn);
    try testing.expectEqualStrings("arn:aws:kinesis:us-east-1:111111111111:stream/zigps/consumer/c:1", k.source.?.aws_kinesis.consumer_arn);
    try testing.expectEqualStrings("arn:aws:iam::111111111111:role/zigps", k.source.?.aws_kinesis.aws_role_arn);
    try testing.expectEqualStrings("zig-gcp@test.iam.gserviceaccount.com", k.source.?.aws_kinesis.gcp_service_account);
    try testing.expectEqual(types.Ingestion.LogSeverity.disabled, k.log_severity);
    try testing.expectEqual(types.IngestionState.unknown, k.state);

    const s = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/zigps-x-cc470e-t27", "ingestionDataSourceSettings": { "cloudStorage": { "bucket": "zigps-x-cc470e-no-such-bucket", "textFormat": { "delimiter": "\n" } } } }
    )).ingestion.?.source.?.cloud_storage;
    try testing.expectEqualStrings("zigps-x-cc470e-no-such-bucket", s.bucket);
    try testing.expectEqualStrings("\n", s.format.text.delimiter);
    try testing.expectEqual(null, s.minimum_object_create_time);
    try testing.expectEqualStrings("", s.match_glob);

    const e = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/zigps-x-cc470e-t33", "ingestionDataSourceSettings": { "azureEventHubs": { "resourceGroup": "rg", "namespace": "ns", "eventHub": "eh", "clientId": "11111111-1111-1111-1111-111111111111", "tenantId": "22222222-2222-2222-2222-222222222222", "subscriptionId": "33333333-3333-3333-3333-333333333333", "gcpServiceAccount": "zig-gcp@test.iam.gserviceaccount.com" } } }
    )).ingestion.?.source.?.azure_event_hubs;
    try testing.expectEqualStrings("rg", e.resource_group);
    try testing.expectEqualStrings("ns", e.namespace);
    try testing.expectEqualStrings("eh", e.event_hub);
    try testing.expectEqualStrings("11111111-1111-1111-1111-111111111111", e.client_id);
    try testing.expectEqualStrings("22222222-2222-2222-2222-222222222222", e.tenant_id);
    try testing.expectEqualStrings("33333333-3333-3333-3333-333333333333", e.subscription_id);
    try testing.expectEqualStrings("zig-gcp@test.iam.gserviceaccount.com", e.gcp_service_account);

    const m = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/zigps-x-cc470e-t34", "ingestionDataSourceSettings": { "awsMsk": { "clusterArn": "arn:aws:kafka:us-east-1:111111111111:cluster/zigps/abc", "topic": "t", "awsRoleArn": "arn:aws:iam::111111111111:role/zigps", "gcpServiceAccount": "zig-gcp@test.iam.gserviceaccount.com" } } }
    )).ingestion.?.source.?.aws_msk;
    try testing.expectEqualStrings("arn:aws:kafka:us-east-1:111111111111:cluster/zigps/abc", m.cluster_arn);
    try testing.expectEqualStrings("t", m.topic);
    try testing.expectEqualStrings("arn:aws:iam::111111111111:role/zigps", m.aws_role_arn);
    try testing.expectEqualStrings("zig-gcp@test.iam.gserviceaccount.com", m.gcp_service_account);

    const c = (try decodeTopic(a,
        \\{ "name": "projects/test/topics/zigps-x-cc470e-t35", "ingestionDataSourceSettings": { "confluentCloud": { "bootstrapServer": "pkc-xxxx.us-east-1.aws.confluent.cloud:9092", "clusterId": "lkc-xxxx", "topic": "t", "identityPoolId": "pool-xxxx", "gcpServiceAccount": "zig-gcp@test.iam.gserviceaccount.com" } } }
    )).ingestion.?.source.?.confluent_cloud;
    try testing.expectEqualStrings("pkc-xxxx.us-east-1.aws.confluent.cloud:9092", c.bootstrap_server);
    try testing.expectEqualStrings("lkc-xxxx", c.cluster_id);
    try testing.expectEqualStrings("t", c.topic);
    try testing.expectEqualStrings("pool-xxxx", c.identity_pool_id);
    try testing.expectEqualStrings("zig-gcp@test.iam.gserviceaccount.com", c.gcp_service_account);

    // A Cloud Storage source with every option, its state and its logs,
    // in the discovery document's shape.
    const full = (try decodeTopic(a,
        \\{"name":"projects/p/topics/t","state":"INGESTION_RESOURCE_ERROR","ingestionDataSourceSettings":{"cloudStorage":{"state":"CLOUD_STORAGE_PERMISSION_DENIED","bucket":"b","avroFormat":{},"minimumObjectCreateTime":"2026-10-12T02:33:53.500Z","matchGlob":"logs/**.avro"},"platformLogsSettings":{"severity":"WARNING"}}}
    ));
    try testing.expectEqual(types.TopicInfo.State.ingestion_resource_error, full.state);
    try testing.expectEqual(types.IngestionState.permission_denied, full.ingestion.?.state);
    try testing.expectEqual(types.Ingestion.LogSeverity.warning, full.ingestion.?.log_severity);
    try testing.expect(full.ingestion.?.source.?.cloud_storage.format == .avro);
    try testing.expectEqual(try timestamp.parse("2026-10-12T02:33:53.5Z"), full.ingestion.?.source.?.cloud_storage.minimum_object_create_time.?);
    try testing.expectEqualStrings("logs/**.avro", full.ingestion.?.source.?.cloud_storage.match_glob);
    try testing.expect((try decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"pubsubAvroFormat\":{}}}}")).ingestion.?.source.?.cloud_storage.format == .pubsub_avro);
    // No format, and a text format with no delimiter or an empty one, are
    // text split at newlines; another delimiter is kept.
    for ([_][]const u8{
        "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\"}}}",
        "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"textFormat\":{}}}}",
        "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"textFormat\":{\"delimiter\":\"\"}}}}",
    }) |body| {
        try testing.expectEqualStrings("\n", (try decodeTopic(a, body)).ingestion.?.source.?.cloud_storage.format.text.delimiter);
    }
    try testing.expectEqualStrings("|", (try decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"textFormat\":{\"delimiter\":\"|\"}}}}")).ingestion.?.source.?.cloud_storage.format.text.delimiter);
    try testing.expectEqual(null, (try decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"minimumObjectCreateTime\":\"\"}}}")).ingestion.?.source.?.cloud_storage.minimum_object_create_time);
    try testing.expectError(error.InvalidResponse, decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"cloudStorage\":{\"bucket\":\"b\",\"minimumObjectCreateTime\":\"yesterday\"}}}"));

    // Every state the discovery document names, under the source that can
    // say it; a word not yet known, the wire's unspecified and none at all
    // are `.unknown`.
    for ([_]struct { []const u8, []const u8, types.IngestionState }{
        .{ "awsKinesis", "ACTIVE", .active },
        .{ "awsKinesis", "KINESIS_PERMISSION_DENIED", .permission_denied },
        .{ "awsKinesis", "PUBLISH_PERMISSION_DENIED", .publish_permission_denied },
        .{ "awsKinesis", "STREAM_NOT_FOUND", .stream_not_found },
        .{ "awsKinesis", "CONSUMER_NOT_FOUND", .consumer_not_found },
        .{ "awsKinesis", "CONFLICTING_REGION_CONSTRAINTS", .conflicting_region_constraints },
        .{ "cloudStorage", "ACTIVE", .active },
        .{ "cloudStorage", "CLOUD_STORAGE_PERMISSION_DENIED", .permission_denied },
        .{ "cloudStorage", "PUBLISH_PERMISSION_DENIED", .publish_permission_denied },
        .{ "cloudStorage", "BUCKET_NOT_FOUND", .bucket_not_found },
        .{ "cloudStorage", "TOO_MANY_OBJECTS", .too_many_objects },
        .{ "azureEventHubs", "ACTIVE", .active },
        .{ "azureEventHubs", "EVENT_HUBS_PERMISSION_DENIED", .permission_denied },
        .{ "azureEventHubs", "NAMESPACE_NOT_FOUND", .namespace_not_found },
        .{ "azureEventHubs", "EVENT_HUB_NOT_FOUND", .event_hub_not_found },
        .{ "azureEventHubs", "SUBSCRIPTION_NOT_FOUND", .subscription_not_found },
        .{ "azureEventHubs", "RESOURCE_GROUP_NOT_FOUND", .resource_group_not_found },
        .{ "awsMsk", "ACTIVE", .active },
        .{ "awsMsk", "MSK_PERMISSION_DENIED", .permission_denied },
        .{ "awsMsk", "CLUSTER_NOT_FOUND", .cluster_not_found },
        .{ "awsMsk", "TOPIC_NOT_FOUND", .topic_not_found },
        .{ "confluentCloud", "ACTIVE", .active },
        .{ "confluentCloud", "CONFLUENT_CLOUD_PERMISSION_DENIED", .permission_denied },
        .{ "confluentCloud", "UNREACHABLE_BOOTSTRAP_SERVER", .unreachable_bootstrap_server },
        .{ "confluentCloud", "CLUSTER_NOT_FOUND", .cluster_not_found },
        .{ "confluentCloud", "TOPIC_NOT_FOUND", .topic_not_found },
        .{ "confluentCloud", "CONFLICTING_REGION_CONSTRAINTS", .conflicting_region_constraints },
        .{ "awsMsk", "STATE_UNSPECIFIED", .unknown },
        .{ "cloudStorage", "QUOTA_EXCEEDED", .unknown },
        .{ "awsKinesis", "active", .unknown },
    }) |case| {
        const source, const word, const want = case;
        const body = try std.fmt.allocPrint(a, "{{\"ingestionDataSourceSettings\":{{\"{s}\":{{\"state\":\"{s}\"}}}}}}", .{ source, word });
        const info = (try decodeTopic(a, body)).ingestion.?;
        try testing.expectEqual(want, info.state);
        try testing.expect(info.source != null);
    }

    // Each severity; none, and the wire's unspecified, are no logs.
    for ([_]struct { []const u8, types.Ingestion.LogSeverity }{
        .{ "DISABLED", .disabled }, .{ "SEVERITY_UNSPECIFIED", .disabled }, .{ "DEBUG", .debug },      .{ "INFO", .info },
        .{ "WARNING", .warning },   .{ "ERROR", .@"error" },                .{ "CRITICAL", .unknown }, .{ "", .unknown },
    }) |case| {
        const word, const want = case;
        const body = try std.fmt.allocPrint(a, "{{\"ingestionDataSourceSettings\":{{\"awsMsk\":{{}},\"platformLogsSettings\":{{\"severity\":\"{s}\"}}}}}}", .{word});
        try testing.expectEqual(want, (try decodeTopic(a, body)).ingestion.?.log_severity);
    }
    try testing.expectEqual(types.Ingestion.LogSeverity.disabled, (try decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"awsMsk\":{},\"platformLogsSettings\":{}}}")).ingestion.?.log_severity);

    // No settings and a null are a standard topic. Settings with a source
    // this client does not model are an import topic still, with its logs.
    try testing.expectEqual(null, (try decodeTopic(a, "{\"name\":\"projects/p/topics/t\"}")).ingestion);
    try testing.expectEqual(null, (try decodeTopic(a, "{\"ingestionDataSourceSettings\":null}")).ingestion);
    const newer = (try decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"someQueue\":{\"queue\":\"q\",\"state\":\"ACTIVE\"},\"platformLogsSettings\":{\"severity\":\"INFO\"}}}")).ingestion.?;
    try testing.expectEqual(null, newer.source);
    try testing.expectEqual(types.Ingestion.LogSeverity.info, newer.log_severity);
    try testing.expectEqual(types.IngestionState.unknown, newer.state);
    // A source with a part left out reads as "" there.
    try testing.expectEqualStrings("", (try decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"awsKinesis\":{}}}")).ingestion.?.source.?.aws_kinesis.stream_arn);
    try testing.expectError(error.InvalidResponse, decodeTopic(a, "{\"ingestionDataSourceSettings\":\"awsKinesis\"}"));
    try testing.expectError(error.InvalidResponse, decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"cloudStorage\":[]}}"));

    // Should an answer hold two sources, the first in the fixed order wins.
    const two = (try decodeTopic(a, "{\"ingestionDataSourceSettings\":{\"confluentCloud\":{\"topic\":\"c\"},\"awsMsk\":{\"topic\":\"m\"}}}")).ingestion.?;
    try testing.expectEqualStrings("m", two.source.?.aws_msk.topic);

    // In a list, each topic with its own.
    const page = try decodeTopicPage(a,
        \\{"topics":[{"name":"projects/p/topics/a"},{"name":"projects/p/topics/b","ingestionDataSourceSettings":{"cloudStorage":{"bucket":"b","state":"ACTIVE"}}}]}
    );
    try testing.expectEqual(null, page.topics[0].ingestion);
    try testing.expectEqual(types.IngestionState.active, page.topics[1].ingestion.?.state);
}

fn genText(g: *ByteGen, arena: Allocator, fallback: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, 24);
    const text = g.utf8(buf, 24);
    return if (text.len == 0) fallback else text;
}

fn genIngestion(g: *ByteGen, arena: Allocator) !types.Ingestion {
    const account = "importer@my-project.iam.gserviceaccount.com";
    const source: types.Ingestion.Source = switch (g.intRange(u8, 0, 4)) {
        0 => .{ .aws_kinesis = .{
            .stream_arn = try std.fmt.allocPrint(arena, "arn:{s}", .{try genText(g, arena, "s")}),
            .consumer_arn = try std.fmt.allocPrint(arena, "arn:{s}", .{try genText(g, arena, "c")}),
            .aws_role_arn = try std.fmt.allocPrint(arena, "arn:{s}", .{try genText(g, arena, "r")}),
            .gcp_service_account = account,
        } },
        1 => .{
            .cloud_storage = .{
                .bucket = g.pick([]const u8, &.{ "my-uploads", "gs://my-uploads", "b", "example.com", "b\u{e9}" }),
                .format = switch (g.intRange(u8, 0, 2)) {
                    0 => .{ .text = .{ .delimiter = try arena.dupe(u8, &.{g.intRange(u8, 0, 0x7f)}) } },
                    1 => .avro,
                    else => .pubsub_avro,
                },
                // Any time a timestamp can hold, to the nanosecond.
                .minimum_object_create_time = if (g.boolean())
                    .{ .nanoseconds = @as(i96, g.intRange(u64, 0, 253_402_300_799)) * std.time.ns_per_s + g.intRange(u32, 0, 999_999_999) }
                else
                    null,
                .match_glob = if (g.boolean()) try genText(g, arena, "**") else "",
            },
        },
        2 => .{ .azure_event_hubs = .{
            .resource_group = try genText(g, arena, "rg"),
            .namespace = try genText(g, arena, "ns"),
            .event_hub = try genText(g, arena, "eh"),
            .client_id = try genText(g, arena, "c"),
            .tenant_id = try genText(g, arena, "t"),
            .subscription_id = try genText(g, arena, "s"),
            .gcp_service_account = account,
        } },
        3 => .{ .aws_msk = .{
            .cluster_arn = try std.fmt.allocPrint(arena, "arn:{s}", .{try genText(g, arena, "k")}),
            .topic = try genText(g, arena, "t"),
            .aws_role_arn = try std.fmt.allocPrint(arena, "arn:{s}", .{try genText(g, arena, "r")}),
            .gcp_service_account = account,
        } },
        else => .{ .confluent_cloud = .{
            .bootstrap_server = try genText(g, arena, "host:9092"),
            .cluster_id = try genText(g, arena, "lkc"),
            .topic = try genText(g, arena, "t"),
            .identity_pool_id = try genText(g, arena, "pool"),
            .gcp_service_account = account,
        } },
    };
    return .{ .source = source, .log_severity = g.pick(types.Ingestion.LogSeverity, &.{ .disabled, .debug, .info, .warning, .@"error" }) };
}

/// Every field of two sources of one kind is the same, strings by their
/// bytes.
fn expectSourcesEqual(want: types.Ingestion.Source, have: types.Ingestion.Source) !void {
    try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(have));
    switch (want) {
        .cloud_storage => |w| {
            const h = have.cloud_storage;
            try testing.expectEqualStrings(w.bucket, h.bucket);
            try testing.expectEqual(std.meta.activeTag(w.format), std.meta.activeTag(h.format));
            if (w.format == .text) try testing.expectEqualStrings(w.format.text.delimiter, h.format.text.delimiter);
            try testing.expectEqual(w.minimum_object_create_time, h.minimum_object_create_time);
            try testing.expectEqualStrings(w.match_glob, h.match_glob);
        },
        inline else => |w, tag| {
            const h = @field(have, @tagName(tag));
            inline for (@typeInfo(@TypeOf(w)).@"struct".field_names) |name| {
                try testing.expectEqualStrings(@field(w, name), @field(h, name));
            }
        },
    }
}

fn ingestionRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = try genIngestion(&g, a);
    try @import("validate.zig").ingestion(settings, null);

    // What a create sends, a read gives back, with no state: that is the
    // server's to add.
    const created = (try decodeTopic(a, try encodeTopic(a, .{ .ingestion = settings }))).ingestion.?;
    try expectSourcesEqual(settings.source, created.source.?);
    try testing.expectEqual(settings.log_severity, created.log_severity);
    try testing.expectEqual(types.IngestionState.unknown, created.state);

    // An update names the settings in its mask exactly when it sets or
    // clears them, and carries them exactly when it sets them.
    const change: types.Change(types.Ingestion) = switch (g.intRange(u8, 0, 2)) {
        0 => .keep,
        1 => .clear,
        else => .{ .set = settings },
    };
    const with_labels = g.boolean();
    if (change == .keep and !with_labels) return;
    const update = try std.json.parseFromSliceLeaky(struct {
        topic: struct { ingestionDataSourceSettings: ?WireIngestion = null, labels: ?std.json.Value = null },
        updateMask: []const u8,
    }, a, try encodeTopicUpdate(a, .{ .labels = if (with_labels) &.{} else null, .ingestion = change }), .{});
    var named: usize = 0;
    var paths = std.mem.splitScalar(u8, update.updateMask, ',');
    while (paths.next()) |path| {
        if (std.mem.eql(u8, path, "ingestionDataSourceSettings")) named += 1;
    }
    try testing.expectEqual(@intFromBool(change != .keep), named);
    try testing.expectEqual(change == .set, update.topic.ingestionDataSourceSettings != null);
    if (change == .set) {
        const sent = (try ingestionFromWire(update.topic.ingestionDataSourceSettings)).?;
        try expectSourcesEqual(settings.source, sent.source.?);
        try testing.expectEqual(settings.log_severity, sent.log_severity);
    }
}

test "fuzz import topic settings: what a create sends a read gives back, and an update's mask names them exactly when it changes them" {
    try test_util.fuzzBytes({}, ingestionRoundTrip, .{
        .corpus = &.{
            "",
            "\x01",
            "\x02",
            "\x03",
            "\x04",
            // A bucket, text with a delimiter, a time and a glob, set in an update.
            "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x02\x41\x01\x00\x00\x00\x00\x6a\x0f\x2b\x11\x1d\xcd\x65\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x02\x01",
            "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    });
}
