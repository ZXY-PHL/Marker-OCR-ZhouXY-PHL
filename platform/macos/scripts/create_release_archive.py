#!/usr/bin/env python3
"""Create a macOS-friendly tar.gz archive with executable mode bits."""

from __future__ import annotations

import argparse
import tarfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = Path(args.output).resolve() if args.output else root.with_suffix(".tar.gz")
    skipped_names = {"__pycache__", ".venv-marker", "outputs", ".DS_Store"}

    def archive_filter(info: tarfile.TarInfo) -> tarfile.TarInfo:
        suffix = Path(info.name).suffix
        if info.isdir():
            info.mode = 0o755
        elif suffix in {".command", ".py"}:
            info.mode = 0o755
        else:
            info.mode = 0o644
        info.uid = 0
        info.gid = 0
        info.uname = "root"
        info.gname = "wheel"
        return info

    with tarfile.open(output, mode="w:gz", compresslevel=1, format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root)
            if any(part in skipped_names for part in relative.parts):
                continue
            arcname = Path(root.name) / relative
            archive.add(path, arcname=str(arcname).replace("\\", "/"), recursive=False, filter=archive_filter)
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
