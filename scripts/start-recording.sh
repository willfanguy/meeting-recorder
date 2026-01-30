#!/bin/bash
# Start meeting recording
# Called by MeetingBar when joining a meeting, or manually

set -e

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

# Ensure directories exist
mkdir -p "$RECORDINGS_DIR"
mkdir -p "$MEETING_NOTES_DIR"

# Get current meeting name from Calendar (with timeout)
get_meeting_name() {
    # Use perl timeout to prevent hanging if calendar permissions aren't granted
    local result
    result=$(perl -e 'alarm 5; exec @ARGV' osascript -e '
tell application "Calendar"
    set currentDate to current date
    set startTime to currentDate - (5 * minutes)
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
        return "Meeting"
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
' 2>/dev/null)
    # Fallback if calendar access fails or times out
    if [ -z "$result" ]; then
        echo "Meeting"
    else
        echo "$result"
    fi
}

# Check if already recording
if [ -f "$STATE_FILE" ]; then
    echo "Recording already in progress. Stop it first with stop-recording.sh"
    osascript -e 'display notification "Recording already in progress" with title "Meeting Recorder"'
    exit 1
fi

# Get meeting name and sanitize for filename
MEETING_NAME=$(get_meeting_name)
SAFE_NAME=$(echo "$MEETING_NAME" | tr '/:*?"<>|\\' '-' | tr -s '-')
TIMESTAMP=$(date "+%Y-%m-%d_%H%M")
FILENAME="${SAFE_NAME} - ${TIMESTAMP}"
AUDIO_FILE="$RECORDINGS_DIR/${FILENAME}.wav"

echo "Starting recording for: $MEETING_NAME"
echo "File: $AUDIO_FILE"

# Find the audio device index
DEVICE_INFO=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -n "$AUDIO_DEVICE" | head -1)
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
ffmpeg -y -f avfoundation -i ":${DEVICE_NUM}" \
    -c:a pcm_s16le -ar 16000 -ac 1 \
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
STATEEOF

echo "Recording started (PID: $FFMPEG_PID)"

# Copy meeting name to clipboard (useful for other workflows)
echo -n "$MEETING_NAME" | pbcopy

# Notification
osascript -e "display notification \"Recording: $MEETING_NAME\" with title \"Meeting Recorder\""
