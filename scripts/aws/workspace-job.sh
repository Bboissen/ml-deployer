#!/usr/bin/env bash
# The SSM document drops privileges and clears the environment before this entrypoint.
set -euo pipefail
exec /opt/workspace/sdk/bin/python - "$@" <<'PY'
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import signal
import subprocess
import sys
import time


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(job):
    require(os.geteuid() > 0 and pwd.getpwuid(os.geteuid()).pw_name == 'workspace', 'run as workspace')
    require(set(job) == {'repository', 'workspace_id', 'account_id', 'region', 'run_id', 'make_target',
                         'timeout_seconds', 'data_uri', 'data_version_id', 'data_sha256', 'output_uri'}, 'closed job settings required')
    require(re.fullmatch(r'[a-z0-9-]{3,48}', job['workspace_id']) and re.fullmatch(r'[0-9a-f]{32}', job['run_id']), 'invalid workspace/run ID')
    require(job['make_target'] is None or re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,63}', job['make_target']), 'invalid Make target')
    require(type(job['timeout_seconds']) is int and 30 <= job['timeout_seconds'] <= 171000, 'invalid execution timeout')
    require(job['output_uri'].endswith('/output/' + job['run_id'] + '/'), 'unique output prefix required')
    require(not any(os.environ.get(k) for k in ('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_PROFILE')), 'native role credentials required')


def execute(arguments, environment, log, timeout, directory=None):
    process = subprocess.Popen(arguments, cwd=directory, env=environment, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)


def run(job):
    validate(job)
    bootstrap = json.loads(Path('/var/lib/workspace/bootstrap-success.json').read_text())
    require(bootstrap['workspace_id'] == job['workspace_id'], 'bootstrap workspace mismatch')
    import boto3
    from botocore.config import Config
    session = boto3.Session(region_name=job['region'])
    require(session.get_credentials().method == 'iam-role', 'native instance role required')
    settings = Config(connect_timeout=3, read_timeout=5, retries={'total_max_attempts': 2})
    identity = session.client('sts', config=settings).get_caller_identity()
    require(identity['Account'] == job['account_id'] and ':assumed-role/' in identity['Arn'], 'instance identity mismatch')
    directory = Path('/workspaces') / job['workspace_id'] / job['run_id']
    directory.mkdir(mode=0o700)
    project = directory / 'project'
    environment = {'HOME': '/home/workspace', 'PATH': '/opt/workspace/sdk/bin:/usr/local/bin:/usr/bin:/bin',
                   'AWS_REGION': job['region'], 'AWS_DEFAULT_REGION': job['region'],
                   'DATA_URI': job['data_uri'], 'DATA_VERSION_ID': job['data_version_id'],
                   'DATA_SHA256': job['data_sha256'], 'OUTPUT_URI': job['output_uri'], 'RUN_ID': job['run_id'],
                   'PYTHONDONTWRITEBYTECODE': '1', 'GIT_TERMINAL_PROMPT': '0'}
    credential = job['repository']['credential']
    clone = ['bash', '/opt/workspace/scripts/aws/workspace-ssh.sh', job['repository']['url'],
             job['repository']['revision'], str(project), credential['secret_arn'], credential['version_id'],
             credential['public_key_fingerprint'], job['region'], job['account_id']]
    deadline = time.monotonic() + job['timeout_seconds']
    receipt = {'run_id': job['run_id'], 'repository_commit': job['repository']['revision'],
               'user': 'workspace', 'instance_role_arn': identity['Arn'], 'make_argv': ['make'],
               'bootstrap': bootstrap,
               'stage': 'clone', 'exit_code': 2, 'credential_removed_before_make': False}
    if job['make_target']:
        receipt['make_argv'].append(job['make_target'])
    log_path = directory / 'job.log'
    with log_path.open('xb') as log:
        try:
            require(execute(clone, environment, log, min(300, job['timeout_seconds'])) == 0, 'SSH clone failed')
            require(subprocess.check_output(['git', '-C', str(project), 'rev-parse', 'HEAD'], env=environment,
                                            timeout=10).decode().strip() == job['repository']['revision'], 'commit mismatch')
            receipt.update(stage='make', credential_removed_before_make=True)
            receipt['exit_code'] = execute(receipt['make_argv'], environment, log,
                                           max(0.01, deadline - time.monotonic()), str(project))
        except subprocess.TimeoutExpired:
            receipt.update(exit_code=124, error='TimeoutExpired')
        except Exception as error:
            receipt.update(exit_code=2, error=type(error).__name__)
    require(log_path.stat().st_size <= 8 * 1024 * 1024, 'job log exceeds upload bound')
    bucket, prefix = job['output_uri'].removeprefix('s3://').split('/', 1)
    s3 = session.client('s3', config=settings)
    with log_path.open('rb') as log:
        response = s3.put_object(Bucket=bucket, Key=prefix+'job.log', Body=log, ContentType='text/plain')
    require(response.get('VersionId') not in (None, '', 'null'), 'versioned log upload required')
    receipt['log_version_id'] = response['VersionId']
    response = s3.put_object(Bucket=bucket, Key=prefix+'execution.json',
                            Body=(json.dumps(receipt, sort_keys=True)+'\n').encode(), ContentType='application/json')
    require(response.get('VersionId') not in (None, '', 'null'), 'versioned execution receipt required')
    print(json.dumps(receipt, sort_keys=True))
    return receipt['exit_code']


if __name__ == '__main__':
    os.umask(0o077)
    def interrupted(_signal, _frame):
        raise TimeoutError('job interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        require(len(sys.argv) == 2 and len(sys.argv[1]) <= 16384, 'one bounded encoded job is required')
        job = json.loads(base64.b64decode(sys.argv[1], validate=True))
        sys.exit(run(job))
    except Exception:
        print('workspace-job: FAIL; see bounded execution/log evidence', file=sys.stderr)
        sys.exit(2)
PY
