//! `Error`: every error a Cloud KMS call can return. The API statuses,
//! their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// A project, location, key ring, key or version this client will not
    /// put in a request: key ring and key ids are 1 to 63 of
    /// `[a-zA-Z0-9_-]`, versions are numbered from 1. Nothing is sent.
    InvalidName,
    /// Options out of range: a retry policy, a user agent, a destroy delay
    /// outside 1 to 120 days, rotation under a day or on a key that cannot
    /// rotate, an algorithm of another purpose, labels that break the
    /// rules, a filter with control characters.
    InvalidOptions,
    /// A version that cannot be used yet: still `PENDING_GENERATION`, as a
    /// new asymmetric version is for a while. `KeyVersion.waitUntilEnabled`
    /// waits it out. `Diagnostics` names the version.
    KeyVersionPending,
    /// A version that is `DISABLED`: enabling it makes it usable again.
    /// `Diagnostics` names the version, which for a decrypt is the only
    /// place the API says which version a ciphertext needs.
    KeyVersionDisabled,
    /// A version that is `DESTROY_SCHEDULED`, which `restore` brings back
    /// until its destroy time, or `DESTROYED`, whose material is gone.
    /// `Diagnostics` says which, and names the version.
    KeyVersionDestroyed,

    /// Plaintext, AAD, data to sign or to MAC past 64 KiB, or a request
    /// for more than 1,024 random bytes: nothing is sent.
    TooLarge,
    /// A digest whose length is not its algorithm's: 32 bytes for SHA-256,
    /// 48 for SHA-384, 64 for SHA-512. Nothing is sent.
    InvalidDigest,
    /// An answer that failed its checksums, after the retry policy's
    /// attempts: the server did not get a checksum that was sent, a
    /// checksum it sent does not match its bytes, it named another version,
    /// or it refused a request checksum as not matching, which only bytes
    /// changed on the way can do. `Diagnostics` says which.
    IntegrityCheckFailed,
    /// A ciphertext this key did not make, or not with this AAD: another
    /// AAD, another key's ciphertext, or bytes that are not a Cloud KMS
    /// ciphertext. `Diagnostics` keeps the server's words, which say which.
    DecryptionFailed,
    /// `waitUntilEnabled` saw the version fail: `generation_failed` or
    /// `import_failed`, the reason in `Diagnostics`.
    KeyVersionFailed,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
};
