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
WHISPER_MODEL_LARGE="$HOME/.local/share/whisper-models/ggml-large-v3-q5_0.bin"
WHISPER_MODEL_MEDIUM="$HOME/.local/share/whisper-models/ggml-medium-q5_0.bin"
WHISPER_VAD_MODEL="$HOME/.local/share/whisper-models/ggml-silero-v6.2.0.bin"
MEETING_NOTES_DIR="$HOME/Vaults/HigherJump/4. Resources/Meeting Notes"
CONFIG_FILE="$HOME/Repos/personal/productivity/config/config.json"

# Extract filename components
BASENAME=$(basename "$AUDIO_FILE" .m4a)
DIRNAME=$(dirname "$AUDIO_FILE")
WAV_FILE="${DIRNAME}/${BASENAME}.wav"
TRANSCRIPT_FILE="${DIRNAME}/${BASENAME}.txt"
NOTE_FILE="${MEETING_NOTES_DIR}/${BASENAME}.md"
METADATA_FILE="${DIRNAME}/${BASENAME}.json"

# Look for matching Zoom team chat
find_zoom_chat() {
    local date_part="$1"  # YYYY-MM-DD
    local time_part="$2"  # HHMM
    local title="$3"      # Meeting Title
    local zoom_dir="/Users/will/Documents/Zoom"

    [ ! -d "$zoom_dir" ] && return 1

    # Convert HHMM to HH.MM pattern for Zoom folder matching
    local hour="${time_part:0:2}"
    local minute="${time_part:2:2}"

    # Try exact date + HH.MM match first
    for folder in "$zoom_dir/${date_part} ${hour}.${minute}"*; do
        if [ -d "$folder" ] && [ -f "$folder/meeting_saved_new_chat.txt" ]; then
            echo "$folder/meeting_saved_new_chat.txt"
            return 0
        fi
    done

    # Fallback: match date + hour only (handles off-by-a-minute starts)
    for folder in "$zoom_dir/${date_part} ${hour}."*; do
        if [ -d "$folder" ] && [ -f "$folder/meeting_saved_new_chat.txt" ]; then
            echo "$folder/meeting_saved_new_chat.txt"
            return 0
        fi
    done

    return 1
}

# Read metadata if available (written by MeetingBar via eventStartScript.scpt)
MEETING_URL=""
MEETING_SERVICE=""
ATTENDEE_COUNT=""
MEETING_LOCATION=""
MEETING_NOTES_CONTENT=""
if [ -f "$METADATA_FILE" ]; then
    echo "Reading MeetingBar metadata from $METADATA_FILE" >> /tmp/meeting-recorder.log
    MEETING_URL=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('meetingUrl',''))" 2>/dev/null)
    MEETING_SERVICE=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('meetingService',''))" 2>/dev/null)
    ATTENDEE_COUNT=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('attendeeCount',0))" 2>/dev/null)
    MEETING_LOCATION=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('location',''))" 2>/dev/null)
    MEETING_NOTES_CONTENT=$(python3 -c "import json; print(json.load(open('$METADATA_FILE')).get('meetingNotes',''))" 2>/dev/null)
fi

# Select Whisper model: large by default, medium only for routine meetings (speed)
TITLE_LOWER=$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]')
USE_MEDIUM=false
if echo "$TITLE_LOWER" | grep -qiE '(stand.?up|standup|daily|sync|check.?in|check in|1:1|1-1|weekly sync)'; then
    USE_MEDIUM=true
    echo "Model selection: medium (routine meeting keyword match)" >> /tmp/meeting-recorder.log
fi

if [ "$USE_MEDIUM" = true ] && [ -f "$WHISPER_MODEL_MEDIUM" ]; then
    WHISPER_MODEL="$WHISPER_MODEL_MEDIUM"
    echo "Using medium-q5_0 model (routine meeting)" >> /tmp/meeting-recorder.log
elif [ -f "$WHISPER_MODEL_LARGE" ]; then
    WHISPER_MODEL="$WHISPER_MODEL_LARGE"
    echo "Using large-v3-q5_0 model (default)" >> /tmp/meeting-recorder.log
else
    WHISPER_MODEL="$WHISPER_MODEL_MEDIUM"
    echo "Using medium-q5_0 model (large not available)" >> /tmp/meeting-recorder.log
fi

# Wait for audio file to be fully written (moov atom can be missing if read too early)
# Long recordings (60+ min) can produce 200MB+ files that take 2-3 min to export
wait_for_valid_audio() {
    local file="$1"
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if ffprobe -v error -show_format "$file" &>/dev/null; then
            echo "Audio file validated on attempt $attempt" >> /tmp/meeting-recorder.log
            return 0
        fi
        echo "Waiting for audio file to be ready (attempt $attempt/$max_attempts)..." >> /tmp/meeting-recorder.log
        sleep 3
        attempt=$((attempt + 1))
    done

    echo "Error: Audio file not valid after $max_attempts attempts (waited $((max_attempts * 3))s)" >> /tmp/meeting-recorder.log
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
MODEL_NAME=$(basename "$WHISPER_MODEL" .bin | sed 's/ggml-//')
echo "Transcribing with Whisper ($MODEL_NAME)..." >> /tmp/meeting-recorder.log
osascript -e "display notification \"Transcribing with Whisper ($MODEL_NAME)...\" with title \"Meeting Recorder\""

if [ ! -f "$WHISPER_MODEL" ]; then
    echo "Error: Whisper model not found: $WHISPER_MODEL" >> /tmp/meeting-recorder.log
    osascript -e 'display notification "Whisper model not found!" with title "Meeting Recorder Error"'
    exit 1
fi

# Build context prompt from meeting title and known proper nouns
# This primes Whisper to correctly recognize names and project terms
TITLE_FOR_PROMPT=$(echo "$BASENAME" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{4} - //')
WHISPER_PROMPT="Meeting: ${TITLE_FOR_PROMPT}. Participants may include: Will Fanguy, Kevin Chen, Aron Delevic, Thomas Murphy, Judith Wilding, Tim Rosenberg, Tony Hawke, Alekhya Guduri. Projects: SuperFit, Project Door, ARC, SIHP, Glassdoor, Indeed, JobsForYou."

# Build whisper command with enhancements
# -t 4: use 4 threads (background task — leave cores free for foreground work)
# -osrt: also output SRT with timestamps for AI summary to reference
WHISPER_ARGS=(-m "$WHISPER_MODEL" -otxt -osrt -l en -t 4)
WHISPER_ARGS+=(--prompt "$WHISPER_PROMPT")
WHISPER_ARGS+=(--carry-initial-prompt)
WHISPER_ARGS+=(--suppress-nst)
# Limit context tokens to prevent hallucination loops (large models can enter
# self-reinforcing repetition when unlimited context accumulates)
WHISPER_ARGS+=(--max-context 224)

# Enable VAD if model exists (prevents hallucination on silence)
if [ -f "$WHISPER_VAD_MODEL" ]; then
    WHISPER_ARGS+=(--vad -vm "$WHISPER_VAD_MODEL")
    echo "VAD enabled with Silero model" >> /tmp/meeting-recorder.log
fi

echo "Whisper args: ${WHISPER_ARGS[*]}" >> /tmp/meeting-recorder.log

# For long recordings (>30 min), split into 15-min chunks to prevent
# hallucination loops from context accumulation in large models
DURATION_SECS=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV_FILE" 2>/dev/null | cut -d. -f1)
CHUNK_THRESHOLD=1800  # 30 minutes

if [ "${DURATION_SECS:-0}" -gt "$CHUNK_THRESHOLD" ]; then
    echo "Long recording (${DURATION_SECS}s) — using chunked transcription" >> /tmp/meeting-recorder.log
    CHUNK_DIR=$(mktemp -d /tmp/whisper-chunks-XXXXXX)
    CHUNK_SIZE=900  # 15 minutes
    CHUNK_NUM=0

    # Split audio into chunks
    for ((start=0; start<DURATION_SECS; start+=CHUNK_SIZE)); do
        CHUNK_NUM=$((CHUNK_NUM + 1))
        CHUNK_FILE="$CHUNK_DIR/chunk_$(printf '%02d' $CHUNK_NUM).wav"
        ffmpeg -y -hide_banner -ss "$start" -t "$CHUNK_SIZE" -i "$WAV_FILE" -c:a pcm_s16le "$CHUNK_FILE" 2>/dev/null
    done
    echo "Split into $CHUNK_NUM chunks" >> /tmp/meeting-recorder.log

    # Transcribe each chunk independently (fresh context per chunk)
    > "$TRANSCRIPT_FILE"
    SRT_FILE="${DIRNAME}/${BASENAME}.srt"
    > "$SRT_FILE"
    for CHUNK in "$CHUNK_DIR"/chunk_*.wav; do
        whisper-cli "${WHISPER_ARGS[@]}" -f "$CHUNK" 2>> /tmp/meeting-recorder.log
        if [ -f "${CHUNK}.txt" ]; then
            cat "${CHUNK}.txt" >> "$TRANSCRIPT_FILE"
            echo "" >> "$TRANSCRIPT_FILE"
        fi
        if [ -f "${CHUNK}.srt" ]; then
            cat "${CHUNK}.srt" >> "$SRT_FILE"
        fi
    done

    # Clean up chunks
    rm -rf "$CHUNK_DIR"
else
    # Short recording — transcribe directly
    whisper-cli "${WHISPER_ARGS[@]}" "$WAV_FILE" 2>> /tmp/meeting-recorder.log
    if [ -f "${WAV_FILE}.txt" ]; then
        mv "${WAV_FILE}.txt" "$TRANSCRIPT_FILE"
    fi
    if [ -f "${WAV_FILE}.srt" ]; then
        mv "${WAV_FILE}.srt" "${DIRNAME}/${BASENAME}.srt"
    fi
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
TITLE_PART=$(echo "$BASENAME" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{4} - //' | sed -E 's/[-[:space:]]+$//')

# Format time as HH:MM
TIME_FORMATTED="${TIME_PART:0:2}:${TIME_PART:2:2}"

# Look for matching Zoom team chat
ZOOM_CHAT_CONTENT=""
ZOOM_CHAT_FILE=$(find_zoom_chat "$DATE_PART" "$TIME_PART" "$TITLE_PART" 2>/dev/null || true)
if [ -n "$ZOOM_CHAT_FILE" ] && [ -f "$ZOOM_CHAT_FILE" ]; then
    echo "Found Zoom chat: $ZOOM_CHAT_FILE" >> /tmp/meeting-recorder.log
    ZOOM_CHAT_CONTENT=$(cat "$ZOOM_CHAT_FILE")
fi

# Build optional frontmatter fields
EXTRA_FRONTMATTER=""
if [ -n "$MEETING_URL" ]; then
    EXTRA_FRONTMATTER="${EXTRA_FRONTMATTER}meeting_url: \"$MEETING_URL\"
"
fi
if [ -n "$MEETING_SERVICE" ]; then
    EXTRA_FRONTMATTER="${EXTRA_FRONTMATTER}meeting_service: \"$MEETING_SERVICE\"
"
fi
if [ -n "$ATTENDEE_COUNT" ] && [ "$ATTENDEE_COUNT" != "0" ]; then
    EXTRA_FRONTMATTER="${EXTRA_FRONTMATTER}attendee_count: $ATTENDEE_COUNT
"
fi
if [ -n "$MEETING_LOCATION" ]; then
    EXTRA_FRONTMATTER="${EXTRA_FRONTMATTER}location: \"$MEETING_LOCATION\"
"
fi

# Build optional agenda section
AGENDA_SECTION=""
if [ -n "$MEETING_NOTES_CONTENT" ]; then
    AGENDA_SECTION="## Agenda / Notes

$MEETING_NOTES_CONTENT

---

"
fi

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
srt: "${DIRNAME}/${BASENAME}.srt"
${EXTRA_FRONTMATTER}attendees: []
tags:
  - meeting
---

# $TITLE_PART

**Date:** $DATE_PART
**Time:** $TIME_FORMATTED CST
**Recording:** [Audio File](file://$(echo "$AUDIO_FILE" | sed 's/ /%20/g'))

---

${AGENDA_SECTION}## Transcript

$(cat "$TRANSCRIPT_FILE")
EOF

# Append Zoom team chat if found
if [ -n "$ZOOM_CHAT_CONTENT" ]; then
    cat >> "$NOTE_FILE" << 'CHATEOF'

---

## Team Chat (Zoom)

CHATEOF
    echo "$ZOOM_CHAT_CONTENT" >> "$NOTE_FILE"
fi

# Clean up metadata file
rm -f "$METADATA_FILE"

echo "Meeting note created: $NOTE_FILE" >> /tmp/meeting-recorder.log
osascript -e 'display notification "Transcription complete!" with title "Meeting Recorder"'

# Run meeting intelligence processor
echo "Running meeting intelligence..." >> /tmp/meeting-recorder.log
osascript -e 'display notification "Running AI analysis..." with title "Meeting Recorder"'

(
    unset CLAUDECODE
    /Users/will/.local/bin/claude -p "BACKGROUND_MODE=true — Process this meeting transcript and add an intelligence summary BEFORE the ## Transcript section. The file is at: $NOTE_FILE" \
        --agent meeting-intelligence-processor \
        --dangerously-skip-permissions \
        >> /tmp/meeting-intelligence.log 2>&1

    if [ $? -eq 0 ]; then
        osascript -e 'display notification "AI analysis complete — run meeting-tasks-extractor to review tasks" with title "Meeting Recorder" sound name "Glass"'
        echo "Meeting intelligence completed successfully" >> /tmp/meeting-recorder.log
    else
        osascript -e 'display notification "AI analysis failed - check logs" with title "Meeting Recorder"'
        echo "Meeting intelligence failed" >> /tmp/meeting-recorder.log
    fi
) &

echo "Meeting intelligence started in background" >> /tmp/meeting-recorder.log
