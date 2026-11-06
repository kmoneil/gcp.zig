[Docs](../README.md) › Service Usage

# 🔌 Service Usage

A client for the Service Usage API, v1, read only: which services (APIs)
a project has enabled, and whether one service, or up to 30 at once, is
enabled. It is what a console's list of a project's APIs reads, and what
a panel that says an API is off asks after a call fails because it is.
Enabling and disabling are not here. **Experimental.**

<!-- snippet: tests/docs_examples.zig#su-first -->
```zig
/// A project's enabled APIs, then whether the one a failed call named is
/// on, as a console's panel would say it.
fn apiPanel(client: *service_usage.Client, out: *std.Io.Writer, failed_api: []const u8) !void {
    var enabled = try client.enabledServices();
    defer enabled.deinit();
    for (enabled.value) |api| try out.print("{s}  {s}\n", .{ api.name, api.title });

    var one = try client.getService(failed_api);
    defer one.deinit();
    switch (one.value.state) {
        .enabled => try out.print("{s} is on\n", .{one.value.title}),
        .disabled, .unknown => try out.print("{s} is off in this project\n", .{one.value.title}),
    }
}
```

The client takes `Options.project_id`, the project's id or number, and a
token provider, as every module's does.

## The calls

| Call | What it does |
| --- | --- |
| `Client.enabledServices()` | Every service enabled in the project, in name order, read 200 to a page (45 were one page when measured) |
| `Client.listServices(options)` | One page of the project's services in name order: the enabled ones unless `options.state` is `.disabled` or `.any` |
| `Client.getService(name)` | One service and its state, by its name such as `pubsub.googleapis.com` |
| `Client.getServices(names)` | 1 to 30 services at once, in the order asked, a name asked twice answered twice |

A `Service` has its `name`, its `title` ("Cloud Pub/Sub API"), its
`summary`, its `state` (`.enabled`, `.disabled`, or `.unknown` for a
state this library does not know), and the `project_number` production
named it under. A summary is as production gives it: empty for some
services, and ending in a newline for others.

Every call asks for just these fields (a `fields` mask). A service's
whole configuration is large: Compute Engine's alone was 1.39 MB, and
293 bytes under the mask.

## Lists

The enabled list is short and cheap: production allows 600 a minute per
project. The others are not:

- **Every public service is in the unfiltered list**, enabled or not:
  13,018 when measured, in name order, 66 pages of 200. Production has
  no "enabled first": the 45 enabled ones were scattered through it.
  The disabled list is the same less those.
- **Those two lists have a quota of 60 a minute** per project, so
  reading either to its end takes more than a minute, past the quota.
  The client retries a 429 as it retries any read, but a console should
  list the enabled ones and ask about the rest by name.

`ListServicesOptions.page_size` is 1 to 200. Left at 0, production
answered 50 to a page of the other lists, and all 45 enabled ones on
one page. A page token works only with the `state` it came from.
Production answers the enabled list's tokens in two forms at random, so
treat them as opaque. Under another `state`, it refuses one form as a
bad token and the other as expired.

## Names

A service's name is its DNS name, `pubsub.googleapis.com`. All 13,018
names production listed were lower case letters, digits, `.` and `-`.
The client refuses anything else before sending, with
`error.InvalidName` and the byte and where it is in `Diagnostics`:

```
invalid service name: 'P' at byte 0; expected a-z, 0-9, '.' and '-', such as pubsub.googleapis.com
```

Production answered an upper case name, a space and a trailing dot as a
service it does not know. It answered `pubsub`, `bigquery` and
`compute` as their `.googleapis.com` names, but `storage` as unknown, so
use the full name.

## Errors

Production cannot tell a service it does not have from one this
principal may not see, and says so, 403 with
`SERVICE_CONFIG_NOT_FOUND_OR_PERMISSION_DENIED`. The client reports it
as `error.PermissionDenied`, the message in `Diagnostics`:

```
Not found or permission denied for service(s): zigps-nope-316.googleapis.com.
```

In a batch, one such name fails the whole call, naming the first.

| What | Error | Production's words |
| --- | --- | --- |
| A service nobody has, or one hidden | `PermissionDenied` | "Not found or permission denied for service(s): ..." |
| A project nobody has | `PermissionDenied` | "Project '...' not found or permission denied." |
| Another account's project | `PermissionDenied` | "Permission denied to list services for consumer container [projects/...]" |
| A token for another scope | `PermissionDenied` | "Request had insufficient authentication scopes." |
| A page token from another list | `InvalidArgument` | "Invalid page token '...'.", "Invalid page token: '...'." or "Page token is expired. ..." |

Every one of production's messages ends with a line `Help Token: ...`
that changes on every call. `Diagnostics` keeps the message as sent,
that line too, for Google's support.

What the client refuses before sending, with nothing sent: a name as
above, `error.InvalidName`; a page size over 200, and no names or more
than 30 for `getServices`, `error.InvalidOptions`.

## What production showed

Measured on 2026-11-06 with a service account in a test project.

- **Scopes**: `cloud-platform` and `cloud-platform.read-only` read
  everything. `service.management`, `service.management.readonly` and
  another API's scope were refused.
- **The project by id or by number** answers the same, and every name
  in an answer carries the number.
- **Quotas per project, a minute**: 600 of the default requests (gets
  and batches), 600 enabled lists, and 60 of the other lists. The 61st
  page of the unfiltered list in a minute was refused, 429.
- **Sizes under the client's mask**: 45 enabled services were 14 KB.
  Without it, the same list was 215 KB, and 30 services at once 4 MB.
- **Page tokens**: the enabled list answered an offset (`enabled-services-offset:3`
  in base64) in 17 of 30 calls and a cursor in the other 13, and took
  either. The other lists' tokens are long and opaque, and the disabled
  list took the unfiltered list's.
- **A batch get** takes a name under another project as one under its
  own: asked for `projects/bigquery-public-data/services/bigquery.googleapis.com`
  beside its own, it answered this project's BigQuery.

## Access

The principal needs `serviceusage.services.list` and
`serviceusage.services.get` on the project: Viewer has both. The
default scope is `cloud-platform.read-only`; `.cloud_platform` is there
for credentials fixed to it.

`examples/service_usage_list.zig` prints a project's enabled APIs and
the state of the ones named, or with `--fake` reads them from the
in-memory Service Usage:

```
$ zig build example-service_usage_list -- extractctl pubsub.googleapis.com bigtableadmin.googleapis.com
45 APIs enabled in extractctl (project number 82150720798):
  analyticshub.googleapis.com              Analytics Hub API
  ...
  telemetry.googleapis.com                 Telemetry API

asked:
  pubsub.googleapis.com                    enabled
  bigtableadmin.googleapis.com             disabled
```

In tests, `service_usage.testing.FakeServiceUsage` holds the services a
test puts in, and answers as production does: [Testing](testing.md).
