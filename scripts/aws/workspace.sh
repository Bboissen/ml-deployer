#!/usr/bin/env bash
# One operator configuration; existing AWS roots and exact saved plans remain separate.
set -euo pipefail
exec "${WORKSPACE_PYTHON:-python3}" - "$@" 3<&0 <<'PY'
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sys

sys.dont_write_bytecode = True
ROOT = Path.cwd().resolve()
code = (ROOT/'scripts/aws/workspace-lifecycle.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
L = {'__name__': 'aws_workspace_lifecycle'}
exec(compile(code, 'scripts/aws/workspace-lifecycle.sh', 'exec'), L)
require, read, write, checked = (L[k] for k in ('require', 'read', 'write', 'checked_path'))


def configuration(path):
    path = checked(path)
    value = read(path)
    fields = {'version', 'target_name', 'target', 'project', 'workspace_id', 'repository',
              'sizing', 'maximum_runtime_minutes', 'foundation', 'artifacts'}
    require(set(value) in (fields, fields | {'job'}), 'unknown/missing project configuration fields')
    require(value['version'] == 1, 'unsupported project configuration version')
    os.environ['WORKSPACE_CONFIG'] = str(path)
    target = L['boundary']['targets']()[value['target_name']]
    require(re.fullmatch(r'[a-z][a-z0-9-]{2,23}', value['project']), 'invalid project name')
    repository = value['repository']
    require(set(repository) in ({'url', 'revision'}, {'url', 'revision', 'credential'}), 'repository requires URL and full revision; optional runtime credential reference only')
    ssh = re.fullmatch(r'git@github\.com:[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\.git', repository['url'])
    require((ssh or re.fullmatch(r'https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+', repository['url']))
            and re.fullmatch(r'[0-9a-f]{40}', repository['revision']), 'reviewed repository endpoint/full revision required')
    if ssh:
        credential = repository.get('credential', {})
        require(set(credential) == {'secret_arn', 'version_id', 'public_key_fingerprint'}, 'SSH requires a pinned runtime credential reference')
        prefix = f"arn:aws:secretsmanager:{target['region']}:{target['account_id']}:secret:{value['project']}/workspaces/{value['workspace_id']}/git/"
        require(re.fullmatch(re.escape(prefix) + r'[A-Za-z0-9_-]+-[A-Za-z0-9]{6}', credential['secret_arn'])
                and re.fullmatch(r'[A-Za-z0-9-]{32,64}', credential['version_id'])
                and re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', credential['public_key_fingerprint']), 'invalid regional credential ARN/version/public fingerprint')
    else:
        require('credential' not in repository, 'runtime SSH credential requires a GitHub SSH endpoint')
    # The source profile remains the reviewed RAM-first choice; no automatic fallback.
    require(value['sizing'] == {'policy': 'ram-first', 'instance_type': 'r8i.2xlarge', 'cpus': 8,
                              'memory_mb': 60000, 'disk_gb': 25, 'availability_zone': 'us-east-1a'}, 'unsupported sizing profile; review another profile first')
    require(target['region'] == 'us-east-1', 'source image/zone profile requires us-east-1')
    require(type(value['maximum_runtime_minutes']) is int and 15 <= value['maximum_runtime_minutes'] <= 60,
            'reviewed lifetime is 15 through 60 minutes')
    require(set(value['foundation']) == {'plan_directory', 'outputs_file', 'outputs_sha256'}, 'foundation requires its applied plan and captured outputs hash')
    if 'job' in value:
        job = value['job']
        require(set(job) == {'make_target', 'timeout_seconds', 'dataset', 'result', 'provenance'}, 'closed job configuration required')
        require(job['make_target'] is None or re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,63}', job['make_target']), 'invalid Make target')
        require(type(job['timeout_seconds']) is int and 30 <= job['timeout_seconds'] <= min(1800, (value['maximum_runtime_minutes']-10)*60), 'job timeout must leave time for cleanup')
        data = job['dataset']
        prefix = f"s3://{target['inventory']['buckets'][0]}/projects/{value['project']}/data/"
        require(set(data) == {'uri', 'version_id', 'sha256'} and data['uri'].startswith(prefix)
                and re.fullmatch(r'[A-Za-z0-9/_.,-]+', data['uri'][len(prefix):])
                and all(part not in ('.', '..') for part in data['uri'][len(prefix):].split('/'))
                and data['version_id'] not in ('', 'null') and re.fullmatch(r'[0-9a-f]{64}', data['sha256']), 'versioned dataset must be inside the reviewed regional namespace')
        require(set(job['result']) == {'file', 'sha256'} and set(job['provenance']) == {'file', 'dependency_lock_sha256'}, 'result and provenance verification required')
        for artifact, hash_field in ((job['result'], 'sha256'), (job['provenance'], 'dependency_lock_sha256')):
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', artifact['file']) and re.fullmatch(r'[0-9a-f]{64}', artifact[hash_field]), 'invalid artifact name/hash')
    return value, target


def render(value, target, directory, starts_at):
    directory = checked(directory)
    require(not directory.exists(), 'preserve earlier workspace run')
    foundation = value['foundation']
    plan_dir = checked(foundation['plan_directory'])
    review, receipt = read(plan_dir/'review.json'), read(plan_dir/'apply-result.json')
    require(review['stage'] in ('fresh-platform', 'workspace-access') and review['target_name'] == value['target_name']
            and review['target'] == target and receipt['status'] == 'success'
            and L['prior_source'](review['source']), 'successful matching foundation receipt required')
    captured = checked(foundation['outputs_file'])
    require(L['sha'](captured.read_bytes()) == foundation['outputs_sha256'], 'captured foundation outputs changed')
    outputs = read(captured)
    platform, guard = (outputs[k]['value'] for k in ('workspace_platform', 'workspace_guard'))
    require(platform['aws_account_id'] == target['account_id'] and platform['aws_region'] == target['region']
            and platform['deployer_role_arn'] == target['deployment_role_arn']
            and platform['state_bucket_arn'] == 'arn:aws:s3:::'+target['backend']['bucket'], 'foundation output target mismatch')
    platform_config = read(plan_dir/'config.tfvars.json')
    require(guard['code_sha256'] == platform_config['workspace_guard']['zip_sha256'], 'captured guard differs from foundation plan')
    project, wid = value['project'], value['workspace_id']
    require(project in platform_config['ml_projects'] and len(target['inventory']['buckets']) == 1,
            'project must already own the single reviewed workload bucket')
    bucket = target['inventory']['buckets'][0]
    request = {'schema_version': '2.0.0', 'kind': 'request', 'provider': 'aws', 'account_scope': target['account_id'],
               'region': target['region'], 'workspace_id': wid, 'toolbox_profile': 'cpu-python-v1',
               'resources': {k: value['sizing'][k] for k in ('cpus', 'memory_mb', 'disk_gb')},
               'operators': [target['operator_arn']], 'maximum_runtime_minutes': value['maximum_runtime_minutes'],
               'storage': {'data_uri': f's3://{bucket}/projects/{project}/data/',
                           'output_uri': f's3://{bucket}/projects/{project}/workspaces/{wid}/output/',
                           'state_uri': f"s3://{target['backend']['bucket']}/{target['backend']['runner_prefix']}{wid}.tfstate"}}
    # Use the same validator as production handoff/readiness, before writing a packet.
    import importlib.util
    module_spec = importlib.util.spec_from_file_location('workspace_contract', ROOT/'scripts/workspace/validate.py')
    validator = importlib.util.module_from_spec(module_spec); module_spec.loader.exec_module(validator)
    require(not list(validator.VALIDATOR.iter_errors(request)), 'request fails workspace schema')
    validator.request_semantics(request)
    artifacts = read(checked(value['artifacts']))
    L['verify_artifact'](artifacts['toolbox_zip_path'], artifacts['toolbox_zip_sha256'], 'toolbox')
    config = {'aws_account_id': target['account_id'], 'aws_region': target['region'],
              'resource_prefix': target['inventory']['resource_prefix'], 'project_name': target['inventory']['resource_prefix'],
              'backend_bucket_name': target['backend']['bucket'], 'state_bucket_arn': platform['state_bucket_arn'],
              'deployer_role_arn': platform['deployer_role_arn'], 'subnet_id': platform['subnet_id'],
              'security_group_id': platform['security_group_id'], 'phase': 'prepare',
              'workspace_identity': {'ml_project_name': project, 'request': request, 'bucket_name': bucket,
                  'permissions_boundary_arn': f"arn:aws:iam::{target['account_id']}:policy/{target['inventory']['resource_prefix']}-ws-{project}-boundary",
                  'session_policy_arn': f"arn:aws:iam::{target['account_id']}:policy/{target['inventory']['resource_prefix']}-session-manager-minimal"},
              'toolbox_zip_path': artifacts['toolbox_zip_path'], 'toolbox_zip_sha256': artifacts['toolbox_zip_sha256'],
              'instance_type': value['sizing']['instance_type'], 'ami_id': L['TOOLBOX']['ami_id'],
              'guard': guard, 'lease': L['lease'](request, starts_at)}
    if 'credential' in value['repository']:
        config['workspace_git_credential'] = value['repository']['credential']
    if 'job' in value:
        config['workspace_job_timeout_seconds'] = value['job']['timeout_seconds']
    L['validate_config'](config, target, 'prepare')
    directory.mkdir(parents=True, mode=0o700)
    write(directory/'project.json', value)
    write(directory/'request.json', request)
    write(directory/'runner.json', config)
    write(directory/'run.json', {'project_sha256': L['sha'](L['canon'](value)),
                                 'runner_sha256': L['sha'](L['canon'](config))})
    return {'run': str(directory), 'cloud_mutations': False, 'native_workspace_ready': False}


def run_configuration(value, directory):
    directory = checked(directory)
    require(read(directory/'project.json') == value, 'project configuration changed; preserve run and render a new one')
    config = read(directory/'runner.json'); manifest = read(directory/'run.json')
    require(manifest == {'project_sha256': L['sha'](L['canon'](value)), 'runner_sha256': L['sha'](L['canon'](config))},
            'rendered inputs changed; preserve run and render a new one')
    return directory, config


def guest_commands(value, config):
    request = config['workspace_identity']['request']
    repository = value['repository']
    clone = ['bash', '/opt/workspace/scripts/aws/clone-project.sh', repository['url'],
             repository['revision'], '/workspaces/'+value['workspace_id']+'/project']
    if 'credential' in repository:
        credential = repository['credential']
        clone = ['bash', '/opt/workspace/scripts/aws/workspace-ssh.sh', *clone[2:], credential['secret_arn'],
                 credential['version_id'], credential['public_key_fingerprint'], config['aws_region'], config['aws_account_id']]
    return {'clone': shlex.join(clone),
            'list_data': shlex.join(['aws', 's3', 'ls', request['storage']['data_uri']]),
            'list_output': shlex.join(['aws', 's3', 'ls', request['storage']['output_uri']]),
            'storage': request['storage'], 'user': 'workspace'}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='AWS workspace: one project config, reviewed saved plans, non-root terminal, S3 and teardown.')
    parser.add_argument('config')
    sub = parser.add_subparsers(dest='verb', required=True)
    p = sub.add_parser('render', help='offline: derive request and runner inputs for a new absolute lease')
    p.add_argument('run'); p.add_argument('--starts-at', required=True)
    p = sub.add_parser('plan'); p.add_argument('run'); p.add_argument('stage', choices=['access', 'prepare', 'launch', 'retire', 'cleanup'])
    p = sub.add_parser('apply'); p.add_argument('run'); p.add_argument('stage', choices=['access', 'prepare', 'launch', 'retire', 'cleanup'])
    p.add_argument('--review-sha256', required=True); p.add_argument('--authorization', required=True)
    for verb in ('connect', 'commands'):
        p = sub.add_parser(verb); p.add_argument('run')
    p = sub.add_parser('preflight', help='read-only AWS/Git checks; no resource creation')
    p.add_argument('run')
    p = sub.add_parser('run', help='one bounded unattended job, independent result verification and compute cleanup')
    p.add_argument('run'); p.add_argument('--authorization', required=True)
    p = sub.add_parser('status', help='bounded local observation of a run')
    p.add_argument('run'); p.add_argument('--wait', type=int, default=0)
    args = parser.parse_args()
    value, target = configuration(args.config)
    if args.verb in ('run', 'preflight', 'status'):
        spec = importlib.util.spec_from_file_location('aws_workspace_e2e', ROOT/'scripts/aws/workspace-e2e.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        if args.verb == 'status': result = module.status(L, args.run, args.wait)
        elif args.verb == 'preflight': result = module.preflight(L, value, target, checked(args.run))
        else: result = module.execute(globals(), args.config, value, target, args.run, args.authorization)
        print(json.dumps(result, indent=2, sort_keys=True))
        if result.get('status') == 'failure': sys.exit(1)
        return
    if args.verb == 'render': result = render(value, target, args.run, args.starts_at)
    else:
        directory, config = run_configuration(value, args.run)
        if args.verb == 'commands': result = guest_commands(value, config)
        elif args.verb == 'plan':
            stage = args.stage
            if stage == 'access':
                require('credential' in value['repository'], 'access planning requires a reviewed runtime SSH credential')
                platform = read(checked(value['foundation']['plan_directory'])/'config.tfvars.json')
                platform['workspace_git_secret_arns'] = {value['project']: [value['repository']['credential']['secret_arn']]}
                inputs = directory/'access.tfvars.json'; write(inputs, platform)
                result = L['native_plan'](value['target_name'], 'workspace-access', str(inputs), str(directory/'access'), value['foundation']['plan_directory'])
                print(json.dumps(result, indent=2, sort_keys=True))
                return
            config['phase'] = 'retire' if stage == 'cleanup' else stage
            inputs = directory/(stage+'.tfvars.json'); write(inputs, config)
            dependency = ((directory/'access' if (directory/'access/apply-result.json').exists() else value['foundation']['plan_directory'])
                          if stage == 'prepare' else directory/{'launch': 'prepare', 'retire': 'launch', 'cleanup': 'retire'}[stage])
            result = L['native_plan'](value['target_name'], stage, str(inputs), str(directory/stage), str(dependency))
        elif args.verb == 'apply':
            plan_dir = directory/args.stage
            L['authorize'](str(plan_dir), args.review_sha256, args.authorization)
            result = L['apply'](str(plan_dir))
        else:
            plan_dir = directory/'launch'
            instance = read(plan_dir/'launched-owned.json')['instance_id']
            if not (directory/'handoff.json').exists():
                L['handoff'](value['target_name'], str(plan_dir), instance, str(directory/'handoff.json'))
            L['run']([sys.executable, 'scripts/workspace/validate.py', str(directory/'request.json'),
                      '--handoff', str(directory/'handoff.json')], os.environ.copy(), 15)
            L['connect'](value['target_name'], str(plan_dir/'config.tfvars.json'), instance)
            return
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print('aws-workspace: FAIL: '+str(exc), file=sys.stderr)
        sys.exit(2)
PY
