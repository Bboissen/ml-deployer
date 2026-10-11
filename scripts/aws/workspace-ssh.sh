#!/usr/bin/env bash
# Runtime-only credential retrieval; no secret values in argv, records or logs.
set -euo pipefail
exec "${WORKSPACE_PYTHON:-/opt/workspace/sdk/bin/python}" - "$@" <<'PY'
import argparse
import base64
import hashlib
import os
from pathlib import Path
import pwd
import re
import shlex
import signal
import subprocess
import tempfile


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def command(arguments, environment=None):
    process = subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=90)
        require(process.returncode == 0, 'SSH authentication/checkout command failed')
        return output
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def validate(args):
    require(os.geteuid() > 0 and pwd.getpwuid(os.geteuid()).pw_name == 'workspace', 'run as workspace')
    require(re.fullmatch(r'git@github\.com:[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\.git', args.url), 'reviewed GitHub SSH URL required')
    require(re.fullmatch(r'[0-9a-f]{40}', args.revision), 'full immutable repository commit required')
    require(re.fullmatch(r'[a-z]{2}-[a-z]+-[0-9]', args.region) and re.fullmatch(r'[0-9]{12}', args.account), 'account/region required')
    require(re.fullmatch(r'arn:aws:secretsmanager:' + re.escape(args.region) + ':' + args.account +
                         r':secret:[A-Za-z0-9/_-]+-[A-Za-z0-9]{6}', args.secret_arn), 'regional secret ARN required')
    require(re.fullmatch(r'[A-Za-z0-9-]{32,64}', args.version_id), 'immutable secret version required')
    require(re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', args.fingerprint), 'public deploy-key fingerprint required')
    require(not Path(args.directory).exists() and not Path(args.directory).is_symlink(), 'destination already exists')


def clone(args, session):
    validate(args)
    require(session.get_credentials().method == 'iam-role', 'native instance-role credentials required')
    from botocore.config import Config
    client = session.client('secretsmanager', region_name=args.region,
                            config=Config(connect_timeout=3, read_timeout=5, retries={'total_max_attempts': 2}))
    require(client.meta.region_name == args.region and
            client.meta.endpoint_url == 'https://secretsmanager.' + args.region + '.amazonaws.com', 'secret endpoint mismatch')
    response = client.get_secret_value(SecretId=args.secret_arn, VersionId=args.version_id)
    require(response.get('ARN') == args.secret_arn and response.get('VersionId') == args.version_id, 'secret reference mismatch')
    private = response.get('SecretString', '')
    require(isinstance(private, str) and len(private.encode()) <= 16384 and
            private.startswith('-----BEGIN OPENSSH PRIVATE KEY-----\n') and
            private.rstrip().endswith('-----END OPENSSH PRIVATE KEY-----'), 'raw OpenSSH private key required')
    require(command(['findmnt', '--noheadings', '--output', 'FSTYPE', '--target', '/dev/shm']).strip() == b'tmpfs',
            'RAM-backed credential directory required')
    with tempfile.TemporaryDirectory(prefix='workspace-git-', dir='/dev/shm') as temporary:
        key = Path(temporary)/'id_ed25519'
        descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(private.rstrip() + '\n')
        private = None
        response.clear()
        public = command(['ssh-keygen', '-y', '-f', str(key)]).decode().split()
        require(len(public) >= 2 and public[0] == 'ssh-ed25519', 'Ed25519 deploy key required')
        fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(public[1], validate=True)).digest()).decode().rstrip('=')
        require(fingerprint == args.fingerprint, 'deploy-key fingerprint mismatch')
        hosts = Path(temporary)/'known_hosts'
        hosts.write_text('github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n')
        environment = {'PATH': '/opt/workspace/sdk/bin:/usr/local/bin:/usr/bin:/bin', 'HOME': '/home/workspace',
                       'GIT_TERMINAL_PROMPT': '0', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                       'GIT_SSH_COMMAND': shlex.join(['ssh', '-F', '/dev/null', '-i', str(key),
                            '-o', 'IdentityAgent=none', '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                            '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(hosts),
                            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'HostKeyAlgorithms=ssh-ed25519',
                            '-o', 'ConnectTimeout=10'])}
        command(['git', 'init', '--', args.directory], environment)
        command(['git', '-C', args.directory, 'remote', 'add', 'origin', args.url], environment)
        command(['git', '-C', args.directory, 'fetch', '--no-tags', '--depth=1', 'origin', args.revision], environment)
        command(['git', '-C', args.directory, 'checkout', '--detach', args.revision], environment)
        require(command(['git', '-C', args.directory, 'rev-parse', 'HEAD'], environment).decode().strip() == args.revision,
                'checked-out repository commit mismatch')
    return {'repository_commit': args.revision, 'user': 'workspace', 'credential_removed': True}


def main():
    os.umask(0o077)
    def interrupted(_signal, _frame):
        raise TimeoutError('SSH execution interrupted')
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    parser = argparse.ArgumentParser(description='Non-root unattended SSH clone with a pinned runtime secret reference.')
    for name in ('url', 'revision', 'directory', 'secret_arn', 'version_id', 'fingerprint', 'region', 'account'):
        parser.add_argument(name)
    args = parser.parse_args()
    validate(args)
    import boto3
    clone(args, boto3.Session(region_name=args.region))
    print('workspace-ssh: PASS; reviewed commit checked out and runtime credential removed')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never echo raw SDK/subprocess diagnostics or retrieved values.
        import sys
        print('workspace-ssh: FAIL; authentication/checkout failed', file=sys.stderr)
        sys.exit(2)
PY
