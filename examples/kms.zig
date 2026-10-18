//! Uses Cloud KMS keys of each kind once: encrypts and decrypts with a
//! symmetric key, signs with an EC P-256 key and checks the signature on
//! this machine, tags data with an HMAC key and checks the tag, and asks
//! for random bytes; then schedules every version it made for
//! destruction.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project KMS_KEY_RING=my-ring zig build example-kms
//!     zig build example-kms -- --fake     # no network
//!
//! Credentials come from `auth.findDefault`. The key ring, in
//! KMS_LOCATION (us-central1 when unset), is created if it is not there;
//! the principal needs Cloud KMS Admin and Cloud KMS CryptoKey Operator
//! on it. `--fake` uses `kms.testing.FakeKms` instead.
//!
//! Each run makes three keys, `example-<run>-sym`, `-sig` and `-mac`,
//! software keys with a 1-day destroy delay: their versions are billed
//! until destroyed, a day after the run, about a cent in all. A deleted
//! key's id is never usable again, so the keys are left for a later run
//! of your own to delete once destroyed (`KeyVersion.delete`, then
//! `Key.delete`).

const std = @import("std");
const auth = @import("auth");
const kms = @import("kms");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_kms, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: kms.Diagnostics = .{};

    var use_fake = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--fake")) {
            use_fake = true;
        } else return usage();
    }

    var fake: kms.testing.FakeKms = .init(init.gpa, init.io, .{ .project_id = "my-project" });
    defer fake.deinit();
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    var static: kms.StaticToken = .{ .token = "fake" };
    const project = if (use_fake) "my-project" else init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse {
        std.debug.print("set GOOGLE_CLOUD_PROJECT to the project whose keys to use\n", .{});
        return error.MissingProject;
    };
    const ring_id = if (use_fake) "example" else init.environ_map.get("KMS_KEY_RING") orelse {
        std.debug.print("set KMS_KEY_RING to the key ring to make the example's keys in\n", .{});
        return error.MissingKeyRing;
    };
    const location = if (use_fake) "us-central1" else init.environ_map.get("KMS_LOCATION") orelse "us-central1";
    if (!use_fake) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    }
    var client = kms.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .location = location,
        .token_provider = if (creds) |*c| c.provider() else static.provider(),
        .transport = if (use_fake) fake.transport() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    const ring = client.keyRing(ring_id);
    if (ring.create()) |made| {
        var info = made;
        defer info.deinit();
        try out.print("made key ring {s}\n", .{info.value.name});
    } else |err| if (err != error.AlreadyExists) return fail(err, &diag);

    var run_bytes: [3]u8 = undefined;
    init.io.random(&run_bytes);
    const run = try std.fmt.allocPrint(arena, "{x}", .{run_bytes});
    const day = std.time.s_per_day;

    // A symmetric key: encrypt with AAD, decrypt with the same AAD.
    const sym = ring.key(try std.fmt.allocPrint(arena, "example-{s}-sym", .{run}));
    var sym_info = sym.create(.{ .purpose = .encrypt_decrypt, .destroy_delay_s = day }) catch |err| return fail(err, &diag);
    sym_info.deinit();
    const secret = "the launch code is 0000";
    var sealed = sym.encrypt(secret, .{ .aad = "record-42" }) catch |err| return fail(err, &diag);
    defer sealed.deinit();
    try out.print("encrypted {d} bytes into {d} with version {d} of {s}\n", .{ secret.len, sealed.value.bytes.len, sealed.value.version, sym.id() });
    var opened = sym.decrypt(sealed.value.bytes, .{ .aad = "record-42" }) catch |err| return fail(err, &diag);
    defer opened.deinit();
    try out.print("decrypted: \"{s}\" (shown here only because it is an example)\n", .{opened.bytes()});
    if (sym.decrypt(sealed.value.bytes, .{ .aad = "record-43" })) |wrong| {
        var w = wrong;
        w.deinit();
        try out.writeAll("another record's AAD decrypted: that should not happen\n");
    } else |err| try out.print("another record's AAD: error.{t}\n", .{err});

    // A signing key: sign, then check the signature here.
    const sig = ring.key(try std.fmt.allocPrint(arena, "example-{s}-sig", .{run}));
    var sig_info = sig.create(.{ .purpose = .asymmetric_sign, .algorithm = .ec_sign_p256_sha256, .destroy_delay_s = day }) catch |err| return fail(err, &diag);
    sig_info.deinit();
    var ready = sig.version(1).waitUntilEnabled(.{}) catch |err| return fail(err, &diag);
    ready.deinit();
    const manifest = "release v1.2.3, sha256 of the tarball 2c26b46b...";
    var signature = sig.version(1).sign(.ec_sign_p256_sha256, manifest) catch |err| return fail(err, &diag);
    defer signature.deinit();
    var public_key = sig.version(1).publicKey() catch |err| return fail(err, &diag);
    defer public_key.deinit();
    public_key.value.verify(manifest, signature.value) catch |err| return fail(err, &diag);
    try out.print("signed {d} bytes: a {d}-byte signature, verified here against the public key\n", .{ manifest.len, signature.value.len });
    try out.print("{s}", .{public_key.value.pem});

    // A MAC key: tag, and check the tag in Cloud KMS.
    const mac = ring.key(try std.fmt.allocPrint(arena, "example-{s}-mac", .{run}));
    var mac_info = mac.create(.{ .purpose = .mac, .algorithm = .hmac_sha256, .destroy_delay_s = day }) catch |err| return fail(err, &diag);
    mac_info.deinit();
    const body = "{\"order\":42,\"total\":\"19.99\"}";
    var tag = mac.version(1).macSign(body) catch |err| return fail(err, &diag);
    defer tag.deinit();
    const genuine = mac.version(1).macVerify(body, tag.value) catch |err| return fail(err, &diag);
    const altered = mac.version(1).macVerify("{\"order\":42,\"total\":\"0.99\"}", tag.value) catch |err| return fail(err, &diag);
    try out.print("tagged a webhook body: {d}-byte tag; genuine {}, altered {}\n", .{ tag.value.len, genuine, altered });

    // Random bytes from an HSM in the location.
    if (client.randomBytes(16)) |random| {
        var r = random;
        defer r.deinit();
        try out.print("16 random bytes: {x}\n", .{r.value});
    } else |err| try out.print("random bytes: error.{t} (needs cloudkms.locations.generateRandomBytes)\n", .{err});

    // Every version made is billed until destroyed: schedule them all.
    for ([_]kms.Key{ sym, sig, mac }) |key| {
        var gone = key.version(1).destroy() catch |err| return fail(err, &diag);
        defer gone.deinit();
        try out.print("{s} version 1: {t}\n", .{ key.id(), gone.value.state });
    }
    try out.flush();
}

fn usage() error{Usage} {
    std.debug.print("usage: kms [--fake]\n", .{});
    return error.Usage;
}

fn fail(err: anyerror, diag: *const kms.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
