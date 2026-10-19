[Docs](../README.md) › Run

# 🏃 Run

A client for Cloud Run's v2 API, read only: the services a project runs
and the revisions behind them, with their conditions, for a health
view's "recent revisions" widget and a trend chart's deploy markers.
Nothing here deploys, routes traffic or deletes anything.
**Experimental**: new in 0.48.0.

```zig
const std = @import("std");
const auth = @import("auth");
const run = @import("run");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try run.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    var revisions = try client.listRevisions("us-central1", "-", .{});
    defer revisions.deinit();
    for (revisions.value.revisions) |revision| {
        if (!revision.ready()) warn(revision);
    }
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listLocations(options)` | One page of the locations services can live in, through v1's list on the same host: v2 has none (43 locations when measured) |
| `Client.listServices(location, options)` | One page of a location's services; the location may be `-`, every region at once, which production answers (though its documentation says otherwise) with `unreachable_regions` for the regions it could not ask |
| `Client.getService(location, id)`, `getServiceNamed(name)` | One service, by its parts or its full name; another project's name is refused before sending |
| `Client.listRevisions(location, service, options)` | One page of a service's revisions, newest first; the service may be `-`, every service in the location |
| `Client.getRevision(location, service, id)`, `getRevisionNamed(name)` | One revision |

A `Service` carries its `uri` and `urls`, the latest ready and created
revision ids, `traffic` (what was asked) and `traffic_statuses` (what
the server serves, with a tag's own uri), its `conditions` and
`terminal_condition`, times, generations and `reconciling`. A
`Revision` carries its `create_time` (the deploy marker), generation,
`containers` with images pinned to their digests as production answers
them, `conditions` and the console's `log_uri`.

**`Service.ready()`** and **`Revision.ready()`** answer the health
view's question; `Revision.readyCondition()` carries the reason and
message. When a deploy fails, production writes the story in plain
words: the broken revision's `Ready` condition said "Image
'&lt;image&gt;' not found." with the service's terminal condition
`CONDITION_FAILED`, reason `REVISION_FAILED`, while
`latest_ready_revision` stayed on the last good revision.

## The scope

Every call asks its token provider for `run.readonly`, the narrowest
scope every read takes.

## What production showed

Measured on 2026-10-19 with a real service (the gated suite repeats
it):

- Deploys, updates and deletes answer **long-running operations**; the
  hello service's deploy was done in 6 s, and a failed deploy's
  operation completes with an `error` rather than hanging.
- **Revisions of a service nobody has are an empty page, not a 404**; a
  service nobody has is a 404 in plain words ("Resource '<id>' of kind
  'SERVICE' in region '<l>' in project '<p>' does not exist.").
- A location that is no region is a 400, "The request has errors".
- An empty list is `{}`. Revisions are named `<service>-0000N-<suffix>`.

In tests, `run.testing.FakeRun` holds locations, services and revisions
a test puts in: [Testing](testing.md). `examples/run_revisions.zig
--fake` draws the recent-revisions widget offline.
