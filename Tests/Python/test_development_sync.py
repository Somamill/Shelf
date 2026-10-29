import importlib.util
import fcntl
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('development_sync', Path(__file__).resolve().parents[2] / 'Scripts/development-sync.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class DevelopmentSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote, self.author, self.repo = [self.root / x for x in ('origin.git', 'author', 'checkout')]
        self.run_git('init', '--bare', '--initial-branch=main', str(self.remote))
        self.run_git('clone', str(self.remote), str(self.author))
        self.run_git('-C', str(self.author), 'config', 'user.name', 'Test')
        self.run_git('-C', str(self.author), 'config', 'user.email', 'test@example.invalid')
        self.publish('initial')
        self.run_git('clone', str(self.remote), str(self.repo))
        self.state = self.root / 'state'
        self.builds = []
        self.home = patch.object(sync.Path, 'home', return_value=self.root)
        self.home.start()
        self.addCleanup(self.home.stop)

    def run_git(self, *args):
        return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout.strip()

    def publish(self, content):
        (self.author / 'source').write_text(content)
        self.run_git('-C', str(self.author), 'add', 'source')
        self.run_git('-C', str(self.author), 'commit', '-m', content)
        self.run_git('-C', str(self.author), 'push', 'origin', 'main')

    def builder(self, repo):
        self.builds.append(sync.git(repo, 'rev-parse', 'HEAD'))
        (self.root / 'Applications/Shelf Dev.app').mkdir(parents=True, exist_ok=True)

    def perform(self, builder=None):
        return sync.sync(self.repo, self.state, str(self.remote), builder or self.builder)

    def test_first_build_fast_forward_and_no_redundant_rebuild(self):
        self.assertTrue(self.perform())
        self.assertTrue(self.perform())
        self.assertEqual(len(self.builds), 1)
        self.publish('second')
        self.assertTrue(self.perform())
        self.assertEqual((self.repo / 'source').read_text(), 'second')
        self.assertEqual(len(self.builds), 2)
        self.assertTrue(self.perform())
        self.assertEqual(len(self.builds), 2)

    def test_tracked_and_untracked_edits_preserved(self):
        self.publish('second')
        (self.repo / 'source').write_text('my local edit')
        self.assertFalse(self.perform())
        self.assertEqual((self.repo / 'source').read_text(), 'my local edit')
        self.run_git('-C', str(self.repo), 'restore', 'source')
        (self.repo / 'my-note').write_text('keep me')
        self.assertFalse(self.perform())
        self.assertEqual((self.repo / 'my-note').read_text(), 'keep me')
        self.assertEqual(self.builds, [])

    def test_local_commits_and_feature_branch_pause(self):
        self.run_git('-C', str(self.repo), 'config', 'user.name', 'Test')
        self.run_git('-C', str(self.repo), 'config', 'user.email', 'test@example.invalid')
        self.run_git('-C', str(self.repo), 'commit', '--allow-empty', '-m', 'unpublished')
        head = sync.git(self.repo, 'rev-parse', 'HEAD')
        self.assertFalse(self.perform())
        self.assertEqual(head, sync.git(self.repo, 'rev-parse', 'HEAD'))
        self.run_git('-C', str(self.repo), 'switch', '-c', 'my-feature')
        self.assertFalse(self.perform())
        self.assertEqual(sync.git(self.repo, 'branch', '--show-current'), 'my-feature')

    def test_failed_build_retries_without_marking_installed(self):
        def fail(repo):
            raise subprocess.CalledProcessError(1, ['build'])
        with self.assertRaises(subprocess.CalledProcessError):
            self.perform(fail)
        self.assertFalse((self.state / 'installed-commit').exists())
        self.assertTrue(self.perform())

    def test_wrong_origin_rejected(self):
        self.run_git('-C', str(self.repo), 'remote', 'set-url', 'origin', 'https://example.invalid/other.git')
        with self.assertRaises(RuntimeError):
            self.perform()
        self.assertEqual(self.builds, [])

    def test_concurrent_sync_does_not_start_another_build(self):
        self.state.mkdir()
        with (self.state / 'sync.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertFalse(self.perform())
        self.assertEqual(self.builds, [])

    def test_fetch_failure_keeps_previous_install_marker(self):
        self.assertTrue(self.perform())
        previous = (self.state / 'installed-commit').read_text()
        self.run_git('-C', str(self.remote), 'update-ref', '-d', 'refs/heads/main')
        with self.assertRaises(subprocess.CalledProcessError):
            self.perform()
        self.assertEqual((self.state / 'installed-commit').read_text(), previous)
        self.assertEqual(len(self.builds), 1)

    def test_agent_handles_spaces_and_disables_git_prompts(self):
        config = plistlib.loads(plistlib.dumps(sync.agent(self.repo, self.root / 'path with spaces')))
        self.assertEqual(config['StartInterval'], 300)
        self.assertIn(str(self.repo), config['ProgramArguments'])
        self.assertEqual(config['EnvironmentVariables']['GIT_TERMINAL_PROMPT'], '0')
        self.assertIn('path with spaces', config['ProgramArguments'][1])


if __name__ == '__main__':
    unittest.main()
