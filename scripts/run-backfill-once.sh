#!/bin/bash
# Wrapper invoked by com.user.diarization-backfill launchd plist.
# Runs the backfill at most once, then no-ops on subsequent firings via marker file.
# Uses caffeinate to prevent system sleep, plus a watchdog timeout to prevent
# multi-hour runaways (e.g., the 15hr thermal runaway on 2026-05-14).

MARKER=/tmp/diarization-backfill.done
LOG=/tmp/diarization-backfill.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMEOUT_SEC=${BACKFILL_TIMEOUT_SEC:-7200}  # 2hr default; override via env

if [ -f "$MARKER" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skipping: marker $MARKER exists" >> "$LOG"
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backfill starting (PID=$$, timeout=${TIMEOUT_SEC}s)" >> "$LOG"

# Python writes its structured log directly to $LOG. Its stdout (print output,
# plus any subprocess stderr) goes to a separate file so $LOG doesn't get
# duplicated lines from the two write paths.
caffeinate -i "$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/backfill-diarization.py" \
    >> "$LOG.subprocess" 2>&1 &
PYTHON_PID=$!

# Watchdog: SIGTERM python if it's still alive after the timeout. macOS has
# no `timeout` command, so we background a sleep+kill alongside the work and
# tear it down when work finishes naturally.
(
    sleep "$TIMEOUT_SEC"
    if kill -0 "$PYTHON_PID" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watchdog: backfill exceeded ${TIMEOUT_SEC}s, sending SIGTERM" >> "$LOG"
        kill -TERM "$PYTHON_PID"
        sleep 10
        kill -KILL "$PYTHON_PID" 2>/dev/null
    fi
) &
WATCHDOG_PID=$!

wait "$PYTHON_PID"
RESULT=$?

kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backfill exited with status $RESULT" >> "$LOG"

# Only set the "all done forever" marker on a clean exit (status 0). The
# Python script exits 2 if any file errored, which means another run should
# pick up the remaining work via the progress state file.
if [ $RESULT -eq 0 ]; then
    touch "$MARKER"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Marker $MARKER created — future firings will no-op" >> "$LOG"
fi
