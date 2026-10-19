"""Offline destructive-scope checks; no AWS account calls or real deletion."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch
import uuid
from botocore.exceptions import LoginRefreshRequired

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT/'scripts/aws'))
spec = importlib.util.spec_from_file_location('cleanup_workspace', ROOT/'scripts/aws/workspace.py')
W = importlib.util.module_from_spec(spec); spec.loader.exec_module(W)
import workspace_s3_cleanup as C
L = W.L


class Store:
    def __init__(self):
        self.versions, self.uploads, self.deleted, self.aborted = [], [], [], []
        self.errors = False; self.lost = False; self.add_after_delete = False
        self.partial = False
        self.region = 'us-east-1'; self.versioning = 'Enabled'; self.owner = None

    def check(self, args):
        assert (args['Bucket'], args['ExpectedBucketOwner']) == self.owner

    def get_bucket_location(self, **args):
        self.check(args); return {'LocationConstraint': self.region}

    def get_bucket_versioning(self, **args):
        self.check(args); return {'Status': self.versioning}

    def list_object_versions(self, **args):
        self.check(args)
        matches = [v for v in self.versions if v['Key'].startswith(args['Prefix'])]
        return {'IsTruncated':False, 'Versions': [{k:v for k,v in item.items() if k != 'marker'} for item in matches if not item.get('marker')],
                'DeleteMarkers': [{k:v for k,v in item.items() if k not in ('marker','Size')} for item in matches if item.get('marker')]}

    def list_multipart_uploads(self, **args):
        self.check(args)
        return {'IsTruncated':False, 'Uploads': [u for u in self.uploads if u['Key'].startswith(args['Prefix'])]}

    def delete_objects(self, **args):
        self.check(args); batch = args['Delete']['Objects']
        assert args['Delete']['Quiet'] is False and 0 < len(batch) <= 1000
        assert all(set(v) == {'Key','VersionId'} for v in batch)
        selected = {(v['Key'],v['VersionId']) for v in batch}
        self.deleted.extend(copy.deepcopy(batch))
        if self.errors: return {'Errors':[{'Code':'AccessDenied','Message':'SENTINEL_SECRET'}]}
        if self.partial:
            first = batch[0]
            self.versions = [v for v in self.versions if (v['Key'],v['VersionId']) != (first['Key'],first['VersionId'])]
            return {'Deleted':[copy.deepcopy(first)],'Errors':[{'Code':'AccessDenied','Message':'SENTINEL_SECRET'}]}
        self.versions = [v for v in self.versions if (v['Key'],v['VersionId']) not in selected]
        if self.lost: raise TimeoutError('SENTINEL_SECRET')
        if self.add_after_delete:
            self.versions.append({'Key':batch[0]['Key'],'VersionId':'concurrent-new','Size':1})
        return {'Deleted': copy.deepcopy(batch)}

    def abort_multipart_upload(self, **args):
        self.check(args)
        item = {k:args[k] for k in ('Key','UploadId')}
        self.aborted.append(item); self.uploads.remove(item)

    def list_parts(self, **args):
        self.check(args); return {'Parts':[], 'IsTruncated':False}


class Cleanup(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ); self.environment.start(); self.addCleanup(self.environment.stop)
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT/'evidence'); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'dataset').mkdir(); (self.root/'dataset/input.csv').write_text('x\n1\n')
        self.project = json.loads((ROOT/'infra/aws/project.example.json').read_text())
        self.project.setdefault('mode','job')
        self.project['project'] = 'cleanup-'+uuid.uuid4().hex[:8]
        self.config = self.root/'project.json'; self.config.write_text(json.dumps(self.project))
        clean_source = {'revision':'a'*40,'working_tree_sha256':L['sha'](b'')}
        self.source = patch.dict(L, {'source':lambda:clean_source, 'prior_source':lambda _:True})
        self.source.start(); self.addCleanup(self.source.stop)
        observed = {'schema_version':'1.0.0','kind':'aws-project-discovery','profile':self.project['profile'],
                    'region':self.project['region'],'identity':{'Account':'111111111111','Arn':'arn:aws:iam::111111111111:user/operator'},
                    'repository':{**self.project['repository'],'revision':'a'*40,'resolved_ref':'refs/heads/main','verification':'advertised-ref'}}
        discovery = self.root/'discovery.json'; discovery.write_text(json.dumps(observed))
        configured = W.P.configure(L, self.config, discovery)
        self.operation = ROOT/configured['operation_directory']; self.addCleanup(shutil.rmtree, self.operation)
        self.deployment = configured['review']
        O = C.D.extensions(L)['onboarding']; self.target = O.target(self.deployment, observed['identity']['Arn'])
        self.registry = ROOT/'evidence/aws/projects'/self.target['inventory']['resource_prefix']
        self.registry.mkdir(parents=True, exist_ok=False); self.addCleanup(shutil.rmtree, self.registry)
        self.binding = {'plan_directory':str(self.root/'foundation')}
        L['write'](self.registry/'foundation.json', self.binding)
        scope = {'source':clean_source,'target':self.target,'configuration_sha256':L['sha'](L['canon'](self.project)),
                 'deployment_sha256':L['sha'](L['canon'](self.deployment))}
        L['write'](self.operation/'scope.json', scope)
        selection = C.D.selection(L, W.P, self.config)
        L['write'](selection, {'directory':str(self.operation)}); self.addCleanup(selection.unlink)
        self.platform = {'storage_layout':'readable-v1','ml_projects':{self.project['project']:{'ml_project_name':self.project['project'],'storage_mode':'auto'}}}
        self.verified = []
        self.O = types.SimpleNamespace(verify_retained=self.verify)
        self.store = Store(); self.store.owner = (self.target['inventory']['buckets'][0], self.target['account_id'])
        self.workspace = self.project['project']+'-'+self.project['workspace']
        self.data, self.results = C.prefixes(self.project['project'],self.workspace,'readable-v1')
        self.store.versions = [{'Key':self.results+'run/files/result.csv','VersionId':'old','Size':5},
                               {'Key':self.results+'run/files/result.csv','VersionId':'new','Size':7},
                               {'Key':self.results+'run/files/result.csv','VersionId':'marker','marker':True},
                               {'Key':self.data+'snapshot/files/input.csv','VersionId':'data','Size':3},
                               {'Key':'results/another-workspace/run/result','VersionId':'other','Size':2}]
        self.store.uploads = [{'Key':self.results+'run/incomplete','UploadId':'owned-upload'},
                              {'Key':'results/another-workspace/incomplete','UploadId':'other-upload'}]
        self.native_sessions = L['sessions']
        self.patches = [patch.object(C.D,'extensions',return_value={'onboarding':self.O,'config':W.P}),
                        patch.dict(L, {'sessions':lambda _: (None,lambda *_:self.store,None)}),
                        patch.dict(L['boundary'], {'profile_environment':lambda *_:{}})]
        for p in self.patches: p.start(); self.addCleanup(p.stop)
        self.output = io.StringIO()

    def verify(self, *_):
        self.verified.append(True)
        return self.platform

    def confirm(self, _prompt):
        review = self.reviews()[-1]
        return 'delete '+L['sha'](L['canon'](L['read'](review)))[:16]

    def reviews(self):
        return sorted((ROOT/'evidence/aws/s3-cleanup').glob('*/review.json'),key=lambda p:p.stat().st_mtime_ns)

    def clean(self, **options):
        with patch.object(C,'interactive',return_value=True), patch('builtins.input',side_effect=self.confirm), \
             patch.object(sys,'stderr',self.output):
            return C.clean(vars(W),self.config,**options)

    def test_default_deletes_only_selected_workspace_versions_markers_and_uploads(self):
        result = self.clean()
        self.assertEqual(result['status'],'success'); self.assertTrue(result['verified'])
        self.assertEqual(result['deleted_versions'],3); self.assertEqual(result['aborted_uploads'],1)
        self.assertEqual({v['VersionId'] for v in self.store.versions},{'data','other'})
        self.assertEqual(self.store.uploads,[{'Key':'results/another-workspace/incomplete','UploadId':'other-upload'}])
        self.assertEqual(len(self.verified),2)
        self.assertIn('cannot be undone',self.output.getvalue())
        receipt = Path(result['receipt_file']); self.assertEqual(receipt.stat().st_mode & 0o777,0o600)
        authorization = L['read'](receipt.parent/'authorization.json')
        self.assertEqual(authorization['scope_sha256'],result['scope_sha256'])

    def test_datasets_are_explicit_and_cached_manifest_is_preserved_outside_reuse_pointer(self):
        cache = {'content_sha256':'a'*64,'bucket':self.store.owner[0]}
        L['write'](self.registry/'dataset.json',cache)
        result = self.clean(include_datasets=True)
        self.assertEqual(result['status'],'success'); self.assertEqual(result['deleted_versions'],4)
        self.assertTrue(result['dataset_cache_archived']); self.assertFalse((self.registry/'dataset.json').exists())
        self.assertEqual(L['read'](Path(result['receipt_file']).parent/'dataset-cache.json'),cache)
        self.assertTrue((self.root/'dataset/input.csv').exists()); self.assertTrue((self.registry/'foundation.json').exists())
        self.assertEqual({v['VersionId'] for v in self.store.versions},{'other'})

    def test_decline_wrong_hash_and_noninteractive_input_never_delete(self):
        for answer in ('', 'y', 'delete', 'delete '+'0'*16):
            with self.subTest(answer=answer), patch.object(C,'interactive',return_value=True), \
                 patch('builtins.input',return_value=answer), patch.object(sys,'stderr',self.output):
                result = C.clean(vars(W),self.config)
                self.assertEqual(result['status'],'cancelled')
        with patch.object(C,'interactive',return_value=False), patch('builtins.input',side_effect=AssertionError('read redirected input')),patch.object(sys,'stderr',self.output):
            self.assertEqual(C.clean(vars(W),self.config)['status'],'confirmation_required')
        self.assertEqual(self.store.deleted,[]); self.assertEqual(self.store.aborted,[])

    def test_preview_never_prompts_or_moves_dataset_cache(self):
        L['write'](self.registry/'dataset.json', {'kept':True})
        with patch.object(self,'confirm',side_effect=AssertionError('preview prompted')):
            result = self.clean(include_datasets=True,dry_run=True)
        self.assertEqual(result['status'],'preview'); self.assertFalse(result['cloud_mutations'])
        self.assertTrue((self.registry/'dataset.json').exists()); self.assertEqual(self.store.deleted,[])

    def test_active_and_unresolved_work_blocks_cleanup_before_native_calls(self):
        L['write'](self.registry/'other-workspace-active.json', {'operation_id':'unresolved'})
        with self.assertRaisesRegex(ValueError,'active or unresolved'):
            self.clean()
        self.assertEqual(self.verified,[]); self.assertEqual(self.store.deleted,[])

    def test_live_compute_and_ownership_failure_cannot_reach_confirmation(self):
        self.O.verify_retained = lambda *_: (_ for _ in ()).throw(ValueError('covered compute remains'))
        with patch('builtins.input',side_effect=AssertionError('prompt before verification')),self.assertRaisesRegex(ValueError,'compute remains'):
            self.clean()
        self.assertEqual(self.store.deleted,[])

    def test_expired_login_stops_before_confirmation_and_preserves_dataset_reuse(self):
        L['write'](self.registry/'dataset.json', {'kept':True})
        self.O.verify_retained = lambda *_: self.native_sessions(self.target)
        with patch('boto3.Session',side_effect=LoginRefreshRequired()) as session, \
             patch('builtins.input',side_effect=AssertionError('prompt before sign-in')), \
             self.assertRaises(L['Failure']) as caught:
            self.clean(include_datasets=True)
        self.assertIn('./workspace login --profile '+self.target['profile']+' --region '+self.target['region'],str(caught.exception))
        session.assert_called_once_with(profile_name=self.target['profile'],region_name=self.target['region'])
        self.assertEqual(self.store.deleted,[]); self.assertEqual(self.store.aborted,[])
        self.assertEqual(L['read'](self.registry/'dataset.json'),{'kept':True})
        with C.D.locked(L,ROOT/'evidence/aws/locks'/(self.target['inventory']['resource_prefix']+'.lock')):
            pass

    def test_cli_offers_native_relogin_then_reviews_and_confirms_cleanup_in_one_command(self):
        events=[]
        def answer(prompt):
            if 'Sign in to AWS' in prompt:
                events.append('offer-login'); self.assertEqual(self.store.deleted,[])
                return 'y'
            events.append('confirm-deletion')
            self.assertIn('native-login',events); self.assertTrue(self.verified)
            return self.confirm(prompt)
        def native(command):
            events.append('native-login')
            self.assertEqual(command,['aws','login','--profile',self.project['profile'],'--region',self.project['region'],'--remote'])
        identity={'Account':self.target['account_id'],'Arn':self.target['operator_arn']}
        authenticated={'identity':identity,'sdk_identity':identity}
        with patch.object(W.A,'auth_check',side_effect=[L['boundary']['LoginRequired']('expired_login'),authenticated]) as check, \
             patch.object(W.A,'profile_method',return_value='console'), patch.object(W.A,'user_terminal',return_value=True), \
             patch.object(W.A,'ssh_session',return_value=True), patch.object(W.A,'interactive',side_effect=native), \
             patch.object(C,'interactive',return_value=True), patch('builtins.input',side_effect=answer), \
             patch.object(sys,'argv',['workspace.py',str(self.config),'clean-s3','--include-datasets']), \
             patch.object(sys,'stderr',self.output), patch.object(sys,'stdout',new_callable=io.StringIO) as stdout:
            W.main()
        self.assertEqual(check.call_count,2)
        self.assertEqual(events,['offer-login','native-login','confirm-deletion'])
        result=json.loads(stdout.getvalue()); self.assertEqual(result['status'],'success')
        self.assertEqual(result['deleted_versions'],4)

    def test_cli_declined_relogin_never_enters_cleanup_or_deployment(self):
        for verb,options in (('clean-s3',[]),('deploy',[]),('deploy',['--authorization','exact-original-authorization']),('deploy',['--authorization',''])):
            with self.subTest(verb=verb,options=options), \
                 patch.object(W.A,'ensure_login',side_effect=L['Failure']('AWS sign-in cancelled')) as auth, \
                 patch.object(C,'clean',side_effect=AssertionError('cleanup after declined sign-in')), \
                 patch.object(sys,'argv',['workspace.py',str(self.config),verb,*options]), \
                 self.assertRaisesRegex(L['Failure'],'sign-in cancelled'):
                W.main()
            auth.assert_called_once_with(self.project['profile'],self.project['region'],allow_login=not bool(options))
        self.assertEqual(self.store.deleted,[]); self.assertEqual(self.store.aborted,[])

    def test_region_versioning_and_external_assignments_are_refused(self):
        for field, value in (('region','eu-west-1'),('versioning','Suspended')):
            with self.subTest(field=field):
                prior = getattr(self.store,field); setattr(self.store,field,value)
                with self.assertRaisesRegex(ValueError,'region/versioning'): self.clean()
                setattr(self.store,field,prior)
        self.platform['ml_projects'][self.project['project']]['assignment']={'ownership':'external'}
        with self.assertRaisesRegex(ValueError,'external storage is protected'): self.clean()
        self.assertEqual(self.store.deleted,[])

    def test_state_and_foreign_buckets_are_never_accepted(self):
        for bucket in (self.target['backend']['bucket'],'foreign-bucket'):
            with self.assertRaisesRegex(ValueError,'cannot be cleaned'):
                C.storage_guard(self.store,self.target,bucket)
        self.assertEqual(self.store.deleted,[])

    def test_objects_changed_during_confirmation_require_a_fresh_review(self):
        original = self.confirm
        def confirm(prompt):
            answer = original(prompt)
            self.store.versions.append({'Key':self.results+'new','VersionId':'concurrent','Size':1})
            return answer
        with patch.object(self,'confirm',side_effect=confirm),self.assertRaisesRegex(ValueError,'changed during review'):
            self.clean()
        self.assertEqual(self.store.deleted,[]); self.assertEqual(self.store.aborted,[])
        self.assertFalse(L['read'](self.reviews()[-1].parent/'receipt.json')['verified'])

    def test_new_versions_after_deletion_are_preserved_and_reported_as_unverified(self):
        self.store.add_after_delete = True
        with self.assertRaisesRegex(ValueError,'could not verify'): self.clean()
        self.assertTrue(any(v['VersionId']=='concurrent-new' for v in self.store.versions))
        self.assertFalse(L['read'](self.reviews()[-1].parent/'receipt.json')['verified'])

    def test_source_review_and_activity_drift_after_confirmation_never_delete(self):
        original = self.confirm
        for fault in ('review','activity','source','compute'):
            with self.subTest(fault=fault):
                def confirm(prompt):
                    answer = original(prompt)
                    if fault=='review':
                        review = self.reviews()[-1]; value = L['read'](review); value['prefixes']=['']
                        review.write_text(json.dumps(value))
                    elif fault=='activity':
                        L['write'](self.registry/'concurrent-active.json', {'operation_id':'concurrent'})
                    elif fault=='source':
                        L['source'] = lambda:{'revision':'b'*40,'working_tree_sha256':L['sha'](b'')}
                    else:
                        self.O.verify_retained = lambda *_: (_ for _ in ()).throw(ValueError('covered compute remains'))
                    return answer
                before = L['source']
                with patch.object(self,'confirm',side_effect=confirm),self.assertRaises(ValueError): self.clean()
                self.assertEqual(self.store.deleted,[]); self.assertEqual(self.store.aborted,[])
                L['source'] = before; self.O.verify_retained = self.verify
                active = self.registry/'concurrent-active.json'
                if active.exists(): active.unlink()

    def test_partial_api_success_records_exact_confirmed_and_unconfirmed_versions(self):
        self.store.partial = True
        with self.assertRaisesRegex(ValueError,'did not confirm'): self.clean()
        folder = self.reviews()[-1].parent
        receipt = L['read'](folder/'receipt.json'); response = L['read'](folder/'batch-000000-response.json')
        self.assertEqual(receipt['deleted_versions'],1); self.assertFalse(receipt['verified'])
        self.assertEqual(len(response['confirmed_deleted']),1); self.assertEqual(len(response['unconfirmed']),2)
        self.assertNotIn('SENTINEL_SECRET',(folder/'receipt.json').read_text()+self.output.getvalue())

    def test_upload_parts_are_verified_and_cannot_be_reported_as_clean_while_remaining(self):
        with patch.object(self.store,'list_parts',return_value={'Parts':[{'PartNumber':1}]}),self.assertRaisesRegex(ValueError,'still has parts'):
            self.clean()
        self.assertEqual(self.store.deleted,[])
        self.assertFalse(L['read'](self.reviews()[-1].parent/'receipt.json')['verified'])

    def test_interruption_preserves_authorization_intent_and_failure_receipt(self):
        def interrupted(**_):
            pending = L['read'](self.reviews()[-1].parent/'receipt.json')
            self.assertEqual(pending['status'],'in_progress'); self.assertTrue(pending['cloud_mutations'])
            raise KeyboardInterrupt()
        self.store.uploads = []
        with patch.object(self.store,'delete_objects',side_effect=interrupted),self.assertRaises(KeyboardInterrupt): self.clean()
        folder = self.reviews()[-1].parent
        self.assertTrue((folder/'authorization.json').exists()); self.assertTrue((folder/'batch-000000-intent.json').exists())
        self.assertEqual(L['read'](folder/'receipt.json')['error_type'],'KeyboardInterrupt')

    def test_empty_dataset_cleanup_can_archive_stale_reuse_metadata(self):
        self.store.versions=[]; self.store.uploads=[]
        L['write'](self.registry/'dataset.json', {'historical':True})
        result = self.clean(include_datasets=True)
        self.assertEqual(result['status'],'success'); self.assertFalse(result['cloud_mutations'])
        self.assertTrue(result['dataset_cache_archived']); self.assertFalse((self.registry/'dataset.json').exists())

    def test_partial_errors_and_lost_responses_leave_failure_receipts_and_archived_cache(self):
        for fault in ('errors','lost'):
            with self.subTest(fault=fault):
                L['write'](self.registry/'dataset.json', {'kept_as_evidence':True})
                self.store.errors = fault=='errors'; self.store.lost = fault=='lost'
                with self.assertRaises((ValueError,TimeoutError)): self.clean(include_datasets=True)
                receipt = L['read'](self.reviews()[-1].parent/'receipt.json')
                self.assertEqual(receipt['status'],'failure'); self.assertFalse(receipt['verified'])
                self.assertTrue(receipt['dataset_cache_archived']); self.assertFalse((self.registry/'dataset.json').exists())
        self.assertNotIn('SENTINEL_SECRET',self.output.getvalue())

    def test_deletes_are_batched_by_exact_version_id(self):
        self.store.versions = [{'Key':self.results+'result','VersionId':'v'+str(i),'Size':1} for i in range(1001)]
        result = self.clean()
        self.assertEqual(result['deleted_versions'],1001)
        self.assertEqual(len(list(Path(result['receipt_file']).parent.glob('batch-*-intent.json'))),2)

    def test_legacy_namespaces_remain_supported_without_broad_deletion(self):
        self.platform['storage_layout'] = 'legacy'
        bucket = C.workload_bucket(self.target['account_id'],self.target['region'],self.project['project'])
        self.target['inventory']['buckets'] = [bucket]; self.store.owner = (bucket,self.target['account_id'])
        scope = L['read'](self.operation/'scope.json'); scope['target'] = self.target
        deployment = L['read'](self.operation/'deployment.json'); deployment['names']['workload_bucket'] = bucket
        (self.operation/'deployment.json').write_text(json.dumps(deployment))
        operation = L['read'](self.operation/'operation.json')
        operation['files']['deployment.json'] = L['sha']((self.operation/'deployment.json').read_bytes())
        (self.operation/'operation.json').write_text(json.dumps(operation))
        scope['deployment_sha256'] = L['sha'](L['canon'](deployment))
        (self.operation/'scope.json').write_text(json.dumps(scope))
        data, results = C.prefixes(self.project['project'],self.workspace,'legacy')
        self.store.versions = [{'Key':results+'run/result','VersionId':'old','Size':1},
                               {'Key':data+'snapshot/input','VersionId':'dataset','Size':1}]
        self.store.uploads=[]
        result = self.clean()
        self.assertEqual(result['deleted_versions'],1)
        self.assertEqual(self.store.versions[0]['VersionId'],'dataset')

    def test_inventory_rejects_foreign_keys_duplicates_null_versions_and_stalled_pages(self):
        owner = {'Bucket':self.store.owner[0],'ExpectedBucketOwner':self.target['account_id']}
        for page in ({},
                     {'IsTruncated':False,'Versions':[{'Key':'outside','VersionId':'v'}]},
                     {'IsTruncated':False,'Versions':[{'Key':self.results+'a','VersionId':'null'}]},
                     {'IsTruncated':False,'Versions':[{'Key':self.results+'a','VersionId':'v'}]*2},
                     {'IsTruncated':True,'NextKeyMarker':'same','NextVersionIdMarker':'same'}):
            with self.subTest(page=page),patch.object(self.store,'list_object_versions',return_value=page),self.assertRaises(ValueError):
                C.inventory(L,self.store,owner,[self.results],time.monotonic()+5)
        with patch.object(C,'MAX_ITEMS',0),self.assertRaisesRegex(ValueError,'entries'):
            C.inventory(L,self.store,owner,[self.results],time.monotonic()+5)

    def test_version_and_upload_pagination_keep_both_markers(self):
        owner = {'Bucket':self.store.owner[0],'ExpectedBucketOwner':self.target['account_id']}
        with patch.object(self.store,'list_object_versions',side_effect=[
                {'Versions':[{'Key':self.results+'a','VersionId':'v1'}],'IsTruncated':True,'NextKeyMarker':'key','NextVersionIdMarker':'v1'},
                {'IsTruncated':False,'DeleteMarkers':[{'Key':self.results+'b','VersionId':'v2'}]}]) as versions, \
             patch.object(self.store,'list_multipart_uploads',side_effect=[
                {'Uploads':[{'Key':self.results+'a','UploadId':'u1'}],'IsTruncated':True,'NextKeyMarker':'key','NextUploadIdMarker':'u1'},
                {'IsTruncated':False,'Uploads':[{'Key':self.results+'b','UploadId':'u2'}]}]) as uploads:
            value = C.inventory(L,self.store,owner,[self.results],time.monotonic()+5)
        self.assertEqual(len(value['versions']),2); self.assertEqual(len(value['uploads']),2)
        self.assertEqual(versions.call_args.kwargs['VersionIdMarker'],'v1')
        self.assertEqual(uploads.call_args.kwargs['UploadIdMarker'],'u1')

    def test_make_and_cli_expose_separate_cleanup_without_yes_bypass(self):
        result = subprocess.run(['bash','workspace',str(self.config),'clean-s3','--help'],capture_output=True,text=True,timeout=15,
                                env={**os.environ,'WORKSPACE_PYTHON':sys.executable})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('--include-datasets',result.stdout); self.assertNotIn('--yes',result.stdout)
        rejected = subprocess.run(['bash','workspace',str(self.config),'clean-s3','--yes'],capture_output=True,text=True,timeout=15,
                                  env={**os.environ,'WORKSPACE_PYTHON':sys.executable})
        self.assertEqual(rejected.returncode,2)
        source = self.root/'make'; source.mkdir()
        shutil.copyfile(ROOT/'Makefile',source/'Makefile')
        (source/'workspace').write_text('#!/bin/bash\nprintf "%s\\n" "$@"\ntest -z "${WORKSPACE_PYTHON:-}"\n')
        path = str(self.root/"project's `touch SENTINEL` folder/project.json")
        result = subprocess.run(['make','--no-print-directory','s3-clean','S3_DATASETS=1','DRY_RUN=1','PROJECT='+path],cwd=source,
                                capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.splitlines(),[path,'clean-s3','--include-datasets','--dry-run'])
        self.assertFalse((source/'SENTINEL').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
