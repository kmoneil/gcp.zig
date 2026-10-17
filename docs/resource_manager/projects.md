[Docs](../README.md) › [Resource Manager](README.md) › Listing projects

# Listing projects

## A list for a switcher

`Client.allProjects` reads every page of one `projects.search` and
returns one list:

- each project number once, since nothing promises a project comes once
  across pages;
- projects pending deletion left out, and counted in `pending_deletion`,
  unless `include_pending_deletion` is set: production returned them to
  an empty search;
- sorted by project id, since search returns projects "in an unspecified
  order".

It waits `page_interval_ms` (250 ms) before each page after the first,
and stops after `max_pages` (100 pages of 500) with `complete = false`.
A page token the server sends again fails the walk with
`error.InvalidResponse` rather than paging forever. Any other failure on
any page fails the walk, and an app keeps the list it had.

Cache the list and refresh it every 15 minutes or so. Match what a person
types against the cache, not the server: search matches only from the
start of a value (`name:pay*`), costs a call a keystroke against a quota
every caller charged to the same project shares, and can lag a change.

<!-- snippet: tests/docs_examples.zig#rm-match -->
```zig
/// What a switcher matches as a person types: the letters anywhere in the
/// display name, the project id or the number, case aside.
fn matches(p: rm.Project, letters: []const u8) bool {
    if (std.ascii.findIgnoreCase(p.label(), letters) != null) return true;
    if (std.ascii.findIgnoreCase(p.project_id, letters) != null) return true;
    var buf: [20]u8 = undefined;
    const number = std.fmt.bufPrint(&buf, "{d}", .{p.number}) catch unreachable;
    return std.mem.indexOf(u8, number, letters) != null;
}
```

`Project.label()` is the display name, or the project id when there is
none. Display names are not unique; project ids and numbers are. The
number comes from `name` ("projects/415104041262"), the only place v3
carries it.

## Page by page

`Client.searchProjects` fixes one request; `page(token)` sends it with a
token. An empty page with a token is an ordinary answer; only a null
token ends a search. Tokens "have a limited lifetime", so start a new
search for each refresh rather than keeping one.

Measured on 2026-10-17 with two visible projects: a token is a position
in one order, not a bookmark in its search. Sent again it gave the same
page, and it still worked 65 s later. Sent with another page size it went
on from its place; sent with another query it applied that query from
its place, so a project listed before the token was not found. The order
was the same on every walk and at every page size (project number order,
which was also id order), but nothing promises it, and the walk sorts by
project id itself.

<!-- snippet: tests/docs_examples.zig#rm-pages -->
```zig
var search = try client.searchProjects(.{ .query = "labels.team:payments", .page_size = 100 });
defer search.deinit();
var token: ?[]const u8 = null;
while (true) {
    var page = try search.page(token);
    defer page.deinit();
    count += page.value.items.len;
    // Only a null token ends a search; keep the next one past deinit.
    token = if (page.value.next_page_token) |t| try arena.dupe(u8, t) else break;
}
```

Production took any page size up to 2,147,483,647, and 0 means its
default.

## The query language, as production read it

The query is sent as written. Measured on 2026-10-17:

| Query | Production |
| --- | --- |
| `projectId:a state:ACTIVE` | **AND**: both must hold, whatever the reference says |
| `projectId:a AND state:ACTIVE`, `x OR y`, `NOT x`, `-x`, `(x OR y) z` | Read as written |
| `name:ext*` | Display names that start with "ext"; `name:ext` alone matches none |
| `name:*ext`, `id:ex*tl` | Matched nothing, and were not refused |
| `NAME:EXT*`, `state:active` | Keys and values ignore case |
| `projectId=a` | The same as `projectId:a` |
| `projectId!=a` | Taken, and did **not** exclude `a` |
| `projectNumber:415104041262` | Read; `projectNumber:4151*` was refused |
| `id:415104041262` | Matched nothing: `id` is the project id |
| `parent:folders/876` | Read from another index: it found a public project an empty search never lists, and a folder that does not exist was 403 |
| `foo:bar` | 400 `field [query] has issue [Invalid filter query: ...]`, `error.InvalidQuery` |
| `extractctl`, `a:b and c:d` | 400 "contains global restriction": a bare word, or a lowercase `and` |
| `name:été` | 400 "Invalid filter query": values past ASCII are refused |
| a value over 1,000 characters, or about 50 terms | 400 "Invalid filter query" |

The client refuses a query over 8,000 bytes itself (`error.InvalidQuery`):
production answered a 20,000-byte one with an HTML page from its front
end.

## One project, as it is now

Search "is eventually consistent": a project made in the last minutes
may be missing, and a renamed or deleted one may show as it was.
`Client.getProject` reads one project by id or number, as it is now,
for a project a person picks from a list that may be stale or types in
full before search shows it. It sends `updateTime`, which search leaves
out. A project that does not exist, and one the caller cannot see, are
both 403, `error.PermissionDenied`: "Permission
'resourcemanager.projects.get' denied on resource ... (or it may not
exist)." A malformed id, such as `a..b`, is 400 "Fail to resolve
resource", `error.InvalidArgument`.

## Where a project sits

`Project.parent` is the folder or organization a project is in, or null
for one at the top of its hierarchy. `Client.parentNames` reads every
folder and organization the caller can read, from one `folders.search`
and one `organizations.search` with no query; for most people that is a
page each, on the same quota as the project search. Then:

- `ParentNames.label(parent)` is the display name, or the parent's name
  ("folders/876") when the caller cannot read it, as the console's
  "Inaccessible parent" shows it;
- `ParentNames.path(gpa, parent)` climbs from the parent through the
  folders the caller can read to the organization: "Prod", "Payments",
  "example.com". An organization's display name is its primary domain.

## Errors

| Error | When |
| --- | --- |
| `InvalidQuery` | The server refused the query (its words in `Diagnostics`), or the client would not send it |
| `InvalidPageToken` | A token the server did not issue: production says only "Request contains an invalid argument." |
| `ServiceDisabled`, `QuotaProjectDenied` | The project charged has the API off, or may not be charged: [The project charged](quota-project.md) |
| `ResourceExhausted` | A 429. Never retried: the next refresh tries again |
| `PermissionDenied` | `getProject` on a project the caller cannot see, or that does not exist |
| `InvalidName` | A project id, number or quota project the client will not put in a path or a header |
| `InvalidResponse` | An answer that does not decode, or a page token sent again |

500, 502, 503, 504 and dropped connections are retried with the client's
`RetryPolicy`: every call here is a GET with no side effect.
