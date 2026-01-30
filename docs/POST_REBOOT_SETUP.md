# Post-Reboot Setup Checklist

After rebooting, complete these steps to finish the meeting recorder setup.

## 1. Verify BlackHole Installed

Open Terminal and run:
```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i blackhole
```

You should see "BlackHole 2ch" in the list. If not, reinstall:
```bash
brew reinstall blackhole-2ch
```

## 2. Create Audio Devices in Audio MIDI Setup

Open **Audio MIDI Setup** (Cmd+Space, type "Audio MIDI Setup")

### Create Multi-Output Device
1. Click **+** at bottom left → "Create Multi-Output Device"
2. Check your speakers/headphones
3. Check "BlackHole 2ch"
4. Right-click → Rename to "Meeting Output"
5. Check "Drift Correction" for BlackHole

### Create Aggregate Device
1. Click **+** → "Create Aggregate Device"
2. Check your microphone (probably "USB Advanced Audio Device" or "MacBook Air Microphone")
3. Check "BlackHole 2ch"
4. Right-click → Rename to **"Meeting Recording Input"** (exact name matters!)
5. Check "Drift Correction" for BlackHole

## 3. Configure Zoom Audio Output

In Zoom settings → Audio → Speaker, select "Meeting Output"

(Do this for any other meeting apps you use)

## 4. Configure MeetingBar

Open MeetingBar preferences:
- Find the "Run AppleScript" options for join/leave
- **When joining**: `~/Repos/personal/meeting-recorder/scripts/MeetingBar-Start.applescript`
- **When leaving**: `~/Repos/personal/meeting-recorder/scripts/MeetingBar-Stop.applescript`

## 5. Test the Setup

### Quick audio test:
```bash
cd ~/Repos/personal/meeting-recorder

# Start recording (will capture from your mic + system audio)
./scripts/start-recording.sh

# Speak into mic, play some audio/music for a few seconds

# Stop and transcribe
./scripts/stop-recording.sh
```

Check the output files:
- Audio: `~/Documents/Meeting Recordings/`
- Transcript + Note: `~/Vaults/HigherJump/4. Resources/Meeting Notes/`

### Verify transcript quality
Open the .txt file and make sure it captured both your voice and the system audio.

## 6. (Optional) Initialize Git Repo

```bash
cd ~/Repos/personal/meeting-recorder
git init
git add .
git commit -m "Initial commit: meeting recorder with auto-transcription"
```

## Troubleshooting

### Can't find BlackHole after reboot
Try reinstalling: `brew reinstall blackhole-2ch`

### ffmpeg can't find "Meeting Recording Input"
The name must match exactly. Check available devices:
```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "audio devices"
```

### Recording works but only captures mic (no system audio)
- Make sure Zoom's speaker is set to "Meeting Output" (not your regular speakers)
- Make sure BlackHole is checked in the Aggregate Device

### Transcription is empty or garbage
- Check the audio file plays correctly in QuickTime
- Try a larger Whisper model (small.en) for better accuracy
