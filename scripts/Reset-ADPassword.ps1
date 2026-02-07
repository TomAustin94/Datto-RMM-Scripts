<#
.SYNOPSIS
Reset an Active Directory user password and unlock the account, except for Domain Admins.

.DESCRIPTION
Intended to run on a Domain Controller. Supplies the new password via parameters and skips any account that is a member of the Domain Admins group.
#>
param(
    [Parameter(Mandatory)]
    [string]$Username,

    [Parameter(Mandatory)]
    [string]$Password
)

Import-Module ActiveDirectory -ErrorAction Stop

try {
    $user = Get-ADUser -Identity $Username -Properties LockedOut -ErrorAction Stop
} catch {
    Write-Error "User '$Username' not found in Active Directory."
    exit 1
}

$groupMembership = Get-ADPrincipalGroupMembership -Identity $user -ErrorAction Stop

if ($groupMembership | Where-Object { $_.Name -eq 'Domain Admins' }) {
    Write-Error "Password reset is blocked for users in the Domain Admins group."
    exit 2
}

if ($groupMembership | Where-Object { $_.Name -eq 'Administrators' -and $_.DistinguishedName -like 'CN=Administrators,CN=Builtin,*' }) {
    Write-Error "Password reset is blocked for members of the built-in Administrators group."
    exit 3
}

$securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force

Set-ADAccountPassword -Identity $user -NewPassword $securePassword -Reset -ErrorAction Stop

if ($user.LockedOut) {
    Unlock-ADAccount -Identity $user -ErrorAction Stop
}

Write-Host "Password for '$Username' reset and account unlocked if required."
