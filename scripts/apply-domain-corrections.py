#!/usr/bin/env python3
"""Apply domain-specific corrections to meeting transcripts.

Reads a JSON dictionary of known transcription errors and applies
case-insensitive replacements to .txt and .srt files. Logs all
changes for transparency.

Usage:
    apply-domain-corrections.py <transcript_file> [--dict <path>] [--dry-run]

The script auto-detects companion files:
  - Given foo.txt, also corrects foo.srt if it exists
  - Given foo.srt, also corrects foo.txt if it exists
"""

import argparse
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DICT = os.path.join(SCRIPT_DIR, "domain-corrections.json")
LOG_FILE = "/tmp/meeting-recorder.log"


def log(msg):
    with open(LOG_FILE, "a") as f:
        f.write(f"{msg}\n")


def load_corrections(dict_path):
    """Load and flatten the corrections dictionary."""
    with open(dict_path) as f:
        data = json.load(f)

    corrections = {}
    for category, entries in data.items():
        if category.startswith("_"):
            continue
        for wrong, right in entries.items():
            # Skip identity mappings (used as documentation placeholders)
            if wrong.lower() != right.lower():
                corrections[wrong] = right
    return corrections


def build_pattern(wrong):
    """Build a regex pattern for case-insensitive whole-word matching.

    Uses word boundaries but handles edge cases:
    - Multi-word phrases match as-is
    - Single words get word boundary anchors
    """
    escaped = re.escape(wrong)
    return re.compile(r'\b' + escaped + r'\b', re.IGNORECASE)


def apply_corrections(text, corrections):
    """Apply all corrections to text. Returns (corrected_text, changes_list)."""
    changes = []

    # Sort by length descending so longer phrases match first
    # e.g., "Aaron Delevic" before "Aaron"
    sorted_corrections = sorted(corrections.items(), key=lambda x: len(x[0]), reverse=True)

    for wrong, right in sorted_corrections:
        pattern = build_pattern(wrong)
        matches = pattern.findall(text)
        if matches:
            text = pattern.sub(right, text)
            changes.append((wrong, right, len(matches)))

    return text, changes


def process_file(filepath, corrections, dry_run=False):
    """Apply corrections to a single file. Returns number of changes."""
    if not os.path.isfile(filepath):
        return 0

    with open(filepath, "r") as f:
        original = f.read()

    corrected, changes = apply_corrections(original, corrections)

    if not changes:
        return 0

    total = sum(count for _, _, count in changes)
    basename = os.path.basename(filepath)

    for wrong, right, count in changes:
        msg = f"Domain correction ({basename}): '{wrong}' -> '{right}' ({count}x)"
        log(msg)
        if dry_run:
            print(f"  [dry-run] {msg}")

    if not dry_run and corrected != original:
        with open(filepath, "w") as f:
            f.write(corrected)

    return total


def main():
    parser = argparse.ArgumentParser(description="Apply domain corrections to transcripts")
    parser.add_argument("transcript", help="Path to .txt or .srt transcript file")
    parser.add_argument("--dict", default=DEFAULT_DICT, help="Path to corrections JSON")
    parser.add_argument("--dry-run", action="store_true", help="Show changes without applying")
    args = parser.parse_args()

    if not os.path.isfile(args.dict):
        print(f"Error: Dictionary not found: {args.dict}", file=sys.stderr)
        sys.exit(1)

    corrections = load_corrections(args.dict)
    if not corrections:
        log("Domain corrections: dictionary empty, skipping")
        return

    # Determine companion files
    base, ext = os.path.splitext(args.transcript)
    files_to_process = [args.transcript]

    if ext == ".txt" and os.path.isfile(base + ".srt"):
        files_to_process.append(base + ".srt")
    elif ext == ".srt" and os.path.isfile(base + ".txt"):
        files_to_process.append(base + ".txt")

    total_changes = 0
    for filepath in files_to_process:
        changes = process_file(filepath, corrections, dry_run=args.dry_run)
        total_changes += changes

    if total_changes > 0:
        action = "would apply" if args.dry_run else "applied"
        log(f"Domain corrections: {action} {total_changes} correction(s) across {len(files_to_process)} file(s)")
    else:
        log("Domain corrections: no corrections needed")


if __name__ == "__main__":
    main()
