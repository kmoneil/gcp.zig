//! Integration tests against real Cloud KMS, which has no emulator:
//! milestone 4 of the KMS spec. They need a key ring kept for them, on
//! which the token's principal holds roles/cloudkms.admin and
//! roles/cloudkms.cryptoOperator, and leave it in place:
//!
//!     GCP_TEST_PROJECT=extractctl GCP_TEST_TOKEN=$(cat token.txt) \
//!     KMS_TEST_KEY_RING=zigps-kms zig build test-integration-gcp -Dtest-filter=kms
//!
//! KMS_TEST_LOCATION is the key ring's location, us-central1 when unset.
//! Without the first three every test skips. A key cannot be deleted while
//! a version of it is not yet destroyed, so cleanup comes in two phases:
//! as a run ends, every version of its keys is scheduled for destruction,
//! and as a later run starts, every `zigps-` key in the ring is swept: its
//! destroyed versions deleted, any still usable scheduled, and the key
//! deleted once it has none. Keys are software keys with a 1-day destroy
//! delay, named `zigps-<run>-<what>`; a run bills eight versions for about
//! a day, a cent or two. A run's own empty key ring is deleted too. The
//! first test runs one script against production and against `FakeKms`,
//! and holds the fake to what production did.

const std = @import("std");
const kms = @import("kms");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const day_s = std.time.s_per_day;
const day_ns: i96 = std.time.ns_per_day;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: kms.StaticToken,
    diag: kms.Diagnostics,
    client: kms.Client,
    arena: std.heap.ArenaAllocator,
    project: []const u8,
    location: []const u8,
    /// The kept key ring's id.
    ring: []const u8,
    /// Six hex digits: this run's keys are `zigps-<run>-<what>`.
    run: []const u8,
    /// The ids of the keys this run made, for the first phase of cleanup.
    made: std.ArrayList([]const u8),

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        f.ring = f.env.get("KMS_TEST_KEY_RING") orelse return f.skip();
        f.location = f.env.get("KMS_TEST_LOCATION") orelse "us-central1";
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        f.made = .empty;
        var bytes: [3]u8 = undefined;
        testing.io.random(&bytes);
        f.run = try f.arena.allocator().print("{x}", .{bytes});
        f.client = try .init(gpa, testing.io, .{
            .project_id = f.project,
            .location = f.location,
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "gcp-zig-kms-gcp-integration/0.1",
        });
        errdefer f.client.deinit();
        f.sweep() catch |err| return f.report(err);
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    /// The first phase of cleanup, for every key this run made.
    fn deinit(f: *Fixture) void {
        for (f.made.items) |id| f.retire(id) catch |err| {
            std.debug.print("cleanup of {s} failed: ", .{id});
            f.say(err);
        };
        f.made.deinit(testing.allocator);
        f.client.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    /// `zigps-<run>-<short>`, to be cleaned up as the run ends.
    fn track(f: *Fixture, short: []const u8) !void {
        const id = try f.arena.allocator().print("zigps-{s}-{s}", .{ f.run, short });
        for (f.made.items) |m| if (std.mem.eql(u8, m, id)) return;
        try f.made.append(testing.allocator, id);
    }

    /// Rotation turned off, so no version comes after, and every version
    /// still usable scheduled for destruction. A key with no version left
    /// is deleted at once.
    fn retire(f: *Fixture, id: []const u8) !void {
        const key = f.client.keyRing(f.ring).key(id);
        var info = key.get() catch |err| switch (err) {
            error.NotFound => return,
            else => return err,
        };
        defer info.deinit();
        if (info.value.rotation_period_s != null or info.value.next_rotation != null) {
            var still = try key.update(.{ .rotation = .clear });
            still.deinit();
        }
        if (try tidyVersions(key, false) == 0) try key.delete();
    }

    /// The second phase of cleanup, for what earlier runs left: every
    /// `zigps-` key in the ring tidied, deleted once none of its versions
    /// is left, and every empty `zigps-` key ring but the kept one deleted.
    /// A key that cannot be tidied yet is reported and left for later.
    fn sweep(f: *Fixture) !void {
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const ring = f.client.keyRing(f.ring);
        var ids: std.ArrayList([]const u8) = .empty;
        var token: ?[]const u8 = null;
        while (true) {
            var page = try ring.listKeys(.{ .page_token = token });
            defer page.deinit();
            for (page.value.keys) |k| {
                const id = lastPart(k.name);
                if (std.mem.startsWith(u8, id, "zigps-")) try ids.append(a, try a.dupe(u8, id));
            }
            token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else null;
            if (token == null) break;
        }
        var deleted: usize = 0;
        for (ids.items) |id| {
            if (sweepKey(ring.key(id))) |gone| {
                if (gone) deleted += 1;
            } else |err| {
                std.debug.print("sweep of {s}: ", .{id});
                f.say(err);
            }
        }
        var rings_deleted: usize = 0;
        token = null;
        while (true) {
            var page = try f.client.listKeyRings(.{ .page_token = token });
            defer page.deinit();
            for (page.value.key_rings) |r| {
                const id = lastPart(r.name);
                if (!std.mem.startsWith(u8, id, "zigps-") or !std.mem.endsWith(u8, id, "-ring") or std.mem.eql(u8, id, f.ring)) continue;
                if (f.client.keyRing(id).delete()) |_| {
                    rings_deleted += 1;
                } else |err| switch (err) {
                    // Deleted already, and still listed while that finishes.
                    error.NotFound, error.FailedPrecondition => {},
                    else => return err,
                }
            }
            token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else null;
            if (token == null) break;
        }
        fact("swept {d} keys of earlier runs, deleted {d}, and {d} key rings", .{ ids.items.len, deleted, rings_deleted });
    }

    /// The server's own words when a call fails unexpectedly.
    fn report(f: *const Fixture, err: anyerror) anyerror {
        f.say(err);
        return err;
    }

    fn say(f: *const Fixture, err: anyerror) void {
        std.debug.print("error.{t}", .{err});
        if (f.diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ f.diag.http_status, f.diag.status() });
        if (f.diag.message().len != 0) std.debug.print(": {s}", .{f.diag.message()});
        std.debug.print("\n", .{});
    }

    /// A member the kept key ring grants a role to: the suite's own
    /// principal, most likely. Null when the ring's policy is empty, as it
    /// is when the grants are the project's.
    fn ringMember(f: *Fixture, a: Allocator) !?[]const u8 {
        var policy = f.client.keyRing(f.ring).iamPolicy() catch |err| return f.report(err);
        defer policy.deinit();
        for (policy.value.bindings) |b| {
            if (b.condition == null and b.members.len > 0) return try a.dupe(u8, b.members[0]);
        }
        return null;
    }
};

/// Returns whether the key was deleted.
fn sweepKey(key: kms.Key) !bool {
    var info = key.get() catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
    defer info.deinit();
    if (info.value.rotation_period_s != null or info.value.next_rotation != null) {
        var still = try key.update(.{ .rotation = .clear });
        still.deinit();
    }
    if (try tidyVersions(key, true) > 0) return false;
    try key.delete();
    return true;
}

/// Schedules every enabled or disabled version for destruction, and with
/// `delete_destroyed` deletes every destroyed one. Returns how many are
/// left.
fn tidyVersions(key: kms.Key, delete_destroyed: bool) !usize {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    var left: usize = 0;
    var token: ?[]const u8 = null;
    while (true) {
        var page = try key.listVersions(.{ .page_token = token });
        defer page.deinit();
        for (page.value.versions) |v| {
            const version = key.version(v.id);
            switch (v.state) {
                .destroyed => if (delete_destroyed) {
                    try version.delete();
                    continue;
                },
                .enabled, .disabled => {
                    var gone = try version.destroy();
                    gone.deinit();
                },
                .pending_generation => if (version.waitUntilEnabled(.{ .timeout_ms = 60_000 })) |ready| {
                    var made = ready;
                    made.deinit();
                    var gone = try version.destroy();
                    gone.deinit();
                } else |_| {},
                else => {},
            }
            left += 1;
        }
        token = if (page.value.next_page_token) |t| try scratch.allocator().dupe(u8, t) else null;
        if (token == null) break;
    }
    return left;
}

fn lastPart(name: []const u8) []const u8 {
    return name[if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| i + 1 else 0..];
}

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  " ++ format ++ "\n", args);
}

fn nowNs() i96 {
    return std.Io.Clock.real.now(testing.io).nanoseconds;
}

/// One step of the script, run as the same calls on both sides.
const Op = struct {
    do: Do,
    /// The key's short name: `zigps-<run>-<key>`.
    key: []const u8 = "",
    version: ?u64 = null,
    purpose: kms.Purpose = .encrypt_decrypt,
    algorithm: ?kms.Algorithm = null,
    text: []const u8 = "",
    aad: []const u8 = "",
    /// Where an encrypt keeps its ciphertext and a MAC its tag, for a later
    /// step to use.
    slot: u2 = 0,
    /// Production may still answer as before a state change for a while:
    /// asked again for up to a minute until it agrees.
    settles: bool = false,
};

const Do = enum {
    create,
    /// A key with no version.
    create_bare,
    get_key,
    list_versions,
    wait,
    encrypt,
    decrypt,
    decrypt_garbage,
    create_version,
    set_primary,
    disable,
    enable,
    destroy,
    restore,
    delete_version,
    delete_key,
    label,
    rotate,
    unrotate,
    /// Signs, then verifies here against the version's public key.
    sign,
    /// Signs a digest of the algorithm named, which may not be the key's.
    sign_digest,
    public_key,
    mac_sign,
    mac_verify,
    iam_policy,
    iam_grant,
    iam_test,
    iam_revoke,
    /// The run's own key ring, `zigps-<run>-ring`.
    ring_create,
    ring_delete,
};

const script = [_]Op{
    // A symmetric key: encrypt, decrypt, and the three ways decryption fails.
    .{ .do = .create, .key = "sym" },
    .{ .do = .encrypt, .key = "sym", .text = "hello", .aad = "ctx", .slot = 0 },
    .{ .do = .decrypt, .key = "sym", .slot = 0, .aad = "ctx" },
    .{ .do = .decrypt, .key = "sym", .slot = 0, .aad = "other" },
    .{ .do = .decrypt, .key = "sym", .slot = 0 },
    .{ .do = .decrypt_garbage, .key = "sym" },
    // A second version made primary; the first still decrypts, and can be
    // pinned.
    .{ .do = .create_version, .key = "sym" },
    .{ .do = .set_primary, .key = "sym", .version = 2 },
    .{ .do = .encrypt, .key = "sym", .text = "two", .slot = 1, .settles = true },
    .{ .do = .decrypt, .key = "sym", .slot = 1 },
    .{ .do = .encrypt, .key = "sym", .text = "pinned", .version = 1, .slot = 2 },
    .{ .do = .decrypt, .key = "sym", .slot = 0, .aad = "ctx" },
    // The first version disabled, destroyed, restored.
    .{ .do = .disable, .key = "sym", .version = 1 },
    .{ .do = .decrypt, .key = "sym", .slot = 2, .settles = true },
    .{ .do = .encrypt, .key = "sym", .text = "x", .version = 1, .slot = 3, .settles = true },
    .{ .do = .disable, .key = "sym", .version = 1 },
    .{ .do = .enable, .key = "sym", .version = 1 },
    .{ .do = .decrypt, .key = "sym", .slot = 2, .settles = true },
    .{ .do = .destroy, .key = "sym", .version = 1 },
    .{ .do = .destroy, .key = "sym", .version = 1 },
    .{ .do = .enable, .key = "sym", .version = 1 },
    .{ .do = .decrypt, .key = "sym", .slot = 2, .settles = true },
    .{ .do = .delete_version, .key = "sym", .version = 1 },
    .{ .do = .restore, .key = "sym", .version = 1 },
    .{ .do = .restore, .key = "sym", .version = 1 },
    .{ .do = .enable, .key = "sym", .version = 1 },
    .{ .do = .decrypt, .key = "sym", .slot = 2, .settles = true },
    .{ .do = .list_versions, .key = "sym" },
    // Labels and rotation, and the deletes a key in use refuses.
    .{ .do = .label, .key = "sym" },
    .{ .do = .rotate, .key = "sym" },
    .{ .do = .get_key, .key = "sym" },
    .{ .do = .delete_key, .key = "sym" },
    .{ .do = .unrotate, .key = "sym" },
    .{ .do = .delete_key, .key = "sym" },
    .{ .do = .delete_version, .key = "sym", .version = 2 },
    // A key's IAM, with a member the key ring grants already.
    .{ .do = .iam_policy, .key = "sym" },
    .{ .do = .iam_grant, .key = "sym" },
    .{ .do = .iam_test, .key = "sym" },
    .{ .do = .iam_revoke, .key = "sym" },
    // A signing key of each family, its signatures verified here, and what
    // a signing key will not do.
    .{ .do = .create, .key = "ec", .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256 },
    .{ .do = .wait, .key = "ec", .version = 1 },
    .{ .do = .sign, .key = "ec", .algorithm = .ec_sign_p256_sha256, .text = "message" },
    .{ .do = .sign_digest, .key = "ec", .algorithm = .ec_sign_p384_sha384, .text = "message" },
    .{ .do = .public_key, .key = "ec" },
    .{ .do = .encrypt, .key = "ec", .text = "x", .slot = 3 },
    .{ .do = .set_primary, .key = "ec", .version = 1 },
    .{ .do = .rotate, .key = "ec" },
    .{ .do = .get_key, .key = "ec" },
    .{ .do = .create, .key = "rsa", .purpose = .asymmetric_sign, .algorithm = .rsa_sign_pkcs1_2048_sha256 },
    .{ .do = .wait, .key = "rsa", .version = 1 },
    .{ .do = .sign, .key = "rsa", .algorithm = .rsa_sign_pkcs1_2048_sha256, .text = "message" },
    .{ .do = .create, .key = "pss", .purpose = .asymmetric_sign, .algorithm = .rsa_sign_pss_2048_sha256 },
    .{ .do = .wait, .key = "pss", .version = 1 },
    .{ .do = .sign, .key = "pss", .algorithm = .rsa_sign_pss_2048_sha256, .text = "message" },
    .{ .do = .create, .key = "ed", .purpose = .asymmetric_sign, .algorithm = .ec_sign_ed25519 },
    .{ .do = .wait, .key = "ed", .version = 1 },
    .{ .do = .sign, .key = "ed", .algorithm = .ec_sign_ed25519, .text = "message" },
    .{ .do = .create, .key = "mldsa", .purpose = .asymmetric_sign, .algorithm = .pq_sign_ml_dsa_65 },
    .{ .do = .wait, .key = "mldsa", .version = 1 },
    .{ .do = .sign, .key = "mldsa", .algorithm = .pq_sign_ml_dsa_65, .text = "message" },
    .{ .do = .public_key, .key = "mldsa" },
    // A MAC key.
    .{ .do = .create, .key = "mac", .purpose = .mac, .algorithm = .hmac_sha256 },
    .{ .do = .mac_sign, .key = "mac", .text = "data", .slot = 3 },
    .{ .do = .mac_verify, .key = "mac", .text = "data", .slot = 3 },
    .{ .do = .mac_verify, .key = "mac", .text = "date", .slot = 3 },
    // A key with no version, deleted at once, and its id retired.
    .{ .do = .create_bare, .key = "bare" },
    .{ .do = .get_key, .key = "bare" },
    .{ .do = .delete_key, .key = "bare" },
    .{ .do = .get_key, .key = "bare" },
    .{ .do = .create_bare, .key = "bare" },
    // A key with no version but a rotation scheduled.
    .{ .do = .create_bare, .key = "rot" },
    .{ .do = .rotate, .key = "rot" },
    .{ .do = .delete_key, .key = "rot" },
    .{ .do = .unrotate, .key = "rot" },
    .{ .do = .delete_key, .key = "rot" },
    // What a software key cannot be, and a key that is not there.
    .{ .do = .create, .key = "k1", .purpose = .asymmetric_sign, .algorithm = .ec_sign_secp256k1_sha256 },
    .{ .do = .get_key, .key = "missing" },
    .{ .do = .encrypt, .key = "missing", .text = "x", .slot = 3 },
    // A key ring of the run's own, deleted while empty.
    .{ .do = .ring_create },
    .{ .do = .ring_create },
    .{ .do = .ring_delete },
};

/// One side of the comparison: production, or the fake.
const Side = struct {
    client: *kms.Client,
    diag: *kms.Diagnostics,
    ring: []const u8,
    run: []const u8,
    member: ?[]const u8,
    slots: [4][]const u8 = .{ "", "", "", "" },
};

const iam_role = "roles/cloudkms.viewer";

/// What an operation came to, in words the same for production and the
/// fake.
fn outcome(a: Allocator, s: *Side, op: Op) ![]const u8 {
    const key = s.client.keyRing(s.ring).key(try a.print("zigps-{s}-{s}", .{ s.run, op.key }));
    const run_ring = s.client.keyRing(try a.print("zigps-{s}-ring", .{s.run}));
    switch (op.do) {
        .create, .create_bare => {
            var info = key.create(.{
                .purpose = op.purpose,
                .algorithm = op.algorithm,
                .destroy_delay_s = day_s,
                .first_version = op.do == .create,
            }) catch |err| return failed(a, err);
            defer info.deinit();
            return a.print("ok {s}", .{try summary(a, info.value)});
        },
        .get_key => {
            var info = key.get() catch |err| return failed(a, err);
            defer info.deinit();
            return summary(a, info.value);
        },
        .label, .rotate, .unrotate => {
            const now: std.Io.Timestamp = .{ .nanoseconds = nowNs() };
            var info = key.update(switch (op.do) {
                .label => .{ .labels = .{ .set = &.{.{ .key = "suite", .value = "kms" }} } },
                .rotate => .{ .rotation = .{ .set = .{ .period_s = 30 * day_s, .next = .{ .nanoseconds = now.nanoseconds + 30 * day_ns } } } },
                else => .{ .rotation = .clear },
            }) catch |err| return failed(a, err);
            defer info.deinit();
            return a.print("ok {s}", .{try summary(a, info.value)});
        },
        .list_versions => {
            var page = key.listVersions(.{}) catch |err| return failed(a, err);
            defer page.deinit();
            const versions = try a.dupe(kms.VersionInfo, page.value.versions);
            std.mem.sort(kms.VersionInfo, versions, {}, struct {
                fn lt(_: void, x: kms.VersionInfo, y: kms.VersionInfo) bool {
                    return x.id < y.id;
                }
            }.lt);
            var out: std.Io.Writer.Allocating = .init(a);
            for (versions) |v| try out.writer.print("{d} {t}, ", .{ v.id, v.state });
            return out.written();
        },
        .wait => {
            var info = key.version(op.version.?).waitUntilEnabled(.{ .timeout_ms = 120_000 }) catch |err| return failed(a, err);
            defer info.deinit();
            return a.print("{t}", .{info.value.state});
        },
        .encrypt => {
            var ct = key.encrypt(op.text, .{ .aad = op.aad, .version = op.version }) catch |err| return failed(a, err);
            defer ct.deinit();
            s.slots[op.slot] = try a.dupe(u8, ct.value.bytes);
            return a.print("ok v{d}", .{ct.value.version});
        },
        .decrypt, .decrypt_garbage => {
            const bytes = if (op.do == .decrypt) s.slots[op.slot] else "not a ciphertext of any key, 0123456789abcdef";
            var p = key.decrypt(bytes, .{ .aad = op.aad }) catch |err| return failed(a, err);
            defer p.deinit();
            return a.print("ok {s} primary={}", .{ p.bytes(), p.used_primary });
        },
        .create_version => {
            var v = key.createVersion() catch |err| return failed(a, err);
            defer v.deinit();
            return a.print("ok v{d} {t}", .{ v.value.id, v.value.state });
        },
        .set_primary => {
            var info = key.setPrimary(op.version.?) catch |err| return failed(a, err);
            defer info.deinit();
            return a.print("ok {s}", .{try summary(a, info.value)});
        },
        .disable, .enable, .destroy, .restore => {
            const v = key.version(op.version.?);
            var info = (switch (op.do) {
                .disable => v.disable(),
                .enable => v.enable(),
                .destroy => v.destroy(),
                else => v.restore(),
            }) catch |err| return failed(a, err);
            defer info.deinit();
            if (info.value.destroy_time) |t| {
                const days = @divFloor(t.nanoseconds - nowNs() + day_ns / 2, day_ns);
                return a.print("ok {t}, destroyed in {d} days", .{ info.value.state, days });
            }
            return a.print("ok {t}", .{info.value.state});
        },
        .delete_version => {
            key.version(op.version.?).delete() catch |err| return failed(a, err);
            return "ok";
        },
        .delete_key => {
            key.delete() catch |err| return failed(a, err);
            return "ok";
        },
        .sign => {
            const v = key.version(op.version orelse 1);
            var signature = v.sign(op.algorithm.?, op.text) catch |err| return failed(a, err);
            defer signature.deinit();
            var pk = v.publicKey() catch |err| return failed(a, err);
            defer pk.deinit();
            pk.value.verify(op.text, signature.value) catch |err| return a.print("signed, but {t} here", .{err});
            return "ok verified";
        },
        .sign_digest => {
            var buf: [64]u8 = undefined;
            const digest = op.algorithm.?.signInput().?.digest.digest(op.text, &buf);
            var signature = key.version(op.version orelse 1).signDigest(op.algorithm.?, digest) catch |err| return failed(a, err);
            defer signature.deinit();
            return a.print("ok {d} bytes", .{signature.value.len});
        },
        .public_key => {
            var pk = key.version(op.version orelse 1).publicKey() catch |err| return failed(a, err);
            defer pk.deinit();
            return a.print("ok {t} pem={} raw={}", .{ pk.value.algorithm, pk.value.pem.len > 0, pk.value.raw.len > 0 });
        },
        .mac_sign => {
            var tag = key.version(op.version orelse 1).macSign(op.text) catch |err| return failed(a, err);
            defer tag.deinit();
            s.slots[op.slot] = try a.dupe(u8, tag.value);
            return a.print("ok {d} bytes", .{tag.value.len});
        },
        .mac_verify => {
            const ok = key.version(op.version orelse 1).macVerify(op.text, s.slots[op.slot]) catch |err| return failed(a, err);
            return a.print("{}", .{ok});
        },
        .iam_policy => {
            var policy = key.iamPolicy() catch |err| return failed(a, err);
            defer policy.deinit();
            return a.print("{d} bindings, etag {s}", .{ policy.value.bindings.len, policy.value.etag orelse "none" });
        },
        .iam_grant, .iam_revoke => {
            const member = s.member orelse return "no member to grant";
            var policy = (if (op.do == .iam_grant) key.addIamBinding(iam_role, member) else key.removeIamBinding(iam_role, member)) catch |err| return failed(a, err);
            defer policy.deinit();
            return a.print("ok, granted {}", .{policy.value.grants(iam_role, member)});
        },
        .iam_test => {
            var held = key.testIamPermissions(&.{ "cloudkms.cryptoKeys.get", "cloudkms.cryptoKeyVersions.useToEncrypt" }) catch |err| return failed(a, err);
            defer held.deinit();
            return a.print("{d} held", .{held.value.len});
        },
        .ring_create => {
            var info = run_ring.create() catch |err| return failed(a, err);
            info.deinit();
            return "ok";
        },
        .ring_delete => {
            run_ring.delete() catch |err| return failed(a, err);
            return "ok";
        },
    }
}

fn failed(a: Allocator, err: anyerror) ![]const u8 {
    return a.print("{t}", .{err});
}

/// A key as both sides should show it.
fn summary(a: Allocator, k: kms.KeyInfo) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{t} {t}", .{ k.purpose, k.algorithm });
    if (k.primary) |p| try out.writer.print(", primary {d} {t}", .{ p.id, p.state });
    for (k.labels) |l| try out.writer.print(", {s}={s}", .{ l.key, l.value });
    if (k.rotation_period_s) |r| try out.writer.print(", rotates every {d} s", .{r});
    if (k.next_rotation != null) try out.writer.writeAll(", next rotation set");
    if (k.destroy_delay_s) |d| try out.writer.print(", destroy delay {d} s", .{d});
    return out.written();
}

fn isError(text: []const u8) bool {
    return text.len > 0 and std.ascii.isUpper(text[0]);
}

test "kms: the fake against production, every outcome of one script compared" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const member = try f.ringMember(a);
    if (member == null) fact("the key ring grants no one: the IAM steps say so on both sides", .{});

    var fake: kms.testing.FakeKms = .init(testing.allocator, testing.io, .{ .project_id = f.project });
    defer fake.deinit();
    var fake_diag: kms.Diagnostics = .{};
    var fake_client = try kms.Client.init(testing.allocator, testing.io, .{
        .project_id = f.project,
        .location = f.location,
        .token_provider = f.token.provider(),
        .transport = fake.transport(),
        .diagnostics = &fake_diag,
    });
    defer fake_client.deinit();
    var ring = try fake_client.keyRing(f.ring).create();
    ring.deinit();

    var in_memory: Side = .{ .client = &fake_client, .diag = &fake_diag, .ring = f.ring, .run = f.run, .member = member };
    var production: Side = .{ .client = &f.client, .diag = &f.diag, .ring = f.ring, .run = f.run, .member = member };
    var differences: usize = 0;
    for (script, 0..) |op, i| {
        if (op.do == .create or op.do == .create_bare) try f.track(op.key);
        const fake_says = try outcome(a, &in_memory, op);
        const fake_words = try a.dupe(u8, fake_diag.message());
        var production_says = try outcome(a, &production, op);
        var waited: usize = 0;
        while (op.settles and waited < 60 and !std.mem.eql(u8, production_says, fake_says)) : (waited += 1) {
            try testing.io.sleep(.fromSeconds(1), .awake);
            production_says = try outcome(a, &production, op);
        }
        const name = if (op.key.len > 0) op.key else "ring";
        if (std.mem.eql(u8, production_says, fake_says)) {
            fact("{d}: {t} {s}: {s}", .{ i, op.do, name, production_says });
        } else {
            differences += 1;
            std.debug.print("{d}: {t} {s}\n  production: {s}\n  fake:       {s}\n", .{ i, op.do, name, production_says, fake_says });
        }
        if (waited > 0) fact("   production agreed after {d} s", .{waited});
        if (isError(production_says)) fact("   production said: {s}", .{f.diag.message()});
        if (isError(fake_says) and !std.mem.eql(u8, fake_words, f.diag.message())) fact("   the fake said:   {s}", .{fake_words});
    }
    try testing.expectEqual(0, differences);
}

test "kms: what only production shows: locations, random bytes, the key ring and its policy, pages, retired keys" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Locations, every page: the key ring's is one.
    var token: ?[]const u8 = null;
    var locations: usize = 0;
    var found = false;
    while (true) {
        var page = f.client.listLocations(.{ .page_token = token }) catch |err| return f.report(err);
        defer page.deinit();
        for (page.value.locations) |l| {
            locations += 1;
            if (std.mem.eql(u8, l.id, f.location)) {
                found = true;
                fact("{s}: hsm {}, ekm {}", .{ l.id, l.hsm_available, l.ekm_available });
            }
        }
        token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else null;
        if (token == null) break;
    }
    fact("{d} locations", .{locations});
    try testing.expect(found);

    // Random bytes from an HSM in the location, never the same twice.
    var first = f.client.randomBytes(16) catch |err| return f.report(err);
    defer first.deinit();
    var second = f.client.randomBytes(16) catch |err| return f.report(err);
    defer second.deinit();
    try testing.expectEqual(16, first.value.len);
    try testing.expect(!std.mem.eql(u8, first.value, second.value));

    // The kept key ring, and what its policy lets this principal do.
    const ring = f.client.keyRing(f.ring);
    var info = ring.get() catch |err| return f.report(err);
    defer info.deinit();
    try testing.expectEqualStrings(f.ring, lastPart(info.value.name));
    try testing.expect(info.value.create_time != null);
    var policy = ring.iamPolicy() catch |err| return f.report(err);
    defer policy.deinit();
    for (policy.value.bindings) |b| fact("{s}: {d} members", .{ b.role, b.members.len });
    var held = ring.testIamPermissions(&.{ "cloudkms.keyRings.get", "cloudkms.cryptoKeys.create", "cloudkms.cryptoKeyVersions.useToSign", "cloudkms.cryptoKeyVersions.destroy" }) catch |err| return f.report(err);
    defer held.deinit();
    try testing.expectEqual(4, held.value.len);

    // Keys page by page, as many as in one page, each found by its name.
    var all = ring.listKeys(.{ .page_size = 1000 }) catch |err| return f.report(err);
    defer all.deinit();
    try testing.expect(all.value.next_page_token == null);
    var paged: usize = 0;
    var pages: usize = 0;
    token = null;
    while (true) {
        var page = ring.listKeys(.{ .page_size = 2, .page_token = token }) catch |err| return f.report(err);
        defer page.deinit();
        try testing.expect(page.value.keys.len <= 2);
        paged += page.value.keys.len;
        pages += 1;
        token = if (page.value.next_page_token) |t| try a.dupe(u8, t) else null;
        if (token == null) break;
    }
    fact("{d} keys in the ring, {d} pages of 2", .{ all.value.keys.len, pages });
    try testing.expectEqual(all.value.keys.len, paged);
    if (all.value.keys.len > 0) {
        const named = f.client.keyNamed(all.value.keys[0].name) catch |err| return f.report(err);
        var again = named.get() catch |err| return f.report(err);
        defer again.deinit();
        try testing.expectEqualStrings(all.value.keys[0].name, again.value.name);
    }

    // Retired keys: every deleted key's id, held for good.
    var retired = f.client.listRetiredKeys(.{ .page_size = 5 }) catch |err| return f.report(err);
    defer retired.deinit();
    try testing.expect(retired.value.retired_keys.len <= 5);
    for (retired.value.retired_keys) |r| {
        try testing.expectEqualStrings("CryptoKey", r.resource_type);
        try testing.expect(std.mem.startsWith(u8, r.original_name, "projects/"));
    }
    fact("{d} retired keys on the first page", .{retired.value.retired_keys.len});
}
