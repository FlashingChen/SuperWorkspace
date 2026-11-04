#!/usr/bin/env python3
"""Check publishable files without printing sensitive matching values.

Default: tracked and non-ignored files in the working tree.
--ref REV: exactly the files in a committed Git tree.
This is a mechanical check; manual content and history review are still required.
"""
import argparse
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument('--ref', help='Audit a committed tree instead of working files')
ARGS = PARSER.parse_args()

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])

if ARGS.ref:
    names = git('ls-tree', '-r', '--name-only', '-z', ARGS.ref).split(b'\0')
else:
    names = git('ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')

checks = {
    'host-specific home path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+'),
    'email address': re.compile(r'[\w.+%-]+@[\w.-]+\.[A-Za-z]{2,}'),
    'credential-like value': re.compile(r'\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b'),
    'private key': re.compile(r'-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----'),
    'literal IPv4 address': re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
    'literal UUID': re.compile(r'\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b'),
}
public_hosts = {'github.com', 'www.apple.com', 'www.w3.org', 'ffmpeg.org'}
blocked_suffixes = {'.pem', '.key', '.p12', '.pfx', '.db', '.sqlite', '.sqlite3',
                    '.log', '.wav', '.mp3', '.mp4', '.mov', '.srt', '.vtt', '.dogscproject'}
failures = []
count = 0
for raw in sorted(set(names)):
    if not raw:
        continue
    name = raw.decode('utf-8')
    path = Path(name)
    if path.suffix.lower() in blocked_suffixes or any(part in {'.build', 'dogsc-source', 'audio'} for part in path.parts) or path.name.startswith('.env'):
        failures.append(f'{name}: prohibited file type or directory')
        continue
    if not ARGS.ref and (ROOT / path).is_symlink():
        failures.append(f'{name}: symbolic link requires manual review')
        continue
    data = git('show', f'{ARGS.ref}:{name}') if ARGS.ref else (ROOT / path).read_bytes()
    count += 1
    if name == 'docs/assets/icon.png' and data.startswith(b'\x89PNG\r\n\x1a\n'):
        offset = 8
        while offset + 12 <= len(data):
            length = int.from_bytes(data[offset:offset + 4], 'big')
            kind = data[offset + 4:offset + 8]
            if kind in {b'tEXt', b'iTXt', b'zTXt', b'eXIf'}:
                failures.append(f'{name}: embedded metadata requires review')
            offset += length + 12
        continue
    try:
        content = data.decode('utf-8')
    except UnicodeDecodeError:
        failures.append(f'{name}: unapproved binary asset')
        continue
    for number, line in enumerate(content.splitlines(), 1):
        for label, pattern in checks.items():
            if pattern.search(line):
                failures.append(f'{name}:{number}: {label}')
        for url in re.findall(r'https?://[^\s<>\)\]"\']+', line):
            if urlsplit(url).hostname not in public_hosts:
                failures.append(f'{name}:{number}: unreviewed URL host')
if failures:
    print('\n'.join(failures))
    raise SystemExit('Public-content check failed; matching values withheld.')
print(f'Public-content check passed: {count} files. Manual content and reachable-history review required.')
