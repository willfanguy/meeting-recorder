# Post-Reboot Setup Checklist

After rebooting (required for BlackHole), complete these steps to finish setup.

## 1. Verify BlackHole installed

```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i blackhole
```

You should see "BlackHole 2ch" in the list. If not, reinstall: `brew reinstall blackhole-2ch` and reboot again.

## 2. Create audio devices in Audio MIDI Setup

Open **Audio MIDI Setup** (Cmd+Space, type "Audio MIDI Setup").

### Multi-Output Device ("Meeting Output")
1. Click **+** at bottom left -> "Create Multi-Output Device"
2. Check your speakers/headphones (e.g. "USB Advanced Audio Device")
3. Check "BlackHole 2ch"
4. Right-click -> Rename to "Meeting Output"
5. Set **Clock Source** to your speakers/headphones (the hardware device, NOT BlackHole)
6. Leave **Drift Correction OFF** for all sub-devices

### Aggregate Device ("Meeting Recording Input")
1. Click **+** -> "Create Aggregate Device"
2. Check **one** microphone — your USB mic if at a desk, or MacBook Air Microphone if mobile
3. Check "BlackHole 2ch"
4. Right-click -> Rename to **"Meeting Recording Input"** (exact name matters!)
5. Clock Source can remain on BlackHole (default) — this works fine
6. Leave **Drift Correction OFF** for all sub-devices
7. Uncheck any "Offline Device" entries that appear (stale references to disconnected devices)
8. Only include the devices you need — extra sub-devices (e.g. both built-in and USB mic) cause instability

> **Key settings that matter:**
> - **Meeting Output clock source** should be your hardware speakers (USB Advanced Audio
>   Device), NOT BlackHole. This ensures stable output timing.
> - **Meeting Recording Input clock source** can stay on BlackHole (the default). This
>   works fine in practice.
> - **Drift Correction must be OFF** on both devices. On macOS Sequoia (and possibly
>   earlier), enabling drift correction for BlackHole causes the audio stream to silently
>   drop after ~20 minutes. Recordings appear to continue but capture silence.
> - **Minimize sub-devices.** Only include one mic + BlackHole in the aggregate. Extra
>   sub-devices (both built-in and USB mic, offline devices) cause instability.

## 3. Configure meeting app audio

Set your meeting app's speaker to "Meeting Output":
- **Zoom**: Settings -> Audio -> Speaker
- **Meet**: Set system audio output to "Meeting Output" before joining
- **Teams**: Settings -> Devices -> Speaker

## 4. Grant macOS permissions

The scripts use AppleScript UI automation. Grant these in System Settings -> Privacy & Security:

- **Microphone**: QuickTime Player
- **Accessibility**: The app that triggers recording (MeetingBar, Raycast, or Terminal)

macOS will prompt on first use. If recording fails silently, check here first.

## 5. Configure MeetingBar (if using)

Open MeetingBar preferences -> Advanced:
- Set **event start script** to:
  ```
  ~/path/to/meeting-recorder/scripts/eventStartScript.applescript
  ```

This handles saving meeting metadata and starting the recording.

## 6. Customize paths

Edit hardcoded paths in these files (see README for details):
- `scripts/quicktime-stop-recording.applescript` (lines 6-8) — recording and notes directories
- `scripts/transcribe-and-process.sh` (lines 17-21) — Whisper models and notes directory
- `scripts/eventStartScript.applescript` (line 22) — path to metadata helper script

## 7. Test the setup

### Quick test via command line:
```bash
cd ~/path/to/meeting-recorder

# Start recording
osascript scripts/quicktime-start-recording.applescript

# Speak into your mic and play some audio for a few seconds

# Stop and transcribe
osascript scripts/quicktime-stop-recording.applescript
```

### Check output:
- Audio file should appear in your recordings directory
- After transcription completes, a `.md` file should appear in your meeting notes directory
- Check the log for errors: `cat /tmp/meeting-recorder.log`

### Verify audio capture:
```bash
# Check the recording has actual audio content
ffmpeg -i YOUR_RECORDING.m4a -af volumedetect -f null - 2>&1 | grep max_volume
```

If max_volume is below -40dB, audio routing isn't working — double-check your meeting app's speaker is set to "Meeting Output".

## Troubleshooting

### BlackHole not showing up
Reinstall and reboot: `brew reinstall blackhole-2ch`

### "Meeting Recording Input" not found
The Aggregate Device name must match exactly. Check available devices:
```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1
```

### Remote participants' audio sounds choppy/glitchy
- Make sure **Drift Correction is OFF** for all sub-devices (it's broken on recent macOS)
- Remove any "Offline Device" (red) entries from the aggregate — stale sub-devices cause instability
- Only include one mic in the aggregate — extra sub-devices compound timing issues
- Check that Meeting Output clock source is your hardware speakers, not BlackHole

### Recording drops audio after ~20 minutes (silent tail)
- Almost certainly **Drift Correction is enabled** — disable it for all sub-devices in both devices
- Verify with: recording appears to continue but `ffmpeg -af silencedetect` shows long silence at end

### Recording captures only mic (no meeting audio)
- Your meeting app's speaker must be "Meeting Output" (not regular speakers)
- BlackHole must be checked in the Aggregate Device

### Permission denied / recording fails silently
Check System Settings -> Privacy & Security -> Accessibility for your triggering app.
