"""Run each offline suite in an owned source snapshot; retain only small receipts."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TESTS = [
    'tests/aws/test-offline-runner.py',
    'tests/aws/test-workstation-setup.py',
    'tests/aws/test-workspace-config.py',
    'tests/aws/test-workspace-onboarding.py',
    'tests/aws/test-workspace-access-recovery.py',
    'tests/aws/test-workspace-ingest.py',
    'tests/aws/test-workspace-generic-job.py',
    'tests/aws/test-workspace-deploy.py',
    'tests/aws/test-workspace-release.py',
    'tests/aws/test-workspace-e2e.sh',
    'tests/aws/test-workspace-ssh.sh',
    'tests/aws/test-workspace-lifecycle.sh',
]


def source_snapshot(root, directory):
    """Keep Git provenance and current source without sharing writable evidence."""
    subprocess.run(['git', 'clone', '--shared', '--no-checkout', '--template=',
                    str(root), str(directory)], check=True, capture_output=True, timeout=30)
    subprocess.run(['git', 'read-tree', 'HEAD'], cwd=directory,
                   check=True, capture_output=True, timeout=30)
    names = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
        cwd=root, timeout=30).decode().split('\0')
    for name in set(names) - {''}:
        source = root/name
        if source.is_file():
            destination = directory/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def run_test(root, name, timeout=600):
    root = Path(root).resolve()
    test = Path(name)
    if test.is_absolute() or '..' in test.parts or not (root/test).is_file():
        raise ValueError('test must be a file inside the source tree')
    free = shutil.disk_usage(root).free
    if free < 2*1024**3:
        raise RuntimeError('offline checks require 2 GiB free space')
    scratch_parent = root/'evidence/aws/tests'
    scratch_parent.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix='offline-', dir=scratch_parent))
    snapshot = scratch/'source'
    log = ''; code = 2; process = None; started = time.monotonic()
    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        source_snapshot(root, snapshot)
        command = [sys.executable, '-B', name] if name.endswith('.py') else ['bash', name]
        # Downloads, native tool caches and conventional temporary files also
        # belong to this test; caller-owned runtimes and caches stay untouched.
        temporary = scratch/'tmp'; temporary.mkdir()
        cache = scratch/'cache'; cache.mkdir()
        environment = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1',
                       'WORKSPACE_PYTHON': sys.executable, 'TMPDIR': str(temporary),
                       'XDG_CACHE_HOME': str(cache), 'UV_CACHE_DIR': str(cache/'uv')}
        process = subprocess.Popen(command, cwd=snapshot, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        log, _ = process.communicate(timeout=timeout)
        code = process.returncode if process.returncode >= 0 else 128-process.returncode
    except subprocess.TimeoutExpired:
        code = 124
        log = 'offline preparation or test exceeded its bounded timeout\n'
    except SystemExit as exc:
        code = exc.code
        raise
    finally:
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        # A successful parent can still leave a test child running. This also
        # covers interruption immediately after Popen, before communicate.
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            tail, _ = process.communicate(timeout=15)
            if tail and tail not in log:
                log += tail
        print(log[-8000:] if code else log[-1000:], flush=True)
        # Deletion is tied to the exact mkdtemp path, never to a before/after
        # inventory of shared evidence that another process may be writing.
        if code:
            for item in snapshot.glob('evidence/**/*-test.log'):
                if item.is_file() and not item.is_symlink():
                    diagnostics = item.read_text(errors='replace')[-8000:]
                    print(diagnostics, flush=True)
                    log += '\n' + diagnostics
        shutil.rmtree(scratch)
        cleanup_verified = not scratch.exists() and not scratch.is_symlink()
        receipt = root/'evidence/aws/test-receipts'/(uuid.uuid4().hex + '.json')
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.with_suffix('.log').write_text(log[-65536:])
        receipt.write_text(json.dumps({
            'test': name, 'exit_code': code, 'elapsed_seconds': round(time.monotonic()-started, 2),
            'deleted_paths': [str(scratch)], 'cleanup_verified': cleanup_verified,
            'free_before': free, 'free_after': shutil.disk_usage(root).free,
            'cloud_mutations': False,
        }, indent=2) + '\n')
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        if not cleanup_verified:
            raise RuntimeError('test cleanup could not be verified: ' + str(scratch))
        print('cleanup verified; receipt=' + str(receipt), flush=True)
    return code


def main():
    for name in sys.argv[1:] or DEFAULT_TESTS:
        code = run_test(ROOT, name)
        if code:
            return code
    return 0


if __name__ == '__main__':
    sys.exit(main())
