# Meeting Recorder

Automatically record and transcribe meetings on macOS using ffmpeg and local Whisper transcription. Integrates with MeetingBar for hands-free recording — starts when you join a meeting, transcribes when you leave.

## Features

- **Automatic recording** via ffmpeg from a virtual audio device, triggered by MeetingBar or Raycast
- **Local transcription** using whisper.cpp — no cloud services, fully private
- **Speaker diarization** (optional) — labels who said what using pyannote + a personal speaker library
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
1. Install ffmpeg (audio recording and format conversion)
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

You need to create two virtual audio devices in **Audio MIDI Setup** (in /Applications/Utilities/) so that ffmpeg can capture both your microphone and meeting audio simultaneously.

### 1. Multi-Output Device (for hearing + capturing audio)

This sends meeting audio to both your speakers AND BlackHole for recording.

1. Open Audio MIDI Setup
2. Click **+** at bottom left → "Create Multi-Output Device"
3. Check your speakers/headphones AND "BlackHole 2ch"
4. Right-click → Rename to **"Meeting Output"**
5. Enable "Drift Correction" for BlackHole

### 2. Aggregate Device (for recording mic + system audio)

This combines your microphone with BlackHole so ffmpeg captures both sides of the conversation.

1. Click **+** → "Create Aggregate Device"
2. Check your microphone AND "BlackHole 2ch"
3. Right-click → Rename to **"Meeting Recording Input"** (exact name required)
4. Enable "Drift Correction" for BlackHole

### Per-app audio routing

Set your meeting app's **speaker output** to "Meeting Output" (the Multi-Output Device):

- **Zoom**: Settings → Audio → Speaker → "Meeting Output"
- **Google Meet**: Set "Meeting Output" as your system default before joining
- **Teams**: Settings → Devices → Speaker → "Meeting Output"

## macOS Permissions

You'll need to grant microphone and accessibility permissions:

1. **Microphone** for Terminal (or whichever app triggers the recording scripts) — System Settings → Privacy & Security → Microphone
2. **Accessibility** for the app triggering the scripts:
   - If using MeetingBar: add MeetingBar
   - If using Raycast: add Raycast
   - If running from Terminal: add Terminal

macOS will prompt you the first time. If recording fails silently, check these permissions.

## Customization

Scripts use `$HOME`-based paths with sensible defaults. To customize, you can either edit the variables at the top of each script or set environment variables:

- **`MEETING_RECORDER_DIR`** — override the repo location (default: `$HOME/Repos/meeting-recorder`)
- **`CLAUDE_BIN`** — path to your Claude Code binary (default: auto-detected via `which claude`)

Paths that need personalizing (edit directly in the scripts):
- `dailyNotesFolder` in `quicktime-stop-recording.applescript` — your Obsidian daily notes folder
- `MEETING_NOTES_DIR` in `transcribe-and-process.sh` — where meeting note markdown files are created

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

This script saves meeting metadata and starts ffmpeg recording.

To stop recording, use Raycast or run the stop script manually. MeetingBar's "leave" event is unreliable for triggering scripts.

### Manual (via Raycast or command line)

**Raycast:** Import the scripts from the `raycast/` folder. Then use:
- "Start Meeting Recording" — starts ffmpeg recording
- "Stop Meeting Recording" — stops recording and triggers transcription

**Command line:**
```bash
# Start recording
osascript scripts/quicktime-start-recording.applescript

# Stop recording and transcribe
osascript scripts/quicktime-stop-recording.applescript
```

### Emergency stop

If something goes wrong:
```bash
# Kill ffmpeg and save what was captured
./raycast/force-close-recording.sh
```

## Output

Each meeting creates:

1. **Audio file**: `~/Meeting Transcriptions/2025-03-04 1400 - Meeting Name.m4a`
2. **Transcript**: `~/Meeting Transcriptions/2025-03-04 1400 - Meeting Name.txt`
3. **SRT subtitles**: `~/Meeting Transcriptions/2025-03-04 1400 - Meeting Name.srt`
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
event_id: "recording-20250304140000"
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

1. **Format conversion** — converts the m4a recording to 16kHz mono WAV for Whisper
2. **Model selection** — uses the medium model for routine meetings (standups, syncs, 1:1s) and the large model for everything else
3. **Long recording chunking** — splits recordings over 30 minutes into 15-minute chunks to prevent Whisper context-loop hallucinations
4. **Transcription** — runs whisper-cli with language and thread settings
5. **Hallucination detection** — checks for repeated lines and retranscribes affected segments
6. **Domain corrections** — applies a customizable dictionary of corrections for proper nouns and technical terms (see `scripts/domain-corrections.json`)
7. **Speaker diarization** (optional) — labels speaker turns using pyannote; see [Diarization](#speaker-diarization-optional) below
8. **Meeting note creation** — generates markdown with YAML frontmatter
9. **Zoom chat capture** — searches for saved Zoom team chat files and appends them
10. **Meeting intelligence** (optional) — spawns a Claude agent to add an AI summary

## Speaker Diarization (Optional)

The pipeline can label who said what in transcripts using [pyannote](https://github.com/pyannote/pyannote-audio) and a personal speaker library.

### Setup

```bash
# Install diarization dependencies (one-time)
scripts/setup-diarization.sh

# Create config.sh with your HuggingFace token
echo 'HF_TOKEN=your-token-here' > config.sh
```

A HuggingFace account and access to `pyannote/speaker-diarization-3.1` is required.

### Enrolling speakers

After any meeting, enroll speakers from the diarization output:

```bash
scripts/.venv/bin/python scripts/enroll-speakers.py \
  --diarization-json "path/to/recording.diarization.json" \
  --assign "Speaker A=Alice Smith" "Speaker B=Bob Jones"
```

Once enrolled, future meetings automatically identify those voices.

### Fallback behavior

If the venv, HuggingFace token, or model is missing, diarization is silently skipped — the unlabeled transcript continues through the pipeline without errors.

## Meeting Intelligence (Optional)

If you have [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed, the transcription script can automatically run a meeting intelligence agent that:
- Summarizes key decisions and action items
- Enriches the note with context from Slack, JIRA, and other sources

To enable: set `RUN_MEETING_INTELLIGENCE="true"` in the script (enabled by default). Requires:
- Claude Code CLI installed and available on `$PATH` (or set `CLAUDE_BIN`)
- A `meeting-intelligence-processor` agent definition in `~/.claude/agents/`

To disable: set `RUN_MEETING_INTELLIGENCE="false"` or simply don't install Claude Code.

## Troubleshooting

### Recording doesn't start

- Check Terminal (or your launcher) has **Microphone** permission in System Settings
- Check the triggering app has **Accessibility** permission
- Look at the log: `cat /tmp/meeting-recorder.log`
- Verify the aggregate device exists: `ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i meeting`

### No audio captured / empty recording

- Verify "Meeting Recording Input" exists in Audio MIDI Setup with the **exact** name
- Make sure your meeting app's speaker is set to "Meeting Output"
- Check BlackHole is included in the Aggregate Device
- Test: `ffmpeg -f avfoundation -list_devices true -i "" 2>&1`

### Transcript shows "You You You You..." (hallucination)

This is Whisper hallucinating on silence or very quiet audio. The script detects this automatically and retranscribes, but if it persists:

1. Check the audio has speech: `ffmpeg -i file.m4a -af volumedetect -f null -`
2. If max_volume is below -40dB, the recording captured silence
3. Verify your meeting app's speaker output is "Meeting Output" (not your regular speakers)

### Transcription fails entirely

Check Whisper models exist:
```bash
ls -la ~/.local/share/whisper-models/
```

You need at least one of `ggml-large-v3-q5_0.bin` or `ggml-medium-q5_0.bin`. See [Additional Whisper models](#additional-whisper-models) above.

### Already recording error

A previous recording wasn't stopped cleanly. Use the force-close script:
```bash
./raycast/force-close-recording.sh
```

## Project Structure

```
scripts/
  eventStartScript.applescript         # MeetingBar handler — saves metadata, starts recording
  quicktime-start-recording.applescript # Starts ffmpeg recording from aggregate device
  quicktime-stop-recording.applescript  # Stops recording, saves file, triggers transcription
  transcribe-and-process.sh            # Full post-processing pipeline
  save-meeting-metadata.py             # Saves MeetingBar event data as JSON
  domain-corrections.json              # Customizable post-transcription corrections dictionary
  apply-domain-corrections.py          # Applies domain corrections to transcripts
  diarize-transcript.py                # Speaker diarization (pyannote)
  enroll-speakers.py                   # Enroll known speakers into the library
  speaker_library.py                   # Speaker identification from embeddings
  setup-diarization.sh                 # One-time diarization environment setup
  start-live-transcript.sh             # Start real-time transcript (yap)
  stop-live-transcript.sh              # Stop live transcript

raycast/
  start-meeting-recording.sh           # Raycast command — start recording
  stop-meeting-recording.sh            # Raycast command — stop recording
  force-close-recording.sh             # Raycast command — emergency stop
  open-live-transcript.sh              # Raycast command — open live transcript in Obsidian
  extract-meeting-tasks.sh             # Raycast command — extract action items via Claude

archive/                               # Old QuickTime UI automation scripts (deprecated)
```

## License

Apache 2.0 — see [LICENSE](LICENSE)
