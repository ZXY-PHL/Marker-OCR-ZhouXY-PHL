"""Helpers for paths dragged into an interactive macOS Terminal prompt."""

from __future__ import annotations

import shlex


def normalize_dragged_path(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    try:
        parts = shlex.split(value)
        if len(parts) == 1:
            return parts[0]
    except ValueError:
        pass
    return value
