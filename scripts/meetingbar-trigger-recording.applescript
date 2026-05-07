#!/usr/bin/osascript

-- MeetingBar trigger — redirects auto-start to Raycast's URL handler.
--
-- Why this layer exists: MeetingBar lacks NSMicrophoneUsageDescription in its
-- Info.plist, so macOS silently denies microphone access to any subprocess
-- MeetingBar spawns (including AppleScripts and any binaries they launch).
-- This was causing auto-started meeting recordings to capture only Zoom's
-- remote audio while missing Will's voice entirely.
--
-- Fix: instead of having MeetingBar run quicktime-start-recording.applescript
-- directly, point MeetingBar at THIS script. All this script does is fire the
-- raycast:// URL, handing control to Raycast (which has approved mic TCC).
-- Raycast then runs the normal recording chain under its own TCC identity, so
-- the Swift CLI inherits approved mic permission and captures Will's voice.
--
-- Chain when MeetingBar auto-fires:
--   MeetingBar → this script → `open raycast://...`
--     → Raycast (URL handler, approved mic TCC)
--     → raycast/start-meeting-recording.sh
--     → osascript quicktime-start-recording.applescript
--     → meeting-recorder --include-mic (inherits Raycast TCC)
--
-- Chain when Will manually triggers from Raycast:
--   Raycast → raycast/start-meeting-recording.sh → ... (same as above)
--
-- Either path produces a recording with Will's mic captured correctly.
--
-- See task note: ~/Vaults/HigherJump/4. Resources/Work Log/Tasks/Fix MeetingBar mic TCC permission.md

on run
    try
        do shell script "open 'raycast://script-commands/start-meeting-recording' >/dev/null 2>&1"
        do shell script "echo '[$(date \"+%Y-%m-%d %H:%M:%S\")] meetingbar-trigger fired Raycast deeplink' >> /tmp/meeting-recorder.log"
        return "Fired Raycast deeplink"
    on error errMsg
        display notification "Failed to fire Raycast deeplink: " & errMsg with title "Meeting Recorder Error"
        do shell script "echo '[$(date \"+%Y-%m-%d %H:%M:%S\")] meetingbar-trigger ERROR: " & errMsg & "' >> /tmp/meeting-recorder.log"
        return "Error: " & errMsg
    end try
end run
