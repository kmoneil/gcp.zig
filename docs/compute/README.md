[Docs](../README.md) › Compute Engine

# 🖥️ Compute Engine

A client for Compute Engine's v1 API, **experimental**: the VMs a
project runs, in one zone or every zone at once, each with its status,
scheduling, disks, network, labels, metadata and the fingerprints a
change must send back; a VM's serial console and the guest attributes
its guest wrote; the zones, machine types and images a create needs;
Compute's own operations, read, listed and waited on; and the writes
that create a VM and run it through its life, each shown before it is
sent if the caller asks. Changing a live VM (labels, metadata, machine
type, disks) and managed groups are the module's next milestones
(issue #346).

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
| `insertInstance(zone, spec, options)` | Creates a VM from an `InstanceSpec` |
| `insertInstanceJson(zone, json, options)` | Creates a VM from an instance body written by the caller |
| `insertFromTemplate(zone, name, template, options)` | Creates a VM from an instance template |
| `startInstance`, `stopInstance`, `suspendInstance`, `resumeInstance`, `resetInstance`, `deleteInstance` | A VM's life, `(zone, name, options)` |
| `insertInstanceRequest` and the other `*Request` twins | The exact request a write would send, unsent |
| `newRequestId(buf)` | A request id, a random UUID |

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

## Creating a VM

```zig
var client = try compute.Client.init(gpa, io, .{
    .project_id = "my-project",
    .token_provider = creds.provider(),
    .scope = .read_write,
});
defer client.deinit();
var op = try client.insertInstance("us-central1-a", .{
    .name = "batch-1",
    .machine_type = "e2-micro",
    .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
    .spot = true,
    .max_run_duration_s = 3600,
    .termination_action = .delete,
    .labels = &.{.{ .key = "team", .value = "data" }},
    .metadata = &.{.{ .key = "startup-script", .value = "#!/bin/bash\n./run-batch\n" }},
}, .{});
defer op.deinit();
var done = try client.waitOperation(op.value.ref(), .{});
defer done.deinit();
// No room in the zone: the caller's to try another.
const no_room = if (done.value.failure) |failure| failure.stockout() else false;
```

`InstanceSpec` holds the shape most VMs take: one boot disk from an
image (`.family`, `.image` or a `.path`, with its size and type), one
network interface (`network`, `subnetwork`, `external_ip`), `labels`,
`metadata` (a startup script is the item `startup-script`), network
`tags`, a `service_account` (given the `cloud-platform` scope when it
names none, so its IAM roles alone say what it may do), `spot`, a run
limit and what happens at it, `automatic_restart` and
`deletion_protection`. The client writes it as production took it when
measured, and checks it before sending: names, label and metadata
rules, a boot disk of at least 10 GB, a spot VM not asked to restart on
its own.

What it leaves out (GPUs, local SSDs, more disks or interfaces,
confidential VMs and the rest of Compute's schema) `insertInstanceJson`
sends as written: Compute's `Instance` resource as JSON, paths relative
to the project (`zones/Z/machineTypes/M`) or full URLs, checked only for
a JSON object with an instance name. `insertFromTemplate` names a
global or regional template and the VM; the template gives the rest.

A write needs a client whose `scope` is `.read_write` (or
`.cloud_platform`): `compute.readonly`, the default, takes no write,
and the client refuses one before sending.

## A VM's life

| Call | From | Through | To | Measured |
| --- | --- | --- | --- | --- |
| `insertInstance` | | PROVISIONING, STAGING | RUNNING | DONE in 9 to 13 s |
| `stopInstance` | RUNNING | STOPPING | TERMINATED | 52 to 54 s |
| `startInstance` | TERMINATED | STAGING | RUNNING | 9 to 23 s |
| `suspendInstance` | RUNNING | SUSPENDING | SUSPENDED | 87 to 93 s standard, 281 s spot |
| `resumeInstance` | SUSPENDED | | RUNNING | 12 to 22 s |
| `resetInstance` | RUNNING | | RUNNING | 2 s |
| `deleteInstance` | any | STOPPING | gone | about 50 s |

A write answers its operation before it is DONE as a rule: RUNNING, or
PENDING (production answered a start each way on two days). Wait on
either the same way.

Stopping a stopped VM and starting a running one are no refusals: each
answers an operation, the start DONE at once. A spot VM can be
suspended. `stopInstance` and `deleteInstance` take
`no_graceful_shutdown`, `stopInstance` and `suspendInstance`
`discard_local_ssd`, which a VM with local SSDs must give.

`examples/compute.zig` is the whole life: it shows the insert it would
send, creates a spot VM with a startup script, reads what the script
wrote to the serial console, stops, starts and deletes it
(`zig build example-compute -- --fake --yes` runs it with no network).

## Previews and request ids

Every write has a `*Request` twin (`insertInstanceRequest`,
`stopInstanceRequest`, ...) that runs the same checks and builds the
exact request without sending it: the method, the whole URL and the
body, byte for byte, for a console's confirmation or a log. Credentials
are not part of it.

Every write carries a `requestId`, so a write sent again lands once:
production answered a repeated id with the same operation, while it ran
and after it was DONE. The client makes one for each call when the
caller gives none, and every retry of that call sends it, so a write is
retried as the reads are; a retry begins no later than ten minutes after
the first attempt. A preview makes its own id too, so to send exactly
what was shown, make one with `newRequestId` and give it to both:

<!-- snippet: tests/docs_examples.zig#compute-confirm -->
```zig
test "the exact stop a console would send, for the user to confirm, then sent" {
    var fake: compute.testing.FakeCompute = .init(std.testing.allocator, std.testing.io, .{});
    defer fake.deinit();
    try fake.putInstance(.{ .zone = "us-central1-a", .name = "batch-1" });
    var token: compute.StaticToken = .{ .token = "none" };
    var client = try compute.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .scope = .read_write,
        .transport = fake.transport(),
    });
    defer client.deinit();
    // One request id for the preview and the stop: the stop sends byte
    // for byte what the user confirmed, and lands once if retried.
    var buf: [36]u8 = undefined;
    const id = client.newRequestId(&buf);
    var confirm = try client.stopInstanceRequest("us-central1-a", "batch-1", .{ .request_id = id });
    defer confirm.deinit();
    try std.testing.expectEqual(.POST, confirm.value.method);
    try std.testing.expect(std.mem.indexOf(u8, confirm.value.url, "/zones/us-central1-a/instances/batch-1/stop?requestId=") != null);
    // Confirmed: sent, then waited on.
    var op = try client.stopInstance("us-central1-a", "batch-1", .{ .request_id = id });
    defer op.deinit();
    var done = try client.waitOperation(op.value.ref(), .{});
    defer done.deinit();
    try std.testing.expect(done.value.succeeded());
    var vm = try client.getInstance("us-central1-a", "batch-1");
    defer vm.deinit();
    try std.testing.expectEqual(.terminated, vm.value.status);
}
```

A request id is a UUID, not all zeros.

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
  room (`ZONE_RESOURCE_POOL_EXHAUSTED`), worth trying another zone. The
  client never moves a VM on its own: where it runs is the caller's
  choice.

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
every read takes, the wait on an operation included, and no write;
`.read_write` (`compute`) for a client that writes.

## Testing

`compute.testing.FakeCompute` is Compute Engine in memory, behind
`Client.Options.transport`: zones, VMs, serial output, guest attributes,
machine types, images and operations a test puts in, read back as
production answered when measured, its refusals in production's words.
An operation a test puts in finishes after the number of waits it
gives, with the failure it gives.

The writes work on it as on production: an insert makes the VM
PROVISIONING and its operation RUNNING, and when the operation's wait
answers DONE (after `Options.write_waits`, one by default) the VM is
RUNNING; the lifecycle moves it the same way, from the states
production took each write in, and a write from another state is 501,
saying which. A repeated `requestId` answers its first operation and
changes nothing; a name taken, an unknown machine type or image and a
delete under protection are refused in production's words. Every zone
has e2-micro, e2-small, e2-medium and e2-standard-2, and debian-12's
image is there from the start. `setStockout(zone, true)` puts a zone out
of room, so a caller's next-zone path can be tested; `putTemplate` puts
in a template for `insertFromTemplate`; `finishOperations` finishes
everything still running. Changing a live VM answers 501 until the
module's next milestone.

<!-- snippet: tests/docs_examples.zig#compute-fake -->
```zig
/// Creates the VM in the first of `zones` with room for it.
fn createSomewhere(client: *compute.Client, zones: []const []const u8, spec: compute.InstanceSpec) ![]const u8 {
    for (zones) |zone| {
        var op = try client.insertInstance(zone, spec, .{});
        defer op.deinit();
        var done = try client.waitOperation(op.value.ref(), .{});
        defer done.deinit();
        const failure = done.value.failure orelse return zone;
        if (!failure.stockout()) return error.InsertFailed;
    }
    return error.NoRoom;
}

test "a spot VM in the first zone with room, against the in-memory Compute Engine" {
    var fake: compute.testing.FakeCompute = .init(std.testing.allocator, std.testing.io, .{});
    defer fake.deinit();
    // How production answers is the test's to arrange: no room in -a.
    try fake.setStockout("us-central1-a", true);
    var token: compute.StaticToken = .{ .token = "none" };
    var client = try compute.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = token.provider(),
        .scope = .read_write,
        .transport = fake.transport(),
    });
    defer client.deinit();
    const zone = try createSomewhere(&client, &.{ "us-central1-a", "us-central1-b" }, .{
        .name = "batch-1",
        .machine_type = "e2-micro",
        .image = .{ .family = .{ .project = "debian-cloud", .name = "debian-12" } },
        .spot = true,
    });
    try std.testing.expectEqualStrings("us-central1-b", zone);
    var vm = try client.getInstance(zone, "batch-1");
    defer vm.deinit();
    try std.testing.expectEqual(.running, vm.value.status);
}
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
