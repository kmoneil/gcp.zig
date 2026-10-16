[Docs](../README.md) › [Cloud Logging](README.md) › Filters

# Filters

Your filter is sent as you wrote it, in the
[Logging query language](https://docs.cloud.google.com/logging/docs/view/logging-query-language).
The client adds only the clauses you ask for, and joins them so your
meaning cannot change:

```
(
resource.type = "cloud_run_revision" -- your filter
)
AND timestamp >= "2026-10-16T09:00:00Z"
AND severity >= WARNING
AND log_id("run.googleapis.com/stderr")
```

- **Each clause is on a line of its own**, so a trailing `--` comment in
  your filter cannot swallow it.
- **Your filter goes in parentheses.** In this language OR binds tighter
  than AND, so `a OR b AND c` is `(a OR b) AND c`, which a Google
  maintainer verified against the API. An `AND` after the whole of your
  filter already applies to all of it; the parentheses are for readers
  who expect the usual rule.
- **An empty filter gives the clauses alone**, with no leading `AND`,
  which the API refuses as unparseable.
- `Query.filter()` shows the filter as sent. The line and column of a
  server's "Unparseable filter" count in that text.

## The clauses

| Option | Clause |
| --- | --- |
| `since` | `timestamp >= "..."`, in UTC with every digit it needs |
| `until` | `timestamp < "..."` |
| `min_severity` | `severity >= NAME`, one of DEFAULT, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT and EMERGENCY |
| `log_id` | `log_id("...")`, the plain id, such as `run.googleapis.com/stderr` |
| `resource_type` | `resource.type = "..."` |

Values are quoted with `"` and `\` escaped by a backslash and a tab
written `\t`, each of which production read back. Any other control
character is refused (`error.InvalidFilter`), since production was not
shown one.

## How production read filters

Measured on 2026-10-16, against the probe's own entries:

- **Comparisons ignore case**, past ASCII too: `insertId = "caseid"`
  matched `CaseID`, and `textPayload = "mixedcase été"` matched
  `MixedCase Été`.
- **A comparison on a field an entry lacks is false**, `!=` too:
  `labels.missing != "x"` matched nothing, and `NOT labels.missing = "x"`
  matched everything.
- **Strings take `\"`, `\\`, `\t`, a literal tab and `é`.**
- **A field no entry has is refused by name**: `thud = 1` is "Field not
  found: 'thud'." (`error.InvalidFilter`).
- **A bare word or a quoted string is a search** over the entry, and
  lowercase `and` is one too: `insertId = "a1" and insertId = "a2"`
  searched for the word "and".
- **Syntax errors name where parsing stopped**: "syntax error at line 1,
  column 4, token ' '" for a leading `AND`, "column 14, token 'AND'" for
  a trailing one, "syntax error at line 1, token '<EOF>'" with no column
  at the end of the text, and "missing token at line 1, column 1, token
  '('" for an unclosed parenthesis.

For speed, Logging's own advice: name an indexed field (`resource.type`,
`logName`, `severity`, `timestamp`, `labels.*`, `trace`, `insertId`) and
bound the time.
