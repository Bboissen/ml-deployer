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
    def guest(self,setup_exit=0,job_exit=0,copy_failure=False,mode='job'):
        objects={}; job={'repository':{'url':'https://github.com/owner/project.git','revision':'a'*40},
            'workspace_id':'demand-dev','account_id':'111111111111','region':'us-east-1','run_id':os.urandom(16).hex(),
            'commands':{'setup':[sys.executable,'-c',f'raise SystemExit({setup_exit})'],
                        'run':[sys.executable,'-c',f'from pathlib import Path;Path("results").write_text("new");raise SystemExit({job_exit})']},
            'outputs':{'paths':['results'],'maximum_bytes':100},'dataset_manifest':{'bucket':'data','manifest_key':'manifest',
                 'manifest_version_id':'data-version','manifest_sha256':'b'*64},'timeout_seconds':30,'output_uri':'','mode':mode}
        job['output_uri']='s3://data/projects/demand/workspaces/demand-dev/output/'+job['run_id']+'/'
        def upload(path,bucket,key,**kw):
            if copy_failure and '/files/' in key: raise RuntimeError('copy failed')
            objects[key]=path.read()
        s3=types.SimpleNamespace(upload_fileobj=upload,head_object=lambda **kw:{'VersionId':'version','ContentLength':len(objects[kw['Key']])},
            put_object=lambda **kw: objects.update({kw['Key']:kw['Body']}) or {'VersionId':'version'})
        sts=types.SimpleNamespace(get_caller_identity=lambda:{'Account':job['account_id'],'Arn':'arn:aws:sts::111111111111:assumed-role/run/i-instance'})
        session=types.SimpleNamespace(get_credentials=lambda:types.SimpleNamespace(method='iam-role'),client=lambda service,**kw:s3 if service=='s3' else sts)
        fake={'boto3':types.SimpleNamespace(Session=lambda **kw:session),
            'botocore.config':types.SimpleNamespace(Config=lambda **kw:kw),'boto3.s3.transfer':types.SimpleNamespace(TransferConfig=lambda **kw:kw)}
        original=G.execute; read_text=Path.read_text
        def clone(argv,env,log,deadline,directory=None):
            if argv[0]=='bash': Path(argv[-1]).mkdir(); return 0
            return original(argv,env,log,deadline,directory)
        def read(path,*args,**kw):
            if str(path)=='/var/lib/workspace/bootstrap-success.json': return json.dumps({'workspace_id':job['workspace_id'],'toolbox_sha256':'c'*64})
            return read_text(path,*args,**kw)
        with patch.dict(sys.modules,fake),patch.object(G.os,'geteuid',return_value=1000),patch.object(G.pwd,'getpwuid',return_value=types.SimpleNamespace(pw_name='workspace')),patch.object(G,'execute',side_effect=clone),patch.object(G.subprocess,'check_output',return_value=b'a'*40+b'\n'),patch.object(Path,'read_text',read):
            code=G.run(job,self.root/'workspaces')
        receipt=json.loads(next(v for k,v in objects.items() if k.endswith('/execution.json')))
        return code,receipt
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
                 'credential_removed_before_setup':True,'output_objects':[]}
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
