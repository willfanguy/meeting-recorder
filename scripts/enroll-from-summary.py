#!/usr/bin/env python3
"""Enroll speakers based on the AI summary's Speaker Identification table.

The meeting-intelligence-processor already does context-based identification
(e.g. "Speaker D = Tony Hawke, high confidence: 'big boss,' runs the agenda")
and writes a table into the meeting note. This script closes the loop by
reading those tables and running enroll-speakers.py for high-confidence rows.

Default behavior: only enroll rows with confidence == "high". Medium and low
need human eyes. Rows where Likely Identity is "unclear" or empty are skipped.

Usage:
    # Process a specific meeting
    enroll-from-summary.py "path/to/2026-05-08 1100 - AI-F Stand up.md"

    # Process the N most recent meetings (excluding ones already processed)
    enroll-from-summary.py --recent 10

    # Dry-run (show what would be enrolled, do nothing)
    enroll-from-summary.py --recent 10 --dry-run
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ENROLL_SCRIPT = SCRIPT_DIR / "enroll-speakers.py"
VENV_PYTHON = SCRIPT_DIR / ".venv" / "bin" / "python"
RECORDINGS_DIR = Path.home() / "Meeting Transcriptions"
NOTES_DIR = Path.home() / "Vaults/HigherJump/4. Resources/Meeting Notes"

# Identities that are never real people — skip these
SKIP_IDENTITIES = {"unclear", "unknown", "n/a", "tbd", "?", ""}

# Names where the AI summary's transcription is ambiguous and human review
# is required before enrolling. "Ali" was a real person who left Glassdoor;
# "Ali" appearing in new meetings is more likely a mis-hearing of "Alli"
# (see feedback_ali_vs_alli.md). Force manual review rather than guess.
SKIP_FOR_MANUAL_REVIEW = {"ali"}

# Normalize variant spellings to the canonical library name. The library is
# keyed by exact name match — without this map, "Phil Mansour" from an AI
# summary would create a duplicate entry alongside the existing "Phil".
NAME_NORMALIZATION = {
    "phil mansour": "Phil",
    "phil m.": "Phil",
    "phil m": "Phil",
    "ellie": "Alli",
    "allie": "Alli",
}


def canonicalize_identity(identity):
    """Map an AI-summary identity to its canonical library name.
    Returns None if the identity should be skipped entirely.
    """
    key = identity.strip().lower()
    if key in SKIP_IDENTITIES:
        return None
    if key in SKIP_FOR_MANUAL_REVIEW:
        return None
    return NAME_NORMALIZATION.get(key, identity.strip())


def find_speaker_id_section(content):
    """Locate the Speaker Identification section. Returns (start_idx, end_idx)
    of the section body, or (None, None) if not found.
    """
    section_match = re.search(
        r"^#{2,3}\s+Speaker Identification[^\n]*$",
        content,
        re.MULTILINE,
    )
    if not section_match:
        return None, None

    start = section_match.end()
    # End at next heading of same/higher level OR horizontal rule
    after = content[start:]
    end_match = re.search(r"^(#{1,3}\s|---\s*$)", after, re.MULTILINE)
    end = start + end_match.start() if end_match else len(content)
    return start, end


def parse_identification_table(section_body):
    """Parse the Markdown table inside a Speaker Identification section.

    Returns list of dicts: {"label", "identity", "confidence", "context"}.
    Skips header/separator rows. Tolerant of column count mismatches.
    """
    rows = []
    for raw_line in section_body.splitlines():
        line = raw_line.strip()
        if not line.startswith("|") or not line.endswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 3:
            continue
        # Skip header and separator
        first = cells[0].lower()
        if first in ("label", "speaker") or first.startswith("---") or first.startswith(":---"):
            continue

        label = cells[0]
        identity = cells[1]
        confidence = cells[2].lower() if len(cells) > 2 else ""
        context = cells[3] if len(cells) > 3 else ""

        # Sanitize identity — strip parentheticals like "Tony Hawke (boss)"
        identity_clean = re.sub(r"\s*\([^)]+\)\s*", " ", identity).strip()
        rows.append({
            "label": label,
            "identity": identity_clean,
            "confidence": confidence,
            "context": context,
        })
    return rows


def find_diarization_json(meeting_note_path):
    """Find the .diarization.json sidecar matching a meeting note.

    Tries the exact filename stem first, then falls back to bracket-stripped
    forms ([SM-685] vs SM-685).
    """
    stem = meeting_note_path.stem
    candidate = RECORDINGS_DIR / f"{stem}.diarization.json"
    if candidate.is_file():
        return candidate
    # Try adding back any bracketed suffix that might have been stripped
    # (rare; mainly relevant for meetings whose note name dropped brackets)
    for json_path in RECORDINGS_DIR.glob("*.diarization.json"):
        json_stem = json_path.name.removesuffix(".diarization.json")
        # Compare with bracket characters removed from both sides
        normalize = lambda s: re.sub(r"[\[\]]", "", s)
        if normalize(json_stem) == normalize(stem):
            return json_path
    return None


def find_recent_meeting_notes(n):
    """Return the N most recent .md files in NOTES_DIR by mtime."""
    notes = sorted(NOTES_DIR.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    return notes[:n]


def process_note(note_path, dry_run=False):
    """Process one meeting note. Returns dict of {label: identity} that were enrolled."""
    if not note_path.is_file():
        return {"_status": "missing", "_msg": f"note not found: {note_path}"}

    content = note_path.read_text()
    start, end = find_speaker_id_section(content)
    if start is None:
        return {"_status": "no-section"}

    rows = parse_identification_table(content[start:end])
    if not rows:
        return {"_status": "empty-table"}

    # Filter to high-confidence rows with real identities
    candidates = []
    skipped_for_review = []
    for row in rows:
        if row["confidence"] != "high":
            continue
        if not row["label"].startswith("Speaker "):
            # Already enrolled (real name in label column) — skip
            continue
        canonical = canonicalize_identity(row["identity"])
        if canonical is None:
            if row["identity"].strip().lower() in SKIP_FOR_MANUAL_REVIEW:
                skipped_for_review.append(row)
            continue
        # Use the canonical name for enrollment
        candidates.append({**row, "identity": canonical})

    if not candidates:
        if skipped_for_review:
            return {
                "_status": "needs-review",
                "_msg": ", ".join(f"{r['label']}={r['identity']}" for r in skipped_for_review),
            }
        return {"_status": "no-high-confidence"}

    json_path = find_diarization_json(note_path)
    if json_path is None:
        return {"_status": "no-sidecar", "_msg": f"no .diarization.json for {note_path.stem}"}

    if dry_run:
        return {
            "_status": "would-enroll",
            **{r["label"]: r["identity"] for r in candidates},
        }

    # Build a single enroll-speakers.py invocation with all assignments
    assigns = [f"{r['label']}={r['identity']}" for r in candidates]
    cmd = [
        str(VENV_PYTHON),
        str(ENROLL_SCRIPT),
        "--diarization-json", str(json_path),
        "--assign", *assigns,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return {"_status": "timeout"}

    if result.returncode != 0:
        return {
            "_status": "enroll-failed",
            "_msg": f"exit {result.returncode}: {result.stderr[:300]}",
        }

    return {
        "_status": "enrolled",
        **{r["label"]: r["identity"] for r in candidates},
    }


def main():
    parser = argparse.ArgumentParser(
        description="Enroll speakers from AI-summary identification tables"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("note", nargs="?", help="Path to a single meeting note .md")
    group.add_argument("--recent", type=int, metavar="N",
                       help="Process the N most recent meeting notes")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be enrolled, do nothing")
    args = parser.parse_args()

    if args.recent:
        notes = find_recent_meeting_notes(args.recent)
    else:
        notes = [Path(args.note)]

    summary = {"enrolled": 0, "skipped": 0, "needs-review": 0, "errors": 0, "would-enroll": 0}

    for note in notes:
        result = process_note(note, dry_run=args.dry_run)
        status = result.pop("_status", "unknown")
        msg = result.pop("_msg", None)
        if status in ("enrolled", "would-enroll"):
            assignments = ", ".join(f"{k}={v}" for k, v in result.items())
            print(f"  {status}: {note.stem}")
            print(f"     {assignments}")
            summary["enrolled" if status == "enrolled" else "would-enroll"] += len(result)
        elif status == "needs-review":
            print(f"  needs-review: {note.stem}")
            print(f"     {msg}")
            summary["needs-review"] += 1
        elif status in ("no-section", "empty-table", "no-high-confidence"):
            summary["skipped"] += 1
        else:
            print(f"  {status}: {note.stem}" + (f" — {msg}" if msg else ""))
            summary["errors"] += 1

    print()
    print(f"Done — {summary}")


if __name__ == "__main__":
    main()
