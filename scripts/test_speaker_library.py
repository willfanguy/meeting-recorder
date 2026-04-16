"""Tests for speaker_library.py."""

import os
import tempfile

import numpy as np

from speaker_library import SpeakerLibrary


def test_enroll_and_identify(embedding_factory):
    """Enroll a speaker, then identify them from their own embedding."""
    lib = SpeakerLibrary(path="/dev/null")
    emb = embedding_factory(seed=1)
    lib.enroll("Will Fanguy", emb)

    name, confidence = lib.identify(emb)
    assert name == "Will Fanguy", f"Expected Will, got {name}"
    assert confidence > 0.99, f"Self-match should be ~1.0, got {confidence}"


def test_identify_different_speaker(embedding_factory):
    """Two different speakers should not match each other."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = embedding_factory(seed=1)
    emb_judith = embedding_factory(seed=2)

    lib.enroll("Will Fanguy", emb_will)
    lib.enroll("Judith Wilding", emb_judith)

    name, _ = lib.identify(emb_will)
    assert name == "Will Fanguy", f"Expected Will, got {name}"

    name, _ = lib.identify(emb_judith)
    assert name == "Judith Wilding", f"Expected Judith, got {name}"


def test_identify_below_threshold(embedding_factory):
    """A dissimilar embedding should return None."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = embedding_factory(seed=1)
    lib.enroll("Will Fanguy", emb_will)

    emb_stranger = embedding_factory(seed=999)
    name, confidence = lib.identify(emb_stranger, threshold=0.9)
    assert name is None, f"Expected None, got {name} with confidence {confidence}"


def test_running_average(embedding_factory):
    """Enrolling the same speaker multiple times should average embeddings."""
    lib = SpeakerLibrary(path="/dev/null")
    emb1 = embedding_factory(seed=10)
    emb2 = embedding_factory(seed=11)

    lib.enroll("Will Fanguy", emb1)
    assert lib.speakers["Will Fanguy"]["sample_count"] == 1

    lib.enroll("Will Fanguy", emb2)
    assert lib.speakers["Will Fanguy"]["sample_count"] == 2

    expected = (emb1 + emb2) / 2
    np.testing.assert_array_almost_equal(
        lib.speakers["Will Fanguy"]["embedding"], expected, decimal=5
    )


def test_save_and_load(embedding_factory):
    """Round-trip save/load preserves all data."""
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        lib_path = f.name

    try:
        lib = SpeakerLibrary(path=lib_path)
        emb_will = embedding_factory(seed=1)
        emb_judith = embedding_factory(seed=2)
        lib.enroll("Will Fanguy", emb_will)
        lib.enroll("Judith Wilding", emb_judith)
        lib.enroll("Will Fanguy", emb_will)  # Second enrollment
        lib.save()

        lib2 = SpeakerLibrary(path=lib_path)
        lib2.load()

        assert len(lib2) == 2
        assert "Will Fanguy" in lib2
        assert "Judith Wilding" in lib2
        assert lib2.speakers["Will Fanguy"]["sample_count"] == 2
        assert lib2.speakers["Judith Wilding"]["sample_count"] == 1

        np.testing.assert_array_almost_equal(
            lib2.speakers["Will Fanguy"]["embedding"],
            lib.speakers["Will Fanguy"]["embedding"],
            decimal=5,
        )
    finally:
        os.unlink(lib_path)


def test_load_nonexistent():
    """Loading from nonexistent path should be a no-op."""
    lib = SpeakerLibrary(path="/nonexistent/path.json")
    lib.load()
    assert len(lib) == 0


def test_identify_all_no_conflicts(embedding_factory):
    """identify_all with distinct speakers, no conflicts."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = embedding_factory(seed=1)
    emb_judith = embedding_factory(seed=2)
    lib.enroll("Will Fanguy", emb_will)
    lib.enroll("Judith Wilding", emb_judith)

    results = lib.identify_all({
        "Speaker A": emb_will,
        "Speaker B": emb_judith,
    })

    assert results["Speaker A"][0] == "Will Fanguy"
    assert results["Speaker B"][0] == "Judith Wilding"


def test_identify_all_conflict_resolution(embedding_factory):
    """When two labels match the same person, highest confidence wins."""
    lib = SpeakerLibrary(path="/dev/null")
    emb_will = embedding_factory(seed=1)
    lib.enroll("Will Fanguy", emb_will)

    emb_close = emb_will + np.random.RandomState(42).randn(256).astype(np.float32) * 0.01
    emb_further = emb_will + np.random.RandomState(43).randn(256).astype(np.float32) * 0.1

    results = lib.identify_all({
        "Speaker A": emb_close,
        "Speaker B": emb_further,
    }, threshold=0.5)

    names = {label: name for label, (name, _) in results.items()}
    will_count = sum(1 for n in names.values() if n == "Will Fanguy")
    assert will_count <= 1, f"Will assigned to multiple speakers: {names}"


def test_identify_empty_library(embedding_factory):
    """Identify with empty library should return None."""
    lib = SpeakerLibrary(path="/dev/null")
    emb = embedding_factory(seed=1)
    name, confidence = lib.identify(emb)
    assert name is None
    assert confidence == 0.0


def test_identify_zero_embedding():
    """Zero embedding should return None (cosine similarity undefined)."""
    lib = SpeakerLibrary(path="/dev/null")
    from conftest import make_embedding
    lib.enroll("Will Fanguy", make_embedding(seed=1))

    name, confidence = lib.identify(np.zeros(256))
    assert name is None
    assert confidence == 0.0


def test_list_speakers(embedding_factory):
    """list_speakers returns alphabetically sorted tuples."""
    lib = SpeakerLibrary(path="/dev/null")
    lib.enroll("Judith Wilding", embedding_factory(seed=2))
    lib.enroll("Will Fanguy", embedding_factory(seed=1))

    speakers = lib.list_speakers()
    assert len(speakers) == 2
    assert speakers[0][0] == "Judith Wilding"
    assert speakers[1][0] == "Will Fanguy"
