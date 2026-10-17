//! Cloud Resource Manager v3 REST client: the projects a credential can see.
//!
//! `Client.allProjects` reads every page of `projects.search` and returns
//! one list, each project once, sorted by project id, for a switcher to
//! cache and filter locally. `Client.searchProjects` fixes one search and
//! `search.page` fetches its pages, one a call. `Client.getProject` reads
//! one project, strongly consistent where search is not.
//! `Client.parentNames` gives display text for the folders and
//! organizations a caller can read, for showing where a project sits.
//!
//! No quota project is sent unless asked for, as gcloud does for every
//! project command: a quota project with the API off breaks a search that
//! works without one. There is no emulator and no unauthenticated mode:
//! every client needs a `TokenProvider`, which the `auth` module supplies.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const Search = @import("search.zig").Search;
pub const ProjectSearch = Search(Project);
pub const FolderSearch = Search(Folder);
pub const OrganizationSearch = Search(Organization);

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`: read only.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Label = @import("types.zig").Label;
pub const State = @import("types.zig").State;
pub const Parent = @import("types.zig").Parent;
pub const Project = @import("types.zig").Project;
pub const Page = @import("types.zig").Page;
pub const ProjectPage = @import("types.zig").ProjectPage;
pub const SearchOptions = @import("types.zig").SearchOptions;
pub const WalkOptions = @import("types.zig").WalkOptions;
pub const ProjectList = @import("types.zig").ProjectList;
pub const Folder = @import("types.zig").Folder;
pub const Organization = @import("types.zig").Organization;
pub const FolderPage = @import("types.zig").FolderPage;
pub const OrganizationPage = @import("types.zig").OrganizationPage;
pub const ParentOptions = @import("types.zig").ParentOptions;
pub const ParentNames = @import("types.zig").ParentNames;
pub const QuotaProject = @import("types.zig").QuotaProject;
pub const ConsumerRefusal = @import("types.zig").ConsumerRefusal;

/// The fixed limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

/// What a test of code that lists projects can stand on, with no emulator
/// and no network. **Experimental**: new in 0.40.0, and free to change
/// between minor versions until it has been used for a while.
pub const testing = struct {
    /// Cloud Resource Manager in memory, behind `Client.Options.transport`:
    /// projects, folders and callers a test adds, searched, paged and read
    /// as production answered, the project charged for each call and its
    /// refusals included. It says so where it does not model something.
    pub const FakeResourceManager = @import("fake_resource_manager.zig").FakeResourceManager;
    /// An `Io` whose clock a test moves, for search lag, token lifetimes
    /// and the search quota's minute.
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("fake_query.zig");
    _ = @import("fake_resource_manager.zig");
    _ = @import("logging.zig");
    _ = @import("production_bodies.zig");
    _ = @import("rpc.zig");
    _ = @import("search.zig");
    _ = @import("test_util.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
    _ = @import("walk.zig");
}

test "every public declaration of types.zig is public here too" {
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
