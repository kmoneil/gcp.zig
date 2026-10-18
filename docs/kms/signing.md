[Docs](../README.md) › [KMS](README.md) › Signing and MACs

# Signing, public keys and MACs

An `asymmetric_sign` key signs with its private key, which never leaves
Cloud KMS, and gives out its public key, so a signature can be checked
anywhere, here included. A `mac` key makes and checks HMAC tags, its
secret never given out at all. Both are used through a version:
`key.version(n)`.

## Signing

<!-- snippet: tests/docs_examples.zig#kms-sign -->
```zig
/// Signs a release's manifest, and checks the signature here against the
/// version's public key, as whoever downloads the release would.
fn signManifest(version: kms.KeyVersion, manifest: []const u8) !kms.Owned([]const u8) {
    var signature = try version.sign(.ec_sign_p256_sha256, manifest);
    errdefer signature.deinit();
    var public_key = try version.publicKey();
    defer public_key.deinit();
    try public_key.value.verify(manifest, signature.value);
    return signature;
}
```

`KeyVersion.sign(algorithm, message)` takes the version's algorithm from
the caller, so no read comes before the signature. For the algorithms
that sign a digest (ECDSA and RSA) the digest is made here, with the
algorithm's SHA-2, and only it is sent; for those that sign the message
(Ed25519 and ML-DSA) the message goes, at most 64 KiB. An algorithm that
is not the version's is the server's refusal: for a digest of another
hash, `error.InvalidArgument`, "The digest SHA384 is not valid for
CryptoKeys with algorithm EC_SIGN_P256_SHA256."

`signDigest(algorithm, digest)` signs a digest made elsewhere, for a
large file hashed as it streams: 32, 48 or 64 bytes as its hash says, or
`error.InvalidDigest`. Ed25519 and ML-DSA sign messages, not digests, so
`signDigest` for them is `error.InvalidOptions`.

A new asymmetric version starts `pending_generation`, and signing with
it then is `error.KeyVersionPending`: `waitUntilEnabled` waits it out.
Software keys were ready within 0.2 s when measured; HSM keys may take
longer.

| Algorithm | Signs | Signature | Checked here |
| --- | --- | --- | --- |
| `ec_sign_p256_sha256`, `ec_sign_p384_sha384` | a SHA-256 or SHA-384 digest | DER, about 70 or 103 bytes | yes |
| `ec_sign_secp256k1_sha256` | a SHA-256 digest; HSM keys only | DER | yes |
| `rsa_sign_pkcs1_*`, `rsa_sign_pss_*` | a SHA-256 or SHA-512 digest | the modulus's length | yes |
| `ec_sign_ed25519` | the message | 64 bytes | yes |
| `pq_sign_ml_dsa_44`, `_65`, `_87` | the message | 2,420, 3,309 or 4,627 bytes | yes |
| `pq_sign_slh_dsa_sha2_128s` and its pre-hash form | the message, or a SHA-256 digest | 7,856 bytes | no: `std` has no SLH-DSA |
| raw PKCS#1, external-mu ML-DSA | input the caller prepares | | not sent: `error.InvalidOptions` |

## Public keys

`KeyVersion.publicKey()` answers a `PublicKey`: the version's name and
algorithm, and the key as a PEM SubjectPublicKeyInfo, which every family
production was asked for came as, ML-DSA included. It is asked for as a
PEM; when the server answers that a key has only the NIST encoding, it
is asked for again that way, and comes in `raw`. A version's public key
never changes, so it can be kept for as long as the version lives.

`PublicKey.verify(message, signature)` checks a signature here, with
`std.crypto` and `core.rsa`, and no call: `error.SignatureInvalid` when
it is not the key's, `error.InvalidPublicKey` for a key that does not
decode as its algorithm's, `error.UnsupportedAlgorithm` for SLH-DSA.
`verifyDigest(digest, signature)` checks a signature over a digest made
elsewhere, for ECDSA and RSA. The PEM is the standard form, so OpenSSL
reads it too:

```sh
openssl dgst -sha256 -verify public.pem -signature manifest.sig manifest.json
```

One signature of each family Cloud KMS made in production is kept as
test data and checked by this code, beside signatures OpenSSL made.

## MACs

<!-- snippet: tests/docs_examples.zig#kms-mac -->
```zig
/// A webhook body's tag, made with an HMAC key that never leaves Cloud
/// KMS, and checked there when the body comes back.
fn tagBody(version: kms.KeyVersion, body: []const u8) !kms.Owned([]const u8) {
    return version.macSign(body);
}

fn bodyIsOurs(version: kms.KeyVersion, body: []const u8, tag: []const u8) !bool {
    return version.macVerify(body, tag);
}
```

`macSign` takes at most 64 KiB and answers the tag: 32 bytes for
`hmac_sha256`. `macVerify` answers whether a tag is the version's over
the data; one that is not is `false`, not an error. Either way the
answer's integrity is checked: the server says it got the data's and the
tag's checksums, and that its verdict's own checksum matches it.

## Integrity

Every signature, public key and tag comes back with its CRC-32C, and the
answer names the version that made it; both are checked, as the
[overview](README.md#integrity) says. A signature that fails its checks
is never handed over.
