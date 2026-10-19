[Docs](../README.md) › [Monitoring](README.md) › Alerts

# Alerts: the incidents open in a project

An alert is the violation of an alert policy: Cloud Monitoring opens one
when a policy's condition fires and closes it when the condition clears
or the policy is deleted. The API reads them only; nothing here (or
anywhere in `monitoring.googleapis.com`) can make, change or close one.
Alert policies themselves, notification channels and the rest of the
configuration plane are not in this module.

```zig
var page = try client.listAlerts(.{ .open_only = true });
defer page.deinit();
for (page.value.alerts) |alert| {
    draw(alert.policy.display_name, alert.policy.severity, alert.open_time);
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listAlerts(options)` | One page of the project's alerts: filtered, ordered by `open_time` or `close_time`, with production's `totalSize` estimate |
| `Client.getAlert(id_or_name)` | One alert, by its id or its full `projects/P/alerts/ID` name; another project's name is refused before sending |

An `Alert` carries the snapshot of the policy that opened it (`name`,
`display_name`, `severity`, `user_labels`), the metric and resource
preserved from the condition that fired, kept even after the close, the
resource metadata's user labels, its system labels as the JSON they came
as (`system_labels`, a `std.json.Value`: Google defines the values as
strings, booleans or lists of strings), and a log-based alert's
extracted labels. `close_time` is null while the alert is open, as
production leaves the field out. Ids are system-assigned and no numbers:
production assigned `0.oe0ehmpm95z2` when measured.

## The filter

Google's documentation describes the `filter` as matching "any fields
belonging to the alert or its subfields", but production parses the
structured filter language (measured 2026-10-19): `state="OPEN"`,
`state=OPEN`, `severity="WARNING"` and `policy.display_name="x"` each
matched, and a bare word was a 400, "Restriction must have a left-hand
side and a right-hand side". `open_only = true` sends `state="OPEN"`
for you, and is refused beside a `filter` of your own.

`order_by` names the two fields production sorts by (`orderBy=severity`
was a 400); unset, production answers newest-opened first. Production's
direction words differ from its documentation too: a bare field name
sorts descending, not the documented ascending, and an `asc` keyword
the documentation does not mention chooses ascending, so this client
always sends the direction (`open_time asc`, `close_time desc`, and so
on). An open alert's null `close_time` sorts before every closed one's.
A page holds at most 50 alerts unless `page_size` asks for more, up to
1,000.

## What production showed

Measured on 2026-10-19 with a real incident (a threshold policy on a
metric the probe wrote; the gated suite repeats it):

- A policy on a metric descriptor just created is refused 404, "could
  take up to 10 minutes to become available"; with a point written
  first it was accepted 1 s later.
- The alert opened **245 s** after the first write over the threshold
  (condition duration 0s, alignment 60s).
- Deleting the policy **closed its alert** 91 s later: `closeTime` set,
  the metric and resource kept, and the alert still listable
  (`state="OPEN"` then matches nothing).
- Every non-empty list answer carried `totalSize`; an answer with no
  matches was `{}`.

In tests, `monitoring.testing.FakeMonitoring` holds alerts a test puts
in: [Testing](testing.md#alerts). `examples/monitoring_alerts.zig
--fake` draws the console's open-incidents widget offline.
