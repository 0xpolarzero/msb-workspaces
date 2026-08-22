#!/usr/bin/python3
"""Fake long-running ssh for lib/msw-port-forwarder.py tests.

Records each invocation (argv) to MSW_FAKE_SSH_LOG, writes its PID to
MSW_FAKE_SSH_PIDFILE, then sleeps until killed (like a real `ssh -N` tunnel).
With MSW_FAKE_SSH_EXIT=1 it exits immediately (simulating an unavailable ssh
binary / an ssh that cannot connect).
"""
import os
import sys
import time

log_path = os.environ.get("MSW_FAKE_SSH_LOG", "")
if log_path:
    with open(log_path, "a") as f:
        f.write(" ".join(sys.argv) + "\n")

pid_path = os.environ.get("MSW_FAKE_SSH_PIDFILE", "")
if pid_path:
    with open(pid_path, "w") as f:
        f.write(str(os.getpid()) + "\n")

if os.environ.get("MSW_FAKE_SSH_EXIT") == "1":
    sys.exit(0)

while True:
    time.sleep(3600)
