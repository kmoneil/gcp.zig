[Docs](../README.md) › [Cloud Logging](README.md) › Tailing

# Tailing

A log explorer's live view is a tail: the newest entries of a filter,
each once, as they arrive. Here it is a poller over `entries.list`.

## Why polling

Logging has an `entries:tail` call, a bidirectional stream. Over HTTP/1.1,
the only transport this library has, it does not work: measured, a
complete request got `[]` and the end of the stream within a second, and
a request body left open drew a 502 from Google's front end after 10
seconds. Every Google client tails over gRPC or refuses to tail over
REST.

## A tail

<!-- snippet: tests/docs_examples.zig#logging-tail -->
```zig
var tail = try client.tail(.{
    .filter = "resource.type = \"cloud_run_revision\"",
    .min_severity = .warning,
});
defer tail.deinit();
while (polls_left > 0) : (polls_left -= 1) {
    try io.sleep(.fromSeconds(5), .awake);
    var batch = try tail.poll();
    defer batch.deinit();
    for (batch.value.entries) |entry| show(entry);
    if (batch.value.behind) note("catching up");
    if (batch.value.stopped) |_| note("paused for the read quota");
}
```

You call `poll` at your own pace; every 5 to 10 seconds suits a person
watching. Each poll is one `entries.list` call when there is little to
read, of the 60 a minute the project's readers share, so every 5
seconds leaves most of them to others.

## The window

Each poll reads a window, oldest first, with literal bounds:

- **From the cursor, less `overlap_ms`** (60 s by default), so entries
  that arrived late are read again;
- **to now, less `settle_ms`** (5 s), so the newest have time to come in.

It reads the window's pages, up to `max_calls_per_poll` (3), and drops
what it returned before, by log name, timestamp and `insertId`: the
server's own key for duplicates, which it applies only within one
result. Then the cursor moves to the end of the window.

Entries arrive late and out of order: by seconds normally, by hours
during incidents. **An entry that arrives later than the overlap is
never returned.** Every poller has that trade, gcloud's included.
`stats().late` counts the late entries the overlap caught, and
`stats().latest_late_ms` says how close the latest came to the overlap's
edge, which tells you whether to widen it.

## Falling behind, and stopping

When a window holds more than `max_calls_per_poll` pages, the poll
returns what it read with `behind` set, and keeps the window with its
next page's token. The next poll asks for that page, so it goes on where
this one stopped. A fresh query would read again what this one passed,
and a run of entries at one timestamp that filled a poll's calls would
hold the tail there for good. A window left for more than an hour is
begun again from the cursor instead.

When the read budget or the server's quota stops a poll, or a call fails
after entries came, the poll returns what it had with `stopped` set, and
the next one tries again where it stopped. A kept page token the server
refuses is dropped, and the next poll begins a window from the cursor.
Only a first call that fails for another reason is an error, and the
cursor stays where it was.

## Keeping the cursor

`tail.cursor()` is how far the tail has read: the end of the last window
it finished, or the last entry it returned past that. Keep it, and a
tail made later with `.from = cursor` resumes there, past the entry it
names, without returning it again.

## Memory

The keys kept against duplicates are those of the overlap window, at
most 100,000. Past that many entries in one overlap, the oldest keys go,
and their entries can come twice.

For continuous, high-volume reading, Logging's own advice is a sink to
Pub/Sub; a tail by polling is for a person watching.
