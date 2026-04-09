#!/usr/bin/env python3
"""Tests for speaker_library.py."""

import json
import os
import tempfile

import numpy as np

from speaker_library import SpeakerLibrary, DEFAULT_THRESHOLD


def make_embedding(seed=42):
    """Generate a deterministic 256-dim embedding."""
    rng = np.random.RandomState(seed)
    emb = rng.randn(256).astype(np.float32)
    return emb / np.linalg.norm(emb)  # L2-normalize


def test_enroll_and_identify():
    """Enroll a speaker, then identify them from their own embedding."""
    lib = SpeakerLibrary(path="/dev/null")
    emb = make_embedding(seed=1)
    lib.enroll("Will Fanguy", emb)

    name, confidence = lib.identify(emb)
    assert name == "Will Fanguy", f"Expected Will, got {name}"
    assert confidence > 0.99, f"Self-match should be ~1.0, got {confidence}"
    print("PASS: test_enroll_and_identify")


def test_identify_different_speaker():
    """Two different speakers should not match each other."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = make_embedding(seed=1)
    emb_judith = make_embedding(seed=2)

    lib.enroll("Will Fanguy", emb_will)
    lib.enroll("Judith Wilding", emb_judith)

    # Will's embedding should identify as Will
    name, conf = lib.identify(emb_will)
    assert name == "Will Fanguy", f"Expected Will, got {name}"

    # Judith's embedding should identify as Judith
    name, conf = lib.identify(emb_judith)
    assert name == "Judith Wilding", f"Expected Judith, got {name}"

    print("PASS: test_identify_different_speaker")


def test_identify_below_threshold():
    """A dissimilar embedding should return None."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = make_embedding(seed=1)
    lib.enroll("Will Fanguy", emb_will)

    # Create an embedding that's very different
    emb_stranger = make_embedding(seed=999)
    name, confidence = lib.identify(emb_stranger, threshold=0.9)
    # With random 256-dim vectors, cosine similarity is typically near 0
    # so this should be below any reasonable threshold
    assert name is None, f"Expected None, got {name} with confidence {confidence}"
    print("PASS: test_identify_below_threshold")


def test_running_average():
    """Enrolling the same speaker multiple times should average embeddings."""
    lib = SpeakerLibrary(path="/dev/null")
    emb1 = make_embedding(seed=10)
    emb2 = make_embedding(seed=11)

    lib.enroll("Will Fanguy", emb1)
    assert lib.speakers["Will Fanguy"]["sample_count"] == 1

    lib.enroll("Will Fanguy", emb2)
    assert lib.speakers["Will Fanguy"]["sample_count"] == 2

    # Average should be (emb1 + emb2) / 2
    expected = (emb1 + emb2) / 2
    np.testing.assert_array_almost_equal(
        lib.speakers["Will Fanguy"]["embedding"], expected, decimal=5
    )
    print("PASS: test_running_average")


def test_save_and_load():
    """Round-trip save/load preserves all data."""
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        lib_path = f.name

    try:
        # Save
        lib = SpeakerLibrary(path=lib_path)
        emb_will = make_embedding(seed=1)
        emb_judith = make_embedding(seed=2)
        lib.enroll("Will Fanguy", emb_will)
        lib.enroll("Judith Wilding", emb_judith)
        lib.enroll("Will Fanguy", emb_will)  # Second enrollment
        lib.save()

        # Load
        lib2 = SpeakerLibrary(path=lib_path)
        lib2.load()

        assert len(lib2) == 2
        assert "Will Fanguy" in lib2
        assert "Judith Wilding" in lib2
        assert lib2.speakers["Will Fanguy"]["sample_count"] == 2
        assert lib2.speakers["Judith Wilding"]["sample_count"] == 1

        # Embeddings should survive roundtrip
        np.testing.assert_array_almost_equal(
            lib2.speakers["Will Fanguy"]["embedding"],
            lib.speakers["Will Fanguy"]["embedding"],
            decimal=5,
        )
    finally:
        os.unlink(lib_path)

    print("PASS: test_save_and_load")


def test_load_nonexistent():
    """Loading from nonexistent path should be a no-op."""
    lib = SpeakerLibrary(path="/nonexistent/path.json")
    lib.load()
    assert len(lib) == 0
    print("PASS: test_load_nonexistent")


def test_identify_all_no_conflicts():
    """identify_all with distinct speakers, no conflicts."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = make_embedding(seed=1)
    emb_judith = make_embedding(seed=2)
    lib.enroll("Will Fanguy", emb_will)
    lib.enroll("Judith Wilding", emb_judith)

    results = lib.identify_all({
        "Speaker A": emb_will,
        "Speaker B": emb_judith,
    })

    assert results["Speaker A"][0] == "Will Fanguy"
    assert results["Speaker B"][0] == "Judith Wilding"
    print("PASS: test_identify_all_no_conflicts")


def test_identify_all_conflict_resolution():
    """When two labels match the same person, highest confidence wins."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = make_embedding(seed=1)
    lib.enroll("Will Fanguy", emb_will)

    # Both labels are similar to Will, but one is closer
    emb_close = emb_will + np.random.RandomState(42).randn(256).astype(np.float32) * 0.01
    emb_further = emb_will + np.random.RandomState(43).randn(256).astype(np.float32) * 0.1

    results = lib.identify_all({
        "Speaker A": emb_close,
        "Speaker B": emb_further,
    }, threshold=0.5)

    # Only the closer match should get the name
    names = {label: name for label, (name, _) in results.items()}
    will_count = sum(1 for n in names.values() if n == "Will Fanguy")
    assert will_count <= 1, f"Will assigned to multiple speakers: {names}"
    print("PASS: test_identify_all_conflict_resolution")


def test_identify_empty_library():
    """Identify with empty library should return None."""
    lib = SpeakerLibrary(path="/dev/null")
    emb = make_embedding(seed=1)
    name, confidence = lib.identify(emb)
    assert name is None
    assert confidence == 0.0
    print("PASS: test_identify_empty_library")


def test_identify_zero_embedding():
    """Zero embedding should return None."""
    lib = SpeakerLibrary(path="/dev/null")
    lib.enroll("Will Fanguy", make_embedding(seed=1))

    name, confidence = lib.identify(np.zeros(256))
    assert name is None
    assert confidence == 0.0
    print("PASS: test_identify_zero_embedding")


def test_list_speakers():
    """list_speakers returns sorted tuples."""
    lib = SpeakerLibrary(path="/dev/null")
    lib.enroll("Judith Wilding", make_embedding(seed=2))
    lib.enroll("Will Fanguy", make_embedding(seed=1))

    speakers = lib.list_speakers()
    assert len(speakers) == 2
    assert speakers[0][0] == "Judith Wilding"  # Sorted alphabetically
    assert speakers[1][0] == "Will Fanguy"
    print("PASS: test_list_speakers")


if __name__ == "__main__":
    test_enroll_and_identify()
    test_identify_different_speaker()
    test_identify_below_threshold()
    test_running_average()
    test_save_and_load()
    test_load_nonexistent()
    test_identify_all_no_conflicts()
    test_identify_all_conflict_resolution()
    test_identify_empty_library()
    test_identify_zero_embedding()
    test_list_speakers()
    print("\nAll speaker library tests passed.")
