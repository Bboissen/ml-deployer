"""Offline end-to-end operation ordering, durable locks and uncertain recovery."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
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
    def test_private_files_stay_owner_only_under_default_acl(self):
        # Default POSIX ACLs replace the umask; only an explicit create mode holds.
        try: subprocess.run(['setfacl','-d','-m','u::rwx,g::rwx,o::rx',str(self.directory)],check=True,capture_output=True,timeout=10)
        except (OSError,subprocess.CalledProcessError): self.skipTest('default ACLs unavailable')
        D.atomic(L,self.directory/'atomic.json',{}); L['write'](self.directory/'write.json',{})
        with L['private_file'](self.directory/'plain') as stream: stream.write(b'x')
        for name in ('atomic.json','write.json','plain'):
            self.assertEqual((self.directory/name).stat().st_mode&0o777,0o600,name)
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
    def test_resume_pre_apply_failure_preserves_receipt_without_replaying_stale_scope(self):
        scope={'operation_id':self.directory.name}
        L['write'](self.directory/'scope.json',scope)
        journal=D.Journal(L,self.directory,L['sha'](L['canon'](scope)))
        journal.record('foundation','unknown')
        result={'status':'failure','cleanup_status':'not_needed','error':{'reason':'explicit inventory fields required'}}
        L['write'](self.directory/'result.json',result)
        before={p:p.read_bytes() for p in self.directory.rglob('*.json')}
        with patch.object(D,'validate_operation',return_value=(self.directory,scope,{})),\
             patch.object(D,'execute',side_effect=AssertionError('stale scope replayed')):
            self.assertEqual(D.resume({'L':L},'config',self.directory),result)
            self.assertEqual(D.cancel({'L':L},'config',self.directory),result)
        self.assertEqual({p:p.read_bytes() for p in self.directory.rglob('*.json')},before)
    def pipeline(self,ingest_failure=False,unknown_launch=False,mode='job',cancelled=False,store=None,migration=False,migration_failure=False,legacy_scope=False,foundation_failure=None):
        directory=self.directory; calls=[]; project=json.loads((ROOT/'infra/aws/project.example.json').read_text()); project['mode']=mode
        target={'profile':'offline','account_id':'111111111111','region':'us-east-1','operator_arn':'arn:aws:iam::111111111111:user/operator',
            'deployment_role_arn':'arn:aws:iam::111111111111:role/deployer','backend':{},'inventory':{'resource_prefix':self.prefix,'buckets':['workload']}}
        registry=directory.parent/'registry' if store else directory/'registry'; deployment={'configuration':project,'account_id':target['account_id'],
            'names':{'workspace_id':project['project']+'-'+project['workspace'],'workload_bucket':'workload'},'repository':{'url':'https://github.com/owner/project.git','revision':'a'*40},
            'dataset':{'adapter':'local','source':'unused'}}
        size={**L['supported_sizes']()['r8i.2xlarge'],'policy':'ram-first','instance_type':'r8i.2xlarge','availability_zone':'us-east-1a','hourly_usd':1}
        scope={'target':target,'registry_directory':str(registry),'capacity':{'selected':size,'candidates':[size]},'foundation':None,
            'foundation_iam_migration':None,'repository_reference':None,'new_private_access':False,'outputs':{'paths':['outputs'],'maximum_bytes':100},'dataset':{'inventory':[]}}
        if legacy_scope: del scope['foundation_iam_migration']
        task={'scope_sha256':'b'*64,'authorization':'authorized bounded mocked operation'}
        if cancelled: L['write'](directory/'cancel.json',{'requested_at':L['stamp']()})
        artifacts={'toolbox_zip_sha256':'c'*64}; binding={'plan_directory':str(directory/'foundation/platform')}
        migrated={'plan_directory':str(directory/'foundation-iam')}
        if migration:
            scope['foundation']=binding
            scope['foundation_iam_migration']={'required':True,'before_policy_sha256':'e'*64,
                'role_arn':target['deployment_role_arn'],'operator_arns':[target['operator_arn']]}
        def migrate(*args):
            calls.append('iam-migration')
            self.assertEqual(args[2],binding)
            self.assertEqual(args[4],scope['foundation_iam_migration'])
            if migration_failure: raise TimeoutError('uncertain IAM migration')
            return migrated
        def provision(*args):
            calls.append('foundation')
            if foundation_failure:
                if foundation_failure=='after-bootstrap':
                    bootstrap=directory/'foundation/bootstrap'
                    L['write'](bootstrap/'apply-started.json',{})
                    L['write'](bootstrap/'apply-result.json',{'status':'success'})
                raise L['Failure']('foundation failed')
            return binding
        O=types.SimpleNamespace(prepare=lambda *a:calls.append('foundation-inputs'),provision=provision,
            capacity=lambda *a,**kw: {'candidates':[size]},migrate_iam=migrate,iam_migration=lambda *a:{'required':True})
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
            control=Path(control); control.mkdir(); L['write'](control/'runner.json',{'lease':{'starts_at':starts},'instance_type':'r8i.2xlarge','availability_zone':size['availability_zone']})
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
        with patch.object(D,'extensions',return_value={'onboarding':O,'ingest':I,'e2e':EE}),patch.object(D,'apply_stage',side_effect=apply_stage),patch.object(D,'cleanup_runner',side_effect=cleanup),patch.dict(L,{'build':build,'sessions':lambda _: (None,lambda *a:s3,None)}),\
             patch.object(D.time,'sleep',side_effect=AssertionError('ready deployment added an idle scheduling delay')):
            result=D.execute({'L':L,'render':render},'config',directory,scope,task)
        return result,calls
    def test_short_config_pipeline_transfers_before_launch_and_verifies_after_cleanup(self):
        result,calls=self.pipeline()
        self.assertEqual(result['status'],'success'); self.assertTrue(result['verified_after_compute_deletion'])
        self.assertLess(calls.index('ingestion'),calls.index('prepare')); self.assertLess(calls.index('prepare'),calls.index('launch'))
        self.assertLess(calls.index('cleanup'),calls.index('verify-after'))
        records=D.Journal(L,self.directory,'b'*64).records
        self.assertEqual([r['state'] for r in records if r['stage']=='cleanup'],['started','completed'])
    def test_failed_ingestion_launches_no_compute(self):
        result,calls=self.pipeline(ingest_failure=True)
        self.assertEqual(result['status'],'failure'); self.assertNotIn('launch',calls); self.assertNotIn('job',calls)
        self.assertFalse(result['recovery_required'])
    def test_pre_apply_failure_releases_ownership_and_allows_a_new_review(self):
        result,calls=self.pipeline(foundation_failure='before-apply')
        self.assertEqual(result['cleanup_status'],'not_needed')
        self.assertFalse(result['recovery_required'])
        self.assertEqual(list((self.directory/'registry').glob('*-active.json')),[])
        self.assertIn('new review','\n'.join(D.describe_result('config',result)))
        self.assertNotIn('launch',calls)
    def test_completed_bootstrap_with_incomplete_foundation_keeps_recovery_ownership(self):
        result,calls=self.pipeline(foundation_failure='after-bootstrap')
        self.assertEqual(result['cleanup_status'],'not_needed')
        self.assertTrue(result['recovery_required'])
        self.assertEqual(len(list((self.directory/'registry').glob('*-active.json'))),1)
        self.assertIn('config resume','\n'.join(D.describe_result('config',result)))
        self.assertNotIn('launch',calls)
    def test_public_retained_foundation_migrates_before_ingestion_and_updates_binding(self):
        result,calls=self.pipeline(migration=True)
        self.assertEqual(result['status'],'success',result)
        self.assertLess(calls.index('foundation'),calls.index('iam-migration'))
        self.assertLess(calls.index('iam-migration'),calls.index('ingestion'))
        updated={'plan_directory':str(self.directory/'foundation-iam')}
        self.assertEqual(L['read'](self.directory/'registry/foundation.json'),updated)
        self.assertEqual(L['read'](self.directory/'runtime.json')['foundation'],updated)
    def test_uncertain_iam_migration_blocks_ingestion_launch_and_retains_operation_ownership(self):
        result,calls=self.pipeline(migration=True,migration_failure=True)
        self.assertEqual(result['status'],'failure')
        self.assertNotIn('ingestion',calls); self.assertNotIn('launch',calls)
        self.assertEqual(len(list((self.directory/'registry').glob('*-active.json'))),1)
        self.assertEqual(D.Journal(L,self.directory,'b'*64).latest('foundation-iam')['state'],'unknown')
    def test_legacy_authorization_requires_new_migration_review_before_ingestion(self):
        result,calls=self.pipeline(legacy_scope=True)
        self.assertEqual(result['status'],'failure')
        self.assertIn('prepare a new deploy review',result['error']['reason'])
        self.assertNotIn('iam-migration',calls); self.assertNotIn('ingestion',calls); self.assertNotIn('launch',calls)
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
    def review_scope(self):
        size={'instance_type':'r8i.2xlarge','availability_zone':'us-east-1a','hourly_usd':1.5,'disk_gb':25}
        return {'disk':D.disk_fit(L,size,3,100*1024*1024),'operation_id':self.directory.name,'target':{'account_id':'111111111111','operator_arn':'arn:aws:iam::111111111111:user/operator','region':'us-east-1'},
            'capacity':{'selected':size},'repository':{'url':'https://github.com/owner/project.git','revision':'a'*40},'new_private_access':False,
            'dataset':{'inventory':[{'path':'rows.csv','bytes':3}],'total_bytes':3,'source':{'source':'/data'}},'maximum_runtime_minutes':30,
            'estimated_compute_usd':0.75,'mode':'job','cleanup':'owned compute after job','foundation':None,'foundation_iam_migration':None,
            'outputs':{'paths':['outputs'],'maximum_bytes':100*1024*1024},'retained_resources':['buckets'],'additional_cost_scope':['storage']}
    def test_interactive_confirmation_binds_the_displayed_scope_once(self):
        scope=self.review_scope(); executed=[]
        clean={'revision':'a'*40,'working_tree_sha256':L['sha'](b'')}
        with patch.object(D,'prepare',return_value=(self.directory,scope)),patch.object(D,'execute',side_effect=lambda W,c,d,s,t:executed.append(t) or {'status':'success'}),\
             patch.dict(L,{'source':lambda:clean}),patch.object(sys.stdin,'isatty',return_value=True),patch.object(sys.stdout,'isatty',return_value=True),\
             patch('builtins.input',return_value='deploy'):
            result=D.deploy({'L':L},'config')
        self.assertEqual(result['status'],'success'); self.assertEqual(len(executed),1)
        task=L['read'](self.directory/'task-authorization.json')
        self.assertEqual(task['scope_sha256'],L['sha'](L['canon'](scope))); self.assertTrue(task['authorization'].startswith('Interactive confirmation'))
    def test_declined_or_noninteractive_review_never_launches(self):
        scope=self.review_scope()
        for tty,answer in ((True,''),(True,'yes'),(False,'deploy')):
            with self.subTest(tty=tty,answer=answer),patch.object(D,'prepare',return_value=(self.directory,scope)),\
                 patch.object(D,'execute',side_effect=AssertionError('launched without authorization')),\
                 patch.object(sys.stdin,'isatty',return_value=tty),patch.object(sys.stdout,'isatty',return_value=tty),patch('builtins.input',return_value=answer):
                result=D.deploy({'L':L},'config')
            self.assertEqual(result['status'],'review_required'); self.assertFalse(result['cloud_mutations'])
            self.assertFalse((self.directory/'task-authorization.json').exists())
    def test_proxy_review_still_requires_the_exact_deploy_answer(self):
        scope=self.review_scope()
        with patch.object(sys.stdin,'isatty',return_value=True),patch.object(sys.stdout,'isatty',return_value=False):
            with patch('builtins.input',return_value='yes'):
                self.assertIsNone(D.confirm(L,scope))
            with patch('builtins.input',return_value='deploy'):
                self.assertIn(L['sha'](L['canon'](scope))[:16],D.confirm(L,scope))
    def test_noninteractive_authorization_must_quote_the_reviewed_scope_hash(self):
        scope=self.review_scope(); executed=[]; digest=L['sha'](L['canon'](scope))[:16]
        clean={'revision':'a'*40,'working_tree_sha256':L['sha'](b'')}
        with patch.object(D,'prepare',return_value=(self.directory,scope)),patch.object(D,'latest',return_value=self.directory),\
             patch.object(D,'execute',side_effect=lambda W,c,d,s,t:executed.append(t) or {'status':'success'}),patch.dict(L,{'source':lambda:clean}),\
             patch.object(sys.stdin,'isatty',return_value=False),patch.object(sys.stdout,'isatty',return_value=False):
            review=D.deploy({'L':L},'config')
            self.assertEqual(review['status'],'review_required'); self.assertEqual(review['scope_sha256'][:16],digest)
            self.assertIn('--authorization "approve scope '+digest+'"','\n'.join(D.describe_result('/p/project.json',review)))
            for text in ('Approve the displayed scope','approve scope '+'0'*16,digest[:8]):
                with self.subTest(text=text),self.assertRaisesRegex(L['Failure'],'scope hash '+digest): D.deploy({'L':L},'config',authorization=text)
            self.assertEqual(executed,[]); self.assertFalse((self.directory/'task-authorization.json').exists())
            result=D.deploy({'L':L},'config',authorization='approve scope '+digest)
        self.assertEqual(result['status'],'success'); self.assertEqual(len(executed),1)
        self.assertEqual(L['read'](self.directory/'task-authorization.json')['scope_sha256'],L['sha'](L['canon'](scope)))
    def test_dataset_and_outputs_must_fit_the_fixed_workspace_disk(self):
        size={'disk_gb':25}; outputs=100*1024*1024; fits=25*1024**3-D.DISK_RESERVE_BYTES-outputs
        self.assertEqual(D.disk_fit(L,size,fits,outputs)['usable_bytes'],25*1024**3)
        for dataset,output in ((fits+1,outputs),(0,25*1024**3)):
            with self.subTest(dataset=dataset,output=output),self.assertRaisesRegex(L['Failure'],'exceed the 25 GiB workspace disk'):
                D.disk_fit(L,size,dataset,output)
    def test_readable_scope_and_outcome_summaries(self):
        lines='\n'.join(D.describe_scope(self.review_scope()))
        for expected in ('111111111111','us-east-1a','r8i.2xlarge','30 minutes','0.75 USD','create new foundation','owner/project.git',
                         '8 GiB environment reserve of 25 GiB usable; fixed gp3 root volume, no added cost'): self.assertIn(expected,lines)
        outcome='\n'.join(D.describe_result('/p/project.json',{'status':'failure','cleanup_status':'unknown','setup_exit':0,'job_exit':None,'outputs_persisted':False,'error':{'reason':'lost'}}))
        self.assertIn('./workspace /p/project.json resume',outcome); self.assertIn('lost',outcome)
        self.assertIn('reuses the retained data','\n'.join(D.describe_result('/p/project.json',{'status':'success','output_uri':'s3://b/o/'})))

if __name__=='__main__': unittest.main(verbosity=2)
