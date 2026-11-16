#!/usr/bin/env python3
"""Scrub Deezer session secrets from every text file under a directory, in place.

usage: redact.py <dir> [known-secret...]

The app logs the ARL, SID, JWT and refresh token at debug level, so logs
collected after a login must never be shared before this runs.
"""
import os
import re
import sys

PATTERNS = [
    (re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"), "[REDACTED_JWT]"),
    (re.compile(r"\b[0-9a-fA-F]{64,}\b"), "[REDACTED_HEX]"),
    (re.compile(r"\bfr[0-9a-f]{30,}\b"), "[REDACTED_SID]"),
    (re.compile(r"(autolog/)[^/\s\"'\[\]]+"), r"\1[REDACTED]"),
    (re.compile(r"\b((?:arl|sid|jwt|refresh_?token|refreshToken|ARL|SID)[\"']?\s*[:=]\s*[\"']?)[^\"',;}\s]{12,}"),
     r"\1[REDACTED]"),
    (re.compile(r"(User autolog result:).*"), r"\1 [REDACTED]"),
]


def scrub(text, secrets):
    for s in secrets:
        text = text.replace(s, "[REDACTED]")
    for pattern, repl in PATTERNS:
        text = pattern.sub(repl, text)
    return text


def main():
    root, secrets = sys.argv[1], [s for s in sys.argv[2:] if s]
    for dirpath, _, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as f:
                    text = f.read()
            except (UnicodeDecodeError, OSError):
                continue  # binary (screenshots) or unreadable
            clean = scrub(text, secrets)
            if clean != text:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(clean)


if __name__ == "__main__":
    main()
