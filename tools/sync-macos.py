#!/usr/bin/env python3
"""Synchronize the canonical macOS source files into the sibling macOS package.

Large native assets, model caches, virtual environments, OCR outputs, and logs
are deliberately outside this synchronization contract.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import tempfile


SOURCE_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = SOURCE_ROOT / "release-manifest.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_atomic(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as source_stream, tempfile.NamedTemporaryFile(
        mode="wb", dir=destination.parent, prefix=f".{destination.name}.", delete=False
    ) as temp_stream:
        shutil.copyfileobj(source_stream, temp_stream)
        temp_path = Path(temp_stream.name)
    try:
        shutil.copystat(source, temp_path, follow_symlinks=False)
        temp_path.replace(destination)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def mark_executable_if_needed(path: Path) -> None:
    if path.suffix not in {".command", ".py"}:
        return
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def main() -> int:
    parser = argparse.ArgumentParser(description="Synchronize canonical Marker OCR macOS code into its package.")
    parser.add_argument("--dry-run", action="store_true", help="report planned changes without writing files")
    args = parser.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    target_name = "macos"
    target = manifest["targets"][target_name]
    package_root = (SOURCE_ROOT / target["package_dir"]).resolve()
    if not package_root.is_dir():
        raise SystemExit(f"macOS package is missing: {package_root}")

    work: list[tuple[Path, Path]] = []
    for shared in manifest["shared_files"]:
        relative = shared["destinations"].get(target_name)
        if relative:
            work.append((SOURCE_ROOT / shared["source"], package_root / relative))
    for relative in target["files"]:
        work.append((SOURCE_ROOT / target["source_dir"] / relative, package_root / relative))

    copied = 0
    unchanged = 0
    source_hashes: dict[str, str] = {}
    for source, destination in work:
        if not source.is_file():
            raise SystemExit(f"canonical source is missing: {source}")
        relative = destination.relative_to(package_root).as_posix()
        source_hashes[relative] = sha256(source)
        if destination.is_file() and sha256(destination) == source_hashes[relative]:
            unchanged += 1
            continue
        print(f"{'Would sync' if args.dry_run else 'Syncing'}: {relative}")
        if not args.dry_run:
            write_atomic(source, destination)
            mark_executable_if_needed(destination)
        copied += 1

    version = str(manifest["release_version"])
    metadata = {
        "schema_version": "1.0",
        "package": target_name,
        "version": version,
        "source_manifest": "Marker-OCR-Source/release-manifest.json",
        "source_hashes": source_hashes,
    }
    if not args.dry_run:
        (package_root / "VERSION").write_text(f"{version}\n", encoding="utf-8")
        (package_root / "release-metadata.json").write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    print(f"macOS sync {'preview' if args.dry_run else 'complete'}: copied={copied} unchanged={unchanged} version={version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
