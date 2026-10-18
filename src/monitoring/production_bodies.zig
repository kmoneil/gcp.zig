//! Answers production gave on 2026-10-18, measured in milestone 0 of the
//! Monitoring spec (`_tmp/monitoring-m0/`), for tests: the probes' own
//! `zigps-m0*` metrics and refusals, verbatim but for a final line break.
//! Test code only.

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

/// A cumulative total lower than the last, under the same start. HTTP 400.
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
