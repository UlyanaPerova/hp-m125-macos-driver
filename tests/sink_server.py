#!/usr/bin/env python3
"""Fake network printer for tests: accepts raw print jobs on a TCP port (like port 9100 of a
real printer) and saves each connection as job-N.pclm.

  sink_server.py PORT OUT_DIR
SPDX-License-Identifier: MIT
"""
import os
import socket
import sys

port, out = int(sys.argv[1]), sys.argv[2]
os.makedirs(out, exist_ok=True)
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(4)
n = 0
while True:
    conn, _ = srv.accept()
    n += 1
    tmp = os.path.join(out, "job-%03d.part" % n)
    with open(tmp, "wb") as f:
        while True:
            data = conn.recv(1 << 16)
            if not data:
                break
            f.write(data)
    conn.close()
    os.rename(tmp, os.path.join(out, "job-%03d.pclm" % n))
