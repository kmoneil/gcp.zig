//! Answers production gave, for tests: on 2026-10-19 in milestone 0 of
//! the Cloud Run spec (`_tmp/run-m0/`), the probe's own `zigps-` service
//! and refusals; from `job_fresh` on, on 2026-10-21 in milestone 0 of the
//! jobs and writes spec (`_tmp/run-writes-m0/`), its `zigps-` jobs, their
//! executions and the writes' operations. Reserialized with the wire's
//! key order (the probes saved parsed bodies). Test code only.

/// The hello service, ready: terminalCondition Ready/SUCCEEDED, traffic statuses, urls and uri, latest revisions. HTTP 200.
pub const service_ready_status = 200;
pub const service_ready =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/services/zigps-a12c61",
    \\ "uid": "04e92968-6f59-40e9-9831-cedf530c1df5",
    \\ "generation": "1",
    \\ "labels": {
    \\  "zigps": "probe"
    \\ },
    \\ "createTime": "2026-10-19T19:32:31.428729Z",
    \\ "updateTime": "2026-10-19T19:32:31.428729Z",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "ingress": "INGRESS_TRAFFIC_ALL",
    \\ "launchStage": "GA",
    \\ "template": {
    \\  "timeout": "300s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "containers": [
    \\   {
    \\    "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\    "resources": {
    \\     "limits": {
    \\      "memory": "512Mi",
    \\      "cpu": "1000m"
    \\     },
    \\     "cpuIdle": true
    \\    },
    \\    "ports": [
    \\     {
    \\      "name": "http1",
    \\      "containerPort": 8080
    \\     }
    \\    ],
    \\    "startupProbe": {
    \\     "timeoutSeconds": 240,
    \\     "periodSeconds": 240,
    \\     "failureThreshold": 1,
    \\     "tcpSocket": {
    \\      "port": 8080
    \\     }
    \\    }
    \\   }
    \\  ],
    \\  "maxInstanceRequestConcurrency": 80
    \\ },
    \\ "traffic": [
    \\  {
    \\   "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\   "percent": 100
    \\  }
    \\ ],
    \\ "scaling": {
    \\  "maxInstanceCount": 20
    \\ },
    \\ "urls": [
    \\  "https://zigps-a12c61-82150720798.us-central1.run.app",
    \\  "https://zigps-a12c61-el44yx5gia-uc.a.run.app"
    \\ ],
    \\ "sshEnabled": false,
    \\ "observedGeneration": "1",
    \\ "terminalCondition": {
    \\  "type": "Ready",
    \\  "state": "CONDITION_SUCCEEDED",
    \\  "lastTransitionTime": "2026-10-19T19:32:36.762898Z"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "type": "RoutesReady",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "lastTransitionTime": "2026-10-19T19:32:36.714800Z"
    \\  },
    \\  {
    \\   "type": "ConfigurationsReady",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "lastTransitionTime": "2026-10-19T19:32:35.381282Z"
    \\  }
    \\ ],
    \\ "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8",
    \\ "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8",
    \\ "trafficStatuses": [
    \\  {
    \\   "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\   "revision": "zigps-a12c61-00001-ct8",
    \\   "percent": 100
    \\  }
    \\ ],
    \\ "uri": "https://zigps-a12c61-el44yx5gia-uc.a.run.app",
    \\ "etag": "\"CM_g2dYGEKjFt8wB/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtYTEyYzYx\""
    \\}
;

/// Its first revision: the Ready condition with a human message, five conditions in all, the image pinned to its digest, logUri. HTTP 200.
pub const revision_ready_status = 200;
pub const revision_ready =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8",
    \\ "uid": "7b3c68ab-f3f7-4279-86a6-fc1f3887ec3b",
    \\ "generation": "1",
    \\ "createTime": "2026-10-19T19:32:31.559921Z",
    \\ "updateTime": "2026-10-19T19:32:31.559921Z",
    \\ "launchStage": "GA",
    \\ "service": "zigps-a12c61",
    \\ "timeout": "300s",
    \\ "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\ "containers": [
    \\  {
    \\   "name": "hello-1",
    \\   "image": "us-docker.pkg.dev/cloudrun/container/hello@sha256:efd04605322d5d1ce6b1fd3dfc63a9c1fb2b99c97194ec316c0df0fd8f5dcf01",
    \\   "resources": {
    \\    "limits": {
    \\     "memory": "512Mi",
    \\     "cpu": "1000m"
    \\    },
    \\    "cpuIdle": true
    \\   },
    \\   "ports": [
    \\    {
    \\     "name": "http1",
    \\     "containerPort": 8080
    \\    }
    \\   ],
    \\   "startupProbe": {
    \\    "timeoutSeconds": 240,
    \\    "periodSeconds": 240,
    \\    "failureThreshold": 1,
    \\    "tcpSocket": {
    \\     "port": 8080
    \\    }
    \\   }
    \\  }
    \\ ],
    \\ "conditions": [
    \\  {
    \\   "type": "Ready",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Deploying revision succeeded in 3.77s.",
    \\   "lastTransitionTime": "2026-10-19T19:32:35.332279Z"
    \\  },
    \\  {
    \\   "type": "Active",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "lastTransitionTime": "2026-10-19T19:32:35.495138Z",
    \\   "severity": "INFO"
    \\  },
    \\  {
    \\   "type": "ResourcesAvailable",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Provisioning imported containers completed in 1.92s. Checking container health. This will wait for up to 4m for the configured startup probe, including an initial delay of 0s.",
    \\   "lastTransitionTime": "2026-10-19T19:32:34.687395Z"
    \\  },
    \\  {
    \\   "type": "ContainerReady",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Container image import completed.",
    \\   "lastTransitionTime": "2026-10-19T19:32:32.763566Z"
    \\  },
    \\  {
    \\   "type": "ContainerHealthy",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Containers became healthy.",
    \\   "lastTransitionTime": "2026-10-19T19:32:35.270482Z"
    \\  }
    \\ ],
    \\ "observedGeneration": "1",
    \\ "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&resource=cloud_run_revision/service_name/zigps-a12c61/revision_name/zigps-a12c61-00001-ct8&advancedFilter=resource.type%3D%22cloud_run_revision%22%0Aresource.labels.service_name%3D%22zigps-a12c61%22%0Aresource.labels.revision_name%3D%22zigps-a12c61-00001-ct8%22",
    \\ "maxInstanceRequestConcurrency": 80,
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "etag": "\"CM_g2dYGEOju_ooC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtYTEyYzYxL3JldmlzaW9ucy96aWdwcy1hMTJjNjEtMDAwMDEtY3Q4\""
    \\}
;

/// The service after a deploy of an image tag nobody has: terminalCondition CONDITION_FAILED with reason REVISION_FAILED, latestReady on the old revision, latestCreated the broken one. HTTP 200.
pub const service_failed_status = 200;
pub const service_failed =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/services/zigps-a12c61",
    \\ "uid": "04e92968-6f59-40e9-9831-cedf530c1df5",
    \\ "generation": "2",
    \\ "createTime": "2026-10-19T19:32:31.428729Z",
    \\ "updateTime": "2026-10-19T19:32:38.637093Z",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "ingress": "INGRESS_TRAFFIC_ALL",
    \\ "launchStage": "GA",
    \\ "template": {
    \\  "timeout": "300s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "containers": [
    \\   {
    \\    "image": "us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag",
    \\    "resources": {
    \\     "limits": {
    \\      "memory": "512Mi",
    \\      "cpu": "1000m"
    \\     },
    \\     "cpuIdle": true
    \\    },
    \\    "ports": [
    \\     {
    \\      "name": "http1",
    \\      "containerPort": 8080
    \\     }
    \\    ],
    \\    "startupProbe": {
    \\     "timeoutSeconds": 240,
    \\     "periodSeconds": 240,
    \\     "failureThreshold": 1,
    \\     "tcpSocket": {
    \\      "port": 8080
    \\     }
    \\    }
    \\   }
    \\  ],
    \\  "maxInstanceRequestConcurrency": 80
    \\ },
    \\ "traffic": [
    \\  {
    \\   "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\   "percent": 100
    \\  }
    \\ ],
    \\ "scaling": {
    \\  "maxInstanceCount": 20
    \\ },
    \\ "urls": [
    \\  "https://zigps-a12c61-82150720798.us-central1.run.app",
    \\  "https://zigps-a12c61-el44yx5gia-uc.a.run.app"
    \\ ],
    \\ "sshEnabled": false,
    \\ "observedGeneration": "2",
    \\ "terminalCondition": {
    \\  "type": "Ready",
    \\  "state": "CONDITION_FAILED",
    \\  "message": "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.",
    \\  "lastTransitionTime": "2026-10-19T19:32:39.040916Z",
    \\  "reason": "REVISION_FAILED"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "type": "RoutesReady",
    \\   "state": "CONDITION_FAILED",
    \\   "message": "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.",
    \\   "lastTransitionTime": "2026-10-19T19:32:39.040916Z",
    \\   "reason": "REVISION_FAILED"
    \\  },
    \\  {
    \\   "type": "ConfigurationsReady",
    \\   "state": "CONDITION_FAILED",
    \\   "message": "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.",
    \\   "lastTransitionTime": "2026-10-19T19:32:38.959783Z"
    \\  }
    \\ ],
    \\ "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8",
    \\ "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00002-qmv",
    \\ "trafficStatuses": [
    \\  {
    \\   "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\   "revision": "zigps-a12c61-00001-ct8",
    \\   "percent": 100
    \\  }
    \\ ],
    \\ "uri": "https://zigps-a12c61-el44yx5gia-uc.a.run.app",
    \\ "etag": "\"CNbg2dYGEIiJ5a8C/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtYTEyYzYx\""
    \\}
;

/// Both revisions after the bad deploy, newest first: the broken one's Ready CONDITION_FAILED. HTTP 200.
pub const revisions_failed_status = 200;
pub const revisions_failed =
    \\{
    \\ "revisions": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00002-qmv",
    \\   "uid": "1fd73471-248f-4959-9d10-0c7a9bf2928c",
    \\   "generation": "1",
    \\   "createTime": "2026-10-19T19:32:38.785328Z",
    \\   "updateTime": "2026-10-19T19:32:38.785328Z",
    \\   "launchStage": "GA",
    \\   "service": "zigps-a12c61",
    \\   "timeout": "300s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "containers": [
    \\    {
    \\     "name": "hello-1",
    \\     "image": "us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag",
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      },
    \\      "cpuIdle": true
    \\     },
    \\     "ports": [
    \\      {
    \\       "name": "http1",
    \\       "containerPort": 8080
    \\      }
    \\     ],
    \\     "startupProbe": {
    \\      "timeoutSeconds": 240,
    \\      "periodSeconds": 240,
    \\      "failureThreshold": 1,
    \\      "tcpSocket": {
    \\       "port": 8080
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "conditions": [
    \\    {
    \\     "type": "Ready",
    \\     "state": "CONDITION_FAILED",
    \\     "message": "Image 'us-docker.pkg.dev/cloudrun/container/hello:zigps-no-such-tag' not found.",
    \\     "lastTransitionTime": "2026-10-19T19:32:38.903177Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "1",
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&resource=cloud_run_revision/service_name/zigps-a12c61/revision_name/zigps-a12c61-00002-qmv&advancedFilter=resource.type%3D%22cloud_run_revision%22%0Aresource.labels.service_name%3D%22zigps-a12c61%22%0Aresource.labels.revision_name%3D%22zigps-a12c61-00002-qmv%22",
    \\   "maxInstanceRequestConcurrency": 80,
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CNbg2dYGEIDPvPYC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtYTEyYzYxL3JldmlzaW9ucy96aWdwcy1hMTJjNjEtMDAwMDItcW12\""
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8",
    \\   "uid": "7b3c68ab-f3f7-4279-86a6-fc1f3887ec3b",
    \\   "generation": "1",
    \\   "createTime": "2026-10-19T19:32:31.559921Z",
    \\   "updateTime": "2026-10-19T19:32:31.559921Z",
    \\   "launchStage": "GA",
    \\   "service": "zigps-a12c61",
    \\   "timeout": "300s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "containers": [
    \\    {
    \\     "name": "hello-1",
    \\     "image": "us-docker.pkg.dev/cloudrun/container/hello@sha256:efd04605322d5d1ce6b1fd3dfc63a9c1fb2b99c97194ec316c0df0fd8f5dcf01",
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      },
    \\      "cpuIdle": true
    \\     },
    \\     "ports": [
    \\      {
    \\       "name": "http1",
    \\       "containerPort": 8080
    \\      }
    \\     ],
    \\     "startupProbe": {
    \\      "timeoutSeconds": 240,
    \\      "periodSeconds": 240,
    \\      "failureThreshold": 1,
    \\      "tcpSocket": {
    \\       "port": 8080
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "conditions": [
    \\    {
    \\     "type": "Ready",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Deploying revision succeeded in 3.77s.",
    \\     "lastTransitionTime": "2026-10-19T19:32:35.332279Z"
    \\    },
    \\    {
    \\     "type": "Active",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "lastTransitionTime": "2026-10-19T19:32:35.495138Z",
    \\     "severity": "INFO"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioning imported containers completed in 1.92s. Checking container health. This will wait for up to 4m for the configured startup probe, including an initial delay of 0s.",
    \\     "lastTransitionTime": "2026-10-19T19:32:34.687395Z"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Container image import completed.",
    \\     "lastTransitionTime": "2026-10-19T19:32:32.763566Z"
    \\    },
    \\    {
    \\     "type": "ContainerHealthy",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Containers became healthy.",
    \\     "lastTransitionTime": "2026-10-19T19:32:35.270482Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "1",
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&resource=cloud_run_revision/service_name/zigps-a12c61/revision_name/zigps-a12c61-00001-ct8&advancedFilter=resource.type%3D%22cloud_run_revision%22%0Aresource.labels.service_name%3D%22zigps-a12c61%22%0Aresource.labels.revision_name%3D%22zigps-a12c61-00001-ct8%22",
    \\   "maxInstanceRequestConcurrency": 80,
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CM_g2dYGEOju_ooC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtYTEyYzYxL3JldmlzaW9ucy96aWdwcy1hMTJjNjEtMDAwMDEtY3Q4\""
    \\  }
    \\ ]
    \\}
;

/// The services list with one service. HTTP 200.
pub const services_list_status = 200;
pub const services_list =
    \\{
    \\ "services": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/services/zigps-a12c61",
    \\   "uid": "04e92968-6f59-40e9-9831-cedf530c1df5",
    \\   "generation": "1",
    \\   "labels": {
    \\    "zigps": "probe"
    \\   },
    \\   "createTime": "2026-10-19T19:32:31.428729Z",
    \\   "updateTime": "2026-10-19T19:32:31.428729Z",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "ingress": "INGRESS_TRAFFIC_ALL",
    \\   "launchStage": "GA",
    \\   "template": {
    \\    "timeout": "300s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\      "resources": {
    \\       "limits": {
    \\        "memory": "512Mi",
    \\        "cpu": "1000m"
    \\       },
    \\       "cpuIdle": true
    \\      },
    \\      "ports": [
    \\       {
    \\        "name": "http1",
    \\        "containerPort": 8080
    \\       }
    \\      ],
    \\      "startupProbe": {
    \\       "timeoutSeconds": 240,
    \\       "periodSeconds": 240,
    \\       "failureThreshold": 1,
    \\       "tcpSocket": {
    \\        "port": 8080
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxInstanceRequestConcurrency": 80
    \\   },
    \\   "traffic": [
    \\    {
    \\     "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\     "percent": 100
    \\    }
    \\   ],
    \\   "scaling": {
    \\    "maxInstanceCount": 20
    \\   },
    \\   "urls": [
    \\    "https://zigps-a12c61-82150720798.us-central1.run.app",
    \\    "https://zigps-a12c61-el44yx5gia-uc.a.run.app"
    \\   ],
    \\   "sshEnabled": false,
    \\   "observedGeneration": "1",
    \\   "terminalCondition": {
    \\    "type": "Ready",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-19T19:32:36.762898Z"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "RoutesReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "lastTransitionTime": "2026-10-19T19:32:36.714800Z"
    \\    },
    \\    {
    \\     "type": "ConfigurationsReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "lastTransitionTime": "2026-10-19T19:32:35.381282Z"
    \\    }
    \\   ],
    \\   "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8",
    \\   "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-a12c61/revisions/zigps-a12c61-00001-ct8",
    \\   "trafficStatuses": [
    \\    {
    \\     "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\     "revision": "zigps-a12c61-00001-ct8",
    \\     "percent": 100
    \\    }
    \\   ],
    \\   "uri": "https://zigps-a12c61-el44yx5gia-uc.a.run.app",
    \\   "etag": "\"CM_g2dYGEKjFt8wB/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtYTEyYzYx\""
    \\  }
    \\ ]
    \\}
;

/// v1 locations.list beside v2 on the same host, trimmed to three of the 43 answered. HTTP 200.
pub const locations_v1_status = 200;
pub const locations_v1 =
    \\{
    \\ "locations": [
    \\  {
    \\   "name": "extractctl/locations/africa-south1",
    \\   "labels": {
    \\    "run.googleapis.com/supportsEphemeralDisk": "true"
    \\   },
    \\   "locationId": "africa-south1",
    \\   "displayName": "Johannesburg"
    \\  },
    \\  {
    \\   "name": "extractctl/locations/asia-east1",
    \\   "labels": {
    \\    "run.googleapis.com/supportsEphemeralDisk": "true"
    \\   },
    \\   "locationId": "asia-east1",
    \\   "displayName": "Taiwan"
    \\  },
    \\  {
    \\   "name": "extractctl/locations/asia-east2",
    \\   "labels": {
    \\    "run.googleapis.com/supportsPzs": "true",
    \\    "run.googleapis.com/supportsEphemeralDisk": "true"
    \\   },
    \\   "locationId": "asia-east2",
    \\   "displayName": "Hong Kong"
    \\  }
    \\ ]
    \\}
;

/// services.list in the location '-': not refused, an unreachable array while nothing listed. HTTP 200.
pub const services_dash_status = 200;
pub const services_dash =
    \\{
    \\ "unreachable": [
    \\  "europe-west15",
    \\  "me-central2",
    \\  "us-central2",
    \\  "us-east7",
    \\  "us-west8"
    \\ ]
    \\}
;

/// services.list in a location that is no region. HTTP 400.
pub const location_bogus_status = 400;
pub const location_bogus =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "The request has errors",
    \\  "status": "INVALID_ARGUMENT",
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\    "fieldViolations": [
    \\     {
    \\      "field": "region",
    \\      "description": "Unsupported region us-fake1"
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ }
    \\}
;

/// services.get of a service nobody has. HTTP 404.
pub const service_unknown_status = 404;
pub const service_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Resource 'zigps-nobody' of kind 'SERVICE' in region 'us-central1' in project 'extractctl' does not exist.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;
/// A job never run: no executionCount, latestCreatedExecution an empty object, Ready. HTTP 200.
pub const job_fresh_status = 200;
pub const job_fresh =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick",
    \\ "uid": "606ea566-45d0-42ca-80a0-cd94f1314e78",
    \\ "generation": "1",
    \\ "labels": {
    \\  "zigps": "probe"
    \\ },
    \\ "createTime": "2026-10-21T12:14:38.395057Z",
    \\ "updateTime": "2026-10-21T12:14:38.395057Z",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "launchStage": "GA",
    \\ "template": {
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "2000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  }
    \\ },
    \\ "observedGeneration": "1",
    \\ "terminalCondition": {
    \\  "type": "Ready",
    \\  "state": "CONDITION_SUCCEEDED",
    \\  "lastTransitionTime": "2026-10-21T12:14:38.713447Z"
    \\ },
    \\ "latestCreatedExecution": {},
    \\ "etag": "\"CK7Z4tYGEOiusLwB/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctcXVpY2s\""
    \\}
;

/// The quick job after two runs: its latest EXECUTION_SUCCEEDED, the id alone as its name. HTTP 200.
pub const job_succeeded_status = 200;
pub const job_succeeded =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick",
    \\ "uid": "606ea566-45d0-42ca-80a0-cd94f1314e78",
    \\ "generation": "1",
    \\ "labels": {
    \\  "zigps": "probe"
    \\ },
    \\ "createTime": "2026-10-21T12:14:38.395057Z",
    \\ "updateTime": "2026-10-21T12:14:38.395057Z",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "launchStage": "GA",
    \\ "template": {
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "2000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  }
    \\ },
    \\ "observedGeneration": "1",
    \\ "terminalCondition": {
    \\  "type": "Ready",
    \\  "state": "CONDITION_SUCCEEDED"
    \\ },
    \\ "executionCount": 2,
    \\ "latestCreatedExecution": {
    \\  "name": "zigps-6b8297-quick-l4ffj",
    \\  "createTime": "2026-10-21T12:17:01.331509Z",
    \\  "completionTime": "2026-10-21T12:18:38.818609Z",
    \\  "completionStatus": "EXECUTION_SUCCEEDED"
    \\ },
    \\ "etag": "\"CK7Z4tYGEOiusLwB/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctcXVpY2s\""
    \\}
;

/// The failing job after its run: latest EXECUTION_FAILED, the job itself still Ready. HTTP 200.
pub const job_failed_status = 200;
pub const job_failed =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-fail",
    \\ "uid": "c69e4789-9491-495d-9108-187ab877f9de",
    \\ "generation": "1",
    \\ "labels": {
    \\  "zigps": "probe"
    \\ },
    \\ "createTime": "2026-10-21T12:14:41.960287Z",
    \\ "updateTime": "2026-10-21T12:14:41.960287Z",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "launchStage": "GA",
    \\ "template": {
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job",
    \\     "env": [
    \\      {
    \\       "name": "FAIL_RATE",
    \\       "value": "1"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  }
    \\ },
    \\ "observedGeneration": "1",
    \\ "terminalCondition": {
    \\  "type": "Ready",
    \\  "state": "CONDITION_SUCCEEDED"
    \\ },
    \\ "executionCount": 1,
    \\ "latestCreatedExecution": {
    \\  "name": "zigps-6b8297-fail-ldg9n",
    \\  "createTime": "2026-10-21T12:18:41.823428Z",
    \\  "completionTime": "2026-10-21T12:20:16.978865Z",
    \\  "completionStatus": "EXECUTION_FAILED"
    \\ },
    \\ "etag": "\"CLHZ4tYGEJii88kD/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctZmFpbA\""
    \\}
;

/// The slow job after both its runs were cancelled: latest EXECUTION_CANCELLED. HTTP 200.
pub const job_cancelled_status = 200;
pub const job_cancelled =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow",
    \\ "uid": "feb25cb4-a104-4149-866d-fa064b70e3f0",
    \\ "generation": "1",
    \\ "labels": {
    \\  "zigps": "probe"
    \\ },
    \\ "createTime": "2026-10-21T12:14:40.184668Z",
    \\ "updateTime": "2026-10-21T12:14:40.184668Z",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "launchStage": "GA",
    \\ "template": {
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "600000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  }
    \\ },
    \\ "observedGeneration": "1",
    \\ "terminalCondition": {
    \\  "type": "Ready",
    \\  "state": "CONDITION_SUCCEEDED"
    \\ },
    \\ "executionCount": 2,
    \\ "latestCreatedExecution": {
    \\  "name": "zigps-6b8297-slow-54x76",
    \\  "createTime": "2026-10-21T12:21:56.969041Z",
    \\  "completionTime": "2026-10-21T12:22:24.232785Z",
    \\  "completionStatus": "EXECUTION_CANCELLED"
    \\ },
    \\ "etag": "\"CLDZ4tYGEOCeh1g/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdw\""
    \\}
;

/// jobs.list with pageSize=1: one job and a token. HTTP 200.
pub const jobs_page_status = 200;
pub const jobs_page =
    \\{
    \\ "jobs": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-fail",
    \\   "uid": "c69e4789-9491-495d-9108-187ab877f9de",
    \\   "generation": "1",
    \\   "labels": {
    \\    "zigps": "probe"
    \\   },
    \\   "createTime": "2026-10-21T12:14:41.960287Z",
    \\   "updateTime": "2026-10-21T12:14:41.960287Z",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "launchStage": "GA",
    \\   "template": {
    \\    "taskCount": 1,
    \\    "template": {
    \\     "containers": [
    \\      {
    \\       "image": "us-docker.pkg.dev/cloudrun/container/job",
    \\       "env": [
    \\        {
    \\         "name": "FAIL_RATE",
    \\         "value": "1"
    \\        }
    \\       ],
    \\       "resources": {
    \\        "limits": {
    \\         "memory": "512Mi",
    \\         "cpu": "1000m"
    \\        }
    \\       }
    \\      }
    \\     ],
    \\     "maxRetries": 0,
    \\     "timeout": "900s",
    \\     "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\     "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\    }
    \\   },
    \\   "observedGeneration": "1",
    \\   "terminalCondition": {
    \\    "type": "Ready",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:14:42.259836Z"
    \\   },
    \\   "latestCreatedExecution": {},
    \\   "etag": "\"CLHZ4tYGEJii88kD/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctZmFpbA\""
    \\  }
    \\ ],
    \\ "nextPageToken": "AAZeWLEDXVw"
    \\}
;

/// jobs.list in location '-', refused. HTTP 400.
pub const jobs_dash_status = 400;
pub const jobs_dash =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Request contains an invalid argument.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// jobs.list in us-fake1, refused as a permission. HTTP 403.
pub const jobs_made_up_region_status = 403;
pub const jobs_made_up_region =
    \\{
    \\ "error": {
    \\  "code": 403,
    \\  "message": "Permission denied on 'locations/us-fake1' (or it may not exist)",
    \\  "status": "PERMISSION_DENIED"
    \\ }
    \\}
;

/// jobs.get of a job nobody has. HTTP 404.
pub const job_unknown_status = 404;
pub const job_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Resource 'zigps-nobody' of kind 'JOB' in region 'us-central1' in project 'extractctl' does not exist.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A running execution: Started succeeded, Completed reconciling, runningCount 1. HTTP 200.
pub const execution_running_status = 200;
pub const execution_running =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb",
    \\ "uid": "9e511d68-6917-4f63-8ffe-6a39621cd47a",
    \\ "generation": "1",
    \\ "createTime": "2026-10-21T12:20:22.572863Z",
    \\ "updateTime": "2026-10-21T12:20:22.572863Z",
    \\ "launchStage": "GA",
    \\ "job": "zigps-6b8297-slow",
    \\ "parallelism": 1,
    \\ "taskCount": 1,
    \\ "template": {
    \\  "containers": [
    \\   {
    \\    "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\    "env": [
    \\     {
    \\      "name": "SLEEP_MS",
    \\      "value": "600000"
    \\     }
    \\    ],
    \\    "resources": {
    \\     "limits": {
    \\      "cpu": "1000m",
    \\      "memory": "512Mi"
    \\     }
    \\    }
    \\   }
    \\  ],
    \\  "maxRetries": 0,
    \\  "timeout": "900s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\ },
    \\ "reconciling": true,
    \\ "conditions": [
    \\  {
    \\   "type": "Started",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Started deployed execution in 1m29.86s.",
    \\   "lastTransitionTime": "2026-10-21T12:21:53.156957Z"
    \\  },
    \\  {
    \\   "type": "Retry",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "System will retry after 00:05 from lastTransitionTime for polling interval",
    \\   "lastTransitionTime": "2026-10-21T12:21:56.014461Z",
    \\   "severity": "INFO",
    \\   "reason": "WAITING_FOR_OPERATION"
    \\  },
    \\  {
    \\   "type": "Completed",
    \\   "state": "CONDITION_RECONCILING",
    \\   "message": "Waiting for execution to complete.",
    \\   "lastTransitionTime": "2026-10-21T12:21:56.014461Z"
    \\  },
    \\  {
    \\   "type": "ContainerReady",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Imported container image.",
    \\   "lastTransitionTime": "2026-10-21T12:20:23.172585Z"
    \\  },
    \\  {
    \\   "type": "ResourcesAvailable",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Provisioned imported containers.",
    \\   "lastTransitionTime": "2026-10-21T12:20:23.295665Z"
    \\  }
    \\ ],
    \\ "observedGeneration": "1",
    \\ "runningCount": 1,
    \\ "startTime": "2026-10-21T12:20:32.389504Z",
    \\ "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-nlzdb%22",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "etag": "\"CIbc4tYGEJjklJEC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LW5semRi\""
    \\}
;

/// An execution cancelled while running, 16 s later: Completed failed, CANCELLED. HTTP 200.
pub const execution_cancelled_status = 200;
pub const execution_cancelled =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb",
    \\ "uid": "9e511d68-6917-4f63-8ffe-6a39621cd47a",
    \\ "generation": "3",
    \\ "createTime": "2026-10-21T12:20:22.572863Z",
    \\ "completionTime": "2026-10-21T12:22:09.802197Z",
    \\ "updateTime": "2026-10-21T12:21:58.037555Z",
    \\ "launchStage": "GA",
    \\ "job": "zigps-6b8297-slow",
    \\ "parallelism": 1,
    \\ "taskCount": 1,
    \\ "template": {
    \\  "containers": [
    \\   {
    \\    "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\    "env": [
    \\     {
    \\      "name": "SLEEP_MS",
    \\      "value": "600000"
    \\     }
    \\    ],
    \\    "resources": {
    \\     "limits": {
    \\      "cpu": "1000m",
    \\      "memory": "512Mi"
    \\     }
    \\    }
    \\   }
    \\  ],
    \\  "maxRetries": 0,
    \\  "timeout": "900s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "type": "Started",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Started deployed execution in 1m29.86s.",
    \\   "lastTransitionTime": "2026-10-21T12:21:53.156957Z"
    \\  },
    \\  {
    \\   "type": "Completed",
    \\   "state": "CONDITION_FAILED",
    \\   "message": "Cancelled by user.",
    \\   "lastTransitionTime": "2026-10-21T12:22:09.802197Z",
    \\   "executionReason": "CANCELLED"
    \\  },
    \\  {
    \\   "type": "ContainerReady",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Imported container image.",
    \\   "lastTransitionTime": "2026-10-21T12:20:23.172585Z"
    \\  },
    \\  {
    \\   "type": "ResourcesAvailable",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Provisioned imported containers.",
    \\   "lastTransitionTime": "2026-10-21T12:20:23.295665Z"
    \\  }
    \\ ],
    \\ "observedGeneration": "3",
    \\ "startTime": "2026-10-21T12:20:32.389504Z",
    \\ "cancelledCount": 1,
    \\ "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-nlzdb%22",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "etag": "\"CObc4tYGELiW9BE/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LW5semRi\""
    \\}
;

/// An execution cancelled 0.4 s after its run, before it started: Completed failed, CANCELLED, and never a completionTime. HTTP 200.
pub const execution_cancelled_pending_status = 200;
pub const execution_cancelled_pending =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-4f3d2d-pending/executions/zigps-4f3d2d-pending-x485c",
    \\ "uid": "9beed1b0-d660-4399-93a0-ea4f63bbe804",
    \\ "generation": "2",
    \\ "createTime": "2026-10-21T12:29:17.527980Z",
    \\ "updateTime": "2026-10-21T12:29:17.978957Z",
    \\ "launchStage": "GA",
    \\ "job": "zigps-4f3d2d-pending",
    \\ "parallelism": 1,
    \\ "taskCount": 1,
    \\ "template": {
    \\  "containers": [
    \\   {
    \\    "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\    "env": [
    \\     {
    \\      "name": "SLEEP_MS",
    \\      "value": "600000"
    \\     }
    \\    ],
    \\    "resources": {
    \\     "limits": {
    \\      "cpu": "1000m",
    \\      "memory": "512Mi"
    \\     }
    \\    }
    \\   }
    \\  ],
    \\  "maxRetries": 0,
    \\  "timeout": "900s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "type": "Started",
    \\   "state": "CONDITION_RECONCILING",
    \\   "message": "Container image import in progress.",
    \\   "lastTransitionTime": "2026-10-21T12:29:18.052284Z"
    \\  },
    \\  {
    \\   "type": "Completed",
    \\   "state": "CONDITION_FAILED",
    \\   "message": "Cancelled by user.",
    \\   "lastTransitionTime": "2026-10-21T12:29:18.115906Z",
    \\   "executionReason": "CANCELLED"
    \\  }
    \\ ],
    \\ "observedGeneration": "2",
    \\ "cancelledCount": 1,
    \\ "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-4f3d2d-pending%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-4f3d2d-pending-x485c%22",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "etag": "\"CJ3g4tYGEMjl5tID/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy00ZjNkMmQtcGVuZGluZy9leGVjdXRpb25zL3ppZ3BzLTRmM2QyZC1wZW5kaW5nLXg0ODVj\""
    \\}
;

/// The slow job's two executions, newest first. HTTP 200.
pub const executions_page_status = 200;
pub const executions_page =
    \\{
    \\ "executions": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-54x76",
    \\   "uid": "b0b831e8-b6cd-4514-9a85-a9a8a6288e0e",
    \\   "generation": "2",
    \\   "createTime": "2026-10-21T12:21:56.969041Z",
    \\   "completionTime": "2026-10-21T12:22:24.232785Z",
    \\   "updateTime": "2026-10-21T12:22:15.572406Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-slow",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "SLEEP_MS",
    \\        "value": "600000"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 27.45s.",
    \\     "lastTransitionTime": "2026-10-21T12:22:25.120732Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_FAILED",
    \\     "message": "Cancelled by user.",
    \\     "lastTransitionTime": "2026-10-21T12:22:24.232785Z",
    \\     "executionReason": "CANCELLED"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image.",
    \\     "lastTransitionTime": "2026-10-21T12:21:57.560619Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:21:57.671927Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "2",
    \\   "startTime": "2026-10-21T12:22:04.414962Z",
    \\   "cancelledCount": 1,
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-54x76%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CPfc4tYGEPDx-JAC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LTU0eDc2\""
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb",
    \\   "uid": "9e511d68-6917-4f63-8ffe-6a39621cd47a",
    \\   "generation": "3",
    \\   "createTime": "2026-10-21T12:20:22.572863Z",
    \\   "completionTime": "2026-10-21T12:22:09.802197Z",
    \\   "updateTime": "2026-10-21T12:21:58.037555Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-slow",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "SLEEP_MS",
    \\        "value": "600000"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 1m29.86s.",
    \\     "lastTransitionTime": "2026-10-21T12:21:53.156957Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_FAILED",
    \\     "message": "Cancelled by user.",
    \\     "lastTransitionTime": "2026-10-21T12:22:09.802197Z",
    \\     "executionReason": "CANCELLED"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image.",
    \\     "lastTransitionTime": "2026-10-21T12:20:23.172585Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:20:23.295665Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "3",
    \\   "startTime": "2026-10-21T12:20:32.389504Z",
    \\   "cancelledCount": 1,
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-nlzdb%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CObc4tYGELiW9BE/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LW5semRi\""
    \\  }
    \\ ]
    \\}
;

/// executions.list with pageSize=1: one and a token. HTTP 200.
pub const executions_page_one_status = 200;
pub const executions_page_one =
    \\{
    \\ "executions": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-54x76",
    \\   "uid": "b0b831e8-b6cd-4514-9a85-a9a8a6288e0e",
    \\   "generation": "2",
    \\   "createTime": "2026-10-21T12:21:56.969041Z",
    \\   "completionTime": "2026-10-21T12:22:24.232785Z",
    \\   "updateTime": "2026-10-21T12:22:15.572406Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-slow",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "SLEEP_MS",
    \\        "value": "600000"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 27.45s.",
    \\     "lastTransitionTime": "2026-10-21T12:22:25.120732Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_FAILED",
    \\     "message": "Cancelled by user.",
    \\     "lastTransitionTime": "2026-10-21T12:22:24.232785Z",
    \\     "executionReason": "CANCELLED"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image.",
    \\     "lastTransitionTime": "2026-10-21T12:21:57.560619Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:21:57.671927Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "2",
    \\   "startTime": "2026-10-21T12:22:04.414962Z",
    \\   "cancelledCount": 1,
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-54x76%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CPfc4tYGEPDx-JAC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LTU0eDc2\""
    \\  }
    \\ ],
    \\ "nextPageToken": "AAZeWMVryz8"
    \\}
;

/// executions.list of jobs/-: every job's executions. HTTP 200.
pub const executions_dash_status = 200;
pub const executions_dash =
    \\{
    \\ "executions": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-54x76",
    \\   "uid": "b0b831e8-b6cd-4514-9a85-a9a8a6288e0e",
    \\   "generation": "2",
    \\   "createTime": "2026-10-21T12:21:56.969041Z",
    \\   "completionTime": "2026-10-21T12:22:24.232785Z",
    \\   "updateTime": "2026-10-21T12:22:15.572406Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-slow",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "SLEEP_MS",
    \\        "value": "600000"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 27.45s.",
    \\     "lastTransitionTime": "2026-10-21T12:22:25.120732Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_FAILED",
    \\     "message": "Cancelled by user.",
    \\     "lastTransitionTime": "2026-10-21T12:22:24.232785Z",
    \\     "executionReason": "CANCELLED"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image.",
    \\     "lastTransitionTime": "2026-10-21T12:21:57.560619Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:21:57.671927Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "2",
    \\   "startTime": "2026-10-21T12:22:04.414962Z",
    \\   "cancelledCount": 1,
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-54x76%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CPfc4tYGEPDx-JAC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LTU0eDc2\""
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb",
    \\   "uid": "9e511d68-6917-4f63-8ffe-6a39621cd47a",
    \\   "generation": "3",
    \\   "createTime": "2026-10-21T12:20:22.572863Z",
    \\   "completionTime": "2026-10-21T12:22:09.802197Z",
    \\   "updateTime": "2026-10-21T12:21:58.037555Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-slow",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "SLEEP_MS",
    \\        "value": "600000"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 1m29.86s.",
    \\     "lastTransitionTime": "2026-10-21T12:21:53.156957Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_FAILED",
    \\     "message": "Cancelled by user.",
    \\     "lastTransitionTime": "2026-10-21T12:22:09.802197Z",
    \\     "executionReason": "CANCELLED"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image.",
    \\     "lastTransitionTime": "2026-10-21T12:20:23.172585Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:20:23.295665Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "3",
    \\   "startTime": "2026-10-21T12:20:32.389504Z",
    \\   "cancelledCount": 1,
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-nlzdb%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CObc4tYGELiW9BE/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LW5semRi\""
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-fail/executions/zigps-6b8297-fail-ldg9n",
    \\   "uid": "527b6286-f2ff-469c-83b1-1ba2138e22f9",
    \\   "generation": "1",
    \\   "createTime": "2026-10-21T12:18:41.823428Z",
    \\   "completionTime": "2026-10-21T12:20:16.978865Z",
    \\   "updateTime": "2026-10-21T12:18:41.823428Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-fail",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "FAIL_RATE",
    \\        "value": "1"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 1m27.38s.",
    \\     "lastTransitionTime": "2026-10-21T12:20:10.001920Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_FAILED",
    \\     "message": "Task zigps-6b8297-fail-ldg9n-task0 failed with exit code: 1 and message: The container exited with an error.",
    \\     "lastTransitionTime": "2026-10-21T12:20:16.978865Z",
    \\     "executionReason": "NON_ZERO_EXIT_CODE"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image.",
    \\     "lastTransitionTime": "2026-10-21T12:18:42.496548Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:18:42.617183Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "1",
    \\   "failedCount": 1,
    \\   "startTime": "2026-10-21T12:18:54.387639Z",
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-fail%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-fail-ldg9n%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CKHb4tYGEKCH0ogD/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctZmFpbC9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1mYWlsLWxkZzlu\""
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-l4ffj",
    \\   "uid": "6d4db278-4bed-45b6-a901-f95781b83407",
    \\   "generation": "1",
    \\   "createTime": "2026-10-21T12:17:01.331509Z",
    \\   "completionTime": "2026-10-21T12:18:38.818609Z",
    \\   "updateTime": "2026-10-21T12:17:01.331509Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-quick",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "SLEEP_MS",
    \\        "value": "2000"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 1m29.01s.",
    \\     "lastTransitionTime": "2026-10-21T12:18:31.149752Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Execution completed successfully in 1m24.42s.",
    \\     "lastTransitionTime": "2026-10-21T12:18:38.818609Z"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image.",
    \\     "lastTransitionTime": "2026-10-21T12:17:02.028194Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:17:02.134260Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "1",
    \\   "succeededCount": 1,
    \\   "startTime": "2026-10-21T12:17:14.389864Z",
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-quick%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-quick-l4ffj%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CL3a4tYGEIjaiZ4B/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctcXVpY2svZXhlY3V0aW9ucy96aWdwcy02YjgyOTctcXVpY2stbDRmZmo\""
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-p64qb",
    \\   "uid": "4efe98ba-c003-4ee1-9947-d6eb3fa82582",
    \\   "generation": "1",
    \\   "createTime": "2026-10-21T12:14:45.068529Z",
    \\   "completionTime": "2026-10-21T12:16:58.758819Z",
    \\   "updateTime": "2026-10-21T12:14:45.068529Z",
    \\   "launchStage": "GA",
    \\   "job": "zigps-6b8297-quick",
    \\   "parallelism": 1,
    \\   "taskCount": 1,
    \\   "template": {
    \\    "containers": [
    \\     {
    \\      "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\      "env": [
    \\       {
    \\        "name": "SLEEP_MS",
    \\        "value": "2000"
    \\       }
    \\      ],
    \\      "resources": {
    \\       "limits": {
    \\        "cpu": "1000m",
    \\        "memory": "512Mi"
    \\       }
    \\      }
    \\     }
    \\    ],
    \\    "maxRetries": 0,
    \\    "timeout": "900s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\   },
    \\   "conditions": [
    \\    {
    \\     "type": "Started",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Started deployed execution in 2m4.5s.",
    \\     "lastTransitionTime": "2026-10-21T12:16:51.400945Z"
    \\    },
    \\    {
    \\     "type": "Completed",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Execution completed successfully in 1m56.38s.",
    \\     "lastTransitionTime": "2026-10-21T12:16:58.758819Z"
    \\    },
    \\    {
    \\     "type": "ContainerReady",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Imported container image in 1.71s.",
    \\     "lastTransitionTime": "2026-10-21T12:14:46.781816Z"
    \\    },
    \\    {
    \\     "type": "ResourcesAvailable",
    \\     "state": "CONDITION_SUCCEEDED",
    \\     "message": "Provisioned imported containers.",
    \\     "lastTransitionTime": "2026-10-21T12:14:46.892449Z"
    \\    }
    \\   ],
    \\   "observedGeneration": "1",
    \\   "succeededCount": 1,
    \\   "startTime": "2026-10-21T12:15:02.369796Z",
    \\   "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-quick%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-quick-p64qb%22",
    \\   "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "etag": "\"CLXZ4tYGEOjW1iA/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctcXVpY2svZXhlY3V0aW9ucy96aWdwcy02YjgyOTctcXVpY2stcDY0cWI\""
    \\  }
    \\ ]
    \\}
;

/// executions.get of an execution nobody has. HTTP 404.
pub const execution_unknown_status = 404;
pub const execution_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Resource 'zigps-nobody-abcde' of kind 'EXECUTION' in region 'us-central1' in project 'extractctl' does not exist.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A run's answer: an operation, not done, its metadata the new Execution. HTTP 200.
pub const operation_run_status = 200;
pub const operation_run =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/6d1e1e32-b691-4524-b5e5-53a92d560cce",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Execution",
    \\  "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-l4ffj",
    \\  "uid": "6d4db278-4bed-45b6-a901-f95781b83407",
    \\  "generation": "1",
    \\  "createTime": "2026-10-21T12:17:01.331509Z",
    \\  "updateTime": "2026-10-21T12:17:01.331509Z",
    \\  "launchStage": "GA",
    \\  "job": "zigps-6b8297-quick",
    \\  "parallelism": 1,
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "2000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "cpu": "1000m",
    \\       "memory": "512Mi"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  },
    \\  "reconciling": true,
    \\  "conditions": [
    \\   {
    \\    "type": "Completed",
    \\    "state": "CONDITION_PENDING"
    \\   }
    \\  ],
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-quick%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-quick-l4ffj%22",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"CL3a4tYGEIjaiZ4B/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctcXVpY2svZXhlY3V0aW9ucy96aWdwcy02YjgyOTctcXVpY2stbDRmZmo\""
    \\ }
    \\}
;

/// The quick run's operation once its execution ended: done, its response the succeeded Execution. HTTP 200.
pub const operation_run_done_status = 200;
pub const operation_run_done =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/6d1e1e32-b691-4524-b5e5-53a92d560cce",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Execution",
    \\  "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-l4ffj",
    \\  "uid": "6d4db278-4bed-45b6-a901-f95781b83407",
    \\  "generation": "1",
    \\  "createTime": "2026-10-21T12:17:01.331509Z",
    \\  "completionTime": "2026-10-21T12:18:38.818609Z",
    \\  "updateTime": "2026-10-21T12:17:01.331509Z",
    \\  "launchStage": "GA",
    \\  "job": "zigps-6b8297-quick",
    \\  "parallelism": 1,
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "2000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "cpu": "1000m",
    \\       "memory": "512Mi"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "Started",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Started deployed execution in 1m29.01s.",
    \\    "lastTransitionTime": "2026-10-21T12:18:31.149752Z"
    \\   },
    \\   {
    \\    "type": "Retry",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "System will retry after 00:00 from lastTransitionTime for attempt 0.",
    \\    "lastTransitionTime": "2026-10-21T12:18:40.088205Z",
    \\    "severity": "INFO",
    \\    "reason": "IMMEDIATE_RETRY"
    \\   },
    \\   {
    \\    "type": "Completed",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Execution completed successfully in 1m24.42s.",
    \\    "lastTransitionTime": "2026-10-21T12:18:38.818609Z"
    \\   },
    \\   {
    \\    "type": "ContainerReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Imported container image.",
    \\    "lastTransitionTime": "2026-10-21T12:17:02.028194Z"
    \\   },
    \\   {
    \\    "type": "ResourcesAvailable",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Provisioned imported containers.",
    \\    "lastTransitionTime": "2026-10-21T12:17:02.134260Z"
    \\   }
    \\  ],
    \\  "observedGeneration": "1",
    \\  "succeededCount": 1,
    \\  "startTime": "2026-10-21T12:17:14.389864Z",
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-quick%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-quick-l4ffj%22",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"CL3a4tYGEIjaiZ4B/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctcXVpY2svZXhlY3V0aW9ucy96aWdwcy02YjgyOTctcXVpY2stbDRmZmo\""
    \\ },
    \\ "done": true,
    \\ "response": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Execution",
    \\  "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-quick/executions/zigps-6b8297-quick-l4ffj",
    \\  "uid": "6d4db278-4bed-45b6-a901-f95781b83407",
    \\  "generation": "1",
    \\  "createTime": "2026-10-21T12:17:01.331509Z",
    \\  "completionTime": "2026-10-21T12:18:38.818609Z",
    \\  "updateTime": "2026-10-21T12:17:01.331509Z",
    \\  "launchStage": "GA",
    \\  "job": "zigps-6b8297-quick",
    \\  "parallelism": 1,
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "2000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "cpu": "1000m",
    \\       "memory": "512Mi"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "Started",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Started deployed execution in 1m29.01s.",
    \\    "lastTransitionTime": "2026-10-21T12:18:31.149752Z"
    \\   },
    \\   {
    \\    "type": "Retry",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "System will retry after 00:00 from lastTransitionTime for attempt 0.",
    \\    "lastTransitionTime": "2026-10-21T12:18:40.088205Z",
    \\    "severity": "INFO",
    \\    "reason": "IMMEDIATE_RETRY"
    \\   },
    \\   {
    \\    "type": "Completed",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Execution completed successfully in 1m24.42s.",
    \\    "lastTransitionTime": "2026-10-21T12:18:38.818609Z"
    \\   },
    \\   {
    \\    "type": "ContainerReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Imported container image.",
    \\    "lastTransitionTime": "2026-10-21T12:17:02.028194Z"
    \\   },
    \\   {
    \\    "type": "ResourcesAvailable",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Provisioned imported containers.",
    \\    "lastTransitionTime": "2026-10-21T12:17:02.134260Z"
    \\   }
    \\  ],
    \\  "observedGeneration": "1",
    \\  "succeededCount": 1,
    \\  "startTime": "2026-10-21T12:17:14.389864Z",
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-quick%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-quick-l4ffj%22",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"CL3a4tYGEIjaiZ4B/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctcXVpY2svZXhlY3V0aW9ucy96aWdwcy02YjgyOTctcXVpY2stbDRmZmo\""
    \\ }
    \\}
;

/// The failing run's operation at its end: done, with an error (code 10) and the failed Execution. HTTP 200.
pub const operation_run_failed_status = 200;
pub const operation_run_failed =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/fff6510c-41d7-4c0d-acf8-3c61c315ad97",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Execution",
    \\  "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-fail/executions/zigps-6b8297-fail-ldg9n",
    \\  "uid": "527b6286-f2ff-469c-83b1-1ba2138e22f9",
    \\  "generation": "1",
    \\  "createTime": "2026-10-21T12:18:41.823428Z",
    \\  "completionTime": "2026-10-21T12:20:16.978865Z",
    \\  "updateTime": "2026-10-21T12:18:41.823428Z",
    \\  "launchStage": "GA",
    \\  "job": "zigps-6b8297-fail",
    \\  "parallelism": 1,
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\     "env": [
    \\      {
    \\       "name": "FAIL_RATE",
    \\       "value": "1"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "cpu": "1000m",
    \\       "memory": "512Mi"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "Started",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Started deployed execution in 1m27.38s.",
    \\    "lastTransitionTime": "2026-10-21T12:20:10.001920Z"
    \\   },
    \\   {
    \\    "type": "Completed",
    \\    "state": "CONDITION_FAILED",
    \\    "message": "Task zigps-6b8297-fail-ldg9n-task0 failed with exit code: 1 and message: The container exited with an error.",
    \\    "lastTransitionTime": "2026-10-21T12:20:16.978865Z",
    \\    "executionReason": "NON_ZERO_EXIT_CODE"
    \\   },
    \\   {
    \\    "type": "ContainerReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Imported container image.",
    \\    "lastTransitionTime": "2026-10-21T12:18:42.496548Z"
    \\   },
    \\   {
    \\    "type": "ResourcesAvailable",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Provisioned imported containers.",
    \\    "lastTransitionTime": "2026-10-21T12:18:42.617183Z"
    \\   }
    \\  ],
    \\  "observedGeneration": "1",
    \\  "failedCount": 1,
    \\  "startTime": "2026-10-21T12:18:54.387639Z",
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-fail%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-fail-ldg9n%22",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"CKHb4tYGEKCH0ogD/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctZmFpbC9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1mYWlsLWxkZzlu\""
    \\ },
    \\ "done": true,
    \\ "error": {
    \\  "code": 10,
    \\  "message": "Task zigps-6b8297-fail-ldg9n-task0 failed with exit code: 1 and message: The container exited with an error."
    \\ }
    \\}
;

/// A cancel's answer: an operation, not done, its metadata the Execution. HTTP 200.
pub const operation_cancel_status = 200;
pub const operation_cancel =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/471dda5c-c10f-43c8-b818-40acd761f21d",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Execution",
    \\  "name": "projects/extractctl/locations/us-central1/jobs/zigps-6b8297-slow/executions/zigps-6b8297-slow-nlzdb",
    \\  "uid": "9e511d68-6917-4f63-8ffe-6a39621cd47a",
    \\  "generation": "2",
    \\  "createTime": "2026-10-21T12:20:22.572863Z",
    \\  "updateTime": "2026-10-21T12:21:57.796788Z",
    \\  "launchStage": "GA",
    \\  "job": "zigps-6b8297-slow",
    \\  "parallelism": 1,
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "600000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "cpu": "1000m",
    \\       "memory": "512Mi"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  },
    \\  "reconciling": true,
    \\  "conditions": [
    \\   {
    \\    "type": "Started",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Started deployed execution in 1m29.86s.",
    \\    "lastTransitionTime": "2026-10-21T12:21:53.156957Z"
    \\   },
    \\   {
    \\    "type": "Retry",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "System will retry after 00:05 from lastTransitionTime for polling interval",
    \\    "lastTransitionTime": "2026-10-21T12:21:56.014461Z",
    \\    "severity": "INFO",
    \\    "reason": "WAITING_FOR_OPERATION"
    \\   },
    \\   {
    \\    "type": "Completed",
    \\    "state": "CONDITION_RECONCILING",
    \\    "message": "Waiting for execution to complete.",
    \\    "lastTransitionTime": "2026-10-21T12:21:56.014461Z"
    \\   },
    \\   {
    \\    "type": "ContainerReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Imported container image.",
    \\    "lastTransitionTime": "2026-10-21T12:20:23.172585Z"
    \\   },
    \\   {
    \\    "type": "ResourcesAvailable",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Provisioned imported containers.",
    \\    "lastTransitionTime": "2026-10-21T12:20:23.295665Z"
    \\   }
    \\  ],
    \\  "observedGeneration": "1",
    \\  "runningCount": 1,
    \\  "startTime": "2026-10-21T12:20:32.389504Z",
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-6b8297-slow%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-6b8297-slow-nlzdb%22",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"COXc4tYGEKCK-PsC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy02YjgyOTctc2xvdy9leGVjdXRpb25zL3ppZ3BzLTZiODI5Ny1zbG93LW5semRi\""
    \\ }
    \\}
;

/// A traffic change's operation at its end, 4 s later: done, its response the Service. HTTP 200.
pub const operation_traffic_done_status = 200;
pub const operation_traffic_done =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/93cc9a58-a067-49d0-a318-74faf477cf18",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Service",
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-6b8297",
    \\  "uid": "d086478c-38dd-4518-8819-1e5a6effbaab",
    \\  "generation": "3",
    \\  "labels": {
    \\   "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-21T12:22:26.679350Z",
    \\  "updateTime": "2026-10-21T12:22:45.008189Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\   "timeout": "300s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\     "env": [
    \\      {
    \\       "name": "ZIGPS",
    \\       "value": "2"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      },
    \\      "cpuIdle": true
    \\     },
    \\     "ports": [
    \\      {
    \\       "name": "http1",
    \\       "containerPort": 8080
    \\      }
    \\     ],
    \\     "startupProbe": {
    \\      "timeoutSeconds": 240,
    \\      "periodSeconds": 240,
    \\      "failureThreshold": 1,
    \\      "tcpSocket": {
    \\       "port": 8080
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6b8297-00001-527",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "scaling": {
    \\   "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\   "https://zigps-6b8297-82150720798.us-central1.run.app",
    \\   "https://zigps-6b8297-el44yx5gia-uc.a.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "3",
    \\  "terminalCondition": {
    \\   "type": "Ready",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "lastTransitionTime": "2026-10-21T12:22:48.415271Z"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "RoutesReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:22:48.371424Z"
    \\   },
    \\   {
    \\    "type": "ConfigurationsReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:22:34.050655Z"
    \\   }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "trafficStatuses": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6b8297-00001-527",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "uri": "https://zigps-6b8297-el44yx5gia-uc.a.run.app",
    \\  "etag": "\"CJXd4tYGEMjo8wM/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtNmI4Mjk3\""
    \\ },
    \\ "done": true,
    \\ "response": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Service",
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-6b8297",
    \\  "uid": "d086478c-38dd-4518-8819-1e5a6effbaab",
    \\  "generation": "3",
    \\  "labels": {
    \\   "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-21T12:22:26.679350Z",
    \\  "updateTime": "2026-10-21T12:22:45.008189Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\   "timeout": "300s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\     "env": [
    \\      {
    \\       "name": "ZIGPS",
    \\       "value": "2"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      },
    \\      "cpuIdle": true
    \\     },
    \\     "ports": [
    \\      {
    \\       "name": "http1",
    \\       "containerPort": 8080
    \\      }
    \\     ],
    \\     "startupProbe": {
    \\      "timeoutSeconds": 240,
    \\      "periodSeconds": 240,
    \\      "failureThreshold": 1,
    \\      "tcpSocket": {
    \\       "port": 8080
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6b8297-00001-527",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "scaling": {
    \\   "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\   "https://zigps-6b8297-82150720798.us-central1.run.app",
    \\   "https://zigps-6b8297-el44yx5gia-uc.a.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "3",
    \\  "terminalCondition": {
    \\   "type": "Ready",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "lastTransitionTime": "2026-10-21T12:22:48.415271Z"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "RoutesReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:22:48.371424Z"
    \\   },
    \\   {
    \\    "type": "ConfigurationsReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:22:34.050655Z"
    \\   }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "trafficStatuses": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6b8297-00001-527",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "uri": "https://zigps-6b8297-el44yx5gia-uc.a.run.app",
    \\  "etag": "\"CJXd4tYGEMjo8wM/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtNmI4Mjk3\""
    \\ }
    \\}
;

/// A traffic change to a revision the service lacks: done, with an error (code 9). HTTP 200.
pub const operation_traffic_failed_status = 200;
pub const operation_traffic_failed =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/b94b55b5-5fe5-4781-80b9-3527170e0fbe",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Service",
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-6b8297",
    \\  "uid": "d086478c-38dd-4518-8819-1e5a6effbaab",
    \\  "generation": "6",
    \\  "labels": {
    \\   "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-21T12:22:26.679350Z",
    \\  "updateTime": "2026-10-21T12:22:59.165115Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\   "timeout": "300s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\     "env": [
    \\      {
    \\       "name": "ZIGPS",
    \\       "value": "2"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      },
    \\      "cpuIdle": true
    \\     },
    \\     "ports": [
    \\      {
    \\       "name": "http1",
    \\       "containerPort": 8080
    \\      }
    \\     ],
    \\     "startupProbe": {
    \\      "timeoutSeconds": 240,
    \\      "periodSeconds": 240,
    \\      "failureThreshold": 1,
    \\      "tcpSocket": {
    \\       "port": 8080
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6b8297-00009-zzz",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "scaling": {
    \\   "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\   "https://zigps-6b8297-82150720798.us-central1.run.app",
    \\   "https://zigps-6b8297-el44yx5gia-uc.a.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "6",
    \\  "terminalCondition": {
    \\   "type": "Ready",
    \\   "state": "CONDITION_FAILED",
    \\   "message": "Revision 'zigps-6b8297-00009-zzz' does not exist or is deleted. Update all traffic to route to currently available revisions.",
    \\   "lastTransitionTime": "2026-10-21T12:22:59.272760Z"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "RoutesReady",
    \\    "state": "CONDITION_FAILED",
    \\    "message": "Revision 'zigps-6b8297-00009-zzz' does not exist or is deleted. Update all traffic to route to currently available revisions.",
    \\    "lastTransitionTime": "2026-10-21T12:22:59.272760Z"
    \\   },
    \\   {
    \\    "type": "ConfigurationsReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Deploying revision succeeded in 1.9s.",
    \\    "lastTransitionTime": "2026-10-21T12:22:57.578157Z",
    \\    "revisionReason": "RETIRED"
    \\   }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "trafficStatuses": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6b8297-00001-527",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "uri": "https://zigps-6b8297-el44yx5gia-uc.a.run.app",
    \\  "etag": "\"CKPd4tYGEPjo3U4/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtNmI4Mjk3\""
    \\ },
    \\ "done": true,
    \\ "error": {
    \\  "code": 9,
    \\  "message": "Revision 'zigps-6b8297-00009-zzz' does not exist or is deleted. Update all traffic to route to currently available revisions."
    \\ }
    \\}
;

/// operations.get of an operation nobody has. HTTP 404.
pub const operation_unknown_status = 404;
pub const operation_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "00000000-0000-0000-0000-000000000000",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;
/// A run with a run.readonly token: every write was refused so. HTTP 403.
pub const write_scope_refused_status = 403;
pub const write_scope_refused =
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
    \\     "service": "run.googleapis.com",
    \\     "method": "google.cloud.run.v2.Jobs.RunJob"
    \\    }
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A cancel of an execution already cancelled; succeeded and failed ones answered the same. HTTP 400.
pub const cancel_not_running_status = 400;
pub const cancel_not_running =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Execution 'zigps-6b8297-slow-nlzdb' cannot be cancelled because it is not running.",
    \\  "status": "FAILED_PRECONDITION"
    \\ }
    \\}
;

/// A traffic change under updateMask=traffic,etag with a stale etag. HTTP 409.
pub const traffic_stale_etag_status = 409;
pub const traffic_stale_etag =
    \\{
    \\ "error": {
    \\  "code": 409,
    \\  "message": "Conflict for resource 'zigps-8e3f3f': version '1792585476717971' was specified but current version is '1792585482447477'.",
    \\  "status": "ABORTED"
    \\ }
    \\}
;

/// A traffic change to another service's revision, refused at once. HTTP 400.
pub const traffic_other_service_status = 400;
pub const traffic_other_service =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "spec.traffic.revision_name[0]: Revision target 'zigps-other-00001-abc' invalid. Expected a revision prefixed with 'zigps-6b8297-'.",
    \\  "status": "INVALID_ARGUMENT",
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\    "fieldViolations": [
    \\     {
    \\      "field": "spec.traffic.revision_name[0]",
    \\      "description": "Revision target 'zigps-other-00001-abc' invalid. Expected a revision prefixed with 'zigps-6b8297-'."
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A traffic change's answer: an operation, not done, its metadata the Service with the asked traffic. HTTP 200.
pub const operation_traffic_status = 200;
pub const operation_traffic =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/93cc9a58-a067-49d0-a318-74faf477cf18",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Service",
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-6b8297",
    \\  "uid": "d086478c-38dd-4518-8819-1e5a6effbaab",
    \\  "generation": "3",
    \\  "labels": {
    \\   "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-21T12:22:26.679350Z",
    \\  "updateTime": "2026-10-21T12:22:45.008189Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\   "timeout": "300s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\     "env": [
    \\      {
    \\       "name": "ZIGPS",
    \\       "value": "2"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      },
    \\      "cpuIdle": true
    \\     },
    \\     "ports": [
    \\      {
    \\       "name": "http1",
    \\       "containerPort": 8080
    \\      }
    \\     ],
    \\     "startupProbe": {
    \\      "timeoutSeconds": 240,
    \\      "periodSeconds": 240,
    \\      "failureThreshold": 1,
    \\      "tcpSocket": {
    \\       "port": 8080
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6b8297-00001-527",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "scaling": {
    \\   "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\   "https://zigps-6b8297-82150720798.us-central1.run.app",
    \\   "https://zigps-6b8297-el44yx5gia-uc.a.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "2",
    \\  "terminalCondition": {
    \\   "type": "Ready",
    \\   "state": "CONDITION_PENDING",
    \\   "lastTransitionTime": "2026-10-21T12:22:43.169189Z"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "RoutesReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:22:43.092203Z"
    \\   },
    \\   {
    \\    "type": "ConfigurationsReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:22:34.050655Z"
    \\   }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-6b8297/revisions/zigps-6b8297-00002-v7z",
    \\  "trafficStatuses": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\    "revision": "zigps-6b8297-00002-v7z",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "uri": "https://zigps-6b8297-el44yx5gia-uc.a.run.app",
    \\  "reconciling": true,
    \\  "etag": "\"CJXd4tYGEMjo8wM/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtNmI4Mjk3\""
    \\ }
    \\}
;

/// A validateOnly traffic change under the etag mask: an operation, nothing changed. HTTP 200.
pub const operation_traffic_validate_status = 200;
pub const operation_traffic_validate =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/f6d4e600-8967-4ba0-8ad0-ff90c3e9021f",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Service",
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-6ff401",
    \\  "uid": "1d56f452-e8a3-4ed1-98fe-6b33e7740e0c",
    \\  "generation": "4",
    \\  "labels": {
    \\   "zigps": "probe2"
    \\  },
    \\  "createTime": "2026-10-21T12:25:45.674930Z",
    \\  "updateTime": "2026-10-21T12:26:08.774121Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\   "timeout": "300s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\     "env": [
    \\      {
    \\       "name": "ZIGPS",
    \\       "value": "2"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "memory": "512Mi",
    \\       "cpu": "1000m"
    \\      },
    \\      "cpuIdle": true
    \\     },
    \\     "ports": [
    \\      {
    \\       "name": "http1",
    \\       "containerPort": 8080
    \\      }
    \\     ],
    \\     "startupProbe": {
    \\      "timeoutSeconds": 240,
    \\      "periodSeconds": 240,
    \\      "failureThreshold": 1,
    \\      "tcpSocket": {
    \\       "port": 8080
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6ff401-00002-wwm",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "scaling": {
    \\   "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\   "https://zigps-6ff401-82150720798.us-central1.run.app",
    \\   "https://zigps-6ff401-el44yx5gia-uc.a.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "3",
    \\  "terminalCondition": {
    \\   "type": "Ready",
    \\   "state": "CONDITION_PENDING",
    \\   "lastTransitionTime": "2026-10-21T12:26:07.207261Z"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "RoutesReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-21T12:26:07.151978Z"
    \\   },
    \\   {
    \\    "type": "ConfigurationsReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Deploying revision succeeded in 7.36s.",
    \\    "lastTransitionTime": "2026-10-21T12:26:07.306654Z",
    \\    "revisionReason": "RETIRED"
    \\   }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-6ff401/revisions/zigps-6ff401-00002-wwm",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-6ff401/revisions/zigps-6ff401-00002-wwm",
    \\  "trafficStatuses": [
    \\   {
    \\    "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
    \\    "revision": "zigps-6ff401-00001-g5f",
    \\    "percent": 100
    \\   }
    \\  ],
    \\  "uri": "https://zigps-6ff401-el44yx5gia-uc.a.run.app",
    \\  "reconciling": true,
    \\  "etag": "\"CODe4tYGEKjMkPEC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtNmZmNDAx\""
    \\ }
    \\}
;
/// An execution cancelled as its task started: Completed failed with no reason, a task counted cancelled. HTTP 200.
pub const execution_cancel_raced_status = 200;
pub const execution_cancel_raced =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-0b36f5-cancel/executions/zigps-0b36f5-cancel-vtff9",
    \\ "uid": "29540b3c-839a-4c33-b599-e5e115dfce0b",
    \\ "generation": "2",
    \\ "createTime": "2026-10-21T13:38:04.405864Z",
    \\ "completionTime": "2026-10-21T13:38:42.993701Z",
    \\ "updateTime": "2026-10-21T13:38:35.072066Z",
    \\ "launchStage": "GA",
    \\ "job": "zigps-0b36f5-cancel",
    \\ "parallelism": 1,
    \\ "taskCount": 1,
    \\ "template": {
    \\  "containers": [
    \\   {
    \\    "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\    "env": [
    \\     {
    \\      "name": "SLEEP_MS",
    \\      "value": "600000"
    \\     }
    \\    ],
    \\    "resources": {
    \\     "limits": {
    \\      "cpu": "1000m",
    \\      "memory": "512Mi"
    \\     }
    \\    }
    \\   }
    \\  ],
    \\  "maxRetries": 0,
    \\  "timeout": "900s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\ },
    \\ "conditions": [
    \\  {
    \\   "type": "Started",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Started deployed execution in 28.62s.",
    \\   "lastTransitionTime": "2026-10-21T13:38:33.712202Z"
    \\  },
    \\  {
    \\   "type": "Completed",
    \\   "state": "CONDITION_FAILED",
    \\   "lastTransitionTime": "2026-10-21T13:38:42.993701Z"
    \\  },
    \\  {
    \\   "type": "ContainerReady",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Imported container image.",
    \\   "lastTransitionTime": "2026-10-21T13:38:04.979021Z"
    \\  },
    \\  {
    \\   "type": "ResourcesAvailable",
    \\   "state": "CONDITION_SUCCEEDED",
    \\   "message": "Provisioned imported containers.",
    \\   "lastTransitionTime": "2026-10-21T13:38:05.088973Z"
    \\  }
    \\ ],
    \\ "observedGeneration": "2",
    \\ "startTime": "2026-10-21T13:38:14.426193Z",
    \\ "cancelledCount": 1,
    \\ "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-0b36f5-cancel%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-0b36f5-cancel-vtff9%22",
    \\ "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "etag": "\"CNuA49YGENDHriI/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy0wYjM2ZjUtY2FuY2VsL2V4ZWN1dGlvbnMvemlncHMtMGIzNmY1LWNhbmNlbC12dGZmOQ\""
    \\}
;

/// That cancel's operation: done, failing with code 2, as the run's did. HTTP 200.
pub const operation_cancel_raced_status = 200;
pub const operation_cancel_raced =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/operations/0f4e2a3a-bf02-4030-9daf-88d3b338b44b",
    \\ "metadata": {
    \\  "@type": "type.googleapis.com/google.cloud.run.v2.Execution",
    \\  "name": "projects/extractctl/locations/us-central1/jobs/zigps-0b36f5-cancel/executions/zigps-0b36f5-cancel-vtff9",
    \\  "uid": "29540b3c-839a-4c33-b599-e5e115dfce0b",
    \\  "generation": "2",
    \\  "createTime": "2026-10-21T13:38:04.405864Z",
    \\  "completionTime": "2026-10-21T13:38:42.993701Z",
    \\  "updateTime": "2026-10-21T13:38:35.072066Z",
    \\  "launchStage": "GA",
    \\  "job": "zigps-0b36f5-cancel",
    \\  "parallelism": 1,
    \\  "taskCount": 1,
    \\  "template": {
    \\   "containers": [
    \\    {
    \\     "image": "us-docker.pkg.dev/cloudrun/container/job@sha256:611099e80127f3c779e6fda0a5982818ff9fd03a228f9457cd3a1b1fed9f1589",
    \\     "env": [
    \\      {
    \\       "name": "SLEEP_MS",
    \\       "value": "600000"
    \\      }
    \\     ],
    \\     "resources": {
    \\      "limits": {
    \\       "cpu": "1000m",
    \\       "memory": "512Mi"
    \\      }
    \\     }
    \\    }
    \\   ],
    \\   "maxRetries": 0,
    \\   "timeout": "900s",
    \\   "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\   "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2"
    \\  },
    \\  "conditions": [
    \\   {
    \\    "type": "Started",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Started deployed execution in 28.62s.",
    \\    "lastTransitionTime": "2026-10-21T13:38:33.712202Z"
    \\   },
    \\   {
    \\    "type": "Completed",
    \\    "state": "CONDITION_FAILED",
    \\    "lastTransitionTime": "2026-10-21T13:38:42.993701Z"
    \\   },
    \\   {
    \\    "type": "ContainerReady",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Imported container image.",
    \\    "lastTransitionTime": "2026-10-21T13:38:04.979021Z"
    \\   },
    \\   {
    \\    "type": "ResourcesAvailable",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "message": "Provisioned imported containers.",
    \\    "lastTransitionTime": "2026-10-21T13:38:05.088973Z"
    \\   }
    \\  ],
    \\  "observedGeneration": "2",
    \\  "startTime": "2026-10-21T13:38:14.426193Z",
    \\  "cancelledCount": 1,
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&advancedFilter=resource.type%3D%22cloud_run_job%22%0Aresource.labels.job_name%3D%22zigps-0b36f5-cancel%22%0Aresource.labels.location%3D%22us-central1%22%0Alabels.%22run.googleapis.com/execution_name%22%3D%22zigps-0b36f5-cancel-vtff9%22",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"CNuA49YGENDHriI/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy0wYjM2ZjUtY2FuY2VsL2V4ZWN1dGlvbnMvemlncHMtMGIzNmY1LWNhbmNlbC12dGZmOQ\""
    \\ },
    \\ "done": true,
    \\ "error": {
    \\  "code": 2,
    \\  "message": "Unspecified error."
    \\ }
    \\}
;

// The IAM reads, measured on 2026-10-23 in milestone 0 of the IAM reads
// spec (`_tmp/iam-reads-m0/`), as the same account: verbatim but for a
// final line break (that probe kept the raw answers).

/// `GET .../services/S:getIamPolicy?options.requestedPolicyVersion=3` of a new service, under `run.readonly`, 2026-10-23 (`_tmp/iam-reads-m0/`): no bindings. A service that does not exist answered the same. HTTP 200.
pub const iam_service_policy_new_status = 200;
pub const iam_service_policy_new =
    \\{
    \\  "etag": "ACAB"
    \\}
;

/// `getIamPolicy` at location `-`. HTTP 403.
pub const iam_service_policy_dash_status = 403;
pub const iam_service_policy_dash =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Permission denied on 'locations/-' (or it may not exist)",
    \\    "status": "PERMISSION_DENIED"
    \\  }
    \\}
;

/// `getIamPolicy` under `cloud-platform.read-only`, a scope Cloud Run does not take. HTTP 403.
pub const iam_service_policy_scope_status = 403;
pub const iam_service_policy_scope =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Request had insufficient authentication scopes.",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "method": "google.cloud.run.v2.Services.GetIamPolicy",
    \\          "service": "run.googleapis.com"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
;

/// `testIamPermissions` of six on the service: the five held, sorted by name. HTTP 200.
pub const iam_service_test_held_status = 200;
pub const iam_service_test_held =
    \\{
    \\  "permissions": [
    \\    "run.routes.invoke",
    \\    "run.services.delete",
    \\    "run.services.get",
    \\    "run.services.getIamPolicy",
    \\    "run.services.update"
    \\  ]
    \\}
;

/// `testIamPermissions` of `pubsub.topics.get` and `bigquery.datasets.get` on a service. HTTP 400.
pub const iam_service_test_other_service_status = 400;
pub const iam_service_test_other_service =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Failed to test IAM permissions: Permission pubsub.topics.get is not valid for this resource.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `testIamPermissions` on a service that does not exist: answered as if it did. HTTP 200.
pub const iam_service_test_missing_status = 200;
pub const iam_service_test_missing =
    \\{
    \\  "permissions": [
    \\    "run.services.get"
    \\  ]
    \\}
;

/// `testIamPermissions` of 101 on a service. HTTP 400.
pub const iam_service_test_too_many_status = 400;
pub const iam_service_test_too_many =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Failed to test IAM permissions: The number of permissions (101) is greater than the maximum allowed (100).",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// `setIamPolicy` as an account without `run.services.setIamPolicy`, for the record: the policy stayed empty. HTTP 403.
pub const iam_service_set_refused_status = 403;
pub const iam_service_set_refused =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Permission 'run.services.setIamPolicy' denied on resource 'projects/extractctl/locations/us-central1/services/zigps-02667a' (or resource may not exist).",
    \\    "status": "PERMISSION_DENIED"
    \\  }
    \\}
;

/// `getIamPolicy` of a new job, under `run.readonly`. HTTP 200.
pub const iam_job_policy_status = 200;
pub const iam_job_policy =
    \\{
    \\  "etag": "ACAB"
    \\}
;

/// `testIamPermissions` of five on the job: the four held, sorted by name. HTTP 200.
pub const iam_job_test_held_status = 200;
pub const iam_job_test_held =
    \\{
    \\  "permissions": [
    \\    "run.executions.cancel",
    \\    "run.jobs.get",
    \\    "run.jobs.run",
    \\    "run.jobs.runWithOverrides"
    \\  ]
    \\}
;

// The settings, measured on 2026-10-23 in milestone 0 of the Cloud Run
// settings spec (`_tmp/run-settings-m0/`): verbatim but for a final
// line break (that probe kept the raw answers).

/// A service deployed with every setting in scope, 2026-10-23 (`_tmp/run-settings-m0/`, run 3c3b48): ingress internal and load balancer, default URL disabled (so no uri or urls), service scaling, and a template with env, secrets, resources, a secret volume and an empty dir, scaling, concurrency, timeout, gen2, direct VPC egress and session affinity. HTTP 200.
pub const settings_service_full_status = 200;
pub const settings_service_full =
    \\{
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-full",
    \\  "uid": "c4f7110e-c31d-49fd-92cf-fefce5f2a4b2",
    \\  "generation": "1",
    \\  "labels": {
    \\    "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-23T14:27:09.189673Z",
    \\  "updateTime": "2026-10-23T14:27:09.189673Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
    \\  "launchStage": "GA",
    \\  "template": {
    \\    "scaling": {
    \\      "maxInstanceCount": 3
    \\    },
    \\    "vpcAccess": {
    \\      "egress": "PRIVATE_RANGES_ONLY",
    \\      "networkInterfaces": [
    \\        {
    \\          "network": "default",
    \\          "subnetwork": "default",
    \\          "tags": [
    \\            "zigps"
    \\          ]
    \\        }
    \\      ]
    \\    },
    \\    "timeout": "120s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "containers": [
    \\      {
    \\        "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\        "env": [
    \\          {
    \\            "name": "PLAIN",
    \\            "value": "hello"
    \\          },
    \\          {
    \\            "name": "EMPTY",
    \\            "value": ""
    \\          },
    \\          {
    \\            "name": "FROM_SECRET",
    \\            "valueSource": {
    \\              "secretKeyRef": {
    \\                "secret": "zigps-3c3b48",
    \\                "version": "latest"
    \\              }
    \\            }
    \\          },
    \\          {
    \\            "name": "FROM_SECRET_FULL",
    \\            "valueSource": {
    \\              "secretKeyRef": {
    \\                "secret": "projects/extractctl/secrets/zigps-3c3b48",
    \\                "version": "1"
    \\              }
    \\            }
    \\          }
    \\        ],
    \\        "resources": {
    \\          "limits": {
    \\            "cpu": "2",
    \\            "memory": "1Gi"
    \\          },
    \\          "startupCpuBoost": true
    \\        },
    \\        "ports": [
    \\          {
    \\            "name": "http1",
    \\            "containerPort": 8080
    \\          }
    \\        ],
    \\        "volumeMounts": [
    \\          {
    \\            "name": "sec",
    \\            "mountPath": "/secrets"
    \\          },
    \\          {
    \\            "name": "scratch",
    \\            "mountPath": "/scratch"
    \\          }
    \\        ],
    \\        "startupProbe": {
    \\          "timeoutSeconds": 240,
    \\          "periodSeconds": 240,
    \\          "failureThreshold": 1,
    \\          "tcpSocket": {
    \\            "port": 8080
    \\          }
    \\        }
    \\      }
    \\    ],
    \\    "volumes": [
    \\      {
    \\        "name": "sec",
    \\        "secret": {
    \\          "secret": "zigps-3c3b48",
    \\          "items": [
    \\            {
    \\              "path": "value",
    \\              "version": "latest"
    \\            }
    \\          ],
    \\          "defaultMode": 292
    \\        }
    \\      },
    \\      {
    \\        "name": "scratch",
    \\        "emptyDir": {
    \\          "medium": "MEMORY",
    \\          "sizeLimit": "64Mi"
    \\        }
    \\      }
    \\    ],
    \\    "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2",
    \\    "maxInstanceRequestConcurrency": 40,
    \\    "sessionAffinity": true
    \\  },
    \\  "traffic": [
    \\    {
    \\      "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\      "percent": 100
    \\    }
    \\  ],
    \\  "scaling": {
    \\    "scalingMode": "AUTOMATIC",
    \\    "maxInstanceCount": 5
    \\  },
    \\  "defaultUriDisabled": true,
    \\  "sshEnabled": false,
    \\  "observedGeneration": "1",
    \\  "terminalCondition": {
    \\    "type": "Ready",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-23T14:27:16.793193Z"
    \\  },
    \\  "conditions": [
    \\    {
    \\      "type": "RoutesReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:16.764483Z"
    \\    },
    \\    {
    \\      "type": "ConfigurationsReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:09.992877Z"
    \\    }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-full/revisions/zigps-3c3b48-full-00001-cld",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-full/revisions/zigps-3c3b48-full-00001-cld",
    \\  "trafficStatuses": [
    \\    {
    \\      "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\      "revision": "zigps-3c3b48-full-00001-cld",
    \\      "percent": 100
    \\    }
    \\  ],
    \\  "etag": "\"CL3d7dYGEKjcuFo/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtM2MzYjQ4LWZ1bGw\""
    \\}
;

/// That service's revision: the same settings, its container named and its image pinned. HTTP 200.
pub const settings_revision_full_status = 200;
pub const settings_revision_full =
    \\{
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-full/revisions/zigps-3c3b48-full-00001-cld",
    \\  "uid": "c00da09d-5629-4290-ba05-94443d6c78f9",
    \\  "generation": "1",
    \\  "createTime": "2026-10-23T14:27:09.294820Z",
    \\  "updateTime": "2026-10-23T14:27:09.294820Z",
    \\  "launchStage": "GA",
    \\  "service": "zigps-3c3b48-full",
    \\  "scaling": {
    \\    "maxInstanceCount": 3
    \\  },
    \\  "vpcAccess": {
    \\    "egress": "PRIVATE_RANGES_ONLY",
    \\    "networkInterfaces": [
    \\      {
    \\        "network": "default",
    \\        "subnetwork": "default",
    \\        "tags": [
    \\          "zigps"
    \\        ]
    \\      }
    \\    ]
    \\  },
    \\  "timeout": "120s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "containers": [
    \\    {
    \\      "name": "hello-1",
    \\      "image": "us-docker.pkg.dev/cloudrun/container/hello@sha256:efd04605322d5d1ce6b1fd3dfc63a9c1fb2b99c97194ec316c0df0fd8f5dcf01",
    \\      "env": [
    \\        {
    \\          "name": "PLAIN",
    \\          "value": "hello"
    \\        },
    \\        {
    \\          "name": "EMPTY",
    \\          "value": ""
    \\        },
    \\        {
    \\          "name": "FROM_SECRET",
    \\          "valueSource": {
    \\            "secretKeyRef": {
    \\              "secret": "zigps-3c3b48",
    \\              "version": "latest"
    \\            }
    \\          }
    \\        },
    \\        {
    \\          "name": "FROM_SECRET_FULL",
    \\          "valueSource": {
    \\            "secretKeyRef": {
    \\              "secret": "projects/extractctl/secrets/zigps-3c3b48",
    \\              "version": "1"
    \\            }
    \\          }
    \\        }
    \\      ],
    \\      "resources": {
    \\        "limits": {
    \\          "cpu": "2",
    \\          "memory": "1Gi"
    \\        },
    \\        "startupCpuBoost": true
    \\      },
    \\      "ports": [
    \\        {
    \\          "name": "http1",
    \\          "containerPort": 8080
    \\        }
    \\      ],
    \\      "volumeMounts": [
    \\        {
    \\          "name": "sec",
    \\          "mountPath": "/secrets"
    \\        },
    \\        {
    \\          "name": "scratch",
    \\          "mountPath": "/scratch"
    \\        }
    \\      ],
    \\      "startupProbe": {
    \\        "timeoutSeconds": 240,
    \\        "periodSeconds": 240,
    \\        "failureThreshold": 1,
    \\        "tcpSocket": {
    \\          "port": 8080
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "volumes": [
    \\    {
    \\      "name": "sec",
    \\      "secret": {
    \\        "secret": "zigps-3c3b48",
    \\        "items": [
    \\          {
    \\            "path": "value",
    \\            "version": "latest"
    \\          }
    \\        ],
    \\        "defaultMode": 292
    \\      }
    \\    },
    \\    {
    \\      "name": "scratch",
    \\      "emptyDir": {
    \\        "medium": "MEMORY",
    \\        "sizeLimit": "64Mi"
    \\      }
    \\    }
    \\  ],
    \\  "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2",
    \\  "conditions": [
    \\    {
    \\      "type": "Ready",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Deploying revision succeeded in 6.14s.",
    \\      "lastTransitionTime": "2026-10-23T14:27:15.431014Z"
    \\    },
    \\    {
    \\      "type": "Active",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:15.592624Z",
    \\      "severity": "INFO"
    \\    },
    \\    {
    \\      "type": "ResourcesAvailable",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Provisioning imported containers completed in 1.75s. Checking container health. This will wait for up to 4m for the configured startup probe, including an initial delay of 0s.",
    \\      "lastTransitionTime": "2026-10-23T14:27:11.644799Z"
    \\    },
    \\    {
    \\      "type": "ContainerReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Container image import completed.",
    \\      "lastTransitionTime": "2026-10-23T14:27:09.897751Z"
    \\    },
    \\    {
    \\      "type": "ContainerHealthy",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Containers became healthy.",
    \\      "lastTransitionTime": "2026-10-23T14:27:15.366776Z"
    \\    }
    \\  ],
    \\  "observedGeneration": "1",
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&resource=cloud_run_revision/service_name/zigps-3c3b48-full/revision_name/zigps-3c3b48-full-00001-cld&advancedFilter=resource.type%3D%22cloud_run_revision%22%0Aresource.labels.service_name%3D%22zigps-3c3b48-full%22%0Aresource.labels.revision_name%3D%22zigps-3c3b48-full-00001-cld%22",
    \\  "maxInstanceRequestConcurrency": 40,
    \\  "sessionAffinity": true,
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"CL3d7dYGEKCxyowB/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtM2MzYjQ4LWZ1bGwvcmV2aXNpb25zL3ppZ3BzLTNjM2I0OC1mdWxsLTAwMDAxLWNsZA\""
    \\}
;

/// A service deployed with an image alone: production's defaults filled in (512Mi, 1000m, cpuIdle, port 8080, a startup probe, 300 s, 80) and a service scaling of 20. HTTP 200.
pub const settings_service_plain_status = 200;
pub const settings_service_plain =
    \\{
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-plain",
    \\  "uid": "ea63946f-9279-4af2-a124-f1e39060c83f",
    \\  "generation": "1",
    \\  "labels": {
    \\    "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-23T14:27:20.071863Z",
    \\  "updateTime": "2026-10-23T14:27:20.071863Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\    "timeout": "300s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "containers": [
    \\      {
    \\        "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\        "resources": {
    \\          "limits": {
    \\            "memory": "512Mi",
    \\            "cpu": "1000m"
    \\          },
    \\          "cpuIdle": true
    \\        },
    \\        "ports": [
    \\          {
    \\            "name": "http1",
    \\            "containerPort": 8080
    \\          }
    \\        ],
    \\        "startupProbe": {
    \\          "timeoutSeconds": 240,
    \\          "periodSeconds": 240,
    \\          "failureThreshold": 1,
    \\          "tcpSocket": {
    \\            "port": 8080
    \\          }
    \\        }
    \\      }
    \\    ],
    \\    "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\    {
    \\      "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\      "percent": 100
    \\    }
    \\  ],
    \\  "scaling": {
    \\    "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\    "https://zigps-3c3b48-plain-82150720798.us-central1.run.app",
    \\    "https://zigps-3c3b48-plain-el44yx5gia-uc.a.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "1",
    \\  "terminalCondition": {
    \\    "type": "Ready",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-23T14:27:24.230184Z"
    \\  },
    \\  "conditions": [
    \\    {
    \\      "type": "RoutesReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:24.177410Z"
    \\    },
    \\    {
    \\      "type": "ConfigurationsReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:20.898613Z"
    \\    }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-plain/revisions/zigps-3c3b48-plain-00001-j6p",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-plain/revisions/zigps-3c3b48-plain-00001-j6p",
    \\  "trafficStatuses": [
    \\    {
    \\      "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\      "revision": "zigps-3c3b48-plain-00001-j6p",
    \\      "percent": 100
    \\    }
    \\  ],
    \\  "uri": "https://zigps-3c3b48-plain-el44yx5gia-uc.a.run.app",
    \\  "etag": "\"CMjd7dYGENiVoiI/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtM2MzYjQ4LXBsYWlu\""
    \\}
;

/// That service's first revision: no scaling, execution environment, VPC access, volumes or session affinity. HTTP 200.
pub const settings_revision_plain_status = 200;
pub const settings_revision_plain =
    \\{
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-plain/revisions/zigps-3c3b48-plain-00001-j6p",
    \\  "uid": "cb73b069-76bd-490b-91dd-76f82cf11703",
    \\  "generation": "1",
    \\  "createTime": "2026-10-23T14:27:20.182816Z",
    \\  "updateTime": "2026-10-23T14:27:20.182816Z",
    \\  "launchStage": "GA",
    \\  "service": "zigps-3c3b48-plain",
    \\  "timeout": "300s",
    \\  "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\  "containers": [
    \\    {
    \\      "name": "hello-1",
    \\      "image": "us-docker.pkg.dev/cloudrun/container/hello@sha256:efd04605322d5d1ce6b1fd3dfc63a9c1fb2b99c97194ec316c0df0fd8f5dcf01",
    \\      "resources": {
    \\        "limits": {
    \\          "memory": "512Mi",
    \\          "cpu": "1000m"
    \\        },
    \\        "cpuIdle": true
    \\      },
    \\      "ports": [
    \\        {
    \\          "name": "http1",
    \\          "containerPort": 8080
    \\        }
    \\      ],
    \\      "startupProbe": {
    \\        "timeoutSeconds": 240,
    \\        "periodSeconds": 240,
    \\        "failureThreshold": 1,
    \\        "tcpSocket": {
    \\          "port": 8080
    \\        }
    \\      }
    \\    }
    \\  ],
    \\  "conditions": [
    \\    {
    \\      "type": "Ready",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Deploying revision succeeded in 2.66s.",
    \\      "lastTransitionTime": "2026-10-23T14:27:22.846876Z"
    \\    },
    \\    {
    \\      "type": "Active",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:22.975600Z",
    \\      "severity": "INFO"
    \\    },
    \\    {
    \\      "type": "ResourcesAvailable",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Provisioning imported containers completed in 1.47s. Checking container health. This will wait for up to 4m for the configured startup probe, including an initial delay of 0s.",
    \\      "lastTransitionTime": "2026-10-23T14:27:22.265815Z"
    \\    },
    \\    {
    \\      "type": "ContainerReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Container image import completed.",
    \\      "lastTransitionTime": "2026-10-23T14:27:20.794192Z"
    \\    },
    \\    {
    \\      "type": "ContainerHealthy",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "message": "Containers became healthy.",
    \\      "lastTransitionTime": "2026-10-23T14:27:22.771028Z"
    \\    }
    \\  ],
    \\  "observedGeneration": "1",
    \\  "logUri": "https://console.cloud.google.com/logs/viewer?project=extractctl&resource=cloud_run_revision/service_name/zigps-3c3b48-plain/revision_name/zigps-3c3b48-plain-00001-j6p&advancedFilter=resource.type%3D%22cloud_run_revision%22%0Aresource.labels.service_name%3D%22zigps-3c3b48-plain%22%0Aresource.labels.revision_name%3D%22zigps-3c3b48-plain-00001-j6p%22",
    \\  "maxInstanceRequestConcurrency": 80,
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "etag": "\"CMjd7dYGEICallc/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtM2MzYjQ4LXBsYWluL3JldmlzaW9ucy96aWdwcy0zYzNiNDgtcGxhaW4tMDAwMDEtajZw\""
    \\}
;

/// The plain service after a deploy of CPU "1" and memory "1G": kept as sent. HTTP 200.
pub const settings_service_cpu_forms_status = 200;
pub const settings_service_cpu_forms =
    \\{
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-plain",
    \\  "uid": "ea63946f-9279-4af2-a124-f1e39060c83f",
    \\  "generation": "3",
    \\  "createTime": "2026-10-23T14:27:20.071863Z",
    \\  "updateTime": "2026-10-23T14:27:34.961029Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\    "timeout": "300s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "containers": [
    \\      {
    \\        "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\        "resources": {
    \\          "limits": {
    \\            "cpu": "1",
    \\            "memory": "1G"
    \\          },
    \\          "cpuIdle": true
    \\        },
    \\        "ports": [
    \\          {
    \\            "name": "http1",
    \\            "containerPort": 8080
    \\          }
    \\        ],
    \\        "startupProbe": {
    \\          "timeoutSeconds": 240,
    \\          "periodSeconds": 240,
    \\          "failureThreshold": 1,
    \\          "tcpSocket": {
    \\            "port": 8080
    \\          }
    \\        }
    \\      }
    \\    ],
    \\    "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\    {
    \\      "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\      "percent": 100
    \\    }
    \\  ],
    \\  "scaling": {
    \\    "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\    "https://zigps-3c3b48-plain-82150720798.us-central1.run.app",
    \\    "https://zigps-3c3b48-plain-el44yx5gia-uc.a.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "3",
    \\  "terminalCondition": {
    \\    "type": "Ready",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-23T14:27:39.299222Z"
    \\  },
    \\  "conditions": [
    \\    {
    \\      "type": "RoutesReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:39.240447Z"
    \\    },
    \\    {
    \\      "type": "ConfigurationsReady",
    \\      "state": "CONDITION_SUCCEEDED",
    \\      "lastTransitionTime": "2026-10-23T14:27:35.740959Z"
    \\    }
    \\  ],
    \\  "latestReadyRevision": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-plain/revisions/zigps-3c3b48-plain-00003-cx5",
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-plain/revisions/zigps-3c3b48-plain-00003-cx5",
    \\  "trafficStatuses": [
    \\    {
    \\      "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\      "revision": "zigps-3c3b48-plain-00003-cx5",
    \\      "percent": 100
    \\    }
    \\  ],
    \\  "uri": "https://zigps-3c3b48-plain-el44yx5gia-uc.a.run.app",
    \\  "etag": "\"CNbd7dYGEIjHoMoD/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtM2MzYjQ4LXBsYWlu\""
    \\}
;

/// A service whose secret env var the runtime account could not read: failed, SECRETS_ACCESS_CHECK_FAILED, its env as sent. HTTP 200.
pub const settings_service_no_secret_access_status = 200;
pub const settings_service_no_secret_access =
    \\{
    \\  "name": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-nogrant",
    \\  "uid": "e558ff3d-2a34-4745-b64c-a65fa9d23b4a",
    \\  "generation": "1",
    \\  "labels": {
    \\    "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-23T14:26:43.743950Z",
    \\  "updateTime": "2026-10-23T14:26:43.743950Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "ingress": "INGRESS_TRAFFIC_ALL",
    \\  "launchStage": "GA",
    \\  "template": {
    \\    "timeout": "300s",
    \\    "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\    "containers": [
    \\      {
    \\        "image": "us-docker.pkg.dev/cloudrun/container/hello",
    \\        "env": [
    \\          {
    \\            "name": "FROM_SECRET",
    \\            "valueSource": {
    \\              "secretKeyRef": {
    \\                "secret": "zigps-3c3b48",
    \\                "version": "latest"
    \\              }
    \\            }
    \\          }
    \\        ],
    \\        "resources": {
    \\          "limits": {
    \\            "memory": "512Mi",
    \\            "cpu": "1000m"
    \\          },
    \\          "cpuIdle": true
    \\        },
    \\        "ports": [
    \\          {
    \\            "name": "http1",
    \\            "containerPort": 8080
    \\          }
    \\        ],
    \\        "startupProbe": {
    \\          "timeoutSeconds": 240,
    \\          "periodSeconds": 240,
    \\          "failureThreshold": 1,
    \\          "tcpSocket": {
    \\            "port": 8080
    \\          }
    \\        }
    \\      }
    \\    ],
    \\    "maxInstanceRequestConcurrency": 80
    \\  },
    \\  "traffic": [
    \\    {
    \\      "type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
    \\      "percent": 100
    \\    }
    \\  ],
    \\  "scaling": {
    \\    "maxInstanceCount": 20
    \\  },
    \\  "urls": [
    \\    "https://zigps-3c3b48-nogrant-82150720798.us-central1.run.app"
    \\  ],
    \\  "sshEnabled": false,
    \\  "observedGeneration": "1",
    \\  "terminalCondition": {
    \\    "type": "Ready",
    \\    "state": "CONDITION_FAILED",
    \\    "message": "spec.template.spec.containers[0].env[0].value_from.secret_key_ref.name: Permission denied on secret: projects/82150720798/secrets/zigps-3c3b48/versions/latest for Revision service account 82150720798-compute@developer.gserviceaccount.com. The service account used must be granted the 'Secret Manager Secret Accessor' role (roles/secretmanager.secretAccessor) at the secret, project or higher level.",
    \\    "lastTransitionTime": "2026-10-23T14:26:45.033871Z",
    \\    "reason": "SECRETS_ACCESS_CHECK_FAILED"
    \\  },
    \\  "conditions": [
    \\    {
    \\      "type": "RoutesReady",
    \\      "state": "CONDITION_FAILED",
    \\      "message": "spec.template.spec.containers[0].env[0].value_from.secret_key_ref.name: Permission denied on secret: projects/82150720798/secrets/zigps-3c3b48/versions/latest for Revision service account 82150720798-compute@developer.gserviceaccount.com. The service account used must be granted the 'Secret Manager Secret Accessor' role (roles/secretmanager.secretAccessor) at the secret, project or higher level.",
    \\      "lastTransitionTime": "2026-10-23T14:26:45.033871Z",
    \\      "reason": "SECRETS_ACCESS_CHECK_FAILED"
    \\    },
    \\    {
    \\      "type": "ConfigurationsReady",
    \\      "state": "CONDITION_FAILED",
    \\      "message": "spec.template.spec.containers[0].env[0].value_from.secret_key_ref.name: Permission denied on secret: projects/82150720798/secrets/zigps-3c3b48/versions/latest for Revision service account 82150720798-compute@developer.gserviceaccount.com. The service account used must be granted the 'Secret Manager Secret Accessor' role (roles/secretmanager.secretAccessor) at the secret, project or higher level.",
    \\      "lastTransitionTime": "2026-10-23T14:26:44.953736Z",
    \\      "reason": "SECRETS_ACCESS_CHECK_FAILED"
    \\    }
    \\  ],
    \\  "latestCreatedRevision": "projects/extractctl/locations/us-central1/services/zigps-3c3b48-nogrant/revisions/zigps-3c3b48-nogrant-00001-99d",
    \\  "etag": "\"CKPd7dYGELCN3-IC/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvc2VydmljZXMvemlncHMtM2MzYjQ4LW5vZ3JhbnQ\""
    \\}
;

/// A job whose task template sets command, args, working directory, env, resources, a volume, gen2 and direct VPC egress. HTTP 200.
pub const settings_job_status = 200;
pub const settings_job =
    \\{
    \\  "name": "projects/extractctl/locations/us-central1/jobs/zigps-3c3b48-job",
    \\  "uid": "88ce2de0-8066-492a-b6b5-971ae3c94603",
    \\  "generation": "1",
    \\  "labels": {
    \\    "zigps": "probe"
    \\  },
    \\  "createTime": "2026-10-23T14:27:57.028013Z",
    \\  "updateTime": "2026-10-23T14:27:57.028013Z",
    \\  "creator": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "lastModifier": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\  "launchStage": "GA",
    \\  "template": {
    \\    "taskCount": 1,
    \\    "template": {
    \\      "containers": [
    \\        {
    \\          "image": "us-docker.pkg.dev/cloudrun/container/job",
    \\          "command": [
    \\            "/bin/sh",
    \\            "-c"
    \\          ],
    \\          "args": [
    \\            "echo hi"
    \\          ],
    \\          "env": [
    \\            {
    \\              "name": "PLAIN",
    \\              "value": "x"
    \\            },
    \\            {
    \\              "name": "FROM_SECRET",
    \\              "valueSource": {
    \\                "secretKeyRef": {
    \\                  "secret": "zigps-3c3b48",
    \\                  "version": "1"
    \\                }
    \\              }
    \\            }
    \\          ],
    \\          "resources": {
    \\            "limits": {
    \\              "cpu": "1",
    \\              "memory": "512Mi"
    \\            }
    \\          },
    \\          "volumeMounts": [
    \\            {
    \\              "name": "scratch",
    \\              "mountPath": "/scratch"
    \\            }
    \\          ],
    \\          "workingDir": "/tmp"
    \\        }
    \\      ],
    \\      "volumes": [
    \\        {
    \\          "name": "scratch",
    \\          "emptyDir": {
    \\            "medium": "MEMORY"
    \\          }
    \\        }
    \\      ],
    \\      "maxRetries": 0,
    \\      "timeout": "600s",
    \\      "serviceAccount": "82150720798-compute@developer.gserviceaccount.com",
    \\      "executionEnvironment": "EXECUTION_ENVIRONMENT_GEN2",
    \\      "vpcAccess": {
    \\        "egress": "ALL_TRAFFIC",
    \\        "networkInterfaces": [
    \\          {
    \\            "network": "default",
    \\            "subnetwork": "default"
    \\          }
    \\        ]
    \\      }
    \\    }
    \\  },
    \\  "observedGeneration": "1",
    \\  "terminalCondition": {
    \\    "type": "Ready",
    \\    "state": "CONDITION_SUCCEEDED",
    \\    "lastTransitionTime": "2026-10-23T14:27:57.336774Z"
    \\  },
    \\  "latestCreatedExecution": {},
    \\  "etag": "\"CO3d7dYGEMjjrQ0/cHJvamVjdHMvZXh0cmFjdGN0bC9sb2NhdGlvbnMvdXMtY2VudHJhbDEvam9icy96aWdwcy0zYzNiNDgtam9i\""
    \\}
;
