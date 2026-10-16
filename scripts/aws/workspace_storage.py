"""S3 names and namespaces shared by preparation, permissions and execution."""
import hashlib
import re

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
    from datetime import datetime
    when = datetime.fromisoformat(observed_at.replace('Z', '+00:00'))
    return when.strftime('%Y-%m-%dT%H-%M-%SZ') + '-' + run_id


def dataset_name(source):
    from pathlib import PurePosixPath
    from urllib.parse import unquote, urlsplit
    path = urlsplit(source).path if '://' in source else source
    name = PurePosixPath(unquote(path.rstrip('/'))).name
    return re.sub(r'[^a-z0-9._-]+', '-', name.lower()).strip('.-')[:64] or 'dataset'


def output_scope(uri, workspace, run_id):
    """Validate a whole output URI, binding either layout to this workspace/run."""
    if not re.fullmatch(r'[0-9a-f]{32}', run_id):
        raise ValueError('invalid run identity')
    bucket = r's3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/'
    date = r'\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-'
    legacy = r'projects/([a-z0-9-]+)/workspaces/' + re.escape(workspace) + '/output/(?:' + date + ')?' + run_id + '/'
    match = re.fullmatch(bucket + legacy, uri)
    if match:
        return f'projects/{match[1]}/data/'
    readable = 'results/' + re.escape(workspace) + '/' + date + run_id + '/'
    if re.fullmatch(bucket + readable, uri):
        return 'datasets/'
    raise ValueError('unique output prefix required')
