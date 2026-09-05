[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Full', 'CodeOnly')]
    [string]$ArchiveMode = 'Full',
    [switch]$OverwriteRelease
)

$arguments = @{ ArchiveMode = $ArchiveMode; OverwriteRelease = $OverwriteRelease }
if (-not [string]::IsNullOrWhiteSpace($Version)) { $arguments.Version = $Version }
& (Join-Path $PSScriptRoot 'tools\release-all.ps1') @arguments
exit $(if ($?) { 0 } else { 1 })
