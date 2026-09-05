[CmdletBinding()]
param(
    [ValidateSet('all', 'windows-full', 'macos', 'windows-lite')]
    [string]$Target = 'all',
    [ValidateRange(1, 30)]
    [int]$DebounceSeconds = 2
)

. (Join-Path $PSScriptRoot 'common.ps1')
$sourcePath = Resolve-SourcePath 'src'
$watcher = [IO.FileSystemWatcher]::new($sourcePath)
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
$watcher.EnableRaisingEvents = $true
Write-Host "Watching canonical source: $sourcePath"
Write-Host 'Press Ctrl+C to stop.'

try {
    while ($true) {
        $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All)
        if ($change.TimedOut) { continue }
        Start-Sleep -Seconds $DebounceSeconds
        while ($watcher.WaitForChanged([IO.WatcherChangeTypes]::All, 100).TimedOut -eq $false) { }
        Write-Host "Change detected: $($change.ChangeType) $($change.Name)"
        & (Join-Path $PSScriptRoot 'build-all.ps1') -Target $Target
        if ($LASTEXITCODE -ne 0) { Write-Host 'Sync or verification failed; inspect the report.' -ForegroundColor Red }
    }
} finally {
    $watcher.Dispose()
}
