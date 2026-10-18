[Docs](../README.md) › [KMS](README.md) › Encrypting

# Encrypting and decrypting

An `encrypt_decrypt` key encrypts up to 64 KiB in one call, with the
key's primary version or one named, and decrypts what it made. The key
material never leaves Cloud KMS.

## A call each way

`Key.encrypt(plaintext, options)` answers an `Owned(Ciphertext)`:
`bytes`, which are opaque and name the version that made them, and
`version`, the number of that version. `Key.decrypt(ciphertext,
options)` answers a `Plaintext`, whose `bytes()` are the plaintext and
whose `deinit` wipes them. Both take at most 65,536 bytes of plaintext
and of AAD, inclusive, as production measured, and refuse more as
`error.TooLarge` before sending anything. A ciphertext is 73 to 85
bytes longer than its plaintext, and two encrypts of the same bytes give
two ciphertexts, both good.

## Additional authenticated data

`EncryptOptions.aad` binds bytes to the ciphertext without encrypting
them: `decrypt` needs the same bytes, or it is `error.DecryptionFailed`
("Decryption failed.", in production's words). The AAD is not secret
and not kept in the ciphertext, so it has to be known again at decrypt
time. A record's id is the usual choice: a ciphertext copied into
another record then fails there, as `seal` and `unseal` in the
[overview](README.md) do.

## Which version

An encrypt uses the key's primary version, or `EncryptOptions.version`
when it names one. After `Key.setPrimary`, Google says encrypt may go on
using the old primary for up to a minute; measured, the next encrypt
used the new one each time. `Ciphertext.version` says which was used,
and an encrypt pinned to a version is checked to have been answered by
that one.

A decrypt finds its version in the ciphertext, and that version must
still be enabled: disabled, it is `error.KeyVersionDisabled`; scheduled
for destruction or destroyed, `error.KeyVersionDestroyed`. Both put the
version's name in `Diagnostics`, the only place the API says which
version a ciphertext needs. `Plaintext.used_primary` is false when an
older version decrypted: encrypting the bytes again moves them onto the
primary, which is how a rotation is finished before the old version is
retired ([Keys](keys.md#rotation)).

`error.DecryptionFailed` covers three refusals, which the server's words
in `Diagnostics` tell apart: another AAD ("Decryption failed."), another
key's ciphertext ("verify that 'name' refers to the correct CryptoKey"),
and bytes that are not a ciphertext ("the ciphertext is invalid").

## The plaintext is wiped

A decrypt's answer lives in one arena over `core.WipingAllocator`: the
response body, which carries the plaintext in base64, the JSON parser's
scratch space, and the decoded bytes. `Plaintext.deinit` zeroes all of
it, an attempt that failed its checksums included.
No format specifier prints a `Plaintext`: `{f}` gives `[REDACTED]`. An
encrypt wipes every buffer it filled with the plaintext before it
returns; the caller's own copy is the caller's. Nothing about either
reaches the log, which says only which call was made and how it went.

## More than 64 KiB

Encrypt the data here with a key made for it, and that key with Cloud
KMS: only 32 bytes go to the server, and the data can be any size.

<!-- snippet: tests/docs_examples.zig#kms-envelope -->
```zig
/// Data of any size, encrypted here with a key of its own, which Cloud
/// KMS encrypts in turn: only those 32 bytes go to the server.
const Envelope = struct {
    wrapped_key: []const u8,
    nonce: [12]u8,
    tag: [16]u8,
    sealed: []const u8,
};

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

fn envelopeSeal(a: std.mem.Allocator, io: std.Io, key: kms.Key, data: []const u8) !Envelope {
    var data_key: [Aes256Gcm.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &data_key);
    io.random(&data_key);
    var nonce: [Aes256Gcm.nonce_length]u8 = undefined;
    io.random(&nonce);
    const sealed = try a.alloc(u8, data.len);
    errdefer a.free(sealed);
    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    Aes256Gcm.encrypt(sealed, &tag, data, "", nonce, data_key);
    var wrapped = try key.encrypt(&data_key, .{});
    defer wrapped.deinit();
    return .{ .wrapped_key = try a.dupe(u8, wrapped.value.bytes), .nonce = nonce, .tag = tag, .sealed = sealed };
}

fn envelopeOpen(a: std.mem.Allocator, key: kms.Key, envelope: Envelope) ![]u8 {
    var data_key = try key.decrypt(envelope.wrapped_key, .{});
    defer data_key.deinit();
    if (data_key.bytes().len != Aes256Gcm.key_length) return error.DecryptionFailed;
    const data = try a.alloc(u8, envelope.sealed.len);
    errdefer a.free(data);
    try Aes256Gcm.decrypt(data, envelope.sealed, envelope.tag, "", envelope.nonce, data_key.bytes()[0..Aes256Gcm.key_length].*);
    return data;
}
```

Store the four fields together. A data key per object means one call to
Cloud KMS per object, each way; a nonce is never used twice under one
key, which a fresh key per object ensures.

## Integrity

Every encrypt and decrypt sends its bytes with their CRC-32C and checks
the answer's, as the [overview](README.md#integrity) says: a failed check
is tried again, and past the retry policy's attempts is
`error.IntegrityCheckFailed`, the bytes never handed over.
