"""Tests for diarize-transcript.py embedding extraction and JSON sidecar."""

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np


# --- Helpers to create mock pyannote objects ---


class MockSegment:
    def __init__(self, start, end):
        self.start = start
        self.end = end


class MockAnnotation:
    """Minimal mock of pyannote.core.Annotation."""

    def __init__(self, tracks):
        # tracks: list of (start, end, speaker_label)
        self._tracks = tracks

    def itertracks(self, yield_label=False):
        for start, end, speaker in self._tracks:
            seg = MockSegment(start, end)
            if yield_label:
                yield seg, None, speaker
            else:
                yield seg, None

    def labels(self):
        seen = []
        for _, _, speaker in self._tracks:
            if speaker not in seen:
                seen.append(speaker)
        return seen


@dataclass
class MockDiarizeOutput:
    speaker_diarization: MockAnnotation
    exclusive_speaker_diarization: MockAnnotation
    speaker_embeddings: np.ndarray = None


# --- Tests ---


def test_write_diarization_json_with_embeddings(diarize_mod):
    """Verify embeddings are persisted to the JSON sidecar."""
    tracks = [
        (0.0, 5.0, "SPEAKER_00"),
        (5.0, 10.0, "SPEAKER_01"),
        (10.0, 15.0, "SPEAKER_00"),
    ]
    diarization = MockAnnotation(tracks)
    speaker_map = diarize_mod.build_speaker_map(diarization)

    embeddings = np.random.randn(2, 256).astype(np.float32)
    diarize_output = MockDiarizeOutput(
        speaker_diarization=diarization,
        exclusive_speaker_diarization=diarization,
        speaker_embeddings=embeddings,
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        wav_path = os.path.join(tmpdir, "test.wav")
        Path(wav_path).touch()

        diarize_mod.write_diarization_json(diarization, speaker_map, wav_path, diarize_output)

        json_path = os.path.join(tmpdir, "test.diarization.json")
        assert os.path.exists(json_path), f"JSON sidecar not created at {json_path}"

        with open(json_path) as f:
            data = json.load(f)

        assert data["speaker_count"] == 2
        assert data["embedding_dimension"] == 256
        assert "speaker_embeddings" in data
        assert len(data["speaker_embeddings"]) == 2

        for label in ["Speaker A", "Speaker B"]:
            assert label in data["speaker_embeddings"], f"Missing embedding for {label}"
            emb = data["speaker_embeddings"][label]
            assert len(emb) == 256, f"Wrong embedding dimension: {len(emb)}"
            assert any(v != 0 for v in emb), f"All-zero embedding for {label}"

        # Verify roundtrip: loaded embeddings match originals
        labels = diarization.labels()
        for i, label in enumerate(labels):
            friendly = speaker_map[label]
            loaded = np.array(data["speaker_embeddings"][friendly])
            np.testing.assert_array_almost_equal(loaded, embeddings[i], decimal=5)


def test_write_diarization_json_without_embeddings(diarize_mod):
    """Verify backward compatibility when diarize_output is None (pyannote 3.x)."""
    tracks = [
        (0.0, 5.0, "SPEAKER_00"),
        (5.0, 10.0, "SPEAKER_01"),
    ]
    diarization = MockAnnotation(tracks)
    speaker_map = diarize_mod.build_speaker_map(diarization)

    with tempfile.TemporaryDirectory() as tmpdir:
        wav_path = os.path.join(tmpdir, "test.wav")
        Path(wav_path).touch()

        diarize_mod.write_diarization_json(diarization, speaker_map, wav_path, diarize_output=None)

        json_path = os.path.join(tmpdir, "test.diarization.json")
        with open(json_path) as f:
            data = json.load(f)

        assert data["speaker_count"] == 2
        assert "speaker_embeddings" not in data
        assert "embedding_dimension" not in data
        assert len(data["segments"]) == 2


def test_write_diarization_json_empty_embeddings(diarize_mod):
    """Verify handling of empty embeddings (0 speakers detected early exit)."""
    tracks = [(0.0, 5.0, "SPEAKER_00")]
    diarization = MockAnnotation(tracks)
    speaker_map = diarize_mod.build_speaker_map(diarization)

    embeddings = np.zeros((0, 256), dtype=np.float32)
    diarize_output = MockDiarizeOutput(
        speaker_diarization=diarization,
        exclusive_speaker_diarization=diarization,
        speaker_embeddings=embeddings,
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        wav_path = os.path.join(tmpdir, "test.wav")
        Path(wav_path).touch()

        diarize_mod.write_diarization_json(diarization, speaker_map, wav_path, diarize_output)

        json_path = os.path.join(tmpdir, "test.diarization.json")
        with open(json_path) as f:
            data = json.load(f)

        assert "speaker_embeddings" not in data


def test_build_speaker_map(diarize_mod):
    """Verify speaker map assigns alphabetical labels sorted by speaker ID."""
    tracks = [
        (0.0, 5.0, "SPEAKER_02"),
        (5.0, 10.0, "SPEAKER_00"),
        (10.0, 15.0, "SPEAKER_01"),
    ]
    diarization = MockAnnotation(tracks)
    speaker_map = diarize_mod.build_speaker_map(diarization)

    assert speaker_map["SPEAKER_00"] == "Speaker A"
    assert speaker_map["SPEAKER_01"] == "Speaker B"
    assert speaker_map["SPEAKER_02"] == "Speaker C"


def test_parse_srt(diarize_mod):
    """Verify SRT parsing handles standard format with multi-line text."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".srt", delete=False) as f:
        f.write("1\n00:00:00,000 --> 00:00:05,500\nHello world\n\n")
        f.write("2\n00:01:30,200 --> 00:01:35,800\nSecond line\nwith continuation\n\n")
        srt_path = f.name

    try:
        entries = diarize_mod.parse_srt(srt_path)
        assert len(entries) == 2
        assert entries[0] == (1, 0.0, 5.5, "Hello world")
        assert entries[1][0] == 2
        assert abs(entries[1][1] - 90.2) < 0.01
        assert "Second line\nwith continuation" in entries[1][3]
    finally:
        os.unlink(srt_path)


def test_assign_speakers_single_dominant(diarize_mod):
    """Verify single-speaker segments get the dominant speaker."""
    tracks = [
        (0.0, 5.0, "SPEAKER_00"),
        (5.0, 10.0, "SPEAKER_01"),
    ]
    diarization = MockAnnotation(tracks)
    srt_entries = [
        (1, 0.5, 4.5, "Hello from speaker zero"),
        (2, 5.5, 9.5, "Hello from speaker one"),
    ]

    labeled = diarize_mod.assign_speakers(srt_entries, diarization)
    assert len(labeled) == 2
    assert labeled[0][2] == "SPEAKER_00"
    assert labeled[1][2] == "SPEAKER_01"
