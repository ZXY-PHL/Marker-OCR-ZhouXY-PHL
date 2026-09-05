#!/usr/bin/env python3
"""Conservatively clean Marker-generated Markdown without rewriting content."""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(errors="backslashreplace")


IMAGE_RE = re.compile(r"(!\[[^\]]*\]\()([^\)]+)(\))")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+")
LIST_RE = re.compile(r"^\s*(?:[-+*]|\d+[.)])\s+")
DOUBLE_ORDERED_LIST_RE = re.compile(
    r"^(\s*)(\d+)([.)])(\s+)(\d+)([.)])(\s+)(\S.*)$"
)
PAGE_RE = re.compile(r"^\s*(?:page\s*)?\d{1,4}(?:\s*(?:/|of)\s*\d{1,4})?\s*$", re.I)
REFERENCE_HEADING_RE = re.compile(r"^#{1,6}\s+(?:references|bibliography|参考文献)\b", re.I)


def normalize_image_paths(line: str) -> str:
    def replace(match: re.Match[str]) -> str:
        target = match.group(2)
        if target.startswith(("http://", "https://", "data:")):
            return match.group(0)
        return f"{match.group(1)}{target.replace(chr(92), '/')}{match.group(3)}"

    return IMAGE_RE.sub(replace, line)


def collapse_marker_ordered_list_runs(lines: list[str]) -> tuple[list[str], int]:
    """Remove Marker's generated outer marker from unambiguous double-numbered runs.

    Marker can serialize printed ``1. Item`` text as ``1. 1. Item`` after its
    layout model also classifies the line as an ordered-list item.  A run is
    considered unambiguous only when it contains at least two adjacent items,
    uses one indentation level, starts its outer sequence at 1, and both the
    outer and printed inner sequences increase by one.  Fenced code and display
    math are excluded.
    """
    collapsed = list(lines)
    eligible = [False] * len(lines)
    in_fence = False
    in_math = False

    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            continue
        if not in_fence and stripped == "$$":
            in_math = not in_math
            continue
        eligible[index] = not in_fence and not in_math

    changed = 0
    index = 0
    while index < len(lines):
        match = DOUBLE_ORDERED_LIST_RE.match(lines[index]) if eligible[index] else None
        if not match:
            index += 1
            continue

        indent = match.group(1)
        run: list[tuple[int, re.Match[str]]] = [(index, match)]
        cursor = index + 1
        while cursor < len(lines) and eligible[cursor]:
            next_match = DOUBLE_ORDERED_LIST_RE.match(lines[cursor])
            if not next_match or next_match.group(1) != indent:
                break
            run.append((cursor, next_match))
            cursor += 1

        outer = [int(item.group(2)) for _, item in run]
        inner = [int(item.group(5)) for _, item in run]
        outer_is_generated = outer == list(range(1, len(run) + 1))
        inner_is_sequential = len(run) >= 2 and all(
            current == previous + 1 for previous, current in zip(inner, inner[1:])
        )
        if outer_is_generated and inner_is_sequential:
            for line_index, item in run:
                collapsed[line_index] = (
                    item.group(1)
                    + item.group(5)
                    + item.group(6)
                    + item.group(7)
                    + item.group(8)
                )
            changed += len(run)

        index = cursor

    return collapsed, changed


def repeated_noise(lines: list[str]) -> set[str]:
    candidates = []
    for line in lines:
        stripped = line.strip()
        if not stripped or len(stripped) > 100:
            continue
        if HEADING_RE.match(stripped) or LIST_RE.match(stripped) or "|" in stripped:
            continue
        if PAGE_RE.match(stripped) or re.search(r"(?:copyright|all rights reserved|doi:|issn|vol\.?\s*\d)", stripped, re.I):
            candidates.append(stripped)
    return {value for value, count in Counter(candidates).items() if count >= 3}


def is_protected(line: str, in_fence: bool, in_math: bool, in_references: bool) -> bool:
    stripped = line.strip()
    return bool(
        in_fence
        or in_math
        or in_references
        or not stripped
        or HEADING_RE.match(stripped)
        or LIST_RE.match(stripped)
        or stripped.startswith(">")
        or "|" in stripped
        or re.match(r"^\[?\d+\]?\s*[.)]", stripped)
        or stripped.startswith("![")
    )


def clean_text(text: str, remove_repeated: bool = True) -> tuple[str, list[str]]:
    warnings: list[str] = []
    text = text.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")
    raw_lines = [line.rstrip() for line in text.split("\n")]
    raw_lines, collapsed_list_items = collapse_marker_ordered_list_runs(raw_lines)
    if collapsed_list_items:
        warnings.append(
            f"Collapsed duplicated Marker numbering in {collapsed_list_items} ordered-list item(s)."
        )
    noise = repeated_noise(raw_lines) if remove_repeated else set()
    if noise:
        warnings.append(f"Removed {len(noise)} repeated high-confidence header/footer pattern(s).")

    normalized: list[str] = []
    in_fence = False
    in_math = False
    in_references = False
    for raw in raw_lines:
        line = normalize_image_paths(raw)
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            normalized.append(line)
            continue
        if not in_fence and stripped == "$$":
            in_math = not in_math
            normalized.append(line)
            continue
        if not in_fence and REFERENCE_HEADING_RE.match(stripped):
            in_references = True
        if not in_fence and not in_math and stripped in noise:
            continue
        if not in_fence and not in_math and PAGE_RE.match(stripped) and len(stripped) <= 18:
            continue
        if not in_fence and not in_math:
            line = re.sub(r"^(\s*)[•●▪◦]\s+", r"\1- ", line)
            line = re.sub(r"^(\s*)[-*+]\s{2,}", r"\1- ", line)
        normalized.append(line)

    joined: list[str] = []
    in_fence = in_math = in_references = False
    for line in normalized:
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
        if not in_fence and stripped == "$$":
            in_math = not in_math
        if not in_fence and REFERENCE_HEADING_RE.match(stripped):
            in_references = True

        if joined and stripped and not is_protected(line, in_fence, in_math, in_references):
            previous = joined[-1]
            previous_stripped = previous.rstrip()
            previous_protected = is_protected(previous, in_fence, in_math, in_references)
            if previous_stripped and not previous_protected:
                if re.search(r"[A-Za-z]{2,}-$", previous_stripped) and re.match(r"^[a-z]", stripped):
                    joined[-1] = previous_stripped[:-1] + stripped
                    continue
                if (re.search(r"[,;:]$", previous_stripped) or re.match(r"^[a-z]", stripped)) and not re.search(r"[.!?。！？]$", previous_stripped):
                    joined[-1] = previous_stripped + " " + stripped
                    continue
        joined.append(line)

    spaced: list[str] = []
    for line in joined:
        if HEADING_RE.match(line):
            if spaced and spaced[-1] != "":
                spaced.append("")
            spaced.append(line.strip())
            spaced.append("")
        else:
            spaced.append(line)

    output: list[str] = []
    blank_count = 0
    for line in spaced:
        if line.strip():
            blank_count = 0
            output.append(line)
        else:
            blank_count += 1
            if blank_count <= 2:
                output.append("")
    cleaned = "\n".join(output).strip() + "\n"
    return cleaned, warnings


def clean_file(path: Path, output: Path | None = None, overwrite: bool = False) -> tuple[Path, list[str]]:
    source = path.resolve()
    if not source.is_file():
        raise FileNotFoundError(f"Markdown file not found: {source}")
    destination = output.resolve() if output else source
    if destination.exists() and destination != source and not overwrite:
        raise FileExistsError(f"Output exists; use --overwrite: {destination}")
    cleaned, warnings = clean_text(source.read_text(encoding="utf-8", errors="replace"))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(cleaned, encoding="utf-8", newline="\n")
    return destination, warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("markdown", type=Path)
    parser.add_argument("--output", type=Path, help="Write to another file; default is in-place.")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    try:
        destination, warnings = clean_file(args.markdown, args.output, args.overwrite)
        print(f"Cleaned Markdown: {destination}")
        for warning in warnings:
            print(f"WARNING: {warning}")
        return 0
    except (OSError, UnicodeError) as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
