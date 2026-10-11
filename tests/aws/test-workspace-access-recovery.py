"""Repeated controller loss preserves the original reviewed IAM transition."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location('workspace', ROOT/'scripts/aws/workspace.py')
workspace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace)
L = workspace.L


class RepeatedAccessRecovery(unittest.TestCase):
    def test_noop_recovery_retains_original_changes_after_repeated_interruptions(self):
        operator = 'arn:aws:iam::111111111111:user/operator'
        address = 'aws_iam_role_policy.deployer'
        before = {'Version': '2012-10-17', 'Statement': [
            {'Sid': 'ManageReviewedNonRootTerminalDocuments', 'Effect': 'Allow',
             'Action': ['ssm:GetDocument'],
             'Resource': ['arn:aws:ssm:us-east-1:111111111111:document/owned-terminal']},
            {'Sid': 'ManageReviewedNamedOperatorWorkspaceGrant', 'Effect': 'Allow',
             'Action': ['iam:PutUserPolicy', 'iam:DeleteUserPolicy', 'iam:GetUserPolicy', 'iam:ListUserTags'],
             'Resource': [operator]},
        ]}
        after = copy.deepcopy(before)
        after['Statement'][-1] = {'Sid': 'DenyReviewedOperatorPolicyMutation',
                                 'Effect': 'Deny', 'Action': ['iam:*'], 'Resource': [operator]}
        config = {'deployer_principal_arns': [operator], 'workspace_git_secret_arns': {}}
        target = {'account_id': '111111111111', 'backend': {'bucket': 'owned-state'}}
        attributes = {'id': 'owned:owned', 'name': 'owned', 'role': 'owned'}
        versions = {}

        def snapshot(version, policy, serial):
            state = {'lineage': 'owned-lineage', 'serial': serial, 'resources': [
                {'mode': 'managed', 'type': 'aws_iam_role_policy', 'name': 'deployer',
                 'instances': [{'attributes': {**attributes, 'policy': json.dumps(policy)}}]},
                {'mode': 'managed', 'type': 'aws_s3_bucket', 'name': 'retained',
                 'instances': [{'attributes': {'id': 'owned-data', 'bucket': 'owned-data'}}]},
            ]}
            versions[version] = L['canon'](state)
            return {'key': 'platform.tfstate', 'version': version, 'lineage': state['lineage'],
                    'serial': serial, 'sha256': L['sha'](versions[version])}

        old_state = snapshot('before', before, 1)
        new_state = snapshot('after', after, 2)
        api = types.SimpleNamespace(get_object=lambda **kwargs: {
            'Body': io.BytesIO(versions[kwargs['VersionId']])})

        with tempfile.TemporaryDirectory(prefix='access-recovery-', dir=ROOT/'evidence') as temporary:
            root = Path(temporary)

            def consumed(name, state, current_policy, recovery=None):
                directory = root/name
                directory.mkdir()
                plan = {'variables': {key: {'value': value} for key, value in config.items()},
                        'planned_values': {'root_module': {'resources': [
                            {'address': address, 'mode': 'managed', 'values': attributes}]}},
                        'resource_changes': [{'address': address, 'mode': 'managed', 'change': {
                            'actions': ['no-op'] if current_policy == after else ['update'],
                            'before': {**attributes, 'policy': json.dumps(current_policy)},
                            'after': {**attributes, 'policy': json.dumps(after)},
                        }}]}
                L['write'](directory/'config.tfvars.json', config)
                L['write'](directory/'plan.json', plan)
                (directory/'saved.tfplan').write_bytes(name.encode())
                review = {'stage': 'workspace-access', 'target_name': 'offline', 'target': target,
                          'source': {'revision': 'a'*40}, 'root': str(L['stage_root']('workspace-access')),
                          'backend': {'key': state['key']}, 'state': state, 'recovery': recovery,
                          'config_sha256': L['sha'](L['canon'](config)),
                          'plan_sha256': L['sha']((directory/'saved.tfplan').read_bytes()),
                          'plan_json_sha256': L['sha']((directory/'plan.json').read_bytes()),
                          'scope': L['plan_scope'](plan, 'workspace-access', recovery)}
                L['write'](directory/'review.json', review)
                L['authorize'](directory, L['sha'](L['canon'](review)), 'Authorized exact offline IAM migration')
                L['write'](directory/'apply-started.json', {'review_sha256': L['sha'](L['canon'](review))})
                return directory

            with patch.dict(L, {'prior_source': lambda _: True, 'platform_compute_absent': lambda *_: None}):
                initial = consumed('initial', old_state, before)
                expected = {address: {'before': before, 'after': after}}
                attempt = initial
                # First loss changes nothing; the second loses a successful IAM
                # response; subsequent losses occur while accepting a no-op.
                for number, (state, current_policy) in enumerate([
                    (old_state, before), (new_state, after), (new_state, after), (new_state, after),
                ], 1):
                    recovered = L['recovery_context'](attempt, 'offline', 'workspace-access',
                                                     config, target, state, None, lambda *_: api)
                    self.assertEqual(recovered['access_changes'], expected)
                    self.assertEqual(recovered['directory'], str(attempt))
                    self.assertIn('aws_s3_bucket.retained', recovered['owned'])
                    attempt = consumed('recovery-'+str(number), state, current_policy, recovered)
                    if current_policy == after:
                        self.assertEqual(L['read'](attempt/'review.json')['scope'], [])
                self.assertEqual(len(list(root.glob('*/apply-started.json'))), 5)
                self.assertEqual(list(root.glob('*/apply-result.json')), [])
                self.assertEqual(L['read'](initial/'plan.json')['resource_changes'][0]['change']['actions'], ['update'])


class AccessPolicyReadback(unittest.TestCase):
    def setUp(self):
        self.policy = {'Version': '2012-10-17', 'Statement': [
            {'Sid': 'Reviewed', 'Effect': 'Allow', 'Action': ['ssm:GetDocument'], 'Resource': ['owned']}]}
        self.changed = copy.deepcopy(self.policy)
        self.changed['Statement'][0]['Resource'] = ['foreign']
        self.role = {'mode': 'managed', 'address': 'aws_iam_role_policy.deployer', 'change': {
            'actions': ['update'], 'before': {'role': 'owned', 'name': 'grant', 'policy': json.dumps(self.policy)}}}
        self.boundary = {'mode': 'managed', 'address': 'aws_iam_policy.project_workspace_boundary["owned"]',
                         'change': {'actions': ['update'], 'before': {
                             'arn': 'arn:aws:iam::111111111111:policy/owned', 'policy': json.dumps(self.policy)}}}

    def role_api(self, policy):
        calls = []

        def get_role_policy(**arguments):
            calls.append(arguments)
            return {'RoleName': 'owned', 'PolicyName': 'grant', 'PolicyDocument': policy}

        return types.SimpleNamespace(get_role_policy=get_role_policy), calls

    def test_role_readback_accepts_reviewed_policy_and_rejects_live_drift(self):
        for changed in (False, True):
            with self.subTest(changed=changed):
                api, calls = self.role_api(self.changed if changed else self.policy)
                plan = {'resource_changes': [self.role]}
                if changed:
                    with self.assertRaisesRegex(L['Failure'], 'changed after planning'):
                        L['verify_access_policies'](plan, None, lambda *_: api)
                else:
                    L['verify_access_policies'](plan, None, lambda *_: api)
                self.assertEqual(calls, [{'RoleName': 'owned', 'PolicyName': 'grant'}])

    def test_boundary_readback_binds_current_default_policy_and_rejects_version_race(self):
        arn = self.boundary['change']['before']['arn']
        for fault in (None, 'policy-drift', 'default-version-changed'):
            with self.subTest(fault=fault):
                calls = []

                def get_policy(**arguments):
                    calls.append(('get', arguments))
                    return {'Policy': {'Arn': arn, 'DefaultVersionId': 'v7'}}

                def get_policy_version(**arguments):
                    calls.append(('version', arguments))
                    return {'PolicyVersion': {'VersionId': 'v7',
                        'IsDefaultVersion': fault != 'default-version-changed',
                        'Document': self.changed if fault == 'policy-drift' else self.policy}}

                api = types.SimpleNamespace(get_policy=get_policy, get_policy_version=get_policy_version)
                plan = {'resource_changes': [self.boundary]}
                if fault:
                    message = 'changed after planning' if fault == 'policy-drift' else 'default version changed'
                    with self.assertRaisesRegex(L['Failure'], message):
                        L['verify_access_policies'](plan, None, lambda *_: api)
                else:
                    L['verify_access_policies'](plan, None, lambda *_: api)
                self.assertEqual(calls, [('get', {'PolicyArn': arn}),
                                        ('version', {'PolicyArn': arn, 'VersionId': 'v7'})])

    def test_noop_recovery_still_reads_policy_and_rejects_new_drift(self):
        plan = {'resource_changes': [copy.deepcopy(self.role)]}
        plan['resource_changes'][0]['change']['actions'] = ['no-op']
        api, calls = self.role_api(self.policy)
        L['verify_access_policies'](plan, None, lambda *_: api)
        self.assertEqual(len(calls), 1)
        api, calls = self.role_api(self.changed)
        with self.assertRaisesRegex(L['Failure'], 'changed after planning'):
            L['verify_access_policies'](plan, None, lambda *_: api)
        self.assertEqual(len(calls), 1)

    def test_apply_rejects_live_drift_before_consuming_authorization_or_mutating(self):
        with tempfile.TemporaryDirectory(prefix='access-readback-', dir=ROOT/'evidence') as temporary:
            directory = Path(temporary)
            source = {'revision': 'a'*40}
            config = {'provision_alert_topic': True}
            plan = {'resource_changes': [self.role]}
            root = L['stage_root']('workspace-access')
            scope = [{'address': self.role['address'], 'actions': ['update']}]
            target, identities, state = {'account_id': '111111111111'}, {}, {'key': 'platform.tfstate'}
            L['write'](directory/'config.tfvars.json', config)
            L['write'](directory/'plan.json', plan)
            L['write'](directory/'backend.json', {})
            (directory/'saved.tfplan').write_bytes(b'exact-reviewed-plan')
            review = {'stage': 'workspace-access', 'target_name': 'offline', 'target': target,
                      'source': source, 'root': str(root), 'state': state, 'identities': identities,
                      'dependencies': [], 'artifacts': {}, 'backend': {}, 'scope': scope,
                      'tofu_version': 'offline', 'config_sha256': L['sha'](L['canon'](config)),
                      'plan_sha256': L['sha']((directory/'saved.tfplan').read_bytes()),
                      'plan_json_sha256': L['sha']((directory/'plan.json').read_bytes()),
                      'lock_sha256': L['sha']((root/'.terraform.lock.hcl').read_bytes())}
            L['write'](directory/'review.json', review)
            L['authorize'](directory, L['sha'](L['canon'](review)), 'Authorized exact offline IAM migration')
            api, reads = self.role_api(self.changed)
            commands = []

            def run(arguments, *_):
                commands.append(arguments)
                self.assertEqual(arguments, ['tofu', 'version', '-json'])
                return json.dumps({'terraform_version': 'offline'})

            with patch.dict(L, {'source': lambda: source, 'plan_scope': lambda *_: scope,
                'context': lambda *_: (target, {}, None, lambda *_: api, identities, state),
                'platform_compute_absent': lambda *_: None, 'shared_lambda_pool': lambda *_: {}, 'run': run}):
                with self.assertRaisesRegex(L['Failure'], 'changed after planning'):
                    L['apply'](directory)
            self.assertEqual(len(reads), 1)
            self.assertEqual(commands, [['tofu', 'version', '-json']])
            self.assertFalse((directory/'apply-started.json').exists())
            self.assertFalse((directory/'apply-result.json').exists())


if __name__ == '__main__':
    unittest.main()
