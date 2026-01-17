# Datto RMM Automation Scripts

This repo is a small collection of PowerShell scripts written to automate common tasks for devices managed by **Datto RMM**, including syncing credentials into **IT Glue**.

## Scripts

### Sync Entra LAPS to IT Glue

`scripts/Sync-EntraLapsToITGlue.ps1` retrieves a Windows LAPS password stored in Entra ID (Azure AD) via Microsoft Graph and upserts it into an IT Glue **Password** record.

`scripts/Set-LocalAdminAndSyncToITGlue.ps1` creates/updates a local admin account on a Windows PC and upserts that credential into IT Glue, associating it to the device Configuration by serial number.

## What it does

- Looks up an Entra device by `displayName` (`-DeviceName`)
- Or enumerates all devices with LAPS (`-AllDevices`) for bulk sync
- Calls the Graph **beta** `deviceLocalCredentials` endpoint to retrieve LAPS credentials
- Selects the credential matching `-LocalAdminAccountName` (falls back to the first credential returned)
- Creates or updates an IT Glue Password record (matched by name) with:
  - `username`: the LAPS account name
  - `password`: the decoded LAPS password
  - `notes`: optional notes + Graph timestamps (backup/expiration) when available

## Requirements

### Microsoft Graph

- PowerShell 5.1+ or PowerShell 7+
- Microsoft Graph PowerShell SDK modules:
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Devices`

Install (CurrentUser):

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Permissions (scopes requested by the script):

- `DeviceLocalCredential.Read.All`
- `Device.Read.All`
- `DeviceManagementManagedDevices.Read.All` (only when auto-associating an IT Glue Configuration by serial number via Intune)

You (or an admin) may need to grant consent depending on your tenant policies.

### IT Glue

- IT Glue API key with write access to Passwords
- Your IT Glue Organization ID (`-ITGlueOrganizationId`)

## Usage

Basic sync (creates the IT Glue Password record if it doesn’t exist):

```powershell
.\scripts\Sync-EntraLapsToITGlue.ps1 `
  -DeviceName "PC-001" `
  -ITGlueOrganizationId 123456
```

Bulk sync all devices with LAPS enabled:

```powershell
.\scripts\Sync-EntraLapsToITGlue.ps1 `
  -AllDevices `
  -ITGlueOrganizationId 123456
```

If running from Datto RMM as a component, set an environment/component variable like `ITGLUE_API_KEY`
and omit `-ITGlueApiKey`.

Create/update a local admin on the endpoint and sync it to IT Glue (Datto RMM component-friendly):

```powershell
$env:LOCAL_ADMIN_PASSWORD = "<set via Datto RMM component variable>"
$env:ITGLUE_API_KEY = "<set via Datto RMM component variable>"

.\scripts\Set-LocalAdminAndSyncToITGlue.ps1 -LocalAdminUsername "RMMAdmin"
```

Preview changes without writing to IT Glue:

```powershell
.\scripts\Sync-EntraLapsToITGlue.ps1 `
  -DeviceName "PC-001" `
  -ITGlueOrganizationId 123456 `
  -WhatIf
```

Use a specific local admin account name and a custom IT Glue Password record name:

```powershell
.\scripts\Sync-EntraLapsToITGlue.ps1 `
  -DeviceName "PC-001" `
  -LocalAdminAccountName "LAPSAdmin" `
  -ITGlueApiKey (Get-Content .\itglue.key -Raw) `
  -ITGlueOrganizationId 123456 `
  -ITGluePasswordName "PC-001 / LAPS"
```

## Parameters

- `-DeviceName`: Entra device `displayName` (must be unique; required unless using `-AllDevices`).
- `-AllDevices`: Enumerate and sync all devices with LAPS credentials (bulk mode).
- `-LocalAdminAccountName`: Which credential to select (default: `Administrator`).
- `-ITGlueApiKey`: IT Glue API key (sent in the `x-api-key` header); if omitted, uses `ITGLUE_API_KEY` env var.
- `-ITGlueOrganizationId` (required): IT Glue organization that owns the Password record.
- `-ITGluePasswordName`: Password record name to upsert (single-device mode only; overrides template).
- `-ITGluePasswordNameTemplate`: Per-device password name template (default: `"{DeviceName} - LAPS"`).
- `-ITGlueBaseUri`: IT Glue API base URL (default: `https://api.itglue.com`).
- `-ITGluePasswordCategoryId`: Optional password category ID to set on create/update.
- `-ITGlueResourceType` / `-ITGlueResourceId`: Optional association (commonly `Configurations` + configuration ID).
- `-ConfigurationSerialNumber`: Optional serial number override used to find an IT Glue Configuration item.
- `-DisableConfigurationLookup`: Skip auto-association to an IT Glue Configuration item by serial number when `-ITGlueResourceId` is not provided.
- `-RequireConfigurationMatch`: Fail if the script cannot uniquely match an IT Glue Configuration by serial number.
- `-ITGlueNotes`: Optional additional notes; Graph timestamps are appended when available.
- `-TenantId`: Optional tenant ID to use when connecting to Graph.

## Output

The script returns an object including:

- `DeviceName`, `DeviceId`, `AccountName`, `PasswordExpirationDateTime`
- `ITGlueOrganizationId`, `ITGluePasswordName`, `ITGluePasswordId`
- `ITGlueResourceType`, `ITGlueResourceId` (resolved association, when available)

## Notes / limitations

- Uses a Microsoft Graph **beta** endpoint (`/beta/deviceLocalCredentials/...`), which may change.
- The device lookup is by exact `displayName`. If multiple devices share the same name, the script stops and asks for a unique name.
- IT Glue upsert is done by searching Passwords by **name** within the given organization (first match is used).
- If `-ITGlueResourceId` is not provided, the script attempts to associate the Password to an IT Glue **Configuration** by looking up the device serial number in Graph and matching `filter[serial_number]` in IT Glue.

## Local admin sync notes

- `scripts/Set-LocalAdminAndSyncToITGlue.ps1` resolves the endpoint serial number from `Win32_BIOS.SerialNumber` and finds the IT Glue Configuration via `filter[serial_number]`.
- The local admin password should be provided via a Datto RMM variable mapped to `LOCAL_ADMIN_PASSWORD` (or passed as `-LocalAdminPassword`).
- The IT Glue Password record is upserted; it prefers matching by name, and may also update an existing record associated with the same Configuration+username when supported by IT Glue filters.

## Security recommendations

- Do not hardcode API keys in scripts. Prefer environment variables or a secret manager.
- Consider restricting who can run this, since it retrieves and stores privileged local admin credentials.
- Use `-WhatIf` when validating behavior in a new tenant or IT Glue org.
