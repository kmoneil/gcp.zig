//! Answers production gave on 2026-10-20, measured in milestone 0 of the
//! Dataflow spec (`_tmp/dataflow-m0/`) and of the writes spec, cancel and
//! drain (`_tmp/dataflow-writes-m0/`), for tests: the probes' own
//! `zigps-` Word_Count jobs and refusals, reserialized with sorted keys
//! (the probe saved parsed bodies). Test code only.

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
