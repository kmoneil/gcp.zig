//! Cloud Run's values as this library holds them: services, revisions,
//! their conditions and traffic, and the locations they live in. Wire
//! names live in the codec. The schemas are large; these types keep what
//! a health view and a deploy marker need, plus what identifies trouble,
//! and the decode skips the rest.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// A condition's state, as the server holds it.
pub const ConditionState = enum {
    unspecified,
    pending,
    reconciling,
    failed,
    succeeded,
    /// A state this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) ConditionState {
        inline for (.{
            .{ "CONDITION_SUCCEEDED", .succeeded },
            .{ "CONDITION_FAILED", .failed },
            .{ "CONDITION_PENDING", .pending },
            .{ "CONDITION_RECONCILING", .reconciling },
            .{ "STATE_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

pub const ConditionSeverity = enum {
    unspecified,
    @"error",
    warning,
    info,
    /// A severity this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) ConditionSeverity {
        inline for (.{
            .{ "ERROR", .@"error" },
            .{ "WARNING", .warning },
            .{ "INFO", .info },
            .{ "SEVERITY_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// One condition of a service or revision, such as `Ready`.
pub const Condition = struct {
    type: []const u8 = "",
    state: ConditionState = .unknown,
    message: []const u8 = "",
    /// The wire's one-of reasons (`reason`, `revisionReason`,
    /// `executionReason`, `instanceReason`) collapsed to whichever came:
    /// production sent `reason: REVISION_FAILED` for a failed deploy.
    reason: []const u8 = "",
    severity: ConditionSeverity = .unspecified,
    last_transition_time: ?std.Io.Timestamp = null,

    pub fn succeeded(self: Condition) bool {
        return self.state == .succeeded;
    }
};

pub const TrafficType = enum {
    unspecified,
    latest,
    revision,
    /// A type this library does not know, read back from the server.
    unknown,

    pub fn fromWire(name: []const u8) TrafficType {
        inline for (.{
            .{ "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", .latest },
            .{ "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", .revision },
            .{ "TRAFFIC_TARGET_ALLOCATION_TYPE_UNSPECIFIED", .unspecified },
        }) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

/// Where traffic is asked to go (`traffic`), or where the server says it
/// goes (`traffic_statuses`, which adds `uri`).
pub const TrafficTarget = struct {
    type: TrafficType = .unspecified,
    /// A revision id; empty for `.latest`.
    revision: []const u8 = "",
    percent: i64 = 0,
    tag: []const u8 = "",
    /// Only on `traffic_statuses`, and only for a tagged target.
    uri: []const u8 = "",
};

/// One container of a revision: what a deploy marker names.
pub const Container = struct {
    name: []const u8 = "",
    /// Production answers it pinned to its digest, not the tag deployed.
    image: []const u8 = "",
};

pub const Service = struct {
    /// `projects/P/locations/L/services/S`.
    name: []const u8,
    /// The trailing segment of `name`.
    id: []const u8,
    /// The `L` segment of `name`.
    location: []const u8,
    description: []const u8 = "",
    /// The main URI; `urls` holds every form.
    uri: []const u8 = "",
    urls: []const []const u8 = &.{},
    /// Revision ids (the trailing segment, as the console shows them).
    latest_ready_revision: []const u8 = "",
    latest_created_revision: []const u8 = "",
    traffic: []const TrafficTarget = &.{},
    traffic_statuses: []const TrafficTarget = &.{},
    /// The service's own summary condition, `Ready` when healthy.
    terminal_condition: ?Condition = null,
    conditions: []const Condition = &.{},
    create_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    creator: []const u8 = "",
    last_modifier: []const u8 = "",
    generation: ?i64 = null,
    observed_generation: ?i64 = null,
    /// The server is still working towards the asked state.
    reconciling: bool = false,
    labels: []const Label = &.{},

    /// Whether the service's terminal condition succeeded.
    pub fn ready(self: Service) bool {
        const terminal = self.terminal_condition orelse return false;
        return terminal.succeeded();
    }
};

pub const Revision = struct {
    /// `projects/P/locations/L/services/S/revisions/R`.
    name: []const u8,
    /// The trailing segment: `<service>-0000N-<suffix>`, as production
    /// names them.
    id: []const u8,
    /// The service's id, as the wire sends it.
    service: []const u8,
    /// The `L` segment of `name`.
    location: []const u8,
    /// The deploy marker.
    create_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    generation: ?i64 = null,
    containers: []const Container = &.{},
    conditions: []const Condition = &.{},
    /// A console link to the revision's logs.
    log_uri: []const u8 = "",
    service_account: []const u8 = "",
    labels: []const Label = &.{},

    /// The `Ready` condition, or null when the answer carried none.
    pub fn readyCondition(self: Revision) ?Condition {
        for (self.conditions) |condition| {
            if (std.mem.eql(u8, condition.type, "Ready")) return condition;
        }
        return null;
    }

    /// Whether the `Ready` condition succeeded.
    pub fn ready(self: Revision) bool {
        const condition = self.readyCondition() orelse return false;
        return condition.succeeded();
    }
};

pub const ListOptions = struct {
    /// 0 for the server's default.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

pub const ServicePage = struct {
    services: []const Service,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
    /// On a `-` location, the regions the server could not ask.
    unreachable_regions: []const []const u8 = &.{},
};

pub const RevisionPage = struct {
    revisions: []const Revision,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const Location = struct {
    /// `projects/P/locations/L`.
    name: []const u8,
    /// The trailing segment: `us-central1`.
    id: []const u8,
    display_name: []const u8 = "",
    labels: []const Label = &.{},
};

pub const LocationPage = struct {
    locations: []const Location,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

const testing = std.testing;

test "enum wires both ways, unknown for the rest" {
    try testing.expectEqual(ConditionState.succeeded, ConditionState.fromWire("CONDITION_SUCCEEDED"));
    try testing.expectEqual(ConditionState.failed, ConditionState.fromWire("CONDITION_FAILED"));
    try testing.expectEqual(ConditionState.pending, ConditionState.fromWire("CONDITION_PENDING"));
    try testing.expectEqual(ConditionState.reconciling, ConditionState.fromWire("CONDITION_RECONCILING"));
    try testing.expectEqual(ConditionState.unspecified, ConditionState.fromWire("STATE_UNSPECIFIED"));
    try testing.expectEqual(ConditionState.unknown, ConditionState.fromWire("CONDITION_MOODY"));
    try testing.expectEqual(ConditionSeverity.@"error", ConditionSeverity.fromWire("ERROR"));
    try testing.expectEqual(ConditionSeverity.info, ConditionSeverity.fromWire("INFO"));
    try testing.expectEqual(ConditionSeverity.unknown, ConditionSeverity.fromWire("FATAL"));
    try testing.expectEqual(TrafficType.latest, TrafficType.fromWire("TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"));
    try testing.expectEqual(TrafficType.revision, TrafficType.fromWire("TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"));
    try testing.expectEqual(TrafficType.unknown, TrafficType.fromWire("SPLIT"));
}

test "Service.ready and Revision.ready answer the widget's question" {
    var service: Service = .{ .name = "projects/p/locations/l/services/s", .id = "s", .location = "l" };
    try testing.expect(!service.ready());
    service.terminal_condition = .{ .type = "Ready", .state = .succeeded };
    try testing.expect(service.ready());
    service.terminal_condition = .{ .type = "Ready", .state = .failed, .reason = "REVISION_FAILED" };
    try testing.expect(!service.ready());

    var revision: Revision = .{ .name = "projects/p/locations/l/services/s/revisions/r", .id = "r", .service = "s", .location = "l" };
    try testing.expect(!revision.ready());
    try testing.expectEqual(null, revision.readyCondition());
    revision.conditions = &.{
        .{ .type = "Active", .state = .succeeded, .severity = .info },
        .{ .type = "Ready", .state = .succeeded, .message = "Deploying revision succeeded in 3.77s." },
    };
    try testing.expect(revision.ready());
    try testing.expectEqualStrings("Deploying revision succeeded in 3.77s.", revision.readyCondition().?.message);
    revision.conditions = &.{.{ .type = "Ready", .state = .failed, .message = "Image not found." }};
    try testing.expect(!revision.ready());
}
