#!/usr/bin/python3
"""Fake long-running ssh for lib/silo-port-forwarder.py tests.

Records each invocation (argv) to SILO_FAKE_SSH_LOG, writes its PID to
SILO_FAKE_SSH_PIDFILE, then sleeps until killed (like a real `ssh -N` tunnel).
With SILO_FAKE_SSH_EXIT=1 it exits immediately (simulating an unavailable ssh
binary / an ssh that cannot connect).
"""
import os
import signal
import socket
import sys
import time

log_path = os.environ.get("SILO_FAKE_SSH_LOG", "")
if log_path:
    with open(log_path, "a") as f:
        f.write(" ".join(sys.argv) + "\n")

pid_path = os.environ.get("SILO_FAKE_SSH_PIDFILE", "")
if pid_path:
    with open(pid_path, "w") as f:
        f.write(str(os.getpid()) + "\n")

if os.environ.get("SILO_FAKE_SSH_EXIT") == "1":
    sys.exit(255)

listeners = []
args = sys.argv[1:]
transaction = os.environ.get("SILO_PORT_FORWARDER_TRANSACTION") == "1"
for index, arg in enumerate(args):
    if arg != "-L" or index + 1 >= len(args):
        continue
    # Candidate-networking tests use names whose loopback aliases are owned by
    # the native host coordinator. This fake proves ssh process liveness; the
    # dedicated forwarding tests exercise real bind behavior separately.
    if transaction:
        continue
    bind_ip, port, _remote_ip, _remote_port = args[index + 1].split(":", 3)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind((bind_ip, int(port)))
        listener.listen(1)
    except OSError:
        listener.close()
        if "ExitOnForwardFailure=yes" in args:
            sys.exit(255)
        continue
    listeners.append(listener)


def stop(_signum, _frame):
    for listener in listeners:
        listener.close()
    sys.exit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(3600)
