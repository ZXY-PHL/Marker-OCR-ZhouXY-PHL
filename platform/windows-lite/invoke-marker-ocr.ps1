[CmdletBinding()]
param(
    [ValidateSet('Check', 'Ocr', 'Merge', 'Status')]
    [string]$Action = 'Ocr',
    [string]$PdfPath,
    [string]$OutputRoot,
    [string]$EngineRoot,
    [string]$OutputName = 'output.md',
    [ValidateRange(1, 256)]
    [int]$ChunkSize = 16,
    [ValidateSet('fast', 'balanced')]
    [string]$Mode = 'fast',
    [ValidateRange(1, 32)]
    [int]$OcrWorkers = 1,
    [ValidateRange(1024, 1048576)]
    [int]$OcrCtxSize = 16384,
    [ValidateRange(1, 100)]
    [int]$MaxRounds = 100,
    [ValidateRange(1, 20)]
    [int]$MaxNoProgressRounds = 3,
    [string]$ResultPath,
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$script:StartedAt = Get-Date
$script:ExitCode = 0
$script:LockStream = $null
$script:LockPath = $null

function Normalize-PathInput {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    $normalized = $Value.Trim()
    if ($normalized.Length -ge 2 -and (
        ($normalized.StartsWith('"') -and $normalized.EndsWith('"')) -or
        ($normalized.StartsWith("'") -and $normalized.EndsWith("'"))
    )) {
        return $normalized.Substring(1, $normalized.Length - 2)
    }
    return $normalized
}

function Resolve-EngineRoot {
    param([string]$Requested)
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $candidates.Add((Normalize-PathInput $Requested))
    } elseif (-not [string]::IsNullOrWhiteSpace($env:MARKER_OCR_ENGINE_ROOT)) {
        $candidates.Add((Normalize-PathInput $env:MARKER_OCR_ENGINE_ROOT))
    } else {
        $candidates.Add((Join-Path $PSScriptRoot '..\Marker-OCR-Portable'))
        $candidates.Add((Join-Path $PSScriptRoot 'Marker-OCR-Portable'))
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try { $full = [IO.Path]::GetFullPath($candidate) } catch { continue }
        if (Test-Path -LiteralPath $full -PathType Container) { return $full }
    }
    throw 'Marker OCR engine not found. Pass -EngineRoot or set MARKER_OCR_ENGINE_ROOT.'
}

function Get-EngineCheck {
    param([string]$Root)
    $required = [ordered]@{
        portable_pwsh = (Join-Path $Root 'runtime\pwsh\pwsh.exe')
        portable_python = (Join-Path $Root 'runtime\python\python.exe')
        pipeline = (Join-Path $Root 'pipeline.ps1')
        runner = (Join-Path $Root 'run_until_done.ps1')
        marker_entry = (Join-Path $Root 'scripts\marker_single_entry.py')
        cleanup = (Join-Path $Root 'scripts\clean_markdown.py')
        validator = (Join-Path $Root 'scripts\validate_markdown.py')
        llama_server = (Join-Path $Root 'llama.cpp-b9627\bin\llama-server.exe')
        surya_model = (Join-Path $Root 'surya-ocr-2-gguf\surya-2.gguf')
        surya_mmproj = (Join-Path $Root 'surya-ocr-2-gguf\surya-2-mmproj.gguf')
        layout_model = (Join-Path $Root 'model-cache\huggingface\hub\models--datalab-to--surya_layout2\refs\main')
        ocr_error_model = (Join-Path $Root 'model-cache\datalab-models\ocr_error_detection\2025_02_18\model.safetensors')
    }
    $items = @()
    foreach ($entry in $required.GetEnumerator()) {
        $exists = Test-Path -LiteralPath $entry.Value -PathType Leaf
        $items += [ordered]@{ name = $entry.Key; ok = [bool]$exists; path = $entry.Value }
    }
    return [ordered]@{
        ok = (@($items | Where-Object { -not $_.ok }).Count -eq 0)
        items = $items
        pwsh = $required.portable_pwsh
        python = $required.portable_python
        pipeline = $required.pipeline
        runner = $required.runner
    }
}

function Get-PageCount {
    param([string]$PythonExe, [string]$SourcePdf)
    $code = 'from pypdfium2 import PdfDocument; import sys; d=PdfDocument(sys.argv[1]); print(len(d)); d.close()'
    $value = & $PythonExe -c $code $SourcePdf 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the PDF page count.' }
    return [int]($value | Select-Object -Last 1)
}

function Get-ProgressSnapshot {
    param([string]$Root, [string]$SourcePdf, [string]$PythonExe, [int]$Size)
    $snapshot = [ordered]@{
        page_count = $null
        expected_chunks = $null
        ocr_chunks = 0
        translated_chunks = 0
        ocr_complete = $false
        translations_complete = $false
    }
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $snapshot }
    $chunks = Join-Path $Root 'chunks'
    if (Test-Path -LiteralPath $chunks -PathType Container) {
        $markdownFiles = @(Get-ChildItem -LiteralPath $chunks -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
        if (-not [string]::IsNullOrWhiteSpace($SourcePdf)) {
            $pdfStem = [IO.Path]::GetFileNameWithoutExtension($SourcePdf)
            $snapshot.ocr_chunks = @($markdownFiles | Where-Object { $_.Name -ieq "${pdfStem}_en.md" }).Count
            $snapshot.translated_chunks = @($markdownFiles | Where-Object { $_.Name -ieq "${pdfStem}.md" }).Count
        } else {
            $snapshot.ocr_chunks = @($markdownFiles | Where-Object { $_.Name -like '*_en.md' }).Count
            $snapshot.translated_chunks = @($markdownFiles | Where-Object { $_.Name -notlike '*_en.md' }).Count
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($SourcePdf) -and (Test-Path -LiteralPath $SourcePdf -PathType Leaf) -and (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        $snapshot.page_count = Get-PageCount -PythonExe $PythonExe -SourcePdf $SourcePdf
        $snapshot.expected_chunks = [int][Math]::Ceiling($snapshot.page_count / [double]$Size)
        $snapshot.ocr_complete = ($snapshot.ocr_chunks -ge $snapshot.expected_chunks)
        $snapshot.translations_complete = ($snapshot.translated_chunks -ge $snapshot.expected_chunks)
    }
    return $snapshot
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
    return $json
}

function Invoke-ChildPowerShell {
    param([string]$Pwsh, [string[]]$Arguments, [string]$LogPath)
    $logParent = Split-Path -Parent $LogPath
    if ($logParent) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
    "[$(Get-Date -Format o)] START" | Add-Content -LiteralPath $LogPath -Encoding UTF8
    & $Pwsh @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $line | Out-File -LiteralPath $LogPath -Append -Encoding utf8
        # Keep stdout reserved for the node's final JSON contract. Progress is
        # interactive-only and is therefore emitted through the host stream.
        try { Write-Host $line } catch { }
    }
    $code = $LASTEXITCODE
    "[$(Get-Date -Format o)] EXIT $code" | Add-Content -LiteralPath $LogPath -Encoding UTF8
    return [int]$code
}

function New-BaseResult {
    param([string]$ResolvedEngine, [string]$ResolvedPdf, [string]$ResolvedOutput)
    return [ordered]@{
        schema_version = '1.0'
        action = $Action.ToUpperInvariant()
        status = 'RUNNING'
        exit_code = 0
        started_at = $script:StartedAt.ToString('o')
        finished_at = $null
        duration_seconds = 0
        engine_root = $ResolvedEngine
        pdf_path = $ResolvedPdf
        output_root = $ResolvedOutput
        output_markdown = $(if ($ResolvedOutput) { Join-Path $ResolvedOutput $OutputName } else { $null })
        conversion_report = $(if ($ResolvedOutput) { Join-Path $ResolvedOutput 'conversion-report.json' } else { $null })
        pipeline_log = $(if ($ResolvedOutput) { Join-Path $ResolvedOutput 'pipeline.log' } else { $null })
        execution_log = $(if ($ResolvedOutput) { Join-Path $ResolvedOutput 'node-execution.log' } else { $null })
        rounds = 0
        no_progress_rounds = 0
        progress = $null
        error = $null
    }
}

$resolvedEngine = $null
$resolvedPdf = $null
$resolvedOutput = $null
$engineCheck = $null
$result = $null

try {
    $resolvedEngine = Resolve-EngineRoot -Requested $EngineRoot
    $engineCheck = Get-EngineCheck -Root $resolvedEngine
    $result = New-BaseResult -ResolvedEngine $resolvedEngine -ResolvedPdf $null -ResolvedOutput $null

    if ($Action -eq 'Check') {
        if ($engineCheck.ok) {
            $probeCode = "import importlib.metadata as m, pypdfium2, torch; from marker.scripts.convert_single import convert_single_cli; print('marker-pdf=' + m.version('marker-pdf')); print('pypdfium2=' + m.version('pypdfium2')); print('torch=' + torch.__version__)"
            $probeOutput = & $engineCheck.python -c $probeCode 2>&1
            $probeExitCode = $LASTEXITCODE
            $engineCheck['python_probe_ok'] = ($probeExitCode -eq 0)
            $engineCheck['python_probe_exit_code'] = $probeExitCode
            $engineCheck['python_probe_output'] = @($probeOutput | ForEach-Object { [string]$_ })
            if ($probeExitCode -ne 0) { $engineCheck.ok = $false }
        }
        $result.status = if ($engineCheck.ok) { 'READY' } else { 'NOT_READY' }
        $result.engine = $engineCheck
        if (-not $engineCheck.ok) { $script:ExitCode = 3 }
    } else {
        if (-not $engineCheck.ok) { throw 'Marker OCR engine is incomplete. Run Check and inspect missing items.' }
        if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw "Action=$Action requires -OutputRoot." }
        if ($Action -eq 'Ocr' -and $Overwrite) { throw '-Overwrite is not accepted for Action=Ocr because OCR checkpoints must be preserved.' }
        $resolvedOutput = [IO.Path]::GetFullPath((Normalize-PathInput $OutputRoot))
        New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

        if (-not [string]::IsNullOrWhiteSpace($PdfPath)) {
            $candidatePdf = Normalize-PathInput $PdfPath
            if (-not (Test-Path -LiteralPath $candidatePdf -PathType Leaf) -or [IO.Path]::GetExtension($candidatePdf) -ine '.pdf') {
                throw "PDF not found or extension is not .pdf: $candidatePdf"
            }
            $resolvedPdf = (Resolve-Path -LiteralPath $candidatePdf).Path
        } elseif ($Action -ne 'Status') {
            throw "Action=$Action requires -PdfPath."
        }

        $result = New-BaseResult -ResolvedEngine $resolvedEngine -ResolvedPdf $resolvedPdf -ResolvedOutput $resolvedOutput
        if ($Action -eq 'Status') {
            $result.progress = Get-ProgressSnapshot -Root $resolvedOutput -SourcePdf $resolvedPdf -PythonExe $engineCheck.python -Size $ChunkSize
            if (Test-Path -LiteralPath $result.conversion_report -PathType Leaf) {
                $result.status = 'SUCCESS'
            } elseif ($result.progress.ocr_complete -and -not $result.progress.translations_complete) {
                $result.status = 'AWAITING_TRANSLATION'
            } elseif ($result.progress.ocr_complete) {
                $result.status = 'OCR_COMPLETE'
            } else {
                $result.status = 'INCOMPLETE'
            }
        } else {
            $script:LockPath = Join-Path $resolvedOutput '.marker-ocr-node.lock'
            try {
                $script:LockStream = [IO.File]::Open($script:LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch {
                $result.status = 'BUSY'
                $result.error = "Another node owns this output directory: $script:LockPath"
                $script:ExitCode = 30
                throw [InvalidOperationException]::new($result.error)
            }

            $common = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
            if ($Action -eq 'Ocr') {
                $arguments = $common + @(
                    '-File', $engineCheck.pipeline,
                    '-PdfPath', $resolvedPdf,
                    '-OutputRoot', $resolvedOutput,
                    '-OutputName', $OutputName,
                    '-ChunkSize', [string]$ChunkSize,
                    '-Mode', $Mode,
                    '-OcrWorkers', [string]$OcrWorkers,
                    '-OcrCtxSize', [string]$OcrCtxSize,
                    '-BaseDir', $resolvedEngine
                )
                $previousCompleted = 0
                $noProgressRounds = 0
                $childCode = 0
                for ($round = 1; $round -le $MaxRounds; $round++) {
                    $result.rounds = $round
                    $childCode = Invoke-ChildPowerShell -Pwsh $engineCheck.pwsh -Arguments $arguments -LogPath $result.execution_log
                    $result.progress = Get-ProgressSnapshot -Root $resolvedOutput -SourcePdf $resolvedPdf -PythonExe $engineCheck.python -Size $ChunkSize
                    if ($result.progress.ocr_complete) { break }

                    if ($result.progress.ocr_chunks -le $previousCompleted) { $noProgressRounds++ } else { $noProgressRounds = 0 }
                    $previousCompleted = $result.progress.ocr_chunks
                    $result.no_progress_rounds = $noProgressRounds
                    if ($noProgressRounds -ge $MaxNoProgressRounds) { break }
                    if ($round -lt $MaxRounds) { Start-Sleep -Seconds 3 }
                }
            } else {
                $arguments = $common + @(
                    '-File', $engineCheck.pipeline,
                    '-PdfPath', $resolvedPdf,
                    '-OutputRoot', $resolvedOutput,
                    '-OutputName', $OutputName,
                    '-ChunkSize', [string]$ChunkSize,
                    '-SkipChunking',
                    '-BaseDir', $resolvedEngine
                )
                if ($Overwrite) { $arguments += '-Overwrite' }
                $result.rounds = 1
                $childCode = Invoke-ChildPowerShell -Pwsh $engineCheck.pwsh -Arguments $arguments -LogPath $result.execution_log
                $result.progress = Get-ProgressSnapshot -Root $resolvedOutput -SourcePdf $resolvedPdf -PythonExe $engineCheck.python -Size $ChunkSize
            }

            if ($Action -eq 'Ocr') {
                if (-not $result.progress.ocr_complete) {
                    $result.status = 'FAILED'
                    $result.error = "OCR stopped after $($result.rounds) round(s), including $($result.no_progress_rounds) no-progress round(s). Inspect node-execution.log and pipeline.log."
                    $script:ExitCode = if ($childCode -ne 0) { 10 } else { 20 }
                } elseif ((Test-Path -LiteralPath $result.conversion_report -PathType Leaf) -and (Test-Path -LiteralPath $result.output_markdown -PathType Leaf)) {
                    $result.status = 'SUCCESS'
                } elseif ($result.progress.translations_complete) {
                    $result.status = 'OCR_COMPLETE'
                } else {
                    $result.status = 'AWAITING_TRANSLATION'
                }
            } else {
                if ($childCode -ne 0) {
                    $result.status = 'FAILED'
                    $result.error = "Underlying Marker process exited with code $childCode. Inspect node-execution.log and pipeline.log."
                    $script:ExitCode = 10
                } elseif ((Test-Path -LiteralPath $result.conversion_report -PathType Leaf) -and (Test-Path -LiteralPath $result.output_markdown -PathType Leaf)) {
                    $result.status = 'SUCCESS'
                } else {
                    $result.status = 'FAILED'
                    $result.error = 'Merge did not create both the final Markdown and conversion-report.json.'
                    $script:ExitCode = 21
                }
            }
        }
    }
} catch {
    if (-not $result) { $result = New-BaseResult -ResolvedEngine $resolvedEngine -ResolvedPdf $resolvedPdf -ResolvedOutput $resolvedOutput }
    if ($result.status -eq 'RUNNING') { $result.status = 'FAILED' }
    if (-not $result.error) { $result.error = $_.Exception.Message }
    if ($script:ExitCode -eq 0) { $script:ExitCode = 2 }
} finally {
    if ($script:LockStream) {
        $script:LockStream.Dispose()
        $script:LockStream = $null
        Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue
    }
}

$result.exit_code = $script:ExitCode
$result.finished_at = (Get-Date).ToString('o')
$result.duration_seconds = [Math]::Round(((Get-Date) - $script:StartedAt).TotalSeconds, 3)

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    if ($resolvedOutput) { $ResultPath = Join-Path $resolvedOutput 'node-result.json' }
    else { $ResultPath = Join-Path $PSScriptRoot 'node-check-result.json' }
}
$ResultPath = [IO.Path]::GetFullPath((Normalize-PathInput $ResultPath))
$jsonOutput = Write-JsonAtomic -Path $ResultPath -Value $result
[Console]::Out.WriteLine($jsonOutput)
exit $script:ExitCode
