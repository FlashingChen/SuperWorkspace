#!/usr/bin/env python3
"""Sign builds with a persistent identity or explicit ad-hoc signing."""
from pathlib import Path
import os
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1])
entitlements = root / 'Resources' / 'SuperWorkspace.entitlements'
if os.environ.get('SUPERWORKSPACE_SIGNING') == 'adhoc':
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Signed ad hoc. This build is not notarized.')
    raise SystemExit(0)

explicit = os.environ.get('CODE_SIGN_IDENTITY', '')
identities = [explicit] if explicit else []
if not explicit:
    result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                            capture_output=True, text=True, check=True)
    available = re.findall(r'\) ([0-9A-F]{40}) "([^"]+)"', result.stdout)
    for prefix in ('Developer ID Application:', 'Apple Development:', 'Mac Developer:'):
        identities.extend(fingerprint for fingerprint, name in available if name.startswith(prefix))
if not identities:
    raise SystemExit('No persistent signing identity available. Set CODE_SIGN_IDENTITY to a local code-signing certificate.')
for identity in identities:
    signing = subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp=none',
        '--entitlements', str(entitlements),
        '--sign', identity, str(app)], capture_output=True, text=True)
    if signing.returncode:
        if explicit:
            raise SystemExit('The selected identity could not sign the application.')
        continue
    assessment = subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)],
                                capture_output=True, text=True)
    verdict = (assessment.stdout + assessment.stderr).upper()
    if any(word in verdict for word in ('CERT_REVOKED', 'CERT_EXPIRED', 'CERTIFICATE REVOKED', 'CERTIFICATE EXPIRED')):
        print('Skipped a revoked or expired signing identity.', file=sys.stderr)
        continue
    if assessment.returncode and 'UNNOTARIZED DEVELOPER ID' not in verdict:
        print('Skipped an identity rejected by system signing policy.', file=sys.stderr)
        continue
    # Local development bundles may be unnotarized; never override Gatekeeper
    # settings or quarantine. The OS remains responsible for launch policy.
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Signed with a persistent local identity; certificate revocation check passed.')
    break
else:
    raise SystemExit('No usable signing identity found; installation was not attempted.')
