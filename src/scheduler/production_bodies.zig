//! Answers production gave on 2026-10-19, measured in milestone 0 of the
//! Scheduler spec (`_tmp/scheduler-m0/`), for tests: the probes' own
//! `zigps-` jobs and refusals, verbatim but for a final line break. Test
//! code only.

/// A job just created with an HTTP target: born with status code -1 and
/// no lastAttemptTime, the server's own User-Agent header and retry and
/// deadline defaults filled in. HTTP 200.
pub const job_created_status = 200;
pub const job_created =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-399f5c-http",
    \\ "httpTarget": {
    \\  "uri": "https://zigps-399f5c-nowhere.invalid/hook",
    \\  "httpMethod": "POST",
    \\  "headers": {
    \\   "User-Agent": "Google-Cloud-Scheduler"
    \\  }
    \\ },
    \\ "userUpdateTime": "2026-10-19T18:16:52.688845Z",
    \\ "state": "ENABLED",
    \\ "status": {
    \\  "code": -1
    \\ },
    \\ "scheduleTime": "2027-01-01T00:00:00Z",
    \\ "retryConfig": {
    \\  "retryCount": 1,
    \\  "maxRetryDuration": "0s",
    \\  "minBackoffDuration": "5s",
    \\  "maxBackoffDuration": "3600s",
    \\  "maxDoublings": 5
    \\ },
    \\ "schedule": "0 0 1 1 *",
    \\ "timeZone": "UTC",
    \\ "attemptDeadline": "180s"
    \\}
;

/// The same job 6 s after a `:run` whose host did not resolve: the
/// attempt's status code 2, lastAttemptTime set, state still ENABLED.
/// HTTP 200.
pub const job_failed_http_status = 200;
pub const job_failed_http =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-399f5c-http",
    \\ "httpTarget": {
    \\  "uri": "https://zigps-399f5c-nowhere.invalid/hook",
    \\  "httpMethod": "POST",
    \\  "headers": {
    \\   "User-Agent": "Google-Cloud-Scheduler"
    \\  }
    \\ },
    \\ "userUpdateTime": "2026-10-19T18:16:52.688845Z",
    \\ "state": "ENABLED",
    \\ "status": {
    \\  "code": 2
    \\ },
    \\ "scheduleTime": "2027-01-01T00:00:01.652510Z",
    \\ "lastAttemptTime": "2026-10-19T18:16:55.258042Z",
    \\ "retryConfig": {
    \\  "retryCount": 1,
    \\  "maxRetryDuration": "0s",
    \\  "minBackoffDuration": "5s",
    \\  "maxBackoffDuration": "3600s",
    \\  "maxDoublings": 5
    \\ },
    \\ "schedule": "0 0 1 1 *",
    \\ "timeZone": "UTC",
    \\ "attemptDeadline": "180s"
    \\}
;

/// A Pub/Sub job on a topic nobody has, after its `:run`: status code 5.
/// The server answered no retryConfig or attemptDeadline keys at all for
/// this one. HTTP 200.
pub const job_failed_pubsub_status = 200;
pub const job_failed_pubsub =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-399f5c-ps",
    \\ "pubsubTarget": {
    \\  "topicName": "projects/extractctl/topics/zigps-399f5c-missing",
    \\  "data": "emlncHM="
    \\ },
    \\ "userUpdateTime": "2026-10-19T18:17:00.999531Z",
    \\ "state": "ENABLED",
    \\ "status": {
    \\  "code": 5
    \\ },
    \\ "scheduleTime": "2027-01-01T00:00:03.758409Z",
    \\ "lastAttemptTime": "2026-10-19T18:17:07.066120Z",
    \\ "schedule": "0 0 1 1 *",
    \\ "timeZone": "UTC"
    \\}
;

/// A paused job: `scheduleTime` is gone; the probe's own header and body
/// kept, the server's Content-Type added for the body. HTTP 200.
pub const job_paused_status = 200;
pub const job_paused =
    \\{
    \\ "name": "projects/extractctl/locations/us-central1/jobs/zigps-d8a22f-http",
    \\ "description": "zig-gcp scheduler probe, deleted by the probe",
    \\ "httpTarget": {
    \\  "uri": "https://zigps-d8a22f-nowhere.invalid/hook",
    \\  "httpMethod": "POST",
    \\  "headers": {
    \\   "Content-Type": "application/octet-stream",
    \\   "X-Zigps": "probe",
    \\   "User-Agent": "Google-Cloud-Scheduler"
    \\  },
    \\  "body": "eyJwcm9iZSI6dHJ1ZX0="
    \\ },
    \\ "userUpdateTime": "2026-10-19T18:12:47.403594Z",
    \\ "state": "PAUSED",
    \\ "status": {
    \\  "code": -1
    \\ },
    \\ "retryConfig": {
    \\  "retryCount": 1,
    \\  "maxRetryDuration": "0s",
    \\  "minBackoffDuration": "5s",
    \\  "maxBackoffDuration": "3600s",
    \\  "maxDoublings": 5
    \\ },
    \\ "schedule": "0 0 1 1 *",
    \\ "timeZone": "UTC",
    \\ "attemptDeadline": "180s"
    \\}
;

/// One page of one job, with a real (opaque, long) page token. HTTP 200.
pub const jobs_page_status = 200;
pub const jobs_page =
    \\{
    \\ "jobs": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1/jobs/zigps-d8a22f-ps",
    \\   "pubsubTarget": {
    \\    "topicName": "projects/extractctl/topics/zigps-d8a22f-missing",
    \\    "data": "emlncHM="
    \\   },
    \\   "userUpdateTime": "2026-10-19T18:12:44.491584Z",
    \\   "state": "ENABLED",
    \\   "status": {
    \\    "code": -1
    \\   },
    \\   "scheduleTime": "2027-01-01T00:00:00Z",
    \\   "schedule": "0 0 1 1 *",
    \\   "timeZone": "UTC"
    \\  }
    \\ ],
    \\ "nextPageToken": "CsABCq8BU1BBTi1DbjBLT3dvTGRYTXRZMlZ1ZEhKaGJERVNIV05zYjNWa2MyTm9aV1IxYkdWeUxtZHZiMmRzWldGd2FYTXVZMjl0R0FFZ25vckNoTElDS2dScWIySnpFZzk2YVdkd2N5MWtPR0V5TW1ZdGNITWFKREEyTW1ZMk5tRXlMV1pqTnpBdE5EVTBPUzFpWWpVNExUVmtZV1JsTURGak1UZ3pZeUVZcHV2TjRTX3NJZxIMCKG72dYGEP23obAD"
    \\}
;

/// A location, as `locations.list` answers one of its 34.
pub const locations_page_status = 200;
pub const locations_page =
    \\{
    \\ "locations": [
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "us-central1"
    \\   },
    \\   "locationId": "us-central1"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-east1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "us-east1"
    \\   },
    \\   "locationId": "us-east1"
    \\  }
    \\ ],
    \\ "nextPageToken": "p2"
    \\}
;

/// `jobs.get` of a job nobody has. HTTP 404.
pub const job_unknown_status = 404;
pub const job_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "Job not found.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// `jobs.list` in a location that does not exist. HTTP 400.
pub const location_unknown_status = 400;
pub const location_unknown =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Location 'us-fake1' is not a valid location. Use ListLocations to list valid locations.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// `jobs.list` with pageSize 501. HTTP 400.
pub const page_size_501_status = 400;
pub const page_size_501 =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "ListJobsRequest.pageSize must be less than or equal to 500.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;
