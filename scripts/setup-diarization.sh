#!/bin/bash
# One-time setup: create Python venv and install pyannote-audio for speaker diarization
# Run manually: ./scripts/setup-diarization.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
UV="$HOME/.local/bin/uv"

if [ ! -f "$UV" ]; then
    echo "ERROR: uv not found at $UV"
    echo "Install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

echo "Creating Python 3.12 virtual environment..."
"$UV" venv --python 3.12 "$VENV_DIR"

echo "Installing torch + pyannote-audio (this may take a few minutes)..."
"$UV" pip install --python "$VENV_DIR/bin/python" \
    torch \
    torchaudio \
    pyannote-audio

echo ""
echo "=== Diarization venv ready at: $VENV_DIR ==="
echo ""
echo "IMPORTANT — Complete these manual steps:"
echo ""
echo "1. Accept the speaker-diarization model license:"
echo "   https://huggingface.co/pyannote/speaker-diarization-3.1"
echo ""
echo "2. Accept the segmentation model license:"
echo "   https://huggingface.co/pyannote/segmentation-3.0"
echo ""
echo "3. Generate a HuggingFace access token (read access is sufficient):"
echo "   https://huggingface.co/settings/tokens"
echo ""
echo "4. Add the token to your config.sh:"
echo "   echo 'HF_TOKEN=\"hf_your_token_here\"' >> $SCRIPT_DIR/../config.sh"
echo ""
echo "First run will download ~100 MB of model weights (cached for subsequent runs)."
