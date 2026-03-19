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

# --- Hallucination detection and retranscription ---
# Post-transcription defense: detects Whisper context-loop hallucinations
# (a line repeated >20 times) and retranscribes the affected segment.
HALLUCINATION_THRESHOLD=20

# detect_hallucination SRT_FILE
# Prints START_SEC,END_SEC pairs (one per line) for hallucinated ranges, or nothing if clean.
detect_hallucination() {
    local srt_file="$1"
    [ ! -f "$srt_file" ] && return 0

    # Get total duration from last SRT timestamp for clamping and threshold scaling
    local total_secs
    total_secs=$(grep '\-\->' "$srt_file" | tail -1 | sed 's/.*--> //' | awk -F'[,:]' '{print $1*3600 + $2*60 + $3}')

    # Scale threshold by duration: base 20 per 15-min block
    # A 45-min meeting legitimately has "Yeah" 30+ times — don't false-positive
    local duration_mins=$(( (total_secs + 59) / 60 ))
    local scaled_threshold=$(( HALLUCINATION_THRESHOLD * (duration_mins / 15 + 1) ))
    echo "Hallucination threshold: $scaled_threshold (base=$HALLUCINATION_THRESHOLD, duration=${duration_mins}min)" >> /tmp/meeting-recorder.log

    # Find lines repeated more than threshold times
    local hallucinated_lines
    hallucinated_lines=$(grep -v '^[0-9]*$' "$srt_file" | grep -v '^$' | grep -v '\-\->' \
        | sort | uniq -c | sort -rn \
        | awk -v thresh="$scaled_threshold" '$1 > thresh { $1=""; print substr($0,2) }')

    [ -z "$hallucinated_lines" ] && return 0

    echo "Hallucination detected! Repeated lines:" >> /tmp/meeting-recorder.log
    echo "$hallucinated_lines" >> /tmp/meeting-recorder.log

    # Write hallucinated lines to temp file (BSD awk can't handle newlines in -v)
    local hall_tmp
    hall_tmp=$(mktemp /tmp/hall-lines-XXXXXX)
    echo "$hallucinated_lines" > "$hall_tmp"

    # Find timestamp ranges of hallucinated segments
    # Parse SRT: for each subtitle block, check if its text matches a hallucinated line
    awk -v total="$total_secs" '
    BEGIN { range_start = -1; range_end = -1 }
    NR == FNR {
        # First file: build lookup of hallucinated lines
        line = $0
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line != "") hall[line] = 1
        next
    }
    /^[0-9]+$/ { next }
    /-->/ {
        # Parse start and end timestamps
        split($0, ts, " --> ")
        split(ts[1], s, /[,:]/)
        split(ts[2], e, /[,:]/)
        cur_start = s[1]*3600 + s[2]*60 + s[3]
        cur_end = e[1]*3600 + e[2]*60 + e[3]
        next
    }
    /^$/ { next }
    {
        # Text line — check if hallucinated
        line = $0
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line in hall) {
            if (range_start < 0) {
                range_start = cur_start
            }
            range_end = cur_end
        } else {
            if (range_start >= 0) {
                # Emit range with 30s padding, clamped
                rs = range_start - 30; if (rs < 0) rs = 0
                re = range_end + 30; if (re > total) re = total
                print int(rs) "," int(re)
                range_start = -1
                range_end = -1
            }
        }
    }
    END {
        if (range_start >= 0) {
            rs = range_start - 30; if (rs < 0) rs = 0
            re = range_end + 30; if (re > total) re = total
            print int(rs) "," int(re)
        }
    }
    ' "$hall_tmp" "$srt_file"

    rm -f "$hall_tmp"
}

# retranscribe_and_splice WAV_FILE SRT_FILE
# Detects hallucination, retranscribes affected segments, splices result back.
retranscribe_and_splice() {
    local wav_file="$1"
    local srt_file="$2"
    local ranges
    ranges=$(detect_hallucination "$srt_file")

    [ -z "$ranges" ] && return 0

    echo "Hallucination ranges to retranscribe: $ranges" >> /tmp/meeting-recorder.log
    osascript -e 'display notification "Hallucination detected — retranscribing affected segment..." with title "Meeting Recorder"'

    # Extract the repeating pattern for --suppress-regex
    # Get the most-repeated line, strip the count prefix, then regex-escape it
    local suppress_pattern
    suppress_pattern=$(grep -v '^[0-9]*$' "$srt_file" | grep -v '^$' | grep -v '\-\->' \
        | sort | uniq -c | sort -rn | head -1 \
        | sed 's/^[[:space:]]*[0-9]*//' | sed 's/^[[:space:]]*//' \
        | sed 's/[.?*+^$()|[\\]/\\&/g')

    echo "$ranges" | while IFS=',' read -r range_start range_end; do
        [ -z "$range_start" ] && continue
        # Validate range: start must be less than end (inverted ranges indicate
        # non-monotonic SRT timestamps, which would cause splice_srt to explode)
        if [ "$range_start" -ge "$range_end" ]; then
            echo "  Skipping invalid range: ${range_start}s - ${range_end}s (start >= end)" >> /tmp/meeting-recorder.log
            continue
        fi
        local duration=$((range_end - range_start))
        echo "Retranscribing range: ${range_start}s - ${range_end}s (${duration}s)" >> /tmp/meeting-recorder.log

        local chunk_dir
        chunk_dir=$(mktemp -d /tmp/whisper-retranscribe-XXXXXX)

        # Split into 2-minute sub-chunks for fresh context
        local sub_chunk_size=120
        local sub_num=0
        local sub_srt="$chunk_dir/combined.srt"
        > "$sub_srt"

        for ((offset=0; offset<duration; offset+=sub_chunk_size)); do
            sub_num=$((sub_num + 1))
            local abs_start=$((range_start + offset))
            local remaining=$((duration - offset))
            local this_chunk_dur=$sub_chunk_size
            [ "$remaining" -lt "$this_chunk_dur" ] && this_chunk_dur=$remaining
            [ "$this_chunk_dur" -le 0 ] && break

            local sub_file="$chunk_dir/sub_$(printf '%02d' $sub_num).wav"
            ffmpeg -y -hide_banner -ss "$abs_start" -t "$this_chunk_dur" -i "$wav_file" -c:a pcm_s16le "$sub_file" 2>/dev/null

            # Build retranscription args: max-context 0 is the key fix
            local retry_args=("${WHISPER_ARGS[@]}")
            # Remove existing -otxt flag (we only want SRT for splicing)
            local clean_args=()
            for arg in "${retry_args[@]}"; do
                [ "$arg" = "-otxt" ] && continue
                clean_args+=("$arg")
            done
            # Override max-context to 0 (no context carryover)
            local final_args=()
            local skip_next=false
            for arg in "${clean_args[@]}"; do
                if [ "$skip_next" = true ]; then
                    skip_next=false
                    continue
                fi
                if [ "$arg" = "--max-context" ]; then
                    skip_next=true
                    continue
                fi
                final_args+=("$arg")
            done
            final_args+=(--max-context 0)
            final_args+=(-osrt)

            # Add suppress-regex if we have a pattern
            if [ -n "$suppress_pattern" ]; then
                final_args+=(--suppress-regex "$suppress_pattern")
            fi

            echo "  Sub-chunk $sub_num: offset=${offset}s, duration=${this_chunk_dur}s" >> /tmp/meeting-recorder.log
            whisper-cli "${final_args[@]}" -f "$sub_file" 2>> /tmp/meeting-recorder.log

            if [ -f "${sub_file}.srt" ]; then
                # Offset sub-chunk timestamps by their position within the range
                offset_srt_timestamps "${sub_file}.srt" "$offset" >> "$sub_srt"
            fi
        done

        # Check if retranscription still has hallucination
        local retry_count=0
        local max_retries=2

        while [ $retry_count -lt $max_retries ]; do
            local recheck
            recheck=$(detect_hallucination "$sub_srt")
            if [ -z "$recheck" ]; then
                echo "  Retranscription clean on pass $((retry_count + 1))" >> /tmp/meeting-recorder.log
                break
            fi

            retry_count=$((retry_count + 1))
            echo "  Retranscription still hallucinated, pass $((retry_count + 1))..." >> /tmp/meeting-recorder.log

            if [ $retry_count -eq 1 ]; then
                # Pass 2: medium model + lower entropy threshold
                > "$sub_srt"
                sub_num=0
                for ((offset=0; offset<duration; offset+=sub_chunk_size)); do
                    sub_num=$((sub_num + 1))
                    local abs_start=$((range_start + offset))
                    local remaining=$((duration - offset))
                    local this_chunk_dur=$sub_chunk_size
                    [ "$remaining" -lt "$this_chunk_dur" ] && this_chunk_dur=$remaining
                    [ "$this_chunk_dur" -le 0 ] && break

                    local sub_file="$chunk_dir/sub_$(printf '%02d' $sub_num).wav"
                    ffmpeg -y -hide_banner -ss "$abs_start" -t "$this_chunk_dur" -i "$wav_file" -c:a pcm_s16le "$sub_file" 2>/dev/null

                    # Use medium model with aggressive entropy threshold
                    local pass2_args=(-m "$WHISPER_MODEL_MEDIUM" -osrt -l en -t 4)
                    pass2_args+=(--prompt "$WHISPER_PROMPT")
                    pass2_args+=(--suppress-nst)
                    pass2_args+=(--max-context 0)
                    pass2_args+=(-et 2.0)
                    if [ -f "$WHISPER_VAD_MODEL" ]; then
                        pass2_args+=(--vad -vm "$WHISPER_VAD_MODEL")
                    fi
                    if [ -n "$suppress_pattern" ]; then
                        pass2_args+=(--suppress-regex "$suppress_pattern")
                    fi

                    whisper-cli "${pass2_args[@]}" -f "$sub_file" 2>> /tmp/meeting-recorder.log
                    if [ -f "${sub_file}.srt" ]; then
                        offset_srt_timestamps "${sub_file}.srt" "$offset" >> "$sub_srt"
                    fi
                done
            else
                # Pass 3: give up, insert gap marker
                echo "  All retranscription passes failed — inserting gap marker" >> /tmp/meeting-recorder.log
                cat > "$sub_srt" << GAPSRT
1
00:00:00,000 --> 00:00:01,000
[transcription gap — audio could not be reliably transcribed]

GAPSRT
                break
            fi
        done

        # Splice the retranscribed SRT back into the original
        splice_srt "$srt_file" "$sub_srt" "$range_start" "$range_end"

        rm -rf "$chunk_dir"
    done

    # Rebuild .txt from the spliced SRT
    local txt_file="${srt_file%.srt}.txt"
    rebuild_txt "$srt_file" "$txt_file"

    echo "Hallucination remediation complete" >> /tmp/meeting-recorder.log
    osascript -e 'display notification "Retranscription complete" with title "Meeting Recorder"'
}

# offset_srt_timestamps SRT_FILE OFFSET_SECS
# Reads an SRT file and adds OFFSET_SECS to all timestamps, writing to stdout.
offset_srt_timestamps() {
    local srt_file="$1"
    local offset="$2"

    awk -v offset="$offset" '
    function fmt(total_s) {
        hh = int(total_s / 3600)
        mm = int((total_s % 3600) / 60)
        ss_val = int(total_s % 60)
        ms_val = int((total_s - int(total_s)) * 1000)
        return sprintf("%02d:%02d:%02d,%03d", hh, mm, ss_val, ms_val)
    }
    /-->/ {
        split($0, parts, " --> ")
        split(parts[1], sa, /[,:]/)
        split(parts[2], ea, /[,:]/)
        ss = sa[1]*3600 + sa[2]*60 + sa[3] + sa[4]/1000 + offset
        es = ea[1]*3600 + ea[2]*60 + ea[3] + ea[4]/1000 + offset
        print fmt(ss) " --> " fmt(es)
        next
    }
    { print }
    ' "$srt_file"
}

# splice_srt ORIGINAL_SRT REPLACEMENT_SRT RANGE_START_SEC RANGE_END_SEC
# Replaces entries in ORIGINAL_SRT that fall within the hallucinated range
# with entries from REPLACEMENT_SRT (offset to absolute time), renumbers sequentially.
splice_srt() {
    local original="$1"
    local replacement="$2"
    local range_start="$3"
    local range_end="$4"

    local tmp_out
    tmp_out=$(mktemp /tmp/spliced-srt-XXXXXX.srt)

    # Extract entries before the hallucinated range
    awk -v rstart="$range_start" '
    BEGIN { keep = 1; block_start = -1 }
    /^[0-9]+$/ && !/-->/ {
        idx = $0
        next
    }
    /-->/ {
        split($0, parts, " --> ")
        split(parts[1], s, /[,:]/)
        ts = s[1]*3600 + s[2]*60 + s[3]
        if (ts >= rstart) { keep = 0 }
        if (keep) { timestamp_line = $0 }
        next
    }
    /^$/ {
        if (keep && timestamp_line != "") {
            print idx
            print timestamp_line
            print text_line
            print ""
        }
        timestamp_line = ""
        text_line = ""
        next
    }
    { if (keep) text_line = $0 }
    ' "$original" > "$tmp_out"

    # Append replacement entries with timestamps offset to absolute position
    awk -v rstart="$range_start" '
    function fmt(total_s) {
        hh = int(total_s / 3600)
        mm = int((total_s % 3600) / 60)
        ss_val = int(total_s % 60)
        ms_val = int((total_s - int(total_s)) * 1000)
        return sprintf("%02d:%02d:%02d,%03d", hh, mm, ss_val, ms_val)
    }
    /-->/ {
        split($0, parts, " --> ")
        split(parts[1], sa, /[,:]/)
        split(parts[2], ea, /[,:]/)
        ss = sa[1]*3600 + sa[2]*60 + sa[3] + sa[4]/1000 + rstart
        es = ea[1]*3600 + ea[2]*60 + ea[3] + ea[4]/1000 + rstart
        print fmt(ss) " --> " fmt(es)
        next
    }
    { print }
    ' "$replacement" >> "$tmp_out"

    # Append entries after the hallucinated range
    awk -v rend="$range_end" '
    BEGIN { past = 0; buffer_idx = ""; buffer_ts = ""; buffer_text = "" }
    /^[0-9]+$/ && !/-->/ {
        buffer_idx = $0
        next
    }
    /-->/ {
        split($0, parts, " --> ")
        split(parts[1], s, /[,:]/)
        ts = s[1]*3600 + s[2]*60 + s[3]
        if (ts >= rend) { past = 1 }
        buffer_ts = $0
        next
    }
    /^$/ {
        if (past && buffer_ts != "") {
            print buffer_idx
            print buffer_ts
            print buffer_text
            print ""
        }
        buffer_idx = ""; buffer_ts = ""; buffer_text = ""
        next
    }
    { buffer_text = $0 }
    ' "$original" >> "$tmp_out"

    # Renumber all entries sequentially
    awk '
    BEGIN { num = 0 }
    /^[0-9]+$/ && !/-->/ {
        num++
        print num
        next
    }
    { print }
    ' "$tmp_out" > "$original"

    rm -f "$tmp_out"
    echo "SRT spliced: replaced ${range_start}s-${range_end}s" >> /tmp/meeting-recorder.log
}

# rebuild_txt SRT_FILE TXT_FILE
# Regenerates plain text transcript from SRT (strips indices and timestamps).
rebuild_txt() {
    local srt_file="$1"
    local txt_file="$2"

    grep -v '^[0-9]*$' "$srt_file" | grep -v '^$' | grep -v '\-\->' | sed 's/^[[:space:]]*//' > "$txt_file"
    echo "Rebuilt .txt from spliced SRT" >> /tmp/meeting-recorder.log
}

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

# --- Part-file concatenation ---
# If partial recordings exist (e.g., from an audio daemon restart mid-meeting),
# find and prepend them before transcription. Matches files with similar names
# in the same directory: "- part1.m4a", "- part 1.m4a", "- partial.m4a",
# " (1).m4a" suffixes, etc.
find_part_files() {
    local base="$1"
    local dir="$2"
    local parts=()

    # Look for files that start with the same basename + a suffix before .m4a
    # Sort alphabetically so parts are in order (part1 before part2, etc.)
    while IFS= read -r -d '' f; do
        # Skip the main file itself
        [ "$f" = "${dir}/${base}.m4a" ] && continue
        parts+=("$f")
    done < <(find "$dir" -maxdepth 1 -name "${base}*" -name "*.m4a" -print0 | sort -z)

    # Also check for files matching the base WITHOUT trailing suffix variations
    # e.g., base="2026-03-18 1200 - Meeting Name" matches
    #        "2026-03-18 1200 - Meeting Name - part1.m4a"
    #        "2026-03-18 1200 - Meeting Name (2).m4a"
    printf '%s\n' "${parts[@]}"
}

PART_FILES=$(find_part_files "$BASENAME" "$DIRNAME")
if [ -n "$PART_FILES" ]; then
    echo "Found partial recording files:" >> /tmp/meeting-recorder.log
    echo "$PART_FILES" >> /tmp/meeting-recorder.log

    # Build ffmpeg concat list: part files first (sorted), then the main recording last
    CONCAT_LIST=$(mktemp /tmp/concat-list-XXXXXX.txt)
    while IFS= read -r part; do
        [ -z "$part" ] && continue
        echo "file '$part'" >> "$CONCAT_LIST"
        echo "  Prepending: $(basename "$part")" >> /tmp/meeting-recorder.log
    done <<< "$PART_FILES"
    echo "file '$AUDIO_FILE'" >> "$CONCAT_LIST"

    COMBINED_FILE="${DIRNAME}/${BASENAME}-combined.m4a"
    echo "Concatenating $(echo "$PART_FILES" | wc -l | tr -d ' ') part(s) + main recording..." >> /tmp/meeting-recorder.log
    osascript -e 'display notification "Combining partial recordings..." with title "Meeting Recorder"'

    if ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -c copy "$COMBINED_FILE" 2>> /tmp/meeting-recorder.log; then
        # Replace the main file with the combined version
        mv "$COMBINED_FILE" "$AUDIO_FILE"
        echo "Combined recording saved as: $AUDIO_FILE" >> /tmp/meeting-recorder.log

        # Move part files to processed subfolder
        PROCESSED_DIR="${DIRNAME}/processed"
        mkdir -p "$PROCESSED_DIR"
        while IFS= read -r part; do
            [ -z "$part" ] && continue
            mv "$part" "$PROCESSED_DIR/"
            echo "  Moved $(basename "$part") to processed/" >> /tmp/meeting-recorder.log
        done <<< "$PART_FILES"
    else
        echo "WARNING: Concatenation failed — proceeding with main recording only" >> /tmp/meeting-recorder.log
        osascript -e 'display notification "⚠️ Could not combine parts — using main recording only" with title "Meeting Recorder"'
        rm -f "$COMBINED_FILE"
    fi

    rm -f "$CONCAT_LIST"
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
            # Offset timestamps by chunk position (each chunk's SRT starts at 0:00)
            CHUNK_BASENAME=$(basename "$CHUNK" .wav)
            CHUNK_IDX=${CHUNK_BASENAME#chunk_}
            CHUNK_OFFSET=$(( (10#$CHUNK_IDX - 1) * CHUNK_SIZE ))
            if [ "$CHUNK_OFFSET" -eq 0 ]; then
                cat "${CHUNK}.srt" >> "$SRT_FILE"
            else
                offset_srt_timestamps "${CHUNK}.srt" "$CHUNK_OFFSET" >> "$SRT_FILE"
            fi
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

# Post-transcription hallucination detection and remediation
SRT_FILE="${DIRNAME}/${BASENAME}.srt"
if [ -f "$SRT_FILE" ]; then
    HALL_RANGES=$(detect_hallucination "$SRT_FILE")
    if [ -n "$HALL_RANGES" ]; then
        echo "Hallucination detected — initiating retranscription" >> /tmp/meeting-recorder.log
        retranscribe_and_splice "$WAV_FILE" "$SRT_FILE"
    else
        echo "No hallucination detected — SRT is clean" >> /tmp/meeting-recorder.log
    fi
fi

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
    MAX_RETRIES=3
    RETRY_DELAY=30
    ATTEMPT=1
    SUCCESS=false

    while [ "$ATTEMPT" -le "$MAX_RETRIES" ]; do
        echo "Meeting intelligence attempt $ATTEMPT of $MAX_RETRIES" >> /tmp/meeting-intelligence.log
        /Users/will/.local/bin/claude -p "BACKGROUND_MODE=true — Process this meeting transcript and add an intelligence summary BEFORE the ## Transcript section. The file is at: $NOTE_FILE" \
            --agent meeting-intelligence-processor \
            --dangerously-skip-permissions \
            >> /tmp/meeting-intelligence.log 2>&1

        if [ $? -eq 0 ]; then
            SUCCESS=true
            break
        fi

        echo "Attempt $ATTEMPT failed, retrying in ${RETRY_DELAY}s..." >> /tmp/meeting-intelligence.log
        ATTEMPT=$((ATTEMPT + 1))
        sleep "$RETRY_DELAY"
    done

    if [ "$SUCCESS" = true ]; then
        osascript -e 'display notification "AI analysis complete — run meeting-tasks-extractor to review tasks" with title "Meeting Recorder" sound name "Glass"'
        echo "Meeting intelligence completed successfully (attempt $ATTEMPT)" >> /tmp/meeting-recorder.log
    else
        osascript -e 'display notification "AI analysis failed after 3 attempts - check logs" with title "Meeting Recorder"'
        echo "Meeting intelligence failed after $MAX_RETRIES attempts" >> /tmp/meeting-recorder.log
    fi
) &

echo "Meeting intelligence started in background" >> /tmp/meeting-recorder.log
