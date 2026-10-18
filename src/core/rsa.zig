//! RSA signing and verifying: RSASSA-PKCS1-v1_5 over SHA-256, the one
//! scheme Google's token endpoint accepts for a service account's JWT
//! assertion, and the PKCS#1 v1.5 and PSS schemes Cloud KMS signs with,
//! over SHA-256, SHA-384 and SHA-512, from a digest. Parses the PEM private
//! key a key file carries, PKCS#8 (`PRIVATE KEY`) or PKCS#1 (`RSA PRIVATE
//! KEY`), without allocating: the decoded key lives on the stack and is
//! wiped. Reads and writes a public key as a SubjectPublicKeyInfo, the form
//! Cloud KMS hands out.
//!
//! The modular exponentiation is `std.crypto.ff`, whose secret-exponent
//! path is constant-time. Every signature is checked against the public
//! exponent before it is returned, so a corrupted key fails here, loudly,
//! instead of at the server.

const std = @import("std");
const ff = std.crypto.ff;
const sha2 = std.crypto.hash.sha2;
const Sha256 = sha2.Sha256;

/// Google issues 2048-bit service account keys and accepts uploaded keys
/// up to 4096 bits.
pub const max_modulus_bits = 4096;
/// Uploaded keys may be as small as 1024 bits; Google no longer issues them.
pub const min_modulus_bits = 1024;
pub const max_modulus_bytes = max_modulus_bits / 8;

const Modulus = ff.Modulus(max_modulus_bits);
const Fe = Modulus.Fe;

pub const ParseError = error{
    /// Not a PEM private key, or one whose contents do not decode.
    InvalidPrivateKey,
    /// A well-formed key this code cannot use: encrypted, not RSA,
    /// multi-prime, or outside the supported modulus sizes.
    UnsupportedKey,
};

pub const SignError = error{
    /// The signature did not verify against the key's own public exponent:
    /// the key is corrupt, or its parts do not belong together. Or, for
    /// PSS, the salt does not fit beside the digest in the modulus.
    SignatureFailed,
};

pub const VerifyError = error{
    /// The signature is not one this key made over this digest.
    SignatureInvalid,
};

pub const PublicKeyError = error{
    /// Not a SubjectPublicKeyInfo, or one whose contents do not decode.
    InvalidPublicKey,
    /// A well-formed key this code cannot use: not RSA, or outside the
    /// supported modulus sizes.
    UnsupportedKey,
};

/// The digests a signature is made over.
pub const Hash = enum {
    sha256,
    sha384,
    sha512,

    pub fn digestLength(h: Hash) usize {
        return switch (h) {
            inline else => |t| t.Type().digest_length,
        };
    }

    fn Type(comptime h: Hash) type {
        return switch (h) {
            .sha256 => sha2.Sha256,
            .sha384 => sha2.Sha384,
            .sha512 => sha2.Sha512,
        };
    }

    /// RFC 8017 9.2, note 1: the DER of DigestInfo up to the digest itself.
    fn digestInfo(h: Hash) []const u8 {
        return switch (h) {
            .sha256 => &.{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
            .sha384 => &.{ 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30 },
            .sha512 => &.{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
        };
    }

    /// `msg`'s digest, into `out`, which is at least 64 bytes.
    pub fn digest(h: Hash, msg: []const u8, out: []u8) []const u8 {
        switch (h) {
            inline else => |t| {
                const H = t.Type();
                H.hash(msg, out[0..H.digest_length], .{});
                return out[0..H.digest_length];
            },
        }
    }
};

pub const PrivateKey = struct {
    n: Modulus,
    e: Fe,
    /// The private exponent, big-endian. Secret: `deinit` wipes it.
    d: [max_modulus_bytes]u8,
    d_len: usize,
    /// The modulus in bytes, which is also every signature's length.
    len: usize,

    pub fn deinit(key: *PrivateKey) void {
        std.crypto.secureZero(u8, &key.d);
        key.* = undefined;
    }

    /// Signs `msg` with RSASSA-PKCS1-v1_5 and SHA-256. Writes `key.len`
    /// bytes into `out` and returns them.
    pub fn sign(key: *const PrivateKey, msg: []const u8, out: []u8) SignError![]const u8 {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(msg, &digest, .{});
        return key.signDigest(.sha256, &digest, out);
    }

    /// Signs a digest made with `hash` with RSASSA-PKCS1-v1_5. Writes
    /// `key.len` bytes into `out` and returns them.
    pub fn signDigest(key: *const PrivateKey, hash: Hash, digest: []const u8, out: []u8) SignError![]const u8 {
        std.debug.assert(digest.len == hash.digestLength());
        var em_buf: [max_modulus_bytes]u8 = undefined;
        const em = encodePkcs1(hash, digest, em_buf[0..key.len]);
        return key.privateOp(em, out);
    }

    /// Signs a digest made with `hash` with RSASSA-PSS, MGF1 over the same
    /// hash and `salt` as the salt, which a caller draws at random, as long
    /// as the digest for the scheme Cloud KMS uses. Writes `key.len` bytes
    /// into `out` and returns them.
    pub fn signPss(key: *const PrivateKey, hash: Hash, digest: []const u8, salt: []const u8, out: []u8) SignError![]const u8 {
        std.debug.assert(digest.len == hash.digestLength());
        const em_bits = key.n.bits() - 1;
        var em_buf: [max_modulus_bytes]u8 = undefined;
        const em = em_buf[0 .. (em_bits + 7) / 8];
        switch (hash) {
            inline else => |t| encodePss(t.Type(), digest, salt, em_bits, em) catch return error.SignatureFailed,
        }
        return key.privateOp(em, out);
    }

    /// The key's public half.
    pub fn publicKey(key: *const PrivateKey) PublicKey {
        return .{ .n = key.n, .e = key.e, .len = key.len };
    }

    /// `em`, an encoded message below the modulus, to the private exponent,
    /// checked against the public one.
    fn privateOp(key: *const PrivateKey, em: []const u8, out: []u8) SignError![]const u8 {
        const k = key.len;
        std.debug.assert(out.len >= k);
        // Every encoding starts with a zero byte or is a byte shorter than
        // the modulus, so it is always below it.
        const m = Fe.fromBytes(key.n, em, .big) catch return error.SignatureFailed;
        const s = key.n.powWithEncodedExponent(m, key.d[0..key.d_len], .big) catch return error.SignatureFailed;
        s.toBytes(out[0..k], .big) catch return error.SignatureFailed;
        const check = key.n.powPublic(s, key.e) catch return error.SignatureFailed;
        if (!check.eql(m)) return error.SignatureFailed;
        return out[0..k];
    }
};

/// The longest SubjectPublicKeyInfo `PublicKey.writeSpki` writes.
pub const max_spki_len = max_modulus_bytes + 64;

/// An RSA public key: verifies signatures made over a digest.
pub const PublicKey = struct {
    n: Modulus,
    e: Fe,
    /// The modulus in bytes, which is also every signature's length.
    len: usize,

    /// Reads a DER SubjectPublicKeyInfo naming `rsaEncryption`.
    pub fn fromSpki(der: []const u8) PublicKeyError!PublicKey {
        var pos: usize = 0;
        const outer = readElement(der, &pos) orelse return error.InvalidPublicKey;
        if (outer.tag != 0x30 or pos != der.len) return error.InvalidPublicKey;
        var p: usize = 0;
        const algorithm = readElement(outer.body, &p) orelse return error.InvalidPublicKey;
        if (algorithm.tag != 0x30) return error.InvalidPublicKey;
        var a: usize = 0;
        const oid = readElement(algorithm.body, &a) orelse return error.InvalidPublicKey;
        if (oid.tag != 0x06) return error.InvalidPublicKey;
        if (!std.mem.eql(u8, oid.body, &rsa_oid)) return error.UnsupportedKey;
        const bits = readElement(outer.body, &p) orelse return error.InvalidPublicKey;
        if (bits.tag != 0x03 or bits.body.len < 1 or bits.body[0] != 0 or p != outer.body.len) return error.InvalidPublicKey;
        var q: usize = 0;
        const seq = readElement(bits.body[1..], &q) orelse return error.InvalidPublicKey;
        if (seq.tag != 0x30) return error.InvalidPublicKey;
        var r: usize = 0;
        const n_int = readElement(seq.body, &r) orelse return error.InvalidPublicKey;
        const e_int = readElement(seq.body, &r) orelse return error.InvalidPublicKey;
        const n_bytes = magnitude(n_int) orelse return error.InvalidPublicKey;
        const e_bytes = magnitude(e_int) orelse return error.InvalidPublicKey;
        if (n_bytes.len > max_modulus_bytes) return error.UnsupportedKey;
        const n = Modulus.fromBytes(n_bytes, .big) catch return error.InvalidPublicKey;
        if (n.bits() < min_modulus_bits) return error.UnsupportedKey;
        if (e_bytes.len == 0 or e_bytes.len > 4) return error.InvalidPublicKey;
        const e = Fe.fromBytes(n, e_bytes, .big) catch return error.InvalidPublicKey;
        if (!e.isOdd()) return error.InvalidPublicKey;
        return .{ .n = n, .e = e, .len = (n.bits() + 7) / 8 };
    }

    /// The key as a DER SubjectPublicKeyInfo, into `out`, which holds at
    /// least `max_spki_len` bytes.
    pub fn writeSpki(pk: PublicKey, out: []u8) []const u8 {
        var n_buf: [max_modulus_bytes]u8 = undefined;
        pk.n.toBytes(n_buf[0..pk.len], .big) catch unreachable;
        var e_buf: [max_modulus_bytes]u8 = undefined;
        pk.e.toBytes(e_buf[0..pk.len], .big) catch unreachable;
        const e_bytes = std.mem.trimStart(u8, e_buf[0..pk.len], &.{0});
        var key_buf: [max_modulus_bytes + 32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&key_buf);
        writeIntegers(&w, &.{ n_buf[0..pk.len], e_bytes }) catch unreachable;
        const rsa_key = w.buffered();
        const algorithm = [_]u8{ 0x30, 0x0d, 0x06, 0x09 } ++ rsa_oid ++ [_]u8{ 0x05, 0x00 };
        var o: std.Io.Writer = .fixed(out);
        const bit_string_len = rsa_key.len + 1;
        const inner_len = algorithm.len + 1 + lengthLen(bit_string_len) + bit_string_len;
        o.writeByte(0x30) catch unreachable;
        writeLength(&o, inner_len) catch unreachable;
        o.writeAll(&algorithm) catch unreachable;
        o.writeByte(0x03) catch unreachable;
        writeLength(&o, bit_string_len) catch unreachable;
        o.writeByte(0) catch unreachable;
        o.writeAll(rsa_key) catch unreachable;
        return o.buffered();
    }

    /// Checks a RSASSA-PKCS1-v1_5 signature over a digest made with `hash`.
    pub fn verifyPkcs1(pk: PublicKey, hash: Hash, digest: []const u8, signature: []const u8) VerifyError!void {
        if (digest.len != hash.digestLength()) return error.SignatureInvalid;
        var em_buf: [max_modulus_bytes]u8 = undefined;
        const em = try pk.publicOp(signature, em_buf[0..pk.len]);
        var want_buf: [max_modulus_bytes]u8 = undefined;
        const want = encodePkcs1(hash, digest, want_buf[0..pk.len]);
        if (!std.mem.eql(u8, em, want)) return error.SignatureInvalid;
    }

    /// Checks a RSASSA-PSS signature over a digest made with `hash`, MGF1
    /// over the same hash, the salt as long as the digest.
    pub fn verifyPss(pk: PublicKey, hash: Hash, digest: []const u8, signature: []const u8) VerifyError!void {
        if (digest.len != hash.digestLength()) return error.SignatureInvalid;
        var em_buf: [max_modulus_bytes]u8 = undefined;
        const full = try pk.publicOp(signature, em_buf[0..pk.len]);
        const em_bits = pk.n.bits() - 1;
        const em_len = (em_bits + 7) / 8;
        // A modulus of 8k + 1 bits leaves the encoding a byte short.
        if (em_len < full.len and full[0] != 0) return error.SignatureInvalid;
        const em = full[full.len - em_len ..];
        const ok = switch (hash) {
            inline else => |t| verifyPssEncoding(t.Type(), digest, em, em_bits),
        };
        if (!ok) return error.SignatureInvalid;
    }

    /// The signature to the public exponent, as `len` bytes into `out`.
    fn publicOp(pk: PublicKey, signature: []const u8, out: []u8) VerifyError![]const u8 {
        if (signature.len != pk.len) return error.SignatureInvalid;
        const s = Fe.fromBytes(pk.n, signature, .big) catch return error.SignatureInvalid;
        const m = pk.n.powPublic(s, pk.e) catch return error.SignatureInvalid;
        m.toBytes(out, .big) catch return error.SignatureInvalid;
        return out;
    }
};

fn lengthLen(len: usize) usize {
    if (len < 0x80) return 1;
    if (len < 0x100) return 2;
    return 3;
}

fn writeLength(w: *std.Io.Writer, len: usize) std.Io.Writer.Error!void {
    if (len < 0x80) return w.writeByte(@intCast(len));
    if (len < 0x100) return w.writeAll(&.{ 0x81, @intCast(len) });
    return w.writeAll(&.{ 0x82, @intCast(len >> 8), @intCast(len & 0xff) });
}

/// A SEQUENCE of positive INTEGERs from their big-endian magnitudes.
fn writeIntegers(w: *std.Io.Writer, ints: []const []const u8) std.Io.Writer.Error!void {
    var body_len: usize = 0;
    for (ints) |int| {
        const pad: usize = if (int.len == 0 or int[0] & 0x80 != 0) 1 else 0;
        body_len += 1 + lengthLen(int.len + pad) + int.len + pad;
    }
    try w.writeByte(0x30);
    try writeLength(w, body_len);
    for (ints) |int| {
        const pad: usize = if (int.len == 0 or int[0] & 0x80 != 0) 1 else 0;
        try w.writeByte(0x02);
        try writeLength(w, int.len + pad);
        if (pad == 1) try w.writeByte(0);
        try w.writeAll(int);
    }
}

/// MGF1 over `H` from `seed`, XORed into `out`.
fn mgf1Xor(comptime H: type, seed: []const u8, out: []u8) void {
    var counter: u32 = 0;
    var i: usize = 0;
    while (i < out.len) : (counter += 1) {
        var h: H = .init(.{});
        h.update(seed);
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        h.update(&c);
        var d: [H.digest_length]u8 = undefined;
        h.final(&d);
        const n = @min(d.len, out.len - i);
        for (out[i..][0..n], d[0..n]) |*o, x| o.* ^= x;
        i += n;
    }
}

/// RFC 8017 9.1.1, EMSA-PSS-ENCODE from the message's digest, filling
/// `em`, which is `ceil(em_bits / 8)` bytes.
fn encodePss(comptime H: type, m_hash: []const u8, salt: []const u8, em_bits: usize, em: []u8) error{EncodingError}!void {
    const h_len = H.digest_length;
    if (em.len < h_len + salt.len + 2) return error.EncodingError;
    const zeros: [8]u8 = @splat(0);
    var hasher: H = .init(.{});
    hasher.update(&zeros);
    hasher.update(m_hash);
    hasher.update(salt);
    var h: [h_len]u8 = undefined;
    hasher.final(&h);
    const db_len = em.len - h_len - 1;
    const db = em[0..db_len];
    @memset(db, 0);
    db[db_len - salt.len - 1] = 0x01;
    @memcpy(db[db_len - salt.len ..], salt);
    mgf1Xor(H, &h, db);
    const zero_bits: u3 = @intCast(8 * em.len - em_bits);
    db[0] &= @as(u8, 0xff) >> zero_bits;
    @memcpy(em[db_len..][0..h_len], &h);
    em[em.len - 1] = 0xbc;
}

/// RFC 8017 9.1.2, EMSA-PSS-VERIFY from the message's digest, the salt as
/// long as the digest.
fn verifyPssEncoding(comptime H: type, m_hash: []const u8, em: []const u8, em_bits: usize) bool {
    const h_len = H.digest_length;
    const s_len = h_len;
    if (em.len < h_len + s_len + 2) return false;
    if (em[em.len - 1] != 0xbc) return false;
    const db_len = em.len - h_len - 1;
    var db_buf: [max_modulus_bytes]u8 = undefined;
    const db = db_buf[0..db_len];
    @memcpy(db, em[0..db_len]);
    const h = em[db_len..][0..h_len];
    const zero_bits: u3 = @intCast(8 * em.len - em_bits);
    const top_mask = @as(u8, 0xff) >> zero_bits;
    if (db[0] & ~top_mask != 0) return false;
    mgf1Xor(H, h, db);
    db[0] &= top_mask;
    const ps_len = db_len - s_len - 1;
    for (db[0..ps_len]) |b| if (b != 0) return false;
    if (db[ps_len] != 0x01) return false;
    const zeros: [8]u8 = @splat(0);
    var hasher: H = .init(.{});
    hasher.update(&zeros);
    hasher.update(m_hash);
    hasher.update(db[db_len - s_len ..]);
    var want: [h_len]u8 = undefined;
    hasher.final(&want);
    return std.mem.eql(u8, &want, h);
}

/// Parses a PEM private key. `pem` may hold anything; nothing secret from
/// it outlives the call except inside the returned key.
pub fn parsePem(pem: []const u8) ParseError!PrivateKey {
    if (std.mem.indexOf(u8, pem, "-----BEGIN ENCRYPTED PRIVATE KEY-----") != null) {
        return error.UnsupportedKey;
    }
    const body = pemBody(pem, "PRIVATE KEY") orelse
        pemBody(pem, "RSA PRIVATE KEY") orelse
        return error.InvalidPrivateKey;
    // A 4096-bit PKCS#8 key is about 2.4 KiB of DER.
    var der_buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &der_buf);
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const len = decoder.decode(&der_buf, body) catch return error.InvalidPrivateKey;
    return parseDer(der_buf[0..len]);
}

/// The base64 between `-----BEGIN <label>-----` and `-----END <label>-----`.
fn pemBody(pem: []const u8, comptime label: []const u8) ?[]const u8 {
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    const start = std.mem.indexOf(u8, pem, begin) orelse return null;
    const after = start + begin.len;
    const stop = std.mem.indexOfPos(u8, pem, after, end) orelse return null;
    return pem[after..stop];
}

/// One DER element at `pos`, which moves past it. Null when the bytes do
/// not hold one; nothing here trusts the input.
const Element = struct { tag: u8, body: []const u8 };

fn readElement(bytes: []const u8, pos: *usize) ?Element {
    var i = pos.*;
    if (bytes.len - i < 2) return null;
    const tag = bytes[i];
    var len: usize = bytes[i + 1];
    i += 2;
    if (len >= 0x80) {
        const n = len - 0x80;
        if (n == 0 or n > 4 or bytes.len - i < n) return null;
        len = 0;
        for (bytes[i..][0..n]) |b| len = (len << 8) | b;
        i += n;
    }
    if (bytes.len - i < len) return null;
    pos.* = i + len;
    return .{ .tag = tag, .body = bytes[i..][0..len] };
}

/// A DER INTEGER's magnitude: positive, sign padding stripped.
fn magnitude(int: Element) ?[]const u8 {
    if (int.tag != 0x02 or int.body.len == 0) return null;
    if (int.body[0] & 0x80 != 0) return null;
    var b = int.body;
    while (b.len > 0 and b[0] == 0) b = b[1..];
    return b;
}

const rsa_oid = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

fn parseDer(bytes: []const u8) ParseError!PrivateKey {
    var pos: usize = 0;
    const outer = readElement(bytes, &pos) orelse return error.InvalidPrivateKey;
    if (outer.tag != 0x30) return error.InvalidPrivateKey;
    var p: usize = 0;
    const version = readElement(outer.body, &p) orelse return error.InvalidPrivateKey;
    if (version.tag != 0x02) return error.InvalidPrivateKey;
    const second = readElement(outer.body, &p) orelse return error.InvalidPrivateKey;
    // A bare RSAPrivateKey starts INTEGER, INTEGER: hand the whole thing over.
    if (second.tag == 0x02) return parsePkcs1(bytes);
    // PKCS#8: version 0, an AlgorithmIdentifier naming RSA, then the
    // RSAPrivateKey in an OCTET STRING.
    if (second.tag != 0x30) return error.InvalidPrivateKey;
    if (!std.mem.eql(u8, version.body, &.{0})) return error.UnsupportedKey;
    var a: usize = 0;
    const oid = readElement(second.body, &a) orelse return error.InvalidPrivateKey;
    if (oid.tag != 0x06) return error.InvalidPrivateKey;
    if (!std.mem.eql(u8, oid.body, &rsa_oid)) return error.UnsupportedKey;
    const inner = readElement(outer.body, &p) orelse return error.InvalidPrivateKey;
    if (inner.tag != 0x04) return error.InvalidPrivateKey;
    return parsePkcs1(inner.body);
}

/// RFC 8017 A.1.2: SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }. Only
/// n, e and d are used; signing with d alone is simpler than CRT and fast
/// enough for a token an hour.
fn parsePkcs1(bytes: []const u8) ParseError!PrivateKey {
    var pos: usize = 0;
    const seq = readElement(bytes, &pos) orelse return error.InvalidPrivateKey;
    if (seq.tag != 0x30) return error.InvalidPrivateKey;
    var p: usize = 0;
    const version = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    if (version.tag != 0x02) return error.InvalidPrivateKey;
    // Version 1 is a multi-prime key, which has a different tail.
    if (!std.mem.eql(u8, version.body, &.{0})) return error.UnsupportedKey;
    const n_int = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    const e_int = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    const d_int = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    const n_bytes = magnitude(n_int) orelse return error.InvalidPrivateKey;
    const e_bytes = magnitude(e_int) orelse return error.InvalidPrivateKey;
    const d_bytes = magnitude(d_int) orelse return error.InvalidPrivateKey;

    if (n_bytes.len > max_modulus_bytes) return error.UnsupportedKey;
    const n = Modulus.fromBytes(n_bytes, .big) catch return error.InvalidPrivateKey;
    if (n.bits() < min_modulus_bits) return error.UnsupportedKey;
    const e = Fe.fromBytes(n, e_bytes, .big) catch return error.InvalidPrivateKey;
    if (!e.isOdd()) return error.InvalidPrivateKey;
    if (d_bytes.len == 0 or d_bytes.len > max_modulus_bytes) return error.InvalidPrivateKey;

    var key: PrivateKey = .{
        .n = n,
        .e = e,
        .d = @splat(0),
        .d_len = d_bytes.len,
        .len = (n.bits() + 7) / 8,
    };
    @memcpy(key.d[0..d_bytes.len], d_bytes);
    return key;
}

/// RFC 8017 9.2, EMSA-PKCS1-v1_5:
/// `0x00 0x01 FF..FF 0x00 DigestInfo digest`, filling `em`.
fn encodePkcs1(hash: Hash, digest: []const u8, em: []u8) []const u8 {
    const digest_info = hash.digestInfo();
    const t_len = digest_info.len + digest.len;
    // The minimum modulus leaves far more than the 11 bytes RFC 8017 needs.
    std.debug.assert(em.len >= t_len + 11);
    em[0] = 0x00;
    em[1] = 0x01;
    const t_start = em.len - t_len;
    @memset(em[2 .. t_start - 1], 0xff);
    em[t_start - 1] = 0x00;
    @memcpy(em[t_start..][0..digest_info.len], digest_info);
    @memcpy(em[em.len - digest.len ..], digest);
    return em;
}

// Test fixtures: throwaway keys generated for these tests with OpenSSL,
// shared with ServiceAccount's tests (pub, but rsa.zig is not exported).
// never used anywhere real. The signatures are OpenSSL's own
// (`openssl dgst -sha256 -sign`) over `test_message`, so these tests
// check against an independent implementation.

pub const test_message = "sign me, exactly these bytes";

/// A 1024-bit test key: the smallest accepted, and much faster to sign
/// with in Debug, so heavier test loops use it.
pub const test_key_1024 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBANec+YqTS8dG4k8D
    \\U2CiScMOaW22NEmsAD0t+UAONP1d1Vi9E8M5hKd5G8zvm1gpvDiZaAZ4OHDcYi49
    \\RHVaemHdaa5F6+KZW+wVR1FbOxV+Fbjn/L2XsMzy132RH186Ty7BKeOs42dzeiYg
    \\Gc43bzgRxfXBY61bvetGjmu3e+UJAgMBAAECgYB4s5e+y9aQKE5ojSQP5MoGN/st
    \\P+LlmzRHC4WNJmbjr7PPiYmWsIxidJnrj/cW08ZaqQZjGMn/5F/SItpAF/aJ64Ud
    \\3Mjgt76f42E+aThOhifugbtOKkeZ5lfH22ujR/hfFxDRiFdmIwG1GPJC7TEPe1fX
    \\0r9VE2BV0DMbYBaxAQJBAPM4pvJNy+/0cZRKsHL62eHl6bZMt7fMsmmJmkkrzACf
    \\q5aHeeYX1nqy5aUR4cMl9j5pkqGvI0KomYI4bDiOEHUCQQDi8P22Q5ADupmjehqj
    \\UdGPFE/2yFyx2nkc/2of9V7WzJorTg/Wz0LcJIeinP9Tb1naraRcnO2N00YKYt40
    \\HO/FAkBZ9p2ByJbjhcYxNMM5dGH9NZ6R6KSX3qYrdVNVN1b48BZ20lubaTvTHLLm
    \\sMuR9Eu14DT1iyN+t4A4c4hMDvg1AkBBgltaj6o0yVqsTAUAfA/IA48Jp9DKLkyj
    \\yD70NrpHuwwN0BzWX0Hnlkvo7vTtOslvTIyTh2EzfXdMbDnERU4ZAkAcqPdLpGOv
    \\rM6tCpzaY2n/6xJfE+siX/07sx+RJ683XHciy2puPXwgRdJ9oaNPGYbyAFaagTSR
    \\YAS7APpRBYGA
    \\-----END PRIVATE KEY-----
;

pub const test_sig_1024_hex = "58b79695ef8b5af573d01eb3ab4694c8c75744f1b624d49b0726346d11b08aa2" ++
    "4260ec91ace15c7b3fedeed9c83167d6dd9eddec082ae6724e1ea73d157be4be" ++
    "45a85b007cceed1e05fd7d446dc52feecb1bbc765c559eba408cb6653814cba0" ++
    "2d555263fe4a83a9a3935f397738e96280eccec1762f5b8a98eb915f72fa5003";

/// A 2048-bit test key, PKCS#8.
pub const test_key_2048 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCJzXN/oMxw5dqm
    \\rwhvYOrg65GgRHWQ3u713WfNhiD96QUDS134zSOkgh1pAPLkb+n9Ju12sm+MDeL4
    \\mjYfpQWZ66jfz311r83gnWSCTL3F2Yh6NxNa4flbjPje+TGxdYtfM+Thu0GDZa1q
    \\iDXwoNDPUp1518fS7oQV/6mu2Bp6u2OyLXjb7hEsO0lxrNdrC20pOQZPgQHih7pn
    \\KJUkhMyktjgniWfI4HLOidUspi4Tu7RV+buuS8sPKmHfCzXZhxxRLCaUH17z6KID
    \\B7XDn195tZ9zIUP7oJBhb+8PMCcSosyZrEhspN0mMzC9pGS0GGxSlk98YYJJ/S66
    \\hGTuomx9AgMBAAECggEAEmVwDtC7mjLFPs1NFfldQcuQ9FFPVJi+U+pLyj8mtl7e
    \\QXNVRzqzkGmiXXs38dES7q28s8TcaVkNPNzxbsYL+mFgeQhtGkHu/RZl7ZMrHneM
    \\5avmlJJoRJWMP9AKl0M26O23l371HwJ65Sbr9ISze4nu5e4tifY3gexQjbvhxRJ+
    \\9V5piS6uCPzJOD30d7zsDcsF901Zh9akClBYRdqkkX8HoWa/lP3v5IqhXy4j3KxL
    \\oWWNj4fuj6fJ2vhgE9wKgfePwB7ggQdcyaMyw2rZ+jOtwSQWj87PMkYfDBEk4BnR
    \\k/n1r19ygtcNebncGcvJavvQyL1GzRiMpoR5Mkp2zQKBgQC9LqToiRoiB1kwSZnB
    \\3RJZCdkLJcgcPRi0rGNg0qQOI9pCMo+REPwedIuOMtSDKE/7X5cClO6FWckrKic7
    \\gstm05RpKtko5GujVUeCTKuTVHAkhsDgatSMaO8HdtWjQnSBTCiUAJHClxH43f2j
    \\pnqJHzQQrbIslgXHAsiYcr+j3wKBgQC6eTGTO3FC7TSqUSayfNCeEJibcUFBfUiE
    \\5aAsNXfrtOzmHUkqFsw45CVfLgi0lL8ioY3asAqb1Y5ZAcfE9fcgUgWXjrWWawTb
    \\TYNxzP1LqUaI6kY9HtEE2JmtzNde/xCppQRQhGLfCOy3OMTeQ+XzJ4bE69OaGmWq
    \\hHcw+KmbIwKBgGot9tKouKkmtLE8bfb4DGc69r2h+/mVdPta0gAy2W8yQjrrQ9bo
    \\0IiLYxRxhQMEKjftA8WoL2Na7GS0qQZmt6DD2cVZDj88TQmEQLlqLNZpCvQFSdXr
    \\P9Z6wsXOtcOG9frn8tJ2q1irD6Q9fDFQq++wOrmts5YAscdr0Yh2xwbDAoGAM3Xa
    \\ro0K9rNLg20dxsgXMmfWFZ+tqIsQhkxwZYLj81Jcxixy0oC0H0cm4RttH5ilHsOC
    \\yEUoyFSpEfshzEMszeiUznx9tGMYVgUQL0mo5UZzxrkQZTGp8TJtRr9u+DJfwNFf
    \\XXELcA2gdfferJAEV5Qi5xlFrhN21xXzZrpY5A0CgYEAllY2eCgSRj9d0SiPYHtP
    \\Y0XysnibDArafqRUMK/bcodMqnD8PpZD/qowl2OAz18BCewZk9GX3deAd4jdGFCH
    \\1CH5qT8s2fqMVABffzxKMtHqNTWwXJroDHAZqqmxKdZ8p9ItQvl6jPR34EKkXgR4
    \\og3ZEBNlBXBeVBFa7gmViI8=
    \\-----END PRIVATE KEY-----
;

/// The same 2048-bit key, PKCS#1.
const test_key_2048_pkcs1 =
    \\-----BEGIN RSA PRIVATE KEY-----
    \\MIIEowIBAAKCAQEAic1zf6DMcOXapq8Ib2Dq4OuRoER1kN7u9d1nzYYg/ekFA0td
    \\+M0jpIIdaQDy5G/p/SbtdrJvjA3i+Jo2H6UFmeuo3899da/N4J1kgky9xdmIejcT
    \\WuH5W4z43vkxsXWLXzPk4btBg2Wtaog18KDQz1KdedfH0u6EFf+prtgaertjsi14
    \\2+4RLDtJcazXawttKTkGT4EB4oe6ZyiVJITMpLY4J4lnyOByzonVLKYuE7u0Vfm7
    \\rkvLDyph3ws12YccUSwmlB9e8+iiAwe1w59febWfcyFD+6CQYW/vDzAnEqLMmaxI
    \\bKTdJjMwvaRktBhsUpZPfGGCSf0uuoRk7qJsfQIDAQABAoIBABJlcA7Qu5oyxT7N
    \\TRX5XUHLkPRRT1SYvlPqS8o/JrZe3kFzVUc6s5Bpol17N/HREu6tvLPE3GlZDTzc
    \\8W7GC/phYHkIbRpB7v0WZe2TKx53jOWr5pSSaESVjD/QCpdDNujtt5d+9R8CeuUm
    \\6/SEs3uJ7uXuLYn2N4HsUI274cUSfvVeaYkurgj8yTg99He87A3LBfdNWYfWpApQ
    \\WEXapJF/B6Fmv5T97+SKoV8uI9ysS6FljY+H7o+nydr4YBPcCoH3j8Ae4IEHXMmj
    \\MsNq2fozrcEkFo/OzzJGHwwRJOAZ0ZP59a9fcoLXDXm53BnLyWr70Mi9Rs0YjKaE
    \\eTJKds0CgYEAvS6k6IkaIgdZMEmZwd0SWQnZCyXIHD0YtKxjYNKkDiPaQjKPkRD8
    \\HnSLjjLUgyhP+1+XApTuhVnJKyonO4LLZtOUaSrZKORro1VHgkyrk1RwJIbA4GrU
    \\jGjvB3bVo0J0gUwolACRwpcR+N39o6Z6iR80EK2yLJYFxwLImHK/o98CgYEAunkx
    \\kztxQu00qlEmsnzQnhCYm3FBQX1IhOWgLDV367Ts5h1JKhbMOOQlXy4ItJS/IqGN
    \\2rAKm9WOWQHHxPX3IFIFl461lmsE202Dccz9S6lGiOpGPR7RBNiZrczXXv8QqaUE
    \\UIRi3wjstzjE3kPl8yeGxOvTmhplqoR3MPipmyMCgYBqLfbSqLipJrSxPG32+Axn
    \\Ova9ofv5lXT7WtIAMtlvMkI660PW6NCIi2MUcYUDBCo37QPFqC9jWuxktKkGZreg
    \\w9nFWQ4/PE0JhEC5aizWaQr0BUnV6z/WesLFzrXDhvX65/LSdqtYqw+kPXwxUKvv
    \\sDq5rbOWALHHa9GIdscGwwKBgDN12q6NCvazS4NtHcbIFzJn1hWfraiLEIZMcGWC
    \\4/NSXMYsctKAtB9HJuEbbR+YpR7DgshFKMhUqRH7IcxDLM3olM58fbRjGFYFEC9J
    \\qOVGc8a5EGUxqfEybUa/bvgyX8DRX11xC3ANoHX33qyQBFeUIucZRa4TdtcV82a6
    \\WOQNAoGBAJZWNngoEkY/XdEoj2B7T2NF8rJ4mwwK2n6kVDCv23KHTKpw/D6WQ/6q
    \\MJdjgM9fAQnsGZPRl93XgHeI3RhQh9Qh+ak/LNn6jFQAX388SjLR6jU1sFya6Axw
    \\GaqpsSnWfKfSLUL5eoz0d+BCpF4EeKIN2RATZQVwXlQRWu4JlYiP
    \\-----END RSA PRIVATE KEY-----
;

/// A 4096-bit test key, PKCS#8.
pub const test_key_4096 =
    \\-----BEGIN PRIVATE KEY-----
    \\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
    \\cSgHVm5Wxx/RL/00MT49ePkNID1/ag==
    \\-----END PRIVATE KEY-----
;

/// An EC P-256 key: valid PKCS#8, not RSA.
pub const test_key_ec =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgAH863KtFBkbQuIiU
    \\wl14N5JJM1Bmu4BA3k2kWi2IZxyhRANCAARIkfe3Eis5p1QObAPwBkQV53XGX2hC
    \\0g/IVqDvDsoqiiN9UZd5PAogT5q1s2pzyi+q3vWt7p4/rIXodkVkXZJV
    \\-----END PRIVATE KEY-----
;

pub const test_sig_2048_hex = "851f9524baa1ab8010ffad57593e795a6aaded58751fee5fe7d723325d8b7846" ++
    "00b0fb548874cd3ffc0f398a64db35e1b91a009f3d0c1b027e82f9026a3a210e" ++
    "b0430384f311da1e69c4706f39b857fa77c4a765b5b60fa1af916317509dd4e9" ++
    "cda66e4e16a24c55ad2bac5814e8a5270820823580e23f204d56302325eaf6a3" ++
    "e5ef7c005ae561ec27c5013b402c41c93772bc1da678ef9d01adcb57a613c74b" ++
    "0559af290a8feec22b0a10594bde673c7691ee867c66710f7b5ed77decc8407e" ++
    "a45bfd1d3b7178acfed1e25631def0b463f23c9e6827552c0da08d422dc0890f" ++
    "f09dd7689a2bbdf2f5886a536998f14ceea8509754bd702c172b36d99276de47";

const test_sig_4096_hex = "0656f181b3b47c0e388acee7d2adf2d997cbbf7dd15d64d8e0f85552f89b17e9" ++
    "4398a875d3fa9284bb1cc5d9b584dd7e9116d9d839c79466b350501010c9aa70" ++
    "f0e0741857865dc7055dbbaba411dafaca5d34d81687a1a7280a2d59c88345cb" ++
    "406513edfdb3d85f2a58e22a3b2d199a2e0cb4572843cbdcab7fb573ce85caa5" ++
    "bfce39cd6294ed60ca8a24fdc414a692d25d0f943a92e0e0def5531cbc983635" ++
    "5f76ba88fd65bc9cf1f6fd7a0f4db568a68820c5290bf84e09e95ad815689424" ++
    "5ff51f4910759fea26c9c18319d8c64989f8fcd5f31377d8f79a128040317572" ++
    "98a152e91c7e5b2969616b4e5cce87b22e24c3d0fd578613fb81b3cbce2a29e8" ++
    "74abf4d71e74809542b7bb141a878487e82e8a81c142df0eb5b43272adb48419" ++
    "84e97afe4c0cc832468bcabcdd79357f95ae2e3c7c283f79243be78c26d7c7a8" ++
    "9381d68b99d0f027e5bab273109bb6480777c7940a6623486c6843437d045b4e" ++
    "229979181fe7bd8390d65f026566d77f012a4b26996e52f46d18807e949f0874" ++
    "7bba11d293f8b3e782f50e3f084d35be7eeb6b9dbc3d89e3629b9b27cf04c4a7" ++
    "4644a909764c19642e1db03943e53f9d15656c1bde04d7d424b8409c425b303d" ++
    "6bb333f411adc0e4da4c7198b6cc342282591cb9cf92723921a3ee70eefb23fe" ++
    "82e98f9b0a77da7662523824d71f39ed872726eb1a7aaa0220a85bec72238d44";

const testing = std.testing;
const test_util = @import("testing.zig");

fn expectSignature(pem: []const u8, expected_hex: []const u8) !void {
    var key = try parsePem(pem);
    defer key.deinit();
    var expected: [max_modulus_bytes]u8 = undefined;
    const want = try std.fmt.hexToBytes(&expected, expected_hex);
    try testing.expectEqual(want.len, key.len);
    var out: [max_modulus_bytes]u8 = undefined;
    const got = try key.sign(test_message, &out);
    try testing.expectEqualSlices(u8, want, got);
}

test "rsa: a 1024-bit key signs exactly as OpenSSL does" {
    try expectSignature(test_key_1024, test_sig_1024_hex);
}

test "rsa: a 2048-bit PKCS#8 key signs exactly as OpenSSL does" {
    try expectSignature(test_key_2048, test_sig_2048_hex);
}

test "rsa: the same key as PKCS#1 gives the same signature" {
    try expectSignature(test_key_2048_pkcs1, test_sig_2048_hex);
}

test "rsa: a 4096-bit key signs exactly as OpenSSL does" {
    try expectSignature(test_key_4096, test_sig_4096_hex);
}

test "rsa: signing is deterministic, and messages differ" {
    var key = try parsePem(test_key_2048);
    defer key.deinit();
    var a: [max_modulus_bytes]u8 = undefined;
    var b: [max_modulus_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, try key.sign("m", &a), try key.sign("m", &b));
    try testing.expect(!std.mem.eql(u8, try key.sign("m", &a), try key.sign("n", &b)));
}

test "rsa: what cannot be a usable key is refused by kind" {
    // Not PEM at all, or PEM whose contents are not a key.
    try testing.expectError(error.InvalidPrivateKey, parsePem(""));
    try testing.expectError(error.InvalidPrivateKey, parsePem("not a key"));
    try testing.expectError(error.InvalidPrivateKey, parsePem("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"));
    try testing.expectError(error.InvalidPrivateKey, parsePem("-----BEGIN PRIVATE KEY-----\nnot base64!\n-----END PRIVATE KEY-----"));
    try testing.expectError(error.InvalidPrivateKey, parsePem("-----BEGIN PRIVATE KEY-----"));
    // A key that is whole but not one this code can use.
    try testing.expectError(error.UnsupportedKey, parsePem(test_key_ec));
    try testing.expectError(error.UnsupportedKey, parsePem("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----"));
    // Truncated: the start of a real key, cut mid-structure.
    var cut: [200]u8 = undefined;
    @memcpy(&cut, test_key_2048[0..200]);
    try testing.expectError(error.InvalidPrivateKey, parsePem(cut ++ "\n-----END PRIVATE KEY-----"));
}

/// The DER inside a `PUBLIC KEY` PEM, into `buf`.
fn publicDer(pem: []const u8, buf: []u8) ![]const u8 {
    const body = pemBody(pem, "PUBLIC KEY") orelse return error.TestUnexpectedResult;
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const len = try decoder.decode(buf, body);
    return buf[0..len];
}

fn hexBytes(hex: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.hexToBytes(buf, hex);
}

test "rsa: PKCS#1 v1.5 over SHA-512 signs as OpenSSL does, and both verify" {
    var key = try parsePem(test_key_2048);
    defer key.deinit();
    var digest_buf: [64]u8 = undefined;
    const digest = Hash.sha512.digest(test_message, &digest_buf);
    var out: [max_modulus_bytes]u8 = undefined;
    var want_buf: [max_modulus_bytes]u8 = undefined;
    const want = try hexBytes(test_sig_2048_sha512_hex, &want_buf);
    try testing.expectEqualSlices(u8, want, try key.signDigest(.sha512, digest, &out));
    const pk = key.publicKey();
    try pk.verifyPkcs1(.sha512, digest, want);
    // OpenSSL's SHA-256 signature too, by the digest.
    var sha256_buf: [64]u8 = undefined;
    const sha256 = Hash.sha256.digest(test_message, &sha256_buf);
    var sig256_buf: [max_modulus_bytes]u8 = undefined;
    try pk.verifyPkcs1(.sha256, sha256, try hexBytes(test_sig_2048_hex, &sig256_buf));
    // Under the wrong hash, over another message, or flipped: refused.
    try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(.sha256, sha256, want));
    try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(.sha512, Hash.sha512.digest("other", &digest_buf), want));
    var flipped = want_buf;
    flipped[17] ^= 1;
    try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(.sha512, Hash.sha512.digest(test_message, &digest_buf), flipped[0..want.len]));
    try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(.sha512, digest[0..63], want));
    try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(.sha512, Hash.sha512.digest(test_message, &digest_buf), want[0..255]));
}

test "rsa: PSS verifies OpenSSL's signature, and std verifies ours" {
    var key = try parsePem(test_key_2048);
    defer key.deinit();
    const pk = key.publicKey();
    var digest_buf: [64]u8 = undefined;
    const digest = Hash.sha256.digest(test_message, &digest_buf);
    var openssl_buf: [max_modulus_bytes]u8 = undefined;
    const openssl_sig = try hexBytes(test_sig_2048_pss_hex, &openssl_buf);
    try pk.verifyPss(.sha256, digest, openssl_sig);
    try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(.sha256, digest, openssl_sig));

    var spki_buf: [max_spki_len]u8 = undefined;
    const spki = pk.writeSpki(&spki_buf);
    var der_buf: [max_spki_len]u8 = undefined;
    const std_rsa = std.crypto.Certificate.rsa;
    inline for (.{ .{ Hash.sha256, sha2.Sha256 }, .{ Hash.sha384, sha2.Sha384 }, .{ Hash.sha512, sha2.Sha512 } }) |pair| {
        const salt: [pair[0].digestLength()]u8 = @splat(0x5a);
        const d = pair[0].digest(test_message, &digest_buf);
        var out: [max_modulus_bytes]u8 = undefined;
        const sig = try key.signPss(pair[0], d, &salt, &out);
        try pk.verifyPss(pair[0], d, sig);
        // std's PSS verifier, an independent implementation, takes it.
        const parsed = try std_rsa.PublicKey.parseDer(try rsaKeyOf(spki, &der_buf));
        const std_key = try std_rsa.PublicKey.fromBytes(parsed.exponent, parsed.modulus);
        try std_rsa.PSSSignature.verify(256, sig[0..256], test_message, std_key, pair[1]);
        // A PKCS#1 signature is refused as PSS, and a PSS one as PKCS#1.
        var p1: [max_modulus_bytes]u8 = undefined;
        try testing.expectError(error.SignatureInvalid, pk.verifyPss(pair[0], d, try key.signDigest(pair[0], d, &p1)));
        try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(pair[0], d, sig));
    }
}

test "rsa: a PSS encoding is refused for any one of its fixed parts changed" {
    const H = sha2.Sha256;
    var digest: [32]u8 = undefined;
    H.hash("m", &digest, .{});
    const salt: [32]u8 = @splat(3);
    var em: [256]u8 = undefined;
    try encodePss(H, &digest, &salt, 2047, &em);
    try testing.expect(verifyPssEncoding(H, &digest, &em, 2047));
    // The trailer byte, the top bit above emBits, the salt's 0x01 marker
    // (under the mask, so flipping it is a flip of its masked byte), the
    // hash, and the digest itself.
    const cases = [_]struct { usize, u8 }{ .{ 255, 0x01 }, .{ 0, 0x80 }, .{ 256 - 32 - 1 - 32 - 1, 0x01 }, .{ 240, 0x10 } };
    for (cases) |case| {
        var bad = em;
        bad[case[0]] ^= case[1];
        try testing.expect(!verifyPssEncoding(H, &digest, &bad, 2047));
    }
    var other = digest;
    other[0] ^= 1;
    try testing.expect(!verifyPssEncoding(H, &other, &em, 2047));
    // Too short for the hash and salt: refused before anything is read.
    try testing.expect(!verifyPssEncoding(H, &digest, em[0..60], 479));
    try testing.expectError(error.EncodingError, encodePss(H, &digest, &salt, 479, em[0..60]));
}

test "rsa: a modulus of 8k + 1 bits, whose PSS encoding is a byte short" {
    var key = try parsePem(test_key_2049);
    defer key.deinit();
    try testing.expectEqual(2049, key.n.bits());
    const pk = key.publicKey();
    var digest_buf: [64]u8 = undefined;
    const d = Hash.sha256.digest(test_message, &digest_buf);
    var out: [max_modulus_bytes]u8 = undefined;
    const salt: [32]u8 = @splat(1);
    const sig = try key.signPss(.sha256, d, &salt, &out);
    try testing.expectEqual(257, sig.len);
    try pk.verifyPss(.sha256, d, sig);
    var p1: [max_modulus_bytes]u8 = undefined;
    try pk.verifyPkcs1(.sha256, d, try key.signDigest(.sha256, d, &p1));
}

test "rsa: the 3072-bit key signs both ways, and a salt too long for the modulus is refused" {
    var key = try parsePem(test_key_3072);
    defer key.deinit();
    try testing.expectEqual(384, key.len);
    const pk = key.publicKey();
    var digest_buf: [64]u8 = undefined;
    const d = Hash.sha256.digest(test_message, &digest_buf);
    var out: [max_modulus_bytes]u8 = undefined;
    try pk.verifyPkcs1(.sha256, d, try key.signDigest(.sha256, d, &out));
    const salt: [32]u8 = @splat(7);
    try pk.verifyPss(.sha256, d, try key.signPss(.sha256, d, &salt, &out));
    const long_salt: [384]u8 = @splat(0);
    try testing.expectError(error.SignatureFailed, key.signPss(.sha256, d, &long_salt, &out));
}

test "rsa: public keys as SubjectPublicKeyInfo, written as OpenSSL writes them and read back" {
    var key = try parsePem(test_key_2048);
    defer key.deinit();
    var spki_buf: [max_spki_len]u8 = undefined;
    const spki = key.publicKey().writeSpki(&spki_buf);
    var der_buf: [max_spki_len]u8 = undefined;
    try testing.expectEqualSlices(u8, try publicDer(test_key_2048_public, &der_buf), spki);
    const back = try PublicKey.fromSpki(spki);
    try testing.expectEqual(key.len, back.len);
    try testing.expect(back.n.toUint().eql(key.n.toUint()));
    // Every size the fixtures have round-trips.
    inline for (.{ test_key_1024, test_key_2049, test_key_3072, test_key_4096 }) |pem| {
        var k = try parsePem(pem);
        defer k.deinit();
        var buf: [max_spki_len]u8 = undefined;
        const written = k.publicKey().writeSpki(&buf);
        const read = try PublicKey.fromSpki(written);
        var again: [max_spki_len]u8 = undefined;
        try testing.expectEqualSlices(u8, written, read.writeSpki(&again));
    }
    // Not RSA, not DER, or cut short.
    try testing.expectError(error.UnsupportedKey, PublicKey.fromSpki(try publicDer(test_key_ec_public, &der_buf)));
    try testing.expectError(error.InvalidPublicKey, PublicKey.fromSpki(""));
    try testing.expectError(error.InvalidPublicKey, PublicKey.fromSpki(spki[0 .. spki.len - 1]));
    var trailing: [max_spki_len + 1]u8 = undefined;
    @memcpy(trailing[0..spki.len], spki);
    trailing[spki.len] = 0;
    try testing.expectError(error.InvalidPublicKey, PublicKey.fromSpki(trailing[0 .. spki.len + 1]));
}

fn spkiProperty(_: void, input: []const u8) !void {
    // Arbitrary DER: a key or an error, never a crash; a key verifies
    // nothing it did not sign, and writes back what it read.
    const pk = PublicKey.fromSpki(input) catch return;
    var buf: [max_spki_len]u8 = undefined;
    const written = pk.writeSpki(&buf);
    _ = try PublicKey.fromSpki(written);
    var digest: [32]u8 = @splat(0);
    var sig: [max_modulus_bytes]u8 = @splat(0x42);
    try testing.expectError(error.SignatureInvalid, pk.verifyPkcs1(.sha256, &digest, sig[0..pk.len]));
    try testing.expectError(error.SignatureInvalid, pk.verifyPss(.sha256, &digest, sig[0..pk.len]));
}

/// The RSAPublicKey inside a SubjectPublicKeyInfo, copied into `buf`.
fn rsaKeyOf(spki: []const u8, buf: []u8) ![]const u8 {
    var pos: usize = 0;
    const outer = readElement(spki, &pos) orelse return error.TestUnexpectedResult;
    var p: usize = 0;
    _ = readElement(outer.body, &p) orelse return error.TestUnexpectedResult;
    const bits = readElement(outer.body, &p) orelse return error.TestUnexpectedResult;
    @memcpy(buf[0 .. bits.body.len - 1], bits.body[1..]);
    return buf[0 .. bits.body.len - 1];
}

/// test_key_2048_public's DER, decoded at compile time for a fuzz corpus.
const test_spki_2048 = spki: {
    @setEvalBranchQuota(1_000_000);
    var buf: [max_spki_len]u8 = undefined;
    const der = publicDer(test_key_2048_public, &buf) catch unreachable;
    const final = der[0..der.len].*;
    break :spki &final;
};

test "fuzz rsa: arbitrary SubjectPublicKeyInfo never crashes, and what it reads it writes back" {
    const spki = test_spki_2048;
    try test_util.fuzzBytes({}, spkiProperty, .{ .corpus = &.{
        spki,
        spki[0..40],
        "\x30\x03\x30\x01\x00",
    } });
}

fn pemProperty(_: void, input: []const u8) !void {
    // Arbitrary bytes: a key or an error, never a crash.
    var key = parsePem(input) catch return;
    key.deinit();
}

fn wrappedProperty(_: void, input: []const u8) !void {
    // Valid PEM armor around arbitrary base64, so the DER parser gets fed.
    var b64_buf: [512]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64_buf, input[0..@min(input.len, 384)]);
    var pem_buf: [1024]u8 = undefined;
    const pem = std.fmt.bufPrint(&pem_buf, "-----BEGIN PRIVATE KEY-----\n{s}\n-----END PRIVATE KEY-----", .{encoded}) catch unreachable;
    var key = parsePem(pem) catch return;
    key.deinit();
}

test "fuzz rsa: arbitrary PEM input never crashes" {
    try test_util.fuzzBytes({}, pemProperty, .{
        .corpus = &.{
            // The whole key, so the property's success arm runs on the
            // corpus alone, not only when mutation stumbles into a key.
            test_key_2048,
            test_key_2048[0..64],
            "-----BEGIN RSA PRIVATE KEY-----\nMA==\n-----END RSA PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----\n\n-----END PRIVATE KEY-----",
        },
    });
}

test "fuzz rsa: arbitrary DER inside valid armor never crashes" {
    try test_util.fuzzBytes({}, wrappedProperty, .{ .corpus = &.{
        "\x30\x82\x04\xa3\x02\x01\x00",
        "\x30\x03\x02\x01\x00",
        "\x30\x84\xff\xff\xff\xff",
        "\x02\x00",
    } });
}

/// A 3072-bit test key, PKCS#8, for the 3072-bit algorithms of Cloud KMS.
pub const test_key_3072 =
    \\-----BEGIN PRIVATE KEY-----
    \\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
    \\ESwmJKIPFHQtlqeEtIQLAv4=
    \\-----END PRIVATE KEY-----
;

/// A 2049-bit test key: its PSS encoding is a byte shorter than its modulus.
pub const test_key_2049 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQGIOyiEYAtFyamR
    \\XSb+oCRy1TPBXAs0zTd+Ldo403J/wNbgzIHaZ8qrLDzNO2ogsRr8tXjBlFvClasi
    \\3lbSKbLwDgAgKVMJVhAKK4NT3+QZt8CKSDVtcOI0EY7ychBh42gNGesXfSSuScaq
    \\a2E0Lb1QNYwEnMDaur1JVgQkn0Bk8NofuzSzk+5ZvG/N7SMMxzW1mE8MeQWCCxMb
    \\qBBifKnufs7tQ0b0pjhWqAwluO+WaCKBtnBSZrVjFOhXBhh8OyX5H9VhuqAw/+sZ
    \\re1swUt7AZcwCZ7auxQFm191s+pP87TfQ1tnsMyp7dMbu4VD8fV/aHFg1bysn//g
    \\bTj/wW8jAgMBAAECggEBAPCAnbp1jdPv8IqSnMt6dH75HfANOU3aG5HCGdHITafq
    \\HZffriu2gr3stSd+q/d5wTt9JptEFfO9hB8wR/o72V16qDcQP7s0y0cBIVi3qwzd
    \\8DCaUDBYDEuzDHy61jK/ltiZsN5JPMmlsSxkBUlSVoetHbriRxqXcGNcW9P81iZN
    \\JAArA2d4tuKEYEV3UDbY+uhtoxz9I4TDglM1vVbFJHwtyf+XAAmMXdCm2aezSJi/
    \\cCXMortkCV8qGfDv+eG70GzyivaoL+W1uWRug4nSahODiZsOrN0wSE+QWSgVbbqf
    \\P+A009sc8u/YGhBAdDQSWR58grX6JsklWPe57BLlbLECgYEB5o0W+i6w60vVZF++
    \\db2O+ybMIQnUm5Xy9KvvbmgL/SAOtDbWQHSFBoc/PFILltHdsDQKr53SeHXAJ71I
    \\8LJ2uX/Dq9wqKRSZPG/koG3aZmhXgij2iUYtrpZAQBAtzYnfjnPH6TAGApZucH0s
    \\4ZCLQrtfp8YyJTZcElEnBOc2OvkCgYEAzl+P/fuwrRHYHq1CeOeGcp9OeQ0ew1b3
    \\VeZsSoUzOSQRpBJaTGNe2KeIMO3v1yv1uhxOl9AQIjoUjKYI2ExnR3M0zjsNtn33
    \\4P7vfgixmXyo6mLG0RXL/WyZhHgARmYEfPXvWe7vnCVanXY1k5LYHjzd3JDn3b8H
    \\XNByDZzUxfsCgYAC1B0nFTBoHce+zqOv0YtMQHx9UK5QvT1tWLaKoMY5EX+kYpE6
    \\TLMdR5oBgsSYet3cEWFihftcQer9ECelZpQ0Hd8IV75TANCnPktI93qGj+K6Wfyc
    \\7bCETFFRTgbGJCANlvS5kVLnnvJDaybgpNN6btZuhkNyXe+JF7mvWJzDGQKBgBMq
    \\7w3Q/bTlbmRTBVSDdIpa34gAvvW3sxtIXpCBVKOfBQBvL/HeXOXUkaKxxs/+ZkFV
    \\9brF+WmkaVoy5alpV0Jcoe/xrjFf+9Dq/MWA+zXdTTcP25V558tu9cdG+geP3CTb
    \\FtMMjTa8hXEQlKNTRT1xu82Lq+19m6p0NdOr2FtXAoGABeZHUyVZkJU2KjswmWRS
    \\CECSnjSRSIC6RpRmhDIA09Dcjmxz2yPfnS/jjPe2XKYHEpivpKuFqv+Fjpji88VB
    \\fD8M6Qa61Ge1q2/1fVy/vSWtybcHdTosFA6xb0vnB12YIjjwhWTRHjLNMe+E4LM7
    \\x2ROHPsHJdwyOU0dNAm9nf8=
    \\-----END PRIVATE KEY-----
;

/// test_key_2048's public half, as OpenSSL writes it (`openssl pkey -pubout`).
pub const test_key_2048_public =
    \\-----BEGIN PUBLIC KEY-----
    \\MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAic1zf6DMcOXapq8Ib2Dq
    \\4OuRoER1kN7u9d1nzYYg/ekFA0td+M0jpIIdaQDy5G/p/SbtdrJvjA3i+Jo2H6UF
    \\meuo3899da/N4J1kgky9xdmIejcTWuH5W4z43vkxsXWLXzPk4btBg2Wtaog18KDQ
    \\z1KdedfH0u6EFf+prtgaertjsi142+4RLDtJcazXawttKTkGT4EB4oe6ZyiVJITM
    \\pLY4J4lnyOByzonVLKYuE7u0Vfm7rkvLDyph3ws12YccUSwmlB9e8+iiAwe1w59f
    \\ebWfcyFD+6CQYW/vDzAnEqLMmaxIbKTdJjMwvaRktBhsUpZPfGGCSf0uuoRk7qJs
    \\fQIDAQAB
    \\-----END PUBLIC KEY-----
;

/// test_key_ec's public half: a SubjectPublicKeyInfo that is not RSA.
pub const test_key_ec_public =
    \\-----BEGIN PUBLIC KEY-----
    \\MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAESJH3txIrOadUDmwD8AZEFed1xl9o
    \\QtIPyFag7w7KKoojfVGXeTwKIE+atbNqc8ovqt71re6eP6yF6HZFZF2SVQ==
    \\-----END PUBLIC KEY-----
;

/// OpenSSL's RSASSA-PKCS1-v1_5 SHA-512 signature over `test_message` with
/// test_key_2048 (`openssl dgst -sha512 -sign`).
pub const test_sig_2048_sha512_hex = "2793e09d773135f4ef04927dc03061641600dea8cf1fd811818504464bcd5dbc3176826c74afab4b18ec301995f5499140136d79984ebe6283ca56f6c9838df4c778c933f5c6de3c70d3d503b4e0260b4e85e7d890917bcde274e3d9281d8fbf35daff59f81bb551bd26bc666241d8f4f2a5c10da540b8646bd45ae2e9c5562215355ea518cfa92e5ea1ded36dddc08451bdf5b93adde71f4943c58c8d01be0fc4d097fbc9f44096fc739529e0d24d4b4d3db3ac386ca7d642512856c4c94b59009cb4a788021c763c862f80a29094bfd0fc081a2c1ba1c94823fc912495e7bf18938070f1b5738eb20ad1ecde7082877144e8641095a74a989de8875a96b881";

/// OpenSSL's RSASSA-PSS SHA-256 signature over `test_message` with test_key_2048,
/// a 32-byte salt (`-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32`).
pub const test_sig_2048_pss_hex = "5bdbe42ad8670270b6a15949c6e77400cd89eb4c328c04f3f82a7526b54d5e37e9368a2d8c2e844ded4ebd252382c946933196a23f041b9b02eae895290011abec54f2a23e41a83c4a30a7ebd6265a6ffd4cdabf1106ed47449d68c3ab7260b9503d34e84e4c69ee1407b7a26d6d7fece4e7e79dda3c98a749c7d58d7189061a75e4af793e87370f49759bfbe91cecdaddfa679a37ddb8e70ccc1e7525a27625c8aa95986a6d72a091c424a75a3d89fc1f6cd50bf07af662f217e5a5ed7b5f0cee7be14080b12895cb8c52a873f4cd53bf61aa3fff343ec25536af016180b8edc238b9b56481208b857e709352ec290c56c1c5d1c173728e256a5fcd2b52b6ca";
