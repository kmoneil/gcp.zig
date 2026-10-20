[Docs](../README.md) › [Monitoring](README.md) › Alert policies

# Alert policies: what opens an alert, and turning one off

An alert policy says when Cloud Monitoring opens an [alert](alerts.md)
and what it tells people when it does. The client reads policies, and
enables or disables one; nothing else about a policy changes here.
Making, editing and deleting policies, and notification channels, are
not in this module. **Experimental**: new in 0.52.0; the write keeps
its own experimental marker until it has had seven clean nights,
whatever the rest of the module is by then.

```zig
var page = try client.listAlertPolicies(.{ .filter = "enabled=true", .order_by = "display_name" });
defer page.deinit();
for (page.value.policies) |policy| {
    for (policy.conditions) |c| draw(policy.display_name, c.kind, c.filter, c.query);
}
```

## The calls

| Call | What it does |
| --- | --- |
| `Client.listAlertPolicies(options)` | One page of the project's policies, filtered and ordered as written; `totalSize` on every page |
| `Client.getAlertPolicy(id_or_name)` | One policy, by its id or its full `projects/P/alertPolicies/ID` name; another project's name is refused before sending |
| `Client.setAlertPolicyEnabled(id_or_name, enabled)` | Enables or disables one, and answers it as it then stands; a disabled policy opens no alerts |
| `Client.setAlertPolicyEnabledRequest(id_or_name, enabled)` | The exact request that sends, built without sending it, for a confirmation |

An `AlertPolicy` carries its display name, `enabled`, severity,
combiner (`and`, `or`, `and_with_matching_resource`), documentation
(content, MIME type, subject), user labels, notification channels'
names, the creation and latest mutation records (who and when), and
`invalid` when production holds the policy invalid, which opens
nothing. Each `Condition` has its name, display name and kind:
`threshold`, `absence`, `log_match`, `mql`, `promql` or `sql`. The
fields a console shows are decoded (the filter or the query, the
comparison and threshold value, the duration, the aggregations and the
trigger), and `raw` holds the whole condition as production sent it,
for the rest (denominators, forecasts, PromQL labels, SQL schedules)
and for kinds Google adds later, which decode as `.unknown`.

## Enabling and disabling

`setAlertPolicyEnabled` sends `PATCH .../alertPolicies/ID?updateMask=enabled`
with `{"enabled":false}` or `{"enabled":true}`, and nothing else can
go with it. That matters: **a patch without a mask replaces the whole
policy**, and production reads an absent `enabled` as true, so the
field always goes on the wire. A console that confirms first shows
`setAlertPolicyEnabledRequest`'s method, URL and body, byte for byte
what the write sends.

Production answers a repeat with 200, moving the mutation record each
time, so a patch is retried as the reads are. The token needs the
`monitoring` or `cloud-platform` scope: `monitoring.read` lists and
gets policies and is refused the patch ("Request had insufficient
authentication scopes."), and `monitoring.write` is refused all of
them. On the IAM side, `roles/monitoring.alertPolicyViewer` reads and
`roles/monitoring.alertPolicyEditor` (or `roles/monitoring.editor`)
writes.

## Filters and orders

The `filter` and `order_by` are sent as written, in Google's sorting
and filtering language over `name`, `display_name`,
`documentation.content`, `documentation.mime_type`, `user_labels`
(`user_labels.team="ingest"` or `user_labels['team']`),
`conditions.size`, `combiner`, `enabled` and `notification_channels`.
Measured on 2026-10-20:

- `display_name=starts_with("x")`, `display_name:"x"`, `enabled=false`,
  `user_labels.k="v"`, `conditions.size>1` and `combiner="AND"`
  matched, joined with `AND`.
- **`severity` is not a filter field**: 400 "... No such field:
  severity." A bare word is the same 400 naming the word.
- `order_by = "display_name"` sorts ascending and `"-display_name"`
  descending; `"display_name desc"` is a 400. **Without an order,
  production sorts by name.**
- `totalSize` comes on every page; a page size of 0 or 1,001 answered
  every policy measured.

## What production showed

- Five condition kinds made and read back: threshold, absence, log
  match, MQL and PromQL. A SQL condition needs a Log Analytics view:
  without one, production refused it ("No alertable views found in
  provided query, at least one is required.").
- A policy nobody has is a 404 whose words name the project id on a
  get ("Failed to find alert policy 1234567890 in extractctl.") and the
  project's number on a patch ("... in 82150720798.").

To silence a policy for a while rather than turn it off, a
[snooze](snoozes.md) closes its open alerts and opens none until it
ends.

In tests, `monitoring.testing.FakeMonitoring.putAlertPolicy` puts
policies in: [Testing](testing.md#alert-policies).
