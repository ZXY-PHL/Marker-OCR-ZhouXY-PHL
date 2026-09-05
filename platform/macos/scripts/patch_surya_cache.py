#!/usr/bin/env python3
"""Patch Surya 2.0 cache paths to honor SURYA_RUNTIME_CACHE_DIR."""

from __future__ import annotations

import importlib.util
from pathlib import Path


def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        return
    if old not in text:
        raise RuntimeError(f"Expected Surya 2.0 source pattern not found in {path}: {old!r}")
    path.write_text(text.replace(old, new), encoding="utf-8")


def main() -> int:
    spec = importlib.util.find_spec("surya")
    if not spec or not spec.submodule_search_locations:
        raise RuntimeError("surya package not found")
    root = Path(next(iter(spec.submodule_search_locations)))
    spawn = root / "inference" / "backends" / "spawn.py"
    client = root / "common" / "batch_service" / "client.py"
    llama = root / "inference" / "backends" / "llamacpp.py"
    replace(
        spawn,
        'base = Path(os.path.expanduser("~/.cache/datalab/surya"))',
        'configured = os.environ.get("SURYA_RUNTIME_CACHE_DIR")\n    base = Path(configured) if configured else Path(os.path.expanduser("~/.cache/datalab/surya"))',
    )
    replace(spawn, 'log_path = Path(f"~/.cache/datalab/surya/{backend}_server.log").expanduser()', 'log_path = _cache_dir() / f"{backend}_server.log"')
    replace(client, 'from surya.inference.backends.spawn import SpawnHandle, attach_or_spawn', 'from surya.inference.backends.spawn import SpawnHandle, _cache_dir, attach_or_spawn')
    replace(client, 'log_path = Path(\n            f"~/.cache/datalab/surya/{self.config.backend}_server.log"\n        ).expanduser()', 'log_path = _cache_dir() / f"{self.config.backend}_server.log"')
    replace(llama, '    SpawnError,\n    attach_or_spawn,', '    SpawnError,\n    _cache_dir,\n    attach_or_spawn,')
    replace(llama, 'log_path = Path("~/.cache/datalab/surya/llamacpp_server.log").expanduser()', 'log_path = _cache_dir() / "llamacpp_server.log"')
    print(f"Patched Surya runtime cache paths under {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
