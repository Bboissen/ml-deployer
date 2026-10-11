"""Offline end-to-end operation ordering, durable locks and uncertain recovery."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]; os.chdir(ROOT)
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts/aws'/name)
    value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
W=module('workspace.py'); D=module('workspace-deploy.py'); E=module('workspace-e2e.py'); L=W.L

class Operations(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=ROOT/'evidence'); self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)/('a'*32); self.directory.mkdir()
        self.prefix='offline-'+os.urandom(8).hex()
        self.lock=ROOT/'evidence/aws/locks'/(self.prefix+'.lock')
        self.addCleanup(lambda:self.lock.unlink() if self.lock.exists() else None)
    def test_journal_survives_reload_and_rejects_changed_scope_or_chain(self):
        journal=D.Journal(L,self.directory,'b'*64); journal.record('launch','started')
        with self.assertRaisesRegex(L['Failure'],'uncertain launch'): journal.stage('launch',lambda:self.fail('duplicate launch'))
        restored=D.Journal(L,self.directory,'b'*64); self.assertEqual(len(restored.records),1)
        with self.assertRaises(L['Failure']): D.Journal(L,self.directory,'c'*64)
        path=self.directory/'journal/000001.json'; value=L['read'](path); value['previous_sha256']='forged'; path.write_text(json.dumps(value))
        with self.assertRaises(L['Failure']): D.Journal(L,self.directory,'b'*64)
    def test_live_lock_excludes_second_deploy_and_releases_after_error(self):
        path=self.directory/'workspace.lock'
        with D.locked(L,path):
            with self.assertRaisesRegex(ValueError,'busy'):
                with D.locked(L,path): pass
        with D.locked(L,path): pass
    def test_scope_change_cannot_reuse_authorization(self):
        project=json.loads((ROOT/'infra/aws/project.example.json').read_text())
        scope={'source':L['source'](),'operation_id':self.directory.name,'configuration_sha256':L['sha'](L['canon'](project)),
               'deployment_sha256':L['sha'](L['canon']({}))}
        L['write'](self.directory/'scope.json',scope); L['write'](self.directory/'deployment.json',{})
        L['write'](self.directory/'task-authorization.json',{'scope_sha256':'f'*64,'authorization':'authorized source scope'})
        P=types.SimpleNamespace(operation_status=lambda *_:None,validate_project=lambda *_:project)
        with patch.object(D,'extensions',return_value={'config':P}),patch.dict(L,{'prior_source':lambda _:True}):
            with self.assertRaisesRegex(L['Failure'],'authorization'): D.validate_operation({'L':L},'config',self.directory)
    def test_resume_success_returns_receipt_without_repeating_cleanup(self):
        result={'status':'success','cleanup_status':'success','verified_after_compute_deletion':True}
        L['write'](self.directory/'result.json',result)
        with patch.object(D,'validate_operation',return_value=(self.directory,{},{})),patch.object(D,'execute',side_effect=AssertionError('completed operation replayed')):
            self.assertEqual(D.resume({'L':L},'config',self.directory),result)
    def test_completed_operations_are_unchanged_by_cancel_or_resume(self):
        for status in ('success','cancelled'):
            for cleanup in ('success','not_needed'):
                with self.subTest(status=status,cleanup=cleanup):
                    directory=self.directory/(status+'-'+cleanup); directory.mkdir()
                    result={'status':status,'cleanup_status':cleanup}
                    L['write'](directory/'result.json',result)
                    before=(directory/'result.json').read_bytes()
                    with patch.object(D,'validate_operation',return_value=(directory,{},{})),patch.object(D,'execute',side_effect=AssertionError('completed operation replayed')):
                        self.assertEqual(D.cancel({'L':L},'config',directory),result)
                        self.assertEqual(D.resume({'L':L},'config',directory),result)
                    self.assertFalse((directory/'cancel.json').exists())
                    self.assertEqual((directory/'result.json').read_bytes(),before)
    def test_resume_failed_or_uncertain_operation_still_reconciles(self):
        result={'status':'failure','cleanup_status':'unknown'}
        L['write'](self.directory/'result.json',result)
        with patch.object(D,'validate_operation',return_value=(self.directory,{},{})),patch.object(D,'execute',return_value=result) as execute:
            self.assertEqual(D.resume({'L':L},'config',self.directory),result)
            execute.assert_called_once()
    def pipeline(self,ingest_failure=False,unknown_launch=False,mode='job',cancelled=False,store=None):
        directory=self.directory; calls=[]; project=json.loads((ROOT/'infra/aws/project.example.json').read_text()); project['mode']=mode
        target={'profile':'offline','account_id':'111111111111','region':'us-east-1','operator_arn':'arn:aws:iam::111111111111:user/operator',
            'deployment_role_arn':'arn:aws:iam::111111111111:role/deployer','backend':{},'inventory':{'resource_prefix':self.prefix,'buckets':['workload']}}
        registry=directory.parent/'registry' if store else directory/'registry'; deployment={'configuration':project,'account_id':target['account_id'],
            'names':{'workspace_id':project['project']+'-'+project['workspace'],'workload_bucket':'workload'},'repository':{'url':'https://github.com/owner/project.git','revision':'a'*40},
            'dataset':{'adapter':'local','source':'unused'}}
        size={**L['supported_sizes']()['r8i.2xlarge'],'policy':'ram-first','instance_type':'r8i.2xlarge','availability_zone':'us-east-1a','hourly_usd':1}
        scope={'target':target,'registry_directory':str(registry),'capacity':{'selected':size,'candidates':[size]},'foundation':None,
            'repository_reference':None,'new_private_access':False,'outputs':{'paths':['outputs'],'maximum_bytes':100},'dataset':{'inventory':[]}}
        task={'scope_sha256':'b'*64,'authorization':'authorized bounded mocked operation'}
        if cancelled: L['write'](directory/'cancel.json',{'requested_at':L['stamp']()})
        artifacts={'toolbox_zip_sha256':'c'*64}; binding={'plan_directory':str(directory/'foundation/platform')}
        O=types.SimpleNamespace(prepare=lambda *a:calls.append('foundation-inputs'),provision=lambda *a:calls.append('foundation') or binding,
            capacity=lambda *a,**kw: {'candidates':[size]})
        def ingest(*a,**kw):
            calls.append('ingestion')
            if ingest_failure: raise ValueError('failed transfer')
            return {'bucket':'workload','manifest_key':'manifest','manifest_version_id':'data-version','manifest_sha256':'d'*64,'content_sha256':'e'*64}
        I=types.SimpleNamespace(source_adapter=lambda *a:types.SimpleNamespace(inventory=lambda *_:[]),ingest=ingest)
        s3=store or types.SimpleNamespace(list_multipart_uploads=lambda **kw:{'Uploads':[]})
        if store:
            actual=module('workspace-ingest.py'); data=directory.parent/'data'; data.mkdir(exist_ok=True)
            if not (data/'input with spaces').exists(): (data/'input with spaces').write_bytes(b'ordinary selected data')
            deployment['dataset']['source']=str(data)
            scope['dataset']['inventory']=actual.Local(data).inventory(__import__('time').monotonic()+30)
            def streamed(*a,**kw): calls.append('ingestion'); return actual.ingest(*a,**kw)
            I=types.SimpleNamespace(source_adapter=actual.source_adapter,ingest=streamed,incomplete=actual.incomplete,canonical=actual.canonical)
        L['write'](directory/'project.json',project); L['write'](directory/'deployment.json',deployment)
        def build(*a): calls.append('build'); return artifacts
        def render(value,selected,control,starts):
            control=Path(control); control.mkdir(); L['write'](control/'runner.json',{'lease':{'starts_at':'2000-01-01T00:00:00Z'},'instance_type':'r8i.2xlarge'})
        def apply_stage(_L,name,stage,inputs,folder,auth,dependency=None,recover_from=None):
            calls.append(stage); folder.mkdir(parents=True,exist_ok=True); L['write'](folder/'apply-started.json',{})
            if stage=='launch' and unknown_launch: raise TimeoutError('lost launch response')
            L['write'](folder/'apply-result.json',{'status':'success'})
            if stage=='launch': L['write'](folder/'launched-owned.json',{'instance_id':'i-owned'})
            return str(folder)
        def cleanup(*a): calls.append('cleanup'); return {'cleanup_status':'success'}
        receipt={'infrastructure_ready':True,'setup_exit':0,'job_exit':0 if mode=='job' else None,'outputs_persisted':mode=='job'}
        def verify(_L,value,target,job,config,instance,s3,out,first=None):
            calls.append('verify-after' if first else 'verify-before'); out.mkdir(parents=True,exist_ok=True)
            result={'execution':receipt}; L['write'](out/'verification.json',result); return result
        EE=types.SimpleNamespace(payload=E.payload,verify_public=lambda *_:None,run_command=lambda *a,**kw:calls.append('job') or {'status':'Success'},verify_generic_result=verify,safe_error=E.safe_error)
        with patch.object(D,'extensions',return_value={'onboarding':O,'ingest':I,'e2e':EE}),patch.object(D,'apply_stage',side_effect=apply_stage),patch.object(D,'cleanup_runner',side_effect=cleanup),patch.dict(L,{'build':build,'sessions':lambda _: (None,lambda *a:s3,None)}):
            result=D.execute({'L':L,'render':render},'config',directory,scope,task)
        return result,calls
    def test_short_config_pipeline_transfers_before_launch_and_verifies_after_cleanup(self):
        result,calls=self.pipeline()
        self.assertEqual(result['status'],'success'); self.assertTrue(result['verified_after_compute_deletion'])
        self.assertLess(calls.index('ingestion'),calls.index('prepare')); self.assertLess(calls.index('prepare'),calls.index('launch'))
        self.assertLess(calls.index('cleanup'),calls.index('verify-after'))
    def test_failed_ingestion_launches_no_compute(self):
        result,calls=self.pipeline(ingest_failure=True)
        self.assertEqual(result['status'],'failure'); self.assertNotIn('launch',calls); self.assertNotIn('job',calls)
    def test_uncertain_launch_is_journaled_and_never_retried(self):
        result,calls=self.pipeline(unknown_launch=True)
        self.assertEqual(calls.count('launch'),1); self.assertNotIn('job',calls)
        journal=D.Journal(L,self.directory,'b'*64)
        with self.assertRaises(L['Failure']): journal.stage('launch',lambda:self.fail('duplicate VM'))
        self.assertEqual(result['cleanup_status'],'success')
    def test_cancelled_operation_never_starts_mutation(self):
        result,calls=self.pipeline(cancelled=True)
        self.assertEqual(result['status'],'cancelled'); self.assertEqual(calls,[])
    def test_reconcile_completed_stage_without_repeating_callback(self):
        journal=D.Journal(L,self.directory,'b'*64); journal.record('ingestion','started')
        calls=[]
        result=journal.stage('ingestion',lambda:self.fail('replayed incomplete stage'),lambda:calls.append('owned reconciliation') or {'version':'native'})
        restored=D.Journal(L,self.directory,'b'*64)
        self.assertEqual(restored.stage('ingestion',lambda:self.fail('repeated completed stage')),result)
        self.assertEqual(calls,['owned reconciliation'])
    def test_cancellation_blocks_uncertain_stage_from_resuming_mutations(self):
        journal=D.Journal(L,self.directory,'b'*64); journal.record('foundation','started')
        L['write'](self.directory/'cancel.json',{'requested_at':L['stamp']()})
        with self.assertRaisesRegex(L['Failure'],'cancel requested'):
            journal.stage('foundation',lambda:self.fail('created new foundation'),
                          lambda:self.fail('recovery applied more foundation resources'))
    def test_recovery_bindings_survive_multiple_interruptions(self):
        O=module('workspace-onboarding.py')
        one=self.directory/'bootstrap-recovery-one'; two=self.directory/'bootstrap-recovery-two'
        O.recovery_pointer(L,self.directory,'bootstrap',one)
        O.recovery_pointer(L,self.directory,'bootstrap',two)
        self.assertEqual(O.recovered_folder(L,self.directory,'bootstrap'),two)
        self.assertEqual(len(list(self.directory.glob('bootstrap-binding-*.json'))),2)
    def test_two_deploys_reuse_exact_manifest_versions_without_reupload(self):
        spec=importlib.util.spec_from_file_location('ingest_tests',ROOT/'tests/aws/test-workspace-ingest.py')
        fixture=importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture); store=fixture.Store()
        first,calls=self.pipeline(store=store); self.assertEqual(first['status'],'success',first); count=len(store.objects)
        manifest=L['read'](self.directory/'ingestion/manifest.json')
        self.directory=self.directory.parent/('f'*32); self.directory.mkdir()
        second,again=self.pipeline(store=store)
        self.assertEqual(first['status'],second['status']); self.assertEqual(second['status'],'success')
        self.assertEqual(len(store.objects),count)
        self.assertEqual(L['read'](self.directory/'ingestion/manifest.json'),manifest)
        self.assertEqual(calls.count('launch'),1); self.assertEqual(again.count('launch'),1)
    def test_workspace_keeps_compute_and_runs_no_cleanup(self):
        result,calls=self.pipeline(mode='workspace')
        self.assertEqual(result['status'],'workspace_ready'); self.assertNotIn('cleanup',calls)

if __name__=='__main__': unittest.main(verbosity=2)
