//! What production answered, measured in extractctl on 2026-10-18 UTC
//! (`_tmp/er-m0`, run f2e07a): bodies verbatim, but for a final line break.
//! Test code only.

/// Group stats of one service over 30 days, ordered by count: two groups. HTTP 200.
pub const group_stats_30_days =
    \\{
    \\  "errorGroupStats": [
    \\    {
    \\      "group": {
    \\        "name": "projects/extractctl/groups/COiYvODSyMz2Bg",
    \\        "groupId": "COiYvODSyMz2Bg",
    \\        "resolutionStatus": "OPEN"
    \\      },
    \\      "count": "6",
    \\      "affectedUsersCount": "3",
    \\      "firstSeenTime": "2026-10-18T01:28:29.345667Z",
    \\      "lastSeenTime": "2026-10-18T01:28:29Z",
    \\      "affectedServices": [
    \\        {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        }
    \\      ],
    \\      "numAffectedServices": 1,
    \\      "representative": {
    \\        "eventTime": "2026-10-18T00:04:29.345667Z",
    \\        "serviceContext": {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        },
    \\        "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\        "context": {
    \\          "httpRequest": {
    \\            "method": "GET",
    \\            "url": "/zigps/py",
    \\            "responseStatusCode": 500
    \\          },
    \\          "user": "user-2"
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "group": {
    \\        "name": "projects/extractctl/groups/CMfm1OTYhMPcdA",
    \\        "groupId": "CMfm1OTYhMPcdA",
    \\        "resolutionStatus": "OPEN"
    \\      },
    \\      "count": "3",
    \\      "affectedUsersCount": "1",
    \\      "firstSeenTime": "2026-10-18T01:22:29.345667Z",
    \\      "lastSeenTime": "2026-10-18T01:22:29Z",
    \\      "affectedServices": [
    \\        {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v2",
    \\          "resourceType": "reported_errors"
    \\        }
    \\      ],
    \\      "numAffectedServices": 1,
    \\      "representative": {
    \\        "eventTime": "2026-10-17T22:16:29.345667Z",
    \\        "serviceContext": {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v2",
    \\          "resourceType": "reported_errors"
    \\        },
    \\        "message": "java.lang.NullPointerException: customer is null\n\tat com.example.zigpsf2e07a.Billing.charge(Billing.java:88)\n\tat com.example.zigpsf2e07a.Billing.run(Billing.java:31)\n\tat java.base/java.lang.Thread.run(Thread.java:1583)",
    \\        "context": {
    \\          "httpRequest": {
    \\            "method": "GET",
    \\            "url": "/zigps/java",
    \\            "responseStatusCode": 500
    \\          },
    \\          "user": "user-9"
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "timeRangeBegin": "2026-09-18T01:34:57Z"
    \\}
;
pub const group_stats_30_days_status = 200;

/// One group over 6 hours in hourly buckets aligned at the end: every bucket there, an empty one without `count`. HTTP 200.
pub const group_stats_timed_end =
    \\{
    \\  "errorGroupStats": [
    \\    {
    \\      "group": {
    \\        "name": "projects/extractctl/groups/COiYvODSyMz2Bg",
    \\        "groupId": "COiYvODSyMz2Bg",
    \\        "resolutionStatus": "OPEN"
    \\      },
    \\      "count": "6",
    \\      "affectedUsersCount": "3",
    \\      "timedCounts": [
    \\        {
    \\          "startTime": "2026-10-17T19:34:49Z",
    \\          "endTime": "2026-10-17T20:34:49Z"
    \\        },
    \\        {
    \\          "count": "2",
    \\          "startTime": "2026-10-17T20:34:49Z",
    \\          "endTime": "2026-10-17T21:34:49Z"
    \\        },
    \\        {
    \\          "startTime": "2026-10-17T21:34:49Z",
    \\          "endTime": "2026-10-17T22:34:49Z"
    \\        },
    \\        {
    \\          "count": "1",
    \\          "startTime": "2026-10-17T22:34:49Z",
    \\          "endTime": "2026-10-17T23:34:49Z"
    \\        },
    \\        {
    \\          "count": "1",
    \\          "startTime": "2026-10-17T23:34:49Z",
    \\          "endTime": "2026-10-18T00:34:49Z"
    \\        },
    \\        {
    \\          "count": "2",
    \\          "startTime": "2026-10-18T00:34:49Z",
    \\          "endTime": "2026-10-18T01:34:49Z"
    \\        }
    \\      ],
    \\      "firstSeenTime": "2026-10-18T01:28:29.345667Z",
    \\      "lastSeenTime": "2026-10-18T01:28:29Z",
    \\      "affectedServices": [
    \\        {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        }
    \\      ],
    \\      "numAffectedServices": 1,
    \\      "representative": {
    \\        "eventTime": "2026-10-18T00:04:29.345667Z",
    \\        "serviceContext": {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        },
    \\        "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\        "context": {
    \\          "httpRequest": {
    \\            "method": "GET",
    \\            "url": "/zigps/py",
    \\            "responseStatusCode": 500
    \\          },
    \\          "user": "user-2"
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "timeRangeBegin": "2026-10-17T19:34:49Z"
    \\}
;
pub const group_stats_timed_end_status = 200;

/// The same, rounded to the hour: the first and last buckets cut to the range. HTTP 200.
pub const group_stats_timed_rounded =
    \\{
    \\  "errorGroupStats": [
    \\    {
    \\      "group": {
    \\        "name": "projects/extractctl/groups/COiYvODSyMz2Bg",
    \\        "groupId": "COiYvODSyMz2Bg",
    \\        "resolutionStatus": "OPEN"
    \\      },
    \\      "count": "6",
    \\      "affectedUsersCount": "3",
    \\      "timedCounts": [
    \\        {
    \\          "startTime": "2026-10-17T19:34:50Z",
    \\          "endTime": "2026-10-17T20:00:00Z"
    \\        },
    \\        {
    \\          "startTime": "2026-10-17T20:00:00Z",
    \\          "endTime": "2026-10-17T21:00:00Z"
    \\        },
    \\        {
    \\          "count": "2",
    \\          "startTime": "2026-10-17T21:00:00Z",
    \\          "endTime": "2026-10-17T22:00:00Z"
    \\        },
    \\        {
    \\          "startTime": "2026-10-17T22:00:00Z",
    \\          "endTime": "2026-10-17T23:00:00Z"
    \\        },
    \\        {
    \\          "count": "1",
    \\          "startTime": "2026-10-17T23:00:00Z",
    \\          "endTime": "2026-10-18T00:00:00Z"
    \\        },
    \\        {
    \\          "count": "1",
    \\          "startTime": "2026-10-18T00:00:00Z",
    \\          "endTime": "2026-10-18T01:00:00Z"
    \\        },
    \\        {
    \\          "count": "2",
    \\          "startTime": "2026-10-18T01:00:00Z",
    \\          "endTime": "2026-10-18T01:34:50Z"
    \\        }
    \\      ],
    \\      "firstSeenTime": "2026-10-18T01:28:29.345667Z",
    \\      "lastSeenTime": "2026-10-18T01:28:29Z",
    \\      "affectedServices": [
    \\        {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        }
    \\      ],
    \\      "numAffectedServices": 1,
    \\      "representative": {
    \\        "eventTime": "2026-10-18T00:04:29.345667Z",
    \\        "serviceContext": {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        },
    \\        "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\        "context": {
    \\          "httpRequest": {
    \\            "method": "GET",
    \\            "url": "/zigps/py",
    \\            "responseStatusCode": 500
    \\          },
    \\          "user": "user-2"
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "timeRangeBegin": "2026-10-17T19:34:50Z"
    \\}
;
pub const group_stats_timed_rounded_status = 200;

/// The first page of one group, with a page token. HTTP 200.
pub const group_stats_page_1 =
    \\{
    \\  "errorGroupStats": [
    \\    {
    \\      "group": {
    \\        "name": "projects/extractctl/groups/COiYvODSyMz2Bg",
    \\        "groupId": "COiYvODSyMz2Bg",
    \\        "resolutionStatus": "OPEN"
    \\      },
    \\      "count": "6",
    \\      "affectedUsersCount": "3",
    \\      "firstSeenTime": "2026-10-18T01:28:29.345667Z",
    \\      "lastSeenTime": "2026-10-18T01:28:29Z",
    \\      "affectedServices": [
    \\        {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        }
    \\      ],
    \\      "numAffectedServices": 1,
    \\      "representative": {
    \\        "eventTime": "2026-10-18T00:04:29.345667Z",
    \\        "serviceContext": {
    \\          "service": "zigps-er-f2e07a-a",
    \\          "version": "v1",
    \\          "resourceType": "reported_errors"
    \\        },
    \\        "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\        "context": {
    \\          "httpRequest": {
    \\            "method": "GET",
    \\            "url": "/zigps/py",
    \\            "responseStatusCode": 500
    \\          },
    \\          "user": "user-2"
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "nextPageToken": "EicxMDEwODQxMzg5NjIwNDQ3NzQwNjE3OTIyOTA5Nzg3MzUzMjgwODQ=",
    \\  "timeRangeBegin": "2026-09-18T01:36:18Z"
    \\}
;
pub const group_stats_page_1_status = 200;

/// One group's six events, newest first. HTTP 200.
pub const events_page =
    \\{
    \\  "errorEvents": [
    \\    {
    \\      "eventTime": "2026-10-18T01:28:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-0"
    \\      }
    \\    },
    \\    {
    \\      "eventTime": "2026-10-18T01:04:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-1"
    \\      }
    \\    },
    \\    {
    \\      "eventTime": "2026-10-18T00:04:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-2"
    \\      }
    \\    },
    \\    {
    \\      "eventTime": "2026-10-17T23:04:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-0"
    \\      }
    \\    },
    \\    {
    \\      "eventTime": "2026-10-17T21:34:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-1"
    \\      }
    \\    },
    \\    {
    \\      "eventTime": "2026-10-17T21:04:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-2"
    \\      }
    \\    }
    \\  ],
    \\  "timeRangeBegin": "2026-09-18T01:34:48Z"
    \\}
;
pub const events_page_status = 200;

/// Two events and a page token. HTTP 200.
pub const events_page_with_token =
    \\{
    \\  "errorEvents": [
    \\    {
    \\      "eventTime": "2026-10-18T01:28:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-0"
    \\      }
    \\    },
    \\    {
    \\      "eventTime": "2026-10-18T01:04:29.345667Z",
    \\      "serviceContext": {
    \\        "service": "zigps-er-f2e07a-a",
    \\        "version": "v1",
    \\        "resourceType": "reported_errors"
    \\      },
    \\      "message": "Traceback (most recent call last):\n  File \"/srv/zigps_f2e07a/orders.py\", line 41, in handle\n    total = price(order)\n  File \"/srv/zigps_f2e07a/orders.py\", line 12, in price\n    raise ValueError(\"order has no lines\")\nValueError: order has no lines",
    \\      "context": {
    \\        "httpRequest": {
    \\          "method": "GET",
    \\          "url": "/zigps/py",
    \\          "responseStatusCode": 500
    \\        },
    \\        "user": "user-1"
    \\      }
    \\    }
    \\  ],
    \\  "nextPageToken": "CLqoyMzutoD5NRDomLzg0sjM9gYY4fSc38je5Mh5IMCz3M/IiJa0ogEog4/y1a/ClwM=",
    \\  "timeRangeBegin": "2026-09-18T01:36:23Z"
    \\}
;
pub const events_page_with_token_status = 200;

/// One group, as groups.get answers. HTTP 200.
pub const group_get =
    \\{
    \\  "name": "projects/extractctl/groups/COiYvODSyMz2Bg",
    \\  "groupId": "COiYvODSyMz2Bg",
    \\  "resolutionStatus": "OPEN"
    \\}
;
pub const group_get_status = 200;

/// A group with a tracking issue, as groups.update answers. HTTP 200.
pub const group_with_issue =
    \\{
    \\  "name": "projects/extractctl/groups/CMfm1OTYhMPcdA",
    \\  "groupId": "CMfm1OTYhMPcdA",
    \\  "trackingIssues": [
    \\    {
    \\      "url": "https://example.com/issues/zigps-2"
    \\    }
    \\  ],
    \\  "resolutionStatus": "ACKNOWLEDGED"
    \\}
;
pub const group_with_issue_status = 200;

/// A group with enum-encoding=int. HTTP 200.
pub const group_int_enums =
    \\{
    \\  "name": "projects/extractctl/groups/COiYvODSyMz2Bg",
    \\  "groupId": "COiYvODSyMz2Bg",
    \\  "resolutionStatus": 1
    \\}
;
pub const group_int_enums_status = 200;

/// 403: the API is off in the project. HTTP 403.
pub const refused_disabled =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Error Reporting API has not been used in project 82150720798 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/clouderrorreporting.googleapis.com/overview?project=82150720798 then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SERVICE_DISABLED",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "activationUrl": "https://console.developers.google.com/apis/api/clouderrorreporting.googleapis.com/overview?project=82150720798",
    \\          "consumer": "projects/82150720798",
    \\          "containerInfo": "82150720798",
    \\          "service": "clouderrorreporting.googleapis.com",
    \\          "serviceTitle": "Error Reporting API"
    \\        }
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
    \\        "locale": "en-US",
    \\        "message": "Error Reporting API has not been used in project 82150720798 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/clouderrorreporting.googleapis.com/overview?project=82150720798 then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry."
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.Help",
    \\        "links": [
    \\          {
    \\            "description": "Google developers console API activation",
    \\            "url": "https://console.developers.google.com/apis/api/clouderrorreporting.googleapis.com/overview?project=82150720798"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;
pub const refused_disabled_status = 403;

/// 400: an id that names no group. HTTP 400.
pub const refused_group_id =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid group id: zigps-no-such-group",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;
pub const refused_group_id_status = 400;

/// 400: a well-formed id that names no group. HTTP 400.
pub const refused_well_formed_group_id =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid group id: CAAAAAAAAAAAAA",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;
pub const refused_well_formed_group_id_status = 400;

/// 400: events.list without a group id. HTTP 400.
pub const refused_missing_group_id =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Missing group_id.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;
pub const refused_missing_group_id_status = 400;

/// 400: a page token never issued. HTTP 400.
pub const refused_page_token =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Error while unescaping page_token in request.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;
pub const refused_page_token_status = 400;

/// 400: buckets too narrow for the period. HTTP 400.
pub const refused_too_short =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "'timed_count_duration' is too short for the requested period",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;
pub const refused_too_short_status = 400;

/// 400: a period that is not one. HTTP 400.
pub const refused_bad_period =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid value at 'time_range.period' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.QueryTimeRange.Period), \"PERIOD_2_DAYS\"",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "time_range.period",
    \\            "description": "Invalid value at 'time_range.period' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.QueryTimeRange.Period), \"PERIOD_2_DAYS\""
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;
pub const refused_bad_period_status = 400;

/// 400: a resolution status that is not one. HTTP 400.
pub const refused_bad_status =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid value at 'group.resolution_status' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ResolutionStatus), \"WONTFIX\"",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "group.resolution_status",
    \\            "description": "Invalid value at 'group.resolution_status' (type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ResolutionStatus), \"WONTFIX\""
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;
pub const refused_bad_status_status = 400;
