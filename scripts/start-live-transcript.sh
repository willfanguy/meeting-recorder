#!/bin/bash
# Start live transcription using yap (Apple Speech.framework)
# Runs alongside QuickTime recording for real-time catch-up during meetings
#
# Usage: start-live-transcript.sh [meeting-name]
#   meeting-name: Optional. If omitted, reads from active session metadata.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIPT_FILE="/tmp/live-transcript.txt"
PID_FILE="/tmp/meeting-recorder-live-pid.txt"
VIEWER_PID_FILE="/tmp/meeting-recorder-live-viewer-pid.txt"
METADATA_FILE="/tmp/meeting-recorder-active-session.json"
LOG="/tmp/meeting-recorder.log"

# Resolve meeting name
MEETING_NAME="${1:-}"
if [ -z "$MEETING_NAME" ] && [ -f "$METADATA_FILE" ]; then
    MEETING_NAME=$(python3 -c "import json; print(json.load(open('$METADATA_FILE'))['title'])" 2>/dev/null || echo "")
fi
if [ -z "$MEETING_NAME" ]; then
    MEETING_NAME="Meeting"
fi

# Kill any existing live transcript session
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    kill "$OLD_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "$(date '+%H:%M:%S') [live] Killed previous yap session (PID: $OLD_PID)" >> "$LOG"
fi
if [ -f "$VIEWER_PID_FILE" ]; then
    kill "$(cat "$VIEWER_PID_FILE")" 2>/dev/null || true
    rm -f "$VIEWER_PID_FILE"
fi

# Clear transcript file
> "$TRANSCRIPT_FILE"

# Resolve yap path now — `script` spawns a clean bash without our PATH.
# AppleScript's `do shell script` may also have a minimal PATH, so check
# the known Homebrew location as a fallback.
YAP_BIN="$(command -v yap 2>/dev/null || true)"
if [ -z "$YAP_BIN" ] && [ -x /opt/homebrew/bin/yap ]; then
    YAP_BIN="/opt/homebrew/bin/yap"
fi
if [ -z "$YAP_BIN" ]; then
    echo "$(date '+%H:%M:%S') [live] ERROR: yap not found in PATH" >> "$LOG"
    echo "Error: yap not found. Install with: brew install yap" >&2
    exit 1
fi

# Use `script` to give yap a PTY — without it, yap block-buffers (~4KB chunks)
# and text only appears every 30+ seconds. With a PTY, yap flushes per segment.
# SRT format outputs short segments (2-5s phrases) more frequently than --txt,
# giving a streaming feel. The viewer parses SRT and renders cleanly.
script -q -a "$TRANSCRIPT_FILE" bash -c "exec $YAP_BIN listen-and-dictate --srt 2>>/tmp/yap-listen.error" > /dev/null 2>&1 &
YAP_PID=$!
echo "$YAP_PID" > "$PID_FILE"

# Start browser-based viewer
python3 "$SCRIPT_DIR/live-transcript-viewer.py" "$TRANSCRIPT_FILE" &
VIEWER_PID=$!
echo "$VIEWER_PID" > "$VIEWER_PID_FILE"

# Give the server a moment to start, then open browser
sleep 0.5
open -a "Comet" "http://localhost:8234"

echo "$(date '+%H:%M:%S') [live] Started live transcript: yap (PID: $YAP_PID), viewer (PID: $VIEWER_PID)" >> "$LOG"
echo "Live transcript: http://localhost:8234"
