[CmdletBinding()]
param(
    [string]$PdfPath,
    [string]$OutputRoot,
    [string]$OutputName = 'output.md',
    [int]$ChunkSize = 16
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

if (-not $PdfPath) { $PdfPath = Read-Host '请拖入原始 PDF，然后按 Enter' }
if (-not $OutputRoot) { $OutputRoot = Read-Host '请拖入本次 OCR 的输出文件夹，然后按 Enter' }
$PdfPath = Normalize-DraggedPath $PdfPath
$OutputRoot = Normalize-DraggedPath $OutputRoot

& (Join-Path $bundleRoot 'pipeline.ps1') -PdfPath $PdfPath -OutputRoot $OutputRoot -OutputName $OutputName -ChunkSize $ChunkSize -SkipChunking -BaseDir $bundleRoot
$code = $LASTEXITCODE
if ($code -eq 0) {
    Write-Host "`n合并、清理和验证已经完成：$(Join-Path $OutputRoot $OutputName)" -ForegroundColor Green
}
Read-Host '按 Enter 关闭窗口'
exit $code
