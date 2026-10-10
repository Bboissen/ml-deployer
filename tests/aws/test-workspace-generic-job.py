"""Ordinary explicit commands, failure stages, bounded logs and output paths."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
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
G=module('workspace-generic-job.py'); W=module('workspace.py')

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
    def test_fresh_run_cannot_pass_using_another_project_output(self):
        (self.project/'result').write_bytes(b'old'); fresh=self.root/'fresh'; fresh.mkdir()
        with self.assertRaisesRegex(ValueError,'missing'): G.output_files(fresh,['result'],100)

if __name__=='__main__': unittest.main(verbosity=2)
