//! The types of the public API: projects, their parents and states, pages
//! and lists, and the options of a search, a walk and a client's quota
//! project. Results come wrapped in core's `Owned`, re-exported here.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// One label of a project, as sent.
pub const Label = struct { key: []const u8, value: []const u8 };

/// A project's lifecycle state.
pub const State = enum {
    /// The server sent none: proto3 JSON leaves out a default.
    unspecified,
    active,
    /// Deleted, and kept for 30 days before it is gone.
    delete_requested,
    /// A name or number this version does not know. Never a failure.
    unknown,

    /// The state for a name, as the server spells it, or a number, as a
    /// client that asks for `enum-encoding=int` gets it.
    pub fn fromWire(name: []const u8) State {
        if (std.mem.eql(u8, name, "ACTIVE")) return .active;
        if (std.mem.eql(u8, name, "DELETE_REQUESTED")) return .delete_requested;
        if (std.mem.eql(u8, name, "STATE_UNSPECIFIED")) return .unspecified;
        return .unknown;
    }

    pub fn fromNumber(n: i64) State {
        return switch (n) {
            0 => .unspecified,
            1 => .active,
            2 => .delete_requested,
            else => .unknown,
        };
    }
};

/// Where a project sits: an organization or a folder.
pub const Parent = struct {
    kind: Kind,
    /// The id, digits as sent; for `.other`, the whole name.
    id: []const u8,
    /// As sent: "folders/876".
    name: []const u8,

    pub const Kind = enum {
        organization,
        folder,
        /// A parent of a type this version does not know, kept whole.
        other,
    };
};

/// A project, as `projects.search` and `projects.get` send it.
pub const Project = struct {
    /// The project number, which v3 carries only in `name`.
    number: u64,
    /// "projects/415104041262".
    name: []const u8,
    /// "payments-prod".
    project_id: []const u8,
    /// Null when the server sent none. Not unique between projects.
    display_name: ?[]const u8 = null,
    /// Null for a project at the top of its hierarchy, with no organization.
    parent: ?Parent = null,
    state: State = .unspecified,
    create_time: ?std.Io.Timestamp = null,
    /// Sent by `projects.get`; production's search leaves it out.
    update_time: ?std.Io.Timestamp = null,
    /// When deletion was asked for.
    delete_time: ?std.Io.Timestamp = null,
    /// In the order sent.
    labels: []const Label = &.{},
    etag: ?[]const u8 = null,

    /// The display name, or the project id when there is none: what a list
    /// shows a person.
    pub fn label(self: Project) []const u8 {
        return self.display_name orelse self.project_id;
    }
};

/// One page of a search. `items` may be empty while `next_page_token` is
/// set; only a null token ends a search.
pub fn Page(comptime T: type) type {
    return struct {
        /// In the server's order, which is unspecified.
        items: []const T,
        next_page_token: ?[]const u8 = null,
    };
}

pub const ProjectPage = Page(Project);

/// What a search sends with every page.
pub const SearchOptions = struct {
    /// The query language, sent as written: two terms side by side mean
    /// AND, and `AND`, `OR`, `NOT`, `-` and parentheses are read
    /// (docs/resource_manager/projects.md). Null or "" sends none, which
    /// finds every project the caller can see.
    query: ?[]const u8 = null,
    /// Projects a page; 0 lets the server choose. Production took any
    /// int32 when measured.
    page_size: u31 = 500,
};

/// How a walk reads a search to its end.
pub const WalkOptions = struct {
    query: ?[]const u8 = null,
    page_size: u31 = 500,
    /// The walk stops after this many pages and says `complete = false`.
    /// 100 pages of 500 is 50,000 projects; the console's own picker shows
    /// at most 4,000.
    max_pages: u32 = 100,
    /// The pause before each page after the first. The three searches share
    /// 4 calls a second and 240 a minute per charged project, documented,
    /// and every user of that project shares them. 0 sends pages back to
    /// back.
    page_interval_ms: u32 = 250,
    /// Projects pending deletion are left out, and counted, unless this is
    /// set. Production returned them to an empty search in 2023.
    include_pending_deletion: bool = false,
};

/// Every project a walk found.
pub const ProjectList = struct {
    /// Sorted by project id; each project number once.
    projects: []const Project,
    /// False when `max_pages` stopped the walk with pages left.
    complete: bool,
    pages: u32,
    /// Projects sent again on a later page, kept once.
    duplicates: u32,
    /// Projects pending deletion that were left out.
    pending_deletion: u32,
};

/// The project charged for a call's quota and checked for the API, sent as
/// `x-goog-user-project`, or none.
pub const QuotaProject = union(enum) {
    /// No header: the credential's own project is charged, a service
    /// account's, or for a person the OAuth client's (gcloud's ADC client
    /// is 764086051850). gcloud sends none for any project command.
    none,
    /// The credentials' quota project, `GOOGLE_CLOUD_QUOTA_PROJECT` or the
    /// ADC file's `quota_project_id`, as every other module sends it. A
    /// person whose quota project has the API off then gets
    /// `error.ServiceDisabled`.
    from_credentials,
    /// This project id or number.
    project: []const u8,
};

/// A refusal that names the project charged: the API off there, or a quota
/// project the caller may not use.
pub const ConsumerRefusal = struct {
    reason: Reason,
    /// "projects/706577269333", or the id as sent: "projects/my-project".
    consumer: []const u8,
    /// The page that turns the API on, or the project's IAM page, when the
    /// server sent one.
    link: ?[]const u8,

    pub const Reason = enum {
        /// `error.ServiceDisabled`.
        service_disabled,
        /// `error.QuotaProjectDenied`.
        quota_project_denied,
    };
};
