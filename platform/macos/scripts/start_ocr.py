#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from path_input import normalize_dragged_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Start resumable OCR")
    parser.add_argument("pdf_path", nargs="?")
    parser.add_argument("--output-root")
    parser.add_argument("--output-name", default="output.md")
    parser.add_argument("--chunk-size", type=int, default=16)
    parser.add_argument("--mode", choices=("fast", "balanced"), default="fast")
    parser.add_argument("--ocr-workers", type=int, default=1)
    parser.add_argument("--ocr-ctx-size", type=int, default=16384)
    args = parser.parse_args()
    bundle = Path(__file__).resolve().parent.parent
    interactive = args.pdf_path is None
    entered = args.pdf_path or input("请把待处理 PDF 拖到此窗口，然后按 Return：\n> ")
    pdf = Path(normalize_dragged_path(entered)).expanduser().resolve()
    if not pdf.is_file() or pdf.suffix.lower() != ".pdf":
        print(f"PDF 不存在或扩展名不正确：{pdf}", file=sys.stderr)
        return 1
    default_output = bundle / "outputs" / f"{pdf.stem}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    output_value = args.output_root
    if interactive and not output_value:
        output_value = input(
            "如需断点续跑，请拖入已有输出文件夹；直接按 Return 则新建默认目录：\n"
            f"{default_output}\n> "
        )
    output = Path(normalize_dragged_path(output_value)).expanduser().resolve() if output_value else default_output
    command = [
        sys.executable,
        str(bundle / "scripts" / "run_until_done.py"),
        "--pdf-path",
        str(pdf),
        "--output-root",
        str(output),
        "--output-name",
        args.output_name,
        "--chunk-size",
        str(args.chunk_size),
        "--mode",
        args.mode,
        "--ocr-workers",
        str(args.ocr_workers),
        "--ocr-ctx-size",
        str(args.ocr_ctx_size),
        "--bundle-root",
        str(bundle),
    ]
    print(f"PDF：{pdf}\n输出：{output}")
    result = subprocess.run(command)
    print(f"\n输出目录：{output}")
    input("按 Return 关闭窗口……")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
