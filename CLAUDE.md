# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This project records and transcribes meetings, integrating with the Obsidian productivity system via morning-plan-processor and meeting-intelligence-processor agents.

**Current approach:** ffmpeg recording from "Meeting Recording Input" aggregate device, controlled via AppleScript entry points. Replaced QuickTime UI automation on 2026-04-09 after a popup menu timing failure. Next step: Swift CLI using Core Audio Taps (see Task Note: "Swift Meeting Recorder CLI").

## Common Commands

```bash
# Start a recording (via Terminal — usually triggered by MeetingBar/Raycast)
osascript scripts/quicktime-start-recording.applescript

# Stop recording and trigger transcription pipeline
osascript scripts/quicktime-stop-recording.applescript

# Run transcription manually on an existing audio file
scripts/transcribe-and-process.sh "/path/to/recording.m4a"

# Set up diarization venv (one-time)
scripts/setup-diarization.sh

# Run diarization manually on existing audio+transcript
scripts/.venv/bin/python scripts/diarize-transcript.py /path/to/audio.wav /path/to/transcript.txt /path/to/transcript.srt

# Check recording status
cat /tmp/meeting-recorder.pid 2>/dev/null && echo "Recording active" || echo "No active recording"

# View logs
tail -f /tmp/meeting-recorder.log

# Verify audio device exists
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i meeting

# Check audio file has content (not silence)
ffmpeg -i file.m4a -af volumedetect -f null -

# Build the Swift CLI (Core Audio Taps recorder)
cd MeetingRecorder && swift build -c release

# Test the Swift CLI (records system audio, Ctrl+C to stop)
MeetingRecorder/.build/release/MeetingRecorder --output /tmp/test.m4a --pid-file /tmp/test.pid

# Enroll speakers into the voice embedding library
scripts/.venv/bin/python scripts/enroll-speakers.py --list
scripts/.venv/bin/python scripts/enroll-speakers.py \
  --diarization-json "path/to/recording.diarization.json" \
  --assign "Speaker A=Will Fanguy" "Speaker B=Judith Wilding"

# Run all tests
scripts/.venv/bin/python scripts/test_diarize.py && \
  scripts/.venv/bin/python scripts/test_speaker_library.py && \
  scripts/.venv/bin/python scripts/test_identification_integration.py
```

## Configuration

- **`config.sh`** — Local config (gitignored). Currently sourced by the diarization pipeline for `HF_TOKEN`. Other scripts have paths hardcoded inline (see `config.example.sh` for reference).
- **`config.example.sh`** — Reference for all configurable values, checked into git.
- Whisper models live at `~/.local/share/whisper-models/`
- All runtime state files go in `/tmp/meeting-recorder-*.{pid,json,txt}`

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
   - Starts ffmpeg recording from "Meeting Recording Input" aggregate device
   - Saves PID for stop script
   - Snapshots MeetingBar metadata (meeting name, event time)
   - No UI automation — fully headless

3. **Meeting end:** User triggers `quicktime-stop-recording.applescript`:
   - Kills ffmpeg (SIGINT for graceful shutdown)
   - Resolves meeting name from metadata/daily note
   - Moves temp file to `~/Meeting Transcriptions/YYYY-MM-DD HHmm - Meeting Name.m4a`
   - Triggers `transcribe-and-process.sh` in background

4. **Post-processing:** `transcribe-and-process.sh`:
   - Converts m4a to wav
   - Transcribes with Whisper (large-v3-q5_0, with VAD and context prompt)
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

## total-recall Sync

After creating a meeting note, `transcribe-and-process.sh` automatically syncs it to the Unraid `total-recall` share via the Mac mini.

**Flow:**
1. Meeting intelligence processor runs and writes AI summary to the note
2. Work machine rsyncs the enriched note to Mac mini vault (bypasses Obsidian Sync delay)
3. Mac mini runs `~/Repos/total-recall/sync/sync-meeting-note.sh` to push to Unraid

The sync happens inside the meeting-intelligence background block after `SUCCESS=true` — Unraid always gets the fully enriched note, not the bare transcript.

**Why via Mac mini:** The work machine can't reach Unraid directly. The Mac mini has the SSH tunnel (`com.totalrecall.bee-tunnel.plist`).

**Remote path escaping:** The rsync destination uses `wills-mac-mini:Vaults/HigherJump/4.\ Resources/Meeting\ Notes/` — spaces must be escaped or rsync throws "server receiver mode requires two argument".

**Logs:** All sync output goes to `/tmp/meeting-recorder.log` under `[total-recall]` prefix.

## Related Components

- **morning-plan-processor** (`~/.claude/agents/morning-plan-processor.md`): Creates daily note with meeting links
- **meeting-intelligence-processor** (`~/.claude/agents/meeting-intelligence-processor.md`): Adds AI summary to meeting notes
- **total-recall sync** (`~/Repos/total-recall/sync/sync-meeting-note.sh` on Mac mini): Pushes notes to Unraid
- **Productivity config** (`~/Repos/personal/productivity/config/config.json`): Central config including `meetings` section
- **Meeting naming spec** (`~/Repos/personal/productivity/config/meeting-naming-spec.md`): Full specification

## Scripts

### quicktime-start-recording.applescript

- Starts ffmpeg recording from "Meeting Recording Input" aggregate device to `/tmp/meeting-recording-temp.m4a`
- Saves ffmpeg PID to `/tmp/meeting-recorder.pid`
- Snapshots MeetingBar metadata for meeting name resolution
- Starts live transcript via Terminal.app (yap)
- Can be triggered from Raycast or MeetingBar
- **Note:** Filename retained for MeetingBar compatibility despite no longer using QuickTime

### quicktime-stop-recording.applescript

- Kills ffmpeg gracefully (SIGINT) and waits for file finalization
- Resolves meeting name from metadata snapshot, live metadata, or daily note (in priority order)
- Moves recording to `~/Meeting Transcriptions/` with proper filename
- Triggers transcribe-and-process.sh in background

### transcribe-and-process.sh

- Converts m4a to wav (16kHz mono for Whisper)
- Runs whisper-cli for transcription
- Runs hallucination detection + retranscription if needed
- **Applies domain corrections** (see below)
- Creates meeting note with frontmatter and transcript
- Runs meeting-intelligence-processor in background

### apply-domain-corrections.py

Post-transcription correction of known domain-specific errors. Runs automatically
after Whisper (or any future transcription engine) finishes.

- **Dictionary**: `scripts/domain-corrections.json` — organized by category (companies, products, domain terms, people)
- **Behavior**: Case-insensitive whole-word matching, processes both .txt and .srt files
- **Logging**: All corrections logged to `/tmp/meeting-recorder.log`
- **Adding corrections**: Edit the JSON dictionary — no code changes needed. Add entries as `"wrong": "right"` under the appropriate category.

Common corrections include: "glass door" → "Glassdoor", "supermatters" → "SuperMatch", "co-complete" → "code complete", name spelling fixes for team members.

### Live Transcript (yap)

Real-time transcription running alongside the recording for catch-up during meetings.

- **Start**: `scripts/start-live-transcript.sh` — launched automatically by the start-recording AppleScript via Terminal.app (needs Terminal's TCC permissions for microphone)
- **Stop**: `scripts/stop-live-transcript.sh` — called by the stop-recording AppleScript
- **Viewer**: `scripts/live-transcript-viewer.py` — Python HTTP server on `localhost:8234` that renders live SRT output in browser
- **Engine**: `yap` (Apple Speech.framework, installed via Homebrew) in `--srt` mode
- **PTY trick**: yap is wrapped in `script -q` to give it a PTY — without this, yap block-buffers and text only appears every ~30 seconds
- **PID files**: `/tmp/meeting-recorder-live-pid.txt` (yap), `/tmp/meeting-recorder-live-viewer-pid.txt` (viewer)

### Speaker Diarization (pyannote-audio)

After domain corrections, the pipeline optionally runs speaker diarization to label who said what.

- **Script**: `scripts/diarize-transcript.py` (runs in `scripts/.venv/` with Python 3.12)
- **Model**: pyannote/speaker-diarization-3.1 (requires HuggingFace token in config.sh)
- **Setup**: Run `scripts/setup-diarization.sh` once to create the venv and install dependencies
- **Fallback**: If venv, token, or model is missing, diarization is silently skipped — unlabeled transcript continues through pipeline
- **Output**: Rewrites .txt with speaker labels (`**Speaker A:** text`), updates .srt with `[Speaker A]` prefixes, writes `.diarization.json` sidecar
- **Speaker labels**: Generic (Speaker A/B/C) — the meeting-intelligence-processor can infer real names from conversational context
- **Performance**: ~3-8 minutes on CPU, faster with MPS GPU acceleration (Apple Silicon)
- **Hint**: If MeetingBar provides `attendee_count`, it's passed as `--num-speakers` to improve accuracy

## Archived Scripts

Old ffmpeg/BlackHole shell scripts (pre-QuickTime era) are in `scripts/archive/`. These were abandoned due to audio device routing issues (often captured silence). The current approach returns to ffmpeg but keeps the AppleScript wrapper for MeetingBar integration and metadata handling — the old shell scripts did everything in bash which was less maintainable.

## Recording History

1. **ffmpeg + BlackHole shell scripts** (original) — unreliable, often captured silence
2. **QuickTime + AppleScript UI automation** — more reliable but fragile System Events popup menu timing
3. **ffmpeg + AppleScript wrapper** (2026-04-09) — headless ffmpeg, no UI automation
4. **Swift CLI with Core Audio Taps** (built 2026-04-09, integration pending) — eliminates BlackHole dependency entirely. Binary at `MeetingRecorder/.build/release/MeetingRecorder`. Build: `cd MeetingRecorder && swift build -c release`

## Project Tracking & Roadmap

Obsidian project index: `~/Vaults/HigherJump/2. Projects/Meeting Recorder.md`

Active task notes (query `projects` field for `[[Meeting Recorder]]` in `4. Resources/Work Log/Tasks/`):

- **Swift Meeting Recorder CLI** (built, integration pending, P3) — Native Core Audio Taps CLI at `MeetingRecorder/`. System audio capture works. Remaining: wire into AppleScript entry points (replace ffmpeg command), add microphone capture (Phase 3b), install to PATH.
- **Meeting Transcript Diarization** (done, P3) — Speaker diarization via pyannote-audio with 256-dim embedding extraction. Integrated into pipeline. Speaker identification via embedding library auto-assigns real names.
- **Speaker Embedding Library** (done, P4) — `scripts/speaker_library.py` + `scripts/enroll-speakers.py`. Cosine similarity matching, running-average enrollment, auto-enrollment of identified speakers. Library at `~/.config/meeting-recorder/speaker-embeddings.json`.

Related skills (in `~/.claude/skills/`): `quicktime-applescript-recording`, `ffmpeg-aggregate-device-silent-downmix`, `pyannote-audio-4x-setup`, `blackhole-silent-loopback-failure`, `meeting-transcription-debugging`, `aggregate-device-choppy-audio`, `yap-vs-whisper-transcription`

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

### ffmpeg recording issues

- **No recording starts:** Check ffmpeg log at `/tmp/ffmpeg-recording.log`. Verify "Meeting Recording Input" device exists: `ffmpeg -f avfoundation -list_devices true -i ""`
- **Captured silence:** Check BlackHole routing. System audio output must go through a Multi-Output Device that includes BlackHole 2ch. Verify in Audio MIDI Setup.
- **Recording already active:** Script checks PID file at `/tmp/meeting-recorder.pid`
- **File too small warning:** Stop script warns if recording is <10KB — likely captured silence
