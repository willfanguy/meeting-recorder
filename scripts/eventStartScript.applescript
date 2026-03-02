-- MeetingBar event start: save metadata and trigger recording
-- Uses meetingStart handler required by MeetingBar (11 event parameters)

on meetingStart(eventId, title, allday, startDate, endDate, eventLocation, repeatingEvent, attendeeCount, meetingUrl, meetingService, meetingNotes)
	try
		-- Extract date/time components from AppleScript date object
		set y to year of startDate
		set m to month of startDate as integer
		set d to day of startDate
		set h to hours of startDate
		set mins to minutes of startDate

		-- Format as YYYY-MM-DD and HHMM
		set dateStr to do shell script "printf '%04d-%02d-%02d' " & y & " " & m & " " & d
		set timeStr to do shell script "printf '%02d%02d' " & h & " " & mins

		-- Save metadata via Python helper (handles JSON escaping safely)
		-- Use full Homebrew path: MeetingBar's sandbox resolves bare "python3"
		-- to /usr/bin/python3 (Xcode CLT stub) which fails if Xcode license
		-- isn't accepted. /opt/homebrew/bin/python3 works unconditionally.
		set homePath to POSIX path of (path to home folder)
		set pyScript to homePath & "Repos/personal/meeting-recorder/scripts/save-meeting-metadata.py"

		do shell script "/opt/homebrew/bin/python3 " & quoted form of pyScript & " " & quoted form of (eventId as text) & " " & quoted form of (title as text) & " " & quoted form of dateStr & " " & quoted form of timeStr & " " & quoted form of (eventLocation as text) & " " & (attendeeCount as text) & " " & quoted form of (meetingUrl as text) & " " & quoted form of (meetingService as text) & " " & quoted form of (meetingNotes as text)

		do shell script "echo 'MeetingBar event: " & dateStr & " " & timeStr & "' >> /tmp/meeting-recorder.log"

		-- Trigger recording
		set scriptPath to homePath & "Repos/personal/meeting-recorder/scripts/quicktime-start-recording.applescript"
		do shell script "osascript " & quoted form of scriptPath & " > /tmp/meeting-recorder-start.log 2>&1 &"

	on error errMsg
		do shell script "echo 'MeetingBar error: " & errMsg & "' >> /tmp/meeting-recorder.log"
	end try
end meetingStart
