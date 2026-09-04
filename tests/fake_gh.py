#!/usr/bin/env python3
"""Minimal gh(1) simulator for host-credential acquisition tests (host-proxy §5).

Driven by SILO_FAKE_GH_STATE (a JSON file):
  {"authed": true, "token": "gho_...", "account": "fake-user"}
- `gh auth status --active` exits 0 and prints a login line when authed, else 1.
  When `status_timeout` is true it exits 1 WITHOUT looking at authed, modeling
  the real `gh auth status` network round-trip timing out while the local
  keyring token stays readable (host-proxy §8 acquisition must not gate on it).
- `gh auth token` prints the token (only when authed).
Anything else exits 2.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> int:
    state_path = Path(os.environ.get("SILO_FAKE_GH_STATE", ""))
    if not state_path.is_file():
        state: dict = {"authed": False, "token": ""}
    else:
        try:
            state = json.loads(state_path.read_text())
        except (OSError, ValueError):
            state = {"authed": False, "token": ""}
    args = sys.argv[1:]
    if not args or args[0] != "auth":
        print("unsupported gh command", file=sys.stderr)
        return 2
    rest = args[1:]
    if rest[:2] == ["status", "--active"]:
        if state.get("status_timeout") or not state.get("authed"):
            return 1
        print(f"Logged in to github.com as {state.get('account', 'fake-user')}")
        return 0
    if rest[:1] == ["token"]:
        if not state.get("authed"):
            return 1
        token = state.get("token", "")
        if not token:
            return 1
        print(token)
        return 0
    print("unsupported gh auth command", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
