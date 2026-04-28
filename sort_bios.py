#!/usr/bin/env python3
r"""
RetroArch BIOS Sorter

Scrapes RetroArch core documentation pages for BIOS file lists and sorts a
flat BIOS directory into platform subdirectories, preserving any subdirectory
structure declared by the core docs (e.g. dc/dc_boot.bin).

Usage (single core):
    python sort_bios.py --source "C:\Users\...\bios" ^
                        --url https://docs.libretro.com/library/opera/

Usage (batch - all cores from BIOS hub):
    python sort_bios.py --source "C:\Users\...\bios" --batch --dry-run
"""

import argparse
import html as html_module
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# HTML parsing helpers (stdlib only)
# ---------------------------------------------------------------------------

TABLE_RE = re.compile(r"<table[^>]*>(.*?)</table>", re.DOTALL | re.IGNORECASE)
ROW_RE   = re.compile(r"<tr[^>]*>(.*?)</tr>",       re.DOTALL | re.IGNORECASE)
CELL_RE  = re.compile(r"<t[hd][^>]*>(.*?)</t[hd]>", re.DOTALL | re.IGNORECASE)
TAG_RE   = re.compile(r"<[^>]+>")
HREF_RE  = re.compile(r'href="([^"]+)"')


def strip_html(raw: str) -> str:
    return TAG_RE.sub("", raw).strip()


def parse_tables(html: str):
    """
    Extract all tables from HTML.
    Returns a list of tables, where each table is a list of rows,
    and each row is a list of dicts: {'text': str, 'hrefs': [str, ...]}
    """
    tables = []
    for tmatch in TABLE_RE.finditer(html):
        rows = []
        for rmatch in ROW_RE.finditer(tmatch.group(1)):
            cells = []
            for cmatch in CELL_RE.finditer(rmatch.group(1)):
                cell_html = cmatch.group(1)
                hrefs = HREF_RE.findall(cell_html)
                text = html_module.unescape(strip_html(cell_html))
                cells.append({"text": text, "hrefs": hrefs})
            if cells:
                rows.append(cells)
        if rows:
            tables.append(rows)
    return tables


# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------

USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"


def fetch_text(url: str, timeout: int = 30) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


# ---------------------------------------------------------------------------
# BIOS Hub scraping
# ---------------------------------------------------------------------------

BIOS_HUB_URL = "https://docs.libretro.com/library/bios/"


def parse_bios_hub(html: str):
    """
    Parse the BIOS Information Hub page.
    Returns list of (platform_name, core_page_url) tuples.
    """
    tables = parse_tables(html)
    cores = []
    for table in tables:
        if not table:
            continue
        headers = [c["text"].lower() for c in table[0]]
        if "system" not in headers or "link" not in headers:
            continue
        sys_idx = headers.index("system")
        link_idx = headers.index("link")
        for row in table[1:]:
            if len(row) <= max(sys_idx, link_idx):
                continue
            platform = row[sys_idx]["text"].strip()
            hrefs = row[link_idx]["hrefs"]
            if not hrefs:
                continue
            # href looks like ../opera/#bios  -> resolve to full URL
            raw_href = hrefs[0]
            full_url = urllib.parse.urljoin(BIOS_HUB_URL, raw_href)
            # Strip fragment so we fetch the page itself
            page_url = full_url.split("#")[0]
            cores.append((platform, page_url))
    return cores


# ---------------------------------------------------------------------------
# Core page scraping
# ---------------------------------------------------------------------------

def parse_core_bios_files(html: str):
    """
    Parse a single core docs page and return a list of BIOS filenames
    (including any subdirectory prefix like 'dc/dc_boot.bin').
    """
    tables = parse_tables(html)
    filenames = []
    for table in tables:
        if not table:
            continue
        headers = [c["text"].lower() for c in table[0]]
        if "filename" not in headers:
            continue
        fname_idx = headers.index("filename")
        for row in table[1:]:
            if len(row) <= fname_idx:
                continue
            fname = row[fname_idx]["text"].strip()
            # Normalize path separators
            fname = fname.replace("\\", "/")
            if fname:
                filenames.append(fname)
    return filenames


# ---------------------------------------------------------------------------
# File scanning & sorting
# ---------------------------------------------------------------------------

def scan_source_files(source_dir: str):
    """
    Walk source_dir recursively and return a dict:
        basename_lower -> [(full_path, rel_path), ...]
    """
    files = {}
    root = Path(source_dir).resolve()
    for p in root.rglob("*"):
        if p.is_file():
            rel = p.relative_to(root).as_posix()
            basename = p.name.lower()
            files.setdefault(basename, []).append((str(p), rel))
    return files


def sort_files(source_dir: str, platform: str, filenames, source_files: dict,
               dry_run: bool = False):
    """
    Move/copy files matching `filenames` into `source_dir/platform/`.
    `filenames` entries may contain slashes (e.g. 'dc/dc_boot.bin').
    `source_files` is mutated (used sources are removed).
    Returns (moved_list, skipped_list, ambiguous_list).
    """
    moved = []
    skipped = []
    ambiguous = []

    # Group scraped filenames by basename
    by_basename = {}
    for fname in filenames:
        basename = Path(fname).name.lower()
        by_basename.setdefault(basename, []).append((platform, fname))

    for basename, scrapes in by_basename.items():
        sources = source_files.get(basename)
        if not sources:
            continue

        # Ambiguity: one source file wanted by multiple *different* platforms
        unique_platforms = set(p for p, _ in scrapes)
        if len(unique_platforms) > 1 and len(sources) == 1:
            ambiguous.append((basename, [s[0] for s in sources], scrapes))
            continue

        used = set()
        for plat, scraped_rel in scrapes:
            src_full = None
            src_rel = None

            # Prefer exact relative-path match among unused sources
            for full, rel in sources:
                if full in used:
                    continue
                if rel.lower() == scraped_rel.lower():
                    src_full, src_rel = full, rel
                    break

            # Otherwise grab first unused source
            if src_full is None:
                for full, rel in sources:
                    if full not in used:
                        src_full, src_rel = full, rel
                        break

            if src_full is None:
                continue

            dest_rel = Path(plat) / scraped_rel
            dest_full = str(Path(source_dir) / dest_rel)

            # Already in correct place?
            if str(Path(src_full).resolve()).lower() == str(Path(dest_full).resolve()).lower():
                used.add(src_full)
                continue

            if Path(dest_full).exists():
                skipped.append((src_full, dest_full, "destination exists"))
                used.add(src_full)
                continue

            if dry_run:
                moved.append((src_full, dest_full, "dry-run"))
            else:
                Path(dest_full).parent.mkdir(parents=True, exist_ok=True)
                shutil.move(src_full, dest_full)
                moved.append((src_full, dest_full, "moved"))

            used.add(src_full)

        # Prune used sources from global pool
        for full, rel in list(sources):
            if full in used:
                sources.remove((full, rel))
        if not sources:
            del source_files[basename]

    return moved, skipped, ambiguous


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Sort RetroArch BIOS files into platform subdirectories."
    )
    parser.add_argument(
        "--source", required=True,
        help="Path to the flat BIOS directory."
    )
    parser.add_argument(
        "--url",
        help="Single core docs URL to scrape."
    )
    parser.add_argument(
        "--name",
        help="Override platform name for single-core mode."
    )
    parser.add_argument(
        "--batch", action="store_true",
        help="Scrape the BIOS hub and process every core listed."
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Preview changes without moving any files."
    )
    args = parser.parse_args()

    source_dir = Path(args.source).resolve()
    if not source_dir.is_dir():
        print(f"ERROR: Source directory does not exist: {source_dir}", file=sys.stderr)
        sys.exit(1)

    # ------------------------------------------------------------------
    # Gather platform -> filenames mappings
    # ------------------------------------------------------------------
    platform_files = []   # list of (platform_name, [filenames, ...])

    if args.batch:
        print("Fetching BIOS Information Hub...")
        try:
            hub_html = fetch_text(BIOS_HUB_URL)
        except urllib.error.URLError as e:
            print(f"ERROR: Failed to fetch BIOS hub: {e}", file=sys.stderr)
            sys.exit(1)

        cores = parse_bios_hub(hub_html)
        print(f"Found {len(cores)} cores in BIOS hub.")

        for idx, (platform, page_url) in enumerate(cores, 1):
            print(f"  [{idx}/{len(cores)}] Fetching {platform} ...", end=" ", flush=True)
            try:
                page_html = fetch_text(page_url)
            except urllib.error.URLError as e:
                print(f"FAILED ({e})")
                continue
            fnames = parse_core_bios_files(page_html)
            print(f"{len(fnames)} file(s)")
            if fnames:
                platform_files.append((platform, fnames))

    elif args.url:
        platform = args.name or Path(urllib.parse.urlparse(args.url).path).name or "Unknown"
        print(f"Fetching {args.url} ...")
        try:
            page_html = fetch_text(args.url)
        except urllib.error.URLError as e:
            print(f"ERROR: Failed to fetch page: {e}", file=sys.stderr)
            sys.exit(1)
        fnames = parse_core_bios_files(page_html)
        print(f"Found {len(fnames)} BIOS file(s) for platform '{platform}'.")
        platform_files.append((platform, fnames))

    else:
        parser.error("Either --batch or --url is required.")

    if not platform_files:
        print("No BIOS data found. Nothing to do.")
        sys.exit(0)

    # ------------------------------------------------------------------
    # Scan source directory
    # ------------------------------------------------------------------
    print(f"\nScanning source directory: {source_dir}")
    source_files = scan_source_files(str(source_dir))
    print(f"Found {sum(len(v) for v in source_files.values())} file(s) total.\n")

    # ------------------------------------------------------------------
    # Sort
    # ------------------------------------------------------------------
    all_moved = []
    all_skipped = []
    all_ambiguous = []

    for platform, fnames in platform_files:
        moved, skipped, ambiguous = sort_files(
            str(source_dir), platform, fnames, source_files, dry_run=args.dry_run
        )
        all_moved.extend(moved)
        all_skipped.extend(skipped)
        all_ambiguous.extend(ambiguous)

    # ------------------------------------------------------------------
    # Report
    # ------------------------------------------------------------------
    action = "Would move" if args.dry_run else "Moved"
    print(f"\n{'='*60}")
    print(f"{action}: {len(all_moved)} file(s)")
    for src, dst, status in all_moved:
        rel_src = Path(src).relative_to(source_dir)
        rel_dst = Path(dst).relative_to(source_dir)
        print(f"  {rel_src}  ->  {rel_dst}")

    if all_skipped:
        print(f"\nSkipped: {len(all_skipped)} file(s)")
        for src, dst, reason in all_skipped:
            rel_src = Path(src).relative_to(source_dir)
            rel_dst = Path(dst).relative_to(source_dir)
            print(f"  {rel_src}  ->  {rel_dst}  ({reason})")

    if all_ambiguous:
        print(f"\nAmbiguous (not moved): {len(all_ambiguous)} file(s)")
        for basename, srcs, scrapes in all_ambiguous:
            platforms = ", ".join(sorted(set(p for p, _ in scrapes)))
            print(f"  {basename}  matches platforms: {platforms}")

    remaining = sum(len(v) for v in source_files.values())
    print(f"\nUnmatched files remaining in source: {remaining}")
    print(f"{'='*60}\n")

    if args.dry_run:
        print("This was a DRY RUN. No files were moved.")
        print("Remove --dry-run to apply changes.\n")


if __name__ == "__main__":
    main()
