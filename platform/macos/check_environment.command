#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ ! -x "$ROOT/.venv-marker/bin/python" ]]; then
  echo "Environment is not installed. Run setup_macos.command first."
  read -r -p "Press Return to close..."
  exit 1
fi
"$ROOT/.venv-marker/bin/python" "$ROOT/scripts/check_environment.py"
read -r -p "Press Return to close..."
