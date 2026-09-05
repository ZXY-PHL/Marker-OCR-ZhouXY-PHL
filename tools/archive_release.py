#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tarfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path


SKIP_PARTS = {".venv-marker", "outputs", "__pycache__", ".DS_Store"}
COPY_BUFFER_SIZE = 4 * 1024 * 1024


def format_bytes(value: int) -> str:
    size = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


class ByteProgress:
    def __init__(self, label: str, total: int) -> None:
        self.label = label
        self.total = max(1, total)
        self.completed = 0
        self.current = ""
        self.is_tty = sys.stdout.isatty()
        self.last_milestone = -5
        self.render(force=True)

    def advance(self, amount: int, current: str = "") -> None:
        self.completed += amount
        if current:
            self.current = current
        self.render()

    def render(self, force: bool = False) -> None:
        percent = min(100.0, 100.0 * self.completed / self.total)
        width = 32
        filled = min(width, int(percent * width / 100))
        bar = "#" * filled + "-" * (width - filled)
        current = self.current
        if len(current) > 48:
            current = "..." + current[-45:]
        line = (
            f"[{bar}] {percent:6.2f}%  "
            f"{format_bytes(min(self.completed, self.total))}/{format_bytes(self.total)}  {current}"
        )
        if self.is_tty:
            print(f"\r{self.label}: {line:<118}", end="", flush=True)
        else:
            milestone = int(percent // 5) * 5
            if force or milestone > self.last_milestone or percent >= 100:
                print(f"[{percent:6.2f}%] {self.label}: {format_bytes(min(self.completed, self.total))}/{format_bytes(self.total)} {current}", flush=True)
                self.last_milestone = milestone

    def finish(self, current: str = "Complete") -> None:
        already_complete = self.completed >= self.total
        self.completed = self.total
        self.current = current
        if self.is_tty:
            self.render(force=True)
            print()
        elif not already_complete:
            self.render(force=True)


class ProgressReader:
    def __init__(self, stream, progress: ByteProgress, label: str) -> None:
        self.stream = stream
        self.progress = progress
        self.label = label

    def read(self, size: int = -1) -> bytes:
        data = self.stream.read(size)
        if data:
            self.progress.advance(len(data), self.label)
        return data


def sha256(path: Path, label: str) -> str:
    digest = hashlib.sha256()
    progress = ByteProgress(f"SHA256 {label}", path.stat().st_size)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(COPY_BUFFER_SIZE), b""):
            digest.update(block)
            progress.advance(len(block), path.name)
    progress.finish(path.name)
    return digest.hexdigest()


def should_skip(relative: Path) -> bool:
    return any(part in SKIP_PARTS for part in relative.parts) or relative.name.endswith(".sync-tmp")


def full_files(package_root: Path) -> list[tuple[Path, Path]]:
    rows: list[tuple[Path, Path]] = []
    for path in sorted(package_root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(package_root)
        if should_skip(relative):
            continue
        rows.append((path, relative))
    return rows


def overlay_files(source_root: Path, manifest: dict, target_name: str, target: dict) -> list[tuple[Path, Path]]:
    selected: dict[str, Path] = {}
    target_source = source_root / Path(target["source_dir"])
    for relative_text in target["files"]:
        relative = Path(relative_text)
        selected[relative.as_posix()] = target_source / relative
    for shared in manifest["shared_files"]:
        destination = shared["destinations"].get(target_name)
        if destination:
            selected[Path(destination).as_posix()] = source_root / Path(shared["source"])
    package_root = (source_root / target["package_dir"]).resolve()
    for generated in ("VERSION", "release-metadata.json"):
        selected[generated] = package_root / generated
    missing = [f"{relative}: {path}" for relative, path in selected.items() if not path.is_file()]
    if missing:
        raise FileNotFoundError("Code overlay source files missing:\n" + "\n".join(missing))
    return [(path, Path(relative)) for relative, path in sorted(selected.items())]


def add_zip(
    output: Path,
    root_name: str,
    files: list[tuple[Path, Path]],
    progress: ByteProgress,
    target_name: str,
) -> None:
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
        for source, relative in files:
            arcname = (Path(root_name) / relative).as_posix()
            info = zipfile.ZipInfo.from_file(source, arcname=arcname)
            info.compress_type = zipfile.ZIP_DEFLATED
            if source.suffix.lower() in {".ps1", ".cmd", ".bat", ".py"}:
                info.external_attr = (0o755 & 0xFFFF) << 16
            label = f"{target_name}: {relative.as_posix()}"
            with source.open("rb") as stream, archive.open(info, "w", force_zip64=True) as destination:
                for block in iter(lambda: stream.read(COPY_BUFFER_SIZE), b""):
                    destination.write(block)
                    progress.advance(len(block), label)


def add_tar(
    output: Path,
    root_name: str,
    files: list[tuple[Path, Path]],
    progress: ByteProgress,
    target_name: str,
) -> None:
    with tarfile.open(output, "w:gz", compresslevel=1, format=tarfile.PAX_FORMAT) as archive:
        for source, relative in files:
            arcname = (Path(root_name) / relative).as_posix()
            info = archive.gettarinfo(str(source), arcname=arcname)
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "wheel"
            if source.suffix.lower() in {".command", ".py"}:
                info.mode = 0o755
            else:
                info.mode = 0o644
            label = f"{target_name}: {relative.as_posix()}"
            with source.open("rb") as stream:
                archive.addfile(info, ProgressReader(stream, progress, label))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--release-dir", required=True)
    parser.add_argument("--mode", choices=("full", "code-only"), default="full")
    parser.add_argument("--target", action="append")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    source_root = Path(args.source_root).resolve()
    release_dir = Path(args.release_dir).resolve()
    manifest = json.loads((source_root / "release-manifest.json").read_text(encoding="utf-8"))
    version = manifest["release_version"]
    targets = args.target or list(manifest["targets"])
    release_dir.mkdir(parents=True, exist_ok=True)
    artifacts = []
    plans = []
    print("Scanning release inputs...", flush=True)
    for target_name in targets:
        target = manifest["targets"][target_name]
        package_root = (source_root / target["package_dir"]).resolve()
        if args.mode == "full":
            files = full_files(package_root)
            archive_name = target["archive_name"].format(version=version)
        else:
            files = overlay_files(source_root, manifest, target_name, target)
            archive_name = target["archive_name"].format(version=version)
            suffix = ".tar.gz" if archive_name.endswith(".tar.gz") else Path(archive_name).suffix
            stem = archive_name[: -len(suffix)]
            archive_name = f"{stem}-code-overlay{suffix}"

        output = release_dir / archive_name
        if output.exists() and not args.overwrite:
            raise FileExistsError(f"Release artifact already exists: {output}")
        plans.append(
            {
                "target_name": target_name,
                "target": target,
                "package_root": package_root,
                "files": files,
                "output": output,
                "input_bytes": sum(source.stat().st_size for source, _ in files),
            }
        )

    total_input_bytes = sum(plan["input_bytes"] for plan in plans)
    archive_progress = ByteProgress("Creating release archives", total_input_bytes)

    for plan in plans:
        target_name = plan["target_name"]
        target = plan["target"]
        package_root = plan["package_root"]
        files = plan["files"]
        output = plan["output"]
        if output.exists():
            output.unlink()
        root_name = package_root.name
        if target["archive_format"] == "zip":
            add_zip(output, root_name, files, archive_progress, target_name)
        elif target["archive_format"] == "tar.gz":
            add_tar(output, root_name, files, archive_progress, target_name)
        else:
            raise ValueError(f"Unsupported archive format: {target['archive_format']}")

        digest = sha256(output, target_name)
        sidecar = output.with_name(output.name + ".sha256")
        sidecar.write_text(f"{digest}  {output.name}\n", encoding="utf-8", newline="\n")
        artifacts.append(
            {
                "target": target_name,
                "mode": args.mode,
                "path": str(output),
                "filename": output.name,
                "bytes": output.stat().st_size,
                "sha256": digest,
                "file_count": len(files),
            }
        )
        print(f"{target_name}: {output} ({output.stat().st_size} bytes)")

    archive_progress.finish("All target archives written")

    release_manifest = {
        "schema_version": "1.0",
        "release_version": version,
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
        "archive_mode": args.mode,
        "artifacts": artifacts,
    }
    output_manifest = release_dir / "release-artifacts.json"
    output_manifest.write_text(json.dumps(release_manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(output_manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
