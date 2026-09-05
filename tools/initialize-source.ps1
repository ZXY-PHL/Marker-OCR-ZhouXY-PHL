[CmdletBinding()]
param([switch]$Force)

. (Join-Path $PSScriptRoot 'common.ps1')
$manifest = Get-ReleaseManifest
$root = Get-SourceRoot
$copied = 0
$skipped = 0

foreach ($shared in $manifest.shared_files) {
    $sourcePath = Resolve-SourcePath $shared.source
    if ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and -not $Force) {
        $skipped++
        continue
    }
    $firstDestination = $shared.destinations.PSObject.Properties | Select-Object -First 1
    $targetConfig = $manifest.targets.($firstDestination.Name)
    $packagePath = Resolve-PackagePath -TargetConfig $targetConfig -RelativePath $firstDestination.Value
    Copy-AtomicFile -Source $packagePath -Destination $sourcePath
    $copied++
}

foreach ($targetProperty in $manifest.targets.PSObject.Properties) {
    $targetName = $targetProperty.Name
    $target = $targetProperty.Value
    foreach ($relative in $target.files) {
        $sourcePath = Resolve-SourcePath (("{0}/{1}" -f $target.source_dir, $relative) -replace '\\', '/')
        if ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and -not $Force) {
            $skipped++
            continue
        }
        $packagePath = Resolve-PackagePath -TargetConfig $target -RelativePath $relative
        Copy-AtomicFile -Source $packagePath -Destination $sourcePath
        $copied++
    }
}

Write-Host "Canonical source initialized: copied=$copied skipped=$skipped root=$root"
