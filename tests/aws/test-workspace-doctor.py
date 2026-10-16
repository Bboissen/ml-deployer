"""Doctor readiness states without cloud credentials, managed tools or network."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location('workspace_doctor', ROOT/'scripts/aws/workspace-doctor.py')
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
BASE = ROOT/'evidence/aws/tests/doctor'
BASE.mkdir(parents=True, exist_ok=True)
IDENTITY = {'Account': '111111111111', 'Arn': 'arn:aws:iam::111111111111:user/operator'}
MAKEFILE = base64.b64encode(b'setup:\n\ttrue\ntrain: setup\n\ttrue\n').decode()


def gh_api(repository, makefile=MAKEFILE, calls=None):
    """Fake read-only `gh api` behind the request boundary; None means not signed in."""
    def request(command, env, seconds):
        if calls is not None: calls.append(command)
        if command[:2] == ['gh', 'auth']: return subprocess.CompletedProcess(command, 0, '', '')
        assert command[:6] == ['gh', 'api', '--hostname', 'github.com', '--method', 'GET'], command
        if repository is None: return subprocess.CompletedProcess(command, 4, '', 'not logged in')
        if '/contents/' not in command[6]: return subprocess.CompletedProcess(command, 0, json.dumps(repository), '')
        if makefile is None: return subprocess.CompletedProcess(command, 1, '', 'gh: Not Found (HTTP 404)')
        return subprocess.CompletedProcess(command, 0, json.dumps({'type': 'file', 'encoding': 'base64', 'content': makefile}), '')
    return request


PUBLIC = {'full_name': 'owner/project', 'private': False, 'visibility': 'public', 'default_branch': 'main'}


class Doctor(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=BASE); self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.project = json.loads((ROOT/'infra/aws/project.example.json').read_text())
        self.project['dataset']['source'] = 'input data'
        (self.directory/'input data').mkdir(); (self.directory/'input data/rows.csv').write_text('1,2,3\n')
        self.project['repository']['ref'] = 'a'*40
        self.config = self.directory/'project.json'
        self.write()
        self.pointer = self.directory/'selection.json'
        patcher = patch.object(M.D, 'selection', lambda *_: self.pointer); patcher.start(); self.addCleanup(patcher.stop)
        # Repository checks use a fake signed-in gh: tests never call GitHub.
        for patcher in (patch.object(shutil, 'which', lambda name: '/usr/bin/' + name), patch.dict(M.B, {'request': gh_api(PUBLIC)})):
            patcher.start(); self.addCleanup(patcher.stop)
        for name in ('AWS_CONFIG_FILE', 'AWS_SHARED_CREDENTIALS_FILE'):
            (self.directory/name).write_text('')
        self.files = {'AWS_CONFIG_FILE': str(self.directory/'AWS_CONFIG_FILE'),
                      'AWS_SHARED_CREDENTIALS_FILE': str(self.directory/'AWS_SHARED_CREDENTIALS_FILE')}

    def write(self):
        self.config.write_text(json.dumps(self.project))

    def states(self, report):
        return {row['check']: row['state'] for row in report.rows}

    def test_without_configuration_reports_unknown_and_next_command(self):
        report, text = M.doctor(None, 'pinned tools verified', False)
        self.assertFalse(report.ready)
        self.assertEqual(self.states(report)['Managed tools'], M.READY)
        self.assertEqual(self.states(report)['AWS identity'], M.UNKNOWN)
        self.assertEqual([row['check'] for row in report.rows][:2], ['Managed tools', 'Project config'])
        self.assertIn('next: ./workspace guide ~/aws-workspace/demo/project.json --repo OWNER/NAME --dataset PATH', text)
        self.assertIn('Not ready yet', text)

    def test_missing_login_is_action_needed_without_network(self):
        with patch.dict(os.environ, self.files, clear=True), patch.object(M.A, 'auth_check', side_effect=AssertionError('network call')):
            report, text = M.doctor(self.config, 'ok', False)
        states = self.states(report)
        self.assertEqual(states['Project config'], M.READY); self.assertEqual(states['GitHub access'], M.READY)
        self.assertEqual(states['AWS identity'], M.ACTION)
        self.assertIn('./workspace login --profile reviewed-temporary --region us-east-1', text)
        self.assertIn('Not ready yet', text); self.assertNotIn('Action needed', text)

    def test_all_ready_points_to_deploy(self):
        with patch.object(M.A, 'profile_method', return_value='console'), patch.object(M.A, 'auth_check', return_value={'identity': IDENTITY}):
            report, text = M.doctor(self.config, 'ok', False)
        self.assertTrue(report.ready, text)
        self.assertIn('login does not prove infrastructure permissions', text)
        self.assertIn('Ready: review and deploy with ./workspace '+str(self.config), text)

    def test_expired_login_and_timeouts_are_distinct(self):
        with patch.object(M.A, 'profile_method', return_value='console'), patch.object(M.A, 'auth_check', side_effect=M.B['Failure']('AWS CLI: expired_login; run login')):
            report, _ = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['AWS identity'], M.ACTION)
        with patch.object(M.A, 'profile_method', return_value='console'), patch.object(M.A, 'auth_check', side_effect=M.B['Failure']('AWS CLI identity request timed out')):
            report, _ = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['AWS identity'], M.UNKNOWN)

    def test_public_repository_never_needs_github_login(self):
        self.project['repository']['ref'] = 'main'; self.write()
        def request(command, env, seconds):
            self.assertNotEqual(command[0], 'gh', 'public repositories must not consult GitHub login'); raise AssertionError(command)
        with patch.object(M.P, 'git_ref', return_value={'revision': 'b'*40}), patch.dict(M.B, {'request': request}), patch.dict(os.environ, self.files, clear=True):
            report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['GitHub access'], M.READY); self.assertIn('no GitHub login needed', text)

    def test_private_repository_needs_managed_gh_then_login(self):
        self.project['repository']['url'] = 'git@github.com:owner/project.git'; self.write()
        with patch.object(shutil, 'which', lambda name: None if name == 'gh' else '/usr/bin/'+name), patch.dict(os.environ, self.files, clear=True):
            report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['GitHub access'], M.ACTION); self.assertIn('./workspace setup --github', text)
        calls = []
        def request(command, env, seconds):
            calls.append(command); return subprocess.CompletedProcess(command, 1, '', 'not logged in')
        with patch.object(shutil, 'which', lambda name: '/usr/bin/'+name), patch.dict(M.B, {'request': request}), patch.dict(os.environ, self.files, clear=True):
            report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['GitHub access'], M.ACTION); self.assertIn('./workspace github-login', text)
        self.assertEqual(calls[0][:3], ['gh', 'auth', 'status'])
        def logged(command, env, seconds): return subprocess.CompletedProcess(command, 0, '', '')
        with patch.object(shutil, 'which', lambda name: '/usr/bin/'+name), patch.dict(M.B, {'request': logged}), patch.dict(os.environ, self.files, clear=True):
            report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['GitHub access'], M.READY); self.assertIn('repository admin permission', text)

    def test_repository_checks_report_visibility_and_makefile_with_next_commands(self):
        def row(request):
            with patch.dict(M.B, {'request': request}), patch.object(M.A, 'profile_method', return_value='console'), \
                 patch.object(M.A, 'auth_check', return_value={'identity': IDENTITY}):
                report, text = M.doctor(self.config, 'ok', False)
            return {r['check']: r for r in report.rows}['GitHub repository'], report, text
        result, report, text = row(gh_api(PUBLIC))
        self.assertEqual(result['state'], M.READY); self.assertIn('owner/project (public)', result['detail'])
        self.assertIn('Makefile has setup, train targets', result['detail']); self.assertTrue(report.ready, text)
        result, _, _ = row(gh_api(None))
        self.assertEqual(result['state'], M.ACTION); self.assertEqual(result['next'], './workspace github-login')
        result, _, _ = row(gh_api({**PUBLIC, 'private': True, 'visibility': 'private'}))
        self.assertEqual(result['state'], M.ACTION); self.assertIn('git@github.com:owner/project.git', result['detail'])
        self.assertEqual(result['next'], './workspace guide ' + M.shell(self.config) + ' --repo owner/project')
        result, _, text = row(gh_api(PUBLIC, base64.b64encode(b'run:\n\ttrue\n').decode()))
        self.assertEqual(result['state'], M.ACTION); self.assertIn('add Makefile targets setup, train', result['detail'])
        self.assertIn('runtime-contract', result['detail']); self.assertEqual(result['next'], M.doctor_command(self.config))
        result, _, _ = row(gh_api(PUBLIC, None))
        self.assertIn('add a Makefile with targets setup, train', result['detail'])
        self.project['commands'] = {'setup': ['python', 'setup.py'], 'run': ['python', 'train.py']}; self.write()
        calls = []
        result, _, _ = row(gh_api(PUBLIC, None, calls))
        self.assertEqual(result['state'], M.READY); self.assertIn('custom commands; Makefile not checked', result['detail'])
        self.assertFalse(any('/contents/' in ' '.join(c) for c in calls))

    def test_invalid_configuration_names_the_field(self):
        self.project['maximum_runtime_minutes'] = 5; self.write()
        report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['Project config'], M.ACTION); self.assertIn('maximum_runtime_minutes', text)
        self.assertNotIn('AWS identity', self.states(report))
        self.project['maximum_runtime_minutes'] = 30; shutil.rmtree(self.directory/'input data'); self.write()
        report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['Project config'], M.ACTION); self.assertIn('dataset', text)

    def test_interrupted_operation_requires_resume_not_a_new_launch(self):
        operation = self.directory/('c'*32); (operation/'journal').mkdir(parents=True)
        M.L['write'](self.pointer, {'directory': str(operation)})
        M.L['write'](operation/'status.json', {'stage': 'launch', 'state': 'started'})
        with patch.object(M.A, 'profile_method', return_value='console'), patch.object(M.A, 'auth_check', return_value={'identity': IDENTITY}):
            report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['Last operation'], M.ACTION); self.assertIn(str(self.config)+' resume', text)
        M.L['write'](operation/'result.json', {'status': 'success', 'cleanup_status': 'success', 'output_uri': 's3://bucket/out/'})
        with patch.object(M.A, 'profile_method', return_value='console'), patch.object(M.A, 'auth_check', return_value={'identity': IDENTITY}):
            report, text = M.doctor(self.config, 'ok', False)
        self.assertEqual(self.states(report)['Last operation'], M.READY); self.assertIn('s3://bucket/out/', text)
        page = json.loads(M.as_json(report, self.config))
        self.assertTrue(page['ready']); self.assertTrue(page['deployed']); self.assertEqual(page['output_uri'], 's3://bucket/out/')
        self.assertEqual(page['repository'], 'public'); self.assertEqual(page['deploy'], './workspace ' + str(self.config))
        self.assertEqual([row['check'] for row in page['rows']], [row['check'] for row in report.rows])

    def test_guide_json_without_configuration_points_to_project_file(self):
        report, _ = M.doctor(None, 'pinned tools verified', False)
        page = json.loads(M.as_json(report, None))
        self.assertFalse(page['ready']); self.assertIsNone(page['config']); self.assertIsNone(page['deploy'])
        self.assertNotIn('deployed', page)
        row = {row['check']: row for row in page['rows']}['Project config']
        self.assertEqual(row['state'], M.ACTION); self.assertIn('~/aws-workspace/demo/project.json', row['next'])

    def test_missing_custom_configuration_uses_its_exact_path_without_network(self):
        config = self.directory/"project's folder/project.json"
        with patch.object(M.A, 'auth_check', side_effect=AssertionError('network call')):
            report, _ = M.doctor(config, 'ok', False)
        row = report.rows[1]
        self.assertEqual(row['state'], M.ACTION)
        self.assertEqual(row['next'], './workspace guide ' + M.shell(config) + ' --repo OWNER/NAME --dataset PATH')
        self.assertEqual(shlex.split(row['next'])[2], str(config), 'the path is quoted as one shell word')
        self.assertEqual(self.states(report)['AWS identity'], M.UNKNOWN)
        self.assertEqual(json.loads(M.as_json(report, config))['expected_config'], str(config))

    def test_debug_lists_names_only(self):
        with patch.dict(os.environ, {**self.files, 'AWS_SECRET_ACCESS_KEY': 'SECRETVALUE', 'GH_TOKEN': 'TOKENVALUE'}, clear=True):
            report, text = M.doctor(None, 'ok', True)
        self.assertIn('Debug (bounded, redacted)', text); self.assertIn('AWS_SECRET_ACCESS_KEY', text); self.assertIn('GH_TOKEN', text)
        self.assertNotIn('SECRETVALUE', text); self.assertNotIn('TOKENVALUE', text)
        self.assertIn('free disk', text)

    def test_launcher_runs_doctor_from_another_directory_without_credentials(self):
        shims = self.directory/'shims'; shims.mkdir()
        (shims/'gh').write_text('#!/bin/sh\nexit 4\n'); (shims/'gh').chmod(0o755)
        environment = {**os.environ, **self.files, 'WORKSPACE_PYTHON': sys.executable, 'PATH': str(shims) + ':' + os.environ['PATH']}
        for key in list(environment):
            if key.startswith(('AWS_', 'GH_', 'GITHUB_')) and key not in self.files: del environment[key]
        result = subprocess.run(['bash', str(ROOT/'workspace'), 'doctor', 'project.json'], cwd=self.directory,
                                env=environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertRegex(result.stdout, r'Project config +Ready'); self.assertRegex(result.stdout, r'GitHub access +Ready')
        self.assertRegex(result.stdout, r'AWS identity +To do')
        self.assertRegex(result.stdout, r'GitHub repository +To do .*\n.*next: ./workspace github-login')
        self.assertIn('./workspace login --profile reviewed-temporary --region us-east-1', result.stdout)
        self.assertIn(str(self.config), result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
