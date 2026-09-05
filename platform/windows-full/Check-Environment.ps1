$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$required = [ordered]@{
    'Portable PowerShell' = Join-Path $root 'runtime\pwsh\pwsh.exe'
    'Portable Python' = Join-Path $root 'runtime\python\python.exe'
    'Marker entry' = Join-Path $root 'scripts\marker_single_entry.py'
    'Pipeline' = Join-Path $root 'pipeline.ps1'
    'llama-server' = Join-Path $root 'llama.cpp-b9627\bin\llama-server.exe'
    'Surya model' = Join-Path $root 'surya-ocr-2-gguf\surya-2.gguf'
    'Surya mmproj' = Join-Path $root 'surya-ocr-2-gguf\surya-2-mmproj.gguf'
    'Fast layout model' = Join-Path $root 'model-cache\huggingface\hub\models--datalab-to--surya_layout2\refs\main'
    'OCR error model' = Join-Path $root 'model-cache\datalab-models\ocr_error_detection\2025_02_18\model.safetensors'
    'Cleanup script' = Join-Path $root 'scripts\clean_markdown.py'
    'Validation script' = Join-Path $root 'scripts\validate_markdown.py'
}

$failed = $false
foreach ($item in $required.GetEnumerator()) {
    $ok = Test-Path -LiteralPath $item.Value -PathType Leaf
    if (-not $ok) { $failed = $true }
    [pscustomobject]@{ Item = $item.Key; Status = if ($ok) { 'OK' } else { 'MISSING' }; Path = $item.Value }
}

if (-not $failed) {
    $python = $required['Portable Python']
    & $python -c "import importlib.metadata as m, pypdfium2, torch; from marker.scripts.convert_single import convert_single_cli; print('Python/Marker imports: OK'); print('marker-pdf='+m.version('marker-pdf')); print('pypdfium2='+m.version('pypdfium2')); print('torch='+torch.__version__)"
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

if ($failed) { throw '便携包环境检查失败，请查看上面的 MISSING 或 Python 导入错误。' }
Write-Host "`n环境检查通过，可以运行 Start-OCR.bat。" -ForegroundColor Green
