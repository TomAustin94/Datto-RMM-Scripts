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

.PARAMETER LocalAdminAccountName
The local admin account name to select from the returned LAPS credentials (default: "Administrator").
If not found, the script falls back to the first credential returned.

.PARAMETER ITGlueApiKey
IT Glue API key (x-api-key header). Consider using a secret manager and passing it in at runtime.

.PARAMETER ITGlueOrganizationId
IT Glue organization ID that owns the Password record.

.PARAMETER ITGluePasswordName
IT Glue Password record name to upsert. Default: "<DeviceName> - LAPS".

.PARAMETER ITGlueBaseUri
IT Glue API base URI. Default: https://api.itglue.com

.PARAMETER ITGluePasswordCategoryId
Optional IT Glue password category ID to set on create.

.PARAMETER ITGlueResourceType
Optional IT Glue resource type to associate (commonly "Configurations").

.PARAMETER ITGlueResourceId
Optional IT Glue resource ID to associate (e.g., a Configuration ID).

.PARAMETER ITGlueNotes
Optional notes to store alongside the password.

.PARAMETER TenantId
Optional Entra tenant ID to use for Connect-MgGraph.

.EXAMPLE
.\scripts\Sync-EntraLapsToITGlue.ps1 -DeviceName "PC-001" -ITGlueApiKey $env:ITGLUE_API_KEY -ITGlueOrganizationId 123456

.EXAMPLE
.\scripts\Sync-EntraLapsToITGlue.ps1 -DeviceName "PC-001" -LocalAdminAccountName "LAPSAdmin" -ITGlueApiKey (Get-Content .\itglue.key -Raw) -ITGlueOrganizationId 123456 -ITGluePasswordName "PC-001 / LAPS" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $DeviceName,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $LocalAdminAccountName = "Administrator",

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $ITGlueApiKey,

  [Parameter(Mandatory = $true)]
  [ValidateRange(1, 2147483647)]
  [int] $ITGlueOrganizationId,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGluePasswordName = "$DeviceName - LAPS",

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
  [string] $ITGlueNotes,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $TenantId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

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

  if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Microsoft Graph PowerShell SDK not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser"
  }

  Import-Module Microsoft.Graph.Authentication -ErrorAction Stop | Out-Null
  Import-Module Microsoft.Graph.Devices -ErrorAction Stop | Out-Null

  $scopes = @("DeviceLocalCredential.Read.All", "Device.Read.All")
  if ($TenantId) {
    Connect-MgGraph -TenantId $TenantId -Scopes $scopes | Out-Null
  } else {
    Connect-MgGraph -Scopes $scopes | Out-Null
  }

  $escapedName = ConvertTo-GraphODataStringLiteral -Value $DeviceName
  $devices = Get-MgDevice -Filter "displayName eq '$escapedName'" -All
  if (-not $devices) { throw "No Entra ID device found with displayName '$DeviceName'." }
  if ($devices.Count -gt 1) { throw "Multiple Entra ID devices found with displayName '$DeviceName'. Use a unique name." }

  $deviceId = $devices[0].Id
  $uri = "https://graph.microsoft.com/beta/deviceLocalCredentials/$deviceId"
  $response = Invoke-MgGraphRequest -Method GET -Uri $uri

  if (-not $response.credentials) { throw "No LAPS credentials returned for device '$DeviceName' ($deviceId)." }

  $selected = @($response.credentials | Where-Object { $_.accountName -eq $LocalAdminAccountName })
  if (-not $selected) { $selected = @($response.credentials | Select-Object -First 1) }

  $cred = $selected | Select-Object -First 1
  if (-not $cred.passwordBase64) { throw "Graph did not return passwordBase64 for device '$DeviceName'." }

  $password = ConvertFrom-Base64StringToText -Base64 $cred.passwordBase64

  [PSCustomObject]@{
    DeviceId                   = $deviceId
    DeviceName                 = $DeviceName
    AccountName                = $cred.accountName
    Password                   = $password
    BackupDateTime             = $cred.backupDateTime
    PasswordExpirationDateTime = $cred.passwordExpirationDateTime
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

$laps = Get-EntraLapsCredential -DeviceName $DeviceName -LocalAdminAccountName $LocalAdminAccountName -TenantId $TenantId

$noteParts = @()
if ($ITGlueNotes) { $noteParts += $ITGlueNotes.Trim() }
if ($laps.BackupDateTime) { $noteParts += "Graph backupDateTime: $($laps.BackupDateTime)" }
if ($laps.PasswordExpirationDateTime) { $noteParts += "Graph passwordExpirationDateTime: $($laps.PasswordExpirationDateTime)" }
$combinedNotes = ($noteParts -join "`n").Trim()
if (-not $combinedNotes) { $combinedNotes = $null }

$existing = Get-ITGluePasswordByName -BaseUri $ITGlueBaseUri -ApiKey $ITGlueApiKey -OrganizationId $ITGlueOrganizationId -Name $ITGluePasswordName

$target = if ($existing) { "IT Glue password '$ITGluePasswordName' (id: $($existing.id))" } else { "IT Glue password '$ITGluePasswordName' (new)" }
if ($PSCmdlet.ShouldProcess($target, "Upsert LAPS password")) {
  if ($existing) {
    $result = Set-ITGluePassword `
      -BaseUri $ITGlueBaseUri `
      -ApiKey $ITGlueApiKey `
      -PasswordId $existing.id `
      -OrganizationId $ITGlueOrganizationId `
      -Name $ITGluePasswordName `
      -Username $laps.AccountName `
      -Password $laps.Password `
      -Notes $combinedNotes `
      -PasswordCategoryId $ITGluePasswordCategoryId `
      -ResourceType $ITGlueResourceType `
      -ResourceId $ITGlueResourceId
  } else {
    $result = New-ITGluePassword `
      -BaseUri $ITGlueBaseUri `
      -ApiKey $ITGlueApiKey `
      -OrganizationId $ITGlueOrganizationId `
      -Name $ITGluePasswordName `
      -Username $laps.AccountName `
      -Password $laps.Password `
      -Notes $combinedNotes `
      -PasswordCategoryId $ITGluePasswordCategoryId `
      -ResourceType $ITGlueResourceType `
      -ResourceId $ITGlueResourceId
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
  ITGluePasswordName         = $ITGluePasswordName
  ITGluePasswordId           = $resultId
}
