//! A Cloud Resource Manager for tests, behind the `Transport` seam:
//! projects a test adds, searched and read as production answered when
//! measured on 2026-10-17 (milestone 0 of the Resource Manager spec,
//! `_tmp/rm-m0/`; the answers are kept verbatim in `production_bodies.zig`,
//! and a test holds this fake's refusals to them word for word). It parses
//! requests with code of its own, so a request this library builds wrong is
//! refused here as production would refuse it. Test code only.
//!
//! What it models:
//!
//! - Callers: each bearer token is a principal a test adds, with the
//!   project it is charged to when it sends no quota project (a service
//!   account's own, or a person's OAuth client's). A token it does not know
//!   is production's 401, and so is no token.
//! - Visibility: a principal sees a project granted to it, or under a
//!   folder or organization granted to it, as `resourcemanager.projects.get`
//!   is inherited. A public project is readable by every caller through
//!   `projects.get` and searched by none but its grantees, as production
//!   read `bigquery-public-data` for the probe and never listed it.
//! - The charged project: the `x-goog-user-project` header when sent, by id
//!   or number, else the principal's own. A header naming a project that
//!   does not exist is production's 400, one the principal may not use its
//!   403, both `USER_PROJECT_DENIED`; a charged project with the API off
//!   is `SERVICE_DISABLED`, in the words of pgAdmin's report of 2025.
//! - The search quota: 240 searches a minute per charged project, the
//!   documented figure, in fixed minutes. The documented 4 a second is not
//!   enforced: production served ten in 205 ms. The 429 follows the shape
//!   of a 2024 Resource Manager 429; its metric and limit names come from
//!   the limits page, since production's for v3 search were not seen.
//! - Order: one order for every search, as production listed two projects
//!   the same way on every walk and at every page size. By default a hash
//!   of each number, which nothing can sort by; `.by_number` lists as
//!   production did.
//! - Paging: the default and largest page sizes are options, since two
//!   visible projects could not show production's. A token is a position
//!   in the order, as production's was: it goes on from there with another
//!   page size, and with another query, applied from there, and gives the
//!   same page each time it is sent. One it did not issue is production's
//!   400.
//! - Eventual consistency: a change shows in `projects.get` at once and in
//!   search after `search_lag_ns`.
//! - The query language, by `fake_query.zig`'s reading of it.
//! - Faults on searches: refusals with any status, dropped connections,
//!   empty pages that go on, and short pages.
//!
//! Not modelled, each answered 501 with the reason: a token past its
//! lifetime (production's still worked after 65 s), or from another kind
//! of search, what `fake_query.zig` does not read, the quota of
//! `projects.get`, and every other call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;
const codec = @import("codec.zig");
const fake_query = @import("fake_query.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const FakeResourceManager = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Holds everything a test adds, and every search's listing, until
    /// `deinit`.
    store: std.heap.ArenaAllocator,
    projects: std.ArrayList(*Stored) = .empty,
    /// By name ("folders/7"), in the order added. In `store`.
    folders: std.StringArrayHashMapUnmanaged(*StoredFolder) = .empty,
    /// By name ("organizations/3"), in the order added. In `store`.
    organizations: std.StringArrayHashMapUnmanaged(*StoredOrganization) = .empty,
    /// By bearer token. In `store`.
    principals: std.StringHashMapUnmanaged(*Principal) = .empty,
    /// Searches by charged project, in the current minute.
    quota: std.StringHashMapUnmanaged(Window) = .empty,
    faults: [4]Fault = @splat(.{}),
    search_calls: usize = 0,
    get_calls: usize = 0,
    /// Makes every token issued its own, as an empty page's is a new one.
    tokens_issued: u64 = 0,

    pub const Options = struct {
        /// Projects a page when a search names no size, or 0. Production's
        /// default could not be seen with one visible project.
        default_page_size: u32 = 500,
        /// A larger size is served this many.
        max_page_size: u32 = 1000,
        /// How long after a change search shows it.
        search_lag_ns: i96 = 0,
        /// How long a token stays good. Production's still worked after 65
        /// s; how much longer was not measured.
        token_lifetime_ns: i96 = std.time.ns_per_hour,
        /// Searches a minute per charged project, shared by every caller
        /// charged to it. 0 counts none.
        searches_per_minute: u32 = 240,
        /// The one order every search lists in.
        order: Order = .seeded,
        /// The seeded order's seed.
        seed: u64 = 0x5eed,
    };

    /// The order searches list in. Production promises none, and listed
    /// two projects in the same order on every walk and at every page
    /// size, which was project number order (and project id order too).
    pub const Order = enum {
        /// Stable, but no order an app could sort by: a hash of each
        /// number, so that nothing comes to depend on one.
        seeded,
        /// By number, as production listed two projects.
        by_number,
    };

    /// A project as a test adds it.
    pub const Project = struct {
        number: u64,
        /// Production's rule for new ones: 6 to 30 lowercase letters,
        /// digits and hyphens, starting with a letter.
        project_id: []const u8,
        display_name: ?[]const u8 = null,
        /// "folders/7" or "organizations/3"; null for none.
        parent: ?[]const u8 = null,
        state: types.State = .active,
        labels: []const types.Label = &.{},
        /// Readable by every caller through `projects.get`, and searched
        /// by its grantees alone.
        public: bool = false,
        /// Whether the Resource Manager API is on, for calls charged here.
        api_enabled: bool = true,
    };

    const Version = struct {
        display_name: ?[]const u8,
        parent: ?[]const u8,
        state: types.State,
        labels: []const types.Label,
        update_ns: i96,
        delete_ns: ?i96,
        /// Gone for good: neither get nor search finds it.
        purged: bool = false,
        serial: u32,
    };

    const Stored = struct {
        number: u64,
        project_id: []const u8,
        create_ns: i96,
        public: bool,
        api_enabled: bool,
        current: Version,
        /// What search shows; null until it first shows the project.
        searched: ?Version = null,
        /// What search shows from `pending_at` on.
        pending: ?Version = null,
        pending_at: i96 = 0,
    };

    const Principal = struct {
        /// The project id charged when the caller names none.
        home: []const u8,
        /// Project ids and numbers, folder and organization names.
        grants: std.StringHashMapUnmanaged(void) = .empty,
        /// Project ids the caller may name as its quota project.
        quota_use: std.StringHashMapUnmanaged(void) = .empty,
    };

    /// What a search lists.
    const Kind = enum { project, folder, organization };

    /// A folder as a test adds it.
    pub const Folder = struct {
        /// "folders/N".
        name: []const u8,
        /// "folders/N" or "organizations/N".
        parent: []const u8,
        display_name: ?[]const u8 = null,
        state: types.State = .active,
    };

    /// An organization as a test adds it.
    pub const Organization = struct {
        /// "organizations/N".
        name: []const u8,
        /// Its primary domain, which production gives as its display name.
        domain: []const u8,
        directory_customer_id: ?[]const u8 = null,
        state: types.State = .active,
    };

    const StoredFolder = struct {
        name: []const u8,
        parent: []const u8,
        display_name: ?[]const u8,
        state: types.State,
        create_ns: i96,
    };

    const StoredOrganization = struct {
        name: []const u8,
        domain: []const u8,
        directory_customer_id: ?[]const u8,
        state: types.State,
        create_ns: i96,
    };

    /// One item a search found: its place in the order, and its JSON.
    const Item = struct { rank: u128, json: []const u8 };

    const Window = struct { minute: i96, count: u32 };

    const Fault = struct { n: usize = 0, status: u16 = 0, max: usize = 0 };
    const refuse = 0;
    const drop = 1;
    const empty = 2;
    const short = 3;

    pub const Reply = struct { status: u16, body: []const u8 };

    pub const WriteError = error{ OutOfMemory, InvalidEntry };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeResourceManager {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeResourceManager) void {
        f.projects.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeResourceManager) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    fn now(f: *const FakeResourceManager) i96 {
        return std.Io.Clock.real.now(f.io).nanoseconds;
    }

    /// Adds a project, created now. `error.InvalidEntry` for a number or
    /// id there already, an id or parent production would not have, or a
    /// label key used twice.
    pub fn addProject(f: *FakeResourceManager, p: Project) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        if (!validate.isProjectRef(p.project_id) or validate.isNumber(p.project_id)) return error.InvalidEntry;
        if (p.parent) |parent| if (!isParentName(parent)) return error.InvalidEntry;
        for (p.labels, 0..) |l, i| for (p.labels[0..i]) |m| if (std.mem.eql(u8, l.key, m.key)) return error.InvalidEntry;
        if (f.byNumber(p.number) != null or f.byId(p.project_id) != null) return error.InvalidEntry;
        const t = f.now();
        const stored = try a.create(Stored);
        stored.* = .{
            .number = p.number,
            .project_id = try a.dupe(u8, p.project_id),
            .create_ns = t,
            .public = p.public,
            .api_enabled = p.api_enabled,
            .current = .{
                .display_name = if (p.display_name) |d| try a.dupe(u8, d) else null,
                .parent = if (p.parent) |d| try a.dupe(u8, d) else null,
                .state = p.state,
                .labels = try dupeLabels(a, p.labels),
                .update_ns = t,
                .delete_ns = if (p.state == .delete_requested) t else null,
                .serial = 1,
            },
        };
        try f.projects.append(f.gpa, stored);
        f.changed(stored);
    }

    /// Adds a folder, which passes grants down to what is under it and
    /// which a caller granted on it or above it reads in a folder search.
    /// `error.InvalidEntry` for a name production would not have, or one
    /// there already.
    pub fn addFolder(f: *FakeResourceManager, folder: Folder) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        if (!std.mem.startsWith(u8, folder.name, "folders/") or !isParentName(folder.name) or !isParentName(folder.parent)) return error.InvalidEntry;
        if (f.folders.contains(folder.name)) return error.InvalidEntry;
        const stored = try a.create(StoredFolder);
        stored.* = .{
            .name = try a.dupe(u8, folder.name),
            .parent = try a.dupe(u8, folder.parent),
            .display_name = if (folder.display_name) |d| try a.dupe(u8, d) else null,
            .state = folder.state,
            .create_ns = f.now(),
        };
        try f.folders.put(a, stored.name, stored);
    }

    /// Adds an organization, which a caller granted on it reads in an
    /// organization search. `error.InvalidEntry` for a name production
    /// would not have, or one there already.
    pub fn addOrganization(f: *FakeResourceManager, org: Organization) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        if (!std.mem.startsWith(u8, org.name, "organizations/") or !isParentName(org.name)) return error.InvalidEntry;
        if (f.organizations.contains(org.name)) return error.InvalidEntry;
        const stored = try a.create(StoredOrganization);
        stored.* = .{
            .name = try a.dupe(u8, org.name),
            .domain = try a.dupe(u8, org.domain),
            .directory_customer_id = if (org.directory_customer_id) |d| try a.dupe(u8, d) else null,
            .state = org.state,
            .create_ns = f.now(),
        };
        try f.organizations.put(a, stored.name, stored);
    }

    /// Adds a caller, by its bearer token, charged to `home` (a project
    /// id) when it names no quota project.
    pub fn addPrincipal(f: *FakeResourceManager, token: []const u8, home: []const u8) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        if (f.principals.contains(token)) return error.InvalidEntry;
        const p = try a.create(Principal);
        p.* = .{ .home = try a.dupe(u8, home) };
        try f.principals.put(a, try a.dupe(u8, token), p);
    }

    /// Grants `resourcemanager.projects.get` on `resource` to the caller
    /// with `token`: a project id or number, or a folder or organization
    /// name, which passes it to everything under it.
    pub fn grant(f: *FakeResourceManager, token: []const u8, resource: []const u8) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        const p = f.principals.get(token) orelse return error.InvalidEntry;
        try p.grants.put(a, try a.dupe(u8, resource), {});
    }

    /// Lets the caller with `token` name `project_id` as its quota project,
    /// as `serviceusage.services.use` does. Its own project needs none.
    pub fn allowQuotaUse(f: *FakeResourceManager, token: []const u8, project_id: []const u8) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        const p = f.principals.get(token) orelse return error.InvalidEntry;
        try p.quota_use.put(a, try a.dupe(u8, project_id), {});
    }

    /// Turns the Resource Manager API on or off for calls charged to
    /// `project_id`.
    pub fn setApiEnabled(f: *FakeResourceManager, project_id: []const u8, enabled: bool) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const s = f.byId(project_id) orelse return error.InvalidEntry;
        s.api_enabled = enabled;
    }

    /// A change to a project, seen by get now and by search after the lag.
    pub const Change = union(enum) {
        display_name: ?[]const u8,
        parent: ?[]const u8,
        state: types.State,
        labels: []const types.Label,
        /// Gone for good, as a project is 30 days after deletion.
        purge,
    };

    pub fn change(f: *FakeResourceManager, project_id: []const u8, c: Change) WriteError!void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const a = f.store.allocator();
        const s = f.byId(project_id) orelse return error.InvalidEntry;
        var v = s.current;
        if (v.purged) return error.InvalidEntry;
        switch (c) {
            .display_name => |d| v.display_name = if (d) |x| try a.dupe(u8, x) else null,
            .parent => |p| {
                if (p) |x| if (!isParentName(x)) return error.InvalidEntry;
                v.parent = if (p) |x| try a.dupe(u8, x) else null;
            },
            .state => |st| {
                v.state = st;
                v.delete_ns = if (st == .delete_requested) f.now() else null;
            },
            .labels => |l| v.labels = try dupeLabels(a, l),
            .purge => v.purged = true,
        }
        v.update_ns = f.now();
        v.serial += 1;
        s.current = v;
        f.changed(s);
    }

    fn changed(f: *FakeResourceManager, s: *Stored) void {
        f.promote(s);
        if (f.options.search_lag_ns <= 0) {
            s.searched = s.current;
            s.pending = null;
        } else {
            s.pending = s.current;
            s.pending_at = f.now() + f.options.search_lag_ns;
        }
    }

    fn promote(f: *const FakeResourceManager, s: *Stored) void {
        if (s.pending) |p| if (f.now() >= s.pending_at) {
            s.searched = p;
            s.pending = null;
        };
    }

    fn byNumber(f: *const FakeResourceManager, number: u64) ?*Stored {
        for (f.projects.items) |s| if (s.number == number) return s;
        return null;
    }

    fn byId(f: *const FakeResourceManager, id: []const u8) ?*Stored {
        for (f.projects.items) |s| if (std.mem.eql(u8, s.project_id, id)) return s;
        return null;
    }

    /// A project by id or number, as a path or a header names it.
    fn byRef(f: *const FakeResourceManager, ref: []const u8) ?*Stored {
        if (validate.isNumber(ref)) return f.byNumber(std.fmt.parseInt(u64, ref, 10) catch return null);
        return f.byId(ref);
    }

    fn dupeLabels(a: Allocator, labels: []const types.Label) Allocator.Error![]const types.Label {
        const out = try a.alloc(types.Label, labels.len);
        for (labels, out) |l, *o| o.* = .{ .key = try a.dupe(u8, l.key), .value = try a.dupe(u8, l.value) };
        return out;
    }

    /// Whether `principal` holds `projects.get` on the project with
    /// `parent`: on the project itself, or anywhere above it.
    fn sees(f: *const FakeResourceManager, principal: *const Principal, s: *const Stored, parent: ?[]const u8) bool {
        if (principal.grants.contains(s.project_id)) return true;
        var buf: [20]u8 = undefined;
        if (principal.grants.contains(std.fmt.bufPrint(&buf, "{d}", .{s.number}) catch unreachable)) return true;
        return f.seesFrom(principal, parent);
    }

    /// Whether `principal` holds a grant on `name` or anywhere above it.
    fn seesFrom(f: *const FakeResourceManager, principal: *const Principal, name: ?[]const u8) bool {
        var at = name;
        var depth: usize = 0;
        while (at) |n| : (depth += 1) {
            if (depth > 64) return false;
            if (principal.grants.contains(n)) return true;
            at = if (f.folders.get(n)) |folder| folder.parent else null;
        }
        return false;
    }

    // Faults, each for the next `n` searches.

    /// Answers them with `status` and production's words for it.
    pub fn refuseNext(f: *FakeResourceManager, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeResourceManager, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Answers them with no projects and a token that goes on from where
    /// they were.
    pub fn emptyNext(f: *FakeResourceManager, n: usize) void {
        f.setFault(empty, .{ .n = n });
    }

    /// Answers them with at most `max` projects, and a token when more wait.
    pub fn shortenNext(f: *FakeResourceManager, n: usize, max: usize) void {
        f.setFault(short, .{ .n = n, .max = max });
    }

    fn setFault(f: *FakeResourceManager, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeResourceManager, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    /// Searches served, faults and refusals included.
    pub fn searchCalls(f: *FakeResourceManager) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.search_calls;
    }

    /// Gets served, refusals included.
    pub fn getCalls(f: *FakeResourceManager) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.get_calls;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeResourceManager = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeResourceManager, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        inline for (.{ .{ "/v3/projects:search", Kind.project }, .{ "/v3/folders:search", Kind.folder }, .{ "/v3/organizations:search", Kind.organization } }) |r| {
            if (req.method == .GET and std.mem.eql(u8, route, r[0])) {
                f.search_calls += 1;
                if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
                if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);
                return f.search(arena, req, query, r[1]);
            }
        }
        if (req.method == .GET and std.mem.startsWith(u8, route, "/v3/projects/")) {
            f.get_calls += 1;
            return f.get(arena, req, route["/v3/projects/".len..], query);
        }
        return notModelled(arena, "this call");
    }

    const Caller = union(enum) {
        principal: *Principal,
        refused: Reply,
    };

    fn caller(f: *FakeResourceManager, arena: Allocator, req: tp.Request, method: []const u8) Allocator.Error!Caller {
        const bearer = req.bearer orelse return .{ .refused = try failInfo(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.", "CREDENTIALS_MISSING", "googleapis.com", &.{
            .{ "method", method },
            .{ "service", service },
        }) };
        const p = f.principals.get(bearer) orelse return .{ .refused = try failInfo(arena, 401, "UNAUTHENTICATED", "Request had invalid authentication credentials. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.", "ACCESS_TOKEN_TYPE_UNSUPPORTED", null, &.{
            .{ "method", method },
            .{ "service", service },
        }) };
        return .{ .principal = p };
    }

    const Charged = union(enum) {
        /// The charged project, by number when the fake has it.
        key: []const u8,
        refused: Reply,
    };

    /// The project charged for a call, or production's refusal of it.
    fn charged(f: *FakeResourceManager, arena: Allocator, req: tp.Request, principal: *const Principal) Allocator.Error!Charged {
        const header = headerOf(req, "x-goog-user-project");
        const name = header orelse principal.home;
        const s = f.byRef(name);
        if (header) |h| {
            const project = s orelse return .{ .refused = try failInfo(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Project 'projects/{s}' not found or deleted.", .{h}), "USER_PROJECT_DENIED", "googleapis.com", &.{
                .{ "containerInfo", try std.fmt.allocPrint(arena, "projects/{s}", .{h}) },
                .{ "service", service },
                .{ "consumer", try std.fmt.allocPrint(arena, "projects/{s}", .{h}) },
            }) };
            const own = std.mem.eql(u8, project.project_id, principal.home);
            if (!own and !principal.quota_use.contains(project.project_id)) {
                const console = try std.fmt.allocPrint(arena, "https://console.developers.google.com/iam-admin/iam?project={s}", .{h});
                const message = try std.fmt.allocPrint(arena, "Caller does not have required permission to use project {s}. Grant the caller the roles/serviceusage.serviceUsageConsumer role, or a custom role with the serviceusage.services.use permission, by visiting {s} and then retry. Propagation of the new permission may take a few minutes.", .{ h, console });
                return .{ .refused = try failConsumer(arena, 403, message, "USER_PROJECT_DENIED", &.{
                    .{ "consoleUrl", console },
                    .{ "containerInfo", h },
                    .{ "service", service },
                    .{ "consumer", try std.fmt.allocPrint(arena, "projects/{s}", .{h}) },
                }, "Google developer console IAM admin", console) };
            }
        }
        const project = s orelse return .{ .key = name };
        if (!project.api_enabled) {
            const number = try std.fmt.allocPrint(arena, "{d}", .{project.number});
            const activation = try std.fmt.allocPrint(arena, "https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project={s}", .{number});
            const message = try std.fmt.allocPrint(arena, "Cloud Resource Manager API has not been used in project {s} before or it is disabled. Enable it by visiting {s} then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.", .{ number, activation });
            return .{ .refused = try failConsumer(arena, 403, message, "SERVICE_DISABLED", &.{
                .{ "activationUrl", activation },
                .{ "serviceTitle", "Cloud Resource Manager API" },
                .{ "containerInfo", number },
                .{ "service", service },
                .{ "consumer", try std.fmt.allocPrint(arena, "projects/{s}", .{number}) },
            }, "Google developers console API activation", activation) };
        }
        return .{ .key = try std.fmt.allocPrint(arena, "{d}", .{project.number}) };
    }

    fn searchMethod(kind: Kind) []const u8 {
        return switch (kind) {
            .project => "google.cloud.resourcemanager.v3.Projects.SearchProjects",
            .folder => "google.cloud.resourcemanager.v3.Folders.SearchFolders",
            .organization => "google.cloud.resourcemanager.v3.Organizations.SearchOrganizations",
        };
    }
    const get_method = "google.cloud.resourcemanager.v3.Projects.GetProject";
    const service = "cloudresourcemanager.googleapis.com";

    fn search(f: *FakeResourceManager, arena: Allocator, req: tp.Request, query: []const u8, kind: Kind) Allocator.Error!Reply {
        const params = try parseParams(arena, query) orelse return notModelled(arena, "a query string this fake cannot read");
        for (params) |p| {
            if (!isOneOf(p.name, &.{ "query", "pageSize", "pageToken", "prettyPrint" })) return notModelled(arena, try std.fmt.allocPrint(arena, "the parameter {s}", .{p.name}));
        }
        const principal = switch (try f.caller(arena, req, searchMethod(kind))) {
            .principal => |p| p,
            .refused => |r| return r,
        };
        const key = switch (try f.charged(arena, req, principal)) {
            .key => |k| k,
            .refused => |r| return r,
        };
        if (f.options.searches_per_minute > 0) {
            const minute = @divFloor(f.now(), 60 * std.time.ns_per_s);
            const entry = try f.quota.getOrPut(f.store.allocator(), key);
            if (!entry.found_existing) entry.key_ptr.* = try f.store.allocator().dupe(u8, key);
            if (!entry.found_existing or entry.value_ptr.minute != minute) entry.value_ptr.* = .{ .minute = minute, .count = 0 };
            if (entry.value_ptr.count >= f.options.searches_per_minute) return quotaRefusal(arena, key);
            entry.value_ptr.count += 1;
        }

        const size_text = paramOf(params, "pageSize") orelse "";
        const size = if (size_text.len == 0) 0 else std.fmt.parseInt(i64, size_text, 10) catch |err| switch (err) {
            error.Overflow => return pageSizeRefusal(arena, size_text),
            error.InvalidCharacter => return pageSizeRefusal(arena, size_text),
        };
        if (size > std.math.maxInt(i32)) return pageSizeRefusal(arena, size_text);
        if (size < 0) return fieldRefusal(arena, "pageSize", "invalid page size");
        const page_size: usize = if (size == 0) f.options.default_page_size else @min(@as(usize, @intCast(size)), f.options.max_page_size);
        const query_text = paramOf(params, "query") orelse "";

        const token = paramOf(params, "pageToken") orelse "";
        // A token is a position in the one order, measured on 2026-10-17:
        // it went on from there with another page size, and with another
        // query, which it applied from there.
        var after: ?u128 = null;
        if (token.len > 0) {
            const at = decodeToken(token) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
            if (at.kind != kind) return notModelled(arena, "a token from another kind of search");
            if (f.now() - at.issued_ns > f.options.token_lifetime_ns) return notModelled(arena, "a token past its lifetime");
            after = at.after;
        }
        const found = try f.items(arena, kind, principal, query_text) orelse return f.queryRefusal(arena, kind, query_text);
        var first: usize = 0;
        if (after) |position| {
            while (first < found.len and found[first].rank <= position) first += 1;
        }
        const left = found[first..];
        var count = @min(page_size, left.len);
        if (f.takeFault(empty) != null) count = 0;
        if (f.takeFault(short)) |fault| count = @min(count, fault.max);
        // An empty page that goes on is only ever a fault's: production
        // never answered one.
        const more = count < left.len;
        const next = if (more) next: {
            f.tokens_issued += 1;
            const position: ?u128 = if (count > 0) left[count - 1].rank else after;
            break :next try encodeToken(arena, kind, position, f.now(), f.tokens_issued);
        } else null;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jsons = try arena.alloc([]const u8, count);
        for (left[0..count], 0..) |item, i| jsons[i] = item.json;
        writePage(&out.writer, switch (kind) {
            .project => "projects",
            .folder => "folders",
            .organization => "organizations",
        }, jsons, next) catch return error.OutOfMemory;
        return ok(try out.toOwnedSlice());
    }

    /// A project's, folder's or organization's place in the one order.
    fn rank(f: *const FakeResourceManager, number: u64) u128 {
        return switch (f.options.order) {
            .by_number => number,
            .seeded => (@as(u128, std.hash.Wyhash.hash(f.options.seed, std.mem.asBytes(&number))) << 64) | number,
        };
    }

    fn byRank(_: void, a: Item, b: Item) bool {
        return a.rank < b.rank;
    }

    /// What a search of `kind` finds for `principal` now, in the one order,
    /// or null when the query is refused.
    fn items(f: *FakeResourceManager, arena: Allocator, kind: Kind, principal: *const Principal, query_text: []const u8) Allocator.Error!?[]Item {
        const found = switch (kind) {
            .project => try f.projectItems(arena, principal, query_text) orelse return null,
            .folder => try f.folderItems(arena, principal, query_text) orelse return null,
            .organization => try f.organizationItems(arena, principal, query_text) orelse return null,
        };
        std.mem.sort(Item, found, {}, byRank);
        return found;
    }

    /// Every project `principal` sees that `query_text` finds, or null when
    /// the query is refused.
    fn projectItems(f: *FakeResourceManager, arena: Allocator, principal: *const Principal, query_text: []const u8) Allocator.Error!?[]Item {
        const parsed = try fake_query.parse(arena, query_text);
        const q = switch (parsed) {
            .query => |q| q,
            .refused => return null,
        };
        var found: std.ArrayList(Item) = .empty;
        for (f.projects.items) |s| {
            f.promote(s);
            const v = s.searched orelse continue;
            if (v.purged or !f.sees(principal, s, v.parent)) continue;
            switch (q.matches(.{ .project_id = s.project_id, .display_name = v.display_name, .number = s.number, .state = v.state, .labels = v.labels })) {
                .yes => try found.append(arena, .{ .rank = f.rank(s.number), .json = try render(arena, s, v, false) }),
                .no => {},
                .unknown => return null,
            }
        }
        return found.items;
    }

    /// The folders `principal` reads: granted on them or above them. Only
    /// the empty query was measured, so any other is refused.
    fn folderItems(f: *FakeResourceManager, arena: Allocator, principal: *const Principal, query_text: []const u8) Allocator.Error!?[]Item {
        if (query_text.len > 0) return null;
        var found: std.ArrayList(Item) = .empty;
        for (f.folders.values()) |folder| if (f.seesFrom(principal, folder.name)) {
            try found.append(arena, .{ .rank = f.rank(idNumber(folder.name)), .json = try renderFolder(arena, folder) });
        };
        return found.items;
    }

    /// The organizations `principal` is granted on. Only the empty query
    /// was measured, so any other is refused.
    fn organizationItems(f: *FakeResourceManager, arena: Allocator, principal: *const Principal, query_text: []const u8) Allocator.Error!?[]Item {
        if (query_text.len > 0) return null;
        var found: std.ArrayList(Item) = .empty;
        for (f.organizations.values()) |org| if (principal.grants.contains(org.name)) {
            try found.append(arena, .{ .rank = f.rank(idNumber(org.name)), .json = try renderOrganization(arena, org) });
        };
        return found.items;
    }

    /// Why `items` refused `query_text`, in production's words or as
    /// not modelled.
    fn queryRefusal(f: *FakeResourceManager, arena: Allocator, kind: Kind, query_text: []const u8) Allocator.Error!Reply {
        _ = f;
        switch (kind) {
            .project => {},
            .folder => return notModelled(arena, "a folder query"),
            .organization => return notModelled(arena, "an organization query"),
        }
        return switch (try fake_query.parse(arena, query_text)) {
            .refused => |r| switch (r.kind) {
                .production => fieldRefusal(arena, r.field, issueOf(r.message)),
                .not_modelled => notModelled(arena, r.message),
            },
            .query => notModelled(arena, "a match that depends on how production splits a name into words"),
        };
    }

    fn get(f: *FakeResourceManager, arena: Allocator, req: tp.Request, raw_ref: []const u8, query: []const u8) Allocator.Error!Reply {
        const ref = try decode(arena, raw_ref) orelse return notModelled(arena, "a path this fake cannot read");
        const params = try parseParams(arena, query) orelse return notModelled(arena, "a query string this fake cannot read");
        for (params) |p| if (!isOneOf(p.name, &.{"prettyPrint"})) return notModelled(arena, try std.fmt.allocPrint(arena, "the parameter {s}", .{p.name}));
        const principal = switch (try f.caller(arena, req, get_method)) {
            .principal => |p| p,
            .refused => |r| return r,
        };
        switch (try f.charged(arena, req, principal)) {
            .key => {},
            .refused => |r| return r,
        }
        if (ref.len == 0 or std.mem.indexOfScalar(u8, ref, '/') != null) return notModelled(arena, "this call");
        if (!resolvable(ref)) return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Fail to resolve resource 'projects/{s}'", .{ref}));
        if (f.byRef(ref)) |s| {
            const v = s.current;
            if (!v.purged and (s.public or f.sees(principal, s, v.parent))) return ok(try render(arena, s, v, true));
        }
        return failInfo(arena, 403, "PERMISSION_DENIED", try std.fmt.allocPrint(arena, "Permission 'resourcemanager.projects.get' denied on resource '//cloudresourcemanager.googleapis.com/projects/{s}' (or it may not exist).", .{ref}), "IAM_PERMISSION_DENIED", "cloudresourcemanager.googleapis.com", &.{
            .{ "resource", try std.fmt.allocPrint(arena, "projects/{s}", .{ref}) },
            .{ "permission", "resourcemanager.projects.get" },
        });
    }
};

/// A project's JSON, its keys in production's order. Search leaves out
/// `updateTime`, as production's did.
fn render(arena: Allocator, s: *const FakeResourceManager.Stored, v: FakeResourceManager.Version, with_update: bool) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeProject(&jw, s, v, with_update) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeProject(jw: *Stringify, s: *const FakeResourceManager.Stored, v: FakeResourceManager.Version, with_update: bool) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.print("\"projects/{d}\"", .{s.number});
    if (v.parent) |p| {
        try jw.objectField("parent");
        try jw.write(p);
    }
    try jw.objectField("projectId");
    try jw.write(s.project_id);
    try jw.objectField("state");
    try jw.write(stateName(v.state));
    if (v.display_name) |d| {
        try jw.objectField("displayName");
        try jw.write(d);
    }
    try writeTime(jw, "createTime", s.create_ns);
    if (with_update) try writeTime(jw, "updateTime", v.update_ns);
    if (v.delete_ns) |t| try writeTime(jw, "deleteTime", t);
    try jw.objectField("etag");
    try jw.print("\"W/\\\"{x:0>16}\\\"\"", .{std.hash.Wyhash.hash(v.serial, std.mem.asBytes(&s.number))});
    if (v.labels.len > 0) {
        try jw.objectField("labels");
        try jw.beginObject();
        for (v.labels) |l| {
            try jw.objectField(l.key);
            try jw.write(l.value);
        }
        try jw.endObject();
    }
    try jw.endObject();
}

fn stateName(state: types.State) []const u8 {
    return switch (state) {
        .active => "ACTIVE",
        .delete_requested => "DELETE_REQUESTED",
        .unspecified, .unknown => "STATE_UNSPECIFIED",
    };
}

/// A folder's JSON, its keys in the proto's order.
fn renderFolder(arena: Allocator, folder: *const FakeResourceManager.StoredFolder) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeFolder(&jw, folder) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeFolder(jw: *Stringify, folder: *const FakeResourceManager.StoredFolder) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(folder.name);
    try jw.objectField("parent");
    try jw.write(folder.parent);
    if (folder.display_name) |d| {
        try jw.objectField("displayName");
        try jw.write(d);
    }
    try jw.objectField("state");
    try jw.write(stateName(folder.state));
    try writeTime(jw, "createTime", folder.create_ns);
    try writeTime(jw, "updateTime", folder.create_ns);
    try jw.objectField("etag");
    try jw.print("\"W/\\\"{x:0>16}\\\"\"", .{std.hash.Wyhash.hash(0, folder.name)});
    try jw.endObject();
}

/// An organization's JSON, its keys in the proto's order.
fn renderOrganization(arena: Allocator, org: *const FakeResourceManager.StoredOrganization) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeOrganization(&jw, org) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeOrganization(jw: *Stringify, org: *const FakeResourceManager.StoredOrganization) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(org.name);
    try jw.objectField("displayName");
    try jw.write(org.domain);
    if (org.directory_customer_id) |d| {
        try jw.objectField("directoryCustomerId");
        try jw.write(d);
    }
    try jw.objectField("state");
    try jw.write(stateName(org.state));
    try writeTime(jw, "createTime", org.create_ns);
    try writeTime(jw, "updateTime", org.create_ns);
    try jw.objectField("etag");
    try jw.print("\"W/\\\"{x:0>16}\\\"\"", .{std.hash.Wyhash.hash(0, org.name)});
    try jw.endObject();
}

fn writeTime(jw: *Stringify, name: []const u8, ns: i96) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.objectField(name);
    try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = ns }));
}

fn writePage(w: *std.Io.Writer, field: []const u8, items: []const []const u8, token: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeByte('{');
    if (items.len > 0) {
        try w.print("\"{s}\":[", .{field});
        for (items, 0..) |item, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(item);
        }
        try w.writeByte(']');
    }
    if (token) |t| {
        if (items.len > 0) try w.writeByte(',');
        try w.print("\"nextPageToken\":\"{s}\"", .{t});
    }
    try w.writeByte('}');
}

const TokenAt = struct { kind: FakeResourceManager.Kind, after: ?u128, issued_ns: i96 };

/// "fake.p.<rank or s>.<issued>.<serial>": the kind of search, the last
/// place listed (s for none yet), when it was issued, and a serial that
/// makes each token its own.
fn encodeToken(arena: Allocator, kind: FakeResourceManager.Kind, after: ?u128, issued_ns: i96, serial: u64) Allocator.Error![]const u8 {
    const k: u8 = switch (kind) {
        .project => 'p',
        .folder => 'f',
        .organization => 'o',
    };
    if (after) |position| return std.fmt.allocPrint(arena, "fake.{c}.{d}.{d}.{d}", .{ k, position, issued_ns, serial });
    return std.fmt.allocPrint(arena, "fake.{c}.s.{d}.{d}", .{ k, issued_ns, serial });
}

fn decodeToken(token: []const u8) ?TokenAt {
    var it = std.mem.splitScalar(u8, token, '.');
    if (!std.mem.eql(u8, it.next() orelse return null, "fake")) return null;
    const k = it.next() orelse return null;
    const kind: FakeResourceManager.Kind = if (std.mem.eql(u8, k, "p")) .project else if (std.mem.eql(u8, k, "f")) .folder else if (std.mem.eql(u8, k, "o")) .organization else return null;
    const position = it.next() orelse return null;
    const after: ?u128 = if (std.mem.eql(u8, position, "s")) null else std.fmt.parseInt(u128, position, 10) catch return null;
    const issued_ns = std.fmt.parseInt(i96, it.next() orelse return null, 10) catch return null;
    _ = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .kind = kind, .after = after, .issued_ns = issued_ns };
}

/// The number in "folders/876" or "organizations/123", which the fake
/// checked when they were added.
fn idNumber(name: []const u8) u64 {
    const slash = std.mem.indexOfScalar(u8, name, '/').?;
    return std.fmt.parseInt(u64, name[slash + 1 ..], 10) catch unreachable;
}

/// Whether production reads `ref` as a project before it checks the
/// caller's permission: digits, or an id of lowercase letters, digits and
/// hyphens starting with a letter, after an optional `domain:`. Measured on
/// 2026-10-17: "Bad_Id!" and "a..b" were refused, 400 "Fail to resolve
/// resource", where an id that does not exist, or a number, was 403.
fn resolvable(ref: []const u8) bool {
    if (ref.len == 0) return false;
    for (ref) |c| {
        if (!std.ascii.isDigit(c)) break;
    } else return true;
    const colon = std.mem.lastIndexOfScalar(u8, ref, ':');
    if (colon) |at| {
        if (at == 0) return false;
        for (ref[0..at]) |c| switch (c) {
            'a'...'z', '0'...'9', '.', '-' => {},
            else => return false,
        };
    }
    const id = ref[if (colon) |at| at + 1 else 0..];
    if (id.len == 0 or !std.ascii.isLower(id[0])) return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A parent as production names one: "folders/N" or "organizations/N".
fn isParentName(name: []const u8) bool {
    inline for (.{ "folders/", "organizations/" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return validate.isNumber(name[prefix.len..]);
    }
    return false;
}

const Param = struct { name: []const u8, value: []const u8 };

/// The query string's parameters, percent-decoded; null for one that does
/// not decode, or a parameter given twice.
fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
    var list: std.ArrayList(Param) = .empty;
    if (query.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
        const name = try decode(arena, pair[0..eq]) orelse return null;
        const value = try decode(arena, pair[eq + 1 ..]) orelse return null;
        for (list.items) |p| if (std.mem.eql(u8, p.name, name)) return null;
        try list.append(arena, .{ .name = name, .value = value });
    }
    return list.items;
}

fn decode(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%') {
            if (i + 3 > text.len) return null;
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
            i += 2;
        } else {
            out[n] = text[i];
        }
        n += 1;
    }
    return out[0..n];
}

fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn headerOf(req: tp.Request, name: []const u8) ?[]const u8 {
    for (req.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn pathOf(url: []const u8) []const u8 {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    const slash = std.mem.indexOfScalarPos(u8, url, scheme_end, '/') orelse return "/";
    return url[slash..];
}

fn ok(body: []const u8) FakeResourceManager.Reply {
    return .{ .status = 200, .body = body };
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakeResourceManager.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

/// A 400 with a `BadRequest` naming `field`, as production refuses a
/// query or a page size: "field [query] has issue [invalid syntax]".
fn fieldRefusal(arena: Allocator, field: []const u8, issue: []const u8) Allocator.Error!FakeResourceManager.Reply {
    const message = try std.fmt.allocPrint(arena, "field [{s}] has issue [{s}]", .{ field, issue });
    return .{ .status = 400, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = 400,
        .message = message,
        .status = "INVALID_ARGUMENT",
        .details = .{.{
            .@"@type" = "type.googleapis.com/google.rpc.BadRequest",
            .fieldViolations = .{.{ .field = field, .description = issue }},
        }},
    } }, .{}) };
}

/// "invalid syntax", of "field [query] has issue [invalid syntax]".
fn issueOf(message: []const u8) []const u8 {
    const marker = "has issue [";
    const at = std.mem.indexOf(u8, message, marker) orelse return message;
    return message[at + marker.len .. message.len - 1];
}

fn pageSizeRefusal(arena: Allocator, text: []const u8) Allocator.Error!FakeResourceManager.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid value at 'page_size' (TYPE_INT32), \"{s}\"", .{text}));
}

const Meta = []const [2][]const u8;

fn failInfo(arena: Allocator, code: u16, status: []const u8, message: []const u8, reason: []const u8, domain: ?[]const u8, metadata: Meta) Allocator.Error!FakeResourceManager.Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeError(&jw, code, status, message, reason, domain, metadata, null) catch return error.OutOfMemory;
    return .{ .status = code, .body = try out.toOwnedSlice() };
}

/// A refusal naming the charged project, with the LocalizedMessage and
/// Help link production sent after its ErrorInfo.
fn failConsumer(arena: Allocator, code: u16, message: []const u8, reason: []const u8, metadata: Meta, link_text: []const u8, link: []const u8) Allocator.Error!FakeResourceManager.Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeError(&jw, code, "PERMISSION_DENIED", message, reason, "googleapis.com", metadata, .{ link_text, link }) catch return error.OutOfMemory;
    return .{ .status = code, .body = try out.toOwnedSlice() };
}

fn writeError(jw: *Stringify, code: u16, status: []const u8, message: []const u8, reason: []const u8, domain: ?[]const u8, metadata: Meta, help: ?[2][]const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(code);
    try jw.objectField("message");
    try jw.write(message);
    try jw.objectField("status");
    try jw.write(status);
    try jw.objectField("details");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("@type");
    try jw.write("type.googleapis.com/google.rpc.ErrorInfo");
    try jw.objectField("reason");
    try jw.write(reason);
    if (domain) |d| {
        try jw.objectField("domain");
        try jw.write(d);
    }
    try jw.objectField("metadata");
    try jw.beginObject();
    for (metadata) |m| {
        try jw.objectField(m[0]);
        try jw.write(m[1]);
    }
    try jw.endObject();
    try jw.endObject();
    if (help) |h| {
        try jw.beginObject();
        try jw.objectField("@type");
        try jw.write("type.googleapis.com/google.rpc.LocalizedMessage");
        try jw.objectField("locale");
        try jw.write("en-US");
        try jw.objectField("message");
        try jw.write(message);
        try jw.endObject();
        try jw.beginObject();
        try jw.objectField("@type");
        try jw.write("type.googleapis.com/google.rpc.Help");
        try jw.objectField("links");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("description");
        try jw.write(h[0]);
        try jw.objectField("url");
        try jw.write(h[1]);
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
}

fn quotaRefusal(arena: Allocator, key: []const u8) Allocator.Error!FakeResourceManager.Reply {
    return failInfo(arena, 429, "RESOURCE_EXHAUSTED", try std.fmt.allocPrint(arena, "Quota exceeded for quota metric 'v3 API search' and limit 'v3 API search per minute per project' of service 'cloudresourcemanager.googleapis.com' for consumer 'project_number:{s}'.", .{key}), "RATE_LIMIT_EXCEEDED", "googleapis.com", &.{
        .{ "consumer", try std.fmt.allocPrint(arena, "projects/{s}", .{key}) },
        .{ "quota_limit_value", "240" },
        .{ "quota_location", "global" },
        .{ "service", "cloudresourcemanager.googleapis.com" },
    });
}

fn refusal(arena: Allocator, status: u16) Allocator.Error!FakeResourceManager.Reply {
    return switch (status) {
        429 => quotaRefusal(arena, "82150720798"),
        403 => fail(arena, 403, "PERMISSION_DENIED", "The caller does not have permission"),
        500 => fail(arena, 500, "INTERNAL", "Internal error encountered."),
        503 => fail(arena, 503, "UNAVAILABLE", "The service is currently unavailable."),
        504 => fail(arena, 504, "DEADLINE_EXCEEDED", "The request timed out."),
        else => fail(arena, status, "UNKNOWN", "fake: refused"),
    };
}

/// What this fake has no answer for: said, never guessed at.
fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!FakeResourceManager.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try std.fmt.allocPrint(arena, "fake: {s} is not modelled yet", .{what}));
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Client = @import("Client.zig");

/// A client on the fake, as a caller the fake knows, and the fake on a
/// clock a test moves.
const Rig = struct {
    clock: test_util.FakeClock,
    fake: FakeResourceManager,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(r: *Rig, options: FakeResourceManager.Options, quota_project: types.QuotaProject) !void {
        r.clock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
        r.fake = .init(testing.allocator, r.clock.io(), options);
        errdefer r.fake.deinit();
        r.token = .{ .token = "person-token" };
        r.diag = .{};
        r.client = try .init(testing.allocator, r.clock.io(), .{
            .token_provider = r.token.provider(),
            .transport = r.fake.transport(),
            .diagnostics = &r.diag,
            .quota_project = quota_project,
            .retry = .{ .max_attempts = 2, .initial_backoff_ms = 0, .max_backoff_ms = 0 },
        });
    }

    fn deinit(r: *Rig) void {
        r.client.deinit();
        r.fake.deinit();
    }

    fn ids(list: []const types.Project, buf: [][]const u8) []const []const u8 {
        for (list, 0..) |p, i| buf[i] = p.project_id;
        return buf[0..list.len];
    }
};

fn expectIds(want: []const []const u8, got: []const types.Project) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g.project_id);
}

test "visibility: grants on a project and above it; a public project is read but not searched" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addFolder(.{ .name = "folders/10", .parent = "organizations/1" });
    try f.addFolder(.{ .name = "folders/11", .parent = "folders/10" });
    try f.addProject(.{ .number = 1, .project_id = "app-oauth" });
    try f.addProject(.{ .number = 2, .project_id = "mine", .display_name = "Mine" });
    try f.addProject(.{ .number = 3, .project_id = "deep", .parent = "folders/11" });
    try f.addProject(.{ .number = 4, .project_id = "public-data", .parent = "folders/99", .public = true });
    try f.addProject(.{ .number = 5, .project_id = "elsewhere", .parent = "organizations/2" });
    try f.addProject(.{ .number = 6, .project_id = "going", .state = .delete_requested });
    try f.addPrincipal("person-token", "app-oauth");
    try f.grant("person-token", "mine");
    try f.grant("person-token", "organizations/1");
    try f.grant("person-token", "6");

    var list = try r.client.allProjects(.{});
    defer list.deinit();
    try expectIds(&.{ "deep", "mine" }, list.value.projects);
    try testing.expectEqual(1, list.value.pending_deletion);
    try testing.expectEqual(.folder, list.value.projects[0].parent.?.kind);

    var public = try r.client.getProject("public-data");
    defer public.deinit();
    try testing.expectEqualStrings("folders/99", public.value.parent.?.name);
    try testing.expect(public.value.update_time != null);
    var by_number = try r.client.getProject("3");
    defer by_number.deinit();
    try testing.expectEqualStrings("deep", by_number.value.project_id);
    try testing.expectError(error.PermissionDenied, r.client.getProject("elsewhere"));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "(or it may not exist)") != null);
    try testing.expectError(error.PermissionDenied, r.client.getProject("no-such-project"));

    // Another caller sees only its own.
    try f.addPrincipal("robot-token", "elsewhere");
    try f.grant("robot-token", "elsewhere");
    r.token.token = "robot-token";
    var robot = try r.client.allProjects(.{});
    defer robot.deinit();
    try expectIds(&.{"elsewhere"}, robot.value.projects);
}

test "parent names: folders three deep, an organization, a parent the caller cannot read, a project with none" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addOrganization(.{ .name = "organizations/1", .domain = "example.com", .directory_customer_id = "C01" });
    try f.addOrganization(.{ .name = "organizations/2", .domain = "elsewhere.com" });
    try f.addFolder(.{ .name = "folders/10", .parent = "organizations/1", .display_name = "Engineering" });
    try f.addFolder(.{ .name = "folders/11", .parent = "folders/10", .display_name = "Payments" });
    try f.addFolder(.{ .name = "folders/12", .parent = "folders/11", .display_name = "Prod", .state = .delete_requested });
    try f.addFolder(.{ .name = "folders/20", .parent = "organizations/2", .display_name = "Hidden" });
    try f.addProject(.{ .number = 1, .project_id = "pay-prod", .parent = "folders/12" });
    try f.addProject(.{ .number = 2, .project_id = "shared-with-me", .parent = "folders/20" });
    try f.addProject(.{ .number = 3, .project_id = "my-own" });
    try f.addPrincipal("person-token", "my-own");
    try f.grant("person-token", "organizations/1");
    try f.grant("person-token", "shared-with-me");
    try f.grant("person-token", "my-own");

    var list = try r.client.allProjects(.{});
    defer list.deinit();
    try expectIds(&.{ "my-own", "pay-prod", "shared-with-me" }, list.value.projects);
    var names = try r.client.parentNames(.{});
    defer names.deinit();
    const n = &names.value;
    try testing.expectEqual(3, n.folders.len);
    try testing.expectEqual(1, n.organizations.len);
    try testing.expectEqualStrings("C01", n.organizations[0].directory_customer_id.?);
    try testing.expectEqual(.delete_requested, n.folder("folders/12").?.state);

    const a = testing.allocator;
    const deep = try n.path(a, list.value.projects[1].parent.?);
    defer a.free(deep);
    try testing.expectEqual(4, deep.len);
    for ([_][]const u8{ "Prod", "Payments", "Engineering", "example.com" }, deep) |want, got| try testing.expectEqualStrings(want, got);
    // A project shared with the caller, its folder unreadable: the name.
    try testing.expectEqualStrings("folders/20", n.label(list.value.projects[2].parent.?));
    try testing.expectEqual(null, list.value.projects[0].parent);

    // Folder and organization queries were not measured, and a token goes
    // with its own kind of search.
    var folders = try r.client.searchFolders(.{ .query = "displayName:Pay*" });
    defer folders.deinit();
    try testing.expectError(error.Unimplemented, folders.page(null));
    var orgs = try r.client.searchOrganizations(.{ .query = "domain:example.com" });
    defer orgs.deinit();
    try testing.expectError(error.Unimplemented, orgs.page(null));
    var projects = try r.client.searchProjects(.{ .page_size = 1 });
    defer projects.deinit();
    var first = try projects.page(null);
    defer first.deinit();
    var plain = try r.client.searchFolders(.{ .page_size = 1 });
    defer plain.deinit();
    try testing.expectError(error.Unimplemented, plain.page(first.value.next_page_token));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "another kind of search") != null);
}

test "callers: no token and an unknown one are production's 401" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const reply = try r.fake.serve(.{ .method = .GET, .url = "https://cloudresourcemanager.googleapis.com/v3/projects:search" }, arena.allocator());
    try testing.expectEqual(401, reply.status);
    try testing.expectError(error.Unauthenticated, r.client.allProjects(.{}));
    try testing.expect(std.mem.startsWith(u8, r.diag.message(), "Request had invalid authentication credentials."));
    // Production reads a project's form before the caller's right to it.
    try r.fake.addPrincipal("person-token", "home");
    for ([_]struct { []const u8, u16 }{
        .{ "a..b", 400 },                    .{ "Bad_Id%21", 400 },               .{ "a.b", 400 },
        .{ "1a", 400 },                      .{ "%3Aa", 400 },                    .{ "example.com%3Aa-1", 403 },
        .{ "99999999999999999999999", 403 }, .{ "zigps-no-such-project-x", 403 }, .{ "x%3A", 400 },
    }) |case| {
        const url = try std.fmt.allocPrint(arena.allocator(), "https://cloudresourcemanager.googleapis.com/v3/projects/{s}", .{case[0]});
        const answer = try r.fake.serve(.{ .method = .GET, .url = url, .bearer = "person-token" }, arena.allocator());
        try testing.expectEqual(case[1], answer.status);
    }
    const get_unsigned = try r.fake.serve(.{ .method = .GET, .url = "https://cloudresourcemanager.googleapis.com/v3/projects/a-project" }, arena.allocator());
    try testing.expectEqual(401, get_unsigned.status);
    try testing.expect(std.mem.indexOf(u8, get_unsigned.body, "GetProject") != null);
}

test "page sizes: production's refusals of a size that is no int32" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    try r.fake.addPrincipal("person-token", "home");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "abc", "99999999999999999999", "2147483648" }) |size| {
        const url = try std.fmt.allocPrint(a, "https://cloudresourcemanager.googleapis.com/v3/projects:search?pageSize={s}", .{size});
        const reply = try r.fake.serve(.{ .method = .GET, .url = url, .bearer = "person-token" }, a);
        try testing.expectEqual(400, reply.status);
        // As production answered `pageSize=abc` on 2026-10-17.
        const want = try std.fmt.allocPrint(a, "Invalid value at 'page_size' (TYPE_INT32), \\\"{s}\\\"", .{size});
        try testing.expect(std.mem.indexOf(u8, reply.body, want) != null);
    }
}

test "the charged project: the caller's own, or the one named; production's refusals of each" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addProject(.{ .number = 517222506229, .project_id = "app-oauth", .api_enabled = false });
    try f.addProject(.{ .number = 2, .project_id = "mine" });
    try f.addProject(.{ .number = 3, .project_id = "theirs" });
    try f.addPrincipal("person-token", "app-oauth");
    try f.grant("person-token", "mine");
    try f.allowQuotaUse("person-token", "mine");

    // The app's own OAuth project has the API off: the Earth Engine case.
    try testing.expectError(error.ServiceDisabled, r.client.allProjects(.{}));
    const off = r.client.lastConsumerRefusal().?;
    try testing.expectEqual(.service_disabled, off.reason);
    try testing.expectEqualStrings("projects/517222506229", off.consumer);
    try testing.expectEqualStrings("https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=517222506229", off.link.?);
    try testing.expect(std.mem.startsWith(u8, r.diag.message(), "Cloud Resource Manager API has not been used in project 517222506229 before or it is disabled."));

    var named: Client = try .init(testing.allocator, r.clock.io(), .{ .token_provider = r.token.provider(), .transport = f.transport(), .quota_project = .{ .project = "mine" } });
    defer named.deinit();
    var list = try named.allProjects(.{});
    defer list.deinit();
    try expectIds(&.{"mine"}, list.value.projects);

    var theirs: Client = try .init(testing.allocator, r.clock.io(), .{ .token_provider = r.token.provider(), .transport = f.transport(), .quota_project = .{ .project = "theirs" } });
    defer theirs.deinit();
    try testing.expectError(error.QuotaProjectDenied, theirs.allProjects(.{}));
    try testing.expectEqualStrings("projects/theirs", theirs.lastConsumerRefusal().?.consumer);
    try testing.expectError(error.QuotaProjectDenied, theirs.getProject("mine"));

    // A quota project the caller may use, with the API off there.
    try f.addProject(.{ .number = 4, .project_id = "billing", .api_enabled = false });
    try f.allowQuotaUse("person-token", "billing");
    var billing: Client = try .init(testing.allocator, r.clock.io(), .{ .token_provider = r.token.provider(), .transport = f.transport(), .quota_project = .{ .project = "billing" } });
    defer billing.deinit();
    try testing.expectError(error.ServiceDisabled, billing.allProjects(.{}));
    try testing.expectEqualStrings("projects/4", billing.lastConsumerRefusal().?.consumer);

    var missing: Client = try .init(testing.allocator, r.clock.io(), .{ .token_provider = r.token.provider(), .transport = f.transport(), .quota_project = .{ .project = "zigps-gone" } });
    defer missing.deinit();
    try testing.expectError(error.QuotaProjectDenied, missing.allProjects(.{}));
    try testing.expectEqual(null, missing.lastConsumerRefusal().?.link);

    // Turned on, the caller's own works again.
    try f.setApiEnabled("app-oauth", true);
    var again = try r.client.allProjects(.{});
    again.deinit();
}

test "paging: one stable order, every page of it, and a token a position in it" {
    var r: Rig = undefined;
    try r.init(.{ .default_page_size = 4, .max_page_size = 6 }, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addPrincipal("person-token", "home");
    var id_buf: [23][8]u8 = undefined;
    for (0..23) |i| {
        const id = std.fmt.bufPrint(&id_buf[i], "proj-{d:0>2}", .{i}) catch unreachable;
        try f.addProject(.{ .number = 100 + i, .project_id = id, .state = if (i % 2 == 0) .active else .delete_requested });
        try f.grant("person-token", id);
    }
    var first = try r.client.allProjects(.{ .page_size = 0, .include_pending_deletion = true });
    defer first.deinit();
    try testing.expectEqual(23, first.value.projects.len);
    try testing.expectEqual(6, first.value.pages);
    try testing.expectEqualStrings("proj-00", first.value.projects[0].project_id);

    // The same order on every search and at every page size, and not one
    // an app could sort by.
    var s1 = try r.client.searchProjects(.{ .page_size = 100 });
    defer s1.deinit();
    var p1 = try s1.page(null);
    defer p1.deinit();
    try testing.expectEqual(6, p1.value.items.len);
    var s2 = try r.client.searchProjects(.{ .page_size = 1 });
    defer s2.deinit();
    var p2 = try s2.page(null);
    defer p2.deinit();
    try testing.expectEqual(p1.value.items[0].number, p2.value.items[0].number);
    var sorted = true;
    for (p1.value.items[1..], p1.value.items[0 .. p1.value.items.len - 1]) |b, a| sorted = sorted and a.number < b.number;
    try testing.expect(!sorted);

    // A token goes on from its place with another page size, and with
    // another query, applied from there, as production's did.
    var bigger = try r.client.searchProjects(.{ .page_size = 3 });
    defer bigger.deinit();
    var after_one = try bigger.page(p2.value.next_page_token);
    defer after_one.deinit();
    for (after_one.value.items, p1.value.items[1..4]) |a, b| try testing.expectEqual(b.number, a.number);
    var first_id_buf: [32]u8 = undefined;
    const first_id = try std.fmt.bufPrint(&first_id_buf, "projectId:{s}", .{p2.value.items[0].project_id});
    var behind = try r.client.searchProjects(.{ .query = first_id, .page_size = 1 });
    defer behind.deinit();
    var none = try behind.page(p2.value.next_page_token);
    defer none.deinit();
    try testing.expectEqual(0, none.value.items.len);
    try testing.expectEqual(null, none.value.next_page_token);
    var active = try r.client.searchProjects(.{ .query = "state:ACTIVE", .page_size = 100 });
    defer active.deinit();
    var rest = try active.page(p2.value.next_page_token);
    defer rest.deinit();
    for (rest.value.items) |p| try testing.expectEqual(.active, p.state);
    // The same token twice gives the same page.
    var again = try bigger.page(p2.value.next_page_token);
    defer again.deinit();
    for (after_one.value.items, again.value.items) |a, b| try testing.expectEqual(a.number, b.number);

    // An empty page partway keeps its place.
    var fives = try r.client.searchProjects(.{ .page_size = 5 });
    defer fives.deinit();
    var five1 = try fives.page(null);
    defer five1.deinit();
    f.emptyNext(1);
    var gap = try fives.page(five1.value.next_page_token);
    defer gap.deinit();
    try testing.expectEqual(0, gap.value.items.len);
    var five2 = try fives.page(gap.value.next_page_token);
    defer five2.deinit();
    try testing.expectEqual(p1.value.items[5].number, five2.value.items[0].number);

    // Empty and short pages go on.
    f.emptyNext(1);
    var emptied = try r.client.allProjects(.{ .page_size = 5, .include_pending_deletion = true });
    defer emptied.deinit();
    try testing.expectEqual(23, emptied.value.projects.len);
    try testing.expectEqual(1 + 5, emptied.value.pages);
    f.shortenNext(1, 1);
    var shortened = try r.client.allProjects(.{ .page_size = 5, .include_pending_deletion = true });
    defer shortened.deinit();
    try testing.expectEqual(23, shortened.value.projects.len);
    // One, then 22 in fives.
    try testing.expectEqual(1 + 5, shortened.value.pages);

    // A token it did not issue is production's 400; one past its lifetime
    // is not modelled.
    try testing.expectError(error.InvalidPageToken, s1.page("garbage"));
    try testing.expectError(error.InvalidPageToken, s1.page("fake.x.s.0.1"));
    r.clock.now_ns += 2 * std.time.ns_per_hour;
    try testing.expectError(error.Unimplemented, s1.page(p1.value.next_page_token));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "past its lifetime") != null);
}

test "paging: by number, as production listed two projects" {
    var r: Rig = undefined;
    try r.init(.{ .order = .by_number }, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addPrincipal("person-token", "home");
    for ([_]u64{ 900000000002, 82150720798, 5 }, [_][]const u8{ "second-proj", "extractctl", "zzz-first" }) |n, id| {
        try f.addProject(.{ .number = n, .project_id = id });
        try f.grant("person-token", id);
    }
    var s = try r.client.searchProjects(.{});
    defer s.deinit();
    var page = try s.page(null);
    defer page.deinit();
    for ([_]u64{ 5, 82150720798, 900000000002 }, page.value.items) |n, p| try testing.expectEqual(n, p.number);
}

test "eventual consistency: get sees a change at once, search after the lag" {
    var r: Rig = undefined;
    try r.init(.{ .search_lag_ns = 30 * std.time.ns_per_s }, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addPrincipal("person-token", "home");
    try f.grant("person-token", "organizations/1");
    try f.addProject(.{ .number = 1, .project_id = "new-one", .parent = "organizations/1", .display_name = "Before" });
    var none = try r.client.allProjects(.{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.projects.len);
    var got = try r.client.getProject("new-one");
    defer got.deinit();
    try testing.expectEqualStrings("Before", got.value.display_name.?);
    r.clock.now_ns += 30 * std.time.ns_per_s;
    var seen = try r.client.allProjects(.{});
    defer seen.deinit();
    try testing.expectEqual(1, seen.value.projects.len);

    try f.change("new-one", .{ .display_name = "After" });
    try f.change("new-one", .{ .state = .delete_requested });
    var stale = try r.client.allProjects(.{});
    defer stale.deinit();
    try testing.expectEqualStrings("Before", stale.value.projects[0].display_name.?);
    var fresh = try r.client.getProject("new-one");
    defer fresh.deinit();
    try testing.expectEqualStrings("After", fresh.value.display_name.?);
    try testing.expectEqual(.delete_requested, fresh.value.state);
    try testing.expect(fresh.value.delete_time != null);
    r.clock.now_ns += 30 * std.time.ns_per_s;
    var later = try r.client.allProjects(.{});
    defer later.deinit();
    try testing.expectEqual(0, later.value.projects.len);
    try testing.expectEqual(1, later.value.pending_deletion);

    try f.change("new-one", .{ .labels = &.{.{ .key = "k", .value = "v" }} });
    var labelled = try r.client.getProject("new-one");
    defer labelled.deinit();
    try testing.expectEqualStrings("v", labelled.value.labels[0].value);
    try f.change("new-one", .purge);
    try testing.expectError(error.PermissionDenied, r.client.getProject("new-one"));
    try testing.expectError(error.InvalidEntry, f.change("new-one", .{ .display_name = "x" }));
}

test "the search quota: 240 a minute per charged project, never retried, then the next minute" {
    var r: Rig = undefined;
    try r.init(.{ .searches_per_minute = 3 }, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addPrincipal("person-token", "home");
    r.clock.now_ns = 1_792_141_200 * std.time.ns_per_s;
    for (0..3) |_| {
        var list = try r.client.allProjects(.{});
        list.deinit();
    }
    try testing.expectError(error.ResourceExhausted, r.client.allProjects(.{}));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "Quota exceeded") != null);
    try testing.expectEqual(4, f.searchCalls());
    r.clock.now_ns += 60 * std.time.ns_per_s;
    var next = try r.client.allProjects(.{});
    next.deinit();
}

test "faults: refusals and drops, retried as the client retries them" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addPrincipal("person-token", "home");
    f.dropNext(1);
    var list = try r.client.allProjects(.{});
    list.deinit();
    try testing.expectEqual(2, f.searchCalls());
    f.refuseNext(2, 503);
    try testing.expectError(error.Unavailable, r.client.allProjects(.{}));
    f.refuseNext(1, 429);
    try testing.expectError(error.ResourceExhausted, r.client.allProjects(.{}));
    try testing.expectEqual(5, f.searchCalls());
    f.refuseNext(1, 403);
    try testing.expectError(error.PermissionDenied, r.client.allProjects(.{}));
    try testing.expectEqualStrings("The caller does not have permission", r.diag.message());
    f.refuseNext(1, 418);
    try testing.expectError(error.Unknown, r.client.allProjects(.{}));
    try testing.expectEqualStrings("fake: refused", r.diag.message());
}

test "queries through the client: production's refusals are InvalidQuery; what is not modelled says so" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addPrincipal("person-token", "home");
    try f.addProject(.{ .number = 1, .project_id = "pay-prod", .display_name = "Payments Prod", .labels = &.{.{ .key = "team", .value = "pay" }} });
    try f.addProject(.{ .number = 2, .project_id = "web", .display_name = "Web" });
    try f.grant("person-token", "pay-prod");
    try f.grant("person-token", "web");
    var team = try r.client.allProjects(.{ .query = "labels.team:pay" });
    defer team.deinit();
    try expectIds(&.{"pay-prod"}, team.value.projects);
    var either = try r.client.allProjects(.{ .query = "name:web OR projectNumber:1" });
    defer either.deinit();
    try expectIds(&.{ "pay-prod", "web" }, either.value.projects);
    try testing.expectError(error.InvalidQuery, r.client.allProjects(.{ .query = "foo:bar" }));
    try testing.expectEqualStrings("field [query] has issue [Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND (foo : bar)]", r.diag.message());
    try testing.expectError(error.Unimplemented, r.client.allProjects(.{ .query = "parent:folders/1" }));
    try testing.expectError(error.Unimplemented, r.client.allProjects(.{ .query = "name:prod*" }));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "splits a name into words") != null);
}

test "requests it does not model are 501, never guessed at" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    try r.fake.addPrincipal("person-token", "home");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "/v3/projects:search?fields=projects",       "/v3/projects:search?query=%zz",
        "/v3/projects:search?pageSize=1&pageSize=2", "/v3/projects/a/b",
        "/v3/projects/a?alt=json",                   "/v3/folders:search?query=x",
        "/v1/projects",
    }) |path| {
        const url = try std.fmt.allocPrint(a, "https://cloudresourcemanager.googleapis.com{s}", .{path});
        const reply = try r.fake.serve(.{ .method = .GET, .url = url, .bearer = "person-token" }, a);
        try testing.expectEqual(501, reply.status);
    }
    const post = try r.fake.serve(.{ .method = .POST, .url = "https://cloudresourcemanager.googleapis.com/v3/projects:search", .bearer = "person-token" }, a);
    try testing.expectEqual(501, post.status);
}

test "test setup it refuses" {
    var r: Rig = undefined;
    try r.init(.{}, .none);
    defer r.deinit();
    const f = &r.fake;
    try f.addProject(.{ .number = 1, .project_id = "a-project" });
    try testing.expectError(error.InvalidEntry, f.addProject(.{ .number = 1, .project_id = "b-project" }));
    try testing.expectError(error.InvalidEntry, f.addProject(.{ .number = 2, .project_id = "a-project" }));
    try testing.expectError(error.InvalidEntry, f.addProject(.{ .number = 3, .project_id = "Bad_Id" }));
    try testing.expectError(error.InvalidEntry, f.addProject(.{ .number = 4, .project_id = "12345" }));
    try testing.expectError(error.InvalidEntry, f.addProject(.{ .number = 5, .project_id = "c-project", .parent = "folder/1" }));
    try testing.expectError(error.InvalidEntry, f.addProject(.{ .number = 6, .project_id = "d-project", .labels = &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } } }));
    try testing.expectError(error.InvalidEntry, f.addFolder(.{ .name = "organizations/1", .parent = "organizations/2" }));
    try testing.expectError(error.InvalidEntry, f.addFolder(.{ .name = "folders/2", .parent = "projects/1" }));
    try f.addFolder(.{ .name = "folders/1", .parent = "organizations/2" });
    try testing.expectError(error.InvalidEntry, f.addFolder(.{ .name = "folders/1", .parent = "organizations/2" }));
    try testing.expectError(error.InvalidEntry, f.addOrganization(.{ .name = "folders/3", .domain = "x.com" }));
    try f.addOrganization(.{ .name = "organizations/2", .domain = "x.com" });
    try testing.expectError(error.InvalidEntry, f.addOrganization(.{ .name = "organizations/2", .domain = "y.com" }));
    try testing.expectError(error.InvalidEntry, f.grant("nobody", "a-project"));
    try testing.expectError(error.InvalidEntry, f.allowQuotaUse("nobody", "a-project"));
    try f.addPrincipal("t", "home");
    try testing.expectError(error.InvalidEntry, f.addPrincipal("t", "home"));
    try testing.expectError(error.InvalidEntry, f.setApiEnabled("none", false));
    try testing.expectError(error.InvalidEntry, f.change("none", .purge));
    try testing.expectError(error.InvalidEntry, f.change("a-project", .{ .parent = "nowhere" }));
}

fn walkProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var clock: test_util.FakeClock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
    const lag: i96 = if (g.boolean()) 10 * std.time.ns_per_s else 0;
    var fake: FakeResourceManager = .init(gpa, clock.io(), .{
        .default_page_size = g.intRange(u32, 1, 6),
        .max_page_size = g.intRange(u32, 1, 10),
        .search_lag_ns = lag,
        .seed = g.int(u64),
    });
    defer fake.deinit();
    try fake.addFolder(.{ .name = "folders/10", .parent = "organizations/1" });
    try fake.addFolder(.{ .name = "folders/11", .parent = "folders/10" });
    try fake.addPrincipal("person-token", "home");

    const Want = struct { number: u64, id: [12]u8, searchable_at: i96, visible: bool, active: bool };
    var wants: [40]Want = undefined;
    const n = g.intRange(usize, 0, wants.len);
    for (wants[0..n], 0..) |*w, i| {
        // Some projects are added later than others, so a lag shows some.
        clock.now_ns += @as(i96, g.intRange(u8, 0, 3)) * std.time.ns_per_s;
        _ = std.fmt.bufPrint(&w.id, "proj-{d:0>7}", .{i}) catch unreachable;
        w.number = 1000 + @as(u64, g.intRange(u16, 0, 60_000)) * 64 + i;
        const parent = g.pick(?[]const u8, &.{ null, "folders/10", "folders/11", "organizations/2" });
        const grant_on = g.intRange(u8, 0, 3);
        w.active = g.intRange(u8, 0, 3) != 0;
        try fake.addProject(.{
            .number = w.number,
            .project_id = &w.id,
            .display_name = if (g.boolean()) "Named" else null,
            .parent = parent,
            .state = if (w.active) .active else .delete_requested,
            .public = g.intRange(u8, 0, 7) == 0,
        });
        w.searchable_at = clock.now_ns + lag;
        switch (grant_on) {
            0 => {
                try fake.grant("person-token", &w.id);
                w.visible = true;
            },
            1 => {
                try fake.grant("person-token", try std.fmt.allocPrint(fake.store.allocator(), "{d}", .{w.number}));
                w.visible = true;
            },
            else => w.visible = false,
        }
    }
    // Everything under organizations/1 is granted from above, folders
    // and all; organizations/2 is not.
    try fake.grant("person-token", "organizations/1");
    clock.now_ns += @as(i96, g.intRange(u8, 0, 20)) * std.time.ns_per_s;

    const include = g.boolean();
    const interval: u32 = g.pick(u32, &.{ 0, 250 });
    for (0..g.intRange(usize, 0, 2)) |_| fake.dropNext(1);
    if (g.boolean()) fake.refuseNext(1, g.pick(u16, &.{ 500, 503, 504 }));
    if (g.boolean()) fake.emptyNext(g.intRange(usize, 1, 3));
    if (g.boolean()) fake.shortenNext(g.intRange(usize, 1, 3), g.intRange(usize, 1, 2));

    var token = core.StaticToken{ .token = "person-token" };
    var client = try Client.init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .retry = .{ .max_attempts = 5, .initial_backoff_ms = 0, .max_backoff_ms = 0 },
    });
    defer client.deinit();
    const sleeps_before = clock.sleep_count;
    // The search's list is fixed when it starts, as a server's index is;
    // the walk's own pauses move the clock on after that.
    const started = clock.now_ns;
    var list = try client.allProjects(.{ .page_size = g.intRange(u31, 0, 7), .include_pending_deletion = include, .page_interval_ms = interval });
    defer list.deinit();
    const v = list.value;

    // What the plain model says the person sees.
    // Each page reads the index as it is then, as production's did, so a
    // project search shows partway through the walk may be listed too:
    // every one searchable when the walk started must be, and none that
    // was not searchable by its end may be.
    const ended = clock.now_ns;
    var must: usize = 0;
    var pending_min: u32 = 0;
    var pending_max: u32 = 0;
    for (wants[0..n]) |*w| {
        const s = fake.byId(&w.id).?;
        const inherited = if (s.current.parent) |p| !std.mem.eql(u8, p, "organizations/2") else false;
        const seen = w.visible or inherited;
        const at_start = seen and started >= w.searchable_at;
        const by_end = seen and ended >= w.searchable_at;
        const listed = for (v.projects) |p| {
            if (std.mem.eql(u8, p.project_id, &w.id)) break true;
        } else false;
        if (!w.active and !include) {
            if (at_start) pending_min += 1;
            if (by_end) pending_max += 1;
            try testing.expect(!listed);
            continue;
        }
        if (at_start) {
            must += 1;
            try testing.expect(listed);
        }
        if (listed) try testing.expect(by_end);
    }
    try testing.expect(v.complete);
    try testing.expectEqual(0, v.duplicates);
    try testing.expect(v.pending_deletion >= pending_min and v.pending_deletion <= pending_max);
    try testing.expect(v.projects.len >= must);
    if (v.projects.len > 1) for (v.projects[1..], v.projects[0 .. v.projects.len - 1]) |b, a| {
        try testing.expect(std.mem.order(u8, a.project_id, b.project_id) == .lt);
    };
    // A pause before each page after the first, and none faster: never
    // more than 4 pages a second.
    if (interval > 0) {
        var paced: usize = 0;
        for (clock.sleeps[sleeps_before..@min(clock.sleep_count, clock.sleeps.len)]) |ns| {
            if (ns == 250 * std.time.ns_per_ms) paced += 1;
        }
        if (clock.sleep_count <= clock.sleeps.len) try testing.expectEqual(v.pages - 1, paced);
    }
}

test "slow property allProjects: every project the caller may see that search shows, once, sorted, through faults" {
    try test_util.fuzzBytes({}, walkProperty, .{
        .corpus = &.{ "", "\x01\x03\x05\x00\x00\x00\x00\x00\x00\x00\x07\x28", "\x00\x01\x01\xff\xff\xff\xff\xff\xff\xff\xff\x10\x02\x00\x01" },
        .random_runs = 150,
        .max_len = 300,
    });
}

fn parentNamesProperty(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var clock: test_util.FakeClock = .{ .now_ns = 1_792_141_200 * std.time.ns_per_s };
    var fake: FakeResourceManager = .init(gpa, clock.io(), .{ .default_page_size = g.intRange(u32, 1, 5), .max_page_size = 5, .seed = g.int(u64) });
    defer fake.deinit();
    try fake.addPrincipal("person-token", "home");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A random forest: organizations, then folders under any earlier node.
    const Node = struct { name: []const u8, parent: ?[]const u8, label: ?[]const u8, granted: bool };
    var nodes: std.ArrayList(Node) = .empty;
    for (0..g.intRange(usize, 1, 3)) |i| {
        const name = try std.fmt.allocPrint(a, "organizations/{d}", .{i + 1});
        const domain = try std.fmt.allocPrint(a, "org{d}.com", .{i + 1});
        try fake.addOrganization(.{ .name = name, .domain = domain });
        const granted = g.boolean();
        if (granted) try fake.grant("person-token", name);
        try nodes.append(a, .{ .name = name, .parent = null, .label = domain, .granted = granted });
    }
    for (0..g.intRange(usize, 0, 12)) |i| {
        const name = try std.fmt.allocPrint(a, "folders/{d}", .{100 + i});
        const parent = nodes.items[g.intRange(usize, 0, nodes.items.len - 1)].name;
        const label: ?[]const u8 = if (g.boolean()) try std.fmt.allocPrint(a, "F{d}", .{i}) else null;
        try fake.addFolder(.{ .name = name, .parent = parent, .display_name = label });
        const granted = g.intRange(u8, 0, 3) == 0;
        if (granted) try fake.grant("person-token", name);
        try nodes.append(a, .{ .name = name, .parent = parent, .label = label, .granted = granted });
    }

    var token = core.StaticToken{ .token = "person-token" };
    var client = try Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    var names = try client.parentNames(.{ .page_size = g.intRange(u31, 0, 6), .page_interval_ms = 0 });
    defer names.deinit();
    try testing.expect(names.value.complete);

    for (nodes.items) |start| {
        // The plain model: a node is readable when it or a node above it is
        // granted; its label is its display name then, else its name; the
        // path climbs through readable folders.
        var want: std.ArrayList([]const u8) = .empty;
        var at: ?[]const u8 = start.name;
        while (at) |name| {
            const node = for (nodes.items) |n| {
                if (std.mem.eql(u8, n.name, name)) break n;
            } else unreachable;
            var readable = false;
            var up: ?[]const u8 = name;
            while (up) |u| {
                const above = for (nodes.items) |n| {
                    if (std.mem.eql(u8, n.name, u)) break n;
                } else unreachable;
                if (above.granted) readable = true;
                up = above.parent;
            }
            try want.append(a, if (readable and node.label != null) node.label.? else name);
            at = if (readable) node.parent else null;
        }
        const parent = try codec.parent(a, start.name);
        const got = try names.value.path(a, parent);
        try testing.expectEqual(want.items.len, got.len);
        for (want.items, got) |w, x| try testing.expectEqualStrings(w, x);
    }
}

test "fuzz parent names: every path climbs the tree as far as the caller can read, as a plain model does" {
    try test_util.fuzzBytes({}, parentNamesProperty, .{ .corpus = &.{ "", "\x03\x00\x00\x00\x00\x00\x00\x00\x00\x01\x01\x01\x0c" } });
}
