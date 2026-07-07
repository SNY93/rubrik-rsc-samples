<#
This script demonstrates how to manually bootstrap a Rubrik Cloud Cluster ES (CCES) leveraging Rubrik AZ-Multi Zone awareness
in Azure and register it with Rubrik Security Cloud (RSC).

It is intended as a reference/starting point. Review and adapt all parameters to your
environment before running. Test in a non-production environment first.
---------------------------------------------
#>

# -------------------------
# AUTHENTICATION
# -------------------------
$TenantId       = ""
$SubscriptionId = ""

# Uncomment and use one of the following authentication methods:
# Connect-AzAccount -UseDeviceAuthentication -TenantId $TenantId
# Connect-AzAccount -ServicePrincipal -Credential (Get-Credential) -Tenant $TenantId -Subscription $SubscriptionId
Set-AzContext -SubscriptionId $SubscriptionId -Tenant $TenantId

# -------------------------
# CONFIGURATION
# -------------------------
$vmRg                 = ''   # Resource group containing the CCES VMs
$vmNamePattern        = ''   # VM name pattern/wildcard to match CCES nodes
$storageRg            = ''   # Resource group containing the storage account
$storageAccountName   = ''   # Storage account name
$managedIdentityName  = ''   # User-assigned managed identity name
$containerPrefix      = ''   # Blob container name prefix used for backup storage
$immutability         = $true # Recommended: enable immutability on the container
$rscServiceAccountFile = ''  # Full path to the RSC service account JSON file

# -------------------------
# 0) RSC Service Account Authentication
# -------------------------
function Connect-RscServiceAccount {
  param(
    [Parameter(Mandatory = $true)]
    [string] $ServiceAccountFile
  )

  try {
    $serviceAccountJson = Get-Content $ServiceAccountFile -ErrorAction Stop | ConvertFrom-Json
    $tokenPayload = @{
      grant_type    = 'client_credentials'
      client_id     = $serviceAccountJson.client_id
      client_secret = $serviceAccountJson.client_secret
    }
    $tokenHeaders = @{
      'Content-Type' = 'application/json'
      'Accept'       = 'application/json'
    }
    $tokenResponse = Invoke-RestMethod -Method Post `
      -Uri $serviceAccountJson.access_token_uri `
      -Body ($tokenPayload | ConvertTo-Json -Depth 10) `
      -Headers $tokenHeaders
  }
  catch {
    Write-Error "Failed to authenticate with RSC service account: $($_.Exception.Message)"
    throw
  }

  if (-not $tokenResponse.access_token) {
    throw 'RSC service account login did not return an access_token.'
  }

  $accessTokenUri = [System.Uri]$serviceAccountJson.access_token_uri
  if (-not $accessTokenUri.Host) {
    throw 'Unable to extract RSC host from access_token_uri in service account file.'
  }

  return [PSCustomObject]@{
    AccessToken = $tokenResponse.access_token
    RscHost     = $accessTokenUri.Host
  }
}

# -------------------------
# 1) Cluster Configuration Template
# -------------------------
function Get-ClusterConfiguration {
  # MODIFICATIONS REQUIRED in this section
  $config = @{
    userRole     = "Customer"
    adminUserInfo = @{
      id           = "admin"
      emailAddress = ""       # e.g. admin@example.com
      password     = "<SET_A_STRONG_PASSWORD>"  # REQUIRED: change before running; update again via UI after bootstrap
    }
    name              = ""   # Cluster display name
    dnsNameservers    = @("") # DNS server IP(s)
    dnsSearchDomains  = @("") # DNS search domain(s)
    ntpServerConfigs  = @(
      @{ server = "" }        # NTP server hostname or IP
    )

    # Populated automatically in later steps - do not modify
    cloudStorageLocation            = @{
      azureStorageConfig = @{
        containerName                       = ""
        isVersionLevelImmutabilitySupported = $true
        storageAccountName                  = ""
        managedIdentityClientId             = ""
        endpointSuffix                      = "core.windows.net"
      }
    }
    shouldDownloadAndRecoverMetavms = $false
    enableSoftwareEncryptionAtRest  = $false
    nodeConfigs                     = @{}
  }

  return $config
}

$ccconfig = Get-ClusterConfiguration

# -------------------------
# 2) Discover VM Network Configuration
# -------------------------
Write-Host "Discovering VMs matching pattern '$vmNamePattern' in resource group '$vmRg'..."
try {
  $allVMs = Get-AzVM -ResourceGroupName $vmRg -ErrorAction Stop
  if (-not $allVMs) {
    Write-Error "No VMs found in resource group '$vmRg'"
    exit 1
  }

  $filteredVMs = $allVMs | Where-Object { $_.Name -like $vmNamePattern }
  if ($filteredVMs.Count -eq 0) {
    Write-Error "No VMs matched pattern '$vmNamePattern' in '$vmRg'. Available: $($allVMs.Name -join ', ')"
    exit 1
  }

  Write-Host "Found $($filteredVMs.Count) VM(s) matching pattern."

  $vms = @()
  $processedCount = 0

  foreach ($vm in $filteredVMs) {
    try {
      Write-Host "Processing VM: $($vm.Name)"

      if (-not $vm.NetworkProfile.NetworkInterfaces -or $vm.NetworkProfile.NetworkInterfaces.Count -eq 0) {
        Write-Warning "VM '$($vm.Name)' has no network interfaces. Skipping."
        continue
      }

      $nicId = ($vm.NetworkProfile.NetworkInterfaces[0].Id).Split('/')[-1]
      if (-not $nicId) {
        Write-Warning "Could not extract NIC ID for VM '$($vm.Name)'. Skipping."
        continue
      }

      $nic = Get-AzNetworkInterface -Name $nicId -ResourceGroupName $vmRg -ErrorAction Stop
      if (-not $nic -or -not $nic.IpConfigurations -or $nic.IpConfigurations.Count -eq 0) {
        Write-Warning "NIC '$nicId' not found or has no IP configurations for VM '$($vm.Name)'. Skipping."
        continue
      }

      $ipConfig  = $nic.IpConfigurations[0]
      $privateIp = $ipConfig.PrivateIpAddress
      if (-not $privateIp) {
        Write-Warning "No private IP found for VM '$($vm.Name)'. Skipping."
        continue
      }

      if (-not $ipConfig.Subnet -or -not $ipConfig.Subnet.Id) {
        Write-Warning "No subnet information found for VM '$($vm.Name)'. Skipping."
        continue
      }

      # Parse VNet/Subnet details from the subnet resource ID
      $parts = $ipConfig.Subnet.Id -split '/'
      if ($parts.Count -lt 10) {
        Write-Warning "Unexpected subnet ID format for VM '$($vm.Name)': $($ipConfig.Subnet.Id). Skipping."
        continue
      }

      $vnetRg     = $parts[4]
      $vnetName   = $parts[8]
      $subnetName = $parts[-1]

      if (-not $vnetRg -or -not $vnetName -or -not $subnetName) {
        Write-Warning "Could not parse VNet details for VM '$($vm.Name)'. Skipping."
        continue
      }

      $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg -ErrorAction Stop
      if (-not $vnet) {
        Write-Warning "VNet '$vnetName' not found in '$vnetRg' for VM '$($vm.Name)'. Skipping."
        continue
      }

      $subnet = $vnet.Subnets | Where-Object Name -EQ $subnetName
      if (-not $subnet) {
        Write-Warning "Subnet '$subnetName' not found in VNet '$vnetName'. Skipping."
        continue
      }

      $cidr = $subnet.AddressPrefix
      if (-not $cidr -or $cidr -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') {
        Write-Warning "Invalid CIDR '$cidr' for VM '$($vm.Name)'. Skipping."
        continue
      }

      # Compute subnet mask from prefix length
      $prefixLength = [int]($cidr.Split('/')[-1])
      if ($prefixLength -lt 1 -or $prefixLength -gt 32) {
        Write-Warning "Invalid prefix length '$prefixLength' for VM '$($vm.Name)'. Skipping."
        continue
      }
      $binMask    = ('1' * $prefixLength).PadRight(32, '0')
      $maskParts  = for ($i = 0; $i -lt 4; $i++) { [Convert]::ToInt32($binMask.Substring($i * 8, 8), 2) }
      $subnetMask = $maskParts -join '.'

      # Gateway = first usable host in the subnet
      $networkAddr    = $cidr.Split('/')[0].Split('.') | ForEach-Object { [int]$_ }
      $networkAddr[3] = $networkAddr[3] + 1
      $gatewayIp      = $networkAddr -join '.'

      $vms += [PSCustomObject]@{
        Name       = $vm.Name
        PrivateIP  = $privateIp
        SubnetMask = $subnetMask
        Gateway    = $gatewayIp
        Zone       = $vm.Zones
      }
      $processedCount++

      Write-Host "  Private IP : $privateIp"
      Write-Host "  Subnet Mask: $subnetMask"
      Write-Host "  Gateway    : $gatewayIp"
      Write-Host "  Zone       : $($vm.Zones -join ', ')"
    }
    catch {
      Write-Warning "Error processing VM '$($vm.Name)': $($_.Exception.Message)"
    }
  }

  if ($vms.Count -eq 0) {
    Write-Error "No VMs were successfully processed. Cannot proceed."
    exit 1
  }
  if ($processedCount -lt $filteredVMs.Count) {
    Write-Warning "Only $processedCount of $($filteredVMs.Count) VMs processed successfully."
  }

  Write-Host "Successfully processed $($vms.Count) VM(s)."
}
catch {
  Write-Error "Critical error during VM discovery: $($_.Exception.Message)"
  Write-Error $_.Exception.StackTrace
  exit 1
}

# -------------------------
# 3) Resolve Azure Storage Configuration
# -------------------------
$storageAccount = Get-AzStorageAccount -ResourceGroupName $storageRg -Name $storageAccountName -ErrorAction Stop

$containers = Get-AzRmStorageContainer -ResourceGroupName $storageRg -AccountName $storageAccountName |
  Where-Object { $_.Name -like "$containerPrefix*" }

if ($containers.Count -gt 0) {
  $containerName = $containers[0].Name
  Write-Host "Found container: $containerName"
}
else {
  Write-Error "No containers found with prefix '$containerPrefix' in storage account '$storageAccountName'."
  exit 1
}

$managedIdentity = Get-AzUserAssignedIdentity -ResourceGroupName $storageRg -Name $managedIdentityName
if ($managedIdentity) {
  $managedIdentityClientId = $managedIdentity.ClientId
  Write-Host "Found managed identity: $($managedIdentity.Name)"
}
else {
  Write-Error "Managed identity '$managedIdentityName' not found in resource group '$storageRg'."
  exit 1
}

# -------------------------
# 4) Build Node Configurations
# -------------------------
$nodeConfigs = @{}
for ($i = 0; $i -lt $vms.Count; $i++) {
  $nodeConfigs[($i + 1).ToString()] = @{
    managementIpConfig = @{
      address = $vms[$i].PrivateIP
      netmask = $vms[$i].SubnetMask
      gateway = $vms[$i].Gateway
    }
    chassisId          = $vms[$i].Zone[0]
  }
}

# -------------------------
# 5) Build Storage Location Configuration
# -------------------------
$cloudStorageLocation = @{
  azureStorageConfig = @{
    containerName                       = $containerName
    isVersionLevelImmutabilitySupported = $immutability
    storageAccountName                  = $storageAccount.StorageAccountName
    managedIdentityClientId             = $managedIdentityClientId
    endpointSuffix                      = "core.windows.net"
  }
}

# -------------------------
# 6) Merge Discovered Values into Cluster Configuration
# -------------------------
$ccconfig.cloudStorageLocation = $cloudStorageLocation
$ccconfig.nodeConfigs          = $nodeConfigs

# -------------------------
# 7) Bootstrap the Cloud Cluster
# -------------------------
$bootstrapSucceeded = $false
try {
  $webResponse = Invoke-WebRequest -Method POST `
    -Body ($ccconfig | ConvertTo-Json -Depth 10) `
    -ContentType "application/json" `
    -SkipCertificateCheck `
    -Uri "https://$($vms[0].PrivateIP)/api/internal/cluster/me/bootstrap"

  $statusCode = $webResponse.StatusCode

  if ($statusCode -eq 202) {
    $requestId      = ($webResponse.Content | ConvertFrom-Json).id
    $statusResponse = $null

    do {
      try {
        $statusWebResponse = Invoke-WebRequest -Method GET `
          -ContentType "application/json" `
          -SkipCertificateCheck `
          -Uri "https://$($vms[0].PrivateIP)/api/internal/cluster/me/bootstrap?request_id=$requestId"
        $statusResponse = $statusWebResponse.Content | ConvertFrom-Json
        Write-Host "Bootstrap status: $($statusResponse.status) - $($statusResponse.message)"
        Start-Sleep -Seconds 60
      }
      catch {
        Write-Warning "Error polling bootstrap status: $($_.Exception.Message)"
        break
      }
    } while ($statusResponse -and $statusResponse.status -ne "FAILURE" -and $statusResponse.status -ne "SUCCESS")

    Write-Host "Final bootstrap status: $($statusResponse.status)"
    $bootstrapSucceeded = $statusResponse.status -eq "SUCCESS"
  }
  elseif ($statusCode -eq 422 -and $webResponse.Content -match 'already bootstrapped node') {
    Write-Host "Cluster is already bootstrapped (422). Continuing with registration."
    $bootstrapSucceeded = $true
  }
  else {
    Write-Error "Bootstrap failed. Status: $statusCode`nResponse: $($webResponse.Content)"
    exit 1
  }
}
catch {
  $statusCode   = $_.Exception.Response?.StatusCode.value__
  $errorMessage = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }

  if ($statusCode -eq 422 -and $errorMessage -match 'already bootstrapped node') {
    Write-Host "Cluster is already bootstrapped (422). Continuing with registration."
    $bootstrapSucceeded = $true
  }
  else {
    Write-Error "Bootstrap failed. HTTP $statusCode - $errorMessage"
    exit 1
  }
}

# -------------------------
# 8) Register Cluster with Rubrik Security Cloud
# -------------------------
if (-not $bootstrapSucceeded) {
  Write-Host "Bootstrap did not succeed. Skipping RSC registration."
  exit 1
}

Write-Host "Bootstrap succeeded. Starting RSC online registration..."

if (-not $rscServiceAccountFile) {
  Write-Error "rscServiceAccountFile must be set for RSC registration."
  exit 1
}

$rscLogin        = Connect-RscServiceAccount -ServiceAccountFile $rscServiceAccountFile
$rscAccessToken  = $rscLogin.AccessToken
$rscHost         = $rscLogin.RscHost

$cdmNodeIp   = $vms[0].PrivateIP
$cdmBaseUri  = "https://$cdmNodeIp"
$basicAuth   = [Convert]::ToBase64String(
  [Text.Encoding]::UTF8.GetBytes("$($ccconfig.adminUserInfo.id):$($ccconfig.adminUserInfo.password)")
)

$cdmHeaders = @{
  'Accept'        = 'application/json'
  'Content-Type'  = 'application/json'
  'Authorization' = "Basic $basicAuth"
}

$registrationRequestUri = "$cdmBaseUri/api/internal/cluster/me/online_registration_request" +
  "?rubrik_url=$([System.Uri]::EscapeDataString($rscHost))" +
  "&redirect_cdm_uri=$([System.Uri]::EscapeDataString($cdmBaseUri))"

$registrationRequest = Invoke-RestMethod -Method Post -Uri $registrationRequestUri `
  -Headers $cdmHeaders -SkipCertificateCheck

$oauthPayload = @{
  client_id             = $registrationRequest.clientId
  state                 = [string]$registrationRequest.State
  redirect_uri          = $registrationRequest.redirectUri
  scope                 = $registrationRequest.scope
  response_type         = $registrationRequest.responseType
  code_challenge        = [string]$registrationRequest.pkceCodeChallenge
  code_challenge_method = [string]$registrationRequest.pkceCodeChallengeMethod
}

$rscHeaders = @{
  'Accept'        = 'application/json'
  'Content-Type'  = 'application/json'
  'Authorization' = "Bearer $rscAccessToken"
}

$authorizeResponse = Invoke-RestMethod -Method Post `
  -Uri "https://$rscHost/api/oauth/authorize" `
  -Body ($oauthPayload | ConvertTo-Json -Depth 10) `
  -Headers $rscHeaders -SkipCertificateCheck

$authCode = if ($authorizeResponse -is [string]) { $authorizeResponse } else { $authorizeResponse.code }

$finalRegistrationUri = "$cdmBaseUri/api/internal/cluster/me/online_registration_v2" +
  "?state=$([System.Uri]::EscapeDataString([string]$registrationRequest.State))" +
  "&rubrik_authorization_code=$([System.Uri]::EscapeDataString($authCode))" +
  "&product_type=Hybrid"

$registrationResponse = Invoke-RestMethod -Method Post -Uri $finalRegistrationUri `
  -Headers $cdmHeaders -SkipCertificateCheck

Write-Host "Registration result    : $($registrationResponse.registeredMode.result)"
Write-Host "Connected to Rubrik    : $($registrationResponse.isConnectedToRubrik)"
Write-Host "RSC URL                : $($registrationResponse.url)"
