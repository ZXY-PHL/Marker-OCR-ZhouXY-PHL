#!/usr/bin/env python3
"""Resumable chunked Marker OCR and post-processing pipeline for macOS."""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


MINIMUM_MARKDOWN_BYTES = 128


def timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


class Pipeline:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.bundle = Path(args.bundle_root).expanduser().resolve()
        self.pdf = Path(args.pdf_path).expanduser().resolve()
        self.output = Path(args.output_root).expanduser().resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.log_path = self.output / "pipeline.log"
        self.status_path = self.output / "chunk-status.jsonl"
        self.chunks_dir = self.output / "chunks"
        self.final_markdown = self.output / args.output_name
        self.runtime_cache = self.output / ".surya-runtime-cache"
        self.runtime_cache.mkdir(parents=True, exist_ok=True)
        self.python = Path(sys.executable).resolve()
        self.marker = self.bundle / ".venv-marker" / "bin" / "marker_single"
        self.clean_script = self.bundle / "scripts" / "clean_markdown.py"
        self.validate_script = self.bundle / "scripts" / "validate_markdown.py"
        self.llama_server = Path(args.llama_server or shutil.which("llama-server") or "")
        self.started = time.monotonic()

    def log(self, message: str, level: str = "INFO") -> None:
        line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{level}] {message}"
        print(line, flush=True)
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def status(self, chunk: str, state: str, size: int = 0, message: str = "") -> None:
        entry = {
            "timestamp": timestamp(),
            "chunk": chunk,
            "status": state,
            "bytes": size,
            "message": message,
        }
        with self.status_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def preflight(self) -> tuple[int, str]:
        if sys.platform != "darwin":
            raise RuntimeError(f"This package requires macOS; current platform is {sys.platform!r}.")
        if not self.pdf.is_file() or self.pdf.suffix.lower() != ".pdf":
            raise FileNotFoundError(f"Source PDF not found: {self.pdf}")
        required = [self.marker, self.clean_script, self.validate_script]
        for path in required:
            if not path.is_file():
                raise FileNotFoundError(f"Required file not found: {path}")
        if not self.llama_server.is_file():
            raise FileNotFoundError("llama-server not found. Run setup_macos.command first.")
        for path in (
            self.bundle / "surya-ocr-2-gguf" / "surya-2.gguf",
            self.bundle / "surya-ocr-2-gguf" / "surya-2-mmproj.gguf",
            self.bundle / "model-cache" / "huggingface" / "hub" / "models--datalab-to--surya_layout2" / "refs" / "main",
            self.bundle / "model-cache" / "datalab-models" / "ocr_error_detection" / "2025_02_18" / "model.safetensors",
        ):
            if not path.is_file():
                raise FileNotFoundError(f"Bundled model file not found: {path}")

        from pypdfium2 import PdfDocument

        document = PdfDocument(str(self.pdf))
        page_count = len(document)
        sample_chars = 0
        for index in range(min(page_count, 12)):
            text_page = document[index].get_textpage()
            try:
                sample_chars += len(text_page.get_text_range().strip())
            finally:
                text_page.close()
        document.close()
        pdf_type = "text" if sample_chars > 50 else "scanned"
        self.log(f"PDF: {self.pdf} | pages={page_count} | type={pdf_type} | sample_chars={sample_chars}")
        return page_count, pdf_type

    def marker_environment(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "LLAMA_CPP_BINARY": str(self.llama_server.resolve()),
                "SURYA_GGUF_LOCAL_MODEL_PATH": str((self.bundle / "surya-ocr-2-gguf" / "surya-2.gguf").resolve()),
                "SURYA_GGUF_LOCAL_MMPROJ_PATH": str((self.bundle / "surya-ocr-2-gguf" / "surya-2-mmproj.gguf").resolve()),
                "SURYA_RUNTIME_CACHE_DIR": str(self.runtime_cache),
                "MODEL_CACHE_DIR": str((self.bundle / "model-cache" / "datalab-models").resolve()),
                "HF_HOME": str((self.bundle / "model-cache" / "huggingface").resolve()),
                "HF_HUB_OFFLINE": "1",
                "SURYA_INFERENCE_BACKEND": "llamacpp",
                "SURYA_INFERENCE_KEEP_ALIVE": "false",
                "SURYA_INFERENCE_PARALLEL": str(self.args.ocr_workers),
                "SURYA_INFERENCE_CTX_SIZE": str(self.args.ocr_ctx_size),
                "LLAMA_CPP_EXTRA_ARGS": "--cache-ram 0",
                # CPU is slower but avoids known long-document MPS instability.
                "TORCH_DEVICE": "cpu",
                "PYTHONUTF8": "1",
                "PYTHONUNBUFFERED": "1",
            }
        )
        return env

    def chunk_paths(self, start: int, end: int) -> tuple[str, Path, Path, Path, Path]:
        stem = self.pdf.stem
        label = f"chunk_{start:03d}_{end:03d}"
        root = self.chunks_dir / label
        asset_dir = root / stem
        return label, root, asset_dir / f"{stem}.md", asset_dir / f"{stem}_en.md", asset_dir / f"{stem}_meta.json"

    @staticmethod
    def valid_artifacts(markdown: Path, metadata: Path) -> bool:
        try:
            if markdown.stat().st_size < MINIMUM_MARKDOWN_BYTES:
                return False
            markdown.read_text(encoding="utf-8")
            json.loads(metadata.read_text(encoding="utf-8"))
            return True
        except (OSError, UnicodeError, json.JSONDecodeError):
            return False

    def recover_marker_paths(self, chunk_root: Path, raw_md: Path, metadata: Path) -> tuple[Path, Path]:
        if raw_md.is_file() and metadata.is_file():
            return raw_md, metadata
        md_candidates = [p for p in chunk_root.rglob(f"{self.pdf.stem}.md") if not p.name.endswith("_en.md")]
        meta_candidates = list(chunk_root.rglob(f"{self.pdf.stem}_meta.json"))
        if len(md_candidates) == 1 and len(meta_candidates) == 1:
            return md_candidates[0], meta_candidates[0]
        return raw_md, metadata

    def run_chunk(self, index: int, total: int, start: int, end: int, force_ocr: bool) -> bool:
        label, chunk_root, raw_md, english_md, metadata = self.chunk_paths(start, end)
        if english_md.is_file() and english_md.stat().st_size >= MINIMUM_MARKDOWN_BYTES:
            self.status(label, "SKIPPED", english_md.stat().st_size, "Existing OCR checkpoint")
            self.log(f"[{index}/{total}] SKIP {label}", "DONE")
            return True

        if self.valid_artifacts(raw_md, metadata):
            raw_md.replace(english_md)
            self.status(label, "RECOVERED", english_md.stat().st_size, "Recovered valid interrupted artifact")
            self.status(label, "SUCCESS", english_md.stat().st_size, "Recovered artifact renamed to _en.md")
            self.log(f"[{index}/{total}] RECOVERED {label}", "DONE")
            return True

        if chunk_root.exists():
            resolved = chunk_root.resolve()
            chunks_resolved = self.chunks_dir.resolve()
            if chunks_resolved not in resolved.parents:
                raise RuntimeError(f"Refusing to remove outside chunks directory: {resolved}")
            failed_logs = list(resolved.glob("marker.*.log"))
            if failed_logs:
                attempt_stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000_000:09d}"
                attempt_dir = self.output / "failed-attempt-logs" / label / attempt_stamp
                attempt_dir.mkdir(parents=True, exist_ok=True)
                for failed_log in failed_logs:
                    shutil.copy2(failed_log, attempt_dir / failed_log.name)
                self.log(f"Archived previous attempt logs: {attempt_dir}", "WARN")
            shutil.rmtree(resolved)
        chunk_root.mkdir(parents=True, exist_ok=True)
        stdout_path = chunk_root / "marker.stdout.log"
        stderr_path = chunk_root / "marker.stderr.log"
        command = [
            str(self.marker),
            str(self.pdf),
            "--page_range",
            f"{start}-{end}",
            "--output_dir",
            str(chunk_root),
            "--output_format",
            "markdown",
            "--mode",
            self.args.mode,
            "--disable_tqdm",
        ]
        if force_ocr:
            command.insert(-1, "--force_ocr")
        self.log(
            f"[{index}/{total}] Input mode: "
            f"{'scanned PDF; force OCR enabled' if force_ocr else 'text PDF; native text extraction'}"
        )
        self.log(f"[{index}/{total}] START {label} pages={start}-{end}")
        chunk_started = time.monotonic()
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            process = subprocess.Popen(
                command,
                cwd=chunk_root,
                env=self.marker_environment(),
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            try:
                while True:
                    try:
                        exit_code = process.wait(timeout=5)
                        break
                    except subprocess.TimeoutExpired:
                        elapsed = int(time.monotonic() - chunk_started)
                        completed = index - 1
                        percent = completed * 100.0 / total if total else 0.0
                        print(
                            f"\rMarker OCR: {completed}/{total} chunks | current {label} "
                            f"(pages {start}-{end}) | {percent:.1f}% | elapsed {elapsed // 3600:02d}:"
                            f"{elapsed % 3600 // 60:02d}:{elapsed % 60:02d}",
                            end="",
                            flush=True,
                        )
            except KeyboardInterrupt:
                os.killpg(process.pid, signal.SIGTERM)
                raise
        print(flush=True)

        raw_md, metadata = self.recover_marker_paths(chunk_root, raw_md, metadata)
        if exit_code != 0 or not self.valid_artifacts(raw_md, metadata):
            message = f"Marker exit={exit_code}; see {stderr_path}"
            self.status(label, "FAILED", 0, message)
            self.log(f"[{index}/{total}] FAIL {label}: {message}", "ERROR")
            return False

        english_md = raw_md.with_name(f"{self.pdf.stem}_en.md")
        raw_md.replace(english_md)
        size = english_md.stat().st_size
        self.status(label, "CHECKPOINTED", size, "Marker exited cleanly; Markdown and metadata readable")
        self.status(label, "SUCCESS", size, "OCR checkpoint saved")
        self.log(f"[{index}/{total}] DONE {label} ({size} bytes)", "DONE")
        return True

    def translated_count(self, page_count: int) -> int:
        count = 0
        for start in range(0, page_count, self.args.chunk_size):
            end = min(start + self.args.chunk_size - 1, page_count - 1)
            _, _, translated, _, _ = self.chunk_paths(start, end)
            if translated.is_file() and translated.stat().st_size >= MINIMUM_MARKDOWN_BYTES:
                count += 1
        return count

    def merge(self, page_count: int, pdf_type: str) -> int:
        if self.final_markdown.exists() and not self.args.overwrite:
            raise FileExistsError(
                f"Final Markdown already exists: {self.final_markdown}. "
                "Use --overwrite only when replacement is intentional."
            )
        temp_path = self.final_markdown.with_suffix(self.final_markdown.suffix + ".tmp")
        image_pattern = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")
        with temp_path.open("w", encoding="utf-8", newline="\n") as output:
            for start in range(0, page_count, self.args.chunk_size):
                end = min(start + self.args.chunk_size - 1, page_count - 1)
                label, _, translated, _, _ = self.chunk_paths(start, end)
                if not translated.is_file() or translated.stat().st_size < MINIMUM_MARKDOWN_BYTES:
                    raise FileNotFoundError(f"Missing translated chunk: {translated}")
                content = translated.read_text(encoding="utf-8")

                def rewrite(match: re.Match[str]) -> str:
                    alt, path = match.group(1), match.group(2)
                    if path.startswith(("http://", "https://", "data:")):
                        return match.group(0)
                    filename = Path(path).name
                    return f"![{alt}](chunks/{label}/{self.pdf.stem}/{filename})"

                output.write(f"<!-- chunk: {label} -->\n\n")
                output.write(image_pattern.sub(rewrite, content).rstrip() + "\n\n")
        temp_path.replace(self.final_markdown)
        self.status("ALL", "MERGED", self.final_markdown.stat().st_size, str(self.final_markdown))
        self.log(f"Merged -> {self.final_markdown}", "DONE")

        cleanup = subprocess.run([str(self.python), str(self.clean_script), str(self.final_markdown)], capture_output=True, text=True)
        if cleanup.returncode != 0:
            self.log(f"Cleanup warning: {cleanup.stdout}\n{cleanup.stderr}", "WARN")
        self.status("ALL", "CLEANED", self.final_markdown.stat().st_size, f"exit={cleanup.returncode}")

        validation = subprocess.run(
            [str(self.python), str(self.validate_script), str(self.final_markdown), "--pdf", str(self.pdf)],
            capture_output=True,
            text=True,
        )
        content = self.final_markdown.read_text(encoding="utf-8")
        image_links = re.findall(r"!\[[^\]]*\]\(([^)]+)\)", content)
        missing_images = [link for link in image_links if not link.startswith(("http://", "https://", "data:")) and not (self.output / link).is_file()]
        status = "SUCCESS" if validation.returncode == 0 and not missing_images else "FAILED"
        report = {
            "generated": timestamp(),
            "status": status,
            "pdf_path": str(self.pdf),
            "pdf_type": pdf_type,
            "source_page_count": page_count,
            "marker_version": "2.0.0",
            "platform": "macOS",
            "machine": platform.machine(),
            "ocr_mode": self.args.mode,
            "chunk_count": math.ceil(page_count / self.args.chunk_size),
            "chunk_size": self.args.chunk_size,
            "final_markdown_path": str(self.final_markdown),
            "final_markdown_bytes": self.final_markdown.stat().st_size,
            "image_count": len(image_links),
            "missing_images": missing_images,
            "validation_exit_code": validation.returncode,
            "validation_stdout": validation.stdout[-4000:],
            "validation_stderr": validation.stderr[-4000:],
            "duration_seconds": round(time.monotonic() - self.started, 3),
        }
        report_path = self.output / "conversion-report.json"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        self.status("ALL", "VALIDATED", self.final_markdown.stat().st_size, f"exit={validation.returncode}")
        self.status("ALL", status, self.final_markdown.stat().st_size, str(report_path))
        self.log(f"Status={status}; report={report_path}", "DONE" if status == "SUCCESS" else "ERROR")
        return 0 if status == "SUCCESS" else 1

    def cleanup_services(self) -> None:
        for sentinel in self.runtime_cache.glob("*_server.json"):
            try:
                state = json.loads(sentinel.read_text(encoding="utf-8"))
                pid = int(state["pid"])
                ps = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
                command = ps.stdout.strip()
                allowed = (
                    str(self.python) in command
                    or str(self.llama_server) in command
                    or str(self.llama_server.resolve()) in command
                )
                if not command:
                    continue
                if not allowed:
                    self.log(f"Refusing to stop unverified service pid={pid}: {command}", "WARN")
                    continue
                os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.2)
                else:
                    os.kill(pid, signal.SIGKILL)
                self.log(f"Stopped portable Surya service pid={pid}")
            except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
                self.log(f"Could not clean service sentinel {sentinel}: {exc}", "WARN")

    def run(self) -> int:
        page_count, pdf_type = self.preflight()
        total_chunks = math.ceil(page_count / self.args.chunk_size)
        self.log(f"Chunks={total_chunks}; chunk_size={self.args.chunk_size}")
        if not self.args.skip_chunking:
            self.chunks_dir.mkdir(parents=True, exist_ok=True)
            for index, start in enumerate(range(0, page_count, self.args.chunk_size), 1):
                end = min(start + self.args.chunk_size - 1, page_count - 1)
                if not self.run_chunk(index, total_chunks, start, end, force_ocr=(pdf_type == "scanned")):
                    return 1
            self.status("ALL", "CHUNKS_COMPLETE", total_chunks, "All OCR chunks verified")
            translated = self.translated_count(page_count)
            if translated < total_chunks:
                self.status("ALL", "AWAITING_TRANSLATION", 0, f"Translated chunks: {translated}/{total_chunks}")
                self.log(f"OCR complete; translated chunks={translated}/{total_chunks}. Stopping before merge.", "DONE")
                return 0
        else:
            translated = self.translated_count(page_count)
            if translated < total_chunks:
                raise RuntimeError(f"Only {translated}/{total_chunks} translated chunks are present.")
        return self.merge(page_count, pdf_type)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Chunked Marker OCR pipeline for macOS")
    parser.add_argument("--pdf-path", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--output-name", default="output.md")
    parser.add_argument("--chunk-size", type=int, default=16)
    parser.add_argument("--mode", choices=("fast", "balanced"), default="fast")
    parser.add_argument("--ocr-workers", type=int, default=1)
    parser.add_argument("--ocr-ctx-size", type=int, default=16384)
    parser.add_argument("--bundle-root", required=True)
    parser.add_argument("--llama-server")
    parser.add_argument("--skip-chunking", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    pipeline = Pipeline(args)
    try:
        return pipeline.run()
    except Exception as exc:
        pipeline.log(f"Pipeline failed: {exc}", "ERROR")
        pipeline.status("ALL", "FAILED", 0, str(exc))
        return 1
    finally:
        pipeline.cleanup_services()


if __name__ == "__main__":
    raise SystemExit(main())
