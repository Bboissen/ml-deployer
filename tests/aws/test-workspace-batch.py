"""Offline batch review, sequential runs, retries, stops and restart recovery; no AWS calls."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT/'scripts/aws'))
spec = importlib.util.spec_from_file_location('batch_workspace', ROOT/'scripts/aws/workspace.py')
W = importlib.util.module_from_spec(spec); spec.loader.exec_module(W)
import workspace_batch as B
import workspace_target
L = W.L
SOURCE = {'revision': 'a'*40, 'working_tree_sha256': L['sha'](b'')}
LAUNCHED = {'status': 'success', 'cleanup_status': 'success', 'recovery_required': False, 'infrastructure_ready': True,
            'setup_exit': 0, 'job_exit': 0, 'outputs_persisted': True}


class Account:
    """Fake prepare/deploy/resume with scripted results per job."""
    def __init__(self, test, root):
        self.test, self.root = test, root
        self.price, self.foundation, self.revision, self.rebinding = 0.6, True, 'a'*40, None
        self.results, self.resumed, self.deploys, self.prepared = {}, {}, [], []
        self.registry = root/'registry'; self.registry.mkdir()

    def scope(self, config, directory):
        name = Path(config).stem
        size = {**L['supported_sizes']()['r8i.2xlarge'], 'policy': 'ram-first', 'instance_type': 'r8i.2xlarge',
                'availability_zone': 'us-east-1a', 'hourly_usd': self.price}
        return {'operation_id': directory.name, 'source': {**SOURCE, 'revision': self.revision},
                'configuration_sha256': L['sha'](Path(config).read_bytes()),
                'target': {'profile': 'offline', 'region': 'us-east-1', 'account_id': '111111111111',
                           'operator_arn': 'arn:aws:iam::111111111111:role/operator', 'inventory': {'resource_prefix': 'offline-'+self.root.name}},
                'repository': {'url': 'https://github.com/owner/ml.git', 'revision': 'b'*40},
                'dataset': {'inventory': [{'path': name, 'bytes': 1, 'sha256': 'c'*64}], 'total_bytes': 1},
                'disk': {'usable_bytes': 1}, 'outputs': {'paths': ['outputs'], 'maximum_bytes': 1}, 'mode': 'job',
                'maximum_runtime_minutes': 60, 'max_ec2_launches': 1, 'capacity': {'selected': size, 'candidates': [size]},
                'foundation': {'plan_directory': 'retained'} if self.foundation else None, 'foundation_iam_migration': None, 'foundation_operator_rebinding': self.rebinding,
                'new_private_access': False, 'registry_directory': str(self.registry), 'estimated_compute_usd': self.price,
                'additional_cost_scope': ['gp3 root disk']}

    def prepare(self, _W, config, directory=None, instance_type=None):
        self.test.assertIsNone(directory)
        directory = self.root/'operations'/os.urandom(16).hex(); directory.mkdir(parents=True)
        L['write'](directory/'deployment.json', {'names': {'workspace_id': 'ml-batch'}})
        scope = self.scope(config, directory); L['write'](directory/'scope.json', scope)
        self.prepared.append((Path(config).stem, instance_type))
        return directory, scope

    def deploy(self, _W, config, directory, authorization):
        name = Path(config).stem; scope = L['read'](directory/'scope.json')
        self.test.assertIn('approve scope '+L['sha'](L['canon'](scope))[:16], authorization)
        L['write'](directory/'task-authorization.json', {'authorization': authorization})
        self.deploys.append(name)
        script = self.results.get(name, [LAUNCHED])
        result = script.pop(0) if len(script) > 1 else script[0]
        if callable(result): result = result(directory)
        if result.get('infrastructure_ready') or result.get('launched'):
            (directory/'workspace/launch').mkdir(parents=True); L['write'](directory/'workspace/launch/apply-started.json', {})
        return {k: v for k, v in result.items() if k != 'launched'}

    def resume(self, _W, config, directory):
        name = Path(config).stem; self.resumed[name] = self.resumed.get(name, 0)+1
        return self.results.get(name+':resume', [LAUNCHED])[0]


class Batch(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT/'evidence'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.account = Account(self, self.root)
        self.projects = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.projects)
        self.configs = []
        for name in ('a', 'b', 'c'):
            path = self.projects/('m-'+name+'-project.json'); path.write_text(json.dumps({'project': name, 'profile': 'offline', 'region': 'us-east-1',
                                                                'commands': {'run': ['make', 'train', 'RUN='+name]}, 'resources': {'policy': 'ram-first'}}))
            self.configs.append(str(path))
        # Batch evidence lives under the real evidence root; remove exactly what this test created.
        pointers = ROOT/'evidence/aws/batch-selections'; before = set(pointers.glob('*')) if pointers.exists() else set()
        latest = pointers/'latest.json'; saved = latest.read_bytes() if latest.exists() else None
        def restore():
            for path in (set(pointers.glob('*')) if pointers.exists() else set())-before:
                if path.name != 'latest.json': path.unlink()
            if saved is None: latest.unlink(missing_ok=True)
            else: latest.write_bytes(saved)
            for directory in self.batches:
                shutil.rmtree(directory, ignore_errors=True)
                (ROOT/'evidence/aws/locks'/('batch-'+directory.name+'.lock')).unlink(missing_ok=True)
            (ROOT/'evidence/aws/locks'/('offline-'+self.root.name+'.lock')).unlink(missing_ok=True)
        self.batches = []; self.addCleanup(restore)
        A = types.SimpleNamespace(ensure_login=lambda *a, **k: None, auth_check=lambda *a: None)
        self.real_wait = B.wait_for_slot
        for target, value in ((B.D, {'prepare': self.account.prepare, 'deploy': self.account.deploy, 'resume': self.account.resume}),
                              (B, {'interactive': lambda: False, 'wait_for_slot': lambda *_: None, 'RETRY_SECONDS': 0}),
                              (W.P, {'validate_project': lambda _L, path: json.loads(Path(path).read_text())})):
            for key, replacement in value.items():
                patcher = patch.object(target, key, replacement); patcher.start(); self.addCleanup(patcher.stop)
        for key, replacement in {'source': lambda: SOURCE, 'A': A}.items():
            store = L if key == 'source' else vars(W)
            patcher = patch.dict(store, {key: replacement}); patcher.start(); self.addCleanup(patcher.stop)

    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = B.main(vars(W), [*args])
        result = json.loads(out.getvalue()); result['exit'] = code; result['stderr'] = err.getvalue()
        if result.get('batch_directory'):
            directory = Path(result['batch_directory'])
            if directory not in self.batches: self.batches.append(directory)
        return result

    def reviewed(self, *options, configs=None):
        review = self.cli(*(configs or self.configs), *options)
        self.assertEqual((review['status'], review['exit'], self.account.deploys), ('review_required', 0, []))
        return review, 'approve batch '+review['batch_sha256'][:16]

    def run_batch(self, authorization, *options, configs=None):
        return self.cli(*(configs or self.configs), *options, '--authorization', authorization)

    def test_one_review_pins_each_scope_and_runs_jobs_in_order(self):
        review, authorization = self.reviewed()
        self.assertEqual([j['name'] for j in review['review']['jobs']], ['m-a', 'm-b', 'm-c'])
        self.assertEqual(review['review']['estimated_compute_usd'], 1.8)
        self.assertIn('about 1.80 USD of compute', review['stderr']); self.assertIn('run: ', review['stderr'])
        self.assertNotIn('spend', json.dumps(review['review']))
        with self.assertRaisesRegex(workspace_target.Failure, 'batch scope'):
            self.run_batch('approve batch 0000000000000000')
        result = self.run_batch(authorization)
        self.assertEqual((result['status'], result['exit']), ('completed', 0))
        self.assertEqual(self.account.deploys, ['m-a-project', 'm-b-project', 'm-c-project'])
        # Every attempt re-prepares its own scope with the reviewed size pinned.
        self.assertEqual(self.account.prepared[3:], [(n, 'r8i.2xlarge') for n in ('m-a-project', 'm-b-project', 'm-c-project')])
        self.assertEqual([j['status'] for j in result['jobs']], ['success']*3)
        self.assertEqual(L['read'](Path(result['batch_directory'])/'manifest.json')['status'], 'completed')
        again = self.run_batch(authorization)
        self.assertEqual((again['status'], len(self.account.deploys)), ('completed', 3))

    def test_review_refuses_missing_foundation_duplicates_and_dirty_source(self):
        self.account.foundation = False
        with self.assertRaisesRegex(workspace_target.Failure, 'retained foundation'): self.cli(*self.configs)
        self.account.foundation, self.account.rebinding = True, {'from': 'old', 'to': 'new'}
        with self.assertRaisesRegex(workspace_target.Failure, 'retained foundation'): self.cli(*self.configs)
        self.account.rebinding = None
        with self.assertRaisesRegex(workspace_target.Failure, 'unique'): self.cli(self.configs[0], self.configs[0])
        with patch.dict(L, {'source': lambda: {**SOURCE, 'working_tree_sha256': 'd'*64}}):
            with self.assertRaisesRegex(workspace_target.Failure, 'clean committed'): self.cli(*self.configs)

    def test_launch_failures_retry_then_skip_counting_only_started_launches(self):
        never = {'status': 'failure', 'cleanup_status': 'not_needed', 'recovery_required': False, 'infrastructure_ready': False, 'job_exit': None}
        self.account.results['m-a-project'] = [{**never, 'launched': True}, never, never]
        _, authorization = self.reviewed('--launch-attempts', '3')
        result = self.run_batch(authorization, '--launch-attempts', '3')
        self.assertEqual(self.account.deploys, ['m-a-project']*3+['m-b-project', 'm-c-project'])
        self.assertEqual([(j['status'], j['attempts']) for j in result['jobs']], [('skipped', 3), ('success', 1), ('success', 1)])
        self.assertEqual(result['jobs'][0]['estimated_compute_usd'], 0.6)
        self.assertEqual((result['status'], result['exit']), ('completed', 1))

    def test_consecutive_job_failures_stop_and_rerun_continues(self):
        failed = {**LAUNCHED, 'status': 'failure', 'job_exit': 1}
        self.account.results.update({'m-a-project': [failed], 'm-b-project': [failed]})
        _, authorization = self.reviewed()
        result = self.run_batch(authorization)
        self.assertEqual((result['status'], self.account.deploys), ('stopped', ['m-a-project', 'm-b-project']))
        self.assertIn('2 consecutive job failures', result['reason'])
        self.assertEqual(self.run_batch(authorization)['status'], 'completed')
        self.assertEqual(self.account.deploys[-1], 'm-c-project')

    def account_calls(self, usage):
        """Run the real slot check against fake quota observations."""
        onboarding = types.SimpleNamespace(vcpu_usage=lambda *_: (*usage.pop(0), {}))
        return contextlib.ExitStack(), [patch.object(B, 'wait_for_slot', self.real_wait),
                                        patch.object(B.D, 'extensions', return_value={'onboarding': onboarding}),
                                        patch.dict(L, {'sessions': lambda target: (None, None, None)})]

    def test_expired_sign_in_pauses_before_launch_and_rerun_continues(self):
        _, authorization = self.reviewed()
        stack, patches = self.account_calls([(8, 0)]*3)
        with stack:
            for item in patches: stack.enter_context(item)
            with patch.object(vars(W)['A'], 'auth_check', side_effect=workspace_target.LoginRequired('expired')):
                result = self.run_batch(authorization)
            self.assertEqual((result['status'], self.account.deploys), ('stopped', []))
            self.assertIn('sign-in expired', result['reason'])
            self.assertEqual(self.run_batch(authorization)['status'], 'completed')

    def test_scope_drift_stops_without_authorizing_a_launch(self):
        _, authorization = self.reviewed()
        for change in ({'price': 0.7}, {'revision': 'e'*40}):
            with self.subTest(change=change):
                for key, value in change.items(): setattr(self.account, key, value)
                result = self.run_batch(authorization)
                self.assertEqual((result['status'], self.account.deploys), ('stopped', []))
                self.assertIn('differs from the batch review', result['reason'])
                self.account.price, self.account.revision = 0.6, 'a'*40
        self.assertEqual(self.run_batch(authorization)['status'], 'completed')

    def test_restart_reconciles_an_open_attempt_without_relaunching(self):
        _, authorization = self.reviewed()
        def crash(directory):
            raise KeyboardInterrupt('controller lost')
        self.account.results['m-a-project'] = [crash]
        with self.assertRaises(KeyboardInterrupt): self.run_batch(authorization)
        self.assertEqual(self.account.deploys, ['m-a-project'])
        status = self.cli('status')
        self.assertEqual(status['status'], 'stopped'); self.assertIn('ended unexpectedly', status['reason'])
        result = self.run_batch(authorization)
        self.assertEqual(self.account.resumed, {'m-a-project': 1})
        self.assertEqual(self.account.deploys, ['m-a-project', 'm-b-project', 'm-c-project'])
        self.assertEqual(result['jobs'][0]['status'], 'success')

    def test_attempt_interrupted_before_authorization_is_abandoned_and_retried(self):
        _, authorization = self.reviewed()
        original = self.account.deploy
        def lost(*args):
            self.account.deploy = original; raise KeyboardInterrupt('lost before authorization')
        with patch.object(B.D, 'deploy', lost):
            with self.assertRaises(KeyboardInterrupt): self.run_batch(authorization)
        result = self.run_batch(authorization)
        self.assertEqual(self.account.resumed, {})
        self.assertEqual((result['jobs'][0]['status'], result['jobs'][0]['attempts']), ('success', 2))

    def test_unconfirmed_cleanup_resumes_once_then_stops(self):
        unsettled = {**LAUNCHED, 'status': 'failure', 'cleanup_status': 'unknown', 'recovery_required': True}
        self.account.results.update({'m-a-project': [unsettled], 'm-a-project:resume': [unsettled]})
        _, authorization = self.reviewed()
        result = self.run_batch(authorization)
        self.assertEqual((result['status'], self.account.resumed, self.account.deploys), ('stopped', {'m-a-project': 1}, ['m-a-project']))
        self.assertIn('resume', result['reason'])
        self.account.results['m-a-project:resume'] = [LAUNCHED]
        self.assertEqual(self.run_batch(authorization)['status'], 'completed')
        self.assertEqual(self.account.deploys, ['m-a-project', 'm-b-project', 'm-c-project'])

    def test_interrupted_or_cancelled_job_stops_the_batch(self):
        interrupted = {'status': 'failure', 'cleanup_status': 'success', 'recovery_required': False, 'infrastructure_ready': True,
                       'job_exit': None, 'error': {'type': 'InterruptedError', 'code': None}}
        cancelled = {**LAUNCHED, 'status': 'cancelled', 'job_exit': None}
        self.account.results.update({'m-a-project': [interrupted, LAUNCHED], 'm-b-project': [cancelled]})
        _, authorization = self.reviewed()
        self.assertIn('interrupted', self.run_batch(authorization)['reason'])
        result = self.run_batch(authorization)
        self.assertIn('cancelled', result['reason'])
        result = self.run_batch(authorization)
        self.assertEqual([j['status'] for j in result['jobs']], ['success', 'cancelled', 'success'])
        self.assertEqual(self.account.deploys, ['m-a-project', 'm-a-project', 'm-b-project', 'm-c-project'])

    def test_wait_for_slot_waits_for_quota_and_refuses_a_foreign_operation(self):
        review, _ = self.reviewed()
        job = review['review']['jobs'][0]; sleeps = []
        stack, patches = self.account_calls([(8, 8), (8, 0)])
        with stack, contextlib.redirect_stderr(io.StringIO()) as err:
            for item in patches[1:]: stack.enter_context(item)
            stack.enter_context(patch.object(B.time, 'sleep', sleeps.append))
            self.real_wait(vars(W), job)
            self.assertEqual(sleeps, [B.SLOT_SECONDS]); self.assertIn('8 of the 8 vCPU quota', err.getvalue())
            L['write'](Path(job['registry'])/'ml-batch-active.json', {'operation_id': 'f'*32})
            with self.assertRaisesRegex(B.Stop, 'another operation owns'): self.real_wait(vars(W), job)
            with patch.object(vars(W)['A'], 'auth_check', side_effect=workspace_target.LoginRequired('expired')):
                with self.assertRaisesRegex(B.Stop, 'sign-in expired'): self.real_wait(vars(W), job)

if __name__ == '__main__':
    unittest.main()
