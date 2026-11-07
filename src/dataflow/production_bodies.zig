//! Answers production gave on 2026-10-20, measured in milestone 0 of the
//! Dataflow spec (`_tmp/dataflow-m0/`) and of the writes spec, cancel and
//! drain (`_tmp/dataflow-writes-m0/`), for tests: the probes' own
//! `zigps-` Word_Count jobs and refusals, reserialized with sorted keys
//! (the probe saved parsed bodies). Test code only.
//!
//! The last group is from 2026-11-07 (#310's milestone 0,
//! `_tmp/dataflow-detail-m0/`, raw bodies there): a job in full and its
//! metrics. Production's job at JOB_VIEW_ALL was 858 KB and its metrics
//! 152 KB, so those two are trimmed: long lists cut to their first
//! entries and long strings cut, every key and every value's shape kept,
//! every display datum and both kinds of metric value kept.

/// The Word_Count job just launched: PENDING, labels already on the plain get, no stageStates yet. HTTP 200.
pub const job_pending =
    \\{
    \\ "createTime": "2026-10-20T14:11:02.290324Z",
    \\ "currentState": "JOB_STATE_PENDING",
    \\ "currentStateTime": "2026-10-20T14:11:02.290324Z",
    \\ "environment": {
    \\  "shuffleMode": "SERVICE_BASED",
    \\  "usePublicIps": true,
    \\  "userAgent": {
    \\   "container.base_repository": "gcr.io/cloud-dataflow/v1beta3",
    \\   "fnapi.container.version": "2.76.0",
    \\   "fnapi.environment.major.version": "8",
    \\   "java.vendor": "Eclipse Adoptium",
    \\   "java.version": "17.0.20.1",
    \\   "legacy.container.version": "2.76.0",
    \\   "legacy.environment.major.version": "8",
    \\   "name": "Apache Beam SDK for Java",
    \\   "os.arch": "amd64",
    \\   "os.name": "Linux",
    \\   "os.version": "7.0.0-1014-gcp",
    \\   "support": {
    \\    "status": "SUPPORTED",
    \\    "url": "https://github.com/apache/beam/releases"
    \\   },
    \\   "version": "2.76.0"
    \\  },
    \\  "version": {
    \\   "job_type": "FNAPI_BATCH",
    \\   "major": "8"
    \\  }
    \\ },
    \\ "id": "2026-10-20_07_11_01-16829577348630633066",
    \\ "jobMetadata": {
    \\  "sdkVersion": {
    \\   "sdkSupportStatus": "SUPPORTED",
    \\   "version": "2.76.0",
    \\   "versionDisplayName": "Apache Beam SDK for Java"
    \\  }
    \\ },
    \\ "labels": {
    \\  "goog-dataflow-provided-template-name": "word_count",
    \\  "goog-dataflow-provided-template-type": "legacy",
    \\  "goog-dataflow-provided-template-version": "2026-10-06-00_rc04"
    \\ },
    \\ "location": "us-central1",
    \\ "name": "zigps-df-05461",
    \\ "projectId": "extractctl",
    \\ "startTime": "2026-10-20T14:11:02.290324Z",
    \\ "type": "JOB_TYPE_BATCH"
    \\}
;

/// The same job 30 s later: RUNNING, stageStates now present. HTTP 200.
pub const job_running =
    \\{
    \\ "createTime": "2026-10-20T14:11:02.290324Z",
    \\ "currentState": "JOB_STATE_RUNNING",
    \\ "currentStateTime": "2026-10-20T14:11:24.260708Z",
    \\ "environment": {
    \\  "shuffleMode": "SERVICE_BASED",
    \\  "usePublicIps": true,
    \\  "userAgent": {
    \\   "container.base_repository": "gcr.io/cloud-dataflow/v1beta3",
    \\   "fnapi.container.version": "2.76.0",
    \\   "fnapi.environment.major.version": "8",
    \\   "java.vendor": "Eclipse Adoptium",
    \\   "java.version": "17.0.20.1",
    \\   "legacy.container.version": "2.76.0",
    \\   "legacy.environment.major.version": "8",
    \\   "name": "Apache Beam SDK for Java",
    \\   "os.arch": "amd64",
    \\   "os.name": "Linux",
    \\   "os.version": "7.0.0-1014-gcp",
    \\   "support": {
    \\    "status": "SUPPORTED",
    \\    "url": "https://github.com/apache/beam/releases"
    \\   },
    \\   "version": "2.76.0"
    \\  },
    \\  "version": {
    \\   "job_type": "FNAPI_BATCH",
    \\   "major": "8"
    \\  }
    \\ },
    \\ "id": "2026-10-20_07_11_01-16829577348630633066",
    \\ "jobMetadata": {
    \\  "sdkVersion": {
    \\   "sdkSupportStatus": "SUPPORTED",
    \\   "version": "2.76.0",
    \\   "versionDisplayName": "Apache Beam SDK for Java"
    \\  }
    \\ },
    \\ "labels": {
    \\  "goog-dataflow-provided-template-name": "word_count",
    \\  "goog-dataflow-provided-template-type": "legacy",
    \\  "goog-dataflow-provided-template-version": "2026-10-06-00_rc04"
    \\ },
    \\ "location": "us-central1",
    \\ "name": "zigps-df-05461",
    \\ "projectId": "extractctl",
    \\ "stageStates": [
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-open-shuffle39",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "F61",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts/WriteFiles/GatherTempFileResults/AsPossiblyEmptyList/Reify.ReifyView/ParDo(Anonymous)/ParMultiDo(Anonymous)/View-org.apache.beam.sdk.values.PCollectionViews$SimplePCollectionView.<init>:1935#d6c184af69871a3b",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "F57",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "F56",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "F59",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "F60",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.392Z",
    \\   "executionStageName": "F62",
    \\   "executionStageState": "JOB_STATE_RUNNING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "ReadLines-Read-ParDo-BoundedSourceAsSDFWrapper--ParMultiDo-BoundedSourceAsSDFWrapper--split-with-sizing-out3",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WordCount-CountWords-Count-PerElement-Combine-perKey-Count--GroupByKey10-shuffle-session15",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WordCount-CountWords-Count-PerElement-Combine-perKey-Count--GroupByKey10-open-shuffle16",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-close-shuffle26",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-open-shuffle24",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-shuffle-session23",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts/WriteFiles/GatherTempFileResults/AsPossiblyEmptyList/Reify.ReifyView/ParDo(Anonymous)/ParMultiDo(Anonymous)/View-org.apache.beam.sdk.values.PCollectionViews$SimplePCollectionView.<init>:1935#d6c184af69871a3b.out",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "success63",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-close-shuffle41",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "failure64",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.386Z",
    \\   "executionStageName": "start65",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-shuffle-session32",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WordCount-CountWords-Count-PerElement-Combine-perKey-Count--GroupByKey10-close-shuffle18",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-shuffle-session38",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-open-shuffle33",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "F58",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-close-shuffle35",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-View-AsIterable-MapElements-Map-ParMultiDo-Anonymous-.output",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  }
    \\ ],
    \\ "startTime": "2026-10-20T14:11:02.290324Z",
    \\ "type": "JOB_TYPE_BATCH"
    \\}
;

/// The same job at 244 s: DONE, every stage state terminal. HTTP 200.
pub const job_done =
    \\{
    \\ "createTime": "2026-10-20T14:11:02.290324Z",
    \\ "currentState": "JOB_STATE_DONE",
    \\ "currentStateTime": "2026-10-20T14:14:54.919613Z",
    \\ "environment": {
    \\  "shuffleMode": "SERVICE_BASED",
    \\  "usePublicIps": true,
    \\  "userAgent": {
    \\   "container.base_repository": "gcr.io/cloud-dataflow/v1beta3",
    \\   "fnapi.container.version": "2.76.0",
    \\   "fnapi.environment.major.version": "8",
    \\   "java.vendor": "Eclipse Adoptium",
    \\   "java.version": "17.0.20.1",
    \\   "legacy.container.version": "2.76.0",
    \\   "legacy.environment.major.version": "8",
    \\   "name": "Apache Beam SDK for Java",
    \\   "os.arch": "amd64",
    \\   "os.name": "Linux",
    \\   "os.version": "7.0.0-1014-gcp",
    \\   "support": {
    \\    "status": "SUPPORTED",
    \\    "url": "https://github.com/apache/beam/releases"
    \\   },
    \\   "version": "2.76.0"
    \\  },
    \\  "version": {
    \\   "job_type": "FNAPI_BATCH",
    \\   "major": "8"
    \\  }
    \\ },
    \\ "id": "2026-10-20_07_11_01-16829577348630633066",
    \\ "jobMetadata": {
    \\  "sdkVersion": {
    \\   "sdkSupportStatus": "SUPPORTED",
    \\   "version": "2.76.0",
    \\   "versionDisplayName": "Apache Beam SDK for Java"
    \\  }
    \\ },
    \\ "labels": {
    \\  "goog-dataflow-provided-template-name": "word_count",
    \\  "goog-dataflow-provided-template-type": "legacy",
    \\  "goog-dataflow-provided-template-version": "2026-10-06-00_rc04"
    \\ },
    \\ "location": "us-central1",
    \\ "name": "zigps-df-05461",
    \\ "projectId": "extractctl",
    \\ "stageStates": [
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:58.317Z",
    \\   "executionStageName": "F56",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:57.596Z",
    \\   "executionStageName": "F59",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:53.954Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-close-shuffle35",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:55.796Z",
    \\   "executionStageName": "WriteCounts/WriteFiles/GatherTempFileResults/AsPossiblyEmptyList/Reify.ReifyView/ParDo(Anonymous)/ParMultiDo(Anonymous)/View-org.apache.beam.sdk.values.PCollectionViews$SimplePCollectionView.<init>:1935#d6c184af69871a3b",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:53.779Z",
    \\   "executionStageName": "F58",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.249Z",
    \\   "executionStageName": "failure64",
    \\   "executionStageState": "JOB_STATE_PENDING"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:58.395Z",
    \\   "executionStageName": "success63",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:50.922Z",
    \\   "executionStageName": "WordCount-CountWords-Count-PerElement-Combine-perKey-Count--GroupByKey10-close-shuffle18",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:55.592Z",
    \\   "executionStageName": "F57",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:47.471Z",
    \\   "executionStageName": "ReadLines-Read-ParDo-BoundedSourceAsSDFWrapper--ParMultiDo-BoundedSourceAsSDFWrapper--split-with-sizing-out3",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:48.074Z",
    \\   "executionStageName": "WordCount-CountWords-Count-PerElement-Combine-perKey-Count--GroupByKey10-shuffle-session15",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:57.736Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-close-shuffle26",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:51.126Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-open-shuffle39",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:11:24.386Z",
    \\   "executionStageName": "start65",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:55.667Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-View-AsIterable-MapElements-Map-ParMultiDo-Anonymous-.output",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:47.402Z",
    \\   "executionStageName": "F62",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:51.489Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-shuffle-session32",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:56.241Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-shuffle-session23",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:55.861Z",
    \\   "executionStageName": "WriteCounts/WriteFiles/GatherTempFileResults/AsPossiblyEmptyList/Reify.ReifyView/ParDo(Anonymous)/ParMultiDo(Anonymous)/View-org.apache.beam.sdk.values.PCollectionViews$SimplePCollectionView.<init>:1935#d6c184af69871a3b.out",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:56.156Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-open-shuffle24",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:53.296Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-close-shuffle41",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:48.011Z",
    \\   "executionStageName": "WordCount-CountWords-Count-PerElement-Combine-perKey-Count--GroupByKey10-open-shuffle16",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:51.202Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-shuffle-session38",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:53.119Z",
    \\   "executionStageName": "F60",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:51.425Z",
    \\   "executionStageName": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-open-shuffle33",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-10-20T14:13:50.802Z",
    \\   "executionStageName": "F61",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  }
    \\ ],
    \\ "startTime": "2026-10-20T14:11:02.290324Z",
    \\ "type": "JOB_TYPE_BATCH"
    \\}
;

/// The first probe's job, which failed 15 s after launch (the service agent race): FAILED, no stageStates. HTTP 200.
pub const job_failed_status = 200;
pub const job_failed =
    \\{
    \\ "createTime": "2026-10-20T14:09:35.414298Z",
    \\ "currentState": "JOB_STATE_FAILED",
    \\ "currentStateTime": "2026-10-20T14:09:37.893665Z",
    \\ "environment": {
    \\  "shuffleMode": "SERVICE_BASED",
    \\  "usePublicIps": true,
    \\  "userAgent": {
    \\   "container.base_repository": "gcr.io/cloud-dataflow/v1beta3",
    \\   "fnapi.container.version": "2.76.0",
    \\   "fnapi.environment.major.version": "8",
    \\   "java.vendor": "Eclipse Adoptium",
    \\   "java.version": "17.0.20.1",
    \\   "legacy.container.version": "2.76.0",
    \\   "legacy.environment.major.version": "8",
    \\   "name": "Apache Beam SDK for Java",
    \\   "os.arch": "amd64",
    \\   "os.name": "Linux",
    \\   "os.version": "7.0.0-1014-gcp",
    \\   "support": {
    \\    "status": "SUPPORTED",
    \\    "url": "https://github.com/apache/beam/releases"
    \\   },
    \\   "version": "2.76.0"
    \\  },
    \\  "version": {
    \\   "job_type": "FNAPI_BATCH",
    \\   "major": "8"
    \\  }
    \\ },
    \\ "id": "2026-10-20_07_09_34-8524524531325271694",
    \\ "jobMetadata": {
    \\  "sdkVersion": {
    \\   "sdkSupportStatus": "SUPPORTED",
    \\   "version": "2.76.0",
    \\   "versionDisplayName": "Apache Beam SDK for Java"
    \\  }
    \\ },
    \\ "labels": {
    \\  "goog-dataflow-provided-template-name": "word_count",
    \\  "goog-dataflow-provided-template-type": "legacy",
    \\  "goog-dataflow-provided-template-version": "2026-10-06-00_rc04"
    \\ },
    \\ "location": "us-central1",
    \\ "name": "zigps-df-05373",
    \\ "projectId": "extractctl",
    \\ "startTime": "2026-10-20T14:09:35.414298Z",
    \\ "type": "JOB_TYPE_BATCH"
    \\}
;

/// The location's list, no filter: summaries (jobMetadata but no labels or environment), newest terminated first. HTTP 200.
pub const jobs_list =
    \\{
    \\ "jobs": [
    \\  {
    \\   "createTime": "2026-10-20T14:11:02.290324Z",
    \\   "currentState": "JOB_STATE_DONE",
    \\   "currentStateTime": "2026-10-20T14:14:54.919613Z",
    \\   "id": "2026-10-20_07_11_01-16829577348630633066",
    \\   "jobMetadata": {
    \\    "sdkVersion": {
    \\     "sdkSupportStatus": "SUPPORTED",
    \\     "version": "2.76.0",
    \\     "versionDisplayName": "Apache Beam SDK for Java"
    \\    }
    \\   },
    \\   "location": "us-central1",
    \\   "name": "zigps-df-05461",
    \\   "projectId": "extractctl",
    \\   "startTime": "2026-10-20T14:11:02.290324Z",
    \\   "type": "JOB_TYPE_BATCH"
    \\  },
    \\  {
    \\   "createTime": "2026-10-20T14:09:35.414298Z",
    \\   "currentState": "JOB_STATE_FAILED",
    \\   "currentStateTime": "2026-10-20T14:09:37.893665Z",
    \\   "id": "2026-10-20_07_09_34-8524524531325271694",
    \\   "jobMetadata": {
    \\    "sdkVersion": {
    \\     "sdkSupportStatus": "SUPPORTED",
    \\     "version": "2.76.0",
    \\     "versionDisplayName": "Apache Beam SDK for Java"
    \\    }
    \\   },
    \\   "location": "us-central1",
    \\   "name": "zigps-df-05373",
    \\   "projectId": "extractctl",
    \\   "startTime": "2026-10-20T14:09:35.414298Z",
    \\   "type": "JOB_TYPE_BATCH"
    \\  }
    \\ ]
    \\}
;

/// The same list at pageSize=1: one job and a nextPageToken. HTTP 200.
pub const jobs_list_paged =
    \\{
    \\ "jobs": [
    \\  {
    \\   "createTime": "2026-10-20T14:11:02.290324Z",
    \\   "currentState": "JOB_STATE_DONE",
    \\   "currentStateTime": "2026-10-20T14:14:54.919613Z",
    \\   "id": "2026-10-20_07_11_01-16829577348630633066",
    \\   "jobMetadata": {
    \\    "sdkVersion": {
    \\     "sdkSupportStatus": "SUPPORTED",
    \\     "version": "2.76.0",
    \\     "versionDisplayName": "Apache Beam SDK for Java"
    \\    }
    \\   },
    \\   "location": "us-central1",
    \\   "name": "zigps-df-05461",
    \\   "projectId": "extractctl",
    \\   "startTime": "2026-10-20T14:11:02.290324Z",
    \\   "type": "JOB_TYPE_BATCH"
    \\  }
    \\ ],
    \\ "nextPageToken": "CigyMDI2LTEwLTIwXzA3XzExXzAxLTE2ODI5NTc3MzQ4NjMwNjMzMDY2GOex9Y_kyJcD"
    \\}
;

/// The aggregated list: both jobs, each carrying its location. HTTP 200.
pub const jobs_aggregated =
    \\{
    \\ "jobs": [
    \\  {
    \\   "createTime": "2026-10-20T14:11:02.290324Z",
    \\   "currentState": "JOB_STATE_DONE",
    \\   "currentStateTime": "2026-10-20T14:14:54.919613Z",
    \\   "id": "2026-10-20_07_11_01-16829577348630633066",
    \\   "jobMetadata": {
    \\    "sdkVersion": {
    \\     "sdkSupportStatus": "SUPPORTED",
    \\     "version": "2.76.0",
    \\     "versionDisplayName": "Apache Beam SDK for Java"
    \\    }
    \\   },
    \\   "location": "us-central1",
    \\   "name": "zigps-df-05461",
    \\   "projectId": "extractctl",
    \\   "startTime": "2026-10-20T14:11:02.290324Z",
    \\   "type": "JOB_TYPE_BATCH"
    \\  },
    \\  {
    \\   "createTime": "2026-10-20T14:09:35.414298Z",
    \\   "currentState": "JOB_STATE_FAILED",
    \\   "currentStateTime": "2026-10-20T14:09:37.893665Z",
    \\   "id": "2026-10-20_07_09_34-8524524531325271694",
    \\   "jobMetadata": {
    \\    "sdkVersion": {
    \\     "sdkSupportStatus": "SUPPORTED",
    \\     "version": "2.76.0",
    \\     "versionDisplayName": "Apache Beam SDK for Java"
    \\    }
    \\   },
    \\   "location": "us-central1",
    \\   "name": "zigps-df-05373",
    \\   "projectId": "extractctl",
    \\   "startTime": "2026-10-20T14:09:35.414298Z",
    \\   "type": "JOB_TYPE_BATCH"
    \\  }
    \\ ]
    \\}
;

/// A job id nobody has: 404 in a sentence that names the method.
pub const job_unknown_status = 404;
pub const job_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "(9e3e240fb8c0da42): Information about job 2026-10-20_00_00_00-1234567890123456789 could not be found in our system. Please double check that the API being used is projects.locations.jobs.get (https://cloud.google.com/dataflow/docs/reference/rest/v1b3/projects.locations.jobs/get). If the API being used is projects.locations.jobs.get, please double check the id (2026-10-20_00_00_00-1234567890123456789) is correct. If it is please contact customer support.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A filter the enum does not have: 400 INVALID_ARGUMENT with a field violation.
pub const filter_bad_status = 400;
pub const filter_bad =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\    "fieldViolations": [
    \\     {
    \\      "description": "Invalid value at 'filter' (type.googleapis.com/google.dataflow.v1beta3.ListJobsRequest.Filter), \"NONSENSE\"",
    \\      "field": "filter"
    \\     }
    \\    ]
    \\   }
    \\  ],
    \\  "message": "Invalid value at 'filter' (type.googleapis.com/google.dataflow.v1beta3.ListJobsRequest.Filter), \"NONSENSE\"",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A get at JOB_VIEW_ALL of the job that failed provisioning: production answers 400 carrying the job's own error text.
pub const job_failed_view_all_status = 400;
pub const job_failed_view_all =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(566ab424ae67c3ad): The Dataflow service agent cannot access the worker service account. Ensure that the Dataflow API is enabled for your project. In addition, verify that for the worker service account, the Dataflow service agent principal has the 'Cloud Dataflow Service Agent' role. To grant the role, see https://cloud.google.com/iam/docs/manage-access-service-accounts#view-access. On the Service Accounts page, select the worker service account, open the Permissions tab, and select 'Include Google-provided role grants' to verify roles. To learn more about service accounts, see https://cloud.google.com/dataflow/docs/concepts/security-and-permissions#permissions",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;
/// The failed job's messages at minimumImportance=ERROR: the one error, the widget's "why is it red". HTTP 200.
pub const messages_error_failed =
    \\{
    \\ "jobMessages": [
    \\  {
    \\   "id": "1792505377766",
    \\   "messageImportance": "JOB_MESSAGE_ERROR",
    \\   "messageText": "The Dataflow service agent cannot access the worker service account. Ensure that the Dataflow API is enabled for your project. In addition, verify that for the worker service account, the Dataflow service agent principal has the 'Cloud Dataflow Service Agent' role. To grant the role, see https://cloud.google.com/iam/docs/manage-access-service-accounts#view-access. On the Service Accounts page, select the worker service account, open the Permissions tab, and select 'Include Google-provided role grants' to verify roles. To learn more about service accounts, see https://cloud.google.com/dataflow/docs/concepts/security-and-permissions#permissions",
    \\   "time": "2026-10-20T14:09:37.766Z"
    \\  }
    \\ ]
    \\}
;

/// The DONE job's messages at minimumImportance=ERROR: no jobMessages key, and the autoscaling events come regardless of the filter. HTTP 200.
pub const messages_error_done =
    \\{
    \\ "autoscalingEvents": [
    \\  {
    \\   "description": {
    \\    "messageKey": "POOL_STARTUP_INITIATED",
    \\    "messageText": "(4aa65aadddcff524): Starting a pool of 1 workers.",
    \\    "parameters": [
    \\     {
    \\      "key": "num_workers",
    \\      "value": 1
    \\     }
    \\    ]
    \\   },
    \\   "eventType": "TARGET_NUM_WORKERS_CHANGED",
    \\   "targetNumWorkers": "1",
    \\   "time": "2026-10-20T14:11:24.731653388Z",
    \\   "workerPool": "Regular"
    \\  },
    \\  {
    \\   "description": {
    \\    "messageKey": "POOL_STARTUP_INITIATED",
    \\    "messageText": "(4aa65aadddcffe6a): Starting a pool of 1 workers.",
    \\    "parameters": [
    \\     {
    \\      "key": "num_workers",
    \\      "value": 1
    \\     }
    \\    ]
    \\   },
    \\   "eventType": "CURRENT_NUM_WORKERS_CHANGED",
    \\   "time": "2026-10-20T14:11:24.731653388Z",
    \\   "workerPool": "Regular"
    \\  },
    \\  {
    \\   "currentNumWorkers": "1",
    \\   "description": {
    \\    "messageKey": "POOL_STARTUP_COMPLETED",
    \\    "messageText": "(e48784c4abcf277b): Worker pool started."
    \\   },
    \\   "eventType": "CURRENT_NUM_WORKERS_CHANGED",
    \\   "time": "2026-10-20T14:12:15.108653190Z",
    \\   "workerPool": "Regular"
    \\  },
    \\  {
    \\   "currentNumWorkers": "1",
    \\   "description": {
    \\    "messageKey": "POOL_SHUTDOWN_INITIATED",
    \\    "messageText": "(dc67ddf3489a59f): Stopping worker pool."
    \\   },
    \\   "eventType": "TARGET_NUM_WORKERS_CHANGED",
    \\   "time": "2026-10-20T14:13:58.560009066Z",
    \\   "workerPool": "Regular"
    \\  },
    \\  {
    \\   "currentNumWorkers": "1",
    \\   "description": {
    \\    "messageKey": "POOL_SHUTDOWN_INITIATED",
    \\    "messageText": "(dc67ddf3489a289): Stopping worker pool."
    \\   },
    \\   "eventType": "CURRENT_NUM_WORKERS_CHANGED",
    \\   "time": "2026-10-20T14:13:58.560009066Z",
    \\   "workerPool": "Regular"
    \\  },
    \\  {
    \\   "description": {
    \\    "messageKey": "POOL_SHUTDOWN_COMPLETED",
    \\    "messageText": "(e48784c4abcf251e): Worker pool stopped."
    \\   },
    \\   "eventType": "CURRENT_NUM_WORKERS_CHANGED",
    \\   "time": "2026-10-20T14:14:52.960442112Z",
    \\   "workerPool": "Regular"
    \\  }
    \\ ]
    \\}
;

/// A cancel taken by a running Word_Count job, and its repeat while cancelling: the job's type alone, no id or state. HTTP 200.
pub const cancel_taken =
    \\{
    \\ "type": "JOB_TYPE_BATCH"
    \\}
;

/// A drain taken by a running Pub/Sub-to-Pub/Sub streaming job, and its repeat while draining: one field, which says JOB_TYPE_BATCH of the streaming job, so the answer carries nothing. HTTP 200.
pub const drain_taken =
    \\{
    \\ "type": "JOB_TYPE_BATCH"
    \\}
;

/// A cancel of a job still PENDING, 0.4 to 17.5 s after its launch: 400 FAILED_PRECONDITION; taken at 20.9 s, once it ran.
pub const cancel_not_ready_status = 400;
pub const cancel_not_ready =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(87cd38ee6aa5ad75): Workflow modification failed. Causes: (891fdc8387302e9c): Operation cancel not allowed for job 2026-10-20_15_14_29-4138990520061636327. Job is not yet ready for canceling. Please retry in a few minutes.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A drain of a running batch job: 400 INVALID_ARGUMENT, before any check of its state (an ended or cancelling batch job answers the same).
pub const drain_batch_status = 400;
pub const drain_batch =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(f689798c2adad10c): Job 2026-10-20_15_12_40-17194894741260815925 is not a streaming workflow. Only streaming workflows can be drained.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A cancel of a batch job that has ended DONE: 400 FAILED_PRECONDITION naming the state it ended in.
pub const cancel_ended_status = 400;
pub const cancel_ended =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(19f81b97a8fbcd51): Workflow modification failed. Causes: (897135efbf4d3a23): Cannot perform operation 'cancel' on Job: 2026-10-20_15_12_39-16726637407140010736. Job has terminated in state SUCCESS: Workflow job: 2026-10-20_15_12_39-16726637407140010736 succeeded.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A cancel of a job nobody has: 404 in a sentence that says cancel, for a drain too, and for a real region the job is not in.
pub const cancel_unknown_status = 404;
pub const cancel_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "(18461e55926cc416): Could not cancel workflow; user does not have sufficient permissions on project: extractctl, or the job does not exist in the project.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A cancel of a batch job that has ended CANCELLED: 400 FAILED_PRECONDITION naming the state.
pub const cancel_cancelled_status = 400;
pub const cancel_cancelled =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(58b258f1ac4ecd4): Workflow modification failed. Causes: (642b8d656b0be058): Cannot perform operation 'cancel' on Job: 2026-10-20_15_14_29-4138990520061636327. Job has terminated in state CANCELLED: Workflow job: 2026-10-20_15_14_29-4138990520061636327 cancelled.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A cancel of a streaming job that ended FAILED (its one worker never started, a zone out of resources): 400 FAILED_PRECONDITION naming the state.
pub const cancel_failed_status = 400;
pub const cancel_failed =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(5c4f5c0e8305c936): Workflow modification failed. Causes: (c7fc581a343ccf1c): Cannot perform operation 'cancel' on Job: 2026-10-20_15_12_41-6567995927817659660. Job has terminated in state FAILED: Workflow job: 2026-10-20_15_12_41-6567995927817659660 failed.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A cancel of the job that failed its launch (the read spec's, FAILED with the service agent's provisioning error): its state named NOT_STARTED.
pub const cancel_not_started_status = 400;
pub const cancel_not_started =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(3bdea72ad4fa527): Workflow modification failed. Causes: (a487fc6f4309d9b): Cannot perform operation 'cancel' on Job: 2026-10-20_07_09_34-8524524531325271694. Job has terminated in state NOT_STARTED: Workflow job: 2026-10-20_07_09_34-8524524531325271694 failed to start.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A drain of a streaming job that has ended: 400 FAILED_PRECONDITION, "Job has terminated." and no state named.
pub const drain_ended_status = 400;
pub const drain_ended =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(aa00684133f7ce3b): Workflow modification failed. Causes: (7491567bbed4c09a): Cannot perform operation 'drain' on Job: 2026-10-20_15_12_41-6567995927817659660. Job has terminated.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A cancel through a made-up region (us-fake1) of a PENDING us-central1 job: answered by the job's own backend, the job named, so a made-up region reaches the job (a real region it is not in, us-east1, is the 404 of cancel_unknown).
pub const cancel_made_up_region_status = 400;
pub const cancel_made_up_region =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(e2641736f91bff2e): Workflow modification failed. Causes: (39d4f0b0a2fa3dda): Operation cancel not allowed for job 2026-10-20_15_12_39-16726637407140010736. Job is not yet ready for canceling. Please retry in a few minutes.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A cancel of a streaming job that has ended DRAINED (126 s after its drain): 400 FAILED_PRECONDITION naming the state.
pub const cancel_drained_status = 400;
pub const cancel_drained =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "(332829a012d8ae21): Workflow modification failed. Causes: (18b98733be202381): Cannot perform operation 'cancel' on Job: 2026-10-20_15_21_25-1828704797262605315. Job has terminated in state DRAINED: Workflow job: 2026-10-20_15_21_25-1828704797262605315 was drained.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// The Word_Count job of 2026-11-07, DONE, at JOB_VIEW_ALL: graph, environment, SDK, labels, every parameter, and `steps`, which alone DESCRIPTION leaves out. Trimmed from 858 KB. HTTP 200.
pub const job_detail_all =
    \\{
    \\ "createTime": "2026-11-07T20:14:27.675912Z",
    \\ "currentState": "JOB_STATE_DONE",
    \\ "currentStateTime": "2026-11-07T20:17:30.968890Z",
    \\ "environment": {
    \\  "dataset": "bigquery.googleapis.com/cloud_dataflow",
    \\  "experiments": [
    \\   "enable_oom_sampler",
    \\   "use_retriable_jac_in_dm",
    \\   "enable_compute_default_service_account_org_policy",
    \\   "primeflex_slow_start_seconds=3600",
    \\   "enable_iam_rsi_location_check",
    \\   "regional_physical_zone_separation_enabled"
    \\  ],
    \\  "sdkPipelineOptions": {
    \\   "display_data": [
    \\    {
    \\     "key": "appName",
    \\     "namespace": "org.apache.beam.sdk.options.ApplicationNameOptions",
    \\     "type": "STRING",
    \\     "value": "WordCount"
    \\    },
    \\    {
    \\     "key": "sdkContainerImage",
    \\     "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineWor",
    \\     "type": "STRING",
    \\     "value": ""
    \\    }
    \\   ],
    \\   "options": {
    \\    "filesToStage": [
    \\     "/b/f/w/src/git/templates/v1/target/classes",
    \\     "/b/f/w/src/git/templates/metadata/target/metadata-1.0-SNAPSH"
    \\    ],
    \\    "inputFile": null,
    \\    "jobName": "wordcount-root-1027145535-a775d090",
    \\    "region": "us-central1",
    \\    "tempLocation": "gs://zigps-df-detail-82456/tmp",
    \\    "templateLocation": "gs://dataflow-templates-us-central1/latest/Word_Count"
    \\   },
    \\   "revision": 7
    \\  },
    \\  "serviceAccountEmail": "82150720798-compute@developer.gserviceaccount.com",
    \\  "shuffleMode": "SERVICE_BASED",
    \\  "tempStoragePrefix": "storage.googleapis.com/zigps-df-detail-82456/tmp",
    \\  "usePublicIps": true,
    \\  "userAgent": {
    \\   "container.base_repository": "gcr.io/cloud-dataflow/v1beta3",
    \\   "fnapi.container.version": "2.77.0",
    \\   "fnapi.environment.major.version": "8",
    \\   "java.vendor": "Eclipse Adoptium",
    \\   "java.version": "17.0.21",
    \\   "legacy.container.version": "2.77.0",
    \\   "legacy.environment.major.version": "8",
    \\   "name": "Apache Beam SDK for Java",
    \\   "os.arch": "amd64",
    \\   "os.name": "Linux",
    \\   "os.version": "7.0.0-1014-gcp",
    \\   "support": {
    \\    "status": "SUPPORTED",
    \\    "url": "https://github.com/apache/beam/releases"
    \\   },
    \\   "version": "2.77.0"
    \\  },
    \\  "version": {
    \\   "job_type": "FNAPI_BATCH",
    \\   "major": "8"
    \\  },
    \\  "workerPools": [
    \\   {
    \\    "autoscalingSettings": {
    \\     "maxNumWorkers": 1
    \\    },
    \\    "diskSizeGb": 30,
    \\    "kind": "harness",
    \\    "machineType": "n1-standard-1",
    \\    "metadata": {
    \\     "enable_containerd_runtime": "true",
    \\     "enable_data_sampling_telemetry": "true",
    \\     "enable_health_checker_startup_timeout": "true",
    \\     "enable_memory_sampler": "true",
    \\     "enable_oom_sampler": "true",
    \\     "enable_worker_cloud_monitoring_exporter": "true",
    \\     "enable_worker_disk_cloud_monitoring": "true",
    \\     "enable_worker_memory_cloud_monitoring": "true",
    \\     "job_name": "zigps-df-82466",
    \\     "packages": "gs://dataflow-templates-libraries/2026-10-27-00_RC00/staging",
    \\     "packages01": "son2-2.2.0-oxtCu6dKG4OinNOoFrAPJglqqAjSWBgx5XW5T6muwsg.jar|g",
    \\     "packages02": "-aVQSGO9ucFR3SdaTvUwYRoF-W9eUmz4olQ-Z8.jar|reload4j-1.2.22-I",
    \\     "packages03": "s_HNK-xQM.jar|maven-core-3.9.9-f6s3_GBE8grgBDdquEFDc2Ns9R4mr",
    \\     "packages_sha256": "classes-lT6aRY7w2fLdA8Z0v6pkot9o35DfWNVwppA87hN3mNA.jar|953e",
    \\     "packages_sha25601": "5yCXF21gPgRW_Sf_Ikwk1JtLtEHn7ySm2pfvQsu2kA.jar|639c825c5db58",
    \\     "packages_sha25602": "32ad58262970f92d2ec4dc142301dd17efb46121|maven-settings-buil",
    \\     "sdk_pipeline_options": "{\"display_data\":[{\"namespace\":\"org.apache.beam.sdk.options.A"
    \\    },
    \\    "network": "default",
    \\    "numWorkers": 2,
    \\    "onHostMaintenance": "MIGRATE",
    \\    "packages": [
    \\     {
    \\      "location": "storage.googleapis.com/dataflow-templates-libraries/2026-10-",
    \\      "name": "classes-lT6aRY7w2fLdA8Z0v6pkot9o35DfWNVwppA87hN3mNA.jar",
    \\      "sha256": "953e9a458ef0d9f2dd03c674bfaa64a2df68df90df58d570a6903cee1377"
    \\     },
    \\     {
    \\      "location": "storage.googleapis.com/dataflow-templates-libraries/2026-10-",
    \\      "name": "metadata-1.0-SNAPSHOT-oqlr8zfeA78YUQE7F7H5CNp86KR5L80357sJ_g",
    \\      "sha256": "a2a96bf337de03bf1851013b17b1f908da7ce8a4792fcd37e7bb09fe00f2"
    \\     }
    \\    ],
    \\    "poolArgs": {},
    \\    "teardownPolicy": "TEARDOWN_ALWAYS",
    \\    "workerHarnessContainerImage": "gcr.io/cloud-dataflow/v1beta3/beam-java17-batch:2.77.0"
    \\   }
    \\  ]
    \\ },
    \\ "id": "2026-11-07_12_14_27-5029885235339452204",
    \\ "jobMetadata": {
    \\  "sdkVersion": {
    \\   "sdkSupportStatus": "SUPPORTED",
    \\   "version": "2.77.0",
    \\   "versionDisplayName": "Apache Beam SDK for Java"
    \\  }
    \\ },
    \\ "labels": {
    \\  "goog-dataflow-provided-template-name": "word_count",
    \\  "goog-dataflow-provided-template-type": "legacy",
    \\  "goog-dataflow-provided-template-version": "2026-10-27-00_rc00",
    \\  "zigps-probe": "detail"
    \\ },
    \\ "location": "us-central1",
    \\ "name": "zigps-df-82466",
    \\ "pipelineDescription": {
    \\  "displayData": [
    \\   {
    \\    "key": "appName",
    \\    "namespace": "org.apache.beam.sdk.options.ApplicationNameOptions",
    \\    "strValue": "WordCount"
    \\   },
    \\   {
    \\    "key": "sdkContainerImage",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineWorkerPoolOptions",
    \\    "strValue": ""
    \\   },
    \\   {
    \\    "key": "userAgent",
    \\    "namespace": "org.apache.beam.sdk.options.PipelineOptions",
    \\    "strValue": "Apache_Beam_SDK_for_Java/2.77.0(JRE_17_environment)"
    \\   },
    \\   {
    \\    "key": "pipelineProtoHash",
    \\    "namespace": "org.apache.beam.sdk.options.SdkHarnessOptions",
    \\    "strValue": "723ab260eb3fbac22c87078d521f2c8563f7803c7717631413c9376108aaaddd"
    \\   },
    \\   {
    \\    "key": "labels",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions",
    \\    "strValue": "{goog-dataflow-provided-template-name=word_count, goog-dataflow-provided-template-version=2026-10-27-00_rc00, goog-dataf"
    \\   },
    \\   {
    \\    "key": "stagingLocation",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions",
    \\    "strValue": "gs://dataflow-templates-libraries/2026-10-27-00_RC00/staging/"
    \\   },
    \\   {
    \\    "key": "filesToStage",
    \\    "namespace": "org.apache.beam.sdk.options.FileStagingOptions",
    \\    "strValue": "[/b/f/w/src/git/templates/v1/target/classes, /b/f/w/src/git/templates/metadata/target/metadata-1.0-SNAPSHOT.jar, /root/."
    \\   },
    \\   {
    \\    "key": "pipelineUrl",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions",
    \\    "strValue": "gs://dataflow-templates-libraries/2026-10-27-00_RC00/staging/pipeline-cjqyYOs_usIshweNUh8shWP3gDx3F2MUE8k3YQiqrd0.pb"
    \\   },
    \\   {
    \\    "key": "jobName",
    \\    "namespace": "org.apache.beam.sdk.options.PipelineOptions",
    \\    "strValue": "zigps-df-82466"
    \\   },
    \\   {
    \\    "key": "project",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions",
    \\    "strValue": "extractctl"
    \\   },
    \\   {
    \\    "key": "dataflowServiceOptions",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions",
    \\    "strValue": "[]"
    \\   },
    \\   {
    \\    "key": "runner",
    \\    "namespace": "org.apache.beam.sdk.options.PipelineOptions",
    \\    "shortStrValue": "DataflowRunner",
    \\    "strValue": "org.apache.beam.runners.dataflow.DataflowRunner"
    \\   },
    \\   {
    \\    "key": "region",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions",
    \\    "strValue": "us-central1"
    \\   },
    \\   {
    \\    "key": "tempLocation",
    \\    "namespace": "org.apache.beam.sdk.options.PipelineOptions",
    \\    "strValue": "gs://zigps-df-detail-82456/tmp"
    \\   },
    \\   {
    \\    "key": "templateLocation",
    \\    "namespace": "org.apache.beam.runners.dataflow.options.DataflowPipelineOptions",
    \\    "strValue": "gs://dataflow-templates-us-central1/latest/Word_Count"
    \\   },
    \\   {
    \\    "int64Value": "1",
    \\    "key": "maxNumWorkers",
    \\    "namespace": "google.dataflow.v1beta3.TemplatesService"
    \\   },
    \\   {
    \\    "key": "gcpTempLocation",
    \\    "namespace": "google.dataflow.v1beta3.TemplatesService",
    \\    "strValue": "gs://zigps-df-detail-82456/tmp"
    \\   },
    \\   {
    \\    "key": "inputFile",
    \\    "strValue": "gs://dataflow-samples/shakespeare/kinglear.txt"
    \\   },
    \\   {
    \\    "key": "output",
    \\    "strValue": "gs://zigps-df-detail-82456/out/wc"
    \\   }
    \\  ],
    \\  "executionPipelineStage": [
    \\   {
    \\    "componentSource": [
    \\     {
    \\      "name": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-also-by-w",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey",
    \\      "userName": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey/Read-out0"
    \\     },
    \\     {
    \\      "name": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey.org.apach",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey.out0",
    \\      "userName": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey/GroupByWi"
    \\     }
    \\    ],
    \\    "componentTransform": [
    \\     {
    \\      "name": "s2-read-shuffle27",
    \\      "originalTransform": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey",
    \\      "userName": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey/Read"
    \\     },
    \\     {
    \\      "name": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-also-by-w",
    \\      "originalTransform": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey",
    \\      "userName": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey/GroupByWi"
    \\     }
    \\    ],
    \\    "id": "S16",
    \\    "inputSource": [
    \\     {
    \\      "name": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-shuffle-s",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey",
    \\      "sizeBytes": "67108864",
    \\      "userName": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey/Session"
    \\     }
    \\    ],
    \\    "kind": "PAR_DO_KIND",
    \\    "name": "F56",
    \\    "prerequisiteStage": [
    \\     "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey-close-shu"
    \\    ]
    \\   },
    \\   {
    \\    "componentSource": [
    \\     {
    \\      "name": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-also-by-window-input-v",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey",
    \\      "userName": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey/Read-out0"
    \\     },
    \\     {
    \\      "name": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey.org.apache.beam.sdk.va",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey.out0",
    \\      "userName": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey/GroupByWindow-out0"
    \\     }
    \\    ],
    \\    "componentTransform": [
    \\     {
    \\      "name": "s2-read-shuffle36",
    \\      "originalTransform": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey",
    \\      "userName": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey/Read"
    \\     },
    \\     {
    \\      "name": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-also-by-window37",
    \\      "originalTransform": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey",
    \\      "userName": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey/GroupByWindow"
    \\     }
    \\    ],
    \\    "id": "S11",
    \\    "inputSource": [
    \\     {
    \\      "name": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-shuffle-session32",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey",
    \\      "sizeBytes": "134217728",
    \\      "userName": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey/Session"
    \\     }
    \\    ],
    \\    "kind": "PAR_DO_KIND",
    \\    "name": "F57",
    \\    "outputSource": [
    \\     {
    \\      "name": "WriteCounts-WriteFiles-GatherTempFileResults-View-AsIterable-MapElements-Map-ParMultiDo-Anonymous-.o",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/GatherTempFileResults/View.AsIterable/MapElements/Map/ParMultiDo(Anonymous).o",
    \\      "sizeBytes": "134217728",
    \\      "userName": "WriteCounts/WriteFiles/GatherTempFileResults/View.AsIterable/MapElements/Map/ParMultiDo(Anonymous).o"
    \\     }
    \\    ],
    \\    "prerequisiteStage": [
    \\     "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-close-shuffle35"
    \\    ]
    \\   },
    \\   {
    \\    "componentSource": [
    \\     {
    \\      "name": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten.org.apache.beam.sdk.values.PC",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/GroupUnwritten.out0",
    \\      "userName": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/GroupUnwritten/Read-out0"
    \\     },
    \\     {
    \\      "name": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-WriteUnwritten.org.apache.beam.sdk.transform",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnwritten.out0",
    \\      "userName": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnwritten-out0"
    \\     }
    \\    ],
    \\    "componentTransform": [
    \\     {
    \\      "name": "s2-read-shuffle42",
    \\      "originalTransform": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/GroupUnwritten",
    \\      "userName": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/GroupUnwritten/Read"
    \\     },
    \\     {
    \\      "name": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-WriteUnwritten",
    \\      "originalTransform": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnwritten",
    \\      "userName": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnwritten"
    \\     }
    \\    ],
    \\    "id": "S09",
    \\    "inputSource": [
    \\     {
    \\      "name": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-shuffle-session38",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/GroupUnwritten",
    \\      "sizeBytes": "67108864",
    \\      "userName": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/GroupUnwritten/Session"
    \\     },
    \\     {
    \\      "name": "WriteCounts-WriteFiles-GatherTempFileResults-Consolidate-Reshuffle-GroupByKey-shuffle-session32",
    \\      "originalTransformOrCollection": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey",
    \\      "sizeBytes": "134217728",
    \\      "userName": "WriteCounts/WriteFiles/GatherTempFileResults/Consolidate/Reshuffle/GroupByKey/Session"
    \\     }
    \\    ],
    \\    "kind": "PAR_DO_KIND",
    \\    "name": "F58",
    \\    "prerequisiteStage": [
    \\     "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-GroupUnwritten-close-shuffle41"
    \\    ]
    \\   }
    \\  ],
    \\  "originalPipelineTransform": [
    \\   {
    \\    "id": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Reshuffle-GroupByKey",
    \\    "inputCollectionName": [
    \\     "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/ReifyOriginalMetadat"
    \\    ],
    \\    "kind": "GROUP_BY_KEY_KIND",
    \\    "name": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey",
    \\    "outputCollectionName": [
    \\     "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/GroupByKey.out0"
    \\    ]
    \\   },
    \\   {
    \\    "displayData": [
    \\     {
    \\      "key": "fn",
    \\      "label": "Transform Function",
    \\      "namespace": "org.apache.beam.sdk.transforms.ParDo$MultiOutput",
    \\      "shortStrValue": "org.apache.beam.sdk.io.WriteFiles$WriteUnshardedBundlesToTempFiles$1",
    \\      "strValue": "org.apache.beam.sdk.io.WriteFiles$WriteUnshardedBundlesToTempFiles$1"
    \\     }
    \\    ],
    \\    "id": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-DropShardNum-ParMultiDo-Anonymous-",
    \\    "inputCollectionName": [
    \\     "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnwritten.out1"
    \\    ],
    \\    "kind": "PAR_DO_KIND",
    \\    "name": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/DropShardNum/ParMultiDo(Anonymous)",
    \\    "outputCollectionName": [
    \\     "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/DropShardNum/ParMultiDo(Anonymous).out0"
    \\    ]
    \\   },
    \\   {
    \\    "displayData": [
    \\     {
    \\      "key": "fn",
    \\      "label": "Transform Function",
    \\      "namespace": "org.apache.beam.sdk.transforms.ParDo$MultiOutput",
    \\      "shortStrValue": "org.apache.beam.sdk.io.WriteFiles$WriteUnshardedTempFilesFn",
    \\      "strValue": "org.apache.beam.sdk.io.WriteFiles$WriteUnshardedTempFilesFn"
    \\     }
    \\    ],
    \\    "id": "WriteCounts-WriteFiles-WriteUnshardedBundlesToTempFiles-WriteUnshardedBundles",
    \\    "inputCollectionName": [
    \\     "WriteCounts/WriteFiles/RewindowIntoGlobal/Window.Assign.out0"
    \\    ],
    \\    "kind": "PAR_DO_KIND",
    \\    "name": "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnshardedBundles",
    \\    "outputCollectionName": [
    \\     "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnshardedBundles.out0",
    \\     "WriteCounts/WriteFiles/WriteUnshardedBundlesToTempFiles/WriteUnshardedBundles.out1"
    \\    ]
    \\   },
    \\   {
    \\    "displayData": [
    \\     {
    \\      "key": "class",
    \\      "label": "class",
    \\      "namespace": "org.apache.beam.sdk.transforms.MapElements",
    \\      "shortStrValue": "org.apache.beam.sdk.transforms.Values$1",
    \\      "strValue": "org.apache.beam.sdk.transforms.Values$1"
    \\     },
    \\     {
    \\      "key": "fn",
    \\      "label": "Transform Function",
    \\      "namespace": "org.apache.beam.sdk.transforms.ParDo$MultiOutput",
    \\      "shortStrValue": "org.apache.beam.sdk.transforms.MapElements$2",
    \\      "strValue": "org.apache.beam.sdk.transforms.MapElements$2"
    \\     }
    \\    ],
    \\    "id": "WriteCounts-WriteFiles-FinalizeTempFileBundles-Reshuffle-ViaRandomKey-Values-Values-Map-ParMultiDo-A",
    \\    "inputCollectionName": [
    \\     "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Reshuffle/RestoreMetadata/ParD"
    \\    ],
    \\    "kind": "PAR_DO_KIND",
    \\    "name": "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Values/Values/Map/ParMultiDo(A",
    \\    "outputCollectionName": [
    \\     "WriteCounts/WriteFiles/FinalizeTempFileBundles/Reshuffle.ViaRandomKey/Values/Values/Map/ParMultiDo(A"
    \\    ]
    \\   }
    \\  ],
    \\  "stepNamesHash": "2b3e50bcca87d926a47ca95eba4872b6c66f175d9d03e2be69a3a0e02944bcfc"
    \\ },
    \\ "projectId": "extractctl",
    \\ "stageStates": [
    \\  {
    \\   "currentStateTime": "2026-11-07T20:16:44.210Z",
    \\   "executionStageName": "F56",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-11-07T20:16:41.454Z",
    \\   "executionStageName": "F57",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-11-07T20:16:39.523Z",
    \\   "executionStageName": "F58",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  },
    \\  {
    \\   "currentStateTime": "2026-11-07T20:16:43.599Z",
    \\   "executionStageName": "F59",
    \\   "executionStageState": "JOB_STATE_DONE"
    \\  }
    \\ ],
    \\ "startTime": "2026-11-07T20:14:27.675912Z",
    \\ "steps": [
    \\  {
    \\   "kind": "ParallelRead",
    \\   "name": "ReadLines-Read-Impulse",
    \\   "properties": {
    \\    "format": "impulse",
    \\    "impulse_element": "%7F%DF%3BdZ%1C%AC%09%00%00%00%01%0F%00",
    \\    "output_info": [
    \\     {
    \\      "encoding": {
    \\       "@type": "kind:windowed_value",
    \\       "component_encodings": [
    \\        {
    \\         "@type": "kind:bytes"
    \\        },
    \\        {
    \\         "@type": "kind:global_window"
    \\        }
    \\       ],
    \\       "is_wrapper": true
    \\      },
    \\      "output_name": "org.apache.beam.sdk.values.PCollection.<init>:397#bb20b45fd4d95138",
    \\      "user_name": "ReadLines/Read/Impulse.org.apache.beam.sdk.values.PCollection.<init>:397#bb20b45"
    \\     }
    \\    ],
    \\    "user_name": "ReadLines/Read/Impulse"
    \\   }
    \\  },
    \\  {
    \\   "kind": "ParallelRead",
    \\   "name": "WriteCounts-WriteFiles-GatherTempFileResults-AsPossiblyEmptyList-Create-Values-I",
    \\   "properties": {
    \\    "format": "impulse",
    \\    "impulse_element": "%7F%DF%3BdZ%1C%AC%09%00%00%00%01%0F%00",
    \\    "output_info": [
    \\     {
    \\      "encoding": {
    \\       "@type": "kind:windowed_value",
    \\       "component_encodings": [
    \\        {
    \\         "@type": "kind:bytes"
    \\        },
    \\        {
    \\         "@type": "kind:global_window"
    \\        }
    \\       ],
    \\       "is_wrapper": true
    \\      },
    \\      "output_name": "org.apache.beam.sdk.values.PCollection.<init>:397#e63ad18dfc139ac0",
    \\      "user_name": "WriteCounts/WriteFiles/GatherTempFileResults/AsPossiblyEmptyList/Create.Values/I"
    \\     }
    \\    ],
    \\    "user_name": "WriteCounts/WriteFiles/GatherTempFileResults/AsPossiblyEmptyList/Create.Values/I"
    \\   }
    \\  },
    \\  {
    \\   "kind": "ParallelDo",
    \\   "name": "ReadLines-Read-ParDo-OutputSingleSource--ParMultiDo-OutputSingleSource-",
    \\   "properties": {
    \\    "display_data": [
    \\     {
    \\      "key": "source",
    \\      "label": "Read Source",
    \\      "namespace": "org.apache.beam.sdk.io.Read$OutputSingleSource",
    \\      "shortValue": "org.apache.beam.sdk.io.CompressedSource",
    \\      "type": "STRING",
    \\      "value": "org.apache.beam.sdk.io.CompressedSource"
    \\     },
    \\     {
    \\      "key": "filePattern",
    \\      "label": "File Pattern",
    \\      "namespace": "org.apache.beam.sdk.io.TextSource",
    \\      "shortValue": "RuntimeValueProvider{propertyName=inputFile, default=null}",
    \\      "type": "STRING",
    \\      "value": "RuntimeValueProvider{propertyName=inputFile, default=null}"
    \\     }
    \\    ],
    \\    "non_parallel_inputs": {},
    \\    "output_info": [
    \\     {
    \\      "encoding": {
    \\       "@type": "kind:windowed_value",
    \\       "component_encodings": [
    \\        {
    \\         "@type": "other",
    \\         "pipeline_proto_coder_id": "SnappyCoder"
    \\        },
    \\        {
    \\         "@type": "kind:global_window"
    \\        }
    \\       ],
    \\       "is_wrapper": true
    \\      },
    \\      "output_name": "output",
    \\      "user_name": "ReadLines/Read/ParDo(OutputSingleSource)/ParMultiDo(OutputSingleSource).output"
    \\     }
    \\    ],
    \\    "parallel_input": {
    \\     "@type": "OutputReference",
    \\     "output_name": "org.apache.beam.sdk.values.PCollection.<init>:397#bb20b45fd4d95138",
    \\     "step_name": "ReadLines-Read-Impulse"
    \\    },
    \\    "serialized_fn": "ReadLines-Read-ParDo-OutputSingleSource--ParMultiDo-OutputSingleSource-",
    \\    "user_name": "ReadLines/Read/ParDo(OutputSingleSource)/ParMultiDo(OutputSingleSource)"
    \\   }
    \\  }
    \\ ],
    \\ "type": "JOB_TYPE_BATCH"
    \\}
;

/// getMetrics on the same job, DONE: 374 updates trimmed to integers, floats and the template's user counters, each beside its tentative twin where production sent one. HTTP 200.
pub const metrics_done =
    \\{
    \\ "metricTime": "2026-11-07T20:17:30.766Z",
    \\ "metrics": [
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-cpu_num_seconds",
    \\     "tentative": "true"
    \\    },
    \\    "name": "TotalVcpuTime",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 103,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-cpu_num_seconds"
    \\    },
    \\    "name": "TotalVcpuTime",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 103,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-mem_mb_seconds",
    \\     "tentative": "true"
    \\    },
    \\    "name": "TotalMemoryUsage",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 397095,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-mem_mb_seconds"
    \\    },
    \\    "name": "TotalMemoryUsage",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 397095,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-pd_gb_seconds",
    \\     "tentative": "true"
    \\    },
    \\    "name": "TotalPdUsage",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 2585,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-pd_gb_seconds"
    \\    },
    \\    "name": "TotalPdUsage",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 2585,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "namespace": "com.google.cloud.teleport.templates.WordCount$ExtractWordsFn",
    \\     "step": "WordCount-CountWords-ParDo-ExtractWords--ParMultiDo-ExtractWords-",
    \\     "tentative": "true"
    \\    },
    \\    "name": "emptyLines",
    \\    "origin": "user"
    \\   },
    \\   "scalar": 1663,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "namespace": "com.google.cloud.teleport.templates.WordCount$ExtractWordsFn",
    \\     "step": "WordCount-CountWords-ParDo-ExtractWords--ParMultiDo-ExtractWords-"
    \\    },
    \\    "name": "emptyLines",
    \\    "origin": "user"
    \\   },
    \\   "scalar": 1663,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-shuffle_service_actual_gb",
    \\     "tentative": "true"
    \\    },
    \\    "name": "TotalShuffleDataProcessed",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 6.410107016563416e-05,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-shuffle_service_actual_gb"
    \\    },
    \\    "name": "TotalShuffleDataProcessed",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 6.410107016563416e-05,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-shuffle_service_chargeable_gb",
    \\     "tentative": "true"
    \\    },
    \\    "name": "BillableShuffleDataProcessed",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 1.602526754140854e-05,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  },
    \\  {
    \\   "name": {
    \\    "context": {
    \\     "original_name": "Service-shuffle_service_chargeable_gb"
    \\    },
    \\    "name": "BillableShuffleDataProcessed",
    \\    "origin": "dataflow/v1b3"
    \\   },
    \\   "scalar": 1.602526754140854e-05,
    \\   "updateTime": "2026-11-07T20:17:30.766Z"
    \\  }
    \\ ]
    \\}
;

/// getMetrics with a startTime past every update: the time, and no `metrics`. HTTP 200.
pub const metrics_future_start =
    \\{
    \\ "metricTime": "2030-01-01T00:00:00Z"
    \\}
;

pub const metrics_bad_start_status = 400;
/// getMetrics with `startTime=yesterday`.
pub const metrics_bad_start =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\    "fieldViolations": [
    \\     {
    \\      "description": "Invalid value at 'start_time' (type.googleapis.com/google.protobuf.Timestamp), Field 'start_time', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.",
    \\      "field": "start_time"
    \\     }
    \\    ]
    \\   }
    \\  ],
    \\  "message": "Invalid value at 'start_time' (type.googleapis.com/google.protobuf.Timestamp), Field 'start_time', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

pub const metrics_unknown_status = 404;
/// getMetrics on a job nobody has: the words name `jobs.get`.
pub const metrics_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "(379a29c3c9cfb379): Information about job 2026-11-07_00_00_00-1234567890123456789 could not be found in our system. Please double check that the API being used is projects.locations.jobs.get (https://cloud.google.com/dataflow/docs/reference/rest/v1b3/projects.locations.jobs/get). If the API being used is projects.locations.jobs.get, please double check the id (2026-11-07_00_00_00-1234567890123456789) is correct. If it is please contact customer support.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

pub const detail_bad_view_status = 400;
/// A get with a view outside the enum.
pub const detail_bad_view =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\    "fieldViolations": [
    \\     {
    \\      "description": "Invalid value at 'view' (type.googleapis.com/google.dataflow.v1beta3.JobView), \"JOB_VIEW_NONSENSE\"",
    \\      "field": "view"
    \\     }
    \\    ]
    \\   }
    \\  ],
    \\  "message": "Invalid value at 'view' (type.googleapis.com/google.dataflow.v1beta3.JobView), \"JOB_VIEW_NONSENSE\"",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;
