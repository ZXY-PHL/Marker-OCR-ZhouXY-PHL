[CmdletBinding()]
param(
    [ValidateSet('all', 'windows-full', 'macos', 'windows-lite')]
    [string]$Target = 'all',
    [string]$Version,
    [ValidateSet('Full', 'CodeOnly')]
    [string]$ArchiveMode = 'Full',
    [string]$ReleaseDirectory,
    [switch]$OverwriteRelease
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
Write-Host '[Release phase 1/2] Synchronizing and verifying packages...' -ForegroundColor Cyan
$buildArgs = @{ Target = $Target }
if (-not [string]::IsNullOrWhiteSpace($Version)) { $buildArgs.Version = $Version }
& (Join-Path $PSScriptRoot 'build-all.ps1') @buildArgs
if (-not $?) { exit 1 }

$manifest = Get-ReleaseManifest
$versionToUse = [string]$manifest.release_version
if ([string]::IsNullOrWhiteSpace($ReleaseDirectory)) {
    $modeDirectory = if ($ArchiveMode -eq 'Full') { 'full' } else { 'code-only' }
    $ReleaseDirectory = Resolve-SourcePath ("releases/{0}/{1}" -f $versionToUse, $modeDirectory)
} else {
    $ReleaseDirectory = [IO.Path]::GetFullPath($ReleaseDirectory)
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCommand) {
    $python = $pythonCommand.Source
} else {
    $python = Resolve-SourcePath '../Marker-OCR-Portable/runtime/python/python.exe'
}
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Python is required to create release archives.' }

$archiveArgs = @(
    (Join-Path $PSScriptRoot 'archive_release.py'),
    '--source-root', (Get-SourceRoot),
    '--release-dir', $ReleaseDirectory,
    '--mode', $(if ($ArchiveMode -eq 'Full') { 'full' } else { 'code-only' })
)
foreach ($targetName in (Get-TargetNames -Target $Target)) { $archiveArgs += @('--target', $targetName) }
if ($OverwriteRelease) { $archiveArgs += '--overwrite' }

Write-Host '[Release phase 2/2] Creating archives and SHA256 files...' -ForegroundColor Cyan
& $python @archiveArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Release complete: version=$versionToUse mode=$ArchiveMode path=$ReleaseDirectory"
