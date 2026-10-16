"""Offline short configuration, read-only discovery and immutable operation checks."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import types
import tempfile
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
        return subprocess.run(['bash', 'workspace', str(self.config), *args],
                              env={**os.environ, 'WORKSPACE_PYTHON': sys.executable},
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
        self.assertTrue(second['execution_supported']); self.assertFalse(second['execution_admitted'])

    def test_new_guided_storage_has_readable_buckets_and_flat_namespaces(self):
        value = self.prepare()['review']
        slug = self.project['project']
        self.assertEqual(value['names']['workload_bucket'], slug+'-storage-111111111111-us-east-1')
        self.assertEqual(value['backend']['bucket'], slug+'-state-111111111111-us-east-1')
        self.assertTrue(value['storage']['data_uri'].endswith('/datasets/'))
        self.assertTrue(value['storage']['output_uri'].endswith('/results/'+value['names']['workspace_id']+'/'))

    def test_retained_foundation_keeps_its_exact_bucket_names_and_layout(self):
        value = self.prepare()['review']
        folder = ROOT/'evidence/aws/projects'/value['names']['resource_prefix']
        folder.mkdir(parents=True, exist_ok=False)
        self.addCleanup(shutil.rmtree, folder)
        prior = self.directory/'retained'; prior.mkdir()
        target = {'account_id':'111111111111','region':'us-east-1',
                  'inventory':{'resource_prefix':value['names']['resource_prefix'],'buckets':['historical-data']},
                  'backend':{'bucket':'historical-state'}}
        L['write'](folder/'foundation.json', {'plan_directory':str(prior)})
        L['write'](prior/'review.json', {'target':target})
        for layout in ('legacy','readable-v1'):
            with self.subTest(layout=layout):
                (prior/'config.tfvars.json').write_text(json.dumps({} if layout=='legacy' else {'storage_layout':layout}))
                retained = self.prepare()['review']
                self.assertEqual(retained['names']['workload_bucket'], 'historical-data')
                self.assertEqual(retained['backend']['bucket'], 'historical-state')
                self.assertEqual(retained['storage_layout'], layout)

    def test_readable_output_scope_is_bound_to_the_whole_run_and_workspace(self):
        from workspace_storage import output_scope, run_folder
        run = 'a'*32
        uri = 's3://data/results/demand-dev/'+run_folder(run,'2026-10-17T14:03:12Z')+'/'
        self.assertEqual(output_scope(uri,'demand-dev',run), 'datasets/')
        for changed in (uri.replace('demand-dev','demand-other'), uri.replace(run,'b'*32),
                        uri+'extra/', uri.replace('/results/','/other/'), uri.replace('/2026','/../2026')):
            with self.assertRaisesRegex(ValueError,'unique output'):
                output_scope(changed,'demand-dev',run)

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

    def test_federated_identity_requires_native_role_resolution(self):
        self.observed['identity']['Arn'] = 'arn:aws:sts::111111111111:assumed-role/Operator/session'
        result = self.prepare()['review']
        self.assertEqual(result['operator_arn'], self.observed['identity']['Arn'])
        self.assertIn('native-operator-role-resolution', result['pending'])
        self.assertTrue(result['execution_supported']); self.assertFalse(result['execution_admitted'])

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
        self.assertIn('short configuration uses deploy', blocked.stderr)

    def test_launcher_preserves_terminal_stdin_descriptor(self):
        runtime = self.directory/'runtime'
        runtime.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps([sys.argv[1:],os.read(3,4096).decode()]))\n')
        runtime.chmod(0o700)
        result = subprocess.run(['bash', 'workspace', 'config.json', 'connect', 'run'],
                                env={**os.environ, 'WORKSPACE_PYTHON': str(runtime)}, input='terminal input',
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [['scripts/aws/workspace.py', str(ROOT/'config.json'), 'connect', 'run'], 'terminal input'])

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


class GitHubDerivation(unittest.TestCase):
    """Repository settings from the read-only GitHub API; responses and input are data."""
    def api(self, *responses):
        calls = []; answers = iter(responses)
        def request(command, env, seconds):
            calls.append(command); code, out, err = next(answers)
            return subprocess.CompletedProcess(command, code, out, err)
        return calls, patch.dict(L['boundary'], {'request': request})

    def test_repository_names_accept_short_and_url_forms_and_never_echo_rejections(self):
        for text in ('owner/repo', ' https://github.com/owner/repo.git ', 'git@github.com:owner/repo.git', 'github.com/owner/repo/'):
            self.assertEqual(P.repository_name(text), 'owner/repo')
        for text in ('owner', 'owner/..', 'https://SECRET@github.com/owner/repo', 'http://github.com/owner/repo',
                     'owner/repo;SECRET', '-owner/repo', 'https://gitlab.com/owner/repo', 'owner/repo/tree/main'):
            with self.assertRaises(ValueError) as caught: P.repository_name(text)
            self.assertNotIn('SECRET', str(caught.exception))

    def test_project_slug_matches_the_schema(self):
        import re
        schema = json.loads((ROOT/'shared/workspace/project.schema.json').read_text())['properties']['project']['pattern']
        for name, slug in (('aws-workspace-e2e', 'aws-workspace-e2e'), ('My_Model.v2', 'my-model-v2'), ('1x', 'ml-x'),
                           ('123', 'ml-project'), ('A'*60, 'a'*24), ('ab-', 'ml-ab'), ('x' * 23 + '-y', 'x' * 23)):
            self.assertEqual(P.project_slug(name), slug); self.assertRegex(slug, schema)
        self.assertTrue(all(re.fullmatch(schema, P.project_slug(n)) for n in ('a', '_', '.github', 'Z--z', '9-to-5')))

    def test_make_targets_is_a_simple_rule_parse(self):
        text = ('SHELL := /bin/bash\nVAR ::= x\nX = a:b\n.PHONY: setup train\n# setup: comment\n'
                'run:\n\tnot: a-target\nsetup train: deps\ncheck::\n%.o: %.c\n')
        self.assertEqual(P.make_targets(text), {'run', 'setup', 'train', 'check'})
        self.assertEqual(P.make_goals({'setup': ['make', 'setup'], 'run': ['make', 'train']}), ['setup', 'train'])
        self.assertEqual(P.make_goals({'setup': ['make', '-C', 'x', 'setup'], 'run': ['python', 'train.py']}), [])

    def test_private_repository_derives_ssh_url_default_branch_and_missing_targets(self):
        import base64
        repository = json.dumps({'full_name': 'Owner/Repo', 'private': True, 'visibility': 'private', 'default_branch': 'feat/x'})
        makefile = json.dumps({'type': 'file', 'encoding': 'base64', 'content': base64.b64encode(b'run:\n\ttrue\n').decode()})
        calls, boundary = self.api((0, repository, ''), (0, makefile, ''))
        with boundary:
            facts = P.github_repository(L, 'owner/repo', None, {'setup': ['make', 'setup'], 'run': ['make', 'train']})
        self.assertEqual((facts['url'], facts['ref'], facts['missing']), ('git@github.com:Owner/Repo.git', 'feat/x', ['setup', 'train']))
        self.assertEqual(calls[1][-1], 'repos/Owner/Repo/contents/Makefile?ref=feat%2Fx')
        self.assertTrue(all(c[:6] == ['gh', 'api', '--hostname', 'github.com', '--method', 'GET'] for c in calls))
        self.assertIn('add Makefile targets setup, train', P.makefile_todo(facts))

    def test_unexpected_or_failed_responses_fail_closed_without_echoing_them(self):
        for response in ((0, json.dumps({'full_name': 'owner/repo; SECRET', 'private': False, 'default_branch': 'main'}), ''),
                         (0, json.dumps({'full_name': 'owner/repo', 'private': False, 'default_branch': '../SECRET'}), ''),
                         (0, 'SECRET not json', ''), (1, '', 'SECRET HTTP 500'), (1, '', 'gh: Not Found (HTTP 404)')):
            _, boundary = self.api(response)
            with boundary, self.assertRaises(L['Failure']) as caught:
                P.github_repository(L, 'owner/repo')
            self.assertNotIn('SECRET', str(caught.exception))


class AccessMigration(unittest.TestCase):
    def test_public_repository_can_plan_exact_iam_update_without_git_secret(self):
        directory = OUT/'public-access'
        foundation = OUT/'retained-foundation'
        platform = {'workspace_git_secret_arns': {}, 'retained': 'unchanged'}
        value = {'repository': {'url': 'https://github.com/owner/project.git'},
                 'project': 'example', 'target_name': 'aws-example',
                 'foundation': {'plan_directory': str(foundation)}}
        with patch.object(sys, 'argv', ['workspace', 'config.json', 'plan', str(directory), 'access']), \
             patch.object(W, 'configuration', return_value=(value, {})), \
             patch.object(W, 'run_configuration', return_value=(directory, {})), \
             patch.object(W, 'read', return_value=platform), patch.object(W, 'write') as write, \
             patch.dict(L, {'load_json': lambda _: {}}), \
             patch.dict(L, {'native_plan': lambda *args: {'stage': args[1], 'config': args[2]}}), \
             patch.object(sys, 'stdout', new_callable=io.StringIO) as output:
            W.main()
        write.assert_called_once_with(directory/'access.tfvars.json', platform)
        self.assertEqual(platform['workspace_git_secret_arns'], {})
        self.assertEqual(json.loads(output.getvalue())['stage'], 'workspace-access')


class Launcher(unittest.TestCase):
    def test_help_needs_no_tools_or_downloads(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)/'must-not-be-installed'
            environment = {**os.environ, 'WORKSPACE_TOOLS_DIR': str(tools)}
            environment.pop('WORKSPACE_PYTHON', None)
            for entry in (ROOT/'workspace',):
                result = subprocess.run(['bash', str(entry), '--help'], cwd=directory,
                                        env=environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Deploy is the default command', result.stdout)
            self.assertFalse(tools.exists())

    def test_default_deploy_preserves_paths_and_authorization_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            python = Path(directory)/'runtime'
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            python.chmod(0o755)
            environment = {**os.environ, 'WORKSPACE_PYTHON': str(python)}
            cases = [([], ['deploy']),
                     (['--authorization', 'reviewed scope with spaces'],
                      ['deploy', '--authorization', 'reviewed scope with spaces']),
                     (['status', '--wait', '0'], ['status', '--wait', '0'])]
            for entry in (ROOT/'workspace',):
                for arguments, expected in cases:
                    result = subprocess.run(['bash', str(entry), 'project with spaces.json', *arguments],
                                            cwd=directory, env=environment, capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(),
                                     ['scripts/aws/workspace.py', str(Path(directory)/'project with spaces.json'), *expected])


if __name__ == '__main__':
    unittest.main(verbosity=2)
