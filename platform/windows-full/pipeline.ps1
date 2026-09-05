[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PdfPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputRoot,

    [string]$OutputName = 'output.md',
    [int]$ChunkSize = 16,
    [switch]$SkipChunking,
    [switch]$Overwrite,
    [string]$Mode = 'fast',
    [int]$OcrWorkers = 4,
    [int]$OcrCtxSize = 49152,
    [ValidateRange(1, 600)]
    [int]$StableCheckSeconds = 20,
    [ValidateRange(0, 3600)]
    [int]$ExitGraceSeconds = 120,
    [ValidateRange(0, 1440)]
    [int]$NoProgressTimeoutMinutes = 0,
    [ValidateRange(1, 10485760)]
    [int]$MinimumMarkdownBytes = 128,

    [string]$BaseDir = $PSScriptRoot,
    [string]$LogFile = $null
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false   # 外部命令非零退出码不触发 Stop
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# ---------- helpers ----------
$_pipelineStart = Get-Date
$_stageTimes = @{}

function _log($msg, $level = 'INFO') {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$level] $msg"
    $color = switch ($level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'DONE' { 'Green' } default { 'White' } }
    # A long OCR run may outlive the terminal/Codex host that launched it.
    # Console output is best-effort; the durable file log remains authoritative.
    try { Write-Host $line -ForegroundColor $color -ErrorAction Stop } catch { }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function _banner($phase) {
    $bar = '─' * 60
    _log $bar
    _log "  ◆  $phase"
    _log $bar
}

function _elapsed {
    param([string]$Stage)
    $now = Get-Date
    $duration = $now - $_pipelineStart
    if ($Stage) { $_stageTimes[$Stage] = $now }
    return $duration.ToString('hh\:mm\:ss')
}

function _show_ocr_progress {
    param(
        [int]$CompletedChunks,
        [int]$TotalChunks,
        [string]$CurrentChunk,
        [int]$PageStart,
        [int]$PageEnd,
        [datetime]$StartedAt,
        [switch]$Completed
    )
    $percent = if ($TotalChunks -gt 0) {
        [Math]::Min(100, [Math]::Round(($CompletedChunks * 100.0) / $TotalChunks, 1))
    } else { 0 }
    $elapsed = ((Get-Date) - $StartedAt).ToString('hh\:mm\:ss')
    $status = if ($Completed) {
        "$CompletedChunks/$TotalChunks chunks complete | 100% | elapsed $elapsed"
    } else {
        "$CompletedChunks/$TotalChunks chunks complete | current $CurrentChunk (pages $PageStart-$PageEnd) | $percent% | elapsed $elapsed"
    }
    try {
        Write-Progress -Id 1 -Activity 'Marker OCR' -Status $status -PercentComplete ([int][Math]::Floor($percent)) -Completed:$Completed
    } catch { }
    return $status
}

function _map_pdrive {
    $script:mapDrive = $null
    foreach ($letter in @('P:', 'Q:', 'R:', 'S:', 'T:', 'U:', 'V:', 'W:', 'X:', 'Y:', 'Z:')) {
        if (-not (Test-Path "$letter\")) {
            $script:mapDrive = $letter
            break
        }
    }
    if (-not $script:mapDrive) {
        throw 'No free drive letter is available for the temporary ASCII path mapping.'
    }
    subst.exe $script:mapDrive $asciiRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $script:mapDrive drive to $asciiRoot"
    }
    $script:driveMapped = $true
    _log "$script:mapDrive → $asciiRoot"
}

function _unmap_pdrive {
    if ($script:driveMapped -and $script:mapDrive) {
        subst.exe $script:mapDrive /d 2>$null
        $script:driveMapped = $false
    }
}

function _map_output_drive {
    $script:outputMapDrive = $null
    foreach ($letter in @('P:', 'Q:', 'R:', 'S:', 'T:', 'U:', 'V:', 'W:', 'X:', 'Y:', 'Z:')) {
        if ($letter -ne $script:mapDrive -and -not (Test-Path "$letter\")) {
            $script:outputMapDrive = $letter
            break
        }
    }
    if (-not $script:outputMapDrive) {
        throw 'No free drive letter is available for the temporary output path mapping.'
    }
    subst.exe $script:outputMapDrive $OutputRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $script:outputMapDrive drive to $OutputRoot"
    }
    $script:outputDriveMapped = $true
    _log "$script:outputMapDrive -> $OutputRoot (short output path)"
}

function _unmap_output_drive {
    if ($script:outputDriveMapped -and $script:outputMapDrive) {
        subst.exe $script:outputMapDrive /d 2>$null
        $script:outputDriveMapped = $false
    }
}

function _stop_surya_runtime_services {
    $runtimeCache = $env:SURYA_RUNTIME_CACHE_DIR
    if (-not $runtimeCache -or -not (Test-Path -LiteralPath $runtimeCache -PathType Container)) {
        return
    }

    foreach ($sentinel in Get-ChildItem -LiteralPath $runtimeCache -Filter '*_server.json' -File -ErrorAction SilentlyContinue) {
        try {
            $state = Get-Content -LiteralPath $sentinel.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $servicePid = [int]$state.pid
            $service = Get-Process -Id $servicePid -ErrorAction SilentlyContinue
            if (-not $service) { continue }

            $servicePath = $service.Path
            $isBundledService = $servicePath -and (
                $servicePath.StartsWith($BaseDir, [StringComparison]::OrdinalIgnoreCase) -or
                ($script:mapDrive -and $servicePath.StartsWith($script:mapDrive, [StringComparison]::OrdinalIgnoreCase))
            ) -and $service.ProcessName -in @('python', 'llama-server')

            if ($isBundledService) {
                _stop_process_tree $servicePid
                if (Get-Process -Id $servicePid -ErrorAction SilentlyContinue) {
                    Stop-Process -Id $servicePid -Force -ErrorAction SilentlyContinue
                }
                $stopDeadline = (Get-Date).AddSeconds(5)
                while ((Get-Process -Id $servicePid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $stopDeadline) {
                    Start-Sleep -Milliseconds 200
                }
                if (Get-Process -Id $servicePid -ErrorAction SilentlyContinue) {
                    _log "Portable Surya service $($state.backend) did not exit within 5s (pid=$servicePid)" 'WARN'
                } else {
                    _log "Stopped portable Surya service $($state.backend) (pid=$servicePid)"
                }
            } else {
                _log "Refusing to stop service pid=$servicePid because it is not a bundled Python/llama-server process" 'WARN'
            }
        } catch {
            _log "Could not inspect Surya service sentinel $($sentinel.FullName): $_" 'WARN'
        }
    }
}

function _write_chunk_status {
    param(
        [string]$Chunk,
        [string]$Status,
        [long]$Bytes = 0,
        [string]$Message = ''
    )
    $entry = [ordered]@{
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        chunk     = $Chunk
        status    = $Status
        bytes     = $Bytes
        message   = $Message
    }
    Add-Content -LiteralPath $chunkStatusPath -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
}

function _stop_process_tree {
    param([int]$ProcessId)
    # Marker starts llama-server itself.  /T confines termination to this
    # invocation's process tree after its output checkpoint is verified.
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
}

function _normalize_dragged_path {
    param([string]$PathValue)
    # At an interactive mandatory-parameter prompt, a path dragged from
    # Explorer may arrive as literal enclosing quotes.  Remove only one
    # matching outer pair; spaces and all inner characters are preserved.
    $value = $PathValue.Trim()
    if ($value.Length -ge 2 -and (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))
    )) {
        return $value.Substring(1, $value.Length - 2)
    }
    return $value
}

# ---------- resolved paths ----------
$enteredPdfPath = $PdfPath
$enteredOutputRoot = $OutputRoot
$PdfPath = _normalize_dragged_path $PdfPath
$OutputRoot = _normalize_dragged_path $OutputRoot
$BaseDir = _normalize_dragged_path $BaseDir

# Marker is launched with each chunk directory as its working directory.
# Resolve all caller-supplied paths before that directory change so relative
# PDF/output paths remain valid in the child process.
if (Test-Path -LiteralPath $PdfPath -PathType Leaf) {
    $PdfPath = (Resolve-Path -LiteralPath $PdfPath).Path
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$BaseDir = [IO.Path]::GetFullPath($BaseDir)
$pythonExe = Join-Path $BaseDir 'runtime\python\python.exe'
$asciiRoot = $BaseDir
$llamaServer = Join-Path $BaseDir 'llama.cpp-b9627\bin\llama-server.exe'
$suryaModel = Join-Path $BaseDir 'surya-ocr-2-gguf\surya-2.gguf'
$suryaMmproj = Join-Path $BaseDir 'surya-ocr-2-gguf\surya-2-mmproj.gguf'

$cleanScript = Join-Path $BaseDir 'scripts\clean_markdown.py'
$validateScript = Join-Path $BaseDir 'scripts\validate_markdown.py'
$markerEntry = Join-Path $BaseDir 'scripts\marker_single_entry.py'

$chunksDir = Join-Path $OutputRoot 'chunks'
$finalMarkdown = Join-Path $OutputRoot $OutputName
$reportPath = Join-Path $OutputRoot 'conversion-report.json'
$chunkStatusPath = Join-Path $OutputRoot 'chunk-status.jsonl'

if (-not $LogFile) {
    $LogFile = Join-Path $OutputRoot 'pipeline.log'
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

# ---------- start ----------
_banner 'START'
if ($PdfPath -ne $enteredPdfPath) { _log 'Removed enclosing quotes from dragged PdfPath.' }
if ($OutputRoot -ne $enteredOutputRoot) { _log 'Removed enclosing quotes from dragged OutputRoot.' }
_log "PDF   : $PdfPath"
_log "Output: $OutputRoot"
_log "Mode  : $Mode  |  ChunkSize: $ChunkSize  |  Workers: $OcrWorkers  |  CTX: $OcrCtxSize"
_log "Checkpoint: stable ${StableCheckSeconds}s | exit grace ${ExitGraceSeconds}s | no-progress timeout $(if ($NoProgressTimeoutMinutes) { "${NoProgressTimeoutMinutes}m" } else { 'disabled' })"
_log "Log   : $LogFile"

# ======================================================================
# PHASE 0 — Pre-flight
# ======================================================================
_banner 'PHASE 0 · PRE-FLIGHT'

foreach ($requiredFile in @($pythonExe, $markerEntry, $cleanScript, $validateScript)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        _log "Required portable-bundle file not found: $requiredFile" 'ERROR'; exit 1
    }
}

if (-not (Test-Path $PdfPath)) {
    _log "Source PDF not found: $PdfPath" 'ERROR'; exit 1
}

# Determine page count
try {
    $pageCount = & $pythonExe -c @"
from pypdfium2 import PdfDocument; d = PdfDocument(r'$PdfPath'); print(len(d)); d.close()
"@
    $pageCount = [int]$pageCount
} catch {
    _log "Cannot read PDF page count: $_" 'ERROR'; exit 1
}
$pdfName = [IO.Path]::GetFileNameWithoutExtension($PdfPath)
$pdfSizeMB = [math]::Round((Get-Item $PdfPath).Length / 1MB, 1)
_log "PDF: $PdfPath  |  ${pageCount} pages  |  ${pdfSizeMB} MB  |  stem=$pdfName"

# Detect text layer
$sampleChars = & $pythonExe -c @"
from pypdfium2 import PdfDocument; d = PdfDocument(r'$PdfPath'); total=0
for i in range(min(len(d),12)): total+=len(d[i].get_textpage().get_text_range().strip()); d[i].get_textpage().close()
d.close(); print(total)
"@
$sampleChars = [int]$sampleChars
$pdfType = if ($sampleChars -gt 50) { 'text' } else { 'scanned' }
_log "Text layer sample: $sampleChars chars → classified as '$pdfType'"

# OCR dependency check for scanned PDFs
$needsOcr = ($pdfType -eq 'scanned')
if ($needsOcr) {
    if (-not (Test-Path $llamaServer)) { _log "llama-server not found: $llamaServer" 'ERROR'; exit 1 }
    if (-not (Test-Path $suryaModel))   { _log "GGUF model not found: $suryaModel" 'ERROR'; exit 1 }
    if (-not (Test-Path $suryaMmproj))  { _log "GGUF mmproj not found: $suryaMmproj" 'ERROR'; exit 1 }
    _log "OCR dependencies verified: llama-server + surya-2 GGUF"
}

# Overwrite
if ($Overwrite -and (Test-Path $chunksDir)) {
    _log "Overwrite: removing existing chunks" 'WARN'
    Remove-Item -LiteralPath $chunksDir -Recurse -Force
}

$totalChunks = [Math]::Ceiling($pageCount / $ChunkSize)
_log "Chunks: $totalChunks blocks  |  ${ChunkSize} pages/block"

# ======================================================================
# PHASE 1 — Chunked OCR
# ======================================================================
if (-not $SkipChunking) {
    _banner 'PHASE 1 · OCR'
    _map_pdrive
    _map_output_drive

    try {
    $ocrStart = Get-Date

    # Environment variables use a temporary ASCII drive mapping because
    # llama.cpp may not handle Chinese installation paths reliably.
    $env:LLAMA_CPP_BINARY = "$script:mapDrive\llama.cpp-b9627\bin\llama-server.exe"
    $env:SURYA_GGUF_LOCAL_MODEL_PATH = "$script:mapDrive\surya-ocr-2-gguf\surya-2.gguf"
    $env:SURYA_GGUF_LOCAL_MMPROJ_PATH = "$script:mapDrive\surya-ocr-2-gguf\surya-2-mmproj.gguf"
    $env:SURYA_RUNTIME_CACHE_DIR = Join-Path $OutputRoot '.surya-runtime-cache'
    $env:MODEL_CACHE_DIR = Join-Path $BaseDir 'model-cache\datalab-models'
    $env:HF_HOME = Join-Path $BaseDir 'model-cache\huggingface'
    $env:SURYA_INFERENCE_PARALLEL = "$OcrWorkers"
    $env:SURYA_INFERENCE_CTX_SIZE = "$OcrCtxSize"
    $env:LLAMA_CPP_EXTRA_ARGS = '--cache-ram 0'

    New-Item -ItemType Directory -Path $chunksDir -Force | Out-Null
    $chunkIndex = 0
    $chunkRecords = @()

    for ($start = 0; $start -lt $pageCount; $start += $ChunkSize) {
        $chunkIndex++
        $end = [Math]::Min($start + $ChunkSize - 1, $pageCount - 1)
        $label = 'chunk_{0:D3}_{1:D3}' -f $start, $end
        $chunkRoot = Join-Path $chunksDir $label
        $chunkMarkdown   = Join-Path $chunkRoot "$pdfName\$pdfName.md"          # 翻译后的最终文件（合并时读取）
        $chunkMarkdownEn = Join-Path $chunkRoot "$pdfName\$($pdfName)_en.md"   # OCR 原始英文输出
        $chunkMeta       = Join-Path $chunkRoot "$pdfName\$($pdfName)_meta.json"

        # Skip if already OCR'd (check _en.md)
        if ((Test-Path -LiteralPath $chunkMarkdownEn) -and (Get-Item -LiteralPath $chunkMarkdownEn).Length -gt 0) {
            $chunkRecords += @{ chunk=$label; bytes=(Get-Item $chunkMarkdownEn).Length; status='SKIPPED' }
            _write_chunk_status $label 'SKIPPED' (Get-Item $chunkMarkdownEn).Length 'Existing verified OCR markdown'
            _log "[$chunkIndex/$totalChunks] SKIP $label (already done)" 'DONE'
            continue
        }

        # Recover a completed Marker artifact left behind when the parent
        # PowerShell/Codex host disappeared after Marker saved its output but
        # before the pipeline could checkpoint and rename it to *_en.md.
        $recoverableArtifact = $false
        $recoveredBytes = 0
        $mdItem = Get-Item -LiteralPath $chunkMarkdown -ErrorAction SilentlyContinue
        $metaItem = Get-Item -LiteralPath $chunkMeta -ErrorAction SilentlyContinue
        if ($mdItem -and $metaItem -and $mdItem.Length -ge $MinimumMarkdownBytes) {
            $oldEnough = ((Get-Date).ToUniversalTime() - $mdItem.LastWriteTimeUtc).TotalSeconds -ge $StableCheckSeconds -and
                        ((Get-Date).ToUniversalTime() - $metaItem.LastWriteTimeUtc).TotalSeconds -ge $StableCheckSeconds
            if ($oldEnough) {
                try {
                    $null = Get-Content -LiteralPath $chunkMarkdown -Raw -Encoding UTF8 -ErrorAction Stop
                    $null = Get-Content -LiteralPath $chunkMeta -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $recoverableArtifact = $true
                    $recoveredBytes = $mdItem.Length
                } catch {
                    $recoverableArtifact = $false
                }
            }
        }
        if ($recoverableArtifact) {
            Rename-Item -LiteralPath $chunkMarkdown -NewName "$($pdfName)_en.md" -Force
            $chunkRecords += @{ chunk=$label; bytes=$recoveredBytes; status='SUCCESS' }
            _write_chunk_status $label 'RECOVERED' $recoveredBytes 'Recovered stable Markdown and readable metadata left by an interrupted parent host'
            _write_chunk_status $label 'SUCCESS' $recoveredBytes 'Recovered artifact renamed to _en.md'
            _log "[$chunkIndex/$totalChunks] RECOVERED $label ($recoveredBytes bytes); continuing with next chunk" 'DONE'
            continue
        }

        # Clean partial
        if (Test-Path -LiteralPath $chunkRoot) {
            $resolved = [IO.Path]::GetFullPath($chunkRoot)
            $resolvedWork = [IO.Path]::GetFullPath($chunksDir)
            if (-not $resolved.StartsWith($resolvedWork, [StringComparison]::OrdinalIgnoreCase)) {
                _log "Safety: refusing to delete outside work root: $resolved" 'ERROR'; exit 1
            }
            $failedLogs = @(Get-ChildItem -LiteralPath $resolved -File -Filter 'marker.*.log' -ErrorAction SilentlyContinue)
            if ($failedLogs.Count -gt 0) {
                $attemptStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
                $attemptDir = Join-Path $OutputRoot "failed-attempt-logs\$label\$attemptStamp"
                New-Item -ItemType Directory -Path $attemptDir -Force | Out-Null
                foreach ($failedLog in $failedLogs) {
                    Copy-Item -LiteralPath $failedLog.FullName -Destination (Join-Path $attemptDir $failedLog.Name) -Force
                }
                _log "Archived previous attempt logs: $attemptDir" 'WARN'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }

        New-Item -ItemType Directory -Path $chunkRoot -Force | Out-Null

        $elapsed = (Get-Date) - $ocrStart
        $avgPerChunk = if ($chunkIndex -gt 1) { $elapsed.TotalSeconds / ($chunkIndex - 1) } else { 900 }
        $etaSeconds = $avgPerChunk * ($totalChunks - $chunkIndex + 1)
        $eta = [timespan]::FromSeconds($etaSeconds).ToString('hh\:mm\:ss')
        _log "[$chunkIndex/$totalChunks] START $label (pages $start-$end) | ETA remaining: $eta"

        # Do not use '& marker_single ...' here: on Windows Marker can finish
        # writing Markdown but remain stuck while cleaning up llama-server.
        # An independent process lets us checkpoint durable output first.
        $markerStdout = Join-Path $chunkRoot 'marker.stdout.log'
        $markerStderr = Join-Path $chunkRoot 'marker.stderr.log'
        $shortChunkRoot = "$script:outputMapDrive\chunks\$label"
        # Start-Process accepts a single command-line string reliably on
        # Windows; explicitly quote file-system values because book paths
        # commonly contain spaces.
        $forceOcrArg = if ($needsOcr) { ' --force_ocr' } else { '' }
        # Marker appends the PDF stem below --output_dir. Passing the full
        # chunk path can exceed the legacy Windows MAX_PATH limit for long
        # article titles. The child already runs with $chunkRoot as its
        # working directory, so a relative output path produces the same
        # files without handing os.makedirs() an oversized absolute string.
        $markerArgs = '-u "{0}" "{1}" --page_range "{2}" --output_dir "." --output_format markdown --mode "{3}"{4} --disable_tqdm' -f `
            $markerEntry, $PdfPath, "$start-$end", $Mode, $forceOcrArg
        _log "[$chunkIndex/$totalChunks] Input mode: $(if ($needsOcr) { 'scanned PDF; force OCR enabled' } else { 'text PDF; native text extraction' })"
        # Do not use -NoNewWindow here. Marker/llama-server cleanup can send
        # console-control signals; sharing the runner's console can terminate
        # the pipeline and run_until_done.ps1 together after the first chunk.
        # A hidden, separate console confines those signals to this OCR child.
        $markerProcess = Start-Process -FilePath $pythonExe -ArgumentList $markerArgs -WorkingDirectory $shortChunkRoot `
            -RedirectStandardOutput $markerStdout -RedirectStandardError $markerStderr -PassThru -WindowStyle Hidden

        $checkpointAt = $null
        $candidateSignature = $null
        $candidateSince = $null
        $lastActivity = Get-Date
        $checkpointMessage = ''
        $lastProgressLog = [datetime]::MinValue
        while (-not $checkpointAt) {
            Start-Sleep -Seconds 5
            $markerProcess.Refresh()

            $progressStatus = _show_ocr_progress -CompletedChunks ($chunkIndex - 1) -TotalChunks $totalChunks `
                -CurrentChunk $label -PageStart $start -PageEnd $end -StartedAt $ocrStart
            if (((Get-Date) - $lastProgressLog).TotalSeconds -ge 30) {
                _log "PROGRESS $progressStatus"
                $lastProgressLog = Get-Date
            }

            $mdItem = Get-Item -LiteralPath $chunkMarkdown -ErrorAction SilentlyContinue
            $metaItem = Get-Item -LiteralPath $chunkMeta -ErrorAction SilentlyContinue
            if ($mdItem -and $metaItem -and $mdItem.Length -ge $MinimumMarkdownBytes) {
                try {
                    $null = Get-Content -LiteralPath $chunkMarkdown -Raw -Encoding UTF8 -ErrorAction Stop
                    $null = Get-Content -LiteralPath $chunkMeta -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $signature = "$($mdItem.Length)|$($mdItem.LastWriteTimeUtc.Ticks)|$($metaItem.Length)|$($metaItem.LastWriteTimeUtc.Ticks)"
                    if ($signature -ne $candidateSignature) {
                        $candidateSignature = $signature
                        $candidateSince = Get-Date
                        $lastActivity = $candidateSince
                    } elseif (((Get-Date) - $candidateSince).TotalSeconds -ge $StableCheckSeconds) {
                        $checkpointAt = Get-Date
                        $checkpointMessage = "stable ${StableCheckSeconds}s; meta readable; marker pid=$($markerProcess.Id)"
                    }
                } catch {
                    $candidateSignature = $null
                    $candidateSince = $null
                }
            }

            if (-not $checkpointAt -and $markerProcess.HasExited) {
                # Small documents may finish cleanly before the normal polling
                # loop has observed an unchanged artifact for the full stable
                # interval.  A successful process exit is a reason to finish
                # the stability check, not to discard otherwise valid output.
                if ($markerProcess.ExitCode -eq 0 -and $candidateSignature -and $candidateSince) {
                    $remainingStableSeconds = [Math]::Ceiling($StableCheckSeconds - ((Get-Date) - $candidateSince).TotalSeconds)
                    if ($remainingStableSeconds -gt 0) {
                        Start-Sleep -Seconds $remainingStableSeconds
                    }
                    try {
                        $finalMdItem = Get-Item -LiteralPath $chunkMarkdown -ErrorAction Stop
                        $finalMetaItem = Get-Item -LiteralPath $chunkMeta -ErrorAction Stop
                        $null = Get-Content -LiteralPath $chunkMarkdown -Raw -Encoding UTF8 -ErrorAction Stop
                        $null = Get-Content -LiteralPath $chunkMeta -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        $finalSignature = "$($finalMdItem.Length)|$($finalMdItem.LastWriteTimeUtc.Ticks)|$($finalMetaItem.Length)|$($finalMetaItem.LastWriteTimeUtc.Ticks)"
                        if ($finalMdItem.Length -ge $MinimumMarkdownBytes -and $finalSignature -eq $candidateSignature) {
                            $checkpointAt = Get-Date
                            $checkpointMessage = "stable ${StableCheckSeconds}s after clean marker exit; meta readable; marker pid=$($markerProcess.Id)"
                        }
                    } catch {
                        $checkpointAt = $null
                    }
                }
            }

            if (-not $checkpointAt -and $markerProcess.HasExited) {
                _log "[$chunkIndex/$totalChunks] FAIL $label — Marker exited before a stable readable checkpoint (exit=$($markerProcess.ExitCode)); see $markerStdout and $markerStderr" 'ERROR'
                _write_chunk_status $label 'FAILED' 0 "Marker exited before checkpoint; exit=$($markerProcess.ExitCode)"
                $chunkRecords += @{ chunk=$label; bytes=0; status='FAILED' }
                break
            }
            if (-not $checkpointAt -and $NoProgressTimeoutMinutes -gt 0 -and ((Get-Date) - $lastActivity).TotalMinutes -ge $NoProgressTimeoutMinutes) {
                _stop_process_tree $markerProcess.Id
                _log "[$chunkIndex/$totalChunks] FAIL $label — no output progress for ${NoProgressTimeoutMinutes}m; process tree stopped" 'ERROR'
                _write_chunk_status $label 'FAILED' 0 "No output progress for ${NoProgressTimeoutMinutes}m"
                $chunkRecords += @{ chunk=$label; bytes=0; status='FAILED' }
                break
            }
        }

        if (-not $checkpointAt) { continue }

        $chunkBytes = (Get-Item -LiteralPath $chunkMarkdown).Length
        _write_chunk_status $label 'CHECKPOINTED' $chunkBytes $checkpointMessage
        _log "[$chunkIndex/$totalChunks] CHECKPOINT $label ($chunkBytes bytes; $checkpointMessage)" 'DONE'

        # A completed artifact is authoritative.  Give Marker a chance to
        # exit normally, then recover only this invocation's lingering tree.
        $graceUntil = (Get-Date).AddSeconds($ExitGraceSeconds)
        while (-not $markerProcess.HasExited -and (Get-Date) -lt $graceUntil) {
            Start-Sleep -Seconds 2
            $markerProcess.Refresh()
        }
        if (-not $markerProcess.HasExited) {
            _stop_process_tree $markerProcess.Id
            _log "[$chunkIndex/$totalChunks] Marker cleanup exceeded ${ExitGraceSeconds}s; stopped its process tree after checkpoint" 'WARN'
            _write_chunk_status $label 'CLEANUP_RECOVERED' $chunkBytes "Exceeded ${ExitGraceSeconds}s exit grace"
        } elseif ($markerProcess.ExitCode -ne 0) {
            _log "marker exit code: $($markerProcess.ExitCode) after verified checkpoint (continuing)" 'WARN'
        }

        # Rename OCR output: <pdf>.md → <pdf>_en.md (user translates, then renames back)
        Rename-Item -LiteralPath $chunkMarkdown -NewName "$($pdfName)_en.md" -Force
        $chunkBytes = (Get-Item -LiteralPath $chunkMarkdownEn).Length
        if ($chunkBytes -eq 0) {
            _log "[$chunkIndex/$totalChunks] FAIL $label — empty markdown" 'ERROR'
            _write_chunk_status $label 'FAILED' 0 'Markdown empty after rename'
            $chunkRecords += @{ chunk=$label; bytes=0; status='FAILED' }
            continue
        }
        _log "[$chunkIndex/$totalChunks] DONE $label ($chunkBytes bytes, $([math]::Round($chunkBytes/1000,1)) KB)" 'DONE'
        _write_chunk_status $label 'SUCCESS' $chunkBytes 'OCR checkpoint verified and renamed to _en.md'
        $chunkRecords += @{ chunk=$label; bytes=$chunkBytes; status='SUCCESS' }
        $null = _show_ocr_progress -CompletedChunks $chunkIndex -TotalChunks $totalChunks `
            -CurrentChunk $label -PageStart $start -PageEnd $end -StartedAt $ocrStart -Completed:($chunkIndex -eq $totalChunks)
    }

    $ocrElapsed = (Get-Date) - $ocrStart
    _log "OCR phase completed in $($ocrElapsed.ToString('hh\:mm\:ss'))"

    # Summary
    $succeeded = @($chunkRecords | Where-Object { $_.status -eq 'SUCCESS' -or $_.status -eq 'SKIPPED' }).Count
    $failed = @($chunkRecords | Where-Object { $_.status -eq 'FAILED' }).Count
    if ($failed -gt 0) {
        _log "OCR: $succeeded/$totalChunks succeeded, $failed FAILED" 'ERROR'
        exit 1
    }
    _log "OCR: $succeeded/$totalChunks all verified" 'DONE'
    _write_chunk_status 'ALL' 'CHUNKS_COMPLETE' $succeeded 'All OCR chunks passed durable checkpoints'

    # OCR produces *_en.md.  Translation is deliberately a separate human or
    # downstream-AI step; do not report an OCR-successful run as a merge
    # failure merely because translated .md files do not exist yet.
    $translatedCount = 0
    for ($translationStart = 0; $translationStart -lt $pageCount; $translationStart += $ChunkSize) {
        $translationEnd = [Math]::Min($translationStart + $ChunkSize - 1, $pageCount - 1)
        $translationLabel = 'chunk_{0:D3}_{1:D3}' -f $translationStart, $translationEnd
        $translationMarkdown = Join-Path $chunksDir $translationLabel "$pdfName\$pdfName.md"
        if ((Test-Path -LiteralPath $translationMarkdown) -and (Get-Item -LiteralPath $translationMarkdown).Length -ge $MinimumMarkdownBytes) {
            $translatedCount++
        }
    }
    if ($translatedCount -lt $totalChunks) {
        _log "OCR complete. Translated chunks: $translatedCount/$totalChunks; stopping before merge. Translate each *_en.md to $pdfName.md, then rerun with -SkipChunking." 'DONE'
        _write_chunk_status 'ALL' 'AWAITING_TRANSLATION' 0 "Translated chunks: $translatedCount/$totalChunks"
        exit 0
    }

    } finally {
        _stop_surya_runtime_services
        _unmap_output_drive
        _unmap_pdrive
    }

} else {
    # Verify existing chunks (check for translated .md files)
    $found = 0
    for ($start = 0; $start -lt $pageCount; $start += $ChunkSize) {
        $end = [Math]::Min($start + $ChunkSize - 1, $pageCount - 1)
        $label = 'chunk_{0:D3}_{1:D3}' -f $start, $end
        $md = Join-Path $chunksDir $label "$pdfName\$pdfName.md"
        if ((Test-Path $md) -and (Get-Item $md).Length -gt 0) { $found++ }
    }
    if ($found -lt $totalChunks) {
        _log "SkipChunking: only $found/$totalChunks chunks exist on disk — aborting" 'ERROR'; exit 1
    }
    _log "SkipChunking: $found/$totalChunks chunks verified on disk"
}

# ======================================================================
# PHASE 2 — Merge
# ======================================================================
_banner 'PHASE 2 · MERGE'
$_stageTimes['merge'] = Get-Date

$chunks = Get-ChildItem -LiteralPath $chunksDir -Directory -ErrorAction Stop | Sort-Object Name

# Write merge to temp file first, then rename (atomic-ish)
$tempMerged = $finalMarkdown + '.tmp'
$writer = [System.IO.StreamWriter]::new($tempMerged, $false, [System.Text.UTF8Encoding]::new($false))

try {
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $chunk = $chunks[$i]
        $mdPath = Join-Path $chunk.FullName "$pdfName\$pdfName.md"
        if (-not (Test-Path $mdPath)) {
            _log "Missing chunk markdown: $mdPath" 'ERROR'; exit 1
        }

        $content = Get-Content -LiteralPath $mdPath -Raw -Encoding UTF8
        $chunkDirName = $chunk.Name

        # Rewrite image refs: ![](relative_path) or ![alt](relative_path)
        $content = [regex]::Replace($content, '!\[([^\]]*)\]\(([^)]+)\)', {
            param($m)
            $alt = $m.Groups[1].Value
            $path = $m.Groups[2].Value
            if ($path -match '^(https?:|data:)') {
                return $m.Value
            }
            $fileName = Split-Path $path -Leaf
            return "![$alt](chunks/$chunkDirName/$pdfName/$fileName)"
        })

        $writer.WriteLine("<!-- chunk: $chunkDirName -->")
        $writer.WriteLine()
        $writer.Write($content.TrimEnd())
        $writer.WriteLine()
        $writer.WriteLine()

        _log "  merged $chunkDirName ($((Get-Item $mdPath).Length) bytes)"
    }
} finally {
    $writer.Close()
    $writer.Dispose()
}

if (Test-Path $finalMarkdown) { Remove-Item $finalMarkdown -Force }
Move-Item $tempMerged $finalMarkdown -Force
_log "Merged → $finalMarkdown ($((Get-Item $finalMarkdown).Length) bytes, $($chunks.Count) chunks)"

# ======================================================================
# PHASE 3 — Cleanup
# ======================================================================
_banner 'PHASE 3 · CLEANUP'
$_stageTimes['cleanup'] = Get-Date

$cleanBytesBefore = (Get-Item $finalMarkdown).Length
$cleanResult = & $pythonExe $cleanScript $finalMarkdown 2>&1
$cleanExitCode = $LASTEXITCODE
$cleanBytesAfter = (Get-Item $finalMarkdown).Length
$delta = $cleanBytesAfter - $cleanBytesBefore
$deltaSign = if ($delta -ge 0) { '+' } else { '' }
_log "Cleanup: $cleanBytesBefore → $cleanBytesAfter bytes (${deltaSign}${delta})  |  exit=$cleanExitCode"
if ($cleanExitCode -ne 0) {
    _log "Cleanup script returned non-zero: $cleanResult" 'WARN'
}

# ======================================================================
# PHASE 4 — Validation
# ======================================================================
_banner 'PHASE 4 · VALIDATE'
$_stageTimes['validate'] = Get-Date

$validateResult = & $pythonExe $validateScript $finalMarkdown --pdf $PdfPath 2>&1
$validateExitCode = $LASTEXITCODE
_log "Validator exit code: $validateExitCode"

# ---- Supplementary checks ----
$content = Get-Content -LiteralPath $finalMarkdown -Raw -Encoding UTF8

# Image accessibility
$imageMatches = [regex]::Matches($content, '!\[[^\]]*\]\(([^)]+)\)')
$imagesFound, $imagesMissing = 0, 0
foreach ($m in $imageMatches) {
    $relPath = $m.Groups[1].Value
    if ($relPath -match '^(https?:|data:)') { $imagesFound++; continue }
    $absPath = Join-Path $OutputRoot $relPath -Resolve -ErrorAction SilentlyContinue
    if ($absPath) { $imagesFound++ } else { $imagesMissing++ }
}
_log "Images: $imagesFound found / $imagesMissing missing / $($imageMatches.Count) total"

# Garbled text (match validate.py logic)
$replacementCount = ([regex]::Matches($content, '\ufffd')).Count
$mojibakeCount = ([regex]::Matches($content, '[ÃÂ]')).Count + ([regex]::Matches($content, 'â€')).Count
$garbledTotal = $replacementCount + $mojibakeCount
if ($garbledTotal -gt 0) {
    _log "Garbled text: $garbledTotal chars (�:$replacementCount, Ã/Â/â€:$mojibakeCount)" 'WARN'
} else {
    _log "Garbled text: 0"
}

# Headings
$headingCount = ([regex]::Matches($content, '^#{1,6}\s', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
_log "Headings: $headingCount"

# Large repeated blocks
$repeatedPassages = 0
$blocks = [regex]::Split($content, '\n\s*\n') | Where-Object { $_.Trim().Length -ge 80 }
$blockCounts = @{}
foreach ($b in $blocks) {
    # Whitespace normalization may shorten the block.  Compute the substring
    # length from the normalized value itself to avoid an out-of-range error.
    $normalizedBlock = ($b -replace '\s+', ' ').Trim()
    $key = $normalizedBlock.Substring(0, [Math]::Min(200, $normalizedBlock.Length))
    $blockCounts[$key] = ($blockCounts[$key] ?? 0) + 1
}
$repeatedPassages = ($blockCounts.GetEnumerator() | Where-Object { $_.Value -ge 3 } | Measure-Object).Count
if ($repeatedPassages -gt 0) {
    _log "Large repeated blocks (≥3x): $repeatedPassages" 'WARN'
} else {
    _log "Large repeated blocks: 0"
}

# ======================================================================
# PHASE 5 — Report
# ======================================================================
_banner 'PHASE 5 · REPORT'

$report = [ordered]@{
    generated           = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    status              = 'SUCCESS'
    pdf_path            = $PdfPath
    pdf_type            = $pdfType
    pdf_size_mb         = $pdfSizeMB
    source_page_count   = $pageCount
    marker_version      = '2.0.0'
    surya_ocr_version   = '0.22.1'
    device              = 'CPU'
    ocr_mode            = $Mode
    ocr_workers         = $OcrWorkers
    ocr_ctx_size        = $OcrCtxSize
    chunk_count         = $totalChunks
    chunk_size          = $ChunkSize
    final_markdown_path = $finalMarkdown
    final_markdown_bytes = (Get-Item $finalMarkdown).Length
    image_count         = $imageMatches.Count
    images_verified     = ($imagesMissing -eq 0)
    heading_count       = $headingCount
    garbled_chars_total = $garbledTotal
    repeated_blocks     = $repeatedPassages
    pipeline_duration   = ((Get-Date) - $_pipelineStart).ToString('hh\:mm\:ss')
    stages              = [ordered]@{
        preflight = $true
        ocr       = (-not $SkipChunking)
        merge     = $true
        cleanup   = $true
        validate  = $true
    }
    warnings            = @()
}

if ($imagesMissing -gt 0) {
    $report.warnings += "$imagesMissing image(s) not accessible from final markdown"
}
if ($garbledTotal -gt 0) {
    $report.warnings += "$garbledTotal garbled character(s) detected"
}
if ($repeatedPassages -gt 0) {
    $report.warnings += "$repeatedPassages large block(s) repeated ≥3 times"
}

$reportJson = $report | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($reportPath, $reportJson, [System.Text.UTF8Encoding]::new($false))
_log "Report → $reportPath"

# ======================================================================
# FINAL
# ======================================================================
_unmap_pdrive  # safety: remove P: if somehow still mapped
_unmap_output_drive

_banner 'COMPLETE'
_log "Status   : SUCCESS" 'DONE'
_log "Markdown : $finalMarkdown" 'DONE'
_log "Size     : $((Get-Item $finalMarkdown).Length) bytes" 'DONE'
_log "Images   : $imagesFound/$($imageMatches.Count) accessible" 'DONE'
_log "Report   : $reportPath" 'DONE'
_log "Duration : $(((Get-Date) - $_pipelineStart).ToString('hh\:mm\:ss'))" 'DONE'
_log "Log      : $LogFile" 'DONE'
