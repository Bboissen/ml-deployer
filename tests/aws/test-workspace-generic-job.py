"""Ordinary explicit commands, failure stages, bounded logs and output paths."""
import importlib.util
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import time
import unittest
import types
from unittest.mock import patch

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]; os.chdir(ROOT)
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts/aws'/name)
    value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
G=module('workspace-generic-job.py'); W=module('workspace.py'); E=module('workspace-e2e.py')

class Jobs(unittest.TestCase):
    def test_real_sdk_transfer_can_close_its_stream_without_losing_mutation_checks(self):
        import boto3
        from botocore.stub import Stubber
        path=self.root/'sdk-output'; path.write_bytes(b'actual transfer contract')
        s3=boto3.client('s3',region_name='us-east-1',
                        aws_access_key_id='offline-test',aws_secret_access_key='offline-test')
        with Stubber(s3) as stub:
            stub.add_response('put_object',{'VersionId':'version'})
            stub.add_response('head_object',{'VersionId':'version','ContentLength':path.stat().st_size})
            record=G.persist(s3,'111111111111','offline-data','outputs/result',path)
        self.assertEqual(record['sha256'],hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(record['version_id'],'version')

    def test_sdk_stream_closure_still_rejects_modified_or_replaced_output(self):
        for replace in (False,True):
            with self.subTest(replace=replace):
                path=self.root/('mutated-output-'+str(replace)); path.write_bytes(b'original')
                def upload(stream,*args,**kwargs):
                    stream.read(); stream.close()
                    if replace:
                        replacement=path.with_suffix('.replacement'); replacement.write_bytes(b'original')
                        replacement.replace(path)
                    else: path.write_bytes(b'modified')
                s3=types.SimpleNamespace(upload_fileobj=upload,head_object=lambda **_:self.fail('accepted changed output'))
                with self.assertRaisesRegex(ValueError,'output changed during upload'):
                    G.persist(s3,'111111111111','offline-data','outputs/result',path)

    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(dir=ROOT/'evidence'); self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name); self.project=self.root/'project'; self.project.mkdir()
    def execute(self,argv,seconds=5):
        with (self.root/('log-'+str(time.monotonic_ns()))).open('wb') as log:
            return G.execute(argv,{'PATH':os.environ['PATH'],'PYTHONDONTWRITEBYTECODE':'1'},log,time.monotonic()+seconds,self.project)
    def test_two_ordinary_projects_with_different_entrypoints(self):
        (self.project/'Makefile').write_text('setup:\n\tmkdir -p results\ntrain:\n\tprintf ordinary > results/result.txt\n')
        self.assertEqual(self.execute(['make','setup']),0); self.assertEqual(self.execute(['make','train']),0)
        self.assertEqual(G.output_files(self.project,['results'],100)[0][0],'results/result.txt')
        (self.project/'entrypoint.py').write_text('from pathlib import Path\nPath("artifact").write_text("second")\n')
        self.assertEqual(self.execute([sys.executable,'entrypoint.py']),0)
        self.assertEqual(G.output_files(self.project,['artifact'],100)[0][0],'artifact')
    def test_setup_and_job_failure_and_timeout_are_distinct_codes(self):
        self.assertEqual(self.execute([sys.executable,'-c','raise SystemExit(7)']),7)
        self.assertEqual(self.execute([sys.executable,'-c','raise SystemExit(9)']),9)
        with self.assertRaises(subprocess.TimeoutExpired): self.execute([sys.executable,'-c','import time;time.sleep(20)'],0.05)
    @unittest.skipUnless(hasattr(os,'fork'),'process groups require POSIX')
    def test_success_and_timeout_kill_children_after_leader_exits(self):
        for close_output in (True,False):
            pidfile=self.root/('child-'+str(close_output))
            child=None
            source='''import os,signal,sys,time
pid=os.fork()
if pid==0:
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    open(sys.argv[1],'w').write(str(os.getpid()))
    if sys.argv[2]=='True':
        os.close(1); os.close(2)
    time.sleep(30)
else:
    while not os.path.exists(sys.argv[1]): time.sleep(.001)
'''
            try:
                argv=[sys.executable,'-c',source,str(pidfile),str(close_output)]
                if close_output: self.assertEqual(self.execute(argv),0)
                else:
                    with self.assertRaises(subprocess.TimeoutExpired): self.execute(argv,0.2)
                child=int(pidfile.read_text())
                # A terminated orphan may remain a zombie briefly until its
                # host reaper collects it; it can no longer execute or write.
                deadline=time.monotonic()+3
                while time.monotonic()<deadline:
                    state=Path('/proc')/str(child)/'stat'
                    if not state.exists() or state.read_text().split()[2]=='Z': break
                    time.sleep(.01)
                else: self.fail('owned descendant survived command cleanup')
            finally:
                if pidfile.exists():
                    try: os.kill(int(pidfile.read_text()),signal.SIGKILL)
                    except ProcessLookupError: pass
    def test_large_log_is_truncated_while_process_completes(self):
        self.assertEqual(self.execute([sys.executable,'-c','import sys;sys.stdout.write("x"*9000000)']),0)
        self.assertEqual(next(self.root.glob('log-*')).stat().st_size,G.LOG_BYTES)
    def test_traversal_symlinks_missing_and_over_limit_outputs_rejected(self):
        (self.project/'result').write_bytes(b'1234'); (self.project/'link').symlink_to('/etc/passwd')
        for paths,limit in [(['../escape'],100),(['missing'],100),(['link'],100),(['result'],3)]:
            with self.assertRaises(ValueError): G.output_files(self.project,paths,limit)
    def guest(self,setup_exit=0,job_exit=0,copy_failure=False,mode='job',setup=None,dataset=None,tamper=None,checkout=None,readable=False):
        objects={}; job={'repository':{'url':'https://github.com/owner/project.git','revision':'a'*40},
            'workspace_id':'demand-dev','account_id':'111111111111','region':'us-east-1','run_id':os.urandom(16).hex(),
            'commands':{'setup':setup or [sys.executable,'-c',f'raise SystemExit({setup_exit})'],
                        'run':[sys.executable,'-c',f'from pathlib import Path;Path("results").write_text("new");raise SystemExit({job_exit})']},
            'outputs':{'paths':['results'],'maximum_bytes':100},'dataset_manifest':None,'timeout_seconds':30,'output_uri':'','mode':mode}
        job['output_uri']='s3://data/projects/demand/workspaces/demand-dev/output/'+job['run_id']+'/'
        # Versioned objects as the controller's ingestion leaves them.
        prefix='projects/demand/data/snapshots/'+'d'*64+'/'; versions={}; records=[]
        if readable:
            job['output_uri']='s3://data/results/demand-dev/2026-10-17T14-03-12Z-'+job['run_id']+'/'
            prefix='datasets/training.csv/2026-10-17T14-03-12Z-'+'e'*32+'/'
        for number,(path,data) in enumerate(dataset or [('train.csv',b'value\n1\n2\n'),('nested/deeper/labels.csv',b'label\n0\n')]):
            key=prefix+'objects/'+'e'*32+'/'+path; versions[key,'v'+str(number)]=data
            records.append({'path':path,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'key':key,'version_id':'v'+str(number)})
        manifest={'schema_version':'1.0.0','kind':'dataset-manifest','bucket':'data','content_sha256':'d'*64,
                  'total_bytes':sum(r['bytes'] for r in records),'objects':records}
        if tamper: tamper(manifest,versions)
        raw=(json.dumps(manifest,sort_keys=True,separators=(',',':'))+'\n').encode(); versions[prefix+'manifests/ingestion.json','manifest-version']=raw
        job['dataset_manifest']={'bucket':'data','manifest_key':prefix+'manifests/ingestion.json','manifest_version_id':'manifest-version',
                                 'manifest_sha256':hashlib.sha256(raw).hexdigest()}
        if tamper: tamper(job['dataset_manifest'],versions)
        def get(**kw):
            self.assertEqual((kw['Bucket'],kw['ExpectedBucketOwner']),('data',job['account_id']))
            data,version=next(((v,k[1]) for k,v in versions.items() if k[0]==kw['Key'] and k[1].startswith(kw['VersionId'])),(None,None))
            if data is None: raise RuntimeError('NoSuchVersion')
            return {'VersionId':version,'ContentLength':len(data),'Body':io.BytesIO(data)}
        def upload(path,bucket,key,**kw):
            if copy_failure and '/files/' in key: raise RuntimeError('copy failed')
            objects[key]=path.read()
        s3=types.SimpleNamespace(upload_fileobj=upload,get_object=get,head_object=lambda **kw:{'VersionId':'version','ContentLength':len(objects[kw['Key']])},
            put_object=lambda **kw: objects.update({kw['Key']:kw['Body']}) or {'VersionId':'version'})
        sts=types.SimpleNamespace(get_caller_identity=lambda:{'Account':job['account_id'],'Arn':'arn:aws:sts::111111111111:assumed-role/run/i-instance'})
        session=types.SimpleNamespace(get_credentials=lambda:types.SimpleNamespace(method='iam-role'),client=lambda service,**kw:s3 if service=='s3' else sts)
        fake={'boto3':types.SimpleNamespace(Session=lambda **kw:session),
            'botocore.config':types.SimpleNamespace(Config=lambda **kw:kw),'boto3.s3.transfer':types.SimpleNamespace(TransferConfig=lambda **kw:kw)}
        original=G.execute; read_text=Path.read_text
        def clone(argv,env,log,deadline,directory=None):
            if argv[0]=='bash':
                Path(argv[-1]).mkdir()
                if checkout: checkout(Path(argv[-1]))
                return 0
            return original(argv,env,log,deadline,directory)
        def read(path,*args,**kw):
            if str(path)=='/var/lib/workspace/bootstrap-success.json': return json.dumps({'workspace_id':job['workspace_id'],'toolbox_sha256':'c'*64})
            return read_text(path,*args,**kw)
        with patch.dict(sys.modules,fake),patch.object(G.os,'geteuid',return_value=1000),patch.object(G.pwd,'getpwuid',return_value=types.SimpleNamespace(pw_name='workspace')),patch.object(G,'execute',side_effect=clone),patch.object(G.subprocess,'check_output',return_value=b'a'*40+b'\n'),patch.object(Path,'read_text',read):
            code=G.run(job,self.root/'workspaces')
        receipt=json.loads(next(v for k,v in objects.items() if k.endswith('/execution.json')))
        return code,receipt
    def test_readable_storage_stages_inputs_and_persists_results_with_exact_versions(self):
        code,receipt=self.guest(readable=True)
        self.assertEqual(code,0)
        self.assertTrue(receipt['dataset_staged']); self.assertTrue(receipt['outputs_persisted'])
        self.assertTrue(receipt['dataset_manifest']['manifest_key'].startswith('datasets/training.csv/'))
        self.assertTrue(receipt['output_objects'][0]['key'].startswith('results/demand-dev/2026-10-17T14-03-12Z-'))
    def test_guest_outcomes_setup_job_and_output_copy_are_independent(self):
        code,receipt=self.guest(setup_exit=7)
        self.assertEqual(code,1); self.assertEqual(receipt['setup_exit'],7); self.assertIsNone(receipt['job_exit'])
        code,receipt=self.guest(job_exit=9)
        self.assertEqual(code,1); self.assertEqual(receipt['setup_exit'],0); self.assertEqual(receipt['job_exit'],9); self.assertTrue(receipt['outputs_persisted'])
        code,receipt=self.guest(copy_failure=True)
        self.assertEqual(code,1); self.assertEqual(receipt['job_exit'],0); self.assertFalse(receipt['outputs_persisted'])
    def test_workspace_runs_setup_only_and_remains_available(self):
        code,receipt=self.guest(mode='workspace')
        self.assertEqual(code,0); self.assertEqual(receipt['setup_exit'],0); self.assertIsNone(receipt['job_exit'])
    def test_dataset_staged_read_only_outside_checkout_before_setup(self):
        check='''import os,stat,sys
from pathlib import Path
data=Path(os.environ["DATA_DIR"]); output=Path(os.environ["OUTPUT_DIR"])
assert data.is_absolute() and data.name=="data" and data.parent==Path.cwd().parent and output==Path.cwd()/"outputs"
assert (data/"train.csv").read_bytes()==b"value\\n1\\n2\\n" and (data/"nested/deeper/labels.csv").read_bytes()==b"label\\n0\\n"
assert all(stat.S_IMODE(p.stat().st_mode)==(0o555 if p.is_dir() else 0o444) for p in [data,*data.rglob("*")])
assert list(output.iterdir())==[] and stat.S_IMODE(output.stat().st_mode)==0o700
for attempt in (lambda:(data/"train.csv").open("ab"),lambda:(data/"new").write_bytes(b"x"),lambda:(data/"nested/new").write_bytes(b"x")):
    try: attempt(); sys.exit(3)
    except PermissionError: pass
'''
        if os.geteuid()==0: self.skipTest('root bypasses read-only modes')
        (self.root/'check.py').write_text(check)
        code,receipt=self.guest(setup=[sys.executable,str(self.root/'check.py')])
        self.assertEqual((code,receipt['setup_exit'],receipt['job_exit']),(0,0,0))
        self.assertEqual((receipt['dataset_staged'],receipt['dataset_staged_bytes']),(True,18))
        self.assertNotIn('execution_error',receipt)
    def test_dataset_rejections_skip_setup(self):
        def objects(change):
            return lambda manifest,versions: 'objects' in manifest and change(manifest,versions)
        def first(field,value): return objects(lambda m,v: m['objects'][0].update({field:value}))
        cases={
            'object hash mismatch':first('sha256','0'*64),
            'manifest hash mismatch':lambda m,v: 'manifest_sha256' in m and m.update(manifest_sha256='0'*64),
            'wrong object version':objects(lambda m,v: v.update({(m['objects'][0]['key'],'v0-other'):v.pop((m['objects'][0]['key'],'v0'))})),
            'wrong manifest version':lambda m,v: 'manifest_sha256' in m and v.update({(m['manifest_key'],'manifest-version-other'):v.pop((m['manifest_key'],'manifest-version'))}),
            'traversal path':first('path','../escape.csv'),
            'absolute path':first('path','/etc/escape.csv'),
            'key outside data prefix':first('key','projects/other/data/x'),
            'other bucket':objects(lambda m,v: m.update(bucket='other')),
            'wrong kind':objects(lambda m,v: m.update(kind='other')),
            'oversize object':objects(lambda m,v: v.update({(m['objects'][0]['key'],'v0'):v[m['objects'][0]['key'],'v0']+b'x'})),
            'understated total':objects(lambda m,v: m.update(total_bytes=1)),
            'duplicate path':objects(lambda m,v: m['objects'].append(dict(m['objects'][0]))),
        }
        for name,tamper in cases.items():
            with self.subTest(name):
                code,receipt=self.guest(tamper=tamper)
                self.assertEqual((code,receipt['execution_error'],receipt['setup_exit'],receipt['dataset_staged']),
                                 (1,{'stage':'data','type':receipt['execution_error']['type']},None,False))
        with patch.object(G,'DATA_OBJECTS',1):
            self.assertEqual(self.guest()[1]['execution_error']['stage'],'data')
        with patch.object(G.shutil,'disk_usage',return_value=types.SimpleNamespace(free=18)):
            self.assertEqual(self.guest()[1]['execution_error']['stage'],'data')
    def test_staging_counts_against_the_job_deadline(self):
        s3=types.SimpleNamespace(get_object=lambda **kw:{'VersionId':'v','ContentLength':1,'Body':io.BytesIO(b'x')})
        with self.assertRaisesRegex(ValueError,'time bound'): G.fetch(s3,'111111111111','data','key','v',time.monotonic()-1,io.BytesIO(),1)
    def test_committed_outputs_directory_is_reused(self):
        code,receipt=self.guest(checkout=lambda project:(project/'outputs').mkdir())
        self.assertEqual((receipt['setup_exit'],receipt['dataset_staged']),(0,True))
    def test_checkout_with_outputs_symlink_is_rejected_before_setup(self):
        code,receipt=self.guest(checkout=lambda project:(project/'outputs').symlink_to(project.parent))
        self.assertEqual((code,receipt['execution_error']['stage'],receipt['setup_exit'],receipt['dataset_staged']),(1,'data',None,False))
    def test_output_metadata_limit_preserves_failure_receipt(self):
        with patch.object(G.files,'EXECUTION_RECEIPT_BYTES',17000):
            code,receipt=self.guest()
        self.assertEqual(code,1)
        self.assertFalse(receipt['outputs_persisted'])
        self.assertEqual(receipt['output_error'],'ValueError')
        self.assertEqual(receipt['output_objects'],[])
    def test_controller_verifies_directory_receipt_larger_than_one_mib(self):
        account='111111111111'; workspace='demand-dev'; run_id='a'*32
        prefix='projects/demand/workspaces/'+workspace+'/output/'+run_id+'/'
        job={'run_id':run_id,'commands':{'setup':['true'],'run':['true']},'dataset_manifest':{},
             'outputs':{'paths':['results'],'maximum_bytes':100},'output_uri':'s3://data/'+prefix}
        value={'workspace_id':workspace,'repository':{'revision':'b'*40}}
        target={'account_id':account,'inventory':{'buckets':['data']}}
        config={'aws_account_id':account,'aws_region':'us-east-1','resource_prefix':'demand',
                'workspace_identity':{'ml_project_name':'demand','request':{'workspace_id':workspace}},
                'toolbox_zip_sha256':'c'*64,'lease':{'starts_at':'2026-01-01T00:00:00Z'}}
        receipt={'run_id':run_id,'repository_commit':value['repository']['revision'],'user':'workspace',
                 'instance_role_arn':'arn:aws:sts::'+account+':assumed-role/'+W.L['role_name'](config)+'/i-owned',
                 'commands':job['commands'],'dataset_manifest':{},'bootstrap':{'workspace_id':workspace,'toolbox_sha256':'c'*64},
                 'infrastructure_ready':True,'outputs_persisted':True,'setup_exit':0,'job_exit':0,
                 'credential_removed_before_setup':True,'dataset_staged':True,'dataset_staged_bytes':0,'output_objects':[]}
        for number in range(6000):
            path='results/file-'+str(number)
            receipt['output_objects'].append({'path':path,'key':prefix+'files/'+path,'version_id':'version',
                                             'bytes':0,'sha256':hashlib.sha256(b'').hexdigest()})
        raw=G.receipt_bytes(receipt); self.assertGreater(len(raw),1024*1024)
        def get(**kw):
            data=raw if kw['Key'].endswith('/execution.json') else b''
            return {'ContentLength':len(data),'VersionId':'version','Body':io.BytesIO(data),
                    'LastModified':dt.datetime(2026,1,1,tzinfo=dt.timezone.utc)}
        verified=E.verify_generic_result(W.L,value,target,job,config,'i-owned',types.SimpleNamespace(get_object=get),self.root/'verified')
        self.assertEqual(verified['execution'],receipt)
    def test_fresh_run_cannot_pass_using_another_project_output(self):
        (self.project/'result').write_bytes(b'old'); fresh=self.root/'fresh'; fresh.mkdir()
        with self.assertRaisesRegex(ValueError,'missing'): G.output_files(fresh,['result'],100)

if __name__=='__main__': unittest.main(verbosity=2)
