#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer must be run on macOS."
  read -r -p "Press Return to close..."
  exit 1
fi

if command -v python3.12 >/dev/null 2>&1; then
  PYTHON="$(command -v python3.12)"
elif command -v brew >/dev/null 2>&1; then
  brew install python@3.12
  PYTHON="$(brew --prefix python@3.12)/bin/python3.12"
else
  echo "Python 3.12 and Homebrew were not found."
  echo "Install Homebrew from https://brew.sh/ and then run this file again."
  open "https://brew.sh/" || true
  read -r -p "Press Return to close..."
  exit 1
fi

if ! command -v llama-server >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install llama.cpp
  else
    echo "llama-server was not found and Homebrew is unavailable. Install llama.cpp first."
    exit 1
  fi
fi

if [[ ! -x "$PYTHON" ]]; then
  echo "Python 3.12 was not found at $PYTHON"
  exit 1
fi

if [[ ! -x "$ROOT/.venv-marker/bin/python" ]]; then
  "$PYTHON" -m venv "$ROOT/.venv-marker"
fi
VENV_PYTHON="$ROOT/.venv-marker/bin/python"
"$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel
"$VENV_PYTHON" -m pip install -r "$ROOT/requirements-macos.txt"
"$VENV_PYTHON" "$ROOT/scripts/patch_surya_cache.py"
chmod +x "$ROOT"/*.command "$ROOT"/scripts/*.py

echo
"$VENV_PYTHON" "$ROOT/scripts/check_environment.py"
echo
echo "Installation complete. You can now double-click start_ocr.command."
read -r -p "Press Return to close..."
