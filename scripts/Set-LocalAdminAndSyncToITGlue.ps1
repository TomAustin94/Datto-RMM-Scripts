<#
.SYNOPSIS
Create/update a local admin on a Windows PC and upsert the credentials into IT Glue.

.DESCRIPTION
Intended for Datto RMM components. The script:
  1) Ensures a local user exists and is in the local Administrators group
  2) Sets the user password (from parameter or environment variable)
  3) Finds the IT Glue Configuration item by serial number
  4) Creates or updates an IT Glue Password record and associates it to the Configuration

Upsert behavior:
  - The IT Glue Password record is matched by name within the resolved organization.
  - If found, the record is updated; otherwise it is created.

.PARAMETER LocalAdminUsername
Local account name to create/update. Default: "RMMAdmin".

.PARAMETER LocalAdminPassword
Password to set. If omitted, the script will try environment variables:
  - LOCAL_ADMIN_PASSWORD
  - DATTO_LOCAL_ADMIN_PASSWORD

.PARAMETER SerialNumber
Optional override for the device serial number. If omitted, uses Win32_BIOS.SerialNumber.

.PARAMETER ITGlueApiKey
IT Glue API key. If omitted, uses environment variable ITGLUE_API_KEY (also tries ITGlueApiKey / IT_GLUE_API_KEY).

.PARAMETER ITGlueBaseUri
IT Glue API base URI. Default: https://api.itglue.com

.PARAMETER ITGluePasswordName
Optional explicit IT Glue Password record name to upsert. If not provided, -ITGluePasswordNameTemplate is used.

.PARAMETER ITGluePasswordNameTemplate
Template for the IT Glue Password name. Tokens: {ComputerName}, {LocalAdminUsername}, {SerialNumber}.
Default: "{ComputerName} - {LocalAdminUsername} (Local Admin)".

.PARAMETER ITGluePasswordCategoryId
Optional IT Glue password category ID to set on create/update.

.PARAMETER ITGlueNotes
Optional additional notes. The script appends serial/config information.

.PARAMETER RequireConfigurationMatch
If set, the script stops if it cannot uniquely match an IT Glue Configuration by serial number.

.EXAMPLE
.\scripts\Set-LocalAdminAndSyncToITGlue.ps1 -LocalAdminUsername "RMMAdmin" -LocalAdminPassword $env:LOCAL_ADMIN_PASSWORD
#>

[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $LocalAdminUsername = "RMMAdmin",

  [Parameter()]
  [string] $LocalAdminPassword,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $SerialNumber,

  [Parameter()]
  [string] $ITGlueApiKey,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGlueBaseUri = "https://api.itglue.com",

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGluePasswordName,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string] $ITGluePasswordNameTemplate = "{ComputerName} - {LocalAdminUsername} (Local Admin)",

  [Parameter()]
  [ValidateRange(1, 2147483647)]
  [int] $ITGluePasswordCategoryId,

  [Parameter()]
  [string] $ITGlueNotes,

  [Parameter()]
  [switch] $RequireConfigurationMatch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
  $current = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($current)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-ITGlueApiKey {
  param([Parameter()][string] $ExplicitApiKey)
  if ($ExplicitApiKey) { return $ExplicitApiKey }
  $key = $env:ITGLUE_API_KEY
  if (-not $key) { $key = $env:ITGlueApiKey }
  if (-not $key) { $key = $env:IT_GLUE_API_KEY }
  return $key
}

function Resolve-LocalAdminPassword {
  param([Parameter()][string] $ExplicitPassword)
  if ($ExplicitPassword) { return $ExplicitPassword }
  $pw = $env:LOCAL_ADMIN_PASSWORD
  if (-not $pw) { $pw = $env:DATTO_LOCAL_ADMIN_PASSWORD }
  return $pw
}

function Get-DeviceSerialNumber {
  $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
  $sn = [string]$bios.SerialNumber
  if ($sn) { return $sn.Trim() }
  return $null
}

function Resolve-ITGluePasswordName {
  param(
    [Parameter()][string] $ExplicitName,
    [Parameter(Mandatory = $true)][string] $Template,
    [Parameter(Mandatory = $true)][string] $ComputerName,
    [Parameter(Mandatory = $true)][string] $LocalAdminUsername,
    [Parameter()][string] $SerialNumber
  )

  if ($ExplicitName) { return $ExplicitName }

  $name = $Template
  $name = $name.Replace("{ComputerName}", $ComputerName)
  $name = $name.Replace("{LocalAdminUsername}", $LocalAdminUsername)
  $name = $name.Replace("{SerialNumber}", $SerialNumber)
  return $name
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
    "x-api-key"    = $ApiKey
    "Accept"       = "application/vnd.api+json"
    "Content-Type" = "application/vnd.api+json"
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
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        try { $retryAfter = $_.Exception.Response.Headers["Retry-After"] } catch { }
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
        if ($retryAfter) { [int]::TryParse(($retryAfter | Select-Object -First 1), [ref]$sleepSeconds) | Out-Null }
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

function Get-ITGlueConfigurationBySerialNumberAnyOrg {
  param(
    [Parameter(Mandatory = $true)][string] $BaseUri,
    [Parameter(Mandatory = $true)][string] $ApiKey,
    [Parameter(Mandatory = $true)][string] $SerialNumber
  )

  $encodedSerial = [System.Net.WebUtility]::UrlEncode($SerialNumber.Trim())
  $path = "configurations?filter[serial_number]=$encodedSerial&page[size]=2"
  $result = Invoke-ITGlueRequest -Method GET -BaseUri $BaseUri -ApiKey $ApiKey -Path $path

  if (-not $result.data) { return $null }
  if ($result.data.Count -eq 1) { return $result.data[0] }
  if ($result.data.Count -gt 1) { throw "Multiple IT Glue Configurations matched serial number '$SerialNumber'. Narrow your search or ensure serials are unique." }
  return $null
}

function Get-ITGlueOrganizationIdFromConfiguration {
  param([Parameter(Mandatory = $true)][object] $Configuration)

  $attrs = $Configuration.attributes
  if (-not $attrs) { return $null }

  if ($attrs.organization_id) { return [int]$attrs.organization_id }
  if ($attrs.'organization-id') { return [int]$attrs.'organization-id' }

  try {
    if ($Configuration.relationships -and $Configuration.relationships.organization -and $Configuration.relationships.organization.data.id) {
      return [int]$Configuration.relationships.organization.data.id
    }
  } catch { }

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

function Get-ITGluePasswordForConfigurationAndUsername {
  param(
    [Parameter(Mandatory = $true)][string] $BaseUri,
    [Parameter(Mandatory = $true)][string] $ApiKey,
    [Parameter(Mandatory = $true)][int] $OrganizationId,
    [Parameter(Mandatory = $true)][int] $ConfigurationId,
    [Parameter(Mandatory = $true)][string] $Username
  )

  $encodedUsername = [System.Net.WebUtility]::UrlEncode($Username)
  $path = "passwords?filter[organization_id]=$OrganizationId&filter[resource_type]=Configurations&filter[resource_id]=$ConfigurationId&filter[username]=$encodedUsername&page[size]=2"

  try {
    $result = Invoke-ITGlueRequest -Method GET -BaseUri $BaseUri -ApiKey $ApiKey -Path $path
    if ($result.data -and $result.data.Count -ge 1) {
      if ($result.data.Count -gt 1) {
        throw "Multiple IT Glue Passwords matched org $OrganizationId configuration $ConfigurationId username '$Username'. Use a unique naming convention or clean up duplicates."
      }
      return $result.data[0]
    }
  } catch {
    # Some IT Glue tenants may not support all password filters; treat as best-effort.
    Write-Verbose "Unable to filter IT Glue Passwords by resource/username. Falling back to name-only matching. Error: $($_.Exception.Message)"
  }

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
    name            = $Name
    username        = $Username
    password        = $Password
    organization_id = $OrganizationId
  }

  if ($Notes) { $attributes.notes = $Notes }
  if ($PasswordCategoryId) { $attributes.password_category_id = $PasswordCategoryId }
  if ($ResourceType) { $attributes.resource_type = $ResourceType }
  if ($ResourceId) { $attributes.resource_id = $ResourceId }

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
    name            = $Name
    username        = $Username
    password        = $Password
    organization_id = $OrganizationId
  }

  if ($Notes) { $attributes.notes = $Notes }
  if ($PasswordCategoryId) { $attributes.password_category_id = $PasswordCategoryId }
  if ($ResourceType) { $attributes.resource_type = $ResourceType }
  if ($ResourceId) { $attributes.resource_id = $ResourceId }

  $body = @{
    data = @{
      id         = [string]$PasswordId
      type       = "passwords"
      attributes = $attributes
    }
  }

  return Invoke-ITGlueRequest -Method PATCH -BaseUri $BaseUri -ApiKey $ApiKey -Path "passwords/$PasswordId" -Body $body
}

function Ensure-LocalAdminUser {
  param(
    [Parameter(Mandatory = $true)][string] $Username,
    [Parameter(Mandatory = $true)][string] $Password
  )

  $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force

  $hasLocalAccounts = $false
  try { $null = Get-Command Get-LocalUser -ErrorAction Stop; $hasLocalAccounts = $true } catch { }

  if ($hasLocalAccounts) {
    $existing = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $existing) {
      New-LocalUser -Name $Username -Password $securePassword -PasswordNeverExpires:$true -AccountNeverExpires:$true | Out-Null
    } else {
      Set-LocalUser -Name $Username -Password $securePassword -PasswordNeverExpires:$true -AccountNeverExpires:$true | Out-Null
      if ($existing.Enabled -eq $false) { Enable-LocalUser -Name $Username | Out-Null }
      try {
        if (Get-Command Unlock-LocalUser -ErrorAction SilentlyContinue) {
          Unlock-LocalUser -Name $Username -ErrorAction SilentlyContinue | Out-Null
        }
      } catch { }
    }

    try {
      Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction Stop | Out-Null
    } catch {
      # Ignore if already a member
    }
    return
  }

  & net.exe user $Username *> $null
  if ($LASTEXITCODE -eq 0) {
    & net.exe user $Username $Password /active:yes /expires:never | Out-Null
  } else {
    & net.exe user $Username $Password /add /y /active:yes /expires:never | Out-Null
  }

  & net.exe localgroup Administrators $Username /add *> $null
}

$apiKey = Resolve-ITGlueApiKey -ExplicitApiKey $ITGlueApiKey
if (-not $apiKey) { throw "IT Glue API key not provided. Set ITGLUE_API_KEY or pass -ITGlueApiKey." }

$adminPassword = Resolve-LocalAdminPassword -ExplicitPassword $LocalAdminPassword
if (-not $adminPassword) {
  throw "Local admin password not provided. Pass -LocalAdminPassword or set LOCAL_ADMIN_PASSWORD."
}

$isAdmin = $false
try { $isAdmin = Test-IsAdministrator } catch { }
if (-not $isAdmin) { throw "This script must be run elevated (Administrator) to manage local users/groups." }

$computerName = $env:COMPUTERNAME
if (-not $computerName) { $computerName = [System.Environment]::MachineName }

$sn = $SerialNumber
if (-not $sn) { $sn = Get-DeviceSerialNumber }
if (-not $sn) { throw "Unable to determine device serial number. Pass -SerialNumber." }

Ensure-LocalAdminUser -Username $LocalAdminUsername -Password $adminPassword

$config = $null
try {
  $config = Get-ITGlueConfigurationBySerialNumberAnyOrg -BaseUri $ITGlueBaseUri -ApiKey $apiKey -SerialNumber $sn
} catch {
  if ($RequireConfigurationMatch) { throw }
  Write-Warning "Unable to uniquely match IT Glue Configuration by serial number '$sn'. Skipping IT Glue sync. Error: $($_.Exception.Message)"
}

if (-not $config) {
  if ($RequireConfigurationMatch) { throw "No IT Glue Configuration found with serial number '$sn'." }
  [PSCustomObject]@{
    ComputerName       = $computerName
    SerialNumber       = $sn
    LocalAdminUsername = $LocalAdminUsername
    ITGlueSynced       = $false
  }
  return
}

$orgId = Get-ITGlueOrganizationIdFromConfiguration -Configuration $config
if (-not $orgId) {
  if ($RequireConfigurationMatch) { throw "Matched IT Glue Configuration '$($config.id)' but could not determine its organization id." }
  Write-Warning "Matched IT Glue Configuration '$($config.id)' but could not determine its organization id. Skipping IT Glue sync."
  [PSCustomObject]@{
    ComputerName         = $computerName
    SerialNumber         = $sn
    LocalAdminUsername   = $LocalAdminUsername
    ITGlueConfigurationId = $config.id
    ITGlueSynced         = $false
  }
  return
}

$passwordName = Resolve-ITGluePasswordName -ExplicitName $ITGluePasswordName -Template $ITGluePasswordNameTemplate -ComputerName $computerName -LocalAdminUsername $LocalAdminUsername -SerialNumber $sn

$noteParts = @()
if ($ITGlueNotes) { $noteParts += $ITGlueNotes.Trim() }
$noteParts += "SerialNumber: $sn"
$noteParts += "ConfigurationId: $($config.id)"
$combinedNotes = ($noteParts -join "`n").Trim()
if (-not $combinedNotes) { $combinedNotes = $null }

$existing = Get-ITGluePasswordByName -BaseUri $ITGlueBaseUri -ApiKey $apiKey -OrganizationId $orgId -Name $passwordName
if (-not $existing) {
  $existing = Get-ITGluePasswordForConfigurationAndUsername `
    -BaseUri $ITGlueBaseUri `
    -ApiKey $apiKey `
    -OrganizationId $orgId `
    -ConfigurationId ([int]$config.id) `
    -Username $LocalAdminUsername
}
$target = if ($existing) { "IT Glue password '$passwordName' (id: $($existing.id))" } else { "IT Glue password '$passwordName' (new)" }

$result = $null
if ($PSCmdlet.ShouldProcess($target, "Upsert local admin password")) {
  if ($existing) {
    $result = Set-ITGluePassword `
      -BaseUri $ITGlueBaseUri `
      -ApiKey $apiKey `
      -PasswordId $existing.id `
      -OrganizationId $orgId `
      -Name $passwordName `
      -Username $LocalAdminUsername `
      -Password $adminPassword `
      -Notes $combinedNotes `
      -PasswordCategoryId $ITGluePasswordCategoryId `
      -ResourceType "Configurations" `
      -ResourceId ([int]$config.id)
  } else {
    $result = New-ITGluePassword `
      -BaseUri $ITGlueBaseUri `
      -ApiKey $apiKey `
      -OrganizationId $orgId `
      -Name $passwordName `
      -Username $LocalAdminUsername `
      -Password $adminPassword `
      -Notes $combinedNotes `
      -PasswordCategoryId $ITGluePasswordCategoryId `
      -ResourceType "Configurations" `
      -ResourceId ([int]$config.id)
  }
}

$resultId = $null
if ($existing) {
  $resultId = $existing.id
} elseif ($result -and $result.data -and $result.data.id) {
  $resultId = $result.data.id
}

[PSCustomObject]@{
  ComputerName          = $computerName
  SerialNumber          = $sn
  LocalAdminUsername    = $LocalAdminUsername
  ITGlueOrganizationId  = $orgId
  ITGlueConfigurationId = $config.id
  ITGluePasswordName    = $passwordName
  ITGluePasswordId      = $resultId
  ITGlueSynced          = $true
}
