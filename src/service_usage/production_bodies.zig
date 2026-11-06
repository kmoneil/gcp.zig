//! Answers production gave on 2026-11-06 in extractctl, measured for the
//! Service Usage spec (`_tmp/su-m0/run3/`): the client's own requests,
//! with its fields masks and `prettyPrint=false`, each body byte for byte
//! as sent, the per-call Help Token in each refusal's message among them.
//! Test code only.

/// services.list, the enabled ones, three to a page: the first page. HTTP 200.
pub const list_enabled_page_status = 200;
pub const list_enabled_page =
    \\{"services":[{"name":"projects/82150720798/services/analyticshub.googleapis.com","config":{"name":"analyticshub.googleapis.com","title":"Analytics Hub API","documentation":{"summary":"Exchange data and analytics assets securely and efficiently."}},"state":"ENABLED"},{"name":"projects/82150720798/services/artifactregistry.googleapis.com","config":{"name":"artifactregistry.googleapis.com","title":"Artifact Registry API","documentation":{"summary":"Store and manage build artifacts in a scalable and integrated service built on Google infrastructure."}},"state":"ENABLED"},{"name":"projects/82150720798/services/backupdr.googleapis.com","config":{"name":"backupdr.googleapis.com","title":"Backup and DR Service API","documentation":{}},"state":"ENABLED"}],"nextPageToken":"ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw=="}
;

/// services.list, the enabled ones, three to a page: the second, by the first's token. HTTP 200.
pub const list_enabled_next_status = 200;
pub const list_enabled_next =
    \\{"services":[{"name":"projects/82150720798/services/bigquery.googleapis.com","config":{"name":"bigquery.googleapis.com","title":"BigQuery API","documentation":{"summary":"A data platform for customers to create, manage, share and query data."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigqueryconnection.googleapis.com","config":{"name":"bigqueryconnection.googleapis.com","title":"BigQuery Connection API","documentation":{"summary":"Allows users to manage BigQuery connections to external data sources."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigquerydatapolicy.googleapis.com","config":{"name":"bigquerydatapolicy.googleapis.com","title":"BigQuery Data Policy API","documentation":{"summary":"Allows users to manage BigQuery data policies."}},"state":"ENABLED"}],"nextPageToken":"ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Ng=="}
;

/// services.list, every enabled one: all 45 on one page, no page size given. HTTP 200.
pub const list_enabled_all_status = 200;
pub const list_enabled_all =
    \\{"services":[{"name":"projects/82150720798/services/analyticshub.googleapis.com","config":{"name":"analyticshub.googleapis.com","title":"Analytics Hub API","documentation":{"summary":"Exchange data and analytics assets securely and efficiently."}},"state":"ENABLED"},{"name":"projects/82150720798/services/artifactregistry.googleapis.com","config":{"name":"artifactregistry.googleapis.com","title":"Artifact Registry API","documentation":{"summary":"Store and manage build artifacts in a scalable and integrated service built on Google infrastructure."}},"state":"ENABLED"},{"name":"projects/82150720798/services/backupdr.googleapis.com","config":{"name":"backupdr.googleapis.com","title":"Backup and DR Service API","documentation":{}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigquery.googleapis.com","config":{"name":"bigquery.googleapis.com","title":"BigQuery API","documentation":{"summary":"A data platform for customers to create, manage, share and query data."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigqueryconnection.googleapis.com","config":{"name":"bigqueryconnection.googleapis.com","title":"BigQuery Connection API","documentation":{"summary":"Allows users to manage BigQuery connections to external data sources."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigquerydatapolicy.googleapis.com","config":{"name":"bigquerydatapolicy.googleapis.com","title":"BigQuery Data Policy API","documentation":{"summary":"Allows users to manage BigQuery data policies."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigquerydatatransfer.googleapis.com","config":{"name":"bigquerydatatransfer.googleapis.com","title":"BigQuery Data Transfer API","documentation":{"summary":"Schedule queries or transfer external data from SaaS applications to Google BigQuery on a regular basis."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigquerymigration.googleapis.com","config":{"name":"bigquerymigration.googleapis.com","title":"BigQuery Migration API","documentation":{"summary":"The migration service, exposing apis for migration jobs operations, and agent management."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigqueryreservation.googleapis.com","config":{"name":"bigqueryreservation.googleapis.com","title":"BigQuery Reservation API","documentation":{"summary":"A service to modify your BigQuery reservations."}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigquerystorage.googleapis.com","config":{"name":"bigquerystorage.googleapis.com","title":"BigQuery Storage API","documentation":{}},"state":"ENABLED"},{"name":"projects/82150720798/services/chat.googleapis.com","config":{"name":"chat.googleapis.com","title":"Google Chat API","documentation":{"summary":"The Google Chat API lets you build Chat apps to integrate your services with Google Chat and manage Chat resources such as spaces, members, and messages."}},"state":"ENABLED"},{"name":"projects/82150720798/services/cloudapis.googleapis.com","config":{"name":"cloudapis.googleapis.com","title":"Google Cloud APIs","documentation":{"summary":"This is a meta service for Google Cloud APIs for convenience. Enabling this service enables all commonly used Google Cloud APIs for the project. By default, it is enabled for all projects created through Google Cloud Console and Google Cloud SDK, and should be manually enabled for all other projects that intend to use Google Cloud APIs. Note: disabling this service has no effect on other services.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/cloudbilling.googleapis.com","config":{"name":"cloudbilling.googleapis.com","title":"Cloud Billing API","documentation":{"summary":"Allows developers to manage billing for their Google Cloud Platform projects\n    programmatically."}},"state":"ENABLED"},{"name":"projects/82150720798/services/cloudbuild.googleapis.com","config":{"name":"cloudbuild.googleapis.com","title":"Cloud Build API","documentation":{"summary":"Creates and manages builds on Google Cloud Platform."}},"state":"ENABLED"},{"name":"projects/82150720798/services/clouderrorreporting.googleapis.com","config":{"name":"clouderrorreporting.googleapis.com","title":"Error Reporting API","documentation":{"summary":"Groups and counts similar errors from cloud services and applications, reports new errors, and provides access to error groups and their associated errors.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/cloudkms.googleapis.com","config":{"name":"cloudkms.googleapis.com","title":"Cloud Key Management Service (KMS) API","documentation":{"summary":"Manages keys and performs cryptographic operations in a central cloud service, for direct use by other cloud resources and applications.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/cloudresourcemanager.googleapis.com","config":{"name":"cloudresourcemanager.googleapis.com","title":"Cloud Resource Manager API","documentation":{"summary":"Creates, reads, and updates metadata for Google Cloud Platform resource containers."}},"state":"ENABLED"},{"name":"projects/82150720798/services/cloudscheduler.googleapis.com","config":{"name":"cloudscheduler.googleapis.com","title":"Cloud Scheduler API","documentation":{"summary":"Creates and manages jobs run on a regular recurring schedule."}},"state":"ENABLED"},{"name":"projects/82150720798/services/cloudtrace.googleapis.com","config":{"name":"cloudtrace.googleapis.com","title":"Cloud Trace API","documentation":{"summary":"Sends application trace data to Cloud Trace for viewing. Trace data is collected for all App Engine applications by default. Trace data from other applications can be provided using this API. This library is used to interact with the Cloud Trace API directly. If you are looking to instrument your application for Cloud Trace, we recommend using OpenTelemetry.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/compute.googleapis.com","config":{"name":"compute.googleapis.com","title":"Compute Engine API","documentation":{"summary":"Creates and runs virtual machines on Google Cloud Platform.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/containerregistry.googleapis.com","config":{"name":"containerregistry.googleapis.com","title":"Container Registry API","documentation":{"summary":"Google Container Registry provides secure, private Docker image storage on Google Cloud Platform.  Our API follows the Docker Registry API specification, so we are fully compatible with the Docker CLI client, as well as standard tooling using the Docker Registry API."}},"state":"ENABLED"},{"name":"projects/82150720798/services/dataflow.googleapis.com","config":{"name":"dataflow.googleapis.com","title":"Dataflow API","documentation":{"summary":"Manages Google Cloud Dataflow projects on Google Cloud Platform."}},"state":"ENABLED"},{"name":"projects/82150720798/services/dataform.googleapis.com","config":{"name":"dataform.googleapis.com","title":"Dataform API","documentation":{"summary":"Service to develop, version control, and operationalize SQL pipelines in BigQuery."}},"state":"ENABLED"},{"name":"projects/82150720798/services/dataplex.googleapis.com","config":{"name":"dataplex.googleapis.com","title":"Cloud Dataplex API","documentation":{"summary":"A unified, intelligent governance solution for data and AI assets."}},"state":"ENABLED"},{"name":"projects/82150720798/services/datastore.googleapis.com","config":{"name":"datastore.googleapis.com","title":"Cloud Datastore API","documentation":{"summary":"Accesses the schemaless NoSQL database to provide fully managed, robust, scalable storage for your application.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/deploymentmanager.googleapis.com","config":{"name":"deploymentmanager.googleapis.com","title":"Cloud Deployment Manager V2 API","documentation":{"summary":"The Google Cloud Deployment Manager v2 API provides services for configuring, deploying, and\nviewing Google Cloud services and APIs via templates which specify deployments of Cloud\nresources."}},"state":"ENABLED"},{"name":"projects/82150720798/services/firebaserules.googleapis.com","config":{"name":"firebaserules.googleapis.com","title":"Firebase Rules API","documentation":{"summary":"Creates and manages rules that determine when a Firebase Rules-enabled service should permit a request.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/firestore.googleapis.com","config":{"name":"firestore.googleapis.com","title":"Cloud Firestore API","documentation":{"summary":"Accesses the NoSQL document database built for automatic scaling, high performance, and ease of application development.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/iam.googleapis.com","config":{"name":"iam.googleapis.com","title":"Identity and Access Management (IAM) API","documentation":{"summary":"Manages identity and access control for Google Cloud resources, including the creation of service accounts, which you can use to authenticate to Google and make API calls. Enabling this API also enables the IAM Service Account Credentials API (iamcredentials.googleapis.com). However, disabling this API doesn't disable the IAM Service Account Credentials API.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/iamcredentials.googleapis.com","config":{"name":"iamcredentials.googleapis.com","title":"IAM Service Account Credentials API","documentation":{"summary":"Creates short-lived credentials for impersonating IAM service accounts. Disabling this API also disables the IAM API (iam.googleapis.com). However, enabling this API doesn't enable the IAM API.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/logging.googleapis.com","config":{"name":"logging.googleapis.com","title":"Cloud Logging API","documentation":{"summary":"Writes log entries and manages your Cloud Logging configuration."}},"state":"ENABLED"},{"name":"projects/82150720798/services/monitoring.googleapis.com","config":{"name":"monitoring.googleapis.com","title":"Cloud Monitoring API","documentation":{"summary":"Manages your Cloud Monitoring data and configurations.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/oslogin.googleapis.com","config":{"name":"oslogin.googleapis.com","title":"Cloud OS Login API","documentation":{"summary":"You can use OS Login to manage access to your VM instances using IAM roles."}},"state":"ENABLED"},{"name":"projects/82150720798/services/pubsub.googleapis.com","config":{"name":"pubsub.googleapis.com","title":"Cloud Pub/Sub API","documentation":{"summary":"Provides reliable, many-to-many, asynchronous messaging between applications.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/run.googleapis.com","config":{"name":"run.googleapis.com","title":"Cloud Run Admin API","documentation":{"summary":"Deploy and manage user provided container images that scale automatically based on incoming requests. The Cloud Run Admin API v1 follows the Knative Serving API specification, while v2 is aligned with Google Cloud AIP-based API standards, as described in https://google.aip.dev/."}},"state":"ENABLED"},{"name":"projects/82150720798/services/secretmanager.googleapis.com","config":{"name":"secretmanager.googleapis.com","title":"Secret Manager API","documentation":{"summary":"Stores sensitive data such as API keys, passwords, and certificates. Provides convenience while improving security.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/servicemanagement.googleapis.com","config":{"name":"servicemanagement.googleapis.com","title":"Service Management API","documentation":{"summary":"Google Service Management allows service producers to publish their services on Google Cloud Platform so that they can be discovered and used by service consumers."}},"state":"ENABLED"},{"name":"projects/82150720798/services/servicenetworking.googleapis.com","config":{"name":"servicenetworking.googleapis.com","title":"Service Networking API","documentation":{"summary":"Provides automatic management of network configurations necessary for certain services."}},"state":"ENABLED"},{"name":"projects/82150720798/services/serviceusage.googleapis.com","config":{"name":"serviceusage.googleapis.com","title":"Service Usage API","documentation":{"summary":"Enables services that service consumers want to use on Google Cloud Platform, lists the available or enabled services, or disables services that service consumers no longer use."}},"state":"ENABLED"},{"name":"projects/82150720798/services/sql-component.googleapis.com","config":{"name":"sql-component.googleapis.com","title":"Cloud SQL","documentation":{"summary":"Google Cloud SQL is a hosted and fully managed relational database service\n    on Google's infrastructure."}},"state":"ENABLED"},{"name":"projects/82150720798/services/sqladmin.googleapis.com","config":{"name":"sqladmin.googleapis.com","title":"Cloud SQL Admin API","documentation":{"summary":"Cloud SQL Admin API"}},"state":"ENABLED"},{"name":"projects/82150720798/services/storage-api.googleapis.com","config":{"name":"storage-api.googleapis.com","title":"Google Cloud Storage JSON API","documentation":{"summary":"Lets you store and retrieve potentially-large, immutable data objects."}},"state":"ENABLED"},{"name":"projects/82150720798/services/storage-component.googleapis.com","config":{"name":"storage-component.googleapis.com","title":"Cloud Storage","documentation":{"summary":"Google Cloud Storage is a RESTful service for storing and accessing your data on Google's\n    infrastructure."}},"state":"ENABLED"},{"name":"projects/82150720798/services/storage.googleapis.com","config":{"name":"storage.googleapis.com","title":"Cloud Storage API","documentation":{"summary":"Lets you store and retrieve potentially-large, immutable data objects."}},"state":"ENABLED"},{"name":"projects/82150720798/services/telemetry.googleapis.com","config":{"name":"telemetry.googleapis.com","title":"Telemetry API","documentation":{"summary":"An API that accepts telemetry data in the OpenTelemetry standard. Written data can be accessed by the corresponding Google Cloud product."}},"state":"ENABLED"}]}
;

/// services.list, the disabled ones, two to a page: the first page. HTTP 200.
pub const list_disabled_page_status = 200;
pub const list_disabled_page =
    \\{"services":[{"name":"projects/82150720798/services/a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC 601 - BYOL","documentation":{}},"state":"DISABLED"},{"name":"projects/82150720798/services/a10-vthunder-adc-100mbps.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-vthunder-adc-100mbps.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC for Advanced Load Balancing - 100 Mbps","documentation":{}},"state":"DISABLED"}],"nextPageToken":"Cs8BCAISyAFFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wSWtkaE1UQXRkblJvZFc1a1pYSXRZV1JqTFRFd01HMWljSE11Wlc1a2NHOXBiblJ6TG1FeE1HNWxkSGR2Y210ekxYQjFZbXhwWXkwek9UWXpNVFV1WTJ4dmRXUXVaMjl2Wnc9PSABEhkI____________ARIMCJn8t9cGEOicuOICIAE="}
;

/// services.list, the disabled ones: the second page. HTTP 200.
pub const list_disabled_next_status = 200;
pub const list_disabled_next =
    \\{"services":[{"name":"projects/82150720798/services/a10-vthunder-adc-10gbps.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-vthunder-adc-10gbps.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC for Advanced Load Balancing - 10 Gbps","documentation":{}},"state":"DISABLED"},{"name":"projects/82150720798/services/a10-vthunder-adc-1gbps.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-vthunder-adc-1gbps.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC for Advanced Load Balancing - 1 Gbps","documentation":{}},"state":"DISABLED"}],"nextPageToken":"CssBCAISxAFFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wSWtWaE1UQXRkblJvZFc1a1pYSXRZV1JqTFRGblluQnpMbVZ1WkhCdmFXNTBjeTVoTVRCdVpYUjNiM0pyY3kxd2RXSnNhV010TXprMk16RTFMbU5zYjNWa0xtZHZiMmM9IAESGQj-__________8BEgwImfy31wYQ6Jy44gIgAQ=="}
;

/// services.list with no filter, two to a page: the first page. HTTP 200.
pub const list_any_page_status = 200;
pub const list_any_page =
    \\{"services":[{"name":"projects/82150720798/services/a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC 601 - BYOL","documentation":{}},"state":"DISABLED"},{"name":"projects/82150720798/services/a10-vthunder-adc-100mbps.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-vthunder-adc-100mbps.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC for Advanced Load Balancing - 100 Mbps","documentation":{}},"state":"DISABLED"}],"nextPageToken":"CpcECAISkARFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wR3ZRQlEzSkpRazFEZDJsWlZFVjNURmhhTUdGSVZuVmFSMVo1VEZkR2ExbDVNSGhOUkVKMFdXNUNla3h0Vm5WYVNFSjJZVmMxTUdONU5XaE5WRUoxV2xoU00ySXpTbkpqZVRGM1pGZEtjMkZYVFhSTmVtc3lUWHBGTVV4dFRuTmlNMVpyVEcxa2RtSXlZMmxNUTBwNldsaEtNbUZYVG14aVYwWjFXVmRrYkdKWFZuVmtRelY2V2xoS01tRlhUbXhqZVVselNXMUZlRTFETVRKa1IyZ3hZbTFTYkdOcE1XaGFSMDEwVFZSQmQySlhTbmRqZVRWc1ltMVNkMkl5YkhWa1NFMTFXVlJGZDJKdFZqQmtNamw1WVROTmRHTklWbWxpUjJ4cVRGUk5OVTVxVFhoT1V6VnFZa2M1TVZwRE5XNWlNamx1U1djOVBTSkhZVEV3TFhaMGFIVnVaR1Z5TFdGa1l5MHhNREJ0WW5CekxtVnVaSEJ2YVc1MGN5NWhNVEJ1WlhSM2IzSnJjeTF3ZFdKc2FXTXRNemsyTXpFMUxtTnNiM1ZrTG1kdmIyYz0gARIZCP___________wESDAia_LfXBhDo-s2cASAB"}
;

/// The unfiltered list's token under the disabled filter: taken, the same page. HTTP 200.
pub const token_any_under_disabled_status = 200;
pub const token_any_under_disabled =
    \\{"services":[{"name":"projects/82150720798/services/a10-vthunder-adc-10gbps.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-vthunder-adc-10gbps.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC for Advanced Load Balancing - 10 Gbps","documentation":{}},"state":"DISABLED"},{"name":"projects/82150720798/services/a10-vthunder-adc-1gbps.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-vthunder-adc-1gbps.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC for Advanced Load Balancing - 1 Gbps","documentation":{}},"state":"DISABLED"}],"nextPageToken":"CssBCAISxAFFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wSWtWaE1UQXRkblJvZFc1a1pYSXRZV1JqTFRGblluQnpMbVZ1WkhCdmFXNTBjeTVoTVRCdVpYUjNiM0pyY3kxd2RXSnNhV010TXprMk16RTFMbU5zYjNWa0xtZHZiMmM9IAESGQj-__________8BEgwImvy31wYQ6PrNnAEgAQ=="}
;

/// The disabled list's token under the enabled filter. HTTP 400.
pub const token_disabled_under_enabled_status = 400;
pub const token_disabled_under_enabled =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid page token 'Cs8BCAISyAFFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wSWtkaE1UQXRkblJvZFc1a1pYSXRZV1JqTFRFd01HMWljSE11Wlc1a2NHOXBiblJ6TG1FeE1HNWxkSGR2Y210ekxYQjFZbXhwWXkwek9UWXpNVFV1WTJ4dmRXUXVaMjl2Wnc9PSABEhkI____________ARIMCJn8t9cGEOicuOICIAE='.\nHelp Token: AaVM3aP_BqVaaI2PQ2IaGYAPuAsNxqtOvIOraRnCoLjoghYA2EKk-9bO0PcD49JFVYab45Pj20KcE_foAtuhhpeYSVUGdZpYe2i7g1REoBxg8nUi",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=300000&token=Cs8BCAISyAFFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wSWtkaE1UQXRkblJvZFc1a1pYSXRZV1JqTFRFd01HMWljSE11Wlc1a2NHOXBiblJ6TG1FeE1HNWxkSGR2Y210ekxYQjFZbXhwWXkwek9UWXpNVFV1WTJ4dmRXUXVaMjl2Wnc9PSABEhkI____________ARIMCJn8t9cGEOicuOICIAE%3D"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "STORAGE_INVALID_PAGE_TOKEN",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "token": "Cs8BCAISyAFFa2tLUjNSNWNHVXVaMjl2WjJ4bFlYQnBjeTVqYjIwdloyOXZaMnhsTG1Gd2FTNXpaWEoyYVdObGJXRnVZV2RsYldWdWRDNTJNUzVNYVhOMFUyVnlkbWxqWlhOU1pYRjFaWE4wSWtkaE1UQXRkblJvZFc1a1pYSXRZV1JqTFRFd01HMWljSE11Wlc1a2NHOXBiblJ6TG1FeE1HNWxkSGR2Y210ekxYQjFZbXhwWXkwek9UWXpNVFV1WTJ4dmRXUXVaMjl2Wnc9PSABEhkI____________ARIMCJn8t9cGEOicuOICIAE="
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// The enabled list's token with no filter. HTTP 400.
pub const token_enabled_under_any_status = 400;
pub const token_enabled_under_any =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid page token: 'ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw=='.\nHelp Token: AaVM3aN9EfUZBM65unpVJHYz8azVYthe8ehaUK4LXAcP52MiR56tljLTdoZ-iyoqs9Mp97ywWNWe-ZgK5yXb1kHvzBa8o2Lg8V-ukKzeEgmDF0SC",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=908038&token=ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw%3D%3D"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SU_INVALID_PAGE_TOKEN",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "token": "ZW5hYmxlZC1zZXJ2aWNlcy1vZmZzZXQ6Mw=="
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// A page token the server never gave, under the enabled filter. HTTP 400.
pub const token_garbage_status = 400;
pub const token_garbage =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid page token 'abc'.\nHelp Token: AaVM3aMMYjYslvW6y6X047l0vwvcIUFrmGm0jsYdCgWE5ZP8jLdnZwLOVcge4s26UKIsItR4FW64sAxBfu18x1DEQOR4ajCz4y6FcKVkY_GrvDSt",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=300000&token=abc"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "STORAGE_INVALID_PAGE_TOKEN",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "token": "abc"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// A page size of 201. HTTP 400.
pub const page_size_201_status = 400;
pub const page_size_201 =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid page size, should be in [0, 200].\nHelp Token: AaVM3aN2wfHdkkOK6XsmIZ8A1hPrUG58kTJsZFVOoJp_k-ivSqK7gN7wzyI_ENEBLASy9sOhPwmeeONqSsomKdCQiWyKxlGgo8ls_T8inIZ-y5OQ",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=908000&max=200"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SU_INVALID_PAGE_SIZE",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "max": "200"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// The filter `state:enabled`. HTTP 400.
pub const filter_lowercase_status = 400;
pub const filter_lowercase =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Valid values for filter are: '', 'state:ENABLED', 'state:DISABLED'.\nHelp Token: AaVM3aM1OKm1iNUp8XiQ86VuspP8ICTUnTcmjcKpvi9SaqAc6mtbE9rwLlVHd4AQovBb8bDk2zUB5sMqCS12yce08aiUsP14Jt9mpTv-b35TW3nn",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "908010"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SU_INVALID_FILTER",
    \\        "domain": "serviceusage.googleapis.com"
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// A fields mask naming a field there is not. HTTP 400.
pub const fields_unknown_status = 400;
pub const fields_unknown =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Request contains an invalid argument.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "services(nope)",
    \\            "description": "Error expanding 'fields' parameter. Cannot find matching fields for path 'services.nope'."
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// A project nobody has, `zigps-no-such-project-316`. HTTP 403.
pub const no_such_project_status = 403;
pub const no_such_project =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Project 'zigps-no-such-project-316' not found or permission denied.\nHelp Token: AaVM3aNoUfPcOTBiGtuVwbVSI9pPjQT1c8M_s4NFyFkFYn9K9x9O29DIOIiRmjH6gO2jXEqPKQdIM-853MCxjEp-JbJlXK-Rgb1FzQwy8tZde4Mk",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=210002&type=Project&resource_id=zigps-no-such-project-316"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "RESOURCES_NOT_FOUND",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "type": "Project",
    \\          "resource_id": "zigps-no-such-project-316"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// A project that is not this account's, `bigquery-public-data`. HTTP 403.
pub const other_project_status = 403;
pub const other_project =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Permission denied to list services for consumer container [projects/1057666841514]\nHelp Token: AaVM3aNmO6vFuJBrDqIohH5YVeAALeGicrbbIo9-5OBQUIOYww-ktS1YtMmYCyamj8Nx3YZMS2bUgqtYr5Rj2lkn6yYiNCmy1fxBLp0df7bgPAQ_",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=110002&service=cloudresourcemanager.googleapis.com&permission=serviceusage.services.list&error_info_id=CiQwMWExYjFhOC1iMTBmLTc2ZTYtYWEyZS0wNDRiNGQ5NTI3ODQSFnByb2plY3RzLzEwNTc2NjY4NDE1MTQ%3D&troubleshooter_url=https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId%3DCiQwMWExYjFhOC1iMTBmLTc2ZTYtYWEyZS0wNDRiNGQ5NTI3ODQSFnByb2plY3RzLzEwNTc2NjY4NDE1MTQ%253D"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "AUTH_PERMISSION_DENIED",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "service": "cloudresourcemanager.googleapis.com",
    \\          "permission": "serviceusage.services.list",
    \\          "error_info_id": "CiQwMWExYjFhOC1iMTBmLTc2ZTYtYWEyZS0wNDRiNGQ5NTI3ODQSFnByb2plY3RzLzEwNTc2NjY4NDE1MTQ=",
    \\          "troubleshooter_url": "https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId=CiQwMWExYjFhOC1iMTBmLTc2ZTYtYWEyZS0wNDRiNGQ5NTI3ODQSFnByb2plY3RzLzEwNTc2NjY4NDE1MTQ%3D"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// No credentials. HTTP 403.
pub const no_credentials_status = 403;
pub const no_credentials =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.",
    \\    "status": "PERMISSION_DENIED"
    \\  }
    \\}
    \\
;

/// A token for `devstorage.read_only` only. HTTP 403.
pub const scope_insufficient_status = 403;
pub const scope_insufficient =
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
    \\          "service": "serviceusage.googleapis.com",
    \\          "method": "google.api.serviceusage.v1.ServiceUsage.ListServices"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// services.get of an enabled service. HTTP 200.
pub const get_enabled_status = 200;
pub const get_enabled =
    \\{"name":"projects/82150720798/services/pubsub.googleapis.com","config":{"name":"pubsub.googleapis.com","title":"Cloud Pub/Sub API","documentation":{"summary":"Provides reliable, many-to-many, asynchronous messaging between applications.\n"}},"state":"ENABLED"}
;

/// services.get of an enabled service with no summary. HTTP 200.
pub const get_no_summary_status = 200;
pub const get_no_summary =
    \\{"name":"projects/82150720798/services/backupdr.googleapis.com","config":{"name":"backupdr.googleapis.com","title":"Backup and DR Service API","documentation":{}},"state":"ENABLED"}
;

/// services.get of a disabled one, the first the disabled list gave. HTTP 200.
pub const get_disabled_status = 200;
pub const get_disabled =
    \\{"name":"projects/82150720798/services/a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC 601 - BYOL","documentation":{}},"state":"DISABLED"}
;

/// services.get of `pubsub`, answered as pubsub.googleapis.com. HTTP 200.
pub const get_alias_status = 200;
pub const get_alias =
    \\{"name":"projects/82150720798/services/pubsub.googleapis.com","config":{"name":"pubsub.googleapis.com","title":"Cloud Pub/Sub API","documentation":{"summary":"Provides reliable, many-to-many, asynchronous messaging between applications.\n"}},"state":"ENABLED"}
;

/// services.get of a service nobody has. HTTP 403.
pub const get_unknown_status = 403;
pub const get_unknown =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Not found or permission denied for service(s): zigps-nope-316.googleapis.com.\nHelp Token: AaVM3aN8dq1BR5F9g8x_tQmbvnA0DTzrg_GOTTOSf4Av3W9F_yrLCILya9CQh3poK1v9e3PLpGAkvjCqUZwyMIKX_OUApQ8YegmJwrog66h1wF1i",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=220002&services=zigps-nope-316.googleapis.com"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SERVICE_CONFIG_NOT_FOUND_OR_PERMISSION_DENIED",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "services": "zigps-nope-316.googleapis.com"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// services.get under another account's project. HTTP 403.
pub const get_other_project_status = 403;
pub const get_other_project =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Permission denied to get service [bigquery.googleapis.com]\nHelp Token: AaVM3aMiSwGRvuz6kD0ePv-udgzS77Mihaf6ncstUXE8hcCgPoXO7yq_uqKrgSRurxtBvhPwFYVf8TgxZ3VuAr1xSR2KG2N5J45kk5bIazWvwSOV",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=110002&service=serviceusage.googleapis.com&permission=serviceusage.services.get&error_info_id=CiQwMWExYjFhOC1jNWM2LTcwZDgtOGU0Zi1lZDY3OTZhODM0MTYSN3Byb2plY3RzLzEwNTc2NjY4NDE1MTQvc2VydmljZXMvYmlncXVlcnkuZ29vZ2xlYXBpcy5jb20%3D&troubleshooter_url=https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId%3DCiQwMWExYjFhOC1jNWM2LTcwZDgtOGU0Zi1lZDY3OTZhODM0MTYSN3Byb2plY3RzLzEwNTc2NjY4NDE1MTQvc2VydmljZXMvYmlncXVlcnkuZ29vZ2xlYXBpcy5jb20%253D"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "AUTH_PERMISSION_DENIED",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "service": "serviceusage.googleapis.com",
    \\          "permission": "serviceusage.services.get",
    \\          "error_info_id": "CiQwMWExYjFhOC1jNWM2LTcwZDgtOGU0Zi1lZDY3OTZhODM0MTYSN3Byb2plY3RzLzEwNTc2NjY4NDE1MTQvc2VydmljZXMvYmlncXVlcnkuZ29vZ2xlYXBpcy5jb20=",
    \\          "troubleshooter_url": "https://console.cloud.google.com/iam-admin/troubleshooter/summary;errorId=CiQwMWExYjFhOC1jNWM2LTcwZDgtOGU0Zi1lZDY3OTZhODM0MTYSN3Byb2plY3RzLzEwNTc2NjY4NDE1MTQvc2VydmljZXMvYmlncXVlcnkuZ29vZ2xlYXBpcy5jb20%3D"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// services.batchGet of an enabled and a disabled one, in that order. HTTP 200.
pub const batch_two_status = 200;
pub const batch_two =
    \\{"services":[{"name":"projects/82150720798/services/pubsub.googleapis.com","config":{"name":"pubsub.googleapis.com","title":"Cloud Pub/Sub API","documentation":{"summary":"Provides reliable, many-to-many, asynchronous messaging between applications.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","config":{"name":"a10-thunder-adc-601b150-byol.endpoints.a10networks-public-396315.cloud.goog","title":"A10 Thunder ADC 601 - BYOL","documentation":{}},"state":"DISABLED"}]}
;

/// services.batchGet of an unknown one, a known one and another unknown one: the first named. HTTP 403.
pub const batch_unknown_two_status = 403;
pub const batch_unknown_two =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Not found or permission denied for service(s): zigps-nope-a.googleapis.com.\nHelp Token: AaVM3aMwVLse1-yWwDZJN8yDdnY5RSDtWQNzVH1rK5Z_ndtF5TxvKSPfJY2kFDmSerhHGChT8Pce1yTPxGAJhkueObHSNw-qSAL2p1LeJR6PZQGT",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=220002&services=zigps-nope-a.googleapis.com"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SERVICE_CONFIG_NOT_FOUND_OR_PERMISSION_DENIED",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "services": "zigps-nope-a.googleapis.com"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// services.batchGet of a name under this project and one under `bigquery-public-data`: both answered as this project's. HTTP 200.
pub const batch_other_project_name_status = 200;
pub const batch_other_project_name =
    \\{"services":[{"name":"projects/82150720798/services/pubsub.googleapis.com","config":{"name":"pubsub.googleapis.com","title":"Cloud Pub/Sub API","documentation":{"summary":"Provides reliable, many-to-many, asynchronous messaging between applications.\n"}},"state":"ENABLED"},{"name":"projects/82150720798/services/bigquery.googleapis.com","config":{"name":"bigquery.googleapis.com","title":"BigQuery API","documentation":{"summary":"A data platform for customers to create, manage, share and query data."}},"state":"ENABLED"}]}
;

/// services.batchGet of 31 names. HTTP 400.
pub const batch_31_status = 400;
pub const batch_31 =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Number of services must not exceed the maximum batch size (30).\nHelp Token: AaVM3aNabswnEE0kk6GoW3b5IwluVIl_ZwZtCzBYQeKwJe1e8FWwIhpVTQJKiO3tBKb_JQ2hrSu0a1tHmDIOToIWJXt5-vvkaPljs-aOHje3ez79",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=908003&max=30"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SU_MAX_BATCH_SIZE_EXCEEDED",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "max": "30"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// services.batchGet of no names. HTTP 400.
pub const batch_none_status = 400;
pub const batch_none =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Name(s) should not be empty.\nHelp Token: AaVM3aPwxGIVJguC69uW4llv6VVS7ndiYaRDSspNdyxPw5JAlLKTDpzY7iGysU6EqhH8sRs-QNLhlxlXhEz07OXxFOn184HnX9hMfokl1oo3qwGG",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "908002"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SU_MISSING_NAMES",
    \\        "domain": "serviceusage.googleapis.com"
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// services.batchGet of a name with no project, `pubsub.googleapis.com`. HTTP 400.
pub const batch_bare_name_status = 400;
pub const batch_bare_name =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid parent format \"pubsub.googleapis.com\".\nHelp Token: AaVM3aNJQ6lq4z1GouZan-IXlnVy9iF9h3cSeRSGG8dofD5aVIcFXdBX33XS_XRXYPdi0cVDQ3mQMvHRRzVB3LD40fZwhSB6P7LIXXmGyPoRLKQ7",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.PreconditionFailure",
    \\        "violations": [
    \\          {
    \\            "type": "googleapis.com",
    \\            "subject": "?error_code=900001&parent=pubsub.googleapis.com"
    \\          }
    \\        ]
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "API_SHARED_INVALID_PARENT_FORMAT",
    \\        "domain": "serviceusage.googleapis.com",
    \\        "metadata": {
    \\          "parent": "pubsub.googleapis.com"
    \\        }
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;
