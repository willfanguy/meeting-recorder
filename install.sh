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
echo "[4/5] Downloading Whisper models..."
MODEL_DIR="$HOME/.local/share/whisper-models"
mkdir -p "$MODEL_DIR"

HF_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

# Large model (default for most meetings)
LARGE_MODEL="$MODEL_DIR/ggml-large-v3-q5_0.bin"
if [ -f "$LARGE_MODEL" ]; then
    echo "  Large model already exists"
else
    echo "  Downloading large-v3-q5_0 model (~1.1GB)..."
    curl -L -o "$LARGE_MODEL" "$HF_BASE/ggml-large-v3-q5_0.bin"
fi

# Medium model (used for routine meetings like standups/syncs)
MEDIUM_MODEL="$MODEL_DIR/ggml-medium-q5_0.bin"
if [ -f "$MEDIUM_MODEL" ]; then
    echo "  Medium model already exists"
else
    echo "  Downloading medium-q5_0 model (~539MB)..."
    curl -L -o "$MEDIUM_MODEL" "$HF_BASE/ggml-medium-q5_0.bin"
fi

# Base model (fallback)
BASE_MODEL="$MODEL_DIR/ggml-base.en.bin"
if [ -f "$BASE_MODEL" ]; then
    echo "  Base model already exists"
else
    echo "  Downloading base.en model (~147MB)..."
    curl -L -o "$BASE_MODEL" "$HF_BASE/ggml-base.en.bin"
fi

echo ""
echo "[5/5] Setting up..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Make scripts executable
chmod +x "$SCRIPT_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$SCRIPT_DIR/raycast/"*.sh 2>/dev/null || true

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo ""
echo "1. REBOOT your Mac (required for BlackHole to load)"
echo ""
echo "2. After reboot, follow docs/POST_REBOOT_SETUP.md:"
echo "   - Create audio devices in Audio MIDI Setup"
echo "   - Configure meeting app audio output"
echo "   - Grant macOS permissions"
echo ""
echo "3. Customize paths in the scripts (see README.md 'Customization' section)"
echo ""
echo "4. (Optional) Set up MeetingBar with:"
echo "   Event start script -> scripts/eventStartScript.applescript"
echo ""
echo "5. Test manually:"
echo "   osascript scripts/quicktime-start-recording.applescript"
echo "   osascript scripts/quicktime-stop-recording.applescript"
echo ""

if [ "$NEEDS_REBOOT" = true ]; then
    echo "*** REBOOT REQUIRED: BlackHole was installed. Reboot before testing. ***"
fi
