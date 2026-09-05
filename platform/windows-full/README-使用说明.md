# Marker OCR 便携包

这是一个面向 Windows 10/11 x64 的离线 PDF 分块 OCR 工具包。包内已经包含 PowerShell 7、Python 3.13.5、Marker 2.0.0（CPU）、pypdfium2、llama-server、Surya OCR GGUF 模型、版面模型和 OCR 错误检测模型。

## 使用前检查

双击 `Check-Environment.bat`。只有看到“环境检查通过”后再开始转换。

## 开始 OCR

可以把 PDF 直接拖到 `Start-OCR.bat` 上，也可以双击它，再把 PDF 拖进打开的窗口。

未指定输出目录时，结果保存到：

```text
本便携包\outputs\PDF文件名_时间戳\
```

程序会按默认每 16 页一个分块生成英文 OCR Markdown：

```text
输出目录\chunks\chunk_000_015\PDF文件名\PDF文件名_en.md
```

已有的非空 `*_en.md` 会作为断点保留。中断后用相同 PDF 和相同输出目录重新运行即可继续，不要同时启动多个转换窗口。

## 翻译和最终合并

OCR 与翻译是两个独立阶段。OCR 完成后，把每个：

```text
PDF文件名_en.md
```

翻译为同目录下的：

```text
PDF文件名.md
```

所有分块翻译完成后，双击 `Finish-Merge.bat`，依次拖入原始 PDF 和本次输出目录。程序会按页码顺序合并、修正图片相对路径、保守清理 Markdown、运行验证，并生成最终 Markdown 与 `conversion-report.json`。

## 迁移到另一台电脑

请复制或压缩整个 `Marker-OCR-Portable` 文件夹，不能只复制脚本或模型。解压后不要改变包内部的目录结构。建议放在本地磁盘中路径较短的位置，例如：

```text
D:\Marker-OCR-Portable
```

本包不要求目标电脑预装 Python、Marker 或 PowerShell 7，也不需要首次联网下载 OCR 模型。目标电脑仍需满足：

- Windows 10/11 x64；
- 足够的内存和磁盘空间；
- CPU 支持当前 Windows x64 运行环境；
- 对便携包和输出目录具有写权限。

当前随包的 PyTorch 是 CPU 版本，因此不依赖 CUDA，但扫描书籍 OCR 可能耗时较长。

双击入口默认使用 `fast`、1 个 OCR worker 和 16384 上下文，以提高不同电脑上的兼容性。熟悉命令行的用户可以通过 `Start-OCR.ps1` 参数调整 `ChunkSize`、`Mode`、`OcrWorkers` 和 `OcrCtxSize`。

## 日志和状态

- `pipeline.log`：主运行日志；
- `chunk-status.jsonl`：每个分块的检查点状态；
- `marker.stdout.log`、`marker.stderr.log`：分块级 Marker 日志；
- `conversion-report.json`：最终转换与验证报告。

若运行失败，先查看 `pipeline.log` 和对应 chunk 的 `marker.stderr.log`。
