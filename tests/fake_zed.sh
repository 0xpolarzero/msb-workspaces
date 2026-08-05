#!/bin/sh
set -eu
[ -n "${MSW_FAKE_LOG:-}" ] && printf 'zed %s\n' "$*" >>"$MSW_FAKE_LOG"
exit 0
