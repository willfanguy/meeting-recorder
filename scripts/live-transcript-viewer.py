#!/usr/bin/env python3
"""Persistent HTTP server that serves live meeting transcripts with auto-refresh.

Reads raw SRT output from yap (via `script` PTY), strips control characters,
and renders as timestamped lines in a dark-themed browser page.

Meeting boundaries are marked by lines in the transcript file:
  --- MEETING START: Title @ 2026-04-16 13:00 ---
  --- MEETING END ---

Only content after the last MEETING START marker is shown. Between meetings
(no marker, or last marker is END), an idle message is displayed.
"""

import html
import http.server
import os
import re
import sys

TRANSCRIPT_FILE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/live-transcript.txt"
PORT = 8234

MEETING_START_RE = re.compile(r"^--- MEETING START: (.+?) @ .+ ---$")
MEETING_END_RE = re.compile(r"^--- MEETING END ---$")

HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
  body {{
    font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
    background: #1a1a2e;
    color: #e0e0e0;
    padding: 24px 32px;
    font-size: 15px;
    line-height: 1.7;
    margin: 0;
  }}
  h1 {{
    color: #7c83ff;
    font-size: 14px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 1px;
    margin: 0 0 16px 0;
    padding-bottom: 8px;
    border-bottom: 1px solid #2a2a4a;
  }}
  .line {{
    padding: 3px 0;
  }}
  .timestamp {{
    color: #5a5a8a;
    font-size: 12px;
    font-family: 'SF Mono', Menlo, monospace;
    margin-right: 10px;
    user-select: none;
  }}
  .empty {{
    color: #5a5a8a;
    font-style: italic;
  }}
  #bottom {{ height: 1px; }}
</style>
</head>
<body>
<h1>{heading}</h1>
<div id="content">{content}</div>
<div id="bottom"></div>
<script>
  let wasAtBottom = true;
  function isNearBottom() {{
    return (window.innerHeight + window.scrollY) >= document.body.scrollHeight - 50;
  }}
  let lastLen = 0;
  async function refresh() {{
    wasAtBottom = isNearBottom();
    try {{
      const resp = await fetch('/content');
      const text = await resp.text();
      if (text.length !== lastLen) {{
        lastLen = text.length;
        document.getElementById('content').innerHTML = text;
        if (wasAtBottom) window.scrollTo(0, document.body.scrollHeight);
      }}
    }} catch(e) {{}}
    requestAnimationFrame(() => setTimeout(refresh, 300));
  }}
  refresh();
</script>
</body>
</html>"""

IDLE_MSG = '<p class="empty">No active meeting — transcript will appear when a meeting starts</p>'


def parse_srt(raw: str) -> list[tuple[str, str]]:
    """Parse raw SRT (with possible control chars) into [(timestamp, text), ...]."""
    # Strip control characters from PTY artifacts
    raw = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", raw)
    lines = raw.split("\n")
    segments = []
    current_ts = ""
    for line in lines:
        line = line.strip("\r").strip()
        if not line:
            continue
        # Skip sequence numbers
        if re.match(r"^\d+$", line):
            continue
        # Timestamp line
        m = re.match(r"(\d{2}):(\d{2}):(\d{2}),\d+\s*-->", line)
        if m:
            h, mn, s = m.groups()
            current_ts = f"{mn}:{s}" if h == "00" else f"{h}:{mn}:{s}"
            continue
        # Text line
        if current_ts:
            segments.append((current_ts, line))
    return segments


def get_active_meeting_content(raw: str) -> tuple[str | None, str]:
    """Find the last MEETING START marker and return (meeting_name, content_after_marker).

    Returns (None, "") if no active meeting (no marker, or last marker is END).
    """
    lines = raw.split("\n")

    # Walk backwards to find the last marker
    last_start_idx = None
    meeting_name = None
    for i in range(len(lines) - 1, -1, -1):
        stripped = lines[i].strip()
        if MEETING_END_RE.match(stripped):
            # Last marker is END — no active meeting
            return None, ""
        m = MEETING_START_RE.match(stripped)
        if m:
            last_start_idx = i
            meeting_name = m.group(1)
            break

    if last_start_idx is None:
        return None, ""

    # Return content after the start marker
    return meeting_name, "\n".join(lines[last_start_idx + 1:])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _read_content(self) -> tuple[str | None, str]:
        """Return (meeting_name, html_content)."""
        if not os.path.exists(TRANSCRIPT_FILE):
            return None, IDLE_MSG
        with open(TRANSCRIPT_FILE, "r", errors="replace") as f:
            raw = f.read()

        meeting_name, meeting_content = get_active_meeting_content(raw)
        if meeting_name is None:
            return None, IDLE_MSG

        segments = parse_srt(meeting_content)
        if not segments:
            return meeting_name, '<p class="empty">Listening...</p>'

        parts = []
        for ts, text in segments:
            ts_html = f'<span class="timestamp">{html.escape(ts)}</span>'
            parts.append(f'<div class="line">{ts_html}{html.escape(text)}</div>')
        return meeting_name, "\n".join(parts)

    def do_GET(self):
        meeting_name, content = self._read_content()
        if self.path == "/content":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(content.encode("utf-8"))
        else:
            title = f"Live: {meeting_name}" if meeting_name else "Live Transcript"
            heading = f"Live Transcript — {html.escape(meeting_name)}" if meeting_name else "Live Transcript"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            page = HTML_TEMPLATE.format(title=html.escape(title), heading=heading, content=content)
            self.wfile.write(page.encode("utf-8"))


if __name__ == "__main__":
    server = http.server.HTTPServer(("localhost", PORT), Handler)
    print(f"Live transcript viewer at http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
