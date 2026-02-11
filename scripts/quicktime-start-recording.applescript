#!/usr/bin/osascript

-- QuickTime Audio Recording - Start
-- Triggered by MeetingBar or Raycast to start meeting recording

on run
    try
        tell application "QuickTime Player"
            activate
            delay 0.3

            -- Check if there's already an "Audio Recording" document (means we're recording)
            set docNames to name of every document
            if docNames contains "Audio Recording" then
                display notification "Already recording!" with title "Meeting Recorder"
                return "Already recording"
            end if

            -- Start new audio recording
            new audio recording
            delay 0.5

            -- Set audio source to Meeting Recording Input via UI automation
            -- (QuickTime's AppleScript "set current microphone" command is broken on modern macOS)
            set theDoc to document "Audio Recording"
            delay 0.3
        end tell

        tell application "System Events"
            tell process "QuickTime Player"
                tell window 1
                    set deviceButton to first button whose description is "show capture device selection pop up"
                    click deviceButton
                    delay 0.5
                    click menu item "Meeting Recording Input" of menu 1 of deviceButton
                    delay 0.3
                end tell
            end tell
        end tell

        tell application "QuickTime Player"
            -- Start the recording
            set theDoc to document "Audio Recording"
            start theDoc
            delay 0.3

            -- Minimize the window
            tell application "System Events"
                tell process "QuickTime Player"
                    try
                        click button 3 of window 1
                    end try
                end tell
            end tell
        end tell

        -- Log start time and save state for stop script
        set startTime to do shell script "date '+%Y-%m-%d %H:%M:%S'"
        set startHHMM to do shell script "date '+%H%M'"
        do shell script "echo 'Recording started: " & startTime & "' >> /tmp/meeting-recorder.log"
        do shell script "echo " & startHHMM & " > /tmp/meeting-recorder-start-time.txt"

        display notification "Recording started" with title "Meeting Recorder" sound name "Ping"
        return "Recording started at " & startTime

    on error errMsg
        display notification "Failed: " & errMsg with title "Meeting Recorder Error"
        do shell script "echo 'Error: " & errMsg & "' >> /tmp/meeting-recorder.log"
        return "Error: " & errMsg
    end try
end run
