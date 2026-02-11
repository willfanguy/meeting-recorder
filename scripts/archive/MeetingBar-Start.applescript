-- MeetingBar trigger: Start meeting recording
-- Configure MeetingBar to run this script when joining a meeting
--
-- To use: In MeetingBar preferences, set "Run AppleScript when joining"
-- to point to this file.

-- Update this path to match your installation
set scriptPath to (POSIX path of (path to home folder)) & "Repos/personal/meeting-recorder/scripts/start-recording.sh"

do shell script scriptPath & " > /tmp/meeting-recorder-start.log 2>&1 &"
