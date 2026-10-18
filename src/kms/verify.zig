//! Verifying a Cloud KMS signature on this machine, from the public key
//! `KeyVersion.publicKey` answers, with no call: ECDSA (P-256, P-384,
//! secp256k1), Ed25519 and ML-DSA through std.crypto, RSA PKCS#1 v1.5 and
//! PSS through core.rsa. A classical key is a PEM SubjectPublicKeyInfo; a
//! post-quantum one is its NIST encoding.

const std = @import("std");
const core = @import("core");
const types = @import("types.zig");

const VerifyError = types.VerifyError;
const ecdsa = std.crypto.sign.ecdsa;
const mldsa = std.crypto.sign.mldsa;
const Ed25519 = std.crypto.sign.Ed25519;
const rsa = core.rsa;

const ec_public_key_oid = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const p256_oid = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const p384_oid = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };
const secp256k1_oid = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x0a };
const ed25519_oid = [_]u8{ 0x2b, 0x65, 0x70 };
/// id-ml-dsa-44, -65 and -87: 2.16.840.1.101.3.4.3.17 to .19.
const mldsa_oid_prefix = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03 };

/// The longest SubjectPublicKeyInfo read: an RSA 4096 one is under 600 bytes.
const max_spki = 1024;

pub fn verify(pk: types.PublicKey, message: []const u8, signature: []const u8) VerifyError!void {
    if (rsaScheme(pk.algorithm)) |scheme| {
        var buf: [64]u8 = undefined;
        return verifyRsa(pk, scheme, scheme.hash.digest(message, &buf), signature);
    }
    return switch (pk.algorithm) {
        .ec_sign_p256_sha256 => verifyEc(ecdsa.EcdsaP256Sha256, &p256_oid, pk, .{ .message = message }, signature),
        .ec_sign_p384_sha384 => verifyEc(ecdsa.EcdsaP384Sha384, &p384_oid, pk, .{ .message = message }, signature),
        .ec_sign_secp256k1_sha256 => verifyEc(ecdsa.EcdsaSecp256k1Sha256, &secp256k1_oid, pk, .{ .message = message }, signature),
        .ec_sign_ed25519 => verifyEd25519(pk, message, signature),
        .pq_sign_ml_dsa_44 => verifyMlDsa(mldsa.MLDSA44, 0x11, pk, message, signature),
        .pq_sign_ml_dsa_65 => verifyMlDsa(mldsa.MLDSA65, 0x12, pk, message, signature),
        .pq_sign_ml_dsa_87 => verifyMlDsa(mldsa.MLDSA87, 0x13, pk, message, signature),
        else => error.UnsupportedAlgorithm,
    };
}

pub fn verifyDigest(pk: types.PublicKey, digest: []const u8, signature: []const u8) VerifyError!void {
    if (rsaScheme(pk.algorithm)) |scheme| {
        if (digest.len != scheme.hash.digestLength()) return error.SignatureInvalid;
        return verifyRsa(pk, scheme, digest, signature);
    }
    return switch (pk.algorithm) {
        .ec_sign_p256_sha256 => verifyEc(ecdsa.EcdsaP256Sha256, &p256_oid, pk, .{ .digest = digest }, signature),
        .ec_sign_p384_sha384 => verifyEc(ecdsa.EcdsaP384Sha384, &p384_oid, pk, .{ .digest = digest }, signature),
        .ec_sign_secp256k1_sha256 => verifyEc(ecdsa.EcdsaSecp256k1Sha256, &secp256k1_oid, pk, .{ .digest = digest }, signature),
        else => error.UnsupportedAlgorithm,
    };
}

const RsaScheme = struct { pss: bool, hash: rsa.Hash };

fn rsaScheme(a: types.Algorithm) ?RsaScheme {
    return switch (a) {
        .rsa_sign_pkcs1_2048_sha256, .rsa_sign_pkcs1_3072_sha256, .rsa_sign_pkcs1_4096_sha256 => .{ .pss = false, .hash = .sha256 },
        .rsa_sign_pkcs1_4096_sha512 => .{ .pss = false, .hash = .sha512 },
        .rsa_sign_pss_2048_sha256, .rsa_sign_pss_3072_sha256, .rsa_sign_pss_4096_sha256 => .{ .pss = true, .hash = .sha256 },
        .rsa_sign_pss_4096_sha512 => .{ .pss = true, .hash = .sha512 },
        else => null,
    };
}

fn verifyRsa(pk: types.PublicKey, scheme: RsaScheme, digest: []const u8, signature: []const u8) VerifyError!void {
    var buf: [max_spki]u8 = undefined;
    const der = try spkiOf(pk.pem, &buf);
    const key = rsa.PublicKey.fromSpki(der) catch return error.InvalidPublicKey;
    const checked = if (scheme.pss) key.verifyPss(scheme.hash, digest, signature) else key.verifyPkcs1(scheme.hash, digest, signature);
    checked catch return error.SignatureInvalid;
}

const EcInput = union(enum) { message: []const u8, digest: []const u8 };

fn verifyEc(comptime Scheme: type, curve: []const u8, pk: types.PublicKey, input: EcInput, signature: []const u8) VerifyError!void {
    var buf: [max_spki]u8 = undefined;
    const point = try keyBits(try spkiOf(pk.pem, &buf), &ec_public_key_oid, curve);
    const key = Scheme.PublicKey.fromSec1(point) catch return error.InvalidPublicKey;
    const sig = Scheme.Signature.fromDer(signature) catch return error.SignatureInvalid;
    switch (input) {
        .message => |m| sig.verify(m, key) catch return error.SignatureInvalid,
        .digest => |d| {
            if (d.len != Scheme.Hash.digest_length) return error.SignatureInvalid;
            sig.verifyPrehashed(d[0..Scheme.Hash.digest_length].*, key) catch return error.SignatureInvalid;
        },
    }
}

fn verifyEd25519(pk: types.PublicKey, message: []const u8, signature: []const u8) VerifyError!void {
    var buf: [max_spki]u8 = undefined;
    const bits = try keyBits(try spkiOf(pk.pem, &buf), &ed25519_oid, null);
    if (bits.len != Ed25519.PublicKey.encoded_length) return error.InvalidPublicKey;
    const key = Ed25519.PublicKey.fromBytes(bits[0..Ed25519.PublicKey.encoded_length].*) catch return error.InvalidPublicKey;
    if (signature.len != Ed25519.Signature.encoded_length) return error.SignatureInvalid;
    const sig = Ed25519.Signature.fromBytes(signature[0..Ed25519.Signature.encoded_length].*);
    sig.verify(message, key) catch return error.SignatureInvalid;
}

/// From the NIST encoding, or from a PEM whose algorithm is the variant's
/// OID, ending in `oid_last`, with no parameters.
fn verifyMlDsa(comptime Scheme: type, comptime oid_last: u8, pk: types.PublicKey, message: []const u8, signature: []const u8) VerifyError!void {
    const key_len = Scheme.PublicKey.encoded_length;
    var buf: [4096]u8 = undefined;
    const raw = if (pk.raw.len > 0) pk.raw else try keyBits(try spkiOf(pk.pem, &buf), &(mldsa_oid_prefix ++ [_]u8{oid_last}), null);
    if (raw.len != key_len) return error.InvalidPublicKey;
    const key = Scheme.PublicKey.fromBytes(raw[0..key_len].*) catch return error.InvalidPublicKey;
    const sig_len = Scheme.Signature.encoded_length;
    if (signature.len != sig_len) return error.SignatureInvalid;
    const sig = Scheme.Signature.fromBytes(signature[0..sig_len].*) catch return error.SignatureInvalid;
    sig.verify(message, key) catch return error.SignatureInvalid;
}

/// The DER inside a `PUBLIC KEY` PEM, into `buf`.
fn spkiOf(pem: []const u8, buf: []u8) VerifyError![]const u8 {
    const begin = "-----BEGIN PUBLIC KEY-----";
    const end = "-----END PUBLIC KEY-----";
    const start = std.mem.indexOf(u8, pem, begin) orelse return error.InvalidPublicKey;
    const stop = std.mem.indexOfPos(u8, pem, start + begin.len, end) orelse return error.InvalidPublicKey;
    const body = pem[start + begin.len .. stop];
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const len = decoder.decode(buf, body) catch return error.InvalidPublicKey;
    return buf[0..len];
}

/// The key bits of a SubjectPublicKeyInfo whose algorithm is `algorithm`,
/// with `parameter` as its one parameter OID, or none when null.
fn keyBits(der: []const u8, algorithm: []const u8, parameter: ?[]const u8) VerifyError![]const u8 {
    var pos: usize = 0;
    const outer = readElement(der, &pos) orelse return error.InvalidPublicKey;
    if (outer.tag != 0x30 or pos != der.len) return error.InvalidPublicKey;
    var p: usize = 0;
    const id = readElement(outer.body, &p) orelse return error.InvalidPublicKey;
    if (id.tag != 0x30) return error.InvalidPublicKey;
    var a: usize = 0;
    const oid = readElement(id.body, &a) orelse return error.InvalidPublicKey;
    if (oid.tag != 0x06 or !std.mem.eql(u8, oid.body, algorithm)) return error.InvalidPublicKey;
    if (parameter) |want| {
        const param = readElement(id.body, &a) orelse return error.InvalidPublicKey;
        if (param.tag != 0x06 or !std.mem.eql(u8, param.body, want)) return error.InvalidPublicKey;
    }
    if (a != id.body.len) return error.InvalidPublicKey;
    const bits = readElement(outer.body, &p) orelse return error.InvalidPublicKey;
    if (bits.tag != 0x03 or bits.body.len < 2 or bits.body[0] != 0 or p != outer.body.len) return error.InvalidPublicKey;
    return bits.body[1..];
}

const Element = struct { tag: u8, body: []const u8 };

/// One DER element at `pos`, which moves past it; null when the bytes do
/// not hold one.
fn readElement(bytes: []const u8, pos: *usize) ?Element {
    var i = pos.*;
    if (bytes.len < i + 2) return null;
    const tag = bytes[i];
    var len: usize = bytes[i + 1];
    i += 2;
    if (len >= 0x80) {
        const n = len - 0x80;
        if (n == 0 or n > 2 or bytes.len - i < n) return null;
        len = 0;
        for (bytes[i..][0..n]) |b| len = (len << 8) | b;
        i += n;
    }
    if (bytes.len - i < len) return null;
    pos.* = i + len;
    return .{ .tag = tag, .body = bytes[i..][0..len] };
}

const testing = std.testing;
const vectors = @import("test_vectors.zig");

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "OpenSSL's signatures verify here, and nothing else does" {
    const cases = [_]struct { types.Algorithm, []const u8, []const u8 }{
        .{ .ec_sign_p256_sha256, vectors.p256_public, &hex(vectors.p256_signature_hex) },
        .{ .ec_sign_p384_sha384, vectors.p384_public, &hex(vectors.p384_signature_hex) },
        .{ .ec_sign_ed25519, vectors.ed25519_public, &hex(vectors.ed25519_signature_hex) },
    };
    for (cases) |case| {
        const pk: types.PublicKey = .{ .name = "v", .algorithm = case[0], .pem = case[1] };
        try pk.verify(vectors.message, case[2]);
        try testing.expectError(error.SignatureInvalid, pk.verify("the messagE", case[2]));
    }
    // By digest, for the ECDSA ones.
    var d256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(vectors.message, &d256, .{});
    try verifyDigest(.{ .name = "v", .algorithm = .ec_sign_p256_sha256, .pem = vectors.p256_public }, &d256, &hex(vectors.p256_signature_hex));
    var d384: [48]u8 = undefined;
    std.crypto.hash.sha2.Sha384.hash(vectors.message, &d384, .{});
    try verifyDigest(.{ .name = "v", .algorithm = .ec_sign_p384_sha384, .pem = vectors.p384_public }, &d384, &hex(vectors.p384_signature_hex));
    try testing.expectError(error.SignatureInvalid, verifyDigest(.{ .name = "v", .algorithm = .ec_sign_p384_sha384, .pem = vectors.p384_public }, &d256, &hex(vectors.p384_signature_hex)));

    const ml: types.PublicKey = .{ .name = "v", .algorithm = .pq_sign_ml_dsa_44, .raw = &hex(vectors.mldsa44_public_hex) };
    try ml.verify(vectors.message, &hex(vectors.mldsa44_signature_hex));
    try testing.expectError(error.SignatureInvalid, ml.verify("other", &hex(vectors.mldsa44_signature_hex)));
    try testing.expectError(error.SignatureInvalid, ml.verify(vectors.message, &hex(vectors.p256_signature_hex)));
    const wrong_size: types.PublicKey = .{ .name = "v", .algorithm = .pq_sign_ml_dsa_65, .raw = &hex(vectors.mldsa44_public_hex) };
    try testing.expectError(error.InvalidPublicKey, wrong_size.verify(vectors.message, &hex(vectors.mldsa44_signature_hex)));

    // RSA: OpenSSL's PKCS#1 v1.5 and PSS signatures by core.rsa's 2048-bit key.
    const rsa_cases = [_]struct { types.Algorithm, []const u8 }{
        .{ .rsa_sign_pkcs1_2048_sha256, &hex(core.rsa.test_sig_2048_hex) },
        .{ .rsa_sign_pss_2048_sha256, &hex(core.rsa.test_sig_2048_pss_hex) },
    };
    for (rsa_cases) |case| {
        const pk: types.PublicKey = .{ .name = "v", .algorithm = case[0], .pem = core.rsa.test_key_2048_public };
        try pk.verify(core.rsa.test_message, case[1]);
        try testing.expectError(error.SignatureInvalid, pk.verify("other", case[1]));
    }
    const pss: types.PublicKey = .{ .name = "v", .algorithm = .rsa_sign_pss_2048_sha256, .pem = core.rsa.test_key_2048_public };
    try pss.verify(vectors.message, &hex(vectors.rsa_pss_signature_hex));
    // PKCS#1 v1.5 by SHA-512 is a 4096-bit algorithm in Cloud KMS; the
    // verifier takes the key it is given.
    const sha512: types.PublicKey = .{ .name = "v", .algorithm = .rsa_sign_pkcs1_4096_sha512, .pem = core.rsa.test_key_2048_public };
    try sha512.verify(core.rsa.test_message, &hex(core.rsa.test_sig_2048_sha512_hex));
    var d512: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(core.rsa.test_message, &d512, .{});
    try sha512.verifyDigest(&d512, &hex(core.rsa.test_sig_2048_sha512_hex));
    try testing.expectError(error.SignatureInvalid, sha512.verifyDigest(d512[0..32], &hex(core.rsa.test_sig_2048_sha512_hex)));
    // An RSA algorithm with an EC key is the wrong key.
    const mismatched: types.PublicKey = .{ .name = "v", .algorithm = .rsa_sign_pss_2048_sha256, .pem = vectors.p256_public };
    try testing.expectError(error.InvalidPublicKey, mismatched.verify("m", "s"));
}

test "SubjectPublicKeyInfo parsing refuses what is not one" {
    var buf: [max_spki]u8 = undefined;
    const der = try spkiOf(vectors.p256_public, &buf);
    try testing.expectEqual(65, (try keyBits(der, &ec_public_key_oid, &p256_oid)).len);
    try testing.expectError(error.InvalidPublicKey, keyBits(der, &ec_public_key_oid, &p384_oid));
    try testing.expectError(error.InvalidPublicKey, keyBits(der, &ed25519_oid, null));
    try testing.expectError(error.InvalidPublicKey, keyBits(der[0 .. der.len - 1], &ec_public_key_oid, &p256_oid));
    var trailing: [max_spki]u8 = undefined;
    @memcpy(trailing[0..der.len], der);
    trailing[der.len] = 0;
    try testing.expectError(error.InvalidPublicKey, keyBits(trailing[0 .. der.len + 1], &ec_public_key_oid, &p256_oid));
    try testing.expectError(error.InvalidPublicKey, keyBits("", &ec_public_key_oid, null));
    try testing.expectError(error.InvalidPublicKey, spkiOf("-----BEGIN PUBLIC KEY-----", &buf));
}

fn verifyProperty(_: void, input: []const u8) !void {
    // Arbitrary keys and signatures, for every algorithm: an answer, never
    // a crash, and never a signature taken that no key made.
    var g: core.testing.ByteGen = .init(input);
    const algorithms = [_]types.Algorithm{ .ec_sign_p256_sha256, .ec_sign_p384_sha384, .ec_sign_secp256k1_sha256, .ec_sign_ed25519, .rsa_sign_pkcs1_2048_sha256, .rsa_sign_pss_4096_sha512, .pq_sign_ml_dsa_44 };
    const algorithm = algorithms[g.byte() % algorithms.len];
    const split = @min(input.len, g.byte());
    const rest = input[@min(input.len, 2)..];
    const key_bytes = rest[0..@min(rest.len, split)];
    const signature = rest[@min(rest.len, split)..];
    var pem_buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&pem_buf);
    w.writeAll("-----BEGIN PUBLIC KEY-----\n") catch return;
    std.base64.standard.Encoder.encodeWriter(&w, key_bytes) catch return;
    w.writeAll("\n-----END PUBLIC KEY-----\n") catch return;
    const pk: types.PublicKey = .{ .name = "v", .algorithm = algorithm, .pem = w.buffered(), .raw = key_bytes };
    if (pk.verify("m", signature)) |_| return error.TestUnexpectedResult else |_| {}
    if (pk.verifyDigest(signature[0..@min(signature.len, 32)], signature)) |_| return error.TestUnexpectedResult else |_| {}
}

test "fuzz verify: arbitrary keys and signatures are refused, never a crash" {
    try core.testing.fuzzBytes({}, verifyProperty, .{ .corpus = &.{
        "\x00\x40\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00\x04",
        "\x03\x2c\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00",
        "",
    } });
}
