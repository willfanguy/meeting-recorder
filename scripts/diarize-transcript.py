#!/usr/bin/env python3
"""
Speaker diarization for meeting transcripts.

Runs pyannote-audio diarization on a WAV file, merges speaker segments with
existing SRT timestamps, and rewrites the transcript with speaker labels.

Usage:
    scripts/.venv/bin/python scripts/diarize-transcript.py \
        <wav_file> <srt_file> <txt_file> \
        [--num-speakers N] [--participants "Name1, Name2, ..."]
"""

import argparse
import json
import os
import re
import string
import sys
from pathlib import Path

import numpy as np

LOG_FILE = "/tmp/meeting-recorder.log"


def log(msg):
    with open(LOG_FILE, "a") as f:
        f.write(f"{msg}\n")


def parse_srt(srt_path):
    """Parse an SRT file into a list of (index, start_sec, end_sec, text) tuples."""
    entries = []
    with open(srt_path, "r") as f:
        content = f.read()

    blocks = re.split(r"\n\n+", content.strip())
    for block in blocks:
        lines = block.strip().split("\n")
        if len(lines) < 3:
            continue

        try:
            idx = int(lines[0].strip())
        except ValueError:
            continue

        timestamp_match = re.match(
            r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})",
            lines[1].strip(),
        )
        if not timestamp_match:
            continue

        g = timestamp_match.groups()
        start_sec = int(g[0]) * 3600 + int(g[1]) * 60 + int(g[2]) + int(g[3]) / 1000
        end_sec = int(g[4]) * 3600 + int(g[5]) * 60 + int(g[6]) + int(g[7]) / 1000
        text = "\n".join(lines[2:]).strip()

        entries.append((idx, start_sec, end_sec, text))

    return entries


def format_timestamp(seconds):
    """Convert seconds to SRT timestamp format HH:MM:SS,mmm."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int(round((seconds % 1) * 1000))
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def assign_speakers(srt_entries, diarization):
    """Assign speaker labels to SRT entries based on diarization timeline overlap.

    Returns a list of (speaker_label, text) pairs in chronological order,
    splitting multi-speaker SRT entries at speaker boundaries.
    """
    labeled_segments = []

    for idx, start, end, text in srt_entries:
        if not text.strip():
            continue

        # Find all diarization segments overlapping this SRT entry
        overlaps = []
        for segment, _, speaker in diarization.itertracks(yield_label=True):
            seg_start = segment.start
            seg_end = segment.end

            # Calculate overlap
            overlap_start = max(start, seg_start)
            overlap_end = min(end, seg_end)
            if overlap_start < overlap_end:
                overlaps.append((overlap_start, overlap_end, speaker))

        if not overlaps:
            # No diarization data for this segment — attribute to unknown
            labeled_segments.append((start, end, "Unknown", text))
            continue

        # Sort overlaps by start time
        overlaps.sort(key=lambda x: x[0])

        # Calculate total time per speaker
        speaker_times = {}
        for ov_start, ov_end, speaker in overlaps:
            duration = ov_end - ov_start
            speaker_times[speaker] = speaker_times.get(speaker, 0) + duration

        srt_duration = end - start
        dominant_speaker = max(speaker_times, key=speaker_times.get)
        dominant_fraction = speaker_times[dominant_speaker] / srt_duration if srt_duration > 0 else 1

        if dominant_fraction >= 0.9 or len(speaker_times) == 1:
            # Single speaker dominates — assign full text
            labeled_segments.append((start, end, dominant_speaker, text))
        else:
            # Multiple speakers — split text proportionally by time
            words = text.split()
            total_words = len(words)
            if total_words == 0:
                continue

            # Group consecutive overlaps by speaker
            speaker_groups = []
            current_speaker = overlaps[0][2]
            current_duration = overlaps[0][1] - overlaps[0][0]
            group_start = overlaps[0][0]

            for ov_start, ov_end, speaker in overlaps[1:]:
                if speaker == current_speaker:
                    current_duration += ov_end - ov_start
                else:
                    speaker_groups.append((group_start, current_speaker, current_duration))
                    current_speaker = speaker
                    current_duration = ov_end - ov_start
                    group_start = ov_start
            speaker_groups.append((group_start, current_speaker, current_duration))

            # Distribute words proportionally
            total_overlap_time = sum(d for _, _, d in speaker_groups)
            word_idx = 0
            for i, (grp_start, speaker, duration) in enumerate(speaker_groups):
                if i == len(speaker_groups) - 1:
                    # Last group gets remaining words
                    segment_words = words[word_idx:]
                else:
                    fraction = duration / total_overlap_time if total_overlap_time > 0 else 0
                    word_count = max(1, round(fraction * total_words))
                    segment_words = words[word_idx : word_idx + word_count]
                    word_idx += word_count

                if segment_words:
                    segment_text = " ".join(segment_words)
                    labeled_segments.append((grp_start, grp_start + duration, speaker, segment_text))

    return labeled_segments


def build_speaker_map(diarization):
    """Map pyannote speaker IDs (SPEAKER_00) to friendly labels (Speaker A)."""
    speakers = sorted(set(label for _, _, label in diarization.itertracks(yield_label=True)))
    labels = list(string.ascii_uppercase)
    return {spk: f"Speaker {labels[i]}" if i < len(labels) else f"Speaker {i+1}"
            for i, spk in enumerate(speakers)}


def write_labeled_txt(labeled_segments, speaker_map, txt_path):
    """Write the labeled transcript to the TXT file."""
    lines = []
    prev_speaker = None

    for start, end, raw_speaker, text in labeled_segments:
        speaker = speaker_map.get(raw_speaker, raw_speaker)
        if speaker != prev_speaker:
            if prev_speaker is not None:
                lines.append("")  # blank line between speaker changes
            lines.append(f"**{speaker}:** {text}")
            prev_speaker = speaker
        else:
            # Same speaker continues — append text
            lines.append(text)

    with open(txt_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_labeled_srt(srt_entries, labeled_segments, speaker_map, srt_path):
    """Rewrite the SRT file with speaker labels prefixed to text."""
    # Build a mapping from SRT time ranges to dominant speaker
    srt_speaker_map = {}
    for idx, start, end, text in srt_entries:
        # Find the first labeled segment that overlaps this SRT entry
        best_speaker = None
        best_overlap = 0
        for seg_start, seg_end, raw_speaker, seg_text in labeled_segments:
            overlap_start = max(start, seg_start)
            overlap_end = min(end, seg_end)
            overlap = max(0, overlap_end - overlap_start)
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = raw_speaker
        srt_speaker_map[idx] = speaker_map.get(best_speaker, "Unknown") if best_speaker else "Unknown"

    with open(srt_path, "w") as f:
        for idx, start, end, text in srt_entries:
            speaker = srt_speaker_map.get(idx, "Unknown")
            f.write(f"{idx}\n")
            f.write(f"{format_timestamp(start)} --> {format_timestamp(end)}\n")
            f.write(f"[{speaker}] {text}\n\n")


def write_diarization_json(diarization, speaker_map, wav_path, diarize_output=None):
    """Write diarization timeline and speaker embeddings as a JSON sidecar."""
    json_path = Path(wav_path).with_suffix(".diarization.json")
    timeline = []
    for segment, _, speaker in diarization.itertracks(yield_label=True):
        timeline.append({
            "start": round(segment.start, 3),
            "end": round(segment.end, 3),
            "speaker_id": speaker,
            "speaker_label": speaker_map.get(speaker, speaker),
        })

    data = {
        "speakers": {v: k for k, v in speaker_map.items()},
        "speaker_count": len(speaker_map),
        "segments": timeline,
    }

    # Persist speaker embeddings (256-dim clustering centroids from pyannote)
    # Ordered by diarization.labels() — same order as speaker_map keys
    if (diarize_output is not None
            and hasattr(diarize_output, "speaker_embeddings")
            and diarize_output.speaker_embeddings is not None
            and diarize_output.speaker_embeddings.shape[0] > 0):
        embeddings = diarize_output.speaker_embeddings
        labels = diarization.labels()
        data["embedding_dimension"] = int(embeddings.shape[1])
        data["speaker_embeddings"] = {
            speaker_map.get(label, label): embeddings[i].tolist()
            for i, label in enumerate(labels)
            if i < embeddings.shape[0]
        }
        log(f"Persisted {len(data['speaker_embeddings'])} speaker embeddings ({embeddings.shape[1]}-dim)")

    with open(json_path, "w") as f:
        json.dump(data, f, indent=2)

    log(f"Diarization timeline written to {json_path}")


def main():
    parser = argparse.ArgumentParser(description="Speaker diarization for meeting transcripts")
    parser.add_argument("wav_file", help="Path to WAV audio file")
    parser.add_argument("srt_file", help="Path to SRT subtitle file")
    parser.add_argument("txt_file", help="Path to TXT transcript file")
    parser.add_argument("--num-speakers", type=int, default=None,
                        help="Expected number of speakers (improves accuracy)")
    parser.add_argument("--participants", type=str, default=None,
                        help="Participant names for context (not used for voice matching)")
    args = parser.parse_args()

    # Validate inputs
    for path in [args.wav_file, args.srt_file, args.txt_file]:
        if not os.path.isfile(path):
            log(f"Diarization error: file not found: {path}")
            print(f"DIARIZATION_FAILED: file not found: {path}")
            return

    hf_token = os.environ.get("HF_TOKEN", "")
    if not hf_token:
        log("Diarization skipped: HF_TOKEN not set")
        print("DIARIZATION_FAILED: HF_TOKEN not set")
        return

    try:
        log("Loading pyannote speaker diarization pipeline...")
        from pyannote.audio import Pipeline
        import torch

        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            token=hf_token,
        )

        # Try MPS (Apple Silicon GPU) acceleration
        if torch.backends.mps.is_available():
            try:
                pipeline.to(torch.device("mps"))
                log("Diarization using MPS (Apple Silicon GPU)")
            except Exception as mps_err:
                log(f"MPS acceleration failed, using CPU: {mps_err}")
        else:
            log("Diarization using CPU")

        # Run diarization
        log(f"Running diarization on {args.wav_file}...")
        diarize_kwargs = {}
        if args.num_speakers and args.num_speakers > 0:
            diarize_kwargs["num_speakers"] = args.num_speakers
            log(f"Speaker count hint: {args.num_speakers}")

        result = pipeline(args.wav_file, **diarize_kwargs)

        # pyannote 4.x returns DiarizeOutput with .speaker_embeddings (256-dim
        # clustering centroids); 3.x returns a bare Annotation.
        diarize_output = result if hasattr(result, "speaker_embeddings") else None
        if hasattr(result, "speaker_diarization"):
            diarization = result.speaker_diarization
        else:
            diarization = result

        # Build speaker map
        speaker_map = build_speaker_map(diarization)
        speaker_count = len(speaker_map)
        log(f"Diarization found {speaker_count} speakers: {list(speaker_map.values())}")

        if speaker_count == 0:
            log("Diarization found no speakers — skipping label assignment")
            print("DIARIZATION_FAILED: no speakers detected")
            return

        # Parse SRT and assign speakers
        srt_entries = parse_srt(args.srt_file)
        log(f"Parsed {len(srt_entries)} SRT entries")

        labeled_segments = assign_speakers(srt_entries, diarization)
        log(f"Assigned speakers to {len(labeled_segments)} segments")

        # Write outputs
        write_labeled_txt(labeled_segments, speaker_map, args.txt_file)
        log(f"Wrote labeled transcript to {args.txt_file}")

        write_labeled_srt(srt_entries, labeled_segments, speaker_map, args.srt_file)
        log(f"Wrote labeled SRT to {args.srt_file}")

        write_diarization_json(diarization, speaker_map, args.wav_file, diarize_output)

        # Summary
        log(f"Diarization complete: {speaker_count} speakers, {len(labeled_segments)} labeled segments")
        print(f"DIARIZATION_OK: {speaker_count} speakers")

    except Exception as e:
        log(f"Diarization failed: {e}")
        print(f"DIARIZATION_FAILED: {e}")
        # Exit 0 so the bash pipeline continues with the unlabeled transcript
        return


if __name__ == "__main__":
    main()
