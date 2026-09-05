#!/usr/bin/env python3
"""Unified Marker OCR product entry point.

The source tree is cross-platform, while native runtimes remain in the
platform-specific distribution directories next to Marker-OCR-Source.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


PRODUCT_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = PRODUCT_ROOT.parent


def host_platform() -> str:
    system = platform.system().lower()
    if system == "windows":
        return "windows"
    if system == "darwin":
        return "macos"
    raise RuntimeError(f"Unsupported operating system: {platform.system()}")


def command_for(action: str, forwarded: list[str]) -> tuple[list[str], Path]:
    host = host_platform()
    if host == "windows":
        package = WORKSPACE_ROOT / "Marker-OCR-Portable"
        scripts = {
            "start": "Start-OCR.ps1",
            "check": "Check-Environment.ps1",
            "finish": "Finish-Merge.ps1",
        }
        pwsh = package / "runtime" / "pwsh" / "pwsh.exe"
        if not pwsh.is_file():
            found = shutil.which("pwsh") or shutil.which("powershell")
            if not found:
                raise RuntimeError("PowerShell was not found.")
            pwsh = Path(found)
        command = [str(pwsh), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(package / scripts[action])]
    else:
        package = WORKSPACE_ROOT / "Marker-OCR-macOS"
        scripts = {
            "start": "start_ocr.command",
            "check": "check_environment.command",
            "finish": "finish_merge.command",
        }
        command = ["/bin/bash", str(package / scripts[action])]

    script_path = Path(command[-1])
    if not package.is_dir():
        raise RuntimeError(f"Platform package is missing: {package}")
    if not script_path.is_file():
        raise RuntimeError(f"Platform entry point is missing: {script_path}")
    return command + forwarded, package


def parse_args(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(
        prog="Marker-OCR",
        description="Unified launcher for the Windows and macOS Marker OCR editions.",
    )
    parser.add_argument("action", nargs="?", choices=("start", "check", "finish"), default="start")
    parser.add_argument("--show-platform", action="store_true", help="print platform routing information and exit")
    return parser.parse_known_args(argv)


def main(argv: list[str] | None = None) -> int:
    args, forwarded = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        command, package = command_for(args.action, forwarded)
    except RuntimeError as exc:
        print(f"Marker-OCR: {exc}", file=sys.stderr)
        return 2

    if args.show_platform:
        print(f"platform={host_platform()}")
        print(f"package={package}")
        print(f"action={args.action}")
        return 0

    env = os.environ.copy()
    env.setdefault("PYTHONUTF8", "1")
    return subprocess.run(command, cwd=package, env=env, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
