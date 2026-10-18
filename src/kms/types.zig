//! Cloud KMS's values as this library holds them: key rings, keys and
//! their versions, what a key is made with and what it is for. Wire names
//! are the enum tags in capitals, `.ec_sign_p256_sha256` for
//! `EC_SIGN_P256_SHA256`; a name the server sends that this library does
//! not know reads as `.unknown`, which is never sent.

const std = @import("std");
const core = @import("core");
const verify_impl = @import("verify.zig");

pub const Owned = core.Owned;

/// The wire name of an enum tag: the tag in capitals, as proto3 JSON names
/// enum values.
fn upper(comptime tag: []const u8) *const [tag.len:0]u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var buf: [tag.len:0]u8 = undefined;
        for (tag, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        const final = buf;
        return &final;
    }
}

/// `wire` and `fromWire` for an enum whose tags are its wire names in
/// lowercase, with `.unknown` standing for `unspecified`.
fn WireNames(comptime E: type, comptime unspecified: []const u8) type {
    return struct {
        fn wire(e: E) []const u8 {
            return switch (e) {
                .unknown => unspecified,
                inline else => |t| comptime upper(@tagName(t)),
            };
        }

        fn fromWire(name: []const u8) E {
            @setEvalBranchQuota(100_000);
            inline for (@typeInfo(E).@"enum".field_names) |tag| {
                if (comptime std.mem.eql(u8, tag, "unknown")) continue;
                if (std.mem.eql(u8, name, comptime upper(tag))) return @field(E, tag);
            }
            return .unknown;
        }
    };
}

/// What a key is for. Fixed when the key is created.
pub const Purpose = enum {
    /// `encrypt` and `decrypt`, up to 64 KiB, with a primary version and
    /// optional automatic rotation.
    encrypt_decrypt,
    /// `sign` with the private half; the public half is `publicKey`.
    asymmetric_sign,
    /// Decryption of what was encrypted to the public half. Not used by
    /// this library yet; a key may be created and managed.
    asymmetric_decrypt,
    /// Raw AES (GCM, CBC, CTR), for ciphertexts other systems read. Not
    /// used by this library yet.
    raw_encrypt_decrypt,
    /// `macSign` and `macVerify`.
    mac,
    /// Key encapsulation (ML-KEM, X-Wing). Not used by this library yet.
    key_encapsulation,
    /// Single-tenant HSM key wrapping. Not used by this library yet.
    aes_wrapping,
    unknown,

    const names = WireNames(Purpose, "CRYPTO_KEY_PURPOSE_UNSPECIFIED");
    pub const wire = names.wire;
    pub const fromWire = names.fromWire;
};

/// Where a key's material lives and its operations run. Fixed when the key
/// is created.
pub const ProtectionLevel = enum {
    /// In software: $0.06 a month a version.
    software,
    /// In a Cloud HSM: $1 to $2.50 a month a version.
    hsm,
    /// In a partner's key manager, reached over the internet.
    external,
    /// In a partner's key manager, reached over a VPC network.
    external_vpc,
    /// In a dedicated HSM instance.
    hsm_single_tenant,
    unknown,

    const names = WireNames(ProtectionLevel, "PROTECTION_LEVEL_UNSPECIFIED");
    pub const wire = names.wire;
    pub const fromWire = names.fromWire;
};

/// How a version's material is used. A key's versions share its purpose;
/// each version has its algorithm, the key's template at its creation.
pub const Algorithm = enum {
    /// AES-256-GCM with Cloud KMS's own framing: the one algorithm of
    /// `encrypt_decrypt`.
    google_symmetric_encryption,
    aes_128_gcm,
    aes_256_gcm,
    aes_128_cbc,
    aes_256_cbc,
    aes_128_ctr,
    aes_256_ctr,
    rsa_sign_pss_2048_sha256,
    rsa_sign_pss_3072_sha256,
    rsa_sign_pss_4096_sha256,
    rsa_sign_pss_4096_sha512,
    rsa_sign_pkcs1_2048_sha256,
    rsa_sign_pkcs1_3072_sha256,
    rsa_sign_pkcs1_4096_sha256,
    rsa_sign_pkcs1_4096_sha512,
    rsa_sign_raw_pkcs1_2048,
    rsa_sign_raw_pkcs1_3072,
    rsa_sign_raw_pkcs1_4096,
    rsa_decrypt_oaep_2048_sha256,
    rsa_decrypt_oaep_3072_sha256,
    rsa_decrypt_oaep_4096_sha256,
    rsa_decrypt_oaep_4096_sha512,
    rsa_decrypt_oaep_2048_sha1,
    rsa_decrypt_oaep_3072_sha1,
    rsa_decrypt_oaep_4096_sha1,
    ec_sign_p256_sha256,
    ec_sign_p384_sha384,
    /// HSM only, says the proto.
    ec_sign_secp256k1_sha256,
    ec_sign_ed25519,
    hmac_sha256,
    hmac_sha1,
    hmac_sha384,
    hmac_sha512,
    hmac_sha224,
    external_symmetric_encryption,
    ml_kem_768,
    ml_kem_1024,
    kem_xwing,
    pq_sign_ml_dsa_44,
    pq_sign_ml_dsa_65,
    pq_sign_ml_dsa_87,
    pq_sign_slh_dsa_sha2_128s,
    pq_sign_hash_slh_dsa_sha2_128s_sha256,
    pq_sign_ml_dsa_44_external_mu,
    pq_sign_ml_dsa_65_external_mu,
    pq_sign_ml_dsa_87_external_mu,
    aes_256_kwp,
    kem_ecdh_p256,
    kem_ecdh_p384,
    unknown,

    const names = WireNames(Algorithm, "CRYPTO_KEY_VERSION_ALGORITHM_UNSPECIFIED");
    pub const wire = names.wire;
    pub const fromWire = names.fromWire;

    /// The purpose of the keys whose versions use it.
    pub fn purpose(a: Algorithm) Purpose {
        return switch (a) {
            .google_symmetric_encryption, .external_symmetric_encryption => .encrypt_decrypt,
            .aes_128_gcm, .aes_256_gcm, .aes_128_cbc, .aes_256_cbc, .aes_128_ctr, .aes_256_ctr => .raw_encrypt_decrypt,
            .rsa_sign_pss_2048_sha256,
            .rsa_sign_pss_3072_sha256,
            .rsa_sign_pss_4096_sha256,
            .rsa_sign_pss_4096_sha512,
            .rsa_sign_pkcs1_2048_sha256,
            .rsa_sign_pkcs1_3072_sha256,
            .rsa_sign_pkcs1_4096_sha256,
            .rsa_sign_pkcs1_4096_sha512,
            .rsa_sign_raw_pkcs1_2048,
            .rsa_sign_raw_pkcs1_3072,
            .rsa_sign_raw_pkcs1_4096,
            .ec_sign_p256_sha256,
            .ec_sign_p384_sha384,
            .ec_sign_secp256k1_sha256,
            .ec_sign_ed25519,
            .pq_sign_ml_dsa_44,
            .pq_sign_ml_dsa_65,
            .pq_sign_ml_dsa_87,
            .pq_sign_slh_dsa_sha2_128s,
            .pq_sign_hash_slh_dsa_sha2_128s_sha256,
            .pq_sign_ml_dsa_44_external_mu,
            .pq_sign_ml_dsa_65_external_mu,
            .pq_sign_ml_dsa_87_external_mu,
            => .asymmetric_sign,
            .rsa_decrypt_oaep_2048_sha256,
            .rsa_decrypt_oaep_3072_sha256,
            .rsa_decrypt_oaep_4096_sha256,
            .rsa_decrypt_oaep_4096_sha512,
            .rsa_decrypt_oaep_2048_sha1,
            .rsa_decrypt_oaep_3072_sha1,
            .rsa_decrypt_oaep_4096_sha1,
            => .asymmetric_decrypt,
            .hmac_sha256, .hmac_sha1, .hmac_sha384, .hmac_sha512, .hmac_sha224 => .mac,
            .ml_kem_768, .ml_kem_1024, .kem_xwing, .kem_ecdh_p256, .kem_ecdh_p384 => .key_encapsulation,
            .aes_256_kwp => .aes_wrapping,
            .unknown => .unknown,
        };
    }

    /// Whether a new version of this algorithm starts `PENDING_GENERATION`
    /// rather than `ENABLED`: every asymmetric one, as Google documents.
    pub fn generatesSlowly(a: Algorithm) bool {
        return switch (a.purpose()) {
            .asymmetric_sign, .asymmetric_decrypt, .key_encapsulation => true,
            else => false,
        };
    }

    /// What a signature of this algorithm is made over, or null for one
    /// that does not sign, or signs input this library does not prepare:
    /// raw PKCS#1 (a DigestInfo the caller builds) and ML-DSA's external mu.
    pub fn signInput(a: Algorithm) ?SignInput {
        return switch (a) {
            .ec_sign_p256_sha256,
            .ec_sign_secp256k1_sha256,
            .rsa_sign_pss_2048_sha256,
            .rsa_sign_pss_3072_sha256,
            .rsa_sign_pss_4096_sha256,
            .rsa_sign_pkcs1_2048_sha256,
            .rsa_sign_pkcs1_3072_sha256,
            .rsa_sign_pkcs1_4096_sha256,
            .pq_sign_hash_slh_dsa_sha2_128s_sha256,
            => .{ .digest = .sha256 },
            .ec_sign_p384_sha384 => .{ .digest = .sha384 },
            .rsa_sign_pss_4096_sha512, .rsa_sign_pkcs1_4096_sha512 => .{ .digest = .sha512 },
            .ec_sign_ed25519, .pq_sign_ml_dsa_44, .pq_sign_ml_dsa_65, .pq_sign_ml_dsa_87, .pq_sign_slh_dsa_sha2_128s => .data,
            else => null,
        };
    }

    /// Whether the public key comes in the NIST encoding rather than as a
    /// PEM: the post-quantum ones.
    pub fn postQuantum(a: Algorithm) bool {
        return switch (a) {
            .pq_sign_ml_dsa_44,
            .pq_sign_ml_dsa_65,
            .pq_sign_ml_dsa_87,
            .pq_sign_slh_dsa_sha2_128s,
            .pq_sign_hash_slh_dsa_sha2_128s_sha256,
            .pq_sign_ml_dsa_44_external_mu,
            .pq_sign_ml_dsa_65_external_mu,
            .pq_sign_ml_dsa_87_external_mu,
            .ml_kem_768,
            .ml_kem_1024,
            .kem_xwing,
            => true,
            else => false,
        };
    }
};

/// A digest a signing key takes in place of the message.
pub const DigestKind = enum {
    sha256,
    sha384,
    sha512,

    pub fn length(d: DigestKind) usize {
        return switch (d) {
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
    }

    /// `msg`'s digest, into `out`, which is at least 64 bytes.
    pub fn digest(d: DigestKind, msg: []const u8, out: []u8) []const u8 {
        const sha2 = std.crypto.hash.sha2;
        switch (d) {
            inline else => |t| {
                const H = switch (t) {
                    .sha256 => sha2.Sha256,
                    .sha384 => sha2.Sha384,
                    .sha512 => sha2.Sha512,
                };
                H.hash(msg, out[0..H.digest_length], .{});
                return out[0..H.digest_length];
            },
        }
    }
};

/// What a signature is made over.
pub const SignInput = union(enum) {
    /// The message's digest, made here.
    digest: DigestKind,
    /// The message itself, at most 64 KiB.
    data,
};

/// What `Key.encrypt` answers.
pub const Ciphertext = struct {
    /// Opaque: they name the version that made them, which `decrypt` finds.
    bytes: []const u8,
    /// The version the server encrypted with. After a primary change it may
    /// be the old primary for a while.
    version: u64,
};

pub const WaitOptions = struct {
    /// How long to wait in all, from the call. Google's own tests waited
    /// 3.75 s and 30 s and both flaked; a FAQ says "a few minutes".
    timeout_ms: u32 = 5 * std.time.ms_per_min,
};

pub const EncryptOptions = struct {
    /// Bound to the ciphertext: `decrypt` needs the same bytes. At most
    /// 64 KiB.
    aad: []const u8 = "",
    /// Encrypt with this version rather than the primary.
    version: ?u64 = null,
};

pub const DecryptOptions = struct {
    /// The bytes `encrypt` was given as `aad`.
    aad: []const u8 = "",
};

/// Why a signature did not verify on this machine.
pub const VerifyError = error{
    /// The signature is not this key's over this message or digest.
    SignatureInvalid,
    /// An algorithm this library cannot verify here: SLH-DSA, which std
    /// does not have; a digest for an algorithm that signs data (Ed25519,
    /// ML-DSA); one that does not sign.
    UnsupportedAlgorithm,
    /// A public key that does not decode as its algorithm's.
    InvalidPublicKey,
};

/// A version's public key, as `KeyVersion.publicKey` answers it. It never
/// changes, so it may be kept for as long as the version lives.
pub const PublicKey = struct {
    /// The version's name.
    name: []const u8,
    algorithm: Algorithm,
    protection_level: ProtectionLevel = .unknown,
    /// A PEM SubjectPublicKeyInfo: every key production gave as one,
    /// ML-DSA's included; "" for one it gave only in the NIST encoding.
    pem: []const u8 = "",
    /// The NIST encoding of a post-quantum key, when that is how it came;
    /// "" otherwise.
    raw: []const u8 = "",

    /// Checks `signature` over `message` here, with std.crypto; no call.
    pub fn verify(pk: PublicKey, message: []const u8, signature: []const u8) VerifyError!void {
        return verify_impl.verify(pk, message, signature);
    }

    /// Checks `signature` over a digest made elsewhere: the ECDSA and RSA
    /// algorithms, whose signatures are made over a digest.
    pub fn verifyDigest(pk: PublicKey, digest: []const u8, signature: []const u8) VerifyError!void {
        return verify_impl.verifyDigest(pk, digest, signature);
    }
};

/// A version's state. Only `enabled` versions can be used.
pub const State = enum {
    /// Being made; asymmetric versions start here.
    pending_generation,
    enabled,
    disabled,
    destroyed,
    /// Destroyed at `VersionInfo.destroy_time` unless restored first.
    destroy_scheduled,
    pending_import,
    import_failed,
    generation_failed,
    pending_external_destruction,
    external_destruction_failed,
    unknown,

    const names = WireNames(State, "CRYPTO_KEY_VERSION_STATE_UNSPECIFIED");
    pub const wire = names.wire;
    pub const fromWire = names.fromWire;

    /// Whether a version in this state is billed: every state until its
    /// material is destroyed, disabled included.
    pub fn billed(s: State) bool {
        return switch (s) {
            .enabled, .disabled, .destroy_scheduled, .pending_generation, .pending_import, .pending_external_destruction => true,
            .destroyed, .import_failed, .generation_failed, .external_destruction_failed, .unknown => false,
        };
    }
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// Automatic rotation of an `encrypt_decrypt` key: at `next`, and every
/// `period_s` after, the server makes a version and makes it primary.
pub const Rotation = struct {
    /// 1 day to 100 years (876,000 hours).
    period_s: u32,
    next: std.Io.Timestamp,
};

/// A key to create.
pub const KeyConfig = struct {
    purpose: Purpose,
    /// Required unless the purpose is `.encrypt_decrypt`, which implies
    /// `.google_symmetric_encryption`. Must be of `purpose`.
    algorithm: ?Algorithm = null,
    protection_level: ProtectionLevel = .software,
    /// How long a destroyed version can still be restored, 1 to 120 days.
    /// Fixed at creation. Null leaves the server's 30 days; an organization
    /// policy may require more.
    destroy_delay_s: ?u32 = null,
    /// `.encrypt_decrypt` only.
    rotation: ?Rotation = null,
    /// Up to 64; see `limits`.
    labels: []const Label = &.{},
    /// False creates the key with no version (`skipInitialVersionCreation`):
    /// nothing to bill, and nothing to use until `createVersion`. Such a key
    /// can be deleted at once.
    first_version: bool = true,
};

/// What an update changes; every field defaults to leaving it as it is.
pub const KeyUpdate = struct {
    /// The key's labels, replaced whole: `.set` with the new list, which
    /// may be empty, or `.clear` for none.
    labels: core.Change([]const Label) = .keep,
    /// Automatic rotation, set or turned off.
    rotation: core.Change(Rotation) = .keep,
    /// The algorithm of versions made from now on, of the key's purpose.
    algorithm: ?Algorithm = null,
};

/// A key ring: a name and nothing else. Key rings cost nothing.
pub const KeyRingInfo = struct {
    /// `projects/P/locations/L/keyRings/R`.
    name: []const u8,
    create_time: ?std.Io.Timestamp,
};

pub const KeyRingPage = struct {
    key_rings: []const KeyRingInfo,
    next_page_token: ?[]const u8,
};

/// A key version.
pub const VersionInfo = struct {
    /// `projects/P/locations/L/keyRings/R/cryptoKeys/K/cryptoKeyVersions/V`.
    name: []const u8,
    /// V: versions are numbered from 1, in order.
    id: u64,
    state: State,
    protection_level: ProtectionLevel,
    algorithm: Algorithm,
    create_time: ?std.Io.Timestamp = null,
    /// When its material was made.
    generate_time: ?std.Io.Timestamp = null,
    /// When a `destroy_scheduled` version will be destroyed.
    destroy_time: ?std.Io.Timestamp = null,
    /// When a `destroyed` version was.
    destroy_event_time: ?std.Io.Timestamp = null,
    /// Why a `generation_failed` version failed; "" otherwise.
    generation_failure_reason: []const u8 = "",
    /// Why an `import_failed` version failed; "" otherwise.
    import_failure_reason: []const u8 = "",
};

pub const VersionPage = struct {
    versions: []const VersionInfo,
    next_page_token: ?[]const u8,
};

/// A key.
pub const KeyInfo = struct {
    /// `projects/P/locations/L/keyRings/R/cryptoKeys/K`.
    name: []const u8,
    purpose: Purpose,
    /// The version `encrypt` uses: `encrypt_decrypt` keys only, and null
    /// for one with no version yet.
    primary: ?VersionInfo = null,
    create_time: ?std.Io.Timestamp = null,
    /// When automatic rotation next makes a version; null when none is set.
    next_rotation: ?std.Io.Timestamp = null,
    /// Null when the key does not rotate by itself.
    rotation_period_s: ?u64 = null,
    /// What new versions are made with.
    protection_level: ProtectionLevel = .unknown,
    algorithm: Algorithm = .unknown,
    labels: []const Label = &.{},
    import_only: bool = false,
    /// How long a destroyed version can still be restored, in seconds.
    destroy_delay_s: ?u64 = null,
    /// The EKM connection or single-tenant HSM behind the key; "" for none.
    backend: []const u8 = "",
};

pub const KeyPage = struct {
    keys: []const KeyInfo,
    next_page_token: ?[]const u8,
};

pub const ListOptions = struct {
    /// 0 lets the server choose.
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
    /// A filter in Cloud KMS's syntax, such as `labels.team=alpha` or
    /// `state=ENABLED`. Sent as given.
    filter: ?[]const u8 = null,
    /// `name` or `name desc`. Sent as given.
    order_by: ?[]const u8 = null,
};

/// A location, with what it offers.
pub const LocationInfo = struct {
    /// `projects/P/locations/L`.
    name: []const u8,
    /// L, such as "us-central1" or "global".
    id: []const u8,
    display_name: []const u8 = "",
    hsm_available: bool = false,
    ekm_available: bool = false,
};

pub const LocationPage = struct {
    locations: []const LocationInfo,
    next_page_token: ?[]const u8,
};

/// A deleted key's record. Its id can never be used again in the project.
pub const RetiredKey = struct {
    /// `projects/P/locations/L/retiredResources/X`.
    name: []const u8,
    /// The deleted key's full name.
    original_name: []const u8,
    /// "CryptoKey", as production wrote it.
    resource_type: []const u8 = "",
    delete_time: ?std.Io.Timestamp = null,
};

pub const RetiredKeyPage = struct {
    retired_keys: []const RetiredKey,
    next_page_token: ?[]const u8,
};

const testing = std.testing;

test "wire names: every tag's name in capitals both ways, unknown for anything else" {
    inline for (.{ Purpose, ProtectionLevel, Algorithm, State }) |E| {
        inline for (@typeInfo(E).@"enum".field_names) |tag| {
            const e = @field(E, tag);
            if (e == .unknown) {
                try testing.expectEqual(E.unknown, E.fromWire(e.wire()));
            } else {
                try testing.expectEqual(e, E.fromWire(e.wire()));
                for (e.wire(), tag) |w, t| try testing.expectEqual(std.ascii.toUpper(t), w);
            }
        }
        try testing.expectEqual(E.unknown, E.fromWire(""));
        try testing.expectEqual(E.unknown, E.fromWire("NOT_A_NAME"));
    }
    try testing.expectEqualStrings("EC_SIGN_P256_SHA256", Algorithm.ec_sign_p256_sha256.wire());
    try testing.expectEqualStrings("PQ_SIGN_HASH_SLH_DSA_SHA2_128S_SHA256", Algorithm.pq_sign_hash_slh_dsa_sha2_128s_sha256.wire());
    try testing.expectEqualStrings("CRYPTO_KEY_VERSION_ALGORITHM_UNSPECIFIED", Algorithm.unknown.wire());
    try testing.expectEqualStrings("DESTROY_SCHEDULED", State.destroy_scheduled.wire());
    try testing.expectEqualStrings("ENCRYPT_DECRYPT", Purpose.encrypt_decrypt.wire());
    try testing.expectEqualStrings("HSM_SINGLE_TENANT", ProtectionLevel.hsm_single_tenant.wire());
    // Case matters, as it does to the server.
    try testing.expectEqual(State.unknown, State.fromWire("enabled"));
}

test "algorithms: each family's purpose, and which start pending" {
    try testing.expectEqual(Purpose.encrypt_decrypt, Algorithm.google_symmetric_encryption.purpose());
    try testing.expectEqual(Purpose.asymmetric_sign, Algorithm.ec_sign_ed25519.purpose());
    try testing.expectEqual(Purpose.asymmetric_sign, Algorithm.pq_sign_ml_dsa_65.purpose());
    try testing.expectEqual(Purpose.asymmetric_decrypt, Algorithm.rsa_decrypt_oaep_4096_sha1.purpose());
    try testing.expectEqual(Purpose.mac, Algorithm.hmac_sha224.purpose());
    try testing.expectEqual(Purpose.raw_encrypt_decrypt, Algorithm.aes_128_ctr.purpose());
    try testing.expectEqual(Purpose.key_encapsulation, Algorithm.kem_xwing.purpose());
    try testing.expectEqual(Purpose.aes_wrapping, Algorithm.aes_256_kwp.purpose());
    try testing.expectEqual(Purpose.unknown, Algorithm.unknown.purpose());
    try testing.expect(Algorithm.rsa_sign_pkcs1_2048_sha256.generatesSlowly());
    try testing.expect(!Algorithm.google_symmetric_encryption.generatesSlowly());
    try testing.expect(!Algorithm.hmac_sha256.generatesSlowly());
}

test "billing: every state until destroyed" {
    try testing.expect(State.disabled.billed());
    try testing.expect(State.destroy_scheduled.billed());
    try testing.expect(!State.destroyed.billed());
}

test "signing algorithms: what each signs, and which keys come in the NIST encoding" {
    try testing.expectEqual(SignInput{ .digest = .sha256 }, Algorithm.ec_sign_p256_sha256.signInput().?);
    try testing.expectEqual(SignInput{ .digest = .sha384 }, Algorithm.ec_sign_p384_sha384.signInput().?);
    try testing.expectEqual(SignInput{ .digest = .sha512 }, Algorithm.rsa_sign_pss_4096_sha512.signInput().?);
    try testing.expectEqual(SignInput.data, Algorithm.pq_sign_ml_dsa_87.signInput().?);
    try testing.expectEqual(null, Algorithm.rsa_sign_raw_pkcs1_3072.signInput());
    try testing.expectEqual(null, Algorithm.hmac_sha256.signInput());
    // Every algorithm that signs is of the signing purpose.
    inline for (@typeInfo(Algorithm).@"enum".field_names) |tag| {
        const a = @field(Algorithm, tag);
        if (a.signInput() != null) try testing.expectEqual(Purpose.asymmetric_sign, a.purpose());
    }
    try testing.expect(Algorithm.kem_xwing.postQuantum());
    try testing.expect(!Algorithm.ec_sign_ed25519.postQuantum());
    var buf: [64]u8 = undefined;
    for ([_]DigestKind{ .sha256, .sha384, .sha512 }) |d| try testing.expectEqual(d.length(), d.digest("m", &buf).len);
}
