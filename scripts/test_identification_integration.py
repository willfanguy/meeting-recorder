#!/usr/bin/env python3
"""Integration test: speaker identification through the full diarization pipeline.

Tests that when a speaker library exists with enrolled speakers, the diarization
output uses real names instead of generic labels.
"""

import json
import os
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from speaker_library import SpeakerLibrary


def make_embedding(seed=42):
    rng = np.random.RandomState(seed)
    emb = rng.randn(256).astype(np.float32)
    return emb / np.linalg.norm(emb)


def test_enrollment_from_diarization_json():
    """Test the enroll-speakers workflow: read embeddings from JSON, enroll, then identify."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # 1. Create a diarization JSON with embeddings (as Phase 1 would produce)
        emb_will = make_embedding(seed=1)
        emb_judith = make_embedding(seed=2)
        emb_thomas = make_embedding(seed=3)

        diarization_data = {
            "speakers": {
                "Speaker A": "SPEAKER_00",
                "Speaker B": "SPEAKER_01",
                "Speaker C": "SPEAKER_02",
            },
            "speaker_count": 3,
            "embedding_dimension": 256,
            "speaker_embeddings": {
                "Speaker A": emb_will.tolist(),
                "Speaker B": emb_judith.tolist(),
                "Speaker C": emb_thomas.tolist(),
            },
            "segments": [],
        }

        json_path = os.path.join(tmpdir, "test.diarization.json")
        with open(json_path, "w") as f:
            json.dump(diarization_data, f)

        # 2. Enroll speakers from the JSON
        lib_path = os.path.join(tmpdir, "speaker-embeddings.json")
        lib = SpeakerLibrary(path=lib_path)

        with open(json_path) as f:
            data = json.load(f)

        lib.enroll("Will Fanguy", np.array(data["speaker_embeddings"]["Speaker A"]))
        lib.enroll("Judith Wilding", np.array(data["speaker_embeddings"]["Speaker B"]))
        lib.enroll("Thomas", np.array(data["speaker_embeddings"]["Speaker C"]))
        lib.save()

        # 3. Simulate a new meeting with the same speakers (slightly noisy embeddings)
        rng = np.random.RandomState(100)
        new_emb_will = emb_will + rng.randn(256).astype(np.float32) * 0.05
        new_emb_judith = emb_judith + rng.randn(256).astype(np.float32) * 0.05
        new_emb_stranger = make_embedding(seed=999)  # Unknown speaker

        new_embeddings = {
            "Speaker A": new_emb_will,
            "Speaker B": new_emb_judith,
            "Speaker C": new_emb_stranger,
        }

        # 4. Identify
        lib2 = SpeakerLibrary(path=lib_path)
        lib2.load()
        results = lib2.identify_all(new_embeddings, threshold=0.75)

        # Will and Judith should be identified (noisy but close)
        assert results["Speaker A"][0] == "Will Fanguy", \
            f"Expected Will, got {results['Speaker A']}"
        assert results["Speaker A"][1] > 0.75, \
            f"Will confidence too low: {results['Speaker A'][1]}"

        assert results["Speaker B"][0] == "Judith Wilding", \
            f"Expected Judith, got {results['Speaker B']}"

        # Stranger should NOT be identified
        assert results["Speaker C"][0] is None, \
            f"Stranger should be None, got {results['Speaker C']}"

    print("PASS: test_enrollment_from_diarization_json")


def test_incremental_enrollment_improves():
    """Enrolling same speaker multiple times should improve robustness."""
    with tempfile.TemporaryDirectory() as tmpdir:
        lib_path = os.path.join(tmpdir, "speaker-embeddings.json")
        lib = SpeakerLibrary(path=lib_path)

        # Enroll Will from 5 different "meetings" (slightly varying embeddings)
        base_emb = make_embedding(seed=1)
        for i in range(5):
            rng = np.random.RandomState(100 + i)
            noisy_emb = base_emb + rng.randn(256).astype(np.float32) * 0.1
            lib.enroll("Will Fanguy", noisy_emb)

        assert lib.speakers["Will Fanguy"]["sample_count"] == 5

        # The averaged embedding should be closer to the true embedding
        # than any single noisy sample
        avg_emb = lib.speakers["Will Fanguy"]["embedding"]
        avg_norm = np.linalg.norm(avg_emb)
        base_norm = np.linalg.norm(base_emb)
        similarity = float(np.dot(avg_emb, base_emb) / (avg_norm * base_norm))

        # With 5 samples at noise=0.1 on 256-dim, running average gives ~0.8+ similarity
        assert similarity > 0.75, f"Average embedding should be closer to true than random: {similarity}"

    print("PASS: test_incremental_enrollment_improves")


def test_library_survives_missing_file():
    """Pipeline should work fine with no library file (graceful degradation)."""
    lib = SpeakerLibrary(path="/nonexistent/path/speaker-embeddings.json")
    lib.load()

    emb = make_embedding(seed=1)
    name, confidence = lib.identify(emb)
    assert name is None
    assert confidence == 0.0

    results = lib.identify_all({"Speaker A": emb})
    assert results["Speaker A"][0] is None

    print("PASS: test_library_survives_missing_file")


def test_enroll_cli_assign_roundtrip():
    """Test the JSON -> enroll -> identify roundtrip that enroll-speakers.py does."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Simulate what enroll-speakers.py --assign does
        emb = make_embedding(seed=42)

        diarization_data = {
            "speaker_embeddings": {
                "Speaker A": emb.tolist(),
            }
        }
        json_path = os.path.join(tmpdir, "test.diarization.json")
        with open(json_path, "w") as f:
            json.dump(diarization_data, f)

        # Load embeddings (same logic as enroll-speakers.py)
        with open(json_path) as f:
            data = json.load(f)

        loaded_emb = np.array(data["speaker_embeddings"]["Speaker A"], dtype=np.float32)

        # Enroll
        lib_path = os.path.join(tmpdir, "lib.json")
        lib = SpeakerLibrary(path=lib_path)
        lib.enroll("Test Speaker", loaded_emb)
        lib.save()

        # Reload and identify
        lib2 = SpeakerLibrary(path=lib_path)
        lib2.load()
        name, conf = lib2.identify(emb)
        assert name == "Test Speaker", f"Expected Test Speaker, got {name}"
        assert conf > 0.99

    print("PASS: test_enroll_cli_assign_roundtrip")


if __name__ == "__main__":
    test_enrollment_from_diarization_json()
    test_incremental_enrollment_improves()
    test_library_survives_missing_file()
    test_enroll_cli_assign_roundtrip()
    print("\nAll identification integration tests passed.")
