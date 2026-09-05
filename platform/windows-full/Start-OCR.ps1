[CmdletBinding()]
param(
    [string]$PdfPath,
    [string]$OutputRoot,
    [string]$OutputName = 'output.md',
    [int]$ChunkSize = 16,
    [ValidateSet('fast', 'balanced')]
    [string]$Mode = 'fast',
    [int]$OcrWorkers = 1,
    [int]$OcrCtxSize = 16384
)

$ErrorActionPreference = 'Stop'
$bundleRoot = $PSScriptRoot

function Normalize-DraggedPath([string]$Value) {
    if (-not $Value) { return $Value }
    $result = $Value.Trim()
    if ($result.Length -ge 2 -and (($result.StartsWith('"') -and $result.EndsWith('"')) -or ($result.StartsWith("'") -and $result.EndsWith("'")))) {
        $result = $result.Substring(1, $result.Length - 2)
    }
    return $result
}

if (-not $PdfPath) {
    $PdfPath = Read-Host '请把待处理的 PDF 拖到此窗口，然后按 Enter'
}
$PdfPath = Normalize-DraggedPath $PdfPath
if (-not (Test-Path -LiteralPath $PdfPath -PathType Leaf) -or [IO.Path]::GetExtension($PdfPath) -ine '.pdf') {
    throw "PDF 文件不存在或扩展名不是 .pdf：$PdfPath"
}
$PdfPath = (Resolve-Path -LiteralPath $PdfPath).Path

if (-not $OutputRoot) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($PdfPath)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputRoot = Join-Path $bundleRoot "outputs\${stem}_${stamp}"
}
$OutputRoot = [IO.Path]::GetFullPath((Normalize-DraggedPath $OutputRoot))

Write-Host "PDF：$PdfPath" -ForegroundColor Cyan
Write-Host "输出：$OutputRoot" -ForegroundColor Cyan
& (Join-Path $bundleRoot 'run_until_done.ps1') -PdfPath $PdfPath -OutputRoot $OutputRoot -OutputName $OutputName -ChunkSize $ChunkSize -Mode $Mode -OcrWorkers $OcrWorkers -OcrCtxSize $OcrCtxSize -BaseDir $bundleRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "`n英文 OCR 分块已经完成。请翻译每个 *_en.md，完成后运行 Finish-Merge.bat。" -ForegroundColor Green
Write-Host "本次输出目录：$OutputRoot" -ForegroundColor Yellow
Read-Host '按 Enter 关闭窗口'
