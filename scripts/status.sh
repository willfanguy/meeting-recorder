#!/bin/bash
# Check current recording status

STATE_FILE="/tmp/meeting-recording-state"

if [ ! -f "$STATE_FILE" ]; then
    echo "No recording in progress."
    exit 0
fi

source "$STATE_FILE"

# Check if ffmpeg is still running
if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    DURATION=$(( $(date +%s) - $(date -j -f "%Y-%m-%d %H:%M:%S" "$START_TIME" +%s 2>/dev/null || echo "0") ))
    MINS=$((DURATION / 60))
    SECS=$((DURATION % 60))

    echo "Recording in progress"
    echo "  Meeting:  $MEETING_NAME"
    echo "  Started:  $START_TIME"
    echo "  Duration: ${MINS}m ${SECS}s"
    echo "  File:     $AUDIO_FILE"
    echo "  PID:      $FFMPEG_PID"
else
    echo "Recording state file exists but ffmpeg is not running."
    echo "The recording may have crashed. Cleaning up..."
    rm -f "$STATE_FILE"
fi
