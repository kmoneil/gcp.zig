//! Answers production gave, for tests: on 2026-11-03 in milestone 0 of
//! the Compute Engine spec (`_tmp/compute-m0/`), in the extractctl
//! project, the probe's own `zigps-m0-` VMs, templates and refusals.
//! Key order as the wire had it; trimmed where a constant says so. Test
//! code only.

/// A spot e2-micro VM running, with a startup script, guest attributes on, a run limit and DELETE at it; `resourceStatus` carries its termination time. GET instance. HTTP 200.
pub const instance_spot_status = 200;
pub const instance_spot =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "6231655708778534534",
    \\ "creationTimestamp": "2026-11-03T10:31:05.869-08:00",
    \\ "name": "zigps-m0-11031830-a",
    \\ "tags": {
    \\  "fingerprint": "42WmSpB8rSM="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "RUNNING",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.0.13",
    \\   "name": "nic0",
    \\   "fingerprint": "2FVvlW2Vfn8=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-a",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "inPgXPhJXaM=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "3600",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "TERMINATE",
    \\  "automaticRestart": false,
    \\  "preemptible": true,
    \\  "provisioningModel": "SPOT",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "AMD Rome",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m0"
    \\ },
    \\ "labelFingerprint": "rNhSjTzLR00=",
    \\ "startRestricted": false,
    \\ "deletionProtection": false,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "GcTUWTqlCmA=",
    \\ "lastStartTimestamp": "2026-11-03T10:31:20.073-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  },
    \\  "scheduling": {
    \\   "terminationTimestamp": "2026-11-03T19:31:07.956607Z"
    \\  }
    \\ }
    \\}
;

/// A standard e2-micro VM running under deletion protection: provisioningModel STANDARD, though the insert sent none. GET instance. HTTP 200.
pub const instance_standard_status = 200;
pub const instance_standard =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "4150782279075468949",
    \\ "creationTimestamp": "2026-11-03T10:31:22.190-08:00",
    \\ "name": "zigps-m0-11031830-s",
    \\ "tags": {
    \\  "fingerprint": "42WmSpB8rSM="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "RUNNING",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.0.14",
    \\   "name": "nic0",
    \\   "fingerprint": "uyTHvb_NuCE=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-s",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "inPgXPhJXaM=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-s",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "3600",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "MIGRATE",
    \\  "automaticRestart": false,
    \\  "preemptible": false,
    \\  "provisioningModel": "STANDARD",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "Intel Broadwell",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m0"
    \\ },
    \\ "labelFingerprint": "rNhSjTzLR00=",
    \\ "startRestricted": false,
    \\ "deletionProtection": true,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "OaUidK-hDzU=",
    \\ "lastStartTimestamp": "2026-11-03T10:31:31.277-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  },
    \\  "scheduling": {
    \\   "terminationTimestamp": "2026-11-03T19:31:24.085471Z"
    \\  }
    \\ }
    \\}
;

/// The spot VM suspended, after its machine type was set to e2-small while stopped. GET instance. HTTP 200.
pub const instance_suspended_status = 200;
pub const instance_suspended =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "6231655708778534534",
    \\ "creationTimestamp": "2026-11-03T10:31:05.869-08:00",
    \\ "name": "zigps-m0-11031830-a",
    \\ "tags": {
    \\  "items": [
    \\   "zigps-probe"
    \\  ],
    \\  "fingerprint": "V8n1wV8vUmg="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-small",
    \\ "status": "SUSPENDED",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.0.13",
    \\   "name": "nic0",
    \\   "fingerprint": "2FVvlW2Vfn8=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-a",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "ZoWzZgwsD-M=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   },
    \\   {
    \\    "key": "zigps",
    \\    "value": "one"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "3600",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "TERMINATE",
    \\  "automaticRestart": false,
    \\  "preemptible": true,
    \\  "provisioningModel": "SPOT",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "Unknown CPU Platform",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m0",
    \\  "probe": "one"
    \\ },
    \\ "labelFingerprint": "ZjVmAPZeL3k=",
    \\ "startRestricted": false,
    \\ "deletionProtection": false,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "jF9SKNSnDZs=",
    \\ "lastStartTimestamp": "2026-11-03T10:37:07.207-08:00",
    \\ "lastStopTimestamp": "2026-11-03T10:36:38.877-08:00",
    \\ "lastSuspendedTimestamp": "2026-11-03T10:41:26.878-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  }
    \\ }
    \\}
;

/// A VM whose guest powered itself off: TERMINATED, no statusMessage, a lastStopTimestamp. GET instance. HTTP 200.
pub const instance_powered_off_status = 200;
pub const instance_powered_off =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "2198597245065467282",
    \\ "creationTimestamp": "2026-11-03T10:44:14.054-08:00",
    \\ "name": "zigps-m0-11031830-p",
    \\ "tags": {
    \\  "fingerprint": "42WmSpB8rSM="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "TERMINATED",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.15.235",
    \\   "name": "nic0",
    \\   "fingerprint": "JDj2qCEl_x4=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-p",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "tfySlSmG3wE=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\n# zigps m0: a guest that powers itself off, to see what that leaves.\nsleep 20\npoweroff\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-p",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "3600",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "TERMINATE",
    \\  "automaticRestart": false,
    \\  "preemptible": true,
    \\  "provisioningModel": "SPOT",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "Unknown CPU Platform",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m0"
    \\ },
    \\ "labelFingerprint": "rNhSjTzLR00=",
    \\ "startRestricted": false,
    \\ "deletionProtection": false,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "IXHPbKOB1wQ=",
    \\ "lastStartTimestamp": "2026-11-03T10:44:27.176-08:00",
    \\ "lastStopTimestamp": "2026-11-03T10:47:39.030-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  },
    \\  "scheduling": {
    \\   "terminationTimestamp": "2026-11-03T19:44:17.130950Z"
    \\  }
    \\ }
    \\}
;

/// A spot VM with a 120 s run limit and DELETE. GET instance. HTTP 200.
pub const instance_run_limit_status = 200;
pub const instance_run_limit =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "3881523147132343710",
    \\ "creationTimestamp": "2026-11-03T10:44:02.034-08:00",
    \\ "name": "zigps-m0-11031830-c",
    \\ "tags": {
    \\  "fingerprint": "42WmSpB8rSM="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "RUNNING",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.15.230",
    \\   "name": "nic0",
    \\   "fingerprint": "kXIQnPqvBsg=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-c",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "inPgXPhJXaM=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-c",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "120",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "TERMINATE",
    \\  "automaticRestart": false,
    \\  "preemptible": true,
    \\  "provisioningModel": "SPOT",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "AMD Rome",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m0"
    \\ },
    \\ "labelFingerprint": "rNhSjTzLR00=",
    \\ "startRestricted": false,
    \\ "deletionProtection": false,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "sehwremWKEE=",
    \\ "lastStartTimestamp": "2026-11-03T10:44:12.870-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  },
    \\  "scheduling": {
    \\   "terminationTimestamp": "2026-11-03T18:46:03.528938Z"
    \\  }
    \\ }
    \\}
;

/// A zone's list with nothing matching the filter: no `items` key at all. HTTP 200.
pub const instance_list_empty_status = 200;
pub const instance_list_empty =
    \\{
    \\ "kind": "compute#instanceList",
    \\ "id": "projects/extractctl/zones/us-central1-a/instances",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances"
    \\}
;

/// The aggregated list with both VMs in one zone; trimmed to that zone and two of the 131 empty zones' NO_RESULTS_ON_PAGE warnings. HTTP 200.
pub const aggregated_two_status = 200;
pub const aggregated_two =
    \\{
    \\ "kind": "compute#instanceAggregatedList",
    \\ "id": "projects/extractctl/aggregated/instances",
    \\ "items": {
    \\  "zones/us-central1-a": {
    \\   "instances": [
    \\    {
    \\     "kind": "compute#instance",
    \\     "id": "6231655708778534534",
    \\     "creationTimestamp": "2026-11-03T10:31:05.869-08:00",
    \\     "name": "zigps-m0-11031830-a",
    \\     "tags": {
    \\      "items": [
    \\       "zigps-probe"
    \\      ],
    \\      "fingerprint": "V8n1wV8vUmg="
    \\     },
    \\     "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\     "status": "RUNNING",
    \\     "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\     "networkInterfaces": [
    \\      {
    \\       "kind": "compute#networkInterface",
    \\       "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\       "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\       "networkIP": "10.128.0.13",
    \\       "name": "nic0",
    \\       "fingerprint": "2FVvlW2Vfn8=",
    \\       "stackType": "IPV4_ONLY"
    \\      }
    \\     ],
    \\     "disks": [
    \\      {
    \\       "kind": "compute#attachedDisk",
    \\       "type": "PERSISTENT",
    \\       "mode": "READ_WRITE",
    \\       "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-a",
    \\       "deviceName": "persistent-disk-0",
    \\       "index": 0,
    \\       "boot": true,
    \\       "autoDelete": true,
    \\       "licenses": [
    \\        "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\       ],
    \\       "interface": "SCSI",
    \\       "guestOsFeatures": [
    \\        {
    \\         "type": "UEFI_COMPATIBLE"
    \\        },
    \\        {
    \\         "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\        },
    \\        {
    \\         "type": "GVNIC"
    \\        },
    \\        {
    \\         "type": "SEV_CAPABLE"
    \\        },
    \\        {
    \\         "type": "SEV_LIVE_MIGRATABLE_V2"
    \\        },
    \\        {
    \\         "type": "SUSPEND_SAFE_FPR"
    \\        }
    \\       ],
    \\       "diskSizeGb": "10",
    \\       "architecture": "X86_64"
    \\      }
    \\     ],
    \\     "metadata": {
    \\      "kind": "compute#metadata",
    \\      "fingerprint": "ZoWzZgwsD-M=",
    \\      "items": [
    \\       {
    \\        "key": "startup-script",
    \\        "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\       },
    \\       {
    \\        "key": "enable-guest-attributes",
    \\        "value": "TRUE"
    \\       },
    \\       {
    \\        "key": "zigps",
    \\        "value": "one"
    \\       }
    \\      ]
    \\     },
    \\     "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\     "scheduling": {
    \\      "maxRunDuration": {
    \\       "seconds": "3600",
    \\       "nanos": 0
    \\      },
    \\      "onHostMaintenance": "TERMINATE",
    \\      "automaticRestart": false,
    \\      "preemptible": true,
    \\      "provisioningModel": "SPOT",
    \\      "instanceTerminationAction": "DELETE"
    \\     },
    \\     "cpuPlatform": "AMD Rome",
    \\     "labels": {
    \\      "purpose": "gcp-zig-test",
    \\      "tool": "compute-m0",
    \\      "probe": "one"
    \\     },
    \\     "labelFingerprint": "ZjVmAPZeL3k=",
    \\     "startRestricted": false,
    \\     "deletionProtection": false,
    \\     "shieldedInstanceConfig": {
    \\      "enableSecureBoot": false,
    \\      "enableVtpm": true,
    \\      "enableIntegrityMonitoring": true
    \\     },
    \\     "shieldedInstanceIntegrityPolicy": {
    \\      "updateAutoLearnPolicy": true
    \\     },
    \\     "fingerprint": "jDDY1tmXNI8=",
    \\     "lastStartTimestamp": "2026-11-03T10:31:20.073-08:00",
    \\     "satisfiesPzi": true,
    \\     "resourceStatus": {
    \\      "effectiveInstanceMetadata": {
    \\       "vmDnsSettingMetadataValue": "ZonalOnly",
    \\       "enableGuestAttributesMetadataValue": true
    \\      },
    \\      "scheduling": {
    \\       "terminationTimestamp": "2026-11-03T19:31:07.956607Z"
    \\      }
    \\     }
    \\    },
    \\    {
    \\     "kind": "compute#instance",
    \\     "id": "4150782279075468949",
    \\     "creationTimestamp": "2026-11-03T10:31:22.190-08:00",
    \\     "name": "zigps-m0-11031830-s",
    \\     "tags": {
    \\      "fingerprint": "42WmSpB8rSM="
    \\     },
    \\     "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\     "status": "RUNNING",
    \\     "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\     "networkInterfaces": [
    \\      {
    \\       "kind": "compute#networkInterface",
    \\       "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\       "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\       "networkIP": "10.128.0.14",
    \\       "name": "nic0",
    \\       "fingerprint": "uyTHvb_NuCE=",
    \\       "stackType": "IPV4_ONLY"
    \\      }
    \\     ],
    \\     "disks": [
    \\      {
    \\       "kind": "compute#attachedDisk",
    \\       "type": "PERSISTENT",
    \\       "mode": "READ_WRITE",
    \\       "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-s",
    \\       "deviceName": "persistent-disk-0",
    \\       "index": 0,
    \\       "boot": true,
    \\       "autoDelete": true,
    \\       "licenses": [
    \\        "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\       ],
    \\       "interface": "SCSI",
    \\       "guestOsFeatures": [
    \\        {
    \\         "type": "UEFI_COMPATIBLE"
    \\        },
    \\        {
    \\         "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\        },
    \\        {
    \\         "type": "GVNIC"
    \\        },
    \\        {
    \\         "type": "SEV_CAPABLE"
    \\        },
    \\        {
    \\         "type": "SEV_LIVE_MIGRATABLE_V2"
    \\        },
    \\        {
    \\         "type": "SUSPEND_SAFE_FPR"
    \\        }
    \\       ],
    \\       "diskSizeGb": "10",
    \\       "architecture": "X86_64"
    \\      }
    \\     ],
    \\     "metadata": {
    \\      "kind": "compute#metadata",
    \\      "fingerprint": "inPgXPhJXaM=",
    \\      "items": [
    \\       {
    \\        "key": "startup-script",
    \\        "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\       },
    \\       {
    \\        "key": "enable-guest-attributes",
    \\        "value": "TRUE"
    \\       }
    \\      ]
    \\     },
    \\     "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-s",
    \\     "scheduling": {
    \\      "maxRunDuration": {
    \\       "seconds": "3600",
    \\       "nanos": 0
    \\      },
    \\      "onHostMaintenance": "MIGRATE",
    \\      "automaticRestart": false,
    \\      "preemptible": false,
    \\      "provisioningModel": "STANDARD",
    \\      "instanceTerminationAction": "DELETE"
    \\     },
    \\     "cpuPlatform": "Intel Broadwell",
    \\     "labels": {
    \\      "purpose": "gcp-zig-test",
    \\      "tool": "compute-m0"
    \\     },
    \\     "labelFingerprint": "rNhSjTzLR00=",
    \\     "startRestricted": false,
    \\     "deletionProtection": true,
    \\     "shieldedInstanceConfig": {
    \\      "enableSecureBoot": false,
    \\      "enableVtpm": true,
    \\      "enableIntegrityMonitoring": true
    \\     },
    \\     "shieldedInstanceIntegrityPolicy": {
    \\      "updateAutoLearnPolicy": true
    \\     },
    \\     "fingerprint": "OaUidK-hDzU=",
    \\     "lastStartTimestamp": "2026-11-03T10:31:31.277-08:00",
    \\     "satisfiesPzi": true,
    \\     "resourceStatus": {
    \\      "effectiveInstanceMetadata": {
    \\       "vmDnsSettingMetadataValue": "ZonalOnly",
    \\       "enableGuestAttributesMetadataValue": true
    \\      },
    \\      "scheduling": {
    \\       "terminationTimestamp": "2026-11-03T19:31:24.085471Z"
    \\      }
    \\     }
    \\    }
    \\   ]
    \\  },
    \\  "zones/us-central1-b": {
    \\   "warning": {
    \\    "code": "NO_RESULTS_ON_PAGE",
    \\    "message": "No results for the scope 'zones/us-central1-b'.",
    \\    "data": [
    \\     {
    \\      "key": "scope",
    \\      "value": "zones/us-central1-b"
    \\     }
    \\    ]
    \\   }
    \\  },
    \\  "zones/europe-west1-b": {
    \\   "warning": {
    \\    "code": "NO_RESULTS_ON_PAGE",
    \\    "message": "No results for the scope 'zones/europe-west1-b'.",
    \\    "data": [
    \\     {
    \\      "key": "scope",
    \\      "value": "zones/europe-west1-b"
    \\     }
    \\    ]
    \\   }
    \\  }
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/aggregated/instances"
    \\}
;

/// The aggregated list with `maxResults=1`: one VM and a token for the next; trimmed to its first two scopes. HTTP 200.
pub const aggregated_page_status = 200;
pub const aggregated_page =
    \\{
    \\ "kind": "compute#instanceAggregatedList",
    \\ "id": "projects/extractctl/aggregated/instances",
    \\ "items": {
    \\  "zones/us-central1-a": {
    \\   "instances": [
    \\    {
    \\     "kind": "compute#instance",
    \\     "id": "6231655708778534534",
    \\     "creationTimestamp": "2026-11-03T10:31:05.869-08:00",
    \\     "name": "zigps-m0-11031830-a",
    \\     "tags": {
    \\      "items": [
    \\       "zigps-probe"
    \\      ],
    \\      "fingerprint": "V8n1wV8vUmg="
    \\     },
    \\     "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\     "status": "RUNNING",
    \\     "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\     "networkInterfaces": [
    \\      {
    \\       "kind": "compute#networkInterface",
    \\       "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\       "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\       "networkIP": "10.128.0.13",
    \\       "name": "nic0",
    \\       "fingerprint": "2FVvlW2Vfn8=",
    \\       "stackType": "IPV4_ONLY"
    \\      }
    \\     ],
    \\     "disks": [
    \\      {
    \\       "kind": "compute#attachedDisk",
    \\       "type": "PERSISTENT",
    \\       "mode": "READ_WRITE",
    \\       "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-a",
    \\       "deviceName": "persistent-disk-0",
    \\       "index": 0,
    \\       "boot": true,
    \\       "autoDelete": true,
    \\       "licenses": [
    \\        "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\       ],
    \\       "interface": "SCSI",
    \\       "guestOsFeatures": [
    \\        {
    \\         "type": "UEFI_COMPATIBLE"
    \\        },
    \\        {
    \\         "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\        },
    \\        {
    \\         "type": "GVNIC"
    \\        },
    \\        {
    \\         "type": "SEV_CAPABLE"
    \\        },
    \\        {
    \\         "type": "SEV_LIVE_MIGRATABLE_V2"
    \\        },
    \\        {
    \\         "type": "SUSPEND_SAFE_FPR"
    \\        }
    \\       ],
    \\       "diskSizeGb": "10",
    \\       "architecture": "X86_64"
    \\      }
    \\     ],
    \\     "metadata": {
    \\      "kind": "compute#metadata",
    \\      "fingerprint": "ZoWzZgwsD-M=",
    \\      "items": [
    \\       {
    \\        "key": "startup-script",
    \\        "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\       },
    \\       {
    \\        "key": "enable-guest-attributes",
    \\        "value": "TRUE"
    \\       },
    \\       {
    \\        "key": "zigps",
    \\        "value": "one"
    \\       }
    \\      ]
    \\     },
    \\     "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\     "scheduling": {
    \\      "maxRunDuration": {
    \\       "seconds": "3600",
    \\       "nanos": 0
    \\      },
    \\      "onHostMaintenance": "TERMINATE",
    \\      "automaticRestart": false,
    \\      "preemptible": true,
    \\      "provisioningModel": "SPOT",
    \\      "instanceTerminationAction": "DELETE"
    \\     },
    \\     "cpuPlatform": "AMD Rome",
    \\     "labels": {
    \\      "purpose": "gcp-zig-test",
    \\      "tool": "compute-m0",
    \\      "probe": "one"
    \\     },
    \\     "labelFingerprint": "ZjVmAPZeL3k=",
    \\     "startRestricted": false,
    \\     "deletionProtection": false,
    \\     "shieldedInstanceConfig": {
    \\      "enableSecureBoot": false,
    \\      "enableVtpm": true,
    \\      "enableIntegrityMonitoring": true
    \\     },
    \\     "shieldedInstanceIntegrityPolicy": {
    \\      "updateAutoLearnPolicy": true
    \\     },
    \\     "fingerprint": "jDDY1tmXNI8=",
    \\     "lastStartTimestamp": "2026-11-03T10:31:20.073-08:00",
    \\     "satisfiesPzi": true,
    \\     "resourceStatus": {
    \\      "effectiveInstanceMetadata": {
    \\       "vmDnsSettingMetadataValue": "ZonalOnly",
    \\       "enableGuestAttributesMetadataValue": true
    \\      },
    \\      "scheduling": {
    \\       "terminationTimestamp": "2026-11-03T19:31:07.956607Z"
    \\      }
    \\     }
    \\    }
    \\   ]
    \\  },
    \\  "zones/us-central1-b": {
    \\   "warning": {
    \\    "code": "NO_RESULTS_ON_PAGE",
    \\    "message": "No results for the scope 'zones/us-central1-b'.",
    \\    "data": [
    \\     {
    \\      "key": "scope",
    \\      "value": "zones/us-central1-b"
    \\     }
    \\    ]
    \\   }
    \\  }
    \\ },
    \\ "nextPageToken": "CgsIAxHQBwAAAAAAABJKCkgIyK6sv7jslwM6PQoCGAMKAyDQDwoCGAIKByCeisKEsgIKAhgHChUqE3ppZ3BzLW0wLTExMDMxODMwLWEKCiCGrZ6im7vSvVY=",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/aggregated/instances"
    \\}
;

/// An insert's operation as the insert answered it: RUNNING, progress 0, the requestId as clientOperationId. HTTP 200.
pub const operation_running_status = 200;
pub const operation_running =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "1768060824142190214",
    \\ "name": "operation-1793730664860-65f63771a0c50-6411bc86-75804f1f",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "8068f1b8-03fc-4f7f-a5bd-d5e775aa7212",
    \\ "operationType": "insert",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T10:31:05.966-08:00",
    \\ "startTime": "2026-11-03T10:31:06.043-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793730664860-65f63771a0c50-6411bc86-75804f1f"
    \\}
;

/// The same operation, DONE, as a wait on it answered. HTTP 200.
pub const operation_done_status = 200;
pub const operation_done =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "1768060824142190214",
    \\ "name": "operation-1793730664860-65f63771a0c50-6411bc86-75804f1f",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "8068f1b8-03fc-4f7f-a5bd-d5e775aa7212",
    \\ "operationType": "insert",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T10:31:05.966-08:00",
    \\ "startTime": "2026-11-03T10:31:06.043-08:00",
    \\ "endTime": "2026-11-03T10:31:20.145-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793730664860-65f63771a0c50-6411bc86-75804f1f"
    \\}
;

/// setMachineType on a running VM: the call succeeded and its operation ended DONE with UNSUPPORTED_OPERATION, httpErrorStatusCode 400. HTTP 200.
pub const operation_failed_status = 200;
pub const operation_failed =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "3480822730143012448",
    \\ "name": "operation-1793730703375-65f637965bd45-eca7bc92-ba81db36",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "af9aa1bd-6032-4003-a147-caf9d92ea748",
    \\ "operationType": "setMachineType",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T10:31:43.712-08:00",
    \\ "startTime": "2026-11-03T10:31:43.753-08:00",
    \\ "endTime": "2026-11-03T10:31:44.009-08:00",
    \\ "error": {
    \\  "errors": [
    \\   {
    \\    "code": "UNSUPPORTED_OPERATION",
    \\    "message": "Instance is starting or running."
    \\   }
    \\  ]
    \\ },
    \\ "httpErrorStatusCode": 400,
    \\ "httpErrorMessage": "BAD REQUEST",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793730703375-65f637965bd45-eca7bc92-ba81db36"
    \\}
;

/// A spot VM's suspend as the first wait answered it, two minutes in: still RUNNING. HTTP 200.
pub const operation_suspending_status = 200;
pub const operation_suspending =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "3638997334748534584",
    \\ "name": "operation-1793731031246-65f638cf0a81b-79f0a9fe-430e264e",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "39441b28-8485-4937-8bcb-765b0627c842",
    \\ "operationType": "suspend",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T10:37:11.433-08:00",
    \\ "startTime": "2026-11-03T10:37:11.452-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793731031246-65f638cf0a81b-79f0a9fe-430e264e"
    \\}
;

/// A zone's operations filtered to one VM, after it was preempted; trimmed to the insert, a setLabels and the preemption. HTTP 200.
pub const operation_list_status = 200;
pub const operation_list =
    \\{
    \\ "kind": "compute#operationList",
    \\ "id": "projects/extractctl/zones/us-central1-a/operations",
    \\ "items": [
    \\  {
    \\   "kind": "compute#operation",
    \\   "id": "1768060824142190214",
    \\   "name": "operation-1793730664860-65f63771a0c50-6411bc86-75804f1f",
    \\   "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\   "clientOperationId": "8068f1b8-03fc-4f7f-a5bd-d5e775aa7212",
    \\   "operationType": "insert",
    \\   "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\   "targetId": "6231655708778534534",
    \\   "status": "DONE",
    \\   "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "progress": 100,
    \\   "insertTime": "2026-11-03T10:31:05.966-08:00",
    \\   "startTime": "2026-11-03T10:31:06.043-08:00",
    \\   "endTime": "2026-11-03T10:31:20.145-08:00",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793730664860-65f63771a0c50-6411bc86-75804f1f"
    \\  },
    \\  {
    \\   "kind": "compute#operation",
    \\   "id": "5121953944675260011",
    \\   "name": "operation-1793730692192-65f6378bb1720-4518b57a-22dbde53",
    \\   "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\   "clientOperationId": "209fc6b5-b2df-4310-810b-45dac00eac2f",
    \\   "operationType": "compute.instance.setLabels",
    \\   "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\   "targetId": "6231655708778534534",
    \\   "status": "DONE",
    \\   "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\   "progress": 100,
    \\   "insertTime": "2026-11-03T10:31:32.431-08:00",
    \\   "startTime": "2026-11-03T10:31:32.433-08:00",
    \\   "endTime": "2026-11-03T10:31:34.654-08:00",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793730692192-65f6378bb1720-4518b57a-22dbde53"
    \\  },
    \\  {
    \\   "kind": "compute#operation",
    \\   "id": "5737672884202476455",
    \\   "name": "systemevent-1793731884335-65f63bfc9c0bb-e6366a68-459c7699",
    \\   "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\   "operationType": "compute.instances.preempted",
    \\   "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\   "targetId": "6231655708778534534",
    \\   "status": "DONE",
    \\   "statusMessage": "Instance was preempted.",
    \\   "user": "system",
    \\   "progress": 100,
    \\   "insertTime": "2026-11-03T10:51:52.409-08:00",
    \\   "startTime": "2026-11-03T10:51:52.431-08:00",
    \\   "endTime": "2026-11-03T10:52:04.239-08:00",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/systemevent-1793731884335-65f63bfc9c0bb-e6366a68-459c7699"
    \\  }
    \\ ],
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations"
    \\}
;

/// A serial console read from 0 after 2.8 MB were written: moved up to the oldest byte kept; contents trimmed from 1 MiB to two lines. HTTP 200.
pub const serial_tail_status = 200;
pub const serial_tail =
    \\{
    \\ "kind": "compute#serialPortOutput",
    \\ "contents": "zigps-m0 serial line 18234 000000000000000000000000000000000000000000000000000000000000\r\nzigps-m0 serial line 18235 000000000000000000000000000000000000000000000000000000000000\r\n",
    \\ "start": "1765733",
    \\ "next": "2814309",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a/serialPortOutput"
    \\}
;

/// A serial console read from `next` with nothing new: no bytes, `next` unchanged. HTTP 200.
pub const serial_nothing_new_status = 200;
pub const serial_nothing_new =
    \\{
    \\ "kind": "compute#serialPortOutput",
    \\ "contents": "",
    \\ "start": "2814309",
    \\ "next": "2814309",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a/serialPortOutput"
    \\}
;

/// Guest attributes under `zigps/`, one the guest wrote. HTTP 200.
pub const guest_attributes_status = 200;
pub const guest_attributes =
    \\{
    \\ "kind": "compute#guestAttributes",
    \\ "queryPath": "zigps/",
    \\ "queryValue": {
    \\  "items": [
    \\   {
    \\    "namespace": "zigps",
    \\    "key": "probe",
    \\    "value": "ready"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a/guestAttributes/zigps/"
    \\}
;

/// A zone. HTTP 200.
pub const zone_status = 200;
pub const zone =
    \\{
    \\ "kind": "compute#zone",
    \\ "id": "2000",
    \\ "creationTimestamp": "1969-12-31T16:00:00.000-08:00",
    \\ "name": "us-central1-a",
    \\ "description": "us-central1-a",
    \\ "status": "UP",
    \\ "region": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "availableCpuPlatforms": [
    \\  "Ampere Altra",
    \\  "ARM Generic",
    \\  "Intel Broadwell",
    \\  "Intel Cascade Lake",
    \\  "Intel Emerald Rapids",
    \\  "AMD Genoa",
    \\  "NVIDIA Grace",
    \\  "Intel Granite Rapids",
    \\  "Intel Haswell",
    \\  "Intel Ice Lake",
    \\  "Intel Ivy Bridge",
    \\  "Google Axion",
    \\  "AMD Milan",
    \\  "AMD Rome",
    \\  "Intel Sandy Bridge",
    \\  "Intel Sapphire Rapids",
    \\  "Intel Skylake",
    \\  "Google Axion",
    \\  "AMD Turin"
    \\ ],
    \\ "supportsPzs": true
    \\}
;

/// A machine type. HTTP 200.
pub const machine_type_status = 200;
pub const machine_type =
    \\{
    \\ "kind": "compute#machineType",
    \\ "id": "334002",
    \\ "creationTimestamp": "1969-12-31T16:00:00.000-08:00",
    \\ "name": "e2-micro",
    \\ "description": "Efficient Instance, 2 vCPU (1/8 shared physical core) and 1 GB RAM",
    \\ "guestCpus": 2,
    \\ "memoryMb": 1024,
    \\ "imageSpaceGb": 0,
    \\ "maximumPersistentDisks": 16,
    \\ "maximumPersistentDisksSizeGb": "3072",
    \\ "zone": "us-central1-a",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "isSharedCpu": true
    \\}
;

/// A page of machine types with `maxResults=5`, and a token. HTTP 200.
pub const machine_type_page_status = 200;
pub const machine_type_page =
    \\{
    \\ "kind": "compute#machineTypeList",
    \\ "id": "projects/extractctl/zones/us-central1-a/machineTypes",
    \\ "items": [
    \\  {
    \\   "kind": "compute#machineType",
    \\   "id": "1000012",
    \\   "creationTimestamp": "1969-12-31T16:00:00.000-08:00",
    \\   "name": "a2-highgpu-1g",
    \\   "description": "Accelerator Optimized: 1 NVIDIA Tesla A100 GPU, 12 vCPUs, 85GB RAM",
    \\   "guestCpus": 12,
    \\   "memoryMb": 87040,
    \\   "imageSpaceGb": 0,
    \\   "maximumPersistentDisks": 128,
    \\   "maximumPersistentDisksSizeGb": "263168",
    \\   "zone": "us-central1-a",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/a2-highgpu-1g",
    \\   "isSharedCpu": false,
    \\   "accelerators": [
    \\    {
    \\     "guestAcceleratorType": "nvidia-tesla-a100",
    \\     "guestAcceleratorCount": 1
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "kind": "compute#machineType",
    \\   "id": "1000024",
    \\   "creationTimestamp": "1969-12-31T16:00:00.000-08:00",
    \\   "name": "a2-highgpu-2g",
    \\   "description": "Accelerator Optimized: 2 NVIDIA Tesla A100 GPUs, 24 vCPUs, 170GB RAM",
    \\   "guestCpus": 24,
    \\   "memoryMb": 174080,
    \\   "imageSpaceGb": 0,
    \\   "maximumPersistentDisks": 128,
    \\   "maximumPersistentDisksSizeGb": "263168",
    \\   "zone": "us-central1-a",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/a2-highgpu-2g",
    \\   "isSharedCpu": false,
    \\   "accelerators": [
    \\    {
    \\     "guestAcceleratorType": "nvidia-tesla-a100",
    \\     "guestAcceleratorCount": 2
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "kind": "compute#machineType",
    \\   "id": "1000048",
    \\   "creationTimestamp": "1969-12-31T16:00:00.000-08:00",
    \\   "name": "a2-highgpu-4g",
    \\   "description": "Accelerator Optimized: 4 NVIDIA Tesla A100 GPUs, 48 vCPUs, 340GB RAM",
    \\   "guestCpus": 48,
    \\   "memoryMb": 348160,
    \\   "imageSpaceGb": 0,
    \\   "maximumPersistentDisks": 128,
    \\   "maximumPersistentDisksSizeGb": "524288",
    \\   "zone": "us-central1-a",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/a2-highgpu-4g",
    \\   "isSharedCpu": false,
    \\   "accelerators": [
    \\    {
    \\     "guestAcceleratorType": "nvidia-tesla-a100",
    \\     "guestAcceleratorCount": 4
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "kind": "compute#machineType",
    \\   "id": "1000096",
    \\   "creationTimestamp": "1969-12-31T16:00:00.000-08:00",
    \\   "name": "a2-highgpu-8g",
    \\   "description": "Accelerator Optimized: 8 NVIDIA Tesla A100 GPUs, 96 vCPUs, 680GB RAM",
    \\   "guestCpus": 96,
    \\   "memoryMb": 696320,
    \\   "imageSpaceGb": 0,
    \\   "maximumPersistentDisks": 128,
    \\   "maximumPersistentDisksSizeGb": "524288",
    \\   "zone": "us-central1-a",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/a2-highgpu-8g",
    \\   "isSharedCpu": false,
    \\   "accelerators": [
    \\    {
    \\     "guestAcceleratorType": "nvidia-tesla-a100",
    \\     "guestAcceleratorCount": 8
    \\    }
    \\   ]
    \\  },
    \\  {
    \\   "kind": "compute#machineType",
    \\   "id": "1001096",
    \\   "creationTimestamp": "1969-12-31T16:00:00.000-08:00",
    \\   "name": "a2-megagpu-16g",
    \\   "description": "Accelerator Optimized: 16 NVIDIA Tesla A100 GPUs, 96 vCPUs, 1360GB RAM",
    \\   "guestCpus": 96,
    \\   "memoryMb": 1392640,
    \\   "imageSpaceGb": 0,
    \\   "maximumPersistentDisks": 128,
    \\   "maximumPersistentDisksSizeGb": "524288",
    \\   "zone": "us-central1-a",
    \\   "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/a2-megagpu-16g",
    \\   "isSharedCpu": false,
    \\   "accelerators": [
    \\    {
    \\     "guestAcceleratorType": "nvidia-tesla-a100",
    \\     "guestAcceleratorCount": 16
    \\    }
    \\   ]
    \\  }
    \\ ],
    \\ "nextPageToken": "Cg5hMi1tZWdhZ3B1LTE2Zw==",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes"
    \\}
;

/// The newest debian-12 image, from its family. HTTP 200.
pub const image_status = 200;
pub const image =
    \\{
    \\ "kind": "compute#image",
    \\ "id": "1253207937433879378",
    \\ "creationTimestamp": "2026-10-26T18:26:21.730-07:00",
    \\ "name": "debian-12-bookworm-v20261027",
    \\ "description": "Debian, Debian GNU/Linux, 12 (bookworm), amd64 built on 20261027",
    \\ "sourceType": "RAW",
    \\ "rawDisk": {
    \\  "source": "",
    \\  "containerType": "TAR"
    \\ },
    \\ "status": "READY",
    \\ "archiveSizeBytes": "36641894400",
    \\ "diskSizeGb": "10",
    \\ "licenses": [
    \\  "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\ ],
    \\ "family": "debian-12",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/images/debian-12-bookworm-v20261027",
    \\ "labels": {
    \\  "public-image": "true"
    \\ },
    \\ "labelFingerprint": "iNBmVNCFF9w=",
    \\ "guestOsFeatures": [
    \\  {
    \\   "type": "UEFI_COMPATIBLE"
    \\  },
    \\  {
    \\   "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\  },
    \\  {
    \\   "type": "GVNIC"
    \\  },
    \\  {
    \\   "type": "SEV_CAPABLE"
    \\  },
    \\  {
    \\   "type": "SEV_LIVE_MIGRATABLE_V2"
    \\  },
    \\  {
    \\   "type": "SUSPEND_SAFE_FPR"
    \\  }
    \\ ],
    \\ "licenseCodes": [
    \\  "2147286739765738111"
    \\ ],
    \\ "storageLocations": [
    \\  "us-west8",
    \\  "us-east1",
    \\  "asia-south1",
    \\  "asia-northeast1",
    \\  "europe-west10",
    \\  "us-west2",
    \\  "europe-north1",
    \\  "asia-northeast3",
    \\  "europe-west3",
    \\  "us-south1",
    \\  "me-central2",
    \\  "europe-west4",
    \\  "northamerica-south1",
    \\  "us-east4",
    \\  "us",
    \\  "australia-southeast2",
    \\  "europe-southwest1",
    \\  "northamerica-northeast1",
    \\  "us-west3",
    \\  "asia-east2",
    \\  "europe-north2",
    \\  "eu",
    \\  "asia-southeast1",
    \\  "europe-west9",
    \\  "europe-west8",
    \\  "asia-southeast2",
    \\  "europe-west2",
    \\  "us-central2",
    \\  "europe-west6",
    \\  "me-central1",
    \\  "africa-south1",
    \\  "europe-west12",
    \\  "us-west4",
    \\  "asia-south2",
    \\  "asia",
    \\  "asia-northeast2",
    \\  "europe-west1",
    \\  "asia-southeast3",
    \\  "us-east5",
    \\  "australia-southeast1",
    \\  "me-west1",
    \\  "southamerica-west1",
    \\  "southamerica-east1",
    \\  "us-east7",
    \\  "europe-central2",
    \\  "asia-east1",
    \\  "us-central1",
    \\  "northamerica-northeast2",
    \\  "us-west1",
    \\  "europe-west15"
    \\ ],
    \\ "architecture": "X86_64",
    \\ "enableConfidentialCompute": false
    \\}
;

/// An instance nobody has. HTTP 404.
pub const not_found_instance_status = 404;
pub const not_found_instance =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-none' was not found",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-none' was not found",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A machine type the zone does not have. HTTP 404.
pub const not_found_machine_type_status = 404;
pub const not_found_machine_type =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'projects/extractctl/zones/us-central1-a/machineTypes/e2-nonesuch' was not found",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/extractctl/zones/us-central1-a/machineTypes/e2-nonesuch' was not found",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// An image family nobody has. HTTP 404.
pub const not_found_family_status = 404;
pub const not_found_family =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'projects/debian-cloud/global/images/family/nonesuch-99' was not found",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/debian-cloud/global/images/family/nonesuch-99' was not found",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// An operation nobody has. HTTP 404.
pub const not_found_operation_status = 404;
pub const not_found_operation =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'projects/extractctl/zones/us-central1-a/operations/operation-nonesuch' was not found",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/extractctl/zones/us-central1-a/operations/operation-nonesuch' was not found",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A zone that does not exist. HTTP 400.
pub const unknown_zone_status = 400;
pub const unknown_zone =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'zone': 'us-central1-q'. Unknown zone.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'zone': 'us-central1-q'. Unknown zone.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A list with a filter and an order together. HTTP 400.
pub const filter_and_order_status = 400;
pub const filter_and_order =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'orderBy': 'creationTimestamp desc'. Specifying both a list filter and sort order is not currently supported.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'orderBy': 'creationTimestamp desc'. Specifying both a list filter and sort order is not currently supported.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A list ordered by a field production does not sort by. HTTP 400.
pub const order_unsupported_status = 400;
pub const order_unsupported =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'orderBy': 'status'. Invalid sort order expression: sorting not supported on the specified field.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'orderBy': 'status'. Invalid sort order expression: sorting not supported on the specified field.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A list with a filter production cannot parse. HTTP 400.
pub const filter_invalid_status = 400;
pub const filter_invalid =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'filter': 'nonesuch ==='. Invalid list filter expression.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'filter': 'nonesuch ==='. Invalid list filter expression.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ],
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\    "reason": "INVALID_FIELD_VALUE",
    \\    "domain": "compute.googleapis.com",
    \\    "metadata": {
    \\     "field": "filter",
    \\     "value": "nonesuch ===",
    \\     "reason": "Invalid list filter expression."
    \\    }
    \\   },
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
    \\    "locale": "en-US",
    \\    "message": "Malformed list filter. Invalid filter string components."
    \\   },
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.Help",
    \\    "links": [
    \\     {
    \\      "description": "Syntax for the filter can be found on the corresponding API method page.",
    \\      "url": "https://cloud.google.com/compute/docs/reference/rest/v1"
    \\     }
    \\    ]
    \\   }
    \\  ]
    \\ }
    \\}
;

/// Serial port 9. HTTP 400.
pub const serial_port_out_of_range_status = 400;
pub const serial_port_out_of_range =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'port': '9'. Must be less than or equal to 4",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'port': '9'. Must be less than or equal to 4",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ],
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\    "reason": "INVALID_FIELD_VALUE",
    \\    "domain": "compute.googleapis.com",
    \\    "metadata": {
    \\     "field": "port",
    \\     "value": "9",
    \\     "reason": "Must be less than or equal to 4"
    \\    }
    \\   },
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
    \\    "locale": "en-US",
    \\    "message": "Invalid value for field 'port': '9'. Must be less than or equal to 4"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A guest attribute path with nothing under it. HTTP 404.
pub const guest_attribute_missing_status = 404;
pub const guest_attribute_missing =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'nonesuch/' of type 'Guest Attribute' was not found.",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'nonesuch/' of type 'Guest Attribute' was not found.",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// An insert of a name taken, with a new requestId, while the first insert still ran. HTTP 409.
pub const already_exists_status = 409;
pub const already_exists =
    \\{
    \\ "error": {
    \\  "code": 409,
    \\  "message": "The resource 'projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a' already exists",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a' already exists",
    \\    "domain": "global",
    \\    "reason": "alreadyExists"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// setLabels with a stale fingerprint. HTTP 412.
pub const stale_label_fingerprint_status = 412;
pub const stale_label_fingerprint =
    \\{
    \\ "error": {
    \\  "code": 412,
    \\  "message": "Labels fingerprint either invalid or resource labels have changed",
    \\  "errors": [
    \\   {
    \\    "message": "Labels fingerprint either invalid or resource labels have changed",
    \\    "domain": "global",
    \\    "reason": "conditionNotMet",
    \\    "location": "If-Match",
    \\    "locationType": "header"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// setMetadata with a stale fingerprint. HTTP 412.
pub const stale_metadata_fingerprint_status = 412;
pub const stale_metadata_fingerprint =
    \\{
    \\ "error": {
    \\  "code": 412,
    \\  "message": "Supplied fingerprint does not match current metadata fingerprint.",
    \\  "errors": [
    \\   {
    \\    "message": "Supplied fingerprint does not match current metadata fingerprint.",
    \\    "domain": "global",
    \\    "reason": "conditionNotMet",
    \\    "location": "If-Match",
    \\    "locationType": "header"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// Deleting a VM under deletion protection. HTTP 400.
pub const deletion_protected_status = 400;
pub const deletion_protected =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid resource usage: 'Resource cannot be deleted if it's protected against deletion.'.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid resource usage: 'Resource cannot be deleted if it's protected against deletion.'.",
    \\    "domain": "global",
    \\    "reason": "invalidResourceUsage"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A standard e2 asked for onHostMaintenance TERMINATE. HTTP 400.
pub const e2_terminate_status = 400;
pub const e2_terminate =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "e2 instances do not support onHostMaintenance=TERMINATE unless they are preemptible.",
    \\  "errors": [
    \\   {
    \\    "message": "e2 instances do not support onHostMaintenance=TERMINATE unless they are preemptible.",
    \\    "domain": "global",
    \\    "reason": "badRequest"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// An insert naming a machine type the zone does not have. HTTP 400.
pub const insert_bad_machine_type_status = 400;
pub const insert_bad_machine_type =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'resource.machineType': 'zones/us-central1-a/machineTypes/e2-nonesuch'. Machine type with name 'e2-nonesuch' does not exist in zone 'us-central1-a'.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'resource.machineType': 'zones/us-central1-a/machineTypes/e2-nonesuch'. Machine type with name 'e2-nonesuch' does not exist in zone 'us-central1-a'.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// An insert from an image family nobody has. HTTP 404.
pub const insert_bad_image_status = 404;
pub const insert_bad_image =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'projects/debian-cloud/global/images/family/nonesuch-99' was not found",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/debian-cloud/global/images/family/nonesuch-99' was not found",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// An insert of a name that is not RFC 1035, with its ErrorInfo and LocalizedMessage details. HTTP 400.
pub const insert_bad_name_status = 400;
pub const insert_bad_name =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'resource.name': 'Bad_Name'. Must be a match of regex '(?:[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?)'",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'resource.name': 'Bad_Name'. Must be a match of regex '(?:[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?)'",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ],
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\    "reason": "INVALID_FIELD_VALUE",
    \\    "domain": "compute.googleapis.com",
    \\    "metadata": {
    \\     "field": "resource.name",
    \\     "value": "Bad_Name",
    \\     "reason": "Must be a match of regex '(?:[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?)'"
    \\    }
    \\   },
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
    \\    "locale": "en-US",
    \\    "message": "Invalid value for field 'resource.name': 'Bad_Name'. Must be a match of regex '(?:[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?)'"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A stop's operation as the stop answered it: RUNNING. HTTP 200.
pub const operation_stop_status = 200;
pub const operation_stop =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "5698577931505735531",
    \\ "name": "operation-1793730948208-65f6387fd992a-0f6970de-a1404bb1",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "67bef999-9f07-49ba-b7ad-1c4a54856d2d",
    \\ "operationType": "stop",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T10:35:48.397-08:00",
    \\ "startTime": "2026-11-03T10:35:48.406-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793730948208-65f6387fd992a-0f6970de-a1404bb1"
    \\}
;

/// The stop, DONE, as the first wait answered it. HTTP 200.
pub const operation_stop_done_status = 200;
pub const operation_stop_done =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "5698577931505735531",
    \\ "name": "operation-1793730948208-65f6387fd992a-0f6970de-a1404bb1",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "67bef999-9f07-49ba-b7ad-1c4a54856d2d",
    \\ "operationType": "stop",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T10:35:48.397-08:00",
    \\ "startTime": "2026-11-03T10:35:48.406-08:00",
    \\ "endTime": "2026-11-03T10:36:41.509-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793730948208-65f6387fd992a-0f6970de-a1404bb1"
    \\}
;

/// The VM after the stop: TERMINATED. GET instance. HTTP 200.
pub const instance_stopped_status = 200;
pub const instance_stopped =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "6231655708778534534",
    \\ "creationTimestamp": "2026-11-03T10:31:05.869-08:00",
    \\ "name": "zigps-m0-11031830-a",
    \\ "tags": {
    \\  "items": [
    \\   "zigps-probe"
    \\  ],
    \\  "fingerprint": "V8n1wV8vUmg="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "TERMINATED",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.0.13",
    \\   "name": "nic0",
    \\   "fingerprint": "2FVvlW2Vfn8=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m0-11031830-a",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "ZoWzZgwsD-M=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   },
    \\   {
    \\    "key": "zigps",
    \\    "value": "one"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "3600",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "TERMINATE",
    \\  "automaticRestart": false,
    \\  "preemptible": true,
    \\  "provisioningModel": "SPOT",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "Unknown CPU Platform",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m0",
    \\  "probe": "one"
    \\ },
    \\ "labelFingerprint": "ZjVmAPZeL3k=",
    \\ "startRestricted": false,
    \\ "deletionProtection": false,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "WKe5MjJKF2M=",
    \\ "lastStartTimestamp": "2026-11-03T10:31:20.073-08:00",
    \\ "lastStopTimestamp": "2026-11-03T10:36:38.877-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  }
    \\ }
    \\}
;

/// A start's operation as the start answered it: RUNNING. HTTP 200.
pub const operation_start_status = 200;
pub const operation_start =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "3520140527217907539",
    \\ "name": "operation-1793731004331-65f638b55f720-46f8d765-55fb272b",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "adbe7c42-2ef2-49c9-b7ee-be0c45acb062",
    \\ "operationType": "start",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T10:36:44.690-08:00",
    \\ "startTime": "2026-11-03T10:36:44.726-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793731004331-65f638b55f720-46f8d765-55fb272b"
    \\}
;

/// Starting a VM already running: an operation DONE at once, no refusal. HTTP 200.
pub const operation_start_running_status = 200;
pub const operation_start_running =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "4273876527110133563",
    \\ "name": "operation-1793731027975-65f638cbebcb3-202be241-88ef1d80",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "18ceb857-3a11-4a57-9e53-e1cbc92ea6e6",
    \\ "operationType": "start",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T10:37:08.353-08:00",
    \\ "startTime": "2026-11-03T10:37:08.385-08:00",
    \\ "endTime": "2026-11-03T10:37:08.385-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793731027975-65f638cbebcb3-202be241-88ef1d80"
    \\}
;

/// A reset's operation as the reset answered it: RUNNING. HTTP 200.
pub const operation_reset_status = 200;
pub const operation_reset =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "1102672185564567354",
    \\ "name": "operation-1793731028920-65f638ccd26cd-95918555-99923cf2",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "f7fe6766-d3be-4644-b9e4-39d83888449b",
    \\ "operationType": "reset",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T10:37:09.231-08:00",
    \\ "startTime": "2026-11-03T10:37:09.248-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793731028920-65f638ccd26cd-95918555-99923cf2"
    \\}
;

/// A suspend's operation as the suspend answered it: RUNNING. HTTP 200.
pub const operation_suspend_status = 200;
pub const operation_suspend =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "3638997334748534584",
    \\ "name": "operation-1793731031246-65f638cf0a81b-79f0a9fe-430e264e",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "39441b28-8485-4937-8bcb-765b0627c842",
    \\ "operationType": "suspend",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T10:37:11.433-08:00",
    \\ "startTime": "2026-11-03T10:37:11.452-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793731031246-65f638cf0a81b-79f0a9fe-430e264e"
    \\}
;

/// A resume's operation as the resume answered it: RUNNING. HTTP 200.
pub const operation_resume_status = 200;
pub const operation_resume =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "8006124410648368159",
    \\ "name": "operation-1793731312436-65f639db3434e-96912a38-54edd6b1",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "4d17ff6b-04a2-40e1-97d9-ac339e160d22",
    \\ "operationType": "resume",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0-11031830-a",
    \\ "targetId": "6231655708778534534",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T10:41:52.810-08:00",
    \\ "startTime": "2026-11-03T10:41:52.825-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793731312436-65f639db3434e-96912a38-54edd6b1"
    \\}
;

/// A delete's operation as the delete answered it: RUNNING (milestone 2's live suite). HTTP 200.
pub const operation_delete_status = 200;
pub const operation_delete =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "4970243858555726347",
    \\ "name": "operation-1793742052617-65f661ddd6cb8-6aef07f8-2594daff",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "8fa5499d-237c-454f-875a-ebddec484448",
    \\ "operationType": "delete",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-9e4cc1-a",
    \\ "targetId": "3177492060727405285",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T13:40:52.822-08:00",
    \\ "startTime": "2026-11-03T13:40:52.845-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793742052617-65f661ddd6cb8-6aef07f8-2594daff"
    \\}
;

/// A start's operation answered PENDING, where milestone 0's had answered RUNNING (milestone 2's live suite). HTTP 200.
pub const operation_start_pending_status = 200;
pub const operation_start_pending =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "5576679861927799464",
    \\ "name": "operation-1793741895310-65f66147d1abd-28fa53bc-798fc6e2",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "968ed054-ed23-4e46-a7d9-0b8b2d0712e6",
    \\ "operationType": "start",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-9e4cc1-a",
    \\ "targetId": "3177492060727405285",
    \\ "status": "PENDING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T13:38:15.669-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793741895310-65f66147d1abd-28fa53bc-798fc6e2"
    \\}
;

/// A standard VM created with automaticRestart false and a run limit: both kept, provisioningModel STANDARD (milestone 2's live suite). GET instance. HTTP 200.
pub const instance_standard_restartless_status = 200;
pub const instance_standard_restartless =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "3728152248699054779",
    \\ "creationTimestamp": "2026-11-03T13:38:28.407-08:00",
    \\ "name": "zigps-9e4cc1-b",
    \\ "tags": {
    \\  "fingerprint": "42WmSpB8rSM="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "RUNNING",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.0.21",
    \\   "name": "nic0",
    \\   "fingerprint": "ft1VD-PdsPs=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-9e4cc1-b",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "azQvSjDzm8c=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\necho zigps-compute-it up > /dev/ttyS0\n"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-9e4cc1-b",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "1800",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "MIGRATE",
    \\  "automaticRestart": false,
    \\  "preemptible": false,
    \\  "provisioningModel": "STANDARD",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "Intel Broadwell",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-it",
    \\  "run": "9e4cc1"
    \\ },
    \\ "labelFingerprint": "FQBtsIpaH9k=",
    \\ "startRestricted": false,
    \\ "deletionProtection": true,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "j1HLD52-yps=",
    \\ "lastStartTimestamp": "2026-11-03T13:38:38.633-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly"
    \\  },
    \\  "scheduling": {
    \\   "terminationTimestamp": "2026-11-03T22:08:29.631334Z"
    \\  }
    \\ }
    \\}
;

/// An insert from a template nobody has (milestone 2's live suite). HTTP 404.
pub const template_not_found_status = 404;
pub const template_not_found =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'projects/extractctl/global/instanceTemplates/zigps-nonesuch' was not found",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/extractctl/global/instanceTemplates/zigps-nonesuch' was not found",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// setTags with a stale fingerprint. HTTP 412.
pub const stale_tags_fingerprint_status = 412;
pub const stale_tags_fingerprint =
    \\{
    \\ "error": {
    \\  "code": 412,
    \\  "message": "Tags fingerprint either invalid or resource tags have changed.",
    \\  "errors": [
    \\   {
    \\    "message": "Tags fingerprint either invalid or resource tags have changed.",
    \\    "domain": "global",
    \\    "reason": "conditionNotMet",
    \\    "location": "If-Match",
    \\    "locationType": "header"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// setLabels's operation as the call answered it: RUNNING, type compute.instance.setLabels (milestone 3's probe). HTTP 200.
pub const operation_set_labels_status = 200;
pub const operation_set_labels =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "4937613828071874033",
    \\ "name": "operation-1793745693885-65f66f6e6c5b7-0947e7f2-3f41758d",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "operationType": "compute.instance.setLabels",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m3-11032241-a",
    \\ "targetId": "6724670434841189882",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T14:41:34.096-08:00",
    \\ "startTime": "2026-11-03T14:41:34.098-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793745693885-65f66f6e6c5b7-0947e7f2-3f41758d"
    \\}
;

/// The VM read right after setLabels was answered, its operation not yet DONE: the new labels and fingerprint already there (milestone 3's probe). GET instance. HTTP 200.
pub const instance_relabelled_status = 200;
pub const instance_relabelled =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "6724670434841189882",
    \\ "creationTimestamp": "2026-11-03T14:41:25.274-08:00",
    \\ "name": "zigps-m3-11032241-a",
    \\ "tags": {
    \\  "fingerprint": "42WmSpB8rSM="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "RUNNING",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.0.30",
    \\   "name": "nic0",
    \\   "fingerprint": "JJ1-Lv6ijKY=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m3-11032241-a",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "osKZ0PQ-g6U=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\necho zigps-m3 up > /dev/ttyS0\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m3-11032241-a",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "3600",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "TERMINATE",
    \\  "automaticRestart": false,
    \\  "preemptible": true,
    \\  "provisioningModel": "SPOT",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "Intel Broadwell",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m3",
    \\  "probe": "one"
    \\ },
    \\ "labelFingerprint": "GlFen7VtVrc=",
    \\ "startRestricted": false,
    \\ "deletionProtection": false,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "9TSze8FIiZw=",
    \\ "lastStartTimestamp": "2026-11-03T14:41:33.068-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  },
    \\  "scheduling": {
    \\   "terminationTimestamp": "2026-11-03T23:41:26.671838Z"
    \\  }
    \\ }
    \\}
;

/// setScheduling on a running spot VM with a run limit, the scheduling unchanged (milestone 3's probe). HTTP 400.
pub const scheduling_running_status = 400;
pub const scheduling_running =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Termination time cannot be changed while the instance is running.",
    \\  "errors": [
    \\   {
    \\    "message": "Termination time cannot be changed while the instance is running.",
    \\    "domain": "global",
    \\    "reason": "badRequest"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// setScheduling on a running VM, its run limit changed (milestone 3's probe). HTTP 400.
pub const scheduling_limit_running_status = 400;
pub const scheduling_limit_running =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Max run duration cannot be changed while the instance is running.",
    \\  "errors": [
    \\   {
    \\    "message": "Max run duration cannot be changed while the instance is running.",
    \\    "domain": "global",
    \\    "reason": "badRequest"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// setScheduling to STANDARD on a spot VM without preemptible false (milestone 3's probe). HTTP 400.
pub const scheduling_standard_preemptible_status = 400;
pub const scheduling_standard_preemptible =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'resource.provisioningModel': 'STANDARD'. For preemptible, only allowed provisioning_model value is SPOT.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'resource.provisioningModel': 'STANDARD'. For preemptible, only allowed provisioning_model value is SPOT.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// setMachineType to a machine type the zone lacks, on a running VM (milestone 3's probe). HTTP 400.
pub const machine_type_unknown_status = 400;
pub const machine_type_unknown =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'machineType': 'zones/us-central1-a/machineTypes/e2-nonesuch'. Machine type with name 'e2-nonesuch' does not exist in zone 'us-central1-a'.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'machineType': 'zones/us-central1-a/machineTypes/e2-nonesuch'. Machine type with name 'e2-nonesuch' does not exist in zone 'us-central1-a'.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A VM with a disk attached beside its boot disk (milestone 3's probe). GET instance. HTTP 200.
pub const instance_two_disks_status = 200;
pub const instance_two_disks =
    \\{
    \\ "kind": "compute#instance",
    \\ "id": "6724670434841189882",
    \\ "creationTimestamp": "2026-11-03T14:41:25.274-08:00",
    \\ "name": "zigps-m3-11032241-a",
    \\ "tags": {
    \\  "fingerprint": "42WmSpB8rSM="
    \\ },
    \\ "machineType": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/machineTypes/e2-micro",
    \\ "status": "RUNNING",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "networkInterfaces": [
    \\  {
    \\   "kind": "compute#networkInterface",
    \\   "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\   "subnetwork": "https://www.googleapis.com/compute/v1/projects/extractctl/regions/us-central1/subnetworks/default",
    \\   "networkIP": "10.128.0.30",
    \\   "name": "nic0",
    \\   "fingerprint": "JJ1-Lv6ijKY=",
    \\   "stackType": "IPV4_ONLY"
    \\  }
    \\ ],
    \\ "disks": [
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m3-11032241-a",
    \\   "deviceName": "persistent-disk-0",
    \\   "index": 0,
    \\   "boot": true,
    \\   "autoDelete": true,
    \\   "licenses": [
    \\    "https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm"
    \\   ],
    \\   "interface": "SCSI",
    \\   "guestOsFeatures": [
    \\    {
    \\     "type": "UEFI_COMPATIBLE"
    \\    },
    \\    {
    \\     "type": "VIRTIO_SCSI_MULTIQUEUE"
    \\    },
    \\    {
    \\     "type": "GVNIC"
    \\    },
    \\    {
    \\     "type": "SEV_CAPABLE"
    \\    },
    \\    {
    \\     "type": "SEV_LIVE_MIGRATABLE_V2"
    \\    },
    \\    {
    \\     "type": "SUSPEND_SAFE_FPR"
    \\    }
    \\   ],
    \\   "diskSizeGb": "10",
    \\   "architecture": "X86_64"
    \\  },
    \\  {
    \\   "kind": "compute#attachedDisk",
    \\   "type": "PERSISTENT",
    \\   "mode": "READ_WRITE",
    \\   "source": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/disks/zigps-m3-11032241-d",
    \\   "deviceName": "zigps-data",
    \\   "index": 1,
    \\   "boot": false,
    \\   "autoDelete": false,
    \\   "interface": "SCSI",
    \\   "diskSizeGb": "10"
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kind": "compute#metadata",
    \\  "fingerprint": "osKZ0PQ-g6U=",
    \\  "items": [
    \\   {
    \\    "key": "startup-script",
    \\    "value": "#!/bin/bash\necho zigps-m3 up > /dev/ttyS0\n"
    \\   },
    \\   {
    \\    "key": "enable-guest-attributes",
    \\    "value": "TRUE"
    \\   }
    \\  ]
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m3-11032241-a",
    \\ "scheduling": {
    \\  "maxRunDuration": {
    \\   "seconds": "3600",
    \\   "nanos": 0
    \\  },
    \\  "onHostMaintenance": "TERMINATE",
    \\  "automaticRestart": false,
    \\  "preemptible": true,
    \\  "provisioningModel": "SPOT",
    \\  "instanceTerminationAction": "DELETE"
    \\ },
    \\ "cpuPlatform": "Intel Broadwell",
    \\ "labels": {
    \\  "purpose": "gcp-zig-test",
    \\  "tool": "compute-m3",
    \\  "probe": "one"
    \\ },
    \\ "labelFingerprint": "GlFen7VtVrc=",
    \\ "startRestricted": false,
    \\ "deletionProtection": false,
    \\ "shieldedInstanceConfig": {
    \\  "enableSecureBoot": false,
    \\  "enableVtpm": true,
    \\  "enableIntegrityMonitoring": true
    \\ },
    \\ "shieldedInstanceIntegrityPolicy": {
    \\  "updateAutoLearnPolicy": true
    \\ },
    \\ "fingerprint": "6F8Fnl4LLFE=",
    \\ "lastStartTimestamp": "2026-11-03T14:41:33.068-08:00",
    \\ "satisfiesPzi": true,
    \\ "resourceStatus": {
    \\  "effectiveInstanceMetadata": {
    \\   "vmDnsSettingMetadataValue": "ZonalOnly",
    \\   "enableGuestAttributesMetadataValue": true
    \\  },
    \\  "scheduling": {
    \\   "terminationTimestamp": "2026-11-03T23:41:26.671838Z"
    \\  }
    \\ }
    \\}
;

/// An attach of a disk the VM has already: the call taken, its operation DONE with RESOURCE_IN_USE_BY_ANOTHER_RESOURCE (milestone 3's probe). HTTP 200.
pub const operation_disk_in_use_status = 200;
pub const operation_disk_in_use =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "3841534716684000708",
    \\ "name": "operation-1793745707240-65f66f7b28c91-ea597ad0-b99fa280",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "operationType": "attachDisk",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m3-11032241-a",
    \\ "targetId": "6724670434841189882",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T14:41:47.494-08:00",
    \\ "startTime": "2026-11-03T14:41:47.500-08:00",
    \\ "endTime": "2026-11-03T14:41:49.816-08:00",
    \\ "error": {
    \\  "errors": [
    \\   {
    \\    "code": "RESOURCE_IN_USE_BY_ANOTHER_RESOURCE",
    \\    "message": "The disk resource 'projects/extractctl/zones/us-central1-a/disks/zigps-m3-11032241-d' is already being used by 'projects/extractctl/zones/us-central1-a/instances/zigps-m3-11032241-a'"
    \\   }
    \\  ]
    \\ },
    \\ "httpErrorStatusCode": 400,
    \\ "httpErrorMessage": "BAD REQUEST",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793745707240-65f66f7b28c91-ea597ad0-b99fa280"
    \\}
;

/// An attach of a disk nobody has (milestone 3's probe). HTTP 404.
pub const disk_not_found_status = 404;
pub const disk_not_found =
    \\{
    \\ "error": {
    \\  "code": 404,
    \\  "message": "The resource 'projects/extractctl/zones/us-central1-a/disks/zigps-m3-nonesuch' was not found",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/extractctl/zones/us-central1-a/disks/zigps-m3-nonesuch' was not found",
    \\    "domain": "global",
    \\    "reason": "notFound"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A detach of a device the VM has none of: the call taken, its operation DONE with INVALID_USAGE (milestone 3's probe). HTTP 200.
pub const operation_no_such_device_status = 200;
pub const operation_no_such_device =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "8827830900814765532",
    \\ "name": "operation-1793745714924-65f66f827ca11-e827d1a2-86ac0a09",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "operationType": "detachDisk",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m3-11032241-a",
    \\ "targetId": "6724670434841189882",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T14:41:55.044-08:00",
    \\ "startTime": "2026-11-03T14:41:55.051-08:00",
    \\ "endTime": "2026-11-03T14:41:55.738-08:00",
    \\ "error": {
    \\  "errors": [
    \\   {
    \\    "code": "INVALID_USAGE",
    \\    "message": "No attached disk found with device name 'zigps-data'"
    \\   }
    \\  ]
    \\ },
    \\ "httpErrorStatusCode": 400,
    \\ "httpErrorMessage": "BAD REQUEST",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793745714924-65f66f827ca11-e827d1a2-86ac0a09"
    \\}
;

/// setDeletionProtection's operation as the call answered it: DONE at once (milestone 3's probe). HTTP 200.
pub const operation_protection_status = 200;
pub const operation_protection =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "2783908838339239387",
    \\ "name": "operation-1793745716041-65f66f838d89f-44e290ac-425d0d01",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "operationType": "setDeletionProtection",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m3-11032241-a",
    \\ "targetId": "6724670434841189882",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T14:41:56.201-08:00",
    \\ "startTime": "2026-11-03T14:41:56.213-08:00",
    \\ "endTime": "2026-11-03T14:41:56.350-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793745716041-65f66f838d89f-44e290ac-425d0d01"
    \\}
;

/// setScheduling to SPOT on a stopped standard VM without preemptible true (milestone 3's live suite). HTTP 400.
pub const scheduling_spot_not_preemptible_status = 400;
pub const scheduling_spot_not_preemptible =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'resource.provisioningModel': 'SPOT'. preemptible=false and provisioning_model=SPOT is contradicting.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'resource.provisioningModel': 'SPOT'. preemptible=false and provisioning_model=SPOT is contradicting.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A global template of spot e2-micro VMs that STOP, no run limit: what a group can use. GET template. HTTP 200.
pub const template_status = 200;
pub const template =
    \\{
    \\ "kind": "compute#instanceTemplate",
    \\ "id": "2741556500840812922",
    \\ "creationTimestamp": "2026-11-03T11:01:41.353-08:00",
    \\ "name": "zigps-m0d-11031901-tpl",
    \\ "description": "",
    \\ "properties": {
    \\  "machineType": "e2-micro",
    \\  "networkInterfaces": [
    \\   {
    \\    "kind": "compute#networkInterface",
    \\    "network": "https://www.googleapis.com/compute/v1/projects/extractctl/global/networks/default",
    \\    "name": "nic0"
    \\   }
    \\  ],
    \\  "disks": [
    \\   {
    \\    "kind": "compute#attachedDisk",
    \\    "type": "PERSISTENT",
    \\    "mode": "READ_WRITE",
    \\    "deviceName": "persistent-disk-0",
    \\    "index": 0,
    \\    "boot": true,
    \\    "initializeParams": {
    \\     "sourceImage": "projects/debian-cloud/global/images/family/debian-12",
    \\     "diskSizeGb": "10",
    \\     "diskType": "pd-standard"
    \\    },
    \\    "autoDelete": true
    \\   }
    \\  ],
    \\  "metadata": {
    \\   "kind": "compute#metadata",
    \\   "fingerprint": "inPgXPhJXaM=",
    \\   "items": [
    \\    {
    \\     "key": "startup-script",
    \\     "value": "#!/bin/bash\n# zigps m0: a guest attribute, then enough serial output for more than one page.\ncurl -s -X PUT --data \"ready\" -H \"Metadata-Flavor: Google\" \\\n  \"http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/zigps/probe\"\nfor i in $(seq 1 30000); do printf 'zigps-m0 serial line %05d %060d\\n' \"$i\" 0; done > /dev/ttyS0\necho \"zigps-m0 serial done\" > /dev/ttyS0\n"
    \\    },
    \\    {
    \\     "key": "enable-guest-attributes",
    \\     "value": "TRUE"
    \\    }
    \\   ]
    \\  },
    \\  "scheduling": {
    \\   "onHostMaintenance": "TERMINATE",
    \\   "automaticRestart": false,
    \\   "preemptible": true,
    \\   "provisioningModel": "SPOT",
    \\   "instanceTerminationAction": "STOP"
    \\  },
    \\  "labels": {
    \\   "purpose": "gcp-zig-test",
    \\   "tool": "compute-m0"
    \\  }
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl"
    \\}
;

/// A template insert of a name taken. HTTP 409.
pub const template_taken_status = 409;
pub const template_taken =
    \\{
    \\ "error": {
    \\  "code": 409,
    \\  "message": "The resource 'projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl' already exists",
    \\  "errors": [
    \\   {
    \\    "message": "The resource 'projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl' already exists",
    \\    "domain": "global",
    \\    "reason": "alreadyExists"
    \\   }
    \\  ]
    \\ }
    \\}
;

/// A group insert's operation as the call answered it: RUNNING. HTTP 200.
pub const operation_group_insert_status = 200;
pub const operation_group_insert =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "2372726781297267063",
    \\ "name": "operation-1793732503163-65f63e4ac5320-b135fe1f-4f32db4f",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "fe23b0c0-a091-40ad-9b39-f69e6e7d5ec1",
    \\ "operationType": "compute.instanceGroupManagers.insert",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g",
    \\ "targetId": "4679602103080423799",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T11:01:44.656-08:00",
    \\ "startTime": "2026-11-03T11:01:44.664-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793732503163-65f63e4ac5320-b135fe1f-4f32db4f"
    \\}
;

/// A new group's VMs at its first read: CREATING, no instanceStatus yet. HTTP 200.
pub const group_instances_creating_status = 200;
pub const group_instances_creating =
    \\{
    \\ "managedInstances": [
    \\  {
    \\   "name": "zigps-m0d-11031901-g-i-940j",
    \\   "instance": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0d-11031901-g-i-940j",
    \\   "targetStatus": "RUNNING",
    \\   "version": {
    \\    "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl"
    \\   },
    \\   "currentAction": "CREATING"
    \\  },
    \\  {
    \\   "name": "zigps-m0d-11031901-g-i-vprl",
    \\   "instance": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0d-11031901-g-i-vprl",
    \\   "targetStatus": "RUNNING",
    \\   "version": {
    \\    "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl"
    \\   },
    \\   "currentAction": "CREATING"
    \\  }
    \\ ]
    \\}
;

/// The group's VMs about 30 s later: RUNNING, doing nothing. HTTP 200.
pub const group_instances_stable_status = 200;
pub const group_instances_stable =
    \\{
    \\ "managedInstances": [
    \\  {
    \\   "name": "zigps-m0d-11031901-g-i-940j",
    \\   "instance": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0d-11031901-g-i-940j",
    \\   "id": "8137573478175314255",
    \\   "instanceStatus": "RUNNING",
    \\   "targetStatus": "RUNNING",
    \\   "version": {
    \\    "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl"
    \\   },
    \\   "currentAction": "NONE"
    \\  },
    \\  {
    \\   "name": "zigps-m0d-11031901-g-i-vprl",
    \\   "instance": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0d-11031901-g-i-vprl",
    \\   "id": "6932497786261180751",
    \\   "instanceStatus": "RUNNING",
    \\   "targetStatus": "RUNNING",
    \\   "version": {
    \\    "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl"
    \\   },
    \\   "currentAction": "NONE"
    \\  }
    \\ ]
    \\}
;

/// The group, stable: two VMs, none doing anything. GET group. HTTP 200.
pub const group_stable_status = 200;
pub const group_stable =
    \\{
    \\ "kind": "compute#instanceGroupManager",
    \\ "id": "4679602103080423799",
    \\ "creationTimestamp": "2026-11-03T11:01:44.622-08:00",
    \\ "name": "zigps-m0d-11031901-g",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl",
    \\ "versions": [
    \\  {
    \\   "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl",
    \\   "targetSize": {
    \\    "calculated": 2
    \\   }
    \\  }
    \\ ],
    \\ "instanceGroup": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instanceGroups/zigps-m0d-11031901-g",
    \\ "baseInstanceName": "zigps-m0d-11031901-g-i",
    \\ "fingerprint": "UTi0tLYL7w8=",
    \\ "currentActions": {
    \\  "none": 2,
    \\  "creating": 0,
    \\  "creatingWithoutRetries": 0,
    \\  "verifying": 0,
    \\  "recreating": 0,
    \\  "deleting": 0,
    \\  "abandoning": 0,
    \\  "restarting": 0,
    \\  "refreshing": 0,
    \\  "suspending": 0,
    \\  "resuming": 0,
    \\  "stopping": 0,
    \\  "starting": 0
    \\ },
    \\ "status": {
    \\  "isStable": true,
    \\  "allInstancesConfig": {
    \\   "effective": true
    \\  },
    \\  "versionTarget": {
    \\   "isReached": true
    \\  },
    \\  "stateful": {
    \\   "hasStatefulConfig": false,
    \\   "perInstanceConfigs": {
    \\    "allEffective": true
    \\   }
    \\  }
    \\ },
    \\ "targetSize": 2,
    \\ "targetSizePolicy": {
    \\  "mode": "INDIVIDUAL"
    \\ },
    \\ "targetStoppedSize": 0,
    \\ "targetSuspendedSize": 0,
    \\ "listManagedInstancesResults": "PAGELESS",
    \\ "standbyPolicy": {
    \\  "mode": "MANUAL"
    \\ },
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g",
    \\ "updatePolicy": {
    \\  "type": "OPPORTUNISTIC",
    \\  "minimalAction": "REPLACE",
    \\  "maxSurge": {
    \\   "fixed": 1,
    \\   "calculated": 1
    \\  },
    \\  "maxUnavailable": {
    \\   "fixed": 1,
    \\   "calculated": 1
    \\  },
    \\  "replacementMethod": "SUBSTITUTE"
    \\ },
    \\ "instanceLifecyclePolicy": {
    \\  "forceUpdateOnRepair": "NO",
    \\  "defaultActionOnFailure": "REPAIR",
    \\  "onFailedHealthCheck": "DEFAULT_ACTION"
    \\ },
    \\ "satisfiesPzi": true,
    \\ "satisfiesPzs": true
    \\}
;

/// A resize's operation as the call answered it: RUNNING. HTTP 200.
pub const operation_group_resize_status = 200;
pub const operation_group_resize =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "8679147246220448045",
    \\ "name": "operation-1793732545924-65f63e738ce19-d4de9b82-6f8e7a9e",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "422b1bc9-7210-49d7-88d5-8a183431d976",
    \\ "operationType": "compute.instanceGroupManagers.resize",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g",
    \\ "targetId": "4679602103080423799",
    \\ "status": "RUNNING",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 0,
    \\ "insertTime": "2026-11-03T11:02:26.059-08:00",
    \\ "startTime": "2026-11-03T11:02:26.061-08:00",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793732545924-65f63e738ce19-d4de9b82-6f8e7a9e"
    \\}
;

/// After createInstances of one by name: it CREATING with no instanceStatus, the other RUNNING. HTTP 200.
pub const group_instances_named_status = 200;
pub const group_instances_named =
    \\{
    \\ "managedInstances": [
    \\  {
    \\   "name": "zigps-m0d-11031901-g-i-940j",
    \\   "instance": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0d-11031901-g-i-940j",
    \\   "id": "8137573478175314255",
    \\   "instanceStatus": "RUNNING",
    \\   "targetStatus": "RUNNING",
    \\   "version": {
    \\    "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl"
    \\   },
    \\   "currentAction": "NONE"
    \\  },
    \\  {
    \\   "name": "zigps-m0d-11031901-g-named",
    \\   "instance": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instances/zigps-m0d-11031901-g-named",
    \\   "targetStatus": "RUNNING",
    \\   "version": {
    \\    "instanceTemplate": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl"
    \\   },
    \\   "currentAction": "CREATING"
    \\  }
    \\ ]
    \\}
;

/// A delete of a template a group uses: the call taken, its operation DONE with RESOURCE_IN_USE_BY_ANOTHER_RESOURCE. HTTP 200.
pub const operation_template_in_use_status = 200;
pub const operation_template_in_use =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "7934919883014770991",
    \\ "name": "operation-1793732543958-65f63e71accc7-454a6749-ac1a1340",
    \\ "clientOperationId": "d7b9bf22-d430-4f9c-9a98-20878866cb28",
    \\ "operationType": "delete",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl",
    \\ "targetId": "2741556500840812922",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T11:02:24.070-08:00",
    \\ "startTime": "2026-11-03T11:02:24.085-08:00",
    \\ "endTime": "2026-11-03T11:02:25.458-08:00",
    \\ "error": {
    \\  "errors": [
    \\   {
    \\    "code": "RESOURCE_IN_USE_BY_ANOTHER_RESOURCE",
    \\    "message": "The instance_template resource 'projects/extractctl/global/instanceTemplates/zigps-m0d-11031901-tpl' is already being used by 'projects/extractctl/zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g@4679602103080423799'"
    \\   }
    \\  ]
    \\ },
    \\ "httpErrorStatusCode": 400,
    \\ "httpErrorMessage": "BAD REQUEST",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/global/operations/operation-1793732543958-65f63e71accc7-454a6749-ac1a1340"
    \\}
;

/// A group insert from a template of spot VMs that DELETE: its operation DONE with UNSUPPORTED_OPERATION. HTTP 200.
pub const operation_group_spot_delete_status = 200;
pub const operation_group_spot_delete =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "4634665960501384117",
    \\ "name": "operation-1793731929893-65f63c280ea49-f9954f42-0dd0512a",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "ddcd3504-cb8a-4649-bc59-419f062300b7",
    \\ "operationType": "compute.instanceGroupManagers.insert",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instanceGroupManagers/zigps-m0-11031830-g",
    \\ "targetId": "4085587896747660213",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T10:52:10.855-08:00",
    \\ "startTime": "2026-11-03T10:52:10.865-08:00",
    \\ "endTime": "2026-11-03T10:52:12.257-08:00",
    \\ "error": {
    \\  "errors": [
    \\   {
    \\    "code": "UNSUPPORTED_OPERATION",
    \\    "message": "Spot virtual machines with termination action set to DELETE cannot be used with Managed Instance Groups."
    \\   }
    \\  ]
    \\ },
    \\ "httpErrorStatusCode": 400,
    \\ "httpErrorMessage": "BAD REQUEST",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793731929893-65f63c280ea49-f9954f42-0dd0512a"
    \\}
;

/// A group insert from a template of spot VMs with a run limit: its operation DONE with UNSUPPORTED_OPERATION. HTTP 200.
pub const operation_group_spot_limit_status = 200;
pub const operation_group_spot_limit =
    \\{
    \\ "kind": "compute#operation",
    \\ "id": "3469411684937339261",
    \\ "name": "operation-1793732497287-65f63e452aa8d-6459e964-401a437f",
    \\ "zone": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a",
    \\ "clientOperationId": "c64c8760-fb53-419a-8b82-3d1b0ef09a36",
    \\ "operationType": "compute.instanceGroupManagers.insert",
    \\ "targetLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/instanceGroupManagers/zigps-m0d-11031901-g-limit",
    \\ "targetId": "264025171856691581",
    \\ "status": "DONE",
    \\ "user": "zig-gcp@extractctl.iam.gserviceaccount.com",
    \\ "progress": 100,
    \\ "insertTime": "2026-11-03T11:01:38.877-08:00",
    \\ "startTime": "2026-11-03T11:01:38.885-08:00",
    \\ "endTime": "2026-11-03T11:01:40.905-08:00",
    \\ "error": {
    \\  "errors": [
    \\   {
    \\    "code": "UNSUPPORTED_OPERATION",
    \\    "message": "Spot virtual machines with set termination time cannot be used with Managed Instance Groups."
    \\   }
    \\  ]
    \\ },
    \\ "httpErrorStatusCode": 400,
    \\ "httpErrorMessage": "BAD REQUEST",
    \\ "selfLink": "https://www.googleapis.com/compute/v1/projects/extractctl/zones/us-central1-a/operations/operation-1793732497287-65f63e452aa8d-6459e964-401a437f"
    \\}
;

/// deleteInstances with an empty instance URL. HTTP 400.
pub const delete_instances_malformed_status = 400;
pub const delete_instances_malformed =
    \\{
    \\ "error": {
    \\  "code": 400,
    \\  "message": "Invalid value for field 'instances[0]': ''. The URL is malformed.",
    \\  "errors": [
    \\   {
    \\    "message": "Invalid value for field 'instances[0]': ''. The URL is malformed.",
    \\    "domain": "global",
    \\    "reason": "invalid"
    \\   }
    \\  ],
    \\  "details": [
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    \\    "reason": "INVALID_FIELD_VALUE",
    \\    "domain": "compute.googleapis.com",
    \\    "metadata": {
    \\     "field": "instances[0]",
    \\     "value": "",
    \\     "reason": "The URL is malformed."
    \\    }
    \\   },
    \\   {
    \\    "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
    \\    "locale": "en-US",
    \\    "message": "Invalid value for field 'instances[0]': ''. The URL is malformed."
    \\   }
    \\  ]
    \\ }
    \\}
;
