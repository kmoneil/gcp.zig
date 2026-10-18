//! The model property, nightly as `slow-kms`: random sequences of calls
//! from a real client against the fake, each outcome held to a plain model
//! of what every key and version allows and what every ciphertext decrypts
//! to. Faults in the answers' checksums are injected along the way: a fault
//! once is tried again and succeeds, a fault every time is
//! `error.IntegrityCheckFailed`, and no fault ever turns into a success
//! with the wrong bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const FakeKms = @import("fake_kms.zig").FakeKms;
const test_util = @import("test_util.zig");
const Rig = test_util.Rig;

const max_keys = 3;
const max_versions = 6;
const max_sealed = 12;
const day_ns: i96 = std.time.ns_per_day;

const Purpose = enum { encrypt, sign, mac };

const VersionState = enum { enabled, disabled, scheduled, destroyed, deleted };

const VersionModel = struct { state: VersionState, destroy_at: i96 = 0 };

const KeyModel = struct {
    purpose: Purpose,
    versions: [max_versions]VersionModel = undefined,
    count: usize = 0,
    primary: ?u64 = null,
    deleted: bool = false,

    fn version(k: *KeyModel, id: u64) ?*VersionModel {
        if (id == 0 or id > k.count) return null;
        const v = &k.versions[id - 1];
        return if (v.state == .deleted) null else v;
    }
};

const Sealed = struct {
    key: usize,
    version: u64,
    plaintext: [16]u8,
    len: usize,
    aad: u8,
    ciphertext: []const u8,
};

const Model = struct {
    keys: [max_keys]?KeyModel = @splat(null),
    sealed: [max_sealed]Sealed = undefined,
    sealed_count: usize = 0,
    now: i96,

    fn settle(m: *Model) void {
        for (&m.keys) |*slot| if (slot.*) |*k| for (k.versions[0..k.count]) |*v| {
            if (v.state == .scheduled and v.destroy_at <= m.now) v.state = .destroyed;
        };
    }

    fn billed(m: *const Model) usize {
        var n: usize = 0;
        for (m.keys) |slot| if (slot) |k| {
            if (k.deleted) continue;
            for (k.versions[0..k.count]) |v| switch (v.state) {
                .enabled, .disabled, .scheduled => n += 1,
                .destroyed, .deleted => {},
            };
        };
        return n;
    }
};

/// What the model says a call comes to.
const Expect = union(enum) { ok, err: anyerror };

/// The error a version in `state` is refused with.
fn stateError(state: VersionState) anyerror {
    return switch (state) {
        .disabled => error.KeyVersionDisabled,
        .scheduled, .destroyed, .deleted => error.KeyVersionDestroyed,
        .enabled => unreachable,
    };
}

fn expectOutcome(expect: Expect, got: anyerror!void, what: []const u8) !void {
    switch (expect) {
        .ok => got catch |err| {
            std.debug.print("{s}: expected success, got {t}\n", .{ what, err });
            return err;
        },
        .err => |want| {
            if (got) |_| {
                std.debug.print("{s}: expected {t}, got success\n", .{ what, want });
                return error.TestUnexpectedResult;
            } else |err| if (err != want) {
                std.debug.print("{s}: expected {t}, got {t}\n", .{ what, want, err });
                return error.TestUnexpectedResult;
            }
        },
    }
}

fn keyId(i: usize) []const u8 {
    return ([_][]const u8{ "k0", "k1", "k2" })[i];
}

pub fn property(_: void, input: []const u8) !void {
    const gpa = test_util.propertyAllocator();
    var g: test_util.ByteGen = .init(input);
    var r: Rig = undefined;
    try r.init(gpa, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer r.deinit();
    var made = try r.client.keyRing("r").create();
    made.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var m: Model = .{ .now = r.clock.now_ns };

    var steps: usize = 0;
    while (g.pos < g.bytes.len and steps < 60) : (steps += 1) {
        const op = g.byte() % 13;
        const i = g.byte() % max_keys;
        const vid: u64 = 1 + g.byte() % max_versions;

        const key = r.client.keyRing("r").key(keyId(i));
        const slot = &m.keys[i];
        switch (op) {
            0 => { // create
                const purpose: Purpose = @fromBackingInt(@intCast(g.byte() % 3));
                const first = g.boolean();
                const expect: Expect = if (slot.* != null) .{ .err = error.AlreadyExists } else .ok;
                const config: types.KeyConfig = switch (purpose) {
                    .encrypt => .{ .purpose = .encrypt_decrypt, .destroy_delay_s = 86_400, .first_version = first },
                    .sign => .{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256, .destroy_delay_s = 86_400, .first_version = first },
                    .mac => .{ .purpose = .mac, .algorithm = .hmac_sha256, .destroy_delay_s = 86_400, .first_version = first },
                };
                const got = if (key.create(config)) |x| {
                    var y = x;
                    y.deinit();
                } else |err| err;
                try expectOutcome(expect, got, "create");
                if (expect == .ok) {
                    slot.* = .{ .purpose = purpose };
                    if (first) {
                        slot.*.?.versions[0] = .{ .state = .enabled };
                        slot.*.?.count = 1;
                        if (purpose == .encrypt) slot.*.?.primary = 1;
                    }
                }
            },
            1 => { // createVersion
                const k = liveKey(slot) orelse {
                    try expectOutcome(.{ .err = error.NotFound }, if (key.createVersion()) |x| free(x) else |err| err, "createVersion");
                    continue;
                };
                if (k.count == max_versions) continue;
                try expectOutcome(.ok, if (key.createVersion()) |x| free(x) else |err| err, "createVersion");
                k.versions[k.count] = .{ .state = .enabled };
                k.count += 1;
            },
            2 => { // setPrimary
                const expect: Expect = e: {
                    const k = liveKey(slot) orelse break :e .{ .err = error.NotFound };
                    if (k.purpose != .encrypt) break :e .{ .err = error.FailedPrecondition };
                    const v = k.version(vid) orelse break :e .{ .err = error.NotFound };
                    if (v.state != .enabled) break :e .{ .err = error.Unimplemented };
                    break :e .ok;
                };
                try expectOutcome(expect, if (key.setPrimary(vid)) |x| free(x) else |err| err, "setPrimary");
                if (expect == .ok) slot.*.?.primary = vid;
            },
            3 => { // enable or disable
                const want: VersionState = if (g.boolean()) .enabled else .disabled;
                const expect: Expect = e: {
                    const k = liveKey(slot) orelse break :e .{ .err = error.NotFound };
                    const v = k.version(vid) orelse break :e .{ .err = error.NotFound };
                    if (v.state != .enabled and v.state != .disabled) break :e .{ .err = error.FailedPrecondition };
                    break :e .ok;
                };
                const handle = key.version(vid);
                const got = if (if (want == .enabled) handle.enable() else handle.disable()) |x| free(x) else |err| err;
                try expectOutcome(expect, got, "enable or disable");
                if (expect == .ok) slot.*.?.version(vid).?.state = want;
            },
            4 => { // destroy
                const expect: Expect = e: {
                    const k = liveKey(slot) orelse break :e .{ .err = error.NotFound };
                    const v = k.version(vid) orelse break :e .{ .err = error.NotFound };
                    if (v.state != .enabled and v.state != .disabled) break :e .{ .err = error.FailedPrecondition };
                    break :e .ok;
                };
                try expectOutcome(expect, if (key.version(vid).destroy()) |x| free(x) else |err| err, "destroy");
                if (expect == .ok) slot.*.?.version(vid).?.* = .{ .state = .scheduled, .destroy_at = m.now + day_ns };
            },
            5 => { // restore
                const expect: Expect = e: {
                    const k = liveKey(slot) orelse break :e .{ .err = error.NotFound };
                    const v = k.version(vid) orelse break :e .{ .err = error.NotFound };
                    if (v.state != .scheduled) break :e .{ .err = error.FailedPrecondition };
                    break :e .ok;
                };
                try expectOutcome(expect, if (key.version(vid).restore()) |x| free(x) else |err| err, "restore");
                if (expect == .ok) slot.*.?.version(vid).?.* = .{ .state = .disabled };
            },
            6 => { // delete a version
                const expect: Expect = e: {
                    const k = liveKey(slot) orelse break :e .{ .err = error.NotFound };
                    const v = k.version(vid) orelse break :e .{ .err = error.NotFound };
                    if (v.state != .destroyed) break :e .{ .err = error.FailedPrecondition };
                    break :e .ok;
                };
                try expectOutcome(expect, key.version(vid).delete(), "delete version");
                if (expect == .ok) slot.*.?.version(vid).?.state = .deleted;
            },
            7 => { // time passes: up to 2 days in hours
                const hours: i64 = g.byte() % 49;
                r.advance(hours * std.time.s_per_hour);
                m.now = r.clock.now_ns;
                m.settle();
            },
            8 => try encryptStep(&r, &m, &g, a, i, vid, null),
            9 => try decryptStep(&r, &m, &g, null),
            10 => try signStep(&r, &m, i, vid, null),
            11 => try macStep(&r, &m, &g, i, vid, null),
            12 => { // delete a key
                const expect: Expect = e: {
                    const k = liveKey(slot) orelse break :e .{ .err = error.NotFound };
                    for (k.versions[0..k.count]) |v| if (v.state != .deleted) break :e .{ .err = error.InvalidArgument };
                    break :e .ok;
                };
                try expectOutcome(expect, key.delete(), "delete key");
                if (expect == .ok) slot.*.?.deleted = true;
            },
            else => unreachable,
        }
        // A fault in the next crypto call, once or every time.
        if (g.byte() % 4 == 0) {
            const fault: Fault = .{ .kind = @fromBackingInt(@intCast(g.byte() % 5)), .times = 1 + g.byte() % 2 };
            switch (g.byte() % 4) {
                0 => try encryptStep(&r, &m, &g, a, i, vid, fault),
                1 => try decryptStep(&r, &m, &g, fault),
                2 => try signStep(&r, &m, i, vid, fault),
                else => try macStep(&r, &m, &g, i, vid, fault),
            }
            r.fake.corruptNext(0, .flip_payload);
        }
        try std.testing.expectEqual(m.billed(), r.fake.billedVersions());
    }
}

const Fault = struct { kind: FakeKms.Corruption, times: usize };

/// What a successful call comes to under `fault`: still a success when the
/// fault happened once, or when the call has nothing it could get wrong;
/// `error.IntegrityCheckFailed` when it happened every time.
fn underFault(fault: ?Fault, applies: bool) Expect {
    const f = fault orelse return .ok;
    if (f.times == 1 or !applies) return .ok;
    return .{ .err = error.IntegrityCheckFailed };
}

fn arm(r: *Rig, fault: ?Fault) void {
    if (fault) |f| r.fake.corruptNext(f.times, f.kind);
}

fn liveKey(slot: *?KeyModel) ?*KeyModel {
    if (slot.*) |*k| if (!k.deleted) return k;
    return null;
}

fn free(owned: anytype) void {
    var o = owned;
    o.deinit();
}

fn encryptStep(r: *Rig, m: *Model, g: *test_util.ByteGen, a: Allocator, i: usize, vid: u64, fault: ?Fault) !void {
    const pinned: ?u64 = if (g.boolean()) vid else null;
    var plaintext: [16]u8 = undefined;
    const len = g.byte() % 17;
    for (plaintext[0..len]) |*b| b.* = g.byte();
    const aad = g.byte() % 3;
    const slot = &m.keys[i];
    const expect: Expect = e: {
        const k = liveKey(slot) orelse break :e .{ .err = error.NotFound };
        if (pinned) |p| if (k.version(p) == null) break :e .{ .err = error.NotFound };
        if (k.purpose != .encrypt) break :e .{ .err = error.FailedPrecondition };
        const target = pinned orelse k.primary orelse break :e .{ .err = error.FailedPrecondition };
        const state = k.versions[target - 1].state;
        if (state != .enabled) break :e .{ .err = stateError(state) };
        const kind = if (fault) |f| f.kind else .flip_payload;
        break :e underFault(fault, switch (kind) {
            .flip_payload, .drop_verified, .refuse_checksum => true,
            .wrong_name => pinned != null,
            .success_mismatch => false,
        });
    };
    arm(r, fault);
    const aad_bytes = ([_][]const u8{ "", "a", "bb" })[aad];
    const key = r.client.keyRing("r").key(keyId(i));
    if (key.encrypt(plaintext[0..len], .{ .aad = aad_bytes, .version = pinned })) |result| {
        var c = result;
        defer c.deinit();
        try expectOutcome(expect, {}, "encrypt");
        const k = &m.keys[i].?;
        const used = pinned orelse k.primary.?;
        // An encrypt by key takes any version of it as the answer's, since
        // during a primary change any may answer: another version's name
        // is the one fault it cannot see, and it misreports only that.
        const misnamed = pinned == null and fault != null and fault.?.kind == .wrong_name;
        if (!misnamed) try std.testing.expectEqual(used, c.value.version);
        if (m.sealed_count < max_sealed) {
            m.sealed[m.sealed_count] = .{ .key = i, .version = used, .plaintext = plaintext, .len = len, .aad = aad, .ciphertext = try a.dupe(u8, c.value.bytes) };
            m.sealed_count += 1;
        }
    } else |err| try expectOutcome(expect, err, "encrypt");
}

fn decryptStep(r: *Rig, m: *Model, g: *test_util.ByteGen, fault: ?Fault) !void {
    if (m.sealed_count == 0) return;
    const s = m.sealed[g.byte() % m.sealed_count];
    // The wrong AAD only when no fault is armed: which the server refuses
    // first, a bad request checksum or the AAD, is not modelled.
    const wrong_aad = g.byte() % 5 == 0 and fault == null;
    const expect: Expect = e: {
        const k = liveKey(&m.keys[s.key]) orelse break :e .{ .err = error.NotFound };
        const v = k.version(s.version) orelse break :e .{ .err = error.DecryptionFailed };
        if (v.state != .enabled) break :e .{ .err = stateError(v.state) };
        if (wrong_aad) break :e .{ .err = error.DecryptionFailed };
        const kind = if (fault) |f| f.kind else .flip_payload;
        break :e underFault(fault, switch (kind) {
            // An empty plaintext has no byte to flip.
            .flip_payload => s.len > 0,
            .refuse_checksum => true,
            .drop_verified, .wrong_name, .success_mismatch => false,
        });
    };
    arm(r, fault);
    const aad_bytes = ([_][]const u8{ "", "a", "bb", "x" })[if (wrong_aad) 3 else s.aad];
    const key = r.client.keyRing("r").key(keyId(s.key));
    if (key.decrypt(s.ciphertext, .{ .aad = aad_bytes })) |result| {
        var p = result;
        defer p.deinit();
        try expectOutcome(expect, {}, "decrypt");
        try std.testing.expectEqualSlices(u8, s.plaintext[0..s.len], p.bytes());
        try std.testing.expectEqual(m.keys[s.key].?.primary == s.version, p.used_primary);
    } else |err| try expectOutcome(expect, err, "decrypt");
}

fn signStep(r: *Rig, m: *Model, i: usize, vid: u64, fault: ?Fault) !void {
    const expect: Expect = e: {
        const k = liveKey(&m.keys[i]) orelse break :e .{ .err = error.NotFound };
        const v = k.version(vid) orelse break :e .{ .err = error.NotFound };
        if (k.purpose != .sign) break :e .{ .err = error.FailedPrecondition };
        if (v.state != .enabled) break :e .{ .err = stateError(v.state) };
        const kind = if (fault) |f| f.kind else .flip_payload;
        break :e underFault(fault, kind != .success_mismatch);
    };
    arm(r, fault);
    const version = r.client.keyRing("r").key(keyId(i)).version(vid);
    if (version.sign(.ec_sign_p256_sha256, "the message")) |result| {
        var sig = result;
        defer sig.deinit();
        try expectOutcome(expect, {}, "sign");
        r.fake.corruptNext(0, .flip_payload);
        var pk = try version.publicKey();
        defer pk.deinit();
        try pk.value.verify("the message", sig.value);
    } else |err| try expectOutcome(expect, err, "sign");
}

fn macStep(r: *Rig, m: *Model, g: *test_util.ByteGen, i: usize, vid: u64, fault: ?Fault) !void {
    const verify = g.boolean();
    const expect: Expect = e: {
        const k = liveKey(&m.keys[i]) orelse break :e .{ .err = error.NotFound };
        const v = k.version(vid) orelse break :e .{ .err = error.NotFound };
        if (k.purpose != .mac) break :e .{ .err = error.FailedPrecondition };
        if (v.state != .enabled) break :e .{ .err = stateError(v.state) };
        const kind = if (fault) |f| f.kind else .flip_payload;
        break :e underFault(fault, switch (kind) {
            .flip_payload => !verify,
            .success_mismatch => verify,
            .drop_verified, .wrong_name, .refuse_checksum => true,
        });
    };
    const version = r.client.keyRing("r").key(keyId(i)).version(vid);
    if (!verify) {
        arm(r, fault);
        if (version.macSign("data")) |result| {
            free(result);
            try expectOutcome(expect, {}, "macSign");
        } else |err| try expectOutcome(expect, err, "macSign");
        return;
    }
    // A MAC to verify: the version's own when it can make one.
    var mac_buf: [32]u8 = @splat(0);
    if (version.macSign("data")) |result| {
        var own = result;
        defer own.deinit();
        @memcpy(mac_buf[0..own.value.len], own.value);
    } else |_| {}
    arm(r, fault);
    if (version.macVerify("data", &mac_buf)) |ok| {
        try expectOutcome(expect, {}, "macVerify");
        try std.testing.expect(ok);
    } else |err| try expectOutcome(expect, err, "macVerify");
}

test "slow property: the client against the fake matches a plain model, and no checksum fault is a wrong success" {
    try test_util.fuzzBytes({}, property, .{
        .random_runs = 40,
        .max_len = 400,
        .corpus = &.{
            "",
            // Make an encryption key, encrypt, rotate by hand, decrypt both.
            "\x00\x00\x00\x00\x01\x08\x00\x00\x00\x07\x01\x00\x00\x01\x00\x01\x00\x01\x08\x00\x02\x01\x01\x09\x00\x00\x01\x09\x00\x00\x01",
            // A signing key and a MAC key, used, destroyed, time passes, deleted.
            "\x00\x01\x00\x01\x01\x0a\x01\x00\x01\x00\x02\x00\x02\x01\x0b\x02\x00\x00\x01\x04\x01\x00\x01\x07\x00\x00\x30\x01\x06\x01\x00\x01\x0c\x01\x00\x01",
            // A MAC key made, then a MAC signed and one verified.
            "\x00\x02\x00\x02\x01\x01\x0b\x02\x00\x00\x01\x0b\x02\x00\x01\x01",
            // Found by a random run: an encrypt by key whose answer names another
            // version, which the client cannot tell from a primary change.
            &fromHex("aabf34fb1d36882c0045b26180a5e13ecc5005bd7fe3d099b739f312a370c9921de2b706ba4e1784cbdd01e522f861ef2f0a97704e49daddfbff6693c1790a6328f2fa69b7160bae2a1a79f11cfc5dd3057c5182cf0e1b5eb37928124a8edea5a5180ef8f6b3c409a75aea8a4a39cab0a01665ce4781869be8fe4e11308d3313d245e1ad076cc002a9b825069fe07297d0086b626cd07558639ed06699fece83afcb99301845f328718a7642f2dad1bbbe2ebb2542f68166462dab23ce11d91f7e47a86c12c81d8163083ce0197906326ae766dcf3f0d29e5a30dee0cc9f30e7644a7ce3350d302455e66b4be8e3d6d3df583213010977ae2ca1"),
        },
    });
}

fn fromHex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}
