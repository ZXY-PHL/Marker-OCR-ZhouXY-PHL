#!/usr/bin/env python3
"""Cross-platform static and state-logic checks for the macOS bundle."""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace

from path_input import normalize_dragged_path
from pipeline_macos import Pipeline


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--integration-pdf")
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    assert normalize_dragged_path(r"/Users/test/My\ Book.pdf") == "/Users/test/My Book.pdf"
    assert normalize_dragged_path("'/Users/test/中文 书.pdf'") == "/Users/test/中文 书.pdf"
    assert (root / "surya-ocr-2-gguf" / "surya-2.gguf").stat().st_size > 1_000_000_000
    assert (root / "surya-ocr-2-gguf" / "surya-2-mmproj.gguf").stat().st_size > 100_000_000

    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        pdf = temp / "book.pdf"
        pdf.write_bytes(b"%PDF-static-test")
        output = temp / "output"
        args = SimpleNamespace(
            bundle_root=str(root),
            pdf_path=str(pdf),
            output_root=str(output),
            output_name="book.md",
            chunk_size=16,
            mode="fast",
            ocr_workers=1,
            ocr_ctx_size=16384,
            llama_server=None,
            skip_chunking=False,
            overwrite=False,
        )
        pipeline = Pipeline(args)
        label, _, translated, english, metadata = pipeline.chunk_paths(0, 15)
        assert label == "chunk_000_015"
        english.parent.mkdir(parents=True)
        english.write_text("x" * 256, encoding="utf-8")
        metadata.write_text(json.dumps({"ok": True}), encoding="utf-8")
        assert pipeline.valid_artifacts(english, metadata)
        assert pipeline.translated_count(16) == 0
        translated.write_text("译" * 256, encoding="utf-8")
        assert pipeline.translated_count(16) == 1

    if options.integration_pdf:
        source_pdf = Path(options.integration_pdf).resolve()
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            args = SimpleNamespace(
                bundle_root=str(root),
                pdf_path=str(source_pdf),
                output_root=str(temp / "output"),
                output_name="integration.md",
                chunk_size=16,
                mode="fast",
                ocr_workers=1,
                ocr_ctx_size=16384,
                llama_server=None,
                skip_chunking=True,
                overwrite=False,
            )
            pipeline = Pipeline(args)
            _, _, translated, _, _ = pipeline.chunk_paths(0, 0)
            translated.parent.mkdir(parents=True)
            translated.write_text(
                "# Integration Test\n\n"
                + "This paragraph verifies merge, cleanup, validation, and report generation. " * 20,
                encoding="utf-8",
            )
            assert pipeline.merge(1, "text") == 0
            report = json.loads((pipeline.output / "conversion-report.json").read_text(encoding="utf-8"))
            assert report["status"] == "SUCCESS"
            assert pipeline.final_markdown.stat().st_size >= 128
        print("MERGE_INTEGRATION_TEST_OK")
    print("STATIC_SELF_TEST_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
