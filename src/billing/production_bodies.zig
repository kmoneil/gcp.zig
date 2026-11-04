//! Answers production gave on 2026-11-04, measured in milestone 0 of the
//! billing spec (`_tmp/billing-m0/`) with the zig-gcp service account in
//! extractctl, for tests: pages read small, refusals, and a few Compute
//! Engine SKUs cut from the full pages, verbatim but for a final line
//! break. Test code only.

/// `services.list` with pageSize=3: the first three services by id, and a
/// next page token (the offset, base64).
pub const services_small_status = 200;
pub const services_small =
    \\{
    \\  "services": [
    \\    {
    \\      "name": "services/0017-8C5E-5B91",
    \\      "serviceId": "0017-8C5E-5B91",
    \\      "displayName": "OpenLogic CentOS 7.8 (v20200922) - Security Hardened",
    \\      "businessEntityName": "businessEntities/GCP"
    \\    },
    \\    {
    \\      "name": "services/002A-FAF7-9793",
    \\      "serviceId": "002A-FAF7-9793",
    \\      "displayName": "Single node file server",
    \\      "businessEntityName": "businessEntities/GCP"
    \\    },
    \\    {
    \\      "name": "services/0042-8437-FF55",
    \\      "serviceId": "0042-8437-FF55",
    \\      "displayName": "Adverity",
    \\      "businessEntityName": "businessEntities/GCP"
    \\    }
    \\  ],
    \\  "nextPageToken": "Mw=="
    \\}
;

/// The page after `services_small`.
pub const services_small_p2_status = 200;
pub const services_small_p2 =
    \\{
    \\  "services": [
    \\    {
    \\      "name": "services/005A-0B51-C56E",
    \\      "serviceId": "005A-0B51-C56E",
    \\      "displayName": "Metabase Data Visualization & BI Platform",
    \\      "businessEntityName": "businessEntities/GCP"
    \\    },
    \\    {
    \\      "name": "services/0069-3716-5463",
    \\      "serviceId": "0069-3716-5463",
    \\      "displayName": "Qubole Open Data Lake Platform",
    \\      "businessEntityName": "businessEntities/GCP"
    \\    },
    \\    {
    \\      "name": "services/008F-652C-F842",
    \\      "serviceId": "008F-652C-F842",
    \\      "displayName": "Nventify Imagizer",
    \\      "businessEntityName": "businessEntities/GCP"
    \\    }
    \\  ],
    \\  "nextPageToken": "Ng=="
    \\}
;

/// Compute Engine's SKUs with pageSize=2: a sole-tenancy premium and its
/// neighbour by id, each with one price entry effective at midnight in Los
/// Angeles today.
pub const skus_small_status = 200;
pub const skus_small =
    \\{
    \\  "skus": [
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0001-B904-8A40",
    \\      "skuId": "0001-B904-8A40",
    \\      "description": "Sole Tenancy Premium for C4 Sole Tenancy Instance Core running in Santiago",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "OnDemand"
    \\      },
    \\      "serviceRegions": [
    \\        "southamerica-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 4954950
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "southamerica-west1"
    \\        ]
    \\      }
    \\    },
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0001-FC8F-A9AF",
    \\      "skuId": "0001-FC8F-A9AF",
    \\      "description": "Spot Preemptible E2 Custom Instance Core running in Paris",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "Preemptible"
    \\      },
    \\      "serviceRegions": [
    \\        "europe-west9"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 14230000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "europe-west9"
    \\        ]
    \\      }
    \\    }
    \\  ],
    \\  "nextPageToken": "Mg=="
    \\}
;

/// The page after `skus_small`.
pub const skus_small_p2_status = 200;
pub const skus_small_p2 =
    \\{
    \\  "skus": [
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0006-C9C8-BB6F",
    \\      "skuId": "0006-C9C8-BB6F",
    \\      "description": "Commitment v1: Memory-optimized Cpu in Phoenix for 1 Year",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "Commit1Yr"
    \\      },
    \\      "serviceRegions": [
    \\        "us-west8"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 20550000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "us-west8"
    \\        ]
    \\      }
    \\    },
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0007-4724-5A32",
    \\      "skuId": "0007-4724-5A32",
    \\      "description": "Sole Tenancy Premium for C4 Sole Tenancy Instance Core running in Finland",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "OnDemand"
    \\      },
    \\      "serviceRegions": [
    \\        "europe-north1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 3815312
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "europe-north1"
    \\        ]
    \\      }
    \\    }
    \\  ],
    \\  "nextPageToken": "NA=="
    \\}
;

/// `skus_small` in EUR: prices converted (truncated), with the rate.
pub const skus_eur_status = 200;
pub const skus_eur =
    \\{
    \\  "skus": [
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0001-B904-8A40",
    \\      "skuId": "0001-B904-8A40",
    \\      "description": "Sole Tenancy Premium for C4 Sole Tenancy Instance Core running in Santiago",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "OnDemand"
    \\      },
    \\      "serviceRegions": [
    \\        "southamerica-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "EUR",
    \\                  "units": "0",
    \\                  "nanos": 4450040
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 0.89809999999983747,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "southamerica-west1"
    \\        ]
    \\      }
    \\    },
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0001-FC8F-A9AF",
    \\      "skuId": "0001-FC8F-A9AF",
    \\      "description": "Spot Preemptible E2 Custom Instance Core running in Paris",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "Preemptible"
    \\      },
    \\      "serviceRegions": [
    \\        "europe-west9"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "EUR",
    \\                  "units": "0",
    \\                  "nanos": 12779962
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 0.89809999999983747,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "europe-west9"
    \\        ]
    \\      }
    \\    }
    \\  ],
    \\  "nextPageToken": "Mg=="
    \\}
;

/// `skus_small` over October (startTime 2026-10-01T07:00:00Z, endTime
/// 2026-10-31T06:59:59Z): the second SKU's five price entries, the first
/// effective at the range's start.
pub const skus_october_status = 200;
pub const skus_october =
    \\{
    \\  "skus": [
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0001-B904-8A40",
    \\      "skuId": "0001-B904-8A40",
    \\      "description": "Sole Tenancy Premium for C4 Sole Tenancy Instance Core running in Santiago",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "OnDemand"
    \\      },
    \\      "serviceRegions": [
    \\        "southamerica-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 4954950
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-10-01T07:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "southamerica-west1"
    \\        ]
    \\      }
    \\    },
    \\    {
    \\      "name": "services/6F81-5844-456A/skus/0001-FC8F-A9AF",
    \\      "skuId": "0001-FC8F-A9AF",
    \\      "description": "Spot Preemptible E2 Custom Instance Core running in Paris",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "Preemptible"
    \\      },
    \\      "serviceRegions": [
    \\        "europe-west9"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 13620000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-10-01T07:00:00Z"
    \\        },
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 14300000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-10-05T07:00:00Z"
    \\        },
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 15020000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-10-12T07:00:00Z"
    \\        },
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 14270000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-10-19T07:00:00Z"
    \\        },
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 14980000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-10-26T07:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "europe-west9"
    \\        ]
    \\      }
    \\    }
    \\  ],
    \\  "nextPageToken": "Mg=="
    \\}
;

/// What production answers for a pageSize over 5000 or below 0, a page token it
/// did not make, a currency it does not know (lowercase included), a range that
/// starts in the future, ends before it starts, has an end and no start, or
/// crosses a month: the same bare 400.
pub const refusal_invalid_argument_status = 400;
pub const refusal_invalid_argument =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Request contains an invalid argument.",
    \\    "status": "INVALID_ARGUMENT"
    \\  }
    \\}
;

/// A service id nobody has, well-formed or not: 404.
pub const refusal_not_found_status = 404;
pub const refusal_not_found =
    \\{
    \\  "error": {
    \\    "code": 404,
    \\    "message": "Requested entity was not found.",
    \\    "status": "NOT_FOUND"
    \\  }
    \\}
;

/// A startTime that is not a timestamp: 400, the one refusal that says why.
pub const refusal_bad_time_status = 400;
pub const refusal_bad_time =
    \\{
    \\  "error": {
    \\    "code": 400,
    \\    "message": "Invalid value at 'start_time' (type.googleapis.com/google.protobuf.Timestamp), Field 'start_time', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset.",
    \\    "status": "INVALID_ARGUMENT",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.BadRequest",
    \\        "fieldViolations": [
    \\          {
    \\            "field": "start_time",
    \\            "description": "Invalid value at 'start_time' (type.googleapis.com/google.protobuf.Timestamp), Field 'start_time', Illegal timestamp format; timestamps must end with 'Z' or have a valid timezone offset."
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// A call with no credentials at all: 403.
pub const refusal_unregistered_status = 403;
pub const refusal_unregistered =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.",
    \\    "status": "PERMISSION_DENIED"
    \\  }
    \\}
;

/// Any call while the Cloud Billing API is off in the token's project: 403
/// `PERMISSION_DENIED` with reason `SERVICE_DISABLED`.
pub const refusal_service_disabled_status = 403;
pub const refusal_service_disabled =
    \\{
    \\  "error": {
    \\    "code": 403,
    \\    "message": "Cloud Billing API has not been used in project 82150720798 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/cloudbilling.googleapis.com/overview?project=82150720798 then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry.",
    \\    "status": "PERMISSION_DENIED",
    \\    "details": [
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\        "reason": "SERVICE_DISABLED",
    \\        "domain": "googleapis.com",
    \\        "metadata": {
    \\          "activationUrl": "https://console.developers.google.com/apis/api/cloudbilling.googleapis.com/overview?project=82150720798",
    \\          "consumer": "projects/82150720798",
    \\          "containerInfo": "82150720798",
    \\          "serviceTitle": "Cloud Billing API",
    \\          "service": "cloudbilling.googleapis.com"
    \\        }
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
    \\        "locale": "en-US",
    \\        "message": "Cloud Billing API has not been used in project 82150720798 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/cloudbilling.googleapis.com/overview?project=82150720798 then retry. If you enabled this API recently, wait a few minutes for the action to propagate to our systems and retry."
    \\      },
    \\      {
    \\        "@type": "type.googleapis.com/google.rpc.Help",
    \\        "links": [
    \\          {
    \\            "description": "Google developers console API activation",
    \\            "url": "https://console.developers.google.com/apis/api/cloudbilling.googleapis.com/overview?project=82150720798"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
;

/// E2's vCPU on demand in us-central1, us-east1 and us-west1, one SKU for the
/// three ("running in Americas").
pub const sku_e2_core_americas =
    \\{
    \\      "name": "services/6F81-5844-456A/skus/CF4E-A0C7-E3BF",
    \\      "skuId": "CF4E-A0C7-E3BF",
    \\      "description": "E2 Instance Core running in Americas",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "OnDemand"
    \\      },
    \\      "serviceRegions": [
    \\        "us-central1",
    \\        "us-east1",
    \\        "us-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 21811590
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "MULTI_REGIONAL",
    \\        "regions": [
    \\          "us-central1",
    \\          "us-east1",
    \\          "us-west1"
    \\        ]
    \\      }
    \\    }
;

/// E2's memory on demand, the same three regions.
pub const sku_e2_ram_americas =
    \\{
    \\      "name": "services/6F81-5844-456A/skus/F449-33EC-A5EF",
    \\      "skuId": "F449-33EC-A5EF",
    \\      "description": "E2 Instance Ram running in Americas",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "RAM",
    \\        "usageType": "OnDemand"
    \\      },
    \\      "serviceRegions": [
    \\        "us-central1",
    \\        "us-east1",
    \\        "us-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "GiBy.h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 2923530
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "gibibyte hour",
    \\            "baseUnit": "By.s",
    \\            "baseUnitDescription": "byte second",
    \\            "baseUnitConversionFactor": 3865470566400
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "MULTI_REGIONAL",
    \\        "regions": [
    \\          "us-central1",
    \\          "us-east1",
    \\          "us-west1"
    \\        ]
    \\      }
    \\    }
;

/// E2's vCPU as spot: "Spot Preemptible" in front, usage type Preemptible.
pub const sku_e2_spot_core_americas =
    \\{
    \\      "name": "services/6F81-5844-456A/skus/F179-E1EA-D97A",
    \\      "skuId": "F179-E1EA-D97A",
    \\      "description": "Spot Preemptible E2 Instance Core running in Americas",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "Preemptible"
    \\      },
    \\      "serviceRegions": [
    \\        "us-central1",
    \\        "us-east1",
    \\        "us-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 13090000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "MULTI_REGIONAL",
    \\        "regions": [
    \\          "us-central1",
    \\          "us-east1",
    \\          "us-west1"
    \\        ]
    \\      }
    \\    }
;

/// E2's memory as spot.
pub const sku_e2_spot_ram_americas =
    \\{
    \\      "name": "services/6F81-5844-456A/skus/9B1F-1E62-4061",
    \\      "skuId": "9B1F-1E62-4061",
    \\      "description": "Spot Preemptible E2 Instance Ram running in Americas",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "RAM",
    \\        "usageType": "Preemptible"
    \\      },
    \\      "serviceRegions": [
    \\        "us-central1",
    \\        "us-east1",
    \\        "us-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "GiBy.h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 1754000
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "gibibyte hour",
    \\            "baseUnit": "By.s",
    \\            "baseUnitDescription": "byte second",
    \\            "baseUnitConversionFactor": 3865470566400
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "MULTI_REGIONAL",
    \\        "regions": [
    \\          "us-central1",
    \\          "us-east1",
    \\          "us-west1"
    \\        ]
    \\      }
    \\    }
;

/// E2's vCPU on demand in europe-west1 alone.
pub const sku_e2_core_belgium =
    \\{
    \\      "name": "services/6F81-5844-456A/skus/9FE0-8F60-A9F0",
    \\      "skuId": "9FE0-8F60-A9F0",
    \\      "description": "E2 Instance Core running in EMEA",
    \\      "category": {
    \\        "serviceDisplayName": "Compute Engine",
    \\        "resourceFamily": "Compute",
    \\        "resourceGroup": "CPU",
    \\        "usageType": "OnDemand"
    \\      },
    \\      "serviceRegions": [
    \\        "europe-west1"
    \\      ],
    \\      "pricingInfo": [
    \\        {
    \\          "summary": "",
    \\          "pricingExpression": {
    \\            "usageUnit": "h",
    \\            "displayQuantity": 1,
    \\            "tieredRates": [
    \\              {
    \\                "startUsageAmount": 0,
    \\                "unitPrice": {
    \\                  "currencyCode": "USD",
    \\                  "units": "0",
    \\                  "nanos": 23993370
    \\                }
    \\              }
    \\            ],
    \\            "usageUnitDescription": "hour",
    \\            "baseUnit": "s",
    \\            "baseUnitDescription": "second",
    \\            "baseUnitConversionFactor": 3600
    \\          },
    \\          "currencyConversionRate": 1,
    \\          "effectiveTime": "2026-11-04T08:00:00Z"
    \\        }
    \\      ],
    \\      "serviceProviderName": "Google",
    \\      "geoTaxonomy": {
    \\        "type": "REGIONAL",
    \\        "regions": [
    \\          "europe-west1"
    \\        ]
    \\      }
    \\    }
;
