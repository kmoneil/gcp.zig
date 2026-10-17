//! Answers production gave on 2026-10-17, measured in milestone 0 of the
//! Resource Manager spec (`_tmp/rm-m0/`) as the zig-gcp service account in
//! extractctl, for tests: verbatim but for a final line break. Test code only.

/// A search as the service account: extractctl alone, no parent key, no labels, no updateTime. HTTP 200.
pub const search_extractctl_status = 200;
pub const search_extractctl =
    \\{"projects":[{"name":"projects/82150720798","projectId":"extractctl","state":"ACTIVE","displayName":"extractctl","createTime":"2026-01-04T23:19:50.778573Z","etag":"W/\"80ecc814d017d568\""}]}
;

/// `GET /v3/projects/extractctl`: what search sent, and updateTime. HTTP 200.
pub const get_extractctl_status = 200;
pub const get_extractctl =
    \\{"name":"projects/82150720798","projectId":"extractctl","state":"ACTIVE","displayName":"extractctl","createTime":"2026-01-04T23:19:50.778573Z","updateTime":"2026-01-04T23:19:50.778573Z","etag":"W/\"80ecc814d017d568\""}
;

/// `GET /v3/projects/bigquery-public-data`: a public project, readable by get though no search shows it. HTTP 200.
pub const get_public_status = 200;
pub const get_public =
    \\{"name":"projects/1057666841514","parent":"folders/460805882129","projectId":"bigquery-public-data","state":"ACTIVE","displayName":"BigQuery Public Data","createTime":"2016-02-12T20:13:32.883Z","updateTime":"2023-01-30T19:32:32.687Z","etag":"W/\"e5c3a763ba492eab\""}
;

/// `GET /v3/projects/1`. HTTP 403.
pub const get_missing_number_status = 403;
pub const get_missing_number =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Permission 'resourcemanager.projects.get' denied on resource '//cloudresourcemanager.googleapis.com/projects/1' (or it may not exist).",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "IAM_PERMISSION_DENIED",
    \\        "domain": "cloudresourcemanager.googleapis.com",
    \\        "metadata": {
    \\          "resource": "projects/1",
    \\          "permission": "resourcemanager.projects.get"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `GET /v3/projects/zigps-no-such-project-x`: the same, with a Troubleshooter link. HTTP 403.
pub const get_missing_id_status = 403;
pub const get_missing_id =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Permission 'resourcemanager.projects.get' denied on resource '//cloudresourcemanager.googleapis.com/projects/zigps-no-such-project-x' (or it may not exist). Remediate access with this Troubleshooter URL or share it with your administrator - https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId=CiQwMWExNGExNC0zZGI4LTdjNGYtYjMyYi04ZWI2NGQ1NTAxMmESIHByb2plY3RzL3ppZ3BzLW5vLXN1Y2gtcHJvamVjdC14 .",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "IAM_PERMISSION_DENIED",
    \\        "domain": "cloudresourcemanager.googleapis.com",
    \\        "metadata": {
    \\          "error_info_id": "CiQwMWExNGExNC0zZGI4LTdjNGYtYjMyYi04ZWI2NGQ1NTAxMmESIHByb2plY3RzL3ppZ3BzLW5vLXN1Y2gtcHJvamVjdC14",
    \\          "troubleshooter_url": "https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId=CiQwMWExNGExNC0zZGI4LTdjNGYtYjMyYi04ZWI2NGQ1NTAxMmESIHByb2plY3RzL3ppZ3BzLW5vLXN1Y2gtcHJvamVjdC14",
    \\          "resource": "projects/zigps-no-such-project-x",
    \\          "permission": "resourcemanager.projects.get"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `GET /v3/projects/Bad_Id!`. HTTP 400.
pub const get_malformed_status = 400;
pub const get_malformed =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Fail to resolve resource 'projects/Bad_Id!'",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `pageSize=-1`. HTTP 400.
pub const page_size_negative_status = 400;
pub const page_size_negative =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [pageSize] has issue [invalid page size]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "pageSize",
    \\            "description": "invalid page size"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `pageSize=2147483648`. HTTP 400.
pub const page_size_overflow_status = 400;
pub const page_size_overflow =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid value at 'page_size' (TYPE_INT32), \"2147483648\"",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "page_size",
    \\            "description": "Invalid value at 'page_size' (TYPE_INT32), \"2147483648\""
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `pageToken=garbage`. HTTP 400.
pub const token_garbage_status = 400;
pub const token_garbage =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Request contains an invalid argument.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `query=foo:bar`. HTTP 400.
pub const query_unknown_field_status = 400;
pub const query_unknown_field =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [query] has issue [Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND (foo : bar)]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "query",
    \\            "description": "Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND (foo : bar)"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `query=name:(`. HTTP 400.
pub const query_syntax_status = 400;
pub const query_syntax =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [query] has issue [invalid syntax]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "query",
    \\            "description": "invalid syntax"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `query=extractctl`: a bare word. HTTP 400.
pub const query_global_restriction_status = 400;
pub const query_global_restriction =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [query] has issue [contains global restriction]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "query",
    \\            "description": "contains global restriction"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `query= `: one space. HTTP 400.
pub const query_space_status = 400;
pub const query_space =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [filter] has issue [Could not parse query]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "filter",
    \\            "description": "Could not parse query"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `query=name:été`. HTTP 400.
pub const query_non_ascii_status = 400;
pub const query_non_ascii =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [query] has issue [Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND (name = été)]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "query",
    \\            "description": "Invalid filter query: resourceType=\"cloudresourcemanager.projects\" AND (name = été)"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `query=parent:folders/1`. HTTP 403.
pub const query_parent_missing_status = 403;
pub const query_parent_missing =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "The caller does not have permission",
    \\    "status": "PERMISSION_DENIED"
    \\  }
    \\}
;

/// `query=parent:organizations/*`. HTTP 400.
pub const query_parent_wildcard_status = 400;
pub const query_parent_wildcard =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [filter] has issue [Parent id must be a number.]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "filter",
    \\            "description": "Parent id must be a number."
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A token with only the userinfo.email scope. HTTP 403.
pub const scope_insufficient_status = 403;
pub const scope_insufficient =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Request had insufficient authentication scopes.",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "service": "cloudresourcemanager.googleapis.com",
    \\          "method": "google.cloud.resourcemanager.v3.Projects.SearchProjects"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// No Authorization header. HTTP 401.
pub const no_credentials_status = 401;
pub const no_credentials =
    \\{
    \\  "error": {
    \\    "code": 401,
    \\    "message": "Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.",
    \\    "status": "UNAUTHENTICATED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "CREDENTIALS_MISSING",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "method": "google.cloud.resourcemanager.v3.Projects.SearchProjects",
    \\          "service": "cloudresourcemanager.googleapis.com"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A bearer token that is no token. HTTP 401.
pub const bad_token_status = 401;
pub const bad_token =
    \\{
    \\  "error": {
    \\    "code": 401,
    \\    "message": "Request had invalid authentication credentials. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.",
    \\    "status": "UNAUTHENTICATED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "ACCESS_TOKEN_TYPE_UNSUPPORTED",
    \\        "metadata": {
    \\          "method": "google.cloud.resourcemanager.v3.Projects.SearchProjects",
    \\          "service": "cloudresourcemanager.googleapis.com"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `x-goog-user-project: bigquery-public-data`, a project the account may not use. HTTP 403.
pub const quota_project_denied_status = 403;
pub const quota_project_denied =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Caller does not have required permission to use project bigquery-public-data. Grant the caller the roles/serviceusage.serviceUsageConsumer role, or a custom role with the serviceusage.services.use permission, by visiting https://console.developers.google.com/iam-admin/iam?project=bigquery-public-data and then retry. Propagation of the new permission may take a few minutes.",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "USER_PROJECT_DENIED",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "consoleUrl": "https://console.developers.google.com/iam-admin/iam?project=bigquery-public-data",
    \\          "containerInfo": "bigquery-public-data",
    \\          "service": "cloudresourcemanager.googleapis.com",
    \\          "consumer": "projects/bigquery-public-data"
    \\        }
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
    \\        "locale": "en-US",
    \\        "message": "Caller does not have required permission to use project bigquery-public-data. Grant the caller the roles/serviceusage.serviceUsageConsumer role, or a custom role with the serviceusage.services.use permission, by visiting https://console.developers.google.com/iam-admin/iam?project=bigquery-public-data and then retry. Propagation of the new permission may take a few minutes."
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.Help",
    \\        "links": [
    \\          {
    \\            "description": "Google developer console IAM admin",
    \\            "url": "https://console.developers.google.com/iam-admin/iam?project=bigquery-public-data"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `x-goog-user-project: zigps-no-such-project-x`, a project that does not exist. HTTP 400.
pub const quota_project_missing_status = 400;
pub const quota_project_missing =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Project 'projects/zigps-no-such-project-x' not found or deleted.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "USER_PROJECT_DENIED",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "containerInfo": "projects/zigps-no-such-project-x",
    \\          "service": "cloudresourcemanager.googleapis.com",
    \\          "consumer": "projects/zigps-no-such-project-x"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `$alt=json;enum-encoding=int`: the state as a number. HTTP 200.
pub const search_enum_int_status = 200;
pub const search_enum_int =
    \\{"projects":[{"name":"projects/82150720798","projectId":"extractctl","state":1,"displayName":"extractctl","createTime":"2026-01-04T23:19:50.778573Z","etag":"W/\"80ecc814d017d568\""}]}
;

/// `GET /v3/folders:search`: the account reads no folder. HTTP 200.
pub const folders_empty_status = 200;
pub const folders_empty =
    \\{}
;

/// `GET /v3/folders:search?query=foo:bar`. HTTP 400.
pub const folders_unknown_field_status = 400;
pub const folders_unknown_field =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "field [query] has issue [Invalid filter query: @type=\"type.googleapis.com/google.cloud.resourcemanager.v2alpha1.Folder\" AND (foo : bar)]",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "query",
    \\            "description": "Invalid filter query: @type=\"type.googleapis.com/google.cloud.resourcemanager.v2alpha1.Folder\" AND (foo : bar)"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `GET /v3/folders/1`. HTTP 403.
pub const folders_get_missing_status = 403;
pub const folders_get_missing =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Permission 'resourcemanager.folders.get' denied on resource '//cloudresourcemanager.googleapis.com/folders/1' (or it may not exist). Remediate access with this Troubleshooter URL or share it with your administrator - https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId=CiQwMWExNGExNC1jMDJmLTcwODctODllOS1hMzk3NjJjYTkzZGISCWZvbGRlcnMvMQ%3D%3D .",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "IAM_PERMISSION_DENIED",
    \\        "domain": "cloudresourcemanager.googleapis.com",
    \\        "metadata": {
    \\          "permission": "resourcemanager.folders.get",
    \\          "error_info_id": "CiQwMWExNGExNC1jMDJmLTcwODctODllOS1hMzk3NjJjYTkzZGISCWZvbGRlcnMvMQ==",
    \\          "resource": "folders/1",
    \\          "troubleshooter_url": "https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId=CiQwMWExNGExNC1jMDJmLTcwODctODllOS1hMzk3NjJjYTkzZGISCWZvbGRlcnMvMQ%3D%3D"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

const std = @import("std");
const core = @import("core");
const testing = std.testing;
const test_util = @import("test_util.zig");
const FakeResourceManager = @import("fake_resource_manager.zig").FakeResourceManager;

/// The fake as the probe found production: the service account, charged
/// to extractctl, which it sees, and `bigquery-public-data`, public.
fn probeFake(clock: *test_util.FakeClock) !FakeResourceManager {
    var fake: FakeResourceManager = .init(testing.allocator, clock.io(), .{});
    errdefer fake.deinit();
    try fake.addProject(.{ .number = 82150720798, .project_id = "extractctl", .display_name = "extractctl" });
    try fake.addProject(.{ .number = 1057666841514, .project_id = "bigquery-public-data", .display_name = "BigQuery Public Data", .parent = "folders/460805882129", .public = true });
    try fake.addPrincipal("sa-token", "extractctl");
    try fake.grant("sa-token", "extractctl");
    return fake;
}

/// The fake's answer, and production's, agree on status, message and
/// every `ErrorInfo`.
fn expectFakeSays(fake: *FakeResourceManager, path: []const u8, header: ?[]const u8, bearer: ?[]const u8, status: u16, production: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const headers: []const core.transport.Header = if (header) |h| &.{.{ .name = "x-goog-user-project", .value = h }} else &.{};
    const url = try std.fmt.allocPrint(a, "https://cloudresourcemanager.googleapis.com{s}", .{path});
    const reply = try fake.serve(.{ .method = .GET, .url = url, .bearer = bearer, .headers = headers }, a);
    try testing.expectEqual(status, reply.status);
    const ours = (try core.errors.decodeErrorBody(a, reply.body)).?;
    const theirs = (try core.errors.decodeErrorBody(a, production)).?;
    try testing.expectEqualStrings(theirs.status, ours.status);
    try testing.expectEqualStrings(theirs.message, ours.message);
    const our_infos = try core.errors.decodeErrorInfos(a, reply.body);
    const their_infos = try core.errors.decodeErrorInfos(a, production);
    try testing.expectEqual(their_infos.len, our_infos.len);
    for (their_infos, our_infos) |t, o| {
        try testing.expectEqualStrings(t.reason, o.reason);
        try testing.expectEqualStrings(t.domain, o.domain);
        try testing.expectEqual(t.metadata.len, o.metadata.len);
        for (t.metadata) |tm| {
            for (o.metadata) |om| {
                if (std.mem.eql(u8, tm.key, om.key)) {
                    try testing.expectEqualStrings(tm.value, om.value);
                    break;
                }
            } else return error.TestMissingMetadata;
        }
    }
}

test "production: the fake refuses what production refused, in its words" {
    var clock: test_util.FakeClock = .{};
    var fake = try probeFake(&clock);
    defer fake.deinit();
    const sa = "sa-token";
    const search = "/v3/projects:search?prettyPrint=false";
    try expectFakeSays(&fake, "/v3/projects/1?prettyPrint=false", null, sa, get_missing_number_status, get_missing_number);
    try expectFakeSays(&fake, "/v3/projects/Bad_Id%21?prettyPrint=false", null, sa, get_malformed_status, get_malformed);
    try expectFakeSays(&fake, "/v3/projects:search?pageSize=-1&prettyPrint=false", null, sa, page_size_negative_status, page_size_negative);
    try expectFakeSays(&fake, "/v3/projects:search?pageSize=2147483648&prettyPrint=false", null, sa, page_size_overflow_status, page_size_overflow);
    try expectFakeSays(&fake, "/v3/projects:search?pageToken=garbage&prettyPrint=false", null, sa, token_garbage_status, token_garbage);
    try expectFakeSays(&fake, "/v3/projects:search?query=foo%3Abar&prettyPrint=false", null, sa, query_unknown_field_status, query_unknown_field);
    try expectFakeSays(&fake, "/v3/projects:search?query=name%3A%28&prettyPrint=false", null, sa, query_syntax_status, query_syntax);
    try expectFakeSays(&fake, "/v3/projects:search?query=extractctl&prettyPrint=false", null, sa, query_global_restriction_status, query_global_restriction);
    try expectFakeSays(&fake, "/v3/projects:search?query=%20&prettyPrint=false", null, sa, query_space_status, query_space);
    try expectFakeSays(&fake, "/v3/projects:search?query=name%3A%C3%A9t%C3%A9&prettyPrint=false", null, sa, query_non_ascii_status, query_non_ascii);
    try expectFakeSays(&fake, search, null, null, no_credentials_status, no_credentials);
    try expectFakeSays(&fake, search, null, "ya29.not-a-token", bad_token_status, bad_token);
    try expectFakeSays(&fake, search, "bigquery-public-data", sa, quota_project_denied_status, quota_project_denied);
    try expectFakeSays(&fake, search, "zigps-no-such-project-x", sa, quota_project_missing_status, quota_project_missing);
}

test "production: the fake's projects are production's, key for key" {
    var clock: test_util.FakeClock = .{ .now_ns = 1_767_568_790_778_573_000 };
    var fake = try probeFake(&clock);
    defer fake.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try fake.serve(.{ .method = .GET, .url = "https://cloudresourcemanager.googleapis.com/v3/projects:search?pageSize=500&prettyPrint=false", .bearer = "sa-token" }, a);
    try expectSameShape(a, search_extractctl, found.body);
    const got = try fake.serve(.{ .method = .GET, .url = "https://cloudresourcemanager.googleapis.com/v3/projects/extractctl?prettyPrint=false", .bearer = "sa-token" }, a);
    try expectSameShape(a, get_extractctl, got.body);
    const public = try fake.serve(.{ .method = .GET, .url = "https://cloudresourcemanager.googleapis.com/v3/projects/bigquery-public-data?prettyPrint=false", .bearer = "sa-token" }, a);
    try testing.expectEqual(200, public.status);
    try expectSameShape(a, get_public, public.body);
}

/// The same keys in the same order, with the same values but for the times
/// and the etag, which are the fake's own.
fn expectSameShape(a: std.mem.Allocator, want: []const u8, got: []const u8) !void {
    const w = try std.json.parseFromSliceLeaky(std.json.Value, a, want, .{});
    const g = try std.json.parseFromSliceLeaky(std.json.Value, a, got, .{});
    if (!sameShape(w, g)) {
        std.debug.print("want: {s}\ngot:  {s}\n", .{ want, got });
        return error.TestExpectedEqual;
    }
}

fn sameShape(x: std.json.Value, y: std.json.Value) bool {
    switch (x) {
        .object => |xo| {
            if (y != .object or xo.count() != y.object.count()) return false;
            for (xo.keys(), y.object.keys(), xo.values(), y.object.values()) |xk, yk, xv, yv| {
                if (!std.mem.eql(u8, xk, yk)) return false;
                const own = std.mem.endsWith(u8, xk, "Time") or std.mem.eql(u8, xk, "etag");
                if (own) {
                    if (xv != .string or yv != .string) return false;
                } else if (!sameShape(xv, yv)) return false;
            }
            return true;
        },
        .array => |xa| {
            if (y != .array or xa.items.len != y.array.items.len) return false;
            for (xa.items, y.array.items) |xi, yi| if (!sameShape(xi, yi)) return false;
            return true;
        },
        .string => |s| return y == .string and std.mem.eql(u8, s, y.string),
        .integer => |i| return y == .integer and i == y.integer,
        .bool => |b| return y == .bool and b == y.bool,
        .null => return y == .null,
        .float => |f| return y == .float and f == y.float,
        .number_string => |s| return y == .number_string and std.mem.eql(u8, s, y.number_string),
    }
}
