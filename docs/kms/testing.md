[Docs](../README.md) › [KMS](README.md) › Testing

# Testing with the in-memory Cloud KMS

Cloud KMS has no emulator, so `kms.testing.FakeKms` is the test double:
key rings, keys and versions in memory, behind
`Client.Options.transport`, with real cryptography and the refusals
production gave, in its words.

<!-- snippet: tests/docs_examples.zig#kms-fake -->
```zig
test "a sealed value opens only for its own record, in the in-memory Cloud KMS" {
    var clock: kms.testing.FakeClock = .{ .now_ns = 1_792_300_000 * std.time.ns_per_s };
    var fake: kms.testing.FakeKms = .init(std.testing.allocator, clock.io(), .{ .project_id = "my-project" });
    defer fake.deinit();
    var token: kms.StaticToken = .{ .token = "none" };
    var client = try kms.Client.init(std.testing.allocator, clock.io(), .{
        .project_id = "my-project",
        .location = "us-central1",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    try makeKeys(&client, std.Io.Clock.real.now(clock.io()));

    const key = client.keyRing("app").key("config");
    var sealed = try seal(key, "user-42", "s3cr3t");
    defer sealed.deinit();
    var value = try unseal(key, "user-42", sealed.value.bytes);
    defer value.deinit();
    try std.testing.expectEqualStrings("s3cr3t", value.bytes());
    // Another record's AAD is refused, as production refuses it.
    try std.testing.expectError(error.DecryptionFailed, unseal(key, "user-43", sealed.value.bytes));

    // The fake's keys are real: its signatures verify here.
    var signature = try signManifest(client.keyRing("app").key("releases").version(1), "v1.2.3");
    defer signature.deinit();
}
```

The fake's clock is the `Io` it is given: with a `FakeClock`, a test
moves time on to pass a destroy delay, a rotation or a key's generation.
It answers only for `Options.project_id`.

## What it models

- **Key rings**: created, read, listed, deleted once empty. An id in use
  is 409.
- **Keys**: a purpose, an algorithm of it, a protection level, a destroy
  delay of 1 to 120 days (30 by default), labels and rotation, and
  version 1 unless asked not to; read, listed, updated (labels, rotation,
  the template's algorithm); deleted once every version is and no
  rotation is scheduled. A deleted key's id is retired for good, and
  listed.
- **Versions**: symmetric and MAC ones enabled at once, asymmetric ones
  `PENDING_GENERATION` for `Options.generation_delay_ms` first; enabled,
  disabled, destroyed after the key's delay and restored before it,
  deleted once destroyed. The primary, set by hand and by rotation, which
  runs on the clock.
- **Cryptography, for real**: AES-256-GCM in a ciphertext of its own
  that names its key and version, so another key's ciphertext and a wrong
  AAD are refused as production refuses them; ECDSA P-256, P-384 and
  secp256k1 (HSM keys), Ed25519 and ML-DSA keys made per version; RSA
  from fixed test keys, since `std` cannot make one; HMAC. Its signatures
  verify with `PublicKey.verify`, and public keys come in PEM, DER and
  the NIST encoding.
- **Integrity**: every checksum checked and answered, as production does.
- **IAM**: policies kept, read and written under etags; enforced on no
  one.
- **Operations**: key and version deletes done when first read, a key
  ring's 422 s later, as production's were.
- **Refusals** in production's status, words and reason: a version not
  enabled, a state change its state forbids, a key or key ring that
  cannot be deleted yet, a retired id, another purpose's call, a digest
  of another hash or length, a primary on a signing key, rotation on a
  key that cannot rotate, secp256k1 in software, immutable fields.

A production suite runs one script of 81 operations against production
and the fake, and holds the fake to every outcome.

## Faults

| Call | What the next calls get |
| --- | --- |
| `refuseNext(n, status)` | Answered with `status`, nothing changed |
| `dropNext(n)` | The connection closed before any answer |
| `loseNext(n, status)` | Served, so what they change is changed, then answered with `status`, as a 503 can after the work was done |
| `corruptNext(n, kind)` | A crypto answer that fails a check: a flipped byte under its old checksum, `verified*` flags false, another version's name, a MAC verdict whose checksum disagrees, or a request checksum refused |

`callCount()` counts the calls served, refusals included;
`billedVersions()` counts the versions made and not yet destroyed or
deleted; `version(key_name, id)` reads one as the fake holds it; and
`serve(request, arena)` answers a request no client would send.

## Where it differs

- A deleted key ring's id is free again at once, where production's
  took 7 minutes.
- Its ciphertexts are its own format, so they are not production's
  length.
- The few refusals production was never seen to give are worded by the
  fake and start `fake:`.

## What it does not model

It says so: 501, `error.Unimplemented`, with a message that begins
`fake:`. Among these: filters and orders on lists, another project,
import jobs, EKM, Autokey, raw encryption, asymmetric decryption, key
encapsulation and SLH-DSA, quotas, and the eventual consistency Google
documents for a disable or a primary change, which production showed at
once.
