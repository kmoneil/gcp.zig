//! Answers production gave, for tests: on 2026-10-24 in milestone 0 of
//! the bucket settings and move spec (`_tmp/storage-settings-m0/`, runs
//! 7b3007 and cd4f6e), as the zig-gcp service account in extractctl:
//! the probe's own `zigps-` buckets and objects, every one deleted
//! within the minute. Verbatim, in the wire's key order. Test code only.

/// A regional bucket created with Autoclass to ARCHIVE, two CORS rules, a website, access logging with a prefix and an IP filter enforced with 0.0.0.0/0 and ::/0, uniform access, soft delete off: the create's answer. HTTP 200.
pub const bucket_every_setting_status = 200;
pub const bucket_every_setting =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-full",
    \\  "id": "zigps-7b3007-full",
    \\  "name": "zigps-7b3007-full",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842027546129654",
    \\  "metageneration": "1",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:40:27.721Z",
    \\  "updated": "2026-10-24T11:40:27.721Z",
    \\  "website": {
    \\    "mainPageSuffix": "index.html",
    \\    "notFoundPage": "404.html"
    \\  },
    \\  "logging": {
    \\    "logBucket": "zigps-7b3007-none",
    \\    "logObjectPrefix": "acc/"
    \\  },
    \\  "cors": [
    \\    {
    \\      "origin": [
    \\        "https://example.com",
    \\        "https://app.example.com"
    \\      ],
    \\      "method": [
    \\        "GET",
    \\        "HEAD"
    \\      ],
    \\      "responseHeader": [
    \\        "Content-Type",
    \\        "x-goog-meta-k"
    \\      ],
    \\      "maxAgeSeconds": 3600
    \\    },
    \\    {
    \\      "origin": [
    \\        "*"
    \\      ],
    \\      "method": [
    \\        "*"
    \\      ]
    \\    }
    \\  ],
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": true,
    \\      "lockedTime": "2027-01-22T11:40:27.721Z"
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": true,
    \\      "lockedTime": "2027-01-22T11:40:27.721Z"
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true,
    \\  "autoclass": {
    \\    "enabled": true,
    \\    "toggleTime": "2026-10-24T11:40:27.721Z",
    \\    "terminalStorageClass": "ARCHIVE",
    \\    "terminalStorageClassUpdateTime": "2026-10-24T11:40:27.721Z"
    \\  },
    \\  "ipFilter": {
    \\    "mode": "Enabled",
    \\    "publicNetworkSource": {
    \\      "allowedIpCidrRanges": [
    \\        "0.0.0.0/0",
    \\        "::/0"
    \\      ]
    \\    },
    \\    "allowCrossOrgVpcs": false,
    \\    "allowAllServiceAgentAccess": true
    \\  }
    \\}
;

/// A regional bucket created with only its name, location and soft delete off: none of the settings appear, `rpo` included. HTTP 200.
pub const bucket_no_setting_status = 200;
pub const bucket_no_setting =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none",
    \\  "id": "zigps-7b3007-none",
    \\  "name": "zigps-7b3007-none",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842026535834042",
    \\  "metageneration": "1",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:40:26.728Z",
    \\  "updated": "2026-10-24T11:40:26.728Z",
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true
    \\}
;

/// A regional bucket created with Autoclass naming no terminal class (NEARLINE filled in), a CORS rule with only an origin and one with `maxAgeSeconds` 0 and an empty `responseHeader` (dropped), a main page only, and logging with no prefix (the bucket's own name filled in): a get. HTTP 200.
pub const bucket_sparse_settings_status = 200;
pub const bucket_sparse_settings =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-ipoff",
    \\  "id": "zigps-7b3007-ipoff",
    \\  "name": "zigps-7b3007-ipoff",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842028555377153",
    \\  "metageneration": "1",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:40:28.734Z",
    \\  "updated": "2026-10-24T11:40:28.734Z",
    \\  "website": {
    \\    "mainPageSuffix": "index.html"
    \\  },
    \\  "logging": {
    \\    "logBucket": "zigps-7b3007-none",
    \\    "logObjectPrefix": "zigps-7b3007-ipoff"
    \\  },
    \\  "cors": [
    \\    {
    \\      "origin": [
    \\        "https://only.example"
    \\      ]
    \\    },
    \\    {
    \\      "origin": [
    \\        "https://z.example"
    \\      ],
    \\      "method": [
    \\        "PUT"
    \\      ],
    \\      "maxAgeSeconds": 0
    \\    }
    \\  ],
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true,
    \\  "autoclass": {
    \\    "enabled": true,
    \\    "toggleTime": "2026-10-24T11:40:28.734Z",
    \\    "terminalStorageClass": "NEARLINE",
    \\    "terminalStorageClassUpdateTime": "2026-10-24T11:40:28.734Z"
    \\  }
    \\}
;

/// The sparse bucket after a patch turning Autoclass off: `enabled` false and `toggleTime`, the terminal class gone. HTTP 200.
pub const bucket_autoclass_off_status = 200;
pub const bucket_autoclass_off =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-ipoff",
    \\  "id": "zigps-7b3007-ipoff",
    \\  "name": "zigps-7b3007-ipoff",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842028555377153",
    \\  "metageneration": "2",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAI=",
    \\  "timeCreated": "2026-10-24T11:40:28.734Z",
    \\  "updated": "2026-10-24T11:40:31.141Z",
    \\  "acl": [
    \\    {
    \\      "kind": "storage#bucketAccessControl",
    \\      "id": "zigps-7b3007-ipoff/project-owners-82150720798",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-ipoff/acl/project-owners-82150720798",
    \\      "bucket": "zigps-7b3007-ipoff",
    \\      "entity": "project-owners-82150720798",
    \\      "role": "OWNER",
    \\      "etag": "CAI=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "owners"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#bucketAccessControl",
    \\      "id": "zigps-7b3007-ipoff/project-editors-82150720798",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-ipoff/acl/project-editors-82150720798",
    \\      "bucket": "zigps-7b3007-ipoff",
    \\      "entity": "project-editors-82150720798",
    \\      "role": "OWNER",
    \\      "etag": "CAI=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "editors"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#bucketAccessControl",
    \\      "id": "zigps-7b3007-ipoff/project-viewers-82150720798",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-ipoff/acl/project-viewers-82150720798",
    \\      "bucket": "zigps-7b3007-ipoff",
    \\      "entity": "project-viewers-82150720798",
    \\      "role": "READER",
    \\      "etag": "CAI=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "viewers"
    \\      }
    \\    }
    \\  ],
    \\  "defaultObjectAcl": [
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "entity": "project-owners-82150720798",
    \\      "role": "OWNER",
    \\      "etag": "CAI=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "owners"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "entity": "project-editors-82150720798",
    \\      "role": "OWNER",
    \\      "etag": "CAI=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "editors"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "entity": "project-viewers-82150720798",
    \\      "role": "READER",
    \\      "etag": "CAI=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "viewers"
    \\      }
    \\    }
    \\  ],
    \\  "website": {
    \\    "mainPageSuffix": "index.html"
    \\  },
    \\  "owner": {
    \\    "entity": "project-owners-82150720798"
    \\  },
    \\  "logging": {
    \\    "logBucket": "zigps-7b3007-none",
    \\    "logObjectPrefix": "zigps-7b3007-ipoff"
    \\  },
    \\  "cors": [
    \\    {
    \\      "origin": [
    \\        "https://only.example"
    \\      ]
    \\    },
    \\    {
    \\      "origin": [
    \\        "https://z.example"
    \\      ],
    \\      "method": [
    \\        "PUT"
    \\      ],
    \\      "maxAgeSeconds": 0
    \\    }
    \\  ],
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true,
    \\  "autoclass": {
    \\    "enabled": false,
    \\    "toggleTime": "2026-10-24T11:40:31.141Z"
    \\  }
    \\}
;

/// A NAM4 dual-region created with `rpo` ASYNC_TURBO: no `customPlacementConfig`. HTTP 200.
pub const bucket_dual_turbo_status = 200;
pub const bucket_dual_turbo =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-dual",
    \\  "id": "zigps-7b3007-dual",
    \\  "name": "zigps-7b3007-dual",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842029266155148",
    \\  "metageneration": "1",
    \\  "location": "NAM4",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:40:29.522Z",
    \\  "updated": "2026-10-24T11:40:29.522Z",
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "dual-region",
    \\  "rpo": "ASYNC_TURBO"
    \\}
;

/// A configurable dual-region (`US` with dataLocations US-EAST1 and US-WEST1): `rpo` DEFAULT filled in. HTTP 200.
pub const bucket_configurable_dual_status = 200;
pub const bucket_configurable_dual =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-cd4f6e-cdual",
    \\  "id": "zigps-cd4f6e-cdual",
    \\  "name": "zigps-cd4f6e-cdual",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842142834079818",
    \\  "metageneration": "1",
    \\  "location": "US",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:42:23.092Z",
    \\  "updated": "2026-10-24T11:42:23.092Z",
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "dual-region",
    \\  "satisfiesPZI": true,
    \\  "customPlacementConfig": {
    \\    "dataLocations": [
    \\      "US-EAST1",
    \\      "US-WEST1"
    \\    ]
    \\  },
    \\  "rpo": "DEFAULT"
    \\}
;

/// A bucket whose IP filter is not enforced, with public ranges, a VPC source on `default` and `allowCrossOrgVpcs` (extractctl has no organization): a get. HTTP 200.
pub const bucket_vpc_sources_status = 200;
pub const bucket_vpc_sources =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-cd4f6e-vpc",
    \\  "id": "zigps-cd4f6e-vpc",
    \\  "name": "zigps-cd4f6e-vpc",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842141142241351",
    \\  "metageneration": "1",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:42:21.312Z",
    \\  "updated": "2026-10-24T11:42:21.312Z",
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true,
    \\  "ipFilter": {
    \\    "mode": "Disabled",
    \\    "publicNetworkSource": {
    \\      "allowedIpCidrRanges": [
    \\        "203.0.113.0/24",
    \\        "2001:db8::/32"
    \\      ]
    \\    },
    \\    "vpcNetworkSources": [
    \\      {
    \\        "network": "projects/extractctl/global/networks/default",
    \\        "allowedIpCidrRanges": [
    \\          "10.128.0.0/20",
    \\          "10.0.0.0/8"
    \\        ]
    \\      }
    \\    ],
    \\    "allowCrossOrgVpcs": true
    \\  }
    \\}
;

/// A bucket created with an IP filter not enforced, public ranges only and neither flag: `allowCrossOrgVpcs` false filled in, `allowAllServiceAgentAccess` absent. HTTP 200.
pub const bucket_filter_flags_filled_status = 200;
pub const bucket_filter_flags_filled =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-cd4f6e-pub",
    \\  "id": "zigps-cd4f6e-pub",
    \\  "name": "zigps-cd4f6e-pub",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842141869663909",
    \\  "metageneration": "1",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:42:22.050Z",
    \\  "updated": "2026-10-24T11:42:22.050Z",
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true,
    \\  "ipFilter": {
    \\    "mode": "Disabled",
    \\    "publicNetworkSource": {
    \\      "allowedIpCidrRanges": [
    \\        "198.51.100.0/24"
    \\      ]
    \\    },
    \\    "allowCrossOrgVpcs": false
    \\  }
    \\}
;

/// The every-setting bucket read with a token downscoped to roles/storage.legacyBucketReader, which lacks storage.buckets.getIpFilter: `ipFilter` left out, the rest there. HTTP 200.
pub const bucket_downscoped_reader_status = 200;
pub const bucket_downscoped_reader =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-full",
    \\  "id": "zigps-7b3007-full",
    \\  "name": "zigps-7b3007-full",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1792842027546129654",
    \\  "metageneration": "1",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-10-24T11:40:27.721Z",
    \\  "updated": "2026-10-24T11:40:27.721Z",
    \\  "website": {
    \\    "mainPageSuffix": "index.html",
    \\    "notFoundPage": "404.html"
    \\  },
    \\  "logging": {
    \\    "logBucket": "zigps-7b3007-none",
    \\    "logObjectPrefix": "acc/"
    \\  },
    \\  "cors": [
    \\    {
    \\      "origin": [
    \\        "https://example.com",
    \\        "https://app.example.com"
    \\      ],
    \\      "method": [
    \\        "GET",
    \\        "HEAD"
    \\      ],
    \\      "responseHeader": [
    \\        "Content-Type",
    \\        "x-goog-meta-k"
    \\      ],
    \\      "maxAgeSeconds": 3600
    \\    },
    \\    {
    \\      "origin": [
    \\        "*"
    \\      ],
    \\      "method": [
    \\        "*"
    \\      ]
    \\    }
    \\  ],
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": true,
    \\      "lockedTime": "2027-01-22T11:40:27.721Z"
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": true,
    \\      "lockedTime": "2027-01-22T11:40:27.721Z"
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true,
    \\  "autoclass": {
    \\    "enabled": true,
    \\    "toggleTime": "2026-10-24T11:40:27.721Z",
    \\    "terminalStorageClass": "ARCHIVE",
    \\    "terminalStorageClassUpdateTime": "2026-10-24T11:40:27.721Z"
    \\  }
    \\}
;

/// listBuckets over run 7b3007's buckets: each IP filter without its ranges. HTTP 200.
pub const bucket_listing_status = 200;
pub const bucket_listing =
    \\{
    \\  "kind": "storage#buckets",
    \\  "items": [
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-dual",
    \\      "id": "zigps-7b3007-dual",
    \\      "name": "zigps-7b3007-dual",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842029266155148",
    \\      "metageneration": "2",
    \\      "location": "NAM4",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAI=",
    \\      "timeCreated": "2026-10-24T11:40:29.522Z",
    \\      "updated": "2026-10-24T11:40:32.403Z",
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": false
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": false
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "dual-region",
    \\      "rpo": "DEFAULT"
    \\    },
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-full",
    \\      "id": "zigps-7b3007-full",
    \\      "name": "zigps-7b3007-full",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842027546129654",
    \\      "metageneration": "1",
    \\      "location": "US-CENTRAL1",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAE=",
    \\      "timeCreated": "2026-10-24T11:40:27.721Z",
    \\      "updated": "2026-10-24T11:40:27.721Z",
    \\      "website": {
    \\        "mainPageSuffix": "index.html",
    \\        "notFoundPage": "404.html"
    \\      },
    \\      "logging": {
    \\        "logBucket": "zigps-7b3007-none",
    \\        "logObjectPrefix": "acc/"
    \\      },
    \\      "cors": [
    \\        {
    \\          "origin": [
    \\            "https://example.com",
    \\            "https://app.example.com"
    \\          ],
    \\          "method": [
    \\            "GET",
    \\            "HEAD"
    \\          ],
    \\          "responseHeader": [
    \\            "Content-Type",
    \\            "x-goog-meta-k"
    \\          ],
    \\          "maxAgeSeconds": 3600
    \\        },
    \\        {
    \\          "origin": [
    \\            "*"
    \\          ],
    \\          "method": [
    \\            "*"
    \\          ]
    \\        }
    \\      ],
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": true,
    \\          "lockedTime": "2027-01-22T11:40:27.721Z"
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": true,
    \\          "lockedTime": "2027-01-22T11:40:27.721Z"
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "region",
    \\      "satisfiesPZI": true,
    \\      "autoclass": {
    \\        "enabled": true,
    \\        "toggleTime": "2026-10-24T11:40:27.721Z",
    \\        "terminalStorageClass": "ARCHIVE",
    \\        "terminalStorageClassUpdateTime": "2026-10-24T11:40:27.721Z"
    \\      },
    \\      "ipFilter": {
    \\        "mode": "Enabled",
    \\        "allowCrossOrgVpcs": false,
    \\        "allowAllServiceAgentAccess": true
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-hns",
    \\      "id": "zigps-7b3007-hns",
    \\      "name": "zigps-7b3007-hns",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842030618343422",
    \\      "metageneration": "1",
    \\      "location": "US-CENTRAL1",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAE=",
    \\      "timeCreated": "2026-10-24T11:40:30.867Z",
    \\      "updated": "2026-10-24T11:40:30.867Z",
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": true,
    \\          "lockedTime": "2027-01-22T11:40:30.867Z"
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": true,
    \\          "lockedTime": "2027-01-22T11:40:30.867Z"
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "region",
    \\      "satisfiesPZI": true,
    \\      "hierarchicalNamespace": {
    \\        "enabled": true
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-ipoff",
    \\      "id": "zigps-7b3007-ipoff",
    \\      "name": "zigps-7b3007-ipoff",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842028555377153",
    \\      "metageneration": "4",
    \\      "location": "US-CENTRAL1",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAQ=",
    \\      "timeCreated": "2026-10-24T11:40:28.734Z",
    \\      "updated": "2026-10-24T11:40:31.551Z",
    \\      "logging": {
    \\        "logBucket": "zigps-7b3007-nosuch",
    \\        "logObjectPrefix": "zigps-7b3007-ipoff"
    \\      },
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": false
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": false
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "region",
    \\      "satisfiesPZI": true,
    \\      "autoclass": {
    \\        "enabled": false,
    \\        "toggleTime": "2026-10-24T11:40:31.141Z"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none",
    \\      "id": "zigps-7b3007-none",
    \\      "name": "zigps-7b3007-none",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842026535834042",
    \\      "metageneration": "3",
    \\      "location": "US-CENTRAL1",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAM=",
    \\      "timeCreated": "2026-10-24T11:40:26.728Z",
    \\      "updated": "2026-10-24T11:40:32.024Z",
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": false
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": false
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "region",
    \\      "satisfiesPZI": true,
    \\      "ipFilter": {
    \\        "mode": "Disabled"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-ver",
    \\      "id": "zigps-7b3007-ver",
    \\      "name": "zigps-7b3007-ver",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842029945349127",
    \\      "metageneration": "1",
    \\      "location": "US-CENTRAL1",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAE=",
    \\      "timeCreated": "2026-10-24T11:40:30.169Z",
    \\      "updated": "2026-10-24T11:40:30.169Z",
    \\      "versioning": {
    \\        "enabled": true
    \\      },
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": false
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": false
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "region",
    \\      "satisfiesPZI": true
    \\    }
    \\  ]
    \\}
;

/// listBuckets over run cd4f6e's buckets: the VPC filter without its sources. HTTP 200.
pub const bucket_listing_vpc_status = 200;
pub const bucket_listing_vpc =
    \\{
    \\  "kind": "storage#buckets",
    \\  "items": [
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-cd4f6e-pub",
    \\      "id": "zigps-cd4f6e-pub",
    \\      "name": "zigps-cd4f6e-pub",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842141869663909",
    \\      "metageneration": "1",
    \\      "location": "US-CENTRAL1",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAE=",
    \\      "timeCreated": "2026-10-24T11:42:22.050Z",
    \\      "updated": "2026-10-24T11:42:22.050Z",
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": false
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": false
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "region",
    \\      "satisfiesPZI": true,
    \\      "ipFilter": {
    \\        "mode": "Disabled",
    \\        "allowCrossOrgVpcs": false
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#bucket",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-cd4f6e-vpc",
    \\      "id": "zigps-cd4f6e-vpc",
    \\      "name": "zigps-cd4f6e-vpc",
    \\      "projectNumber": "82150720798",
    \\      "generation": "1792842141142241351",
    \\      "metageneration": "1",
    \\      "location": "US-CENTRAL1",
    \\      "storageClass": "STANDARD",
    \\      "etag": "CAE=",
    \\      "timeCreated": "2026-10-24T11:42:21.312Z",
    \\      "updated": "2026-10-24T11:42:21.312Z",
    \\      "softDeletePolicy": {
    \\        "retentionDurationSeconds": "0"
    \\      },
    \\      "iamConfiguration": {
    \\        "bucketPolicyOnly": {
    \\          "enabled": false
    \\        },
    \\        "uniformBucketLevelAccess": {
    \\          "enabled": false
    \\        },
    \\        "publicAccessPrevention": "inherited"
    \\      },
    \\      "locationType": "region",
    \\      "satisfiesPZI": true,
    \\      "ipFilter": {
    \\        "mode": "Disabled",
    \\        "allowCrossOrgVpcs": true
    \\      }
    \\    }
    \\  ]
    \\}
;

/// A regional create naming `rpo` DEFAULT. HTTP 400.
pub const refusal_rpo_region_status = 400;
pub const refusal_rpo_region =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "RPO: DEFAULT cannot be enabled on REGION bucket 'zigps-7b3007-full'.",
    \\    "errors": [
    \\      {
    \\        "message": "RPO: DEFAULT cannot be enabled on REGION bucket 'zigps-7b3007-full'.",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A regional bucket patched to `rpo` ASYNC_TURBO. HTTP 400.
pub const refusal_rpo_turbo_region_status = 400;
pub const refusal_rpo_turbo_region =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "RPO: ASYNC_TURBO cannot be enabled on REGION bucket 'zigps-7b3007-none'.",
    \\    "errors": [
    \\      {
    \\        "message": "RPO: ASYNC_TURBO cannot be enabled on REGION bucket 'zigps-7b3007-none'.",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A multi-region create naming `rpo` ASYNC_TURBO. HTTP 400.
pub const refusal_rpo_turbo_multi_status = 400;
pub const refusal_rpo_turbo_multi =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "RPO: ASYNC_TURBO cannot be enabled on MULTI_REGION bucket 'zigps-cd4f6e-multi'.",
    \\    "errors": [
    \\      {
    \\        "message": "RPO: ASYNC_TURBO cannot be enabled on MULTI_REGION bucket 'zigps-cd4f6e-multi'.",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A create whose IP filter names a VPC source without `allowCrossOrgVpcs`, in a project with no organization. HTTP 400.
pub const refusal_vpc_cross_org_status = 400;
pub const refusal_vpc_cross_org =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid IP filter configuration. You must either set the vpcNetworkSources within your own organization, or set the allowCrossOrgVpcs flag to true to bypass this validation.",
    \\    "errors": [
    \\      {
    \\        "message": "Invalid IP filter configuration. You must either set the vpcNetworkSources within your own organization, or set the allowCrossOrgVpcs flag to true to bypass this validation.",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// Autoclass with terminal class COLDLINE. HTTP 400.
pub const refusal_autoclass_coldline_status = 400;
pub const refusal_autoclass_coldline =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid value for terminalStorageClass field in Autoclass config. Valid values are NEARLINE and ARCHIVE",
    \\    "errors": [
    \\      {
    \\        "message": "Invalid value for terminalStorageClass field in Autoclass config. Valid values are NEARLINE and ARCHIVE",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A configurable dual-region naming the regions of a predefined one. HTTP 400.
pub const refusal_predefined_pair_status = 400;
pub const refusal_predefined_pair =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Please create your bucket in NAM4, which is made up of the regions (US-CENTRAL1, US-EAST1)",
    \\    "errors": [
    \\      {
    \\        "message": "Please create your bucket in NAM4, which is made up of the regions (US-CENTRAL1, US-EAST1)",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// An upload with customTime 2026-10-01T12:34:56.789+02:00: answered in UTC, the milliseconds kept. HTTP 200.
pub const object_custom_time_millis_status = 200;
pub const object_custom_time_millis =
    \\{
    \\  "kind": "storage#object",
    \\  "id": "zigps-7b3007-none/ct/b/1792842034478713",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/ct%2Fb",
    \\  "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-none/o/ct%2Fb?generation=1792842034478713&alt=media",
    \\  "name": "ct/b",
    \\  "bucket": "zigps-7b3007-none",
    \\  "generation": "1792842034478713",
    \\  "metageneration": "1",
    \\  "contentType": "text/plain",
    \\  "storageClass": "STANDARD",
    \\  "size": "3",
    \\  "md5Hash": "I4uNgfsODwP+rVYTtSNLdA==",
    \\  "crc32c": "+v9AtQ==",
    \\  "etag": "CPn86YTJ0pcDEAE=",
    \\  "timeCreated": "2026-10-24T11:40:34.486Z",
    \\  "updated": "2026-10-24T11:40:34.486Z",
    \\  "timeStorageClassUpdated": "2026-10-24T11:40:34.486Z",
    \\  "customTime": "2026-10-01T10:34:56.789Z",
    \\  "timeFinalized": "2026-10-24T11:40:34.486Z"
    \\}
;

/// A patch of customTime null: taken, the time kept, the metageneration moved. HTTP 200.
pub const object_custom_time_null_status = 200;
pub const object_custom_time_null =
    \\{
    \\  "kind": "storage#object",
    \\  "id": "zigps-7b3007-none/ct/a/1792842034325172",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/ct%2Fa",
    \\  "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-none/o/ct%2Fa?generation=1792842034325172&alt=media",
    \\  "name": "ct/a",
    \\  "bucket": "zigps-7b3007-none",
    \\  "generation": "1792842034325172",
    \\  "metageneration": "4",
    \\  "contentType": "text/plain",
    \\  "storageClass": "STANDARD",
    \\  "size": "3",
    \\  "md5Hash": "I4uNgfsODwP+rVYTtSNLdA==",
    \\  "crc32c": "+v9AtQ==",
    \\  "etag": "CLTN4ITJ0pcDEAQ=",
    \\  "timeCreated": "2026-10-24T11:40:34.332Z",
    \\  "updated": "2026-10-24T11:40:35.168Z",
    \\  "timeStorageClassUpdated": "2026-10-24T11:40:34.332Z",
    \\  "customTime": "2026-10-02T00:00:00Z",
    \\  "timeFinalized": "2026-10-24T11:40:34.332Z"
    \\}
;

/// A patch moving customTime earlier. HTTP 400.
pub const refusal_custom_time_earlier_status = 400;
pub const refusal_custom_time_earlier =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Custom time cannot be decreased. Previously: 2026-10-01T00:00:00+00:00. Attempting to set: 2025-01-01T00:00:00+00:00.",
    \\    "errors": [
    \\      {
    \\        "message": "Custom time cannot be decreased. Previously: 2026-10-01T00:00:00+00:00. Attempting to set: 2025-01-01T00:00:00+00:00.",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// An upload with customTime "not a time". HTTP 400.
pub const refusal_custom_time_malformed_status = 400;
pub const refusal_custom_time_malformed =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Parse Error: Invalid value for type.googleapis.com/google.protobuf.Timestamp field: 'Field 'customTime', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.'.",
    \\    "errors": [
    \\      {
    \\        "message": "Parse Error: Invalid value for type.googleapis.com/google.protobuf.Timestamp field: 'Field 'customTime', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.'.",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A listing of objects with custom times, each with its mediaLink. HTTP 200.
pub const object_listing_custom_times_status = 200;
pub const object_listing_custom_times =
    \\{
    \\  "kind": "storage#objects",
    \\  "items": [
    \\    {
    \\      "kind": "storage#object",
    \\      "id": "zigps-7b3007-none/ct/a/1792842034325172",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/ct%2Fa",
    \\      "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-none/o/ct%2Fa?generation=1792842034325172&alt=media",
    \\      "name": "ct/a",
    \\      "bucket": "zigps-7b3007-none",
    \\      "generation": "1792842034325172",
    \\      "metageneration": "4",
    \\      "contentType": "text/plain",
    \\      "storageClass": "STANDARD",
    \\      "size": "3",
    \\      "md5Hash": "I4uNgfsODwP+rVYTtSNLdA==",
    \\      "crc32c": "+v9AtQ==",
    \\      "etag": "CLTN4ITJ0pcDEAQ=",
    \\      "timeCreated": "2026-10-24T11:40:34.332Z",
    \\      "updated": "2026-10-24T11:40:35.168Z",
    \\      "timeStorageClassUpdated": "2026-10-24T11:40:34.332Z",
    \\      "customTime": "2026-10-02T00:00:00Z",
    \\      "timeFinalized": "2026-10-24T11:40:34.332Z"
    \\    },
    \\    {
    \\      "kind": "storage#object",
    \\      "id": "zigps-7b3007-none/ct/b/1792842034478713",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/ct%2Fb",
    \\      "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-none/o/ct%2Fb?generation=1792842034478713&alt=media",
    \\      "name": "ct/b",
    \\      "bucket": "zigps-7b3007-none",
    \\      "generation": "1792842034478713",
    \\      "metageneration": "1",
    \\      "contentType": "text/plain",
    \\      "storageClass": "STANDARD",
    \\      "size": "3",
    \\      "md5Hash": "I4uNgfsODwP+rVYTtSNLdA==",
    \\      "crc32c": "+v9AtQ==",
    \\      "etag": "CPn86YTJ0pcDEAE=",
    \\      "timeCreated": "2026-10-24T11:40:34.486Z",
    \\      "updated": "2026-10-24T11:40:34.486Z",
    \\      "timeStorageClassUpdated": "2026-10-24T11:40:34.486Z",
    \\      "customTime": "2026-10-01T10:34:56.789Z",
    \\      "timeFinalized": "2026-10-24T11:40:34.486Z"
    \\    },
    \\    {
    \\      "kind": "storage#object",
    \\      "id": "zigps-7b3007-none/ct/c/1792842034637125",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/ct%2Fc",
    \\      "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-none/o/ct%2Fc?generation=1792842034637125&alt=media",
    \\      "name": "ct/c",
    \\      "bucket": "zigps-7b3007-none",
    \\      "generation": "1792842034637125",
    \\      "metageneration": "1",
    \\      "contentType": "text/plain",
    \\      "storageClass": "STANDARD",
    \\      "size": "3",
    \\      "md5Hash": "I4uNgfsODwP+rVYTtSNLdA==",
    \\      "crc32c": "+v9AtQ==",
    \\      "etag": "CMXS84TJ0pcDEAE=",
    \\      "timeCreated": "2026-10-24T11:40:34.642Z",
    \\      "updated": "2026-10-24T11:40:34.642Z",
    \\      "timeStorageClassUpdated": "2026-10-24T11:40:34.642Z",
    \\      "customTime": "2030-01-01T00:00:00Z",
    \\      "timeFinalized": "2026-10-24T11:40:34.642Z"
    \\    }
    \\  ]
    \\}
;

/// A move in a flat bucket: a new generation keeping the source's content type, cache control, custom time and metadata. HTTP 200.
pub const move_flat_status = 200;
pub const move_flat =
    \\{
    \\  "kind": "storage#object",
    \\  "id": "zigps-7b3007-none/mv/dst1/1792842035833399",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst1",
    \\  "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst1?generation=1792842035833399&alt=media",
    \\  "name": "mv/dst1",
    \\  "bucket": "zigps-7b3007-none",
    \\  "generation": "1792842035833399",
    \\  "metageneration": "1",
    \\  "contentType": "text/plain",
    \\  "storageClass": "STANDARD",
    \\  "size": "3",
    \\  "md5Hash": "+XxdKZQb+xsv2rCHSQargg==",
    \\  "cacheControl": "no-cache",
    \\  "crc32c": "KpSy6Q==",
    \\  "etag": "CLfUvIXJ0pcDEAE=",
    \\  "timeCreated": "2026-10-24T11:40:35.850Z",
    \\  "updated": "2026-10-24T11:40:35.850Z",
    \\  "timeStorageClassUpdated": "2026-10-24T11:40:35.850Z",
    \\  "customTime": "2026-10-01T00:00:00Z",
    \\  "timeFinalized": "2026-10-24T11:40:35.850Z",
    \\  "metadata": {
    \\    "k": "v"
    \\  }
    \\}
;

/// The same move repeated with a new idempotency token, pinned to the source's generation. HTTP 404.
pub const move_repeat_pinned_status = 404;
pub const move_repeat_pinned =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "No such object: zigps-7b3007-none/mv/src1",
    \\    "errors": [
    \\      {
    \\        "message": "No such object: zigps-7b3007-none/mv/src1",
    \\        "domain": "global",
    \\        "reason": "notFound"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A move onto an existing object under ifGenerationMatch=0. HTTP 412.
pub const move_condition_failed_status = 412;
pub const move_condition_failed =
    \\{
    \\  "error": {
    \\    "code": 412,
    \\    "message": "At least one of the pre-conditions you specified did not hold.",
    \\    "errors": [
    \\      {
    \\        "message": "At least one of the pre-conditions you specified did not hold.",
    \\        "domain": "global",
    \\        "reason": "conditionNotMet",
    \\        "locationType": "header",
    \\        "location": "If-Match"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A move under ifSourceGenerationNotMatch naming the source's own generation: no body. HTTP 304.
pub const move_not_match_hit_status = 304;
pub const move_not_match_hit = "";

/// A move under ifSourceGenerationMatch and ifSourceGenerationNotMatch together. HTTP 409.
pub const move_conflicting_conditions_status = 409;
pub const move_conflicting_conditions =
    \\{
    \\  "error": {
    \\    "code": 409,
    \\    "message": "Found conflicting object preconditions. Mutually exclusive fields cannot be set simultaneously.",
    \\    "errors": [
    \\      {
    \\        "message": "Found conflicting object preconditions. Mutually exclusive fields cannot be set simultaneously.",
    \\        "domain": "global",
    \\        "reason": "conflict"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A move whose source and destination are one name. HTTP 400.
pub const move_onto_itself_status = 400;
pub const move_onto_itself =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Source and destination object names must be different.",
    \\    "errors": [
    \\      {
    \\        "message": "Source and destination object names must be different.",
    \\        "domain": "global",
    \\        "reason": "invalid"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A move of an object under a temporary hold. HTTP 403.
pub const move_held_source_status = 403;
pub const move_held_source =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Object 'zigps-7b3007-none/mv/held' is under active Temporary hold and cannot be deleted, overwritten or archived until hold is removed.",
    \\    "errors": [
    \\      {
    \\        "message": "Object 'zigps-7b3007-none/mv/held' is under active Temporary hold and cannot be deleted, overwritten or archived until hold is removed.",
    \\        "domain": "global",
    \\        "reason": "forbidden"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A move of an object that does not exist. HTTP 404.
pub const move_missing_source_status = 404;
pub const move_missing_source =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "No such object: zigps-7b3007-none/mv/nosuch",
    \\    "errors": [
    \\      {
    \\        "message": "No such object: zigps-7b3007-none/mv/nosuch",
    \\        "domain": "global",
    \\        "reason": "notFound"
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A move under projection=full: the answer carries acl and owner. HTTP 200.
pub const move_projection_full_status = 200;
pub const move_projection_full =
    \\{
    \\  "kind": "storage#object",
    \\  "id": "zigps-7b3007-none/mv/dst5/1792842040117073",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst5",
    \\  "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst5?generation=1792842040117073&alt=media",
    \\  "name": "mv/dst5",
    \\  "bucket": "zigps-7b3007-none",
    \\  "generation": "1792842040117073",
    \\  "metageneration": "1",
    \\  "contentType": "text/plain",
    \\  "storageClass": "STANDARD",
    \\  "size": "4",
    \\  "md5Hash": "MAVuHKt6YdJW/I7dlw0U9Q==",
    \\  "crc32c": "yTHHZA==",
    \\  "etag": "CNGOwofJ0pcDEAE=",
    \\  "timeCreated": "2026-10-24T11:40:40.131Z",
    \\  "updated": "2026-10-24T11:40:40.131Z",
    \\  "timeStorageClassUpdated": "2026-10-24T11:40:40.131Z",
    \\  "timeFinalized": "2026-10-24T11:40:40.131Z",
    \\  "acl": [
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "object": "mv/dst5",
    \\      "generation": "1792842040117073",
    \\      "id": "zigps-7b3007-none/mv/dst5/1792842040117073/project-owners-82150720798",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst5/acl/project-owners-82150720798",
    \\      "bucket": "zigps-7b3007-none",
    \\      "entity": "project-owners-82150720798",
    \\      "role": "OWNER",
    \\      "etag": "CNGOwofJ0pcDEAE=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "owners"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "object": "mv/dst5",
    \\      "generation": "1792842040117073",
    \\      "id": "zigps-7b3007-none/mv/dst5/1792842040117073/project-editors-82150720798",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst5/acl/project-editors-82150720798",
    \\      "bucket": "zigps-7b3007-none",
    \\      "entity": "project-editors-82150720798",
    \\      "role": "OWNER",
    \\      "etag": "CNGOwofJ0pcDEAE=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "editors"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "object": "mv/dst5",
    \\      "generation": "1792842040117073",
    \\      "id": "zigps-7b3007-none/mv/dst5/1792842040117073/project-viewers-82150720798",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst5/acl/project-viewers-82150720798",
    \\      "bucket": "zigps-7b3007-none",
    \\      "entity": "project-viewers-82150720798",
    \\      "role": "READER",
    \\      "etag": "CNGOwofJ0pcDEAE=",
    \\      "projectTeam": {
    \\        "projectNumber": "82150720798",
    \\        "team": "viewers"
    \\      }
    \\    },
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "object": "mv/dst5",
    \\      "generation": "1792842040117073",
    \\      "id": "zigps-7b3007-none/mv/dst5/1792842040117073/user-zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-none/o/mv%2Fdst5/acl/user-zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "bucket": "zigps-7b3007-none",
    \\      "entity": "user-zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "role": "OWNER",
    \\      "email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "etag": "CNGOwofJ0pcDEAE="
    \\    }
    \\  ],
    \\  "owner": {
    \\    "entity": "user-zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  }
    \\}
;

/// A move in a hierarchical-namespace bucket into folders that did not exist. HTTP 200.
pub const move_hns_status = 200;
pub const move_hns =
    \\{
    \\  "kind": "storage#object",
    \\  "id": "zigps-7b3007-hns/x/y/dst/1792842041570325",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-7b3007-hns/o/x%2Fy%2Fdst",
    \\  "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-7b3007-hns/o/x%2Fy%2Fdst?generation=1792842041570325&alt=media",
    \\  "name": "x/y/dst",
    \\  "bucket": "zigps-7b3007-hns",
    \\  "generation": "1792842041570325",
    \\  "metageneration": "1",
    \\  "contentType": "text/plain",
    \\  "storageClass": "STANDARD",
    \\  "size": "3",
    \\  "md5Hash": "kILjvIrlrhBKzAk6+TuN4Q==",
    \\  "crc32c": "aJv2Bw==",
    \\  "etag": "CJXomojJ0pcDEAE=",
    \\  "timeCreated": "2026-10-24T11:40:41.596Z",
    \\  "updated": "2026-10-24T11:40:41.596Z",
    \\  "timeStorageClassUpdated": "2026-10-24T11:40:41.596Z",
    \\  "timeFinalized": "2026-10-24T11:40:41.596Z"
    \\}
;

/// A get, projection=full, of an object moved from one uploaded with predefinedAcl=private: the private list carried. HTTP 200.
pub const move_private_acl_status = 200;
pub const move_private_acl =
    \\{
    \\  "kind": "storage#object",
    \\  "id": "zigps-cd4f6e-flat/acl/dst/1792842145663877",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-cd4f6e-flat/o/acl%2Fdst",
    \\  "mediaLink": "https://storage.googleapis.com/download/storage/v1/b/zigps-cd4f6e-flat/o/acl%2Fdst?generation=1792842145663877&alt=media",
    \\  "name": "acl/dst",
    \\  "bucket": "zigps-cd4f6e-flat",
    \\  "generation": "1792842145663877",
    \\  "metageneration": "1",
    \\  "contentType": "text/plain",
    \\  "storageClass": "STANDARD",
    \\  "size": "3",
    \\  "md5Hash": "ozkVuiJrbb0e2z4J+sQe2Q==",
    \\  "crc32c": "e/qb5A==",
    \\  "etag": "CIWX7LnJ0pcDEAE=",
    \\  "timeCreated": "2026-10-24T11:42:25.677Z",
    \\  "updated": "2026-10-24T11:42:25.677Z",
    \\  "timeStorageClassUpdated": "2026-10-24T11:42:25.677Z",
    \\  "timeFinalized": "2026-10-24T11:42:25.677Z",
    \\  "acl": [
    \\    {
    \\      "kind": "storage#objectAccessControl",
    \\      "object": "acl/dst",
    \\      "generation": "1792842145663877",
    \\      "id": "zigps-cd4f6e-flat/acl/dst/1792842145663877/user-zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-cd4f6e-flat/o/acl%2Fdst/acl/user-zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "bucket": "zigps-cd4f6e-flat",
    \\      "entity": "user-zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "role": "OWNER",
    \\      "email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\      "etag": "CIWX7LnJ0pcDEAE="
    \\    }
    \\  ],
    \\  "owner": {
    \\    "entity": "user-zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  }
    \\}
;
