#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Open Live Transcript
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 📝
# @raycast.packageName Meeting Recorder

LIVE_FILE_REF="/tmp/meeting-recorder-live-file.txt"

if [ ! -f "$LIVE_FILE_REF" ]; then
    echo "No live transcript active"
    exit 0
fi

LIVE_FILE=$(cat "$LIVE_FILE_REF")

if [ ! -f "$LIVE_FILE" ]; then
    echo "Live transcript file not found"
    exit 1
fi

# Open in Obsidian via URI scheme
# Encode the vault-relative path for the Obsidian URI
VAULT_PATH="${OBSIDIAN_VAULT_PATH:-$HOME/Vaults/HigherJump/}"  # Set OBSIDIAN_VAULT_PATH in your env or update this default
REL_PATH="${LIVE_FILE#$VAULT_PATH}"
ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$REL_PATH'))")
open "obsidian://open?vault=HigherJump&file=${ENCODED}"
