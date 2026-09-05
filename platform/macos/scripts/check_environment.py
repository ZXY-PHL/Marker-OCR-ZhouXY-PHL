#!/usr/bin/env python3
from __future__ import annotations

import importlib.metadata
import os
import platform
import shutil
import sys
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    checks: list[tuple[str, bool, str]] = []
    checks.append(("macOS", sys.platform == "darwin", sys.platform))
    checks.append(("Architecture", platform.machine() in {"arm64", "x86_64"}, platform.machine()))
    checks.append(("Python", sys.version_info >= (3, 10), sys.version.split()[0]))
    checks.append(("marker_single", (root / ".venv-marker" / "bin" / "marker_single").is_file(), str(root / ".venv-marker" / "bin" / "marker_single")))
    llama = shutil.which("llama-server")
    checks.append(("llama-server", bool(llama), llama or "not found"))
    required_files = {
        "Surya GGUF": root / "surya-ocr-2-gguf" / "surya-2.gguf",
        "Surya mmproj": root / "surya-ocr-2-gguf" / "surya-2-mmproj.gguf",
        "Fast layout model": root / "model-cache" / "huggingface" / "hub" / "models--datalab-to--surya_layout2" / "refs" / "main",
        "OCR error model": root / "model-cache" / "datalab-models" / "ocr_error_detection" / "2025_02_18" / "model.safetensors",
        "Cleanup script": root / "scripts" / "clean_markdown.py",
        "Validation script": root / "scripts" / "validate_markdown.py",
    }
    checks.extend((name, path.is_file(), str(path)) for name, path in required_files.items())
    try:
        import pypdfium2  # noqa: F401
        import torch
        from marker.scripts.convert_single import convert_single_cli  # noqa: F401

        marker_version = importlib.metadata.version("marker-pdf")
        checks.append(("Marker import", marker_version == "2.0.0", marker_version))
        checks.append(("PyTorch import", True, f"{torch.__version__}; mps={torch.backends.mps.is_available()}"))
        checks.append(("pypdfium2", True, importlib.metadata.version("pypdfium2")))
    except Exception as exc:
        checks.append(("Python imports", False, str(exc)))
    width = max(len(name) for name, _, _ in checks)
    for name, ok, detail in checks:
        print(f"{name:<{width}}  {'OK' if ok else 'FAIL':<4}  {detail}")
    failed = [name for name, ok, _ in checks if not ok]
    if failed:
        print("\n环境检查失败：" + ", ".join(failed), file=sys.stderr)
        return 1
    print("\n环境检查通过，可以运行 start_ocr.command。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
