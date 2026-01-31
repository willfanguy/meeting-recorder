# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Meeting Recorder is a macOS utility that automatically records and transcribes meetings. It integrates with MeetingBar to start/stop recording when joining/leaving meetings, uses ffmpeg to capture system audio + microphone, and processes the recording with Whisper (OpenAI's speech-to-text) for local transcription.

The tool outputs markdown meeting notes with transcripts, saved to an Obsidian vault for note-taking.

## Architecture

### Core Components

1. **Recording Engine** (`scripts/start-recording.sh`)
   - Uses ffmpeg to capture audio from an Aggregate Device (mic + BlackHole virtual audio device)
   - Records at 16kHz mono with 16-bit PCM (optimized for Whisper)
   - Implements audio channel mixing: BlackHole (system audio) on channels 0-1, microphone on channels 2-3
   - Boosts microphone signal 8x (with limiter) to balance against louder system audio
   - Manages state via `/tmp/meeting-recording-state` file to track active recording
   - Validates audio device availability with retry logic (devices can be slow to initialize)

2. **Recording Termination** (`scripts/stop-recording.sh`)
   - Gracefully stops ffmpeg recording process
   - **Smart meeting name lookup**: Queries the user's Obsidian daily note to find the actual meeting name by matching current time against scheduled events
   - Falls back to generic "Meeting" name if no calendar lookup succeeds
   - Handles filename conflicts by appending counter suffix
   - Invokes Whisper transcription via `whisper-cli`
   - Generates markdown note file with transcript and audio file link
   - Optionally launches Claude via `claude` CLI for meeting intelligence processing (background job)

3. **Status Monitor** (`scripts/status.sh`)
   - Checks if recording is currently active
   - Displays elapsed time and meeting details

4. **MeetingBar Integration** (`scripts/MeetingBar-Start.applescript`, `scripts/MeetingBar-Stop.applescript`)
   - AppleScript wrappers that trigger recording scripts when joining/leaving meetings
   - Paths must match your installation directory (currently hardcoded to `/Repos/personal/meeting-recorder/`)

### Configuration

- `config.sh` (created from `config.example.sh` during install)
- Key settings:
  - `RECORDINGS_DIR`: Where audio files are saved (default: `~/Documents/Meeting Recordings`)
  - `MEETING_NOTES_DIR`: Where markdown notes are saved (default: `~/Documents/Meeting Notes`)
  - `WHISPER_MODEL`: Path to Whisper model binary (default: `~/.local/share/whisper-models/ggml-base.en.bin`)
  - `AUDIO_DEVICE`: Name of Aggregate Device for audio capture (must match Audio MIDI Setup)
  - `RUN_MEETING_INTELLIGENCE`: Boolean to enable/disable AI post-processing

### Data Flow

1. User joins meeting (MeetingBar trigger)
2. `MeetingBar-Start.applescript` → `start-recording.sh`
3. ffmpeg starts recording from Aggregate Device to WAV file
4. State saved to `/tmp/meeting-recording-state`
5. User leaves meeting (MeetingBar trigger)
6. `MeetingBar-Stop.applescript` → `stop-recording.sh`
7. ffmpeg stops gracefully
8. Meeting name looked up from Obsidian daily note (time-based matching)
9. Audio file renamed with meeting name
10. `whisper-cli` transcribes WAV → TXT
11. Markdown note created with transcript and audio link
12. (Optional) Claude CLI invoked in background for meeting intelligence processing

## Development Setup

### Installation

```bash
./install.sh
```

This installs:
- ffmpeg (audio recording)
- BlackHole 2ch (virtual audio device for system audio capture)
- whisper-cpp (local speech-to-text)
- Whisper base.en model (147MB)

After install, **reboot Mac** for BlackHole kernel extension to load.

### Audio Setup (Post-Reboot)

See `docs/POST_REBOOT_SETUP.md` for detailed steps. Requires:
1. Multi-Output Device in Audio MIDI Setup (speakers + BlackHole) for hearing audio
2. Aggregate Device in Audio MIDI Setup (mic + BlackHole) named "Meeting Recording Input" for recording
3. MeetingBar preferences configured to run the AppleScripts

### Testing

```bash
# Create config from template (if not already done)
cp config.example.sh config.sh

# Manual recording test
./scripts/start-recording.sh
# ... speak into mic, play audio ...
./scripts/stop-recording.sh

# Check status anytime
./scripts/status.sh
```

## Common Tasks

### Debug Audio Device Issues

```bash
# List available audio devices
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "audio devices"
```

Device names must match exactly between Audio MIDI Setup and `config.sh`.

### Change Whisper Model

Download a different model from [huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) and update `WHISPER_MODEL` in `config.sh`:

```bash
# Example: download small.en model for better accuracy
curl -L -o ~/.local/share/whisper-models/ggml-small.en.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
```

### Disable AI Processing

Set `RUN_MEETING_INTELLIGENCE="false"` in `config.sh` to skip the background Claude processing step.

### Monitor Background AI Processing

```bash
tail -f /tmp/meeting-intelligence.log
```

## Key Implementation Details

### Audio Channel Mixing

The ffmpeg filter chain in `start-recording.sh:98-100` implements:
```
pan=mono|c0=0.5*c0+0.5*c1+8*c2+8*c3,alimiter=limit=0.9
```

- Channels 0-1: BlackHole (system audio from meeting) → average and use as base
- Channels 2-3: Microphone (your voice) → boost 8x to balance against louder system audio
- `alimiter`: Prevents clipping from the 8x boost
- Output: Single mono channel at 16kHz

This is critical for quality transcription where both sides of the conversation are audible.

### Meeting Name Lookup

The daily note parsing in `stop-recording.sh:87-109` uses regex to:
1. Find time ranges in format `HH:MM - HH:MM` in the daily note
2. Match current time within that range (with 15-minute buffer after end time)
3. Extract meeting name from Obsidian link format: `[[Meeting Notes/...|Display Name]]`

This avoids relying on calendar APIs and uses the source of truth (Obsidian vault).

### State Management

Active recording state is stored in `/tmp/meeting-recording-state` as shell variables:
- `FFMPEG_PID`: Process ID for force-killing if needed
- `AUDIO_FILE`: Full path to WAV file
- `MEETING_NAME`: Initial meeting name (may change during stop)
- `FILENAME`: Base filename (used to preserve timestamp during rename)
- `START_TIME`: Recording start time for duration calculation

## File Structure

```
meeting-recorder/
├── CLAUDE.md                          # This file
├── README.md                          # User-facing documentation
├── config.example.sh                  # Configuration template
├── install.sh                         # Dependency installer
├── scripts/
│   ├── start-recording.sh             # Begin recording (called by MeetingBar)
│   ├── stop-recording.sh              # Stop, transcribe, create note (called by MeetingBar)
│   ├── status.sh                      # Check active recording status
│   ├── MeetingBar-Start.applescript   # AppleScript trigger for join event
│   └── MeetingBar-Stop.applescript    # AppleScript trigger for leave event
├── docs/
│   └── POST_REBOOT_SETUP.md           # Post-reboot configuration checklist
└── raycast/                           # (Optional Raycast extension integration)
```

## Dependencies

- **ffmpeg**: Audio recording from macOS audio devices
- **BlackHole 2ch**: Virtual audio device for capturing system audio
- **whisper-cpp**: Local speech-to-text (compiled from OpenAI's Whisper)
- **Whisper model file**: Binary model (ggml format, ~147MB for base.en)
- **claude CLI**: Optional, for meeting intelligence post-processing
- **Bash 4+**: All scripts use bash
- **AppleScript/osascript**: For MeetingBar integration and notifications

## Notes for Future Development

- Paths to Obsidian vault are currently hardcoded in `stop-recording.sh:78` - consider making configurable
- AppleScript paths in MeetingBar trigger files are hardcoded and must be updated manually for different installations
- Audio channel boost factor (8x) is tuned for typical Zoom/Meet scenarios but may need adjustment for different hardware
- The 15-minute buffer after meeting end time in daily note lookup is hardcoded but could be configurable
- Meeting intelligence processing runs in background without error handling - failures are logged but don't block the main workflow
