#!/usr/bin/env python3
"""Minimal security(1) simulator for Keychain deletion error-path tests."""
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


def main() -> int:
    state_path = Path(os.environ["MSW_FAKE_SECURITY_STATE"])
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    args = sys.argv[1:]
    if not args:
        print("missing security command", file=sys.stderr)
        return 2

    command = args[0]
    service = option(args, "-s")
    account = option(args, "-a")
    key = f"{service}/{account}"
    mode = os.environ.get("MSW_FAKE_SECURITY_MODE", "normal")

    if command == "add-generic-password":
        state[key] = option(args, "-w")
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
