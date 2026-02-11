#!/bin/bash
# Transcribe audio file and run meeting intelligence
# Called by quicktime-stop-recording.applescript after saving

set -e

AUDIO_FILE="$1"

if [ -z "$AUDIO_FILE" ] || [ ! -f "$AUDIO_FILE" ]; then
    echo "Error: Audio file not provided or doesn't exist" >> /tmp/meeting-recorder.log
    exit 1
fi

echo "Processing: $AUDIO_FILE" >> /tmp/meeting-recorder.log

# Configuration
WHISPER_MODEL="$HOME/.local/share/whisper-models/ggml-base.en.bin"
MEETING_NOTES_DIR="$HOME/Vaults/HigherJump/4. Resources/Meeting Notes"

# Extract filename components
BASENAME=$(basename "$AUDIO_FILE" .m4a)
DIRNAME=$(dirname "$AUDIO_FILE")
WAV_FILE="${DIRNAME}/${BASENAME}.wav"
TRANSCRIPT_FILE="${DIRNAME}/${BASENAME}.txt"
NOTE_FILE="${MEETING_NOTES_DIR}/${BASENAME}.md"

# Wait for audio file to be fully written (moov atom can be missing if read too early)
wait_for_valid_audio() {
    local file="$1"
    local max_attempts=10
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if ffprobe -v error -show_format "$file" &>/dev/null; then
            echo "Audio file validated on attempt $attempt" >> /tmp/meeting-recorder.log
            return 0
        fi
        echo "Waiting for audio file to be ready (attempt $attempt/$max_attempts)..." >> /tmp/meeting-recorder.log
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "Error: Audio file not valid after $max_attempts attempts" >> /tmp/meeting-recorder.log
    return 1
}

# Wait for file to be fully written before processing
if ! wait_for_valid_audio "$AUDIO_FILE"; then
    osascript -e 'display notification "Audio file corrupted or incomplete" with title "Meeting Recorder Error"'
    exit 1
fi

# Convert m4a to wav for Whisper
echo "Converting to WAV..." >> /tmp/meeting-recorder.log
ffmpeg -y -i "$AUDIO_FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV_FILE" 2>> /tmp/meeting-recorder.log

# Transcribe with Whisper
echo "Transcribing with Whisper..." >> /tmp/meeting-recorder.log
osascript -e 'display notification "Transcribing with Whisper..." with title "Meeting Recorder"'

if [ ! -f "$WHISPER_MODEL" ]; then
    echo "Error: Whisper model not found: $WHISPER_MODEL" >> /tmp/meeting-recorder.log
    osascript -e 'display notification "Whisper model not found!" with title "Meeting Recorder Error"'
    exit 1
fi

whisper-cli -m "$WHISPER_MODEL" -otxt -l en -t 4 "$WAV_FILE" 2>> /tmp/meeting-recorder.log

# Move transcript to expected location
if [ -f "${WAV_FILE}.txt" ]; then
    mv "${WAV_FILE}.txt" "$TRANSCRIPT_FILE"
fi

if [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: Transcription failed" >> /tmp/meeting-recorder.log
    osascript -e 'display notification "Transcription failed!" with title "Meeting Recorder Error"'
    exit 1
fi

echo "Transcription complete: $TRANSCRIPT_FILE" >> /tmp/meeting-recorder.log

# Extract date and time from filename (format: YYYY-MM-DD HHMM - Title)
DATE_PART=$(echo "$BASENAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
TIME_PART=$(echo "$BASENAME" | grep -oE ' [0-9]{4} ' | tr -d ' ')
TITLE_PART=$(echo "$BASENAME" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{4} - //')

# Format time as HH:MM
TIME_FORMATTED="${TIME_PART:0:2}:${TIME_PART:2:2}"

# Create meeting note
echo "Creating meeting note..." >> /tmp/meeting-recorder.log
cat > "$NOTE_FILE" << EOF
---
title: "$TITLE_PART"
date: $DATE_PART
time: "$TIME_FORMATTED"
event_id: "quicktime-$(date +%Y%m%d%H%M%S)"
status: transcribed
recording: "$AUDIO_FILE"
attendees: []
tags:
  - meeting
---

# $TITLE_PART

**Date:** $DATE_PART
**Time:** $TIME_FORMATTED CST
**Recording:** [Audio File](file://$(echo "$AUDIO_FILE" | sed 's/ /%20/g'))

---

## Transcript

$(cat "$TRANSCRIPT_FILE")
EOF

echo "Meeting note created: $NOTE_FILE" >> /tmp/meeting-recorder.log
osascript -e 'display notification "Transcription complete!" with title "Meeting Recorder"'

# Run meeting intelligence processor
echo "Running meeting intelligence..." >> /tmp/meeting-recorder.log
osascript -e 'display notification "Running AI analysis..." with title "Meeting Recorder"'

(
    /Users/will/.local/bin/claude -p "Process this meeting transcript and add an intelligence summary to the end of the file. The file is at: $NOTE_FILE" \
        --agent meeting-intelligence-processor \
        --dangerously-skip-permissions \
        >> /tmp/meeting-intelligence.log 2>&1

    if [ $? -eq 0 ]; then
        osascript -e 'display notification "AI analysis complete!" with title "Meeting Recorder" sound name "Glass"'
        echo "Meeting intelligence completed successfully" >> /tmp/meeting-recorder.log
    else
        osascript -e 'display notification "AI analysis failed - check logs" with title "Meeting Recorder"'
        echo "Meeting intelligence failed" >> /tmp/meeting-recorder.log
    fi
) &

echo "Meeting intelligence started in background" >> /tmp/meeting-recorder.log
