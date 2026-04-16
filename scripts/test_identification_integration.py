"""Integration test: speaker identification through the full diarization pipeline.

Tests that when a speaker library exists with enrolled speakers, the diarization
output uses real names instead of generic labels.
"""

import json
import os
import tempfile

import numpy as np

from speaker_library import SpeakerLibrary


def test_enrollment_from_diarization_json(embedding_factory):
    """Test the enroll-speakers workflow: read embeddings from JSON, enroll, then identify."""
    with tempfile.TemporaryDirectory() as tmpdir:
        emb_will = embedding_factory(seed=1)
        emb_judith = embedding_factory(seed=2)
        emb_thomas = embedding_factory(seed=3)

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

        # Enroll speakers from the JSON
        lib_path = os.path.join(tmpdir, "speaker-embeddings.json")
        lib = SpeakerLibrary(path=lib_path)

        with open(json_path) as f:
            data = json.load(f)

        lib.enroll("Will Fanguy", np.array(data["speaker_embeddings"]["Speaker A"]))
        lib.enroll("Judith Wilding", np.array(data["speaker_embeddings"]["Speaker B"]))
        lib.enroll("Thomas", np.array(data["speaker_embeddings"]["Speaker C"]))
        lib.save()

        # Simulate a new meeting with the same speakers (slightly noisy embeddings)
        rng = np.random.RandomState(100)
        new_emb_will = emb_will + rng.randn(256).astype(np.float32) * 0.05
        new_emb_judith = emb_judith + rng.randn(256).astype(np.float32) * 0.05
        new_emb_stranger = embedding_factory(seed=999)

        new_embeddings = {
            "Speaker A": new_emb_will,
            "Speaker B": new_emb_judith,
            "Speaker C": new_emb_stranger,
        }

        lib2 = SpeakerLibrary(path=lib_path)
        lib2.load()
        results = lib2.identify_all(new_embeddings, threshold=0.75)

        assert results["Speaker A"][0] == "Will Fanguy", \
            f"Expected Will, got {results['Speaker A']}"
        assert results["Speaker A"][1] > 0.75, \
            f"Will confidence too low: {results['Speaker A'][1]}"
        assert results["Speaker B"][0] == "Judith Wilding", \
            f"Expected Judith, got {results['Speaker B']}"
        assert results["Speaker C"][0] is None, \
            f"Stranger should be None, got {results['Speaker C']}"


def test_incremental_enrollment_improves(embedding_factory):
    """Enrolling same speaker multiple times should improve robustness."""
    with tempfile.TemporaryDirectory() as tmpdir:
        lib_path = os.path.join(tmpdir, "speaker-embeddings.json")
        lib = SpeakerLibrary(path=lib_path)

        base_emb = embedding_factory(seed=1)
        for i in range(5):
            rng = np.random.RandomState(100 + i)
            noisy_emb = base_emb + rng.randn(256).astype(np.float32) * 0.1
            lib.enroll("Will Fanguy", noisy_emb)

        assert lib.speakers["Will Fanguy"]["sample_count"] == 5

        avg_emb = lib.speakers["Will Fanguy"]["embedding"]
        avg_norm = np.linalg.norm(avg_emb)
        base_norm = np.linalg.norm(base_emb)
        similarity = float(np.dot(avg_emb, base_emb) / (avg_norm * base_norm))

        assert similarity > 0.75, f"Average embedding should converge toward true: {similarity}"


def test_library_survives_missing_file(embedding_factory):
    """Pipeline should work fine with no library file (graceful degradation)."""
    lib = SpeakerLibrary(path="/nonexistent/path/speaker-embeddings.json")
    lib.load()

    emb = embedding_factory(seed=1)
    name, confidence = lib.identify(emb)
    assert name is None
    assert confidence == 0.0

    results = lib.identify_all({"Speaker A": emb})
    assert results["Speaker A"][0] is None


def test_enroll_cli_assign_roundtrip(embedding_factory):
    """Test the JSON -> enroll -> identify roundtrip that enroll-speakers.py does."""
    with tempfile.TemporaryDirectory() as tmpdir:
        emb = embedding_factory(seed=42)

        diarization_data = {
            "speaker_embeddings": {
                "Speaker A": emb.tolist(),
            }
        }
        json_path = os.path.join(tmpdir, "test.diarization.json")
        with open(json_path, "w") as f:
            json.dump(diarization_data, f)

        with open(json_path) as f:
            data = json.load(f)

        loaded_emb = np.array(data["speaker_embeddings"]["Speaker A"], dtype=np.float32)

        lib_path = os.path.join(tmpdir, "lib.json")
        lib = SpeakerLibrary(path=lib_path)
        lib.enroll("Test Speaker", loaded_emb)
        lib.save()

        lib2 = SpeakerLibrary(path=lib_path)
        lib2.load()
        name, conf = lib2.identify(emb)
        assert name == "Test Speaker", f"Expected Test Speaker, got {name}"
        assert conf > 0.99
