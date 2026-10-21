"""Identity Center setup: owner console steps, one reviewed scope, append-only profiles."""
import argparse
import importlib.util
import io
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
sys.path.insert(0, str(ROOT/'scripts/aws'))
spec = importlib.util.spec_from_file_location('identity_center', ROOT/'scripts/aws/workspace-identity-center.py')
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
from workspace_setup import Console

ACCOUNT = '111111111111'
BASE = ROOT/'evidence/aws/tests/identity-center'
BASE.mkdir(parents=True, exist_ok=True)


class Missing(Exception):
    def __init__(self, code): self.response = {'Error': {'Code': code}}


class Account:
    """In-memory organization, Identity Center and IAM; records every mutation."""
    def __init__(self, organization=True, instance=True):
        self.organization = organization; self.instance = instance
        self.users = {}; self.sets = {}; self.inline = {}; self.roles = {}; self.attached = {}; self.assignments = []
        self.calls = []

    def __call__(self, service): return self

    # STS / Organizations
    def get_caller_identity(self): return {'Account': ACCOUNT, 'Arn': 'arn:aws:iam::' + ACCOUNT + ':user/admin'}
    def describe_organization(self):
        if not self.organization: raise Missing('AWSOrganizationsNotInUseException')
        return {'Organization': {'Id': 'o-example', 'MasterAccountId': ACCOUNT, 'FeatureSet': 'ALL'}}

    # Identity Center
    def list_instances(self):
        return {'Instances': [{'InstanceArn': 'arn:aws:sso:::instance/ssoins-1', 'IdentityStoreId': 'd-1234567890',
                               'Status': 'ACTIVE'}] if self.instance else []}
    def get_user_id(self, IdentityStoreId, AlternateIdentifier):
        name = AlternateIdentifier['UniqueAttribute']['AttributeValue']
        if name not in self.users: raise Missing('ResourceNotFoundException')
        return {'UserId': self.users[name]}
    def create_user(self, **arguments):
        self.calls.append(('create_user', arguments)); self.users[arguments['UserName']] = 'user-1'
        return {'UserId': 'user-1'}
    def get_paginator(self, _):
        account = self
        class Pages:
            def paginate(self, **_): return [{'PermissionSets': list(account.sets)}]
        return Pages()
    def describe_permission_set(self, InstanceArn, PermissionSetArn): return {'PermissionSet': self.sets[PermissionSetArn]}
    def get_inline_policy_for_permission_set(self, InstanceArn, PermissionSetArn): return {'InlinePolicy': self.inline.get(PermissionSetArn, '')}
    def create_permission_set(self, **arguments):
        self.calls.append(('create_permission_set', arguments))
        self.sets['ps-1'] = {'Name': arguments['Name'], 'SessionDuration': arguments['SessionDuration']}
        return {'PermissionSet': {'PermissionSetArn': 'ps-1'}}
    def put_inline_policy_to_permission_set(self, **arguments):
        self.calls.append(('put_inline_policy', arguments)); self.inline[arguments['PermissionSetArn']] = arguments['InlinePolicy']
    def list_account_assignments(self, **arguments):
        return {'AccountAssignments': [{'PrincipalType': 'USER', 'PrincipalId': p} for p in self.assignments]}
    def create_account_assignment(self, **arguments):
        self.calls.append(('assign', arguments)); self.assignments.append(arguments['PrincipalId'])
        return {'AccountAssignmentCreationStatus': {'RequestId': 'r-1', 'Status': 'IN_PROGRESS'}}
    def describe_account_assignment_creation_status(self, **_):
        return {'AccountAssignmentCreationStatus': {'Status': 'SUCCEEDED'}}

    # IAM
    def get_role(self, RoleName):
        if RoleName not in self.roles: raise Missing('NoSuchEntity')
        return {'Role': self.roles[RoleName]}
    def create_role(self, **arguments):
        self.calls.append(('create_role', arguments))
        self.roles[arguments['RoleName']] = {'Arn': 'arn:aws:iam::' + ACCOUNT + ':role/' + arguments['RoleName'],
                                             'AssumeRolePolicyDocument': json.loads(arguments['AssumeRolePolicyDocument'])}
    def list_attached_role_policies(self, RoleName):
        return {'AttachedPolicies': [{'PolicyArn': p} for p in self.attached.get(RoleName, [])]}
    def attach_role_policy(self, **arguments):
        self.calls.append(('attach', arguments)); self.attached.setdefault(arguments['RoleName'], []).append(arguments['PolicyArn'])


def arguments(**overrides):
    values = {'profile': 'admin', 'region': 'us-east-1', 'user': 'owner', 'email': 'owner@example.com',
              'display_name': 'Example Owner', 'new_profile': 'ml-deployer-sso', 'start_url': None, 'days': 30,
              'settings_confirmed': True, 'authorization': None}
    values.update(overrides)
    return argparse.Namespace(**values)


class Setup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=BASE); self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        self.config = directory/'config'; credentials = directory/'credentials'
        self.original = '[profile admin]\nlogin_session = arn:aws:iam::' + ACCOUNT + ':user/admin\n'
        self.config.write_text(self.original); credentials.write_text('')
        environment = patch.dict(os.environ, {'AWS_CONFIG_FILE': str(self.config), 'AWS_SHARED_CREDENTIALS_FILE': str(credentials),
                                              'HOME': str(directory)}, clear=True)
        environment.start(); self.addCleanup(environment.stop)
        self.output = io.StringIO()
        self.ui = Console(stream=self.output)
        receipts = patch.object(M, 'ROOT', directory); receipts.start(); self.addCleanup(receipts.stop)

    def run_setup(self, account, **overrides):
        with patch.object(M, 'user_terminal', return_value=False):
            return M.run(arguments(**overrides), account, self.ui)

    def test_owner_console_steps_stop_before_any_change(self):
        for account, step in ((Account(organization=False), 'organization'), (Account(instance=False), 'instance')):
            with self.subTest(step=step):
                self.assertEqual(self.run_setup(account)['step'], step)
                self.assertEqual(account.calls, [])
                self.assertIn('console.aws.amazon.com', self.output.getvalue())
        account = Account()
        self.assertEqual(self.run_setup(account, settings_confirmed=False)['step'], 'settings')
        self.assertIn('Standard authentication', self.output.getvalue())
        self.assertEqual(account.calls, [])
        self.assertEqual(self.config.read_text(), self.original)

    def test_review_needs_its_exact_hash_then_applies_once(self):
        account = Account()
        with self.assertRaisesRegex(M.B['Failure'], 'approve scope'):
            self.run_setup(account)
        digest = self.output.getvalue().split('Scope hash ')[1].split('.')[0]
        with self.assertRaisesRegex(M.B['Failure'], 'does not match'):
            self.run_setup(account, authorization='approve scope 0000000000000000')
        self.assertEqual(account.calls, [])
        result = self.run_setup(account, authorization='approve scope ' + digest)
        self.assertEqual([c[0] for c in account.calls],
                         ['create_user', 'create_permission_set', 'put_inline_policy', 'create_role', 'attach', 'assign'])
        role = account.calls[3][1]
        trust = json.loads(role['AssumeRolePolicyDocument'])['Statement'][0]
        self.assertEqual(trust['Condition']['ArnLike']['aws:PrincipalArn'],
                         'arn:aws:iam::' + ACCOUNT + ':role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_MlDeployerOperator_*')
        inline = json.loads(account.calls[2][1]['InlinePolicy'])['Statement']
        self.assertEqual(inline, [{'Sid': 'AssumeWorkspaceOperatorOnly', 'Effect': 'Allow', 'Action': 'sts:AssumeRole',
                                   'Resource': 'arn:aws:iam::' + ACCOUNT + ':role/ml-deployer-operator'}])
        self.assertEqual(account.calls[1][1]['SessionDuration'], 'PT12H')
        text = self.config.read_text()
        self.assertTrue(text.startswith(self.original))
        for line in ('[sso-session ml-deployer-sso]', 'sso_start_url = https://d-1234567890.awsapps.com/start',
                     '[profile ml-deployer-sso-portal]', 'sso_role_name = MlDeployerOperator',
                     '[profile ml-deployer-sso]', 'source_profile = ml-deployer-sso-portal', 'role_session_name = owner'):
            self.assertIn(line, text)
        self.assertEqual(result['status'], 'ready_for_first_sign_in')
        self.assertEqual(len(list((Path(self.temp.name)/'evidence/aws/identity-center').glob('setup-*.json'))), 1)
        # The SDK validator accepts the new chain; a rerun changes nothing.
        M.B['profile_environment']('ml-deployer-sso', 'us-east-1')
        calls = list(account.calls)
        self.assertIsNone(self.run_setup(account)['scope_hash'])
        self.assertEqual(account.calls, calls)

    def test_existing_profile_or_foreign_role_is_never_overwritten(self):
        self.config.write_text(self.original + '\n[profile ml-deployer-sso]\nlogin_session = something\n')
        with self.assertRaisesRegex(M.B['Failure'], 'exists with other values'):
            self.run_setup(Account())
        account = Account()
        account.roles['ml-deployer-operator'] = {'Arn': 'arn:aws:iam::' + ACCOUNT + ':role/ml-deployer-operator',
                                                 'AssumeRolePolicyDocument': {'Version': '2012-10-17', 'Statement': []}}
        self.config.write_text(self.original)
        with self.assertRaisesRegex(M.B['Failure'], 'differs from the reviewed trust'):
            self.run_setup(account)
        self.assertEqual(account.calls, [])

    def test_invalid_inputs_are_rejected_before_cloud_calls(self):
        for overrides in ({'email': 'not-an-address'}, {'new_profile': 'admin'}, {'days': 120},
                          {'start_url': 'http://example.com/start'}, {'user': 'bad name'},
                          {'region': 'us-gov-west-1'}, {'region': 'cn-north-1'}):
            with self.subTest(overrides=overrides), self.assertRaises(M.B['Failure']):
                self.run_setup(Account(), **overrides)


if __name__ == '__main__':
    unittest.main(verbosity=2)
