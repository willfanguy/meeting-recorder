#!/bin/bash
# Wrapper invoked by com.user.enroll-from-summary launchd plist.
# Scans the last N meeting notes for high-confidence Speaker Identification
# rows and auto-enrolls them into the voice embedding library.

LOG=/tmp/enroll-from-summary.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECENT_COUNT=25

echo "[$(date '+%Y-%m-%d %H:%M:%S')] enroll-from-summary starting (--recent $RECENT_COUNT)" >> "$LOG"

"$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/enroll-from-summary.py" --recent "$RECENT_COUNT" >> "$LOG" 2>&1
RESULT=$?

echo "[$(date '+%Y-%m-%d %H:%M:%S')] enroll-from-summary exited with status $RESULT" >> "$LOG"
exit $RESULT
