"""Speaker embedding library for voice-based speaker identification.

Maintains a persistent JSON library mapping speaker names to average voice
embeddings (256-dim clustering centroids from pyannote-audio). Used by
diarize-transcript.py to replace generic labels (Speaker A/B/C) with real
names when a voice match is found.

Library file: ~/.config/meeting-recorder/speaker-embeddings.json
"""

import json
import os
from datetime import date
from pathlib import Path

import numpy as np

DEFAULT_LIBRARY_PATH = os.path.expanduser(
    "~/.config/meeting-recorder/speaker-embeddings.json"
)
DEFAULT_THRESHOLD = 0.75


class SpeakerLibrary:
    """Persistent voice embedding library for speaker identification."""

    def __init__(self, path=None):
        self.path = path or DEFAULT_LIBRARY_PATH
        self.version = 1
        self.embedding_dimension = 256
        self.speakers = {}  # name -> {"embedding": np.array, "sample_count": int, "last_updated": str}
        self._dirty = False

    def load(self):
        """Load library from disk. Returns self for chaining. No-op if file doesn't exist."""
        if not os.path.isfile(self.path):
            return self

        with open(self.path) as f:
            data = json.load(f)

        self.version = data.get("version", 1)
        self.embedding_dimension = data.get("embedding_dimension", 256)

        for name, entry in data.get("speakers", {}).items():
            self.speakers[name] = {
                "embedding": np.array(entry["embedding"], dtype=np.float32),
                "sample_count": entry.get("sample_count", 1),
                "last_updated": entry.get("last_updated", ""),
            }

        return self

    def save(self):
        """Write library to disk. Creates parent directory if needed."""
        os.makedirs(os.path.dirname(self.path), exist_ok=True)

        data = {
            "version": self.version,
            "embedding_dimension": self.embedding_dimension,
            "speakers": {},
        }

        for name, entry in self.speakers.items():
            data["speakers"][name] = {
                "embedding": entry["embedding"].tolist(),
                "sample_count": entry["sample_count"],
                "last_updated": entry["last_updated"],
            }

        with open(self.path, "w") as f:
            json.dump(data, f, indent=2)

        self._dirty = False

    def enroll(self, name, embedding, source=None):
        """Add or update a speaker's voice embedding using running average.

        Args:
            name: Speaker's real name
            embedding: numpy array (256-dim) or list of floats
            source: Optional meeting identifier for logging
        """
        embedding = np.asarray(embedding, dtype=np.float32)

        if name in self.speakers:
            existing = self.speakers[name]
            count = existing["sample_count"]
            # Running average: new_avg = (old_avg * count + new) / (count + 1)
            existing["embedding"] = (existing["embedding"] * count + embedding) / (count + 1)
            existing["sample_count"] = count + 1
            existing["last_updated"] = date.today().isoformat()
        else:
            self.speakers[name] = {
                "embedding": embedding,
                "sample_count": 1,
                "last_updated": date.today().isoformat(),
            }

        self._dirty = True

    def identify(self, embedding, threshold=DEFAULT_THRESHOLD):
        """Identify a speaker by voice embedding.

        Returns:
            (name, confidence) if match found above threshold
            (None, best_score) if no match above threshold
            (None, 0.0) if library is empty
        """
        if not self.speakers:
            return None, 0.0

        embedding = np.asarray(embedding, dtype=np.float32)
        emb_norm = np.linalg.norm(embedding)
        if emb_norm == 0:
            return None, 0.0

        best_name = None
        best_score = -1.0

        for name, entry in self.speakers.items():
            ref = entry["embedding"]
            ref_norm = np.linalg.norm(ref)
            if ref_norm == 0:
                continue
            # Cosine similarity: dot(a, b) / (||a|| * ||b||)
            similarity = float(np.dot(embedding, ref) / (emb_norm * ref_norm))
            if similarity > best_score:
                best_score = similarity
                best_name = name

        if best_score >= threshold:
            return best_name, best_score
        return None, best_score

    def identify_all(self, embeddings_dict, threshold=DEFAULT_THRESHOLD):
        """Identify multiple speakers from a dict of {label: embedding}.

        Returns dict of {label: (name_or_None, confidence)}.
        Prevents duplicate assignments: if two labels match the same person,
        the higher-confidence match wins and the other gets None.
        """
        results = {}
        for label, embedding in embeddings_dict.items():
            name, confidence = self.identify(embedding, threshold)
            results[label] = (name, confidence)

        # Resolve conflicts: if multiple labels map to the same name,
        # keep the highest confidence match, set others to None
        name_to_best = {}  # name -> (label, confidence)
        for label, (name, confidence) in results.items():
            if name is None:
                continue
            if name not in name_to_best or confidence > name_to_best[name][1]:
                name_to_best[name] = (label, confidence)

        resolved = {}
        for label, (name, confidence) in results.items():
            if name is None:
                resolved[label] = (None, confidence)
            elif name_to_best[name][0] == label:
                resolved[label] = (name, confidence)
            else:
                # Another label had higher confidence for this name
                resolved[label] = (None, confidence)

        return resolved

    def __len__(self):
        return len(self.speakers)

    def __contains__(self, name):
        return name in self.speakers

    def list_speakers(self):
        """Return list of (name, sample_count, last_updated) tuples."""
        return [
            (name, entry["sample_count"], entry["last_updated"])
            for name, entry in sorted(self.speakers.items())
        ]
