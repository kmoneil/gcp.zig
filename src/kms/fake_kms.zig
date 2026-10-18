//! Cloud KMS for tests, behind the `Transport` seam: key rings, keys and
//! their versions, with the state machine production documents, held to
//! the rules of the KMS spec (sections 8 and 11). It parses requests with
//! code of its own, so a request this library builds wrong is refused here
//! as production would refuse it.
//!
//! What it models:
//!
//! - Key rings: created, read, listed, deleted once empty. An id in use is
//!   409.
//! - Keys: created with a purpose, an algorithm of that purpose, a
//!   protection level, a destroy delay of 1 to 120 days (30 by default),
//!   labels and rotation, and version 1 unless asked not to; read, listed,
//!   updated (labels, rotation, the template's algorithm), deleted once
//!   every version is and no rotation is scheduled. A deleted key's id is
//!   retired for good, and listed as a retired resource.
//! - Versions: symmetric and MAC ones enabled at once, asymmetric ones
//!   `PENDING_GENERATION` for `Options.generation_delay_ms` first; enabled
//!   and disabled; destroyed after the key's delay, and restored before it;
//!   deleted once destroyed. The primary of an `ENCRYPT_DECRYPT` key, set
//!   by `updatePrimaryVersion` and by rotation, which runs on the clock.
//! - A refusal of a version that is not enabled carries the
//!   `PreconditionFailure` production sends, and a state change the
//!   machine forbids is `FAILED_PRECONDITION` in production's words.
//! - Deletes answer an operation that is not done yet, and done when read,
//!   as production's was (0.2 s later, on 2026-10-18).
//! - Faults a test asks for, and a call served and then answered with an
//!   error, as a lost answer is.
//!
//! Where it differs, until milestone 0 measures production: messages for
//! a missing resource, a delete out of order and a create refused are its
//! own; a key ring id is free again at once, where production takes 5 to
//! 10 minutes. Not modelled, each answered 501 with the reason: filters
//! and orders on lists, another project, import jobs, EKM, Autokey, IAM
//! enforcement (every caller may do everything), quotas, and the eventual
//! consistency of a disable or a primary change.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const JsonValue = std.json.Value;
const core = @import("core");
const tp = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");
const ecdsa = std.crypto.sign.ecdsa;
const mldsa = std.crypto.sign.mldsa;
const Ed25519 = std.crypto.sign.Ed25519;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const hmac = std.crypto.auth.hmac;

pub const FakeKms = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: Options,
    /// Strings, rings, keys and versions, freed with the fake.
    store: std.heap.ArenaAllocator,
    /// By full name.
    rings: std.StringArrayHashMapUnmanaged(Ring) = .empty,
    /// By full name.
    keys: std.StringArrayHashMapUnmanaged(*Key) = .empty,
    /// Every key id ever deleted, by full name: never usable again.
    retired: std.ArrayList(Retired) = .empty,
    operations: usize = 0,
    faults: [3]Fault = .{ .{}, .{}, .{} },
    corruption: struct { n: usize = 0, kind: Corruption = .flip_payload } = .{},
    calls: usize = 0,

    const Fault = struct { n: usize = 0, status: u16 = 0 };
    const refuse = 0;
    const drop = 1;
    const lose = 2;

    /// The destroy delay of a key that names none.
    pub const default_destroy_delay_s: u64 = 30 * std.time.s_per_day;
    /// The largest page a list answers.
    pub const max_page = 1000;

    pub const Options = struct {
        /// The project it answers for, by id.
        project_id: []const u8 = "my-project",
        /// How long a new asymmetric version stays `PENDING_GENERATION`.
        generation_delay_ms: u32 = 0,
    };

    pub const Reply = struct { status: u16, headers: []const tp.Header = &.{}, body: []const u8 };

    const Ring = struct {
        name: []const u8,
        create_time: i96,
    };

    const Key = struct {
        name: []const u8,
        ring: []const u8,
        purpose: types.Purpose,
        protection_level: types.ProtectionLevel,
        /// The template: what new versions are made with.
        algorithm: types.Algorithm,
        create_time: i96,
        destroy_delay_s: u64,
        labels: []const types.Label,
        rotation_period_s: ?u64 = null,
        next_rotation: ?i96 = null,
        primary: ?u64 = null,
        /// Every version made, deleted ones too, so the next id is
        /// `versions.items.len + 1`.
        versions: std.ArrayList(Version) = .empty,
    };

    pub const Version = struct {
        id: u64,
        state: types.State,
        algorithm: types.Algorithm,
        protection_level: types.ProtectionLevel,
        create_time: i96,
        /// When a pending version is ready, and when a ready one was made.
        generate_time: i96,
        destroy_time: ?i96 = null,
        destroy_event_time: ?i96 = null,
        deleted: bool = false,
        /// The key material, made with the version.
        material: *const Material,
    };

    /// A version's key, real, so what the fake encrypts it decrypts and
    /// what it signs verifies. RSA keys come from core.rsa's test keys,
    /// since std cannot make one: two RSA versions of a size share one.
    pub const Material = union(enum) {
        aes: [32]u8,
        hmac: struct { key: [64]u8, len: u8 },
        p256: ecdsa.EcdsaP256Sha256.KeyPair,
        p384: ecdsa.EcdsaP384Sha384.KeyPair,
        secp256k1: ecdsa.EcdsaSecp256k1Sha256.KeyPair,
        ed25519: Ed25519.KeyPair,
        /// The modulus's bits: 2048, 3072 or 4096.
        rsa: u16,
        mldsa44: mldsa.MLDSA44.KeyPair,
        mldsa65: mldsa.MLDSA65.KeyPair,
        mldsa87: mldsa.MLDSA87.KeyPair,
        /// An algorithm whose cryptography the fake does not model: raw
        /// AES, RSA-OAEP, key encapsulation, SLH-DSA.
        none,
    };

    /// What the next crypto answers get wrong, for a test of the client's
    /// checks (the KMS spec, section 7.6).
    pub const Corruption = enum {
        /// A byte of the answer's payload flipped, its checksum left as it
        /// was: ciphertext, plaintext, signature, MAC, key or random bytes.
        flip_payload,
        /// The `verified*` flags false, as if the server had not got the
        /// request's checksums.
        drop_verified,
        /// The answer names the version after the one asked for.
        wrong_name,
        /// `macVerify`'s `verifiedSuccessIntegrity` not its `success`.
        success_mismatch,
        /// The request refused as if a checksum it carried did not match.
        refuse_checksum,
    };

    /// The next `n` crypto answers get `kind` wrong.
    pub fn corruptNext(f: *FakeKms, n: usize, kind: Corruption) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.corruption = .{ .n = n, .kind = kind };
    }

    fn takeCorruption(f: *FakeKms) ?Corruption {
        if (f.corruption.n == 0) return null;
        f.corruption.n -= 1;
        return f.corruption.kind;
    }

    const Retired = struct { name: []const u8, original: []const u8, delete_time: i96 };

    pub fn init(gpa: Allocator, io: std.Io, options: Options) FakeKms {
        return .{ .gpa = gpa, .io = io, .options = options, .store = .init(gpa) };
    }

    pub fn deinit(f: *FakeKms) void {
        f.rings.deinit(f.gpa);
        f.keys.deinit(f.gpa);
        f.retired.deinit(f.gpa);
        f.store.deinit();
        f.* = undefined;
    }

    /// Goes into `Client.Options.transport`.
    pub fn transport(f: *FakeKms) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    fn nowNs(f: *const FakeKms) i96 {
        return std.Io.Clock.real.now(f.io).nanoseconds;
    }

    // Faults, each for the next `n` calls.

    /// Answers them with `status`, and changes nothing.
    pub fn refuseNext(f: *FakeKms, n: usize, status: u16) void {
        f.setFault(refuse, .{ .n = n, .status = status });
    }

    /// Closes their connection before any answer.
    pub fn dropNext(f: *FakeKms, n: usize) void {
        f.setFault(drop, .{ .n = n });
    }

    /// Serves them, so what they change is changed, and answers `status`
    /// instead of what was done, as a 503 can after the work was done.
    pub fn loseNext(f: *FakeKms, n: usize, status: u16) void {
        f.setFault(lose, .{ .n = n, .status = status });
    }

    fn setFault(f: *FakeKms, slot: usize, fault: Fault) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.faults[slot] = fault;
    }

    fn takeFault(f: *FakeKms, slot: usize) ?Fault {
        const fault = &f.faults[slot];
        if (fault.n == 0) return null;
        fault.n -= 1;
        return fault.*;
    }

    // What a test reads.

    /// Calls served, refusals included.
    pub fn callCount(f: *FakeKms) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.calls;
    }

    /// Versions that would be billed now: made, and not destroyed or
    /// deleted.
    pub fn billedVersions(f: *FakeKms) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.settle();
        var n: usize = 0;
        for (f.keys.values()) |k| for (k.versions.items) |v| {
            if (!v.deleted and v.state.billed()) n += 1;
        };
        return n;
    }

    /// The version as the fake holds it, or null.
    pub fn version(f: *FakeKms, key_name: []const u8, id: u64) ?Version {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.settle();
        const k = f.keys.get(key_name) orelse return null;
        if (id == 0 or id > k.versions.items.len) return null;
        const v = k.versions.items[id - 1];
        return if (v.deleted) null else v;
    }

    // The transport.

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const f: *FakeKms = @ptrCast(@alignCast(ptr));
        const reply = try f.serve(req, arena);
        return .{ .status = reply.status, .headers = reply.headers, .body = reply.body };
    }

    /// One request, as `send` serves it: for a test that wants to send
    /// what no client would.
    pub fn serve(f: *FakeKms, req: tp.Request, arena: Allocator) tp.Error!Reply {
        const path = pathOf(req.url);
        const q_at = std.mem.indexOfScalar(u8, path, '?');
        const route_text = path[0 .. q_at orelse path.len];
        const query = if (q_at) |q| path[q + 1 ..] else "";
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.calls += 1;
        if (f.takeFault(drop) != null) return error.ConnectionResetByPeer;
        if (f.takeFault(refuse)) |fault| return refusal(arena, fault.status);
        const lost = f.takeFault(lose);
        f.settle();
        const reply = try f.route(req, arena, route_text, query);
        if (lost) |fault| return refusal(arena, fault.status);
        return reply;
    }

    /// Moves every version and key along the clock: pending versions ready,
    /// scheduled ones destroyed, rotations run.
    fn settle(f: *FakeKms) void {
        const now = f.nowNs();
        for (f.keys.values()) |k| {
            for (k.versions.items) |*v| {
                if (v.state == .pending_generation and v.generate_time <= now) v.state = .enabled;
                if (v.state == .destroy_scheduled and v.destroy_time.? <= now) {
                    v.state = .destroyed;
                    v.destroy_event_time = v.destroy_time;
                    v.destroy_time = null;
                }
            }
            while (k.next_rotation) |next| {
                if (next > now) break;
                const v = f.addVersion(k, next) catch return;
                k.primary = v.id;
                k.next_rotation = if (k.rotation_period_s) |p| next + @as(i96, p) * std.time.ns_per_s else null;
            }
        }
    }

    fn addVersion(f: *FakeKms, k: *Key, at: i96) Allocator.Error!*Version {
        const slow = k.algorithm.generatesSlowly();
        const material = try f.store.allocator().create(Material);
        material.* = f.newMaterial(k.algorithm);
        try k.versions.append(f.store.allocator(), .{
            .id = k.versions.items.len + 1,
            .state = if (slow and f.options.generation_delay_ms > 0) .pending_generation else .enabled,
            .algorithm = k.algorithm,
            .protection_level = k.protection_level,
            .create_time = at,
            .generate_time = at + if (slow) @as(i96, f.options.generation_delay_ms) * std.time.ns_per_ms else 0,
            .material = material,
        });
        return &k.versions.items[k.versions.items.len - 1];
    }

    fn newMaterial(f: *FakeKms, algorithm: types.Algorithm) Material {
        switch (algorithm) {
            .google_symmetric_encryption => {
                var key: [32]u8 = undefined;
                f.io.random(&key);
                return .{ .aes = key };
            },
            .hmac_sha1, .hmac_sha224, .hmac_sha256, .hmac_sha384, .hmac_sha512 => {
                var key: [64]u8 = undefined;
                f.io.random(&key);
                const len: u8 = switch (algorithm) {
                    .hmac_sha1 => 20,
                    .hmac_sha224 => 28,
                    .hmac_sha256 => 32,
                    .hmac_sha384 => 48,
                    else => 64,
                };
                return .{ .hmac = .{ .key = key, .len = len } };
            },
            .ec_sign_p256_sha256 => return .{ .p256 = .generate(f.io) },
            .ec_sign_p384_sha384 => return .{ .p384 = .generate(f.io) },
            .ec_sign_secp256k1_sha256 => return .{ .secp256k1 = .generate(f.io) },
            .ec_sign_ed25519 => return .{ .ed25519 = .generate(f.io) },
            .rsa_sign_pss_2048_sha256, .rsa_sign_pkcs1_2048_sha256 => return .{ .rsa = 2048 },
            .rsa_sign_pss_3072_sha256, .rsa_sign_pkcs1_3072_sha256 => return .{ .rsa = 3072 },
            .rsa_sign_pss_4096_sha256, .rsa_sign_pss_4096_sha512, .rsa_sign_pkcs1_4096_sha256, .rsa_sign_pkcs1_4096_sha512 => return .{ .rsa = 4096 },
            .pq_sign_ml_dsa_44 => return .{ .mldsa44 = .generate(f.io) },
            .pq_sign_ml_dsa_65 => return .{ .mldsa65 = .generate(f.io) },
            .pq_sign_ml_dsa_87 => return .{ .mldsa87 = .generate(f.io) },
            else => return .none,
        }
    }

    fn route(f: *FakeKms, req: tp.Request, arena: Allocator, route_text: []const u8, query: []const u8) Allocator.Error!Reply {
        if (req.bearer == null) return fail(arena, 401, "UNAUTHENTICATED", "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.");
        const params = try parseParams(arena, query) orelse return fail(arena, 400, "INVALID_ARGUMENT", "Invalid query string.");
        const target = parseTarget(route_text) orelse return htmlNotFound(arena);
        if (!std.mem.eql(u8, target.project, f.options.project_id)) return notModelled(arena, "a project other than the fake's own");
        if (paramOf(params, "filter") != null or paramOf(params, "orderBy") != null) return notModelled(arena, "a filter or an order on a list");
        const body = req.body orelse "";
        return switch (target.kind) {
            .locations => if (req.method == .GET) f.listLocations(arena, target.project) else htmlNotFound(arena),
            .key_rings => switch (req.method) {
                .POST => f.createRing(arena, target, params),
                .GET => f.listRings(arena, target, params),
                else => htmlNotFound(arena),
            },
            .key_ring => if (target.method.len > 0) notModelled(arena, "this method on a key ring") else switch (req.method) {
                .GET => f.getRing(arena, target),
                .DELETE => f.deleteRing(arena, target),
                else => htmlNotFound(arena),
            },
            .keys => switch (req.method) {
                .POST => f.createKey(arena, target, params, body),
                .GET => f.listKeys(arena, target, params),
                else => htmlNotFound(arena),
            },
            .key => f.keyRoute(arena, req.method, target, params, body),
            .versions => switch (req.method) {
                .POST => f.createVersion(arena, target, body),
                .GET => f.listVersions(arena, target, params),
                else => htmlNotFound(arena),
            },
            .version => f.versionRoute(arena, req.method, target, params, body),
            .retired => if (req.method == .GET) f.listRetired(arena, target, params) else htmlNotFound(arena),
            .operation => if (req.method == .GET) f.getOperation(arena, route_text) else htmlNotFound(arena),
            .location => if (req.method == .POST and std.mem.eql(u8, target.method, "generateRandomBytes")) f.randomBytes(arena, body) else htmlNotFound(arena),
            .public_key => if (req.method == .GET) f.publicKey(arena, target, params) else htmlNotFound(arena),
        };
    }

    // Locations: a fixed few, with what each offers.

    fn listLocations(f: *FakeKms, arena: Allocator, project: []const u8) Allocator.Error!Reply {
        _ = f;
        const known = [_]struct { []const u8, []const u8, bool, bool }{
            .{ "global", "Global", true, false },
            .{ "us", "United States", true, true },
            .{ "us-central1", "Iowa", true, true },
            .{ "us-east1", "South Carolina", true, true },
            .{ "europe-west1", "Belgium", true, true },
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeLocations(&jw, project, &known) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn writeLocations(jw: *Stringify, project: []const u8, known: anytype) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("locations");
        try jw.beginArray();
        for (known) |l| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.print("\"projects/{s}/locations/{s}\"", .{ project, l[0] });
            try jw.objectField("locationId");
            try jw.write(l[0]);
            try jw.objectField("displayName");
            try jw.write(l[1]);
            try jw.objectField("metadata");
            try jw.beginObject();
            try jw.objectField("@type");
            try jw.write("type.googleapis.com/google.cloud.kms.v1.LocationMetadata");
            if (l[2]) {
                try jw.objectField("hsmAvailable");
                try jw.write(true);
            }
            if (l[3]) {
                try jw.objectField("ekmAvailable");
                try jw.write(true);
            }
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }

    // Key rings.

    fn createRing(f: *FakeKms, arena: Allocator, target: Target, params: []const Param) Allocator.Error!Reply {
        const id = paramOf(params, "keyRingId") orelse return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
        if (!validate.isId(id)) return invalidId(arena, "key_ring_id", id);
        const name = try std.fmt.allocPrint(f.store.allocator(), "{s}/keyRings/{s}", .{ target.location_name, id });
        if (f.rings.contains(name)) return fail(arena, 409, "ALREADY_EXISTS", try arena.print("KeyRing {s} already exists.", .{name}));
        try f.rings.put(f.gpa, name, .{ .name = name, .create_time = f.nowNs() });
        return .{ .status = 200, .body = try renderRing(arena, f.rings.get(name).?) };
    }

    fn getRing(f: *FakeKms, arena: Allocator, target: Target) Allocator.Error!Reply {
        const ring = f.rings.get(target.ring_name) orelse return notFound(arena, "KeyRing", target.ring_name);
        return .{ .status = 200, .body = try renderRing(arena, ring) };
    }

    fn listRings(f: *FakeKms, arena: Allocator, target: Target, params: []const Param) Allocator.Error!Reply {
        var found: std.ArrayList(Ring) = .empty;
        for (f.rings.values()) |r| {
            if (std.mem.startsWith(u8, r.name, target.location_name) and r.name[target.location_name.len] == '/') try found.append(arena, r);
        }
        const window = pageOf(params, found.items.len) orelse return pageTokenRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePage(&jw, "keyRings", found.items[window.from..window.to], window.next, writeRing) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn deleteRing(f: *FakeKms, arena: Allocator, target: Target) Allocator.Error!Reply {
        if (!f.rings.contains(target.ring_name)) return notFound(arena, "KeyRing", target.ring_name);
        for (f.keys.values()) |k| if (std.mem.eql(u8, k.ring, target.ring_name)) {
            return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("fake: KeyRing {s} still holds keys; delete them first", .{target.ring_name}));
        };
        _ = f.rings.orderedRemove(target.ring_name);
        return f.startOperation(arena, target, null);
    }

    // Keys.

    fn createKey(f: *FakeKms, arena: Allocator, target: Target, params: []const Param, body: []const u8) Allocator.Error!Reply {
        if (!f.rings.contains(target.ring_name)) return notFound(arena, "KeyRing", target.ring_name);
        const id = paramOf(params, "cryptoKeyId") orelse return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
        if (!validate.isId(id)) return invalidId(arena, "crypto_key_id", id);
        const skip = if (paramOf(params, "skipInitialVersionCreation")) |s| std.mem.eql(u8, s, "true") else false;
        const s = f.store.allocator();
        const name = try std.fmt.allocPrint(s, "{s}/cryptoKeys/{s}", .{ target.ring_name, id });
        if (f.keys.contains(name)) return fail(arena, 409, "ALREADY_EXISTS", try arena.print("CryptoKey {s} already exists.", .{name}));
        if (f.retiredOf(name)) |retired| return retiredRefusal(arena, name, retired);

        const root = parseJson(arena, body) orelse return invalidJson(arena);
        if (root != .object) return invalidJson(arena);
        const o = root.object;
        const purpose = types.Purpose.fromWire(stringField(o, "purpose") orelse "");
        if (purpose == .unknown) return fail(arena, 400, "INVALID_ARGUMENT", "fake: a key names its purpose");
        var protection: types.ProtectionLevel = .software;
        var algorithm: types.Algorithm = if (purpose == .encrypt_decrypt) .google_symmetric_encryption else .unknown;
        if (objectField(o, "versionTemplate")) |t| {
            if (stringField(t, "protectionLevel")) |p| protection = types.ProtectionLevel.fromWire(p);
            if (stringField(t, "algorithm")) |a| algorithm = types.Algorithm.fromWire(a);
        }
        if (algorithm == .unknown or protection == .unknown) return fail(arena, 400, "INVALID_ARGUMENT", "fake: a key names an algorithm and a protection level this fake knows");
        if (algorithm.purpose() != purpose) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: algorithm {s} is not for purpose {s}", .{ algorithm.wire(), purpose.wire() }));
        if (protection != .software and protection != .hsm) return notModelled(arena, "an external or single-tenant key");
        var delay = default_destroy_delay_s;
        if (stringField(o, "destroyScheduledDuration")) |d| {
            delay = durationSeconds(d) orelse return fail(arena, 400, "INVALID_ARGUMENT", "fake: destroyScheduledDuration is a duration");
            if (delay < validate.min_destroy_delay_s or delay > validate.max_destroy_delay_s) return fail(arena, 400, "INVALID_ARGUMENT", "fake: the destroy scheduled duration is 1 to 120 days");
        }
        var key: Key = .{
            .name = name,
            .ring = f.rings.getEntry(target.ring_name).?.key_ptr.*,
            .purpose = purpose,
            .protection_level = protection,
            .algorithm = algorithm,
            .create_time = f.nowNs(),
            .destroy_delay_s = delay,
            .labels = try storedLabels(s, o) orelse return invalidJson(arena),
        };
        if (validate.labelsProblem(key.labels)) |p| return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: {s}", .{p}));
        if (try rotationOf(arena, o)) |r| switch (r) {
            .refusal => |reply| return reply,
            .set => |rot| {
                if (purpose != .encrypt_decrypt) return fail(arena, 400, "INVALID_ARGUMENT", "fake: only ENCRYPT_DECRYPT keys rotate");
                key.rotation_period_s = rot.period_s;
                key.next_rotation = rot.next;
            },
        };
        const k = try s.create(Key);
        k.* = key;
        try f.keys.put(f.gpa, name, k);
        if (!skip) {
            const v = try f.addVersion(k, k.create_time);
            if (purpose == .encrypt_decrypt) k.primary = v.id;
        }
        return .{ .status = 200, .body = try f.renderKey(arena, k) };
    }

    fn keyRoute(f: *FakeKms, arena: Allocator, method: tp.Method, target: Target, params: []const Param, body: []const u8) Allocator.Error!Reply {
        const k = f.keys.get(target.key_name) orelse return notFound(arena, "CryptoKey", target.key_name);
        if (std.mem.eql(u8, target.method, "updatePrimaryVersion")) {
            if (method != .POST) return htmlNotFound(arena);
            return f.setPrimary(arena, k, body);
        }
        if (std.mem.eql(u8, target.method, "encrypt") or std.mem.eql(u8, target.method, "decrypt")) {
            if (method != .POST) return htmlNotFound(arena);
            if (target.method[0] == 'e') return f.encrypt(arena, k, null, body);
            return f.decrypt(arena, k, body);
        }
        if (target.method.len > 0) return notModelled(arena, "this method on a key");
        return switch (method) {
            .GET => .{ .status = 200, .body = try f.renderKey(arena, k) },
            .PATCH => f.updateKey(arena, k, params, body),
            .DELETE => f.deleteKey(arena, target, k),
            else => htmlNotFound(arena),
        };
    }

    fn setPrimary(f: *FakeKms, arena: Allocator, k: *Key, body: []const u8) Allocator.Error!Reply {
        if (k.purpose != .encrypt_decrypt) return fail(arena, 400, "INVALID_ARGUMENT", "fake: only ENCRYPT_DECRYPT keys have a primary version");
        const root = parseJson(arena, body) orelse return invalidJson(arena);
        if (root != .object) return invalidJson(arena);
        const text = stringField(root.object, "cryptoKeyVersionId") orelse return invalidJson(arena);
        const id = std.fmt.parseInt(u64, text, 10) catch return invalidJson(arena);
        const v = liveVersion(k, id) orelse return notFound(arena, "CryptoKeyVersion", try arena.print("{s}/cryptoKeyVersions/{s}", .{ k.name, text }));
        if (v.state != .enabled) return notModelled(arena, "a primary version that is not enabled");
        k.primary = id;
        return .{ .status = 200, .body = try f.renderKey(arena, k) };
    }

    fn updateKey(f: *FakeKms, arena: Allocator, k: *Key, params: []const Param, body: []const u8) Allocator.Error!Reply {
        const mask = paramOf(params, "updateMask") orelse return fail(arena, 400, "INVALID_ARGUMENT", "fake: an update names its updateMask");
        const root = parseJson(arena, body) orelse return invalidJson(arena);
        if (root != .object) return invalidJson(arena);
        const o = root.object;
        var labels = k.labels;
        var period = k.rotation_period_s;
        var next = k.next_rotation;
        var algorithm = k.algorithm;
        var paths = std.mem.splitScalar(u8, mask, ',');
        var rotation_named = false;
        while (paths.next()) |p| {
            if (std.mem.eql(u8, p, "labels")) {
                labels = try storedLabels(f.store.allocator(), o) orelse return invalidJson(arena);
                if (validate.labelsProblem(labels)) |problem| return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: {s}", .{problem}));
            } else if (std.mem.eql(u8, p, "rotationPeriod") or std.mem.eql(u8, p, "nextRotationTime")) {
                rotation_named = true;
            } else if (std.mem.eql(u8, p, "versionTemplate.algorithm")) {
                const t = objectField(o, "versionTemplate") orelse return invalidJson(arena);
                algorithm = types.Algorithm.fromWire(stringField(t, "algorithm") orelse "");
                if (algorithm == .unknown or algorithm.purpose() != k.purpose) return fail(arena, 400, "INVALID_ARGUMENT", "fake: the template's algorithm is of the key's purpose");
            } else {
                return notModelled(arena, try arena.print("updateMask path {s}", .{p}));
            }
        }
        if (rotation_named) {
            if (k.purpose != .encrypt_decrypt and (o.get("rotationPeriod") != null or o.get("nextRotationTime") != null)) {
                return fail(arena, 400, "INVALID_ARGUMENT", "fake: only ENCRYPT_DECRYPT keys rotate");
            }
            if (try rotationOf(arena, o)) |r| switch (r) {
                .refusal => |reply| return reply,
                .set => |rot| {
                    period = rot.period_s;
                    next = rot.next;
                },
            } else {
                period = null;
                next = null;
            }
        }
        k.labels = labels;
        k.rotation_period_s = period;
        k.next_rotation = next;
        k.algorithm = algorithm;
        return .{ .status = 200, .body = try f.renderKey(arena, k) };
    }

    fn deleteKey(f: *FakeKms, arena: Allocator, target: Target, k: *Key) Allocator.Error!Reply {
        for (k.versions.items) |v| if (!v.deleted) {
            return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("fake: CryptoKey {s} still has versions that are not deleted", .{k.name}));
        };
        if (k.next_rotation != null) return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("fake: CryptoKey {s} has automatic rotation scheduled", .{k.name}));
        const retired_name = try std.fmt.allocPrint(f.store.allocator(), "{s}/retiredResources/r{d}", .{ target.location_name, f.retired.items.len + 1 });
        try f.retired.append(f.gpa, .{ .name = retired_name, .original = k.name, .delete_time = f.nowNs() });
        _ = f.keys.orderedRemove(k.name);
        return f.startOperation(arena, target, retired_name);
    }

    fn listKeys(f: *FakeKms, arena: Allocator, target: Target, params: []const Param) Allocator.Error!Reply {
        if (!f.rings.contains(target.ring_name)) return notFound(arena, "KeyRing", target.ring_name);
        var found: std.ArrayList(*Key) = .empty;
        for (f.keys.values()) |k| if (std.mem.eql(u8, k.ring, target.ring_name)) try found.append(arena, k);
        const window = pageOf(params, found.items.len) orelse return pageTokenRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeKeyPage(f, &jw, found.items[window.from..window.to], window.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    /// The retired resource's name of a deleted key, or null.
    fn retiredOf(f: *const FakeKms, key_name: []const u8) ?[]const u8 {
        for (f.retired.items) |r| if (std.mem.eql(u8, r.original, key_name)) return r.name;
        return null;
    }

    // Versions.

    fn createVersion(f: *FakeKms, arena: Allocator, target: Target, body: []const u8) Allocator.Error!Reply {
        const k = f.keys.get(target.key_name) orelse return notFound(arena, "CryptoKey", target.key_name);
        const root = parseJson(arena, body) orelse return invalidJson(arena);
        if (root != .object) return invalidJson(arena);
        var disabled = false;
        if (stringField(root.object, "state")) |s| {
            const state = types.State.fromWire(s);
            if (state != .enabled and state != .disabled) return fail(arena, 400, "INVALID_ARGUMENT", "fake: a new version is ENABLED or DISABLED");
            disabled = state == .disabled;
        }
        const v = try f.addVersion(k, f.nowNs());
        if (disabled and v.state == .enabled) v.state = .disabled;
        return .{ .status = 200, .body = try renderVersion(arena, k, v.*) };
    }

    fn listVersions(f: *FakeKms, arena: Allocator, target: Target, params: []const Param) Allocator.Error!Reply {
        const k = f.keys.get(target.key_name) orelse return notFound(arena, "CryptoKey", target.key_name);
        var found: std.ArrayList(Version) = .empty;
        for (k.versions.items) |v| if (!v.deleted) try found.append(arena, v);
        const window = pageOf(params, found.items.len) orelse return pageTokenRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeVersionPage(&jw, k, found.items[window.from..window.to], window.next) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn versionRoute(f: *FakeKms, arena: Allocator, method: tp.Method, target: Target, params: []const Param, body: []const u8) Allocator.Error!Reply {
        const k = f.keys.get(target.key_name) orelse return notFound(arena, "CryptoKey", target.key_name);
        const v = liveVersion(k, target.version) orelse return notFound(arena, "CryptoKeyVersion", target.version_name);
        if (target.method.len == 0) return switch (method) {
            .GET => .{ .status = 200, .body = try renderVersion(arena, k, v.*) },
            .PATCH => f.patchVersion(arena, k, v, params, body),
            .DELETE => f.deleteVersion(arena, target, v),
            else => htmlNotFound(arena),
        };
        if (method != .POST) return htmlNotFound(arena);
        if (std.mem.eql(u8, target.method, "destroy")) {
            if (v.state != .enabled and v.state != .disabled) return transitionRefused(arena, target.version_name, v.state);
            v.state = .destroy_scheduled;
            v.destroy_time = f.nowNs() + @as(i96, k.destroy_delay_s) * std.time.ns_per_s;
            return .{ .status = 200, .body = try renderVersion(arena, k, v.*) };
        }
        if (std.mem.eql(u8, target.method, "restore")) {
            if (v.state != .destroy_scheduled) return transitionRefused(arena, target.version_name, v.state);
            v.state = .disabled;
            v.destroy_time = null;
            return .{ .status = 200, .body = try renderVersion(arena, k, v.*) };
        }
        if (std.mem.eql(u8, target.method, "encrypt")) return f.encrypt(arena, k, v, body);
        if (std.mem.eql(u8, target.method, "asymmetricSign")) return f.sign(arena, k, v, target.version_name, body);
        if (std.mem.eql(u8, target.method, "macSign")) return f.mac(arena, k, v, target.version_name, body, false);
        if (std.mem.eql(u8, target.method, "macVerify")) return f.mac(arena, k, v, target.version_name, body, true);
        return notModelled(arena, try arena.print("{s} on a key version", .{target.method}));
    }

    fn patchVersion(f: *FakeKms, arena: Allocator, k: *Key, v: *Version, params: []const Param, body: []const u8) Allocator.Error!Reply {
        _ = f;
        const mask = paramOf(params, "updateMask") orelse return fail(arena, 400, "INVALID_ARGUMENT", "fake: an update names its updateMask");
        if (!std.mem.eql(u8, mask, "state")) return notModelled(arena, try arena.print("updateMask {s} on a key version", .{mask}));
        const root = parseJson(arena, body) orelse return invalidJson(arena);
        if (root != .object) return invalidJson(arena);
        const want = types.State.fromWire(stringField(root.object, "state") orelse "");
        if (want != .enabled and want != .disabled) return fail(arena, 400, "INVALID_ARGUMENT", "fake: a version's state is set to ENABLED or DISABLED");
        if (v.state != .enabled and v.state != .disabled) return transitionRefused(arena, try versionName(arena, k, v.id), v.state);
        v.state = want;
        return .{ .status = 200, .body = try renderVersion(arena, k, v.*) };
    }

    fn deleteVersion(f: *FakeKms, arena: Allocator, target: Target, v: *Version) Allocator.Error!Reply {
        switch (v.state) {
            .destroyed, .generation_failed, .import_failed => {},
            else => return transitionRefused(arena, target.version_name, v.state),
        }
        v.deleted = true;
        return f.startOperation(arena, target, null);
    }

    fn liveVersion(k: *Key, id: u64) ?*Version {
        if (id == 0 or id > k.versions.items.len) return null;
        const v = &k.versions.items[id - 1];
        return if (v.deleted) null else v;
    }

    // Cryptography.

    /// The fake's ciphertext: a magic, the version, a nonce, AES-256-GCM
    /// over the plaintext with the key's name and the AAD as associated
    /// data, so another key's ciphertext fails as production's does.
    const ciphertext_magic = "FKC1";
    const ciphertext_overhead = ciphertext_magic.len + 8 + Aes256Gcm.nonce_length + Aes256Gcm.tag_length;

    fn encrypt(f: *FakeKms, arena: Allocator, k: *Key, pinned: ?*Version, body: []const u8) Allocator.Error!Reply {
        if (k.purpose != .encrypt_decrypt) return wrongPurpose(arena, k, "encrypt");
        const o = (try requestObject(arena, body)) orelse return invalidJson(arena);
        const plaintext = (try checkedBytes(arena, o, "plaintext", "plaintext")).value orelse return invalidJson(arena);
        const aad = (try checkedBytes(arena, o, "additionalAuthenticatedData", "additional_authenticated_data")).value orelse return invalidJson(arena);
        if (try checksumRefusal(arena, o, &.{ .{ "plaintext", "plaintext" }, .{ "additionalAuthenticatedData", "additional_authenticated_data" } })) |r| return r;
        if (plaintext.len > validate.max_payload or aad.len > validate.max_payload) return fail(arena, 400, "INVALID_ARGUMENT", "fake: plaintext and AAD are at most 64 KiB each");
        const v = pinned orelse (if (k.primary) |p| &k.versions.items[p - 1] else return fail(arena, 400, "FAILED_PRECONDITION", "fake: the key has no primary version"));
        const name = try versionName(arena, k, v.id);
        if (v.state != .enabled) return notEnabled(arena, name, v.state);
        const corruption = f.takeCorruption();
        if (corruption == .refuse_checksum) return checksumRefused(arena, "plaintext");
        const out = try arena.alloc(u8, ciphertext_overhead + plaintext.len);
        @memcpy(out[0..4], ciphertext_magic);
        std.mem.writeInt(u64, out[4..12], v.id, .big);
        const nonce = out[12..][0..Aes256Gcm.nonce_length];
        f.io.random(nonce);
        const ad = try std.mem.concat(arena, u8, &.{ k.name, "\x00", aad });
        const ct = out[12 + Aes256Gcm.nonce_length ..][0..plaintext.len];
        const tag = out[out.len - Aes256Gcm.tag_length ..][0..Aes256Gcm.tag_length];
        Aes256Gcm.encrypt(ct, tag, plaintext, ad, nonce.*, v.material.aes);
        return f.cryptoAnswer(arena, corruption, .{
            .name = name,
            .payload = .{ "ciphertext", out },
            .flags = &.{ .{ "verifiedPlaintextCrc32c", o.get("plaintextCrc32c") != null }, .{ "verifiedAdditionalAuthenticatedDataCrc32c", o.get("additionalAuthenticatedDataCrc32c") != null } },
            .protection_level = v.protection_level,
        });
    }

    fn decrypt(f: *FakeKms, arena: Allocator, k: *Key, body: []const u8) Allocator.Error!Reply {
        if (k.purpose != .encrypt_decrypt) return wrongPurpose(arena, k, "decrypt");
        const o = (try requestObject(arena, body)) orelse return invalidJson(arena);
        const ciphertext = (try checkedBytes(arena, o, "ciphertext", "ciphertext")).value orelse return invalidJson(arena);
        const aad = (try checkedBytes(arena, o, "additionalAuthenticatedData", "additional_authenticated_data")).value orelse return invalidJson(arena);
        if (try checksumRefusal(arena, o, &.{ .{ "ciphertext", "ciphertext" }, .{ "additionalAuthenticatedData", "additional_authenticated_data" } })) |r| return r;
        const invalid = "Decryption failed: the ciphertext is invalid.";
        const wrong_key = "Decryption failed: verify that 'name' refers to the correct CryptoKey.";
        if (ciphertext.len < ciphertext_overhead or !std.mem.eql(u8, ciphertext[0..4], ciphertext_magic)) return fail(arena, 400, "INVALID_ARGUMENT", invalid);
        const id = std.mem.readInt(u64, ciphertext[4..12], .big);
        const v = liveVersion(k, id) orelse return fail(arena, 400, "INVALID_ARGUMENT", wrong_key);
        if (v.state != .enabled) return notEnabled(arena, try versionName(arena, k, v.id), v.state);
        if (v.material.* != .aes) return fail(arena, 400, "INVALID_ARGUMENT", wrong_key);
        const corruption = f.takeCorruption();
        if (corruption == .refuse_checksum) return checksumRefused(arena, "ciphertext");
        const nonce = ciphertext[12..][0..Aes256Gcm.nonce_length];
        const ct = ciphertext[12 + Aes256Gcm.nonce_length .. ciphertext.len - Aes256Gcm.tag_length];
        const tag = ciphertext[ciphertext.len - Aes256Gcm.tag_length ..][0..Aes256Gcm.tag_length];
        const plaintext = try arena.alloc(u8, ct.len);
        const ad = try std.mem.concat(arena, u8, &.{ k.name, "\x00", aad });
        Aes256Gcm.decrypt(plaintext, ct, tag.*, ad, nonce.*, v.material.aes) catch return fail(arena, 400, "INVALID_ARGUMENT", wrong_key);
        return f.cryptoAnswer(arena, corruption, .{
            .payload = .{ "plaintext", plaintext },
            .flags = &.{.{ "usedPrimary", k.primary == v.id }},
            .protection_level = v.protection_level,
        });
    }

    fn sign(f: *FakeKms, arena: Allocator, k: *Key, v: *Version, name: []const u8, body: []const u8) Allocator.Error!Reply {
        if (k.purpose != .asymmetric_sign) return wrongPurpose(arena, k, "asymmetricSign");
        if (v.state != .enabled) return notEnabled(arena, name, v.state);
        const o = (try requestObject(arena, body)) orelse return invalidJson(arena);
        const want = v.algorithm.signInput() orelse return notModelled(arena, try arena.print("signing with {s}", .{v.algorithm.wire()}));
        var input: []const u8 = undefined;
        var flag: []const u8 = undefined;
        switch (want) {
            .digest => |kind| {
                if (o.get("data") != null) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: {s} signs a digest, not data", .{v.algorithm.wire()}));
                const digest = objectField(o, "digest") orelse return fail(arena, 400, "INVALID_ARGUMENT", "fake: a digest is required");
                if (digest.count() != 1 or !std.mem.eql(u8, digest.keys()[0], @tagName(kind))) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: {s} signs a {s} digest", .{ v.algorithm.wire(), @tagName(kind) }));
                input = (try checkedBytes(arena, digest, @tagName(kind), "")).value orelse return invalidJson(arena);
                if (input.len != kind.length()) return fail(arena, 400, "INVALID_ARGUMENT", "fake: the digest's length is not its algorithm's");
                if (o.get("digestCrc32c")) |crc| if (crcOf(crc) != core.crc32c.hash(input)) return checksumRefused(arena, "digest");
                flag = "verifiedDigestCrc32c";
            },
            .data => {
                if (o.get("digest") != null) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: {s} signs data, not a digest", .{v.algorithm.wire()}));
                input = (try checkedBytes(arena, o, "data", "data")).value orelse return invalidJson(arena);
                if (input.len > validate.max_payload) return fail(arena, 400, "INVALID_ARGUMENT", "fake: data is at most 64 KiB");
                if (try checksumRefusal(arena, o, &.{.{ "data", "data" }})) |r| return r;
                flag = "verifiedDataCrc32c";
            },
        }
        const corruption = f.takeCorruption();
        if (corruption == .refuse_checksum) return checksumRefused(arena, if (want == .data) "data" else "digest");
        const signature = (try f.signWith(arena, v, input)) orelse return notModelled(arena, try arena.print("signing with {s}", .{v.algorithm.wire()}));
        return f.cryptoAnswer(arena, corruption, .{
            .name = name,
            .payload = .{ "signature", signature },
            .flags = &.{.{ flag, o.get(if (want == .data) "dataCrc32c" else "digestCrc32c") != null }},
            .protection_level = v.protection_level,
        });
    }

    fn signWith(f: *FakeKms, arena: Allocator, v: *const Version, input: []const u8) Allocator.Error!?[]const u8 {
        switch (v.material.*) {
            // `sign` checked the digest's length against the algorithm's.
            .p256 => |kp| return try derOf(arena, kp.signPrehashed(input[0..32].*, null) catch return null),
            .p384 => |kp| return try derOf(arena, kp.signPrehashed(input[0..48].*, null) catch return null),
            .secp256k1 => |kp| return try derOf(arena, kp.signPrehashed(input[0..32].*, null) catch return null),
            .ed25519 => |kp| {
                const sig = kp.sign(input, null) catch return null;
                return try arena.dupe(u8, &sig.toBytes());
            },
            inline .mldsa44, .mldsa65, .mldsa87 => |kp| {
                const sig = kp.sign(input, null) catch return null;
                return try arena.dupe(u8, &sig.toBytes());
            },
            .rsa => |bits| {
                var key = core.rsa.parsePem(rsaPem(bits)) catch return null;
                defer key.deinit();
                const hash: core.rsa.Hash = switch (v.algorithm.signInput().?.digest) {
                    .sha256 => .sha256,
                    .sha384 => .sha384,
                    .sha512 => .sha512,
                };
                const out = try arena.alloc(u8, key.len);
                const pss = switch (v.algorithm) {
                    .rsa_sign_pss_2048_sha256, .rsa_sign_pss_3072_sha256, .rsa_sign_pss_4096_sha256, .rsa_sign_pss_4096_sha512 => true,
                    else => false,
                };
                if (pss) {
                    var salt: [64]u8 = undefined;
                    f.io.random(&salt);
                    return key.signPss(hash, input, salt[0..input.len], out) catch null;
                }
                return key.signDigest(hash, input, out) catch null;
            },
            else => return null,
        }
    }

    fn mac(f: *FakeKms, arena: Allocator, k: *Key, v: *Version, name: []const u8, body: []const u8, verify: bool) Allocator.Error!Reply {
        if (k.purpose != .mac) return wrongPurpose(arena, k, if (verify) "macVerify" else "macSign");
        if (v.state != .enabled) return notEnabled(arena, name, v.state);
        const o = (try requestObject(arena, body)) orelse return invalidJson(arena);
        const data = (try checkedBytes(arena, o, "data", "data")).value orelse return invalidJson(arena);
        if (data.len > validate.max_payload) return fail(arena, 400, "INVALID_ARGUMENT", "fake: data is at most 64 KiB");
        if (try checksumRefusal(arena, o, if (verify) &.{ .{ "data", "data" }, .{ "mac", "mac" } } else &.{.{ "data", "data" }})) |r| return r;
        const corruption = f.takeCorruption();
        if (corruption == .refuse_checksum) return checksumRefused(arena, "data");
        const key = v.material.hmac.key[0..v.material.hmac.len];
        var buf: [64]u8 = undefined;
        const computed = macOf(v.algorithm, key, data, &buf);
        if (!verify) return f.cryptoAnswer(arena, corruption, .{
            .name = name,
            .payload = .{ "mac", computed },
            .flags = &.{.{ "verifiedDataCrc32c", o.get("dataCrc32c") != null }},
            .protection_level = v.protection_level,
        });
        const given = (try checkedBytes(arena, o, "mac", "mac")).value orelse return invalidJson(arena);
        const success = std.mem.eql(u8, given, computed);
        const integrity_flag = if (corruption == .success_mismatch) !success else success;
        return f.cryptoAnswer(arena, corruption, .{
            .name = name,
            .flags = &.{
                .{ "success", success },
                .{ "verifiedDataCrc32c", o.get("dataCrc32c") != null },
                .{ "verifiedMacCrc32c", o.get("macCrc32c") != null },
                .{ "verifiedSuccessIntegrity", integrity_flag },
            },
            .protection_level = v.protection_level,
        });
    }

    fn publicKey(f: *FakeKms, arena: Allocator, target: Target, params: []const Param) Allocator.Error!Reply {
        const k = f.keys.get(target.key_name) orelse return notFound(arena, "CryptoKey", target.key_name);
        const v = liveVersion(k, target.version) orelse return notFound(arena, "CryptoKeyVersion", target.version_name);
        if (k.purpose != .asymmetric_sign) return wrongPurpose(arena, k, "getPublicKey");
        if (v.state != .enabled) return notEnabled(arena, target.version_name, v.state);
        const format = paramOf(params, "publicKeyFormat") orelse "PEM";
        const pq = v.algorithm.postQuantum();
        if (pq and !std.mem.eql(u8, format, "NIST_PQC")) return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: Only NIST_PQC format is supported for {s}.", .{v.algorithm.wire()}));
        if (!pq and !std.mem.eql(u8, format, "PEM")) return notModelled(arena, try arena.print("public key format {s}", .{format}));
        const key = (try publicKeyOf(arena, v)) orelse return notModelled(arena, try arena.print("a public key for {s}", .{v.algorithm.wire()}));
        // A public key's request carries no checksum to refuse.
        const corruption = f.takeCorruption();
        var shown = key;
        if (corruption == .flip_payload) {
            const copy = try arena.dupe(u8, key);
            copy[copy.len / 2] ^= 1;
            shown = copy;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePublicKey(&jw, .{
            .name = if (corruption == .wrong_name) try versionName(arena, k, v.id + 1) else target.version_name,
            .algorithm = v.algorithm,
            .protection_level = v.protection_level,
            .format = format,
            .key = shown,
            .crc = core.crc32c.hash(key),
            .pem = !pq,
        }) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn randomBytes(f: *FakeKms, arena: Allocator, body: []const u8) Allocator.Error!Reply {
        const o = (try requestObject(arena, body)) orelse return invalidJson(arena);
        if (!std.mem.eql(u8, stringField(o, "protectionLevel") orelse "", "HSM")) return fail(arena, 400, "INVALID_ARGUMENT", "fake: random bytes come from an HSM");
        const len_value = o.get("lengthBytes") orelse return invalidJson(arena);
        const len = crcOf(len_value) orelse return invalidJson(arena);
        if (len < validate.min_random_bytes or len > validate.max_random_bytes) return fail(arena, 400, "INVALID_ARGUMENT", "fake: lengthBytes is 8 to 1024");
        const corruption = f.takeCorruption();
        const data = try arena.alloc(u8, len);
        f.io.random(data);
        return f.cryptoAnswer(arena, corruption, .{ .payload = .{ "data", data } });
    }

    const Answer = struct {
        name: ?[]const u8 = null,
        /// The bytes field and its value; its checksum is `<field>Crc32c`.
        payload: ?struct { []const u8, []const u8 } = null,
        flags: []const struct { []const u8, bool } = &.{},
        protection_level: ?types.ProtectionLevel = null,
        /// The payload's checksum, when not its bytes': after a corruption.
        payload_crc: ?u32 = null,
    };

    /// A crypto call's answer, with what `corruption` says to get wrong.
    fn cryptoAnswer(f: *FakeKms, arena: Allocator, corruption: ?Corruption, answer: Answer) Allocator.Error!Reply {
        var a = answer;
        if (corruption) |c| switch (c) {
            .wrong_name => if (a.name) |n| {
                const at = std.mem.lastIndexOfScalar(u8, n, '/').?;
                const id = std.fmt.parseInt(u64, n[at + 1 ..], 10) catch 0;
                a.name = try arena.print("{s}/{d}", .{ n[0..at], id + 1 });
            },
            .flip_payload => if (a.payload) |p| if (p[1].len > 0) {
                // The checksum stays the original bytes'.
                a.payload_crc = core.crc32c.hash(p[1]);
                const copy = try arena.dupe(u8, p[1]);
                copy[0] ^= 1;
                a.payload = .{ p[0], copy };
            },
            else => {},
        };
        _ = f;
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeAnswer(&jw, a, corruption) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    // Retired keys and operations.

    fn listRetired(f: *FakeKms, arena: Allocator, target: Target, params: []const Param) Allocator.Error!Reply {
        var found: std.ArrayList(Retired) = .empty;
        for (f.retired.items) |r| if (std.mem.startsWith(u8, r.name, target.location_name) and r.name[target.location_name.len] == '/') try found.append(arena, r);
        const window = pageOf(params, found.items.len) orelse return pageTokenRefusal(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writePage(&jw, "retiredResources", found.items[window.from..window.to], window.next, writeRetired) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    /// A delete's operation: the work done, the answer not, as production
    /// answered; read back, it is done.
    fn startOperation(f: *FakeKms, arena: Allocator, target: Target, retired: ?[]const u8) Allocator.Error!Reply {
        f.operations += 1;
        return .{ .status = 200, .body = try renderOperation(arena, target.location_name, f.operations, retired, false) };
    }

    fn getOperation(f: *FakeKms, arena: Allocator, route_text: []const u8) Allocator.Error!Reply {
        const name = route_text["/v1/".len..];
        const at = std.mem.lastIndexOf(u8, name, "/operations/op-") orelse return notFound(arena, "Operation", name);
        const n = std.fmt.parseInt(usize, name[at + "/operations/op-".len ..], 10) catch return notFound(arena, "Operation", name);
        if (n == 0 or n > f.operations) return notFound(arena, "Operation", name);
        return .{ .status = 200, .body = try renderOperation(arena, name[0..at], n, null, true) };
    }

    // Rendering.

    fn renderKey(f: *const FakeKms, arena: Allocator, k: *const Key) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeKey(f, &jw, k) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeKey(_: *const FakeKms, jw: *Stringify, k: *const Key) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(k.name);
        if (k.primary) |p| {
            try jw.objectField("primary");
            try writeVersion(jw, k, k.versions.items[p - 1]);
        }
        try jw.objectField("purpose");
        try jw.write(k.purpose.wire());
        try jw.objectField("createTime");
        try writeTime(jw, k.create_time);
        if (k.next_rotation) |n| {
            try jw.objectField("nextRotationTime");
            try writeTime(jw, n);
        }
        if (k.rotation_period_s) |p| {
            try jw.objectField("rotationPeriod");
            try jw.print("\"{d}s\"", .{p});
        }
        try jw.objectField("versionTemplate");
        try jw.beginObject();
        try jw.objectField("protectionLevel");
        try jw.write(k.protection_level.wire());
        try jw.objectField("algorithm");
        try jw.write(k.algorithm.wire());
        try jw.endObject();
        if (k.labels.len > 0) {
            try jw.objectField("labels");
            try jw.beginObject();
            for (k.labels) |l| {
                try jw.objectField(l.key);
                try jw.write(l.value);
            }
            try jw.endObject();
        }
        try jw.objectField("destroyScheduledDuration");
        try jw.print("\"{d}s\"", .{k.destroy_delay_s});
        try jw.endObject();
    }

    fn writeKeyPage(f: *const FakeKms, jw: *Stringify, keys: []const *Key, next: ?usize) Stringify.Error!void {
        try jw.beginObject();
        if (keys.len > 0) {
            try jw.objectField("cryptoKeys");
            try jw.beginArray();
            for (keys) |k| try f.writeKey(jw, k);
            try jw.endArray();
        }
        try writeNext(jw, next);
        try jw.endObject();
    }
};

fn writeAnswer(jw: *Stringify, a: FakeKms.Answer, corruption: ?FakeKms.Corruption) Stringify.Error!void {
    try jw.beginObject();
    if (a.name) |n| {
        try jw.objectField("name");
        try jw.write(n);
    }
    if (a.payload) |p| {
        const crc = a.payload_crc orelse core.crc32c.hash(p[1]);
        if (p[1].len > 0) {
            try jw.objectField(p[0]);
            try core.base64.writeJsonString(jw, p[1]);
        }
        var name_buf: [64]u8 = undefined;
        try jw.objectField(std.fmt.bufPrint(&name_buf, "{s}Crc32c", .{p[0]}) catch unreachable);
        try jw.print("\"{d}\"", .{crc});
    }
    for (a.flags) |flag| {
        const dropped = corruption == .drop_verified and std.mem.startsWith(u8, flag[0], "verified");
        if (!flag[1] or dropped) continue;
        try jw.objectField(flag[0]);
        try jw.write(true);
    }
    if (a.protection_level) |p| {
        try jw.objectField("protectionLevel");
        try jw.write(p.wire());
    }
    try jw.endObject();
}

fn derOf(arena: Allocator, sig: anytype) Allocator.Error![]const u8 {
    var buf: [@TypeOf(sig).der_encoded_length_max]u8 = undefined;
    return arena.dupe(u8, sig.toDer(&buf));
}

const PublicKeyAnswer = struct {
    name: []const u8,
    algorithm: types.Algorithm,
    protection_level: types.ProtectionLevel,
    format: []const u8,
    key: []const u8,
    crc: u32,
    /// The key is a PEM, also in `pem` with its checksum.
    pem: bool,
};

fn writePublicKey(jw: *Stringify, a: PublicKeyAnswer) Stringify.Error!void {
    try jw.beginObject();
    if (a.pem) {
        try jw.objectField("pem");
        try jw.write(a.key);
        try jw.objectField("pemCrc32c");
        try jw.print("\"{d}\"", .{a.crc});
    }
    try jw.objectField("algorithm");
    try jw.write(a.algorithm.wire());
    try jw.objectField("name");
    try jw.write(a.name);
    try jw.objectField("protectionLevel");
    try jw.write(a.protection_level.wire());
    try jw.objectField("publicKeyFormat");
    try jw.write(a.format);
    try jw.objectField("publicKey");
    try jw.beginObject();
    try jw.objectField("data");
    try core.base64.writeJsonString(jw, a.key);
    try jw.objectField("crc32cChecksum");
    try jw.print("\"{d}\"", .{a.crc});
    try jw.endObject();
    try jw.endObject();
}

fn rsaPem(bits: u16) []const u8 {
    return switch (bits) {
        2048 => core.rsa.test_key_2048,
        3072 => core.rsa.test_key_3072,
        else => core.rsa.test_key_4096,
    };
}

fn macOf(a: types.Algorithm, key: []const u8, data: []const u8, buf: *[64]u8) []const u8 {
    switch (a) {
        inline .hmac_sha1, .hmac_sha224, .hmac_sha256, .hmac_sha384, .hmac_sha512 => |t| {
            const H = switch (t) {
                .hmac_sha1 => hmac.HmacSha1,
                .hmac_sha224 => hmac.sha2.HmacSha224,
                .hmac_sha256 => hmac.sha2.HmacSha256,
                .hmac_sha384 => hmac.sha2.HmacSha384,
                else => hmac.sha2.HmacSha512,
            };
            H.create(buf[0..H.mac_length], data, key);
            return buf[0..H.mac_length];
        },
        else => unreachable,
    }
}

/// A classical version's public key as a PEM SubjectPublicKeyInfo, or a
/// post-quantum one's NIST encoding; null for one the fake does not model.
fn publicKeyOf(arena: Allocator, v: *const FakeKms.Version) Allocator.Error!?[]const u8 {
    var der_buf: [core.rsa.max_spki_len]u8 = undefined;
    const der: []const u8 = switch (v.material.*) {
        .p256 => |kp| ecSpki(&der_buf, &.{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 }, &kp.public_key.toUncompressedSec1()),
        .p384 => |kp| ecSpki(&der_buf, &.{ 0x2b, 0x81, 0x04, 0x00, 0x22 }, &kp.public_key.toUncompressedSec1()),
        .secp256k1 => |kp| ecSpki(&der_buf, &.{ 0x2b, 0x81, 0x04, 0x00, 0x0a }, &kp.public_key.toUncompressedSec1()),
        .ed25519 => |kp| ed: {
            const prefix = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
            @memcpy(der_buf[0..prefix.len], &prefix);
            @memcpy(der_buf[prefix.len..][0..32], &kp.public_key.toBytes());
            break :ed der_buf[0 .. prefix.len + 32];
        },
        .rsa => |bits| rsa: {
            var key = core.rsa.parsePem(rsaPem(bits)) catch return null;
            defer key.deinit();
            break :rsa key.publicKey().writeSpki(&der_buf);
        },
        inline .mldsa44, .mldsa65, .mldsa87 => |kp| return try arena.dupe(u8, &kp.public_key.toBytes()),
        else => return null,
    };
    return try pemOf(arena, der);
}

/// SEQUENCE { SEQUENCE { ecPublicKey, curve }, BIT STRING point }, for a
/// curve whose OID and point are short enough for one-byte lengths.
fn ecSpki(buf: []u8, curve: []const u8, point: []const u8) []const u8 {
    const ec_oid = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
    const alg_len = 2 + ec_oid.len + 2 + curve.len;
    const bits_len = 1 + point.len;
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(&.{ 0x30, @intCast(2 + alg_len + 2 + bits_len), 0x30, @intCast(alg_len), 0x06, ec_oid.len }) catch unreachable;
    w.writeAll(&ec_oid) catch unreachable;
    w.writeAll(&.{ 0x06, @intCast(curve.len) }) catch unreachable;
    w.writeAll(curve) catch unreachable;
    w.writeAll(&.{ 0x03, @intCast(bits_len), 0x00 }) catch unreachable;
    w.writeAll(point) catch unreachable;
    return w.buffered();
}

fn pemOf(arena: Allocator, der: []const u8) Allocator.Error![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, encoder.calcSize(der.len));
    _ = encoder.encode(b64, der);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("-----BEGIN PUBLIC KEY-----\n") catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < b64.len) : (i += 64) {
        w.writeAll(b64[i..@min(b64.len, i + 64)]) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;
    }
    w.writeAll("-----END PUBLIC KEY-----\n") catch return error.OutOfMemory;
    return out.written();
}

fn requestObject(arena: Allocator, body: []const u8) Allocator.Error!?std.json.ObjectMap {
    const root = parseJson(arena, body) orelse return null;
    return if (root == .object) root.object else null;
}

/// A bytes field of a request, "" when absent; its value null when it is
/// not base64.
fn checkedBytes(arena: Allocator, o: std.json.ObjectMap, field: []const u8, _: []const u8) Allocator.Error!struct { value: ?[]const u8 } {
    const v = o.get(field) orelse return .{ .value = "" };
    if (v != .string) return .{ .value = null };
    const bytes = core.base64.decode(arena, v.string) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase64 => return .{ .value = null },
    };
    return .{ .value = bytes };
}

/// A checksum, or a length: a string or a number of digits.
fn crcOf(v: JsonValue) ?u64 {
    const text = switch (v) {
        .string, .number_string => |s| s,
        else => return null,
    };
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// The refusal production sends when a request checksum does not match its
/// bytes, for the first of `fields` (JSON name, proto name) whose does not.
fn checksumRefusal(arena: Allocator, o: std.json.ObjectMap, fields: []const struct { []const u8, []const u8 }) Allocator.Error!?FakeKms.Reply {
    for (fields) |f| {
        var name_buf: [64]u8 = undefined;
        const crc_field = std.fmt.bufPrint(&name_buf, "{s}Crc32c", .{f[0]}) catch unreachable;
        const crc = o.get(crc_field) orelse continue;
        const bytes = (try checkedBytes(arena, o, f[0], f[1])).value orelse continue;
        if (crcOf(crc) != core.crc32c.hash(bytes)) return try checksumRefused(arena, f[1]);
    }
    return null;
}

/// "The checksum in field plaintext_crc32c did not match the data in
/// field plaintext.", as Google's data-integrity guide quotes it.
fn checksumRefused(arena: Allocator, field: []const u8) Allocator.Error!FakeKms.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("The checksum in field {s}_crc32c did not match the data in field {s}.", .{ field, field }));
}

fn wrongPurpose(arena: Allocator, k: *const FakeKms.Key, call: []const u8) Allocator.Error!FakeKms.Reply {
    return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("fake: {s} is not for a key of purpose {s}: {s}", .{ call, k.purpose.wire(), k.name }));
}

const Target = struct {
    kind: Kind,
    project: []const u8,
    /// `projects/P/locations/L`.
    location_name: []const u8,
    ring_name: []const u8 = "",
    key_name: []const u8 = "",
    version_name: []const u8 = "",
    version: u64 = 0,
    /// What follows a `:`, such as "destroy"; "" for none.
    method: []const u8 = "",

    const Kind = enum { locations, location, key_rings, key_ring, keys, key, versions, version, public_key, retired, operation };
};

/// The resource a path names, from `/v1/projects/P/locations...`; null for
/// a path no binding of the API matches, which production answers with an
/// HTML 404.
fn parseTarget(path: []const u8) ?Target {
    const prefix = "/v1/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const full = path[prefix.len..];
    // A method follows the last segment's `:`; a project id may hold one.
    const colon = std.mem.indexOfScalarPos(u8, full, std.mem.lastIndexOfScalar(u8, full, '/') orelse 0, ':');
    const name = full[0 .. colon orelse full.len];
    const method = if (colon) |c| full[c + 1 ..] else "";
    var parts: [12][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |p| {
        if (n == parts.len or p.len == 0) return null;
        parts[n] = p;
        n += 1;
    }
    if (n < 3 or !std.mem.eql(u8, parts[0], "projects") or !std.mem.eql(u8, parts[2], "locations")) return null;
    var t: Target = .{ .kind = .locations, .project = parts[1], .location_name = "", .method = method };
    if (n == 3) return if (method.len == 0) t else null;
    t.location_name = full[0 .. "projects/".len + parts[1].len + "/locations/".len + parts[3].len];
    if (n == 4) return if (method.len > 0) t: {
        var loc = t;
        loc.kind = .location;
        break :t loc;
    } else null;
    if (n == 5 and std.mem.eql(u8, parts[4], "keyRings")) return withKind(t, .key_rings);
    if (n == 5 and std.mem.eql(u8, parts[4], "retiredResources")) return withKind(t, .retired);
    if (n == 6 and std.mem.eql(u8, parts[4], "operations")) return withKind(t, .operation);
    if (!std.mem.eql(u8, parts[4], "keyRings")) return null;
    t.ring_name = name[0 .. t.location_name.len + "/keyRings/".len + parts[5].len];
    if (n == 6) return withKind(t, .key_ring);
    if (!std.mem.eql(u8, parts[6], "cryptoKeys")) return null;
    if (n == 7) return withKind(t, .keys);
    t.key_name = name[0 .. t.ring_name.len + "/cryptoKeys/".len + parts[7].len];
    if (n == 8) return withKind(t, .key);
    if (!std.mem.eql(u8, parts[8], "cryptoKeyVersions")) return null;
    if (n == 9) return withKind(t, .versions);
    t.version = std.fmt.parseInt(u64, parts[9], 10) catch 0;
    if (n == 11 and std.mem.eql(u8, parts[10], "publicKey")) {
        t.version_name = name[0 .. name.len - "/publicKey".len];
        return withKind(t, .public_key);
    }
    if (n != 10) return null;
    t.version_name = name;
    return withKind(t, .version);
}

fn withKind(t: Target, kind: Target.Kind) ?Target {
    var out = t;
    out.kind = kind;
    // Only a key and a version take methods, and create calls none.
    if (out.method.len > 0 and kind != .key and kind != .version and kind != .key_ring) return null;
    return out;
}

fn versionName(arena: Allocator, k: *const FakeKms.Key, id: u64) Allocator.Error![]const u8 {
    return arena.print("{s}/cryptoKeyVersions/{d}", .{ k.name, id });
}

fn renderRing(arena: Allocator, r: FakeKms.Ring) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeRing(&jw, r) catch return error.OutOfMemory;
    return out.written();
}

fn writeRing(jw: *Stringify, r: FakeKms.Ring) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(r.name);
    try jw.objectField("createTime");
    try writeTime(jw, r.create_time);
    try jw.endObject();
}

fn renderVersion(arena: Allocator, k: *const FakeKms.Key, v: FakeKms.Version) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeVersion(&jw, k, v) catch return error.OutOfMemory;
    return out.written();
}

fn writeVersion(jw: *Stringify, k: *const FakeKms.Key, v: FakeKms.Version) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.print("\"{s}/cryptoKeyVersions/{d}\"", .{ k.name, v.id });
    try jw.objectField("state");
    try jw.write(v.state.wire());
    try jw.objectField("createTime");
    try writeTime(jw, v.create_time);
    try jw.objectField("protectionLevel");
    try jw.write(v.protection_level.wire());
    try jw.objectField("algorithm");
    try jw.write(v.algorithm.wire());
    if (v.state != .pending_generation) {
        try jw.objectField("generateTime");
        try writeTime(jw, v.generate_time);
    }
    if (v.destroy_time) |t| {
        try jw.objectField("destroyTime");
        try writeTime(jw, t);
    }
    if (v.destroy_event_time) |t| {
        try jw.objectField("destroyEventTime");
        try writeTime(jw, t);
    }
    try jw.endObject();
}

fn writeVersionPage(jw: *Stringify, k: *const FakeKms.Key, versions: []const FakeKms.Version, next: ?usize) Stringify.Error!void {
    try jw.beginObject();
    if (versions.len > 0) {
        try jw.objectField("cryptoKeyVersions");
        try jw.beginArray();
        for (versions) |v| try writeVersion(jw, k, v);
        try jw.endArray();
    }
    try writeNext(jw, next);
    try jw.endObject();
}

fn writeRetired(jw: *Stringify, r: FakeKms.Retired) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(r.name);
    try jw.objectField("originalResource");
    try jw.write(r.original);
    try jw.objectField("resourceType");
    try jw.write("CryptoKey");
    try jw.objectField("deleteTime");
    try writeTime(jw, r.delete_time);
    try jw.endObject();
}

fn renderOperation(arena: Allocator, location_name: []const u8, n: usize, retired: ?[]const u8, done: bool) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeOperation(&jw, location_name, n, retired, done) catch return error.OutOfMemory;
    return out.written();
}

fn writeOperation(jw: *Stringify, location_name: []const u8, n: usize, retired: ?[]const u8, done: bool) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.print("\"{s}/operations/op-{d}\"", .{ location_name, n });
    if (retired) |r| {
        try jw.objectField("metadata");
        try jw.beginObject();
        try jw.objectField("@type");
        try jw.write("type.googleapis.com/google.cloud.kms.v1.DeleteCryptoKeyMetadata");
        try jw.objectField("retiredResource");
        try jw.write(r);
        try jw.endObject();
    }
    if (!done) return jw.endObject();
    try jw.objectField("done");
    try jw.write(true);
    try jw.objectField("response");
    try jw.beginObject();
    try jw.objectField("@type");
    try jw.write("type.googleapis.com/google.protobuf.Empty");
    try jw.endObject();
    try jw.endObject();
}

fn writePage(jw: *Stringify, list_name: []const u8, items: anytype, next: ?usize, comptime each: anytype) Stringify.Error!void {
    try jw.beginObject();
    if (items.len > 0) {
        try jw.objectField(list_name);
        try jw.beginArray();
        for (items) |item| try each(jw, item);
        try jw.endArray();
    }
    try writeNext(jw, next);
    try jw.endObject();
}

fn writeNext(jw: *Stringify, next: ?usize) Stringify.Error!void {
    if (next) |n| {
        try jw.objectField("nextPageToken");
        try jw.print("\"p{d}\"", .{n});
    }
}

fn writeTime(jw: *Stringify, ns: i96) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.write(core.timestamp.format(&buf, .{ .nanoseconds = ns }));
}

// Request parsing.

fn pathOf(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    return rest[slash..];
}

const Param = struct { name: []const u8, value: []const u8 };

fn parseParams(arena: Allocator, query: []const u8) Allocator.Error!?[]const Param {
    var list: std.ArrayList(Param) = .empty;
    if (query.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
        try list.append(arena, .{ .name = try decoded(arena, pair[0..eq]), .value = try decoded(arena, pair[eq + 1 ..]) });
    }
    return list.items;
}

fn decoded(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const copy = try arena.dupe(u8, text);
    return std.Uri.percentDecodeInPlace(copy);
}

fn paramOf(params: []const Param, name: []const u8) ?[]const u8 {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

const Window = struct { from: usize, to: usize, next: ?usize };

/// The page a request asks for: `pageSize` (0 for the most) from the
/// position its token names.
fn pageOf(params: []const Param, total: usize) ?Window {
    var size: usize = FakeKms.max_page;
    if (paramOf(params, "pageSize")) |text| {
        const n = std.fmt.parseInt(usize, text, 10) catch return null;
        if (n != 0) size = @min(n, FakeKms.max_page);
    }
    var from: usize = 0;
    if (paramOf(params, "pageToken")) |t| {
        if (!std.mem.startsWith(u8, t, "p")) return null;
        from = std.fmt.parseInt(usize, t[1..], 10) catch return null;
        if (from > total) return null;
    }
    const to = @min(total, from + size);
    return .{ .from = from, .to = to, .next = if (to < total) to else null };
}

fn parseJson(arena: Allocator, body: []const u8) ?JsonValue {
    return std.json.parseFromSliceLeaky(JsonValue, arena, body, .{ .parse_numbers = false }) catch null;
}

fn stringField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn objectField(o: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const v = o.get(name) orelse return null;
    return if (v == .object) v.object else null;
}

/// The `labels` object, copied into `store`; null when it is not an
/// object of strings.
fn storedLabels(store: Allocator, o: std.json.ObjectMap) Allocator.Error!?[]const types.Label {
    const v = o.get("labels") orelse return &.{};
    if (v != .object) return null;
    const out = try store.alloc(types.Label, v.object.count());
    for (v.object.keys(), v.object.values(), out) |k, val, *l| {
        if (val != .string) return null;
        l.* = .{ .key = try store.dupe(u8, k), .value = try store.dupe(u8, val.string) };
    }
    return out;
}

/// Whole seconds of a Duration such as "86400s"; null for anything else.
fn durationSeconds(text: []const u8) ?u64 {
    const d = core.duration.parse(text) catch return null;
    if (d.nanoseconds < 0 or @rem(d.nanoseconds, std.time.ns_per_s) != 0) return null;
    return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_s));
}

const RotationOf = union(enum) {
    set: struct { period_s: ?u64, next: i96 },
    refusal: FakeKms.Reply,
};

/// The rotation a key's body sets, a refusal of one that breaks the rules,
/// or null for none.
fn rotationOf(arena: Allocator, o: std.json.ObjectMap) Allocator.Error!?RotationOf {
    const period_text = stringField(o, "rotationPeriod");
    const next_text = stringField(o, "nextRotationTime");
    if (period_text == null and next_text == null) return null;
    const next = core.timestamp.parse(next_text orelse return .{ .refusal = try fail(arena, 400, "INVALID_ARGUMENT", "fake: a rotation period needs a next rotation time") }) catch
        return .{ .refusal = try fail(arena, 400, "INVALID_ARGUMENT", "fake: nextRotationTime is a timestamp") };
    var period: ?u64 = null;
    if (period_text) |p| {
        const s = durationSeconds(p) orelse return .{ .refusal = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid rotation period.") };
        if (s < validate.min_rotation_s or s > validate.max_rotation_s) return .{ .refusal = try fail(arena, 400, "INVALID_ARGUMENT", "Invalid rotation period.") };
        period = s;
    }
    return .{ .set = .{ .period_s = period, .next = next.nanoseconds } };
}

// Answers.

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakeKms.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

/// A version that is not enabled, used: production's words and its
/// `PreconditionFailure`.
pub fn notEnabled(arena: Allocator, version_name: []const u8, state: types.State) Allocator.Error!FakeKms.Reply {
    const violation = switch (state) {
        .pending_generation => "KEY_PENDING_GENERATION",
        .disabled => "KEY_DISABLED",
        .destroy_scheduled => "KEY_DESTROY_SCHEDULED",
        .destroyed => "KEY_DESTROYED",
        else => "KEY_DISABLED",
    };
    const message = try arena.print("{s} is not enabled, current state is: {s}.", .{ version_name, state.wire() });
    return .{ .status = 400, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = 400,
        .message = message,
        .status = "FAILED_PRECONDITION",
        .details = .{.{
            .@"@type" = "type.googleapis.com/google.rpc.PreconditionFailure",
            .violations = .{.{ .type = violation, .subject = version_name }},
        }},
    } }, .{}) };
}

/// A state change the machine forbids, in production's words.
fn transitionRefused(arena: Allocator, version_name: []const u8, state: types.State) Allocator.Error!FakeKms.Reply {
    return fail(arena, 400, "FAILED_PRECONDITION", try arena.print("The request cannot be fulfilled. Resource {s} has value {s} in field crypto_key_version.state.", .{ version_name, state.wire() }));
}

/// A create under a deleted key's id, in production's words.
fn retiredRefusal(arena: Allocator, name: []const u8, retired: []const u8) Allocator.Error!FakeKms.Reply {
    const message = try arena.print("CryptoKey {s} has already been deleted and has the following RetiredResource name: {s}.", .{ name, retired });
    return .{ .status = 400, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = 400,
        .message = message,
        .status = "INVALID_ARGUMENT",
        .details = .{.{
            .@"@type" = "type.googleapis.com/google.rpc.ErrorInfo",
            .reason = "RESOURCE_DELETED",
            .domain = "cloudkms.googleapis.com",
            .metadata = .{ .resource_name = name, .retired_resource_name = retired },
        }},
    } }, .{}) };
}

fn notFound(arena: Allocator, kind: []const u8, name: []const u8) Allocator.Error!FakeKms.Reply {
    return fail(arena, 404, "NOT_FOUND", try arena.print("fake: {s} {s} not found.", .{ kind, name }));
}

fn invalidId(arena: Allocator, field: []const u8, id: []const u8) Allocator.Error!FakeKms.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", try arena.print("fake: {s} \"{s}\" does not match [a-zA-Z0-9_-]{{1,63}}", .{ field, id }));
}

/// What production answered a path no binding matched: an HTML page.
fn htmlNotFound(arena: Allocator) Allocator.Error!FakeKms.Reply {
    _ = arena;
    return .{ .status = 404, .headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=UTF-8" }}, .body = "<!DOCTYPE html>\n<html lang=en><title>Error 404 (Not Found)!!1</title><p>The requested URL was not found on this server.</html>" };
}

/// The fake's own words: production was not asked about a body that is
/// not JSON or not of the API's shape.
fn invalidJson(arena: Allocator) Allocator.Error!FakeKms.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "Invalid JSON payload received.");
}

fn pageTokenRefusal(arena: Allocator) Allocator.Error!FakeKms.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "fake: the page token is not valid.");
}

fn notModelled(arena: Allocator, what: []const u8) Allocator.Error!FakeKms.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try arena.print("fake: {s} is not modelled yet", .{what}));
}

fn refusal(arena: Allocator, status: u16) Allocator.Error!FakeKms.Reply {
    const name = switch (status) {
        400 => "INVALID_ARGUMENT",
        401 => "UNAUTHENTICATED",
        403 => "PERMISSION_DENIED",
        404 => "NOT_FOUND",
        409 => "ALREADY_EXISTS",
        429 => "RESOURCE_EXHAUSTED",
        500 => "INTERNAL",
        503 => "UNAVAILABLE",
        504 => "DEADLINE_EXCEEDED",
        else => "UNKNOWN",
    };
    return fail(arena, status, name, "fake: refused as the test asked");
}

test "parseTarget: every resource the API binds, and nothing else" {
    const ring = parseTarget("/v1/projects/p/locations/l/keyRings/r").?;
    try std.testing.expectEqual(Target.Kind.key_ring, ring.kind);
    try std.testing.expectEqualStrings("projects/p/locations/l", ring.location_name);
    try std.testing.expectEqualStrings("projects/p/locations/l/keyRings/r", ring.ring_name);
    const version = parseTarget("/v1/projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/3:destroy").?;
    try std.testing.expectEqual(Target.Kind.version, version.kind);
    try std.testing.expectEqualStrings("projects/p/locations/l/keyRings/r/cryptoKeys/k", version.key_name);
    try std.testing.expectEqualStrings("projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/3", version.version_name);
    try std.testing.expectEqual(3, version.version);
    try std.testing.expectEqualStrings("destroy", version.method);
    try std.testing.expectEqual(Target.Kind.locations, parseTarget("/v1/projects/p/locations").?.kind);
    try std.testing.expectEqual(Target.Kind.retired, parseTarget("/v1/projects/p/locations/l/retiredResources").?.kind);
    try std.testing.expectEqual(Target.Kind.operation, parseTarget("/v1/projects/p/locations/l/operations/op-1").?.kind);
    try std.testing.expectEqual(Target.Kind.versions, parseTarget("/v1/projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions").?.kind);
    const domain = parseTarget("/v1/projects/example.com:p/locations/l/keyRings/r/cryptoKeys/k:encrypt").?;
    try std.testing.expectEqualStrings("example.com:p", domain.project);
    try std.testing.expectEqualStrings("encrypt", domain.method);
    try std.testing.expectEqualStrings("", parseTarget("/v1/projects/example.com:p/locations/l/keyRings/r").?.method);
    for ([_][]const u8{
        "/v2/projects/p/locations/l/keyRings/r",
        "/v1/projects/p/locations/l",
        "/v1/projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/3/x",
        "/v1/projects/p/locations/l/keyRings//cryptoKeys/k",
        "/v1/projects/p/locations/l/keyRings:list",
        "/v1/projects/p/locations/l/somethingElse",
    }) |bad| try std.testing.expectEqual(null, parseTarget(bad));
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Rig = test_util.Rig;
const day: i64 = std.time.s_per_day;

test "a symmetric key's whole life: versions made, rotated by hand, destroyed, restored, deleted, its id retired" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{});
    defer r.deinit();
    const ring = r.client.keyRing("zigps-r");
    var ring_info = try ring.create();
    ring_info.deinit();
    const key = ring.key("k");
    var info = try key.create(.{ .purpose = .encrypt_decrypt, .destroy_delay_s = 86_400, .labels = &.{.{ .key = "team", .value = "a" }} });
    try testing.expectEqual(1, info.value.primary.?.id);
    try testing.expectEqual(types.State.enabled, info.value.primary.?.state);
    try testing.expectEqual(86_400, info.value.destroy_delay_s.?);
    try testing.expectEqualStrings("team", info.value.labels[0].key);
    info.deinit();
    try testing.expectEqual(1, r.fake.billedVersions());

    var v2 = try key.createVersion();
    try testing.expectEqual(2, v2.value.id);
    v2.deinit();
    var primary = try key.setPrimary(2);
    try testing.expectEqual(2, primary.value.primary.?.id);
    primary.deinit();

    const old = key.version(1);
    var d = try old.disable();
    d.deinit();
    var scheduled = try old.destroy();
    try testing.expectEqual(types.State.destroy_scheduled, scheduled.value.state);
    try testing.expectEqual(test_util.start_ns + day * std.time.ns_per_s, scheduled.value.destroy_time.?.nanoseconds);
    scheduled.deinit();
    var restored = try old.restore();
    try testing.expectEqual(types.State.disabled, restored.value.state);
    try testing.expectEqual(null, restored.value.destroy_time);
    restored.deinit();
    var again = try old.destroy();
    again.deinit();
    // Not destroyed yet: it cannot be deleted, and is still billed.
    try testing.expectError(error.FailedPrecondition, old.delete());
    try testing.expectEqual(2, r.fake.billedVersions());
    r.advance(day);
    var gone = try old.get();
    try testing.expectEqual(types.State.destroyed, gone.value.state);
    try testing.expectEqual(test_util.start_ns + day * std.time.ns_per_s, gone.value.destroy_event_time.?.nanoseconds);
    gone.deinit();
    try testing.expectEqual(1, r.fake.billedVersions());
    try old.delete();
    try testing.expectError(error.NotFound, old.get());

    // The key keeps version 2, so it cannot go yet, nor its ring.
    try testing.expectError(error.FailedPrecondition, key.delete());
    try testing.expectError(error.FailedPrecondition, ring.delete());
    var listed = try key.listVersions(.{});
    try testing.expectEqual(1, listed.value.versions.len);
    try testing.expectEqual(2, listed.value.versions[0].id);
    listed.deinit();
    var last = try key.version(2).destroy();
    last.deinit();
    r.advance(day);
    try key.version(2).delete();
    try key.delete();
    try testing.expectError(error.NotFound, key.get());

    // Its id is retired for good; the ring's is free.
    var retired = try r.client.listRetiredKeys(.{});
    try testing.expectEqualStrings("projects/my-project/locations/us-central1/keyRings/zigps-r/cryptoKeys/k", retired.value.retired_keys[0].original_name);
    retired.deinit();
    try testing.expectError(error.AlreadyExists, key.create(.{ .purpose = .encrypt_decrypt }));
    try ring.delete();
    try testing.expectError(error.NotFound, ring.get());
    var reborn = try ring.create();
    reborn.deinit();
    try testing.expectEqual(0, r.fake.billedVersions());
}

test "an asymmetric version is pending for the fake's delay, and a version-less key can go at once" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{ .fake = .{ .generation_delay_ms = 2500 } });
    defer r.deinit();
    const ring = r.client.keyRing("r");
    var made = try ring.create();
    made.deinit();
    const key = ring.key("sign");
    var info = try key.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256 });
    try testing.expectEqual(null, info.value.primary);
    info.deinit();
    var v = try key.version(1).get();
    try testing.expectEqual(types.State.pending_generation, v.value.state);
    try testing.expectEqual(null, v.value.generate_time);
    v.deinit();
    // Pending: no state change yet.
    try testing.expectError(error.FailedPrecondition, key.version(1).disable());
    r.advance(3);
    var ready = try key.version(1).get();
    try testing.expectEqual(types.State.enabled, ready.value.state);
    try testing.expectEqual(types.Algorithm.ec_sign_p256_sha256, ready.value.algorithm);
    ready.deinit();
    // Signing keys have no primary to set.
    try testing.expectError(error.InvalidArgument, key.setPrimary(1));

    const bare = ring.key("bare");
    var b = try bare.create(.{ .purpose = .mac, .algorithm = .hmac_sha256, .first_version = false });
    b.deinit();
    try bare.delete();
}

test "automatic rotation makes a version and makes it primary, on the clock, until turned off" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{});
    defer r.deinit();
    const ring = r.client.keyRing("r");
    var made = try ring.create();
    made.deinit();
    const key = ring.key("k");
    const first: std.Io.Timestamp = .{ .nanoseconds = test_util.start_ns + std.time.ns_per_hour };
    var info = try key.create(.{ .purpose = .encrypt_decrypt, .rotation = .{ .period_s = 86_400, .next = first } });
    try testing.expectEqual(86_400, info.value.rotation_period_s.?);
    info.deinit();
    r.advance(3600);
    var rotated = try key.get();
    try testing.expectEqual(2, rotated.value.primary.?.id);
    try testing.expectEqual(first.nanoseconds + day * std.time.ns_per_s, rotated.value.next_rotation.?.nanoseconds);
    rotated.deinit();
    r.advance(2 * day);
    var twice = try key.get();
    try testing.expectEqual(4, twice.value.primary.?.id);
    twice.deinit();
    // A key with rotation scheduled cannot be deleted; turned off, it can,
    // once its versions are gone.
    var off = try key.update(.{ .rotation = .clear });
    try testing.expectEqual(null, off.value.next_rotation);
    try testing.expectEqual(null, off.value.rotation_period_s);
    off.deinit();
    r.advance(10 * day);
    var still = try key.get();
    try testing.expectEqual(4, still.value.primary.?.id);
    still.deinit();
}

test "updates: labels replaced and cleared, the template's algorithm, refusals of another purpose's" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{});
    defer r.deinit();
    const ring = r.client.keyRing("r");
    var made = try ring.create();
    made.deinit();
    const key = ring.key("s");
    var info = try key.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256, .labels = &.{.{ .key = "a", .value = "1" }} });
    info.deinit();
    var relabelled = try key.update(.{ .labels = .{ .set = &.{ .{ .key = "b", .value = "2" }, .{ .key = "c", .value = "" } } }, .algorithm = .ec_sign_p384_sha384 });
    try testing.expectEqual(2, relabelled.value.labels.len);
    try testing.expectEqualStrings("b", relabelled.value.labels[0].key);
    try testing.expectEqual(types.Algorithm.ec_sign_p384_sha384, relabelled.value.algorithm);
    relabelled.deinit();
    var v2 = try key.createVersion();
    try testing.expectEqual(types.Algorithm.ec_sign_p384_sha384, v2.value.algorithm);
    v2.deinit();
    var cleared = try key.update(.{ .labels = .clear });
    try testing.expectEqual(0, cleared.value.labels.len);
    cleared.deinit();
    try testing.expectError(error.InvalidArgument, key.update(.{ .algorithm = .hmac_sha256 }));
    try testing.expectError(error.InvalidArgument, key.update(.{ .rotation = .{ .set = .{ .period_s = 86_400, .next = .{ .nanoseconds = test_util.start_ns } } } }));
}

test "the fake refuses what production would: missing rings, state changes the machine forbids, a key of the wrong algorithm" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{});
    defer r.deinit();
    const ring = r.client.keyRing("r");
    try testing.expectError(error.NotFound, ring.key("k").create(.{ .purpose = .encrypt_decrypt }));
    var made = try ring.create();
    made.deinit();
    try testing.expectError(error.AlreadyExists, ring.create());
    const key = ring.key("k");
    var info = try key.create(.{ .purpose = .encrypt_decrypt });
    info.deinit();
    // The client checks first; the fake refuses the same when sent raw.
    try testing.expectError(error.FailedPrecondition, key.version(1).restore());
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "has value ENABLED in field crypto_key_version.state") != null);
    try testing.expectError(error.NotFound, key.version(9).get());
    try testing.expectError(error.NotFound, key.setPrimary(9));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = [_]struct { tp.Method, []const u8, ?[]const u8, u16 }{
        .{ .POST, "/keyRings/r/cryptoKeys?cryptoKeyId=x", "{\"purpose\":\"ASYMMETRIC_SIGN\",\"versionTemplate\":{\"algorithm\":\"HMAC_SHA256\"}}", 400 },
        .{ .POST, "/keyRings/r/cryptoKeys?cryptoKeyId=x", "{\"purpose\":\"MAC\"}", 400 },
        .{ .POST, "/keyRings/r/cryptoKeys?cryptoKeyId=x", "{\"purpose\":\"ENCRYPT_DECRYPT\",\"destroyScheduledDuration\":\"3600s\"}", 400 },
        .{ .POST, "/keyRings/r/cryptoKeys?cryptoKeyId=x", "{\"purpose\":\"ENCRYPT_DECRYPT\",\"rotationPeriod\":\"60s\",\"nextRotationTime\":\"2026-10-19T00:00:00Z\"}", 400 },
        .{ .POST, "/keyRings/r/cryptoKeys?cryptoKeyId=x", "{\"purpose\":\"ENCRYPT_DECRYPT\",\"rotationPeriod\":\"86400s\"}", 400 },
        .{ .POST, "/keyRings/r/cryptoKeys?cryptoKeyId=x.y", "{\"purpose\":\"ENCRYPT_DECRYPT\"}", 400 },
        .{ .POST, "/keyRings?keyRingId=", "{}", 400 },
        .{ .POST, "/keyRings/r/cryptoKeys?cryptoKeyId=x", "not json", 400 },
        .{ .PATCH, "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1?updateMask=state", "{\"state\":\"DESTROYED\"}", 400 },
        .{ .PATCH, "/keyRings/r/cryptoKeys/k", "{}", 400 },
        .{ .GET, "/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1:decrypt", null, 404 },
        .{ .GET, "/keyRings?filter=x", null, 501 },
        .{ .GET, "/keyRings?pageToken=zzz", null, 400 },
    };
    for (raw) |case| {
        const reply = try r.fake.serve(.{ .method = case[0], .url = try std.mem.concat(a, u8, &.{ test_util.base, case[1] }), .bearer = "t", .body = case[2] }, a);
        testing.expectEqual(case[3], reply.status) catch |err| {
            std.debug.print("{s} {s}: {s}\n", .{ @tagName(case[0]), case[1], reply.body });
            return err;
        };
    }
    // A request without credentials is refused before anything else.
    const unauthenticated = try r.fake.serve(.{ .method = .GET, .url = test_util.base ++ "/keyRings" }, a);
    try testing.expectEqual(401, unauthenticated.status);
}

test "lists come a page at a time, and every key ring in the location" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{});
    defer r.deinit();
    const ids = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (ids) |id| {
        var made = try r.client.keyRing(id).create();
        made.deinit();
    }
    var seen: usize = 0;
    var token: ?[]const u8 = null;
    var pages: [4]?test_util.Owned(types.KeyRingPage) = .{ null, null, null, null };
    defer for (&pages) |*p| if (p.*) |*page| page.deinit();
    for (&pages) |*slot| {
        slot.* = try r.client.listKeyRings(.{ .page_size = 2, .page_token = token });
        seen += slot.*.?.value.key_rings.len;
        token = slot.*.?.value.next_page_token;
        if (token == null) break;
    }
    try testing.expectEqual(5, seen);
    try testing.expectEqual(null, token);
    var locations = try r.client.listLocations(.{});
    defer locations.deinit();
    try testing.expect(locations.value.locations.len > 1);
}

test "faults: a create whose answer is lost is read back, and one dropped before it reached is sent again" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{});
    defer r.deinit();
    const ring = r.client.keyRing("r");
    r.fake.loseNext(1, 503);
    var made = try ring.create();
    made.deinit();
    r.fake.dropNext(1);
    var key = try ring.key("k").create(.{ .purpose = .encrypt_decrypt });
    key.deinit();
    r.fake.loseNext(1, 503);
    var destroyed = try ring.key("k").version(1).destroy();
    try testing.expectEqual(types.State.destroy_scheduled, destroyed.value.state);
    destroyed.deinit();
    // A version made once, not twice, though its answer was lost.
    r.fake.loseNext(1, 503);
    try testing.expectError(error.Unavailable, ring.key("k").createVersion());
    try testing.expect(r.fake.version("projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k", 2) != null);
    try testing.expectEqual(null, r.fake.version("projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/k", 3));
    r.fake.refuseNext(1, 429);
    var after = try ring.key("k").get();
    after.deinit();
}

test "routes no client call takes: operations read back, a disabled new version, methods the fake does not serve" {
    var r: Rig = undefined;
    try r.init(testing.allocator, .{});
    defer r.deinit();
    var made = try r.client.keyRing("r").create();
    made.deinit();
    var key = try r.client.keyRing("r").key("k").create(.{ .purpose = .encrypt_decrypt, .first_version = false });
    key.deinit();
    try r.client.keyRing("r").key("k").delete();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loc = "https://cloudkms.googleapis.com/v1/projects/my-project/locations/us-central1";
    const cases = [_]struct { tp.Method, []const u8, ?[]const u8, u16, []const u8 }{
        .{ .GET, loc ++ "/operations/op-1", null, 200, "\"done\":true" },
        .{ .GET, loc ++ "/operations/op-2", null, 404, "not found" },
        .{ .GET, loc ++ "/operations/op-x", null, 404, "not found" },
        .{ .GET, loc ++ "/operations/other", null, 404, "not found" },
        .{ .POST, loc ++ "/operations/op-1", "{}", 404, "Error 404" },
        .{ .POST, loc ++ "/keyRings/r/cryptoKeys?cryptoKeyId=k2", "{\"purpose\":\"ENCRYPT_DECRYPT\"}", 200, "\"primary\"" },
        .{ .POST, loc ++ "/keyRings/r/cryptoKeys/k2/cryptoKeyVersions", "{\"state\":\"DISABLED\"}", 200, "\"state\":\"DISABLED\"" },
        .{ .POST, loc ++ "/keyRings/r/cryptoKeys/k2/cryptoKeyVersions", "{\"state\":\"DESTROYED\"}", 400, "ENABLED or DISABLED" },
        .{ .POST, loc ++ "/keyRings/r/cryptoKeys/k2/cryptoKeyVersions/1:frobnicate", "{}", 501, "frobnicate on a key version" },
        .{ .PUT, loc ++ "/keyRings/r/cryptoKeys/k2/cryptoKeyVersions/1", "{}", 404, "Error 404" },
        .{ .PUT, loc ++ "/keyRings/r/cryptoKeys/k2/cryptoKeyVersions", "{}", 404, "Error 404" },
        .{ .GET, loc ++ "/keyRings/r/cryptoKeys/k2/cryptoKeyVersions/1:destroy", null, 404, "Error 404" },
        .{ .PUT, loc ++ "/keyRings/r/cryptoKeys/k2", "{}", 404, "Error 404" },
        .{ .GET, loc ++ "/keyRings/r/cryptoKeys/k2:updatePrimaryVersion", null, 404, "Error 404" },
        .{ .POST, loc ++ "/keyRings/r/cryptoKeys/k2:frobnicate", "{}", 501, "this method on a key" },
        .{ .POST, loc ++ "/keyRings/r:getIamPolicy", "{}", 501, "this method on a key ring" },
        .{ .PUT, loc ++ "/keyRings/r", "{}", 404, "Error 404" },
        .{ .PUT, loc ++ "/keyRings", "{}", 404, "Error 404" },
        .{ .PUT, loc ++ "/keyRings/r/cryptoKeys", "{}", 404, "Error 404" },
        .{ .POST, loc ++ "/retiredResources", "{}", 404, "Error 404" },
        .{ .POST, "https://cloudkms.googleapis.com/v1/projects/my-project/locations", "{}", 404, "Error 404" },
        .{ .GET, "https://cloudkms.googleapis.com/v1/projects/other/locations", null, 501, "a project other than the fake's own" },
        .{ .GET, loc ++ "/keyRings?a", null, 400, "Invalid query string" },
        .{ .PATCH, loc ++ "/keyRings/r/cryptoKeys/k2?updateMask=purpose", "{}", 501, "updateMask path purpose" },
        .{ .PATCH, loc ++ "/keyRings/r/cryptoKeys/k2?updateMask=rotationPeriod,nextRotationTime", "{\"rotationPeriod\":\"60s\",\"nextRotationTime\":\"2026-10-19T00:00:00Z\"}", 400, "Invalid rotation period." },
        .{ .PATCH, loc ++ "/keyRings/r/cryptoKeys/k2/cryptoKeyVersions/1?updateMask=algorithm", "{}", 501, "updateMask algorithm" },
        .{ .POST, loc ++ "/keyRings/r/cryptoKeys/k2:updatePrimaryVersion", "{\"cryptoKeyVersionId\":\"2\"}", 501, "not enabled" },
    };
    for (cases) |case| {
        const reply = try r.fake.serve(.{ .method = case[0], .url = case[1], .bearer = "t", .body = case[2] }, a);
        testing.expectEqual(case[3], reply.status) catch |err| {
            std.debug.print("{s} {s}: {s}\n", .{ @tagName(case[0]), case[1], reply.body });
            return err;
        };
        if (std.mem.indexOf(u8, reply.body, case[4]) == null) {
            std.debug.print("{s} {s}: {s}\n", .{ @tagName(case[0]), case[1], reply.body });
            return error.TestUnexpectedResult;
        }
    }
    // The client lists the key it made raw, and sets its rotation.
    var keys = try r.client.keyRing("r").listKeys(.{});
    try testing.expectEqual(1, keys.value.keys.len);
    keys.deinit();
    var rotating = try r.client.keyRing("r").key("k2").update(.{ .rotation = .{ .set = .{ .period_s = 86_400, .next = .{ .nanoseconds = test_util.start_ns + 60 * std.time.ns_per_s } } } });
    try testing.expectEqual(86_400, rotating.value.rotation_period_s.?);
    rotating.deinit();
}

/// A rig with key ring "r" made.
fn ringRig(r: *Rig, gpa: Allocator, options: Rig.Options) !void {
    try r.init(gpa, options);
    errdefer r.deinit();
    var made = try r.client.keyRing("r").create();
    made.deinit();
}

test "encrypt and decrypt: round trips with AAD, the primary and older versions, and each refusal" {
    var r: Rig = undefined;
    try ringRig(&r, testing.allocator, .{});
    defer r.deinit();
    const key = r.client.keyRing("r").key("k");
    var info = try key.create(.{ .purpose = .encrypt_decrypt });
    info.deinit();
    var c1 = try key.encrypt("attack at dawn", .{ .aad = "ctx" });
    defer c1.deinit();
    try testing.expectEqual(1, c1.value.version);
    var p1 = try key.decrypt(c1.value.bytes, .{ .aad = "ctx" });
    try testing.expectEqualStrings("attack at dawn", p1.bytes());
    try testing.expect(p1.used_primary);
    p1.deinit();
    // Two encrypts of the same bytes differ.
    var c1b = try key.encrypt("attack at dawn", .{ .aad = "ctx" });
    defer c1b.deinit();
    try testing.expect(!std.mem.eql(u8, c1.value.bytes, c1b.value.bytes));
    // The wrong AAD, another key's ciphertext, and bytes that are not one.
    try testing.expectError(error.DecryptionFailed, key.decrypt(c1.value.bytes, .{}));
    const other = r.client.keyRing("r").key("other");
    var other_info = try other.create(.{ .purpose = .encrypt_decrypt });
    other_info.deinit();
    try testing.expectError(error.DecryptionFailed, other.decrypt(c1.value.bytes, .{ .aad = "ctx" }));
    try testing.expectError(error.DecryptionFailed, key.decrypt("not a ciphertext at all, not even close to one", .{}));
    // A second version made primary: old ciphertexts still decrypt, by
    // version 1, which is not the primary.
    var v2 = try key.createVersion();
    v2.deinit();
    var primary = try key.setPrimary(2);
    primary.deinit();
    var c2 = try key.encrypt("", .{});
    defer c2.deinit();
    try testing.expectEqual(2, c2.value.version);
    var empty = try key.decrypt(c2.value.bytes, .{});
    try testing.expectEqualStrings("", empty.bytes());
    empty.deinit();
    var old = try key.decrypt(c1.value.bytes, .{ .aad = "ctx" });
    try testing.expect(!old.used_primary);
    old.deinit();
    var pinned = try key.encrypt("x", .{ .version = 1 });
    try testing.expectEqual(1, pinned.value.version);
    pinned.deinit();
    // Version 1 disabled, then destroyed: its ciphertexts say so.
    var d = try key.version(1).disable();
    d.deinit();
    try testing.expectError(error.KeyVersionDisabled, key.decrypt(c1.value.bytes, .{ .aad = "ctx" }));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "cryptoKeyVersions/1 is not enabled") != null);
    try testing.expectError(error.KeyVersionDisabled, key.encrypt("x", .{ .version = 1 }));
    var gone = try key.version(1).destroy();
    gone.deinit();
    try testing.expectError(error.KeyVersionDestroyed, key.decrypt(c1.value.bytes, .{ .aad = "ctx" }));
    // A signing key does not encrypt.
    const s = r.client.keyRing("r").key("s");
    var s_info = try s.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256 });
    s_info.deinit();
    try testing.expectError(error.FailedPrecondition, s.encrypt("x", .{}));
    try testing.expectError(error.FailedPrecondition, s.decrypt(c1.value.bytes, .{}));
}

test "sign and verify here: every signing algorithm the fake models, by message and by digest" {
    var r: Rig = undefined;
    try ringRig(&r, testing.allocator, .{});
    defer r.deinit();
    const algorithms = [_]types.Algorithm{
        .ec_sign_p256_sha256,      .ec_sign_p384_sha384,        .ec_sign_secp256k1_sha256,
        .ec_sign_ed25519,          .rsa_sign_pkcs1_2048_sha256, .rsa_sign_pss_2048_sha256,
        .rsa_sign_pss_3072_sha256, .rsa_sign_pkcs1_4096_sha512, .rsa_sign_pss_4096_sha512,
        .pq_sign_ml_dsa_44,        .pq_sign_ml_dsa_65,          .pq_sign_ml_dsa_87,
    };
    var id_buf: [8]u8 = undefined;
    for (algorithms, 0..) |algorithm, i| {
        const id = try std.fmt.bufPrint(&id_buf, "s{d}", .{i});
        const key = r.client.keyRing("r").key(id);
        var info = try key.create(.{ .purpose = .asymmetric_sign, .algorithm = algorithm });
        info.deinit();
        const v = key.version(1);
        var pk = try v.publicKey();
        defer pk.deinit();
        try testing.expectEqual(algorithm, pk.value.algorithm);
        try testing.expectEqual(algorithm.postQuantum(), pk.value.raw.len > 0);
        var sig = try v.sign(algorithm, "the message");
        defer sig.deinit();
        try pk.value.verify("the message", sig.value);
        try testing.expectError(error.SignatureInvalid, pk.value.verify("another message", sig.value));
        const flipped = try testing.allocator.dupe(u8, sig.value);
        defer testing.allocator.free(flipped);
        flipped[flipped.len - 1] ^= 1;
        try testing.expectError(error.SignatureInvalid, pk.value.verify("the message", flipped));
        if (algorithm.signInput().? == .digest) {
            var buf: [64]u8 = undefined;
            const digest = algorithm.signInput().?.digest.digest("by digest", &buf);
            var pre = try v.signDigest(algorithm, digest);
            defer pre.deinit();
            try pk.value.verifyDigest(digest, pre.value);
            try pk.value.verify("by digest", pre.value);
        } else {
            try testing.expectError(error.UnsupportedAlgorithm, pk.value.verifyDigest("0123456789abcdef0123456789abcdef", sig.value));
        }
    }
}

test "local verification refuses a key that is not its algorithm's, and algorithms it cannot check" {
    var r: Rig = undefined;
    try ringRig(&r, testing.allocator, .{});
    defer r.deinit();
    const key = r.client.keyRing("r").key("ec");
    var info = try key.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256 });
    info.deinit();
    var pk = try key.version(1).publicKey();
    defer pk.deinit();
    var wrong = pk.value;
    for ([_]types.Algorithm{ .ec_sign_p384_sha384, .ec_sign_ed25519, .rsa_sign_pkcs1_2048_sha256 }) |a| {
        wrong.algorithm = a;
        try testing.expectError(error.InvalidPublicKey, wrong.verify("m", "sig"));
    }
    wrong.algorithm = .pq_sign_ml_dsa_44;
    try testing.expectError(error.InvalidPublicKey, wrong.verify("m", "sig"));
    for ([_]types.Algorithm{ .pq_sign_slh_dsa_sha2_128s, .hmac_sha256, .google_symmetric_encryption }) |a| {
        wrong.algorithm = a;
        try testing.expectError(error.UnsupportedAlgorithm, wrong.verify("m", "sig"));
        try testing.expectError(error.UnsupportedAlgorithm, wrong.verifyDigest("m", "sig"));
    }
    wrong = pk.value;
    wrong.pem = "not a PEM";
    try testing.expectError(error.InvalidPublicKey, wrong.verify("m", "sig"));
    wrong.pem = "-----BEGIN PUBLIC KEY-----\n!!!\n-----END PUBLIC KEY-----\n";
    try testing.expectError(error.InvalidPublicKey, wrong.verify("m", "sig"));
    // A signature that is not DER, or a digest of another length.
    try testing.expectError(error.SignatureInvalid, pk.value.verify("m", "not DER"));
    try testing.expectError(error.SignatureInvalid, pk.value.verifyDigest("short", "not DER"));
}

test "MACs: every HMAC, a wrong MAC false, and a MAC key does not sign" {
    var r: Rig = undefined;
    try ringRig(&r, testing.allocator, .{});
    defer r.deinit();
    const algorithms = [_]types.Algorithm{ .hmac_sha1, .hmac_sha224, .hmac_sha256, .hmac_sha384, .hmac_sha512 };
    const lengths = [_]usize{ 20, 28, 32, 48, 64 };
    var id_buf: [8]u8 = undefined;
    for (algorithms, lengths, 0..) |algorithm, len, i| {
        const key = r.client.keyRing("r").key(try std.fmt.bufPrint(&id_buf, "m{d}", .{i}));
        var info = try key.create(.{ .purpose = .mac, .algorithm = algorithm });
        info.deinit();
        const v = key.version(1);
        var m = try v.macSign("data");
        defer m.deinit();
        try testing.expectEqual(len, m.value.len);
        try testing.expect(try v.macVerify("data", m.value));
        try testing.expect(!try v.macVerify("other data", m.value));
        try testing.expect(!try v.macVerify("data", ""));
        try testing.expectError(error.FailedPrecondition, v.sign(.ec_sign_p256_sha256, "data"));
    }
}

test "the fake's other refusals: a pending version, the wrong input, the wrong format, random bytes" {
    var r: Rig = undefined;
    try ringRig(&r, testing.allocator, .{ .fake = .{ .generation_delay_ms = 1000 } });
    defer r.deinit();
    const key = r.client.keyRing("r").key("s");
    var info = try key.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256 });
    info.deinit();
    try testing.expectError(error.KeyVersionPending, key.version(1).sign(.ec_sign_p256_sha256, "m"));
    try testing.expectError(error.KeyVersionPending, key.version(1).publicKey());
    r.advance(1);
    // The algorithm the caller names is what is sent: another one is the
    // server's refusal.
    try testing.expectError(error.InvalidArgument, key.version(1).sign(.ec_sign_ed25519, "m"));
    try testing.expectError(error.InvalidArgument, key.version(1).sign(.ec_sign_p384_sha384, "m"));
    var random = try r.client.randomBytes(32);
    try testing.expectEqual(32, random.value.len);
    random.deinit();
    var sym = try r.client.keyRing("r").key("e").create(.{ .purpose = .encrypt_decrypt });
    sym.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = test_util.base;
    const raw = [_]struct { tp.Method, []const u8, ?[]const u8, u16, []const u8 }{
        .{ .GET, base ++ "/keyRings/r/cryptoKeys/s/cryptoKeyVersions/1/publicKey?publicKeyFormat=DER", null, 501, "public key format DER" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/s/cryptoKeyVersions/1/publicKey", "{}", 404, "Error 404" },
        .{ .POST, base ++ ":generateRandomBytes", "{\"lengthBytes\":16}", 400, "from an HSM" },
        .{ .POST, base ++ ":generateRandomBytes", "{\"lengthBytes\":7,\"protectionLevel\":\"HSM\"}", 400, "8 to 1024" },
        .{ .POST, base ++ ":generateRandomBytes", "{\"protectionLevel\":\"HSM\"}", 400, "Invalid JSON" },
        .{ .GET, base ++ ":generateRandomBytes", null, 404, "Error 404" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/s/cryptoKeyVersions/1:asymmetricSign", "{\"digest\":{\"sha256\":\"AAAA\"}}", 400, "length is not" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/s/cryptoKeyVersions/1:asymmetricSign", "{}", 400, "digest is required" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/s/cryptoKeyVersions/1:asymmetricSign", "{\"digest\":{\"sha256\":\"5GsyAWXuyR5jRPoQNA1bMggwTWytKdDVrtGEZtHZ2A4=\"},\"digestCrc32c\":\"1\"}", 400, "The checksum in field digest_crc32c" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/e:encrypt", "{\"plaintext\":\"aGVsbG8=\",\"plaintextCrc32c\":\"1\"}", 400, "The checksum in field plaintext_crc32c did not match the data in field plaintext." },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/e:encrypt", "{\"plaintext\":\"aGVsbG8=\",\"plaintextCrc32c\":\"2591144780\",\"additionalAuthenticatedData\":\"eA==\",\"additionalAuthenticatedDataCrc32c\":\"7\"}", 400, "field additional_authenticated_data_crc32c" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/e:encrypt", "{\"plaintext\":\"!!\"}", 400, "Invalid JSON" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/e:encrypt", "[1]", 400, "Invalid JSON" },
        .{ .POST, base ++ "/keyRings/r/cryptoKeys/s:encrypt", "{}", 400, "not for a key of purpose ASYMMETRIC_SIGN" },
        .{ .GET, base ++ "/keyRings/r/cryptoKeys/s:encrypt", null, 404, "Error 404" },
    };
    for (raw) |case| {
        const reply = try r.fake.serve(.{ .method = case[0], .url = case[1], .bearer = "t", .body = case[2] }, a);
        if (reply.status != case[3] or std.mem.indexOf(u8, reply.body, case[4]) == null) {
            std.debug.print("{s} {s}: {d} {s}\n", .{ @tagName(case[0]), case[1], reply.status, reply.body });
            return error.TestUnexpectedResult;
        }
    }
}

test "keys whose cryptography the fake does not model are made and managed, and their use is 501" {
    var r: Rig = undefined;
    try ringRig(&r, testing.allocator, .{});
    defer r.deinit();
    const slh = r.client.keyRing("r").key("slh");
    var a = try slh.create(.{ .purpose = .asymmetric_sign, .algorithm = .pq_sign_slh_dsa_sha2_128s });
    a.deinit();
    try testing.expectError(error.Unimplemented, slh.version(1).sign(.pq_sign_slh_dsa_sha2_128s, "m"));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "signing with PQ_SIGN_SLH_DSA_SHA2_128S") != null);
    try testing.expectError(error.Unimplemented, slh.version(1).publicKey());
    const raw = r.client.keyRing("r").key("raw");
    var b = try raw.create(.{ .purpose = .raw_encrypt_decrypt, .algorithm = .aes_256_gcm });
    b.deinit();
    var v = try raw.version(1).get();
    try testing.expectEqual(types.State.enabled, v.value.state);
    v.deinit();
    try testing.expectEqual(FakeKms.Material.none, r.fake.version("projects/my-project/locations/us-central1/keyRings/r/cryptoKeys/raw", 1).?.material.*);
}

test "integrity faults: each check catches its fault, once tried again and past the attempts refused" {
    var r: Rig = undefined;
    try ringRig(&r, testing.allocator, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer r.deinit();
    const sym = r.client.keyRing("r").key("sym");
    var a = try sym.create(.{ .purpose = .encrypt_decrypt });
    a.deinit();
    const sig = r.client.keyRing("r").key("sig");
    var b = try sig.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256 });
    b.deinit();
    const mac = r.client.keyRing("r").key("mac");
    var m = try mac.create(.{ .purpose = .mac, .algorithm = .hmac_sha256 });
    m.deinit();
    var ct = try sym.encrypt("p", .{});
    defer ct.deinit();
    var tag = try mac.version(1).macSign("d");
    defer tag.deinit();

    // An encrypt by key may be answered by any of its versions, while a
    // primary change settles, so another version's name is caught only
    // when the encrypt named one.
    const Call = enum { encrypt, encrypt_pinned, decrypt, sign, public_key, mac_sign, mac_verify, random };
    const plan = [_]struct { Call, FakeKms.Corruption }{
        .{ .encrypt, .flip_payload },     .{ .encrypt, .drop_verified },   .{ .encrypt_pinned, .wrong_name },   .{ .encrypt, .refuse_checksum },
        .{ .decrypt, .flip_payload },     .{ .decrypt, .refuse_checksum }, .{ .sign, .flip_payload },           .{ .sign, .drop_verified },
        .{ .sign, .wrong_name },          .{ .sign, .refuse_checksum },    .{ .public_key, .flip_payload },     .{ .public_key, .wrong_name },
        .{ .mac_sign, .flip_payload },    .{ .mac_sign, .drop_verified },  .{ .mac_sign, .wrong_name },         .{ .mac_sign, .refuse_checksum },
        .{ .mac_verify, .drop_verified }, .{ .mac_verify, .wrong_name },   .{ .mac_verify, .success_mismatch }, .{ .mac_verify, .refuse_checksum },
        .{ .random, .flip_payload },
    };
    for (plan) |step| {
        inline for (.{ 1, 2 }) |times| {
            r.fake.corruptNext(times, step[1]);
            const outcome: anyerror!void = switch (step[0]) {
                .encrypt => if (sym.encrypt("p", .{})) |x| {
                    var y = x;
                    y.deinit();
                } else |err| err,
                .encrypt_pinned => if (sym.encrypt("p", .{ .version = 1 })) |x| {
                    var y = x;
                    y.deinit();
                } else |err| err,
                .decrypt => if (sym.decrypt(ct.value.bytes, .{})) |x| {
                    var y = x;
                    try testing.expectEqualStrings("p", y.bytes());
                    y.deinit();
                } else |err| err,
                .sign => if (sig.version(1).sign(.ec_sign_p256_sha256, "m")) |x| {
                    var y = x;
                    y.deinit();
                } else |err| err,
                .public_key => if (sig.version(1).publicKey()) |x| {
                    var y = x;
                    y.deinit();
                } else |err| err,
                .mac_sign => if (mac.version(1).macSign("d")) |x| {
                    var y = x;
                    y.deinit();
                } else |err| err,
                .mac_verify => if (mac.version(1).macVerify("d", tag.value)) |ok| try testing.expect(ok) else |err| err,
                .random => if (r.client.randomBytes(16)) |x| {
                    var y = x;
                    y.deinit();
                } else |err| err,
            };
            if (times == 1) {
                outcome catch |err| {
                    std.debug.print("{t} {t} once: {t} {s}\n", .{ step[0], step[1], err, r.diag.message() });
                    return err;
                };
            } else {
                testing.expectError(error.IntegrityCheckFailed, outcome) catch |err| {
                    std.debug.print("{t} {t} twice\n", .{ step[0], step[1] });
                    return err;
                };
            }
        }
    }
}

fn cryptoAllocations(gpa: Allocator) !void {
    var r: Rig = undefined;
    try ringRig(&r, gpa, .{});
    defer r.deinit();
    const sym = r.client.keyRing("r").key("sym");
    var a = try sym.create(.{ .purpose = .encrypt_decrypt });
    a.deinit();
    var ct = try sym.encrypt("plain", .{ .aad = "x" });
    defer ct.deinit();
    var p = try sym.decrypt(ct.value.bytes, .{ .aad = "x" });
    p.deinit();
    const sig = r.client.keyRing("r").key("sig");
    var b = try sig.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_ed25519 });
    b.deinit();
    var s = try sig.version(1).sign(.ec_sign_ed25519, "m");
    s.deinit();
    var pk = try sig.version(1).publicKey();
    pk.deinit();
    const mac = r.client.keyRing("r").key("mac");
    var m = try mac.create(.{ .purpose = .mac, .algorithm = .hmac_sha256 });
    m.deinit();
    var t = try mac.version(1).macSign("d");
    defer t.deinit();
    _ = try mac.version(1).macVerify("d", t.value);
    var rb = try r.client.randomBytes(8);
    rb.deinit();
}

test "crypto calls against the fake: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, cryptoAllocations, .{});
}

fn lifecycleAllocations(gpa: Allocator) !void {
    var r: Rig = undefined;
    try r.init(gpa, .{});
    defer r.deinit();
    const ring = r.client.keyRing("r");
    // A lost answer, so the read-back allocates too.
    r.fake.loseNext(1, 503);
    var made = try ring.create();
    made.deinit();
    const key = ring.key("k");
    var info = try key.create(.{ .purpose = .encrypt_decrypt, .labels = &.{.{ .key = "a", .value = "b" }} });
    info.deinit();
    r.fake.loseNext(1, 503);
    var v = try key.version(1).destroy();
    v.deinit();
    var page = try key.listVersions(.{});
    page.deinit();
    var keys = try ring.listKeys(.{});
    keys.deinit();
    var rings = try r.client.listKeyRings(.{});
    rings.deinit();
    var locations = try r.client.listLocations(.{});
    locations.deinit();
    var retired = try r.client.listRetiredKeys(.{});
    retired.deinit();
}

test "a lifecycle against the fake: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, lifecycleAllocations, .{});
}
