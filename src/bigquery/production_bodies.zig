//! Answers production gave on 2026-10-21, measured in milestone 0 of the
//! BigQuery spec (`_tmp/bigquery-m0/`), for tests: the public samples and
//! the probe's own `zigps_` dataset, tables and jobs, reserialized in the
//! wire's key order (the probe saved parsed bodies). The dataset list is
//! trimmed to the probe's own dataset: the project's others are not this
//! library's. Test code only.

/// bigquery-public-data:samples, read from another project. HTTP 200.
pub const dataset_public_status = 200;
pub const dataset_public =
    \\{
    \\ "kind": "bigquery#dataset",
    \\ "etag": "Kh3ZQoe0NmSydRlxOI2pnQ==",
    \\ "id": "bigquery-public-data:samples",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/bigquery-public-data/datasets/samples",
    \\ "datasetReference": {
    \\  "datasetId": "samples",
    \\  "projectId": "bigquery-public-data"
    \\ },
    \\ "description": "Data Updated On : 2020-12-02\nA collection of tables that are subset of larger datasets.  These tables are suited for testing queries and learning BigQuery.",
    \\ "labels": {
    \\  "dg_data_source": "public",
    \\  "dg_data_context": "metadata",
    \\  "dg_data_confidentiality": "public",
    \\  "dataplex-data-documentation-published-project": "bigquery-public-data",
    \\  "dataplex-data-documentation-published-location": "us-central1",
    \\  "dataplex-data-documentation-published-scan": "a9bb275bd-2f20-4e05-9a3d-486ab8fbf6fb"
    \\ },
    \\ "access": [
    \\  {
    \\   "role": "WRITER",
    \\   "specialGroup": "projectWriters"
    \\  },
    \\  {
    \\   "role": "OWNER",
    \\   "specialGroup": "projectOwners"
    \\  },
    \\  {
    \\   "role": "OWNER",
    \\   "userByEmail": "public-data-migration@bigquery-public-data.iam.gserviceaccount.com"
    \\  },
    \\  {
    \\   "role": "READER",
    \\   "iamMember": "allUsers"
    \\  },
    \\  {
    \\   "role": "READER",
    \\   "specialGroup": "projectReaders"
    \\  }
    \\ ],
    \\ "creationTime": "1457975794805",
    \\ "lastModifiedTime": "1773065902215",
    \\ "location": "US",
    \\ "type": "DEFAULT",
    \\ "maxTimeTravelHours": "168"
    \\}
;

/// The probe's own dataset, with a description, a label and a default table expiration. HTTP 200.
pub const dataset_ours_status = 200;
pub const dataset_ours =
    \\{
    \\ "kind": "bigquery#dataset",
    \\ "etag": "y2bUJBApVwXzAvtHDxAW+A==",
    \\ "id": "extractctl:zigps_9cb674",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/datasets/zigps_9cb674",
    \\ "datasetReference": {
    \\  "datasetId": "zigps_9cb674",
    \\  "projectId": "extractctl"
    \\ },
    \\ "description": "zigps probe",
    \\ "defaultTableExpirationMs": "86400000",
    \\ "labels": {
    \\  "zigps": "probe"
    \\ },
    \\ "access": [
    \\  {
    \\   "role": "WRITER",
    \\   "specialGroup": "projectWriters"
    \\  },
    \\  {
    \\   "role": "OWNER",
    \\   "specialGroup": "projectOwners"
    \\  },
    \\  {
    \\   "role": "OWNER",
    \\   "userByEmail": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  },
    \\  {
    \\   "role": "READER",
    \\   "specialGroup": "projectReaders"
    \\  }
    \\ ],
    \\ "creationTime": "1792597662365",
    \\ "lastModifiedTime": "1792597662365",
    \\ "location": "US",
    \\ "type": "DEFAULT",
    \\ "maxTimeTravelHours": "168"
    \\}
;

/// datasets.list with all=true, trimmed to the probe's own dataset. HTTP 200.
pub const datasets_page_status = 200;
pub const datasets_page =
    \\{
    \\ "kind": "bigquery#datasetList",
    \\ "etag": "ZiNUw5j689Lyjfev615Bug==",
    \\ "datasets": [
    \\  {
    \\   "kind": "bigquery#dataset",
    \\   "id": "extractctl:zigps_9cb674",
    \\   "datasetReference": {
    \\    "datasetId": "zigps_9cb674",
    \\    "projectId": "extractctl"
    \\   },
    \\   "labels": {
    \\    "zigps": "probe"
    \\   },
    \\   "location": "US",
    \\   "type": "DEFAULT"
    \\  }
    \\ ]
    \\}
;

/// bigquery-public-data.samples.shakespeare: four REQUIRED columns. HTTP 200.
pub const table_shakespeare_status = 200;
pub const table_shakespeare =
    \\{
    \\ "kind": "bigquery#table",
    \\ "etag": "BeoZAW5rQH2EllmuKl2a2A==",
    \\ "id": "bigquery-public-data:samples.shakespeare",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/bigquery-public-data/datasets/samples/tables/shakespeare",
    \\ "tableReference": {
    \\  "projectId": "bigquery-public-data",
    \\  "datasetId": "samples",
    \\  "tableId": "shakespeare"
    \\ },
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "word",
    \\    "type": "STRING",
    \\    "mode": "REQUIRED",
    \\    "description": "A single unique word (where whitespace is the delimiter) extracted from a corpus."
    \\   },
    \\   {
    \\    "name": "word_count",
    \\    "type": "INTEGER",
    \\    "mode": "REQUIRED",
    \\    "description": "The number of times this word appears in this corpus."
    \\   },
    \\   {
    \\    "name": "corpus",
    \\    "type": "STRING",
    \\    "mode": "REQUIRED",
    \\    "description": "The work from which this word was extracted."
    \\   },
    \\   {
    \\    "name": "corpus_date",
    \\    "type": "INTEGER",
    \\    "mode": "REQUIRED",
    \\    "description": "The year in which this corpus was published."
    \\   }
    \\  ]
    \\ },
    \\ "numBytes": "6432064",
    \\ "numLongTermBytes": "6432064",
    \\ "numRows": "164656",
    \\ "creationTime": "1457975805856",
    \\ "lastModifiedTime": "1457975805856",
    \\ "type": "TABLE",
    \\ "location": "US",
    \\ "numTimeTravelPhysicalBytes": "0",
    \\ "numTotalLogicalBytes": "6432064",
    \\ "numActiveLogicalBytes": "0",
    \\ "numLongTermLogicalBytes": "6432064",
    \\ "numTotalPhysicalBytes": "485656",
    \\ "numActivePhysicalBytes": "0",
    \\ "numLongTermPhysicalBytes": "485656",
    \\ "numCurrentPhysicalBytes": "485656"
    \\}
;

/// A table made from a query of every type: legacy type names, RANGE element types, arrays and records. HTTP 200.
pub const table_typed_status = 200;
pub const table_typed =
    \\{
    \\ "kind": "bigquery#table",
    \\ "etag": "JG+nOkg8rSvMyirum5gkQQ==",
    \\ "id": "extractctl:zigps_9cb674.typed",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/datasets/zigps_9cb674/tables/typed",
    \\ "tableReference": {
    \\  "projectId": "extractctl",
    \\  "datasetId": "zigps_9cb674",
    \\  "tableId": "typed"
    \\ },
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "int64",
    \\    "type": "INTEGER"
    \\   },
    \\   {
    \\    "name": "int64_min",
    \\    "type": "INTEGER"
    \\   },
    \\   {
    \\    "name": "float64",
    \\    "type": "FLOAT"
    \\   },
    \\   {
    \\    "name": "nan",
    \\    "type": "FLOAT"
    \\   },
    \\   {
    \\    "name": "inf",
    \\    "type": "FLOAT"
    \\   },
    \\   {
    \\    "name": "ninf",
    \\    "type": "FLOAT"
    \\   },
    \\   {
    \\    "name": "numeric",
    \\    "type": "NUMERIC"
    \\   },
    \\   {
    \\    "name": "bignumeric",
    \\    "type": "BIGNUMERIC"
    \\   },
    \\   {
    \\    "name": "bool",
    \\    "type": "BOOLEAN"
    \\   },
    \\   {
    \\    "name": "string",
    \\    "type": "STRING"
    \\   },
    \\   {
    \\    "name": "bytes",
    \\    "type": "BYTES"
    \\   },
    \\   {
    \\    "name": "date",
    \\    "type": "DATE"
    \\   },
    \\   {
    \\    "name": "time",
    \\    "type": "TIME"
    \\   },
    \\   {
    \\    "name": "datetime",
    \\    "type": "DATETIME"
    \\   },
    \\   {
    \\    "name": "timestamp",
    \\    "type": "TIMESTAMP"
    \\   },
    \\   {
    \\    "name": "geography",
    \\    "type": "GEOGRAPHY"
    \\   },
    \\   {
    \\    "name": "json",
    \\    "type": "JSON"
    \\   },
    \\   {
    \\    "name": "interval_sum",
    \\    "type": "INTERVAL"
    \\   },
    \\   {
    \\    "name": "range_date",
    \\    "type": "RANGE",
    \\    "rangeElementType": {
    \\     "type": "DATE"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_ts_open",
    \\    "type": "RANGE",
    \\    "rangeElementType": {
    \\     "type": "TIMESTAMP"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_datetime",
    \\    "type": "RANGE",
    \\    "rangeElementType": {
    \\     "type": "DATETIME"
    \\    }
    \\   },
    \\   {
    \\    "name": "interval_full",
    \\    "type": "INTERVAL"
    \\   },
    \\   {
    \\    "name": "interval_negative",
    \\    "type": "INTERVAL"
    \\   },
    \\   {
    \\    "name": "interval_fraction",
    \\    "type": "INTERVAL"
    \\   },
    \\   {
    \\    "name": "numeric_trailing",
    \\    "type": "NUMERIC"
    \\   },
    \\   {
    \\    "name": "bool_false",
    \\    "type": "BOOLEAN"
    \\   },
    \\   {
    \\    "name": "time_whole",
    \\    "type": "TIME"
    \\   },
    \\   {
    \\    "name": "polygon",
    \\    "type": "GEOGRAPHY"
    \\   },
    \\   {
    \\    "name": "json_numbers",
    \\    "type": "JSON"
    \\   },
    \\   {
    \\    "name": "array_int",
    \\    "type": "INTEGER",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "array_empty",
    \\    "type": "STRING",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "record",
    \\    "type": "RECORD",
    \\    "fields": [
    \\     {
    \\      "name": "x",
    \\      "type": "INTEGER"
    \\     },
    \\     {
    \\      "name": "y",
    \\      "type": "STRING"
    \\     },
    \\     {
    \\      "name": "zs",
    \\      "type": "RECORD",
    \\      "mode": "REPEATED",
    \\      "fields": [
    \\       {
    \\        "name": "z",
    \\        "type": "INTEGER"
    \\       }
    \\      ]
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "array_record",
    \\    "type": "RECORD",
    \\    "mode": "REPEATED",
    \\    "fields": [
    \\     {
    \\      "name": "a",
    \\      "type": "INTEGER"
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "null_int",
    \\    "type": "INTEGER"
    \\   },
    \\   {
    \\    "name": "null_record",
    \\    "type": "RECORD",
    \\    "fields": [
    \\     {
    \\      "name": "q",
    \\      "type": "INTEGER"
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ },
    \\ "numBytes": "547",
    \\ "numLongTermBytes": "0",
    \\ "numRows": "1",
    \\ "creationTime": "1792597663942",
    \\ "expirationTime": "1792684063942",
    \\ "lastModifiedTime": "1792597663942",
    \\ "type": "TABLE",
    \\ "location": "US",
    \\ "numTotalLogicalBytes": "547",
    \\ "numActiveLogicalBytes": "547",
    \\ "numLongTermLogicalBytes": "0"
    \\}
;

/// A table partitioned by DATE(ts) and clustered by user, two rows in it. HTTP 200.
pub const table_events_status = 200;
pub const table_events =
    \\{
    \\ "kind": "bigquery#table",
    \\ "etag": "QoDo5az6LZ1/sSSfUufoeQ==",
    \\ "id": "extractctl:zigps_9cb674.events",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/datasets/zigps_9cb674/tables/events",
    \\ "tableReference": {
    \\  "projectId": "extractctl",
    \\  "datasetId": "zigps_9cb674",
    \\  "tableId": "events"
    \\ },
    \\ "description": "zigps events",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "ts",
    \\    "type": "TIMESTAMP"
    \\   },
    \\   {
    \\    "name": "user",
    \\    "type": "STRING"
    \\   },
    \\   {
    \\    "name": "n",
    \\    "type": "INTEGER"
    \\   }
    \\  ]
    \\ },
    \\ "timePartitioning": {
    \\  "type": "DAY",
    \\  "field": "ts"
    \\ },
    \\ "numBytes": "38",
    \\ "numLongTermBytes": "0",
    \\ "numRows": "2",
    \\ "creationTime": "1792597664678",
    \\ "expirationTime": "1792684064678",
    \\ "lastModifiedTime": "1792597666243",
    \\ "type": "TABLE",
    \\ "location": "US",
    \\ "clustering": {
    \\  "fields": [
    \\   "user"
    \\  ]
    \\ },
    \\ "numTotalLogicalBytes": "38",
    \\ "numActiveLogicalBytes": "38",
    \\ "numLongTermLogicalBytes": "0",
    \\ "partitionDefinition": {
    \\  "partitionedColumn": [
    \\   {
    \\    "field": "ts"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A view: its query, numRows 0. HTTP 200.
pub const table_view_status = 200;
pub const table_view =
    \\{
    \\ "kind": "bigquery#table",
    \\ "etag": "iwJMHMtlHGzNaLqeEj6GKQ==",
    \\ "id": "extractctl:zigps_9cb674.recent",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/datasets/zigps_9cb674/tables/recent",
    \\ "tableReference": {
    \\  "projectId": "extractctl",
    \\  "datasetId": "zigps_9cb674",
    \\  "tableId": "recent"
    \\ },
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "user",
    \\    "type": "STRING"
    \\   },
    \\   {
    \\    "name": "n",
    \\    "type": "INTEGER"
    \\   }
    \\  ]
    \\ },
    \\ "numBytes": "0",
    \\ "numLongTermBytes": "0",
    \\ "numRows": "0",
    \\ "creationTime": "1792597666982",
    \\ "expirationTime": "1792684066982",
    \\ "lastModifiedTime": "1792597666982",
    \\ "type": "VIEW",
    \\ "view": {
    \\  "query": "SELECT user, n FROM `extractctl.zigps_9cb674.events` WHERE n > 0",
    \\  "useLegacySql": false
    \\ },
    \\ "location": "US",
    \\ "numTotalLogicalBytes": "0",
    \\ "numActiveLogicalBytes": "0",
    \\ "numLongTermLogicalBytes": "0"
    \\}
;

/// A materialized view, refreshing every 30 minutes. HTTP 200.
pub const table_materialized_view_status = 200;
pub const table_materialized_view =
    \\{
    \\ "kind": "bigquery#table",
    \\ "etag": "BWp7x32ucfKKSUIEowOV1A==",
    \\ "id": "extractctl:zigps_9cb674.totals",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/datasets/zigps_9cb674/tables/totals",
    \\ "tableReference": {
    \\  "projectId": "extractctl",
    \\  "datasetId": "zigps_9cb674",
    \\  "tableId": "totals"
    \\ },
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "user",
    \\    "type": "STRING"
    \\   },
    \\   {
    \\    "name": "total",
    \\    "type": "INTEGER"
    \\   }
    \\  ]
    \\ },
    \\ "numBytes": "0",
    \\ "numLongTermBytes": "0",
    \\ "numRows": "0",
    \\ "creationTime": "1792597667607",
    \\ "expirationTime": "1792684067607",
    \\ "lastModifiedTime": "1792597667607",
    \\ "type": "MATERIALIZED_VIEW",
    \\ "location": "US",
    \\ "materializedView": {
    \\  "query": "SELECT user, SUM(n) AS total FROM `extractctl.zigps_9cb674.events` GROUP BY user",
    \\  "enableRefresh": true,
    \\  "refreshIntervalMs": "1800000"
    \\ },
    \\ "numTotalLogicalBytes": "0",
    \\ "numActiveLogicalBytes": "0",
    \\ "numLongTermLogicalBytes": "0",
    \\ "materializedViewStatus": {}
    \\}
;

/// tables.list of the probe's dataset: types, partitioning and clustering, no schema. HTTP 200.
pub const tables_page_status = 200;
pub const tables_page =
    \\{
    \\ "kind": "bigquery#tableList",
    \\ "etag": "Rd4IKdsVgAqOCsdKUzI74A==",
    \\ "tables": [
    \\  {
    \\   "kind": "bigquery#table",
    \\   "id": "extractctl:zigps_9cb674.events",
    \\   "tableReference": {
    \\    "projectId": "extractctl",
    \\    "datasetId": "zigps_9cb674",
    \\    "tableId": "events"
    \\   },
    \\   "type": "TABLE",
    \\   "timePartitioning": {
    \\    "type": "DAY",
    \\    "field": "ts"
    \\   },
    \\   "creationTime": "1792597664678",
    \\   "expirationTime": "1792684064678",
    \\   "clustering": {
    \\    "fields": [
    \\     "user"
    \\    ]
    \\   }
    \\  },
    \\  {
    \\   "kind": "bigquery#table",
    \\   "id": "extractctl:zigps_9cb674.recent",
    \\   "tableReference": {
    \\    "projectId": "extractctl",
    \\    "datasetId": "zigps_9cb674",
    \\    "tableId": "recent"
    \\   },
    \\   "type": "VIEW",
    \\   "view": {
    \\    "useLegacySql": false
    \\   },
    \\   "creationTime": "1792597666982",
    \\   "expirationTime": "1792684066982"
    \\  },
    \\  {
    \\   "kind": "bigquery#table",
    \\   "id": "extractctl:zigps_9cb674.totals",
    \\   "tableReference": {
    \\    "projectId": "extractctl",
    \\    "datasetId": "zigps_9cb674",
    \\    "tableId": "totals"
    \\   },
    \\   "type": "MATERIALIZED_VIEW",
    \\   "creationTime": "1792597667607",
    \\   "expirationTime": "1792684067607"
    \\  },
    \\  {
    \\   "kind": "bigquery#table",
    \\   "id": "extractctl:zigps_9cb674.typed",
    \\   "tableReference": {
    \\    "projectId": "extractctl",
    \\    "datasetId": "zigps_9cb674",
    \\    "tableId": "typed"
    \\   },
    \\   "type": "TABLE",
    \\   "creationTime": "1792597663942",
    \\   "expirationTime": "1792684063942"
    \\  }
    \\ ],
    \\ "totalItems": 4
    \\}
;

/// tables.list of samples, three at a time: totalItems 7 and a token. HTTP 200.
pub const tables_page_public_status = 200;
pub const tables_page_public =
    \\{
    \\ "kind": "bigquery#tableList",
    \\ "etag": "L7wBA8cEGEvD+zJC5PXqKA==",
    \\ "nextPageToken": "gsod",
    \\ "tables": [
    \\  {
    \\   "kind": "bigquery#table",
    \\   "id": "bigquery-public-data:samples.github_nested",
    \\   "tableReference": {
    \\    "projectId": "bigquery-public-data",
    \\    "datasetId": "samples",
    \\    "tableId": "github_nested"
    \\   },
    \\   "type": "TABLE",
    \\   "creationTime": "1457975804113"
    \\  },
    \\  {
    \\   "kind": "bigquery#table",
    \\   "id": "bigquery-public-data:samples.github_timeline",
    \\   "tableReference": {
    \\    "projectId": "bigquery-public-data",
    \\    "datasetId": "samples",
    \\    "tableId": "github_timeline"
    \\   },
    \\   "type": "TABLE",
    \\   "creationTime": "1457975805074"
    \\  },
    \\  {
    \\   "kind": "bigquery#table",
    \\   "id": "bigquery-public-data:samples.gsod",
    \\   "tableReference": {
    \\    "projectId": "bigquery-public-data",
    \\    "datasetId": "samples",
    \\    "tableId": "gsod"
    \\   },
    \\   "type": "TABLE",
    \\   "creationTime": "1457975806075"
    \\  }
    \\ ],
    \\ "totalItems": 7
    \\}
;

/// jobs.list, projection=full, five of the probe's jobs, newest first, two failed. HTTP 200.
pub const jobs_page_status = 200;
pub const jobs_page =
    \\{
    \\ "etag": "7Q48hik3APBKY4VwaEr9rw==",
    \\ "kind": "bigquery#jobList",
    \\ "nextPageToken": "1792597569721-job_OXaDynBvSxkkGze-O5gcD4fFDSBr",
    \\ "jobs": [
    \\  {
    \\   "id": "extractctl:US.job_EywYubUjCwnX64kjeEskZYEjrHtS",
    \\   "kind": "bigquery#job",
    \\   "jobReference": {
    \\    "projectId": "extractctl",
    \\    "jobId": "job_EywYubUjCwnX64kjeEskZYEjrHtS",
    \\    "location": "US"
    \\   },
    \\   "state": "DONE",
    \\   "statistics": {
    \\    "creationTime": "1792597573372",
    \\    "startTime": "1792597573642",
    \\    "endTime": "1792597573913",
    \\    "totalBytesProcessed": "547",
    \\    "query": {
    \\     "queryPlan": [
    \\      {
    \\       "name": "S00: Output",
    \\       "id": "0",
    \\       "startMs": "1792597573761",
    \\       "endMs": "1792597573779",
    \\       "waitRatioAvg": 0.6153846153846154,
    \\       "waitMsAvg": "8",
    \\       "waitRatioMax": 0.6153846153846154,
    \\       "waitMsMax": "8",
    \\       "readRatioAvg": 0.23076923076923078,
    \\       "readMsAvg": "3",
    \\       "readRatioMax": 0.23076923076923078,
    \\       "readMsMax": "3",
    \\       "computeRatioAvg": 1,
    \\       "computeMsAvg": "13",
    \\       "computeRatioMax": 1,
    \\       "computeMsMax": "13",
    \\       "writeRatioAvg": 0.38461538461538464,
    \\       "writeMsAvg": "5",
    \\       "writeRatioMax": 0.38461538461538464,
    \\       "writeMsMax": "5",
    \\       "shuffleOutputBytes": "677",
    \\       "shuffleOutputBytesSpilled": "0",
    \\       "recordsRead": "1",
    \\       "recordsWritten": "1",
    \\       "parallelInputs": "1",
    \\       "completedParallelInputs": "1",
    \\       "status": "COMPLETE",
    \\       "steps": [
    \\        {
    \\         "kind": "READ",
    \\         "substeps": [
    \\          "$1:int64, $2:int64_min, $3:float64, $4:nan, $5:inf, $6:ninf, $7:numeric, $8:bignumeric, $9:bool, $10:string, $11:bytes, $12:date, $13:time, $14:datetime, $15:timestamp, $16:geography",
    \\          "FROM extractctl.zigps_828161.typed"
    \\         ]
    \\        },
    \\        {
    \\         "kind": "COMPUTE",
    \\         "substeps": [
    \\          "$50 := MAKE_STRUCT($34, $33)",
    \\          "$51 := MAKE_STRUCT($36, $35)",
    \\          "$52 := MAKE_STRUCT($39, $38, MAKE_STRUCT($41, $40), $37)"
    \\         ]
    \\        },
    \\        {
    \\         "kind": "WRITE",
    \\         "substeps": [
    \\          "$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16",
    \\          "TO __stage00_output"
    \\         ]
    \\        }
    \\       ],
    \\       "slotMs": "38",
    \\       "computeMode": "BIGQUERY"
    \\      }
    \\     ],
    \\     "estimatedBytesProcessed": "547",
    \\     "timeline": [
    \\      {
    \\       "elapsedMs": "148",
    \\       "totalSlotMs": "38",
    \\       "pendingUnits": "0",
    \\       "completedUnits": "1",
    \\       "estimatedRunnableUnits": "0"
    \\      }
    \\     ],
    \\     "totalPartitionsProcessed": "0",
    \\     "totalBytesProcessed": "547",
    \\     "totalBytesBilled": "10485760",
    \\     "billingTier": 1,
    \\     "totalSlotMs": "38",
    \\     "cacheHit": false,
    \\     "referencedTables": [
    \\      {
    \\       "projectId": "extractctl",
    \\       "datasetId": "zigps_828161",
    \\       "tableId": "typed"
    \\      }
    \\     ],
    \\     "statementType": "SELECT",
    \\     "transferredBytes": "0",
    \\     "metadataCacheStatistics": {
    \\      "tableMetadataCacheUsage": [
    \\       {
    \\        "tableReference": {
    \\         "projectId": "extractctl",
    \\         "datasetId": "zigps_828161",
    \\         "tableId": "typed"
    \\        },
    \\        "unusedReason": "OTHER_REASON",
    \\        "explanation": "Table does not have CMETA."
    \\       }
    \\      ]
    \\     }
    \\    },
    \\    "totalSlotMs": "38",
    \\    "finalExecutionDurationMs": "43"
    \\   },
    \\   "configuration": {
    \\    "query": {
    \\     "query": "SELECT * FROM `extractctl.zigps_828161.typed`",
    \\     "destinationTable": {
    \\      "projectId": "extractctl",
    \\      "datasetId": "_de5ba0b733580e9d15132243da0107e55eca8f86",
    \\      "tableId": "anon29c671ae1736bff717ccf503201f5646084543c4717a2c3ed73f408f7aba39a2"
    \\     },
    \\     "writeDisposition": "WRITE_TRUNCATE",
    \\     "priority": "INTERACTIVE",
    \\     "useLegacySql": false
    \\    },
    \\    "jobType": "QUERY"
    \\   },
    \\   "status": {
    \\    "state": "DONE"
    \\   },
    \\   "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  },
    \\  {
    \\   "id": "extractctl:US.job_6G9uRbJv9iWQUWHUK6TEfHdP60L3",
    \\   "kind": "bigquery#job",
    \\   "jobReference": {
    \\    "projectId": "extractctl",
    \\    "jobId": "job_6G9uRbJv9iWQUWHUK6TEfHdP60L3",
    \\    "location": "US"
    \\   },
    \\   "state": "DONE",
    \\   "errorResult": {
    \\    "reason": "notFound",
    \\    "message": "Not found: Table extractctl:zigps_828161.events was not found in location US"
    \\   },
    \\   "statistics": {
    \\    "creationTime": "1792597570638",
    \\    "startTime": "1792597570774",
    \\    "endTime": "1792597570774",
    \\    "query": {}
    \\   },
    \\   "configuration": {
    \\    "query": {
    \\     "query": "CREATE MATERIALIZED VIEW `extractctl.zigps_828161.totals` AS SELECT user, SUM(n) AS total FROM `extractctl.zigps_828161.events` GROUP BY user",
    \\     "priority": "INTERACTIVE",
    \\     "useLegacySql": false
    \\    },
    \\    "jobType": "QUERY"
    \\   },
    \\   "status": {
    \\    "errorResult": {
    \\     "reason": "notFound",
    \\     "message": "Not found: Table extractctl:zigps_828161.events was not found in location US"
    \\    },
    \\    "errors": [
    \\     {
    \\      "reason": "notFound",
    \\      "message": "Not found: Table extractctl:zigps_828161.events was not found in location US"
    \\     }
    \\    ],
    \\    "state": "DONE"
    \\   },
    \\   "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  },
    \\  {
    \\   "id": "extractctl:US.job_oAAC06-VXO0KeeWhnBmzoev3v04l",
    \\   "kind": "bigquery#job",
    \\   "jobReference": {
    \\    "projectId": "extractctl",
    \\    "jobId": "job_oAAC06-VXO0KeeWhnBmzoev3v04l",
    \\    "location": "US"
    \\   },
    \\   "state": "DONE",
    \\   "errorResult": {
    \\    "reason": "notFound",
    \\    "message": "Not found: Table extractctl:zigps_828161.events was not found in location US"
    \\   },
    \\   "statistics": {
    \\    "creationTime": "1792597570119",
    \\    "startTime": "1792597570438",
    \\    "endTime": "1792597570438",
    \\    "query": {}
    \\   },
    \\   "configuration": {
    \\    "query": {
    \\     "query": "CREATE VIEW `extractctl.zigps_828161.recent` AS SELECT user, n FROM `extractctl.zigps_828161.events` WHERE n > 0",
    \\     "priority": "INTERACTIVE",
    \\     "useLegacySql": false
    \\    },
    \\    "jobType": "QUERY"
    \\   },
    \\   "status": {
    \\    "errorResult": {
    \\     "reason": "notFound",
    \\     "message": "Not found: Table extractctl:zigps_828161.events was not found in location US"
    \\    },
    \\    "errors": [
    \\     {
    \\      "reason": "notFound",
    \\      "message": "Not found: Table extractctl:zigps_828161.events was not found in location US"
    \\     }
    \\    ],
    \\    "state": "DONE"
    \\   },
    \\   "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  },
    \\  {
    \\   "id": "extractctl:US.job_hzsX-3RGpH9t27dH2oOuzWg9IXAJ",
    \\   "kind": "bigquery#job",
    \\   "jobReference": {
    \\    "projectId": "extractctl",
    \\    "jobId": "job_hzsX-3RGpH9t27dH2oOuzWg9IXAJ",
    \\    "location": "US"
    \\   },
    \\   "state": "DONE",
    \\   "errorResult": {
    \\    "reason": "invalidQuery",
    \\    "location": "query",
    \\    "message": "Syntax error: Unexpected keyword AT at [1:42]"
    \\   },
    \\   "statistics": {
    \\    "creationTime": "1792597569911",
    \\    "startTime": "1792597569917",
    \\    "endTime": "1792597569917",
    \\    "query": {}
    \\   },
    \\   "configuration": {
    \\    "query": {
    \\     "query": "INSERT `extractctl.zigps_828161.events` (at, user, n) VALUES (TIMESTAMP '2026-10-21 01:00:00+00', 'a', 1), (TIMESTAMP '2026-10-20 02:00:00+00', 'b', 2)",
    \\     "priority": "INTERACTIVE",
    \\     "useLegacySql": false
    \\    },
    \\    "jobType": "QUERY"
    \\   },
    \\   "status": {
    \\    "errorResult": {
    \\     "reason": "invalidQuery",
    \\     "location": "query",
    \\     "message": "Syntax error: Unexpected keyword AT at [1:42]"
    \\    },
    \\    "errors": [
    \\     {
    \\      "reason": "invalidQuery",
    \\      "location": "query",
    \\      "message": "Syntax error: Unexpected keyword AT at [1:42]"
    \\     }
    \\    ],
    \\    "state": "DONE"
    \\   },
    \\   "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  },
    \\  {
    \\   "id": "extractctl:US.job_OXaDynBvSxkkGze-O5gcD4fFDSBr",
    \\   "kind": "bigquery#job",
    \\   "jobReference": {
    \\    "projectId": "extractctl",
    \\    "jobId": "job_OXaDynBvSxkkGze-O5gcD4fFDSBr",
    \\    "location": "US"
    \\   },
    \\   "state": "DONE",
    \\   "errorResult": {
    \\    "reason": "invalidQuery",
    \\    "location": "query",
    \\    "message": "Syntax error: Unexpected keyword AT at [1:48]"
    \\   },
    \\   "statistics": {
    \\    "creationTime": "1792597569721",
    \\    "startTime": "1792597569725",
    \\    "endTime": "1792597569725",
    \\    "query": {}
    \\   },
    \\   "configuration": {
    \\    "query": {
    \\     "query": "CREATE TABLE `extractctl.zigps_828161.events` (at TIMESTAMP, user STRING, n INT64) PARTITION BY DATE(at) CLUSTER BY user OPTIONS (description = 'zigps events')",
    \\     "priority": "INTERACTIVE",
    \\     "useLegacySql": false
    \\    },
    \\    "jobType": "QUERY"
    \\   },
    \\   "status": {
    \\    "errorResult": {
    \\     "reason": "invalidQuery",
    \\     "location": "query",
    \\     "message": "Syntax error: Unexpected keyword AT at [1:48]"
    \\    },
    \\    "errors": [
    \\     {
    \\      "reason": "invalidQuery",
    \\      "location": "query",
    \\      "message": "Syntax error: Unexpected keyword AT at [1:48]"
    \\     }
    \\    ],
    \\    "state": "DONE"
    \\   },
    \\   "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com"
    \\  }
    \\ ]
    \\}
;

/// jobs.get of a cancelled query: DONE, errorResult stopped. HTTP 200.
pub const job_cancelled_status = 200;
pub const job_cancelled =
    \\{
    \\ "kind": "bigquery#job",
    \\ "etag": "v0+EGL4rKDo1EQvwMrsBeQ==",
    \\ "id": "extractctl:US.job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/jobs/job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC?location=US",
    \\ "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "configuration": {
    \\  "query": {
    \\   "query": "SELECT COUNT(*) FROM UNNEST(GENERATE_ARRAY(1, 1000000)) AS a CROSS JOIN UNNEST(GENERATE_ARRAY(1, 3000)) AS b",
    \\   "destinationTable": {
    \\    "projectId": "extractctl",
    \\    "datasetId": "_de5ba0b733580e9d15132243da0107e55eca8f86",
    \\    "tableId": "anonev_ibGMFUhJ98UV6eZEsXfVDSkzcIxslZ0nEUscKmooTOk"
    \\   },
    \\   "writeDisposition": "WRITE_TRUNCATE",
    \\   "priority": "INTERACTIVE",
    \\   "useQueryCache": false,
    \\   "useLegacySql": false
    \\  },
    \\  "jobType": "QUERY"
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\  "location": "US"
    \\ },
    \\ "statistics": {
    \\  "creationTime": "1792597550138",
    \\  "startTime": "1792597550188",
    \\  "endTime": "1792597561013",
    \\  "totalBytesProcessed": "0",
    \\  "query": {
    \\   "queryPlan": [
    \\    {
    \\     "name": "S00: Input",
    \\     "id": "0",
    \\     "startMs": "1792597550519",
    \\     "endMs": "1792597550592",
    \\     "waitMsAvg": "0",
    \\     "waitMsMax": "0",
    \\     "readMsAvg": "0",
    \\     "readMsMax": "0",
    \\     "computeMsAvg": "109",
    \\     "computeMsMax": "109",
    \\     "writeMsAvg": "4",
    \\     "writeMsMax": "4",
    \\     "shuffleOutputBytes": "0",
    \\     "shuffleOutputBytesSpilled": "0",
    \\     "recordsRead": "0",
    \\     "recordsWritten": "1",
    \\     "parallelInputs": "1",
    \\     "completedParallelInputs": "1",
    \\     "status": "COMPLETE",
    \\     "steps": [
    \\      {
    \\       "kind": "COMPUTE",
    \\       "substeps": [
    \\        "$10 := generate_array(1, 1000000)"
    \\       ]
    \\      },
    \\      {
    \\       "kind": "WRITE",
    \\       "substeps": [
    \\        "$10",
    \\        "TO __stage00_output"
    \\       ]
    \\      }
    \\     ],
    \\     "slotMs": "136",
    \\     "computeMode": "BIGQUERY"
    \\    },
    \\    {
    \\     "name": "S01: Output",
    \\     "id": "1",
    \\     "startMs": "1792597550598",
    \\     "inputStages": [
    \\      "0"
    \\     ],
    \\     "waitMsAvg": "0",
    \\     "waitMsMax": "0",
    \\     "readMsAvg": "0",
    \\     "readMsMax": "0",
    \\     "computeMsAvg": "0",
    \\     "computeMsMax": "0",
    \\     "writeMsAvg": "0",
    \\     "writeMsMax": "0",
    \\     "shuffleOutputBytes": "0",
    \\     "shuffleOutputBytesSpilled": "0",
    \\     "recordsRead": "0",
    \\     "recordsWritten": "0",
    \\     "parallelInputs": "1",
    \\     "completedParallelInputs": "0",
    \\     "status": "RUNNING",
    \\     "steps": [
    \\      {
    \\       "kind": "READ",
    \\       "substeps": [
    \\        "$10",
    \\        "FROM __stage00_output"
    \\       ]
    \\      },
    \\      {
    \\       "kind": "AGGREGATE",
    \\       "substeps": [
    \\        "$1 := SUM_OF_COUNTS($20)"
    \\       ]
    \\      },
    \\      {
    \\       "kind": "AGGREGATE",
    \\       "substeps": [
    \\        "$20 := COUNT_STAR()"
    \\       ]
    \\      },
    \\      {
    \\       "kind": "COMPUTE",
    \\       "substeps": [
    \\        "$30 := generate_array(1, 3000)"
    \\       ]
    \\      },
    \\      {
    \\       "kind": "WRITE",
    \\       "substeps": [
    \\        "$1",
    \\        "TO __stage01_output"
    \\       ]
    \\      }
    \\     ],
    \\     "slotMs": "0",
    \\     "computeMode": "BIGQUERY"
    \\    }
    \\   ],
    \\   "estimatedBytesProcessed": "0",
    \\   "timeline": [
    \\    {
    \\     "elapsedMs": "812",
    \\     "totalSlotMs": "6238",
    \\     "pendingUnits": "1",
    \\     "completedUnits": "1",
    \\     "activeUnits": "1",
    \\     "estimatedRunnableUnits": "0"
    \\    }
    \\   ],
    \\   "totalBytesProcessed": "0",
    \\   "totalBytesBilled": "0",
    \\   "billingTier": 1,
    \\   "totalSlotMs": "6238",
    \\   "cacheHit": false,
    \\   "statementType": "SELECT"
    \\  },
    \\  "totalSlotMs": "6238"
    \\ },
    \\ "status": {
    \\  "errorResult": {
    \\   "reason": "stopped",
    \\   "message": "Job execution was cancelled: User requested cancellation"
    \\  },
    \\  "errors": [
    \\   {
    \\    "reason": "stopped",
    \\    "message": "Job execution was cancelled: User requested cancellation"
    \\   }
    \\  ],
    \\  "state": "DONE"
    \\ },
    \\ "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ }
    \\}
;

/// jobs.insert of a query over maximumBytesBilled: a DONE job with that error. HTTP 200.
pub const job_over_limit_status = 200;
pub const job_over_limit =
    \\{
    \\ "kind": "bigquery#job",
    \\ "etag": "Rz1FZ/rVtZvD/dA9OBYewA==",
    \\ "id": "extractctl:US.job_ep8wEuEy-5VFIovyEaETMBPV6dd1",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/jobs/job_ep8wEuEy-5VFIovyEaETMBPV6dd1?location=US",
    \\ "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "configuration": {
    \\  "query": {
    \\   "query": "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5 -- insert 828161",
    \\   "destinationTable": {
    \\    "projectId": "extractctl",
    \\    "datasetId": "_de5ba0b733580e9d15132243da0107e55eca8f86",
    \\    "tableId": "anonev_1FYN9e92rR371Efz_4l66HfqjT8a6SR3Zx92dhCuG6E"
    \\   },
    \\   "writeDisposition": "WRITE_TRUNCATE",
    \\   "priority": "INTERACTIVE",
    \\   "useQueryCache": false,
    \\   "maximumBytesBilled": "1000",
    \\   "useLegacySql": false
    \\  },
    \\  "jobType": "QUERY"
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_ep8wEuEy-5VFIovyEaETMBPV6dd1",
    \\  "location": "US"
    \\ },
    \\ "statistics": {
    \\  "creationTime": "1792597567093",
    \\  "startTime": "1792597567282",
    \\  "endTime": "1792597567363",
    \\  "query": {
    \\   "cacheHit": false,
    \\   "referencedTables": [
    \\    {
    \\     "projectId": "bigquery-public-data",
    \\     "datasetId": "samples",
    \\     "tableId": "shakespeare"
    \\    }
    \\   ],
    \\   "statementType": "SELECT",
    \\   "searchStatistics": {
    \\    "indexUnusedReasons": [
    \\     {
    \\      "code": "INDEX_CONFIG_NOT_AVAILABLE",
    \\      "message": "There is no index configuration for the base table `bigquery-public-data:samples.shakespeare`.",
    \\      "baseTable": {
    \\       "projectId": "bigquery-public-data",
    \\       "datasetId": "samples",
    \\       "tableId": "shakespeare"
    \\      }
    \\     }
    \\    ]
    \\   }
    \\  }
    \\ },
    \\ "status": {
    \\  "errorResult": {
    \\   "reason": "bytesBilledLimitExceeded",
    \\   "message": "Query exceeded limit for bytes billed: 1000. 10485760 or higher required."
    \\  },
    \\  "errors": [
    \\   {
    \\    "reason": "bytesBilledLimitExceeded",
    \\    "message": "Query exceeded limit for bytes billed: 1000. 10485760 or higher required."
    \\   }
    \\  ],
    \\  "state": "DONE"
    \\ },
    \\ "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ }
    \\}
;

/// jobs.insert of a dry run: DONE, no jobId, the bytes it would process. HTTP 200.
pub const job_dry_run_status = 200;
pub const job_dry_run =
    \\{
    \\ "kind": "bigquery#job",
    \\ "etag": "fJaqXO+LBfb9enxB2LtYAg==",
    \\ "id": "extractctl:US.",
    \\ "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/jobs/?location=US",
    \\ "user_email": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "configuration": {
    \\  "query": {
    \\   "query": "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` WHERE corpus = 'hamlet' ORDER BY word_count DESC LIMIT 5",
    \\   "destinationTable": {
    \\    "projectId": "extractctl",
    \\    "datasetId": "_de5ba0b733580e9d15132243da0107e55eca8f86",
    \\    "tableId": "anonbb0189134cf149abc3581f485f97c79e19d5e9324f73f657dc024f9c6915ccc2"
    \\   },
    \\   "writeDisposition": "WRITE_TRUNCATE",
    \\   "priority": "INTERACTIVE",
    \\   "useLegacySql": false
    \\  },
    \\  "dryRun": true,
    \\  "jobType": "QUERY"
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "location": "US"
    \\ },
    \\ "statistics": {
    \\  "creationTime": "1792597446738",
    \\  "endTime": "1792597447008",
    \\  "totalBytesProcessed": "5114816",
    \\  "query": {
    \\   "totalBytesProcessed": "5114816",
    \\   "totalBytesBilled": "0",
    \\   "cacheHit": true,
    \\   "referencedTables": [
    \\    {
    \\     "projectId": "bigquery-public-data",
    \\     "datasetId": "samples",
    \\     "tableId": "shakespeare"
    \\    }
    \\   ],
    \\   "schema": {
    \\    "fields": [
    \\     {
    \\      "name": "word",
    \\      "type": "STRING",
    \\      "mode": "NULLABLE"
    \\     },
    \\     {
    \\      "name": "word_count",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     }
    \\    ]
    \\   },
    \\   "statementType": "SELECT",
    \\   "totalBytesProcessedAccuracy": "PRECISE",
    \\   "searchStatistics": {
    \\    "indexUsageMode": "UNUSED",
    \\    "indexUnusedReasons": [
    \\     {
    \\      "code": "QUERY_CACHE_HIT",
    \\      "message": "Search indexes are not used because the query was cached."
    \\     }
    \\    ]
    \\   }
    \\  }
    \\ },
    \\ "status": {
    \\  "state": "DONE"
    \\ },
    \\ "principal_subject": "serviceAccount:zig-gcp@extractctl.iam.gserviceaccount.com"
    \\}
;

/// jobs.cancel of a running query: the job, RUNNING. HTTP 200.
pub const cancel_running_status = 200;
pub const cancel_running =
    \\{
    \\ "kind": "bigquery#jobCancelResponse",
    \\ "job": {
    \\  "kind": "bigquery#job",
    \\  "etag": "pr+6cQQQhKPm1dS2kk8ttQ==",
    \\  "id": "extractctl:US.job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\  "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/jobs/job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC?location=US",
    \\  "configuration": {
    \\   "query": {
    \\    "query": "SELECT COUNT(*) FROM UNNEST(GENERATE_ARRAY(1, 1000000)) AS a CROSS JOIN UNNEST(GENERATE_ARRAY(1, 3000)) AS b",
    \\    "destinationTable": {
    \\     "projectId": "extractctl",
    \\     "datasetId": "_de5ba0b733580e9d15132243da0107e55eca8f86",
    \\     "tableId": "anonev_ibGMFUhJ98UV6eZEsXfVDSkzcIxslZ0nEUscKmooTOk"
    \\    },
    \\    "writeDisposition": "WRITE_TRUNCATE",
    \\    "priority": "INTERACTIVE",
    \\    "useQueryCache": false,
    \\    "useLegacySql": false
    \\   },
    \\   "jobType": "QUERY"
    \\  },
    \\  "jobReference": {
    \\   "projectId": "extractctl",
    \\   "jobId": "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\   "location": "US"
    \\  },
    \\  "statistics": {
    \\   "creationTime": "1792597550138",
    \\   "startTime": "1792597550188",
    \\   "query": {
    \\    "statementType": "SELECT"
    \\   }
    \\  },
    \\  "status": {
    \\   "state": "RUNNING"
    \\  },
    \\  "jobCreationReason": {
    \\   "code": "REQUESTED"
    \\  }
    \\ }
    \\}
;

/// datasets.get of a dataset nobody has. HTTP 404.
pub const dataset_unknown_status = 404;
pub const dataset_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Not found: Dataset extractctl:zigps_nobody",
    \\  "errors": [
    \\   {
    \\    "message": "Not found: Dataset extractctl:zigps_nobody",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ],
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// tables.get of a table nobody has. HTTP 404.
pub const table_unknown_status = 404;
pub const table_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Not found: Table bigquery-public-data:samples.zigps_nobody",
    \\  "errors": [
    \\   {
    \\    "message": "Not found: Table bigquery-public-data:samples.zigps_nobody",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ],
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// datasets.list of a project nobody has. HTTP 404.
pub const project_unknown_status = 404;
pub const project_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Not found: Project zigps-not-a-project-x",
    \\  "errors": [
    \\   {
    \\    "message": "Not found: Project zigps-not-a-project-x",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ],
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// jobs.get of a job nobody has. HTTP 404.
pub const job_unknown_status = 404;
pub const job_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Not found: Job extractctl:US.zigps_nobody",
    \\  "errors": [
    \\   {
    \\    "message": "Not found: Job extractctl:US.zigps_nobody",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ],
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// jobs.get of a US job with location EU. HTTP 404.
pub const job_wrong_location_status = 404;
pub const job_wrong_location =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Not found: Job extractctl:EU.job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\  "errors": [
    \\   {
    \\    "message": "Not found: Job extractctl:EU.job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ],
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// jobs.cancel with a cloud-platform.read-only token. HTTP 403.
pub const cancel_read_only_status = 403;
pub const cancel_read_only =
    \\{
    \\ "error": {
    \\  "code": 403,
    \\  "message": "Request had insufficient authentication scopes.",
    \\  "errors": [
    \\   {
    \\    "message": "Insufficient Permission",
    \\    "domain": "global",
    \\    "reason": "insufficientPermissions"
    \\   }
    \\  ],
    \\  "status": "PERMISSION_DENIED",
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\    "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
    \\    "domain": "googleapis.com",
    \\    "metadata": {
    \\     "method": "google.cloud.bigquery.v2.JobService.CancelJob",
    \\     "service": "bigquery.googleapis.com"
    \\    }
    \\   }
    \\  ]
    \\ }
    \\}
;

/// The every-type row from jobs.query, timestamps asked as int64 microseconds (formatOptions.useInt64Timestamp), as this library asks. HTTP 200.
pub const query_every_type_status = 200;
pub const query_every_type =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "int64",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "int64_min",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "float64",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "nan",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "inf",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "ninf",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "numeric",
    \\    "type": "NUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bignumeric",
    \\    "type": "BIGNUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bool",
    \\    "type": "BOOLEAN",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "string",
    \\    "type": "STRING",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bytes",
    \\    "type": "BYTES",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "date",
    \\    "type": "DATE",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "time",
    \\    "type": "TIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "datetime",
    \\    "type": "DATETIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "timestamp",
    \\    "type": "TIMESTAMP",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "geography",
    \\    "type": "GEOGRAPHY",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "json",
    \\    "type": "JSON",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_sum",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "range_date",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "DATE"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_ts_open",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "TIMESTAMP"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_datetime",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "DATETIME"
    \\    }
    \\   },
    \\   {
    \\    "name": "interval_full",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_negative",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_fraction",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "numeric_trailing",
    \\    "type": "NUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bool_false",
    \\    "type": "BOOLEAN",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "time_whole",
    \\    "type": "TIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "polygon",
    \\    "type": "GEOGRAPHY",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "json_numbers",
    \\    "type": "JSON",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "array_int",
    \\    "type": "INTEGER",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "array_empty",
    \\    "type": "STRING",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "record",
    \\    "type": "RECORD",
    \\    "mode": "NULLABLE",
    \\    "fields": [
    \\     {
    \\      "name": "x",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     },
    \\     {
    \\      "name": "y",
    \\      "type": "STRING",
    \\      "mode": "NULLABLE"
    \\     },
    \\     {
    \\      "name": "zs",
    \\      "type": "RECORD",
    \\      "mode": "REPEATED",
    \\      "fields": [
    \\       {
    \\        "name": "z",
    \\        "type": "INTEGER",
    \\        "mode": "NULLABLE"
    \\       }
    \\      ]
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "array_record",
    \\    "type": "RECORD",
    \\    "mode": "REPEATED",
    \\    "fields": [
    \\     {
    \\      "name": "a",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "null_int",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "null_record",
    \\    "type": "RECORD",
    \\    "mode": "NULLABLE",
    \\    "fields": [
    \\     {
    \\      "name": "q",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_l6pMSV47fOfk6-gPmc6nJhNmRZ8h",
    \\  "location": "US"
    \\ },
    \\ "totalRows": "1",
    \\ "rows": [
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "1"
    \\    },
    \\    {
    \\     "v": "-9223372036854775808"
    \\    },
    \\    {
    \\     "v": "1.5"
    \\    },
    \\    {
    \\     "v": "NaN"
    \\    },
    \\    {
    \\     "v": "Infinity"
    \\    },
    \\    {
    \\     "v": "-Infinity"
    \\    },
    \\    {
    \\     "v": "123.456"
    \\    },
    \\    {
    \\     "v": "1.23456789012345678901234567890123456789"
    \\    },
    \\    {
    \\     "v": "true"
    \\    },
    \\    {
    \\     "v": "héllo \"q\""
    \\    },
    \\    {
    \\     "v": "AP9hYg=="
    \\    },
    \\    {
    \\     "v": "2026-10-21"
    \\    },
    \\    {
    \\     "v": "13:14:15.123456"
    \\    },
    \\    {
    \\     "v": "2026-10-21T13:14:15.123456"
    \\    },
    \\    {
    \\     "v": "1792588455123456"
    \\    },
    \\    {
    \\     "v": "POINT(-122.35 47.62)"
    \\    },
    \\    {
    \\     "v": "{\"a\":[1,2],\"b\":null}"
    \\    },
    \\    {
    \\     "v": "1-0 2 3:0:0"
    \\    },
    \\    {
    \\     "v": "[2024-01-01, 2024-02-01)"
    \\    },
    \\    {
    \\     "v": "[1704067200000000, UNBOUNDED)"
    \\    },
    \\    {
    \\     "v": "[2024-01-01T01:02:03.500000, 2024-01-02T00:00:00)"
    \\    },
    \\    {
    \\     "v": "1-2 3 4:5:6"
    \\    },
    \\    {
    \\     "v": "0-0 -3 0:0:0"
    \\    },
    \\    {
    \\     "v": "0-0 0 0:0:0.250"
    \\    },
    \\    {
    \\     "v": "1.5"
    \\    },
    \\    {
    \\     "v": "false"
    \\    },
    \\    {
    \\     "v": "01:02:03"
    \\    },
    \\    {
    \\     "v": "POLYGON((1 1, 0 1, 0 0, 1 1))"
    \\    },
    \\    {
    \\     "v": "{\"a\":10000000000000000000,\"s\":\"x\",\"z\":1.0}"
    \\    },
    \\    {
    \\     "v": [
    \\      {
    \\       "v": "1"
    \\      },
    \\      {
    \\       "v": "2"
    \\      },
    \\      {
    \\       "v": "3"
    \\      }
    \\     ]
    \\    },
    \\    {
    \\     "v": []
    \\    },
    \\    {
    \\     "v": {
    \\      "f": [
    \\       {
    \\        "v": "1"
    \\       },
    \\       {
    \\        "v": "y"
    \\       },
    \\       {
    \\        "v": [
    \\         {
    \\          "v": {
    \\           "f": [
    \\            {
    \\             "v": "2"
    \\            }
    \\           ]
    \\          }
    \\         }
    \\        ]
    \\       }
    \\      ]
    \\     }
    \\    },
    \\    {
    \\     "v": [
    \\      {
    \\       "v": {
    \\        "f": [
    \\         {
    \\          "v": "1"
    \\         }
    \\        ]
    \\       }
    \\      },
    \\      {
    \\       "v": {
    \\        "f": [
    \\         {
    \\          "v": "2"
    \\         }
    \\        ]
    \\       }
    \\      }
    \\     ]
    \\    },
    \\    {
    \\     "v": null
    \\    },
    \\    {
    \\     "v": null
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": true,
    \\ "queryId": "job_l6pMSV47fOfk6-gPmc6nJhNmRZ8h",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ },
    \\ "totalBytesBilled": "0",
    \\ "location": "US",
    \\ "creationTime": "1792597451747",
    \\ "startTime": "1792597451800",
    \\ "endTime": "1792597451882",
    \\ "pageRowCount": "1",
    \\ "statementType": "SELECT"
    \\}
;

/// The same row with the default formats: a timestamp as seconds in exponent notation, a timestamp range's ends as decimal seconds. HTTP 200.
pub const query_every_type_float_status = 200;
pub const query_every_type_float =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "int64",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "int64_min",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "float64",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "nan",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "inf",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "ninf",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "numeric",
    \\    "type": "NUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bignumeric",
    \\    "type": "BIGNUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bool",
    \\    "type": "BOOLEAN",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "string",
    \\    "type": "STRING",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bytes",
    \\    "type": "BYTES",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "date",
    \\    "type": "DATE",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "time",
    \\    "type": "TIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "datetime",
    \\    "type": "DATETIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "timestamp",
    \\    "type": "TIMESTAMP",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "geography",
    \\    "type": "GEOGRAPHY",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "json",
    \\    "type": "JSON",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_sum",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "range_date",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "DATE"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_ts_open",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "TIMESTAMP"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_datetime",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "DATETIME"
    \\    }
    \\   },
    \\   {
    \\    "name": "interval_full",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_negative",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_fraction",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "numeric_trailing",
    \\    "type": "NUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bool_false",
    \\    "type": "BOOLEAN",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "time_whole",
    \\    "type": "TIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "polygon",
    \\    "type": "GEOGRAPHY",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "json_numbers",
    \\    "type": "JSON",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "array_int",
    \\    "type": "INTEGER",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "array_empty",
    \\    "type": "STRING",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "record",
    \\    "type": "RECORD",
    \\    "mode": "NULLABLE",
    \\    "fields": [
    \\     {
    \\      "name": "x",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     },
    \\     {
    \\      "name": "y",
    \\      "type": "STRING",
    \\      "mode": "NULLABLE"
    \\     },
    \\     {
    \\      "name": "zs",
    \\      "type": "RECORD",
    \\      "mode": "REPEATED",
    \\      "fields": [
    \\       {
    \\        "name": "z",
    \\        "type": "INTEGER",
    \\        "mode": "NULLABLE"
    \\       }
    \\      ]
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "array_record",
    \\    "type": "RECORD",
    \\    "mode": "REPEATED",
    \\    "fields": [
    \\     {
    \\      "name": "a",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "null_int",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "null_record",
    \\    "type": "RECORD",
    \\    "mode": "NULLABLE",
    \\    "fields": [
    \\     {
    \\      "name": "q",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_QuU_EunlZPOr_5lR1nUOYym6939N",
    \\  "location": "US"
    \\ },
    \\ "totalRows": "1",
    \\ "rows": [
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "1"
    \\    },
    \\    {
    \\     "v": "-9223372036854775808"
    \\    },
    \\    {
    \\     "v": "1.5"
    \\    },
    \\    {
    \\     "v": "NaN"
    \\    },
    \\    {
    \\     "v": "Infinity"
    \\    },
    \\    {
    \\     "v": "-Infinity"
    \\    },
    \\    {
    \\     "v": "123.456"
    \\    },
    \\    {
    \\     "v": "1.23456789012345678901234567890123456789"
    \\    },
    \\    {
    \\     "v": "true"
    \\    },
    \\    {
    \\     "v": "héllo \"q\""
    \\    },
    \\    {
    \\     "v": "AP9hYg=="
    \\    },
    \\    {
    \\     "v": "2026-10-21"
    \\    },
    \\    {
    \\     "v": "13:14:15.123456"
    \\    },
    \\    {
    \\     "v": "2026-10-21T13:14:15.123456"
    \\    },
    \\    {
    \\     "v": "1.792588455123456E9"
    \\    },
    \\    {
    \\     "v": "POINT(-122.35 47.62)"
    \\    },
    \\    {
    \\     "v": "{\"a\":[1,2],\"b\":null}"
    \\    },
    \\    {
    \\     "v": "1-0 2 3:0:0"
    \\    },
    \\    {
    \\     "v": "[2024-01-01, 2024-02-01)"
    \\    },
    \\    {
    \\     "v": "[1704067200.000000, UNBOUNDED)"
    \\    },
    \\    {
    \\     "v": "[2024-01-01T01:02:03.500000, 2024-01-02T00:00:00)"
    \\    },
    \\    {
    \\     "v": "1-2 3 4:5:6"
    \\    },
    \\    {
    \\     "v": "0-0 -3 0:0:0"
    \\    },
    \\    {
    \\     "v": "0-0 0 0:0:0.250"
    \\    },
    \\    {
    \\     "v": "1.5"
    \\    },
    \\    {
    \\     "v": "false"
    \\    },
    \\    {
    \\     "v": "01:02:03"
    \\    },
    \\    {
    \\     "v": "POLYGON((1 1, 0 1, 0 0, 1 1))"
    \\    },
    \\    {
    \\     "v": "{\"a\":10000000000000000000,\"s\":\"x\",\"z\":1.0}"
    \\    },
    \\    {
    \\     "v": [
    \\      {
    \\       "v": "1"
    \\      },
    \\      {
    \\       "v": "2"
    \\      },
    \\      {
    \\       "v": "3"
    \\      }
    \\     ]
    \\    },
    \\    {
    \\     "v": []
    \\    },
    \\    {
    \\     "v": {
    \\      "f": [
    \\       {
    \\        "v": "1"
    \\       },
    \\       {
    \\        "v": "y"
    \\       },
    \\       {
    \\        "v": [
    \\         {
    \\          "v": {
    \\           "f": [
    \\            {
    \\             "v": "2"
    \\            }
    \\           ]
    \\          }
    \\         }
    \\        ]
    \\       }
    \\      ]
    \\     }
    \\    },
    \\    {
    \\     "v": [
    \\      {
    \\       "v": {
    \\        "f": [
    \\         {
    \\          "v": "1"
    \\         }
    \\        ]
    \\       }
    \\      },
    \\      {
    \\       "v": {
    \\        "f": [
    \\         {
    \\          "v": "2"
    \\         }
    \\        ]
    \\       }
    \\      }
    \\     ]
    \\    },
    \\    {
    \\     "v": null
    \\    },
    \\    {
    \\     "v": null
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": false,
    \\ "queryId": "job_QuU_EunlZPOr_5lR1nUOYym6939N",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ },
    \\ "totalBytesBilled": "0",
    \\ "totalSlotMs": "30",
    \\ "location": "US",
    \\ "creationTime": "1792597451282",
    \\ "startTime": "1792597451330",
    \\ "endTime": "1792597451533",
    \\ "pageRowCount": "1",
    \\ "statementType": "SELECT"
    \\}
;

/// The same row with timestampOutputFormat ISO8601_STRING. HTTP 200.
pub const query_every_type_iso_status = 200;
pub const query_every_type_iso =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "int64",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "int64_min",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "float64",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "nan",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "inf",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "ninf",
    \\    "type": "FLOAT",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "numeric",
    \\    "type": "NUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bignumeric",
    \\    "type": "BIGNUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bool",
    \\    "type": "BOOLEAN",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "string",
    \\    "type": "STRING",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bytes",
    \\    "type": "BYTES",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "date",
    \\    "type": "DATE",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "time",
    \\    "type": "TIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "datetime",
    \\    "type": "DATETIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "timestamp",
    \\    "type": "TIMESTAMP",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "geography",
    \\    "type": "GEOGRAPHY",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "json",
    \\    "type": "JSON",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_sum",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "range_date",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "DATE"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_ts_open",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "TIMESTAMP"
    \\    }
    \\   },
    \\   {
    \\    "name": "range_datetime",
    \\    "type": "RANGE",
    \\    "mode": "NULLABLE",
    \\    "rangeElementType": {
    \\     "type": "DATETIME"
    \\    }
    \\   },
    \\   {
    \\    "name": "interval_full",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_negative",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "interval_fraction",
    \\    "type": "INTERVAL",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "numeric_trailing",
    \\    "type": "NUMERIC",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "bool_false",
    \\    "type": "BOOLEAN",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "time_whole",
    \\    "type": "TIME",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "polygon",
    \\    "type": "GEOGRAPHY",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "json_numbers",
    \\    "type": "JSON",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "array_int",
    \\    "type": "INTEGER",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "array_empty",
    \\    "type": "STRING",
    \\    "mode": "REPEATED"
    \\   },
    \\   {
    \\    "name": "record",
    \\    "type": "RECORD",
    \\    "mode": "NULLABLE",
    \\    "fields": [
    \\     {
    \\      "name": "x",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     },
    \\     {
    \\      "name": "y",
    \\      "type": "STRING",
    \\      "mode": "NULLABLE"
    \\     },
    \\     {
    \\      "name": "zs",
    \\      "type": "RECORD",
    \\      "mode": "REPEATED",
    \\      "fields": [
    \\       {
    \\        "name": "z",
    \\        "type": "INTEGER",
    \\        "mode": "NULLABLE"
    \\       }
    \\      ]
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "array_record",
    \\    "type": "RECORD",
    \\    "mode": "REPEATED",
    \\    "fields": [
    \\     {
    \\      "name": "a",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     }
    \\    ]
    \\   },
    \\   {
    \\    "name": "null_int",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "null_record",
    \\    "type": "RECORD",
    \\    "mode": "NULLABLE",
    \\    "fields": [
    \\     {
    \\      "name": "q",
    \\      "type": "INTEGER",
    \\      "mode": "NULLABLE"
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_Z1gi-GZLF0T3Q9bqijaPTrkVSc1w",
    \\  "location": "US"
    \\ },
    \\ "totalRows": "1",
    \\ "rows": [
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "1"
    \\    },
    \\    {
    \\     "v": "-9223372036854775808"
    \\    },
    \\    {
    \\     "v": "1.5"
    \\    },
    \\    {
    \\     "v": "NaN"
    \\    },
    \\    {
    \\     "v": "Infinity"
    \\    },
    \\    {
    \\     "v": "-Infinity"
    \\    },
    \\    {
    \\     "v": "123.456"
    \\    },
    \\    {
    \\     "v": "1.23456789012345678901234567890123456789"
    \\    },
    \\    {
    \\     "v": "true"
    \\    },
    \\    {
    \\     "v": "héllo \"q\""
    \\    },
    \\    {
    \\     "v": "AP9hYg=="
    \\    },
    \\    {
    \\     "v": "2026-10-21"
    \\    },
    \\    {
    \\     "v": "13:14:15.123456"
    \\    },
    \\    {
    \\     "v": "2026-10-21T13:14:15.123456"
    \\    },
    \\    {
    \\     "v": "2026-10-21T13:14:15.123456Z"
    \\    },
    \\    {
    \\     "v": "POINT(-122.35 47.62)"
    \\    },
    \\    {
    \\     "v": "{\"a\":[1,2],\"b\":null}"
    \\    },
    \\    {
    \\     "v": "1-0 2 3:0:0"
    \\    },
    \\    {
    \\     "v": "[2024-01-01, 2024-02-01)"
    \\    },
    \\    {
    \\     "v": "[2024-01-01T00:00:00.000000Z, UNBOUNDED)"
    \\    },
    \\    {
    \\     "v": "[2024-01-01T01:02:03.500000, 2024-01-02T00:00:00)"
    \\    },
    \\    {
    \\     "v": "1-2 3 4:5:6"
    \\    },
    \\    {
    \\     "v": "0-0 -3 0:0:0"
    \\    },
    \\    {
    \\     "v": "0-0 0 0:0:0.250"
    \\    },
    \\    {
    \\     "v": "1.5"
    \\    },
    \\    {
    \\     "v": "false"
    \\    },
    \\    {
    \\     "v": "01:02:03"
    \\    },
    \\    {
    \\     "v": "POLYGON((1 1, 0 1, 0 0, 1 1))"
    \\    },
    \\    {
    \\     "v": "{\"a\":10000000000000000000,\"s\":\"x\",\"z\":1.0}"
    \\    },
    \\    {
    \\     "v": [
    \\      {
    \\       "v": "1"
    \\      },
    \\      {
    \\       "v": "2"
    \\      },
    \\      {
    \\       "v": "3"
    \\      }
    \\     ]
    \\    },
    \\    {
    \\     "v": []
    \\    },
    \\    {
    \\     "v": {
    \\      "f": [
    \\       {
    \\        "v": "1"
    \\       },
    \\       {
    \\        "v": "y"
    \\       },
    \\       {
    \\        "v": [
    \\         {
    \\          "v": {
    \\           "f": [
    \\            {
    \\             "v": "2"
    \\            }
    \\           ]
    \\          }
    \\         }
    \\        ]
    \\       }
    \\      ]
    \\     }
    \\    },
    \\    {
    \\     "v": [
    \\      {
    \\       "v": {
    \\        "f": [
    \\         {
    \\          "v": "1"
    \\         }
    \\        ]
    \\       }
    \\      },
    \\      {
    \\       "v": {
    \\        "f": [
    \\         {
    \\          "v": "2"
    \\         }
    \\        ]
    \\       }
    \\      }
    \\     ]
    \\    },
    \\    {
    \\     "v": null
    \\    },
    \\    {
    \\     "v": null
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": true,
    \\ "queryId": "job_Z1gi-GZLF0T3Q9bqijaPTrkVSc1w",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ },
    \\ "totalBytesBilled": "0",
    \\ "location": "US",
    \\ "creationTime": "1792597452180",
    \\ "startTime": "1792597452246",
    \\ "endTime": "1792597452318",
    \\ "pageRowCount": "1",
    \\ "statementType": "SELECT"
    \\}
;

/// jobs.query of five Hamlet words from the public samples, under a 100 MB limit: complete, five rows. HTTP 200.
pub const query_run_status = 200;
pub const query_run =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "word",
    \\    "type": "STRING",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "word_count",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_3xSjRB7aLm3FIgAkBpq9X-aA5EZx",
    \\  "location": "US"
    \\ },
    \\ "totalRows": "5",
    \\ "rows": [
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "the"
    \\    },
    \\    {
    \\     "v": "995"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "and"
    \\    },
    \\    {
    \\     "v": "706"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "to"
    \\    },
    \\    {
    \\     "v": "635"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "of"
    \\    },
    \\    {
    \\     "v": "630"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "I"
    \\    },
    \\    {
    \\     "v": "546"
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": true,
    \\ "queryId": "job_3xSjRB7aLm3FIgAkBpq9X-aA5EZx",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ },
    \\ "totalBytesBilled": "0",
    \\ "location": "US",
    \\ "creationTime": "1792597448912",
    \\ "startTime": "1792597449094",
    \\ "endTime": "1792597449180",
    \\ "pageRowCount": "5",
    \\ "statementType": "SELECT"
    \\}
;

/// The same query as a dry run: complete, a job reference without a jobId, the bytes and the schema. HTTP 200.
pub const query_dry_run_status = 200;
pub const query_dry_run =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "word",
    \\    "type": "STRING",
    \\    "mode": "NULLABLE"
    \\   },
    \\   {
    \\    "name": "word_count",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "location": "US"
    \\ },
    \\ "totalBytesProcessed": "5114816",
    \\ "jobComplete": true,
    \\ "cacheHit": true,
    \\ "totalBytesBilled": "0",
    \\ "location": "US",
    \\ "creationTime": "1792597445907",
    \\ "endTime": "1792597446132",
    \\ "statementType": "SELECT"
    \\}
;

/// A query that outlived timeoutMs 10: unfinished, its job and nothing else. HTTP 200.
pub const query_slow_status = 200;
pub const query_slow =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_yqKr7l89vGwL2TIqWdhA7sDltZ8O",
    \\  "location": "US"
    \\ },
    \\ "jobComplete": false,
    \\ "queryId": "job_yqKr7l89vGwL2TIqWdhA7sDltZ8O",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ },
    \\ "location": "US",
    \\ "creationTime": "1792597455053",
    \\ "startTime": "1792597455129",
    \\ "statementType": "SELECT"
    \\}
;

/// A second jobs.query with the first's requestId: the same job, answered unfinished and without rows although it had ended. HTTP 200.
pub const query_repeat_status = 200;
pub const query_repeat =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_Sorr4TiYD0h32C31IK3GGXkQXsEn",
    \\  "location": "US"
    \\ },
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": false,
    \\ "cacheHit": false,
    \\ "queryId": "job_Sorr4TiYD0h32C31IK3GGXkQXsEn",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ },
    \\ "totalBytesBilled": "0",
    \\ "totalSlotMs": "1",
    \\ "location": "US",
    \\ "creationTime": "1792597562975",
    \\ "startTime": "1792597563030",
    \\ "endTime": "1792597563508",
    \\ "statementType": "SELECT"
    \\}
;

/// jobs.query with JOB_CREATION_OPTIONAL: complete, no jobReference, a queryId. HTTP 200.
pub const query_optional_job_status = 200;
pub const query_optional_job =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "f0_",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   }
    \\  ]
    \\ },
    \\ "totalRows": "1",
    \\ "rows": [
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "1"
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": false,
    \\ "queryId": "0QzAcZxdxSiJOmtNYg913SXyrfI4@1a15f241c57",
    \\ "totalBytesBilled": "0",
    \\ "totalSlotMs": "1",
    \\ "location": "US",
    \\ "creationTime": "1792597564461",
    \\ "startTime": "1792597564503",
    \\ "endTime": "1792597564544",
    \\ "statementType": "SELECT"
    \\}
;

/// An INSERT of two rows: numDmlAffectedRows, no rows. HTTP 200.
pub const query_insert_status = 200;
pub const query_insert =
    \\{
    \\ "kind": "bigquery#queryResponse",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "ts",
    \\    "type": "TIMESTAMP"
    \\   },
    \\   {
    \\    "name": "user",
    \\    "type": "STRING"
    \\   },
    \\   {
    \\    "name": "n",
    \\    "type": "INTEGER"
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_ZNzGxPC8ET6hZveu0Tg5Z-GEsITz",
    \\  "location": "US"
    \\ },
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": false,
    \\ "numDmlAffectedRows": "2",
    \\ "dmlStats": {
    \\  "insertedRowCount": "2",
    \\  "dmlMode": "COARSE_GRAINED_DML"
    \\ },
    \\ "queryId": "job_ZNzGxPC8ET6hZveu0Tg5Z-GEsITz",
    \\ "jobCreationReason": {
    \\  "code": "REQUESTED"
    \\ },
    \\ "totalBytesBilled": "0",
    \\ "totalSlotMs": "3290",
    \\ "location": "US",
    \\ "creationTime": "1792597664935",
    \\ "startTime": "1792597665356",
    \\ "endTime": "1792597666441",
    \\ "statementType": "INSERT"
    \\}
;

/// getQueryResults, a page of ten with a pageToken. HTTP 200.
pub const results_page_status = 200;
pub const results_page =
    \\{
    \\ "kind": "bigquery#getQueryResultsResponse",
    \\ "etag": "XgUBuLHDeWGRTUP05PJ8fA==",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "n",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_zuWkgIS8xmg5cnX_F1jDBhKLWyA4",
    \\  "location": "US"
    \\ },
    \\ "totalRows": "50",
    \\ "pageToken": "BGYGOIS7UEAQAAASA4EAAEEAQCAAKGQEBAKBACRAWCXBKSVBAIFGQCQVBIFGK6DUOJQWG5DDORWBCHUFSAQBGAAAAAJCSX3EMU2WEYJQMI3TGMZVHAYGKOLEGE2TCMZSGI2DGZDBGAYTAN3FGU2WKY3BHBTDQNQ2EQ4DOOBUGZSGIYRNMY2TMYRNGRTDANZNHEYDCOBNGI2WIMZWMMZDSYJZGZSBERDBNZXW4OBZGVTGCZBWGEYGCMJVGI3WCOLFMZQTAYRQMEYTEMJXMMYGKYRTGFRDEOJVGMZDQYTFG5RDEOLDMI2GEN3GGE3DEZRXGQ2WKYTFHBSBU3ZYHE2WMYLEGYYTAYJRGUZDOYJZMVTGCMDCGBQTCMRRG5RTAZLCGMYWEMRZGUZTEODCMU3WEMRZMNRDIYRXMYYTMMTGG42DKZLCMU4GII3FOZPWMRZZIRMG4RRVMJ4FE4RSORIWY43XIV2E46TLJBBEE3KDJUZFKMTMNJ4XSTBZG5DTSRCB",
    \\ "rows": [
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "11"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "12"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "13"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "14"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "15"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "16"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "17"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "18"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "19"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "20"
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": true
    \\}
;

/// The last page: no pageToken. HTTP 200.
pub const results_last_status = 200;
pub const results_last =
    \\{
    \\ "kind": "bigquery#getQueryResultsResponse",
    \\ "etag": "q9RjyEQLEb8+dwWECGsc0Q==",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "n",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_zuWkgIS8xmg5cnX_F1jDBhKLWyA4",
    \\  "location": "US"
    \\ },
    \\ "totalRows": "50",
    \\ "rows": [
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "41"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "42"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "43"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "44"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "45"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "46"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "47"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "48"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "49"
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "f": [
    \\    {
    \\     "v": "50"
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": true
    \\}
;

/// getQueryResults of a running job with timeoutMs 2000: held about 2 s, unfinished. HTTP 200.
pub const results_unfinished_status = 200;
pub const results_unfinished =
    \\{
    \\ "kind": "bigquery#getQueryResultsResponse",
    \\ "etag": "BIMbqCBOUxHmRDHax2fneA==",
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_yqKr7l89vGwL2TIqWdhA7sDltZ8O",
    \\  "location": "US"
    \\ },
    \\ "jobComplete": false
    \\}
;

/// getQueryResults with maxResults=0 and timeoutMs 60000: held 53 s to the job's end, the schema, the row count and a pageToken, no rows. HTTP 200.
pub const results_wait_status = 200;
pub const results_wait =
    \\{
    \\ "kind": "bigquery#getQueryResultsResponse",
    \\ "etag": "pZFch9EzPsLb5c5jvaRCug==",
    \\ "schema": {
    \\  "fields": [
    \\   {
    \\    "name": "f0_",
    \\    "type": "INTEGER",
    \\    "mode": "NULLABLE"
    \\   }
    \\  ]
    \\ },
    \\ "jobReference": {
    \\  "projectId": "extractctl",
    \\  "jobId": "job_5aP-2fB2ZnFmxumu9Gzyjx_d4D7k",
    \\  "location": "US"
    \\ },
    \\ "totalRows": "1",
    \\ "pageToken": "BHGOEI27UEAQAAASA4EAAEEAQCAAKGQIBAABB7X7777QOIFQVYKUVTQBBJUAUFIKBJSXQ5DSMFRXIY3UNQIR5BMQEAJQAAAACIUV6ZDFGVRGCMDCG4ZTGNJYGBSTSZBRGUYTGMRSGQZWIYJQGEYDOZJVGVSWGYJYMY4DMGREHA3TQNBWMRSGELLGGU3GELJUMYYDOLJZGAYTQLJSGVSDGNTDGI4WCOJWMQJDEYLON5XGK5S7NZZGQR2WNBRV63KJGJFUETLLHBIVKYSGGEZVEN2HIJ2FAQZWK5UU2QKMLBVHGUCYPJJVKGROMV3F63TSNBDVM2DDL5WUSMSLIJGWWOCRKVREMMJTKI3UOQTUKBBTMV3JJVAUYWDKONIFQ6STKU======",
    \\ "totalBytesProcessed": "0",
    \\ "jobComplete": true,
    \\ "cacheHit": false
    \\}
;

/// jobs.query of a syntax error. HTTP 400.
pub const query_syntax_status = 400;
pub const query_syntax =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Syntax error: Unexpected keyword WHERE at [2:3]",
    \\  "errors": [
    \\   {
    \\    "message": "Syntax error: Unexpected keyword WHERE at [2:3]",
    \\    "domain": "global",
    \\    "reason": "invalidQuery",
    \\    "location": "q",
    \\    "locationType": "parameter"
    \\   }
    \\  ],
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A dry run of the same syntax error. HTTP 400.
pub const dry_run_syntax_status = 400;
pub const dry_run_syntax =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Syntax error: Unexpected keyword WHERE at [2:3]",
    \\  "errors": [
    \\   {
    \\    "message": "Syntax error: Unexpected keyword WHERE at [2:3]",
    \\    "domain": "global",
    \\    "reason": "invalidQuery",
    \\    "location": "q",
    \\    "locationType": "parameter"
    \\   }
    \\  ],
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// jobs.query over maximumBytesBilled 1000. HTTP 400.
pub const query_over_limit_status = 400;
pub const query_over_limit =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Query exceeded limit for bytes billed: 1000. 10485760 or higher required.",
    \\  "errors": [
    \\   {
    \\    "message": "Query exceeded limit for bytes billed: 1000. 10485760 or higher required.",
    \\    "domain": "global",
    \\    "reason": "bytesBilledLimitExceeded"
    \\   }
    \\  ],
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// jobs.query of SELECT 1 / 0. HTTP 400.
pub const query_runtime_error_status = 400;
pub const query_runtime_error =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "division by zero: 1 / 0",
    \\  "errors": [
    \\   {
    \\    "message": "division by zero: 1 / 0",
    \\    "domain": "global",
    \\    "reason": "invalidQuery",
    \\    "location": "q",
    \\    "locationType": "parameter"
    \\   }
    \\  ],
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A US table queried with location EU. HTTP 403.
pub const query_location_eu_status = 403;
pub const query_location_eu =
    \\{
    \\ "error": {
    \\  "code": 403,
    \\  "message": "Access Denied: Table bigquery-public-data:samples.shakespeare: User does not have permission to query table bigquery-public-data:samples.shakespeare, or perhaps it does not exist.",
    \\  "errors": [
    \\   {
    \\    "message": "Access Denied: Table bigquery-public-data:samples.shakespeare: User does not have permission to query table bigquery-public-data:samples.shakespeare, or perhaps it does not exist.",
    \\    "domain": "global",
    \\    "reason": "accessDenied"
    \\   }
    \\  ],
    \\  "status": "PERMISSION_DENIED"
    \\ }
    \\}
;

/// A dry run reading a dataset nobody has. HTTP 404.
pub const dry_run_missing_table_status = 404;
pub const dry_run_missing_table =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Not found: Dataset extractctl:zigps_nobody was not found in location US",
    \\  "errors": [
    \\   {
    \\    "message": "Not found: Dataset extractctl:zigps_nobody was not found in location US",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ],
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A cancel of a job already done: no refusal, the job DONE. HTTP 200.
pub const cancel_done_status = 200;
pub const cancel_done =
    \\{
    \\ "kind": "bigquery#jobCancelResponse",
    \\ "job": {
    \\  "kind": "bigquery#job",
    \\  "etag": "Lxb3TdGsmvxp9mjhFOKrMg==",
    \\  "id": "extractctl:US.job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\  "selfLink": "https://bigquery.googleapis.com/bigquery/v2/projects/extractctl/jobs/job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC?location=US",
    \\  "configuration": {
    \\   "query": {
    \\    "query": "SELECT COUNT(*) FROM UNNEST(GENERATE_ARRAY(1, 1000000)) AS a CROSS JOIN UNNEST(GENERATE_ARRAY(1, 3000)) AS b",
    \\    "destinationTable": {
    \\     "projectId": "extractctl",
    \\     "datasetId": "_de5ba0b733580e9d15132243da0107e55eca8f86",
    \\     "tableId": "anonev_ibGMFUhJ98UV6eZEsXfVDSkzcIxslZ0nEUscKmooTOk"
    \\    },
    \\    "writeDisposition": "WRITE_TRUNCATE",
    \\    "priority": "INTERACTIVE",
    \\    "useQueryCache": false,
    \\    "useLegacySql": false
    \\   },
    \\   "jobType": "QUERY"
    \\  },
    \\  "jobReference": {
    \\   "projectId": "extractctl",
    \\   "jobId": "job_uJJN89pQ9cqYnDKc4Z_VpBpHsSqC",
    \\   "location": "US"
    \\  },
    \\  "statistics": {
    \\   "creationTime": "1792597550138",
    \\   "startTime": "1792597550188",
    \\   "endTime": "1792597561013",
    \\   "totalBytesProcessed": "0",
    \\   "query": {
    \\    "queryPlan": [
    \\     {
    \\      "name": "S00: Input",
    \\      "id": "0",
    \\      "startMs": "1792597550519",
    \\      "endMs": "1792597550592",
    \\      "waitMsAvg": "0",
    \\      "waitMsMax": "0",
    \\      "readMsAvg": "0",
    \\      "readMsMax": "0",
    \\      "computeMsAvg": "109",
    \\      "computeMsMax": "109",
    \\      "writeMsAvg": "4",
    \\      "writeMsMax": "4",
    \\      "shuffleOutputBytes": "0",
    \\      "shuffleOutputBytesSpilled": "0",
    \\      "recordsRead": "0",
    \\      "recordsWritten": "1",
    \\      "parallelInputs": "1",
    \\      "completedParallelInputs": "1",
    \\      "status": "COMPLETE",
    \\      "steps": [
    \\       {
    \\        "kind": "COMPUTE",
    \\        "substeps": [
    \\         "$10 := generate_array(1, 1000000)"
    \\        ]
    \\       },
    \\       {
    \\        "kind": "WRITE",
    \\        "substeps": [
    \\         "$10",
    \\         "TO __stage00_output"
    \\        ]
    \\       }
    \\      ],
    \\      "slotMs": "136",
    \\      "computeMode": "BIGQUERY"
    \\     },
    \\     {
    \\      "name": "S01: Output",
    \\      "id": "1",
    \\      "startMs": "1792597550598",
    \\      "inputStages": [
    \\       "0"
    \\      ],
    \\      "waitMsAvg": "0",
    \\      "waitMsMax": "0",
    \\      "readMsAvg": "0",
    \\      "readMsMax": "0",
    \\      "computeMsAvg": "0",
    \\      "computeMsMax": "0",
    \\      "writeMsAvg": "0",
    \\      "writeMsMax": "0",
    \\      "shuffleOutputBytes": "0",
    \\      "shuffleOutputBytesSpilled": "0",
    \\      "recordsRead": "0",
    \\      "recordsWritten": "0",
    \\      "parallelInputs": "1",
    \\      "completedParallelInputs": "0",
    \\      "status": "RUNNING",
    \\      "steps": [
    \\       {
    \\        "kind": "READ",
    \\        "substeps": [
    \\         "$10",
    \\         "FROM __stage00_output"
    \\        ]
    \\       },
    \\       {
    \\        "kind": "AGGREGATE",
    \\        "substeps": [
    \\         "$1 := SUM_OF_COUNTS($20)"
    \\        ]
    \\       },
    \\       {
    \\        "kind": "AGGREGATE",
    \\        "substeps": [
    \\         "$20 := COUNT_STAR()"
    \\        ]
    \\       },
    \\       {
    \\        "kind": "COMPUTE",
    \\        "substeps": [
    \\         "$30 := generate_array(1, 3000)"
    \\        ]
    \\       },
    \\       {
    \\        "kind": "WRITE",
    \\        "substeps": [
    \\         "$1",
    \\         "TO __stage01_output"
    \\        ]
    \\       }
    \\      ],
    \\      "slotMs": "0",
    \\      "computeMode": "BIGQUERY"
    \\     }
    \\    ],
    \\    "estimatedBytesProcessed": "0",
    \\    "timeline": [
    \\     {
    \\      "elapsedMs": "812",
    \\      "totalSlotMs": "6238",
    \\      "pendingUnits": "1",
    \\      "completedUnits": "1",
    \\      "activeUnits": "1",
    \\      "estimatedRunnableUnits": "0"
    \\     }
    \\    ],
    \\    "totalBytesProcessed": "0",
    \\    "totalBytesBilled": "0",
    \\    "billingTier": 1,
    \\    "totalSlotMs": "6238",
    \\    "cacheHit": false,
    \\    "statementType": "SELECT"
    \\   },
    \\   "totalSlotMs": "6238"
    \\  },
    \\  "status": {
    \\   "errorResult": {
    \\    "reason": "stopped",
    \\    "debugInfo": "[CANCELLED] message=[CANCELLED] errorProto=code: \"JOB_CANCELLED\"\nargument: \"User requested cancel or job timed out\"\n errorProto=code: \"JOB_CANCELLED\"\nargument: \"User requested cancellation\"\n\n\tat com.google.cloud.helix.common.Exceptions$Public.jobCancelled(Exceptions.java:978)\n\tat com.google.cloud.helix.common.Exceptions.fromCancelRequest(Exceptions.java:2013)\n\tat com.google.cloud.helix.common.CancelState.wrapException(CancelState.java:31)\n\tat com.google.cloud.helix.server.job.LocalJobController.handleJobDone(LocalJobController.java:446)\n\tat com.google.cloud.helix.server.job.LocalJobController.lambda$runThread$0(LocalJobController.java:350)\n\tat com.google.common.util.concurrent.CombinedFuture$CallableInterruptibleTask.runInterruptibly(CombinedFuture.java:196)\n\tat com.google.common.util.concurrent.InterruptibleTask.run(InterruptibleTask.java:72)\n\tat com.google.common.context.ContextRunnable.runInContext(ContextRunnable.java:83)\n\tat io.grpc.Context.run(Context.java:537)\n\tat com.google.common.context.ContextCallback.runInInheritedContext(ContextCallback.java:56)\n\tat com.google.common.context.ContextRunnable.run(ContextRunnable.java:74)\n\tat java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(Unknown Source)\n\tat java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(Unknown Source)\n\tat java.base/java.lang.Thread.run(Unknown Source)\nCaused by: [CANCELLED] errorProto=code: \"JOB_CANCELLED\"\nargument: \"User requested cancel or job timed out\"\n\n\tat com.google.cloud.helix.common.HelixException.withExtension(HelixException.java:496)\n\tat com.google.cloud.helix.server.job.LocalQueryJobController.handleQueryException(LocalQueryJobController.java:3086)\n\tat com.google.cloud.helix.server.job.LocalQueryJobController.handleQueryDone(LocalQueryJobController.java:2664)\n\tat com.google.cloud.helix.server.job.LocalQueryJobController.lambda$runJob$0(LocalQueryJobController.java:2481)\n\t... 9 more\n\tSuppressed: java.lang.Exception: Including call stack from HelixFutures\n\t\tat com.google.cloud.helix.common.HelixFutures.getHelixException(HelixFutures.java:76)\n\t\tat com.google.cloud.helix.common.HelixFutures.get(HelixFutures.java:42)\n\t\tat com.google.cloud.helix.server.job.LocalJobController.handleJobDone(LocalJobController.java:414)\n\t\tat com.google.cloud.helix.server.job.LocalJobController.lambda$runThread$0(LocalJobController.java:350)\n\t\t... 9 more\nCaused by: [CANCELLED] errorProto=code: \"JOB_CANCELLED\"\nargument: \"User requested cancel or job timed out\"\n\n\tat com.google.cloud.helix.common.Exceptions$Public.jobCancelled(Exceptions.java:986)\n\tat com.google.cloud.helix.server.job.DremelErrorUtil.createHelixErrorFromDremelRpcException(DremelErrorUtil.java:76)\n\tat com.google.cloud.helix.common.dremel.QueryExecutorImpl$ConfiguredQueryMigration$StreamHandler.onMessage(QueryExecutorImpl.java:824)\n\tat com.google.cloud.helix.common.dremel.QueryExecutorImpl$ConfiguredQueryMigration$StreamHandler.onMessage(QueryExecutorImpl.java:736)\n\tat com.google.net.rpc3.stream.RpcMessageCallback$ForwardingRpcMessageCallback.onMessage(RpcMessageCallback.java:128)\n\tat com.google.net.rpc3.impl.RpcStreamInternalContext.processMessageUnlocked(RpcStreamInternalContext.java:1862)\n\tat com.google.net.rpc3.impl.RpcStreamInternalContext.invokeCallbacksInternalUnlocked(RpcStreamInternalContext.java:2915)\n\tat com.google.net.rpc3.impl.RpcStreamInternalContext.invokeCallbacksUnlocked(RpcStreamInternalContext.java:2841)\n\tat com.google.net.eventmanager.AbstractFutureTask$Sync.innerRun(AbstractFutureTask.java:259)\n\tat com.google.net.eventmanager.AbstractFutureTask.run(AbstractFutureTask.java:120)\n\tat com.google.net.eventmanager.EventManagerImpl.runTaskTraced(EventManagerImpl.java:903)\n\tat com.google.net.eventmanager.EventManagerImpl.runTask(EventManagerImpl.java:895)\n\tat com.google.net.eventmanager.EventManagerImpl.internalRunWorkerLoop(EventManagerImpl.java:1322)\n\tat com.google.net.eventmanager.EventManagerImpl.runWorkerLoop(EventManagerImpl.java:1213)\n\tat com.google.net.eventmanager.WorkerThreadInfo.runWorkerLoop(WorkerThreadInfo.java:153)\n\tat com.google.net.eventmanager.EventManagerImpl$WorkerThread.run(EventManagerImpl.java:2006)\n"
    \\   },
    \\   "errors": [
    \\    {
    \\     "reason": "stopped"
    \\    }
    \\   ],
    \\   "state": "DONE"
    \\  },
    \\  "jobCreationReason": {
    \\   "code": "REQUESTED"
    \\  }
    \\ }
    \\}
;
