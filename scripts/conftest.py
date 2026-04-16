"""Shared fixtures for meeting-recorder tests."""

import os
import sys
from importlib.util import spec_from_file_location, module_from_spec

import numpy as np
import pytest

# Add scripts dir to path so test files can import modules directly
sys.path.insert(0, os.path.dirname(__file__))


@pytest.fixture(scope="session")
def diarize_mod():
    """Import diarize-transcript.py (hyphenated filename requires importlib)."""
    spec = spec_from_file_location(
        "diarize_transcript",
        os.path.join(os.path.dirname(__file__), "diarize-transcript.py"),
    )
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="session")
def domain_corrections_mod():
    """Import apply-domain-corrections.py."""
    spec = spec_from_file_location(
        "domain_corrections",
        os.path.join(os.path.dirname(__file__), "apply-domain-corrections.py"),
    )
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="session")
def enroll_speakers_mod():
    """Import enroll-speakers.py."""
    spec = spec_from_file_location(
        "enroll_speakers",
        os.path.join(os.path.dirname(__file__), "enroll-speakers.py"),
    )
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_embedding(seed=42):
    """Generate a deterministic L2-normalized 256-dim embedding."""
    rng = np.random.RandomState(seed)
    emb = rng.randn(256).astype(np.float32)
    return emb / np.linalg.norm(emb)


@pytest.fixture
def embedding_factory():
    """Provide the make_embedding helper as a fixture."""
    return make_embedding
