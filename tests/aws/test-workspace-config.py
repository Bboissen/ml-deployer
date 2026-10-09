"""Offline short configuration, read-only discovery and immutable operation checks."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location('aws_workspace', ROOT/'scripts/aws/workspace.py')
W = importlib.util.module_from_spec(spec); spec.loader.exec_module(W)
P, L = W.P, W.L
OUT = ROOT/'evidence/aws/tests/config'/uuid.uuid4().hex
OUT.mkdir(parents=True)


class Configuration(unittest.TestCase):
    def setUp(self):
        self.directory = OUT/self.id().split('.')[-1]
        self.directory.mkdir()
        (self.directory/'dataset').mkdir()
        (self.directory/'dataset'/'input with spaces.csv').write_bytes(b'1\n2\n')
        self.project = json.loads((ROOT/'infra/aws/project.example.json').read_text())
        self.config = self.directory/'project.json'
        self.discovery = self.directory/'discovery.json'
        self.observed = {'schema_version': '1.0.0', 'kind': 'aws-project-discovery',
                         'profile': self.project['profile'], 'region': self.project['region'],
                         'identity': {'Account': '111111111111', 'Arn': 'arn:aws:iam::111111111111:user/operator'},
                         'repository': {**self.project['repository'], 'revision': 'a'*40,
                                        'resolved_ref': 'refs/heads/main', 'verification': 'advertised-ref'}}

    def save(self):
        self.config.write_text(json.dumps(self.project))
        self.discovery.write_text(json.dumps(self.observed))

    def prepare(self):
        self.save()
        with patch.object(P, 'discover', side_effect=AssertionError('offline configure called live discovery')):
            return P.configure(L, self.config, self.discovery)

    def rejected(self):
        with self.assertRaises(L['Failure']):
            self.prepare()

    def cli(self, *args):
        return subprocess.run(['bash', 'scripts/aws/workspace.sh', str(self.config), *args],
                              capture_output=True, text=True, timeout=20)

    def test_two_accounts_and_projects_generate_distinct_scopes(self):
        first = self.prepare()['review']
        self.project.update(project='fraud-model', workspace='test-02', profile='other-temporary')
        self.observed.update(profile='other-temporary', identity={'Account': '222222222222',
                              'Arn': 'arn:aws:iam::222222222222:user/other'})
        second = self.prepare()['review']
        self.assertNotEqual(first['names']['workload_bucket'], second['names']['workload_bucket'])
        self.assertNotEqual(first['backend']['bucket'], second['backend']['bucket'])
        self.assertEqual(second['names']['workspace_id'], 'fraud-model-test-02')
        self.assertIn('222222222222', second['storage']['state_uri'])
        self.assertEqual(second['dataset']['bytes'], 4)
        self.assertFalse(second['execution_supported'])

    def test_default_job_mode_declares_setup_and_run_without_executing(self):
        marker = self.directory/'never-execute'
        self.project['commands']['run'] = [sys.executable, '-c', 'from pathlib import Path; Path('+repr(str(marker))+').touch()']
        result = self.prepare()
        self.assertEqual(result['review']['configuration']['mode'], 'job')
        self.assertTrue(result['review']['scope']['execute_on_deploy'])
        self.assertEqual(result['review']['scope']['commands'], self.project['commands'])
        self.assertEqual(result['review']['scope']['cleanup'], 'owned-compute')
        self.assertFalse(marker.exists())
        self.assertFalse(result['deployment_authorized'])
        self.assertEqual(result['discovery_origin'], 'supplied-offline')

    def test_workspace_mode_preserves_absolute_expiry_policy(self):
        self.project['mode'] = 'workspace'
        scope = self.prepare()['review']['scope']
        self.assertFalse(scope['execute_on_deploy'])
        self.assertEqual(scope['cleanup'], 'explicit-or-absolute-expiry')

    def test_same_inputs_keep_names_and_create_separate_immutable_operations(self):
        first = self.prepare(); second = self.prepare()
        self.assertEqual(first['review'], second['review'])
        self.assertNotEqual(first['operation_id'], second['operation_id'])
        before = (ROOT/first['operation_directory']/'operation.json').read_bytes()
        P.operation_status(L, self.config, first['operation_directory'])
        self.assertEqual(before, (ROOT/first['operation_directory']/'operation.json').read_bytes())

    def test_long_project_names_do_not_collide_or_exceed_bucket_limits(self):
        self.project.update(project='abcdefghijklmnopqrstuvwx', workspace='experiment-01')
        first = self.prepare()['review']
        self.project['project'] = 'abcdefghijklmnopqrstuvwy'
        second = self.prepare()['review']
        self.assertLessEqual(len(first['backend']['bucket']), 63)
        self.assertNotEqual(first['backend']['bucket'], second['backend']['bucket'])

    def test_existing_operation_directory_is_preserved_on_collision(self):
        result = self.prepare()
        directory = ROOT/result['operation_directory']
        before = (directory/'operation.json').read_bytes()
        with patch.object(P.uuid, 'uuid4', return_value=types.SimpleNamespace(hex=result['operation_id'])):
            with self.assertRaises(FileExistsError):
                self.prepare()
        self.assertEqual(before, (directory/'operation.json').read_bytes())

    def test_unknown_secret_field_and_unknown_version_rejected_without_echo(self):
        for change in ({'password': 'PRIVATE_TOKEN_CANARY'}, {'schema_version': '2.0.0'}):
            with self.subTest(change=list(change)):
                self.project.update(change); self.save()
                result = self.cli('configure', '--discovery', str(self.discovery))
                self.assertEqual(result.returncode, 2)
                self.assertNotIn('PRIVATE_TOKEN_CANARY', result.stdout+result.stderr)
                self.project = json.loads((ROOT/'infra/aws/project.example.json').read_text())

    def test_duplicate_fields_nonfinite_and_boolean_lifetime_rejected(self):
        self.project['maximum_runtime_minutes'] = True
        self.rejected()
        for raw in ('{"schema_version":"1.0.0","schema_version":"1.0.0"}', '{"price":NaN}'):
            self.config.write_text(raw)
            with self.assertRaises(L['Failure']):
                P.validate_project(L, self.config)

    def test_unknown_nested_fields_commands_and_output_traversal_rejected(self):
        baseline = copy.deepcopy(self.project)
        for field, change in [('resources', {'policy': 'ram-first', 'instance_type': 'giant'}),
                              ('commands', {'setup': [], 'run': ['make']}),
                              ('commands', {'setup': ['make'], 'run': '-shell string'}),
                              ('outputs', {'paths': ['../outside']}), ('outputs', {'paths': ['/tmp/out']}),
                              ('outputs', {'paths': ['.git/config']}), ('outputs', {'paths': ['a//b']})]:
            with self.subTest(field=field, change=change):
                self.project = copy.deepcopy(baseline); self.project[field] = change; self.rejected()

    def test_unsupported_cloud_and_region_stop_before_discovery(self):
        self.save()
        for field, value in [('provider', 'gcp'), ('provider', 'azure'), ('region', 'us-west-2')]:
            self.project[field] = value; self.config.write_text(json.dumps(self.project))
            with patch.object(P, 'discover') as discover:
                with self.assertRaises(L['Failure']):
                    P.configure(L, self.config)
                discover.assert_not_called()
            self.project = json.loads((ROOT/'infra/aws/project.example.json').read_text())

    def test_identity_profile_region_and_repository_mismatches_rejected(self):
        baseline = copy.deepcopy(self.observed)
        for field, value in [('profile', 'foreign'), ('region', 'us-west-2'),
                             ('identity', {'Account': '111111111111', 'Arn': 'arn:aws:iam::222222222222:user/operator'}),
                             ('identity', {'Account': '111111111111', 'Arn': 'arn:aws:iam::111111111111:root'}),
                             ('repository', {**baseline['repository'], 'revision': 'bad'}),
                             ('repository', {**baseline['repository'], 'resolved_ref': 'refs/heads/foreign'})]:
            with self.subTest(field=field):
                self.observed = copy.deepcopy(baseline); self.observed[field] = value; self.rejected()

    def test_federated_identity_is_recorded_with_native_grant_blocker(self):
        self.observed['identity']['Arn'] = 'arn:aws:sts::111111111111:assumed-role/Operator/session'
        result = self.prepare()['review']
        self.assertEqual(result['operator_arn'], self.observed['identity']['Arn'])
        self.assertIn('operator-grants-unsupported-by-current-runner', result['pending'])
        self.assertFalse(result['execution_supported'])

    def test_repository_credentials_invalid_refs_and_signed_dataset_url_rejected(self):
        baseline = copy.deepcopy(self.project)
        for url, ref in [('https://PRIVATE_TOKEN_CANARY@github.com/owner/project.git', 'main'),
                         ('https://evil.example/owner/project.git', 'main'),
                         ('https://github.com/owner/project.git', '-options'),
                         ('https://github.com/owner/project.git', 'a..b')]:
            self.project['repository'] = {'url': url, 'ref': ref}; self.rejected()
        self.project = baseline
        for source in ('sftp://server/dataset', 'https://user:PRIVATE_TOKEN_CANARY@example.org/data',
                       'https://example.org/data?token=PRIVATE_TOKEN_CANARY', 's3://bucket/../other',
                       'https://example.org:PRIVATE_TOKEN_CANARY/data'):
            self.project['dataset']['source'] = source; self.rejected()
            self.save()
            result = self.cli('configure', '--discovery', str(self.discovery))
            self.assertNotIn('PRIVATE_TOKEN_CANARY', result.stdout+result.stderr)

    def test_local_paths_spaces_missing_empty_symlinks_and_special_files(self):
        first = self.prepare()['review']['dataset']
        self.assertEqual(first['files'], 1)
        self.assertEqual(first['verification'], 'metadata-only')
        self.project['dataset']['source'] = 'dataset/input with spaces.csv'
        self.assertEqual(self.prepare()['review']['dataset']['bytes'], 4)
        (self.directory/'empty').mkdir()
        (self.directory/'linked').symlink_to(self.directory/'dataset', target_is_directory=True)
        for source in ('missing', 'empty', 'linked'):
            self.project['dataset']['source'] = source; self.rejected()
        self.project['dataset']['source'] = 'dataset'
        (self.directory/'dataset'/'linked-file').symlink_to(self.directory/'dataset'/'input with spaces.csv')
        self.rejected()
        self.project['dataset']['source'] = 'pipe'
        os.mkfifo(self.directory/'pipe'); self.rejected()

    def test_remote_sources_remain_unverified_and_do_not_transfer(self):
        for source in ('s3://source-bucket/dataset/', 'https://example.org/data.csv'):
            self.project['dataset']['source'] = source
            data = self.prepare()['review']['dataset']
            self.assertIsNone(data['bytes']); self.assertFalse(data['uploaded'])
            self.assertEqual(data['verification'], 'pending-ingestion')

    def test_dataset_scan_timeout_stops_before_discovery(self):
        self.save()
        with patch.object(P.time, 'monotonic', side_effect=[0, 31]), patch.object(P, 'discover') as discover:
            with self.assertRaisesRegex(L['Failure'], '30 seconds'):
                P.configure(L, self.config)
            discover.assert_not_called()

    def test_status_rejects_changed_configuration_and_artifacts(self):
        result = self.prepare(); directory = ROOT/result['operation_directory']
        self.assertEqual(P.operation_status(L, self.config, directory)['status'], 'prepared')
        self.project['commands']['run'] = ['make', 'other']; self.save()
        with self.assertRaises(L['Failure']):
            P.operation_status(L, self.config, directory)
        self.project['commands']['run'] = ['make', 'train']; self.save()
        (directory/'deployment.json').write_text('{}')
        with self.assertRaises(L['Failure']):
            P.operation_status(L, self.config, directory)

    def test_cli_configure_status_and_deployment_gate(self):
        self.save()
        prepared = self.cli('configure', '--discovery', str(self.discovery))
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        result = json.loads(prepared.stdout)
        status = self.cli('status', result['operation_directory'])
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)['operation_id'], result['operation_id'])
        blocked = self.cli('run', result['operation_directory'], '--authorization', 'source improvement only')
        self.assertEqual(blocked.returncode, 2)
        self.assertIn('generic deployment is pending', blocked.stderr)

    def test_launcher_preserves_terminal_stdin_descriptor(self):
        runtime = self.directory/'runtime'
        runtime.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps([sys.argv[1:],os.read(3,4096).decode()]))\n')
        runtime.chmod(0o700)
        result = subprocess.run(['bash', 'scripts/aws/workspace.sh', 'config.json', 'connect', 'run'],
                                env={**os.environ, 'WORKSPACE_PYTHON': str(runtime)}, input='terminal input',
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [['scripts/aws/workspace.py', 'config.json', 'connect', 'run'], 'terminal input'])

    def test_status_rejects_symlink_and_changed_operation_flags(self):
        result = self.prepare(); directory = ROOT/result['operation_directory']
        (self.directory/'operation-link').symlink_to(directory, target_is_directory=True)
        with self.assertRaises(L['Failure']):
            P.operation_status(L, self.config, self.directory/'operation-link')
        record = json.loads((directory/'operation.json').read_text())
        record['deployment_authorized'] = True
        (directory/'operation.json').write_text(json.dumps(record))
        with self.assertRaises(L['Failure']):
            P.operation_status(L, self.config, directory)


class Discovery(unittest.TestCase):
    def setUp(self):
        self.repository = {'url': 'https://github.com/owner/project.git', 'ref': 'main'}

    def lookup(self, text, repository=None, code=0):
        with patch.dict(L['boundary'], {'request': lambda argv, env, seconds: subprocess.CompletedProcess(argv, code, text, '')}):
            return P.git_ref(L, repository or self.repository)

    def test_branch_tag_and_annotated_tag_resolve_exact_commit(self):
        self.assertEqual(self.lookup('a'*40+'\trefs/heads/main\n')['revision'], 'a'*40)
        repo = {**self.repository, 'ref': 'refs/tags/release'}
        tag = self.lookup('b'*40+'\trefs/tags/release\n'+'c'*40+'\trefs/tags/release^{}\n', repo)
        self.assertEqual(tag['revision'], 'c'*40)

    def test_ambiguous_missing_unexpected_and_failed_ref_lookup_rejected(self):
        for text in ('a'*40+'\trefs/heads/main\n'+'b'*40+'\trefs/tags/main\n', '', 'not a ref',
                     'a'*40+'\trefs/heads/foreign\n'):
            with self.assertRaises(L['Failure']):
                self.lookup(text)
        with self.assertRaises(L['Failure']):
            self.lookup('PRIVATE_TOKEN_CANARY', code=1)

    def test_full_commit_stays_pin_only_without_git_or_fetch_claim(self):
        with patch.dict(L['boundary'], {'request': lambda *a: self.fail('pin-only called Git')}):
            result = P.git_ref(L, {**self.repository, 'ref': 'd'*40})
        self.assertEqual(result['revision'], 'd'*40)
        self.assertEqual(result['verification'], 'pin-only')

    def test_discovery_uses_existing_profile_boundary_and_only_sts(self):
        project = json.loads((ROOT/'infra/aws/project.example.json').read_text())
        calls = []
        def aws(target, environment, args, query):
            calls.append((target['profile'], target['region'], args))
            return {'status': 'observed', 'data': {'Account': '111111111111', 'Arn': 'arn:aws:iam::111111111111:user/operator'}}
        with patch.dict(L['boundary'], {'profile_environment': lambda profile, region: {}, 'aws': aws}), \
             patch.object(P, 'git_ref', return_value={**project['repository'], 'revision': 'a'*40,
                          'resolved_ref': 'refs/heads/main', 'verification': 'advertised-ref'}):
            result = P.discover(L, project)
        self.assertEqual(calls, [(project['profile'], project['region'], ['sts', 'get-caller-identity'])])
        P.validate_discovery(L, project, result)


if __name__ == '__main__':
    unittest.main(verbosity=2)
