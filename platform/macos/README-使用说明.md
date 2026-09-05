# Marker OCR macOS 版——使用说明

## 1. 这个包是做什么的

本包用于在 macOS 上把 PDF 分块转换为结构化 Markdown，并支持中断后继续运行。它会尽量保留标题、段落、表格、公式、图片及其相对路径。

完整工作流程是：

```text
PDF → 分块 OCR → 生成英文 Markdown（*_en.md）
    → 人工或其他工具翻译 → 生成同目录中文 Markdown（*.md）
    → 检查并合并 → 最终 Markdown + 质量报告
```

注意：本包负责 OCR、检查点管理和最终合并，**不会自动完成英译中**。OCR 完成后会停在 `AWAITING_TRANSLATION`，等待中文 Markdown 文件。

## 2. 适用系统和硬件

- 建议使用 macOS Sonoma 14 或更新版本。
- 同时支持 Apple Silicon（M1/M2/M3/M4 等，arm64）和 Intel Mac（x86_64）。
- 建议至少预留 20 GB 可用磁盘空间；长篇书籍可能需要更多。
- 建议接通电源，并暂时关闭自动睡眠。
- 首次安装 Python 包时需要联网；包内已经包含主要 OCR、版面和错误检测模型，安装完成后的模型推理可离线运行。

Python、PyTorch、Marker 和 llama.cpp 必须安装 macOS 原生版本，Windows 中的虚拟环境或可执行文件不能直接复制到 macOS 使用。

## 3. 包内主要文件

| 文件或目录 | 用途 |
|---|---|
| `setup_macos.command` | 首次安装或修复本包的 Python 运行环境 |
| `check_environment.command` | 检查 Python、Marker、模型及 `llama-server` 是否可用 |
| `start_ocr.command` | 开始 OCR，或从已有输出目录断点续跑 |
| `finish_merge.command` | 中文分块全部就绪后执行检查和最终合并 |
| `scripts/` | OCR、检查点、清理、验证和合并代码 |
| `models/` | 包内携带的模型文件 |
| `SHA256SUMS.txt` | 主要模型文件的完整性校验值 |
| `THIRD-PARTY-NOTICES.md` | 第三方软件和模型说明 |
| `outputs/` | 默认输出位置，首次运行时自动创建 |

请完整保留文件夹结构，不要只复制四个 `.command` 文件。

## 4. 传到另一台 Mac 后先做什么

建议将压缩包复制到本地磁盘后再解压，例如放在：

```text
~/Marker-OCR-macOS
```

不要直接在 U 盘、网盘同步目录或压缩包预览界面中运行。若同时收到 `.sha256` 文件，可先在终端进入压缩包所在目录并校验：

```bash
shasum -a 256 -c Marker-OCR-macOS.tar.gz.sha256
```

显示 `OK` 后再解压：

```bash
tar -xzf Marker-OCR-macOS.tar.gz
cd Marker-OCR-macOS
```

然后校验包内主要模型：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

所有项目应显示 `OK`。

## 5. 首次安装

### 方法 A：双击安装

1. 双击 `setup_macos.command`。
2. 如果出现系统安全提示，右键该文件，选择“打开”，再确认运行。
3. 等待安装完成，不要关闭终端窗口。
4. 双击 `check_environment.command` 做环境检查。

安装程序会优先使用现有的 Python 3.12 和 `llama-server`。如果缺少依赖，会尝试通过 Homebrew 安装，并在本包内建立 `.venv-marker` 虚拟环境，然后安装 Marker 2.0.0。

### 方法 B：终端安装

打开“终端”，进入本包目录：

```bash
cd ~/Marker-OCR-macOS
./setup_macos.command
./check_environment.command
```

如果电脑尚未安装 Homebrew，先按 <https://brew.sh/> 的官方说明安装，再重新运行 `setup_macos.command`。

## 6. 如果电脑已经装好了依赖

仍建议先运行：

```bash
cd ~/Marker-OCR-macOS
./check_environment.command
```

若环境检查全部通过，可直接运行 OCR，不必重复安装：

```bash
./start_ocr.command "/Users/你的用户名/Documents/book.pdf"
```

若检查提示本包内没有 `.venv-marker`，运行一次：

```bash
./setup_macos.command
```

它会复用可用的系统依赖，并为本包建立独立虚拟环境。这样不会要求你删除原有 Python 环境，也不建议手工把其他电脑的 `.venv-marker` 复制过来。

## 7. macOS 阻止脚本运行时

先尝试右键 `.command` 文件并选择“打开”。如果仍提示无法验证开发者或没有执行权限，在终端进入本包目录后执行：

```bash
xattr -dr com.apple.quarantine .
chmod +x *.command scripts/*.py
```

然后重新运行环境检查：

```bash
./check_environment.command
```

只应对你确认来自可信来源的本包执行上述 `xattr` 命令。

## 8. 开始 OCR

### 最简单的方式

1. 双击 `start_ocr.command`。
2. 将待处理 PDF 拖到终端窗口中，按 Return。
3. 第二次询问输出目录时：
   - 直接按 Return：自动创建新的时间戳输出目录；
   - 拖入以前的输出目录：从现有检查点继续运行。

默认输出目录为：

```text
Marker-OCR-macOS/outputs/PDF名称_时间戳/
```

### 使用终端

自动创建输出目录：

```bash
./start_ocr.command "/Users/你的用户名/Documents/book.pdf"
```

指定输出目录：

```bash
./start_ocr.command "/Users/你的用户名/Documents/book.pdf" \
  --output-root "/Users/你的用户名/Documents/book-run"
```

常用可选参数：

```bash
./start_ocr.command "/path/book.pdf" \
  --output-root "/path/book-run" \
  --chunk-size 16 \
  --mode fast \
  --ocr-workers 1 \
  --ocr-ctx-size 16384
```

默认值就是每 16 页一块、`fast` 模式、1 个 OCR worker 和 16384 上下文。第一次使用时建议保持默认值，以降低内存压力。

路径中含空格或中文时，请保留英文双引号。也可以直接把文件拖到终端，macOS 会自动填入路径。

## 9. 怎样判断 OCR 是否完成

运行中请查看输出目录中的：

- `pipeline.log`：整个流程的主日志；
- `chunk-status.jsonl`：每个分块的检查点和阶段状态；
- 各 chunk 内的 `marker.stdout.log`、`marker.stderr.log`：Marker 详细日志。

成功的英文分块通常位于：

```text
输出目录/chunks/chunk_000_015/PDF名称/PDF名称_en.md
```

页码范围会随 chunk 改变。所有 OCR 分块完成后，状态会变为：

```text
AWAITING_TRANSLATION
```

这表示 OCR 已完成，正在等待翻译，不是程序故障。

## 10. 中断后怎样继续

关机、断电或手动停止后，重新运行同一个 PDF，并指定**原来的输出目录**：

```bash
./start_ocr.command "/path/book.pdf" --output-root "/path/原输出目录"
```

程序会重新核对检查点，保留已经生成且非空的 `*_en.md`，再继续缺失的分块。不要删除或重命名 `chunks`、`chunk-status.jsonl` 和已有的分块目录。

为避免状态冲突，同一个 PDF 和同一个输出目录不要同时启动两个 OCR 进程。

如果连续三轮失败且没有生成新检查点，程序会停止，避免无限重试。此时先查看失败 chunk 的 `marker.stderr.log`，解决问题后再用相同输出目录继续。

## 11. 翻译文件应怎样放置

OCR 生成的英文文件名带 `_en`：

```text
PDF名称_en.md
```

请将它翻译成简体中文，并保存在**同一个目录**，文件名去掉 `_en`：

```text
PDF名称.md
```

例如：

```text
book_en.md   ← OCR 英文原稿，保留不要覆盖
book.md      ← 对应的中文译稿
```

翻译时请注意：

- 不要覆盖或删除 `*_en.md`；
- 不要改变 chunk 文件夹结构；
- 保留 Markdown 标题层级、表格、公式、引用和图片链接；
- 不要把多个 chunk 提前手工合并；
- 每个非空 `*_en.md` 都必须有一个同目录、同主文件名的 `.md` 中文文件。

## 12. 完成检查和最终合并

所有中文分块准备好后：

1. 双击 `finish_merge.command`。
2. 按提示拖入原始 PDF，按 Return。
3. 拖入本次 OCR 的输出目录，按 Return。

也可在终端运行：

```bash
./finish_merge.command "/path/book.pdf" "/path/book-run"
```

程序会检查翻译文件是否齐全，按页序合并，调整图片相对路径，保守清理 Markdown，并生成：

```text
输出目录/output.md
输出目录/conversion-report.json
```

若要指定最终文件名：

```bash
./finish_merge.command "/path/book.pdf" "/path/book-run" \
  --output-name "book_中文.md"
```

如果目标 Markdown 已存在，程序默认拒绝覆盖。确认旧文件不再需要后，才使用：

```bash
./.venv-marker/bin/python scripts/finish_merge.py "/path/book.pdf" "/path/book-run" \
  --output-name "output.md" --overwrite
```

## 13. 输出结果验收

合并结束后至少检查以下内容：

1. `conversion-report.json` 中没有未处理的缺失分块或失败状态；
2. 打开最终 Markdown，确认开头、中间、结尾都存在；
3. 随机检查数个标题、表格、公式和图片；
4. 确认图片相对链接在 Markdown 阅读器中可以打开；
5. 保留整个输出目录，直到最终文档验收完成。

## 14. 常见问题

### 双击后窗口立即关闭

不要继续双击。打开“终端”，进入本包目录后运行相同命令，这样可以看到错误信息：

```bash
cd ~/Marker-OCR-macOS
./check_environment.command
```

### 提示 `command not found: python3.12` 或找不到虚拟环境

运行：

```bash
./setup_macos.command
```

如果提示找不到 Homebrew，先安装 Homebrew 后再运行安装脚本。

### 提示找不到 `llama-server`

先运行 `setup_macos.command`。若仍失败，可在 Homebrew 可用后执行：

```bash
brew install llama.cpp
./check_environment.command
```

### OCR 很慢

长篇 PDF 的 OCR 本来就可能持续数小时。保持默认 `fast`、1 worker，接通电源并防止电脑睡眠。不要因为日志短时间没有刷新就立即重复启动第二个进程。

### 某个 chunk 反复失败

查看该 chunk 目录中的 `marker.stderr.log`，同时检查剩余磁盘空间。解决问题后用原 PDF 和原输出目录断点续跑。连续三轮无进展时程序会主动停止。

### 合并时提示缺少翻译

检查每个 `*_en.md` 的同目录下是否都有对应的 `.md`，并确认中文文件非空、文件名完全一致，仅去掉了 `_en`。

### 最终文件已存在

这是防止误覆盖的保护。优先更换 `--output-name`；只有确认需要替换时才使用 `--overwrite`。

### 磁盘空间不足

停止当前任务，释放空间后使用原输出目录继续。不要为了腾空间而删除已经成功的 chunk、模型文件或状态文件。

## 15. 数据和运行安全

- 源 PDF 不会被修改。
- 已验证的 OCR 检查点默认不会被覆盖。
- 最终 Markdown 默认不会覆盖同名旧文件。
- 本地 OCR 模型推理不要求把 PDF 上传到云端；但你另行使用的翻译工具是否上传内容，取决于该工具本身。
- 任务未验收前，建议同时保留原 PDF、整个输出目录和最终 Markdown。

## 16. 当前版本的验证边界

本包是在 Windows 工作区内生成和归档的，已经完成代码、路径、模型校验清单和归档结构检查，但无法在该环境中实际运行 macOS 原生的 Homebrew、Python、PyTorch 和 llama.cpp。

因此，在一台新 Mac 上首次使用时，请按以下顺序验收：

```text
校验压缩包 → 解压 → setup_macos.command
→ check_environment.command → 用短 PDF 做一次真实 OCR
→ 检查 *_en.md → 准备对应中文 .md → finish_merge.command
```

环境检查和一份真实 PDF 全流程成功后，才能认为该 Mac 已通过端到端验证。
