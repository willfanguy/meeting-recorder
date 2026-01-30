#!/bin/bash
# Meeting Recorder Installation Script
# Installs dependencies and sets up the environment

set -e

echo "=== Meeting Recorder Installation ==="
echo ""

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "ERROR: Homebrew is required but not installed."
    echo "Install it from https://brew.sh"
    exit 1
fi

echo "[1/5] Installing ffmpeg..."
if command -v ffmpeg &> /dev/null; then
    echo "  ffmpeg already installed: $(ffmpeg -version 2>&1 | head -1)"
else
    brew install ffmpeg
fi

echo ""
echo "[2/5] Installing BlackHole audio driver..."
if ls /Library/Audio/Plug-Ins/HAL/ 2>/dev/null | grep -qi blackhole; then
    echo "  BlackHole already installed"
else
    echo "  Installing BlackHole 2ch (requires password)..."
    brew install blackhole-2ch
    echo ""
    echo "  *** IMPORTANT: You must REBOOT after installation for BlackHole to work ***"
    NEEDS_REBOOT=true
fi

echo ""
echo "[3/5] Installing whisper-cpp..."
if command -v whisper-cli &> /dev/null; then
    echo "  whisper-cpp already installed"
else
    brew install whisper-cpp
fi

echo ""
echo "[4/5] Downloading Whisper model..."
MODEL_DIR="$HOME/.local/share/whisper-models"
MODEL_FILE="$MODEL_DIR/ggml-base.en.bin"
mkdir -p "$MODEL_DIR"

if [ -f "$MODEL_FILE" ]; then
    echo "  Model already exists: $MODEL_FILE"
else
    echo "  Downloading base.en model (147MB)..."
    curl -L -o "$MODEL_FILE" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
fi

echo ""
echo "[5/5] Setting up configuration..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/config.sh" ]; then
    echo "  config.sh already exists"
else
    cp "$SCRIPT_DIR/config.example.sh" "$SCRIPT_DIR/config.sh"
    echo "  Created config.sh from template"
    echo "  Edit config.sh to customize paths for your setup"
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/scripts/"*.sh

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo ""
echo "1. Edit config.sh to set your paths"
echo ""
echo "2. Set up audio routing in Audio MIDI Setup:"
echo "   a. Create Multi-Output Device (speakers + BlackHole) - for hearing audio"
echo "   b. Create Aggregate Device (mic + BlackHole) named 'Meeting Recording Input'"
echo ""
echo "3. Configure MeetingBar to run the AppleScripts:"
echo "   - Join meeting  → scripts/MeetingBar-Start.applescript"
echo "   - Leave meeting → scripts/MeetingBar-Stop.applescript"
echo ""
echo "4. Test manually:"
echo "   ./scripts/start-recording.sh"
echo "   ./scripts/stop-recording.sh"
echo ""

if [ "$NEEDS_REBOOT" = true ]; then
    echo "*** REBOOT REQUIRED: BlackHole was installed. Reboot before testing. ***"
fi
