#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/env python3 "$ROOT/app/marker_ocr.py" "$@"
