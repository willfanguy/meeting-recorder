#!/bin/bash
# Meeting Recorder Configuration
# Copy this file to config.sh and customize for your setup

# Directory where audio recordings are saved
RECORDINGS_DIR="$HOME/Documents/Meeting Recordings"

# Directory where meeting notes/transcripts are saved (e.g., Obsidian vault)
MEETING_NOTES_DIR="$HOME/Documents/Meeting Notes"

# Whisper model path
# Available models: tiny, base, small, medium, large
# English-only models (faster): tiny.en, base.en, small.en, medium.en
WHISPER_MODEL="$HOME/.local/share/whisper-models/ggml-base.en.bin"

# Audio device name - must match the Aggregate Device you create in Audio MIDI Setup
# This device should combine your microphone + BlackHole for capturing both sides of the call
AUDIO_DEVICE="Meeting Recording Input"

# Run Claude meeting intelligence processor after transcription (true/false)
# Requires Claude Code CLI to be installed and configured
RUN_MEETING_INTELLIGENCE="true"
