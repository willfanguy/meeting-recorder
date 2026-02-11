# Meeting Recorder - Claude Code Context

## Overview

This project records and transcribes meetings, integrating with the Obsidian productivity system via morning-plan-processor and meeting-intelligence-processor agents.

**Current approach:** QuickTime audio recording via AppleScript (more reliable than ffmpeg/BlackHole).

## File Naming Convention

**Standard format:** `YYYY-MM-DD HHmm - Sanitized Title`

Examples:
- `2026-02-02 1100 - AIF Stand up.m4a`
- `2026-02-02 1100 - AIF Stand up.md`

**Critical:** The timestamp comes from the **calendar event's start time**, NOT the current time when recording starts. This ensures filenames match the links created by morning-plan-processor.

## Integration with Obsidian Productivity System

### Workflow

1. **Morning (8:30am):** `morning-plan-processor` agent runs, creates daily note with meeting links:
   ```markdown
   - [ ] 11:00 - 11:30 [[4. Resources/Meeting Notes/2026-02-02 1100 - AIF Stand up|AIF Stand up]]
   ```

2. **Meeting start:** User triggers `quicktime-start-recording.applescript` (via Raycast or MeetingBar):
   - Opens QuickTime Player
   - Starts new audio recording
   - Minimizes window

3. **Meeting end:** User triggers `quicktime-stop-recording.applescript`:
   - Stops QuickTime recording
   - Reads daily note to find meeting name for current hour
   - Saves as `YYYY-MM-DD HHmm - Meeting Name.m4a`
   - Triggers `transcribe-and-process.sh` in background

4. **Post-processing:** `transcribe-and-process.sh`:
   - Converts m4a to wav
   - Transcribes with Whisper
   - Creates meeting note with frontmatter
   - Runs `meeting-intelligence-processor` for AI summary

5. **Result:** The Obsidian link from step 1 resolves to the meeting note with transcript and AI summary.

### Why Event Start Time Matters

If user joins at 10:58 for an 11:00 meeting:
- ❌ Wrong: `2026-02-02 1058 - ...` (current time)
- ✅ Correct: `2026-02-02 1100 - ...` (event time)

Using current time would break the link created by morning-plan-processor.

## File Locations

| Type | Path |
|------|------|
| Audio recordings | `~/Meeting Transcriptions/` |
| Processed recordings | `~/Meeting Transcriptions/processed/` |
| Meeting notes | `~/Vaults/HigherJump/4. Resources/Meeting Notes/` |
| Daily notes | `~/Vaults/HigherJump/4. Resources/Daily Notes/` |

## Meeting Note Frontmatter

```yaml
---
title: "Meeting Title"
date: 2026-02-02
time: "11:00"
event_id: "quicktime-20260202110000"
status: transcribed
recording: "/Users/will/Meeting Transcriptions/2026-02-02 1100 - AIF Stand up.m4a"
attendees: []
tags:
  - meeting
---
```

### Status Values

- `created` - File exists, no content
- `recording` - Recording in progress
- `transcribed` - Transcript added
- `summarized` - AI summary added (by meeting-intelligence-processor)
- `reviewed` - Human-reviewed

## Title Sanitization

Applied to meeting titles for filenames:
1. Remove control characters
2. Replace `:`, `/`, `\`, `|`, `*`, `?`, `<`, `>` with `-`
3. Collapse multiple spaces/dashes
4. Trim leading/trailing spaces and dashes

## Zoom Team Chat Integration

When Will saves the team chat from a Zoom meeting, it's stored at:
`~/Documents/Zoom/YYYY-MM-DD HH.MM.SS Meeting Title/meeting_saved_new_chat.txt`

The `transcribe-and-process.sh` script automatically searches this directory for a chat matching the meeting's date and time. If found, it's appended to the meeting note as a `## Team Chat (Zoom)` section.

**Matching logic:** Date + HH.MM from the Zoom folder against our HHMM time format. Falls back to hour-only matching if exact minute doesn't match.

The meeting-intelligence-processor also knows to check for Zoom chat — both in the meeting note (primary) and by searching the Zoom directory directly (fallback for notes not created by the recorder pipeline).

## Related Components

- **morning-plan-processor** (`~/.claude/agents/morning-plan-processor.md`): Creates daily note with meeting links
- **meeting-intelligence-processor** (`~/.claude/agents/meeting-intelligence-processor.md`): Adds AI summary to meeting notes
- **Productivity config** (`~/Repos/personal/productivity/config/config.json`): Central config including `meetings` section
- **Meeting naming spec** (`~/Repos/personal/productivity/config/meeting-naming-spec.md`): Full specification

## Scripts

### quicktime-start-recording.applescript

- Opens QuickTime Player
- Creates new audio recording
- Starts recording
- Minimizes window to reduce distraction
- Can be triggered from Raycast or MeetingBar

### quicktime-stop-recording.applescript

- Stops QuickTime recording
- Reads daily note to find meeting name for current hour
- Exports as m4a with proper filename
- Triggers transcribe-and-process.sh in background

### transcribe-and-process.sh

- Converts m4a to wav (16kHz mono for Whisper)
- Runs whisper-cli for transcription
- Creates meeting note with frontmatter and transcript
- Runs meeting-intelligence-processor in background

## Archived Scripts

Old ffmpeg/BlackHole approach scripts are in `scripts/archive/`. These were unreliable due to audio device routing issues (often captured silence instead of meeting audio).

## Troubleshooting

### Meeting note link doesn't resolve

Check that:
1. Filename uses event start time, not current time
2. Morning-plan-processor ran and created the link
3. Filename sanitization matches between morning-plan and recording scripts

### Transcript shows "You You You You..."

This is Whisper hallucinating on silence. Check:
1. Audio file has actual content: `ffmpeg -i file.m4a -af volumedetect -f null -`
2. QuickTime was recording from correct input device
3. Meeting audio was actually playing through speakers

See `meeting-transcription-debugging` skill for detailed diagnostics.

### QuickTime recording issues

- **No recording starts:** Check QuickTime has microphone permissions in System Settings
- **Wrong audio source:** Set default input in System Settings > Sound before starting
- **Recording already active:** Script checks for existing recordings and notifies
