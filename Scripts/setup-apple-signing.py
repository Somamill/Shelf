#!/usr/bin/env python3
"""Configure private GitHub signing secrets after validating Apple's credentials.

Run in Terminal. No account password, signing key, or export enters the repository.
"""
import base64
import getpass
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = 'Somamill/Shelf'
NAMES = ('APPLE_ID', 'APPLE_TEAM_ID', 'APPLE_APP_SPECIFIC_PASSWORD',
         'APPLE_CERTIFICATE_PASSWORD', 'APPLE_CERTIFICATE_BASE64')


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs)


def main():
    run(['gh', 'api', f'repos/{REPOSITORY}/actions/secrets/public-key'])
    identities = json.loads(run(['swift', str(ROOT/'Scripts/export-developer-id.swift')], text=True).stdout)
    configured = json.loads(run(['gh', 'secret', 'list', '--repo', REPOSITORY, '--json', 'name'], text=True).stdout)
    present = {item['name'] for item in configured}
    print('GitHub connection: ready')
    print('Developer ID identities:', len(identities))
    for name in NAMES:
        print(name + ': ' + ('configured' if name in present else 'missing'))
    if '--check' in sys.argv:
        return 0 if identities and all(name in present for name in NAMES) else 1
    if not identities:
        raise ValueError('In Xcode → Settings → Apple Accounts, select your paid team → Manage Certificates → + → Developer ID Application. Personal Team cannot create this certificate. Then rerun this assistant.')
    if not sys.stdin.isatty():
        raise ValueError('Run this assistant in an interactive Terminal; do not paste credentials into chat.')
    for item in identities:
        print(item['index'] + ': ' + item['name'])
    selection = input('Certificate number [0]: ').strip() or '0'
    chosen = next((item for item in identities if item['index'] == selection), None)
    if chosen is None:
        raise ValueError('Unknown certificate number')
    team = re.search(r'\(([A-Z0-9]{10})\)$', chosen['name'])
    if not team:
        raise ValueError('Cannot determine the team from the selected Developer ID certificate')
    apple_id = input('Apple Account email for notarization: ').strip()
    if not apple_id or '@' not in apple_id:
        raise ValueError('Enter the Apple Account email, not a password')
    password = getpass.getpass('App-specific password from account.apple.com (hidden): ').strip()
    if not password:
        raise ValueError('No password entered; nothing changed')
    print('Validating notarization access with Apple…')
    # Capture output because notarytool can include private account details.
    run(['xcrun', 'notarytool', 'history', '--apple-id', apple_id,
         '--password', password, '--team-id', team[1], '--output-format', 'json'])
    export_password = secrets.token_urlsafe(32)
    with tempfile.TemporaryDirectory(prefix='shelf-apple-signing-') as temporary:
        os.chmod(temporary, 0o700)
        p12 = Path(temporary)/'developer-id.p12'
        run(['swift', str(ROOT/'Scripts/export-developer-id.swift'), selection, str(p12)],
            input=export_password, text=True)
        values = dict(APPLE_ID=apple_id, APPLE_TEAM_ID=team[1],
                      APPLE_APP_SPECIFIC_PASSWORD=password,
                      APPLE_CERTIFICATE_PASSWORD=export_password,
                      APPLE_CERTIFICATE_BASE64=base64.b64encode(p12.read_bytes()).decode())
        print('Apple access validated. Saving signing credentials to private GitHub Actions secrets…')
        for name in NAMES:
            run(['gh', 'secret', 'set', name, '--repo', REPOSITORY], input=values[name], text=True)
        run(['gh', 'variable', 'set', 'REQUIRE_APPLE_SIGNING', '--repo', REPOSITORY, '--body', 'true'])
    print('Ready: future releases will use Developer ID signing and Apple notarization. No private export was kept.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except subprocess.CalledProcessError:
        sys.exit('Signing setup failed. No secret was printed. Check GitHub access, the app-specific password, and your paid team’s notarization access; rerun safely.')
    except (ValueError, OSError) as exc:
        sys.exit(str(exc))
    except (KeyboardInterrupt, EOFError):
        sys.exit('Setup stopped. Rerun to finish configuring all signing secrets.')
