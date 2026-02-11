#!/usr/bin/env python3
"""Save meeting metadata from MeetingBar event data to JSON.

Called by eventStartScript.scpt with MeetingBar's 11 event parameters.
The metadata file is read by quicktime-stop-recording.applescript for
file naming and by transcribe-and-process.sh for meeting note frontmatter.
"""
import json
import sys


def clean_value(val):
    """MeetingBar returns 'EMPTY' for missing fields."""
    return "" if val == "EMPTY" else val


def main():
    if len(sys.argv) < 10:
        print(
            "Usage: save-meeting-metadata.py eventId title startDate startTime "
            "location attendeeCount meetingUrl meetingService meetingNotes",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        attendee_count = int(sys.argv[6])
    except (ValueError, IndexError):
        attendee_count = 0

    data = {
        "eventId": sys.argv[1],
        "title": sys.argv[2],
        "startDate": sys.argv[3],
        "startTime": sys.argv[4],
        "location": clean_value(sys.argv[5]),
        "attendeeCount": attendee_count,
        "meetingUrl": clean_value(sys.argv[7]),
        "meetingService": clean_value(sys.argv[8]),
        "meetingNotes": clean_value(sys.argv[9]),
    }

    with open("/tmp/meeting-recorder-metadata.json", "w") as f:
        json.dump(data, f, indent=2)


if __name__ == "__main__":
    main()
