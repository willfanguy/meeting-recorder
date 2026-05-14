#!/usr/bin/env python3
"""Backfill diarization on existing meeting recordings with Priority 2 settings.

Re-runs diarize-transcript.py on every recording that already has a
.diarization.json sidecar, using soft speaker bounds (min=2, max=8) instead
of the old hard num_speakers cap. Updates each meeting note's ## Transcript
section in place, preserving the AI summary and any other curated content.

Per-meeting hint logic:
  - attendee_count == 2 (1:1) → --num-speakers 2 (hard constraint)
  - attendee_count >= 3      → --min-speakers 2 --max-speakers min(N, 8)
  - unknown                  → --min-speakers 2 --max-speakers 8

Designed to be safe to re-run: skips recordings missing the .wav, logs
errors and continues, idempotent on success.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import yaml
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
VENV_PYTHON = SCRIPT_DIR / ".venv" / "bin" / "python"
DIARIZE_SCRIPT = SCRIPT_DIR / "diarize-transcript.py"
RECORDINGS_DIR = Path.home() / "Meeting Transcriptions"
NOTES_DIR = Path.home() / "Vaults/HigherJump/4. Resources/Meeting Notes"
LOG_FILE = Path("/tmp/diarization-backfill.log")
STATE_FILE = Path("/tmp/diarization-backfill-progress.json")
SPEAKER_LIBRARY = Path.home() / ".config/meeting-recorder/speaker-embeddings.json"


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def load_progress(dry_run: bool = False) -> set:
    """Return set of stems already processed in a prior run.

    Why: pyannote diarization is 3-5 min per file. A crash on file 50 of 59
    used to restart from file 1. Now successive runs skip stems already
    completed via the state file at STATE_FILE.

    To force a full reprocess (e.g., after a diarization algorithm change),
    delete STATE_FILE manually before re-running.
    """
    if dry_run or not STATE_FILE.is_file():
        return set()
    try:
        return set(json.loads(STATE_FILE.read_text()).get("completed", []))
    except (json.JSONDecodeError, OSError):
        return set()


def mark_completed(stem: str, dry_run: bool = False) -> None:
    if dry_run:
        return
    completed = load_progress(dry_run=False)
    completed.add(stem)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"completed": sorted(completed)}, indent=2))
    tmp.replace(STATE_FILE)


def load_hf_token():
    config = PROJECT_DIR / "config.sh"
    if not config.is_file():
        return None
    for line in config.read_text().splitlines():
        m = re.match(r'^HF_TOKEN="([^"]+)"', line)
        if m:
            return m.group(1)
    return None


def parse_frontmatter(md_path):
    """Extract YAML frontmatter dict from a meeting note. Returns {} on failure."""
    try:
        content = md_path.read_text()
    except Exception:
        return {}
    m = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not m:
        return {}
    try:
        return yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        return {}


def get_attendee_count(md_path):
    """Return active attendee count, or None if unknown."""
    fm = parse_frontmatter(md_path)
    # Prefer explicit attendee_count if present
    if isinstance(fm.get("attendee_count"), int):
        return fm["attendee_count"]
    # Fall back to length of attendees list
    attendees = fm.get("attendees")
    if isinstance(attendees, list) and len(attendees) > 0:
        return len(attendees)
    return None


def build_diarize_args(attendee_count):
    """Translate attendee count into diarize-transcript.py CLI args."""
    if attendee_count == 2:
        return ["--num-speakers", "2"]
    if attendee_count is not None and attendee_count >= 3:
        cap = min(attendee_count, 8)
        return ["--min-speakers", "2", "--max-speakers", str(cap)]
    # Default for unknown
    return ["--min-speakers", "2", "--max-speakers", "8"]


def strip_srt_speaker_prefixes(srt_path, dest_path):
    """Copy SRT to dest with leading [Speaker X] / [Name] prefixes stripped."""
    content = srt_path.read_text()
    cleaned = re.sub(r"^\[[^\]]+\]\s+", "", content, flags=re.MULTILINE)
    dest_path.write_text(cleaned)


def update_md_transcript(md_path, new_txt_path):
    """Replace the ## Transcript section content with the new .txt content.
    Preserves frontmatter, AI summary, and any sections after the transcript.
    Returns True if updated, False if the section wasn't found.
    """
    if not md_path.is_file():
        return False
    content = md_path.read_text()
    lines = content.split("\n")

    transcript_idx = None
    for i, line in enumerate(lines):
        if line.strip() == "## Transcript":
            transcript_idx = i
            break
    if transcript_idx is None:
        return False

    # End of transcript = next "---" separator or next "## " header
    end_idx = len(lines)
    for i in range(transcript_idx + 1, len(lines)):
        if lines[i].strip() == "---" or lines[i].startswith("## "):
            end_idx = i
            break

    new_txt = new_txt_path.read_text().rstrip()
    before = "\n".join(lines[: transcript_idx + 1])
    after = "\n".join(lines[end_idx:])
    new_content = f"{before}\n\n{new_txt}\n\n{after}"
    md_path.write_text(new_content)
    return True


def find_meeting_note(stem):
    """Find the .md note matching a recording stem.
    Handles the [SM-685] / SM-685 bracket-mismatch case by trying both forms.
    """
    # Try exact match first
    candidate = NOTES_DIR / f"{stem}.md"
    if candidate.is_file():
        return candidate
    # Try stripping square brackets (e.g. [SM-685] → SM-685)
    no_brackets = re.sub(r"\[([^\]]+)\]", r"\1", stem)
    candidate = NOTES_DIR / f"{no_brackets}.md"
    if candidate.is_file():
        return candidate
    return None


def process_recording(json_path, hf_token, dry_run=False):
    """Re-diarize one meeting. Returns (status, msg) tuple."""
    stem = json_path.name.removesuffix(".diarization.json")
    wav = RECORDINGS_DIR / f"{stem}.wav"
    srt = RECORDINGS_DIR / f"{stem}.srt"
    txt = RECORDINGS_DIR / f"{stem}.txt"

    if not wav.is_file():
        return ("skip", f"no .wav")
    if not srt.is_file() or not txt.is_file():
        return ("skip", f"missing .srt or .txt")

    md_path = find_meeting_note(stem)
    attendee_count = get_attendee_count(md_path) if md_path else None
    args = build_diarize_args(attendee_count)
    hint = (
        f"num=2" if "--num-speakers" in args
        else f"max={args[args.index('--max-speakers') + 1]}"
    )

    if dry_run:
        return ("would-process", f"{hint} (attendees={attendee_count})")

    # Stage a clean SRT (no embedded speaker prefixes) for the new run
    with tempfile.TemporaryDirectory() as tmp:
        tmp_srt = Path(tmp) / "input.srt"
        strip_srt_speaker_prefixes(srt, tmp_srt)

        cmd = [
            str(VENV_PYTHON),
            str(DIARIZE_SCRIPT),
            str(wav),
            str(tmp_srt),
            str(txt),  # txt gets overwritten with new labels
            "--speaker-library",
            str(SPEAKER_LIBRARY),
        ] + args

        env = os.environ.copy()
        env["HF_TOKEN"] = hf_token

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, env=env, timeout=900
            )
        except subprocess.TimeoutExpired:
            return ("error", "diarization timed out (>15min)")

        if result.returncode != 0:
            return ("error", f"diarize exited {result.returncode}: {result.stderr[:200]}")

        # tmp_srt now has the labeled output — copy back to canonical location
        shutil.copy2(tmp_srt, srt)

    # Update meeting note transcript section if it exists
    md_updated = False
    if md_path:
        try:
            md_updated = update_md_transcript(md_path, txt)
        except Exception as e:
            return ("partial", f"sidecars updated, .md failed: {e}")

    suffix = " (md updated)" if md_updated else " (no .md)"
    return ("ok", f"{hint}{suffix}")


def main():
    dry_run = "--dry-run" in sys.argv

    log("=" * 60)
    log(f"Backfill starting (dry_run={dry_run})")

    if not VENV_PYTHON.is_file():
        log(f"FATAL: venv not found at {VENV_PYTHON}")
        sys.exit(1)

    hf_token = load_hf_token()
    if not hf_token and not dry_run:
        log("FATAL: HF_TOKEN not found in config.sh")
        sys.exit(1)

    if not RECORDINGS_DIR.is_dir():
        log(f"FATAL: recordings dir not found: {RECORDINGS_DIR}")
        sys.exit(1)

    json_files = sorted(RECORDINGS_DIR.glob("*.diarization.json"))
    log(f"Found {len(json_files)} recordings with diarization sidecars")

    completed = load_progress(dry_run=dry_run)
    if completed:
        log(f"Resuming: {len(completed)} stems already completed in prior run")

    counts = {"ok": 0, "skip": 0, "error": 0, "partial": 0, "would-process": 0, "already-done": 0}
    start = time.monotonic()

    for i, json_path in enumerate(json_files, 1):
        stem = json_path.name.removesuffix(".diarization.json")
        if stem in completed:
            log(f"[{i}/{len(json_files)}] {stem} — already done, skipping")
            counts["already-done"] += 1
            continue
        log(f"[{i}/{len(json_files)}] {stem}")
        status, msg = process_recording(json_path, hf_token, dry_run=dry_run)
        counts[status] = counts.get(status, 0) + 1
        log(f"  → {status}: {msg}")
        if status in ("ok", "partial", "skip"):
            mark_completed(stem, dry_run=dry_run)

    elapsed = time.monotonic() - start
    log("-" * 60)
    log(f"Backfill done in {elapsed/60:.1f}min — "
        + ", ".join(f"{k}={v}" for k, v in counts.items() if v > 0))

    # Non-zero exit if anything errored, so the wrapper knows not to set its
    # "all done forever" marker. Already-done + ok + skip + partial all count
    # as success (diarization itself completed; only md update may have failed).
    sys.exit(2 if counts.get("error", 0) > 0 else 0)


if __name__ == "__main__":
    main()
