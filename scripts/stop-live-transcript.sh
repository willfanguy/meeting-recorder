#!/bin/bash
# Signal that a meeting has ended, or fully shut down the live transcript daemon.
#
# Usage:
#   stop-live-transcript.sh          Write end marker (yap keeps running for next meeting)
#   stop-live-transcript.sh --kill   Full shutdown: kill yap + viewer, clean up

set -euo pipefail

TRANSCRIPT_FILE="/tmp/live-transcript.txt"
PID_FILE="/tmp/meeting-recorder-live-pid.txt"
VIEWER_PID_FILE="/tmp/meeting-recorder-live-viewer-pid.txt"
LOG="/tmp/meeting-recorder.log"

if [ "${1:-}" = "--kill" ]; then
    # Full shutdown
    if [ -f "$PID_FILE" ]; then
        YAP_PID=$(cat "$PID_FILE")
        kill -- -"$YAP_PID" 2>/dev/null || kill "$YAP_PID" 2>/dev/null || true
        rm -f "$PID_FILE"
        echo "$(date '+%H:%M:%S') [live] Stopped yap (PID: $YAP_PID)" >> "$LOG"
    fi
    if [ -f "$VIEWER_PID_FILE" ]; then
        kill "$(cat "$VIEWER_PID_FILE")" 2>/dev/null || true
        rm -f "$VIEWER_PID_FILE"
    fi
    rm -f "$TRANSCRIPT_FILE"
    echo "Live transcript stopped"
else
    # Write end marker — yap stays running
    if [ -f "$TRANSCRIPT_FILE" ]; then
        printf '\n--- MEETING END ---\n' >> "$TRANSCRIPT_FILE"
        echo "$(date '+%H:%M:%S') [live] Meeting ended" >> "$LOG"
    fi
    echo "Meeting ended (live transcript still running)"
fi
