#!/bin/bash
# Stop live transcription and clean up

set -euo pipefail

PID_FILE="/tmp/meeting-recorder-live-pid.txt"
VIEWER_PID_FILE="/tmp/meeting-recorder-live-viewer-pid.txt"
LOG="/tmp/meeting-recorder.log"

# Kill yap pipeline
if [ -f "$PID_FILE" ]; then
    YAP_PID=$(cat "$PID_FILE")
    # Kill the pipeline process group (yap + python formatter)
    kill -- -"$YAP_PID" 2>/dev/null || kill "$YAP_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "$(date '+%H:%M:%S') [live] Stopped yap (PID: $YAP_PID)" >> "$LOG"
else
    echo "No live transcript running"
fi

# Kill viewer
if [ -f "$VIEWER_PID_FILE" ]; then
    kill "$(cat "$VIEWER_PID_FILE")" 2>/dev/null || true
    rm -f "$VIEWER_PID_FILE"
fi

# Clean up transcript file
rm -f /tmp/live-transcript.txt

echo "Live transcript stopped"
