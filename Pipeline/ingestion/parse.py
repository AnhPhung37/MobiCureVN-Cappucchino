"""
parse.py — Stage 1: PDF → Markdown

Input:  raw_pdfs/*.pdf
Output: parsed_markdowns/*.md

Usage:
    python parse.py
    python parse.py --force
"""
from __future__ import annotations

import argparse
from pathlib import Path

_ROOT = Path(__file__).parent.parent
PDF_DIR = _ROOT / "data" / "raw_pdfs"
PARSED_DIR = _ROOT / "data" / "parsed_markdowns"

_FAULTY_PDFS: set[str] = {
    "Bowel_Cancer_UK_Colonic_Stenting_V2.1",  # manually parsed; already in cleaned_markdowns
}


def main(force: bool) -> None:
    import pymupdf4llm

    PARSED_DIR.mkdir(exist_ok=True)
    pdfs = sorted(PDF_DIR.glob("*.pdf"))
    if not pdfs:
        print("[WARN] No PDFs found in raw_pdfs/")
        return

    for pdf in pdfs:
        stem = pdf.stem
        out = PARSED_DIR / f"{stem}.md"
        if stem in _FAULTY_PDFS:
            print(f"[SKIP] {pdf.name} — manually parsed, skipping")
            continue
        if out.exists() and not force:
            print(f"[SKIP] {pdf.name} — already parsed (use --force to rebuild)")
            continue
        try:
            md = pymupdf4llm.to_markdown(str(pdf))
            out.write_text(md, encoding="utf-8")
            print(f"[OK]   {pdf.name} → {out.name}")
        except Exception as exc:
            print(f"[FAIL] {pdf.name}: {exc}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stage 1: Parse PDFs to Markdown.")
    parser.add_argument("--force", action="store_true", help="Rebuild even if output exists")
    args = parser.parse_args()
    main(args.force)
