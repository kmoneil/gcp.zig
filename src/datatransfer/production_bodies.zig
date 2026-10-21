//! Answers production gave on 2026-10-21, measured in milestone 0 of the
//! Data Transfer spec (`_tmp/datatransfer-m0/`), for tests: the project's
//! locations, and the probe's own `zigps_dt_bd4dcf` dataset's three
//! scheduled queries (a manual one, a scheduled one disabled, a failing
//! one), their runs and messages, reserialized in the order the probe
//! saved them. extractctl held no other config. Test code only.

/// projects.locations.list: every location, one page. HTTP 200.
pub const locations_page_status = 200;
pub const locations_page =
    \\{
    \\ "locations": [
    \\  {
    \\   "name": "projects/extractctl/locations/us",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "us",
    \\    "cloud.googleapis.com/country": "US"
    \\   },
    \\   "locationId": "us"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "europe",
    \\    "cloud.googleapis.com/country": "IE"
    \\   },
    \\   "locationId": "europe"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-east1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "US",
    \\    "cloud.googleapis.com/location": "us-east1",
    \\    "cloud.googleapis.com/region": "us-east1"
    \\   },
    \\   "locationId": "us-east1",
    \\   "displayName": "South Carolina"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-east4",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "us-east4",
    \\    "cloud.googleapis.com/location": "us-east4",
    \\    "cloud.googleapis.com/country": "US"
    \\   },
    \\   "locationId": "us-east4",
    \\   "displayName": "Northern Virginia"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-east5",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "US",
    \\    "cloud.googleapis.com/region": "us-east5",
    \\    "cloud.googleapis.com/location": "us-east5"
    \\   },
    \\   "locationId": "us-east5",
    \\   "displayName": "Columbus"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central1",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "us-central1",
    \\    "cloud.googleapis.com/region": "us-central1",
    \\    "cloud.googleapis.com/country": "US"
    \\   },
    \\   "locationId": "us-central1",
    \\   "displayName": "Iowa"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-central2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "us-central2",
    \\    "cloud.googleapis.com/region": "us-central2",
    \\    "cloud.googleapis.com/country": "US"
    \\   },
    \\   "locationId": "us-central2",
    \\   "displayName": "Oklahoma"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-west1",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "us-west1",
    \\    "cloud.googleapis.com/region": "us-west1",
    \\    "cloud.googleapis.com/country": "US"
    \\   },
    \\   "locationId": "us-west1",
    \\   "displayName": "Oregon"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-west2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "us-west2",
    \\    "cloud.googleapis.com/country": "US",
    \\    "cloud.googleapis.com/region": "us-west2"
    \\   },
    \\   "locationId": "us-west2",
    \\   "displayName": "Los Angeles"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-west3",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "us-west3",
    \\    "cloud.googleapis.com/country": "US",
    \\    "cloud.googleapis.com/region": "us-west3"
    \\   },
    \\   "locationId": "us-west3",
    \\   "displayName": "Salt Lake City"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-west4",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "us-west4",
    \\    "cloud.googleapis.com/location": "us-west4",
    \\    "cloud.googleapis.com/country": "US"
    \\   },
    \\   "locationId": "us-west4",
    \\   "displayName": "Las Vegas"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/us-south1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "US",
    \\    "cloud.googleapis.com/location": "us-south1",
    \\    "cloud.googleapis.com/region": "us-south1"
    \\   },
    \\   "locationId": "us-south1",
    \\   "displayName": "Dallas"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-east1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "TW",
    \\    "cloud.googleapis.com/region": "asia-east1",
    \\    "cloud.googleapis.com/location": "asia-east1"
    \\   },
    \\   "locationId": "asia-east1",
    \\   "displayName": "Taiwan"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-northeast1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "asia-northeast1",
    \\    "cloud.googleapis.com/country": "JP",
    \\    "cloud.googleapis.com/location": "asia-northeast1"
    \\   },
    \\   "locationId": "asia-northeast1",
    \\   "displayName": "Tokyo"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-southeast1",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "asia-southeast1",
    \\    "cloud.googleapis.com/country": "SG",
    \\    "cloud.googleapis.com/region": "asia-southeast1"
    \\   },
    \\   "locationId": "asia-southeast1",
    \\   "displayName": "Singapore"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-south1",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "asia-south1",
    \\    "cloud.googleapis.com/country": "IN",
    \\    "cloud.googleapis.com/region": "asia-south1"
    \\   },
    \\   "locationId": "asia-south1",
    \\   "displayName": "Mumbai"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-east2",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "HK",
    \\    "cloud.googleapis.com/location": "asia-east2",
    \\    "cloud.googleapis.com/region": "asia-east2"
    \\   },
    \\   "locationId": "asia-east2",
    \\   "displayName": "Hong Kong"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-northeast2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "asia-northeast2",
    \\    "cloud.googleapis.com/region": "asia-northeast2",
    \\    "cloud.googleapis.com/country": "JP"
    \\   },
    \\   "locationId": "asia-northeast2",
    \\   "displayName": "Osaka"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-northeast3",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "asia-northeast3",
    \\    "cloud.googleapis.com/region": "asia-northeast3",
    \\    "cloud.googleapis.com/country": "KR"
    \\   },
    \\   "locationId": "asia-northeast3",
    \\   "displayName": "Seoul"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-southeast2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "asia-southeast2",
    \\    "cloud.googleapis.com/region": "asia-southeast2",
    \\    "cloud.googleapis.com/country": "ID"
    \\   },
    \\   "locationId": "asia-southeast2",
    \\   "displayName": "Jakarta"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-south2",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "IN",
    \\    "cloud.googleapis.com/location": "asia-south2",
    \\    "cloud.googleapis.com/region": "asia-south2"
    \\   },
    \\   "locationId": "asia-south2",
    \\   "displayName": "Delhi"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-north1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "europe-north1",
    \\    "cloud.googleapis.com/location": "europe-north1",
    \\    "cloud.googleapis.com/country": "FI"
    \\   },
    \\   "locationId": "europe-north1",
    \\   "displayName": "Finland"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "BE",
    \\    "cloud.googleapis.com/region": "europe-west1",
    \\    "cloud.googleapis.com/location": "europe-west1"
    \\   },
    \\   "locationId": "europe-west1",
    \\   "displayName": "Belgium"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west2",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "europe-west2",
    \\    "cloud.googleapis.com/country": "GB",
    \\    "cloud.googleapis.com/location": "europe-west2"
    \\   },
    \\   "locationId": "europe-west2",
    \\   "displayName": "London"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west3",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "europe-west3",
    \\    "cloud.googleapis.com/country": "DE",
    \\    "cloud.googleapis.com/region": "europe-west3"
    \\   },
    \\   "locationId": "europe-west3",
    \\   "displayName": "Frankfurt"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west4",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "europe-west4",
    \\    "cloud.googleapis.com/country": "NL",
    \\    "cloud.googleapis.com/location": "europe-west4"
    \\   },
    \\   "locationId": "europe-west4",
    \\   "displayName": "Netherlands"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west6",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "europe-west6",
    \\    "cloud.googleapis.com/country": "CH",
    \\    "cloud.googleapis.com/region": "europe-west6"
    \\   },
    \\   "locationId": "europe-west6",
    \\   "displayName": "Zurich"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-central2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "europe-central2",
    \\    "cloud.googleapis.com/region": "europe-central2",
    \\    "cloud.googleapis.com/country": "PL"
    \\   },
    \\   "locationId": "europe-central2",
    \\   "displayName": "Warsaw"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west9",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "FR",
    \\    "cloud.googleapis.com/region": "europe-west9",
    \\    "cloud.googleapis.com/location": "europe-west9"
    \\   },
    \\   "locationId": "europe-west9",
    \\   "displayName": "Paris"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west8",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "europe-west8",
    \\    "cloud.googleapis.com/country": "IT",
    \\    "cloud.googleapis.com/region": "europe-west8"
    \\   },
    \\   "locationId": "europe-west8",
    \\   "displayName": "Milan"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-southwest1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "ES",
    \\    "cloud.googleapis.com/location": "europe-southwest1",
    \\    "cloud.googleapis.com/region": "europe-southwest1"
    \\   },
    \\   "locationId": "europe-southwest1",
    \\   "displayName": "Madrid"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west10",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "europe-west10",
    \\    "cloud.googleapis.com/location": "europe-west10",
    \\    "cloud.googleapis.com/country": "DE"
    \\   },
    \\   "locationId": "europe-west10",
    \\   "displayName": "Berlin"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-west12",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "IT",
    \\    "cloud.googleapis.com/location": "europe-west12",
    \\    "cloud.googleapis.com/region": "europe-west12"
    \\   },
    \\   "locationId": "europe-west12",
    \\   "displayName": "Turin"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/northamerica-northeast1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "northamerica-northeast1",
    \\    "cloud.googleapis.com/country": "CA",
    \\    "cloud.googleapis.com/location": "northamerica-northeast1"
    \\   },
    \\   "locationId": "northamerica-northeast1",
    \\   "displayName": "Montréal"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/northamerica-northeast2",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "CA",
    \\    "cloud.googleapis.com/region": "northamerica-northeast2",
    \\    "cloud.googleapis.com/location": "northamerica-northeast2"
    \\   },
    \\   "locationId": "northamerica-northeast2",
    \\   "displayName": "Toronto"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/southamerica-east1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "BR",
    \\    "cloud.googleapis.com/location": "southamerica-east1",
    \\    "cloud.googleapis.com/region": "southamerica-east1"
    \\   },
    \\   "locationId": "southamerica-east1",
    \\   "displayName": "São Paulo"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/southamerica-west1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "CL",
    \\    "cloud.googleapis.com/location": "southamerica-west1",
    \\    "cloud.googleapis.com/region": "southamerica-west1"
    \\   },
    \\   "locationId": "southamerica-west1",
    \\   "displayName": "Santiago"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/australia-southeast1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "australia-southeast1",
    \\    "cloud.googleapis.com/location": "australia-southeast1",
    \\    "cloud.googleapis.com/country": "AU"
    \\   },
    \\   "locationId": "australia-southeast1",
    \\   "displayName": "Sydney"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/australia-southeast2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "australia-southeast2",
    \\    "cloud.googleapis.com/region": "australia-southeast2",
    \\    "cloud.googleapis.com/country": "AU"
    \\   },
    \\   "locationId": "australia-southeast2",
    \\   "displayName": "Melbourne"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/me-central2",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "SA",
    \\    "cloud.googleapis.com/location": "me-central2",
    \\    "cloud.googleapis.com/region": "me-central2"
    \\   },
    \\   "locationId": "me-central2",
    \\   "displayName": "Dammam"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/me-west1",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "me-west1",
    \\    "cloud.googleapis.com/country": "IL",
    \\    "cloud.googleapis.com/region": "me-west1"
    \\   },
    \\   "locationId": "me-west1",
    \\   "displayName": "Tel Aviv"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/me-central1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "me-central1",
    \\    "cloud.googleapis.com/country": "QA",
    \\    "cloud.googleapis.com/location": "me-central1"
    \\   },
    \\   "locationId": "me-central1",
    \\   "displayName": "Doha"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/africa-south1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "africa-south1",
    \\    "cloud.googleapis.com/location": "africa-south1",
    \\    "cloud.googleapis.com/country": "ZA"
    \\   },
    \\   "locationId": "africa-south1",
    \\   "displayName": "Johannesburg"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/aws-eu-central-1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "aws-eu-central-1",
    \\    "cloud.googleapis.com/location": "aws-eu-central-1"
    \\   },
    \\   "locationId": "aws-eu-central-1",
    \\   "displayName": "Amazon Europe (Frankfurt)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/aws-us-east-1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "aws-us-east-1",
    \\    "cloud.googleapis.com/location": "aws-us-east-1"
    \\   },
    \\   "locationId": "aws-us-east-1",
    \\   "displayName": "Amazon US East (N. Virginia)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/aws-us-west-2",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "aws-us-west-2",
    \\    "cloud.googleapis.com/location": "aws-us-west-2"
    \\   },
    \\   "locationId": "aws-us-west-2",
    \\   "displayName": "Amazon US West (Oregon)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/aws-ap-northeast-2",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "aws-ap-northeast-2",
    \\    "cloud.googleapis.com/location": "aws-ap-northeast-2"
    \\   },
    \\   "locationId": "aws-ap-northeast-2",
    \\   "displayName": "Amazon Asia Pacific (Seoul)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/aws-ap-southeast-2",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "aws-ap-southeast-2",
    \\    "cloud.googleapis.com/location": "aws-ap-southeast-2"
    \\   },
    \\   "locationId": "aws-ap-southeast-2",
    \\   "displayName": "Amazon Asia Pacific (Sydney)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/aws-eu-west-1",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "aws-eu-west-1",
    \\    "cloud.googleapis.com/location": "aws-eu-west-1"
    \\   },
    \\   "locationId": "aws-eu-west-1",
    \\   "displayName": "Amazon Europe (Ireland)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/azure-eastus2",
    \\   "labels": {
    \\    "cloud.googleapis.com/region": "azure-eastus2",
    \\    "cloud.googleapis.com/location": "azure-eastus2"
    \\   },
    \\   "locationId": "azure-eastus2",
    \\   "displayName": "Azure East US 2 (Virginia)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/azure-westus2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "azure-westus2",
    \\    "cloud.googleapis.com/region": "azure-westus2"
    \\   },
    \\   "locationId": "azure-westus2",
    \\   "displayName": "Azure West US 2 (Washington)"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/northamerica-south1",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "MX",
    \\    "cloud.googleapis.com/region": "northamerica-south1",
    \\    "cloud.googleapis.com/location": "northamerica-south1"
    \\   },
    \\   "locationId": "northamerica-south1",
    \\   "displayName": "Mexico"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/europe-north2",
    \\   "labels": {
    \\    "cloud.googleapis.com/location": "europe-north2",
    \\    "cloud.googleapis.com/region": "europe-north2",
    \\    "cloud.googleapis.com/country": "SE"
    \\   },
    \\   "locationId": "europe-north2",
    \\   "displayName": "Stockholm"
    \\  },
    \\  {
    \\   "name": "projects/extractctl/locations/asia-southeast3",
    \\   "labels": {
    \\    "cloud.googleapis.com/country": "TH",
    \\    "cloud.googleapis.com/location": "asia-southeast3",
    \\    "cloud.googleapis.com/region": "asia-southeast3"
    \\   },
    \\   "locationId": "asia-southeast3",
    \\   "displayName": "Bangkok"
    \\  }
    \\ ]
    \\}
;

/// projects.locations.get of us. HTTP 200.
pub const location_us_status = 200;
pub const location_us =
    \\{
    \\ "name": "projects/extractctl/locations/us",
    \\ "labels": {
    \\  "cloud.googleapis.com/country": "US",
    \\  "cloud.googleapis.com/location": "us"
    \\ },
    \\ "locationId": "us"
    \\}
;

/// projects.locations.list with pageSize=2: refused. HTTP 400.
pub const locations_page_size_status = 400;
pub const locations_page_size =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Request contains an invalid argument.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// The us configs: the probe's three, as a list carries them (no ownerInfo). HTTP 200.
pub const configs_page_status = 200;
pub const configs_page =
    \\{
    \\ "transferConfigs": [
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "displayName": "zigps-bd4dcf-manual",
    \\   "updateTime": "2026-10-21T18:44:55.812597Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "userId": "3050904112232290637",
    \\   "datasetRegion": "us",
    \\   "emailPreferences": {},
    \\   "scheduleOptions": {
    \\    "disableAutoScheduling": true
    \\   },
    \\   "scheduleOptionsV2": {
    \\    "manualSchedule": {}
    \\   }
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4f-0000-2bb7-b042-14223bbd2862",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "displayName": "zigps-bd4dcf-failing",
    \\   "updateTime": "2026-10-21T18:44:56.646726Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "query": "SELECT 1 / 0 AS x",
    \\    "destination_table_name_template": "zigps_failing_{run_date}"
    \\   },
    \\   "userId": "3050904112232290637",
    \\   "datasetRegion": "us",
    \\   "emailPreferences": {},
    \\   "scheduleOptions": {
    \\    "disableAutoScheduling": true
    \\   },
    \\   "scheduleOptionsV2": {
    \\    "manualSchedule": {}
    \\   }
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ae71a2f-0000-2481-a02b-fc41166ce871",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "displayName": "zigps-bd4dcf-scheduled",
    \\   "updateTime": "2026-10-21T18:44:56.336827Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "schedule": "every 24 hours",
    \\   "params": {
    \\    "write_disposition": "WRITE_APPEND",
    \\    "destination_table_name_template": "zigps_scheduled_{run_date}",
    \\    "query": "SELECT 2 AS x"
    \\   },
    \\   "userId": "3050904112232290637",
    \\   "disabled": true,
    \\   "datasetRegion": "us",
    \\   "emailPreferences": {},
    \\   "scheduleOptions": {},
    \\   "scheduleOptionsV2": {
    \\    "timeBasedSchedule": {
    \\     "schedule": "every 24 hours"
    \\    }
    \\   }
    \\  }
    \\ ]
    \\}
;

/// The us configs with pageSize=1: one, and a token. HTTP 200.
pub const configs_page_token_status = 200;
pub const configs_page_token =
    \\{
    \\ "transferConfigs": [
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "displayName": "zigps-bd4dcf-manual",
    \\   "updateTime": "2026-10-21T18:44:55.812597Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x"
    \\   },
    \\   "userId": "3050904112232290637",
    \\   "datasetRegion": "us",
    \\   "emailPreferences": {},
    \\   "scheduleOptions": {
    \\    "disableAutoScheduling": true
    \\   },
    \\   "scheduleOptionsV2": {
    \\    "manualSchedule": {}
    \\   }
    \\  }
    \\ ],
    \\ "nextPageToken": "COXm6Kbiy5cDEAE"
    \\}
;

/// A manual scheduled query (disableAutoScheduling), before its first run. HTTP 200.
pub const config_manual_status = 200;
pub const config_manual =
    \\{
    \\ "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862",
    \\ "destinationDatasetId": "zigps_dt_bd4dcf",
    \\ "displayName": "zigps-bd4dcf-manual",
    \\ "updateTime": "2026-10-21T18:44:55.812597Z",
    \\ "dataSourceId": "scheduled_query",
    \\ "params": {
    \\  "destination_table_name_template": "zigps_manual_{run_date}",
    \\  "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\  "write_disposition": "WRITE_TRUNCATE"
    \\ },
    \\ "userId": "3050904112232290637",
    \\ "datasetRegion": "us",
    \\ "emailPreferences": {},
    \\ "scheduleOptions": {
    \\  "disableAutoScheduling": true
    \\ },
    \\ "ownerInfo": {
    \\  "email": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "scheduleOptionsV2": {
    \\  "manualSchedule": {}
    \\ }
    \\}
;

/// A scheduled query on every 24 hours, disabled. HTTP 200.
pub const config_scheduled_status = 200;
pub const config_scheduled =
    \\{
    \\ "name": "projects/82150720798/locations/us/transferConfigs/6ae71a2f-0000-2481-a02b-fc41166ce871",
    \\ "destinationDatasetId": "zigps_dt_bd4dcf",
    \\ "displayName": "zigps-bd4dcf-scheduled",
    \\ "updateTime": "2026-10-21T18:44:56.336827Z",
    \\ "dataSourceId": "scheduled_query",
    \\ "schedule": "every 24 hours",
    \\ "params": {
    \\  "query": "SELECT 2 AS x",
    \\  "write_disposition": "WRITE_APPEND",
    \\  "destination_table_name_template": "zigps_scheduled_{run_date}"
    \\ },
    \\ "userId": "3050904112232290637",
    \\ "disabled": true,
    \\ "datasetRegion": "us",
    \\ "emailPreferences": {},
    \\ "scheduleOptions": {},
    \\ "ownerInfo": {
    \\  "email": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "scheduleOptionsV2": {
    \\  "timeBasedSchedule": {
    \\   "schedule": "every 24 hours"
    \\  }
    \\ }
    \\}
;

/// The failing scheduled query, before its run. HTTP 200.
pub const config_failing_status = 200;
pub const config_failing =
    \\{
    \\ "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4f-0000-2bb7-b042-14223bbd2862",
    \\ "destinationDatasetId": "zigps_dt_bd4dcf",
    \\ "displayName": "zigps-bd4dcf-failing",
    \\ "updateTime": "2026-10-21T18:44:56.646726Z",
    \\ "dataSourceId": "scheduled_query",
    \\ "params": {
    \\  "destination_table_name_template": "zigps_failing_{run_date}",
    \\  "query": "SELECT 1 / 0 AS x",
    \\  "write_disposition": "WRITE_TRUNCATE"
    \\ },
    \\ "userId": "3050904112232290637",
    \\ "datasetRegion": "us",
    \\ "emailPreferences": {},
    \\ "scheduleOptions": {
    \\  "disableAutoScheduling": true
    \\ },
    \\ "ownerInfo": {
    \\  "email": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "scheduleOptionsV2": {
    \\  "manualSchedule": {}
    \\ }
    \\}
;

/// The manual config after its runs: its latest run's state. HTTP 200.
pub const config_after_runs_status = 200;
pub const config_after_runs =
    \\{
    \\ "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862",
    \\ "destinationDatasetId": "zigps_dt_bd4dcf",
    \\ "displayName": "zigps-bd4dcf-manual",
    \\ "updateTime": "2026-10-21T18:44:55.812597Z",
    \\ "dataSourceId": "scheduled_query",
    \\ "params": {
    \\  "write_disposition": "WRITE_TRUNCATE",
    \\  "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\  "destination_table_name_template": "zigps_manual_{run_date}"
    \\ },
    \\ "state": "SUCCEEDED",
    \\ "userId": "3050904112232290637",
    \\ "datasetRegion": "us",
    \\ "emailPreferences": {},
    \\ "scheduleOptions": {
    \\  "disableAutoScheduling": true
    \\ },
    \\ "ownerInfo": {
    \\  "email": "zig-gcp@extractctl.iam.gserviceaccount.com"
    \\ },
    \\ "scheduleOptionsV2": {
    \\  "manualSchedule": {}
    \\ }
    \\}
;

/// A config nobody has. HTTP 404.
pub const config_unknown_status = 404;
pub const config_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The requested transfer config (projects/extractctl/locations/us/transferConfigs/zigps-nobody) was not found.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// The manual config asked for in europe. HTTP 404.
pub const config_wrong_location_status = 404;
pub const config_wrong_location =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The requested transfer config (projects/extractctl/locations/europe/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862) was not found.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// A list of configs in a made-up location. HTTP 400.
pub const location_invalid_status = 400;
pub const location_invalid =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Request uses an invalid location: zz-nowhere1",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A list of configs in -. HTTP 400.
pub const location_dash_status = 400;
pub const location_dash =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "BigQuery Data Transfer Service does not yet support location: unknown",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// The manual config's eight runs, every attempt. HTTP 200.
pub const runs_page_status = 200;
pub const runs_page =
    \\{
    \\ "transferRuns": [
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6af3e99b-0000-2c02-b02c-582429bc99a4",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.267282Z",
    \\   "startTime": "2026-10-21T18:44:59.464655Z",
    \\   "endTime": "2026-10-21T18:46:14.464551Z",
    \\   "updateTime": "2026-10-21T18:46:14.464600Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "runTime": "2026-10-21T18:45:59.089657Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6adeae2f-0000-2ea4-b629-7474463ccf05",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.497504Z",
    \\   "startTime": "2026-10-21T18:44:59.753074Z",
    \\   "endTime": "2026-10-21T18:46:14.736961Z",
    \\   "updateTime": "2026-10-21T18:46:14.737001Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "destination_table_name_template": "zigps_manual_{run_date}",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "write_disposition": "WRITE_TRUNCATE"
    \\   },
    \\   "runTime": "2026-10-21T18:45:09.308250Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6aded3ab-0000-2be1-acc7-7474463f9305",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.744731Z",
    \\   "startTime": "2026-10-21T18:44:59.966987Z",
    \\   "endTime": "2026-10-21T18:46:14.953205Z",
    \\   "updateTime": "2026-10-21T18:46:14.953223Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "runTime": "2026-10-21T18:45:00.577027Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6ae65981-0000-2805-bdde-883d24fa83a4",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.019303Z",
    \\   "startTime": "2026-10-21T18:44:59.282036Z",
    \\   "endTime": "2026-10-21T18:46:14.215921Z",
    \\   "updateTime": "2026-10-21T18:46:14.215978Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "runTime": "2026-10-21T18:44:58.873464Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6adf9c99-0000-283f-a109-7474463caddd",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:45:00.552493Z",
    \\   "startTime": "2026-10-21T18:45:01.854968Z",
    \\   "endTime": "2026-10-21T18:46:15.761932Z",
    \\   "updateTime": "2026-10-21T18:46:15.761973Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "runTime": "2026-10-21T18:44:58Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6ad99c6d-0000-2bb7-b042-14223bbd2862",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:45:00.174878Z",
    \\   "startTime": "2026-10-21T18:45:00.359134Z",
    \\   "endTime": "2026-10-21T18:46:15.345024Z",
    \\   "updateTime": "2026-10-21T18:46:15.345060Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "runTime": "2026-10-21T18:44:29.844299Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6aee3ef0-0000-2edc-88df-582429c969a0",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.976653Z",
    \\   "startTime": "2026-10-21T18:45:00.221088Z",
    \\   "endTime": "2026-10-21T18:46:15.127046Z",
    \\   "updateTime": "2026-10-21T18:46:15.127080Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x"
    \\   },
    \\   "runTime": "2026-10-21T18:44:29.844299Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6ad9fe2d-0000-2cff-ab79-ac3eb1438058",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:45:00.345166Z",
    \\   "startTime": "2026-10-21T18:45:04.078022Z",
    \\   "endTime": "2026-10-21T18:46:15.494647Z",
    \\   "updateTime": "2026-10-21T18:46:15.494694Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x"
    \\   },
    \\   "runTime": "2026-10-20T00:00:00Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  }
    \\ ]
    \\}
;

/// The same with runAttempt=LATEST: one a run date. HTTP 200.
pub const runs_latest_status = 200;
pub const runs_latest =
    \\{
    \\ "transferRuns": [
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6af3e99b-0000-2c02-b02c-582429bc99a4",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.267282Z",
    \\   "startTime": "2026-10-21T18:44:59.464655Z",
    \\   "endTime": "2026-10-21T18:46:14.464551Z",
    \\   "updateTime": "2026-10-21T18:46:14.464600Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "runTime": "2026-10-21T18:45:59.089657Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6ad9fe2d-0000-2cff-ab79-ac3eb1438058",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:45:00.345166Z",
    \\   "startTime": "2026-10-21T18:45:04.078022Z",
    \\   "endTime": "2026-10-21T18:46:15.494647Z",
    \\   "updateTime": "2026-10-21T18:46:15.494694Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x"
    \\   },
    \\   "runTime": "2026-10-20T00:00:00Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  }
    \\ ]
    \\}
;

/// The same with pageSize=2: two, and a token. HTTP 200.
pub const runs_page_token_status = 200;
pub const runs_page_token =
    \\{
    \\ "transferRuns": [
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6af3e99b-0000-2c02-b02c-582429bc99a4",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.267282Z",
    \\   "startTime": "2026-10-21T18:44:59.464655Z",
    \\   "endTime": "2026-10-21T18:46:14.464551Z",
    \\   "updateTime": "2026-10-21T18:46:14.464600Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "destination_table_name_template": "zigps_manual_{run_date}",
    \\    "write_disposition": "WRITE_TRUNCATE"
    \\   },
    \\   "runTime": "2026-10-21T18:45:59.089657Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  },
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6adeae2f-0000-2ea4-b629-7474463ccf05",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.497504Z",
    \\   "startTime": "2026-10-21T18:44:59.753074Z",
    \\   "endTime": "2026-10-21T18:46:14.736961Z",
    \\   "updateTime": "2026-10-21T18:46:14.737001Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "SUCCEEDED",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x",
    \\    "destination_table_name_template": "zigps_manual_{run_date}"
    \\   },
    \\   "runTime": "2026-10-21T18:45:09.308250Z",
    \\   "userId": "3050904112232290637",
    \\   "errorStatus": {},
    \\   "emailPreferences": {}
    \\  }
    \\ ],
    \\ "nextPageToken": "CIeFzMziy5cDEAI"
    \\}
;

/// A states filter outside the enum. HTTP 400.
pub const runs_states_invalid_status = 400;
pub const runs_states_invalid =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value at 'states' (type.googleapis.com/google.cloud.bigquery.datatransfer.v1.TransferState), \"NOPE\"",
    \\  "status": "INVALID_ARGUMENT",
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\    "fieldViolations": [
    \\     {
    \\      "field": "states",
    \\      "description": "Invalid value at 'states' (type.googleapis.com/google.cloud.bigquery.datatransfer.v1.TransferState), \"NOPE\""
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A run that succeeded: errorStatus {}. HTTP 200.
pub const run_succeeded_status = 200;
pub const run_succeeded =
    \\{
    \\ "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6ae65981-0000-2805-bdde-883d24fa83a4",
    \\ "destinationDatasetId": "zigps_dt_bd4dcf",
    \\ "scheduleTime": "2026-10-21T18:44:59.019303Z",
    \\ "startTime": "2026-10-21T18:44:59.282036Z",
    \\ "endTime": "2026-10-21T18:46:14.215921Z",
    \\ "updateTime": "2026-10-21T18:46:14.215978Z",
    \\ "dataSourceId": "scheduled_query",
    \\ "state": "SUCCEEDED",
    \\ "params": {
    \\  "destination_table_name_template": "zigps_manual_{run_date}",
    \\  "write_disposition": "WRITE_TRUNCATE",
    \\  "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x"
    \\ },
    \\ "runTime": "2026-10-21T18:44:58.873464Z",
    \\ "userId": "3050904112232290637",
    \\ "errorStatus": {},
    \\ "emailPreferences": {}
    \\}
;

/// The failing config's run. HTTP 200.
pub const run_failed_status = 200;
pub const run_failed =
    \\{
    \\ "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4f-0000-2bb7-b042-14223bbd2862/runs/6adcc85e-0000-22a0-83a1-883d24f92054",
    \\ "destinationDatasetId": "zigps_dt_bd4dcf",
    \\ "scheduleTime": "2026-10-21T18:45:00.875659Z",
    \\ "startTime": "2026-10-21T18:45:03.738592Z",
    \\ "endTime": "2026-10-21T18:46:16.118005Z",
    \\ "updateTime": "2026-10-21T18:46:16.118058Z",
    \\ "dataSourceId": "scheduled_query",
    \\ "state": "FAILED",
    \\ "params": {
    \\  "write_disposition": "WRITE_TRUNCATE",
    \\  "destination_table_name_template": "zigps_failing_{run_date}",
    \\  "query": "SELECT 1 / 0 AS x"
    \\ },
    \\ "runTime": "2026-10-21T18:44:55.741321Z",
    \\ "userId": "3050904112232290637",
    \\ "errorStatus": {
    \\  "code": 3,
    \\  "message": "division by zero: 1 / 0; JobID: 82150720798:US.scheduled_query_6adcc85e-0000-22a0-83a1-883d24f92054"
    \\ },
    \\ "emailPreferences": {}
    \\}
;

/// A run nobody has. HTTP 404.
pub const run_unknown_status = 404;
pub const run_unknown =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The requested transfer run (projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/00000000-0000-0000-0000-000000000000) was not found.",
    \\  "status": "NOT_FOUND"
    \\ }
    \\}
;

/// The succeeded run's messages, newest first. HTTP 200.
pub const messages_succeeded_status = 200;
pub const messages_succeeded =
    \\{
    \\ "transferMessages": [
    \\  {
    \\   "messageTime": "2026-10-21T18:46:14.199552Z",
    \\   "severity": "INFO",
    \\   "messageText": "Summary: succeeded 1 jobs, failed 0 jobs."
    \\  },
    \\  {
    \\   "messageTime": "2026-10-21T18:46:01.325154Z",
    \\   "severity": "INFO",
    \\   "messageText": "Job scheduled_query_6ae65981-0000-2805-bdde-883d24fa83a4 (table zigps_manual_20261021) completed successfully."
    \\  },
    \\  {
    \\   "messageTime": "2026-10-21T18:45:01.109460Z",
    \\   "severity": "INFO",
    \\   "messageText": "Job scheduled_query_6ae65981-0000-2805-bdde-883d24fa83a4 (table zigps_manual_20261021) started."
    \\  },
    \\  {
    \\   "messageTime": "2026-10-21T18:44:59.397319Z",
    \\   "severity": "INFO",
    \\   "messageText": "Starting to process the query job with parameters @run_date=2026-10-21, @run_time=2026-10-21 18:44:58+00:00."
    \\  },
    \\  {
    \\   "messageTime": "2026-10-21T18:44:59.138445Z",
    \\   "severity": "INFO",
    \\   "messageText": "Dispatched run to data source with id 22427835434095732"
    \\  }
    \\ ]
    \\}
;

/// The failed run's ERROR messages. HTTP 200.
pub const messages_failed_error_status = 200;
pub const messages_failed_error =
    \\{
    \\ "transferMessages": [
    \\  {
    \\   "messageTime": "2026-10-21T18:46:09.548944Z",
    \\   "severity": "ERROR",
    \\   "messageText": "BigQuery job scheduled_query_6adcc85e-0000-22a0-83a1-883d24f92054 (table zigps_failing_20261021) failed with error INVALID_ARGUMENT: division by zero: 1 / 0; JobID: 82150720798:US.scheduled_query_6adcc85e-0000-22a0-83a1-883d24f92054. Check BigQuery job details for more information."
    \\  }
    \\ ]
    \\}
;

/// The succeeded run's messages with pageSize=1. HTTP 200.
pub const messages_page_token_status = 200;
pub const messages_page_token =
    \\{
    \\ "transferMessages": [
    \\  {
    \\   "messageTime": "2026-10-21T18:46:14.199552Z",
    \\   "severity": "INFO",
    \\   "messageText": "Summary: succeeded 1 jobs, failed 0 jobs."
    \\  }
    \\ ],
    \\ "nextPageToken": "CK3Xk83iy5cDEAE"
    \\}
;

/// A run now under the bigquery scope: one run, PENDING. HTTP 200.
pub const started_status = 200;
pub const started =
    \\{
    \\ "runs": [
    \\  {
    \\   "name": "projects/82150720798/locations/us/transferConfigs/6ad99c4e-0000-2bb7-b042-14223bbd2862/runs/6ae65981-0000-2805-bdde-883d24fa83a4",
    \\   "destinationDatasetId": "zigps_dt_bd4dcf",
    \\   "scheduleTime": "2026-10-21T18:44:59.019303638Z",
    \\   "updateTime": "2026-10-21T18:44:59.030348Z",
    \\   "dataSourceId": "scheduled_query",
    \\   "state": "PENDING",
    \\   "params": {
    \\    "write_disposition": "WRITE_TRUNCATE",
    \\    "destination_table_name_template": "zigps_manual_{run_date}",
    \\    "query": "SELECT @run_date AS d, @run_time AS t, 17 AS x"
    \\   },
    \\   "runTime": "2026-10-21T18:44:58.873464Z",
    \\   "userId": "3050904112232290637",
    \\   "emailPreferences": {}
    \\  }
    \\ ]
    \\}
;

/// A run now of the disabled config. HTTP 400.
pub const start_disabled_status = 400;
pub const start_disabled =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Transfer is disabled. Please enable the transfer config before starting transfer runs.",
    \\  "status": "INVALID_ARGUMENT"
    \\ }
    \\}
;

/// A run now under cloud-platform.read-only. HTTP 403.
pub const start_read_only_status = 403;
pub const start_read_only =
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
    \\     "method": "google.cloud.bigquery.datatransfer.v1.DataTransferService.StartManualTransferRuns",
    \\     "service": "bigquerydatatransfer.googleapis.com"
    \\    }
    \\   }
    \\  ]
    \\ }
    \\}
;
