#!/usr/bin/env python3
"""Guardian that resumes the macOS pipeline until all OCR chunks exist."""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
import time
from pathlib import Path


def page_count(pdf: Path) -> int:
    from pypdfium2 import PdfDocument

    document = PdfDocument(str(pdf))
    count = len(document)
    document.close()
    return count


def completed_chunks(output: Path, stem: str, pages: int, chunk_size: int) -> int:
    completed = 0
    for start in range(0, pages, chunk_size):
        end = min(start + chunk_size - 1, pages - 1)
        markdown = output / "chunks" / f"chunk_{start:03d}_{end:03d}" / stem / f"{stem}_en.md"
        if markdown.is_file() and markdown.stat().st_size >= 128:
            completed += 1
    return completed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf-path", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--output-name", default="output.md")
    parser.add_argument("--chunk-size", type=int, default=16)
    parser.add_argument("--mode", choices=("fast", "balanced"), default="fast")
    parser.add_argument("--ocr-workers", type=int, default=1)
    parser.add_argument("--ocr-ctx-size", type=int, default=16384)
    parser.add_argument("--bundle-root", required=True)
    parser.add_argument("--max-rounds", type=int, default=100)
    args = parser.parse_args()

    pdf = Path(args.pdf_path).expanduser().resolve()
    output = Path(args.output_root).expanduser().resolve()
    bundle = Path(args.bundle_root).expanduser().resolve()
    pages = page_count(pdf)
    total = math.ceil(pages / args.chunk_size)
    previous = completed_chunks(output, pdf.stem, pages, args.chunk_size)
    no_progress_failures = 0

    for round_number in range(1, args.max_rounds + 1):
        print(f"\n=== ROUND {round_number} ===", flush=True)
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
            "--mode",
            args.mode,
            "--ocr-workers",
            str(args.ocr_workers),
            "--ocr-ctx-size",
            str(args.ocr_ctx_size),
            "--bundle-root",
            str(bundle),
        ]
        result = subprocess.run(command)
        completed = completed_chunks(output, pdf.stem, pages, args.chunk_size)
        print(f"Chunks: {completed}/{total}; pipeline exit={result.returncode}", flush=True)
        if completed >= total:
            print("All OCR chunks are complete.", flush=True)
            print(
                "After translating every *_en.md, run finish_merge.command with the same PDF and output directory.",
                flush=True,
            )
            return 0
        if completed > previous:
            no_progress_failures = 0
        elif result.returncode != 0:
            no_progress_failures += 1
        if no_progress_failures >= 3:
            print("Stopped after three consecutive failed rounds with no new checkpoint. Inspect pipeline.log and marker.stderr.log.", file=sys.stderr)
            return 1
        previous = completed
        time.sleep(3)
    print(f"Maximum rounds reached with only {previous}/{total} chunks complete.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
