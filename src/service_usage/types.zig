//! Service Usage's values as this library holds them: a project's
//! services and whether each is enabled. Wire names live in the codec.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// Whether a service is enabled in the project.
pub const State = enum {
    enabled,
    disabled,
    /// `STATE_UNSPECIFIED`, none given, or a state this library does not
    /// know.
    unknown,

    pub fn fromWire(name: []const u8) State {
        if (std.mem.eql(u8, name, "ENABLED")) return .enabled;
        if (std.mem.eql(u8, name, "DISABLED")) return .disabled;
        return .unknown;
    }

    pub fn wireName(self: State) ?[]const u8 {
        return switch (self) {
            .enabled => "ENABLED",
            .disabled => "DISABLED",
            .unknown => null,
        };
    }
};

/// A service, as a list or a get answers it.
pub const Service = struct {
    /// The service's DNS name, such as `pubsub.googleapis.com`: what
    /// `getService` takes.
    name: []const u8,
    /// Its product title, such as "Cloud Pub/Sub API".
    title: []const u8 = "",
    /// What it does, in a sentence or two, as production gives it: empty
    /// for some (2 of 45 enabled ones when measured), and ending in a
    /// newline for others (13 of 45).
    summary: []const u8 = "",
    state: State = .unknown,
    /// The project, by number, whichever form the client was given:
    /// production names it so in every answer.
    project_number: []const u8 = "",
};

/// Which services `listServices` lists.
pub const StateFilter = enum {
    /// Those enabled in the project, the default.
    enabled,
    /// Those not enabled: every other public service, 12,973 when measured.
    disabled,
    /// Every public service, enabled or not, 13,018 when measured.
    any,

    /// The `filter` production takes; null lists every one.
    pub fn wire(self: StateFilter) ?[]const u8 {
        return switch (self) {
            .enabled => "state:ENABLED",
            .disabled => "state:DISABLED",
            .any => null,
        };
    }
};

pub const ListServicesOptions = struct {
    /// Enabled ones unless asked otherwise. Production has no "enabled
    /// first": every other list is all public services in name order,
    /// 66 pages of 200 when measured, past the quota of 60 such lists a
    /// minute.
    state: StateFilter = .enabled,
    /// 1 to 200; 0 is the server's own, 50 (the enabled list answered all
    /// of its 45 in one page when measured, so its own was not seen).
    page_size: u32 = 0,
    /// A page token a list with the same `state` answered.
    page_token: ?[]const u8 = null,
};

pub const ServicePage = struct {
    /// In name order, as production lists them.
    services: []const Service,
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};
