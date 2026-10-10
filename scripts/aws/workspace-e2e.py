"""AWS-only orchestration around the existing immutable-plan lifecycle.

The external repository owns dependencies, data processing and result upload.
This controller owns admission, execution, independent verification and cleanup.
"""
import base64
import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import resource
import signal
import subprocess
import tempfile
import time
import uuid

GITHUB_HOST = 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n'


def publish_status(L, directory, value):
    # Each event is immutable evidence. Only the convenience pointer changes,
    # atomically, so observers never read a partly written JSON document.
    events = directory/'events'
    events.mkdir(mode=0o700, exist_ok=True)
    event = events/(uuid.uuid4().hex+'.json')
    L['write'](event, value)
    temporary = directory/('.status-'+uuid.uuid4().hex)
    L['write'](temporary, value)
    os.replace(temporary, directory/'status.json')


def status(L, directory, seconds=0):
    L['require'](0 <= seconds <= 60, 'observation must be bounded to 60 seconds')
    directory = L['checked_path'](directory)
    deadline = time.monotonic() + seconds
    while True:
        final = directory/'result.json'
        if final.exists():
            return L['read'](final)
        if time.monotonic() >= deadline:
            return L['read'](directory/'status.json') if (directory/'status.json').exists() else {'status': 'not_started'}
        time.sleep(min(2, max(0, deadline-time.monotonic())))


def object_bytes(L, s3, account, bucket, key, version=None, limit=1024*1024):
    arguments = {'Bucket': bucket, 'Key': key, 'ExpectedBucketOwner': account}
    if version:
        arguments['VersionId'] = version
    response = s3.get_object(**arguments)
    try:
        L['require'](response['ContentLength'] <= limit, 'artifact exceeds the configured acceptance bound')
        data = response['Body'].read(limit+1)
    finally:
        response['Body'].close()
    observed = response.get('VersionId')
    L['require'](observed not in (None, '', 'null') and (not version or version == observed), 'persistent object version required')
    L['require'](len(data) == response['ContentLength'], 'incomplete artifact download')
    return data, {'key': key, 'version_id': observed, 'sha256': L['sha'](data),
                  'size': len(data), 'last_modified': L['stamp'](response['LastModified'])}


def verify_commit(L,value,environment):
    def git(arguments, timeout=45):
        remote = subprocess.Popen(['git', *arguments], env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                                  preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024**2,512*1024**2)))
        try:
            output, _ = remote.communicate(timeout=timeout)
        finally:
            if remote.poll() is None:
                os.killpg(remote.pid, signal.SIGKILL)
                remote.communicate(timeout=5)
        L['require'](remote.returncode == 0, 'Repository cannot fetch the pinned GitHub commit')
        return output
    # A pinned commit may be older than the advertised branch heads. Fetch
    # that exact object into a temporary bare repository; execute no code.
    with tempfile.TemporaryDirectory(prefix='workspace-ref-') as checkout:
        L['require'](shutil.disk_usage(checkout).free>=2*1024**3,'commit preflight requires 2 GiB free')
        repository = str(Path(checkout)/'repository.git')
        git(['init', '--bare', '--template=', repository], 5)
        git(['-C', repository, '-c', 'core.hooksPath=/dev/null', 'fetch', '--depth=1', '--no-tags',
             '--', value['repository']['url'], value['repository']['revision']])
        L['require'](git(['-C', repository, 'rev-parse', 'FETCH_HEAD'], 5).decode().strip() == value['repository']['revision'],
                     'Fetched repository commit differs from the pin')
    return {'commit':value['repository']['revision'],'fetch_verified':True}


def verify_public(L,value):
    environment={'PATH':os.environ['PATH'],'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_TERMINAL_PROMPT':'0'}
    return verify_commit(L,value,environment)


def verify_ssh(L, base, client, value, target):
    reference = value['repository']['credential']
    response = client(base, 'secretsmanager').get_secret_value(SecretId=reference['secret_arn'], VersionId=reference['version_id'])
    L['require'](response.get('ARN') == reference['secret_arn'] and response.get('VersionId') == reference['version_id'], 'Git secret reference mismatch')
    private = response.get('SecretString', '')
    L['require'](isinstance(private, str) and len(private.encode()) <= 16384 and
                 private.startswith('-----BEGIN OPENSSH PRIVATE KEY-----\n') and
                 private.rstrip().endswith('-----END OPENSSH PRIVATE KEY-----'), 'Store raw OpenSSH private key plaintext in the selected Secrets Manager version')
    spec = importlib.util.spec_from_file_location('workspace_ram', L['REPO']/'scripts/aws/workspace_ram.py')
    ram = importlib.util.module_from_spec(spec); spec.loader.exec_module(ram)
    with ram.key_directory() as temporary:
        key = Path(temporary)/'key'
        descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(private.rstrip()+'\n')
        private = None
        response.clear()
        public = subprocess.run(['ssh-keygen', '-y', '-f', str(key)], capture_output=True, timeout=10)
        L['require'](public.returncode == 0, 'Git private key is invalid or requires a passphrase')
        parts = public.stdout.decode().split()
        L['require'](len(parts) >= 2 and parts[0] == 'ssh-ed25519', 'Dedicated Ed25519 deploy key required')
        fingerprint = 'SHA256:'+base64.b64encode(hashlib.sha256(base64.b64decode(parts[1], validate=True)).digest()).decode().rstrip('=')
        L['require'](fingerprint == reference['public_key_fingerprint'], 'Private key does not match the reviewed GitHub deploy-key fingerprint')
        hosts = Path(temporary)/'known_hosts'; hosts.write_text(GITHUB_HOST)
        ssh = ['ssh', '-F', '/dev/null', '-i', str(key), '-o', 'IdentityAgent=none', '-o', 'IdentitiesOnly=yes',
               '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile='+str(hosts),
               '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'ConnectTimeout=10']
        environment = {'PATH': os.environ['PATH'], 'HOME': str(Path.home()), 'GIT_CONFIG_NOSYSTEM': '1',
                       'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0', 'GIT_SSH_COMMAND': shlex.join(ssh)}
        verify_commit(L,value,environment)
    return {'public_key_fingerprint': fingerprint, 'private_key_file_removed': True, 'read_access_verified': True}


def preflight(L, value, target, directory):
    L['require']('job' in value and 'credential' in value['repository'], 'Configure the SSH repository and job before execution')
    directory = L['checked_path'](directory)
    directory.mkdir(parents=True, mode=0o700)
    base, client, _ = L['sessions'](target)
    s3 = client(base, 's3'); account = target['account_id']; bucket = target['inventory']['buckets'][0]
    for name in (bucket, target['backend']['bucket']):
        s3.head_bucket(Bucket=name, ExpectedBucketOwner=account)
        region = s3.get_bucket_location(Bucket=name, ExpectedBucketOwner=account)['LocationConstraint'] or 'us-east-1'
        L['require'](region == target['region'] and s3.get_bucket_versioning(Bucket=name, ExpectedBucketOwner=account).get('Status') == 'Enabled', 'Same-region versioned storage required')
    dataset = value['job']['dataset']; key = dataset['uri'].removeprefix('s3://'+bucket+'/')
    data, observed = object_bytes(L, s3, account, bucket, key, dataset['version_id'])
    L['require'](observed['sha256'] == dataset['sha256'], 'Configured dataset version/hash mismatch')
    L['write'](directory/'dataset.json', observed)
    ssh = verify_ssh(L, base, client, value, target)
    ec2 = client(base, 'ec2')
    page = ec2.describe_instances(Filters=[{'Name': 'instance-state-name', 'Values': ['pending','running','stopping','stopped','shutting-down']}], MaxResults=100)
    L['require'](not page.get('NextToken') and not page['Reservations'], 'This acceptance requires zero live EC2 instances before its one launch')
    result = {'status': 'success', 'observed_at': L['stamp'](), 'dataset': observed, 'ssh': ssh,
              'account_id': account, 'region': target['region'], 'live_ec2_instances': 0, 'cloud_resources_created': False}
    L['write'](directory/'result.json', result)
    return result


def payload(value, target, run_id):
    job = value['job']; bucket = target['inventory']['buckets'][0]
    if 'commands' in job:
        return {'repository':value['repository'],'workspace_id':value['workspace_id'],'account_id':target['account_id'],
                'region':target['region'],'run_id':run_id,'commands':job['commands'],'outputs':job['outputs'],
                'dataset_manifest':job['dataset_manifest'],'timeout_seconds':job['timeout_seconds'],'mode':value.get('mode','job'),
                'output_uri':f"s3://{bucket}/projects/{value['project']}/workspaces/{value['workspace_id']}/output/{run_id}/"}
    return {'repository': value['repository'], 'workspace_id': value['workspace_id'], 'account_id': target['account_id'],
            'region': target['region'], 'run_id': run_id, 'make_target': job['make_target'], 'timeout_seconds': job['timeout_seconds'],
            'data_uri': job['dataset']['uri'], 'data_version_id': job['dataset']['version_id'], 'data_sha256': job['dataset']['sha256'],
            'output_uri': f"s3://{bucket}/projects/{value['project']}/workspaces/{value['workspace_id']}/output/{run_id}/"}


def verify_credential_access(L, base, client, value, target, config, directory):
    secret=value['repository']['credential']['secret_arn']
    metadata=client(base,'secretsmanager').describe_secret(SecretId=secret)
    L['require'](metadata['ARN']==secret,'Git-secret encryption metadata mismatch')
    key=client(base,'kms').describe_key(KeyId=metadata.get('KmsKeyId','alias/aws/secretsmanager'))['KeyMetadata']
    L['require'](key['KeyState']=='Enabled' and key['Arn'].startswith(f"arn:aws:kms:{target['region']}:{target['account_id']}:key/"),
                 'Git-secret encryption key must be enabled in the reviewed account/region')
    role=f"arn:aws:iam::{target['account_id']}:role/{L['role_name'](config)}"
    context=[{'ContextKeyName':name,'ContextKeyValues':[content],'ContextKeyType':'string'} for name,content in {
        'kms:ViaService':f"secretsmanager.{target['region']}.amazonaws.com",'kms:CallerAccount':target['account_id'],
        'kms:EncryptionContext:SecretARN':secret}.items()]
    iam=client(base,'iam'); decisions=[]
    for action,resource in (('secretsmanager:GetSecretValue',secret),('kms:Decrypt',key['Arn'])):
        response=iam.simulate_principal_policy(PolicySourceArn=role,ActionNames=[action],ResourceArns=[resource],ContextEntries=context)
        items=response['EvaluationResults']
        L['require'](not response.get('IsTruncated') and len(items)==1 and items[0]['EvalDecision']=='allowed'
                     and items[0]['EvalActionName']==action and items[0]['EvalResourceName']==resource,
                     'Prepared runtime identity cannot retrieve/decrypt the reviewed Git secret')
        decisions.append({'action':action,'resource':resource,'decision':items[0]['EvalDecision']})
    L['write'](directory/'credential-access.json',{'role_arn':role,'decisions':decisions,
              'scope':'IAM policy simulation; real role retrieval is independently required during the SSH job'})


def verify_result(L, value, target, job, config, instance, s3, directory, first=None):
    bucket = target['inventory']['buckets'][0]; prefix = job['output_uri'].removeprefix('s3://'+bucket+'/')
    result, observed = object_bytes(L, s3, target['account_id'], bucket, prefix+value['job']['result']['file'],
                                    first['result']['version_id'] if first else None)
    L['require'](observed['sha256'] == value['job']['result']['sha256'], 'Independent result hash verification failed')
    raw, provenance_object = object_bytes(L, s3, target['account_id'], bucket, prefix+value['job']['provenance']['file'],
                                          first['provenance_object']['version_id'] if first else None, 65536)
    provenance = json.loads(raw)
    expected_role = f"arn:aws:sts::{target['account_id']}:assumed-role/{L['role_name'](config)}/{instance}"
    L['require'](provenance['run_id'] == job['run_id'] and provenance['repository_commit'] == value['repository']['revision']
                 and provenance['user'] == 'workspace' and provenance['identity_arn'] == expected_role
                 and provenance['aws_region'] == target['region'] and provenance['dataset'] == value['job']['dataset']
                 and provenance['dependency_lock_sha256'] == value['job']['provenance']['dependency_lock_sha256']
                 and provenance['python_version'] == L['TOOLBOX']['rpms']['python3.13']['ver']
                 and provenance['result'] == {'uri': job['output_uri']+value['job']['result']['file'], 'version_id': observed['version_id'], 'sha256': observed['sha256']},
                 'Provenance does not bind this run, instance, input, environment and result version')
    if value['job']['make_target']:
        L['require'](provenance['make_target'] == value['job']['make_target'], 'Make target mismatch')
    L['require'](L['utc'](observed['last_modified']) >= L['utc'](config['lease']['starts_at']), 'Old output cannot satisfy a new run')
    if first:
        L['require'](observed == first['result'] and provenance_object == first['provenance_object'], 'Artifact changed after compute deletion')
    else:
        execution, execution_object = object_bytes(L, s3, target['account_id'], bucket, prefix+'execution.json', limit=65536)
        execution = json.loads(execution)
        L['require'](execution['exit_code'] == 0 and execution['run_id'] == job['run_id'] and execution['repository_commit'] == value['repository']['revision']
                     and execution['user'] == 'workspace' and execution['instance_role_arn'] == expected_role
                     and execution['make_argv'] == (['make', job['make_target']] if job['make_target'] else ['make'])
                     and execution['bootstrap']['toolbox_sha256'] == config['toolbox_zip_sha256']
                     and execution['bootstrap']['workspace_id'] == value['workspace_id']
                     and execution['credential_removed_before_make'], 'Guest execution was not a successful non-root pinned job')
        L['write'](directory/'execution.json', execution)
    directory.mkdir(mode=0o700, exist_ok=True)
    (directory/'result.bin').write_bytes(result)
    L['write'](directory/'provenance.json', provenance)
    record = {'result': observed, 'provenance_object': provenance_object, 'provenance': provenance}
    L['write'](directory/'verification.json', record)
    return record


def run_command(L, base, client, target, config, launch, instance, job, directory, cancelled=lambda:False):
    expected = {r['address']: r['values'] for r in L['read'](launch/'plan.json')['planned_values']['root_module']['resources']}
    ssm = client(base, 'ssm'); name = L['role_name'](config)
    document = ssm.get_document(Name=name+'-job', DocumentVersion='1')
    description = ssm.describe_document(Name=name+'-job', DocumentVersion='1')['Document']
    L['require'](json.loads(document['Content']) == json.loads(expected['aws_ssm_document.job']['content']) and
                 document['DocumentType'] == 'Command' and document['DocumentVersion'] == '1'
                 and description['DocumentVersion'] == '1' and description['HashType'] == 'Sha256', 'Unattended command document differs from the exact reviewed plan')
    operator = L['operator_policy'](client(base, 'iam'), config, name+'-terminal')['PolicyDocument']
    L['require'](operator == json.loads(expected[L['operator_address'](config)]['policy']), 'Unattended operator grant differs from the exact reviewed plan')
    deadline = time.monotonic()+720
    while True:
        L['require'](not cancelled(),'cancel requested')
        L['bound_instance'](base, client, config, instance)
        information = ssm.describe_instance_information(Filters=[{'Key':'InstanceIds','Values':[instance]}])
        if any(i['InstanceId'] == instance and i['PingStatus'] == 'Online'
               and i['AgentVersion'] == L['TOOLBOX']['rpms']['amazon-ssm-agent']['ver'] for i in information['InstanceInformationList']):
            break
        L['require'](time.monotonic() < deadline, 'Bootstrap/SSM registration timed out')
        time.sleep(5)
    encoded = base64.b64encode(L['canon'](job)).decode()
    response = ssm.send_command(InstanceIds=[instance], DocumentName=name+'-job', DocumentVersion='1',
                                DocumentHash=description['Hash'], DocumentHashType='Sha256', Parameters={'job':[encoded]},
                                TimeoutSeconds=60, MaxConcurrency='1', MaxErrors='0')
    command = response['Command']; identifier = command['CommandId']
    L['require'](command['InstanceIds'] == [instance], 'Command target mismatch')
    L['write'](directory/'command.json', {'command_id': identifier, 'instance_id': instance,
                                         'document_hash': description['Hash'], 'submitted_at': L['stamp'](command['RequestedDateTime'])})
    deadline = time.monotonic()+job['timeout_seconds']+120
    while True:
        L['require'](not cancelled(),'cancel requested')
        try:
            invocation = ssm.get_command_invocation(CommandId=identifier, InstanceId=instance, PluginName='workspaceJob')
        except ssm.exceptions.InvocationDoesNotExist:
            invocation = {'Status': 'Pending'}
        if invocation['Status'] in ('Success','Failed','TimedOut','Cancelled','Undeliverable','Terminated'):
            L['write'](directory/'invocation.json', invocation)
            if 'commands' not in job:
                L['require'](invocation['Status'] == 'Success' and invocation['ResponseCode'] == 0, 'Unattended SSH/Make command failed')
            return {'command_id':identifier,'status':invocation['Status'],'exit_code':invocation.get('ResponseCode')}
        L['require'](time.monotonic() < deadline, 'Unattended job timed out')
        time.sleep(5)


def safe_error(error):
    if isinstance(error, ValueError) or type(error).__name__ == 'Failure':
        return {'type': type(error).__name__, 'reason': str(error)}
    return {'type': type(error).__name__, 'code': getattr(error, 'response', {}).get('Error', {}).get('Code')}


def cleanup_runner(L, target_name, control, config, applied):
    """Shared retirement path; expiry stays armed until ownership/absence passes."""
    if config is None or not (control/'prepare/apply-started.json').exists():
        return {'cleanup_status':'not_needed'}
    config=copy.deepcopy(config); config['phase']='retire'
    inputs=control/('retire-inputs-'+uuid.uuid4().hex+'.json'); L['write'](inputs,config)
    if (control/'launch/apply-result.json').exists():
        retired=applied('retire',inputs,str(control/'launch'))
        applied('cleanup',inputs,str(retired))
    else:
        recovery=control/('launch' if (control/'launch/apply-started.json').exists() else 'prepare')
        if recovery.name=='launch':
            retirement=control/'retire'
            if not retirement.exists(): L['native_plan'](target_name,'retire',str(inputs),str(retirement),None,None)
            plan=L['read'](retirement/'plan.json')
            if any(r['address']=='aws_instance.workspace[0]' and r['change']['before'] for r in plan['resource_changes']):
                applied('retire',inputs)
                recovery=None
        if recovery: applied('cleanup',inputs,recover_from=str(recovery))
        else: applied('cleanup',inputs,str(control/'retire'))
    return {'cleanup_status':'success'}


def execute(W, configuration_path, value, target, directory, authorization):
    L = W['L']; require = L['require']; directory = L['checked_path'](directory)
    require(len(authorization.strip()) >= 12 and 'job' in value, 'Explicit task authorization and a configured job required')
    require(L['source']()['working_tree_sha256'] == L['sha'](b''), 'Native execution requires clean committed source')
    directory.mkdir(parents=True, mode=0o700)
    run_id = uuid.uuid4().hex; job = payload(value, target, run_id)
    L['write'](directory/'task.json', {'authorization': authorization, 'account_id': target['account_id'],
                'region': target['region'], 'run_id': run_id, 'max_ec2_launches': 1, 'job': job, 'source': L['source']()})
    result = {'status': 'failure', 'run_id': run_id, 'output_uri': job['output_uri'], 'job_success': False,
              'cleanup_success': False, 'verified_after_compute_deletion': False, 'source': L['source'](),
              'repository_commit': value['repository']['revision'], 'dataset': value['job']['dataset']}
    control = directory/'workspace'; config = None; instance = None; base = client = None
    def phase(name):
        publish_status(L, directory, {'status': 'running', 'phase': name, 'run_id': run_id, 'observed_at': L['stamp']()})
    def applied(stage, inputs, dependency=None, recover_from=None, folder=None):
        folder = folder or control/stage
        if (folder/'apply-result.json').exists():
            require(L['read'](folder/'apply-result.json')['status']=='success','unsuccessful apply receipt')
            return folder
        require(not (folder/'apply-started.json').exists(),'uncertain apply; do not replay')
        if not folder.exists(): L['native_plan'](value['target_name'], stage, str(inputs), str(folder), dependency, recover_from)
        review = L['read'](folder/'review.json')
        # native_plan checked the complete mutation scope; bind this task to its
        # exact immutable review and plan, with no fresh plan hidden in apply.
        L['authorize'](str(folder), L['sha'](L['canon'](review)), authorization)
        L['apply'](str(folder))
        return folder
    def interrupted(_signum, _frame):
        raise InterruptedError('controller interrupted; cleanup required')
    old_handlers = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGTERM, signal.SIGINT)}
    try:
        phase('preflight'); preflight(L, value, target, directory/'preflight')
        base, client, _ = L['sessions'](target); s3 = client(base, 's3')
        prefix = job['output_uri'].removeprefix('s3://'+target['inventory']['buckets'][0]+'/')
        existing = s3.list_object_versions(Bucket=target['inventory']['buckets'][0], Prefix=prefix, MaxKeys=1, ExpectedBucketOwner=target['account_id'])
        require(not existing.get('Versions') and not existing.get('DeleteMarkers') and not existing.get('IsTruncated'), 'Unique output prefix is already occupied')
        phase('access')
        foundation = L['checked_path'](value['foundation']['plan_directory'])
        platform = L['read'](foundation/'config.tfvars.json')
        policy_arn=f"arn:aws:iam::{target['account_id']}:policy/{target['inventory']['resource_prefix']}-ws-{value['project']}-boundary"
        iam=client(base,'iam'); version=iam.get_policy(PolicyArn=policy_arn)['Policy']['DefaultVersionId']
        policy=iam.get_policy_version(PolicyArn=policy_arn,VersionId=version)['PolicyVersion']['Document']
        if platform.get('workspace_git_secret_arns', {}).get(value['project']) != [value['repository']['credential']['secret_arn']] or not any(s.get('Sid')=='DecryptReviewedGitCredential' for s in policy['Statement']):
            platform['workspace_git_secret_arns'] = {value['project']: [value['repository']['credential']['secret_arn']]}
            inputs = directory/'access.tfvars.json'; L['write'](inputs, platform)
            access = applied('workspace-access', inputs, str(foundation), folder=directory/'access')
            L['write'](directory/'configuration-before-access.json', value)
            value = copy.deepcopy(value); value['foundation']['plan_directory'] = str(access)
            # Persist the successfully applied foundation receipt for subsequent
            # runs, preserving the previous complete configuration beside it.
            Path(configuration_path).write_bytes(L['canon'](value))
        phase('prepare')
        starts = dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=5)
        W['render'](value, target, str(control), L['stamp'](starts))
        config = L['read'](control/'runner.json')
        inputs = control/'prepare.tfvars.json'; L['write'](inputs, config)
        applied('prepare', inputs, value['foundation']['plan_directory'])
        verify_credential_access(L, base, client, value, target, config, directory)
        phase('launch_window')
        while dt.datetime.now(dt.timezone.utc) < starts:
            time.sleep(min(5, (starts-dt.datetime.now(dt.timezone.utc)).total_seconds()))
        phase('launch'); config['phase'] = 'launch'
        inputs = control/'launch.tfvars.json'; L['write'](inputs, config)
        applied('launch', inputs, str(control/'prepare'))
        instance = L['read'](control/'launch/launched-owned.json')['instance_id']
        result.update(instance_id=instance, lease=config['lease'])
        phase('execute'); (directory/'execution').mkdir(mode=0o700)
        result['execution'] = run_command(L, base, client, target, config, control/'launch', instance, job, directory/'execution')
        phase('verify_before_deletion'); (directory/'before').mkdir(mode=0o700)
        result['verification'] = verify_result(L, value, target, job, config, instance, s3, directory/'before')
        result['job_success'] = True
    except BaseException as error:
        result['error'] = safe_error(error)
    finally:
        # Never let a second interruption disable cleanup; provider-side expiry
        # remains armed until absence checks permit deleting runner controls.
        for signum in old_handlers:
            signal.signal(signum, signal.SIG_IGN)
        if config is not None and (control/'prepare/apply-started.json').exists():
            try:
                phase('cleanup'); cleanup_runner(L,value['target_name'],control,config,applied)
                result['cleanup_success'] = True
            except BaseException as error:
                result['cleanup_error'] = safe_error(error)
        else:
            result['cleanup_success'] = True  # no runner mutation began
        if result['job_success'] and result['cleanup_success']:
            try:
                phase('verify_after_deletion'); (directory/'after').mkdir(mode=0o700)
                L['remaining_owned'](base, client, L['read'](control/'retire/retired-owned.json'))
                L['inventory'](base, client, config)
                result['after'] = verify_result(L, value, target, job, config, instance, client(base, 's3'), directory/'after', result['verification'])
                for bucket in (target['inventory']['buckets'][0], target['backend']['bucket']):
                    require(client(base, 's3').get_bucket_versioning(Bucket=bucket, ExpectedBucketOwner=target['account_id']).get('Status') == 'Enabled', 'Persistent bucket was not retained/versioned')
                dataset = value['job']['dataset']; bucket = target['inventory']['buckets'][0]
                _, checked = object_bytes(L, client(base, 's3'), target['account_id'], bucket, dataset['uri'].removeprefix('s3://'+bucket+'/'), dataset['version_id'])
                require(checked['sha256'] == dataset['sha256'], 'Input fixture changed')
                result['verified_after_compute_deletion'] = True
                result['status'] = 'success'
            except BaseException as error:
                result['after_error'] = safe_error(error)
        result['completed_at'] = L['stamp']()
        L['write'](directory/'result.json', result)
        publish_status(L, directory, {'status': result['status'], 'phase': 'complete', 'run_id': run_id, 'observed_at': result['completed_at']})
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
    return result


def verify_generic_result(L,value,target,job,config,instance,s3,directory,first=None):
    """Bind independent execution/transfer outcomes without acceptance fixture hashes."""
    spec=importlib.util.spec_from_file_location('ingest',L['REPO']/'scripts/aws/workspace-ingest.py')
    ingest=importlib.util.module_from_spec(spec); spec.loader.exec_module(ingest)
    bucket=target['inventory']['buckets'][0]; prefix=job['output_uri'][5:].split('/',1)[1]
    raw,object_record=object_bytes(L,s3,target['account_id'],bucket,prefix+'execution.json',
                                 first['execution_object']['version_id'] if first else None,1024*1024)
    receipt=json.loads(raw)
    expected_role=f"arn:aws:sts::{target['account_id']}:assumed-role/{L['role_name'](config)}/{instance}"
    L['require'](receipt['run_id']==job['run_id'] and receipt['repository_commit']==value['repository']['revision'] and
                 receipt['user']=='workspace' and receipt['instance_role_arn']==expected_role and
                 receipt['commands']==job['commands'] and receipt['dataset_manifest']==job['dataset_manifest'] and
                 receipt['bootstrap']['workspace_id']==value['workspace_id'] and receipt['bootstrap']['toolbox_sha256']==config['toolbox_zip_sha256'],
                 'execution receipt does not bind this run/repository/instance/input/toolbox')
    L['require'](receipt['infrastructure_ready'] is True and type(receipt['outputs_persisted']) is bool and
                 all(receipt[k] is None or type(receipt[k]) is int for k in ('setup_exit','job_exit')),
                 'invalid independent outcomes')
    if receipt['setup_exit'] is not None:
        L['require'](receipt['credential_removed_before_setup'] is True,'clone credential not removed before setup')
    L['require'](L['utc'](object_record['last_modified'])>=L['utc'](config['lease']['starts_at']),'old execution receipt')
    total=0; seen=set(); deadline=time.monotonic()+300
    for record in receipt['output_objects']:
        path=ingest.relative(record['path'])
        L['require'](record['key']==prefix+'files/'+path and path not in seen and
                     any(path==declared or path.startswith(declared+'/') for declared in job['outputs']['paths']),
                     'output outside this run/declared paths')
        seen.add(path); total+=record['bytes']
        L['require'](total<=job['outputs']['maximum_bytes'],'output transfer exceeds selected bound')
        ingest.verify_object(s3,target['account_id'],bucket,record,deadline)
    if receipt['outputs_persisted']: L['require'](seen,'success requires declared output versions')
    if 'log_object' in receipt:
        record=receipt['log_object']; L['require'](record['key']==prefix+'job.log' and record['bytes']<=8*1024*1024,'log scope/bound differs')
        ingest.verify_object(s3,target['account_id'],bucket,record,deadline)
    record={'execution':receipt,'execution_object':object_record}
    if first: L['require'](record==first,'outputs/execution changed after compute cleanup')
    directory.mkdir(parents=True,mode=0o700,exist_ok=True)
    L['write'](directory/'verification.json',record)
    return record
