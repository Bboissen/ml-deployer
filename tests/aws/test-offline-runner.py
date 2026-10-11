"""Exercise owned cleanup against failures, timeouts and concurrent evidence."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('offline_runner', ROOT/'tests/aws/run-offline.py')
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)


class Isolation(unittest.TestCase):
    def setUp(self):
        base = ROOT/'evidence/aws/tests/harness'; base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root/'tests').mkdir()
        (self.root/'tests/example.py').write_text('raise SystemExit(99)\n')
        (self.root/'.gitignore').write_text('evidence/\n.tools/\n')
        for args in [('init', '--template='), ('add', '--', '.gitignore', 'tests/example.py'),
                     ('-c', 'user.name=Offline test', '-c', 'user.email=offline@example.invalid',
                      '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                      'commit', '-m', 'offline fixture')]:
            subprocess.run(['git', *args], cwd=self.root, check=True, capture_output=True)
        self.evidence = self.root/'evidence/aws/operations/real'; self.evidence.mkdir(parents=True)
        (self.evidence/'state.json').write_text('preserve real state')

    def receipt(self):
        receipts = list((self.root/'evidence/aws/test-receipts').glob('*.json'))
        self.assertEqual(len(receipts), 1)
        value = json.loads(receipts[0].read_text())
        self.assertTrue(value['cleanup_verified'])
        for deleted in value['deleted_paths']:
            self.assertFalse(Path(deleted).exists())
        self.assertEqual((self.evidence/'state.json').read_text(), 'preserve real state')
        return value

    def test_snapshot_preserves_git_tracking_edits_and_deletions(self):
        clean = self.root/'evidence/clean-snapshot'
        R.source_snapshot(self.root, clean)
        tracked = subprocess.check_output(['git', 'ls-files'], cwd=clean)
        self.assertEqual(tracked, b'.gitignore\ntests/example.py\n')
        self.assertEqual(subprocess.check_output(['git', 'status', '--porcelain'], cwd=clean), b'')
        (self.root/'tests/example.py').write_text('raise SystemExit(0)\n')
        (self.root/'tests/helper.py').write_text('VALUE = 1\n')
        edited = self.root/'evidence/edited-snapshot'
        R.source_snapshot(self.root, edited)
        status = subprocess.check_output(['git', 'status', '--porcelain'], cwd=edited).decode()
        self.assertEqual(status, ' M tests/example.py\n?? tests/helper.py\n')
        (self.root/'tests/example.py').unlink()
        deleted = self.root/'evidence/deleted-snapshot'
        R.source_snapshot(self.root, deleted)
        self.assertFalse((deleted/'tests/example.py').exists())
        self.assertIn(' D tests/example.py', subprocess.check_output(
            ['git', 'status', '--porcelain'], cwd=deleted).decode())

    def test_interruption_during_preparation_has_correct_receipt(self):
        with patch.object(R, 'source_snapshot', side_effect=SystemExit(143)):
            with self.assertRaises(SystemExit):
                R.run_test(self.root, 'tests/example.py')
        self.assertEqual(self.receipt()['exit_code'], 143)

    def test_timeout_during_preparation_has_correct_receipt(self):
        with patch.object(R, 'source_snapshot', side_effect=subprocess.TimeoutExpired('git', 30)):
            self.assertEqual(R.run_test(self.root, 'tests/example.py'), 124)
        self.assertEqual(self.receipt()['exit_code'], 124)

    def test_current_untracked_source_and_concurrent_evidence_survive_failure(self):
        other = self.evidence.parent/'concurrent'
        (self.root/'tests/helper.py').write_text('VALUE = 17\n')
        (self.root/'tests/example.py').write_text(
            'from pathlib import Path\nimport helper\n'
            'assert helper.VALUE == 17\n'
            'p = Path(' + repr(str(other)) + '); p.mkdir(); (p/"state.json").write_text("concurrent state")\n'
            'local = Path("evidence/aws/operations/test"); local.mkdir(parents=True)\n'
            '(local/"large.bin").write_bytes(b"x" * 1024 * 1024)\n'
            'raise SystemExit(7)\n')
        self.assertEqual(R.run_test(self.root, 'tests/example.py'), 7)
        self.assertEqual(self.receipt()['exit_code'], 7)
        self.assertEqual((other/'state.json').read_text(), 'concurrent state')
        self.assertEqual(list((self.root/'evidence/aws/tests').iterdir()), [])

    def test_timeout_records_failure_and_removes_only_its_snapshot(self):
        (self.root/'tests/example.py').write_text('import time\ntime.sleep(60)\n')
        self.assertEqual(R.run_test(self.root, 'tests/example.py', timeout=0.1), 124)
        self.assertEqual(self.receipt()['exit_code'], 124)

    def test_termination_cleans_snapshot_and_records_interruption(self):
        (self.root/'tests/example.py').write_text(
            'import os, signal, time\n'
            'os.kill(os.getppid(), signal.SIGTERM)\ntime.sleep(60)\n')
        with self.assertRaises(SystemExit) as interrupted:
            R.run_test(self.root, 'tests/example.py')
        self.assertEqual(interrupted.exception.code, 143)
        self.assertEqual(self.receipt()['exit_code'], 143)

    def test_success_removes_test_downloads_and_cache(self):
        (self.root/'tests/example.py').write_text(
            'import os\nfrom pathlib import Path\n'
            'for name in ("TMPDIR", "XDG_CACHE_HOME", "UV_CACHE_DIR"):\n'
            ' p=Path(os.environ[name]); p.mkdir(parents=True,exist_ok=True); (p/"download").write_bytes(b"fixture")\n')
        self.assertEqual(R.run_test(self.root, 'tests/example.py'), 0)
        self.assertEqual(self.receipt()['exit_code'], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
