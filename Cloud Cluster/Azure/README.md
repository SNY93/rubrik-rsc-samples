# Manual CCES Bootstrap – Azure

This script manually bootstraps a **Rubrik Cloud Cluster ES (CCES)** deployed in Azure and registers it with **Rubrik Security Cloud (RSC)**. It is useful when the standard automated bootstrap flow is not available or when a hands-on, step-by-step deployment is required.

> **Note:** This is a reference/starting point. Review and adapt all parameters to your environment before running. Always test in a non-production environment first.

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.2 or later |
| Az PowerShell module | `Install-Module Az` |
| Azure permissions | Reader on VMs, Storage Account, VNet; Contributor on the CCES resource group |
| RSC Service Account | JSON file downloaded from RSC → Settings → Service Accounts |
| RBAC Role | Cluster View & Cluster Add
| CCES VMs deployed | VMs must already be provisioned from the **Rubrik CDM marketplace image** (ARM template or Terraform), one per Availability Zone |
| Availability Zones | Each node must be deployed in a distinct AZ (e.g. node 1 → AZ1, node 2 → AZ2, node 3 → AZ3). The script reads the AZ from the VM and uses it as the `chassisId` for that node |
| Managed identity | User-assigned managed identity attached to each CCES VM with custom least privileged role |
| Blob container | Container must exist in the target storage account before running |

---

## Architecture – Zone-Aware Deployment

CCES in Azure is deployed in an **Availability Zone-aware** configuration. Each cluster node must reside in a different AZ to ensure fault tolerance. A standard 3-node cluster maps to:

| Node | Availability Zone |
|------|------------------|
| Node 1 | AZ 1 |
| Node 2 | AZ 2 |
| Node 3 | AZ 3 |

Each VM must be deployed from the **Rubrik CDM marketplace image** before running this script — the bootstrap API configures a running CDM instance, it does not install software. The one VM must be reachable on **port 443** from the machine executing the script.

The script automatically reads each VM's `Zones` property from Azure and assigns it as the `chassisId` in the bootstrap payload, so the cluster is AZ-aware from initial configuration.

---

## What the Script Does

The script automates the following sequence:

1. **Discovers CCES VMs** – Finds Azure VMs by name pattern and collects their private IP, subnet mask, gateway, and availability zone.
2. **Resolves storage configuration** – Looks up the storage account, blob container, and managed identity client ID automatically.
3. **Builds the bootstrap payload** – Assembles the cluster configuration (node IPs, DNS, NTP, storage) and posts it to the CDM bootstrap API.
4. **Polls for completion** – Checks bootstrap status every 60 seconds until `SUCCESS` or `FAILURE`.
5. **Registers with RSC** – On successful bootstrap, performs the OAuth-based online registration so the cluster appears in RSC.

---

## Configuration

Open the script and fill in the variables at the top of the file before running.

### Azure Connection

```powershell
$TenantId       = ""   # Azure AD tenant ID
$SubscriptionId = ""   # Azure subscription ID
```

Uncomment one of the authentication lines that matches your setup:

```powershell
# Interactive device-code login
Connect-AzAccount -UseDeviceAuthentication -TenantId $TenantId

# Service principal login
Connect-AzAccount -ServicePrincipal -Credential (Get-Credential) -Tenant $TenantId -Subscription $SubscriptionId
```

### Resource Variables

```powershell
$vmRg                  = ''   # Resource group containing the CCES VMs
$vmNamePattern         = ''   # Wildcard pattern to match CCES VMs, e.g. 'rubrik-cces-*'
$storageRg             = ''   # Resource group containing the storage account
$storageAccountName    = ''   # Storage account name
$managedIdentityName   = ''   # User-assigned managed identity name
$containerPrefix       = ''   # Blob container name prefix, e.g. 'rubrik-backup'
$immutability          = $true
$rscServiceAccountFile = ''   # Full local path to RSC service account JSON
```

### Cluster Configuration

Inside `Get-ClusterConfiguration`, fill in the cluster-specific settings:

```powershell
adminUserInfo = @{
    emailAddress = "admin@example.com"
    password     = "YourSecurePassword!"   # Change immediately after bootstrap
}
name             = "my-cces-cluster"
dnsNameservers   = @("10.0.0.4")
dnsSearchDomains = @("corp.example.com")
ntpServerConfigs = @(@{ server = "time.windows.com" })
```

---

## Usage

```powershell
# 1. Sign in to Azure (choose your preferred method from the script header)
Connect-AzAccount -UseDeviceAuthentication -TenantId "<your-tenant-id>"

# 2. Run the script
.\manual-cces-bootstrap.ps1
```

The script will print progress at each stage. Bootstrap typically takes 10–20 minutes. RSC registration completes within a few seconds after bootstrap succeeds.

---

## Expected Output

```
Discovering VMs matching pattern 'rubrik-cces-*' in resource group 'rg-cces'...
Found 4 VM(s) matching pattern.
Processing VM: rubrik-cces-1
  Private IP : 10.0.1.4
  Subnet Mask: 255.255.255.0
  Gateway    : 10.0.1.1
  Zone       : 1
...
Found container: rubrik-backup-01
Found managed identity: mi-cces-storage
Bootstrap status: IN_PROGRESS - Bootstrap is in progress
Bootstrap status: SUCCESS - Bootstrap completed
Final bootstrap status: SUCCESS
Bootstrap succeeded. Starting RSC online registration...
Registration result    : REGISTERED
Connected to Rubrik    : True
RSC URL                : https://your-tenant.my.rubrik.com
```

---

## Already-Bootstrapped Clusters

If the cluster was previously bootstrapped, the API returns HTTP `422` with `already bootstrapped node`. The script detects this and skips to RSC registration automatically — no manual intervention required.

---

## RSC Service Account JSON

The service account file is downloaded from RSC and has the following structure:

```json
{
  "client_id": "client|...",
  "client_secret": "...",
  "access_token_uri": "https://<tenant>.my.rubrik.com/api/client_token"
}
```

Store this file securely. Do not commit it to source control.

---

## Troubleshooting

| Symptom | Likely cause | Resolution |
|---|---|---|
| No VMs found | Pattern does not match VM names | Check `$vmNamePattern`; use `Get-AzVM -ResourceGroupName $vmRg` to list names |
| Container not found | Wrong prefix or storage account | Verify `$containerPrefix` and `$storageAccountName` |
| Bootstrap stuck in `IN_PROGRESS` | VMs not reachable on port 443 | Check NSG rules allow port 443 inbound from the machine running this script |
| `chassisId` errors during bootstrap | VMs not assigned to an AZ | Verify each VM has an Availability Zone set; VMs without a zone assignment cannot be used |
| RSC authentication fails | Expired or incorrect service account | Re-download the service account JSON from RSC |
| `422 already bootstrapped` during fresh deploy | Prior partial run | Script handles this automatically and proceeds to RSC registration |

---

## Disclaimer

This script is provided as-is, without warranty of any kind. It is not an official Rubrik product. Test thoroughly in a non-production environment before use in production.
