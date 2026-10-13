"""Guided first use: owned local files, mocked identities, no native login."""
import copy
import importlib.util
import io
import json
import os
import pty
import select
import signal
import shutil
import socket
import subprocess
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT/'scripts/aws'))
import workspace_setup as S
M = S.support()
IDENTITY = {'Account': '111111111111', 'Arn': 'arn:aws:iam::111111111111:user/operator'}


class Setup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = self.directory/'project folder/project.json'
        self.dataset = self.directory/'input data.csv'; self.dataset.write_text('x\n1\n')
        self.project = json.loads((ROOT/'infra/aws/project.example.json').read_text())
        self.project['dataset']['source'] = str(self.dataset)
        self.project['repository'] = {'url': 'https://github.com/operator/project.git', 'ref': 'a'*40}
        self.output = io.StringIO()
        self.doctor = type('Doctor', (), {'lock': threading.Lock(), 'cached': {'old': True}})()
        for name, replacement in [('profile_method', 'console'), ('auth_check', {'identity': IDENTITY})]:
            p = patch.object(M.A, name, return_value=replacement); p.start(); self.addCleanup(p.stop)
        p = patch.object(M.D, 'selection', return_value=self.directory/'absent-selection.json'); p.start(); self.addCleanup(p.stop)
        p = patch.object(M.P, 'git_ref', return_value={'revision': 'a'*40}); p.start(); self.addCleanup(p.stop)

    def console(self, answers):
        answers = iter(answers)
        def read(_):
            try: return next(answers)
            except StopIteration: raise EOFError()
        return S.Console(self.output, read)

    def answers(self):
        return ['example', 'experiment-01', 'my-workspace', 'us-east-1', 'job', '30',
                'https://github.com/operator/project.git', 'a'*40,
                'python "setup project.py"', 'python train.py', 'outputs', str(self.dataset)]

    def write(self, project=None):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(json.dumps(project or self.project))

    def test_answers_create_a_valid_private_project_without_an_editor_or_commands(self):
        project = S.create_project(self.config, self.console(self.answers()), M)
        self.assertEqual(M.P.validate_project(M.L, self.config), project)
        self.assertEqual(project['commands']['setup'], ['python', 'setup project.py'])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])
        self.assertIn('Project saved', self.output.getvalue())

    def test_invalid_inputs_retry_without_echoing_rejected_values(self):
        answers = self.answers()
        answers[5:6] = ['SECRETVALUE', '30']
        answers[2:3] = ['default', 'my-workspace']
        # Invalid credentials in a URL must never reach a saved file or message.
        position = answers.index('https://github.com/operator/project.git')
        answers[position:position] = ['https://user:SECRETVALUE@github.com/operator/project.git']
        project = S.create_project(self.config, self.console(answers), M)
        self.assertEqual(project['profile'], 'my-workspace')
        self.assertNotIn('SECRETVALUE', self.output.getvalue())
        self.assertNotIn('SECRETVALUE', self.config.read_text())

    def test_interruption_leaves_no_partial_project_or_scratch_file(self):
        with self.assertRaises(EOFError): S.create_project(self.config, self.console(['example']), M)
        self.assertFalse(self.config.parent.exists())

    def test_valid_existing_project_is_kept_and_completed_steps_are_skipped(self):
        self.write(); before = self.config.read_bytes()
        with patch.object(M.A, 'login', side_effect=AssertionError('login repeated')), \
             patch.object(M.A, 'github_login', side_effect=AssertionError('public GitHub login')):
            self.assertTrue(S.setup_project(self.config, self.console([]), self.doctor, M))
        self.assertEqual(self.config.read_bytes(), before)
        self.assertIsNone(self.doctor.cached)

    def test_confirmed_repair_preserves_existing_optional_limits(self):
        project = copy.deepcopy(self.project); project['profile'] = 'default'
        project['resources']['maximum_hourly_usd'] = 0.5
        project['dataset']['maximum_bytes'] = 1024
        self.write(project)
        saved = S.create_project(self.config, self.console(['y', *self.answers()]), M)
        self.assertEqual(saved['resources']['maximum_hourly_usd'], 0.5)
        self.assertEqual(saved['dataset']['maximum_bytes'], 1024)

    def test_unknown_existing_fields_and_symlinks_are_never_overwritten(self):
        project = {**self.project, 'password': 'SECRETVALUE'}; self.write(project)
        before = self.config.read_bytes()
        with self.assertRaisesRegex(ValueError, 'unknown fields'):
            S.create_project(self.config, self.console([]), M)
        self.assertEqual(self.config.read_bytes(), before)
        alias = self.directory/'alias.json'; alias.symlink_to(self.config)
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            S.create_project(alias, self.console([]), M)
        self.assertEqual(self.config.read_bytes(), before)

    def test_concurrent_changes_are_preserved(self):
        self.write(); answers = iter(['y', *self.answers()])
        changed = self.config.read_bytes() + b'\n'
        def read(_):
            answer = next(answers)
            if answer == str(self.dataset): self.config.write_bytes(changed)
            return answer
        with self.assertRaisesRegex(ValueError, 'changed while you answered'):
            S.create_project(self.config, S.Console(self.output, read), M)
        self.assertEqual(self.config.read_bytes(), changed)

    def test_ssh_aws_login_is_offered_in_the_same_terminal_using_remote_mode(self):
        self.write()
        with patch.object(M.A, 'profile_method', return_value='new'), patch.object(M.A, 'login') as login, \
             patch.dict(os.environ, {'SSH_CONNECTION': 'client server'}):
            self.assertTrue(S.setup_project(self.config, self.console(['y', 'auto']), self.doctor, M))
        login.assert_called_once_with(self.project['profile'], 'us-east-1', 'auto', True)

    def test_declining_login_never_launches_native_authentication(self):
        self.write()
        with patch.object(M.A, 'profile_method', return_value='new'), \
             patch.object(M.A, 'login', side_effect=AssertionError('login should wait')):
            S.setup_project(self.config, self.console(['n']), self.doctor, M)
        self.assertIn('sign-in deferred', self.output.getvalue())

    def test_commands_are_argument_arrays_not_shell_programs(self):
        sentinel = self.directory/'must-not-exist'
        result = S.argv('python train.py "$(touch ' + str(sentinel) + ')"')
        self.assertIn('$(touch ' + str(sentinel) + ')', result)
        self.assertFalse(sentinel.exists())
        with self.assertRaisesRegex(ValueError, 'shell operators'): S.argv('make setup && make train')

    def test_color_requires_a_terminal_and_respects_no_color(self):
        class Terminal(io.StringIO):
            def isatty(self): return True
        colored = Terminal()
        with patch.dict(os.environ, {'TERM': 'xterm-256color'}, clear=True):
            S.Console(colored).status('done', 'Ready')
        self.assertIn('\033[32m', colored.getvalue())
        plain = Terminal()
        with patch.dict(os.environ, {'TERM': 'xterm', 'NO_COLOR': ''}, clear=True):
            S.Console(plain).status('done', 'Ready')
        self.assertNotIn('\033[', plain.getvalue())
        self.assertNotIn('\033[', self.output.getvalue())

    def test_proxy_terminal_keeps_color_but_arbitrary_capture_and_no_color_stay_plain(self):
        output = io.StringIO()
        with patch.object(sys, 'stdout', output), patch.object(sys.stdin, 'isatty', return_value=True), \
             patch.dict(os.environ, {'TERM': 'xterm'}, clear=True):
            S.Console().status('done', 'Ready')
            self.assertIn('\033[32m', output.getvalue())
            self.assertFalse(S.Console(io.StringIO()).color)
            os.environ['NO_COLOR'] = ''
            self.assertFalse(S.Console().color)


class MakeFlow(unittest.TestCase):
    def test_make_creates_project_in_its_own_terminal_and_companion_tracks_it(self):
        self.make_flow()

    @unittest.skipUnless(shutil.which('rtk'), 'RTK is optional for the standalone installer')
    def test_make_remote_through_rtk_keeps_questions_color_and_safe_paths(self):
        self.make_flow(remote=True)

    def make_flow(self, remote=False):
        # Reuse the bootstrap's verified archive fixtures, rather than depending
        # on host cloud tools or downloading anything in this acceptance check.
        spec = importlib.util.spec_from_file_location('setup_fixtures', ROOT/'tests/aws/test-workstation-setup.py')
        fixtures = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixtures)
        fixture = fixtures.Bootstrap('test_check_only_has_no_writes_or_downloads')
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        spec = importlib.util.spec_from_file_location('offline_snapshot', ROOT/'tests/aws/run-offline.py')
        runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
        repo = fixture.root/'full repo'; runner.source_snapshot(ROOT, repo)
        for name in ('workstation-tools.lock.tsv', 'controller-requirements.lock'):
            (repo/'scripts/aws'/name).write_bytes((fixture.repo/'scripts/aws'/name).read_bytes())
        config = fixture.root/("project's `touch MAKE-INJECTION` folder/project.json" if remote else 'project/project.json')
        dataset = fixture.root/'data.csv'; dataset.write_text('x\n1\n')
        files = {}
        for name in ('AWS_CONFIG_FILE', 'AWS_SHARED_CREDENTIALS_FILE'):
            file = fixture.root/name; file.write_text(''); files[name] = str(file)
        environment = {**fixture.env, **files, 'TERM': 'xterm-256color', 'SSH_CONNECTION': 'fixture'}
        for name in list(environment):
            if name.startswith(('AWS_', 'GH_', 'GITHUB_', 'TF_')) and name not in files: environment.pop(name)
        environment.pop('NO_COLOR', None)
        environment['SSH_CONNECTION'] = '192.0.2.10 54321 192.0.2.20 2222'
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
        environment['WORKSPACE_GUIDE_PORT'] = str(port)
        master, slave = pty.openpty()
        command = [*([shutil.which('rtk'), 'proxy'] if remote else []), 'make',
                   *(['remote'] if remote else []), 'PROJECT=' + str(config)]
        process = subprocess.Popen(command, cwd=repo, env=environment,
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        captured = bytearray()
        def stop():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
            os.close(master)
        self.addCleanup(stop)
        def until(text):
            deadline = time.monotonic() + 30
            while text.encode() not in captured and time.monotonic() < deadline:
                if select.select([master], [], [], 0.2)[0]:
                    try: block = os.read(master, 4096)
                    except OSError: break
                    if not block: break
                    captured.extend(block)
            self.assertIn(text, captured.decode(errors='replace'))
        until('Project name')
        answers = ['example', 'experiment-01', 'my-workspace', '', '', '30',
                   'https://github.com/operator/project.git', 'a'*40,
                   'make setup', 'make train', 'outputs', str(dataset), 'n']
        os.write(master, ('\n'.join(answers) + '\n').encode())
        until('Companion stays available')
        value = json.loads(config.read_text())
        self.assertEqual(value['profile'], 'my-workspace')
        self.assertEqual(value['repository']['ref'], 'a'*40)
        self.assertEqual(value['dataset']['source'], str(dataset))
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        output = captured.decode(errors='replace')
        self.assertIn('\033[', output)
        self.assertNotIn('workstation-setup:', output)
        self.assertNotIn('Activate with:', output)
        self.assertNotIn('mkdir -p', output)
        self.assertNotIn('Your local setup guide', output)
        self.assertFalse((repo/'MAKE-INJECTION').exists())
        self.assertEqual(list(Path(environment.get('TMPDIR', '/tmp')).glob('workspace-setup.*')), [])
        if remote:
            self.assertIn('laptop terminal outside SSH', output)
            self.assertIn('192.0.2.20', output)
            self.assertIn('setup continues here', output)
            self.assertIn('ExitOnForwardFailure=yes', output)
        with urllib.request.urlopen('http://127.0.0.1:%d/status.json' % port, timeout=10) as response:
            report = json.load(response)
        self.assertEqual(report['setup_mode'], 'interactive')
        rows = {row['check']: row for row in report['rows']}
        self.assertEqual(rows['Project config']['state'], 'Ready')
        self.assertEqual(rows['AWS identity']['state'], 'To do')
        with urllib.request.urlopen('http://127.0.0.1:%d/' % port, timeout=10) as response:
            self.assertIn('Describe your project', response.read().decode())
        os.killpg(process.pid, signal.SIGINT); process.wait(timeout=10)
        with socket.socket() as connection:
            self.assertNotEqual(connection.connect_ex(('127.0.0.1', port)), 0)
        # Scratch, fake runtimes and extracted archives belong to fixture.root;
        # its registered cleanup removes them before the outer runner receipt.


if __name__ == '__main__':
    unittest.main(verbosity=2)
