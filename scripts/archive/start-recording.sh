#!/bin/bash
# Start meeting recording
# Called by MeetingBar when joining a meeting, or manually

set -e

# Ensure Homebrew paths are available (needed when called from MeetingBar/AppleScript)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
CONFIG_FILE="$PROJECT_DIR/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Copy config.example.sh to config.sh and customize it."
    exit 1
fi
source "$CONFIG_FILE"

# State file for tracking current recording
STATE_FILE="/tmp/meeting-recording-state"

# Multi-output device for routing audio to both speakers and BlackHole
MULTI_OUTPUT_DEVICE="Meeting Output"

# Ensure directories exist
mkdir -p "$RECORDINGS_DIR"
mkdir -p "$MEETING_NOTES_DIR"

# Switch system audio output to multi-output device (so BlackHole captures meeting audio)
echo "Switching audio output for recording..."
ORIGINAL_OUTPUT=$(SwitchAudioSource -t output -c 2>/dev/null || echo "")
if [ -n "$ORIGINAL_OUTPUT" ]; then
    echo "Current output: $ORIGINAL_OUTPUT"
    if SwitchAudioSource -t output -s "$MULTI_OUTPUT_DEVICE" 2>/dev/null; then
        echo "Switched to: $MULTI_OUTPUT_DEVICE"
    else
        echo "WARNING: Could not switch to $MULTI_OUTPUT_DEVICE - recording may not capture meeting audio"
        echo "Make sure the multi-output device exists in Audio MIDI Setup"
    fi
else
    echo "WARNING: Could not detect current audio output device"
fi

# Get current meeting info from daily note
# Returns: MEETING_NAME and EVENT_START_TIME (HHmm format)
get_meeting_info() {
    # Try environment override first
    if [ -n "$MEETING_NAME_OVERRIDE" ]; then
        MEETING_NAME="$MEETING_NAME_OVERRIDE"
        # If override provided, use current time rounded to nearest 5 min
        EVENT_START_TIME=$(date "+%H%M")
        return
    fi

    # Look up from daily note (same logic as stop-recording.sh)
    TODAY_DATE=$(date "+%Y-%m-%d")
    TODAY_DAY=$(date "+%a")
    DAILY_NOTE="/Users/will/Vaults/HigherJump/4. Resources/Daily Notes/${TODAY_DATE} ${TODAY_DAY} - Daily.md"

    if [ -f "$DAILY_NOTE" ]; then
        CURRENT_HOUR=$(date "+%H")
        CURRENT_MIN=$(date "+%M")
        CURRENT_MINS=$((10#$CURRENT_HOUR * 60 + 10#$CURRENT_MIN))

        while IFS= read -r line; do
            # Extract start and end time (HH:MM - HH:MM)
            if [[ $line =~ ([0-9]{1,2}):([0-9]{2})\ -\ ([0-9]{1,2}):([0-9]{2}) ]]; then
                START_H="${BASH_REMATCH[1]}"
                START_M="${BASH_REMATCH[2]}"
                END_H="${BASH_REMATCH[3]}"
                END_M="${BASH_REMATCH[4]}"

                START_MINS=$((10#$START_H * 60 + 10#$START_M))
                END_MINS=$((10#$END_H * 60 + 10#$END_M))

                # Check if current time is within 10 min before start to 15 min after end
                if [ $CURRENT_MINS -ge $((START_MINS - 10)) ] && [ $CURRENT_MINS -le $((END_MINS + 15)) ]; then
                    # Extract meeting name from [[...Meeting Notes/...|Display Name]] format
                    POTENTIAL_NAME=$(echo "$line" | sed -n 's/.*Meeting Notes\/[^|]*|\([^]]*\)].*/\1/p')
                    if [ -n "$POTENTIAL_NAME" ]; then
                        MEETING_NAME="$POTENTIAL_NAME"
                        # Use the event's actual start time (padded to 2 digits)
                        EVENT_START_TIME=$(printf "%02d%02d" "$START_H" "$START_M")
                        echo "Found meeting: $MEETING_NAME (starts $EVENT_START_TIME)"
                        return
                    fi
                fi
            fi
        done < "$DAILY_NOTE"
    fi

    # Fallback: generic name with current time
    MEETING_NAME="Meeting"
    EVENT_START_TIME=$(date "+%H%M")
}

# Check if already recording
if [ -f "$STATE_FILE" ]; then
    echo "Recording already in progress. Stop it first with stop-recording.sh"
    osascript -e 'display notification "Recording already in progress" with title "Meeting Recorder"'
    exit 1
fi

# Get meeting info from daily note (sets MEETING_NAME and EVENT_START_TIME)
get_meeting_info

# Sanitize: remove emojis (rough), replace unsafe chars, collapse spaces
SAFE_NAME=$(echo "$MEETING_NAME" | sed 's/[[:cntrl:]]//g' | tr '/:*?"<>|\\' '-' | tr -s '[:space:]' ' ' | tr -s '-' | sed 's/^[- ]*//;s/[- ]*$//')
# Standardized format: YYYY-MM-DD HHmm - Title (uses EVENT start time, not current time)
TODAY_DATE=$(date "+%Y-%m-%d")
FILENAME="${TODAY_DATE} ${EVENT_START_TIME} - ${SAFE_NAME}"
AUDIO_FILE="$RECORDINGS_DIR/${FILENAME}.wav"

echo "Starting recording for: $MEETING_NAME"
echo "File: $AUDIO_FILE"

# Find the audio device index (with retry for slow device initialization)
DEVICE_INFO=""
for attempt in 1 2 3 4 5; do
    DEVICE_INFO=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -n "$AUDIO_DEVICE" | head -1)
    if [ -n "$DEVICE_INFO" ]; then
        break
    fi
    echo "Waiting for audio device (attempt $attempt/5)..."
    sleep 1
done

if [ -z "$DEVICE_INFO" ]; then
    echo "ERROR: Audio device '$AUDIO_DEVICE' not found."
    echo ""
    echo "Available audio devices:"
    ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A100 "AVFoundation audio devices:" | grep "^\[AVFoundation"
    echo ""
    echo "Create an Aggregate Device in Audio MIDI Setup named '$AUDIO_DEVICE'"
    echo "that combines your microphone and BlackHole 2ch."
    osascript -e "display notification \"Audio device not found: $AUDIO_DEVICE\" with title \"Meeting Recorder Error\""
    exit 1
fi

# Get actual device number from ffmpeg listing
DEVICE_NUM=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "$AUDIO_DEVICE" | sed -n 's/.*\[\([0-9]*\)\].*/\1/p' | head -1)

echo "Using audio device [$DEVICE_NUM]: $AUDIO_DEVICE"

# Start recording in background
# -y: overwrite output file
# -f avfoundation: macOS audio/video input
# -i ":$DEVICE_NUM": audio-only from device number
# -c:a pcm_s16le: 16-bit PCM (uncompressed, whisper-compatible)
# -ar 16000: 16kHz sample rate (optimal for Whisper)
# -ac 1: mono (sufficient for speech)
# Record all channels from aggregate device and mix down to mono
# Uses amerge to combine all input channels, then downmix to mono
# This works regardless of how many channels the aggregate device has
ffmpeg -y -f avfoundation -i ":${DEVICE_NUM}" \
    -af "aresample=async=1,pan=1c|c0=c0+c1+c2+c3+c4+c5,alimiter=limit=0.9" \
    -c:a pcm_s16le -ar 16000 \
    "$AUDIO_FILE" \
    > /tmp/ffmpeg-recording.log 2>&1 &

FFMPEG_PID=$!

# Verify ffmpeg started
sleep 1
if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    echo "ERROR: ffmpeg failed to start. Check /tmp/ffmpeg-recording.log"
    cat /tmp/ffmpeg-recording.log
    exit 1
fi

# Save state (quote values to handle spaces)
cat > "$STATE_FILE" <<STATEEOF
FFMPEG_PID="$FFMPEG_PID"
AUDIO_FILE="$AUDIO_FILE"
MEETING_NAME="$MEETING_NAME"
FILENAME="$FILENAME"
START_TIME="$(date "+%Y-%m-%d %H:%M:%S")"
ORIGINAL_OUTPUT="$ORIGINAL_OUTPUT"
STATEEOF

echo "Recording started (PID: $FFMPEG_PID)"

# Copy meeting name to clipboard (useful for other workflows)
echo -n "$MEETING_NAME" | pbcopy

# Notification
osascript -e "display notification \"Recording: $MEETING_NAME\" with title \"Meeting Recorder\""
