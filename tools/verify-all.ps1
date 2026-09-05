[CmdletBinding()]
param(
    [ValidateSet('all', 'windows-full', 'macos', 'windows-lite')]
    [string]$Target = 'all',
    [switch]$NoReport
)

. (Join-Path $PSScriptRoot 'common.ps1')
$manifest = Get-ReleaseManifest
$targetNames = @(Get-TargetNames -Target $Target)
$checks = New-Object System.Collections.Generic.List[object]
Write-TerminalProgress -Activity 'Verifying Marker OCR editions' -Percent 0 -Status 'Checking shared files'

function Add-Check {
    param([string]$TargetName, [string]$Kind, [string]$Path, [bool]$Ok, [string]$Message)
    $checks.Add([ordered]@{ target=$TargetName; kind=$Kind; path=$Path; ok=$Ok; message=$Message })
}

foreach ($shared in $manifest.shared_files) {
    $sourcePath = Resolve-SourcePath $shared.source
    $sourceExists = Test-Path -LiteralPath $sourcePath -PathType Leaf
    Add-Check 'shared' 'source' $sourcePath $sourceExists $(if ($sourceExists) { 'present' } else { 'missing' })
    if (-not $sourceExists) { continue }
    $sourceHash = Get-Sha256 $sourcePath
    foreach ($destination in $shared.destinations.PSObject.Properties) {
        if ($targetNames -notcontains $destination.Name) { continue }
        $destinationPath = Resolve-PackagePath -TargetConfig $manifest.targets.($destination.Name) -RelativePath $destination.Value
        $ok = (Test-Path -LiteralPath $destinationPath -PathType Leaf) -and ((Get-Sha256 $destinationPath) -eq $sourceHash)
        Add-Check $destination.Name 'shared-sync' $destinationPath $ok $(if ($ok) { 'hash matches canonical source' } else { 'missing or drifted' })
    }
}
Write-TerminalProgress -Activity 'Verifying Marker OCR editions' -Percent 15 -Status 'Shared files checked'

$sourceCodeFiles = New-Object System.Collections.Generic.List[string]
foreach ($shared in $manifest.shared_files) { $sourceCodeFiles.Add((Resolve-SourcePath $shared.source)) }
$sourceCodeFiles.Add((Resolve-SourcePath 'release-manifest.json'))
foreach ($toolFile in Get-ChildItem -LiteralPath (Resolve-SourcePath 'tools') -File) {
    if ($toolFile.Extension.ToLowerInvariant() -in @('.ps1', '.py', '.json')) { $sourceCodeFiles.Add($toolFile.FullName) }
}
foreach ($rootScript in Get-ChildItem -LiteralPath (Get-SourceRoot) -File -Filter '*.ps1') { $sourceCodeFiles.Add($rootScript.FullName) }
foreach ($appFile in Get-ChildItem -LiteralPath (Resolve-SourcePath 'app') -Recurse -File) {
    if ($appFile.Extension.ToLowerInvariant() -in @('.py', '.json')) { $sourceCodeFiles.Add($appFile.FullName) }
}

foreach ($targetName in $targetNames) {
    $targetConfig = $manifest.targets.$targetName
    $packageRoot = Resolve-PackagePath -TargetConfig $targetConfig
    Add-Check $targetName 'package-root' $packageRoot (Test-Path -LiteralPath $packageRoot -PathType Container) 'package directory'

    foreach ($relative in $targetConfig.files) {
        $sourcePath = Resolve-SourcePath (("{0}/{1}" -f $targetConfig.source_dir, $relative) -replace '\\', '/')
        $destinationPath = Resolve-PackagePath -TargetConfig $targetConfig -RelativePath $relative
        $sourceCodeFiles.Add($sourcePath)
        $ok = (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and (Test-Path -LiteralPath $destinationPath -PathType Leaf)
        if ($ok) { $ok = (Get-Sha256 $sourcePath) -eq (Get-Sha256 $destinationPath) }
        Add-Check $targetName 'target-sync' $destinationPath $ok $(if ($ok) { 'hash matches canonical source' } else { 'missing or drifted' })
    }

    foreach ($relative in $targetConfig.required_assets) {
        $assetPath = Resolve-PackagePath -TargetConfig $targetConfig -RelativePath $relative
        $ok = Test-Path -LiteralPath $assetPath -PathType Leaf
        Add-Check $targetName 'required-asset' $assetPath $ok $(if ($ok) { 'present' } else { 'missing' })
    }

    $versionPath = Join-Path $packageRoot 'VERSION'
    $versionOk = (Test-Path -LiteralPath $versionPath -PathType Leaf) -and ((Get-Content -Raw -LiteralPath $versionPath).Trim() -eq [string]$manifest.release_version)
    Add-Check $targetName 'version' $versionPath $versionOk $(if ($versionOk) { [string]$manifest.release_version } else { 'missing or mismatched' })

    $metadataPath = Join-Path $packageRoot 'release-metadata.json'
    $metadataOk = $false
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = Get-Content -Raw -LiteralPath $metadataPath -Encoding UTF8 | ConvertFrom-Json
            $metadataOk = ([string]$metadata.version -eq [string]$manifest.release_version) -and ([string]$metadata.package -eq $targetName)
        } catch { $metadataOk = $false }
    }
    Add-Check $targetName 'metadata' $metadataPath $metadataOk $(if ($metadataOk) { 'valid' } else { 'missing or invalid' })
    $targetIndex = [Array]::IndexOf([object[]]$targetNames, $targetName) + 1
    Write-TerminalProgress -Activity 'Verifying Marker OCR editions' -Percent (15 + (45 * $targetIndex / $targetNames.Count)) -Status "$targetName package and assets checked"
}

$uniqueSourceFiles = @($sourceCodeFiles | Sort-Object -Unique)
$sourceIndex = 0
foreach ($path in $uniqueSourceFiles) {
    $sourceIndex++
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        Add-Check 'source' 'powershell-parse' $path ($errors.Count -eq 0) $(if ($errors.Count -eq 0) { 'valid' } else { ($errors.Message -join '; ') })
    } elseif ($extension -eq '.json') {
        try { $null = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json; $ok = $true; $message = 'valid' } catch { $ok = $false; $message = $_.Exception.Message }
        Add-Check 'source' 'json-parse' $path $ok $message
    } elseif ($extension -eq '.py') {
        $pythonExe = Resolve-PackagePath -TargetConfig $manifest.targets.'windows-full' -RelativePath 'runtime/python/python.exe'
        $parseCode = 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), filename=sys.argv[1])'
        $parseOutput = & $pythonExe -c $parseCode $path 2>&1
        $ok = ($LASTEXITCODE -eq 0)
        Add-Check 'source' 'python-parse' $path $ok $(if ($ok) { 'valid' } else { ($parseOutput -join '; ') })
    } elseif ($extension -eq '.command') {
        $bytes = [IO.File]::ReadAllBytes($path)
        $hasCrLf = $false
        for ($i=0; $i -lt $bytes.Length-1; $i++) { if ($bytes[$i] -eq 13 -and $bytes[$i+1] -eq 10) { $hasCrLf = $true; break } }
        Add-Check 'macos' 'line-endings' $path (-not $hasCrLf) $(if ($hasCrLf) { 'CRLF found; macOS scripts require LF' } else { 'LF compatible' })
    }
    Write-TerminalProgress -Activity 'Verifying Marker OCR editions' -Percent (60 + (35 * $sourceIndex / [Math]::Max(1, $uniqueSourceFiles.Count))) -Status "Syntax: $([IO.Path]::GetFileName($path))"
}

$liteContractPath = Resolve-SourcePath 'platform/windows-lite/node-contract.json'
try {
    $liteContract = Get-Content -Raw -LiteralPath $liteContractPath -Encoding UTF8 | ConvertFrom-Json
    $contractOk = [string]$liteContract.version -eq [string]$manifest.release_version
} catch { $contractOk = $false }
Add-Check 'windows-lite' 'contract-version' $liteContractPath $contractOk $(if ($contractOk) { [string]$manifest.release_version } else { 'version mismatch' })

$failed = @($checks | Where-Object { -not $_.ok })
$report = [ordered]@{
    schema_version = '1.0'
    generated_at = (Get-Date).ToString('o')
    release_version = [string]$manifest.release_version
    targets = $targetNames
    status = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
    total_checks = $checks.Count
    failed_checks = $failed.Count
    checks = $checks
}

if (-not $NoReport) {
    $reportDir = Resolve-SourcePath 'reports'
    $reportPath = Join-Path $reportDir ("verification-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Utf8Json -Path $reportPath -Value $report -Depth 16
    Write-Host "Verification report: $reportPath"
}
Complete-TerminalProgress -Activity 'Verifying Marker OCR editions' -Status "$($report.status): checks=$($checks.Count) failed=$($failed.Count)"
Write-Host "Verification $($report.status): checks=$($checks.Count) failed=$($failed.Count) version=$($manifest.release_version)"
if ($failed.Count -gt 0) {
    $failed | Select-Object target,kind,path,message | Format-Table -AutoSize
    exit 1
}
