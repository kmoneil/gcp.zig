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

/// A folder, as `folders.search` sends it.
pub const Folder = struct {
    /// "folders/876".
    name: []const u8,
    /// The digits of `name`.
    id: []const u8,
    /// A folder or an organization. Null only if the server sent none.
    parent: ?Parent = null,
    /// Unique among a folder's siblings.
    display_name: ?[]const u8 = null,
    state: State = .unspecified,
    create_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    delete_time: ?std.Io.Timestamp = null,
    etag: ?[]const u8 = null,
};

/// An organization, as `organizations.search` sends it.
pub const Organization = struct {
    /// "organizations/123".
    name: []const u8,
    /// The digits of `name`.
    id: []const u8,
    /// Set by the server: the primary domain of the Workspace customer
    /// that owns it, such as "example.com".
    display_name: ?[]const u8 = null,
    directory_customer_id: ?[]const u8 = null,
    state: State = .unspecified,
    create_time: ?std.Io.Timestamp = null,
    update_time: ?std.Io.Timestamp = null,
    delete_time: ?std.Io.Timestamp = null,
    etag: ?[]const u8 = null,
};

pub const FolderPage = Page(Folder);
pub const OrganizationPage = Page(Organization);

/// How `Client.parentNames` reads its two searches.
pub const ParentOptions = struct {
    /// Folders or organizations a page; 0 lets the server choose.
    page_size: u31 = 500,
    /// Each search stops after this many pages, and the names say
    /// `complete = false`.
    max_pages: u32 = 100,
    /// The pause before each page after the first, across both searches,
    /// which share the project search's quota.
    page_interval_ms: u32 = 250,
};

/// Display text for the parents a caller can read: every folder and
/// organization its searches returned. A parent it cannot read stays its
/// name, as the console's "Inaccessible parent" does.
pub const ParentNames = struct {
    /// Sorted by name; each once.
    folders: []const Folder,
    /// Sorted by name; each once.
    organizations: []const Organization,
    /// False when `max_pages` stopped either search with pages left.
    complete: bool,
    pages: u32,

    /// The folder named `name`, if the caller can read it.
    pub fn folder(self: *const ParentNames, name: []const u8) ?*const Folder {
        return find(Folder, self.folders, name);
    }

    /// The organization named `name`, if the caller can read it.
    pub fn organization(self: *const ParentNames, name: []const u8) ?*const Organization {
        return find(Organization, self.organizations, name);
    }

    /// What to show for `parent`: its display name when the caller can read
    /// it, else its name as sent ("folders/876").
    pub fn label(self: *const ParentNames, parent: Parent) []const u8 {
        switch (parent.kind) {
            .folder => if (self.folder(parent.name)) |f| if (f.display_name) |d| return d,
            .organization => if (self.organization(parent.name)) |o| if (o.display_name) |d| return d,
            .other => {},
        }
        return parent.name;
    }

    /// The labels from `parent` up to its organization, nearest first, as
    /// far as the caller can read: the first parent it cannot read ends the
    /// path with its name. At most 16, as folders nest at most ten deep.
    pub fn path(self: *const ParentNames, gpa: std.mem.Allocator, parent: Parent) std.mem.Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        var at: ?Parent = parent;
        while (at) |p| {
            if (out.items.len == max_path) break;
            try out.append(gpa, self.label(p));
            at = if (p.kind == .folder) if (self.folder(p.name)) |f| f.parent else null else null;
        }
        return out.toOwnedSlice(gpa);
    }

    pub const max_path = 16;

    fn find(comptime T: type, items: []const T, name: []const u8) ?*const T {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, items[mid].name, name)) {
                .eq => return &items[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};
