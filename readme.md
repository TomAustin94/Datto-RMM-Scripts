# Sync Entra LAPS to IT Glue

`scripts/Sync-EntraLapsToITGlue.ps1` retrieves a Windows LAPS password stored in Entra ID (Azure AD) via Microsoft Graph and upserts it into an IT Glue **Password** record.

## What it does

- Looks up an Entra device by `displayName` (`-DeviceName`)
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

You (or an admin) may need to grant consent depending on your tenant policies.

### IT Glue

- IT Glue API key with write access to Passwords
- Your IT Glue Organization ID (`-ITGlueOrganizationId`)

## Usage

Basic sync (creates the IT Glue Password record if it doesn’t exist):

```powershell
.\scripts\Sync-EntraLapsToITGlue.ps1 `
  -DeviceName "PC-001" `
  -ITGlueApiKey $env:ITGLUE_API_KEY `
  -ITGlueOrganizationId 123456
```

Preview changes without writing to IT Glue:

```powershell
.\scripts\Sync-EntraLapsToITGlue.ps1 `
  -DeviceName "PC-001" `
  -ITGlueApiKey $env:ITGLUE_API_KEY `
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

- `-DeviceName` (required): Entra device `displayName` (must be unique).
- `-LocalAdminAccountName`: Which credential to select (default: `Administrator`).
- `-ITGlueApiKey` (required): IT Glue API key (sent in the `x-api-key` header).
- `-ITGlueOrganizationId` (required): IT Glue organization that owns the Password record.
- `-ITGluePasswordName`: Password record name to upsert (default: `"<DeviceName> - LAPS"`).
- `-ITGlueBaseUri`: IT Glue API base URL (default: `https://api.itglue.com`).
- `-ITGluePasswordCategoryId`: Optional password category ID to set on create/update.
- `-ITGlueResourceType` / `-ITGlueResourceId`: Optional association (commonly `Configurations` + configuration ID).
- `-ITGlueNotes`: Optional additional notes; Graph timestamps are appended when available.
- `-TenantId`: Optional tenant ID to use when connecting to Graph.

## Output

The script returns an object including:

- `DeviceName`, `DeviceId`, `AccountName`, `PasswordExpirationDateTime`
- `ITGlueOrganizationId`, `ITGluePasswordName`, `ITGluePasswordId`

## Notes / limitations

- Uses a Microsoft Graph **beta** endpoint (`/beta/deviceLocalCredentials/...`), which may change.
- The device lookup is by exact `displayName`. If multiple devices share the same name, the script stops and asks for a unique name.
- IT Glue upsert is done by searching Passwords by **name** within the given organization (first match is used).

## Security recommendations

- Do not hardcode API keys in scripts. Prefer environment variables or a secret manager.
- Consider restricting who can run this, since it retrieves and stores privileged local admin credentials.
- Use `-WhatIf` when validating behavior in a new tenant or IT Glue org.
