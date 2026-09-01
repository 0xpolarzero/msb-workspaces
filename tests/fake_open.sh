#!/bin/sh
set -eu
[ -n "${SILO_FAKE_LOG:-}" ] && printf 'open %s\n' "$*" >>"$SILO_FAKE_LOG"
exit 0
