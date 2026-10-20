//! Answers production gave on 2026-10-18, measured in milestone 0 of the
//! Monitoring spec (`_tmp/monitoring-m0/`), for tests: the probes' own
//! `zigps-m0*` metrics and refusals, verbatim but for a final line break;
//! and on 2026-10-19, for issue #239, at the end; and on 2026-10-20, for
//! issue #275, alert policies and snoozes (`_tmp/policies-m0/`). Test code
//! only.

/// A descriptor the probe made: GAUGE INT64, unit 1, one string label. HTTP 200.
pub const descriptor_get_status = 200;
pub const descriptor_get =
    \\{
    \\  "name": "projects/extractctl/metricDescriptors/custom.googleapis.com/zigps-m0-62b2c8/gauge",
    \\  "labels": [
    \\    {
    \\      "key": "k"
    \\    }
    \\  ],
    \\  "metricKind": "GAUGE",
    \\  "valueType": "INT64",
    \\  "unit": "1",
    \\  "description": "zig-gcp milestone 0 probe",
    \\  "type": "custom.googleapis.com/zigps-m0-62b2c8/gauge",
    \\  "monitoredResourceTypes": [
    \\    "aws_ec2_instance",
    \\    "aws_lambda_function",
    \\    "aws_sqs_queue",
    \\    "baremetalsolution.googleapis.com/Instance",
    \\    "cloud_composer_environment",
    \\    "cloud_composer_workflow",
    \\    "cloud_dataproc_batch",
    \\    "cloud_dataproc_job",
    \\    "cloud_dataproc_session",
    \\    "cloudbuild.googleapis.com/Location",
    \\    "dataflow_job",
    \\    "gae_instance",
    \\    "gce_instance",
    \\    "generic_node",
    \\    "generic_task",
    \\    "gke_container",
    \\    "global",
    \\    "k8s_cluster",
    \\    "k8s_container",
    \\    "k8s_node",
    \\    "k8s_pod",
    \\    "k8s_service",
    \\    "prometheus_target"
    \\  ]
    \\}
;

/// A get of a descriptor just made, before it reads back (it flapped for about 2 s). HTTP 404.
pub const descriptor_missing_status = 404;
pub const descriptor_missing =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "Could not find descriptor for metric 'custom.googleapis.com/zigps-m0-62b2c8/gauge'.",
    \\    "status": "NOT_FOUND"
    \\  }
    \\}
;

/// A get with the type's slashes as %2F. HTTP 400.
pub const descriptor_encoded_slash_status = 400;
pub const descriptor_encoded_slash =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid metric name: custom.googleapis.com%2Fzigps-m0-62b2c8%2Fgauge",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A create of an existing type with another kind. HTTP 409.
pub const descriptor_other_kind_status = 409;
pub const descriptor_other_kind =
    \\{
    \\  "error": {
    \\    "code": 409,
    \\    "message": "Errors during metric descriptor creation: {(metric: custom.googleapis.com/zigps-m0b-b66e4f/gauge, error: The metric already exists.)}.",
    \\    "status": "ALREADY_EXISTS"
    \\  }
    \\}
;

/// A delete of a type that has no descriptor. HTTP 404.
pub const descriptor_delete_missing_status = 404;
pub const descriptor_delete_missing =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "The metric 'custom.googleapis.com/zigps-m0b-b66e4f/nothing' does not exist.",
    \\    "status": "NOT_FOUND"
    \\  }
    \\}
;

/// The generic_task resource type. HTTP 200.
pub const resource_generic_task_status = 200;
pub const resource_generic_task =
    \\{
    \\  "type": "generic_task",
    \\  "displayName": "Generic Task",
    \\  "description": "A generic task identifies an application process for which no more specific resource is applicable, such as a process scheduled by a custom orchestration system. The label values must uniquely identify the task.",
    \\  "labels": [
    \\    {
    \\      "key": "project_id",
    \\      "description": "The identifier of the GCP project associated with this resource, such as \"my-project\"."
    \\    },
    \\    {
    \\      "key": "location",
    \\      "description": "The Google Cloud region or zone that determines where data about the resource is stored. For example, \"us-east1-a\"."
    \\    },
    \\    {
    \\      "key": "namespace",
    \\      "description": "A namespace identifier, such as a cluster name."
    \\    },
    \\    {
    \\      "key": "job",
    \\      "description": "An identifier for a grouping of related tasks, such as the name of a microservice or distributed batch job."
    \\    },
    \\    {
    \\      "key": "task_id",
    \\      "description": "A unique identifier for the task within the namespace and job, such as a replica index identifying the task within the job."
    \\    }
    \\  ],
    \\  "name": "projects/extractctl/monitoredResourceDescriptors/generic_task",
    \\  "launchStage": "GA"
    \\}
;

/// A resource type that is not one. HTTP 404.
pub const resource_missing_status = 404;
pub const resource_missing =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "Could not find descriptor for resource type 'no_such_type'.",
    \\    "status": "NOT_FOUND"
    \\  }
    \\}
;

/// A point 1 s after the series' last. HTTP 400.
pub const write_too_frequent_status = 400;
pub const write_too_frequent =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"freq\"}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"62b2c8-a\", \"namespace\": \"zigps\", \"location\": \"us-central1\", \"job\": \"m0\"}): write for resource failed: One or more points were written more frequently than the maximum sampling period configured for the metric. {Metric: custom.googleapis.com/zigps-m0-62b2c8/gauge, Timestamps: {Youngest Existing: '2026/10/18-06:46:35.949', New: '2026/10/18-06:46:36.949'}}",
    \\    "status": "FAILED_PRECONDITION",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 9
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A point 10 s before the series' last. HTTP 400.
pub const write_out_of_order_status = 400;
pub const write_out_of_order =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"order\"}, resource.type=\"generic_task\", resource.labels={\"namespace\": \"zigps\", \"location\": \"us-central1\", \"task_id\": \"62b2c8-a\", \"job\": \"m0\"}): write for resource failed: Points must be written in order. One or more of the points specified had an older end time than the most recent point.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// The same series twice in one request. HTTP 400.
pub const write_duplicate_status = 400;
pub const write_duplicate =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[1] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"dup\"}, resource.type=\"generic_task\", resource.labels={\"job\": \"m0\", \"location\": \"us-central1\", \"task_id\": \"62b2c8-a\", \"namespace\": \"zigps\"}): Duplicate TimeSeries encountered. Only one point can be written per TimeSeries per request.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 2,
    \\        "successPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A gauge whose start is 30 s before its end. HTTP 400.
pub const write_gauge_start_status = 400;
pub const write_gauge_start =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"gstart\"}, resource.type=\"generic_task\", resource.labels={\"namespace\": \"zigps\", \"job\": \"m0\", \"location\": \"us-central1\", \"task_id\": \"62b2c8-a\"}): Field points[0].interval.start_time had an invalid value of \"2026-10-18T06:46:05.949-07:00\": The start time must be equal to the end time (2026-10-18T06:46:35.949-07:00) for the gauge metric 'custom.googleapis.com/zigps-m0-62b2c8/gauge'.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A point six minutes ahead. HTTP 400.
pub const write_ahead_status = 400;
pub const write_ahead =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"ahead\"}, resource.type=\"generic_task\", resource.labels={\"namespace\": \"zigps\", \"job\": \"m0\", \"location\": \"us-central1\", \"task_id\": \"62b2c8-a\"}): Field points[0].interval.end_time had an invalid value of \"2026-10-18T06:52:35.949-07:00\": Data points cannot be written more than 5m into the future. Your data point is 5m59.949s after the present time, which is too far in the future.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A point 26 hours back. HTTP 400.
pub const write_back_status = 400;
pub const write_back =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"back\"}, resource.type=\"generic_task\", resource.labels={\"namespace\": \"zigps\", \"job\": \"m0\", \"location\": \"us-central1\", \"task_id\": \"62b2c8-a\"}): Field points[0].interval.end_time had an invalid value of \"2026-10-17T04:46:35.949-07:00\": Data points cannot be written more than approximately 24 hours in the past, specifically no more than 25h10s in the past. Your data point is 26h0.051s before the present time, which is too far in the past.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// Two good series and one six minutes ahead, in one request. HTTP 400.
pub const write_mixed_status = 400;
pub const write_mixed =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[2] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"mix3\"}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"62b2c8-a\", \"job\": \"m0\", \"namespace\": \"zigps\", \"location\": \"us-central1\"}): Field points[0].interval.end_time had an invalid value of \"2026-10-18T06:52:35.949-07:00\": Data points cannot be written more than 5m into the future. Your data point is 5m59.949s after the present time, which is too far in the future.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 3,
    \\        "successPointCount": 2,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A DOUBLE point for an INT64 descriptor. HTTP 400.
pub const write_wrong_value_type_status = 400;
pub const write_wrong_value_type =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"vt\"}, resource.type=\"generic_task\", resource.labels={\"job\": \"m0\", \"location\": \"us-central1\", \"task_id\": \"62b2c8-a\", \"namespace\": \"zigps\"}): value type for metric must be INT64, but is DOUBLE",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A CUMULATIVE point for a GAUGE descriptor. HTTP 400.
pub const write_wrong_kind_status = 400;
pub const write_wrong_kind =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"kind\"}, resource.type=\"generic_task\", resource.labels={\"job\": \"m0\", \"location\": \"us-central1\", \"task_id\": \"62b2c8-a\", \"namespace\": \"zigps\"}): metric kind for metric must be GAUGE, but is CUMULATIVE",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A generic_task in location nowhere-1. HTTP 400.
pub const write_unknown_location_status = 400;
pub const write_unknown_location =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"loc\"}, resource.type=\"generic_task\", resource.labels={\"job\": \"m0\", \"namespace\": \"zigps\", \"task_id\": \"62b2c8\", \"location\": \"nowhere-1\"}): write for resource failed: Unrecognized region or location.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A generic_task without its namespace. HTTP 400.
pub const write_missing_label_status = 400;
pub const write_missing_label =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0-62b2c8/gauge\", metric.labels={\"k\": \"res\"}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"62b2c8\", \"job\": \"m0\", \"location\": \"us-central1\"}): the set of resource labels is incomplete, missing (namespace)",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A DELTA point to a new custom.googleapis.com/ type. HTTP 400.
pub const write_delta_custom_status = 400;
pub const write_delta_custom =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field metricDescriptor.metricKind had an invalid value of \"DELTA\": When creating metric custom.googleapis.com/zigps-m0-62b2c8/delta: the DELTA metric kind is not supported for custom metrics.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A cumulative point whose start is 30 s before the series' start. HTTP 400.
pub const write_cumulative_earlier_status = 400;
pub const write_cumulative_earlier =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/cum\", metric.labels={}, resource.type=\"generic_task\", resource.labels={\"location\": \"us-central1\", \"task_id\": \"b66e4f-a\", \"job\": \"m0\", \"namespace\": \"zigps\"}): write for resource failed: Points must be written in order. One or more of the points specified had an older start time than the most recent point.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A cumulative point under the start of the earlier-start probe, 30 s before the series' start, with a lower total: refused for its start. (A total that falls under the series' own start was taken, measured later.) HTTP 400.
pub const write_cumulative_falls_status = 400;
pub const write_cumulative_falls =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/cum\", metric.labels={}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"b66e4f-a\", \"job\": \"m0\", \"namespace\": \"zigps\", \"location\": \"us-central1\"}): write for resource failed: Points must be written in order. One or more of the points specified had an older start time than the most recent point.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A cumulative point whose start is its end. HTTP 400.
pub const write_cumulative_no_interval_status = 400;
pub const write_cumulative_no_interval =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/cum2\", metric.labels={}, resource.type=\"generic_task\", resource.labels={\"namespace\": \"zigps\", \"job\": \"m0\", \"location\": \"us-central1\", \"task_id\": \"b66e4f-a\"}): Field points[0].interval.start_time had an invalid value of \"2026-10-18T06:49:11.034-07:00\": The start time must be before the end time (2026-10-18T06:49:11.034-07:00) for the non-gauge metric 'custom.googleapis.com/zigps-m0b-b66e4f/cum2'.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A STRING point to a new custom.googleapis.com/ type. HTTP 400.
pub const write_string_custom_status = 400;
pub const write_string_custom =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field metricDescriptor.valueType had an invalid value of \"STRING\": When creating metric custom.googleapis.com/zigps-m0b-b66e4f/str: the value type is not supported for custom metrics.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A distribution whose bucket counts sum to 3 and count is 4. HTTP 400.
pub const write_distribution_count_status = 400;
pub const write_distribution_count =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/dist\", metric.labels={}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"b66e4f-d2\", \"location\": \"us-central1\", \"job\": \"m0\", \"namespace\": \"zigps\"}): Field points[0].distributionValue had an invalid value: Distribution value has |bucket_counts| fields that sum to 3 which does not equal the |count| field value of 4.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A linear layout of width 0. HTTP 400.
pub const write_linear_width_status = 400;
pub const write_linear_width =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/dist\", metric.labels={}, resource.type=\"generic_task\", resource.labels={\"namespace\": \"zigps\", \"task_id\": \"b66e4f-d4\", \"location\": \"us-central1\", \"job\": \"m0\"}): Field points[0].distributionValue had an invalid value: Distribution |bucket_options.linear_buckets| has a |width| of 0 which is not greater than 0.0.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// 201 series in one request. HTTP 400.
pub const write_201_series_status = 400;
pub const write_201_series =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field timeSeries had an invalid value: A maximum of 200 TimeSeries can be written in a single request.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A metric label value of 1,025 bytes. HTTP 400.
pub const write_label_value_long_status = 400;
pub const write_label_value_long =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/gauge2\", metric.labels={\"k\": \"vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\"}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"b66e4f-a\", \"location\": \"us-central1\", \"job\": \"m0\", \"namespace\": \"zigps\"}): Field metric.labels had an invalid value of \"k\": Label value exceeds the maximum string size of 1024 characters.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A metric label key of 101 bytes, in a new type. HTTP 400.
pub const write_label_key_long_status = 400;
pub const write_label_key_long =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field labels[0].key had an invalid value of \"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk\": When creating metric custom.googleapis.com/zigps-m0b-b66e4f/keys:  the label key is more than 100 characters long.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A metric label key starting with a digit. HTTP 400.
pub const write_label_key_digit_status = 400;
pub const write_label_key_digit =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/keys\", metric.labels={\"1k\": \"v\"}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"b66e4f-kd\", \"location\": \"us-central1\", \"job\": \"m0\", \"namespace\": \"zigps\"}): Field metric.labels had an invalid value of \"1k\": Label key contains invalid characters.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// 31 metric labels. HTTP 400.
pub const write_31_labels_status = 400;
pub const write_31_labels =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/l31\", metric.labels={\"l15\": \"v\", \"l7\": \"v\", \"l6\": \"v\", \"l2\": \"v\", \"l30\": \"v\", \"l1\": \"v\", \"l13\": \"v\", \"l17\": \"v\", \"l12\": \"v\", \"l0\": \"v\", \"l4\": \"v\", \"l28\": \"v\", \"l21\": \"v\", \"l23\": \"v\", \"l19\": \"v\", \"l29\": \"v\", \"l20\": \"v\", \"l11\": \"v\", \"l5\": \"v\", \"l24\": \"v\", \"l18\": \"v\", \"l9\": \"v\", \"l26\": \"v\", \"l8\": \"v\", \"l27\": \"v\", \"l10\": \"v\", \"l25\": \"v\", \"l14\": \"v\", \"l22\": \"v\", \"l16\": \"v\", \"l3\": \"v\"}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"b66e4f-a\", \"job\": \"m0\", \"location\": \"us-central1\", \"namespace\": \"zigps\"}): Field metric.labels had an invalid value: The metric custom.googleapis.com/zigps-m0b-b66e4f/l31 has more than 30 labels.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A string point of 1,025 bytes. HTTP 400.
pub const write_string_long_status = 400;
pub const write_string_long =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-m0b-b66e4f/str2\", metric.labels={}, resource.type=\"generic_task\", resource.labels={\"task_id\": \"b66e4f-a\", \"job\": \"m0\", \"namespace\": \"zigps\", \"location\": \"us-central1\"}): Field points[0].value had an invalid value: The metric value exceeds the maximum string size of 1024 characters.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A request with no series. HTTP 400.
pub const write_empty_status = 400;
pub const write_empty =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Request was missing field timeSeries.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A resource project_id naming another project. HTTP 400.
pub const write_foreign_project_status = 400;
pub const write_foreign_project =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field resource.labels.project_id had an invalid value of \"other-project\": if present, must be the project number or ID in the request name (projects/extractctl).",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A read of a type with no descriptor. HTTP 404.
pub const read_unknown_type_status = 404;
pub const read_unknown_type =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "Cannot find metric(s) that match type = \"custom.googleapis.com/zigps-m0b-b66e4f/nothing\". If a metric was created recently, it could take up to 10 minutes to become available. Please try again soon.",
    \\    "status": "NOT_FOUND"
    \\  }
    \\}
;

/// An aligner without an alignment period. HTTP 400.
pub const read_no_period_status = 400;
pub const read_no_period =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field aggregation.alignmentPeriod had an invalid value of \"0\": The alignment period must be greater than or equal to 10s.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A reducer without an aligner. HTTP 400.
pub const read_no_aligner_status = 400;
pub const read_no_aligner =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Request was missing field aggregation.perSeriesAligner.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A read whose start is after its end. HTTP 400.
pub const read_start_after_end_status = 400;
pub const read_start_after_end =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field interval.endTime had an invalid value: The start time must be less than or equal to the end time.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A read without a filter. HTTP 400.
pub const read_no_type_status = 400;
pub const read_no_type =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "The provided filter matches more than one metric. TimeSeries data are limited to a single metric per request.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// An alignment period of 9 s. HTTP 400.
pub const read_period_9s_status = 400;
pub const read_period_9s =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field aggregation.alignmentPeriod had an invalid value of \"9s\": The alignment period must be greater than or equal to 10s.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A read without view of one series with two points, newest first. HTTP 200.
pub const read_full_status = 200;
pub const read_full =
    \\{
    \\  "timeSeries": [
    \\    {
    \\      "metric": {
    \\        "labels": {
    \\          "k": "mix1"
    \\        },
    \\        "type": "custom.googleapis.com/zigps-m0-62b2c8/gauge"
    \\      },
    \\      "resource": {
    \\        "type": "generic_task",
    \\        "labels": {
    \\          "project_id": "extractctl",
    \\          "task_id": "62b2c8-a",
    \\          "job": "m0",
    \\          "location": "us-central1",
    \\          "namespace": "zigps"
    \\        }
    \\      },
    \\      "metricKind": "GAUGE",
    \\      "valueType": "INT64",
    \\      "points": [
    \\        {
    \\          "interval": {
    \\            "startTime": "2026-10-18T13:46:51.146Z",
    \\            "endTime": "2026-10-18T13:46:51.146Z"
    \\          },
    \\          "value": {
    \\            "int64Value": "2"
    \\          }
    \\        },
    \\        {
    \\          "interval": {
    \\            "startTime": "2026-10-18T13:46:35.949Z",
    \\            "endTime": "2026-10-18T13:46:35.949Z"
    \\          },
    \\          "value": {
    \\            "int64Value": "1"
    \\          }
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "unit": "1"
    \\}
;

/// The same read with pageSize 1: the newer point. HTTP 200.
pub const read_page_1_status = 200;
pub const read_page_1 =
    \\{
    \\  "timeSeries": [
    \\    {
    \\      "metric": {
    \\        "labels": {
    \\          "k": "mix1"
    \\        },
    \\        "type": "custom.googleapis.com/zigps-m0-62b2c8/gauge"
    \\      },
    \\      "resource": {
    \\        "type": "generic_task",
    \\        "labels": {
    \\          "task_id": "62b2c8-a",
    \\          "location": "us-central1",
    \\          "project_id": "extractctl",
    \\          "namespace": "zigps",
    \\          "job": "m0"
    \\        }
    \\      },
    \\      "metricKind": "GAUGE",
    \\      "valueType": "INT64",
    \\      "points": [
    \\        {
    \\          "interval": {
    \\            "startTime": "2026-10-18T13:46:51.146Z",
    \\            "endTime": "2026-10-18T13:46:51.146Z"
    \\          },
    \\          "value": {
    \\            "int64Value": "2"
    \\          }
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "nextPageToken": "COPqxbCV3v3n-wESqQEiIAoaCgsIy5vT1gYQgJHPRRILCMub09YGEICRz0USAhACKgxnZW5lcmljX3Rhc2syd2oWCgdwcm9qZWN0Ggs4MjE1MDcyMDc5OGoXCghsb2NhdGlvbhoLdXMtY2VudHJhbDFqEgoJbmFtZXNwYWNlGgV6aWdwc2oJCgNqb2IaAm0wahMKB3Rhc2tfaWQaCDYyYjJjOC1hchAKCG1ldHJpYzprGgRtaXgx",
    \\  "unit": "1"
    \\}
;

/// Its next page: the older point, the same series again. HTTP 200.
pub const read_page_2_status = 200;
pub const read_page_2 =
    \\{
    \\  "timeSeries": [
    \\    {
    \\      "metric": {
    \\        "labels": {
    \\          "k": "mix1"
    \\        },
    \\        "type": "custom.googleapis.com/zigps-m0-62b2c8/gauge"
    \\      },
    \\      "resource": {
    \\        "type": "generic_task",
    \\        "labels": {
    \\          "location": "us-central1",
    \\          "job": "m0",
    \\          "project_id": "extractctl",
    \\          "namespace": "zigps",
    \\          "task_id": "62b2c8-a"
    \\        }
    \\      },
    \\      "metricKind": "GAUGE",
    \\      "valueType": "INT64",
    \\      "points": [
    \\        {
    \\          "interval": {
    \\            "startTime": "2026-10-18T13:46:35.949Z",
    \\            "endTime": "2026-10-18T13:46:35.949Z"
    \\          },
    \\          "value": {
    \\            "int64Value": "1"
    \\          }
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "unit": "1"
    \\}
;

/// view=HEADERS with pageSize 1: one series, no points. HTTP 200.
pub const read_headers_status = 200;
pub const read_headers =
    \\{
    \\  "timeSeries": [
    \\    {
    \\      "metric": {
    \\        "labels": {
    \\          "k": "ns"
    \\        },
    \\        "type": "custom.googleapis.com/zigps-m0-62b2c8/gauge"
    \\      },
    \\      "resource": {
    \\        "type": "generic_task",
    \\        "labels": {
    \\          "job": "m0",
    \\          "namespace": "",
    \\          "project_id": "extractctl",
    \\          "task_id": "62b2c8-ns",
    \\          "location": "us-central1"
    \\        }
    \\      },
    \\      "metricKind": "GAUGE",
    \\      "valueType": "INT64"
    \\    }
    \\  ],
    \\  "nextPageToken": "COSXkZzgxtX80AESgQEqDGdlbmVyaWNfdGFzazJxahYKB3Byb2plY3QaCzgyMTUwNzIwNzk4ahcKCGxvY2F0aW9uGgt1cy1jZW50cmFsMWoNCgluYW1lc3BhY2UaAGoJCgNqb2IaAm0wahQKB3Rhc2tfaWQaCTYyYjJjOC1uc3IOCghtZXRyaWM6axoCbnM",
    \\  "unit": "1"
    \\}
;

/// ALIGN_MAX over 60 s and REDUCE_SUM across every series. HTTP 200.
pub const read_aligned_status = 200;
pub const read_aligned =
    \\{
    \\  "timeSeries": [
    \\    {
    \\      "metric": {
    \\        "type": "custom.googleapis.com/zigps-m0-62b2c8/gauge"
    \\      },
    \\      "resource": {
    \\        "type": "generic_task",
    \\        "labels": {
    \\          "project_id": "extractctl"
    \\        }
    \\      },
    \\      "metricKind": "GAUGE",
    \\      "valueType": "INT64",
    \\      "points": [
    \\        {
    \\          "interval": {
    \\            "startTime": "2026-10-18T13:46:53.230Z",
    \\            "endTime": "2026-10-18T13:46:53.230Z"
    \\          },
    \\          "value": {
    \\            "int64Value": "71"
    \\          }
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "unit": "1"
    \\}
;

/// A filter matching the label value a\"b\\c, escaped with backslashes. HTTP 200.
pub const read_escaped_status = 200;
pub const read_escaped =
    \\{
    \\  "timeSeries": [
    \\    {
    \\      "metric": {
    \\        "labels": {
    \\          "k": "a\"b\\c"
    \\        },
    \\        "type": "custom.googleapis.com/zigps-m0-62b2c8/gauge"
    \\      },
    \\      "resource": {
    \\        "type": "generic_task",
    \\        "labels": {
    \\          "job": "m0",
    \\          "location": "us-central1",
    \\          "namespace": "zigps",
    \\          "project_id": "extractctl",
    \\          "task_id": "62b2c8-a"
    \\        }
    \\      },
    \\      "metricKind": "GAUGE",
    \\      "valueType": "INT64",
    \\      "points": [
    \\        {
    \\          "interval": {
    \\            "startTime": "2026-10-18T13:46:44.893Z",
    \\            "endTime": "2026-10-18T13:46:44.893Z"
    \\          },
    \\          "value": {
    \\            "int64Value": "4"
    \\          }
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "unit": "1"
    \\}
;

// Answers production gave on 2026-10-19 for issue #239, measured by
// `_tmp/monitoring-pubsub/probe*.py`: Pub/Sub's own metrics and the
// refusals around them. Re-indented; tests compare their messages.

/// A write of Pub/Sub's backlog to pubsub_subscription zigps-mon-517da9-a.
/// HTTP 403.
pub const write_google_metric_status = 403;
pub const write_google_metric =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "User does not have permission to write to metric pubsub.googleapis.com/subscription/num_undelivered_messages.",
    \\    "status": "PERMISSION_DENIED"
    \\  }
    \\}
;

/// A create of pubsub.googleapis.com/subscription/zigps_mon_517da9, GAUGE
/// INT64. HTTP 403.
pub const create_google_descriptor_status = 403;
pub const create_google_descriptor =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "User does not have permission to write to metric pubsub.googleapis.com/subscription/zigps_mon_517da9.",
    \\    "status": "PERMISSION_DENIED"
    \\  }
    \\}
;

/// A write of a new GAUGE INT64 custom.googleapis.com/zigps-mon-517da9/on_sub
/// to pubsub_subscription zigps-mon-517da9-a. Its descriptor was made all the
/// same: deleting it answered 200. HTTP 400.
pub const write_on_pubsub_subscription_status = 400;
pub const write_on_pubsub_subscription =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "One or more TimeSeries could not be written: timeSeries[0] (metric.type=\"custom.googleapis.com/zigps-mon-517da9/on_sub\", metric.labels={}, resource.type=\"pubsub_subscription\", resource.labels={\"subscription_id\": \"zigps-mon-517da9-a\"}): metrics cannot be written to pubsub_subscription, see https://cloud.google.com/monitoring/custom-metrics/creating-metrics#which-resource for a list of writable resource types",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.monitoring.v3.CreateTimeSeriesSummary",
    \\        "totalPointCount": 1,
    \\        "errors": [
    \\          {
    \\            "status": {
    \\              "code": 3
    \\            },
    \\            "pointCount": 1
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// ALIGN_DELTA on Pub/Sub's backlog, a GAUGE INT64. HTTP 400.
pub const read_delta_on_gauge_status = 400;
pub const read_delta_on_gauge =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field aggregation.perSeriesAligner had an invalid value of \"ALIGN_DELTA\": The aligner cannot be applied to metrics with kind GAUGE and value type INT64.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// ALIGN_RATE on Pub/Sub's backlog. HTTP 400.
pub const read_rate_on_gauge_status = 400;
pub const read_rate_on_gauge =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field aggregation.perSeriesAligner had an invalid value of \"ALIGN_RATE\": The aligner cannot be applied to metrics with kind GAUGE and value type INT64.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// ALIGN_RATE on a GAUGE DOUBLE custom metric. HTTP 400.
pub const read_rate_on_double_gauge_status = 400;
pub const read_rate_on_double_gauge =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field aggregation.perSeriesAligner had an invalid value of \"ALIGN_RATE\": The aligner cannot be applied to metrics with kind GAUGE and value type DOUBLE.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// ALIGN_NEXT_OLDER on Pub/Sub's sent count, a DELTA INT64. HTTP 400.
pub const read_next_older_on_delta_status = 400;
pub const read_next_older_on_delta =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field aggregation.perSeriesAligner had an invalid value of \"ALIGN_NEXT_OLDER\": The aligner cannot be applied to metrics with kind DELTA and value type INT64.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// ALIGN_PERCENTILE_99 on Pub/Sub's sent count. HTTP 400.
pub const read_percentile_on_delta_status = 400;
pub const read_percentile_on_delta =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field aggregation.perSeriesAligner had an invalid value of \"ALIGN_PERCENTILE_99\": The aligner cannot be applied to metrics with kind DELTA and value type INT64.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// Pub/Sub's sent count, filtered on resource.type pubsub_topic. HTTP 400.
pub const read_other_resource_type_status = 400;
pub const read_other_resource_type =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "The supplied filter does not specify a valid combination of metric and monitored resource descriptors. The query will not return any time series.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A create of workload.googleapis.com/zigps-mon3-2b2a2a/delta_int64, DELTA
/// INT64. HTTP 400.
pub const create_delta_workload_status = 400;
pub const create_delta_workload =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field metricDescriptor.metricKind had an invalid value of \"DELTA\": When creating metric workload.googleapis.com/zigps-mon3-2b2a2a/delta_int64: the DELTA metric kind is not supported for custom metrics.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A create of external.googleapis.com/zigps-mon3-2b2a2a/delta_int64, DELTA
/// INT64. HTTP 400.
pub const create_delta_external_status = 400;
pub const create_delta_external =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field metricDescriptor.metricKind had an invalid value of \"DELTA\": When creating metric external.googleapis.com/zigps-mon3-2b2a2a/delta_int64: the DELTA metric kind is not supported for external metrics.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A create of external.googleapis.com/zigps-mon3-2b2a2a/gauge_string, GAUGE
/// STRING. HTTP 400.
pub const create_string_external_status = 400;
pub const create_string_external =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field metricDescriptor.valueType had an invalid value of \"STRING\": When creating metric external.googleapis.com/zigps-mon3-2b2a2a/gauge_string: the value type is not supported for external metrics.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A create of workload.googleapis.com/zigps-mon3-2b2a2a/gauge_string, GAUGE
/// STRING. HTTP 400.
pub const create_string_workload_status = 400;
pub const create_string_workload =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field metricDescriptor.valueType had an invalid value of \"STRING\": When creating metric workload.googleapis.com/zigps-mon3-2b2a2a/gauge_string: the value type is not supported for custom metrics.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

// Alerts, measured 2026-10-19 in milestone 0 of the alerts spec
// (`_tmp/alerts-m0/`, issue #246): a threshold policy the probe made
// fired on a metric it wrote, and the alert was read open, then closed
// 91 s after the policy's delete, its metric and resource kept.

/// `alerts.get` of the open alert. HTTP 200. No closeTime, no metadata,
/// no log; the id is no number.
pub const alert_open_status = 200;
pub const alert_open =
    \\{
    \\  "name": "projects/extractctl/alerts/0.oe0ehmpm95z2",
    \\  "state": "OPEN",
    \\  "openTime": "2026-10-19T17:14:00Z",
    \\  "resource": {
    \\    "type": "global",
    \\    "labels": {
    \\      "project_id": "extractctl"
    \\    }
    \\  },
    \\  "metric": {
    \\    "type": "custom.googleapis.com/zigps-alerts-0ea66e/level"
    \\  },
    \\  "policy": {
    \\    "name": "projects/extractctl/alertPolicies/9108504683352368943",
    \\    "displayName": "zigps-alerts-0ea66e",
    \\    "severity": "WARNING",
    \\    "userLabels": {
    \\      "team": "zigps"
    \\    }
    \\  }
    \\}
;

/// The same alert after its policy's delete. HTTP 200.
pub const alert_closed_status = 200;
pub const alert_closed =
    \\{
    \\  "name": "projects/extractctl/alerts/0.oe0ehmpm95z2",
    \\  "state": "CLOSED",
    \\  "openTime": "2026-10-19T17:14:00Z",
    \\  "closeTime": "2026-10-19T17:15:47Z",
    \\  "resource": {
    \\    "type": "global",
    \\    "labels": {
    \\      "project_id": "extractctl"
    \\    }
    \\  },
    \\  "metric": {
    \\    "type": "custom.googleapis.com/zigps-alerts-0ea66e/level"
    \\  },
    \\  "policy": {
    \\    "name": "projects/extractctl/alertPolicies/9108504683352368943",
    \\    "displayName": "zigps-alerts-0ea66e",
    \\    "severity": "WARNING",
    \\    "userLabels": {
    \\      "team": "zigps"
    \\    }
    \\  }
    \\}
;

/// `alerts.list` while the alert was open: `totalSize`, no page token.
pub const alerts_list_status = 200;
pub const alerts_list =
    \\{
    \\  "alerts": [
    \\    {
    \\      "name": "projects/extractctl/alerts/0.oe0ehmpm95z2",
    \\      "state": "OPEN",
    \\      "openTime": "2026-10-19T17:14:00Z",
    \\      "resource": {
    \\        "type": "global",
    \\        "labels": {
    \\          "project_id": "extractctl"
    \\        }
    \\      },
    \\      "metric": {
    \\        "type": "custom.googleapis.com/zigps-alerts-0ea66e/level"
    \\      },
    \\      "policy": {
    \\        "name": "projects/extractctl/alertPolicies/9108504683352368943",
    \\        "displayName": "zigps-alerts-0ea66e",
    \\        "severity": "WARNING",
    \\        "userLabels": {
    \\          "team": "zigps"
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "totalSize": 1
    \\}
;

/// `alerts.get` of an id nobody has. HTTP 404.
pub const alert_unknown_status = 404;
pub const alert_unknown =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "Requested entity was not found.",
    \\    "status": "NOT_FOUND"
    \\  }
    \\}
;

/// `alerts.list` with `filter=zigps-alerts-0ea66e`, a bare word: the
/// filter is the structured language, not a search, whatever the
/// discovery document's wording says. HTTP 400.
pub const alerts_filter_word_status = 400;
pub const alerts_filter_word =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Field filter had an invalid value of \"comparator: \t GLOBAL\nrhs {\n  value: \"zigps-alerts-0ea66e\"\n}\n\": Restriction must have a left-hand side and a right-hand side.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `alerts.list` with `orderBy=severity`, a field it does not sort by.
/// HTTP 400.
pub const alerts_order_bogus_status = 400;
pub const alerts_order_bogus =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Request contains an invalid argument.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A threshold policy on Pub/Sub's publish count, WARNING, with
/// documentation, a label, ALIGN_RATE and a count trigger. HTTP 200.
pub const policy_threshold_status = 200;
pub const policy_threshold =
    \\{
    \\ "name": "projects/extractctl/alertPolicies/9594883664150561401",
    \\ "displayName": "zigps-d5b8f4-threshold",
    \\ "combiner": "OR",
    \\ "creationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:53.325284581Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "mutationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:53.325284581Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "conditionThreshold": {
    \\    "filter": "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" AND resource.type=\"pubsub_topic\"",
    \\    "comparison": "COMPARISON_GT",
    \\    "thresholdValue": 1000,
    \\    "duration": "60s",
    \\    "trigger": {
    \\     "count": 1
    \\    },
    \\    "aggregations": [
    \\     {
    \\      "alignmentPeriod": "60s",
    \\      "perSeriesAligner": "ALIGN_RATE"
    \\     }
    \\    ]
    \\   },
    \\   "displayName": "rate over 1000",
    \\   "name": "projects/extractctl/alertPolicies/9594883664150561401/conditions/9594883664150564016"
    \\  }
    \\ ],
    \\ "documentation": {
    \\  "content": "Publish rate over 1000/s.",
    \\  "mimeType": "text/markdown",
    \\  "subject": "zigps publish rate"
    \\ },
    \\ "userLabels": {
    \\  "zigps": "probe"
    \\ },
    \\ "enabled": true,
    \\ "severity": "WARNING"
    \\}
;

/// An absence policy, disabled, ERROR, with a percent trigger. HTTP 200.
pub const policy_absence_status = 200;
pub const policy_absence =
    \\{
    \\ "name": "projects/extractctl/alertPolicies/5575262459168249474",
    \\ "displayName": "zigps-d5b8f4-absence",
    \\ "combiner": "OR",
    \\ "creationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:54.785040626Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "mutationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:54.785040626Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "conditionAbsent": {
    \\    "filter": "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" AND resource.type=\"pubsub_topic\"",
    \\    "duration": "300s",
    \\    "trigger": {
    \\     "percent": 50
    \\    },
    \\    "aggregations": [
    \\     {
    \\      "alignmentPeriod": "60s",
    \\      "perSeriesAligner": "ALIGN_COUNT"
    \\     }
    \\    ]
    \\   },
    \\   "displayName": "no publishes",
    \\   "name": "projects/extractctl/alertPolicies/5575262459168249474/conditions/5575262459168251595"
    \\  }
    \\ ],
    \\ "userLabels": {
    \\  "zigps": "probe"
    \\ },
    \\ "enabled": false,
    \\ "severity": "ERROR"
    \\}
;

/// A log-match policy, CRITICAL, with a label extractor and the alert
/// strategy production requires of one. HTTP 200.
pub const policy_log_status = 200;
pub const policy_log =
    \\{
    \\ "name": "projects/extractctl/alertPolicies/3389115242718001746",
    \\ "displayName": "zigps-d5b8f4-log",
    \\ "combiner": "OR",
    \\ "creationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:56.159593832Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "mutationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:56.159593832Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "displayName": "probe log line",
    \\   "name": "projects/extractctl/alertPolicies/3389115242718001746/conditions/3389115242717999981",
    \\   "conditionMatchedLog": {
    \\    "filter": "logName=\"projects/extractctl/logs/zigps-d5b8f4\" AND severity>=ERROR",
    \\    "labelExtractors": {
    \\     "k": "EXTRACT(jsonPayload.k)"
    \\    }
    \\   }
    \\  }
    \\ ],
    \\ "userLabels": {
    \\  "zigps": "probe"
    \\ },
    \\ "enabled": true,
    \\ "alertStrategy": {
    \\  "notificationRateLimit": {
    \\   "period": "300s"
    \\  },
    \\  "autoClose": "1800s"
    \\ },
    \\ "severity": "CRITICAL"
    \\}
;

/// An MQL policy with no severity: the field is absent. HTTP 200.
pub const policy_mql_status = 200;
pub const policy_mql =
    \\{
    \\ "name": "projects/extractctl/alertPolicies/4294582767119635845",
    \\ "displayName": "zigps-d5b8f4-mql",
    \\ "combiner": "OR",
    \\ "creationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:57.262961882Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "mutationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:57.262961882Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "displayName": "mql rate",
    \\   "name": "projects/extractctl/alertPolicies/4294582767119635845/conditions/4294582767119635738",
    \\   "conditionMonitoringQueryLanguage": {
    \\    "query": "fetch pubsub_topic | metric 'pubsub.googleapis.com/topic/send_message_operation_count' | align rate(1m) | every 1m | condition val() > 1000 '1/s'",
    \\    "duration": "60s",
    \\    "trigger": {
    \\     "count": 1
    \\    }
    \\   }
    \\  }
    \\ ],
    \\ "userLabels": {
    \\  "zigps": "probe"
    \\ },
    \\ "enabled": true
    \\}
;

/// A PromQL policy with an evaluation interval and labels. HTTP 200.
pub const policy_promql_status = 200;
pub const policy_promql =
    \\{
    \\ "name": "projects/extractctl/alertPolicies/6864678670941340587",
    \\ "displayName": "zigps-d5b8f4-promql",
    \\ "combiner": "OR",
    \\ "creationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:58.538873776Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "mutationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:58.538873776Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "displayName": "promql rate",
    \\   "name": "projects/extractctl/alertPolicies/6864678670941340587/conditions/6864678670941342846",
    \\   "conditionPrometheusQueryLanguage": {
    \\    "query": "rate(pubsub_googleapis_com:topic_send_message_operation_count[5m]) > 1000",
    \\    "duration": "60s",
    \\    "evaluationInterval": "30s",
    \\    "labels": {
    \\     "zigps": "probe"
    \\    }
    \\   }
    \\  }
    \\ ],
    \\ "userLabels": {
    \\  "zigps": "probe"
    \\ },
    \\ "enabled": true
    \\}
;

/// Two threshold conditions combined with AND. HTTP 200.
pub const policy_two_status = 200;
pub const policy_two =
    \\{
    \\ "name": "projects/extractctl/alertPolicies/7136103533907925714",
    \\ "displayName": "zigps-d5b8f4-two",
    \\ "combiner": "AND",
    \\ "creationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:59.726220947Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "mutationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:59.726220947Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "conditionThreshold": {
    \\    "filter": "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" AND resource.type=\"pubsub_topic\"",
    \\    "comparison": "COMPARISON_GT",
    \\    "thresholdValue": 1000,
    \\    "duration": "0s",
    \\    "aggregations": [
    \\     {
    \\      "alignmentPeriod": "60s",
    \\      "perSeriesAligner": "ALIGN_RATE"
    \\     }
    \\    ]
    \\   },
    \\   "displayName": "rate over 1000",
    \\   "name": "projects/extractctl/alertPolicies/7136103533907925714/conditions/7136103533907926391"
    \\  },
    \\  {
    \\   "conditionThreshold": {
    \\    "filter": "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" AND resource.type=\"pubsub_topic\"",
    \\    "comparison": "COMPARISON_LT",
    \\    "thresholdValue": 1,
    \\    "duration": "0s",
    \\    "aggregations": [
    \\     {
    \\      "alignmentPeriod": "60s",
    \\      "perSeriesAligner": "ALIGN_RATE"
    \\     }
    \\    ]
    \\   },
    \\   "displayName": "rate under 1",
    \\   "name": "projects/extractctl/alertPolicies/7136103533907925714/conditions/7136103533907923886"
    \\  }
    \\ ],
    \\ "userLabels": {
    \\  "zigps": "probe"
    \\ },
    \\ "enabled": true
    \\}
;

/// One page of one policy: `totalSize` on every page, a token. HTTP 200.
pub const policy_page_status = 200;
pub const policy_page =
    \\{
    \\ "nextPageToken": "H4sIAAAAAAAAAAXBsQ2AQAwEwY6Q923O5y-IEBEg6mfmft7r-NgkYw1quQwlx870wLlqNY6gSz8lohzAMAAAAA==",
    \\ "alertPolicies": [
    \\  {
    \\   "name": "projects/extractctl/alertPolicies/3389115242718001746",
    \\   "displayName": "zigps-d5b8f4-log",
    \\   "combiner": "OR",
    \\   "creationRecord": {
    \\    "mutateTime": "2026-10-20T18:55:56.159593832Z",
    \\    "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\   },
    \\   "mutationRecord": {
    \\    "mutateTime": "2026-10-20T18:55:56.159593832Z",
    \\    "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "displayName": "probe log line",
    \\     "name": "projects/extractctl/alertPolicies/3389115242718001746/conditions/3389115242717999981",
    \\     "conditionMatchedLog": {
    \\      "filter": "logName=\"projects/extractctl/logs/zigps-d5b8f4\" AND severity>=ERROR",
    \\      "labelExtractors": {
    \\       "k": "EXTRACT(jsonPayload.k)"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "userLabels": {
    \\    "zigps": "probe"
    \\   },
    \\   "enabled": true,
    \\   "alertStrategy": {
    \\    "notificationRateLimit": {
    \\     "period": "300s"
    \\    },
    \\    "autoClose": "1800s"
    \\   },
    \\   "severity": "CRITICAL"
    \\  }
    \\ ],
    \\ "totalSize": 6
    \\}
;

/// The answer to `PATCH ...?updateMask=enabled` with `{"enabled":false}`:
/// the whole policy, its mutation record moved. HTTP 200.
pub const policy_disabled_status = 200;
pub const policy_disabled =
    \\{
    \\ "name": "projects/extractctl/alertPolicies/9594883664150561401",
    \\ "displayName": "zigps-d5b8f4-threshold",
    \\ "combiner": "OR",
    \\ "creationRecord": {
    \\  "mutateTime": "2026-10-20T18:55:53.325284581Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "mutationRecord": {
    \\  "mutateTime": "2026-10-20T18:56:08.456766336Z",
    \\  "mutatedBy": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "conditionThreshold": {
    \\    "filter": "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" AND resource.type=\"pubsub_topic\"",
    \\    "comparison": "COMPARISON_GT",
    \\    "thresholdValue": 1000,
    \\    "duration": "60s",
    \\    "trigger": {
    \\     "count": 1
    \\    },
    \\    "aggregations": [
    \\     {
    \\      "alignmentPeriod": "60s",
    \\      "perSeriesAligner": "ALIGN_RATE"
    \\     }
    \\    ]
    \\   },
    \\   "displayName": "rate over 1000",
    \\   "name": "projects/extractctl/alertPolicies/9594883664150561401/conditions/9594883664150564016"
    \\  }
    \\ ],
    \\ "documentation": {
    \\  "content": "Publish rate over 1000/s.",
    \\  "mimeType": "text/markdown",
    \\  "subject": "zigps publish rate"
    \\ },
    \\ "userLabels": {
    \\  "zigps": "probe"
    \\ },
    \\ "enabled": false,
    \\ "severity": "WARNING"
    \\}
;

/// A get of a policy nobody has. HTTP 404.
pub const policy_unknown_status = 404;
pub const policy_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Failed to find alert policy 1234567890 in extractctl.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A patch of a policy nobody has: the project's number in the words.
/// HTTP 404.
pub const policy_patch_unknown_status = 404;
pub const policy_patch_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Failed to find alert policy 1234567890 in 82150720798.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A filter on `severity`, which policies cannot be filtered by. HTTP 400.
pub const policy_filter_severity_status = 400;
pub const policy_filter_severity =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid field \"filter\" [value ==\"severity=\"WARNING\"\"]; member reference \"severity\" is not valid; No such field: severity.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A filter of a bare word. HTTP 400.
pub const policy_filter_bare_status = 400;
pub const policy_filter_bare =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid field \"filter\" [value ==\"zigps-d5b8f4\"]; member reference \"zigps-d5b8f4\" is not valid; No such field: zigps-d5b8f4.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A filter that does not parse. HTTP 400.
pub const policy_filter_syntax_status = 400;
pub const policy_filter_syntax =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Could not parse filter \"display_name=(\"; syntax error at line 1, token '<EOF>'",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// `orderBy` with a trailing `desc`. HTTP 400.
pub const policy_order_desc_word_status = 400;
pub const policy_order_desc_word =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid field \"order_by\" [value == \"display_name desc\"; member reference \"display_name desc\" is invalid; No such field: display_name desc.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A patch with a token for `monitoring.read` alone. HTTP 403.
pub const policy_patch_read_scope_status = 403;
pub const policy_patch_read_scope =
    \\{
    \\ "error": {
    \\  "code": 403,
    \\  "message": "Request had insufficient authentication scopes.",
    \\  "status": "PERMISSION_DENIED",
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\    "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
    \\    "domain": "googleapis.com",
    \\    "metadata": {
    \\     "method": "google.monitoring.v3.AlertPolicyService.UpdateAlertPolicy",
    \\     "service": "monitoring.googleapis.com"
    \\    }
    \\   }
    \\  ]
    \\ }
    \\}
;

/// The answer to a create: the times as sent, to the microsecond (the
/// probe sent whole seconds here). HTTP 200.
pub const snooze_created_status = 200;
pub const snooze_created =
    \\{
    \\ "name": "projects/extractctl/snoozes/66323307854672813985269061791550861051",
    \\ "criteria": {
    \\  "policies": [
    \\   "projects/extractctl/alertPolicies/1234567890"
    \\  ]
    \\ },
    \\ "interval": {
    \\  "startTime": "2026-10-20T18:58:49Z",
    \\  "endTime": "2026-10-20T19:08:29Z"
    \\ },
    \\ "displayName": "zigps-98dd5a-active"
    \\}
;

/// A create sent with microseconds, answered with them; later reads keep
/// whole seconds. HTTP 200.
pub const snooze_created_micros_status = 200;
pub const snooze_created_micros =
    \\{
    \\ "name": "projects/extractctl/snoozes/141366793827031231927670956031820956967",
    \\ "criteria": {
    \\  "policies": [
    \\   "projects/extractctl/alertPolicies/9594883664150561401"
    \\  ]
    \\ },
    \\ "interval": {
    \\  "startTime": "2026-10-20T18:56:34.868813Z",
    \\  "endTime": "2026-10-20T18:58:34.868813Z"
    \\ },
    \\ "displayName": "zigps-d5b8f4-active"
    \\}
;

/// That snooze read back: whole seconds. HTTP 200.
pub const snooze_read_status = 200;
pub const snooze_read =
    \\{
    \\ "name": "projects/extractctl/snoozes/141366793827031231927670956031820956967",
    \\ "criteria": {
    \\  "policies": [
    \\   "projects/extractctl/alertPolicies/9594883664150561401"
    \\  ]
    \\ },
    \\ "interval": {
    \\  "startTime": "2026-10-20T18:56:34Z",
    \\  "endTime": "2026-10-20T18:58:34Z"
    \\ },
    \\ "displayName": "zigps-d5b8f4-active"
    \\}
;

/// Every snooze, newest start first, no token. HTTP 200.
pub const snooze_page_status = 200;
pub const snooze_page =
    \\{
    \\ "snoozes": [
    \\  {
    \\   "name": "projects/extractctl/snoozes/19761671275394382374556839010361943928",
    \\   "criteria": {
    \\    "policies": [
    \\     "projects/extractctl/alertPolicies/9594883664150561401"
    \\    ]
    \\   },
    \\   "interval": {
    \\    "startTime": "2026-10-20T19:11:14Z",
    \\    "endTime": "2026-10-20T19:12:44Z"
    \\   },
    \\   "displayName": "zigps-d5b8f4-odd"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/snoozes/242867838827108119907480401533518316931",
    \\   "criteria": {
    \\    "policies": [
    \\     "projects/extractctl/alertPolicies/1234567890"
    \\    ]
    \\   },
    \\   "interval": {
    \\    "startTime": "2026-10-20T19:11:14Z",
    \\    "endTime": "2026-10-20T19:12:14Z"
    \\   },
    \\   "displayName": "zigps-d5b8f4-nobody"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/snoozes/194576221680978247011253250776386421153",
    \\   "criteria": {
    \\    "policies": [
    \\     "projects/extractctl/alertPolicies/9594883664150561401",
    \\     "projects/extractctl/alertPolicies/4294582767119635845"
    \\    ]
    \\   },
    \\   "interval": {
    \\    "startTime": "2026-10-20T19:06:14Z",
    \\    "endTime": "2026-10-20T19:07:14Z"
    \\   },
    \\   "displayName": "zigps-d5b8f4-upcoming"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/snoozes/141366793827031231927670956031820956967",
    \\   "criteria": {
    \\    "policies": [
    \\     "projects/extractctl/alertPolicies/9594883664150561401"
    \\    ]
    \\   },
    \\   "interval": {
    \\    "startTime": "2026-10-20T18:56:34Z",
    \\    "endTime": "2026-10-20T18:58:34Z"
    \\   },
    \\   "displayName": "zigps-d5b8f4-active"
    \\  }
    \\ ]
    \\}
;

/// An active snooze, over a minute old, ended at now. HTTP 200.
pub const snooze_ended_status = 200;
pub const snooze_ended =
    \\{
    \\ "name": "projects/extractctl/snoozes/66323307854672813985269061791550861051",
    \\ "criteria": {
    \\  "policies": [
    \\   "projects/extractctl/alertPolicies/1234567890"
    \\  ]
    \\ },
    \\ "interval": {
    \\  "startTime": "2026-10-20T18:58:49Z",
    \\  "endTime": "2026-10-20T19:00:03Z"
    \\ },
    \\ "displayName": "zigps-98dd5a-active"
    \\}
;

/// An active snooze under a minute old, cancelled: end equal to start.
/// HTTP 200.
pub const snooze_cancelled_active_status = 200;
pub const snooze_cancelled_active =
    \\{
    \\ "name": "projects/extractctl/snoozes/103582372923997332788178603503246600980",
    \\ "criteria": {
    \\  "policies": [
    \\   "projects/extractctl/alertPolicies/1234567890"
    \\  ]
    \\ },
    \\ "interval": {
    \\  "startTime": "2026-10-20T18:58:49Z",
    \\  "endTime": "2026-10-20T18:58:49Z"
    \\ },
    \\ "displayName": "zigps-98dd5a-young"
    \\}
;

/// An upcoming snooze cancelled: start and end both now. HTTP 200.
pub const snooze_cancelled_upcoming_status = 200;
pub const snooze_cancelled_upcoming =
    \\{
    \\ "name": "projects/extractctl/snoozes/242831289449413298544550108805664711645",
    \\ "criteria": {
    \\  "policies": [
    \\   "projects/extractctl/alertPolicies/1234567890"
    \\  ]
    \\ },
    \\ "interval": {
    \\  "startTime": "2026-10-20T19:00:44Z",
    \\  "endTime": "2026-10-20T19:00:44Z"
    \\ },
    \\ "displayName": "zigps-98dd5a-late"
    \\}
;

/// A create starting two minutes ago. HTTP 400.
pub const snooze_past_start_status = 400;
pub const snooze_past_start =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "The Snooze cannot start in the past.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A create naming 17 policies. HTTP 400.
pub const snooze_seventeen_status = 400;
pub const snooze_seventeen =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "The criteria cannot have more than 16 policies that the Snooze applies to.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A create with a filter and two policies. HTTP 400.
pub const snooze_filter_two_status = 400;
pub const snooze_filter_two =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "The criteria must have exactly one policy given a non-empty filter.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A create without a display name. HTTP 400.
pub const snooze_no_name_status = 400;
pub const snooze_no_name =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "The Snooze must have a display name.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A create whose end comes before its start. HTTP 400.
pub const snooze_backwards_status = 400;
pub const snooze_backwards =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "The snooze duration must be >= 1m.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A get of a snooze nobody has. HTTP 404.
pub const snooze_unknown_status = 404;
pub const snooze_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The snooze (with id 1234567890) was not found.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A patch of a snooze nobody has. HTTP 404.
pub const snooze_patch_unknown_status = 404;
pub const snooze_patch_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The snooze to update (with id 1234567890) was not found.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// An active snooze under a minute old, its end moved to now. HTTP 400.
pub const snooze_too_short_status = 400;
pub const snooze_too_short =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "The snooze duration must be >= 1m, unless the snooze is being canceled, in which case it should be of length 0.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// An upcoming snooze, its end alone moved to its start. HTTP 400.
pub const snooze_cancel_upcoming_end_only_status = 400;
pub const snooze_cancel_upcoming_end_only =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "An upcoming snooze's start and end time must be set to the current time to cancel it.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// Any change to an ended or cancelled snooze, a repeat included. HTTP 400.
pub const snooze_already_ended_status = 400;
pub const snooze_already_ended =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Cannot update a snooze that already ended, or that was canceled.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A snooze filter with `>`. HTTP 400.
pub const snooze_filter_greater_status = 400;
pub const snooze_filter_greater =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Field filter had an invalid value of \"go/debugstr  \ncomparator: GREATER_THAN\nlhs {\n  member {\n    expressions {\n      value: \"interval\"\n    }\n    expressions {\n      value: \"end_time\"\n    }\n  }\n}\nrhs {\n  phrase {\n    values: \"2026-10-20T18\"\n    values: \":\"\n    values: \"56\"\n    values: \":\"\n    values: \"41.506362Z\"\n  }\n}\n\": Only equality, greater than or equals comparison and less than or equals comparison restrictions are supported.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A snooze filter with OR. HTTP 400.
pub const snooze_filter_or_status = 400;
pub const snooze_filter_or =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Field filter had an invalid value of \"go/debugproto   \ndisjunction {\n  expressions {\n    restriction {\n      comparator: GREATER_THAN_EQUALS\n      lhs {\n        member {\n          expressions {\n            value: \"interval\"\n          }\n          expressions {\n            value: \"start_time\"\n          }\n        }\n      }\n      rhs {\n        phrase {\n          values: \"2026-10-20T18\"\n          values: \":\"\n          values: \"58\"\n          values: \":\"\n          values: \"55Z\"\n        }\n      }\n    }\n  }\n  expressions {\n    restriction {\n      comparator: LESS_THAN_EQUALS\n      lhs {\n        member {\n          expressions {\n            value: \"interval\"\n          }\n          expressions {\n            value: \"end_time\"\n          }\n        }\n      }\n      rhs {\n        phrase {\n          values: \"2026-10-20T18\"\n          values: \":\"\n          values: \"58\"\n          values: \":\"\n          values: \"55Z\"\n        }\n      }\n    }\n  }\n}\n\": Only restrictions and conjunctions are supported.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A snooze filter with an unquoted time. HTTP 400.
pub const snooze_filter_unquoted_status = 400;
pub const snooze_filter_unquoted =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Field filter had an invalid value of \"interval.end_time >= 2026-10-20T18:58:55Z\": Invalid filter syntax.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A snooze filter on display_name. HTTP 400.
pub const snooze_filter_display_name_status = 400;
pub const snooze_filter_display_name =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Field filter had an invalid value of \"go/debugstr  \ncomparator: EQUALS\nlhs {\n  value: \"display_name\"\n}\nrhs {\n  phrase {\n    values: \"zigps-d5b8f4-active\"\n  }\n}\n\": Unrecognized filter property: display_name",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;
