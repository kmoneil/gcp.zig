//! What Google's OAuth token endpoint and the metadata server send back:
//! `{"access_token", "expires_in", "token_type"}` with a token, and
//! `{"error", "error_description"}` when the token endpoint refuses. The
//! error shape differs from the Google API one: `error` is a string here.
//! A refusal may also ask for a wait before the next attempt.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const Cache = @import("Cache.zig");

pub const ParseError = error{ InvalidTokenResponse, OutOfMemory };

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .duplicate_field_behavior = .use_last,
    .allocate = .alloc_if_needed,
};

/// The token and its lifetime from a success body. The cache checks that
/// both are usable. The token may point into `body`.
pub fn parse(arena: Allocator, body: []const u8) ParseError!Cache.Fetched {
    const Wire = struct {
        access_token: ?[]const u8 = null,
        expires_in: ?i64 = null,
        token_type: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, parse_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTokenResponse,
    };
    const token = wire.access_token orelse return error.InvalidTokenResponse;
    const expires_in = wire.expires_in orelse return error.InvalidTokenResponse;
    // A token of another type would not work as a bearer token.
    if (wire.token_type) |t| if (!std.ascii.eqlIgnoreCase(t, "Bearer")) return error.InvalidTokenResponse;
    return .{ .token = token, .expires_in = expires_in };
}

/// https anywhere, or plain http to this machine (127.0.0.1, [::1] or
/// localhost), as tests use. Credentials travel to the token endpoint, so
/// it must not cross a network in the clear.
pub fn isAcceptableTokenUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const component = uri.host orelse return false;
    var buf: [256]u8 = undefined;
    const host = component.toRaw(&buf) catch return false;
    if (host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]") or std.ascii.eqlIgnoreCase(host, "localhost");
}

/// An OAuth error, such as `invalid_grant`.
pub const OAuthError = struct {
    code: []const u8,
    /// "" when the server sent none.
    description: []const u8,
};

/// The wait a refused answer asked for, from `Retry-After`,
/// `retry-after-ms` or a RetryInfo detail; null when it asked for none.
/// It is kept in `diag` too, so call this after `diag.set`, which clears it.
pub fn askedDelayMs(io: std.Io, arena: Allocator, res: core.transport.Response, diag: ?*core.Diagnostics) Allocator.Error!?u32 {
    const ms = try core.retry_after.serverDelayMs(arena, res.headers, res.body, std.Io.Clock.real.now(io));
    if (diag) |d| d.retry_after_ms = ms;
    return ms;
}

/// The OAuth error in `body`, or null when the body is not one.
pub fn parseError(arena: Allocator, body: []const u8) Allocator.Error!?OAuthError {
    const Wire = struct {
        @"error": ?[]const u8 = null,
        error_description: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, parse_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const code = wire.@"error" orelse return null;
    return .{ .code = code, .description = wire.error_description orelse "" };
}

/// What a token response says of the account it was issued for.
pub const Identity = union(enum) {
    /// The account's email, pointing into `arena`.
    email: []const u8,
    /// Why it names no account, for Diagnostics.
    none: []const u8,
};

/// The account a token endpoint's `body` names in its `id_token`, as an
/// OAuth refresh of a login that granted `openid` and `userinfo.email`
/// sends one. OpenID Connect Core 3.1.3.7 lets a client take an id_token
/// that came straight from the token endpoint over TLS without checking
/// its signature, and Google says the same of its own; the other checks
/// stay: `iss` is Google's, `aud` holds `client_id`, and `email_verified`
/// is true. Google writes that claim as a boolean in an id_token and as a
/// string in tokeninfo, so both are taken.
pub fn identity(arena: Allocator, body: []const u8, client_id: []const u8) Allocator.Error!Identity {
    const Wire = struct { id_token: ?[]const u8 = null };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, parse_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .none = "the token endpoint's answer is not JSON" },
    };
    const jwt = wire.id_token orelse
        return .{ .none = "the token endpoint sent no id_token: the login may lack the openid and userinfo.email scopes" };
    return idTokenIdentity(arena, jwt, client_id);
}

/// `identity`'s checks on the id_token itself.
pub fn idTokenIdentity(arena: Allocator, jwt: []const u8, client_id: []const u8) Allocator.Error!Identity {
    const malformed: Identity = .{ .none = "the id_token is not a JWT with a JSON payload" };
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next();
    const encoded = parts.next() orelse return malformed;
    // The signature, which is not checked, must still be there.
    _ = parts.next() orelse return malformed;
    if (parts.next() != null) return malformed;
    const json = core.base64.decode(arena, encoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase64 => return malformed,
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return malformed,
    };
    if (value != .object) return malformed;
    const claims = value.object;
    const iss = stringOf(claims.get("iss")) orelse "";
    if (!std.mem.eql(u8, iss, "https://accounts.google.com") and !std.mem.eql(u8, iss, "accounts.google.com")) {
        return .{ .none = "the id_token was not issued by Google" };
    }
    if (!holdsAudience(claims.get("aud"), client_id)) return .{ .none = "the id_token was not issued to this login's client" };
    const email = stringOf(claims.get("email")) orelse
        return .{ .none = "the id_token carries no email: the login may lack the userinfo.email scope" };
    if (!isVerified(claims.get("email_verified"))) return .{ .none = "the id_token's email is not verified" };
    if (!isAccount(email)) return .{ .none = "the id_token's email is not an address" };
    return .{ .email = email };
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

/// `aud` is one string, or an array of them, as OIDC allows.
fn holdsAudience(value: ?std.json.Value, client_id: []const u8) bool {
    const v = value orelse return false;
    switch (v) {
        .string => |s| return std.mem.eql(u8, s, client_id),
        .array => |list| {
            for (list.items) |item| if (item == .string and std.mem.eql(u8, item.string, client_id)) return true;
            return false;
        },
        else => return false,
    }
}

fn isVerified(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        else => false,
    };
}

/// An address as Google writes one: visible ASCII, at most 320 bytes, with
/// something on each side of an `@`.
pub fn isAccount(text: []const u8) bool {
    if (text.len == 0 or text.len > 320) return false;
    for (text) |c| if (c <= ' ' or c >= 0x7f) return false;
    const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return false;
    return at > 0 and at + 1 < text.len;
}

const testing = std.testing;
const test_util = @import("core").testing;

test "token_response: a token and its lifetime" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try parse(a,
        \\{"access_token": "ya29.a0-token", "expires_in": 3599,
        \\ "scope": "https://www.googleapis.com/auth/cloud-platform", "token_type": "Bearer"}
    );
    try testing.expectEqualStrings("ya29.a0-token", got.token);
    try testing.expectEqual(3599, got.expires_in);
    // The metadata server sends no scope; either may leave out the type.
    _ = try parse(a, "{\"access_token\":\"t\",\"expires_in\":1}");
    _ = try parse(a, "{\"access_token\":\"t\",\"expires_in\":1,\"token_type\":\"bearer\"}");
    // std.json reads an integral number however it is written.
    try testing.expectEqual(3599, (try parse(a, "{\"access_token\":\"t\",\"expires_in\":\"3599\"}")).expires_in);
    try testing.expectEqual(3599, (try parse(a, "{\"access_token\":\"t\",\"expires_in\":3599.0}")).expires_in);
}

test "token_response: a body without a usable token is InvalidTokenResponse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"expires_in\":3599}",
        "{\"access_token\":\"t\"}",
        "{\"access_token\":\"t\",\"expires_in\":3599.5}",
        "{\"access_token\":\"t\",\"expires_in\":99999999999999999999}",
        "{\"access_token\":\"t\",\"expires_in\":3599,\"token_type\":\"mac\"}",
        "{\"access_token\":42,\"expires_in\":3599}",
        "<html>Bad Gateway</html>",
        "",
    }) |body| try testing.expectError(error.InvalidTokenResponse, parse(a, body));
}

test "token_response: OAuth errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = (try parseError(a, "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}")).?;
    try testing.expectEqualStrings("invalid_grant", e.code);
    try testing.expectEqualStrings("Token has been expired or revoked.", e.description);
    try testing.expectEqualStrings("", (try parseError(a, "{\"error\":\"invalid_client\"}")).?.description);
    // The Google API shape, and bodies that are no error at all.
    try testing.expectEqual(null, try parseError(a, "{\"error\":{\"code\":400,\"status\":\"INVALID_ARGUMENT\"}}"));
    try testing.expectEqual(null, try parseError(a, "{}"));
    try testing.expectEqual(null, try parseError(a, "<html></html>"));
}

test "token_response: running out of memory is OutOfMemory, never a verdict on the body" {
    // Escapes make std.json allocate; without them it points into the body.
    // Each parser gets its own sweep: an arena that one call has grown would
    // serve the next without asking the failing allocator.
    const Run = struct {
        fn token(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const got = try parse(arena.allocator(), "{\"access_token\":\"ya29.\\u0061b\",\"expires_in\":3599}");
            try testing.expectEqualStrings("ya29.ab", got.token);
        }

        fn oauthError(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const e = try parseError(arena.allocator(), "{\"error\":\"invalid_grant\",\"error_description\":\"it\\u0027s gone\"}") orelse
                return error.TestExpectedOAuthError;
            try testing.expectEqualStrings("it's gone", e.description);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.token, .{});
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.oauthError, .{});
}

fn arbitraryProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Total: every body yields a value, null or InvalidTokenResponse.
    _ = parse(arena.allocator(), input) catch |err| try testing.expectEqual(error.InvalidTokenResponse, err);
    _ = try parseError(arena.allocator(), input);
}

/// A JWT with `payload` as its claims, base64url without padding, as
/// Google writes them; its header and signature mean nothing here.
fn jwtOf(arena: Allocator, payload: []const u8) ![]const u8 {
    const codec = std.base64.url_safe_no_pad.Encoder;
    const header = "{\"alg\":\"RS256\",\"kid\":\"k1\",\"typ\":\"JWT\"}";
    var out: std.Io.Writer.Allocating = .init(arena);
    try codec.encodeWriter(&out.writer, header);
    try out.writer.writeByte('.');
    try codec.encodeWriter(&out.writer, payload);
    try out.writer.writeAll(".c2lnbmF0dXJl");
    return out.written();
}

const test_client = "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com";

/// The claims production's refresh of a gcloud application-default login
/// carried on 2026-10-17, every value made up but their shapes.
const refreshed_claims =
    \\{"iss":"https://accounts.google.com","azp":"764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com","aud":"764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com","sub":"104223497553108011111","hd":"example.com","email":"person@example.com","email_verified":true,"at_hash":"bGWy3hA0Jp1d5Sv0x6m7Ig","iat":1792255951,"exp":1792259551}
;

test "identity: the email of a refresh's id_token, as production sent it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try a.print("{{\"access_token\":\"ya29.x\",\"expires_in\":3599,\"scope\":\"openid https://www.googleapis.com/auth/userinfo.email\",\"token_type\":\"Bearer\",\"id_token\":\"{s}\"}}", .{try jwtOf(a, refreshed_claims)});
    try testing.expectEqualStrings("person@example.com", (try identity(a, body, test_client)).email);
    // Another client's login is not taken for this one.
    try testing.expectEqualStrings("the id_token was not issued to this login's client", (try identity(a, body, "other.apps.googleusercontent.com")).none);
}

test "identity: each check, and what it says when it fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const accepted = [_][]const u8{
        "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email\":\"p@x.com\",\"email_verified\":true}",
        // tokeninfo's spelling of the claim, a string.
        "{\"iss\":\"https://accounts.google.com\",\"aud\":\"c\",\"email\":\"p@x.com\",\"email_verified\":\"true\"}",
        "{\"iss\":\"https://accounts.google.com\",\"aud\":[\"other\",\"c\"],\"email\":\"p@x.com\",\"email_verified\":true}",
    };
    for (accepted) |claims| try testing.expectEqualStrings("p@x.com", (try idTokenIdentity(a, try jwtOf(a, claims), "c")).email);

    const refused = [_]struct { []const u8, []const u8 }{
        .{ "{\"aud\":\"c\",\"email\":\"p@x.com\",\"email_verified\":true}", "the id_token was not issued by Google" },
        .{ "{\"iss\":\"https://evil.example\",\"aud\":\"c\",\"email\":\"p@x.com\",\"email_verified\":true}", "the id_token was not issued by Google" },
        .{ "{\"iss\":\"accounts.google.com\",\"email\":\"p@x.com\",\"email_verified\":true}", "the id_token was not issued to this login's client" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":[\"other\"],\"email\":\"p@x.com\",\"email_verified\":true}", "the id_token was not issued to this login's client" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":7,\"email\":\"p@x.com\",\"email_verified\":true}", "the id_token was not issued to this login's client" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email_verified\":true}", "the id_token carries no email: the login may lack the userinfo.email scope" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email\":\"p@x.com\"}", "the id_token's email is not verified" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email\":\"p@x.com\",\"email_verified\":false}", "the id_token's email is not verified" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email\":\"p@x.com\",\"email_verified\":\"false\"}", "the id_token's email is not verified" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email\":\"p@x.com\",\"email_verified\":1}", "the id_token's email is not verified" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email\":\"p x@x.com\",\"email_verified\":true}", "the id_token's email is not an address" },
        .{ "{\"iss\":\"accounts.google.com\",\"aud\":\"c\",\"email\":\"@x.com\",\"email_verified\":true}", "the id_token's email is not an address" },
        .{ "[1,2]", "the id_token is not a JWT with a JSON payload" },
        .{ "not json", "the id_token is not a JWT with a JSON payload" },
    };
    for (refused) |case| try testing.expectEqualStrings(case[1], (try idTokenIdentity(a, try jwtOf(a, case[0]), "c")).none);

    const good = try jwtOf(a, accepted[0]);
    const dot = std.mem.indexOfScalar(u8, good, '.').?;
    for ([_][]const u8{ "", "a", "a.b", "a.b.c.d", "a.!!!.c", good[0..std.mem.lastIndexOfScalar(u8, good, '.').?] }) |jwt| {
        try testing.expectEqualStrings("the id_token is not a JWT with a JSON payload", (try idTokenIdentity(a, jwt, "c")).none);
    }
    // A fourth part makes it no JWT, though the payload would pass.
    try testing.expectEqualStrings("the id_token is not a JWT with a JSON payload", (try idTokenIdentity(a, try a.print("{s}.x", .{good}), "c")).none);
    // The header is not read: only the payload names the account.
    try testing.expectEqualStrings("p@x.com", (try idTokenIdentity(a, try a.print("x{s}", .{good[dot..]}), "c")).email);

    try testing.expectEqualStrings("the token endpoint sent no id_token: the login may lack the openid and userinfo.email scopes", (try identity(a, "{\"access_token\":\"t\",\"expires_in\":1}", "c")).none);
    try testing.expectEqualStrings("the token endpoint's answer is not JSON", (try identity(a, "<html>", "c")).none);
}

test "isAccount" {
    for ([_][]const u8{ "a@b", "person@example.com", "robot@p.iam.gserviceaccount.com" }) |good| try testing.expect(isAccount(good));
    for ([_][]const u8{ "", "ab", "@b", "a@", "a b@c", "a@b\x7f", "a\t@b", "\xc3\xa9@b" }) |bad| try testing.expect(!isAccount(bad));
    try testing.expect(isAccount("a@" ++ test_util.repeat("b", 318)));
    try testing.expect(!isAccount("a@" ++ test_util.repeat("b", 319)));
}

test "identity: running out of memory is OutOfMemory, never a verdict" {
    // The body is built outside the sweep: only `identity` meets failures.
    var built: std.heap.ArenaAllocator = .init(testing.allocator);
    defer built.deinit();
    const body = try built.allocator().print("{{\"id_token\":\"{s}\"}}", .{try jwtOf(built.allocator(), refreshed_claims)});
    const Run = struct {
        fn run(gpa: Allocator, sent: []const u8) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            try testing.expectEqualStrings("person@example.com", (try identity(arena.allocator(), sent, test_client)).email);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{body});
}

fn identityProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    // A model: claims drawn from what passes and what does not, the answer
    // an email exactly when every check passes.
    const iss = g.pick([]const u8, &.{ "https://accounts.google.com", "accounts.google.com", "https://accounts.google.com/", "", "x" });
    const aud = g.pick([]const u8, &.{ "\"c\"", "[\"c\"]", "[\"d\",\"c\"]", "\"d\"", "[]", "null" });
    const email = g.pick([]const u8, &.{ "\"p@x.com\"", "\"p@\"", "null", "3" });
    const verified = g.pick([]const u8, &.{ "true", "\"true\"", "false", "\"True\"", "null" });
    const claims = try a.print("{{\"iss\":\"{s}\",\"aud\":{s},\"email\":{s},\"email_verified\":{s}}}", .{ iss, aud, email, verified });
    const got = try idTokenIdentity(a, try jwtOf(a, claims), "c");
    const passes = (std.mem.eql(u8, iss, "https://accounts.google.com") or std.mem.eql(u8, iss, "accounts.google.com")) and
        std.mem.indexOf(u8, aud, "\"c\"") != null and
        std.mem.eql(u8, email, "\"p@x.com\"") and
        (std.mem.eql(u8, verified, "true") or std.mem.eql(u8, verified, "\"true\""));
    if (passes) try testing.expectEqualStrings("p@x.com", got.email) else try testing.expect(got == .none);
    // And whatever the rest of the input is, as a body or as a token: an
    // answer, never a crash.
    const rest = g.rest();
    _ = try identity(a, rest, "c");
    _ = try idTokenIdentity(a, rest, "c");
}

test "fuzz identity: a model of the checks, and arbitrary bodies and tokens" {
    try test_util.fuzzBytes({}, identityProperty, .{ .corpus = &.{ "", "\x00\x00\x00\x00{\"id_token\":\"a.e30.c\"}", "\x01\x02\x03\x04a.bm90.c" } });
}

test "fuzz token_response: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{
        "{\"access_token\":\"t\",\"expires_in\":3599,\"token_type\":\"Bearer\"}",
        "{\"error\":\"invalid_grant\",\"error_description\":\"x\"}",
        "{\"access_token\":\"\\ud800\",\"expires_in\":-1}",
    } });
}
