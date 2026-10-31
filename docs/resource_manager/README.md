[Docs](../README.md) › Resource Manager

# 🗂️ Resource Manager

A client for the projects a credential can see, from Cloud Resource
Manager's v3 REST API: every project in one list, for a project switcher
to cache and filter as a person types; one project read as it is now;
and display text for the folders and organizations above them. It
changes nothing.

```zig
const std = @import("std");
const auth = @import("auth");
const rm = @import("resource_manager");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try rm.Client.init(init.gpa, init.io, .{ .token_provider = creds.provider() });
    defer client.deinit();
    try refresh(&client, init.gpa);
}
```

<!-- snippet: tests/docs_examples.zig#rm-first -->
```zig
/// The switcher's list: every project the credentials can see, and where
/// each sits, refreshed every 15 minutes or so and filtered locally.
fn refresh(client: *rm.Client, gpa: std.mem.Allocator) !void {
    var list = try client.allProjects(.{});
    defer list.deinit();
    var names = try client.parentNames(.{});
    defer names.deinit();
    for (list.value.projects) |p| {
        const where = if (p.parent) |parent| names.value.label(parent) else "";
        try remember(gpa, p.project_id, p.label(), where);
    }
}
```

A project shows when the principal holds `resourcemanager.projects.get`
on it, or on a folder or organization above it (Viewer, Browser and the
basic roles do). The client asks for the
`https://www.googleapis.com/auth/cloud-platform.read-only` scope and
nothing wider. No client takes a project of its own: a search spans
everything the credential can see.

## The guides

| Guide | What's in it |
| --- | --- |
| [Listing projects](projects.md) | The walk a switcher wants, matching letters locally, searching page by page, the query language as production read it, a project read as it is now, projects pending deletion, and where a project sits |
| [The project charged](quota-project.md) | Which project each call is charged to and checked for the API, why none is named by default, and the two refusals that name it |
| [Testing](testing.md) | An in-memory Resource Manager for your own tests, with production's answers |

## The calls

| Call | What it does |
| --- | --- |
| `Client.allProjects(options)` | Every page of one search: each project once, pending deletion left out, sorted by project id |
| `Client.searchProjects(options)`, `search.page(token)` | One search, a page a call, the same request every time |
| `Client.getProject(id_or_number)` | One project, as it is now |
| `Client.getProjectIamPolicy(id_or_number)` | The project's IAM policy, which everything under it inherits: [Who has access](projects.md#who-has-access) |
| `Client.testProjectIamPermissions(id_or_number, permissions)` | Which of the permissions asked the caller holds on the project |
| `Client.parentNames(options)` | The folders and organizations the caller can read, for `label` and `path` |
| `Client.searchFolders`, `Client.searchOrganizations` | Either search, a page a call |
| `Client.lastConsumerRefusal()` | The project a refusal charged, and the link that fixes it |

## What was measured

Resource Manager has no emulator, so what this module does was measured
in production on 2026-10-17 before it was built on, and a production
suite replays 37 scripts against production and the fake. What that
changed:

- **Two search terms side by side mean AND**, whatever the reference
  says: `projectId:my-app state:DELETE_REQUESTED` found nothing for an
  active project.
- **No order and no stable page size are promised**, so the walk sorts
  by project id and keeps each project number once.
- **A public project can be read but not found.** `getProject` read
  `bigquery-public-data`, and no search listed it.
- **Search leaves out `updateTime`**; `getProject` sends it.
- **A project with no organization has no `parent` key at all.**
- **A quota project with the API off breaks a call that works without
  one**, the commonest failure reported; so none is sent unless asked
  for. [The project charged](quota-project.md) says why.
- **Ten searches in 205 ms were all served**, though Google documents 4
  a second; the walk still waits 250 ms between pages.

## Not here

Creating, moving, deleting and undeleting projects; folder and
organization management; IAM policies, liens and tags; the
strongly consistent `projects.list` by parent, which needs a permission
on the parent that a person granted only projects does not hold.
