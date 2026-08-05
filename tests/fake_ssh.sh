#!/bin/sh
set -eu
[ -n "${MSW_FAKE_LOG:-}" ] && printf 'ssh %s\n' "$*" >>"$MSW_FAKE_LOG"
exit 0
