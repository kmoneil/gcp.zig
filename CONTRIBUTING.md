# Contributing

Bug reports, fixes and improvements are welcome. For anything larger than a
small fix, open an issue first so the approach can be agreed on.

## Setup

You need Zig 0.17.0, and two programs on the PATH that `zig build test`
runs: [zigvet](https://github.com/kmoneil/zigvet), which reports code
the compiler accepts that is almost certainly wrong, and
[gnarl](https://github.com/kmoneil/gnarl), which measures each
function's complexity (`brew install kmoneil/tap/zigvet
kmoneil/tap/gnarl`, or a binary from either's releases).
[docs/development.md](docs/development.md) lists every build step; these
are the ones to know:

```
zig build test          # unit, property and fuzz-corpus tests
zig build fmt           # zig fmt --check
python3 tools/check_docs.py  # the docs' links, anchors and snippets
zig build test-integration
```

Integration tests skip unless a server is configured. Start the Pub/Sub
emulator and point `PUBSUB_EMULATOR_HOST` at it:

```
gcloud beta emulators pubsub start --project=test --host-port=127.0.0.1:8085
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 zig build test-integration
```

The step also runs `tests/fault_injection.zig`: the whole stack against the
emulator, through a proxy that drops, cuts, delays and rewrites responses.
Those tests need the emulator specifically and never target production.

Each integration suite prints a line as every test starts, and `OK` when it
passes. In CI the step gives up after ten minutes; if it does, the log's
last line, a test name with no `OK` after it, is the test that hung.

The auth integration tests run against Google when `AUTH_TEST_CREDENTIALS`
names a credentials file, of type `authorized_user` or `service_account`;
each test runs when the file is the type it exercises.
[docs/development.md](docs/development.md#auth) shows how.

The metadata server can only be checked where there is one. One test skips
unless a probe answers, and `examples/whoami.zig` shows the same path by
hand. To run it on a VM, with everything named `zigps-` so the cleanup is
obvious:

```
zig build-exe -target x86_64-linux-musl -O ReleaseSafe \
    --dep pubsub --dep auth -Mroot=examples/whoami.zig \
    --dep core -Mpubsub=src/pubsub/root.zig \
    --dep core -Mauth=src/auth/root.zig \
    -Mcore=src/core/root.zig -femit-bin=whoami
gcloud storage cp whoami gs://zigps-oncloud-$USER/whoami
gcloud compute instances create zigps-oncloud-$USER --zone=us-central1-a \
    --machine-type=e2-micro --image-family=debian-12 \
    --image-project=debian-cloud \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --metadata-from-file=startup-script=run.sh   # downloads and runs whoami
gcloud compute instances get-serial-port-output zigps-oncloud-$USER \
    --zone=us-central1-a
gcloud compute instances delete zigps-oncloud-$USER \
    --zone=us-central1-a --quiet
gcloud storage rm -r gs://zigps-oncloud-$USER
```

The instance needs the `cloud-platform` scope: the default scopes leave out
Pub/Sub, so the token comes back fine and the API call fails. Delete the
instance and the bucket as soon as the output is in hand.

To fuzz, run `zig build test -Dfuzz-runner -Dtest-filter=fuzz --fuzz=100K`.
For line coverage, install [kcov](https://github.com/SimonKagstrom/kcov) and
run `zig build coverage`; the report is `zig-out/coverage/index.html`.

For a campaign longer than a nightly's, `tools/vmrun/vmrun
tools/vmrun/jobs/fuzz.sh [JOB...]` fuzzes the nightly's jobs (all of them,
or those named) on every core of a throwaway Linux spot VM, in the project
a service account key names (`GCP_KEY`), for three hours unless
`--timeout MINUTES` says otherwise. It brings the lanes' logs, their grown
corpora and every failure home to `_vmrun/`, and deletes the VM and its
bucket. Run `tools/vmrun/fetch-seeds` first to start from the corpora the
nightlies kept. A fuzzer that sits on one input for ten minutes is called
stalled, and its threads' stacks are kept with the input. The job's header
has the rest; `tools/vmrun/blip-test` checks vmrun itself offline, against
a fake Google.

## Changes

- `main` is protected: open a pull request, and CI must pass before it
  merges. Six checks are required by name: `test`, `release (ReleaseSafe)`,
  `release (ReleaseFast)`, `platforms (macos-latest)`,
  `platforms (windows-latest)` and `coverage`. Renaming one of those jobs,
  or changing a matrix value that appears in its name, leaves every pull
  request waiting for a check that will never report; change the rule for
  `main` in the same breath. The nightly `fuzz` jobs, one per module and
  one per slow property, are not required, because they do not run on
  pull requests.
- A bug fix comes with a test that fails without it. When the fuzzer finds
  a failing input, add that input to the property's corpus. The fuzzer
  saves it as `.zig-cache/f/crash`, and the nightly CI run attaches it as
  the `fuzz-failure-<job>` artifact: a 4-byte little-endian length, then
  the input. `zig build test -Dfuzz-runner -Dmodule=<module>
  -Dtest-filter=fuzz --fuzz` fuzzes one module the way its job does. A
  test that fails while being fuzzed does not fail `zig build`, which
  exits 0 all the same; the saved input and the `input saved to` line
  are the signs, and the nightly job fails on either. A fuzzer that
  stalls saves nothing and holds its job until the fuzzing step's 150
  minutes run out; then the job attaches gdb to whatever is still
  running, and the same artifact holds every thread's backtrace
  (`fuzz-stacks.txt`) and the input each fuzzer was on (`in<N>`: a
  20-byte header whose last four bytes are the length, then the input).
- Name a property test `fuzz <what>: <what it holds>`, and the nightly job
  fuzzes it. A property that costs more than a few milliseconds a run,
  such as one that signs with RSA every time, is named `slow property
  <what>: …` instead, so the module's job skips it, and it gets a job of
  its own in `.github/workflows/ci.yml`, filtered by its name. One that
  builds a client and a fake server every run, a millisecond or more, is a
  `heavy property <what>: …`, and storage's and pubsub's run in jobs of
  their own. A `fault property` drives whole transfers through injected
  faults and costs more still; storage's run nightly in two jobs of their
  own, `fault-storage` and `fault-gzip`, and every test run still runs
  them, under that run's seed. `--fuzz=N`
  runs every matching property N times, so size a job from its
  properties' costs on CI: run the workflow by hand twice, with
  `fuzz_iterations` at two counts such as 2K and 20K, and each job's
  cost per run is the difference in its fuzzing step's time over the
  difference in runs, the build cancelled out. Aim at about half the
  job's 180 minutes. A local run can be three times faster than CI, so
  it only compares properties with each other.
  `zig build test` runs both kinds alike.
- A function over a critical complexity limit for its class fails
  `zig build test`, unless `complexity.baseline` holds it there already and
  it got no worse. The classes are in `complexity.zon`: hot for what runs
  per request, message, chunk or row, cold for the build, tools, tests,
  examples and test-only code, normal for the rest. Before committing,
  `gnarl --diff HEAD` lists each function the change touched, its numbers
  before and after. A new function over a limit is split rather than
  baselined (`gnarl --explain path:line` names the lines worth lifting
  out); a change that improves, renames or moves a baselined function
  runs `gnarl --update-baseline .` and commits the file with it.
- A zigvet finding is fixed in the code, not worked around.
- User-visible changes go in `CHANGELOG.md`. Until 1.0, minor versions may
  break the API; say how in the changelog entry.
- Follow the existing code: `zig fmt`, doc comments on public declarations,
  camelCase functions, snake_case fields and variables, and TitleCase types.
