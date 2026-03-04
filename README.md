# Meeting Recorder

Automatically record and transcribe meetings on macOS. Integrates with MeetingBar to start recording when you join a meeting and transcribe when you leave.

## Features

- **Automatic recording** triggered by MeetingBar (or manual start/stop)
- **Local transcription** using Whisper (OpenAI's speech recognition) - no cloud services, fully private
- **Calendar integration** - automatically names recordings based on your current calendar event
- **Markdown output** - transcripts saved as markdown files ready for Obsidian or other note apps

## Requirements

- macOS (tested on Sonoma/Sequoia)
- [Homebrew](https://brew.sh)
- [MeetingBar](https://meetingbar.app) (optional, for automatic start/stop)

## Installation

```bash
git clone https://github.com/willfanguy/meeting-recorder.git
cd meeting-recorder
./install.sh
```

The install script will:
1. Install ffmpeg (audio recording)
2. Install BlackHole (virtual audio device)
3. Install whisper-cpp (local transcription)
4. Download the Whisper base.en model
5. Create your config file

**After installation, reboot your Mac** for BlackHole to load.

## Audio Setup

You need to create two virtual audio devices in **Audio MIDI Setup** (in /Applications/Utilities/):

### 1. Multi-Output Device (for hearing + capturing audio)

This sends meeting audio to both your speakers AND BlackHole for recording.

1. Open Audio MIDI Setup
2. Click **+** → "Create Multi-Output Device"
3. Check your speakers/headphones AND "BlackHole 2ch"
4. Rename to "Meeting Output"
5. Enable "Drift Correction" for BlackHole

### 2. Aggregate Device (for recording mic + system audio)

This combines your microphone with BlackHole so you capture both sides of the conversation.

1. Click **+** → "Create Aggregate Device"
2. Check your microphone AND "BlackHole 2ch"
3. Rename to **"Meeting Recording Input"** (must match config.sh)
4. Enable "Drift Correction" for BlackHole

### 3. Configure Zoom/Meet

Set your meeting app's **speaker output** to "Meeting Output" (the Multi-Output Device). This ensures audio goes to both your ears and BlackHole.

## Configuration

Edit `config.sh` to customize:

```bash
# Where to save audio recordings
RECORDINGS_DIR="$HOME/YOUR_DIRECTORY_HERE"

# Where to save meeting notes/transcripts (Obsidian vault)
MEETING_NOTES_DIR="$HOME/YOUR_DIRECTORY_HERE"

# Whisper model (base.en is a good balance of speed/accuracy)
WHISPER_MODEL="$HOME/.local/share/whisper-models/ggml-base.en.bin"

# Must match your Aggregate Device name
AUDIO_DEVICE="Meeting Recording Input"

# Run Claude meeting intelligence processor after transcription (true/false)
RUN_MEETING_INTELLIGENCE="true"
```

## Usage

### With MeetingBar (recommended)

Configure MeetingBar preferences:
- **Run AppleScript when joining**: `scripts/MeetingBar-Start.applescript`
- **Run AppleScript when leaving**: `scripts/MeetingBar-Stop.applescript`

Recordings start automatically when you join and transcribe when you leave.

### Manual

```bash
# Start recording
./scripts/start-recording.sh

# Check status
./scripts/status.sh

# Stop and transcribe
./scripts/stop-recording.sh
```

## Output

Each meeting creates:

1. **Audio file**: `~/YOUR_DIRECTORY_HERE/2024-01-15 1400 - Meeting Name.wav`
2. **Transcript**: `~/YOUR_DIRECTORY_HERE/2024-01-15 1400 - Meeting Name.txt`
3. **Meeting note**: `~/YOUR_DIRECTORY_HERE/2024-01-15 1400 - Meeting Name.md`

### File Naming Convention

Files use the format `YYYY-MM-DD HHmm - Title` where:
- Date/time comes from the **calendar event's start time** (not when recording started)
- This ensures filenames match links created by morning-plan-processor

The meeting note includes YAML frontmatter for status tracking and the transcript.

## Whisper Models

The default `base.en` model is a good balance. For better accuracy (slower), download a larger model:

```bash
# Small model (~500MB, better accuracy)
curl -L -o ~/.local/share/whisper-models/ggml-small.en.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
```

Then update `WHISPER_MODEL` in config.sh.

Available models (English-only versions are faster):
- `tiny.en` - Fastest, lowest accuracy
- `base.en` - Good balance (default)
- `small.en` - Better accuracy
- `medium.en` - High accuracy
- `large` - Best accuracy, slowest

## Troubleshooting

### "Audio device not found"

Make sure you created the Aggregate Device in Audio MIDI Setup with the exact name in your config.sh (default: "Meeting Recording Input").

List available devices:
```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "audio devices"
```

### Recording file is empty/tiny

Check that:
1. BlackHole is installed and you've rebooted
2. Your meeting app's speaker is set to "Meeting Output"
3. The Aggregate Device includes both your mic and BlackHole

### Transcription fails

Check the model file exists:
```bash
ls -la ~/.local/share/whisper-models/
```

Re-download if needed:
```bash
curl -L -o ~/.local/share/whisper-models/ggml-base.en.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
```

## License

MIT
