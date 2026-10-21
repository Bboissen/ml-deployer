"""A retained foundation moves to a new operator only through an exact reviewed trust change."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location('workspace', ROOT/'scripts/aws/workspace.py')
workspace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace)
L = workspace.L
spec = importlib.util.spec_from_file_location('onboarding', ROOT/'scripts/aws/workspace-onboarding.py')
O = importlib.util.module_from_spec(spec)
spec.loader.exec_module(O)

OLD = 'arn:aws:iam::111111111111:user/operator'
NEW = 'arn:aws:iam::111111111111:role/ml-deployer-operator'
ROLE = {'name': 'owned-workspace-deployer', 'arn': 'arn:aws:iam::111111111111:role/owned-workspace-deployer',
        'max_session_duration': 43200, 'description': 'Least-privilege OpenTofu deployer'}


def trust(principal, **extra):
    return json.dumps({'Version': '2012-10-17', 'Statement': [{
        'Sid': 'ReviewedTemporaryPrincipalsOnly', 'Effect': 'Allow', 'Action': 'sts:AssumeRole',
        'Principal': {'AWS': principal}, **extra}]})


def grant(principal):
    return {'Version': '2012-10-17', 'Statement': [
        {'Sid': 'DenyReviewedOperatorPolicyMutation', 'Effect': 'Deny', 'Action': 'iam:*', 'Resource': principal},
        {'Sid': 'ManageReviewedNonRootTerminalDocuments', 'Effect': 'Allow', 'Action': ['ssm:GetDocument'],
         'Resource': ['arn:aws:ssm:us-east-1:111111111111:document/owned-run-ws-*-terminal']}]}


def plan(role_after=None, grant_after=None, principals=(NEW,), role_before=None):
    policy = {'role': ROLE['name'], 'name': ROLE['name']}
    changes = []
    if role_after is not False:
        changes.append({'address': 'aws_iam_role.deployer', 'mode': 'managed', 'change': {
            'actions': ['update'], 'before': {**ROLE, 'assume_role_policy': role_before or trust(OLD)},
            'after': role_after or {**ROLE, 'assume_role_policy': trust(NEW)}}})
    changes.append({'address': 'aws_iam_role_policy.deployer', 'mode': 'managed', 'change': {
        'actions': ['update'], 'before': {**policy, 'policy': json.dumps(grant(OLD))},
        'after': {**policy, 'policy': json.dumps(grant_after or grant(NEW))}}})
    return {'variables': {'deployer_principal_arns': {'value': list(principals)},
                          'workspace_git_secret_arns': {'value': {}}}, 'resource_changes': changes}


class TrustScope(unittest.TestCase):
    def test_exact_rebinding_updates_only_trust_and_operator_denial(self):
        self.assertEqual(L['plan_scope'](plan(), 'workspace-access'), [
            {'address': 'aws_iam_role.deployer', 'actions': ['update']},
            {'address': 'aws_iam_role_policy.deployer', 'actions': ['update']}])

    def test_unrelated_or_partial_changes_are_rejected(self):
        widened = grant(NEW); widened['Statement'][1]['Action'].append('ssm:DeleteDocument')
        cases = {
            'role attribute': plan(role_after={**ROLE, 'max_session_duration': 3600, 'assume_role_policy': trust(NEW)}),
            'trust condition': plan(role_after={**ROLE, 'assume_role_policy': trust(NEW, Condition={'Bool': {'aws:MultiFactorAuthPresent': 'false'}})}),
            'extra principal': plan(role_after={**ROLE, 'assume_role_policy': trust([NEW, OLD])}),
            'unreviewed principal': plan(principals=('arn:aws:iam::111111111111:role/other',)),
            'denial without trust': plan(role_after=False),
            'denial keeps old operator': plan(grant_after=grant(OLD)),
            'widened deployer grant': plan(grant_after=widened),
            'same operator': plan(role_before=trust(NEW)),
        }
        for name, value in cases.items():
            with self.subTest(name), self.assertRaises(L['Failure']):
                L['plan_scope'](value, 'workspace-access')

    def test_recovery_compares_the_trust_document_field(self):
        recovery = {'access_changes': {
            'aws_iam_role.deployer': {'before': json.loads(trust(OLD)), 'after': json.loads(trust(NEW))},
            'aws_iam_role_policy.deployer': {'before': grant(OLD), 'after': grant(NEW)}}}
        self.assertEqual(len(L['plan_scope'](plan(), 'workspace-access', recovery)), 2)
        drift = plan(role_after={**ROLE, 'assume_role_policy': trust('arn:aws:iam::111111111111:role/other')})
        with self.assertRaises(L['Failure']):
            L['plan_scope'](drift, 'workspace-access', recovery)

    def test_live_trust_readback_rejects_drift(self):
        role = plan()['resource_changes'][0]
        class IAM:
            def __init__(self, document): self.document = document
            def get_role(self, RoleName):
                return {'Role': {'RoleName': RoleName, 'Arn': ROLE['arn'], 'AssumeRolePolicyDocument': self.document}}
        L['verify_access_policies']({'resource_changes': [role]}, None, lambda *_: IAM(json.loads(trust(OLD))))
        with self.assertRaisesRegex(L['Failure'], 'changed after planning'):
            L['verify_access_policies']({'resource_changes': [role]}, None, lambda *_: IAM(json.loads(trust(NEW))))


def target(operator, profile):
    return {'profile': profile, 'account_id': '111111111111', 'region': 'us-east-1', 'operator_arn': operator,
            'deployment_role_arn': ROLE['arn'], 'backend': {'bucket': 'owned-state'}, 'inventory': {'resource_prefix': 'owned'}}


class Edges(unittest.TestCase):
    def test_operator_rebinding_allows_only_operator_and_profile(self):
        old, new = target(OLD, 'console'), target(NEW, 'sso')
        self.assertEqual(L['operator_rebinding'](old, new, {'deployer_principal_arns': [OLD]}, {'deployer_principal_arns': [NEW]}),
                         {'from': OLD, 'to': NEW})
        for older, newer, before, after in [
            (old, {**new, 'region': 'us-west-2'}, [OLD], [NEW]),
            (old, new, [OLD, NEW], [NEW]),
            (old, new, [OLD], [OLD]),
            (old, {**old, 'profile': 'sso'}, [OLD], [OLD])]:
            with self.subTest(after=after), self.assertRaises(L['Failure']):
                L['operator_rebinding'](older, newer, {'deployer_principal_arns': before}, {'deployer_principal_arns': after})

    def chain(self, root, rebinding_scope):
        """fresh-platform (old operator) <- access plan (new operator) <- preparation."""
        old_config = {'deployer_principal_arns': [OLD], 'workspace_git_secret_arns': {}, 'aws_region': 'us-east-1'}
        new_config = {**old_config, 'deployer_principal_arns': [NEW]}
        links = []
        for name, stage, config, owner, changes, scope in [
            ('platform', 'fresh-platform', old_config, target(OLD, 'console'), [], []),
            ('rebind', 'workspace-access', new_config, target(NEW, 'sso'), plan()['resource_changes'], rebinding_scope)]:
            directory = root/name; directory.mkdir()
            L['write'](directory/'config.tfvars.json', config)
            L['write'](directory/'plan.json', {'resource_changes': changes})
            (directory/'saved.tfplan').write_bytes(name.encode())
            review = {'stage': stage, 'target_name': 'offline', 'target': owner, 'source': {'revision': 'a'*40},
                      'scope': scope, 'dependencies': links[-1:] if links else [], 'recovery': None,
                      'config_sha256': L['sha'](L['canon'](config)),
                      'plan_sha256': L['sha']((directory/'saved.tfplan').read_bytes()),
                      'plan_json_sha256': L['sha']((directory/'plan.json').read_bytes())}
            receipt = {'status': 'success'}
            L['write'](directory/'review.json', review); L['write'](directory/'apply-result.json', receipt)
            links = [{'directory': str(directory), 'review_sha256': L['sha'](L['canon'](review)),
                      'receipt_sha256': L['sha'](L['canon'](receipt))}]
        return {'target_name': 'offline', 'target': target(NEW, 'sso'), 'dependencies': links}

    def test_launch_evidence_follows_one_reviewed_rebinding_edge(self):
        scope = [{'address': 'aws_iam_role.deployer', 'actions': ['update']},
                 {'address': 'aws_iam_role_policy.deployer', 'actions': ['update']}]
        with tempfile.TemporaryDirectory(prefix='rebinding-', dir=ROOT/'evidence') as temporary, \
                patch.dict(L, {'prior_source': lambda _: True}):
            preparation = self.chain(Path(temporary), scope)
            _, bindings = L['reviewed_platform_plan'](preparation)
            self.assertEqual(len(bindings), 2)
        with tempfile.TemporaryDirectory(prefix='rebinding-', dir=ROOT/'evidence') as temporary, \
                patch.dict(L, {'prior_source': lambda _: True}):
            directory = Path(temporary)
            preparation = self.chain(directory, scope)
            # The same operator change hidden in an ordinary access plan is refused.
            plan_path = directory/'rebind/plan.json'; plan_path.unlink()
            L['write'](plan_path, {'resource_changes': plan(role_after=False)['resource_changes']})
            review = L['read'](directory/'rebind/review.json')
            review.update(scope=scope[1:], plan_json_sha256=L['sha'](plan_path.read_bytes()))
            (directory/'rebind/review.json').unlink(); L['write'](directory/'rebind/review.json', review)
            preparation['dependencies'][0]['review_sha256'] = L['sha'](L['canon'](review))
            with self.assertRaisesRegex(L['Failure'], 'outside a rebinding plan'):
                L['reviewed_platform_plan'](preparation)


class RetainedFoundation(unittest.TestCase):
    def test_retained_foundation_reports_rebinding_and_verifies_previous_owner(self):
        with tempfile.TemporaryDirectory(prefix='rebinding-', dir=ROOT/'evidence') as temporary:
            directory = Path(temporary)
            L['write'](directory/'review.json', {'target': target(OLD, 'console')})
            L['write'](directory/'config.tfvars.json', {'deployer_principal_arns': [OLD]})
            binding = {'plan_directory': str(directory)}
            self.assertIsNone(O.operator_rebinding(L, binding, target(OLD, 'console')))
            self.assertEqual(O.operator_rebinding(L, binding, target(NEW, 'sso')), {'from': OLD, 'to': NEW})
            reserved = 'arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_X_1'
            with self.assertRaisesRegex(L['Failure'], 'non-reserved'):
                O.operator_rebinding(L, binding, target(reserved, 'sso'))
            with self.assertRaises(L['Failure']):
                O.operator_rebinding(L, binding, {**target(NEW, 'sso'), 'region': 'us-west-2'})

    def test_rebind_requires_reviewed_operator_before_any_plan(self):
        with tempfile.TemporaryDirectory(prefix='rebinding-', dir=ROOT/'evidence') as temporary:
            directory = Path(temporary)
            L['write'](directory/'config.tfvars.json', {'deployer_principal_arns': [OLD]})
            with patch.object(O, 'apply_access') as applied, self.assertRaisesRegex(L['Failure'], 'reviewed scope'):
                O.rebind_operator(L, 'offline', {'plan_directory': str(directory)}, target(NEW, 'sso'),
                                  {'from': 'arn:aws:iam::111111111111:user/other', 'to': NEW}, directory/'rebind', 'approve')
            applied.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
