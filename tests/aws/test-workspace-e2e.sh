#!/usr/bin/env bash
# Offline orchestration, failure cleanup and independent object verification.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec "${WORKSPACE_PYTHON:-python3}" - <<'PY'
import copy
import datetime as dt
import io
import json
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path.cwd()
sys.path.insert(0, str(ROOT/'scripts/aws'))
OUT = ROOT/'evidence/aws/tests/e2e'/dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
OUT.mkdir(parents=True)

def load(path):
    text = (ROOT/path).read_text()
    if path.endswith('.sh'):
        text = text.split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
    namespace = {'__name__': 'offline'}
    exec(compile(text, path, 'exec'), namespace)
    return namespace

L = load('scripts/aws/workspace_lifecycle.py')
E = load('scripts/aws/workspace-e2e.py')
G = load('scripts/aws/workspace-job.sh')
T = dt.datetime(2026, 10, 9, 12, tzinfo=dt.timezone.utc)
VALUE = json.loads((ROOT/'infra/aws/workspace.example.json').read_text())
TARGET = VALUE['target']
INSTANCE = 'i-00000000000000001'

class Objects(unittest.TestCase):
    def setUp(self):
        self.value = copy.deepcopy(VALUE)
        self.config = {'workspace_identity': {'request': {'workspace_id': VALUE['workspace_id']}},
                       'lease': {'starts_at': L['stamp'](T)}, 'toolbox_zip_sha256':'e'*64}
        self.job = E['payload'](self.value, TARGET, 'a'*32)
        self.role = 'arn:aws:sts::000000000000:assumed-role/offline/'+INSTANCE
        self.result = b'{"count":4,"mean":2.5,"sum":10}\n'
        self.provenance = {'run_id': self.job['run_id'], 'repository_commit': VALUE['repository']['revision'],
            'user': 'workspace', 'identity_arn': self.role, 'aws_region': TARGET['region'],
            'dataset': VALUE['job']['dataset'], 'dependency_lock_sha256': VALUE['job']['provenance']['dependency_lock_sha256'],
            'python_version': L['TOOLBOX']['rpms']['python3.13']['ver'], 'make_target': 'run',
            'result': {'uri': self.job['output_uri']+'result.json', 'version_id': 'result-version', 'sha256': L['sha'](self.result)}}
        self.execution = {'exit_code': 0, 'run_id': self.job['run_id'], 'repository_commit': VALUE['repository']['revision'],
            'user': 'workspace', 'instance_role_arn': self.role, 'credential_removed_before_make': True, 'make_argv': ['make'],
            'bootstrap':{'toolbox_sha256':'e'*64,'workspace_id':VALUE['workspace_id']}}
        self.calls = []
        self.modified = T
        self.current_version = 'result-version'
        def get(**kw):
            self.calls.append(kw)
            name = kw['Key'].rsplit('/',1)[-1]
            data, version = {'result.json': (self.result, self.current_version),
                'provenance.json': (L['canon'](self.provenance), 'provenance-version'),
                'execution.json': (L['canon'](self.execution), 'execution-version')}[name]
            return {'Body': io.BytesIO(data), 'ContentLength': len(data), 'VersionId': version, 'LastModified': self.modified}
        self.s3 = types.SimpleNamespace(get_object=get)
    def verify(self, name, first=None):
        with patch.dict(L, {'role_name': lambda _: 'offline'}):
            return E['verify_result'](L, self.value, TARGET, self.job, self.config, INSTANCE, self.s3, OUT/name, first)
    def test_before_and_after_retrieve_exact_same_persistent_versions(self):
        first = self.verify('before')
        self.assertEqual(first, self.verify('after', first))
        self.assertEqual([c['VersionId'] for c in self.calls[-2:]], ['result-version','provenance-version'])
        self.assertTrue(all(c['ExpectedBucketOwner'] == TARGET['account_id'] for c in self.calls))
    def test_wrong_result_bytes_fail(self):
        self.result = b'old or corrupt result'
        with self.assertRaises(L['Failure']): self.verify('bad-result')
    def test_foreign_run_commit_user_input_or_lock_fails(self):
        for field, replacement in [('run_id','b'*32), ('repository_commit','c'*40), ('user','root'),
                                   ('dataset',{}), ('dependency_lock_sha256','d'*64), ('identity_arn','foreign')]:
            original = self.provenance[field]; self.provenance[field] = replacement
            with self.subTest(field=field), self.assertRaises(L['Failure']): self.verify('bad-'+field)
            self.provenance[field] = original
    def test_key_must_be_removed_before_exact_make_argv(self):
        for changes in ({'credential_removed_before_make':False}, {'make_argv':['make','other']}, {'exit_code':1},
                        {'bootstrap':{'toolbox_sha256':'f'*64,'workspace_id':VALUE['workspace_id']}}):
            original = dict(self.execution); self.execution.update(changes)
            with self.assertRaises(L['Failure']): self.verify('bad-execution')
            self.execution = original
    def test_stale_result_and_changed_version_fail(self):
        self.modified = T-dt.timedelta(seconds=1)
        with self.assertRaises(L['Failure']): self.verify('stale')
        self.modified = T
        first = self.verify('version-before'); self.current_version = 'new-version'
        with self.assertRaises(L['Failure']): self.verify('version-after', first)
    def test_unversioned_or_oversized_objects_fail(self):
        self.current_version = 'null'
        with self.assertRaises(L['Failure']): self.verify('null')
        self.result = b'x'*(1024*1024+1)
        with self.assertRaises(L['Failure']): self.verify('oversized')

class Controller(unittest.TestCase):
    def exercise(self, name, failure=None, partial_compute=False):
        directory = OUT/name; configuration = OUT/(name+'-configuration.json')
        value = copy.deepcopy(VALUE); foundation = OUT/(name+'-foundation'); foundation.mkdir()
        value['foundation']['plan_directory'] = str(foundation)
        L['write'](foundation/'config.tfvars.json', {})
        L['write'](configuration, value)
        calls = []; config = {'phase':'prepare','lease':{'id':'lease'},'workspace_identity':{'request':{'workspace_id':VALUE['workspace_id']}}}
        s3 = types.SimpleNamespace(list_object_versions=lambda **_: {}, get_bucket_versioning=lambda **_: {'Status':'Enabled'},
            get_policy=lambda **_: {'Policy':{'DefaultVersionId':'v1'}},get_policy_version=lambda **_: {'PolicyVersion':{'Document':{'Statement':[]}}})
        def render(_value, _target, location, _starts):
            p = Path(location); p.mkdir(); L['write'](p/'runner.json', config)
        def plan(_target, stage, _inputs, location, dependency=None, recover=None):
            calls.append(('plan', stage, dependency, recover)); p = Path(location); p.mkdir(parents=True)
            if failure == 'plan-'+stage: raise ValueError('offline plan failure')
            L['write'](p/'review.json', {'stage':stage,'scope':[]})
            changes = [{'address':'aws_instance.workspace[0]', 'change':{'before':{'id':INSTANCE} if partial_compute else None}}] if stage=='retire' else []
            L['write'](p/'plan.json', {'resource_changes':changes})
        def apply(location):
            p = Path(location); stage = L['read'](p/'review.json')['stage']; calls.append(('apply',stage))
            L['write'](p/'apply-started.json', {})
            if failure == stage: raise ValueError('offline apply failure')
            L['write'](p/'apply-result.json', {'status':'success'})
            if stage == 'launch': L['write'](p/'launched-owned.json', {'instance_id':INSTANCE})
            if stage == 'retire': L['write'](p/'retired-owned.json', {'instance_id':INSTANCE})
        def command(*_):
            calls.append(('command',))
            if failure == 'command': raise ValueError('offline Make failure')
            return {'status':'success'}
        def credentials(*_):
            if failure=='credentials': raise ValueError('offline KMS deny')
        def verify(*args):
            calls.append(('verify','after' if args[-1] is not None and isinstance(args[-1],dict) else 'before'))
            if failure == 'verify': raise ValueError('offline result mismatch')
            return {'result':{'version_id':'version'}}
        class Clock(dt.datetime):
            calls = 0
            @classmethod
            def now(cls, tz=None):
                cls.calls += 1
                return T if cls.calls==1 else T+dt.timedelta(minutes=10)
        overrides = {'native_plan':plan,'apply':apply,'authorize':lambda *_:None,
            'source':lambda:{'revision':'f'*40,'working_tree_sha256':L['sha'](b'')},
            'sessions':lambda _:(None,lambda *_:s3,None), 'inventory':lambda *_:{'live_compute':0}, 'remaining_owned':lambda *_:None}
        with patch.dict(L,overrides), patch.dict(E,{'preflight':lambda *_:{'status':'success'},'run_command':command,
            'verify_result':verify,'verify_credential_access':credentials,'object_bytes':lambda *_:(b'',{'sha256':VALUE['job']['dataset']['sha256']}),
            'dt':types.SimpleNamespace(datetime=Clock,timedelta=dt.timedelta,timezone=dt.timezone)}):
            result = E['execute']({'L':L,'render':render},configuration,value,TARGET,directory,'User authorized one bounded E2E and cleanup')
        self.assertEqual(E['status'](L,directory)['status'],result['status'])
        self.assertEqual(sum(c[:2]==('apply','launch') for c in calls),0 if failure in ('prepare','plan-launch','credentials') else 1)
        return result,calls
    def test_success_requires_both_verifications_and_cleanup(self):
        result,calls = self.exercise('success')
        self.assertEqual(result['status'],'success'); self.assertTrue(result['verified_after_compute_deletion'])
        self.assertIn(('apply','retire'),calls); self.assertIn(('apply','cleanup'),calls)
        self.assertEqual(sum(c[0]=='verify' for c in calls),2)
    def test_make_failure_and_bad_result_still_cleanup(self):
        for failure in ('command','verify'):
            result,calls = self.exercise(failure,failure)
            self.assertEqual(result['status'],'failure'); self.assertTrue(result['cleanup_success'])
            self.assertIn(('apply','retire'),calls); self.assertIn(('apply','cleanup'),calls)
    def test_partial_prepare_and_unapplied_launch_cleanup_without_compute(self):
        for failure in ('prepare','plan-launch','credentials'):
            result,calls = self.exercise(failure,failure)
            self.assertEqual(result['status'],'failure'); self.assertTrue(result['cleanup_success'])
            self.assertFalse(any(c[:2]==('apply','retire') for c in calls))
            self.assertTrue(any(c[:2]==('plan','cleanup') and c[3].endswith('/prepare') for c in calls))
    def test_partial_launch_with_compute_retires_before_cleanup(self):
        result,calls = self.exercise('partial-launch','launch',partial_compute=True)
        self.assertEqual(result['status'],'failure'); self.assertTrue(result['cleanup_success'])
        self.assertIn(('apply','retire'),calls); self.assertIn(('apply','cleanup'),calls)
    def test_partial_launch_without_compute_uses_owned_recovery(self):
        result,calls = self.exercise('no-compute-launch','launch')
        self.assertEqual(result['status'],'failure'); self.assertTrue(result['cleanup_success'])
        self.assertTrue(any(c[:2]==('plan','cleanup') and c[3].endswith('/launch') for c in calls))
    def test_cleanup_failure_cannot_report_success(self):
        result,_ = self.exercise('cleanup-failure','cleanup')
        self.assertEqual(result['status'],'failure'); self.assertFalse(result['cleanup_success'])
        self.assertFalse(result['verified_after_compute_deletion'])

class GuestBoundary(unittest.TestCase):
    def test_root_static_keys_target_injection_and_nonunique_output_rejected(self):
        job = E['payload'](VALUE,TARGET,'a'*32)
        with patch.dict(os.environ,{},clear=True), patch('os.geteuid',return_value=1000), patch.object(G['pwd'],'getpwuid',return_value=types.SimpleNamespace(pw_name='workspace')):
            G['validate'](job)
            for change in ({'make_target':'run;id'}, {'output_uri':'s3://other/output/'}, {'timeout_seconds':1801}):
                with self.assertRaises(ValueError): G['validate']({**job,**change})
            with patch.dict(os.environ,{'AWS_PROFILE':'admin'}), self.assertRaises(ValueError): G['validate'](job)
            with patch('os.geteuid',return_value=0), self.assertRaises(ValueError): G['validate'](job)
    def test_status_keeps_events_and_is_bounded(self):
        p=OUT/'status-events'; p.mkdir()
        for phase in ('prepare','launch','cleanup'):
            E['publish_status'](L,p,{'status':'running','phase':phase})
        self.assertEqual(E['status'](L,p)['phase'],'cleanup')
        self.assertEqual(len(list((p/'events').glob('*.json'))),3)
        with self.assertRaises(L['Failure']): E['status'](L,p,61)

class CommandBoundary(unittest.TestCase):
    def test_denied_secret_decryption_stops_before_compute(self):
        secret=VALUE['repository']['credential']['secret_arn']; key='arn:aws:kms:us-east-1:000000000000:key/managed-key'
        calls=[]
        def simulate(**kwargs):
            calls.append(kwargs)
            action=kwargs['ActionNames'][0]
            return {'EvaluationResults':[{'EvalActionName':action,'EvalResourceName':kwargs['ResourceArns'][0],
                'EvalDecision':'explicitDeny' if action=='kms:Decrypt' else 'allowed'}]}
        clients={'secretsmanager':types.SimpleNamespace(describe_secret=lambda **_: {'ARN':secret}),
                 'kms':types.SimpleNamespace(describe_key=lambda **_: {'KeyMetadata':{'Arn':key,'KeyState':'Enabled'}}),
                 'iam':types.SimpleNamespace(simulate_principal_policy=simulate)}
        with patch.dict(L,{'role_name':lambda _: 'offline'}),self.assertRaises(L['Failure']):
            E['verify_credential_access'](L,None,lambda _,service:clients[service],VALUE,TARGET,{},OUT/'denied-credentials')
        self.assertEqual(len(calls),2)
        self.assertFalse((OUT/'denied-credentials/credential-access.json').exists())
    def test_command_pins_document_hash_version_instance_and_uses_separate_description_api(self):
        directory=OUT/'command-boundary'; directory.mkdir(); launch=directory/'launch'; launch.mkdir()
        content={'schemaVersion':'2.2'}; policy={'Statement':[]}
        L['write'](launch/'plan.json',{'planned_values':{'root_module':{'resources':[
            {'address':'aws_ssm_document.job','values':{'content':json.dumps(content)}},
            {'address':'aws_iam_user_policy.operator[0]','values':{'policy':json.dumps(policy)}}]}}})
        calls=[]
        ssm=types.SimpleNamespace(
            get_document=lambda **_: {'Content':json.dumps(content),'DocumentType':'Command','DocumentVersion':'1'},
            describe_document=lambda **_: {'Document':{'Hash':'d'*64,'HashType':'Sha256','DocumentVersion':'1'}},
            describe_instance_information=lambda **_: {'InstanceInformationList':[{'InstanceId':INSTANCE,'PingStatus':'Online','AgentVersion':L['TOOLBOX']['rpms']['amazon-ssm-agent']['ver']}]},
            get_command_invocation=lambda **_: {'Status':'Success','ResponseCode':0},
            exceptions=types.SimpleNamespace(InvocationDoesNotExist=RuntimeError))
        def send(**kwargs):
            calls.append(kwargs)
            return {'Command':{'InstanceIds':[INSTANCE],'CommandId':'command-id','RequestedDateTime':T}}
        ssm.send_command=send
        iam=types.SimpleNamespace(get_user_policy=lambda **_: {'PolicyDocument':policy})
        with patch.dict(L,{'role_name':lambda _: 'offline','bound_instance':lambda *_:None}):
            E['run_command'](L,None,lambda _,service: {'ssm':ssm,'iam':iam}[service],TARGET,{'workspace_identity':{'request':{'operators':['arn:aws:iam::000000000000:user/sposhfi-admin']}}},launch,INSTANCE,E['payload'](VALUE,TARGET,'a'*32),directory)
        self.assertEqual(calls[0]['InstanceIds'],[INSTANCE]); self.assertEqual(calls[0]['DocumentVersion'],'1')
        self.assertEqual(calls[0]['DocumentHash'],'d'*64); self.assertEqual(calls[0]['DocumentHashType'],'Sha256')
        self.assertNotIn('PRIVATE KEY',json.dumps(calls))

unittest.main(verbosity=2)
PY
