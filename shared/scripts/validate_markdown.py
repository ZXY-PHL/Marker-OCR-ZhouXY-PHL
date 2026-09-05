#!/usr/bin/env python3
"""Diagnose structural and completeness problems in converted Markdown."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(errors="backslashreplace")


IMAGE_RE = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+", re.M)
REFERENCE_RE = re.compile(r"^\s{0,3}#{1,6}\s+(?:references|bibliography|参考文献)\b", re.I | re.M)


def pdf_stats(pdf: Path) -> tuple[int | None, int | None, str | None]:
    try:
        import pypdfium2 as pdfium

        document = pdfium.PdfDocument(str(pdf))
        pages = len(document)
        characters = 0
        for index in range(min(pages, 12)):
            page = document[index]
            textpage = page.get_textpage()
            characters += len(textpage.get_text_range().strip())
            textpage.close()
            page.close()
        document.close()
        return pages, characters, None
    except Exception as exc:  # diagnostics must survive malformed/encrypted PDFs
        return None, None, str(exc)


def repeated_lines(text: str) -> list[str]:
    values = [re.sub(r"\s+", " ", line.strip()) for line in text.splitlines()]
    counts = Counter(value for value in values if 4 <= len(value) <= 100)
    return [value for value, count in counts.items() if count >= 3]


def repeated_passages(text: str) -> list[str]:
    passages = [re.sub(r"\s+", " ", block.strip()) for block in re.split(r"\n\s*\n", text)]
    counts = Counter(value for value in passages if len(value) >= 80)
    return [value[:160] for value, count in counts.items() if count >= 2]


def validate(path: Path, pdf: Path | None = None) -> dict:
    report: dict[str, object] = {
        "result": "FAIL",
        "markdown_file": str(path.resolve()),
        "image_count": 0,
        "missing_images": [],
        "heading_count": 0,
        "possible_repeated_headers": [],
        "possible_garbled_text": False,
        "reference_section_found": False,
        "warnings": [],
        "errors": [],
    }
    errors: list[str] = report["errors"]  # type: ignore[assignment]
    warnings: list[str] = report["warnings"]  # type: ignore[assignment]
    if not path.is_file():
        errors.append("Markdown file does not exist.")
        return report
    raw = path.read_bytes()
    report["file_size_bytes"] = len(raw)
    if not raw:
        errors.append("Markdown file is empty.")
        return report
    text = raw.decode("utf-8", errors="replace")
    visible = re.sub(r"\s+", "", text)
    if len(visible) < 20:
        errors.append("Markdown has fewer than 20 non-whitespace characters.")
    elif len(visible) < 200:
        warnings.append("Markdown is unusually short (fewer than 200 non-whitespace characters).")

    headings = HEADING_RE.findall(text)
    report["heading_count"] = len(headings)
    if not headings:
        warnings.append("No ATX Markdown headings were found.")

    image_targets = IMAGE_RE.findall(text)
    report["image_count"] = len(image_targets)
    missing: list[str] = []
    for target in image_targets:
        clean_target = target.strip().strip("<>").split(maxsplit=1)[0]
        if clean_target.startswith(("http://", "https://", "data:")):
            continue
        candidate = (path.parent / Path(clean_target)).resolve()
        if not candidate.exists():
            missing.append(target)
    report["missing_images"] = missing
    if missing:
        warnings.append(f"{len(missing)} referenced image(s) are missing.")

    replacement_count = text.count("\ufffd")
    mojibake_count = sum(text.count(token) for token in ("Ã", "Â", "â€", "锟斤拷"))
    control_count = sum(1 for char in text if ord(char) < 32 and char not in "\n\r\t")
    garbled = replacement_count > max(2, len(text) // 1000) or mojibake_count > 3 or control_count > 0
    report["possible_garbled_text"] = garbled
    if garbled:
        warnings.append("Possible garbled text or invalid replacement characters detected.")

    repeats = repeated_lines(text)
    report["possible_repeated_headers"] = repeats[:20]
    if repeats:
        warnings.append(f"{len(repeats)} short line(s) repeat at least three times.")
    passage_repeats = repeated_passages(text)
    report["possible_repeated_passages"] = passage_repeats[:20]
    if passage_repeats:
        warnings.append(f"{len(passage_repeats)} long passage(s) appear repeatedly.")

    table_issues = 0
    for block in re.split(r"\n\s*\n", text):
        rows = [line for line in block.splitlines() if "|" in line]
        if len(rows) >= 2:
            counts = [row.count("|") for row in rows]
            has_separator = any(re.match(r"^\s*\|?\s*:?-{3,}", row) for row in rows)
            if max(counts) - min(counts) > 2 or not has_separator:
                table_issues += 1
    report["possible_table_issues"] = table_issues
    if table_issues:
        warnings.append(f"{table_issues} possible malformed Markdown table block(s).")

    formula_issues = 0
    if text.count("$$") % 2:
        formula_issues += 1
    if text.count("\\[") != text.count("\\]") or text.count("\\(") != text.count("\\)"):
        formula_issues += 1
    single_dollars = re.findall(r"(?<!\\)(?<!\$)\$(?!\$)", text)
    if len(single_dollars) % 2:
        formula_issues += 1
    report["possible_formula_delimiter_issues"] = formula_issues
    if formula_issues:
        warnings.append("Formula delimiters may be unbalanced.")

    reference_found = bool(REFERENCE_RE.search(text))
    report["reference_section_found"] = reference_found
    if re.search(r"\b(?:doi:|et al\.|references)\b", text, re.I) and not reference_found:
        warnings.append("Citation-like content exists but no References/Bibliography heading was found.")

    if pdf:
        report["source_pdf"] = str(pdf.resolve())
        pages, sampled_characters, pdf_error = pdf_stats(pdf)
        report["source_page_count"] = pages
        report["sampled_pdf_text_characters"] = sampled_characters
        if pdf_error:
            warnings.append(f"Could not inspect source PDF pages: {pdf_error}")
        elif pages and pages >= 3 and len(visible) < pages * 60:
            warnings.append("Markdown content is very short relative to the source page count.")

    if errors:
        report["result"] = "FAIL"
    elif warnings:
        report["result"] = "WARNING"
    else:
        report["result"] = "PASS"
    return report


def print_report(report: dict) -> None:
    print(f"Validation result: {report['result']}")
    print(f"Markdown file: {report['markdown_file']}")
    print(f"Image count: {report.get('image_count', 0)}")
    print(f"Missing images: {len(report.get('missing_images', []))}")
    print(f"Heading count: {report.get('heading_count', 0)}")
    print(f"Possible repeated headers: {len(report.get('possible_repeated_headers', []))}")
    print(f"Possible garbled text: {report.get('possible_garbled_text', False)}")
    print(f"Possible table issues: {report.get('possible_table_issues', 0)}")
    print(f"Possible formula delimiter issues: {report.get('possible_formula_delimiter_issues', 0)}")
    print(f"Reference section found: {report.get('reference_section_found', False)}")
    if "source_page_count" in report:
        print(f"Source PDF pages: {report.get('source_page_count')}")
    print("Warnings:")
    for warning in report.get("warnings", []):
        print(f"- {warning}")
    for error in report.get("errors", []):
        print(f"- ERROR: {error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("markdown", type=Path)
    parser.add_argument("--pdf", type=Path, help="Source PDF for page/content comparison.")
    parser.add_argument("--json", dest="json_path", type=Path, help="Also write a JSON report.")
    parser.add_argument("--strict", action="store_true", help="Return nonzero for WARNING as well as FAIL.")
    args = parser.parse_args()
    report = validate(args.markdown, args.pdf)
    print_report(report)
    if args.json_path:
        args.json_path.parent.mkdir(parents=True, exist_ok=True)
        args.json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    if report["result"] == "FAIL" or (args.strict and report["result"] == "WARNING"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
