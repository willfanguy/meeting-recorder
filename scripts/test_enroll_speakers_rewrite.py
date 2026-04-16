"""Tests for _rewrite_speaker_id_section() in enroll-speakers.py.

This function rewrites the Speaker Identification section of an Obsidian meeting
note after speakers are enrolled: removes enrolled rows from the table, adds an
enrolled summary, and removes the enrollment code block.
"""


# --- Fixtures ---


SAMPLE_NOTE = """\
---
title: "Team Standup"
date: 2026-04-16
---

## Summary

The team discussed sprint progress.

### Speaker Identification

| Label | Likely Identity | Confidence | Context |
|-------|----------------|------------|---------|
| Speaker A | Will Fanguy | 0.92 | Project lead |
| Speaker B | Judith Wilding | 0.87 | Design lead |
| Speaker C | Unknown | 0.45 | Brief appearance |

```
To enroll identified speakers, run:
scripts/.venv/bin/python scripts/enroll-speakers.py --assign "Speaker A=Will Fanguy"
```

### Transcript

Speaker A: Hello everyone.
Speaker B: Hi there.
"""


SAMPLE_NOTE_H2 = """\
---
title: "Team Standup"
---

## Speaker Identification

| Label | Likely Identity | Confidence | Context |
|-------|----------------|------------|---------|
| Speaker A | Will Fanguy | 0.92 | Project lead |

## Transcript

Hello everyone.
"""


# --- Tests ---


def test_rewrite_removes_enrolled_rows(enroll_speakers_mod):
    """Enrolled speakers are removed from the table; unidentified remain."""
    assignments = {"Speaker A": "Will Fanguy", "Speaker B": "Judith Wilding"}
    result, changed = enroll_speakers_mod._rewrite_speaker_id_section(SAMPLE_NOTE, assignments)

    assert changed is True
    # Speaker C should remain in the output (not enrolled)
    assert "Speaker C" in result
    # Enrolled speakers should NOT appear as table rows
    # (they appear in the enrolled summary instead)
    assert "**Enrolled:** Will Fanguy (Speaker A), Judith Wilding (Speaker B)" in result


def test_rewrite_adds_enrolled_summary(enroll_speakers_mod):
    """The output contains an enrolled summary line."""
    assignments = {"Speaker A": "Will Fanguy"}
    result, changed = enroll_speakers_mod._rewrite_speaker_id_section(SAMPLE_NOTE, assignments)

    assert changed is True
    assert "**Enrolled:** Will Fanguy (Speaker A)" in result


def test_rewrite_preserves_content_outside_section(enroll_speakers_mod):
    """Content before and after the Speaker Identification section is unchanged."""
    assignments = {"Speaker A": "Will Fanguy"}
    result, _ = enroll_speakers_mod._rewrite_speaker_id_section(SAMPLE_NOTE, assignments)

    assert "## Summary" in result
    assert "The team discussed sprint progress." in result
    assert "### Transcript" in result
    assert "Speaker A: Hello everyone." in result


def test_rewrite_handles_missing_section(enroll_speakers_mod):
    """Returns (content, False) when no Speaker Identification heading exists."""
    content = "# Meeting\n\nJust a regular note with no speaker section.\n"
    result, changed = enroll_speakers_mod._rewrite_speaker_id_section(
        content, {"Speaker A": "Will"}
    )

    assert changed is False
    assert result == content


def test_rewrite_handles_h2_heading(enroll_speakers_mod):
    """Works with ## Speaker Identification (not just ###)."""
    assignments = {"Speaker A": "Will Fanguy"}
    result, changed = enroll_speakers_mod._rewrite_speaker_id_section(SAMPLE_NOTE_H2, assignments)

    assert changed is True
    assert "**Enrolled:** Will Fanguy (Speaker A)" in result
    # Content after the section boundary should be preserved
    assert "## Transcript" in result
    assert "Hello everyone." in result


def test_rewrite_all_speakers_enrolled(enroll_speakers_mod):
    """When all speakers are enrolled, no remaining-speakers table is shown."""
    assignments = {
        "Speaker A": "Will Fanguy",
        "Speaker B": "Judith Wilding",
        "Speaker C": "Thomas Murphy",
    }
    result, changed = enroll_speakers_mod._rewrite_speaker_id_section(SAMPLE_NOTE, assignments)

    assert changed is True
    assert "**Enrolled:**" in result
    # No "Remaining unidentified speakers" header should appear
    assert "Remaining unidentified" not in result


def test_rewrite_removes_enroll_codeblock(enroll_speakers_mod):
    """The 'To enroll' code block is removed from the section."""
    assignments = {"Speaker A": "Will Fanguy"}
    result, _ = enroll_speakers_mod._rewrite_speaker_id_section(SAMPLE_NOTE, assignments)

    assert "To enroll identified speakers" not in result
    assert "enroll-speakers.py --assign" not in result
