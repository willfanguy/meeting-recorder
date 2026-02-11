#!/usr/bin/osascript

-- QuickTime Audio Recording - Stop
-- Stops recording, saves with proper meeting name, triggers transcription

property recordingsFolder : "/Users/will/Meeting Transcriptions/"
property tempFolder : "/Users/will/Movies/"  -- QuickTime has sandbox access here
property dailyNotesFolder : "/Users/will/Vaults/HigherJump/4. Resources/Daily Notes/"

on run
    try
        tell application "QuickTime Player"
            -- Check if there's any document open
            if (count of documents) is 0 then
                display notification "No active recording" with title "Meeting Recorder"
                return "No active recording"
            end if

            -- Get first document (the recording)
            set theDoc to document 1
            set docName to name of theDoc

            -- If it's "Audio Recording", stop it first
            if docName is "Audio Recording" then
                stop theDoc
                delay 0.5
            end if
        end tell

        -- Get current date/time info
        set currentDate to do shell script "date '+%Y-%m-%d'"
        set currentHour to do shell script "date '+%H%M'"

        -- Try MeetingBar metadata first (written by eventStartScript.scpt)
        set meetingName to ""
        set eventTime to ""
        set metadataFile to "/tmp/meeting-recorder-metadata.json"
        set hasMetadata to false
        try
            set metaCheck to do shell script "[ -f " & quoted form of metadataFile & " ] && echo yes || echo no"
            if metaCheck is "yes" then
                set meetingName to do shell script "python3 -c \"import json; print(json.load(open('" & metadataFile & "'))['title'])\""
                set eventTime to do shell script "python3 -c \"import json; print(json.load(open('" & metadataFile & "'))['startTime'])\""
                set currentDate to do shell script "python3 -c \"import json; print(json.load(open('" & metadataFile & "'))['startDate'])\""
                set hasMetadata to true
                do shell script "echo 'Using MeetingBar metadata: " & meetingName & "' >> /tmp/meeting-recorder.log"
            end if
        on error metaErr
            do shell script "echo 'Metadata read error: " & metaErr & "' >> /tmp/meeting-recorder.log"
        end try

        -- Fall back to daily note parsing (Raycast-triggered recordings)
        if meetingName is "" then
            set startHour to currentHour
            try
                set startHour to do shell script "cat /tmp/meeting-recorder-start-time.txt 2>/dev/null | tr -d '\\n'"
                if startHour is "" then set startHour to currentHour
            on error
                set startHour to currentHour
            end try
            do shell script "rm -f /tmp/meeting-recorder-start-time.txt"

            set meetingResult to my getMeetingForTime(currentDate, startHour)
            set meetingName to item 1 of meetingResult
            set eventTime to item 2 of meetingResult
        end if

        -- Apply defaults
        if meetingName is "" then
            set meetingName to "Meeting"
        end if
        if eventTime is "" then
            set eventTime to currentHour
        end if
        set fileName to currentDate & " " & eventTime & " - " & my sanitizeFilename(meetingName)
        set tempPath to tempFolder & fileName & ".m4a"
        set finalPath to recordingsFolder & fileName & ".m4a"

        -- Export to Movies folder (QuickTime has sandbox access)
        -- Note: Long recordings (30+ min) can take 2-3 minutes to export
        tell application "QuickTime Player"
            set theDoc to document 1
            try
                with timeout of 300 seconds
                    export theDoc in tempPath using settings preset "Audio Only"
                end timeout
            on error exportErr
                -- If export fails, force close to prevent stuck modal
                close theDoc saving no
                error "Export failed: " & exportErr
            end try
            delay 1
            close theDoc saving no
        end tell

        -- Move to final destination
        do shell script "mv " & quoted form of tempPath & " " & quoted form of finalPath

        -- Move metadata alongside audio for transcribe script
        if hasMetadata then
            set metadataFinalPath to recordingsFolder & fileName & ".json"
            do shell script "mv " & quoted form of metadataFile & " " & quoted form of metadataFinalPath
        else
            do shell script "rm -f " & quoted form of metadataFile
        end if

        display notification "Saved: " & fileName with title "Meeting Recorder"
        do shell script "echo 'Recording saved: " & finalPath & "' >> /tmp/meeting-recorder.log"

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

        -- Fall back to hour-only match (e.g., "10" matches "2026-02-06 10xx")
        if matchLine is "" then
            set targetHour to text 1 thru 2 of timeStr
            set hourPattern to "Meeting Notes/" & dateStr & " " & targetHour
            set matchLine to do shell script "grep -o '\\[\\[.*" & hourPattern & ".*|[^]]*\\]\\]' " & quoted form of dailyNote & " 2>/dev/null | head -1"
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
