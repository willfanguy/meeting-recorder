-- MeetingBar trigger: Stop meeting recording and transcribe
-- Configure MeetingBar to run this script when leaving a meeting
--
-- To use: In MeetingBar preferences, set "Run AppleScript when leaving"
-- to point to this file.

-- Update this path to match your installation
set scriptPath to (POSIX path of (path to home folder)) & "Repos/personal/meeting-recorder/scripts/stop-recording.sh"

do shell script scriptPath & " > /tmp/meeting-recorder-stop.log 2>&1"
