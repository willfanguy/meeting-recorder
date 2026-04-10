#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Catch Me Up
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🧠
# @raycast.packageName Meeting Recorder
# @raycast.description Quick recap of the last 3 minutes of the live meeting

TRANSCRIPT="/tmp/live-transcript.txt"
MINUTES=3
WORDS_PER_MIN=150
WORD_COUNT=$((MINUTES * WORDS_PER_MIN))

if [ ! -f "$TRANSCRIPT" ] || [ ! -s "$TRANSCRIPT" ]; then
    echo "No active meeting transcript."
    exit 0
fi

# Extract text from SRT, apply domain corrections, get last 3 minutes
RECENT=$(sed -n '/^[^0-9]/p' "$TRANSCRIPT" \
    | grep -v '\-\->' \
    | grep -v '^\s*$' \
    | sed 's/\[Speaker \([A-Z]\)\] /Speaker \1: /g' \
    | tr '\n' ' ' \
    | sed 's/  */ /g' \
    | sed -e 's/glass door/Glassdoor/gi' \
          -e 's/super match/SuperMatch/gi' -e 's/superman/SuperMatch/gi' -e 's/supermatters/SuperMatch/gi' \
          -e 's/super fit/SuperFit/gi' \
          -e 's/project door/Project Door/gi' \
          -e 's/jobs for you/JobsForYou/gi' \
          -e 's/barker barker/blocker/gi' \
          -e 's/Gleen/Glean/gi' -e 's/Baya/beta/gi' \
          -e 's/co-complete/code complete/gi' \
          -e 's/but backs/bug bashes/gi' -e 's/evalves/evals/gi' \
          -e 's/Karen Hoff/Kaarin Hoff/gi' -e 's/Corinne Hoff/Kaarin Hoff/gi' \
          -e 's/Erin Breyer/Eric Breier/gi' -e 's/Erin Briar/Eric Breier/gi' \
          -e 's/Julie Wilding/Judith Wilding/gi' -e 's/Aaron Delevic/Aron Delevic/gi' \
    | awk -v n="$WORD_COUNT" '{
        split($0, words, " ")
        total = length(words)
        start = total - n
        if (start < 1) start = 1
        for (i = start; i <= total; i++) printf "%s ", words[i]
    }')

if [ ${#RECENT} -lt 20 ]; then
    echo "Not enough transcript yet."
    exit 0
fi

echo "$RECENT" | /opt/homebrew/bin/afm -i "Quick meeting recap. In 2-4 sentences, tell me what's being discussed right now and anything important I missed. Be direct and casual — I'm catching up mid-meeting."
