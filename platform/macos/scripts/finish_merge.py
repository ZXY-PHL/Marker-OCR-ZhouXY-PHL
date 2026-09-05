#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from path_input import normalize_dragged_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Merge translated chunks")
    parser.add_argument("pdf_path", nargs="?")
    parser.add_argument("output_root", nargs="?")
    parser.add_argument("--output-name", default="output.md")
    parser.add_argument("--chunk-size", type=int, default=16)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    bundle = Path(__file__).resolve().parent.parent
    pdf_value = args.pdf_path or input("请拖入原始 PDF，然后按 Return：\n> ")
    output_value = args.output_root or input("请拖入本次 OCR 的输出文件夹，然后按 Return：\n> ")
    pdf = Path(normalize_dragged_path(pdf_value)).expanduser().resolve()
    output = Path(normalize_dragged_path(output_value)).expanduser().resolve()
    command = [
        sys.executable,
        str(bundle / "scripts" / "pipeline_macos.py"),
        "--pdf-path",
        str(pdf),
        "--output-root",
        str(output),
        "--output-name",
        args.output_name,
        "--chunk-size",
        str(args.chunk_size),
        "--bundle-root",
        str(bundle),
        "--skip-chunking",
    ]
    if args.overwrite:
        command.append("--overwrite")
    result = subprocess.run(command)
    if result.returncode == 0:
        print(f"合并、清理和验证完成：{output / args.output_name}")
    input("按 Return 关闭窗口……")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
