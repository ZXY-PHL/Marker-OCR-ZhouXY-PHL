[CmdletBinding()]
param([string]$Version)

$arguments = @{}
if (-not [string]::IsNullOrWhiteSpace($Version)) { $arguments.Version = $Version }
& (Join-Path $PSScriptRoot 'tools\build-all.ps1') @arguments
exit $(if ($?) { 0 } else { 1 })
