"""
clean.py — Stage 2: Clean parsed Markdown

Input:  parsed_markdowns/*.md
Output: cleaned_markdowns/*.md

Usage:
    python clean.py
    python clean.py --force
"""
from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path

_ROOT = Path(__file__).parent.parent
PARSED_DIR = _ROOT / "data" / "parsed_markdowns"
CLEANED_DIR = _ROOT / "data" / "cleaned_markdowns"

_HEADING_RE = re.compile(r"^\s*#{1,6}\s+")
_LIST_RE = re.compile(r"^\s*([*\-]|\d+\.)\s+")
_BLANK_RE = re.compile(r"^\s*$")
_TABLE_ROW_RE = re.compile(r"^\s*\|.*\|\s*$")
_TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$")
_SENTENCE_END_RE = re.compile(r"[.!?:]\s*$")
_LOWER_START_RE = re.compile(r"^[a-z(\[\{\)\]\}]")
_DOWNLOAD_URL_RE = re.compile(r"Downloaded from https?://", re.IGNORECASE)
_HEADING_NORM_RE = re.compile(r"^\s*(#{1,6})\s+(.*)")


def _is_table_line(line: str) -> bool:
    return bool(_TABLE_ROW_RE.match(line) or _TABLE_SEP_RE.match(line))


def _is_protected(line: str) -> bool:
    return bool(_BLANK_RE.match(line) or _LIST_RE.match(line) or _is_table_line(line))


def _detect_repeating_lines(text: str, min_length: int = 5, freq_threshold: float = 0.02) -> set[str]:
    raw_lines = [l.strip() for l in text.split("\n")]
    filtered = [l for l in raw_lines if len(l) >= min_length and not _is_protected(l)]
    total = len(filtered)
    if total == 0:
        return set()
    counter = Counter(filtered)
    return {line for line, count in counter.items() if count > 2 and count / total >= freq_threshold}


def _normalize_whitespace(text: str) -> str:
    text = re.sub(r"^[ \t]+", "", text, flags=re.MULTILINE)
    text = re.sub(r"[ \t]+$", "", text, flags=re.MULTILINE)
    text = re.sub(r"[ ]{2,}", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def _remove_bold_asterisks(text: str) -> str:
    return re.sub(r"\*\*(.*?)\*\*", r"\1", text)


def _fix_broken_words(text: str) -> str:
    text = re.sub(r"(\w+)-\n(\w+)", r"\1\2", text)
    text = re.sub(r"([a-zA-Z0-9]+)\s+(-\w+)", r"\1\2", text)
    return text


def _normalize_bullets(text: str) -> str:
    return re.sub(r"^\s*#*\s*([•▪◦●○]|(`o`))+\s*", "\n- ", text, flags=re.MULTILINE)


def _remove_download_urls(text: str) -> str:
    lines = [l for l in text.split("\n") if not _DOWNLOAD_URL_RE.search(l)]
    return "\n".join(lines)


def _merge_lines(text: str) -> str:
    lines = text.split("\n")
    merged: list[str] = []
    i = 0

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if _is_table_line(line):
            merged.append(line)
            i += 1
            continue

        if re.match(r"\s*---\s*", line):
            i += 1
            continue

        if _BLANK_RE.match(line):
            if merged:
                prev = merged[-1]
                j = i + 1
                while j < len(lines) and _BLANK_RE.match(lines[j]):
                    j += 1
                nxt = lines[j].strip() if j < len(lines) else ""
                if j < len(lines) and not _SENTENCE_END_RE.search(prev) and _LOWER_START_RE.match(nxt):
                    i += 1
                    continue
                if _LIST_RE.match(prev) and _LIST_RE.match(nxt):
                    i += 1
                    continue
            if not merged or merged[-1] != "":
                merged.append("")
            i += 1
            continue

        if _HEADING_RE.match(line):
            merged.append(stripped)
            i += 1
            continue

        if _LIST_RE.match(line):
            merged.append(stripped)
            i += 1
            continue

        if merged:
            prev = merged[-1]
            if _is_table_line(prev):
                merged.append(stripped)
                i += 1
                continue
            if _LIST_RE.match(prev):
                merged[-1] = prev + " " + stripped
                i += 1
                continue
            if not _HEADING_RE.match(prev) and not _SENTENCE_END_RE.search(prev) and _LOWER_START_RE.match(stripped):
                merged[-1] = prev + " " + stripped
                i += 1
                continue

        merged.append(stripped)
        i += 1

    return "\n".join(merged)


def _clean_and_normalize_headings(text: str) -> str:
    MAX_HEADER_WORDS = 10
    lines = text.split("\n")
    out: list[str] = []
    seen: set[str] = set()
    prev_level = 0
    i = 0

    while i < len(lines):
        line = lines[i].strip()
        m = _HEADING_NORM_RE.match(line)
        if not m:
            out.append(lines[i])
            i += 1
            continue

        hashes, content = m.groups()
        combined = content
        j = i + 1
        while j < len(lines):
            nxt = lines[j].strip()
            nm = _HEADING_NORM_RE.match(nxt)
            if nm:
                combined += " " + nm.group(2)
                j += 1
            elif nxt and len(nxt.split()) <= 6:
                combined += " " + nxt
                j += 1
            else:
                break

        words = combined.split()
        has_content = any(
            lines[k].strip() and not _HEADING_NORM_RE.match(lines[k].strip())
            for k in range(j, len(lines))
            if not _HEADING_NORM_RE.match(lines[k].strip())
        )

        if len(words) > MAX_HEADER_WORDS or not has_content:
            out.append(combined)
            i = j
            continue

        lvl = len(hashes)
        key = combined.lower().strip()

        if prev_level and lvl > prev_level + 1:
            lvl = prev_level + 1
        if key in seen:
            lvl = min(lvl + 1, 6)
        else:
            seen.add(key)
        if lvl == 1 and prev_level != 0:
            lvl = 2

        out.append("#" * lvl + " " + combined.strip())
        prev_level = lvl
        i = j

    return "\n".join(out)


def _remove_headers_footers(text: str) -> str:
    lines = text.split("\n")
    cleaned = []
    for line in lines:
        if re.match(r"^\s*(\*\*)?\d{1,3}(\*\*)?\s*$", line):
            continue
        if len(line.strip()) < 3:
            cleaned.append(line)
            continue
        if line.isupper() and len(line.split()) > 5:
            continue
        cleaned.append(line)
    return "\n".join(cleaned)


def _remove_repeating_lines(text: str) -> str:
    repeating = _detect_repeating_lines(text)
    return "\n".join(l for l in text.split("\n") if l.strip() not in repeating)


def _clean_text(text: str) -> str:
    text = _normalize_whitespace(text)
    text = _remove_bold_asterisks(text)
    text = _fix_broken_words(text)
    text = _normalize_bullets(text)
    text = _remove_download_urls(text)
    text = _merge_lines(text)
    text = _clean_and_normalize_headings(text)
    text = _remove_repeating_lines(text)
    text = _remove_headers_footers(text)
    text = _normalize_whitespace(text)
    return text


def main(force: bool) -> None:
    CLEANED_DIR.mkdir(exist_ok=True)
    mds = sorted(PARSED_DIR.glob("*.md"))
    if not mds:
        print("[WARN] No markdown files in parsed_markdowns/ — run parse.py first")
        return
    for path in mds:
        out = CLEANED_DIR / path.name
        if out.exists() and not force:
            print(f"[SKIP] {path.name} — already cleaned")
            continue
        text = path.read_text(encoding="utf-8")
        cleaned = _clean_text(text)
        out.write_text(cleaned, encoding="utf-8")
        print(f"[OK]   {path.name} → cleaned")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stage 2: Clean parsed Markdown.")
    parser.add_argument("--force", action="store_true", help="Rebuild even if output exists")
    args = parser.parse_args()
    main(args.force)
