[Docs](../README.md) › Compute Engine

# 🖥️ Compute Engine

A client for Compute Engine's v1 API, **experimental**: the VMs a
project runs, in one zone or every zone at once, each with its status,
scheduling, disks, network, labels, metadata and the fingerprints a
change must send back; a VM's serial console and the guest attributes
its guest wrote; the zones, machine types and images a create needs;
and Compute's own operations, read, listed and waited on. Nothing here
creates, changes or deletes a VM yet: those calls are the module's next
milestones (issue #346).

```zig
const std = @import("std");
const auth = @import("auth");
const compute = @import("compute");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try compute.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    var all = try client.listAllInstances(.{ .partial_success = true });
    defer all.deinit();
    for (all.value.instances) |vm| {
        std.debug.print("{s} {s} {t}\n", .{ vm.zone, vm.name, vm.status });
    }
}
```

## The calls

| Call | What it answers |
| --- | --- |
| `listInstances(zone, options)` | One page of a zone's VMs |
| `listAllInstances(options)` | One page of the VMs in every zone, each with its `zone`; zones production could not answer for in `warnings` |
| `getInstance(zone, name)` | One VM |
| `serialOutput(zone, name, options)` | A stretch of its serial console, at most 1 MiB |
| `guestAttributes(zone, name, path)` | What its guest wrote under a namespace or key |
| `listZones`, `getZone` | The zones the project can use |
| `listMachineTypes`, `getMachineType` | A zone's machine types |
| `getImage(project, name)`, `imageFromFamily(project, family)` | An image, or a family's newest that is not deprecated (`imageFromFamily("debian-cloud", "debian-12")`) |
| `listOperations(scope, options)` | A zone's, region's or the project's operations |
| `getOperation(ref)` | One operation as it stands |
| `waitOperation(ref, options)` | One operation once it is DONE, or at a deadline |

Every list takes `ListOptions`: a `filter` in Compute's own syntax
(`labels.env = prod`, `name = "web-.*"`, `status = RUNNING`), an
`order_by` (`name` or `creationTimestamp desc`, the only two production
sorts by), `max_results` (500 at most and by default), a `page_token`,
and `partial_success`. Compute refuses a filter and an order together,
so the client does too, before sending.

## A VM

`Instance` keeps what managing a VM needs: `status` (an enum of
Compute's twelve states), `zone` and `machine_type` as short names,
`labels`, `metadata`, `tags`, `disks`, `network_interfaces`,
`service_accounts`, `scheduling`, `deletion_protection`, the times it
was made, last started, stopped and suspended, and three fingerprints:
`label_fingerprint`, `metadata.fingerprint` and `tags.fingerprint`, each
what a change to it must send back.

- A VM a caller stopped reads `.terminated`, not `.stopped`, and so does
  one whose guest powered itself off. `Instance.stopped()` answers both.
- A spot VM's `scheduling` has `provisioning_model` `.spot`,
  `preemptible` true and `on_host_maintenance` TERMINATE, which
  production fills in on its own. A run limit is `max_run_duration_s`,
  with `termination_action` saying what happens at it, and
  `termination_time` when.
- `Instance.label(key)` and `Instance.metadataValue(key)` read one entry.

## Across zones

`listAllInstances` asks every zone in one call. Production answers
every zone it has, 132 when measured, an empty one with a warning,
NO_RESULTS_ON_PAGE; those are left out, and any other warning is kept
in `warnings` with its scope. A page counts VMs, and may span zones.

## The serial console

A VM's console keeps its last megabyte or so. `serialOutput` with no
`start` reads the newest 1 MiB; `SerialOutput.start` and `.next` are
byte offsets into everything the port has written. Reading from `next`
until it stops moving follows the console as it grows; a `start` older
than what the VM still keeps is moved up to its oldest byte, as
production does. Ports are 1 to 4.

## Guest attributes

A VM's guest writes them to its metadata server (with the metadata
`enable-guest-attributes` set to TRUE), and `guestAttributes` reads them
back: `"app/"` for a namespace, `"app/state"` for one key. A path with
nothing under it is `error.NotFound`.

## Operations and waiting

Every write Compute takes answers an `Operation` at once, and the work
goes on after. `waitOperation(op.ref(), .{ .timeout_ms = 600_000 })`
waits for it: each wait call is held by the server for up to two
minutes, the client loops until the operation is DONE or the deadline
passes, and answers the operation as it stands then. The client gives a
wait call at least 150 s, past its usual request limit.

A write can be refused two ways, and a caller must handle both:

- **At once, as an error**, for what Compute can check before acting: a
  name taken (`error.AlreadyExists`, 409), a stale or missing fingerprint
  (`error.FailedPrecondition`, 412), an unknown zone, machine type or
  image, a delete under deletion protection (`error.InvalidArgument` or
  `error.NotFound`).
- **In the operation**, for what it finds while acting: the call
  succeeds, and the operation ends DONE with `failure` set. Setting a
  running VM's machine type ends `UNSUPPORTED_OPERATION`, "Instance is
  starting or running."; deleting a template a group uses ends
  `RESOURCE_IN_USE_BY_ANOTHER_RESOURCE`. `Operation.succeeded()` is done
  and not failed; `Operation.Failure.stockout()` says the zone had no
  room, worth trying another zone.

Every write sends a `requestId`; production answered a repeated one with
the same operation, while it ran and after, so a write retried after a
lost answer lands once.

## What ended a VM

A zone's operations say, each by `user` "system":

| `operation_type` | What happened |
| --- | --- |
| `compute.instances.preempted` | Google took back a spot VM |
| `compute.instances.deferredDelete` | Its run limit, with DELETE |
| `compute.instances.guestTerminate` | Its guest powered itself off |

`listOperations(.{ .zone = z }, .{ .filter = "targetLink eq .*/instances/web-1" })`
lists one VM's; `Operation.targetsInstance(name)` checks one. An
operation's links name the `www.googleapis.com` host, not the one a
client calls, so `Operation.target` keeps only the path.
`operation_type` is not one vocabulary ("insert", "stop",
"compute.instance.setLabels"), so it stays a string.

## The scope

A client asks for one OAuth scope: `compute.readonly` by default, which
every call here takes, the wait on an operation included.

## Testing

`compute.testing.FakeCompute` is Compute Engine in memory, behind
`Client.Options.transport`: zones, VMs, serial output, guest attributes,
machine types, images and operations a test puts in, read back as
production answered when measured, its refusals in production's words.
An operation finishes after the number of waits the test gives it, with
the failure the test gives it. Writes answer 501 until the module's next
milestones.

```zig
var fake: compute.testing.FakeCompute = .init(gpa, io, .{});
defer fake.deinit();
try fake.putInstance(.{ .zone = "us-central1-a", .name = "web-1", .spot = true });
const op = try fake.putOperation(.{ .scope = .{ .zone = "us-central1-a" }, .waits_to_finish = 2 });
var client = try compute.Client.init(gpa, io, .{
    .project_id = "my-project",
    .token_provider = token.provider(),
    .transport = fake.transport(),
});
```

## What production showed

Measured on 2026-11-03 in a test project, on e2-micro VMs, spot and
standard:

| Asked | Answer |
| --- | --- |
| An insert again with the same `requestId` | The same operation, while it ran and after it was DONE |
| An insert of a name taken | 409 `alreadyExists` at once, while the first insert still ran |
| A stale or missing fingerprint | 412 `conditionNotMet` |
| A delete under deletion protection | 400 `invalidResourceUsage` |
| A standard e2 asked for onHostMaintenance TERMINATE | 400 `badRequest`; a spot e2 has it filled in |
| A filter and an order together | 400 `invalid` |
| A wait on a running operation | Back at about two minutes; three calls for a 281 s suspend |
| A wait on a DONE operation, an unknown one | At once; 404 |
| An insert, stop, start, resume | DONE in 9 to 13 s, about 54 s, about 23 s, 12 to 19 s |
| A suspend | 93 s standard, 281 s spot (a spot VM can be suspended) |
| Stopping a stopped VM, starting a running one | Each an operation, not a refusal |
| A preemption after `simulateMaintenanceEvent` | 253 s later |
| The serial console with no `start` | The last 1 MiB, with byte offsets |
| An empty zone in the aggregated list | NO_RESULTS_ON_PAGE, 131 of 132 zones |
