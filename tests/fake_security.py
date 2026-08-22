#!/usr/bin/env python3
"""Minimal security(1) simulator for Keychain tests.

Supports the Path C §5 hygiene form `add-generic-password ... -w` with -w as
the LAST option: security(1)'s prompted mode reads the password from stdin,
so the simulator reads it from stdin too (never from argv). It records every
invocation's argv to MSW_FAKE_SECURITY_ARGV_LOG when set, so tests can prove
the token never appears in child argv.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path



ITEM_NOT_FOUND = 44
ITEM_NOT_FOUND_MESSAGE = (
    "security: SecKeychainSearchCopyNext: "
    "The specified item could not be found in the keychain."
)


def option(args: list[str], name: str) -> str:
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        raise SystemExit(f"missing {name}")


def option_index(args: list[str], name: str) -> int:
    try:
        return args.index(name)
    except ValueError:
        return -1


def main() -> int:
    state_path = Path(os.environ["MSW_FAKE_SECURITY_STATE"])
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    args = sys.argv[1:]
    argv_log = os.environ.get("MSW_FAKE_SECURITY_ARGV_LOG")
    if argv_log:
        with open(argv_log, "a") as fh:
            fh.write("|".join(args) + "\n")
    if not args:
        print("missing security command", file=sys.stderr)
        return 2

    command = args[0]
    service = option(args, "-s")
    account = option(args, "-a")
    key = f"{service}/{account}"
    mode = os.environ.get("MSW_FAKE_SECURITY_MODE", "normal")

    if command == "add-generic-password":
        # -w LAST => read the password from stdin (prompted mode); -w VALUE
        # (legacy Connect path) reads the following argv element.
        w_idx = option_index(args, "-w")
        if w_idx == -1:
            return 2
        if w_idx == len(args) - 1:
            # security(1)'s prompted mode reads one line per prompt; the
            # record is piped twice (password + retype), the first wins.
            value = sys.stdin.readline().rstrip("\n")
        else:
            value = args[w_idx + 1]
        state[key] = value
        state_path.write_text(json.dumps(state, sort_keys=True))
        return 0

    if command == "find-generic-password":
        expected_home = os.environ.get("MSW_FAKE_SECURITY_HOME")
        if expected_home and os.environ.get("HOME") != expected_home:
            print(ITEM_NOT_FOUND_MESSAGE, file=sys.stderr)
            return ITEM_NOT_FOUND
        if mode == "post-delete-lookup-failure":
            print("security: The keychain is locked.", file=sys.stderr)
            return 1
        if key in state:
            print(state[key])
            return 0
        print(ITEM_NOT_FOUND_MESSAGE, file=sys.stderr)
        return ITEM_NOT_FOUND

    if command == "delete-generic-password":
        if mode == "delete-failure":
            print("security: User interaction is not allowed.", file=sys.stderr)
            return 1
        if mode != "still-present":
            if key not in state:
                print(ITEM_NOT_FOUND_MESSAGE, file=sys.stderr)
                return ITEM_NOT_FOUND
            del state[key]
            state_path.write_text(json.dumps(state, sort_keys=True))
        return 0

    print(f"unsupported security command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
