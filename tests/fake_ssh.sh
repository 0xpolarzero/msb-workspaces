#!/bin/sh
set -eu
[ -n "${SILO_FAKE_LOG:-}" ] && printf 'ssh %s\n' "$*" >>"$SILO_FAKE_LOG"
exit 0
