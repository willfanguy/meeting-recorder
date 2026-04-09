#!/usr/bin/env python3
"""Enroll speakers into the voice embedding library from diarization JSON sidecars.

Usage:
    # Assign speakers from a specific meeting
    scripts/.venv/bin/python scripts/enroll-speakers.py \
        --diarization-json "path/to/recording.diarization.json" \
        --assign "Speaker D=Judith Wilding" "Speaker E=Will Fanguy"

    # List all enrolled speakers
    scripts/.venv/bin/python scripts/enroll-speakers.py --list

    # Scan a directory for diarization JSONs and show available speakers
    scripts/.venv/bin/python scripts/enroll-speakers.py \
        --scan "$HOME/Meeting Transcriptions/" --interactive

    # Remove a speaker from the library
    scripts/.venv/bin/python scripts/enroll-speakers.py --remove "Will Fanguy"
"""

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from speaker_library import SpeakerLibrary, DEFAULT_LIBRARY_PATH


def load_embeddings_from_json(json_path):
    """Load speaker embeddings from a diarization JSON sidecar.

    Returns dict of {speaker_label: np.array} or None if no embeddings.
    """
    with open(json_path) as f:
        data = json.load(f)

    if "speaker_embeddings" not in data:
        return None

    embeddings = {}
    for label, values in data["speaker_embeddings"].items():
        embeddings[label] = np.array(values, dtype=np.float32)

    return embeddings


def cmd_assign(args):
    """Enroll speakers from a diarization JSON using explicit name assignments."""
    if not os.path.isfile(args.diarization_json):
        print(f"Error: file not found: {args.diarization_json}", file=sys.stderr)
        return 1

    embeddings = load_embeddings_from_json(args.diarization_json)
    if embeddings is None:
        print("Error: no speaker_embeddings in JSON (re-run diarization to extract them)",
              file=sys.stderr)
        return 1

    # Parse assignments: "Speaker D=Judith Wilding"
    assignments = {}
    for pair in args.assign:
        if "=" not in pair:
            print(f"Error: invalid assignment '{pair}' (expected 'Speaker X=Name')", file=sys.stderr)
            return 1
        label, name = pair.split("=", 1)
        label = label.strip()
        name = name.strip()
        if label not in embeddings:
            print(f"Warning: '{label}' not found in JSON. Available: {list(embeddings.keys())}",
                  file=sys.stderr)
            continue
        assignments[label] = name

    if not assignments:
        print("No valid assignments provided.", file=sys.stderr)
        return 1

    lib = SpeakerLibrary(path=args.library)
    lib.load()

    source = Path(args.diarization_json).stem.replace(".diarization", "")
    for label, name in assignments.items():
        emb = embeddings[label]
        lib.enroll(name, emb, source=source)
        count = lib.speakers[name]["sample_count"]
        print(f"  Enrolled: {name} <- {label} (sample #{count})")

    lib.save()
    print(f"\nLibrary saved: {args.library} ({len(lib)} speakers)")
    return 0


def cmd_list(args):
    """List all enrolled speakers."""
    lib = SpeakerLibrary(path=args.library)
    lib.load()

    if not lib.speakers:
        print("Library is empty.")
        return 0

    print(f"Speaker library: {args.library}")
    print(f"{'Name':<30} {'Samples':>8} {'Last Updated':>14}")
    print("-" * 55)
    for name, count, updated in lib.list_speakers():
        print(f"{name:<30} {count:>8} {updated:>14}")

    return 0


def cmd_remove(args):
    """Remove a speaker from the library."""
    lib = SpeakerLibrary(path=args.library)
    lib.load()

    if args.remove not in lib:
        print(f"Speaker '{args.remove}' not found in library.", file=sys.stderr)
        return 1

    del lib.speakers[args.remove]
    lib.save()
    print(f"Removed '{args.remove}' from library. {len(lib)} speakers remaining.")
    return 0


def cmd_scan(args):
    """Scan a directory for diarization JSONs and show/enroll speakers."""
    scan_dir = Path(args.scan)
    if not scan_dir.is_dir():
        print(f"Error: not a directory: {scan_dir}", file=sys.stderr)
        return 1

    json_files = sorted(scan_dir.glob("*.diarization.json"))
    if not json_files:
        print(f"No .diarization.json files found in {scan_dir}")
        return 0

    lib = SpeakerLibrary(path=args.library)
    lib.load()

    files_with_embeddings = []
    for json_path in json_files:
        embeddings = load_embeddings_from_json(json_path)
        if embeddings:
            files_with_embeddings.append((json_path, embeddings))

    if not files_with_embeddings:
        print("No diarization JSONs contain speaker embeddings.")
        print("Re-run diarization on existing recordings to extract embeddings.")
        return 0

    print(f"Found {len(files_with_embeddings)} meetings with embeddings:\n")

    if not args.interactive:
        # Just list what's available
        for json_path, embeddings in files_with_embeddings:
            meeting = json_path.stem.replace(".diarization", "")
            speakers = list(embeddings.keys())
            print(f"  {meeting}")
            for s in speakers:
                # Check if we can identify this speaker
                name, conf = lib.identify(embeddings[s])
                if name:
                    print(f"    {s} -> {name} ({conf:.2f})")
                else:
                    print(f"    {s} (unknown, best match: {conf:.2f})")
            print()
        return 0

    # Interactive mode
    for json_path, embeddings in files_with_embeddings:
        meeting = json_path.stem.replace(".diarization", "")
        print(f"\n--- {meeting} ---")
        print(f"Speakers: {list(embeddings.keys())}")

        for label, emb in embeddings.items():
            name, conf = lib.identify(emb)
            if name:
                print(f"  {label} -> auto-identified as {name} ({conf:.2f})")
                response = input(f"    Accept? [Y/n/name]: ").strip()
                if response.lower() in ("", "y", "yes"):
                    lib.enroll(name, emb)
                    print(f"    Updated {name}")
                elif response.lower() in ("n", "no"):
                    print(f"    Skipped")
                else:
                    lib.enroll(response, emb)
                    print(f"    Enrolled as {response}")
            else:
                print(f"  {label} -> unknown (best match: {conf:.2f})")
                response = input(f"    Name (or Enter to skip): ").strip()
                if response:
                    lib.enroll(response, emb)
                    print(f"    Enrolled as {response}")

    lib.save()
    print(f"\nLibrary saved: {args.library} ({len(lib)} speakers)")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Manage the speaker voice embedding library"
    )
    parser.add_argument(
        "--library", default=DEFAULT_LIBRARY_PATH,
        help=f"Path to speaker library JSON (default: {DEFAULT_LIBRARY_PATH})"
    )

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="List enrolled speakers")
    group.add_argument("--remove", metavar="NAME", help="Remove a speaker")
    group.add_argument(
        "--diarization-json", metavar="PATH",
        help="Diarization JSON to enroll from (use with --assign)"
    )
    group.add_argument(
        "--scan", metavar="DIR",
        help="Scan directory for diarization JSONs"
    )

    parser.add_argument(
        "--assign", nargs="+", metavar="'Speaker X=Name'",
        help="Speaker label to name mappings (use with --diarization-json)"
    )
    parser.add_argument(
        "--interactive", action="store_true",
        help="Interactive enrollment mode (use with --scan)"
    )

    args = parser.parse_args()

    if args.diarization_json and not args.assign:
        parser.error("--diarization-json requires --assign")

    if args.list:
        return cmd_list(args)
    elif args.remove:
        return cmd_remove(args)
    elif args.diarization_json:
        return cmd_assign(args)
    elif args.scan:
        return cmd_scan(args)


if __name__ == "__main__":
    sys.exit(main() or 0)
