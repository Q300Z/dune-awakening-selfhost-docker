"""Filter bounded Docker/Podman output after all supplied process-generation starts."""
from datetime import datetime
import re
import sys

TS_RE = re.compile(
    r"^(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?\s*(Z|[+-]\d\d:?\d\d)(?:\s+[A-Za-z0-9_+-]+)?$"
)

def timestamp(value):
    match = TS_RE.fullmatch(value.strip())
    if not match:
        raise ValueError("Invalid Docker timestamp")
    date_part, time_part, frac_part, tz_part = match.groups()
    if tz_part == "Z":
        tz_iso = "+00:00"
    elif ":" in tz_part:
        tz_iso = tz_part
    else:
        tz_iso = tz_part[:3] + ":" + tz_part[3:]
    seconds = datetime.fromisoformat(f"{date_part}T{time_part}{tz_iso}")
    return int(seconds.timestamp()), int((frac_part or "").ljust(9, "0")[:9])


def main():
    start = max(timestamp(value) for value in sys.argv[1:])
    for line in sys.stdin:
        stamp, separator, message = line.partition(" ")
        if not separator:
            continue
        try:
            current = timestamp(stamp)
        except ValueError:
            continue
        if current >= start:
            sys.stdout.write(message)


if __name__ == "__main__":
    main()
