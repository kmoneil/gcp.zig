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

    /// A success response could not be decoded. Never retried.
    InvalidResponse,
};
