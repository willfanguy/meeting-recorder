#!/usr/bin/osascript

-- Meeting Audio Recording - Stop (ffmpeg)
-- Stops ffmpeg recording, names file from metadata, triggers transcription

property recordingsFolder : "/Users/will/Meeting Transcriptions/"
property dailyNotesFolder : "/Users/will/Vaults/HigherJump/4. Resources/Daily Notes/"

on run
    try
        -- Check if recorder is active (works for both Swift CLI and ffmpeg)
        set pidFile to "/tmp/meeting-recorder.pid"
        set tempAudioFile to "/tmp/meeting-recording-temp.m4a"
        set recorderPid to ""
        try
            set recorderPid to do shell script "cat " & quoted form of pidFile & " 2>/dev/null || echo ''"
        end try
        if recorderPid is "" then
            display notification "No active recording" with title "Meeting Recorder"
            return "No active recording"
        end if

        -- Stop recorder gracefully (SIGINT flushes and closes the m4a container)
        try
            do shell script "kill -INT " & recorderPid & " 2>/dev/null || true"
            -- Wait for process to finish writing (up to 5 seconds)
            repeat with i from 1 to 10
                set isRunning to do shell script "kill -0 " & recorderPid & " 2>/dev/null && echo yes || echo no"
                if isRunning is "no" then exit repeat
                delay 0.5
            end repeat
            -- Force kill if still running
            set isStillRunning to do shell script "kill -0 " & recorderPid & " 2>/dev/null && echo yes || echo no"
            if isStillRunning is "yes" then
                do shell script "kill -9 " & recorderPid & " 2>/dev/null || true"
                delay 1
            end if
        end try
        do shell script "rm -f " & quoted form of pidFile

        -- Verify recording file exists and has content
        set fileCheck to do shell script "[ -f " & quoted form of tempAudioFile & " ] && echo yes || echo no"
        if fileCheck is "no" then
            display notification "Recording file not found" with title "Meeting Recorder Error"
            do shell script "echo 'Error: temp recording file not found at " & tempAudioFile & "' >> /tmp/meeting-recorder.log"
            return "Error: recording file not found"
        end if
        set fileSize to do shell script "stat -f%z " & quoted form of tempAudioFile & " 2>/dev/null || echo 0"
        if (fileSize as integer) < 10000 then
            do shell script "echo 'WARNING: Recording file very small (" & fileSize & " bytes) -- may have captured silence' >> /tmp/meeting-recorder.log"
        end if

        -- Get current date/time info
        set currentDate to do shell script "date '+%Y-%m-%d'"
        set currentHour to do shell script "date '+%H%M'"

        -- Get the actual recording start time (saved when recording began)
        set recordingStartHour to currentHour
        try
            set recordingStartHour to do shell script "cat /tmp/meeting-recorder-start-time.txt 2>/dev/null | tr -d '\\n'"
            if recordingStartHour is "" then set recordingStartHour to currentHour
        on error
            set recordingStartHour to currentHour
        end try
        do shell script "rm -f /tmp/meeting-recorder-start-time.txt"

        -- Try active session snapshot first (frozen at recording start)
        -- This is immune to the live metadata being overwritten by a later meeting
        set meetingName to ""
        set eventTime to ""
        set activeSession to "/tmp/meeting-recorder-active-session.json"
        set metadataFile to "/tmp/meeting-recorder-metadata.json"
        set hasMetadata to false
        set metadataSource to ""
        try
            -- Prefer the snapshot (frozen when recording started -- trustworthy)
            set snapshotCheck to do shell script "[ -f " & quoted form of activeSession & " ] && echo yes || echo no"
            if snapshotCheck is "yes" then
                set sessionFile to activeSession
                set metaTitle to do shell script "python3 -c \"import json; print(json.load(open('" & sessionFile & "'))['title'])\""
                set metaTime to do shell script "python3 -c \"import json; print(json.load(open('" & sessionFile & "'))['startTime'])\""
                set metaDate to do shell script "python3 -c \"import json; print(json.load(open('" & sessionFile & "'))['startDate'])\""

                set meetingName to metaTitle
                set eventTime to metaTime
                set currentDate to metaDate
                set hasMetadata to true
                set metadataSource to sessionFile
                do shell script "echo 'Using snapshot metadata: " & meetingName & " at " & metaTime & "' >> /tmp/meeting-recorder.log"
            else
                -- No snapshot -- fall back to live metadata with hour validation
                -- (live file may have been overwritten by a later meeting)
                set liveCheck to do shell script "[ -f " & quoted form of metadataFile & " ] && echo yes || echo no"
                if liveCheck is "yes" then
                    set sessionFile to metadataFile
                    set metaTitle to do shell script "python3 -c \"import json; print(json.load(open('" & sessionFile & "'))['title'])\""
                    set metaTime to do shell script "python3 -c \"import json; print(json.load(open('" & sessionFile & "'))['startTime'])\""
                    set metaDate to do shell script "python3 -c \"import json; print(json.load(open('" & sessionFile & "'))['startDate'])\""

                    -- Validate: metadata hour must match recording start hour
                    set metaStartHour to text 1 thru 2 of metaTime
                    set recordingStartHourPrefix to text 1 thru 2 of recordingStartHour
                    if metaStartHour is recordingStartHourPrefix then
                        set meetingName to metaTitle
                        set eventTime to metaTime
                        set currentDate to metaDate
                        set hasMetadata to true
                        set metadataSource to sessionFile
                        do shell script "echo 'Using live metadata (hour validated): " & meetingName & " at " & metaTime & "' >> /tmp/meeting-recorder.log"
                    else
                        do shell script "echo 'Live metadata stale: metadata says " & metaTime & " but recording started at " & recordingStartHour & ", falling back to daily note' >> /tmp/meeting-recorder.log"
                    end if
                end if
            end if
        on error metaErr
            do shell script "echo 'Metadata read error: " & metaErr & "' >> /tmp/meeting-recorder.log"
        end try

        -- Fall back to daily note parsing (stale metadata or Raycast-triggered recordings)
        if meetingName is "" then
            set meetingResult to my getMeetingForTime(currentDate, recordingStartHour)
            set meetingName to item 1 of meetingResult
            set eventTime to item 2 of meetingResult
            if meetingName is not "" then
                do shell script "echo 'Using daily note fallback: " & meetingName & " at " & eventTime & " (recording started at " & recordingStartHour & ")' >> /tmp/meeting-recorder.log"
            end if
        end if

        -- Apply defaults
        if meetingName is "" then
            set meetingName to "Meeting"
        end if
        if eventTime is "" then
            set eventTime to currentHour
        end if
        set fileName to currentDate & " " & eventTime & " - " & my sanitizeFilename(meetingName)
        set tempPath to tempAudioFile
        set finalPath to recordingsFolder & fileName & ".m4a"

        -- Move to final destination (with overwrite protection)
        set existingCheck to do shell script "[ -f " & quoted form of finalPath & " ] && echo yes || echo no"
        if existingCheck is "yes" then
            -- Append a numeric suffix to avoid overwriting
            set suffixNum to 2
            repeat
                set suffixedName to fileName & " (" & suffixNum & ")"
                set candidatePath to recordingsFolder & suffixedName & ".m4a"
                set candidateCheck to do shell script "[ -f " & quoted form of candidatePath & " ] && echo yes || echo no"
                if candidateCheck is "no" then
                    set finalPath to candidatePath
                    set fileName to suffixedName
                    exit repeat
                end if
                set suffixNum to suffixNum + 1
            end repeat
            do shell script "echo 'WARNING: file already existed, saved as " & fileName & "' >> /tmp/meeting-recorder.log"
            display notification "Warning: Name conflict -- saved as " & fileName with title "Meeting Recorder"
        end if
        do shell script "mv " & quoted form of tempPath & " " & quoted form of finalPath

        -- Move metadata alongside audio for transcribe script
        if hasMetadata then
            set metadataFinalPath to recordingsFolder & fileName & ".json"
            do shell script "cp " & quoted form of metadataSource & " " & quoted form of metadataFinalPath
        end if
        -- Clean up session snapshot and live metadata
        do shell script "rm -f " & quoted form of activeSession
        do shell script "rm -f " & quoted form of metadataFile

        display notification "Saved: " & fileName with title "Meeting Recorder"
        do shell script "echo 'Recording saved: " & finalPath & "' >> /tmp/meeting-recorder.log"

        -- Stop live transcript
        try
            do shell script "/Users/will/Repos/personal/meeting-recorder/scripts/stop-live-transcript.sh >> /tmp/meeting-recorder.log 2>&1"
        on error liveErr
            do shell script "echo 'Live transcript stop error (non-fatal): " & liveErr & "' >> /tmp/meeting-recorder.log"
        end try

        -- Trigger transcription in background
        my triggerTranscription(finalPath)

        return "Saved: " & fileName

    on error errMsg
        display notification "Error: " & errMsg with title "Meeting Recorder"
        do shell script "echo 'Error: " & errMsg & "' >> /tmp/meeting-recorder.log"
        return "Error: " & errMsg
    end try
end run

-- Get meeting name and event time from daily note based on recording start time
-- Returns {meetingName, eventTime} where eventTime is the HHMM from the link
on getMeetingForTime(dateStr, timeStr)
    try
        -- Find daily note for today
        set dailyNote to do shell script "ls " & quoted form of dailyNotesFolder & dateStr & "*.md 2>/dev/null | head -1"

        if dailyNote is "" then
            return {"", ""}
        end if

        -- Try exact 4-digit match first (e.g., "1030" matches "2026-02-06 1030")
        set exactPattern to "Meeting Notes/" & dateStr & " " & timeStr
        set matchLine to do shell script "grep -o '\\[\\[.*" & exactPattern & ".*|[^]]*\\]\\]' " & quoted form of dailyNote & " 2>/dev/null | head -1"

        -- Fall back to best-fit match within the hour
        -- Find the latest meeting that starts at or before recording time
        -- (prevents picking an earlier meeting when a later one is the correct match)
        if matchLine is "" then
            set targetHour to text 1 thru 2 of timeStr
            set hourPattern to "Meeting Notes/" & dateStr & " " & targetHour
            set matchLine to do shell script "grep -o '\\[\\[.*" & hourPattern & ".*|[^]]*\\]\\]' " & quoted form of dailyNote & " 2>/dev/null | while IFS= read -r line; do t=$(echo \"$line\" | grep -o '" & dateStr & " [0-9]\\{4\\}' | awk '{print $2}'); if [ \"$t\" -le \"" & timeStr & "\" ]; then echo \"$line\"; fi; done | tail -1"
        end if

        -- Hour boundary fix: if recording started at XX:55+ and no match yet,
        -- check the next hour's :00 meeting (handles joining a minute early)
        if matchLine is "" then
            set targetMinute to text 3 thru 4 of timeStr
            if targetMinute >= "55" then
                set nextHour to do shell script "printf '%02d' $(( " & targetHour & " + 1 ))"
                set nextHourPattern to "Meeting Notes/" & dateStr & " " & nextHour & "00"
                set matchLine to do shell script "grep -o '\\[\\[.*" & nextHourPattern & ".*|[^]]*\\]\\]' " & quoted form of dailyNote & " 2>/dev/null | head -1"
                if matchLine is not "" then
                    do shell script "echo 'Hour boundary match: recording at " & timeStr & " matched next-hour meeting at " & nextHour & "00' >> /tmp/meeting-recorder.log"
                end if
            end if
        end if

        if matchLine is "" then
            return {"", ""}
        end if

        -- Extract event time (4 digits after date in the link path)
        set eventTime to ""
        try
            set eventTime to do shell script "echo " & quoted form of matchLine & " | grep -o '" & dateStr & " [0-9]\\{4\\}' | awk '{print $2}'"
        end try

        -- Extract display name (part after |)
        if matchLine contains "|" then
            set AppleScript's text item delimiters to "|"
            set parts to text items of matchLine
            set displayName to item 2 of parts
            set AppleScript's text item delimiters to "]]"
            set displayName to item 1 of text items of displayName
            set AppleScript's text item delimiters to ""
            return {displayName, eventTime}
        end if

        return {"", eventTime}
    on error
        return {"", ""}
    end try
end getMeetingForTime

-- Sanitize filename
on sanitizeFilename(inputName)
    set cleanName to inputName
    set badChars to {":", "/", "\\", "|", "*", "?", "<", ">", "\""}
    repeat with badChar in badChars
        set AppleScript's text item delimiters to badChar
        set textItems to text items of cleanName
        set AppleScript's text item delimiters to "-"
        set cleanName to textItems as text
    end repeat
    set AppleScript's text item delimiters to ""
    -- Strip trailing hyphens and spaces (e.g. "prompts?" -> "prompts-" -> "prompts")
    repeat while cleanName ends with "-" or cleanName ends with " "
        set cleanName to text 1 thru -2 of cleanName
    end repeat
    return cleanName
end sanitizeFilename

-- Trigger transcription in background
on triggerTranscription(audioPath)
    try
        display notification "Starting transcription..." with title "Meeting Recorder"
        do shell script "/Users/will/Repos/personal/meeting-recorder/scripts/transcribe-and-process.sh " & quoted form of audioPath & " >> /tmp/meeting-recorder.log 2>&1 &"
    on error errMsg
        do shell script "echo 'Transcription trigger error: " & errMsg & "' >> /tmp/meeting-recorder.log"
    end try
end triggerTranscription
