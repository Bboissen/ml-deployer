#!/usr/bin/env bash
# Offline runtime SSH and credential lifecycle tests; no Git or AWS calls.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec "${WORKSPACE_PYTHON:-python3}" - <<'PY'
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

text = Path('scripts/aws/workspace-ssh.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
SSH = {'__name__': 'offline_ssh'}
exec(compile(text, 'workspace-ssh', 'exec'), SSH)
PUBLIC = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBp6q1ENFe6gNItycHG6veAjDktVHEBpFSksTGz14XTE'
FINGERPRINT = 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(PUBLIC.split()[1])).digest()).decode().rstrip('=')
PRIVATE = '-----BEGIN OPENSSH PRIVATE KEY-----\nOFFLINE-PLACEHOLDER-NOT-A-KEY\n-----END OPENSSH PRIVATE KEY-----\n'
ARN = 'arn:aws:secretsmanager:us-east-1:000000000000:secret:demo/workspaces/demo-dev-01/git/aws-workspace-e2e-ABCdef'
CONFIG = types.ModuleType('botocore.config'); CONFIG.Config = lambda **arguments: arguments


class RuntimeSSH(unittest.TestCase):
    def setUp(self):
        self.args = argparse.Namespace(url='git@github.com:Bboissen/aws-workspace-e2e.git', revision='a' * 40,
            directory='/workspaces/demo-dev-01/offline-ssh-project', secret_arn=ARN,
            version_id='00000000-0000-0000-0000-000000000000', fingerprint=FINGERPRINT,
            account='000000000000', region='us-east-1')
        self.temporary = tempfile.TemporaryDirectory(prefix='offline-ssh-')
        self.addCleanup(self.temporary.cleanup)
        self.commands = []; self.key_path = None; self.reads = []
        self.response = {'ARN': ARN, 'VersionId': self.args.version_id, 'SecretString': PRIVATE}
        self.method = 'iam-role'; self.failure = None
        self.client = types.SimpleNamespace(meta=types.SimpleNamespace(region_name='us-east-1',
            endpoint_url='https://secretsmanager.us-east-1.amazonaws.com'), get_secret_value=self.retrieve)
        self.session = types.SimpleNamespace(get_credentials=lambda: types.SimpleNamespace(method=self.method),
            client=lambda *arguments, **settings: self.client)

    def retrieve(self, **arguments):
        self.reads.append(arguments)
        return dict(self.response)

    def command(self, arguments, environment=None):
        self.commands.append((arguments, environment))
        if arguments[0] == 'findmnt':
            return b'tmpfs\n'
        if arguments[0] == 'ssh-keygen':
            self.key_path = Path(arguments[-1])
            self.assertEqual(self.key_path.read_text(), PRIVATE)
            self.assertEqual(self.key_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.key_path.parent.stat().st_mode & 0o777, 0o700)
            return PUBLIC.encode()
        if self.failure and self.failure in arguments:
            raise ValueError('SSH authentication/checkout command failed')
        if arguments[-1] == 'HEAD':
            return self.args.revision.encode()
        return b''

    def key_directory(self, *, prefix, dir):
        self.assertEqual(dir, '/dev/shm')
        return tempfile.TemporaryDirectory(prefix=prefix, dir=self.temporary.name)

    def invoke(self):
        with patch.dict('sys.modules', {'botocore.config': CONFIG}), \
                patch.object(SSH['os'], 'geteuid', return_value=1000), \
                patch.object(SSH['pwd'], 'getpwuid', return_value=types.SimpleNamespace(pw_name='workspace')), \
                patch.dict(SSH, {'command': self.command, 'tempfile': types.SimpleNamespace(TemporaryDirectory=self.key_directory)}):
            return SSH['clone'](self.args, self.session)

    def test_secure_clone_uses_pinned_version_commit_and_removes_key(self):
        result = self.invoke()
        self.assertEqual(self.reads, [{'SecretId': ARN, 'VersionId': self.args.version_id}])
        self.assertFalse(self.key_path.exists())
        self.assertFalse(self.key_path.parent.exists())
        self.assertTrue(result['credential_removed'])
        self.assertEqual(result['repository_commit'], self.args.revision)
        git_calls = [item for item in self.commands if item[0][0] == 'git']
        self.assertEqual(len(git_calls), 5)
        self.assertFalse(any('clone' in arguments for arguments, _ in git_calls))
        self.assertEqual([arguments for arguments, _ in git_calls if 'fetch' in arguments], [
            ['git', '-C', self.args.directory, 'fetch', '--no-tags', '--depth=1', 'origin', self.args.revision]
        ])
        for arguments, environment in git_calls:
            ssh = environment['GIT_SSH_COMMAND']
            for option in ('StrictHostKeyChecking=yes', 'IdentitiesOnly=yes', 'IdentityAgent=none',
                           'BatchMode=yes', 'HostKeyAlgorithms=ssh-ed25519', 'GlobalKnownHostsFile=/dev/null'):
                self.assertIn(option, ssh)
            self.assertEqual(environment['GIT_CONFIG_GLOBAL'], '/dev/null')
            self.assertNotIn('SSH_AUTH_SOCK', environment)
            self.assertNotIn(PRIVATE, str((arguments, environment)))

    def test_wrong_secret_version_fails_before_writing_key(self):
        self.response['VersionId'] = '11111111-1111-1111-1111-111111111111'
        with self.assertRaisesRegex(ValueError, 'reference mismatch'):
            self.invoke()
        self.assertIsNone(self.key_path)

    def test_console_plaintext_without_final_newline_is_accepted(self):
        self.response['SecretString'] = PRIVATE.rstrip()
        self.assertTrue(self.invoke()['credential_removed'])
        self.assertFalse(self.key_path.parent.exists())

    def test_wrong_secret_arn_fails_before_writing_key(self):
        self.response['ARN'] = ARN + 'wrong'
        with self.assertRaisesRegex(ValueError, 'reference mismatch'):
            self.invoke()
        self.assertIsNone(self.key_path)

    def test_json_secret_is_rejected(self):
        self.response['SecretString'] = json.dumps({'private_key': PRIVATE})
        with self.assertRaisesRegex(ValueError, 'raw OpenSSH'):
            self.invoke()
        self.assertIsNone(self.key_path)

    def test_non_native_credentials_never_read_secret(self):
        self.method = 'env'
        with self.assertRaisesRegex(ValueError, 'native instance-role'):
            self.invoke()
        self.assertEqual(self.reads, [])

    def test_wrong_fingerprint_removes_key_without_contacting_git(self):
        self.args.fingerprint = 'SHA256:' + 'A' * 43
        with self.assertRaisesRegex(ValueError, 'fingerprint mismatch'):
            self.invoke()
        self.assertFalse(self.key_path.parent.exists())
        self.assertFalse(any(item[0][0] == 'git' for item in self.commands))

    def test_failed_fetch_removes_key(self):
        self.failure = 'fetch'
        with self.assertRaisesRegex(ValueError, 'checkout command failed'):
            self.invoke()
        self.assertFalse(self.key_path.parent.exists())

    def test_wrong_endpoint_never_reads_secret(self):
        self.client.meta.endpoint_url = 'https://example.invalid'
        with self.assertRaisesRegex(ValueError, 'endpoint mismatch'):
            self.invoke()
        self.assertEqual(self.reads, [])

    def test_https_is_not_accepted_as_ssh(self):
        self.args.url = 'https://github.com/Bboissen/aws-workspace-e2e.git'
        with self.assertRaisesRegex(ValueError, 'GitHub SSH URL'):
            self.invoke()
        self.assertEqual(self.reads, [])

    def test_mutable_revision_never_reads_secret(self):
        self.args.revision = 'main'
        with self.assertRaisesRegex(ValueError, 'immutable repository commit'):
            self.invoke()
        self.assertEqual(self.reads, [])

    def test_root_cannot_execute_runtime_authentication(self):
        with patch.object(SSH['os'], 'geteuid', return_value=0):
            with self.assertRaisesRegex(ValueError, 'run as workspace'):
                SSH['validate'](self.args)
        self.assertEqual(self.reads, [])


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RuntimeSSH))
directory = Path('evidence/aws/tests/ssh') / dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
directory.mkdir(parents=True, mode=0o700)
with (directory / 'result.json').open('x') as stream:
    json.dump({'passed': result.wasSuccessful(), 'tests_run': result.testsRun,
               'cloud_mutations': False, 'real_private_value_retrieved': False}, stream)
    stream.write('\n')
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
