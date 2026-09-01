#!/usr/bin/env python3
"""Minimal curl(1) simulator for host_github_api tests (Path C §5).

The real host_github_api keeps the Bearer token out of the child argv by
passing `-H @-` (curl reads the header line from stdin — no tempfile, §5
hygiene). This simulator reads the header from stdin for `@-` (and still
supports `@file`), performs the request with stdlib urllib against the local
fake GitHub server, and prints the response body. HTTP responses (with a
body) exit 0 exactly like curl -sS without -f; connection failures exit 7.
This makes the CLI-side acquisition/verification tests exercise the same wire
path the proxy uses (SILO_PROXY_UPSTREAM_ROOT -> fake GitHub).
"""
from __future__ import annotations

import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def main() -> int:
    args = sys.argv[1:]
    argv_log = os.environ.get("SILO_FAKE_API_CURL_ARGV_LOG")
    if argv_log:
        with open(argv_log, "a") as fh:
            fh.write("|".join(args) + "\n")
    method = "GET"
    headers: dict[str, str] = {}
    form: dict[str, str] = {}
    url = ""
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "-X" and i + 1 < len(args):
            method = args[i + 1]
            i += 2
            continue
        if arg == "-H" and i + 1 < len(args):
            value = args[i + 1]
            if value == "@-":
                value = sys.stdin.read().strip()
            elif value.startswith("@"):
                path = Path(value[1:])
                if path.is_file():
                    value = path.read_text().strip()
            if ":" in value:
                name, _, val = value.partition(":")
                headers[name.strip()] = val.strip()
            i += 2
            continue
        if arg == "--data-urlencode" and i + 1 < len(args):
            pair = args[i + 1]
            if "=" in pair:
                key, _, val = pair.partition("=")
                form[key] = val
            i += 2
            continue
        if arg.startswith("http://") or arg.startswith("https://"):
            url = arg
        i += 1
    if not url:
        print("fake api curl: no URL", file=sys.stderr)
        return 2
    body: bytes | None = None
    if form:
        body = urllib.parse.urlencode(form).encode("utf-8")
        headers.setdefault("Content-Type", "application/x-www-form-urlencoded")
    req = urllib.request.Request(url, method=method, headers=headers, data=body)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            sys.stdout.write(resp.read().decode("utf-8", "replace"))
        return 0
    except urllib.error.HTTPError as exc:
        sys.stdout.write(exc.read().decode("utf-8", "replace"))
        return 0
    except OSError:
        return 7


if __name__ == "__main__":
    raise SystemExit(main())
