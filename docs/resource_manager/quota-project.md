[Docs](../README.md) › [Resource Manager](README.md) › The project charged

# The project charged

Every call is charged to a project, its *consumer*, which must have the
Resource Manager API turned on: "The project checked for activation is
the same project checked for rate quota." It is the project an
`x-goog-user-project` header names, or, with no header, the credential's
own:

| Credential | Charged with no header |
| --- | --- |
| A service account | Its own project |
| A person, through an app's own OAuth client | The OAuth client's project, for every user of the app |
| A person, through gcloud's application default credentials with no quota project | gcloud's ADC client project, 764086051850, where search has worked in every report found |

## None by default

Other modules send the credentials' quota project, which
`GOOGLE_CLOUD_QUOTA_PROJECT` or the ADC file's `quota_project_id` names,
and gcloud writes one into that file by default. Here that breaks a
search that works without one: when the person's quota project has the
API off, every call fails. That is the commonest failure reported for
listing projects, and why Earth Engine's plugin gave up and asks for a
project id instead. gcloud sends no header for any of its project
commands ("so you can create a project before you have a project"), and
neither does this module unless asked:

| `Client.Options.quota_project` | Sent |
| --- | --- |
| `.none` (the default) | No header |
| `.from_credentials` | The credentials' quota project, as other modules send it |
| `.{ .project = "my-billing-project" }` | That project, by id or number |

An app with its own OAuth client turns the API on in the client's
project once, for every user. The searches allow 240 calls a minute per
charged project (and Google documents 4 a second), shared by every user
of that project; one walk every 15 minutes is a call or two each.

## When the project charged refuses

Two refusals name the project charged, and the client keeps it with the
link that fixes it:

- `error.ServiceDisabled`: "Cloud Resource Manager API has not been used
  in project N before or it is disabled. Enable it by visiting URL then
  retry." The link turns the API on.
- `error.QuotaProjectDenied`: the header named a project the caller may
  not use, 403 "Caller does not have required permission to use project
  P. Grant the caller the roles/serviceusage.serviceUsageConsumer role,
  ...", with a link to its IAM page; or one that does not exist, 400
  "Project 'projects/P' not found or deleted.", with no link. Both carry
  `USER_PROJECT_DENIED`.

<!-- snippet: tests/docs_examples.zig#rm-refusal -->
```zig
var list = client.allProjects(.{}) catch |err| switch (err) {
    error.ServiceDisabled, error.QuotaProjectDenied => {
        const r = client.lastConsumerRefusal().?;
        return try std.fmt.allocPrint(gpa, "{s} cannot be charged for this call: {s}", .{
            r.consumer, r.link orelse "no link sent",
        });
    },
    else => return err,
};
defer list.deinit();
```

`lastConsumerRefusal()` lasts until the next call. Neither refusal is
retried, and the client never drops a quota project it was told to send:
the error says what to fix.

## Measured

On 2026-10-17, as a service account in its own project: no header, and
a header naming that project by id or by number, all searched;
`bigquery-public-data`, which no test principal may charge, was the 403;
a project that does not exist was the 400. What a person's credentials
are charged to comes from Google's documentation and from reports of
the failure above; no person's run has measured it.
