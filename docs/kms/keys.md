[Docs](../README.md) › [KMS](README.md) › Keys

# Key rings, keys and versions

A key ring is a name in one location, holding keys. A key has a purpose,
fixed when it is made, and versions, each its own key material, numbered
from 1. What is used is a version: an encrypt names its key and uses the
primary; a signature or a MAC names its version.

## Making them

<!-- snippet: tests/docs_examples.zig#kms-keys -->
```zig
/// Makes the key ring and the two keys an application uses: one that
/// encrypts, rotated every 90 days, and one that signs. What exists
/// already is left as it is.
fn makeKeys(client: *kms.Client, now: std.Io.Timestamp) !void {
    const ring = client.keyRing("app");
    if (ring.create()) |made| {
        var info = made;
        info.deinit();
    } else |err| if (err != error.AlreadyExists) return err;

    const ninety_days = 90 * std.time.s_per_day;
    if (ring.key("config").create(.{
        .purpose = .encrypt_decrypt,
        .rotation = .{ .period_s = ninety_days, .next = .{ .nanoseconds = now.nanoseconds + ninety_days * std.time.ns_per_s } },
    })) |made| {
        var info = made;
        info.deinit();
    } else |err| if (err != error.AlreadyExists) return err;

    const releases = ring.key("releases");
    if (releases.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256 })) |made| {
        var info = made;
        info.deinit();
        // An asymmetric version is made after the create answers.
        var ready = try releases.version(1).waitUntilEnabled(.{});
        ready.deinit();
    } else |err| if (err != error.AlreadyExists) return err;
}
```

`KeyConfig` says what a key is:

- `purpose`: `encrypt_decrypt`, `asymmetric_sign` or `mac` for the calls
  this module makes. Keys of the other purposes can be made and managed,
  but nothing here uses them yet.
- `algorithm`, of that purpose: required, but for an `encrypt_decrypt`
  key, whose is `google_symmetric_encryption` when left out.
- `protection_level`: `software` by default, or `hsm`.
- `destroy_delay_s`: how long a destroyed version can still be restored,
  1 to 120 days, 30 when left out, fixed for good at creation.
- `rotation`, for an `encrypt_decrypt` key; `labels`, up to 64.
- `first_version = false` makes the key with no version: nothing billed,
  nothing to use until `createVersion`, and deletable at once.

Ids are 1 to 63 of `[a-zA-Z0-9_-]`. A key ring cannot be renamed or
moved, and neither can a key. `Client.keyNamed(name)` takes a key named
in full, `projects/P/locations/L/keyRings/R/cryptoKeys/K`, in any
project and location, as a Cloud Storage bucket or a secret names its
encryption key.

## Versions and their states

| State | Usable | Billed | Comes from |
| --- | --- | --- | --- |
| `pending_generation` | no: `KeyVersionPending` | yes | a new asymmetric version, for a moment |
| `enabled` | yes | yes | made, or `enable` |
| `disabled` | no: `KeyVersionDisabled` | yes | `disable`, or `restore` |
| `destroy_scheduled` | no: `KeyVersionDestroyed` | yes | `destroy` |
| `destroyed` | no: `KeyVersionDestroyed` | no | the destroy delay passing |

`Key.createVersion()` makes the next version from the key's template;
it is not made primary. Symmetric and MAC versions are enabled at once;
asymmetric ones are generated first, and `waitUntilEnabled` waits for
them (5 minutes at most by default), answering `error.KeyVersionFailed`
if generation fails. A state change the current state forbids, such as a
second `destroy` or enabling a version scheduled for destruction, is
`error.FailedPrecondition`, the server's words in `Diagnostics`.

## Rotation

Rotating a symmetric key is making a new version and making it primary:
`createVersion` then `setPrimary`, or `KeyConfig.rotation` (or
`Key.update` with `.rotation`), which has the server do both every
period, from 1 day to 100 years. New encrypts use the new primary; old
ciphertexts still decrypt with the versions that made them, which must
stay enabled. To retire an old version, encrypt again what it made
(`Plaintext.used_primary` is false for those), then destroy it.
Signing and MAC keys have no primary and cannot rotate by themselves:
make a version, start signing with it, and publish its public key.

## Destroying and deleting

<!-- snippet: tests/docs_examples.zig#kms-retire -->
```zig
/// Retires a version no ciphertext needs any more: scheduled for
/// destruction the first time, restorable until its destroy time, and
/// deleted by a run after that.
fn retireVersion(key: kms.Key, id: u64) !void {
    var info = try key.version(id).get();
    defer info.deinit();
    switch (info.value.state) {
        .enabled, .disabled => {
            var scheduled = try key.version(id).destroy();
            scheduled.deinit();
        },
        .destroyed => try key.version(id).delete(),
        else => {},
    }
}
```

`destroy` schedules a version's material for destruction at the key's
destroy delay from now; until then `restore` brings it back, disabled.
After it, the version is `destroyed`, no longer billed, and can be
deleted; deleting one in any other state is `error.FailedPrecondition`.
A key can be deleted once every version is and no rotation is scheduled,
or the server refuses it as `error.InvalidArgument`. **A deleted key's
id is retired in the project for good**: creating a key under it again
is `error.AlreadyExists`, and `Client.listRetiredKeys` lists every one.
A key ring can be deleted once its keys are, or it is
`error.FailedPrecondition`; `KeyRing.delete` returns once the server has
taken the delete, which finishes minutes later, and the id was free
again after 7 minutes when measured.

Key and version deletes wait for their operation, which was done at the
first read when measured.

## What is billed

Every version is billed by the month until it is `destroyed`, disabled
and scheduled ones included; key rings and keys with no version are
free. Each use of a key is billed by the 10,000 calls. A destroy delay
is time a version goes on being billed after `destroy`, so a short one
costs less, and a longer one is longer to undo a mistake in.
`State.billed()` says which states are billed.

## IAM

Key rings and keys have IAM policies; a key's grants add to its key
ring's, and versions have none of their own. Grant a program the role it
needs on the key it uses, rather than the key ring or the project:

<!-- snippet: tests/docs_examples.zig#kms-iam -->
```zig
/// Lets a project's Cloud Storage service agent use a key for a bucket's
/// default encryption: on that key alone, not on its key ring.
fn letStorageUse(key: kms.Key, project_number: []const u8, buffer: []u8) !void {
    const member = try std.fmt.bufPrint(buffer, "serviceAccount:service-{s}@gs-project-accounts.iam.gserviceaccount.com", .{project_number});
    var policy = try key.addIamBinding("roles/cloudkms.cryptoKeyEncrypterDecrypter", member);
    defer policy.deinit();
}
```

`addIamBinding` and `removeIamBinding` read the policy, change it and
write it under the read's etag, starting over when another change came
between. `setIamPolicy` writes a whole policy; `testIamPermissions`
says which of up to 100 permissions the caller holds, and answers none
for a resource that does not exist. Setting a policy needs Cloud KMS
Admin; Editor cannot.
