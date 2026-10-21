[Docs](README.md) › Development

# Development

Building, testing, fuzzing and measuring coverage, and running the
integration suites against the emulators and Google. How changes are
made and reviewed is in [CONTRIBUTING.md](../CONTRIBUTING.md).

**On this page:** [Build steps](#build-steps) · [Fuzzing](#fuzzing) ·
[Coverage](#coverage) · [Continuous integration](#continuous-integration) ·
[Integration tests](#integration-tests)

## Build steps

```sh
zig build test                         # unit, property and fuzz-corpus tests
zig build test --seed=0x1234           # same, with different pseudo-random inputs
zig build test -Doptimize=ReleaseFast  # same, optimized; also ReleaseSafe
zig build test -Dfuzz-runner --fuzz    # coverage-guided fuzzing (see below)
zig build test-integration             # needs a server, see below
zig build test-integration-gcp         # against Google, see below
zig build coverage                     # line coverage; needs kcov (see below)
zig build bench-crc32c                 # how fast this machine computes CRC-32C
zig build example-publish -- orders 5
zig build example-worker -- orders orders-worker
zig build example-whoami               # which credentials, and the topics they see
zig build fmt                          # zig fmt --check
python3 tools/check_docs.py            # the docs' links, anchors and snippets
python3 -I tools/discovery_drift.py OLD.json NEW.json  # what changed between two discovery documents
```

`zig build test` also compiles every example and the suites that run
against Google, so none of them can rot between runs. `zig build
test-unit` runs the same tests and compiles nothing else, which is what
CI's optimized jobs run.

## Fuzzing

Every fuzz property also runs in `zig build test`: on its seed corpus and
on a few hundred pseudo-random inputs. Zig's default x86_64 backend emits
no coverage instrumentation, so `-Dfuzz-runner` builds the tests with
LLVM. Every test build, fuzzing or not, runs under `tools/test_runner.zig`,
Zig 0.17's test runner with one fix (see
[Zig 0.17 workarounds](zig-std-workarounds.md)). The fuzzer keeps its
corpus in `.zig-cache/f`, so only one fuzzing run per checkout at a time;
`-Dtest-filter=fuzz` skips the unit tests that are not fuzz targets. When
it finds a failing input, it saves it to `.zig-cache/f/crash`: a 4-byte
little-endian length, then the input. `zig build` still exits 0 then, so
look for that file, or for "input saved to" in the output, as CI does.
Add the input to that property's corpus, so the fix stays covered.

## Coverage

`zig build coverage` runs the unit tests under
[kcov](https://github.com/SimonKagstrom/kcov) and writes the report to
`zig-out/coverage/index.html`. `tools/coverage_summary.py` prints it as
Markdown, including every line no test reached. kcov counts lines, not
branches, and sees only code the compiler kept.

## Continuous integration

CI runs the unit tests on Linux, macOS and Windows, and on Linux also in
ReleaseSafe and ReleaseFast, and core's on a baseline CPU, whose build
computes CRC-32C with tables rather than instructions; the docs check;
the integration tests and examples against the emulators; and coverage,
whose summary and report are attached to each run.

Every night it also fuzzes, one job per module, each starting from the
corpus that earlier nights built up for it (kept for 30 days as the
artifact `fuzz-corpus-<job>`), and jobs of their own for
the properties too slow to share one: auth's RSA signing
(`slow-auth`), pubsub's Publisher and Subscriber models (`slow-pubsub`,
`slow-subscriber`) and its heavy properties (`heavy-pubsub`), storage's
slow and heavy properties (`slow-storage`, `heavy-storage`), and its
fault properties, which drive whole transfers through injected faults
(`fault-storage`, `fault-gzip`), Firestore's model of writes against
its fake (`heavy-firestore`), Logging's tail by polling against its
fake (`slow-logging`), Resource Manager's walk of every page against its
fake (`slow-resource_manager`), and KMS's model of calls against its fake
with checksum faults injected (`slow-kms`). A test that fails while
being fuzzed fails its job, and the input is attached to the run as
`fuzz-failure-<job>`, such as `fuzz-failure-pubsub`.

## Integration tests

Integration tests skip unless a server is configured.

### Pub/Sub

```sh
gcloud beta emulators pubsub start --project=test --host-port=127.0.0.1:8085
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 zig build test-integration
```

The emulator binds to IPv6 localhost unless given `--host-port`. The
same step runs `tests/fault_injection.zig`: the whole stack against the
emulator, through a proxy that drops, cuts, delays and rewrites
responses. Those tests need the emulator specifically and never target
production.

Or a real project. Every test creates `zigps-*` resources and deletes
them. With the project's number, the dead-letter test grants Pub/Sub's
service agent the roles it needs on its own topic and subscription;
without it, that test skips. The grants go with the resources.

```sh
PUBSUB_TEST_PROJECT=my-project PUBSUB_TEST_TOKEN=$(gcloud auth print-access-token) \
    PUBSUB_TEST_PROJECT_NUMBER=$(gcloud projects describe my-project --format='value(projectNumber)') \
    zig build test-integration
```

The unit test that holds `FakePubSub` to the emulator, over random
scripts of 400 calls, eight seeds; it skips without the emulator, and
`PUBSUB_DIFF_SEED` replays one seed:

```sh
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 \
    zig build test -Dmodule=pubsub "-Dtest-filter=emulator differential"
```

And the one that holds the fake's reference to production: one script
of the fake's model property, replayed against a real project, slowly,
because production answers in its own time. `PUBSUB_REPLAY` names the
script: `corpus:3` for the fourth of the property's own, `seed:17` for
240 random bytes, `hex:...` for the bytes themselves. It makes two
topics, three subscriptions and up to three snapshots named
`zigps-f-*`, deletes them, and grants nothing. A script takes from two
minutes to half an hour, most of it waiting; a token lasts an hour.

```sh
PUBSUB_REPLAY=seed:17 PUBSUB_TEST_PROJECT=my-project PUBSUB_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test -Dmodule=pubsub "-Dtest-filter=production replay"
```

### auth

Against Google's token endpoint, with the file gcloud's login wrote, and
a read-only Pub/Sub call with the token it gets:

```sh
AUTH_TEST_CREDENTIALS=$HOME/.config/gcloud/application_default_credentials.json \
    PUBSUB_TEST_PROJECT=my-project zig build test-integration
```

### Firestore

Three suites, each skipping without what it needs. Against the
emulator, every test in a project of its own:

```sh
gcloud emulators firestore start --host-port=127.0.0.1:8087
FIRESTORE_EMULATOR_HOST=127.0.0.1:8087 zig build test-integration
```

The unit test that holds `FakeFirestore` to the emulator, over 400
random queries and aggregations per seed, five seeds; it skips without
the emulator, and `FIRESTORE_DIFF_SEED` replays one seed:

```sh
FIRESTORE_EMULATOR_HOST=127.0.0.1:8087 \
    zig build test -Dmodule=firestore "-Dtest-filter=emulator differential"
```

Against production, in a named database made for the run and deleted
after it; the suite refuses `(default)`. Firestore's free quota covers
one database per project, the first made, so in a project that already
has one, the run is billed, a fraction of a cent. A deleted database's
id cannot be used again for about 5 minutes.

```sh
DB=zigps-fs-$(openssl rand -hex 4)
gcloud firestore databases create --database=$DB --location=us-central1
GCP_TEST_PROJECT=my-project FIRESTORE_TEST_DATABASE=$DB \
    GCP_TEST_TOKEN=$(gcloud auth print-access-token) zig build test-integration-gcp
gcloud firestore databases delete --database=$DB
```

The emulator suite runs against production too, in the same kind of
database, when `FIRESTORE_TEST_PRODUCTION=1` is set and
`FIRESTORE_EMULATOR_HOST` is not. Each test empties the database after
itself. Two of its queries need composite indexes there, which the
emulator never asks for; make them before the run, and wait for them to
be ready:

```sh
gcloud firestore indexes composite create --database=$DB \
    --collection-group=items --field-config=field-path=rank,order=descending \
    --field-config=field-path=__name__,order=ascending
gcloud firestore indexes composite create --database=$DB \
    --collection-group=cities --field-config=field-path=state,order=ascending \
    --field-config=field-path=population,order=ascending
FIRESTORE_TEST_PRODUCTION=1 GCP_TEST_PROJECT=my-project FIRESTORE_TEST_DATABASE=$DB \
    GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test-integration -Dtest-filter=firestore_integration
```

### Cloud Logging

Cloud Logging has no emulator, so its tests need a real project and a
token that may write and read logs. Each test writes its entries to a
`zigps-lg-*` log of its own, through `entries:write` by hand, and deletes
the log after; entries a crashed run leaves expire with `_Default`'s 30
days. Reads are free, and the entries fit far inside the free ingestion.
Logging shows what was written after about 13 seconds, so the tests poll,
and a run takes about five minutes. The last test replays a set of
scripts against production and against `FakeLogging`, and fails on any
answer the two do not share.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test-integration-gcp -Dtest-filter=logging
```

### Resource Manager

Resource Manager has no emulator, so its tests need a token and the id
of a project its principal can see. They only read: nothing is created,
enabled or granted, and calls are free. Two tests name
`bigquery-public-data` as the quota project, which no test principal may
charge, to record production's refusal. The last test replays a set of
scripts against production and against `FakeResourceManager`, set up as
production answered, and fails on any answer the two do not share. A run
takes a few seconds.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test-integration-gcp -Dtest-filter=resource_manager
```

### Error Reporting

Error Reporting has no emulator, so its tests need a project with the
API on and a token that may report errors and read and update groups
(Editor may). Each run reports a few errors of its own through
`events.report`, which the module never calls, under the service
`zigps-er-<run>`, with the run id in every frame so no other run's
errors share their groups. Error Reporting keeps them 30 days; there is
no way to delete one group's. Statuses change only on those groups, and a
muted one is opened again whatever happens. The first test asks
production and `FakeErrorReporting`, fed the same errors, ten group-stats
queries and fails on any answer the two do not share. Calls are free; a
run takes about a minute.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test-integration-gcp -Dtest-filter=error_reporting
```

### Monitoring

Cloud Monitoring has no emulator, so its tests need a project with the
API on and a token that may write and read metrics and create and delete
descriptors (Editor may). Each run writes only under
`custom.googleapis.com/zigps-<run>/` and deletes every descriptor there
as it ends, failed or not. The tests write every value type and read it
back, run a `Recorder` over three intervals, and replay one script of 60
operations against production and `FakeMonitoring`, failing on any
outcome the two do not share; an operation production answers with a
5xx is sent again. Writes are free and the reads far inside the free
million series a month; a run takes about a minute.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    zig build test-integration-gcp -Dtest-filter=monitoring
```

### KMS

Cloud KMS has no emulator, so its tests need a key ring kept for them,
`KMS_TEST_KEY_RING`, in `KMS_TEST_LOCATION` (us-central1 when unset), on
which the token's principal holds Cloud KMS Admin and Cloud KMS CryptoKey
Operator; Editor cannot use keys. Each run makes software keys with a
1-day destroy delay, `zigps-<run>-<what>`, and schedules every version
of them for destruction as it ends. A key cannot be deleted until its
versions are, so each run starts by sweeping what earlier runs left:
destroyed versions deleted, then their keys, and any empty `zigps-` key
ring but the kept one. The first test runs one script of 81 operations
against production and `FakeKms`, failing on any outcome the two do not
share; the second reads what only production has. A run bills eight
versions for about a day, a cent or two, and takes about a minute.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    KMS_TEST_KEY_RING=my-test-ring zig build test-integration-gcp -Dtest-filter=kms
```

### BigQuery

BigQuery has no emulator, so its suite needs a project with the API on
and a token for the `bigquery` or `cloud-platform` scope whose principal
may run queries and make a dataset there (BigQuery Job User and Data
Editor, or Editor). It
reads the public samples, makes a `zigps_<run>` dataset labelled
`zigps=suite` through the client's own DDL, runs the script described
in [the BigQuery testing guide](bigquery/testing.md) against production
and then against `FakeBigQuery` seeded from production's answers,
failing on any outcome the two do not share, and drops the dataset; a
crashed run's is dropped by the next once a day old. Every query sets a
bytes limit of 100 MB or less: about 100 MiB billed a run, inside the
free tier. About two minutes.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    BIGQUERY_TEST=1 zig build test-integration-gcp -Dtest-filter="bigquery:"
```

### Secret Manager and bucket settings

Secret Manager has no emulator, so its tests need a real project. They
create `zigps-*` secrets labelled `zig-gcp-test` and delete them, and
sweep up anything a crashed run left behind. `GCP_TEST_LOCATION` adds the
regional tests. The same project runs the Cloud Storage bucket tests,
which make `zigps-settings-*` buckets with soft delete off and delete
them; they need Storage Admin there.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp
```

### Cloud Storage on the emulator

Against fake-gcs-server, on its memory backend, the one that keeps
versions. Every test creates a `zigps-*` bucket and deletes it.

```sh
docker run -d -p 4443:4443 fsouza/fake-gcs-server:1.56.1 -backend memory -scheme http -port 4443
# Or without Docker: go install github.com/fsouza/fake-gcs-server@latest
fake-gcs-server -backend memory -scheme http -port 4443
STORAGE_EMULATOR_HOST=http://127.0.0.1:4443 zig build test-integration
```

The emulator serves the paths signed URLs use only for the host they
name, so those tests need `-public-host`, as CI passes it:

```sh
docker run -d -p 4443:4443 fsouza/fake-gcs-server:1.56.1 -backend memory -scheme http -port 4443 \
    -public-host 127.0.0.1:4443
```

### Notifications on both emulators

fake-gcs-server publishes a bucket's notifications only to the Pub/Sub
emulator its own environment names, so the two must reach each other,
as they do in CI:

```sh
docker network create emulators
docker run -d --name pubsub --network emulators -p 8085:8085 \
    gcr.io/google.com/cloudsdktool/google-cloud-cli:emulators \
    gcloud beta emulators pubsub start --project=test --host-port=0.0.0.0:8085
docker run -d --name fake-gcs --network emulators -p 4443:4443 \
    -e PUBSUB_EMULATOR_HOST=pubsub:8085 \
    fsouza/fake-gcs-server:1.56.1 -backend memory -scheme http -port 4443 -public-host 127.0.0.1:4443
PUBSUB_EMULATOR_HOST=127.0.0.1:8085 STORAGE_EMULATOR_HOST=http://127.0.0.1:4443 \
    zig build test-integration
```

Without Docker, start fake-gcs-server with
`PUBSUB_EMULATOR_HOST=127.0.0.1:8085` in its environment.

### Cloud Storage against a real bucket

For what an emulator cannot show: every precondition enforced, checksums
checked by the server, gzip transcoding, uploads and downloads cut
mid-body that resume against Google itself, and transfers a second
client carries on from a checkpoint. Objects live under `zig-gcp-test/`
and are deleted. The token needs Storage Object Admin on the bucket,
which must not have object versioning on. It moves about 5.7 GiB over
the wire, 1 GiB of it in one object at a time.

```sh
GCP_TEST_BUCKET=my-bucket GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp
```

### Signed URLs and POST policies

Against a real bucket, the only place a signature is ever checked, and
the only place Cloud Storage says what it makes of a policy's
conditions. Name a key file, an account the token may sign as through
IAM, or both: each test runs once per signer. That account needs Storage
Object Admin on the bucket, since a URL or a policy grants what its
signer may do.

```sh
GCP_TEST_BUCKET=my-bucket GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    GCP_TEST_SIGNER_KEY=key.json GCP_TEST_SIGNER_EMAIL=signer@my-project.iam.gserviceaccount.com \
    zig build test-integration-gcp
```

### Requester pays

As someone other than the bucket's owners: a requester pays bucket, and
an account with Storage Object Admin on it that may bill
`GCP_TEST_PROJECT` (Service Usage Consumer there) and that the token may
sign as through IAM. Without them those tests skip; the owners' test
needs `GCP_TEST_PROJECT` alone.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    GCP_TEST_REQUESTER_BUCKET=their-bucket GCP_TEST_REQUESTER_EMAIL=requester@my-project.iam.gserviceaccount.com \
    GCP_TEST_REQUESTER_TOKEN=$(gcloud auth print-access-token --impersonate-service-account=requester@my-project.iam.gserviceaccount.com) \
    zig build test-integration-gcp -Dtest-filter="requester pays"
```

### Encryption keys

The customer-supplied key tests draw keys of their own and need
`GCP_TEST_PROJECT` alone; the Cloud KMS test also needs a key in
us-central1 that the project's Cloud Storage service agent may use.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    GCP_TEST_KMS_KEY=projects/my-project/locations/us-central1/keyRings/my-ring/cryptoKeys/my-key \
    zig build test-integration-gcp -Dtest-filter="keys:"
```

### Access control lists and HMAC keys

The ACL tests make buckets of their own, as the bucket tests do, with
public access prevention enforced so no list they write can grant the
public anything. The HMAC key tests make keys for the service account
`GCP_TEST_HMAC_ACCOUNT` names, sign a GET, a PUT and a POST policy with
a fresh key and use them with no credentials, and delete every key they
made, and any a crashed run left for that account. The token needs
`storage.hmacKeys.*` (HMAC Key Admin, or Editor), which Storage Admin
does not grant.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
    GCP_TEST_HMAC_ACCOUNT=signer@my-project.iam.gserviceaccount.com \
    zig build test-integration-gcp -Dtest-filter="ACLs" -Dtest-filter="HMAC"
```

### Notifications against Google

A bucket in the project, and a token allowed to manage its notifications
and to create Pub/Sub topics and subscriptions and set their policies.
Each test makes a `zigps-ntf-*` topic and subscription, and a
configuration for objects under that name, and deletes them all, even
when it fails.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_BUCKET=my-bucket \
    GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp -Dtest-filter="notifications against Google"
```

### An import topic against Google

The one test that watches Pub/Sub read a bucket: it uploads an object
of three lines, makes its topic an [import topic](pubsub/import-topics.md)
over the bucket, and waits for the three messages, which took 73
seconds when measured. Besides the variables above it needs a bucket
that Pub/Sub's service agent,
`service-{project number}@gcp-sa-pubsub.iam.gserviceaccount.com`, may
read (`storage.buckets.get`, `storage.objects.list` and
`storage.objects.get`: Storage Object Viewer and Storage Legacy Bucket
Reader on the bucket give them), and the project's number. The test
grants nothing on the bucket. It makes the agent a publisher of its own
topic, which goes with the topic.

```sh
GCP_TEST_PROJECT=my-project GCP_TEST_BUCKET=my-bucket GCP_TEST_IMPORT_BUCKET=my-bucket \
    GCP_TEST_PROJECT_NUMBER=$(gcloud projects describe my-project --format='value(projectNumber)') \
    GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
    zig build test-integration-gcp -Dtest-filter="an import topic against Google"
```
