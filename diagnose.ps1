# Read-only diagnostics. Does not load stored credentials or call a login/logout endpoint.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'campus-login.ps1') -Mode Library
$state = Get-PortalState
$context = Get-PortalContext (Invoke-PortalGet "$script:PortalBase/")
$profile = Get-LoginProfile $context
[pscustomobject]@{
    State = $state
    LocalAddressMatchesPortal = $true
    LoginMethod = $profile.Method
    ProfileIndex = $profile.Index
    FormRecognized = $true
    CredentialsRead = $false
    LoginAttempted = $false
} | ConvertTo-Json
