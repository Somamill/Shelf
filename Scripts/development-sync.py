#!/usr/bin/env python3
"""Opt-in Mac source sync. Never reset, stash, push, or overwrite local work."""
import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

LABEL = 'app.shelf.development-sync'
REMOTE = 'https://github.com/Somamill/Shelf.git'


def command(args, cwd=None, capture=False, env=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None, env=env).stdout


def git(repo, *args):
    return command(['git', '-C', str(repo), *args], capture=True).strip()


def eligible(repo, remote):
    if git(repo, 'rev-parse', '--show-toplevel') != str(repo.resolve()):
        raise RuntimeError('Choose the checkout root, not a directory inside another repository.')
    if git(repo, 'remote', 'get-url', 'origin') != remote:
        raise RuntimeError('Unexpected origin; no source or local work was changed.')
    if git(repo, 'branch', '--show-current') != 'main':
        print('Paused: checkout is not on main.', flush=True)
        return False
    if git(repo, 'status', '--porcelain', '--untracked-files=normal'):
        print('Paused: commit or move local changes before automatic sync.', flush=True)
        return False
    return True


def build(repo):
    command(['/usr/bin/python3', '-m', 'unittest', 'discover', '-s', 'Tests/Python', '-v'], cwd=repo)
    if shutil.which('node'):
        command(['node', '--check', 'Resources/Dashboard/app.js'], cwd=repo)
    env = dict(os.environ, SHELF_DEVELOPMENT_BUILD='1', SHELF_SIGNING_IDENTITY='-',
               SHELF_APPLICATIONS_DIR=str(Path.home() / 'Applications'))
    command(['bash', 'Scripts/build-and-install.sh'], cwd=repo, env=env)


def sync(repo, state, remote=REMOTE, builder=build):
    repo = repo.resolve()
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / 'sync.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Another development sync is running.', flush=True)
            return False
        if not eligible(repo, remote):
            return False
        command(['git', '-C', str(repo), 'fetch', '--no-tags', 'origin',
                 'refs/heads/main:refs/remotes/origin/main'])
        head = git(repo, 'rev-parse', 'HEAD')
        target = git(repo, 'rev-parse', 'refs/remotes/origin/main')
        if head != target:
            ancestry = subprocess.run(['git', '-C', str(repo), 'merge-base', '--is-ancestor', head, target])
            if ancestry.returncode == 1:
                print('Paused: main contains local commits or has diverged. Reconcile it manually.', flush=True)
                return False
            ancestry.check_returncode()
            # Check again after the network operation before touching the working tree.
            if not eligible(repo, remote) or git(repo, 'rev-parse', 'HEAD') != head:
                return False
            command(['git', '-C', str(repo), 'merge', '--ff-only', target])
        marker = state / 'installed-commit'
        app = Path.home() / 'Applications/Shelf Dev.app'
        if marker.exists() and marker.read_text().strip() == target and app.exists():
            print('Shelf Dev is current.', flush=True)
            return True
        if not eligible(repo, remote) or git(repo, 'rev-parse', 'HEAD') != target:
            return False
        builder(repo)
        if not eligible(repo, remote) or git(repo, 'rev-parse', 'HEAD') != target:
            print('Checkout changed during build; leaving the installed-commit marker unset.', flush=True)
            return False
        temporary = state / 'installed-commit.tmp'
        temporary.write_text(target + '\n')
        temporary.replace(marker)
        print('Built and opened Shelf Dev at ' + target[:12], flush=True)
        return True


def agent(repo, state):
    return {
        'Label': LABEL,
        'ProgramArguments': ['/usr/bin/python3', str(state / 'development-sync.py'),
                             'sync', '--repo', str(repo), '--state', str(state)],
        'RunAtLoad': True, 'StartInterval': 300,
        'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                                 'GIT_TERMINAL_PROMPT': '0'},
        'StandardOutPath': str(state / 'sync.log'),
        'StandardErrorPath': str(state / 'sync-error.log'),
        'ProcessType': 'Background',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['setup', 'sync', 'stop'])
    parser.add_argument('--repo', type=Path, default=Path.home() / 'Developer/Shelf')
    parser.add_argument('--state', type=Path, default=Path.home() / 'Library/Application Support/Shelf/Development')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Run this command on macOS.')
    repo, state = args.repo.expanduser().resolve(), args.state.expanduser().resolve()
    service = 'gui/' + str(os.getuid())
    plist = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
    if args.action == 'stop':
        subprocess.run(['launchctl', 'bootout', service + '/' + LABEL], check=False)
        plist.unlink(missing_ok=True)
        print('Automatic source sync stopped. Checkout and app are preserved.')
    elif args.action == 'setup':
        if not sync(repo, state):
            raise RuntimeError('Resolve the paused condition, then rerun setup. No agent was installed.')
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        destination = state / 'development-sync.py'
        if Path(__file__).resolve() != destination:
            shutil.copyfile(__file__, destination)
        os.chmod(destination, 0o700)
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(plistlib.dumps(agent(repo, state)))
        os.chmod(plist, 0o600)
        subprocess.run(['launchctl', 'bootout', service + '/' + LABEL], check=False)
        command(['launchctl', 'bootstrap', service, str(plist)])
        print('Installed: GitHub main is checked every five minutes while logged in.')
        print('Log: ' + str(state / 'sync.log'))
    else:
        if not sync(repo, state):
            sys.exit(2)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print('Development sync stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
