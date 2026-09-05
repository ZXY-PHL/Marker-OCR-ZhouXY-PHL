[CmdletBinding()]
param(
    [ValidateSet('all', 'windows-full', 'macos', 'windows-lite')]
    [string]$Target = 'all',
    [string]$Version,
    [switch]$SkipSync
)

$ErrorActionPreference = 'Stop'
if (-not $SkipSync) {
    Write-Host '[Phase 1/2] Synchronizing all selected editions...' -ForegroundColor Cyan
    $syncArgs = @{ Target = $Target }
    if (-not [string]::IsNullOrWhiteSpace($Version)) { $syncArgs.Version = $Version }
    & (Join-Path $PSScriptRoot 'sync-all.ps1') @syncArgs
    if (-not $?) { exit 1 }
}
Write-Host '[Phase 2/2] Verifying synchronized editions...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'verify-all.ps1') -Target $Target
if (-not $?) { exit 1 }
exit 0
