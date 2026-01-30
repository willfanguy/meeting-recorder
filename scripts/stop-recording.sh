#!/bin/bash
# Stop meeting recording, transcribe, and save to notes folder
# Called by MeetingBar when leaving a meeting, or manually

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
CONFIG_FILE="$PROJECT_DIR/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

STATE_FILE="/tmp/meeting-recording-state"

# Check if recording is in progress
if [ ! -f "$STATE_FILE" ]; then
    echo "No recording in progress."
    osascript -e 'display notification "No recording in progress" with title "Meeting Recorder"'
    exit 0
fi

# Load state
source "$STATE_FILE"

echo "Stopping recording: $MEETING_NAME"

# Stop ffmpeg gracefully
if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    # Send SIGINT for graceful shutdown
    kill -INT "$FFMPEG_PID"

    # Wait for it to finish writing (up to 5 seconds)
    for i in {1..10}; do
        if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done

    # Force kill if still running
    if kill -0 "$FFMPEG_PID" 2>/dev/null; then
        echo "Force stopping ffmpeg..."
        kill -9 "$FFMPEG_PID" 2>/dev/null || true
        sleep 1
    fi
fi

# Clean up state file
rm -f "$STATE_FILE"

# Verify audio file exists and has content
if [ ! -f "$AUDIO_FILE" ]; then
    echo "ERROR: Audio file not found: $AUDIO_FILE"
    osascript -e 'display notification "Recording file not found!" with title "Meeting Recorder Error"'
    exit 1
fi

FILE_SIZE=$(stat -f%z "$AUDIO_FILE" 2>/dev/null || echo "0")
if [ "$FILE_SIZE" -lt 10000 ]; then
    echo "WARNING: Audio file is very small ($FILE_SIZE bytes). Recording may have failed."
    echo "Check /tmp/ffmpeg-recording.log for errors."
fi

echo "Recording saved: $AUDIO_FILE"

# Look up actual meeting name from calendar (we have more time at stop)
echo "Looking up meeting name from calendar..."
CALENDAR_NAME=$(osascript -e '
tell application "Calendar"
    set currentDate to current date
    set startTime to currentDate - (90 * minutes)
    set endTime to currentDate + (5 * minutes)
    set foundEvents to {}

    repeat with currentCalendar in every calendar
        try
            set currentEvents to (every event of currentCalendar whose start date ≤ endTime and end date ≥ startTime and allday event is false)
            repeat with evt in currentEvents
                set end of foundEvents to evt
            end repeat
        end try
    end repeat

    if (count of foundEvents) = 0 then
        return ""
    else if (count of foundEvents) = 1 then
        return summary of item 1 of foundEvents
    else
        set bestEvent to item 1 of foundEvents
        set bestDiff to 9999999
        repeat with evt in foundEvents
            set diff to (start date of evt) - currentDate
            if diff < 0 then set diff to -diff
            if diff < bestDiff then
                set bestDiff to diff
                set bestEvent to evt
            end if
        end repeat
        return summary of bestEvent
    end if
end tell
' 2>/dev/null || echo "")

# If we got a calendar name and the file is currently named "Meeting", rename it
if [ -n "$CALENDAR_NAME" ] && [ "$CALENDAR_NAME" != "" ] && [[ "$MEETING_NAME" == "Meeting" ]]; then
    echo "Found calendar event: $CALENDAR_NAME"
    MEETING_NAME="$CALENDAR_NAME"
    SAFE_NAME=$(echo "$MEETING_NAME" | tr '/:*?"<>|\\' '-' | tr -s '-')
    TIMESTAMP=$(echo "$FILENAME" | sed 's/.*- //')
    NEW_FILENAME="${SAFE_NAME} - ${TIMESTAMP}"
    NEW_AUDIO_FILE="$RECORDINGS_DIR/${NEW_FILENAME}.wav"

    if [ "$AUDIO_FILE" != "$NEW_AUDIO_FILE" ]; then
        echo "Renaming to: $NEW_FILENAME"
        mv "$AUDIO_FILE" "$NEW_AUDIO_FILE"
        AUDIO_FILE="$NEW_AUDIO_FILE"
        FILENAME="$NEW_FILENAME"
    fi
else
    echo "Using original name: $MEETING_NAME"
fi

osascript -e "display notification \"Transcribing...\" with title \"Meeting Recorder\""

# Transcribe with Whisper
echo "Transcribing with Whisper..."
TRANSCRIPT_FILE="${AUDIO_FILE%.wav}.txt"

# Check model exists
if [ ! -f "$WHISPER_MODEL" ]; then
    echo "ERROR: Whisper model not found: $WHISPER_MODEL"
    echo "Run the install script or download manually from:"
    echo "https://huggingface.co/ggerganov/whisper.cpp/tree/main"
    osascript -e 'display notification "Whisper model not found!" with title "Meeting Recorder Error"'
    exit 1
fi

# Run whisper-cli
whisper-cli -m "$WHISPER_MODEL" -otxt -l en -t 4 "$AUDIO_FILE" 2>&1 | tee /tmp/whisper-output.log

# whisper-cli creates output with same name as input + .txt
WHISPER_OUTPUT="${AUDIO_FILE}.txt"
if [ -f "$WHISPER_OUTPUT" ]; then
    mv "$WHISPER_OUTPUT" "$TRANSCRIPT_FILE"
fi

if [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "ERROR: Transcription failed. Check /tmp/whisper-output.log"
    osascript -e 'display notification "Transcription failed!" with title "Meeting Recorder Error"'
    exit 1
fi

echo "Transcript saved: $TRANSCRIPT_FILE"

# Create meeting note
TODAY=$(date "+%Y-%m-%d")
NOTE_FILE="$MEETING_NOTES_DIR/${FILENAME}.md"

cat > "$NOTE_FILE" <<NOTEEOF
# $MEETING_NAME

**Date:** $TODAY
**Recording:** [Audio File](file://${AUDIO_FILE// /%20})

---

## Transcript

$(cat "$TRANSCRIPT_FILE")

NOTEEOF

echo "Meeting note created: $NOTE_FILE"

# Final notification
osascript -e "display notification \"Ready: $MEETING_NAME\" with title \"Meeting Recorder\" sound name \"Glass\""

# Output summary
echo ""
echo "=== Recording Complete ==="
echo "Audio:      $AUDIO_FILE"
echo "Transcript: $TRANSCRIPT_FILE"
echo "Note:       $NOTE_FILE"

# Run Claude meeting intelligence processor if enabled
if [ "${RUN_MEETING_INTELLIGENCE:-true}" = "true" ]; then
    echo ""
    echo "Running meeting intelligence processor..."
    osascript -e "display notification \"Processing with AI...\" with title \"Meeting Recorder\""

    # Run Claude in background to process the meeting note
    claude -p "Process this meeting transcript and add an intelligence summary to the end of the file. The file is at: $NOTE_FILE" \
        --agent meeting-intelligence-processor \
        --dangerously-skip-permissions \
        > /tmp/meeting-intelligence.log 2>&1 &

    CLAUDE_PID=$!
    echo "Meeting intelligence processing started in background (PID: $CLAUDE_PID)"
    echo "Check /tmp/meeting-intelligence.log for progress"
fi
