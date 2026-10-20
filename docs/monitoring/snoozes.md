[Docs](../README.md) › [Monitoring](README.md) › Snoozes

# Snoozes: silencing a policy for a while

A snooze names up to 16 [alert policies](policies.md) and an interval.
From its start, Cloud Monitoring closes their open [alerts](alerts.md)
and opens none until its end; then they alert again. **Experimental**:
new in 0.52.0, the writes with their own marker, as the policy write
has.

```zig
const now = std.Io.Clock.real.now(io);
var snooze = try client.createSnooze(.{
    .display_name = "deploy window",
    .policies = &.{policy_name},
    .start = now,
    .end = .{ .nanoseconds = now.nanoseconds + std.time.ns_per_hour },
});
defer snooze.deinit();
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.createSnooze(spec)` | Makes one; never sent twice once it may have left |
| `Client.listSnoozes(options)` | One page, newest start first; `active_at` asks for the ones holding at a time |
| `Client.getSnooze(id_or_name)` | One snooze |
| `Client.endSnooze(snooze, at)` | Ends it at `at`, in the form production takes for its state |
| `Client.createSnoozeRequest(spec)`, `Client.endSnoozeRequest(snooze, at)` | The exact request each write sends, built without sending it, for a confirmation |

A `Snooze` carries its name and id, display name, the policies' full
names, its filter (resource labels narrowing it to some of one
policy's alerts), and its `start` and `end`, in whole seconds as
production keeps them. `stateAt(now)` says whether it is upcoming,
active or ended; `cancelled()` whether it was cancelled (an interval
of no length).

**Snoozes cannot be deleted**, and their policies and filter cannot
change: production has no delete, and refuses a change to the
criteria. An ended one stays in the project's history.

## Making one

`NewSnooze` is checked before sending as production checks one: a
display name of 1 to 512 characters, 1 to 16 policies (ids, or this
project's full names), a filter only with exactly one policy, and an
end at least a minute after the start. The start must not be in the
past; production allows 15 s of skew, and only it can judge that, so a
start of "now" works. Production does **not** check that the policies
exist, and has no whole-minutes rule (a 90 s snooze was made).

Every create that lands makes a snooze nobody can delete, so a create
that may have reached the server is never sent again: only a refused
connection or a failed name lookup is retried. Any other failure comes
back as an error; list the snoozes to see whether it landed.

## Listing

Production's filter takes only `interval.start_time` and
`interval.end_time`, compared with `>=` or `<=` to a quoted time,
joined by `AND`: `>`, `<`, `=`, `OR`, an unquoted time and any other
field (`display_name` included) were refused. `active_at` writes the
one that answers "which are holding now":
`interval.start_time <= "T" AND interval.end_time >= "T"`.

## Ending one early

Production takes a different patch for each state, so `endSnooze`
takes the snooze as read and sends the one it needs at `at`:

| The snooze at `at` | What goes | Why |
| --- | --- | --- |
| Active for a minute or more | `updateMask=interval.end_time`, the end at `at` | The plain case |
| Active for less | The end set to its start: cancelled | Production refuses one shorter than a minute "unless the snooze is being canceled, in which case it should be of length 0" |
| Upcoming | `updateMask=interval.start_time,interval.end_time`, both at `at`: cancelled | "An upcoming snooze's start and end time must be set to the current time to cancel it." |
| Ended or cancelled | Nothing: `error.InvalidOptions` | Production refuses any change to one |

`at` goes in whole seconds. Give `endSnoozeRequest` the same snooze
and `at` to show the same request. A repeat after a patch that landed
is refused ("Cannot update a snooze that already ended, or that was
canceled."), so a lost answer is followed by a read: a snooze that
ended by `at` is the answer.

## Scopes and roles

Reads take `monitoring.read`; creating and ending take `monitoring` or
`cloud-platform` (a `monitoring.read` token is refused, and
`monitoring.write` is refused every call here, reads included). On the
IAM side, `roles/monitoring.snoozeViewer` reads and
`roles/monitoring.snoozeEditor` makes and ends; `roles/monitoring.viewer`
reads snoozes too.

## What production showed

Measured on 2026-10-20 in extractctl with a real alert: it **closed one
second after the snooze's start**, and no other opened while the
snooze held; ended by hand once it had run a minute, a new alert
opened about 77 s later, the condition still true. A create's answer
carries the times as sent; reads after keep whole seconds.

In tests, `FakeMonitoring` takes snoozes through the API and closes
the alerts they hold over: [Testing](testing.md#snoozes).
