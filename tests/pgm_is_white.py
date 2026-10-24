#!/usr/bin/env python3
"""Print "white" if a binary PGM (P5) image has no ink, else "ink". SPDX-License-Identifier: MIT"""
import re
import sys
data = open(sys.argv[1], "rb").read()
m = re.match(rb"P5\s+\d+\s+\d+\s+\d+\s", data)   # header ends with exactly one whitespace byte
pixels = data[m.end():] if m else b""
print("white" if pixels and pixels.count(255) == len(pixels) else "ink")
