[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PdfPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputRoot,

    [string]$OutputName = 'output.md',
    [int]$ChunkSize = 16,
    [string]$Mode = 'fast',
    [int]$OcrWorkers = 4,
    [int]$OcrCtxSize = 49152,
    [string]$BaseDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function _normalize_dragged_path {
    param([string]$PathValue)

    $value = $PathValue.Trim()
    if ($value.Length -ge 2 -and (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))
    )) {
        return $value.Substring(1, $value.Length - 2)
    }
    return $value
}

$PdfPath = _normalize_dragged_path $PdfPath
$OutputRoot = _normalize_dragged_path $OutputRoot
$BaseDir = _normalize_dragged_path $BaseDir
$pipelineScript = Join-Path $BaseDir 'pipeline.ps1'
if (-not (Test-Path -LiteralPath $pipelineScript -PathType Leaf)) {
    throw "Pipeline script not found: $pipelineScript"
}

Write-Host 'Resume mode: existing non-empty *_en.md checkpoints will be preserved; -Overwrite is disabled.' -ForegroundColor Green

$maxRounds = 100
$round = 0
$allChunksComplete = $false

do {
    $round++
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "`n[$ts] === ROUND $round ===" -ForegroundColor Cyan

    # Invoke the child PowerShell with an argument array so paths containing
    # spaces or Chinese characters remain distinct arguments.  Intentionally
    # do not pass -Overwrite: existing non-empty *_en.md files are checkpoints
    # and pipeline_power_from_cold.ps1 will skip them on every retry.
    $pipelineArgs = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $pipelineScript
        '-PdfPath', $PdfPath
        '-OutputRoot', $OutputRoot
        '-OutputName', $OutputName
        '-ChunkSize', $ChunkSize
        '-Mode', $Mode
        '-OcrWorkers', $OcrWorkers
        '-OcrCtxSize', $OcrCtxSize
        '-BaseDir', $BaseDir
    )

    # ProcessStartInfo.ArgumentList preserves argument boundaries without
    # relying on Windows command-line quoting performed by Start-Process.
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $bundledPwsh = Join-Path $BaseDir 'runtime\pwsh\pwsh.exe'
    if (-not (Test-Path -LiteralPath $bundledPwsh -PathType Leaf)) {
        throw "Bundled PowerShell not found: $bundledPwsh"
    }
    $startInfo.FileName = $bundledPwsh
    $startInfo.UseShellExecute = $false
    foreach ($argument in $pipelineArgs) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $pipelineProcess = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $pipelineProcess.WaitForExit()
        $pipelineExitCode = $pipelineProcess.ExitCode
    } finally {
        $pipelineProcess.Dispose()
    }

    Write-Host "[$ts] Pipeline exited with code: $pipelineExitCode" -ForegroundColor DarkGray

    # Count completed chunks
    $chunksDir = Join-Path $OutputRoot 'chunks'
    if (-not (Test-Path -LiteralPath $chunksDir -PathType Container)) {
        throw "Pipeline exited with code $pipelineExitCode without creating the chunks directory: $chunksDir"
    }

    $pageCount = 0
    try {
        $pythonExe = Join-Path $BaseDir 'runtime\python\python.exe'
        $result = & $pythonExe -c "from pypdfium2 import PdfDocument; d=PdfDocument(r'$PdfPath'); print(len(d)); d.close()" 2>$null
        $pageCount = [int]$result
    } catch {
        throw "Cannot determine page count: $_"
    }

    $totalChunks = [Math]::Ceiling($pageCount / $ChunkSize)
    $pdfStem = [IO.Path]::GetFileNameWithoutExtension($PdfPath)
    $completed = 0
    for ($start = 0; $start -lt $pageCount; $start += $ChunkSize) {
        $end = [Math]::Min($start + $ChunkSize - 1, $pageCount - 1)
        $label = 'chunk_{0:D3}_{1:D3}' -f $start, $end
        $md = Join-Path $chunksDir $label "$pdfStem\$($pdfStem)_en.md"
        if ((Test-Path $md) -and (Get-Item $md).Length -gt 0) { $completed++ }
    }

    Write-Host "[$ts] Chunks: $completed / $totalChunks" -ForegroundColor Yellow

    if ($completed -ge $totalChunks) {
        Write-Host "`nAll $totalChunks chunks complete!" -ForegroundColor Green
        $allChunksComplete = $true
        break
    }

    if ($round -ge $maxRounds) {
        throw "Max rounds ($maxRounds) reached with only $completed/$totalChunks OCR chunks complete."
    }

    Start-Sleep -Seconds 3
} while ($true)

if (-not $allChunksComplete) {
    throw 'OCR loop ended before all chunks were verified.'
}

Write-Host "`nNow run post-processing:" -ForegroundColor Cyan
$bundledPwsh = Join-Path $BaseDir 'runtime\pwsh\pwsh.exe'
Write-Host "  & `"$bundledPwsh`" -NoProfile -File `"$pipelineScript`" -PdfPath `"$PdfPath`" -OutputRoot `"$OutputRoot`" -OutputName `"$OutputName`" -SkipChunking -BaseDir `"$BaseDir`"" -ForegroundColor White
