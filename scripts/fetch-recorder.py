#!/usr/bin/env python3
"""Fetch the tested recorder revision without replacing an existing checkout."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'dogsc-source'
UPSTREAM = 'https://github.com/laogou717/dogsc.git'
REVISION = '567fd6ed3bf113227dcf3e815f87ce60f0b69497'

if not SOURCE.exists():
    subprocess.run(['git', 'clone', '--no-checkout', '--filter=blob:none', UPSTREAM, str(SOURCE)], check=True)
    subprocess.run(['git', '-C', str(SOURCE), 'checkout', '--detach', REVISION], check=True)

head = subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip()
if head != REVISION:
    raise SystemExit('Recorder revision differs from the tested version; existing checkout left unchanged.')
if subprocess.check_output(['git', '-C', str(SOURCE), 'status', '--porcelain'], text=True).strip():
    raise SystemExit('Recorder checkout has local changes; existing files left unchanged.')
print('Recorder source matches the pinned revision.')
