# Marker OCR 双电脑源码同步

Git 仓库只保存 `Marker-OCR-Source` 的源码、工具和文档。不要将模型、Python/虚拟环境、OCR 输出、日志或发行压缩包加入 Git。

## 首次在 Mac 准备

将 `Marker-OCR-macOS` 完整包解压到本地磁盘。然后在同一父目录克隆源码：

```bash
mkdir -p ~/Marker-OCR
cd ~/Marker-OCR
git clone https://github.com/ZXY-PHL/Marker-OCR-ZhouXY-PHL.git Marker-OCR-Source
```

目录必须是：

```text
~/Marker-OCR/
├─ Marker-OCR-Source/
└─ Marker-OCR-macOS/
```

第一次或每次源码更新后，先查看将会同步哪些文件：

```bash
cd ~/Marker-OCR/Marker-OCR-Source
python3 tools/sync-macos.py --dry-run
```

确认后同步 macOS 适配层和共享代码。该命令不会动模型、`.venv-marker`、输出或日志：

```bash
python3 tools/sync-macos.py
cd ../Marker-OCR-macOS
./check_environment.command
```

## 日常修改流程

开始修改前，在当前电脑执行：

```bash
git pull --ff-only
```

Mac 修改后，先同步到本机 macOS 包并完成环境检查和一份短 PDF 的真实 OCR。确认后提交：

```bash
cd ~/Marker-OCR/Marker-OCR-Source
git add .
git commit -m "Describe the macOS fix"
git push
```

Windows 拉取 Mac 提交后，运行统一构建和验证：

```powershell
cd "D:\学习使我快乐\林组\翻译\ai学习资料\Marker-OCR-Source"
git pull --ff-only
.\Update-All.ps1
```

Windows 修改后同样提交和推送；Mac 再执行 `git pull --ff-only` 与 `python3 tools/sync-macos.py`。

## 冲突或未提交修改

`git pull --ff-only` 若失败，不要强行覆盖。先检查：

```bash
git status
git diff
```

将本机修改提交后再拉取；如两台电脑修改了同一文件，解决冲突、重新测试后再提交。不要长期直接修改 `Marker-OCR-Portable`、`Marker-OCR-macOS` 或 `Marker-OCR-Portable-Lite` 中的脚本；修改应回到 `Marker-OCR-Source`。
