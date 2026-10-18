[zig-gcp](../README.md) › Docs

# zig-gcp documentation

Start with [Essentials](essentials.md), which every module shares, and
[Credentials](auth.md), which every production program needs; then the
guide for the service at hand. Each guide says what was measured against
Google, not only what Google documents, and where the emulators differ.

## 🧭 Every module

| Guide | What's in it |
| --- | --- |
| [Essentials](essentials.md) | Clients and handles, endpoints and emulators, results and memory, errors and `Diagnostics`, retries, time limits and cancellation, logging, and testing code that uses this library |
| [Credentials](auth.md) | `findDefault` and where it looks, user logins, service account keys, workload identity federation, impersonation, static tokens, and signing |
| [IAM on every resource](iam.md) | Reading, granting, revoking and testing permissions on buckets, topics, subscriptions and secrets, and where the services differ |

## 📨 Pub/Sub

| Guide | What's in it |
| --- | --- |
| [Overview](pubsub/README.md) | A first program, the calls, pulling, retries, limits, and where the emulator differs |
| [Subscribing](pubsub/subscribing.md) | `Subscriber`, a worker loop that extends leases and shuts down cleanly; exactly-once delivery; knowing whether an ack held |
| [Publishing](pubsub/publishing.md) | `Publisher`, which batches from many tasks; caps, ordering keys and compression |
| [Topics and subscriptions](pubsub/topics-and-subscriptions.md) | Dead letters, retry policies, filters, retention, expiration, labels, updates, and IAM |
| [Delivery](pubsub/delivery.md) | Push, BigQuery and Cloud Storage subscriptions: the body options, the export states, and changing kind |
| [Replaying and purging](pubsub/replay.md) | Snapshots, seeking back to replay or ahead to purge, and detaching a subscription |
| [Schemas](pubsub/schemas.md) | Schemas and their revisions, a topic that takes only what fits, and what a subscriber reads off a message |
| [Message transforms](pubsub/transforms.md) | JavaScript functions Pub/Sub runs on a topic's or a subscription's messages, and why the emulator cannot test one |
| [Import topics](pubsub/import-topics.md) | A topic that fills itself from a bucket or from another cloud, and the state of its source |
| [Testing](pubsub/testing.md) | An in-memory Pub/Sub for your own tests, with production's answers, a clock the test moves and faults on request (experimental) |

## 🪣 Cloud Storage

| Guide | What's in it |
| --- | --- |
| [Overview](storage/README.md) | A first program, and every call with the guide that covers it |
| [Transfers](storage/transfers.md) | Files and streams of any size, parallel uploads and downloads, and checkpoints that carry a transfer on in a later process |
| [Checksums and compression](storage/checksums-and-compression.md) | CRC-32C in both directions and at the CPU's speed, objects stored gzip-compressed, and compressing on upload |
| [Writing objects](storage/writing-objects.md) | Preconditions, retries and idempotency tokens, metadata after the upload, compose, and copies that change what they carry |
| [Signed URLs and POST policies](storage/signed-urls.md) | Requests and browser uploads without credentials, and who can sign them |
| [Buckets](storage/buckets.md) | Settings and lifecycle rules, versions and soft delete, retention and holds, requester pays, IAM |
| [Access control lists](storage/acls.md) | Per-object grants on buckets without uniform access: reading, changing safely, canned lists |
| [HMAC keys](storage/hmac.md) | A service account's second credential: making and retiring keys, and signing with one |
| [Encryption keys](storage/encryption.md) | Customer-supplied keys and Cloud KMS keys |
| [Notifications](storage/notifications.md) | A Pub/Sub message for every change to a bucket's objects, and what each change publishes |
| [Folders](storage/folders.md) | Hierarchical buckets, atomic tree renames, and managed folders with policies of their own |
| [The emulator](storage/emulator.md) | What fake-gcs-server does differently, and how the tests make up for it |

## 🔑 Secret Manager

| Guide | What's in it |
| --- | --- |
| [Overview](secret-manager/README.md) | Reading a secret's bytes, verified and wiped; every call; checksums; regional secrets; IAM |
| [Changing a secret](secret-manager/updating.md) | Updates, etag preconditions, aliases, expiry and delayed destruction, with the rules production enforces |
| [Notifications and rotation](secret-manager/notifications.md) | Topics, the service agent, every event and how late it comes, and rotating on schedule |
| [Encryption keys](secret-manager/encryption.md) | Cloud KMS keys for automatic, user-managed and regional secrets, and what a key that goes away does |

## 🔥 Firestore

| Guide | What's in it |
| --- | --- |
| [Overview](firestore/README.md) | A first program, values and documents, paths and handles, every call, errors and retries, and the limits checked before sending |
| [Writing documents](firestore/writing.md) | Set, update and delete; masks and preconditions; creating documents; transforms; several writes in one commit; which writes are retried |
| [Queries and aggregations](firestore/queries.md) | Conditions, null and NaN, the order of values, cursors and paging, collection groups, count, sum and average |
| [Transactions](firestore/transactions.md) | A handler run again on contention, read-only transactions, and transactions by hand |
| [The emulator](firestore/emulator.md) | What the emulator does differently from production, and how the tests hold the fake to both |

## 📜 Cloud Logging

| Guide | What's in it |
| --- | --- |
| [Overview](logging/README.md) | A first program, the calls, and what production showed when measured (experimental) |
| [Listing entries](logging/listing.md) | Queries and their pages, page tokens, the time range, order and page size, the read quota and `ReadBudget`, what an entry carries, errors |
| [Filters](logging/filters.md) | How the client joins your filter to its clauses, and how production read the query language |
| [Tailing](logging/tail.md) | A tail by polling: the window, late entries, falling behind, keeping the cursor, and why there is no live tail |
| [Logs, buckets and views](logging/picker.md) | Log names, buckets and views, and a picker that orders them for a person |
| [Testing](logging/testing.md) | An in-memory Cloud Logging for your own tests, with production's answers (experimental) |

## 🗂️ Resource Manager

| Guide | What's in it |
| --- | --- |
| [Overview](resource_manager/README.md) | A first program, the calls, and what production showed when measured (experimental) |
| [Listing projects](resource_manager/projects.md) | The list a project switcher caches, matching letters locally, searching page by page, the query language as production read it, a project as it is now, and where each sits |
| [The project charged](resource_manager/quota-project.md) | Which project each call is charged to, why none is named by default, and the refusals that name it |
| [Testing](resource_manager/testing.md) | An in-memory Resource Manager for your own tests, with production's answers (experimental) |

## 🚨 Error Reporting

| Guide | What's in it |
| --- | --- |
| [Overview](error_reporting/README.md) | A dashboard's first program, periods and buckets, statuses and muted groups, the quota, locations, and what production showed when measured (experimental) |
| [Testing](error_reporting/testing.md) | An in-memory Error Reporting for your own tests, held to production's answers (experimental) |

## 📈 Monitoring

| Guide | What's in it |
| --- | --- |
| [Overview](monitoring/README.md) | A program's first write, the calls, who is writing, errors, and what production showed when measured (experimental) |
| [Writing](monitoring/writing.md) | A write and its result, the rules production holds each series to, kinds and values, descriptors, retries, limits |
| [Reading](monitoring/reading.md) | Filters, aligning and reducing, pages of points, incomplete answers, cost |
| [The Recorder](monitoring/recorder.md) | Counters, gauges, histograms and observers written every interval from a task of their own; stopping, descriptors, stats |
| [Testing](monitoring/testing.md) | An in-memory Cloud Monitoring for your own tests, held to production's answers (experimental) |

## 🔐 KMS

| Guide | What's in it |
| --- | --- |
| [Overview](kms/README.md) | A first program, the calls, integrity, errors, and what production showed when measured (experimental) |
| [Encrypting](kms/encrypting.md) | Encrypt and decrypt, AAD, which version is used, the plaintext wiped, more than 64 KiB |
| [Signing and MACs](kms/signing.md) | Signing messages and digests, public keys, checking a signature on this machine, MAC tags |
| [Keys](kms/keys.md) | Key rings, keys and versions; states, rotation, destroying and deleting; what is billed; IAM |
| [Testing](kms/testing.md) | An in-memory Cloud KMS for your own tests, held to production's answers (experimental) |

## 🛠️ Working on zig-gcp

| Guide | What's in it |
| --- | --- |
| [Development](development.md) | Build steps, fuzzing, coverage, CI, and every integration suite with what it needs |
| [Zig 0.17 workarounds](zig-std-workarounds.md) | Standard library issues this library works around, each with its regression test |
| [Contributing](../CONTRIBUTING.md) | How changes are proposed, tested and merged |
| [Security](../SECURITY.md) | The threat model, and the test that holds each claim |
| [Changelog](../CHANGELOG.md) | Every release, and what each one breaks |
