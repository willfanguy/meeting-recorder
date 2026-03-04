#!/bin/bash
# Meeting Recorder Configuration Reference
#
# NOTE: This file is NOT sourced by the current scripts. Paths are hardcoded
# directly in the scripts listed below. This file serves as a reference for
# what you need to customize when setting up on a new machine.
#
# Files to edit:
#   scripts/quicktime-stop-recording.applescript (lines 6-8)
#     - recordingsFolder, tempFolder, dailyNotesFolder
#
#   scripts/transcribe-and-process.sh (lines 17-21)
#     - WHISPER_MODEL_LARGE, WHISPER_MODEL_MEDIUM, WHISPER_VAD_MODEL
#     - MEETING_NOTES_DIR
#
#   scripts/eventStartScript.applescript (line 22)
#     - Path to save-meeting-metadata.py

# --- Reference values ---

# Directory where audio recordings (.m4a) are saved
RECORDINGS_DIR="$HOME/Meeting Transcriptions"

# Directory where meeting notes (.md) are created (e.g., Obsidian vault)
MEETING_NOTES_DIR="$HOME/Documents/Meeting Notes"

# Whisper models (download from https://huggingface.co/ggerganov/whisper.cpp)
# The transcription script uses large by default, medium for routine meetings
WHISPER_MODEL_LARGE="$HOME/.local/share/whisper-models/ggml-large-v3-q5_0.bin"
WHISPER_MODEL_MEDIUM="$HOME/.local/share/whisper-models/ggml-medium-q5_0.bin"
WHISPER_VAD_MODEL="$HOME/.local/share/whisper-models/ggml-silero-v6.2.0.bin"

# Audio device name - must match the Aggregate Device created in Audio MIDI Setup
# This device combines your microphone + BlackHole for capturing both sides of the call
AUDIO_DEVICE="Meeting Recording Input"

# Run Claude meeting intelligence processor after transcription (true/false)
# Requires Claude Code CLI to be installed and a meeting-intelligence-processor agent
RUN_MEETING_INTELLIGENCE="true"
