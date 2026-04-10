#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Catch Me Up
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🧠
# @raycast.packageName Meeting Recorder
# @raycast.description Summarize the last few minutes of the live meeting transcript

TRANSCRIPT="/tmp/live-transcript.txt"
MINUTES=${1:-5}

if [ ! -f "$TRANSCRIPT" ]; then
    echo "No active meeting transcript."
    echo ""
    echo "Start a meeting recording first — the live transcript appears at $TRANSCRIPT"
    exit 0
fi

# Check file has content
if [ ! -s "$TRANSCRIPT" ]; then
    echo "Transcript file is empty — meeting may have just started."
    exit 0
fi

# Extract text from SRT format (strip timestamps and sequence numbers, keep speaker labels)
# Then take roughly the last N minutes worth (~150 words/min of speech)
WORDS_PER_MIN=150
WORD_COUNT=$((MINUTES * WORDS_PER_MIN))

TEXT=$(sed -n '/^[^0-9]/p' "$TRANSCRIPT" \
    | grep -v '\-\->' \
    | grep -v '^\s*$' \
    | sed 's/\[Speaker \([A-Z]\)\] /Speaker \1: /g' \
    | tr '\n' ' ' \
    | sed 's/  */ /g')

# Get the last N words
RECENT=$(echo "$TEXT" | awk -v n="$WORD_COUNT" '{
    split($0, words, " ")
    total = length(words)
    start = total - n
    if (start < 1) start = 1
    result = ""
    for (i = start; i <= total; i++) {
        result = result " " words[i]
    }
    print result
}')

if [ -z "$RECENT" ] || [ ${#RECENT} -lt 20 ]; then
    echo "Not enough transcript content yet. Keep talking!"
    exit 0
fi

# Summarize via Apple Foundation Models
echo "$RECENT" | /opt/homebrew/bin/afm -i "You are a meeting assistant. Based on this recent meeting transcript excerpt, provide:

1. **Current topic**: What's being discussed right now (1 sentence)
2. **Key points** (3-5 bullets): The most important things said
3. **Decisions made**: Any decisions or agreements (or 'None yet')
4. **Action items mentioned**: Any tasks assigned (or 'None yet')

Be concise. Use the speakers' actual words where helpful."
