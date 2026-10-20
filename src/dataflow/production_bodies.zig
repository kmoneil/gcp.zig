//! Answers production gave on 2026-10-20, measured in milestone 0 of the
//! Dataflow spec (`_tmp/dataflow-m0/`), for tests: the probe's own
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
