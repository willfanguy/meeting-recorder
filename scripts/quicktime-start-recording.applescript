#!/usr/bin/osascript

-- Meeting Audio Recording - Start (ffmpeg)
-- Triggered by MeetingBar or Raycast to start meeting recording
-- Records from "Meeting Recording Input" aggregate device via ffmpeg (no UI automation)

on run
    try
        set pidFile to "/tmp/meeting-recorder.pid"
        set tempAudioFile to "/tmp/meeting-recording-temp.m4a"

        -- Check if already recording
        try
            set existingPid to do shell script "cat " & quoted form of pidFile & " 2>/dev/null || echo ''"
            if existingPid is not "" then
                set isRunning to do shell script "kill -0 " & existingPid & " 2>/dev/null && echo yes || echo no"
                if isRunning is "yes" then
                    display notification "Already recording!" with title "Meeting Recorder"
                    return "Already recording"
                end if
            end if
        end try

        -- Remove stale temp file and PID
        do shell script "rm -f " & quoted form of tempAudioFile & " " & quoted form of pidFile

        -- Start recording via Swift CLI (Core Audio Taps — no BlackHole/aggregate device needed)
        -- Falls back to ffmpeg if Swift CLI is not installed
        set recorderBin to do shell script "PATH=$HOME/.local/bin:/opt/homebrew/bin:$PATH command -v meeting-recorder 2>/dev/null || echo ''"
        if recorderBin is "" then
            -- Fallback: ffmpeg with aggregate audio device
            do shell script "/opt/homebrew/bin/ffmpeg -nostdin -y -f avfoundation -i ':Meeting Recording Input' -af 'pan=1c|c0=c0+c1+c2+c3,aresample=async=1,alimiter=limit=0.9' -c:a aac -b:a 128k " & quoted form of tempAudioFile & " > /tmp/ffmpeg-recording.log 2>&1 & echo $! > " & quoted form of pidFile
            do shell script "echo 'Using ffmpeg fallback (meeting-recorder CLI not found)' >> /tmp/meeting-recorder.log"
        else
            do shell script recorderBin & " --output " & quoted form of tempAudioFile & " --pid-file " & quoted form of pidFile & " --include-mic > /tmp/meeting-recorder-cli.log 2>&1 &"
        end if
        delay 1

        -- Verify recorder started successfully
        set recorderPid to do shell script "cat " & quoted form of pidFile & " 2>/dev/null || echo ''"
        if recorderPid is "" then
            error "Recorder PID file empty -- process failed to start"
        end if
        set isRunning to do shell script "kill -0 " & recorderPid & " 2>/dev/null && echo yes || echo no"
        if isRunning is "no" then
            set recorderError to do shell script "tail -5 /tmp/meeting-recorder-cli.log 2>/dev/null; tail -5 /tmp/ffmpeg-recording.log 2>/dev/null"
            error "Recorder failed to start: " & recorderError
        end if

        -- Log start time and save state for stop script
        set startTime to do shell script "date '+%Y-%m-%d %H:%M:%S'"
        set startHHMM to do shell script "date '+%H%M'"
        do shell script "echo 'Recording started (PID " & recorderPid & "): " & startTime & "' >> /tmp/meeting-recorder.log"

        -- Snapshot MeetingBar metadata for this recording session
        -- The live metadata file gets overwritten when the next meeting starts,
        -- so we freeze it here to preserve the identity of the meeting we're recording
        set metadataFile to "/tmp/meeting-recorder-metadata.json"
        set activeSession to "/tmp/meeting-recorder-active-session.json"
        try
            set metaExists to do shell script "[ -f " & quoted form of metadataFile & " ] && echo yes || echo no"
            if metaExists is "yes" then
                do shell script "cp " & quoted form of metadataFile & " " & quoted form of activeSession
                -- Use event start time (not system clock) so filename matches daily note links
                set eventHHMM to do shell script "python3 -c \"import json; print(json.load(open('" & activeSession & "'))['startTime'])\" 2>/dev/null || echo ''"
                if eventHHMM is not "" then
                    set startHHMM to eventHHMM
                    do shell script "echo 'Using event time " & eventHHMM & " (not system clock) for start time' >> /tmp/meeting-recorder.log"
                end if
            end if
        on error snapErr
            do shell script "echo 'Metadata snapshot error (non-fatal): " & snapErr & "' >> /tmp/meeting-recorder.log"
        end try

        do shell script "echo " & startHHMM & " > /tmp/meeting-recorder-start-time.txt"

        -- Signal meeting start to the persistent live transcript daemon.
        -- Writes a marker to the transcript file (sandbox-safe file append).
        -- If yap isn't running, signal-meeting-start.sh launches it via Terminal.app.
        try
            set meetingLabel to "Meeting"
            try
                set metaCheck to do shell script "[ -f " & quoted form of activeSession & " ] && echo yes || echo no"
                if metaCheck is "yes" then
                    set meetingLabel to do shell script "python3 -c \"import json; print(json.load(open('" & activeSession & "'))['title'])\""
                end if
            end try
            do shell script "${MEETING_RECORDER_DIR:-$HOME/Repos/personal/meeting-recorder}/scripts/signal-meeting-start.sh " & quoted form of meetingLabel & " >> /tmp/meeting-recorder.log 2>&1"
        on error liveErr
            do shell script "echo 'Live transcript signal error (non-fatal): " & liveErr & "' >> /tmp/meeting-recorder.log"
        end try

        -- Report to script dashboard
        try
            do shell script "source $HOME/Repos/personal/script-dashboard/lib/report.sh 2>/dev/null && report_start 'meeting-start' 'meeting' 'Recording: " & meetingLabel & "' && report_log 'Recording started (PID " & recorderPid & ")' && report_end 0 || true"
        end try

        display notification "Recording started" with title "Meeting Recorder" sound name "Ping"
        return "Recording started at " & startTime

    on error errMsg
        -- Clean up on failure
        try
            do shell script "rm -f " & quoted form of pidFile
        end try
        display notification "Failed: " & errMsg with title "Meeting Recorder Error"
        do shell script "echo 'Error: " & errMsg & "' >> /tmp/meeting-recorder.log"
        return "Error: " & errMsg
    end try
end run
