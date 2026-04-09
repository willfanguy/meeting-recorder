#!/bin/bash
# Batch diarize and enroll speakers from known 1:1 and small meetings.
# Uses the existing library to auto-identify Will, then enrolls the
# remaining unknown speaker(s) by name.
#
# Run: scripts/batch-enroll.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.venv/bin/python"
DIARIZE="$SCRIPT_DIR/diarize-transcript.py"
ENROLL="$SCRIPT_DIR/enroll-speakers.py"
RECORDINGS="$HOME/Meeting Transcriptions"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG="/tmp/meeting-recorder.log"

# Load HF token
HF_TOKEN=$(grep '^HF_TOKEN=' "$PROJECT_DIR/config.sh" | cut -d'"' -f2)
export HF_TOKEN

diarize_meeting() {
    local meeting="$1"
    local num_speakers="$2"

    local wav="$RECORDINGS/${meeting}.wav"
    local srt="$RECORDINGS/${meeting}.srt"
    local txt="$RECORDINGS/${meeting}.txt"

    if [ ! -f "$wav" ] || [ ! -f "$srt" ] || [ ! -f "$txt" ]; then
        echo "SKIP: $meeting (missing files)"
        return 1
    fi

    echo ""
    echo "=== $meeting ==="
    echo "Diarizing ($num_speakers speakers)..."

    if "$VENV" "$DIARIZE" "$wav" "$srt" "$txt" --num-speakers "$num_speakers" >> "$LOG" 2>&1; then
        echo "Diarization OK"
        return 0
    else
        echo "Diarization failed"
        return 1
    fi
}

enroll_unknown() {
    # After diarization with library identification, find the unknown
    # speaker(s) and enroll them with the given name(s).
    local json="$1"
    shift
    # Remaining args: names for unknown speakers (in order)

    if [ ! -f "$json" ]; then
        echo "No JSON found"
        return
    fi

    # Find speaker labels that weren't identified (still generic "Speaker X")
    local unknowns
    unknowns=$("$VENV" -c "
import json
d = json.load(open('$json'))
embs = d.get('speaker_embeddings', {})
# Speakers with generic labels (Speaker A/B/C...) are unidentified
generic = [k for k in embs if k.startswith('Speaker ')]
print('\n'.join(generic))
" 2>/dev/null)

    if [ -z "$unknowns" ]; then
        echo "All speakers already identified"
        return
    fi

    # Build array of name arguments
    local names=("$@")
    local i=0
    local enroll_args=()
    while IFS= read -r label; do
        if [ $i -lt ${#names[@]} ]; then
            enroll_args+=(--assign "${label}=${names[$i]}")
            echo "  Assigning: $label -> ${names[$i]}"
        fi
        i=$((i + 1))
    done <<< "$unknowns"

    if [ ${#enroll_args[@]} -gt 0 ]; then
        "$VENV" "$ENROLL" --diarization-json "$json" "${enroll_args[@]}"
    fi
}

echo "Batch enrollment starting..."
echo "Library before:"
"$VENV" "$ENROLL" --list
echo ""

# --- 1:1 meetings (2 speakers: Will + one other) ---

if diarize_meeting "2026-04-02 1530 - Will - Judith 1-1" 2; then
    enroll_unknown "$RECORDINGS/2026-04-02 1530 - Will - Judith 1-1.diarization.json" "Judith Wilding"
fi

if diarize_meeting "2026-04-03 1400 - Will - Ali Weekly 1-1" 2; then
    enroll_unknown "$RECORDINGS/2026-04-03 1400 - Will - Ali Weekly 1-1.diarization.json" "Ali"
fi

if diarize_meeting "2026-04-07 0930 - Will - Kaarin → 1-1 (monthly)" 2; then
    enroll_unknown "$RECORDINGS/2026-04-07 0930 - Will - Kaarin → 1-1 (monthly).diarization.json" "Kaarin Hoff"
fi

if diarize_meeting "2026-03-27 1200 - Will + Thomas → Weekly Sync" 2; then
    enroll_unknown "$RECORDINGS/2026-03-27 1200 - Will + Thomas → Weekly Sync.diarization.json" "Thomas"
fi

if diarize_meeting "2026-04-09 1500 - Will - Judith 1-1" 2; then
    enroll_unknown "$RECORDINGS/2026-04-09 1500 - Will - Judith 1-1.diarization.json" "Judith Wilding"
fi

# --- 3-speaker meeting ---

if diarize_meeting "2026-04-06 1545 - Will - Judith - Thomas check in re scope" 3; then
    enroll_unknown "$RECORDINGS/2026-04-06 1545 - Will - Judith - Thomas check in re scope.diarization.json" "Judith Wilding" "Thomas"
fi

echo ""
echo "=== Batch complete ==="
echo "Library after:"
"$VENV" "$ENROLL" --list
