"""S3 names and namespaces for reviewed deployment preparation."""
import hashlib
import re
from datetime import datetime, timezone
from pathlib import PurePosixPath
from urllib.parse import unquote, urlsplit

LEGACY = 'legacy'
READABLE = 'readable-v1'


def workload_bucket(account, region, project, layout=LEGACY):
    if layout == READABLE:
        return f'{project}-storage-{account}-{region}'
    if layout != LEGACY:
        raise ValueError('unsupported storage layout')
    suffix = hashlib.sha256(f'{account}/{region}/{project}'.encode()).hexdigest()[:16]
    return f'ml-{project}-{suffix}'


def prefixes(project, workspace, layout=LEGACY):
    if layout == READABLE:
        return 'datasets/', f'results/{workspace}/'
    if layout != LEGACY:
        raise ValueError('unsupported storage layout')
    return f'projects/{project}/data/', f'projects/{project}/workspaces/{workspace}/output/'


def run_folder(run_id, observed_at):
    # Full identity stays in the path to preserve unique per-operation writes.
    when = datetime.fromisoformat(observed_at.replace('Z', '+00:00'))
    if when.tzinfo is None:
        raise ValueError('timezone required for storage date')
    return when.astimezone(timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ') + '-' + run_id


def dataset_name(source):
    path = urlsplit(source).path if '://' in source else source
    name = PurePosixPath(unquote(path.rstrip('/'))).name
    return re.sub(r'[^a-z0-9._-]+', '-', name.lower()).strip('.-')[:64] or 'dataset'
