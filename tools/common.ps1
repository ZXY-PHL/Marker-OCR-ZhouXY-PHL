Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:ProgressMilestones = @{}

function Write-TerminalProgress {
    param(
        [Parameter(Mandatory=$true)][string]$Activity,
        [Parameter(Mandatory=$true)][double]$Percent,
        [string]$Status = '',
        [int]$Width = 32
    )
    $bounded = [Math]::Max(0, [Math]::Min(100, $Percent))
    $rounded = [int][Math]::Floor($bounded)
    $filled = [int][Math]::Floor($bounded * $Width / 100)
    $bar = ('#' * $filled) + ('-' * ($Width - $filled))
    $line = "[{0}] {1,3}%  {2}" -f $bar, $rounded, $Status
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $bounded

    if (-not [Console]::IsOutputRedirected) {
        $padding = [Math]::Max(0, 100 - $line.Length)
        Write-Host ("`r" + $line + (' ' * $padding)) -NoNewline
        if ($bounded -ge 100) { Write-Host '' }
    } else {
        $milestone = [int]([Math]::Floor($bounded / 10) * 10)
        $last = if ($script:ProgressMilestones.ContainsKey($Activity)) { [int]$script:ProgressMilestones[$Activity] } else { -10 }
        if ($milestone -gt $last -or $bounded -ge 100) {
            Write-Host ("[{0,3}%] {1}: {2}" -f $rounded, $Activity, $Status)
            $script:ProgressMilestones[$Activity] = $milestone
        }
    }
}

function Complete-TerminalProgress {
    param([Parameter(Mandatory=$true)][string]$Activity, [string]$Status = 'Complete')
    Write-TerminalProgress -Activity $Activity -Percent 100 -Status $Status
    Write-Progress -Activity $Activity -Completed
    $script:ProgressMilestones.Remove($Activity)
}

function Get-SourceRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-ReleaseManifest {
    $root = Get-SourceRoot
    $path = Join-Path $root 'release-manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release manifest not found: $path"
    }
    return Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-SourcePath {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    return [IO.Path]::GetFullPath((Join-Path (Get-SourceRoot) ($RelativePath -replace '/', '\')))
}

function Resolve-PackagePath {
    param(
        [Parameter(Mandatory=$true)]$TargetConfig,
        [string]$RelativePath
    )
    $root = Resolve-SourcePath $TargetConfig.package_dir
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $root }
    return [IO.Path]::GetFullPath((Join-Path $root ($RelativePath -replace '/', '\')))
}

function Get-TargetNames {
    param([string]$Target = 'all')
    $manifest = Get-ReleaseManifest
    if ($Target -eq 'all') { return @($manifest.targets.PSObject.Properties.Name) }
    if ($manifest.targets.PSObject.Properties.Name -notcontains $Target) {
        throw "Unknown target: $Target"
    }
    return @($Target)
}

function Copy-AtomicFile {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [switch]$WhatIf
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Source file not found: $Source"
    }
    if ($WhatIf) {
        Write-Host "WHATIF copy: $Source -> $Destination"
        return
    }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Destination + '.sync-tmp'
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
}

function Get-Sha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Value,
        [int]$Depth = 12
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $json = $Value | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Write-Utf8Text {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
