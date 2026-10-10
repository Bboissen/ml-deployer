"""Run isolated offline checks and remove their exact disposable evidence."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
# This worktree's offline tests exclusively own new entries in these namespaces.
SCOPES = [ROOT/'evidence/aws/tests', ROOT/'evidence/aws/operations', ROOT/'evidence/workspace']
commands = sys.argv[1:] or ['tests/aws/test-workstation-setup.py','tests/aws/test-workspace-config.py',
    'tests/aws/test-workspace-onboarding.py','tests/aws/test-workspace-ingest.py','tests/aws/test-workspace-generic-job.py',
    'tests/aws/test-workspace-deploy.py','tests/aws/test-workspace-release.py','tests/aws/test-workspace-e2e.sh',
    'tests/aws/test-workspace-lifecycle.sh']
for name in commands:
    before = {path for scope in SCOPES if scope.exists() for path in scope.rglob('*')}
    free = shutil.disk_usage(ROOT).free
    if free < 2*1024**3: raise RuntimeError('offline checks require 2 GiB free space')
    deleted = []; code = 2; log = ''; started = time.monotonic()
    try:
        command = [sys.executable,'-B',name] if name.endswith('.py') else ['bash',name]
        process = subprocess.Popen(command, env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1','WORKSPACE_PYTHON':sys.executable},
                                   stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        try:
            log,_=process.communicate(timeout=600); code=process.returncode
        finally:
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            tail,_=process.communicate(timeout=15)
            if not log: log=tail or ''
        print(log[-8000:] if code else log[-1000:], flush=True)
    finally:
        created = {path for scope in SCOPES if scope.exists() for path in scope.rglob('*')} - before
        if code:
            for item in sorted(created):
                if item.is_file() and item.name.endswith('-test.log'):
                    diagnostics = item.read_text()[-8000:]
                    print(diagnostics, flush=True)
                    log += '\n'+diagnostics
        roots = sorted((p for p in created if p.parent not in created), key=str)
        for path in roots:
            deleted.append(str(path))
            if path.is_dir() and not path.is_symlink(): shutil.rmtree(path)
            else: path.unlink()
        assert all(not p.exists() and not p.is_symlink() for p in roots)
        receipt = ROOT/'evidence/aws/test-receipts'/ (uuid.uuid4().hex+'.json')
        receipt.parent.mkdir(parents=True, exist_ok=True)
        if 'log' in locals(): receipt.with_suffix('.log').write_text(log[-65536:])
        receipt.write_text(json.dumps({'test':name,'exit_code':code,'elapsed_seconds':round(time.monotonic()-started,2),
            'deleted_paths':deleted,'cleanup_verified':True,'free_before':free,'free_after':shutil.disk_usage(ROOT).free,
            'cloud_mutations':False},indent=2)+'\n')
        print('cleanup verified; receipt='+str(receipt), flush=True)
    if code: sys.exit(code)
