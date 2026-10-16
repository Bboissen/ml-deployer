"""AWS configuration preparation; never applies plans or executes project code."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time
from urllib.parse import quote, unquote, urlsplit
import uuid


def validate_project(L, path):
    return validate_project_value(L, L['load_json'](path))


def validate_project_value(L, value):
    """Validate CLI answers and file inputs against the same project contract."""
    from jsonschema import Draft202012Validator
    schema = L['load_json'](L['REPO']/'shared/workspace/project.schema.json')
    errors = list(Draft202012Validator(schema).iter_errors(value))
    # Schema errors may contain rejected credential values. Report field paths only.
    L['require'](not errors, 'invalid project configuration at '+
                 ', '.join('.'.join(map(str, e.absolute_path)) or 'root' for e in errors))
    L['require'](value['provider'] == 'aws', 'provider capability unsupported: AWS configuration only')
    L['require'](value['profile'] != 'default', 'select an explicit non-default temporary AWS profile')
    L['require'](len(value['project']+'-'+value['workspace']) <= 48, 'derived workspace ID exceeds 48 characters')
    repo = value['repository']
    L['require'](re.fullmatch(r'(?:https://github\.com/|git@github\.com:)[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\.git', repo['url']),
                 'repository requires a credential-free GitHub HTTPS or SSH URL')
    L['require'](valid_ref(repo['ref']), 'invalid repository branch, tag or full commit')
    for path in value['outputs']['paths']:
        parts = path.split('/')
        L['require'](not path.startswith(('/', '-')) and '\\' not in path and
                     all(p not in ('', '.', '..', '.git') for p in parts), 'outputs require relative project paths without traversal')
    for argv in value['commands'].values():
        L['require'](not argv[0].startswith('-'), 'command executable cannot start with an option')
    value = copy.deepcopy(value)
    value.setdefault('mode', 'job')
    return value


def valid_ref(ref):
    return bool(isinstance(ref, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,254}', ref) and
                not any(s in ref for s in ('..', '//', '@{')) and
                not any(p.startswith('.') or p.endswith(('.', '.lock')) for p in ref.split('/')) and
                not ref.endswith('/'))


GITHUB_NAME = r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}'


def repository_name(text):
    """OWNER/NAME from OWNER/NAME, a github.com URL or SSH address; errors never echo the input."""
    match = re.fullmatch(r'(?:(?:https://)?github\.com/|git@github\.com:)?(' + GITHUB_NAME + r')/?', text.strip())
    name = match.group(1) if match else ''
    name = name[:-4] if name.endswith('.git') else name
    if not re.fullmatch(GITHUB_NAME, name) or name.split('/')[1] in ('.', '..'):
        raise ValueError('enter a GitHub repository as OWNER/NAME or its github.com URL')
    return name


def project_slug(name):
    """A project name from a repository name: lowercase, letter first, 3-24 characters."""
    slug = re.sub(r'^[^a-z]+', '', re.sub(r'[^a-z0-9]+', '-', name.lower()))[:24].strip('-')
    return slug if len(slug) >= 3 else ('ml-' + slug).strip('-') if slug else 'ml-project'


def make_targets(text):
    """Explicit rule targets of a Makefile: a simple parse, not GNU make."""
    targets = set()
    for line in text.splitlines():
        match = re.match(r'([A-Za-z0-9_][A-Za-z0-9_./ -]*?)\s*(?:::|:)(?![:=])', line)
        if match: targets.update(match.group(1).split())
    return targets


def make_goals(commands):
    """Targets named by plain `make TARGET` commands; custom commands are not checked."""
    return [argv[1] for argv in commands.values() if len(argv) == 2 and argv[0] == 'make' and not argv[1].startswith('-')]


def github_api(L, path):
    """One read-only GitHub API call through the signed-in gh; None when not found. Responses are data."""
    try:
        result = L['boundary']['request'](['gh', 'api', '--hostname', 'github.com', '--method', 'GET', path], os.environ.copy(), 30)
    except subprocess.TimeoutExpired:
        L['require'](False, 'GitHub API request timed out')
    except OSError:
        L['require'](False, 'GitHub CLI unavailable; run ./workspace github-login')
    if result.returncode != 0:
        if re.search(r'\(HTTP 404\)', result.stderr): return None
        L['require'](False, 'GitHub API request failed; run ./workspace github-login and check repository access')
    L['require'](len(result.stdout) <= 4*1024*1024, 'GitHub API response too large')
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        L['require'](False, 'GitHub API returned an invalid response')


def github_repository(L, name, ref=None, commands=None):
    """Canonical name, visibility, clone URL, default branch and Makefile goals of one repository."""
    data = github_api(L, 'repos/' + name)
    L['require'](data is not None, 'GitHub repository not found, or not visible to your GitHub login')
    L['require'](isinstance(data, dict) and isinstance(data.get('full_name'), str) and re.fullmatch(GITHUB_NAME, data['full_name']) and
                 isinstance(data.get('private'), bool) and valid_ref(data.get('default_branch')), 'unexpected GitHub repository response')
    private = data['private'] or data.get('visibility') != 'public'
    full = data['full_name']; ref = ref or data['default_branch']
    L['require'](valid_ref(ref), 'invalid repository branch, tag or full commit')
    facts = {'name': full, 'private': private, 'default_branch': data['default_branch'], 'ref': ref,
             'url': ('git@github.com:' if private else 'https://github.com/') + full + '.git', 'makefile': None, 'missing': []}
    goals = make_goals(commands) if commands else []
    if goals:
        content = github_api(L, 'repos/' + full + '/contents/Makefile?ref=' + quote(ref, safe=''))
        if content is not None:
            L['require'](isinstance(content, dict) and content.get('type') == 'file' and content.get('encoding') == 'base64' and
                         isinstance(content.get('content'), str), 'unexpected GitHub Makefile response')
            try:
                text = base64.b64decode(content['content']).decode('utf-8', 'replace')
            except ValueError:
                L['require'](False, 'unexpected GitHub Makefile response')
            facts['makefile'] = True
            facts['missing'] = [goal for goal in goals if goal not in make_targets(text)]
        else:
            facts['makefile'] = False; facts['missing'] = goals
    return facts


MAKEFILE_GUIDE = ('Deploy runs make setup then make train in your repository, with DATA_DIR (dataset, read-only) and '
                  'OUTPUT_DIR (saved outputs) set. Add the targets, push, then run make again. Template:')
MAKEFILE_DOC = 'docs/operations/aws-deployer-quickstart.md#runtime-contract'


def makefile_todo(facts):
    """The repository change the default commands still need, or None."""
    if not facts['missing']: return None
    where = ' at ' + facts['name'] + ' ' + facts['ref']
    if facts['makefile'] is False: return 'add a Makefile with targets ' + ', '.join(facts['missing']) + where
    return 'add Makefile target' + ('s ' if len(facts['missing']) > 1 else ' ') + ', '.join(facts['missing']) + where


def supported_profile(L, region):
    profile = L['load_json'](L['REPO']/'infra/aws/workspace-profiles.json')['profiles']['cpu-python-v1']
    L['require'](region == profile['region'], 'unsupported region for the reviewed cpu-python-v1 profile')
    return profile


def workload_bucket(account, region, project):
    """Same deterministic naming as workspace storage preparation and its root."""
    suffix = hashlib.sha256(f'{account}/{region}/{project}'.encode()).hexdigest()[:16]
    return f'ml-{project}-{suffix}'


def storage_uris(bucket, project, workspace, backend_bucket, runner_prefix):
    return {'data_uri': f's3://{bucket}/projects/{project}/data/',
            'output_uri': f's3://{bucket}/projects/{project}/workspaces/{workspace}/output/',
            'state_uri': f's3://{backend_bucket}/{runner_prefix}{workspace}.tfstate'}


def dataset_metadata(L, source, config_directory):
    try:
        parsed = urlsplit(source)
        port = parsed.port
    except ValueError:
        L['require'](False, 'invalid dataset URL')
    if parsed.scheme:
        L['require'](parsed.scheme in ('s3', 'https') and parsed.netloc and
                     not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
                     'dataset scheme unsupported or URL contains credentials/query/fragment')
        L['require'](all(p not in ('.', '..') for p in unquote(parsed.path).split('/')), 'dataset URL contains traversal')
        if parsed.scheme == 's3':
            L['require'](re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', parsed.netloc), 'invalid dataset bucket')
        else:
            L['require'](parsed.hostname and port in (None, 443), 'dataset HTTPS endpoint unsupported')
        return {'adapter': parsed.scheme, 'source': source, 'bytes': None, 'files': None,
                'verification': 'pending-ingestion', 'uploaded': False}
    path = Path(os.path.abspath(config_directory/source))
    L['require'](not any(p.is_symlink() for p in (path, *path.parents)), 'dataset symlinks are unsupported')
    L['require'](path.exists() and (path.is_file() or path.is_dir()), 'local dataset must be an existing file or directory')
    records = []
    deadline = time.monotonic()+30
    def record(item, relative):
        L['require'](time.monotonic() <= deadline, 'dataset metadata scan exceeded 30 seconds')
        metadata = item.lstat()
        L['require'](stat.S_ISREG(metadata.st_mode), 'dataset contains a symlink or special file')
        records.append({'path': relative, 'bytes': metadata.st_size, 'mtime_ns': metadata.st_mtime_ns})
        L['require'](len(records) <= 100000, 'dataset metadata scan exceeds 100000 files')
    if path.is_file():
        record(path, path.name)
    else:
        def scan_error(_):
            L['require'](False, 'dataset directory cannot be inspected')
        for directory, directories, files in os.walk(path, followlinks=False, onerror=scan_error):
            L['require'](time.monotonic() <= deadline, 'dataset metadata scan exceeded 30 seconds')
            L['require'](not any((Path(directory)/d).is_symlink() for d in directories), 'dataset directory symlinks are unsupported')
            for name in files:
                item = Path(directory)/name
                record(item, item.relative_to(path).as_posix())
    L['require'](records, 'local dataset contains no files')
    records.sort(key=lambda r: r['path'])
    return {'adapter': 'local', 'source': str(path), 'bytes': sum(r['bytes'] for r in records),
            'files': len(records), 'metadata_sha256': L['sha'](L['canon'](records)),
            'verification': 'metadata-only', 'uploaded': False}


def repository_refs(ref):
    return [ref] if ref.startswith(('refs/heads/', 'refs/tags/')) else ['refs/heads/'+ref, 'refs/tags/'+ref]


def git_ref(L, repository):
    ref = repository['ref']
    if re.fullmatch(r'[0-9a-f]{40}', ref):
        return {**repository, 'revision': ref, 'resolved_ref': ref, 'verification': 'pin-only'}
    choices = repository_refs(ref)
    patterns = choices+[r+'^{}' for r in choices if r.startswith('refs/tags/')]
    environment = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'AWS_', 'TF_'))}
    environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0',
                       GIT_SSH_COMMAND='ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10')
    result = L['boundary']['request'](['git', '-c', 'core.hooksPath=/dev/null', 'ls-remote', '--exit-code',
                                      repository['url'], *patterns], environment, 30)
    L['require'](result.returncode == 0 and len(result.stdout) <= 65536,
                 'Git ref lookup failed; check repository access/ref with no interactive prompts')
    refs = {}
    for line in result.stdout.splitlines():
        parts = line.split('\t')
        L['require'](len(parts) == 2 and re.fullmatch(r'[0-9a-f]{40}', parts[0]) and
                     parts[1] in patterns and parts[1] not in refs, 'unexpected Git ref response')
        refs[parts[1]] = parts[0]
    matched = [r for r in choices if r in refs]
    L['require'](len(matched) == 1, 'Git ref missing or ambiguous; use refs/heads/name or refs/tags/name')
    selected = matched[0]
    return {**repository, 'revision': refs.get(selected+'^{}', refs[selected]),
            'resolved_ref': selected, 'verification': 'advertised-ref'}


def discover(L, project):
    boundary = L['boundary']
    environment = boundary['profile_environment'](project['profile'], project['region'])
    result = boundary['aws'](project, environment, ['sts', 'get-caller-identity'], '{Account:Account,Arn:Arn}')
    L['require'](result['status'] == 'observed', 'authentication failed: '+result.get('error', 'unknown'))
    return {'schema_version': '1.0.0', 'kind': 'aws-project-discovery', 'profile': project['profile'],
            'region': project['region'], 'identity': result['data'], 'repository': git_ref(L, project['repository'])}


def validate_discovery(L, project, observed):
    require = L['require']
    require(isinstance(observed, dict) and set(observed) ==
            {'schema_version', 'kind', 'profile', 'region', 'identity', 'repository'}, 'invalid discovery fields')
    require(observed['schema_version'] == '1.0.0' and observed['kind'] == 'aws-project-discovery' and
            observed['profile'] == project['profile'] and observed['region'] == project['region'], 'discovery profile/region mismatch')
    identity = observed['identity']
    require(isinstance(identity, dict) and set(identity) == {'Account', 'Arn'}, 'invalid identity fields')
    require(isinstance(identity['Account'], str) and re.fullmatch(r'[0-9]{12}', identity['Account']), 'invalid discovered account')
    require(isinstance(identity['Arn'], str) and re.fullmatch(
        r'arn:aws:(?:iam::'+identity['Account']+r':(?:user|role)/[A-Za-z0-9_+=,.@/-]+|sts::'+identity['Account']+
        r':assumed-role/[A-Za-z0-9_+=,.@-]+/[A-Za-z0-9_+=,.@-]+)', identity['Arn']), 'identity account/partition mismatch or unsupported identity')
    repository = observed['repository']
    require(isinstance(repository, dict) and set(repository) == {'url', 'ref', 'revision', 'resolved_ref', 'verification'}, 'invalid repository discovery fields')
    require(all(repository[k] == project['repository'][k] for k in ('url', 'ref')) and
            isinstance(repository['revision'], str) and re.fullmatch(r'[0-9a-f]{40}', repository['revision']), 'repository discovery mismatch')
    ref = repository['ref']
    if re.fullmatch(r'[0-9a-f]{40}', ref):
        require(repository['revision'] == ref and repository['resolved_ref'] == ref and repository['verification'] == 'pin-only', 'commit pin mismatch')
    else:
        choices = repository_refs(ref)
        require(repository['resolved_ref'] in choices and repository['verification'] == 'advertised-ref', 'resolved Git ref mismatch')


def configure(L, config_path, discovery_path=None):
    project = validate_project(L, config_path)
    profile = supported_profile(L, project['region'])
    dataset = dataset_metadata(L, project['dataset']['source'], Path(config_path).absolute().parent)
    observed = L['load_json'](discovery_path) if discovery_path else discover(L, project)
    validate_discovery(L, project, observed)
    account = observed['identity']['Account']; region = project['region']; slug = project['project']
    workspace = slug+'-'+project['workspace']; bucket = workload_bucket(account, region, slug)
    resource_prefix = slug[:12]+'-'+L['sha'](f'{account}/{region}/{slug}'.encode())[:10]
    backend = f'{resource_prefix}-tofu-state-{account}-{region}-ws-v1'
    prefix = f'aws/{account}/{region}/'
    storage = storage_uris(bucket, slug, workspace, backend, prefix+'runner/')
    pending = ['foundation-ownership-and-lineage', 'quota-image-offering-and-price-discovery',
               'runtime-repository-access', 'dataset-ingestion', 'generic-project-execution-and-output-persistence']
    if ':assumed-role/' in observed['identity']['Arn']:
        pending.append('native-operator-role-resolution')
    if observed['repository']['verification'] == 'pin-only':
        pending.append('repository-commit-fetch-verification')
    deployment = {'schema_version': '1.0.0', 'kind': 'resolved-deployment', 'provider': 'aws',
                  'configuration': project, 'account_id': account, 'operator_arn': observed['identity']['Arn'],
                  'repository': observed['repository'], 'dataset': dataset, 'toolbox_profile': 'cpu-python-v1',
                  'sizing': profile['sizing'], 'image_reference': L['TOOLBOX']['ami_id'],
                  'names': {'resource_prefix': resource_prefix, 'workspace_id': workspace, 'workload_bucket': bucket,
                            'deployer_role_arn': f'arn:aws:iam::{account}:role/{resource_prefix}-workspace-deployer'},
                  'backend': {'bucket': backend, 'region': region, 'platform_key': prefix+'platform/platform.tfstate',
                              'runner_prefix': prefix+'runner/'}, 'storage': storage,
                  'scope': {'maximum_runtime_minutes': project['maximum_runtime_minutes'], 'max_ec2_launches': 1,
                            'commands': project['commands'], 'execute_on_deploy': project['mode'] == 'job',
                            'cleanup': 'owned-compute' if project['mode'] == 'job' else 'explicit-or-absolute-expiry',
                            'retain': ['state-storage', 'workload-storage']},
                  'field_sources': {'account_id': 'discovery.identity.Account', 'operator_arn': 'discovery.identity.Arn',
                                    'repository': 'discovery.repository', 'names': 'configuration + discovery account/region',
                                    'sizing': 'infra/aws/workspace-profiles.json', 'image_reference': 'toolbox/versions.json',
                                    'dataset': 'configuration source + local metadata; remote sizes unverified'},
                  'execution_supported': True, 'execution_admitted': False, 'pending': pending}
    identifier = uuid.uuid4().hex
    directory = L['inside'](L['REPO']/'evidence/aws/operations'/identifier)
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    files = {'project.json': project, 'discovery.json': observed, 'deployment.json': deployment}
    for name, value in files.items():
        L['write'](directory/name, value)
    operation = {'schema_version': '1.0.0', 'kind': 'configuration-operation', 'operation_id': identifier,
                 'status': 'prepared', 'observed_at': L['stamp'](), 'source': L['source'](),
                 'discovery_origin': 'supplied-offline' if discovery_path else 'read-only-live',
                 'files': {name: L['sha']((directory/name).read_bytes()) for name in files},
                 'deployment_authorized': False, 'cloud_mutations': False}
    # Written last: partial preparation never looks like a complete operation.
    L['write'](directory/'operation.json', operation)
    return {**operation, 'operation_directory': str(directory.relative_to(L['REPO'])), 'review': deployment}


def operation_status(L, config_path, directory):
    directory = L['inside'](Path(directory).absolute())
    L['require'](directory.parent == L['REPO']/'evidence/aws/operations' and
                 re.fullmatch(r'[0-9a-f]{32}', directory.name), 'invalid configuration operation directory')
    operation = L['read'](directory/'operation.json')
    L['require'](set(operation) == {'schema_version', 'kind', 'operation_id', 'status', 'observed_at', 'source',
                                  'discovery_origin', 'files', 'deployment_authorized', 'cloud_mutations'} and
                 operation['schema_version'] == '1.0.0' and operation['operation_id'] == directory.name and
                 operation['kind'] == 'configuration-operation' and operation['status'] == 'prepared' and
                 operation['deployment_authorized'] is False and operation['cloud_mutations'] is False and
                 operation['discovery_origin'] in ('supplied-offline', 'read-only-live') and
                 set(operation['files']) == {'project.json', 'discovery.json', 'deployment.json'} and
                 not (directory/'operation.json').is_symlink(), 'invalid configuration operation')
    for name, expected in operation['files'].items():
        L['require'](isinstance(expected, str) and re.fullmatch(r'[0-9a-f]{64}', expected) and
                     not (directory/name).is_symlink() and L['sha']((directory/name).read_bytes()) == expected,
                     'configuration operation artifact changed')
    L['require'](L['read'](directory/'project.json') == validate_project(L, config_path),
                 'project configuration changed; prepare a new operation')
    return {**operation, 'operation_directory': str(directory.relative_to(L['REPO'])),
            'review': L['read'](directory/'deployment.json')}
