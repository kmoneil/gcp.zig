//! What the Google Cloud modules share: Google's half of a REST client
//! (its API errors, request loop hook, IAM policies, resource names, CRC-32C
//! and the `Signer` seam) over rest-core's cloud-neutral half (the HTTP
//! transport, the retry policy, `Diagnostics`, `Owned` results, the
//! `TokenProvider` seam, time, RSA and test fakes).
//! Applications rarely import this module directly; each service module
//! re-exports what its callers need.

const rest_core = @import("rest_core");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in tests.
pub const transport = rest_core.transport;

/// The request loop every service module runs: credentials, retries, error
/// mapping and diagnostics.
pub const rpc = @import("rpc.zig");

/// Resource-name rules more than one service needs.
pub const names = @import("names.zig");

/// Turning a configured endpoint into the base URL of every request.
pub const endpoint = @import("endpoint.zig");

/// Base64, as Google's JSON APIs carry `bytes` fields.
pub const base64 = rest_core.base64;

pub const RetryPolicy = rest_core.RetryPolicy;
pub const isRetryable = @import("retry.zig").isRetryable;

/// A refused response's own retry delay: `Retry-After`, `retry-after-ms`
/// and `google.rpc.RetryInfo`, read into milliseconds.
pub const retry_after = @import("retry_after.zig");

/// The Google API error body, status mapping and `Diagnostics`.
pub const errors = @import("errors.zig");
pub const ApiError = errors.ApiError;
pub const Diagnostics = rest_core.Diagnostics;

pub const Owned = rest_core.Owned;

/// A request as a client would send it, built without sending it, for a
/// caller that shows a write before making it. Service modules re-export it.
pub const PreparedRequest = @import("PreparedRequest.zig");

/// What an update does to a setting that can be taken away: `.keep`,
/// `.set`, or `.clear`. Service modules re-export it.
pub const Change = rest_core.Change;

/// IAM policies as `getIamPolicy` and `setIamPolicy` read and write them.
pub const iam = @import("iam.zig");

/// The seam through which service modules get bearer tokens.
pub const TokenProvider = rest_core.TokenProvider;
pub const StaticToken = rest_core.StaticToken;

/// The seam through which a service module signs as a service account,
/// as a signed URL needs.
pub const Signer = @import("Signer.zig");

/// An allocator that wipes memory before freeing it, for secrets.
pub const WipingAllocator = rest_core.WipingAllocator;

/// A writer that counts what passes through it to another writer.
pub const CountingWriter = rest_core.CountingWriter;

/// A writer that splits a streamed JSON array into its elements as they
/// arrive, as Firestore's streamed answers travel.
pub const JsonArraySplitter = @import("JsonArraySplitter.zig");

/// CRC-32C, the checksum Google sends beside payload bytes.
pub const crc32c = @import("crc32c.zig");

/// RSA with a private key held here: PKCS#1 v1.5 and PSS signatures from a
/// digest, as a service account key signs and as Cloud KMS's fake does, and
/// public keys read and written as SubjectPublicKeyInfo.
pub const rsa = rest_core.rsa;

/// gzip, zlib and deflate decompression: std's.
pub const flate = @import("flate.zig");

/// Percent-encoding for request paths, and a query-string builder.
pub const query = rest_core.query;

/// Logging under each module's own scope, captured in test builds.
pub const logging = rest_core.logging;

/// RFC 3339 timestamps, as Google's APIs send them.
pub const timestamp = rest_core.timestamp;
/// Durations, as Google's JSON APIs write them: `600s`, `1.500s`.
pub const duration = @import("duration.zig");
/// gzip for request bodies held whole in memory, checked by reading back.
pub const gzip = @import("gzip.zig");

/// Fakes and property-test helpers, for tests only.
pub const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("JsonArraySplitter.zig");
    _ = @import("PreparedRequest.zig");
    _ = @import("Signer.zig");
    _ = @import("crc32c.zig");
    _ = @import("duration.zig");
    _ = @import("endpoint.zig");
    _ = @import("errors.zig");
    _ = @import("flate.zig");
    _ = @import("gzip.zig");
    _ = @import("iam.zig");
    _ = @import("names.zig");
    _ = @import("retry.zig");
    _ = @import("retry_after.zig");
    _ = @import("rpc.zig");
    _ = @import("testing.zig");
}
