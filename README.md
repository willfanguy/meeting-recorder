# Meeting Recorder

Automatically record and transcribe meetings on macOS using QuickTime and local Whisper transcription. Integrates with MeetingBar for hands-free recording — starts when you join a meeting, transcribes when you leave.

## Features

- **Automatic recording** via QuickTime Player, triggered by MeetingBar or Raycast
- **Local transcription** using whisper.cpp — no cloud services, fully private
- **Intelligent model selection** — uses the large model for important meetings, medium for standups/syncs
- **Hallucination detection** — automatically detects and retranscribes Whisper context-loop artifacts
- **Calendar integration** — names recordings from your calendar event, not the system clock
- **Zoom chat capture** — appends saved Zoom team chat to the meeting note
- **Markdown output** — transcripts saved as markdown with YAML frontmatter, ready for Obsidian
- **Meeting intelligence** (optional) — runs a Claude agent to generate AI summaries after transcription

## Requirements

- macOS (tested on Sonoma/Sequoia)
- [Homebrew](https://brew.sh)
- [MeetingBar](https://meetingbar.app) (optional, for automatic start/stop)
- [Raycast](https://raycast.com) (optional, for manual start/stop via launcher)

## Installation

```bash
git clone https://github.com/willfanguy/meeting-recorder.git
cd meeting-recorder
./install.sh
```

The install script will:
1. Install ffmpeg (audio format conversion)
2. Install BlackHole 2ch (virtual audio device for capturing system audio)
3. Install whisper-cpp (local transcription engine)
4. Download Whisper models
5. Create your config file

**After installation, reboot your Mac** for BlackHole to load.

### Additional Whisper models

The transcription script uses larger quantized models for better accuracy. Download them after install:

```bash
MODEL_DIR="$HOME/.local/share/whisper-models"

# Large model (recommended — used by default for most meetings)
curl -L -o "$MODEL_DIR/ggml-large-v3-q5_0.bin" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"

# Medium model (used for routine meetings like standups/syncs)
curl -L -o "$MODEL_DIR/ggml-medium-q5_0.bin" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"

# VAD model (optional — voice activity detection for silence filtering)
curl -L -o "$MODEL_DIR/ggml-silero-v6.2.0.bin" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-silero-v6.2.0.bin"
```

At minimum, you need either the large or medium model. The base model installed by `install.sh` is a fallback only.

## Audio Setup

You need to create two virtual audio devices in **Audio MIDI Setup** (in /Applications/Utilities/). This lets QuickTime capture both your microphone and meeting audio.

### 1. Multi-Output Device (for hearing + capturing audio)

This sends meeting audio to both your speakers AND BlackHole for recording.

1. Open Audio MIDI Setup
2. Click **+** at bottom left -> "Create Multi-Output Device"
3. Check your speakers/headphones AND "BlackHole 2ch"
4. Right-click -> Rename to "Meeting Output"
5. Enable "Drift Correction" for BlackHole

### 2. Aggregate Device (for recording mic + system audio)

This combines your microphone with BlackHole so you capture both sides of the conversation.

1. Click **+** -> "Create Aggregate Device"
2. Check your microphone AND "BlackHole 2ch"
3. Right-click -> Rename to **"Meeting Recording Input"** (exact name matters — the recording script selects this device)
4. Enable "Drift Correction" for BlackHole

### 3. Configure your meeting app

Set your meeting app's **speaker output** to "Meeting Output" (the Multi-Output Device). This ensures audio goes to both your ears and BlackHole for capture.

- **Zoom**: Settings -> Audio -> Speaker -> "Meeting Output"
- **Google Meet**: Chrome's audio output follows system default, so set "Meeting Output" as system output before joining
- **Teams**: Settings -> Devices -> Speaker -> "Meeting Output"

## macOS Permissions

The recording scripts use AppleScript UI automation. You'll need to grant:

1. **Microphone access** for QuickTime Player (System Settings -> Privacy & Security -> Microphone)
2. **Accessibility access** for the app triggering the scripts (System Settings -> Privacy & Security -> Accessibility):
   - If using MeetingBar: add MeetingBar
   - If using Raycast: add Raycast
   - If running from Terminal: add Terminal

macOS will prompt you the first time. If recording fails silently, check these permissions.

## Customization

Paths are currently hardcoded in the scripts. Before first use, update these files with your own paths:

- **`scripts/quicktime-stop-recording.applescript`** (lines 6-8):
  - `recordingsFolder` — where audio files are saved
  - `tempFolder` — QuickTime sandbox export path (~/Movies/ works for most setups)
  - `dailyNotesFolder` — your Obsidian daily notes folder (used for meeting name lookup)

- **`scripts/transcribe-and-process.sh`** (lines 17-21):
  - `WHISPER_MODEL_LARGE` / `WHISPER_MODEL_MEDIUM` / `WHISPER_VAD_MODEL` — Whisper model paths
  - `MEETING_NOTES_DIR` — where meeting note markdown files are created

- **`scripts/eventStartScript.applescript`** (line 22):
  - Path to `save-meeting-metadata.py` (update if you cloned to a different location)

See `config.example.sh` for a reference of all configurable values.

## Usage

### With MeetingBar (recommended)

MeetingBar triggers recording automatically when you join/leave calendar events.

**Setup:**

1. Open MeetingBar preferences
2. Go to the **Advanced** tab
3. Under "Run AppleScript", set the **event start script** to:
   ```
   ~/path/to/meeting-recorder/scripts/eventStartScript.applescript
   ```

This script handles both saving meeting metadata and starting QuickTime recording.

To stop recording, use Raycast or run the stop script manually (see below). MeetingBar's "leave" event is unreliable for triggering scripts.

### Manual (via Raycast or command line)

**Raycast:** Import the scripts from the `raycast/` folder into Raycast. Then use:
- "Start Meeting Recording" — opens QuickTime and starts recording
- "Stop Meeting Recording" — stops recording and triggers transcription

**Command line:**
```bash
# Start recording
osascript scripts/quicktime-start-recording.applescript

# Stop recording and transcribe
osascript scripts/quicktime-stop-recording.applescript
```

### Emergency stop

If something goes wrong with QuickTime:
```bash
# Force-close recording (saves what was captured)
./raycast/force-close-recording.sh
```

## Output

Each meeting creates:

1. **Audio file**: `~/YOUR_RECORDINGS_DIR/2025-03-04 1400 - Meeting Name.m4a`
2. **Transcript**: `~/YOUR_RECORDINGS_DIR/2025-03-04 1400 - Meeting Name.txt`
3. **SRT subtitles**: `~/YOUR_RECORDINGS_DIR/2025-03-04 1400 - Meeting Name.srt`
4. **Meeting note**: `~/YOUR_NOTES_DIR/2025-03-04 1400 - Meeting Name.md`

### File naming

Files use the format `YYYY-MM-DD HHmm - Title` where:
- Date/time comes from the **calendar event's start time** (not when recording started)
- Title is sanitized (special characters removed, truncated to 80 chars)

This convention ensures filenames match wiki-links created by other tools that reference calendar events.

### Meeting note format

```yaml
---
title: "Weekly Sync"
date: 2025-03-04
time: "14:00"
event_id: "quicktime-20250304140000"
status: transcribed
recording: "/path/to/recording.m4a"
srt: "/path/to/subtitles.srt"
attendees: []
tags:
  - meeting
---

## Transcript

[transcript content here]
```

## How Transcription Works

The `transcribe-and-process.sh` script handles post-recording processing:

1. **Format conversion** — converts QuickTime's m4a to 16kHz mono WAV for Whisper
2. **Model selection** — uses the medium model for routine meetings (standups, syncs, 1:1s) and the large model for everything else
3. **Long recording chunking** — splits recordings over 30 minutes into 15-minute chunks to prevent Whisper context-loop hallucinations
4. **Transcription** — runs whisper-cli with language and thread settings
5. **Hallucination detection** — checks for repeated lines (a sign of Whisper looping) and retranscribes affected segments with different parameters
6. **Meeting note creation** — generates markdown with YAML frontmatter
7. **Zoom chat capture** — searches for saved Zoom team chat files matching the meeting date/time and appends them
8. **Meeting intelligence** (optional) — spawns a Claude agent to add an AI summary

## Meeting Intelligence (Optional)

If you have [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed, the transcription script can automatically run a meeting intelligence agent that:
- Summarizes key decisions and action items
- Enriches the note with context from Slack, JIRA, and other sources

To enable: set `RUN_MEETING_INTELLIGENCE="true"` in the script (enabled by default). Requires:
- Claude Code CLI installed at a known path
- A `meeting-intelligence-processor` agent definition in `~/.claude/agents/`

To disable: set `RUN_MEETING_INTELLIGENCE="false"` or simply don't install Claude Code.

## Troubleshooting

### Recording doesn't start

- Check QuickTime has **Microphone** permission in System Settings
- Check the triggering app has **Accessibility** permission
- Look at the log: `cat /tmp/meeting-recorder.log`

### No audio captured / empty recording

- Verify "Meeting Recording Input" exists in Audio MIDI Setup with the exact name
- Make sure your meeting app's speaker is set to "Meeting Output"
- Check BlackHole is included in the Aggregate Device
- Test: play audio, then check `ffmpeg -f avfoundation -list_devices true -i "" 2>&1`

### Transcript shows "You You You You..." (hallucination)

This is Whisper hallucinating on silence or very quiet audio. The script detects this automatically and retranscribes, but if it persists:

1. Check the audio actually has speech: `ffmpeg -i file.m4a -af volumedetect -f null -`
2. If max_volume is below -40dB, the recording likely captured silence
3. Verify your meeting app's speaker output is "Meeting Output" (not your regular speakers)
4. Try the large model if you were using medium

### Transcription fails entirely

Check Whisper models exist:
```bash
ls -la ~/.local/share/whisper-models/
```

You need at least one of `ggml-large-v3-q5_0.bin` or `ggml-medium-q5_0.bin`. See [Additional Whisper models](#additional-whisper-models) above.

### QuickTime "already recording" notification

A previous recording wasn't stopped cleanly. Use the force-close script:
```bash
./raycast/force-close-recording.sh
```

Or quit QuickTime Player manually and start fresh.

## Project Structure

```
scripts/
  eventStartScript.applescript    # MeetingBar handler — saves metadata, starts recording
  quicktime-start-recording.applescript  # Opens QuickTime, starts audio recording
  quicktime-stop-recording.applescript   # Stops recording, saves file, triggers transcription
  transcribe-and-process.sh       # Converts, transcribes, detects hallucinations, creates notes
  save-meeting-metadata.py        # Saves MeetingBar event data as JSON
  archive/                        # Old ffmpeg/BlackHole scripts (deprecated)

raycast/
  start-meeting-recording.sh      # Raycast command — start recording
  stop-meeting-recording.sh       # Raycast command — stop recording
  force-close-recording.sh        # Raycast command — emergency stop
  extract-meeting-tasks.sh        # Raycast command — extract action items from recent meetings
```

## License

MIT
