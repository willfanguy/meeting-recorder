"""Tests for apply-domain-corrections.py.

Tests the core correction logic: loading dictionaries, building regex patterns,
and applying corrections with longest-match-first ordering. Includes property-based
tests via hypothesis for idempotency and determinism invariants.
"""

import json
import os
import tempfile

import pytest

try:
    from hypothesis import given, settings, assume
    from hypothesis import strategies as st

    HAS_HYPOTHESIS = True
except ImportError:
    HAS_HYPOTHESIS = False


# --- Fixtures ---


@pytest.fixture
def corrections_dict(tmp_path):
    """Write a test corrections dictionary and return its path."""
    data = {
        "_comment": "Test dictionary",
        "companies": {
            "glass door": "Glassdoor",
            "glassdoor": "Glassdoor",  # identity mapping — should be skipped
        },
        "products": {
            "super match": "SuperMatch",
            "supermatters": "SuperMatch",
        },
        "people": {
            "Aaron Delevic": "Aron Delevic",
            "Julie Wilding": "Judith Wilding",
        },
        "domain_terms": {
            "agentic": "agentic",  # identity mapping — should be skipped
            "co-complete": "code complete",
        },
    }
    path = tmp_path / "corrections.json"
    path.write_text(json.dumps(data))
    return str(path)


# --- load_corrections tests ---


def test_load_corrections_flattens_categories(domain_corrections_mod, corrections_dict):
    """Categories are flattened into a single dict; _comment key is skipped."""
    corrections = domain_corrections_mod.load_corrections(corrections_dict)

    assert "glass door" in corrections
    assert "super match" in corrections
    assert "Aaron Delevic" in corrections
    assert "co-complete" in corrections
    # _comment category should be skipped entirely
    assert "_comment" not in corrections
    assert "Test dictionary" not in corrections.values()


def test_load_corrections_skips_identity_mappings(domain_corrections_mod, corrections_dict):
    """Entries where wrong.lower() == right.lower() are excluded."""
    corrections = domain_corrections_mod.load_corrections(corrections_dict)

    # "glassdoor" -> "Glassdoor" is identity (same lowercased)
    assert "glassdoor" not in corrections
    # "agentic" -> "agentic" is identity
    assert "agentic" not in corrections
    # "glass door" -> "Glassdoor" is NOT identity (different lowercased)
    assert "glass door" in corrections


# --- build_pattern tests ---


def test_build_pattern_word_boundaries(domain_corrections_mod):
    """Pattern matches whole words, not substrings."""
    pattern = domain_corrections_mod.build_pattern("glass door")

    assert pattern.search("the glass door here")
    assert pattern.search("a glass door.")
    # Should NOT match inside other words
    assert not pattern.search("hourglass doorway")


def test_build_pattern_case_insensitive(domain_corrections_mod):
    """Pattern matches regardless of case."""
    pattern = domain_corrections_mod.build_pattern("glass door")

    assert pattern.search("GLASS DOOR")
    assert pattern.search("Glass Door")
    assert pattern.search("glass door")


def test_build_pattern_regex_special_chars(domain_corrections_mod):
    r"""Regex metacharacters in the wrong string are escaped (don't break the regex).

    Note: \\b word boundaries require \\w/\\W transitions at both ends.
    Terms that start or end with non-word chars (like "C++") won't match
    properly. The real dictionary only contains terms that start and end
    with word characters, so this is the expected behavior.
    """
    # "jobs4you" has digits — should match as a word
    pattern = domain_corrections_mod.build_pattern("jobs4you")
    assert pattern.search("Check out jobs4you today")
    assert not pattern.search("Check out jobs4yourself")

    # Multi-word phrase with regex metachar in the middle — should not
    # crash or produce wrong matches due to unescaped special chars
    pattern = domain_corrections_mod.build_pattern("super.match")
    # The dot should be literal, not match any character
    assert pattern.search("about super.match here")
    assert not pattern.search("about supermatch here")


# --- apply_corrections tests ---


def test_apply_corrections_basic(domain_corrections_mod):
    """Basic correction replaces wrong with right."""
    corrections = {"glass door": "Glassdoor"}
    text = "I work at glass door in Austin."
    result, changes = domain_corrections_mod.apply_corrections(text, corrections)

    assert result == "I work at Glassdoor in Austin."
    assert len(changes) == 1
    assert changes[0] == ("glass door", "Glassdoor", 1)


def test_apply_corrections_longest_match_first(domain_corrections_mod):
    """Longer phrases match before shorter overlapping ones."""
    corrections = {
        "Aaron Delevic": "Aron Delevic",
        "Aaron": "WRONG",  # Should NOT match "Aaron" inside "Aaron Delevic"
    }
    text = "Aaron Delevic said hello to Aaron."
    result, changes = domain_corrections_mod.apply_corrections(text, corrections)

    assert "Aron Delevic" in result
    # The standalone "Aaron" at the end should match the shorter pattern
    assert result == "Aron Delevic said hello to WRONG."


def test_apply_corrections_case_insensitive_replacement(domain_corrections_mod):
    """Matches are case-insensitive but replacement uses the right-side casing."""
    corrections = {"glass door": "Glassdoor"}
    text = "GLASS DOOR is a company."
    result, _ = domain_corrections_mod.apply_corrections(text, corrections)

    assert result == "Glassdoor is a company."


def test_apply_corrections_multiple_occurrences(domain_corrections_mod):
    """Multiple occurrences in one text are all corrected."""
    corrections = {"glass door": "Glassdoor"}
    text = "glass door and glass door again."
    result, changes = domain_corrections_mod.apply_corrections(text, corrections)

    assert result == "Glassdoor and Glassdoor again."
    assert changes[0][2] == 2  # count


def test_apply_corrections_changes_list_accuracy(domain_corrections_mod):
    """Changes list reports (wrong, right, count) for each correction applied."""
    corrections = {
        "glass door": "Glassdoor",
        "super match": "SuperMatch",
    }
    text = "glass door uses super match for super match results."
    result, changes = domain_corrections_mod.apply_corrections(text, corrections)

    changes_dict = {wrong: (right, count) for wrong, right, count in changes}
    assert changes_dict["glass door"] == ("Glassdoor", 1)
    assert changes_dict["super match"] == ("SuperMatch", 2)


# --- Boundary / attack tests ---


def test_apply_corrections_empty_text(domain_corrections_mod):
    """Empty string returns empty string with no changes."""
    corrections = {"glass door": "Glassdoor"}
    result, changes = domain_corrections_mod.apply_corrections("", corrections)

    assert result == ""
    assert changes == []


def test_apply_corrections_empty_corrections(domain_corrections_mod):
    """Text is unchanged when corrections dict is empty."""
    text = "Hello glass door world."
    result, changes = domain_corrections_mod.apply_corrections(text, {})

    assert result == text
    assert changes == []


def test_apply_corrections_no_matches(domain_corrections_mod):
    """Text with no matching patterns passes through unchanged."""
    corrections = {"glass door": "Glassdoor"}
    text = "No relevant terms here at all."
    result, changes = domain_corrections_mod.apply_corrections(text, corrections)

    assert result == text
    assert changes == []


# --- Property-based tests (hypothesis) ---


@pytest.mark.skipif(not HAS_HYPOTHESIS, reason="hypothesis not installed")
@given(text=st.text(min_size=0, max_size=500))
@settings(max_examples=200)
def test_apply_corrections_idempotent(domain_corrections_mod, text):
    """Applying corrections twice gives the same result as applying once."""
    corrections = {
        "glass door": "Glassdoor",
        "super match": "SuperMatch",
        "co-complete": "code complete",
    }
    once, _ = domain_corrections_mod.apply_corrections(text, corrections)
    twice, _ = domain_corrections_mod.apply_corrections(once, corrections)
    assert once == twice, f"Not idempotent: '{once}' != '{twice}'"


@pytest.mark.skipif(not HAS_HYPOTHESIS, reason="hypothesis not installed")
@given(text=st.text(min_size=1, max_size=500))
@settings(max_examples=200)
def test_apply_corrections_deterministic(domain_corrections_mod, text):
    """Same input always produces same output."""
    corrections = {"glass door": "Glassdoor", "super match": "SuperMatch"}
    result1, changes1 = domain_corrections_mod.apply_corrections(text, corrections)
    result2, changes2 = domain_corrections_mod.apply_corrections(text, corrections)
    assert result1 == result2
    assert changes1 == changes2


@pytest.mark.skipif(not HAS_HYPOTHESIS, reason="hypothesis not installed")
@given(text=st.from_regex(r"[a-z]{1,20}( [a-z]{1,20}){0,10}", fullmatch=True))
@settings(max_examples=200)
def test_apply_corrections_noop_without_triggers(domain_corrections_mod, text):
    """Text containing only lowercase a-z words never triggers corrections
    that require specific multi-word phrases or capitalization patterns."""
    # These corrections require specific phrases that random a-z words won't match
    corrections = {
        "Aaron Delevic": "Aron Delevic",
        "Julie Wilding": "Judith Wilding",
    }
    # Filter out texts that accidentally contain a trigger
    assume("aaron delevic" not in text.lower())
    assume("julie wilding" not in text.lower())

    result, changes = domain_corrections_mod.apply_corrections(text, corrections)
    assert result == text
    assert changes == []
