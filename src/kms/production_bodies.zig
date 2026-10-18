//! Answers production gave, kept verbatim, from milestone 0 of the KMS
//! spec (`_tmp/kms-m0/probe-*.json`, extractctl, 2026-10-18). Tests hold
//! the client, and the fake, to them.

/// A key deleted: the operation's first answer is not done.
pub const delete_key_started =
    \\{"name":"projects/extractctl/locations/us-central1/operations/6f74f131-e1d9-404a-b8af-1b71cc214ada","metadata":{"@type":"type.googleapis.com/google.cloud.kms.v1.DeleteCryptoKeyMetadata","retiredResource":"projects/extractctl/locations/us-central1/retiredResources/037a6e3d-f7e3-4d1f-9e7e-55e40572b59c"}}
;

/// The same operation, read 0.2 s later: done.
pub const delete_key_done =
    \\{"name":"projects/extractctl/locations/us-central1/operations/6f74f131-e1d9-404a-b8af-1b71cc214ada","done":true,"response":{"@type":"type.googleapis.com/google.protobuf.Empty"}}
;

/// A key created again under the id of one deleted: 400, not 409.
pub const create_retired_key =
    \\{"error":{"code":400,"message":"CryptoKey projects/extractctl/locations/us-central1/keyRings/zigps-kms/cryptoKeys/zigps-m0-fe7c50-bare has already been deleted and has the following RetiredResource name: projects/extractctl/locations/us-central1/retiredResources/037a6e3d-f7e3-4d1f-9e7e-55e40572b59c.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"RESOURCE_DELETED","domain":"cloudkms.googleapis.com","metadata":{"resource_name":"projects/extractctl/locations/us-central1/keyRings/zigps-kms/cryptoKeys/zigps-m0-fe7c50-bare","retired_resource_name":"projects/extractctl/locations/us-central1/retiredResources/037a6e3d-f7e3-4d1f-9e7e-55e40572b59c"}}]}}
;
