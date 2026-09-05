[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet('all', 'windows-full', 'macos', 'windows-lite')]
    [string]$Target = 'all',
    [string]$Version
)

. (Join-Path $PSScriptRoot 'common.ps1')
$manifestPath = Resolve-SourcePath 'release-manifest.json'
$manifest = Get-ReleaseManifest

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    if ($Target -ne 'all') {
        throw 'Version is global. Use -Target all whenever -Version is supplied.'
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
        throw "Version must be semantic, for example 1.1.0: $Version"
    }
    $manifest.release_version = $Version
    $liteContractPath = Resolve-SourcePath 'platform/windows-lite/node-contract.json'
    $liteContract = Get-Content -Raw -LiteralPath $liteContractPath -Encoding UTF8 | ConvertFrom-Json
    $liteContract.version = $Version
    if ($PSCmdlet.ShouldProcess($liteContractPath, "set contract version to $Version")) {
        Write-Utf8Json -Path $liteContractPath -Value $liteContract
        Write-Utf8Json -Path $manifestPath -Value $manifest
    }
}

$versionToUse = [string]$manifest.release_version
$targetNames = @(Get-TargetNames -Target $Target)
$copied = 0
$unchanged = 0
$sharedWork = @($manifest.shared_files | ForEach-Object { $_.destinations.PSObject.Properties } | Where-Object { $targetNames -contains $_.Name }).Count
$targetWork = 0
foreach ($targetName in $targetNames) { $targetWork += @($manifest.targets.$targetName.files).Count + 1 }
$totalWork = [Math]::Max(1, $sharedWork + $targetWork)
$completedWork = 0
Write-TerminalProgress -Activity 'Synchronizing Marker OCR editions' -Percent 0 -Status "Preparing $($targetNames.Count) target(s)"

foreach ($shared in $manifest.shared_files) {
    $sourcePath = Resolve-SourcePath $shared.source
    foreach ($destination in $shared.destinations.PSObject.Properties) {
        if ($targetNames -notcontains $destination.Name) { continue }
        $targetConfig = $manifest.targets.($destination.Name)
        $destinationPath = Resolve-PackagePath -TargetConfig $targetConfig -RelativePath $destination.Value
        if ((Test-Path -LiteralPath $destinationPath -PathType Leaf) -and (Get-Sha256 $sourcePath) -eq (Get-Sha256 $destinationPath)) {
            $unchanged++
            $completedWork++
            Write-TerminalProgress -Activity 'Synchronizing Marker OCR editions' -Percent (100 * $completedWork / $totalWork) -Status "$($destination.Name): $($destination.Value) (unchanged)"
            continue
        }
        if ($PSCmdlet.ShouldProcess($destinationPath, "sync shared file from $sourcePath")) {
            Copy-AtomicFile -Source $sourcePath -Destination $destinationPath
        }
        $copied++
        $completedWork++
        Write-TerminalProgress -Activity 'Synchronizing Marker OCR editions' -Percent (100 * $completedWork / $totalWork) -Status "$($destination.Name): $($destination.Value)"
    }
}

foreach ($targetName in $targetNames) {
    $targetConfig = $manifest.targets.$targetName
    foreach ($relative in $targetConfig.files) {
        $sourceRelative = (("{0}/{1}" -f $targetConfig.source_dir, $relative) -replace '\\', '/')
        $sourcePath = Resolve-SourcePath $sourceRelative
        $destinationPath = Resolve-PackagePath -TargetConfig $targetConfig -RelativePath $relative
        if ((Test-Path -LiteralPath $destinationPath -PathType Leaf) -and (Get-Sha256 $sourcePath) -eq (Get-Sha256 $destinationPath)) {
            $unchanged++
            $completedWork++
            Write-TerminalProgress -Activity 'Synchronizing Marker OCR editions' -Percent (100 * $completedWork / $totalWork) -Status "$targetName`: $relative (unchanged)"
            continue
        }
        if ($PSCmdlet.ShouldProcess($destinationPath, "sync target file from $sourcePath")) {
            Copy-AtomicFile -Source $sourcePath -Destination $destinationPath
        }
        $copied++
        $completedWork++
        Write-TerminalProgress -Activity 'Synchronizing Marker OCR editions' -Percent (100 * $completedWork / $totalWork) -Status "$targetName`: $relative"
    }

    $packageRoot = Resolve-PackagePath -TargetConfig $targetConfig
    $versionPath = Join-Path $packageRoot 'VERSION'
    $metadataPath = Join-Path $packageRoot 'release-metadata.json'
    $sourceHashes = [ordered]@{}
    foreach ($relative in $targetConfig.files) {
        $sourcePath = Resolve-SourcePath (("{0}/{1}" -f $targetConfig.source_dir, $relative) -replace '\\', '/')
        $sourceHashes[$relative] = Get-Sha256 $sourcePath
    }
    foreach ($shared in $manifest.shared_files) {
        $destination = $shared.destinations.PSObject.Properties[$targetName]
        if ($null -ne $destination) { $sourceHashes[[string]$destination.Value] = Get-Sha256 (Resolve-SourcePath $shared.source) }
    }
    $metadata = [ordered]@{
        schema_version = '1.0'
        package = $targetName
        version = $versionToUse
        generated_at = (Get-Date).ToString('o')
        source_manifest = 'Marker-OCR-Source/release-manifest.json'
        source_hashes = $sourceHashes
    }
    if ($PSCmdlet.ShouldProcess($packageRoot, "write VERSION and release-metadata.json")) {
        Write-Utf8Text -Path $versionPath -Text ($versionToUse + [Environment]::NewLine)
        Write-Utf8Json -Path $metadataPath -Value $metadata
    }
    $completedWork++
    Write-TerminalProgress -Activity 'Synchronizing Marker OCR editions' -Percent (100 * $completedWork / $totalWork) -Status "$targetName`: version metadata"
}

Complete-TerminalProgress -Activity 'Synchronizing Marker OCR editions' -Status "version=$versionToUse copied=$copied unchanged=$unchanged"
Write-Host "Sync complete: version=$versionToUse targets=$($targetNames -join ',') copied=$copied unchanged=$unchanged"
