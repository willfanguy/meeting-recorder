#!/bin/bash
# Signal that a meeting has started by writing a marker to the live transcript.
# The viewer shows only content after the last marker.
#
# Usage: signal-meeting-start.sh [meeting-name]
#   meeting-name: Optional. Falls back to metadata file, then "Meeting".
#
# If yap isn't running, attempts to start it via Terminal.app (TCC fallback).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIPT_FILE="/tmp/live-transcript.txt"
PID_FILE="/tmp/meeting-recorder-live-pid.txt"
METADATA_FILE="/tmp/meeting-recorder-active-session.json"
LOG="/tmp/meeting-recorder.log"

# Resolve meeting name
MEETING_NAME="${1:-}"
if [ -z "$MEETING_NAME" ] && [ -f "$METADATA_FILE" ]; then
    MEETING_NAME=$(python3 -c "import json; print(json.load(open('$METADATA_FILE'))['title'])" 2>/dev/null || echo "")
fi
if [ -z "$MEETING_NAME" ]; then
    MEETING_NAME="Meeting"
fi

# Write meeting-start marker (prepend newline — yap's PTY output may not end with one)
printf '\n--- MEETING START: %s @ %s ---\n' "$MEETING_NAME" "$(date '+%Y-%m-%d %H:%M')" >> "$TRANSCRIPT_FILE"
echo "$(date '+%H:%M:%S') [live] Meeting started: $MEETING_NAME" >> "$LOG"

# yap's Speech.framework recognizer can silently freeze after long-running
# sessions while the process stays alive. Age-cap must match start-live-transcript.sh.
MAX_YAP_AGE_SECS=${MAX_YAP_AGE_SECS:-28800}  # 8 hours

# Check if yap is running AND fresh — stale yap is treated like missing yap.
# kill -0 alone is insufficient: a silently-frozen yap passes the liveness check.
YAP_RUNNING=false
if [ -f "$PID_FILE" ]; then
    YAP_PID=$(cat "$PID_FILE")
    if kill -0 "$YAP_PID" 2>/dev/null; then
        START_STR=$(ps -o lstart= -p "$YAP_PID" 2>/dev/null || true)
        if [ -n "$START_STR" ]; then
            START_EPOCH=$(date -jf "%a %b %e %T %Y" "$START_STR" +%s 2>/dev/null || echo 0)
            AGE_SECS=$(( $(date +%s) - START_EPOCH ))
        else
            AGE_SECS=0
        fi

        if [ "$AGE_SECS" -gt "$MAX_YAP_AGE_SECS" ]; then
            echo "$(date '+%H:%M:%S') [live] yap stale (age ${AGE_SECS}s > ${MAX_YAP_AGE_SECS}s) -- killing for restart" >> "$LOG"
            kill -- -"$YAP_PID" 2>/dev/null || kill "$YAP_PID" 2>/dev/null || true
            pgrep -P "$YAP_PID" | xargs -r kill 2>/dev/null || true
            sleep 1
            rm -f "$PID_FILE"
        else
            YAP_RUNNING=true
        fi
    else
        rm -f "$PID_FILE"
    fi
fi

if [ "$YAP_RUNNING" = false ]; then
    echo "$(date '+%H:%M:%S') [live] yap not running, attempting to start..." >> "$LOG"

    # Try cmux first (works from non-sandboxed contexts)
    CMUX_BIN="/Applications/cmux.app/Contents/Resources/bin/cmux"
    DAEMON_CMD="$SCRIPT_DIR/start-live-transcript.sh >> $LOG 2>&1"

    if "$CMUX_BIN" new-workspace --name "Live Transcript" --command "$DAEMON_CMD" 2>/dev/null; then
        echo "$(date '+%H:%M:%S') [live] Started yap via cmux" >> "$LOG"
    else
        # Fallback: Terminal.app via .command file (works from sandboxed apps)
        CMD_FILE="/tmp/meeting-recorder-live-transcript.command"
        printf '#!/bin/bash\n%s\n' "$DAEMON_CMD" > "$CMD_FILE"
        chmod +x "$CMD_FILE"
        open -a Terminal.app "$CMD_FILE"
        echo "$(date '+%H:%M:%S') [live] Started yap via Terminal.app fallback" >> "$LOG"
    fi
fi
