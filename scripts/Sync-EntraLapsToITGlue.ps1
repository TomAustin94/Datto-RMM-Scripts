<#
.SYNOPSIS
Sync an Entra ID (Azure AD) Windows LAPS password into an IT Glue Password record.

.DESCRIPTION
Uses Microsoft Graph (beta) deviceLocalCredentials to retrieve the current LAPS password for a device,
then creates or updates an IT Glue Password record (by name) with the retrieved password.

Prereqs:
  - Microsoft Graph PowerShell SDK installed (Microsoft.Graph)
  - Graph permission: DeviceLocalCredential.Read.All
  - IT Glue API key with write access

.PARAMETER DeviceName
Entra ID device display name (e.g., "PC-001").

.PARAMETER AllDevices
Enumerate all Entra devices with LAPS credentials available and sync them in bulk.

.PARAMETER LocalAdminAccountName
The local admin account name to select from the returned LAPS credentials (default: "Administrator").
If not found, the script falls back to the first credential returned.

.PARAMETER ITGlueApiKey
IT Glue API key (x-api-key header). If not provided, the script will try to read it from an environment
variable (recommended for Datto RMM components) such as ITGLUE_API_KEY.

.PARAMETER ITGlueOrganizationId
IT Glue organization ID that owns the Password record.

.PARAMETER ITGluePasswordName
IT Glue Password record name to upsert (single-device mode). If not provided, the name is generated from
-ITGluePasswordNameTemplate.

.PARAMETER ITGluePasswordNameTemplate
Template used to generate per-device IT Glue Password names. Default: "{DeviceName} - LAPS".

.PARAMETER ITGlueBaseUri
IT Glue API base URI. Default: https://api.itglue.com

.PARAMETER ITGluePasswordCategoryId
Optional IT Glue password category ID to set on create.

.PARAMETER ITGlueResourceType
Optional IT Glue resource type to associate (commonly "Configurations").

.PARAMETER ITGlueResourceId
Optional IT Glue resource ID to associate (e.g., a Configuration ID).

.PARAMETER ConfigurationSerialNumber
Optional override for the device serial number to use when looking up an IT Glue Configuration item.
If not provided, the script attempts to retrieve the serial number from Microsoft Graph.

.PARAMETER DisableConfigurationLookup
Disable automatic lookup of an IT Glue Configuration item by serial number when -ITGlueResourceId is not provided.

.PARAMETER RequireConfigurationMatch
If set, the script stops when it cannot uniquely match an IT Glue Configuration item by serial number.

.PARAMETER ITGlueNotes
Optional notes to store alongside the password.

.PARAMETER TenantId
Optional Entra tenant ID to use for Connect-MgGraph.

.EXAMPLE
.\scripts\Sync-EntraLapsToITGlue.ps1 -DeviceName "PC-001" -ITGlueApiKey $env:ITGLUE_API_KEY -ITGlueOrganizationId 123456

.EXAMPLE
.\scripts\Sync-EntraLapsToITGlue.ps1 -DeviceName "PC-001" -LocalAdminAccountName "LAPSAdmin" -ITGlueApiKey (Get-Content .\itglue.key -Raw) -ITGlueOrganizationId 123456 -ITGluePasswordName "PC-001 / LAPS" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false, DefaultParameterSetName = "Single")]
param(
  [Parameter(Mandatory = $true, ParameterSetName = "Single")]
  [ValidateNotNullOrEmpty()]
  [string] $DeviceName,

  [Parameter(Mandatory = $true, ParameterSetName = "All")]
  [switch] $AllDevices,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $LocalAdminAccountName = "Administrator",

  [Parameter()]
  [string] $ITGlueApiKey,

  [Parameter(Mandatory = $true)]
  [ValidateRange(1, 2147483647)]
  [int] $ITGlueOrganizationId,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGluePasswordName,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGluePasswordNameTemplate = "{DeviceName} - LAPS",

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGlueBaseUri = "https://api.itglue.com",

  [Parameter()]
  [ValidateRange(1, 2147483647)]
  [int] $ITGluePasswordCategoryId,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGlueResourceType,

  [Parameter()]
  [ValidateRange(1, 2147483647)]
  [int] $ITGlueResourceId,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ConfigurationSerialNumber,

  [Parameter()]
  [switch] $DisableConfigurationLookup,

  [Parameter()]
  [switch] $RequireConfigurationMatch,

  [Parameter()]
  [string] $ITGlueNotes,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $TenantId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$DefaultITGlueApiKey = $env:ITGLUE_API_KEY
if (-not $DefaultITGlueApiKey) { $DefaultITGlueApiKey = $env:ITGlueApiKey }
if (-not $DefaultITGlueApiKey) { $DefaultITGlueApiKey = $env:IT_GLUE_API_KEY }

if (-not $ITGlueApiKey) { $ITGlueApiKey = $DefaultITGlueApiKey }
if (-not $ITGlueApiKey) {
  throw "IT Glue API key not provided. Pass -ITGlueApiKey or set environment variable ITGLUE_API_KEY."
}

if ($PSCmdlet.ParameterSetName -eq "All") {
  if ($ITGluePasswordName) {
    throw "In -AllDevices mode, do not pass -ITGluePasswordName (it would cause all devices to overwrite the same record). Use -ITGluePasswordNameTemplate instead."
  }
  if ($ConfigurationSerialNumber) {
    throw "In -AllDevices mode, do not pass -ConfigurationSerialNumber (it would associate all devices to the same serial/config). Let the script resolve serials per-device, or use -DisableConfigurationLookup."
  }
}

function Ensure-MgGraphConnection {
  param(
    [Parameter(Mandatory = $true)][string[]] $Scopes,
    [Parameter()][string] $TenantId
  )

  if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Microsoft Graph PowerShell SDK not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser"
  }

  Import-Module Microsoft.Graph.Authentication -ErrorAction Stop | Out-Null
  Import-Module Microsoft.Graph.Devices -ErrorAction Stop | Out-Null

  $ctx = $null
  try { $ctx = Get-MgContext } catch { }

  $needConnect = $true
  if ($ctx -and $ctx.Account) {
    $granted = @()
    try { $granted = @($ctx.Scopes) } catch { }
    $missing = @($Scopes | Where-Object { $granted -notcontains $_ })
    if (-not $missing) { $needConnect = $false }
  }

  if ($needConnect) {
    if ($TenantId) {
      Connect-MgGraph -TenantId $TenantId -Scopes $Scopes | Out-Null
    } else {
      Connect-MgGraph -Scopes $Scopes | Out-Null
    }
  }
}

function ConvertTo-GraphODataStringLiteral {
  param([Parameter(Mandatory = $true)][string] $Value)
  return $Value.Replace("'", "''")
}

function ConvertFrom-Base64StringToText {
  param([Parameter(Mandatory = $true)][string] $Base64)

  $bytes = [Convert]::FromBase64String($Base64)

  $utf8 = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($utf8 -notmatch "`0") { return $utf8 }

  $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
  if ($unicode -notmatch "`0") { return $unicode }

  return $utf8.TrimEnd([char]0)
}

function Get-EntraLapsCredential {
  param(
    [Parameter(Mandatory = $true)][string] $DeviceName,
    [Parameter(Mandatory = $true)][string] $LocalAdminAccountName,
    [Parameter()][string] $TenantId
  )

  $escapedName = ConvertTo-GraphODataStringLiteral -Value $DeviceName
  $devices = Get-MgDevice -Filter "displayName eq '$escapedName'" -All -Property "id,deviceId,displayName,physicalIds"
  if (-not $devices) { throw "No Entra ID device found with displayName '$DeviceName'." }
  if ($devices.Count -gt 1) { throw "Multiple Entra ID devices found with displayName '$DeviceName'. Use a unique name." }

  return Get-EntraLapsCredentialByDevice -Device $devices[0] -LocalAdminAccountName $LocalAdminAccountName
}

function Get-EntraLapsCredentialByDevice {
  param(
    [Parameter(Mandatory = $true)][object] $Device,
    [Parameter(Mandatory = $true)][string] $LocalAdminAccountName
  )

  $deviceId = $Device.Id
  $azureAdDeviceId = $Device.DeviceId
  $physicalIds = $Device.PhysicalIds
  $deviceName = $Device.DisplayName

  $uri = "https://graph.microsoft.com/beta/deviceLocalCredentials/$deviceId"
  $response = Invoke-MgGraphRequest -Method GET -Uri $uri

  if (-not $response.credentials) { throw "No LAPS credentials returned for device '$deviceName' ($deviceId)." }

  $selected = @($response.credentials | Where-Object { $_.accountName -eq $LocalAdminAccountName })
  if (-not $selected) { $selected = @($response.credentials | Select-Object -First 1) }

  $cred = $selected | Select-Object -First 1
  if (-not $cred.passwordBase64) { throw "Graph did not return passwordBase64 for device '$deviceName'." }

  $password = ConvertFrom-Base64StringToText -Base64 $cred.passwordBase64

  [PSCustomObject]@{
    DeviceId                   = $deviceId
    AzureAdDeviceId            = $azureAdDeviceId
    DeviceName                 = $deviceName
    PhysicalIds                = $physicalIds
    AccountName                = $cred.accountName
    Password                   = $password
    BackupDateTime             = $cred.backupDateTime
    PasswordExpirationDateTime = $cred.passwordExpirationDateTime
  }
}

function Get-GraphPagedItems {
  param(
    [Parameter(Mandatory = $true)][string] $Uri
  )

  $items = @()
  $next = $Uri
  while ($next) {
    $res = Invoke-MgGraphRequest -Method GET -Uri $next
    if ($res.value) { $items += @($res.value) }
    $next = $null
    try { $next = $res.'@odata.nextLink' } catch { }
  }
  return $items
}

function Get-EntraDevicesWithLapsEnabled {
  $uri = "https://graph.microsoft.com/beta/deviceLocalCredentials?`$select=id&`$top=999"
  $entries = @(Get-GraphPagedItems -Uri $uri)
  if (-not $entries) { return @() }

  $devices = @()
  foreach ($entry in $entries) {
    if (-not $entry.id) { continue }
    try {
      $devices += Get-MgDevice -DeviceId $entry.id -Property "id,deviceId,displayName,physicalIds"
    } catch {
      Write-Warning "Unable to read device '$($entry.id)' from Graph. Skipping. Error: $($_.Exception.Message)"
    }
  }
  return $devices
}

function Get-EntraDeviceSerialNumber {
  param(
    [Parameter()][string] $AzureAdDeviceId,
    [Parameter()][string[]] $PhysicalIds,
    [Parameter()][string] $DeviceName
  )

  if ($PhysicalIds) {
    foreach ($entry in $PhysicalIds) {
      if (-not $entry) { continue }

      $m = [regex]::Match($entry, "(?i)(?:\\[serial(?:number)?\\]|serial(?:number)?)\\s*[:=]\\s*(.+)$")
      if ($m.Success) {
        $serial = $m.Groups[1].Value.Trim()
        if ($serial) { return $serial }
      }
    }
  }

  if (-not $AzureAdDeviceId) { return $null }

  $filter = [System.Net.WebUtility]::UrlEncode("azureADDeviceId eq '$AzureAdDeviceId'")
  $select = [System.Net.WebUtility]::UrlEncode("serialNumber,deviceName,azureADDeviceId")
  $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$filter&`$select=$select"

  try {
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    $matches = @($response.value | Where-Object { $_.serialNumber })
    if (-not $matches) { return $null }

    if ($matches.Count -gt 1 -and $DeviceName) {
      $byName = @($matches | Where-Object { $_.deviceName -eq $DeviceName })
      if ($byName.Count -ge 1) { return ($byName | Select-Object -First 1).serialNumber }
    }

    return ($matches | Select-Object -First 1).serialNumber
  } catch {
    Write-Warning "Unable to query Intune managedDevices for serial number. If you need serial-based IT Glue configuration association, grant Graph scope DeviceManagementManagedDevices.Read.All (or pass -ConfigurationSerialNumber). Error: $($_.Exception.Message)"
    return $null
  }
}

function Invoke-ITGlueRequest {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PATCH")][string] $Method,
    [Parameter(Mandatory = $true)][string] $BaseUri,
    [Parameter(Mandatory = $true)][string] $ApiKey,
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter()][object] $Body
  )

  $headers = @{
    "x-api-key"      = $ApiKey
    "Accept"         = "application/vnd.api+json"
    "Content-Type"   = "application/vnd.api+json"
  }

  $uri = ($BaseUri.TrimEnd("/") + "/" + $Path.TrimStart("/"))

  $payload = $null
  if ($null -ne $Body) {
    $payload = $Body | ConvertTo-Json -Depth 20
  }

  $maxAttempts = 5
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
      if ($payload) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $payload
      }
      return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    } catch {
      $statusCode = $null
      $retryAfter = $null
      $responseBody = $null

      if ($_.Exception.Response) {
        try {
          $statusCode = [int]$_.Exception.Response.StatusCode
        } catch { }

        try {
          $retryAfter = $_.Exception.Response.Headers["Retry-After"]
        } catch { }

        try {
          $stream = $_.Exception.Response.GetResponseStream()
          if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            $responseBody = $reader.ReadToEnd()
          }
        } catch { }
      }

      if ($statusCode -eq 429 -and $attempt -lt $maxAttempts) {
        $sleepSeconds = 5
        if ($retryAfter) {
          [int]::TryParse(($retryAfter | Select-Object -First 1), [ref]$sleepSeconds) | Out-Null
        }
        Start-Sleep -Seconds $sleepSeconds
        continue
      }

      if ($responseBody) {
        throw "IT Glue API error ($statusCode) calling $Method $uri. Response: $responseBody"
      }
      throw
    }
  }
}

function Get-ITGlueConfigurationBySerialNumber {
  param(
    [Parameter(Mandatory = $true)][string] $BaseUri,
    [Parameter(Mandatory = $true)][string] $ApiKey,
    [Parameter(Mandatory = $true)][int] $OrganizationId,
    [Parameter(Mandatory = $true)][string] $SerialNumber
  )

  $encodedSerial = [System.Net.WebUtility]::UrlEncode($SerialNumber.Trim())
  $path = "configurations?filter[organization_id]=$OrganizationId&filter[serial_number]=$encodedSerial&page[size]=2"
  $result = Invoke-ITGlueRequest -Method GET -BaseUri $BaseUri -ApiKey $ApiKey -Path $path

  if (-not $result.data) { return $null }
  if ($result.data.Count -eq 1) { return $result.data[0] }
  if ($result.data.Count -gt 1) { throw "Multiple IT Glue Configurations matched serial number '$SerialNumber' in org $OrganizationId. Specify -ITGlueResourceId to disambiguate." }
  return $null
}

function Get-ITGluePasswordByName {
  param(
    [Parameter(Mandatory = $true)][string] $BaseUri,
    [Parameter(Mandatory = $true)][string] $ApiKey,
    [Parameter(Mandatory = $true)][int] $OrganizationId,
    [Parameter(Mandatory = $true)][string] $Name
  )

  $encodedName = [System.Net.WebUtility]::UrlEncode($Name)
  $path = "passwords?filter[organization_id]=$OrganizationId&filter[name]=$encodedName&page[size]=1"
  $result = Invoke-ITGlueRequest -Method GET -BaseUri $BaseUri -ApiKey $ApiKey -Path $path
  if ($result.data -and $result.data.Count -ge 1) { return $result.data[0] }
  return $null
}

function New-ITGluePassword {
  param(
    [Parameter(Mandatory = $true)][string] $BaseUri,
    [Parameter(Mandatory = $true)][string] $ApiKey,
    [Parameter(Mandatory = $true)][int] $OrganizationId,
    [Parameter(Mandatory = $true)][string] $Name,
    [Parameter(Mandatory = $true)][string] $Username,
    [Parameter(Mandatory = $true)][string] $Password,
    [Parameter()][string] $Notes,
    [Parameter()][int] $PasswordCategoryId,
    [Parameter()][string] $ResourceType,
    [Parameter()][int] $ResourceId
  )

  $attributes = @{
    name     = $Name
    username = $Username
    password = $Password
  }
  if ($Notes) { $attributes.notes = $Notes }
  if ($PasswordCategoryId) { $attributes.password_category_id = $PasswordCategoryId }
  if ($ResourceType) { $attributes.resource_type = $ResourceType }
  if ($ResourceId) { $attributes.resource_id = $ResourceId }
  $attributes.organization_id = $OrganizationId

  $body = @{
    data = @{
      type       = "passwords"
      attributes = $attributes
    }
  }

  return Invoke-ITGlueRequest -Method POST -BaseUri $BaseUri -ApiKey $ApiKey -Path "passwords" -Body $body
}

function Set-ITGluePassword {
  param(
    [Parameter(Mandatory = $true)][string] $BaseUri,
    [Parameter(Mandatory = $true)][string] $ApiKey,
    [Parameter(Mandatory = $true)][string] $PasswordId,
    [Parameter(Mandatory = $true)][int] $OrganizationId,
    [Parameter(Mandatory = $true)][string] $Name,
    [Parameter(Mandatory = $true)][string] $Username,
    [Parameter(Mandatory = $true)][string] $Password,
    [Parameter()][string] $Notes,
    [Parameter()][int] $PasswordCategoryId,
    [Parameter()][string] $ResourceType,
    [Parameter()][int] $ResourceId
  )

  $attributes = @{
    name     = $Name
    username = $Username
    password = $Password
  }
  if ($Notes) { $attributes.notes = $Notes }
  if ($PasswordCategoryId) { $attributes.password_category_id = $PasswordCategoryId }
  if ($ResourceType) { $attributes.resource_type = $ResourceType }
  if ($ResourceId) { $attributes.resource_id = $ResourceId }
  $attributes.organization_id = $OrganizationId

  $body = @{
    data = @{
      id         = [string]$PasswordId
      type       = "passwords"
      attributes = $attributes
    }
  }

  return Invoke-ITGlueRequest -Method PATCH -BaseUri $BaseUri -ApiKey $ApiKey -Path "passwords/$PasswordId" -Body $body
}

function Resolve-ITGluePasswordName {
  param(
    [Parameter()][string] $ExplicitName,
    [Parameter(Mandatory = $true)][string] $Template,
    [Parameter(Mandatory = $true)][string] $DeviceName
  )

  if ($ExplicitName) { return $ExplicitName }
  return $Template.Replace("{DeviceName}", $DeviceName)
}

function Sync-DeviceLapsToITGlue {
  param(
    [Parameter(Mandatory = $true)][object] $Device
  )

  $laps = Get-EntraLapsCredentialByDevice -Device $Device -LocalAdminAccountName $LocalAdminAccountName

  $resolvedPasswordName = Resolve-ITGluePasswordName -ExplicitName $ITGluePasswordName -Template $ITGluePasswordNameTemplate -DeviceName $laps.DeviceName

  $resolvedResourceType = $ITGlueResourceType
  $resolvedResourceId = $ITGlueResourceId

  if (
    (-not $DisableConfigurationLookup) -and
    (-not $resolvedResourceId) -and
    ((-not $resolvedResourceType) -or ($resolvedResourceType -eq "Configurations"))
  ) {
    $serial = $ConfigurationSerialNumber
    if (-not $serial) {
      $serial = Get-EntraDeviceSerialNumber -AzureAdDeviceId $laps.AzureAdDeviceId -PhysicalIds $laps.PhysicalIds -DeviceName $laps.DeviceName
    }

    if ($serial) {
      try {
        $config = Get-ITGlueConfigurationBySerialNumber -BaseUri $ITGlueBaseUri -ApiKey $ITGlueApiKey -OrganizationId $ITGlueOrganizationId -SerialNumber $serial
        if ($config) {
          if (-not $resolvedResourceType) { $resolvedResourceType = "Configurations" }
          $resolvedResourceId = [int]$config.id
        } elseif ($RequireConfigurationMatch) {
          throw "No IT Glue Configuration found with serial number '$serial' in org $ITGlueOrganizationId."
        } else {
          Write-Warning "No IT Glue Configuration found with serial number '$serial' in org $ITGlueOrganizationId. Continuing without resource association."
        }
      } catch {
        if ($RequireConfigurationMatch) { throw }
        Write-Warning "Failed to resolve IT Glue Configuration by serial number. Continuing without resource association. Error: $($_.Exception.Message)"
      }
    } elseif ($RequireConfigurationMatch) {
      throw "Unable to determine device serial number from Microsoft Graph. Pass -ConfigurationSerialNumber, or disable serial-based association with -DisableConfigurationLookup."
    } else {
      Write-Warning "Unable to determine device serial number from Microsoft Graph; skipping IT Glue Configuration association."
    }
  }

  $noteParts = @()
  if ($ITGlueNotes) { $noteParts += $ITGlueNotes.Trim() }
  if ($laps.BackupDateTime) { $noteParts += "Graph backupDateTime: $($laps.BackupDateTime)" }
  if ($laps.PasswordExpirationDateTime) { $noteParts += "Graph passwordExpirationDateTime: $($laps.PasswordExpirationDateTime)" }
  $combinedNotes = ($noteParts -join "`n").Trim()
  if (-not $combinedNotes) { $combinedNotes = $null }

  $existing = Get-ITGluePasswordByName -BaseUri $ITGlueBaseUri -ApiKey $ITGlueApiKey -OrganizationId $ITGlueOrganizationId -Name $resolvedPasswordName

  $target = if ($existing) { "IT Glue password '$resolvedPasswordName' (id: $($existing.id))" } else { "IT Glue password '$resolvedPasswordName' (new)" }
  $result = $null
  if ($PSCmdlet.ShouldProcess($target, "Upsert LAPS password")) {
    if ($existing) {
      $result = Set-ITGluePassword `
        -BaseUri $ITGlueBaseUri `
        -ApiKey $ITGlueApiKey `
        -PasswordId $existing.id `
        -OrganizationId $ITGlueOrganizationId `
        -Name $resolvedPasswordName `
        -Username $laps.AccountName `
        -Password $laps.Password `
        -Notes $combinedNotes `
        -PasswordCategoryId $ITGluePasswordCategoryId `
        -ResourceType $resolvedResourceType `
        -ResourceId $resolvedResourceId
    } else {
      $result = New-ITGluePassword `
        -BaseUri $ITGlueBaseUri `
        -ApiKey $ITGlueApiKey `
        -OrganizationId $ITGlueOrganizationId `
        -Name $resolvedPasswordName `
        -Username $laps.AccountName `
        -Password $laps.Password `
        -Notes $combinedNotes `
        -PasswordCategoryId $ITGluePasswordCategoryId `
        -ResourceType $resolvedResourceType `
        -ResourceId $resolvedResourceId
    }
  }

  $resultId = $null
  if ($existing) {
    $resultId = $existing.id
  } elseif ($result -and $result.data -and $result.data.id) {
    $resultId = $result.data.id
  }

  [PSCustomObject]@{
    DeviceName                 = $laps.DeviceName
    DeviceId                   = $laps.DeviceId
    AccountName                = $laps.AccountName
    PasswordExpirationDateTime = $laps.PasswordExpirationDateTime
    ITGlueOrganizationId       = $ITGlueOrganizationId
    ITGluePasswordName         = $resolvedPasswordName
    ITGluePasswordId           = $resultId
    ITGlueResourceType         = $resolvedResourceType
    ITGlueResourceId           = $resolvedResourceId
  }
}

$scopes = @("DeviceLocalCredential.Read.All", "Device.Read.All")
$needsManagedDevicesSerial =
  (-not $DisableConfigurationLookup) -and
  (-not $ITGlueResourceId) -and
  (-not $ConfigurationSerialNumber) -and
  ((-not $ITGlueResourceType) -or ($ITGlueResourceType -eq "Configurations"))
if ($needsManagedDevicesSerial) { $scopes += "DeviceManagementManagedDevices.Read.All" }

Ensure-MgGraphConnection -Scopes $scopes -TenantId $TenantId

if ($PSCmdlet.ParameterSetName -eq "All") {
  $devices = @(Get-EntraDevicesWithLapsEnabled)
  foreach ($device in $devices) {
    try {
      Sync-DeviceLapsToITGlue -Device $device
    } catch {
      Write-Warning "Failed syncing LAPS for '$($device.DisplayName)' ($($device.Id)). Error: $($_.Exception.Message)"
    }
  }
} else {
  $device = Get-MgDevice -Filter "displayName eq '$(ConvertTo-GraphODataStringLiteral -Value $DeviceName)'" -All -Property "id,deviceId,displayName,physicalIds"
  if (-not $device) { throw "No Entra ID device found with displayName '$DeviceName'." }
  if ($device.Count -gt 1) { throw "Multiple Entra ID devices found with displayName '$DeviceName'. Use a unique name." }
  Sync-DeviceLapsToITGlue -Device $device[0]
}
