"""Guided first use: owned local files, mocked identities, no native login."""
import base64
import copy
import hashlib
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


MAKEFILE = 'SHELL := /bin/bash\n.PHONY: setup train\nsetup:\n\tuv sync\ntrain: setup\n\tpython train.py\n'


def github(repositories, calls=None, signed_in=True):
    """A fake `gh` behind the request boundary: read-only API answers, no network."""
    def request(command, env, seconds):
        if calls is not None: calls.append(command)
        if command[:3] == ['gh', 'auth', 'status']:
            return subprocess.CompletedProcess(command, 0 if signed_in else 1, '', '')
        assert command[:6] == ['gh', 'api', '--hostname', 'github.com', '--method', 'GET'], command
        path = command[6]
        if not signed_in: return subprocess.CompletedProcess(command, 4, '', 'gh auth login required')
        name, _, rest = path[len('repos/'):].partition('/contents/')
        repository = next((r for key, r in repositories.items() if name.lower() in (key, r['full_name'].lower())), None)
        if repository is None: return subprocess.CompletedProcess(command, 1, '{"message":"Not Found"}', 'gh: Not Found (HTTP 404)')
        if not rest:
            return subprocess.CompletedProcess(command, 0, json.dumps(
                {'full_name': repository['full_name'], 'private': repository['private'],
                 'visibility': 'private' if repository['private'] else 'public',
                 'default_branch': repository.get('default_branch', 'main')}), '')
        if repository.get('makefile') is None: return subprocess.CompletedProcess(command, 1, '', 'gh: Not Found (HTTP 404)')
        return subprocess.CompletedProcess(command, 0, json.dumps(
            {'type': 'file', 'encoding': 'base64', 'content': base64.b64encode(repository['makefile'].encode()).decode()}), '')
    return request


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
        self.calls = []
        self.repositories = {'operator/project': {'full_name': 'operator/project', 'private': False, 'makefile': MAKEFILE},
                             'operator/secret-model': {'full_name': 'Operator/Secret_Model.v2', 'private': True,
                                                       'default_branch': 'develop', 'makefile': 'run:\n\tpython run.py\n'}}
        for name, replacement in [('profile_method', 'console'), ('auth_check', {'identity': IDENTITY}),
                                  ('native_profiles', ['my-workspace'])]:
            p = patch.object(M.A, name, return_value=replacement); p.start(); self.addCleanup(p.stop)
        p = patch.object(M.D, 'selection', return_value=self.directory/'absent-selection.json'); p.start(); self.addCleanup(p.stop)
        p = patch.object(M.P, 'git_ref', return_value={'revision': 'a'*40}); p.start(); self.addCleanup(p.stop)
        p = patch.dict(M.B, {'request': github(self.repositories, self.calls)}); p.start(); self.addCleanup(p.stop)
        p = patch.object(S.shutil, 'which', lambda name: '/usr/bin/' + name); p.start(); self.addCleanup(p.stop)

    def console(self, answers):
        answers = iter(answers); self.prompts = []
        def read(prompt):
            self.prompts.append(prompt)
            try: return next(answers)
            except StopIteration: raise EOFError()
        return S.Console(self.output, read)

    def silent(self):
        def read(prompt): raise AssertionError('scripted setup asked: ' + prompt)
        return S.Console(self.output, read)

    def answers(self):
        return ['operator/project', str(self.dataset)]

    def write(self, project=None):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(json.dumps(project or self.project))

    def test_two_answers_derive_every_other_setting(self):
        project = S.create_project(self.config, self.console(self.answers()), M)
        self.assertEqual(len(self.prompts), 2)
        self.assertEqual(M.P.validate_project(M.L, self.config), project)
        self.assertEqual(project['repository'], {'url': 'https://github.com/operator/project.git', 'ref': 'main'})
        self.assertEqual((project['project'], project['profile'], project['region']), ('project', 'my-workspace', 'us-east-1'))
        self.assertEqual((project['mode'], project['maximum_runtime_minutes'], project['outputs']['paths']), ('job', 60, ['outputs']))
        self.assertEqual(project['commands'], {'setup': ['make', 'setup'], 'run': ['make', 'train']})
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])
        output = self.output.getvalue()
        for text in ('Project saved', 'Repository operator/project (public, HTTPS) at main', 'make setup then make train',
                     'AWS profile my-workspace in us-east-1', 'up to 60 min'):
            self.assertIn(text, output)
        self.assertNotIn('To do', output)
        self.assertTrue(all(c[:2] == ['gh', 'auth'] or c[4:6] == ['--method', 'GET'] for c in self.calls), 'GitHub stays read-only')

    def test_private_repository_uses_ssh_canonical_name_and_reports_missing_targets(self):
        project = S.create_project(self.config, self.console(['https://github.com/operator/secret-model.git', str(self.dataset)]), M)
        self.assertEqual(project['repository'], {'url': 'git@github.com:Operator/Secret_Model.v2.git', 'ref': 'develop'})
        self.assertEqual(project['project'], 'secret-model-v2')
        output = self.output.getvalue()
        self.assertIn('private, SSH deploy key', output)
        self.assertIn('To do: add Makefile targets setup, train at Operator/Secret_Model.v2 develop', output)
        self.assertIn('runtime-contract', output)
        self.repositories['operator/secret-model']['makefile'] = None; self.config.unlink()
        S.create_project(self.config, self.console(['operator/secret-model', str(self.dataset)]), M)
        self.assertIn('add a Makefile with targets setup, train', self.output.getvalue())

    def test_flags_set_up_without_any_question(self):
        project = S.create_project(self.config, self.silent(), M, 'operator/project', str(self.dataset))
        self.assertEqual(project['repository']['ref'], 'main')
        with patch.object(M.A, 'native_profiles', return_value=['first', 'second']):
            self.config.unlink()
            with self.assertRaisesRegex(ValueError, '--profile NAME'):
                S.create_project(self.config, self.silent(), M, 'operator/project', str(self.dataset))
            project = S.create_project(self.config, self.silent(), M, 'operator/project', str(self.dataset), 'second')
            self.assertEqual(project['profile'], 'second')

    def test_profile_is_asked_only_between_several_native_profiles(self):
        with patch.object(M.A, 'native_profiles', return_value=[]):
            self.assertEqual(S.create_project(self.config, self.console(self.answers()), M)['profile'], S.DEFAULT_PROFILE)
        self.config.unlink()
        with patch.object(M.A, 'native_profiles', return_value=['first', 'second']):
            project = S.create_project(self.config, self.console(['operator/project', 'unlisted', 'second', str(self.dataset)]), M)
        self.assertEqual(project['profile'], 'second')
        self.assertTrue(any('AWS profile (first, second)' in prompt for prompt in self.prompts))

    def test_invalid_inputs_retry_without_echoing_rejected_values(self):
        answers = ['https://user:SECRETVALUE@github.com/operator/project.git', 'SECRETVALUE/missing-repository',
                   'operator/project', str(self.directory/'SECRETVALUE'), str(self.dataset)]
        project = S.create_project(self.config, self.console(answers), M)
        self.assertEqual(project['repository']['url'], 'https://github.com/operator/project.git')
        self.assertIn('not found, or not visible', self.output.getvalue())
        self.assertNotIn('SECRETVALUE', self.output.getvalue())
        self.assertNotIn('SECRETVALUE', self.config.read_text())
        with self.assertRaisesRegex(ValueError, 'OWNER/NAME') as caught:
            S.create_project(self.directory/'other.json', self.silent(), M, 'SECRETVALUE;rm', str(self.dataset))
        self.assertNotIn('SECRETVALUE', str(caught.exception))

    def test_github_sign_in_is_offered_before_reading_the_repository(self):
        with patch.dict(M.B, {'request': github(self.repositories, signed_in=False)}), \
             patch.object(M.A, 'github_login', side_effect=AssertionError('declined login ran')):
            with self.assertRaisesRegex(ValueError, 'GitHub sign-in is needed'):
                S.create_project(self.config, self.console(['n']), M)
        self.assertFalse(self.config.parent.exists())
        with patch.dict(M.B, {'request': github(self.repositories, signed_in=False)}), \
             patch.object(S, 'github_login', side_effect=lambda ui, M: M.B.update(request=github(self.repositories))) as login:
            S.create_project(self.config, self.silent(), M, 'operator/project', str(self.dataset))
        login.assert_called_once()

    def test_interruption_leaves_no_partial_project_or_scratch_file(self):
        with self.assertRaises(EOFError): S.create_project(self.config, self.console(['operator/project']), M)
        self.assertFalse(self.config.parent.exists())

    def test_rerun_preserves_existing_values_and_flags_override_only_their_field(self):
        project = copy.deepcopy(self.project)
        project.update(maximum_runtime_minutes=30, mode='workspace', profile='chosen', workspace='trial-2')
        project['commands'] = {'setup': ['python', 'setup project.py'], 'run': ['python', 'train.py']}
        project['outputs'] = {'paths': ['results', 'models']}
        self.write(project)
        other = self.directory/'other data'; other.mkdir(); (other/'rows.csv').write_text('1\n')
        saved = S.create_project(self.config, self.silent(), M, dataset=str(other))
        self.assertEqual(saved['dataset']['source'], str(other))
        self.assertEqual({k: saved[k] for k in project if k != 'dataset'}, {k: project[k] for k in project if k != 'dataset'})
        self.assertNotIn('To do', self.output.getvalue(), 'custom commands skip the Makefile check')

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
        saved = S.create_project(self.config, self.console(['y']), M)
        self.assertEqual(saved['profile'], 'my-workspace')
        self.assertEqual(saved['repository'], project['repository'])
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
        self.write(); changed = self.config.read_bytes() + b'\n'
        request = github(self.repositories)
        def edit_during_lookup(command, env, seconds):
            self.config.write_bytes(changed); return request(command, env, seconds)
        with patch.dict(M.B, {'request': edit_during_lookup}), \
             self.assertRaisesRegex(ValueError, 'changed while you answered'):
            S.create_project(self.config, self.console(['y']), M)
        self.assertEqual(self.config.read_bytes(), changed)

    def test_scripted_setup_starts_native_logins_without_confirmation(self):
        with patch.object(M.A, 'profile_method', return_value='new'), patch.object(M.A, 'login') as login:
            self.assertTrue(S.setup_project(self.config, self.silent(), self.doctor, M, remote=False,
                                            repo='operator/project', dataset=str(self.dataset)))
        login.assert_called_once_with('my-workspace', 'us-east-1', 'auto', False)

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


class Profiles(unittest.TestCase):
    def test_native_profiles_exclude_default_and_static_keys_and_prefer_aws_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            config, credentials = Path(directory)/'config', Path(directory)/'credentials'
            config.write_text('[default]\nregion = us-east-1\n[profile console-one]\nlogin_session = arn:aws:iam::111111111111:user/a\n'
                              '[profile sso-one]\nsso_session = corp\nsso_account_id = 111111111111\nsso_role_name = r\n'
                              '[sso-session corp]\nsso_start_url = https://example.invalid/start\nsso_region = us-east-1\n'
                              '[profile process]\ncredential_process = /bin/false\n[profile keys]\nregion = us-east-1\n')
            credentials.write_text('[keys]\naws_access_key_id = PLACEHOLDER\naws_secret_access_key = PLACEHOLDER\n')
            files = {'AWS_CONFIG_FILE': str(config), 'AWS_SHARED_CREDENTIALS_FILE': str(credentials)}
            with patch.dict(os.environ, files, clear=True):
                self.assertEqual(M.A.native_profiles('us-east-1'), ['console-one', 'sso-one'])
            with patch.dict(os.environ, {**files, 'AWS_PROFILE': 'sso-one'}, clear=True):
                self.assertEqual(M.A.native_profiles('us-east-1'), ['sso-one', 'console-one'])


class MakeFlow(unittest.TestCase):
    def test_make_creates_project_in_its_own_terminal_and_companion_tracks_it(self):
        self.make_flow()

    @unittest.skipUnless(shutil.which('rtk'), 'RTK is optional for the standalone installer')
    def test_make_detects_ssh_through_rtk_and_keeps_questions_color_and_safe_paths(self):
        self.make_flow(relay=True)

    def test_make_re_cleans_before_reinstalling_and_resuming_setup_with_parallel_make(self):
        self.make_flow(rebuild=True)

    def make_flow(self, relay=False, rebuild=False):
        # Reuse the bootstrap's verified archive fixtures, rather than depending
        # on host cloud tools or downloading anything in this acceptance check.
        spec = importlib.util.spec_from_file_location('setup_fixtures', ROOT/'tests/aws/test-workstation-setup.py')
        fixtures = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixtures)
        fixture = fixtures.Bootstrap('test_check_only_has_no_writes_or_downloads')
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        # The managed gh answers the read-only API calls setup makes; it never reaches GitHub.
        fake_gh = ('#!' + sys.executable + '\nimport base64,json,sys\na=sys.argv[1:]\n'
                   'if a==["--version"]: print("gh version 2.102.0 (mock)")\n'
                   'elif a[:2]==["auth","status"]: pass\n'
                   'elif a[:1]==["api"] and a[-1]=="repos/operator/project": print(json.dumps({"full_name":"operator/project","private":False,"visibility":"public","default_branch":"main"}))\n'
                   'elif a[:1]==["api"] and a[-1].startswith("repos/operator/project/contents/Makefile?ref="): print(json.dumps({"type":"file","encoding":"base64","content":base64.b64encode(' + repr(MAKEFILE) + '.encode()).decode()}))\n'
                   'else: sys.exit(1)\n')
        old_hash = hashlib.sha256((fixture.cache/'gh.tgz').read_bytes()).hexdigest()
        new_hash = fixture.archive('gh.tgz', {'gh/bin/gh': fake_gh})
        lock = fixture.repo/'scripts/aws/workstation-tools.lock.tsv'
        lock.write_text(lock.read_text().replace(old_hash, new_hash))
        if rebuild:
            self.assertEqual(fixture.run_setup('--github').returncode, 0)
            previous = (fixture.prefix/'current').resolve()
        spec = importlib.util.spec_from_file_location('offline_snapshot', ROOT/'tests/aws/run-offline.py')
        runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
        repo = fixture.root/'full repo'; runner.source_snapshot(ROOT, repo)
        for name in ('workstation-tools.lock.tsv', 'controller-requirements.lock'):
            (repo/'scripts/aws'/name).write_bytes((fixture.repo/'scripts/aws'/name).read_bytes())
        config = fixture.root/("project's `touch MAKE-INJECTION` folder/project.json" if relay else 'project/project.json')
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
        command = [*([shutil.which('rtk'), 'proxy'] if relay else []), 'make',
                   *(['-j4', 're'] if rebuild else []), 'PROJECT=' + str(config)]
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
        until('repository (OWNER/NAME')
        answers = ['operator/project', str(dataset), 'n']
        os.write(master, ('\n'.join(answers) + '\n').encode())
        until('Companion stays available')
        if rebuild:
            self.assertFalse(previous.exists())
            self.assertNotEqual((fixture.prefix/'current').resolve(), previous)
            self.assertEqual(len(list((repo/'evidence').glob('workstation-cleanup.*'))), 1)
        value = json.loads(config.read_text())
        self.assertEqual(value['profile'], S.DEFAULT_PROFILE)
        self.assertEqual(value['repository'], {'url': 'https://github.com/operator/project.git', 'ref': 'main'})
        self.assertEqual(value['maximum_runtime_minutes'], 60)
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
        if relay:
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
        self.assertEqual(rows['GitHub repository']['state'], 'Ready')
        with urllib.request.urlopen('http://127.0.0.1:%d/' % port, timeout=10) as response:
            self.assertIn('Describe your project', response.read().decode())
        os.killpg(process.pid, signal.SIGINT); process.wait(timeout=10)
        with socket.socket() as connection:
            self.assertNotEqual(connection.connect_ex(('127.0.0.1', port)), 0)
        # Scratch, fake runtimes and extracted archives belong to fixture.root;
        # its registered cleanup removes them before the outer runner receipt.


if __name__ == '__main__':
    unittest.main(verbosity=2)
