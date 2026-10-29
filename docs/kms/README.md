[Docs](../README.md) › KMS

# 🔐 KMS

A client for Cloud KMS's v1 API: encrypt and decrypt with keys the server
holds, sign and MAC with them, check signatures on this machine, and
manage key rings, keys and their versions from creation to deletion.
Every answer is checked against its CRC-32C checksums, and decrypted
bytes are wiped.

```zig
const std = @import("std");
const auth = @import("auth");
const kms = @import("kms");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();
    var client = try kms.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .location = "us-central1",
        .token_provider = creds.provider(),
    });
    defer client.deinit();
    const key = client.keyRing("app").key("config");
    var sealed = try seal(key, "user-42", "s3cr3t");
    defer sealed.deinit();
    var value = try unseal(key, "user-42", sealed.value.bytes);
    defer value.deinit();
}
```

<!-- snippet: tests/docs_examples.zig#kms-seal -->
```zig
/// Encrypts a value for storage, bound to the record it belongs to: a
/// ciphertext copied into another record does not decrypt there.
fn seal(key: kms.Key, record_id: []const u8, value: []const u8) !kms.Owned(kms.Ciphertext) {
    return key.encrypt(value, .{ .aad = record_id });
}

/// The value back, in memory its `deinit` wipes.
fn unseal(key: kms.Key, record_id: []const u8, ciphertext: []const u8) !kms.Plaintext {
    return key.decrypt(ciphertext, .{ .aad = record_id });
}
```

A handle (`keyRing`, `key`, `version`) makes no call; each method makes
one, or a few for a call that waits. Using a key needs a role on it or on
its key ring: Cloud KMS CryptoKey Encrypter/Decrypter to encrypt and
decrypt, Signer/Verifier to sign and MAC, Public Key Viewer for public
keys. Managing keys needs Cloud KMS Admin, which is also the role that
sets IAM policies. Editor is not enough: measured, it may create, read,
update and delete keys and versions, but not use, destroy or restore
them, nor set a policy. `examples/kms.zig` makes a key, encrypts, signs
and MACs with it and schedules what it made for destruction, and runs
offline with `--fake`.

## The guides

| Guide | What's in it |
| --- | --- |
| [Encrypting](encrypting.md) | Encrypt and decrypt, AAD, which version is used, the plaintext wiped, more than 64 KiB, integrity |
| [Signing and MACs](signing.md) | Signing messages and digests, public keys, checking a signature here, MAC tags |
| [Keys](keys.md) | Key rings, keys and versions; states, rotation, destroying and deleting; what is billed; IAM |
| [Testing](testing.md) | An in-memory Cloud KMS for your own tests, held to production's answers |

## The calls

| Call | What it does |
| --- | --- |
| `Key.encrypt(plaintext, options)`, `Key.decrypt(ciphertext, options)` | Up to 64 KiB, with AAD; decrypted bytes come back in memory `deinit` wipes |
| `KeyVersion.sign(algorithm, message)`, `.signDigest(algorithm, digest)` | A signature; the caller names the algorithm, so no read comes first |
| `KeyVersion.publicKey()`, `PublicKey.verify(message, signature)` | A version's public key, and a signature checked here with `std.crypto` |
| `KeyVersion.macSign(data)`, `.macVerify(data, mac)` | An HMAC tag made and checked in Cloud KMS |
| `Client.randomBytes(len)` | 8 to 1,024 random bytes from an HSM in the client's location |
| `KeyRing.create()`, `.get()`, `.delete()`, `Client.listKeyRings(options)` | Key rings, which cost nothing |
| `Key.create(config)`, `.get()`, `.update(changes)`, `.setPrimary(id)`, `.delete()`, `KeyRing.listKeys(options)` | Keys: purpose, algorithm, protection level, destroy delay, labels, rotation |
| `Key.createVersion()`, `.listVersions(options)`, `KeyVersion.get()`, `.enable()`, `.disable()`, `.destroy()`, `.restore()`, `.delete()`, `.waitUntilEnabled(options)` | Versions and their states |
| `iamPolicy`, `setIamPolicy`, `addIamBinding`, `removeIamBinding`, `testIamPermissions` | On a key ring or a key |
| `Client.keyNamed(name)`, `Client.listLocations(options)`, `Client.listRetiredKeys(options)` | A key named in full, anywhere; the locations; every deleted key's id |

## Integrity

Every byte string sent goes with its CRC-32C, and every answer is
checked three ways: the server says it got each checksum
(`verified...`), each byte string it returns matches the checksum
beside it, and the answer names the version asked for, or, for an
encrypt by key, a version of that key. A failed check is tried again as
a 503 is, and past the retry policy's attempts is
`error.IntegrityCheckFailed`, with what failed in `Diagnostics`. Bytes
that failed are never handed over. Google asks every client to do this,
and its own libraries leave it to the caller.

## Errors

| Error | When |
| --- | --- |
| `InvalidName` | A key ring or key id outside 1 to 63 of `[a-zA-Z0-9_-]`, a version numbered 0, a key named in full that does not parse. Nothing is sent |
| `InvalidOptions` | A destroy delay outside 1 to 120 days, rotation under a day or on a key that cannot rotate, an algorithm of another purpose, labels that break the rules |
| `TooLarge`, `InvalidDigest` | Plaintext, AAD or data past 65,536 bytes; a digest of the wrong length. Nothing is sent |
| `KeyVersionPending` | A version still being generated: `waitUntilEnabled` waits it out |
| `KeyVersionDisabled`, `KeyVersionDestroyed` | A version that is not enabled; `Diagnostics` names it, the only place a decrypt says which version a ciphertext needs |
| `DecryptionFailed` | Another AAD, another key's ciphertext, or bytes that are not one; the server's words say which |
| `IntegrityCheckFailed` | An answer that failed its checksums after every attempt |
| `KeyVersionFailed` | `waitUntilEnabled` saw a version fail to generate or import |
| `AlreadyExists` | An id in use, or one a deleted key held: a key's id is retired for good |
| `FailedPrecondition` | A state change the version's state forbids, a key ring that still holds keys, a primary on a key that has none |
| `InvalidArgument` | What the server refused as asked, such as a key with versions left to delete, or a digest of another hash than the key's |

Every call retries 5xx, 429 and dropped connections with the client's
`RetryPolicy`, but a `setIamPolicy` with no etag, which is sent once. A
create whose answer was lost is read back, not sent again; a state
change that may have landed is read to see; and `createVersion`, which
bills a new version each time, is never sent twice once it may have
left.

## What was measured

Cloud KMS has no emulator, so this module was measured in production on
2026-10-18 before it was built on, and a production suite holds the fake
to production's outcome for each of 81 operations. What that showed:

- **A public key asked for as PEM comes in `publicKey.data`**, with no
  `pem` field; asked for in no format, it comes in `pem`. An ML-DSA key
  comes as a PEM too, and in its raw 1,952 bytes with `NIST_PQC`.
- **Software asymmetric keys are usable within 0.2 s**, where Google
  warns of minutes; a sign sent to a version still generating was
  answered once it was ready.
- **The 64 KiB limits are 65,536 bytes**, inclusive, for plaintext, AAD
  and MAC data.
- **A ciphertext is 73 to 85 bytes longer than its plaintext**, and two
  encrypts of the same bytes differ.
- **Disabling, destroying and a primary change took effect at once**,
  each of the three times measured, where Google says up to a minute.
- **A wrong AAD is "Decryption failed."**, another key's ciphertext
  says so, and garbage is "the ciphertext is invalid".
- **A key ring's delete finishes minutes after it is taken**, and its id
  was free again after 7; key and version deletes are done at once.
- **A key's id is retired for good when it is deleted**, and creating
  one under it is 400 with a `RESOURCE_DELETED` reason, which the client
  makes `AlreadyExists`.
- **Deleting a key with versions left, or with rotation scheduled, is
  400 `INVALID_ARGUMENT`**, where a key ring holding keys is
  `FAILED_PRECONDITION`.
- **Data sent to a key that signs a digest is signed**: the server hashes
  it. The client makes the digest itself anyway.
- **Every signature KMS made verifies here**, one of each family, kept as
  test data.

## Not here

Asymmetric decryption and key encapsulation; raw encryption, external-mu
ML-DSA and raw PKCS#1 signing; key import; envelope encryption for data
past 64 KiB; a KMS-backed `Signer` for signed URLs and JWTs; EKM,
Autokey and single-tenant HSMs. HSM keys work through `protection_level`,
but were not measured.
