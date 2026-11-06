#!/usr/bin/env python3
"""Deterministic time-window contract for the load-test triage.

The AI client never does date arithmetic itself: it calls this script and uses the JSON output verbatim
as the Loki query range. Everything else (relative phrases, missing offsets, wrong order, too-wide or
future windows) is rejected with a clear message, so the window used in a report is always explicit.

Usage:
  scripts/triage-window.py <from> <to>        both RFC3339 WITH offset, e.g. 2026-11-06T14:00:00+03:00 2026-11-06T14:35:00+03:00
  scripts/triage-window.py --last 15m         now-15m .. now  (units: m, h; max 12h)
  scripts/triage-window.py --date 2026-11-06 --from 14:00 --to 14:35 --tz +03:00
                                              wall-clock form for people who copy times from a test report

Output (stdout, single line):  {"from":"...Z","to":"...Z","minutes":N,"source":"explicit|last|wallclock"}
Exit code 0 on success, 2 on any validation error (message on stderr).
"""
import json
import re
import sys
from datetime import datetime, timedelta, timezone

MAX_MINUTES = 12 * 60
RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$")
OFFSET = re.compile(r"^[+-]\d{2}:\d{2}$")


def fail(msg):
    sys.stderr.write("triage-window: " + msg + "\n")
    sys.exit(2)


def parse_rfc3339(value, label):
    if not RFC3339.match(value):
        fail(f"{label}='{value}' is not RFC3339 with an explicit offset "
             "(expected e.g. 2026-11-06T14:00:00+03:00 or 2026-11-06T11:00:00Z; relative phrases like "
             "'son 15 dk' are not accepted here - use --last 15m)")
    v = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        return datetime.fromisoformat(v)
    except ValueError as e:
        fail(f"{label}='{value}': {e}")


def parse_offset(tz):
    if not OFFSET.match(tz):
        fail(f"--tz '{tz}' must look like +03:00")
    sign = 1 if tz[0] == "+" else -1
    return timezone(sign * timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6])))


def emit(start, end, source):
    now = datetime.now(timezone.utc)
    start, end = start.astimezone(timezone.utc), end.astimezone(timezone.utc)
    if end <= start:
        fail(f"'to' ({end.isoformat()}) must be after 'from' ({start.isoformat()})")
    minutes = (end - start).total_seconds() / 60
    if minutes > MAX_MINUTES:
        fail(f"window is {minutes:.0f} minutes; maximum is {MAX_MINUTES} (narrow it or split the triage)")
    if start > now + timedelta(minutes=5):
        fail(f"'from' ({start.isoformat()}) is in the future")
    fmt = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
    print(json.dumps({"from": fmt(start), "to": fmt(min(end, now)), "minutes": round(minutes), "source": source}))


def main(argv):
    if len(argv) == 2 and argv[0] == "--last":
        m = re.fullmatch(r"(\d+)([mh])", argv[1])
        if not m:
            fail(f"--last '{argv[1]}' must be like 15m or 2h")
        n = int(m.group(1)) * (60 if m.group(2) == "h" else 1)
        if n <= 0:
            fail("--last must be positive")
        now = datetime.now(timezone.utc).replace(microsecond=0)
        return emit(now - timedelta(minutes=n), now, "last")
    if argv and argv[0] == "--date":
        opts = dict(zip(argv[0::2], argv[1::2]))
        for k in ("--date", "--from", "--to", "--tz"):
            if k not in opts:
                fail(f"wall-clock form needs --date YYYY-MM-DD --from HH:MM --to HH:MM --tz +03:00 (missing {k})")
        tz = parse_offset(opts["--tz"])
        try:
            d = datetime.strptime(opts["--date"], "%Y-%m-%d")
            f = datetime.strptime(opts["--from"], "%H:%M").time()
            t = datetime.strptime(opts["--to"], "%H:%M").time()
        except ValueError as e:
            fail(str(e))
        return emit(datetime.combine(d, f, tz), datetime.combine(d, t, tz), "wallclock")
    if len(argv) == 2:
        return emit(parse_rfc3339(argv[0], "from"), parse_rfc3339(argv[1], "to"), "explicit")
    fail("usage: <from> <to> | --last 15m | --date YYYY-MM-DD --from HH:MM --to HH:MM --tz +03:00")


if __name__ == "__main__":
    main(sys.argv[1:])
