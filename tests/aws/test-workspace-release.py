"""Real archive/install/configure round trip with mocked downloads and tooling."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]; os.chdir(ROOT)
BASE=ROOT/'evidence/aws/tests/release'; BASE.mkdir(parents=True,exist_ok=True)
def module(path):
    spec=importlib.util.spec_from_file_location(path.name,path)
    value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
P=module(ROOT/'scripts/aws/package-release.py'); R=module(ROOT/'scripts/aws/workspace_release.py')


class Release(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=BASE); self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name); self.repo=self.directory/'source'; self.repo.mkdir()
        names=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=ROOT).decode().split('\0')[:-1]
        names+=['scripts/aws/package-release.py','scripts/aws/install-release.sh','scripts/aws/workspace_release.py','shared/workspace/release.json']
        for name in set(names):
            source=ROOT/name
            if not source.is_file(): continue
            target=self.repo/name; target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(source,target)
        # Tool installation is tested by the workstation suite. This fixture
        # isolates the release transport, extraction, activation and controller.
        (self.repo/'scripts/aws/workstation-setup.sh').write_text('#!/bin/bash\nexit "${MOCK_SETUP_FAILURE:-0}"\n')
        self.git('init','--template='); self.git('add','--',*sorted(set(names)))
        self.git('-c','user.name=Offline release test','-c','user.email=offline@example.invalid',
                 '-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','commit','-m','isolated release fixture')
        self.result=P.package(self.repo,self.directory/'artifacts'); self.archive=Path(self.result['archive'])
        self.prefix=self.directory/'installed'; self.shims=self.directory/'shims'; self.shims.mkdir()
        curl=self.shims/'curl'; curl.write_text('#!'+sys.executable+'\nimport pathlib,shutil,sys\na=sys.argv[1:]\nshutil.copyfile(pathlib.Path('+repr(str(self.archive.parent))+')/a[-1].rsplit("/",1)[-1],a[a.index("-o")+1])\n'); curl.chmod(0o755)
        self.env={**os.environ,'PATH':str(self.shims)+':'+os.environ['PATH'],'WORKSPACE_PYTHON':sys.executable}
    def git(self,*args): return subprocess.check_output(['git','-C',str(self.repo),*args],stderr=subprocess.STDOUT,timeout=30)
    def install(self,**env):
        return subprocess.run(['bash',str(ROOT/'scripts/aws/install-release.sh'),'--prefix',str(self.prefix)],
                              cwd=self.directory,env={**self.env,**env},capture_output=True,text=True,timeout=30)
    def test_reproducible_committed_archive_contains_no_operational_material(self):
        second=P.package(self.repo,self.directory/'second')
        self.assertEqual(self.result['sha256'],second['sha256'])
        with tarfile.open(self.archive) as tar:
            self.assertTrue(all(i.isfile() for i in tar))
            names=tar.getnames(); self.assertFalse(any('/.git/' in n or '/.tools/' in n or '/evidence/aws/' in n for n in names))
        (self.repo/'README.md').write_text('dirty source')
        with self.assertRaisesRegex((ValueError,AssertionError),'clean committed'): P.package(self.repo,self.directory/'dirty')
    def test_archive_uses_committed_blobs_during_checkout_changes(self):
        original=P.git; committed=original(self.repo,'show','HEAD:README.md')
        def raced(root,*arguments):
            if arguments[0]=='archive': (self.repo/'README.md').write_text('concurrent uncommitted change')
            return original(root,*arguments)
        with patch.object(P,'git',side_effect=raced): result=P.package(self.repo,self.directory/'raced')
        with tarfile.open(result['archive']) as tar:
            self.assertEqual(tar.extractfile('aws-workspace-'+result['version']+'/README.md').read(),committed)
    def test_install_from_other_directory_configure_status_without_git_metadata(self):
        result=self.install(); self.assertEqual(result.returncode,0,result.stderr)
        release=self.prefix/'releases'/self.result['version']; self.assertFalse((release/'.git').exists())
        self.assertEqual(R.provenance(release)['source']['working_tree_sha256'],hashlib.sha256(b'').hexdigest())
        project=json.loads((ROOT/'infra/aws/project.example.json').read_text()); project['dataset']['source']='input with spaces'
        project['repository']={'url':'https://github.com/owner/project.git','ref':'a'*40}
        config=self.directory/'project.json'; config.write_text(json.dumps(project)); (self.directory/'input with spaces').write_bytes(b'bounded data')
        observed={'schema_version':'1.0.0','kind':'aws-project-discovery','profile':project['profile'],'region':project['region'],
                  'identity':{'Account':'111111111111','Arn':'arn:aws:iam::111111111111:user/operator'},
                  'repository':{**project['repository'],'revision':'a'*40,'resolved_ref':'a'*40,'verification':'pin-only'}}
        discovery=self.directory/'discovery.json'; discovery.write_text(json.dumps(observed))
        cli=self.prefix/'bin/aws-workspace'
        prepared=subprocess.run([str(cli),'project.json','configure','--discovery',str(discovery)],cwd=self.directory,
                                env=self.env,capture_output=True,text=True,timeout=30)
        self.assertEqual(prepared.returncode,0,prepared.stderr); operation=json.loads(prepared.stdout)
        status=subprocess.run([str(cli),'project.json','status',str(release/operation['operation_directory'])],cwd=self.directory,
                              env=self.env,capture_output=True,text=True,timeout=30)
        self.assertEqual(status.returncode,0,status.stderr)
        self.assertFalse(json.loads(status.stdout)['cloud_mutations'])
        self.assertFalse((self.prefix/'install.lock').exists())
    def test_reinstall_preserves_real_evidence_and_rejects_tampered_source(self):
        self.assertEqual(self.install().returncode,0)
        release=self.prefix/'releases'/self.result['version']; evidence=release/'evidence/aws/retained.json'
        evidence.parent.mkdir(parents=True,exist_ok=True); evidence.write_text('preserve real state receipt')
        self.assertEqual(self.install().returncode,0); self.assertEqual(evidence.read_text(),'preserve real state receipt')
        (release/'scripts/aws/workspace.py').write_text('tampered source')
        self.assertNotEqual(R.provenance(release)['source']['working_tree_sha256'],hashlib.sha256(b'').hexdigest())
        result=self.install()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('installed release source changed',result.stderr)
        self.assertEqual(evidence.read_text(),'preserve real state receipt')
    def test_reinstall_rejects_symlinked_source_before_executing_setup(self):
        self.assertEqual(self.install().returncode,0)
        release=self.prefix/'releases'/self.result['version']
        setup=release/'scripts/aws/workstation-setup.sh'
        outside=self.directory/'replacement-setup.sh'
        marker=self.directory/'executed'
        outside.write_text('#!/bin/sh\ntouch '+shlex.quote(str(marker))+'\n')
        setup.unlink(); setup.symlink_to(outside)
        result=self.install()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('cannot be symlinked',result.stderr)
        self.assertFalse(marker.exists())
    def test_corrupt_archive_and_failed_setup_leave_no_runtime_or_activation(self):
        good=self.archive.read_bytes(); self.archive.write_bytes(b'corrupted')
        result=self.install(); self.assertNotEqual(result.returncode,0); self.assertIn('checksum mismatch',result.stderr)
        self.assertFalse((self.prefix/'bin/aws-workspace').exists()); self.assertFalse((self.prefix/'install.lock').exists())
        self.archive.write_bytes(good)
        result=self.install(MOCK_SETUP_FAILURE='9'); self.assertEqual(result.returncode,9)
        self.assertFalse((self.prefix/'releases'/self.result['version']).exists()); self.assertFalse((self.prefix/'install.lock').exists())
    def test_foreign_prefix_is_preserved(self):
        self.prefix.mkdir(); (self.prefix/'valuable').write_text('keep')
        self.assertNotEqual(self.install().returncode,0); self.assertEqual((self.prefix/'valuable').read_text(),'keep')


if __name__=='__main__': unittest.main(verbosity=2)
