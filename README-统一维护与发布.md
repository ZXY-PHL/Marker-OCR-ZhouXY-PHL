# Marker OCR 跨平台统一工具

## 1. 解决的问题

本目录是 Marker OCR 的统一产品源码。用户面对同一个产品、统一命令和一致的处理流程；Windows 与 macOS 仍分别携带原生运行时并生成各自的发行包。以后不要直接把成品包作为主要开发位置；在本目录中修改，然后运行一次构建命令，三个成品目录会一起更新并接受一致性检查。

```text
Marker-OCR-Source/
├─ app/                    统一入口和后续跨平台应用层
├─ shared/                 各平台复用的核心代码
├─ platform/
│  ├─ windows-full/        Windows 完整版适配层
│  ├─ macos/               macOS 适配层
│  └─ windows-lite/        Windows 自动化节点适配层
├─ models/                 共用模型的路径和校验契约（不重复存放大文件）
├─ tools/                  同步、验证、构建和发布工具
├─ Start-Marker-OCR.bat    Windows 统一入口
└─ Start-Marker-OCR.command macOS 统一入口
```

模型、Python、PyTorch、PowerShell 和 llama.cpp 等大文件仍保留在对应平台成品包中，不重复复制进源码目录。这样能够共享源码和产品体验，同时避免把 Windows DLL/EXE 与 macOS 原生二进制混装。

## 2. 统一使用入口

Windows 双击 `Start-Marker-OCR.bat`，macOS 双击 `Start-Marker-OCR.command`。入口会自动识别当前系统并路由到相邻的 `Marker-OCR-Portable` 或 `Marker-OCR-macOS` 成品目录。

也可以在终端使用动作参数：

```text
Start-Marker-OCR.bat start
Start-Marker-OCR.bat check
Start-Marker-OCR.bat finish

./Start-Marker-OCR.command start
./Start-Marker-OCR.command check
./Start-Marker-OCR.command finish
```

`--show-platform` 只显示当前路由结果，不启动 OCR，适合安装后自检。

Windows 与 Mac 的 Git 同步和本机 macOS 包同步步骤见 [docs/Git同步指南.md](docs/Git同步指南.md)。

## 3. 最常用维护命令

在 PowerShell 中进入：

```powershell
cd "D:\学习使我快乐\林组\翻译\ai学习资料\Marker-OCR-Source"
```

修改源码后同步并验证三个版本：

```powershell
.\Update-All.ps1
```

发布新版本并同时更新三个版本号：

```powershell
.\Publish-All.ps1 -Version 1.1.0
```

该命令依次执行：同步公共及平台代码、写入 `VERSION` 和 `release-metadata.json`、验证文件与依赖、生成三个完整归档、计算 SHA256、生成统一发行清单。

根目录的 `Update-All.ps1` 和 `Publish-All.ps1` 是最简入口；`tools` 中的脚本用于更细粒度控制。

## 4. 终端进度显示

同步、验证、归档和 SHA256 校验现在都会在终端显示进度条及百分比，例如：

```text
[################--------] 76%  windows-full: runtime/python/...
```

完整发布时还会显示已处理容量：

```text
Creating release archives: [############--------------------] 38.42%  1.9 GB/4.9 GB
SHA256 windows-full:        [###################-------------] 61.08%  1.2 GB/1.9 GB
```

进度阶段包括：

1. 同步三个版本；
2. 验证源码、版本、依赖和模型；
3. 创建 Windows ZIP、macOS tar.gz 和轻量版 ZIP；
4. 分别计算归档的 SHA256。

如果输出被自动化平台重定向到日志，工具不会反复写同一行，而是每增加约 5% 或 10% 输出一条带百分比的里程碑记录。

## 5. 日常开发流程

### 修改三个版本共用的 Markdown 清理或验证逻辑

修改：

```text
shared/scripts/clean_markdown.py
shared/scripts/validate_markdown.py
```

然后运行：

```powershell
.\tools\build-all.ps1
```

工具会同步到 Windows 完整版和 macOS 版。轻量版不重复携带这些代码，而是在运行时调用完整版引擎，因此会自动使用完整版的更新。

### 修改某个平台专属逻辑

分别修改：

```text
platform/windows-full/
platform/macos/
platform/windows-lite/
```

仍然运行 `build-all.ps1`。工具会更新对应版本，并验证其他版本没有发生公共代码漂移。

### 持续监听源码并自动同步

```powershell
.\tools\watch-source.ps1
```

该进程会监听 `src`。保存文件后，它会自动同步并执行验证。按 Ctrl+C 停止。

## 6. 各工具用途

| 工具 | 用途 |
|---|---|
| `initialize-source.ps1` | 首次从现有三个成品包迁移代码；通常不再重复运行 |
| `sync-all.ps1` | 将统一源码同步到成品目录，并写版本元数据 |
| `verify-all.ps1` | 检查哈希一致性、必需模型、版本、PowerShell 语法和 macOS 换行符 |
| `build-all.ps1` | 依次执行同步和验证，日常最常用 |
| `watch-source.ps1` | 监听源码变更并自动执行构建 |
| `release-all.ps1` | 构建、验证、归档、SHA256 和发行清单 |
| `archive_release.py` | 创建 ZIP 和保留 macOS 执行权限的 tar.gz |

## 7. 只操作某一个目标

允许的目标为：`windows-full`、`macos`、`windows-lite`、`all`。

```powershell
.\tools\build-all.ps1 -Target windows-lite
.\tools\verify-all.ps1 -Target macos
```

即使只构建一个目标，公共源码仍是唯一基准。正式发布建议始终使用 `all`。

## 8. 完整包与代码更新包

默认发布完整包：

```powershell
.\tools\release-all.ps1 -Version 1.1.0 -ArchiveMode Full
```

完整包包含对应系统运行环境和模型，体积很大。如果目标电脑已经有相同版本的运行环境，只需生成代码更新包：

```powershell
.\tools\release-all.ps1 -Version 1.1.0 -ArchiveMode CodeOnly
```

代码更新包文件名包含 `code-overlay`，不能在空电脑上独立运行，只能覆盖到兼容的现有完整版目录。覆盖前建议备份，并在覆盖后执行环境检查。

## 9. 版本与发行产物

版本号保存在 `release-manifest.json`。传入 `-Version` 时会同时更新：

- 统一发行清单中的版本；
- 轻量版节点契约版本；
- 三个成品目录中的 `VERSION`；
- 三个成品目录中的 `release-metadata.json`。

默认发行目录按版本和归档模式分开：

```text
Marker-OCR-Source/releases/版本号/full/
Marker-OCR-Source/releases/版本号/code-only/
```

其中包括归档、对应 `.sha256` 文件以及 `release-artifacts.json`。

## 10. 验证失败时

不要强行发布。查看 `reports/verification-时间.json` 中的失败项：

- `shared-sync` 或 `target-sync`：成品文件与统一源码不一致，重新运行 `sync-all.ps1`；
- `required-asset`：运行环境或模型缺失；
- `powershell-parse`：PowerShell 脚本语法错误；
- `line-endings`：macOS `.command` 文件出现 CRLF；
- `contract-version`：轻量节点契约与统一版本不一致。

只有验证结果为 `PASS` 时，`release-all.ps1` 才会创建发行归档。

## 11. 平台边界

Windows 不能验证 macOS 原生 Homebrew、PyTorch 和 llama.cpp 的实际运行。因此统一工具可以在 Windows 上同步 macOS 代码、检查结构、换行符、Python 语法并生成 tar.gz，但正式 macOS 发行仍应在目标 Mac 上运行环境检查和一份真实 PDF 的端到端验收。
