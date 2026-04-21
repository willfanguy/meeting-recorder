#!/bin/bash
# Start persistent live transcription daemon using yap (Apple Speech.framework)
# Runs all day — meeting boundaries are handled by markers, not process lifecycle.
#
# Usage: start-live-transcript.sh
#   Idempotent: exits early if yap is already running.
#   Must be run in a TCC-authorized context (Terminal.app, cmux) for audio access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIPT_FILE="/tmp/live-transcript.txt"
PID_FILE="/tmp/meeting-recorder-live-pid.txt"
VIEWER_PID_FILE="/tmp/meeting-recorder-live-viewer-pid.txt"
LOG="/tmp/meeting-recorder.log"

# yap's Speech.framework recognizer can silently freeze after long-running
# sessions (seen: 5 hours of runtime, then stopped emitting SRT output while
# process stayed alive). Cap the daemon's lifetime so every meeting gets a
# known-good recognizer. This loses at most 1-2 seconds of the first meeting
# after a restart, vs. silently dropping all subsequent meetings.
MAX_YAP_AGE_SECS=${MAX_YAP_AGE_SECS:-28800}  # 8 hours

# Check if already running (idempotent)
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        # Compute elapsed seconds since the yap wrapper started
        START_STR=$(ps -o lstart= -p "$OLD_PID" 2>/dev/null || true)
        if [ -n "$START_STR" ]; then
            START_EPOCH=$(date -jf "%a %b %e %T %Y" "$START_STR" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            AGE_SECS=$(( NOW_EPOCH - START_EPOCH ))
        else
            AGE_SECS=0
        fi

        if [ "$AGE_SECS" -gt "$MAX_YAP_AGE_SECS" ]; then
            echo "$(date '+%H:%M:%S') [live] yap stale (age ${AGE_SECS}s > ${MAX_YAP_AGE_SECS}s) -- restarting" >> "$LOG"
            # Kill the whole process group so the `script` wrapper and yap both die
            kill -- -"$OLD_PID" 2>/dev/null || kill "$OLD_PID" 2>/dev/null || true
            # Also kill the yap child directly in case process group didn't stick
            pgrep -P "$OLD_PID" | xargs -r kill 2>/dev/null || true
            sleep 1
            rm -f "$PID_FILE"
        else
            echo "$(date '+%H:%M:%S') [live] yap already running (PID: $OLD_PID, age ${AGE_SECS}s)" >> "$LOG"
            echo "Live transcript already running (PID: $OLD_PID)"
            exit 0
        fi
    else
        # Stale PID file -- clean up
        rm -f "$PID_FILE"
    fi
fi

# Resolve yap path — `script` spawns a clean bash without our PATH.
YAP_BIN="$(command -v yap 2>/dev/null || true)"
if [ -z "$YAP_BIN" ] && [ -x /opt/homebrew/bin/yap ]; then
    YAP_BIN="/opt/homebrew/bin/yap"
fi
if [ -z "$YAP_BIN" ]; then
    echo "$(date '+%H:%M:%S') [live] ERROR: yap not found in PATH" >> "$LOG"
    echo "Error: yap not found. Install with: brew install yap" >&2
    exit 1
fi

# Initialize transcript file if it doesn't exist
touch "$TRANSCRIPT_FILE"

# Use `script` to give yap a PTY — without it, yap block-buffers (~4KB chunks)
# and text only appears every 30+ seconds. With a PTY, yap flushes per segment.
# System audio only (no mic) — captures Zoom/Meet remote participants.
# No privacy concern, near-zero output between meetings.
script -q -a "$TRANSCRIPT_FILE" bash -c "exec $YAP_BIN listen --srt 2>>/tmp/yap-listen.error" > /dev/null 2>&1 &
YAP_PID=$!
echo "$YAP_PID" > "$PID_FILE"

# Start viewer if not already running
if [ -f "$VIEWER_PID_FILE" ]; then
    VIEWER_PID=$(cat "$VIEWER_PID_FILE")
    if kill -0 "$VIEWER_PID" 2>/dev/null; then
        echo "$(date '+%H:%M:%S') [live] Viewer already running (PID: $VIEWER_PID)" >> "$LOG"
    else
        rm -f "$VIEWER_PID_FILE"
    fi
fi
if [ ! -f "$VIEWER_PID_FILE" ]; then
    python3 "$SCRIPT_DIR/live-transcript-viewer.py" "$TRANSCRIPT_FILE" &
    VIEWER_PID=$!
    echo "$VIEWER_PID" > "$VIEWER_PID_FILE"
fi

echo "$(date '+%H:%M:%S') [live] Started live transcript daemon: yap (PID: $YAP_PID)" >> "$LOG"
echo "Live transcript: http://localhost:8234"
