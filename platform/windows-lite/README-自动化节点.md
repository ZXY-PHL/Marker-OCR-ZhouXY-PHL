# Marker-OCR-Portable-Lite（Windows 自动化节点）

## 定位

这是一个无交互、轻量的 Windows 自动化适配包。它不包含约 3.3 GB 的 Python、PyTorch、Marker、llama.cpp 和模型文件，而是复用现有的完整版 `Marker-OCR-Portable` 作为执行引擎。

本节点不会弹出输入窗口，不使用 `Read-Host`，也不要求双击文件。输入全部通过命令行参数传入；执行结果写入 JSON，并通过进程退出码通知工作流。

```text
自动化平台
  → Marker-OCR-Portable-Lite（参数、锁、JSON 契约）
  → Marker-OCR-Portable（Python、Marker、模型）
  → 输出目录（分块、日志、node-result.json）
```

## 目录摆放

推荐将轻量节点和完整版放在同一父目录：

```text
D:\OCR\
├─ Marker-OCR-Portable\
└─ Marker-OCR-Portable-Lite\
```

此时无需指定引擎位置。也可以把完整版放在其他位置，并采用以下任一方式：

```powershell
# 每次调用时指定
-EngineRoot "D:\Tools\Marker-OCR-Portable"

# 或为自动化服务账户设置环境变量
$env:MARKER_OCR_ENGINE_ROOT = 'D:\Tools\Marker-OCR-Portable'
```

引擎查找顺序为：`-EngineRoot` → `MARKER_OCR_ENGINE_ROOT` → 同级完整版目录。

## 1. 工作流部署时检查环境

```powershell
& "D:\OCR\Marker-OCR-Portable-Lite\run-node.cmd" `
  -Action Check `
  -EngineRoot "D:\OCR\Marker-OCR-Portable"

if ($LASTEXITCODE -ne 0) { throw 'Marker OCR engine is not ready' }
```

结果写入轻量包内的 `node-check-result.json`。成功状态为 `READY`，退出码为 `0`。

## 2. OCR 节点

```powershell
$lite = 'D:\OCR\Marker-OCR-Portable-Lite\run-node.cmd'
$pdf = 'D:\workflow\input\book.pdf'
$out = 'D:\workflow\runs\job-20260815'

& $lite `
  -Action Ocr `
  -PdfPath $pdf `
  -OutputRoot $out `
  -ChunkSize 16 `
  -Mode fast `
  -OcrWorkers 1 `
  -OcrCtxSize 16384 `
  -MaxNoProgressRounds 3

if ($LASTEXITCODE -ne 0) { throw "OCR node failed: exit=$LASTEXITCODE" }
$result = Get-Content -Raw -LiteralPath (Join-Path $out 'node-result.json') | ConvertFrom-Json
if ($result.status -ne 'AWAITING_TRANSLATION' -and $result.status -ne 'SUCCESS') {
    throw "Unexpected OCR status: $($result.status)"
}
```

正常的纯 OCR 结束状态是 `AWAITING_TRANSLATION`，退出码仍为 `0`。这表示所有 `*_en.md` 已经生成并通过检查，工作流应进入翻译节点，而不是把它当成错误。

OCR 阶段不会覆盖非空的 `*_en.md` 检查点。使用相同 PDF、相同 `OutputRoot` 再次调用即可断点续跑。

节点默认最多运行 100 轮，但连续 3 轮没有新增 OCR 检查点时会提前失败，防止工作流无限空转。可通过 `-MaxRounds` 和 `-MaxNoProgressRounds` 调整；一般不建议增大无进展上限，应先检查日志。

## 3. 翻译节点约定

本包不负责翻译。下游翻译节点应将每个：

```text
chunks\chunk_xxx_xxx\PDF名称\PDF名称_en.md
```

翻译为同目录下的：

```text
chunks\chunk_xxx_xxx\PDF名称\PDF名称.md
```

不要覆盖或删除 `*_en.md`，不要改变 chunk 目录结构，并保留图片相对链接。

## 4. 合并节点

所有中文分块写入后调用：

```powershell
& "D:\OCR\Marker-OCR-Portable-Lite\run-node.cmd" `
  -Action Merge `
  -PdfPath "D:\workflow\input\book.pdf" `
  -OutputRoot "D:\workflow\runs\job-20260815" `
  -OutputName "book_zh.md" `
  -ChunkSize 16

if ($LASTEXITCODE -ne 0) { throw "Merge node failed: exit=$LASTEXITCODE" }
```

成功后状态为 `SUCCESS`，主要产物是：

- `<OutputRoot>\book_zh.md`；
- `<OutputRoot>\conversion-report.json`；
- `<OutputRoot>\node-result.json`。

默认拒绝覆盖已有最终 Markdown。只有工作流明确允许覆盖时才添加 `-Overwrite`。

## 5. 只查询状态

```powershell
& "D:\OCR\Marker-OCR-Portable-Lite\run-node.cmd" `
  -Action Status `
  -PdfPath "D:\workflow\input\book.pdf" `
  -OutputRoot "D:\workflow\runs\job-20260815" `
  -ChunkSize 16
```

`Status` 不执行 OCR 或合并，只统计磁盘上的检查点。若不提供 `PdfPath`，仍可统计现有文件，但无法计算预期 chunk 总数。

## 6. Python 工作流调用示例

```python
import json
import subprocess
from pathlib import Path

lite = Path(r"D:\OCR\Marker-OCR-Portable-Lite\run-node.cmd")
pdf = Path(r"D:\workflow\input\book.pdf")
out = Path(r"D:\workflow\runs\job-20260815")

completed = subprocess.run(
    [str(lite), "-Action", "Ocr", "-PdfPath", str(pdf), "-OutputRoot", str(out)],
    check=False,
)
result = json.loads((out / "node-result.json").read_text(encoding="utf-8"))
if completed.returncode != 0:
    raise RuntimeError(result)
if result["status"] == "AWAITING_TRANSLATION":
    print("Send *_en.md files to the translation node")
```

## 7. JSON 结果字段

每次调用都会原子写入 `node-result.json`：

```json
{
  "schema_version": "1.0",
  "action": "OCR",
  "status": "AWAITING_TRANSLATION",
  "exit_code": 0,
  "pdf_path": "D:\\workflow\\input\\book.pdf",
  "output_root": "D:\\workflow\\runs\\job-20260815",
  "output_markdown": "D:\\workflow\\runs\\job-20260815\\output.md",
  "conversion_report": "D:\\workflow\\runs\\job-20260815\\conversion-report.json",
  "pipeline_log": "D:\\workflow\\runs\\job-20260815\\pipeline.log",
  "execution_log": "D:\\workflow\\runs\\job-20260815\\node-execution.log",
  "progress": {
    "page_count": 254,
    "expected_chunks": 16,
    "ocr_chunks": 16,
    "translated_chunks": 0,
    "ocr_complete": true,
    "translations_complete": false
  },
  "error": null
}
```

自动化平台应同时检查退出码和 `status`，不要只依赖终端最后一行。

## 8. 退出码

| 退出码 | 含义 |
|---:|---|
| `0` | 当前 Action 正常结束；具体阶段见 `status` |
| `2` | 参数、路径或包装器异常 |
| `3` | 完整版引擎缺少依赖 |
| `10` | 底层 Marker 流程失败 |
| `20` | OCR 退出但预期检查点不完整 |
| `21` | 合并后未生成最终文件和报告 |
| `30` | 同一个输出目录已有节点占用 |

## 9. 日志和并发规则

- `node-execution.log`：轻量节点捕获的底层控制台输出；
- `pipeline.log`：底层 OCR 主日志；
- `chunk-status.jsonl`：分块状态和检查点；
- `marker.stdout.log`、`marker.stderr.log`：具体 chunk 的 Marker 日志。

同一个 `OutputRoot` 同时只允许一个 OCR 或合并任务；节点使用 `.marker-ocr-node.lock` 防止冲突。不同输出目录可以分别排队运行，但 CPU 版 OCR 很重，不建议在同一台机器上并行多个长篇任务。

`Ocr` 动作不接受 `-Overwrite`；已有的非空检查点始终保留。`-Overwrite` 只用于明确授权替换最终 Markdown 的 `Merge` 动作。

## 10. 工作流建议

推荐状态流：

```text
Check(READY)
→ Ocr(AWAITING_TRANSLATION)
→ 翻译所有 *_en.md
→ Merge(SUCCESS)
→ 检查 conversion-report.json
```

源 PDF 不会被修改。任务完成前应保留整个输出目录，不能只取走最终 `.md`，否则图片资源和质量报告可能丢失。
