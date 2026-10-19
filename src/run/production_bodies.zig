//! Answers production gave on 2026-10-19, measured in milestone 0 of the
//! Cloud Run spec (`_tmp/run-m0/`), for tests: the probe's own `zigps-`
//! service and refusals, reserialized with the wire's key order (the
//! probe saved parsed bodies). Test code only.

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
