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

# Restore original audio output device
if [ -n "$ORIGINAL_OUTPUT" ]; then
    echo "Restoring audio output to: $ORIGINAL_OUTPUT"
    SwitchAudioSource -t output -s "$ORIGINAL_OUTPUT" 2>/dev/null || echo "WARNING: Could not restore audio output"
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

# Look up actual meeting name from Obsidian daily note (fast)
echo "Looking up meeting name..."
CALENDAR_NAME=""

# Get today's daily note path
TODAY_DATE=$(date "+%Y-%m-%d")
TODAY_DAY=$(date "+%a")
DAILY_NOTE="/Users/will/Vaults/HigherJump/4. Resources/Daily Notes/${TODAY_DATE} ${TODAY_DAY} - Daily.md"

if [ -f "$DAILY_NOTE" ]; then
    # Get current time in minutes since midnight for comparison
    CURRENT_HOUR=$(date "+%H")
    CURRENT_MIN=$(date "+%M")
    CURRENT_MINS=$((10#$CURRENT_HOUR * 60 + 10#$CURRENT_MIN))

    # Parse schedule lines and find matching meeting
    while IFS= read -r line; do
        # Extract start and end time (HH:MM - HH:MM)
        if [[ $line =~ ([0-9]{1,2}):([0-9]{2})\ -\ ([0-9]{1,2}):([0-9]{2}) ]]; then
            START_H="${BASH_REMATCH[1]}"
            START_M="${BASH_REMATCH[2]}"
            END_H="${BASH_REMATCH[3]}"
            END_M="${BASH_REMATCH[4]}"

            START_MINS=$((10#$START_H * 60 + 10#$START_M))
            END_MINS=$((10#$END_H * 60 + 10#$END_M))

            # Check if current time falls within this meeting (with 15 min buffer after)
            if [ $CURRENT_MINS -ge $START_MINS ] && [ $CURRENT_MINS -le $((END_MINS + 15)) ]; then
                # Extract meeting name from [[...Meeting Notes/...|Display Name]] format using sed
                POTENTIAL_NAME=$(echo "$line" | sed -n 's/.*Meeting Notes\/[^|]*|\([^]]*\)].*/\1/p')
                if [ -n "$POTENTIAL_NAME" ]; then
                    CALENDAR_NAME="$POTENTIAL_NAME"
                    echo "Found in daily note: $CALENDAR_NAME"
                    break
                fi
            fi
        fi
    done < "$DAILY_NOTE"
fi

if [ -z "$CALENDAR_NAME" ]; then
    echo "No matching meeting found in daily note"
fi

# If we got a calendar name and the file is currently named "Meeting", rename it
if [ -n "$CALENDAR_NAME" ] && [ "$CALENDAR_NAME" != "" ] && [[ "$MEETING_NAME" == "Meeting" ]]; then
    echo "Found calendar event: $CALENDAR_NAME"
    MEETING_NAME="$CALENDAR_NAME"
fi

# Generate unique filename using standardized format: YYYY-MM-DD HHmm - Title
SAFE_NAME=$(echo "$MEETING_NAME" | sed 's/[[:cntrl:]]//g' | tr '/:*?"<>|\\' '-' | tr -s '[:space:]' ' ' | tr -s '-' | sed 's/^[- ]*//;s/[- ]*$//')
# Extract the date-time portion from existing filename (format: YYYY-MM-DD HHmm - ...)
TIMESTAMP=$(echo "$FILENAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{4}' || date "+%Y-%m-%d %H%M")
NEW_FILENAME="${TIMESTAMP} - ${SAFE_NAME}"

# Ensure unique filename by checking if meeting note already exists
COUNTER=0
BASE_FILENAME="$NEW_FILENAME"
while [ -f "$MEETING_NOTES_DIR/${NEW_FILENAME}.md" ]; do
    COUNTER=$((COUNTER + 1))
    NEW_FILENAME="${BASE_FILENAME} (${COUNTER})"
    echo "File exists, trying: $NEW_FILENAME"
done

NEW_AUDIO_FILE="$RECORDINGS_DIR/${NEW_FILENAME}.wav"

if [ "$AUDIO_FILE" != "$NEW_AUDIO_FILE" ]; then
    echo "Renaming to: $NEW_FILENAME"
    mv "$AUDIO_FILE" "$NEW_AUDIO_FILE"
    AUDIO_FILE="$NEW_AUDIO_FILE"
    FILENAME="$NEW_FILENAME"
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

# Create meeting note with standardized frontmatter
TODAY=$(date "+%Y-%m-%d")
TIME_DISPLAY=$(date "+%I:%M %p %Z" | sed 's/^0//')
# Extract time from timestamp (HHmm -> HH:mm)
TIME_24H=$(echo "$TIMESTAMP" | grep -oE '[0-9]{4}$' | sed 's/\(..\)\(..\)/\1:\2/')
# Generate unique event ID for duplicate detection
EVENT_ID="recording-$(date +%Y%m%d%H%M%S)"
NOTE_FILE="$MEETING_NOTES_DIR/${FILENAME}.md"

cat > "$NOTE_FILE" <<NOTEEOF
---
title: "$MEETING_NAME"
date: $TODAY
time: "$TIME_24H"
event_id: "$EVENT_ID"
status: transcribed
recording: "$AUDIO_FILE"
attendees: []
tags:
  - meeting
---

# $MEETING_NAME

**Date:** $TODAY
**Time:** $TIME_DISPLAY
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
    /Users/will/.local/bin/claude -p "Process this meeting transcript and add an intelligence summary to the end of the file. The file is at: $NOTE_FILE" \
        --agent meeting-intelligence-processor \
        --dangerously-skip-permissions \
        > /tmp/meeting-intelligence.log 2>&1 &

    CLAUDE_PID=$!
    echo "Meeting intelligence processing started in background (PID: $CLAUDE_PID)"
    echo "Check /tmp/meeting-intelligence.log for progress"
fi
