#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Force Close Recording
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ⚠️
# @raycast.packageName Meeting Recorder

# Force quit QuickTime and check if recording was saved

RECORDINGS_DIR="$HOME/Meeting Transcriptions"
TODAY=$(date '+%Y-%m-%d')

# Check for recent recording before killing
RECENT_FILE=$(find "$RECORDINGS_DIR" -name "${TODAY}*.m4a" -mmin -30 2>/dev/null | tail -1)

# Force quit QuickTime
if pgrep -x "QuickTime Player" > /dev/null; then
    pkill -9 "QuickTime Player"
    sleep 0.5
fi

# Report status
if [ -n "$RECENT_FILE" ] && [ -f "$RECENT_FILE" ]; then
    BASENAME=$(basename "$RECENT_FILE")
    # Check if file is valid
    if ffprobe -v error -show_format "$RECENT_FILE" &>/dev/null; then
        osascript -e "display notification \"Recording saved: $BASENAME\" with title \"Meeting Recorder\" subtitle \"QuickTime force closed\""
    else
        osascript -e "display notification \"Recording may be corrupted: $BASENAME\" with title \"Meeting Recorder\" subtitle \"Check the file\""
    fi
else
    osascript -e 'display notification "No recent recording found" with title "Meeting Recorder" subtitle "QuickTime force closed"'
fi
