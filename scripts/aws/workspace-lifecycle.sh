#!/usr/bin/env bash
# Explicit workspace execution extension to milestone A. No generic exec verb.
set -euo pipefail
exec "${WORKSPACE_PYTHON:-python3}" - "$@" 3<&0 <<'PY'
import argparse
import base64
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import time
import uuid
import zipfile

sys.dont_write_bytecode = True
REPO = Path.cwd().resolve()
# Reuse A's target, environment, source and evidence boundary verbatim. Its
# closed exec command remains closed; this script implements only named stages.
code = (REPO / 'scripts/aws/workspace-target.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
boundary = {'__name__': 'aws_target_boundary'}
exec(code.rsplit('\ntry:\n    main()', 1)[0], boundary)
Failure, require, inside, write, source = (boundary[n] for n in ('Failure','require','inside','write','source'))

def sha(data):
    return hashlib.sha256(data).hexdigest()

def canon(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)+'\n').encode()

def utc(value):
    parsed = dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
    require(parsed.strftime('%Y-%m-%dT%H:%M:%SZ') == value, 'noncanonical timestamp')
    return parsed

def stamp(value=None):
    return (value or dt.datetime.now(dt.timezone.utc)).strftime('%Y-%m-%dT%H:%M:%SZ')

def checked_path(value):
    return inside(Path(value).resolve())

def read(value):
    path=checked_path(value)
    require(path.stat().st_size<=16*1024*1024,'input exceeds bound')
    def pairs(items):
        result={}
        for key,value in items:
            require(key not in result,'duplicate JSON field'); result[key]=value
        return result
    return json.loads(path.read_text(),object_pairs_hook=pairs,parse_constant=lambda _: require(False,'nonfinite JSON'))

def run(args, env, seconds=180):
    p = boundary['request'](args, env, seconds)
    require(p.returncode == 0, 'command failed; '+boundary['error_category'](p.stderr))
    return p.stdout

def bounded(seconds, callback):
    def expired(_signal,_frame): raise Failure('native observation exceeded its time bound')
    previous=signal.signal(signal.SIGALRM,expired)
    signal.setitimer(signal.ITIMER_REAL,seconds)
    try: return callback()
    finally:
        signal.setitimer(signal.ITIMER_REAL,0)
        signal.signal(signal.SIGALRM,previous)

def archive(path, members):
    inside(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as f, zipfile.ZipFile(f, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(members.items()):
            info = zipfile.ZipInfo(name, date_time=(1980,1,1,0,0,0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, data)
    return sha(path.read_bytes())

def build(directory):
    directory = checked_path(directory)
    require(not directory.exists(), 'artifact directory already exists; preserve earlier artifacts')
    directory.mkdir(parents=True, mode=0o700)
    toolbox = REPO/'infra/aws/runner/workspace/toolbox'
    members = {p.name:p.read_bytes() for p in toolbox.iterdir() if p.is_file()}
    for name in ('scripts/workspace/probe-toolbox.py','shared/workspace/toolbox.json','scripts/aws/clone-project.sh','scripts/aws/workspace-guest-observe.sh'):
        members[name] = (REPO/name).read_bytes()
    toolbox_hash = archive(directory/'toolbox.zip', members)
    sdk = directory/'sdk'
    # Local dependency downloads only; SDK is bundled to avoid mutable Lambda
    # runtime SDK behavior. uv verifies every wheel against the reviewed lock.
    env = {k:v for k,v in os.environ.items() if not k.startswith(('AWS_','TF_'))}
    env.update(UV_CACHE_DIR=str(directory/'uv-cache'), PYTHONDONTWRITEBYTECODE='1')
    run(['uv','pip','install','--python','3.13','--target',str(sdk),'--only-binary',':all:',
         '--require-hashes','--no-compile-bytecode','-r',str(toolbox/'sdk-requirements.lock')],env,180)
    sdk_members = {str(p.relative_to(sdk)):p.read_bytes() for p in sdk.rglob('*')
                   if p.is_file() and '__pycache__' not in p.parts and p.suffix != '.pyc' and p.relative_to(sdk).parts[0]!='bin'
                   and p.name not in ('RECORD','uv_cache.json','direct_url.json')}
    sdk_members['watchdog.py'] = (REPO/'infra/aws/runner/workspace/watchdog.py.tftpl').read_bytes()
    guard_hash = archive(directory/'watchdog.zip',sdk_members)
    result = {'source':source(),'toolbox_zip_path':str(directory/'toolbox.zip'),
              'toolbox_zip_sha256':toolbox_hash,'guard_zip_path':str(directory/'watchdog.zip'),
              'guard_zip_sha256':guard_hash,'native_readiness':'unverified'}
    write(directory/'artifacts.json',result)
    return result

def lease(request, starts_at):
    start = utc(starts_at)
    require(request['maximum_runtime_minutes'] >= 15, 'lease too short')
    return {'id':uuid.uuid4().hex,'starts_at':stamp(start),'launch_before':stamp(start+dt.timedelta(minutes=5)),
            'expires_at':stamp(start+dt.timedelta(minutes=request['maximum_runtime_minutes']))}

def verify_artifact(path,expected,kind):
    path=checked_path(path); manifest=read(path.parent/'artifacts.json')
    require(manifest['source']==source() and manifest[kind+'_zip_path']==str(path) and manifest[kind+'_zip_sha256']==expected
            and sha(path.read_bytes())==expected,'artifact source/path/hash mismatch; rebuild and review')
    with zipfile.ZipFile(path) as zipped:
        require(len(zipped.namelist())==len(set(zipped.namelist())),'duplicate archive member')
        if kind=='guard':
            require(zipped.read('watchdog.py')==(REPO/'infra/aws/runner/workspace/watchdog.py.tftpl').read_bytes(),'guard archive source mismatch')
        else:
            members={p.name:p.read_bytes() for p in (REPO/'infra/aws/runner/workspace/toolbox').iterdir() if p.is_file()}
            for name in ('scripts/workspace/probe-toolbox.py','shared/workspace/toolbox.json','scripts/aws/clone-project.sh','scripts/aws/workspace-guest-observe.sh'): members[name]=(REPO/name).read_bytes()
            require(set(zipped.namelist())==set(members) and all(zipped.read(k)==v for k,v in members.items()),'toolbox archive differs from current source')

def packet(target_name,storage_directory,artifacts_path,platform_config_path,alarm_topic,output):
    target=boundary['targets']()[target_name]; storage_directory=checked_path(storage_directory)
    storage=read(storage_directory/'storage-preparation.json'); artifacts=read(artifacts_path)
    require(storage['target']==target_name and storage['configuration_sha256']==sha(canon(target)),'storage target mismatch')
    require(storage['ml_project_name']=='demo' and storage['workspace_id']=='demo-dev-01','accepted first project/workspace mismatch')
    directory=checked_path(output); require(not directory.exists(),'packet directory already exists'); directory.mkdir(parents=True)
    request={'schema_version':'2.0.0','kind':'request','provider':'aws','account_scope':target['account_id'],'region':target['region'],
             'workspace_id':storage['workspace_id'],'toolbox_profile':'cpu-python-v1','resources':{'cpus':8,'memory_mb':60000,'disk_gb':25},
             'storage':storage['storage'],'operators':[target['operator_arn']],'maximum_runtime_minutes':60}
    write(directory/'request.json',request)
    run([sys.executable,'scripts/workspace/validate.py',str(directory/'request.json')],os.environ.copy(),15)
    platform=read(platform_config_path); validate_config(platform,target,'platform') if platform.get('workspace_guard') else None
    entries=read(storage_directory/'platform-project-entry.json')
    projects=platform.get('ml_projects',{})
    for name,entry in entries.items():
        require(name not in projects or projects[name]==entry,'project map conflict; review existing assignment instead')
        projects[name]=entry
    platform['ml_projects']=projects
    platform['workspace_guard']={'zip_path':artifacts['guard_zip_path'],'zip_sha256':artifacts['guard_zip_sha256'],'alarm_topic_arn':alarm_topic}
    validate_config(platform,target,'platform'); write(directory/'platform.tfvars.json',platform)
    identity={'ml_project_name':storage['ml_project_name'],'request':request,'bucket_name':storage['storage']['data_uri'].split('/')[2],
              'permissions_boundary_arn':f"arn:aws:iam::{target['account_id']}:policy/{target['inventory']['resource_prefix']}-ws-demo-boundary",
              'session_policy_arn':f"arn:aws:iam::{target['account_id']}:policy/{target['inventory']['resource_prefix']}-session-manager-minimal"}
    skeleton={'aws_account_id':target['account_id'],'aws_region':target['region'],'resource_prefix':target['inventory']['resource_prefix'],
              'project_name':platform['project_name'],'backend_bucket_name':target['backend']['bucket'],'state_bucket_arn':platform['state_bucket_arn'],
              'deployer_role_arn':target['deployment_role_arn'],'subnet_id':'subnet-00000000000000000','security_group_id':'sg-00000000000000000',
              'phase':'prepare','workspace_identity':identity,'toolbox_zip_path':artifacts['toolbox_zip_path'],
              'toolbox_zip_sha256':artifacts['toolbox_zip_sha256'],'instance_type':'r8i.2xlarge','ami_id':'ami-03c3da4cfa8e8943a'}
    require(target['account_id']=='000000000000' and target['region']=='us-east-1','packet network pins require accepted target')
    write(directory/'runner-skeleton.json',skeleton)
    return {'packet':str(directory.relative_to(REPO)),'compute_enabled':False,'native_readiness':'unverified','missing_runner_inputs':['guard output','future absolute lease']}

def outputs(target_name,plan_directory,output):
    directory=checked_path(plan_directory); m=read(directory/'review.json'); config=read(directory/'config.tfvars.json')
    require(m['target_name']==target_name and m['stage']=='platform' and m['source']==source() and read(directory/'apply-result.json')['status']=='success','exact successful platform required')
    target,env,base,client,identities,state=context(target_name,'platform',config)
    require(target==m['target'] and sha(canon(config))==m['config_sha256'],'platform output target/config drift')
    env.update(TF_DATA_DIR=str(directory/'tofu-data'))
    guard=json.loads(run(['tofu',f"-chdir={m['root']}",'output','-json','workspace_guard'],env,30))
    require(guard['code_sha256']==config['workspace_guard']['zip_sha256'],'platform guard output hash mismatch')
    write(checked_path(output),guard)
    return {'guard_output':str(checked_path(output).relative_to(REPO)),'guard_native_acceptance':'unverified'}

def sessions(target):
    import boto3, botocore
    from botocore.config import Config
    require(boto3.__version__ == botocore.__version__ == '1.43.109', 'install reviewed SDK lock for native commands')
    cfg = Config(connect_timeout=3,read_timeout=5,retries={'total_max_attempts':2})
    base = boto3.Session(profile_name=target['profile'],region_name=target['region'])
    def client(session, service):
        c = session.client(service,region_name=target['region'],config=cfg)
        require(c.meta.region_name == target['region'], 'SDK region mismatch')
        require(c.meta.endpoint_url.startswith('https://') and c.meta.endpoint_url.split('/')[2].endswith('.amazonaws.com'), 'SDK endpoint mismatch')
        return c
    observed = client(base,'sts').get_caller_identity()
    require(observed['Account'] == target['account_id'] and observed['Arn'] == target['operator_arn'], 'SDK operator differs from named target')
    def assume(session, arn):
        credentials = client(session,'sts').assume_role(RoleArn=arn,RoleSessionName='workspace-preflight',DurationSeconds=900)['Credentials']
        assumed = boto3.Session(aws_access_key_id=credentials['AccessKeyId'],aws_secret_access_key=credentials['SecretAccessKey'],
                               aws_session_token=credentials['SessionToken'],region_name=target['region'])
        result = client(assumed,'sts').get_caller_identity()
        prefix = f"arn:aws:sts::{target['account_id']}:assumed-role/{arn.rsplit('/',1)[1]}/"
        require(result['Account'] == target['account_id'] and result['Arn'].startswith(prefix), 'SDK assumed identity mismatch')
        return assumed, result['Arn']
    return base, client, assume

def snapshot(base, client, target, key):
    s3 = client(base,'s3')
    args = {'Bucket':target['backend']['bucket'],'Key':key,'ExpectedBucketOwner':target['account_id']}
    location=s3.get_bucket_location(Bucket=args['Bucket'],ExpectedBucketOwner=args['ExpectedBucketOwner'])['LocationConstraint'] or 'us-east-1'
    require(location==target['region'] and s3.get_bucket_versioning(Bucket=args['Bucket'],ExpectedBucketOwner=args['ExpectedBucketOwner']).get('Status')=='Enabled','backend region/versioning mismatch')
    try:
        head = s3.head_object(**args)
    except s3.exceptions.ClientError as exc:
        # 403 is unknown, never absence. Missing live key with retained history
        # is not a fresh state and must not be silently reinitialized.
        require(exc.response['Error']['Code'] in ('404','NoSuchKey'), 'backend state access unknown')
        versions = s3.list_object_versions(Bucket=args['Bucket'],Prefix=key,MaxKeys=100,ExpectedBucketOwner=args['ExpectedBucketOwner'])
        require(not versions.get('IsTruncated') and not any(v['Key']==key for k in ('Versions','DeleteMarkers') for v in versions.get(k,[])), 'state history exists; recovery needs review')
        return {'key':key,'version':None,'lineage':None,'serial':None,'sha256':None}
    require(head.get('VersionId') and 0 < head['ContentLength'] <= 2*1024*1024, 'versioned bounded state required')
    response = s3.get_object(**args,VersionId=head['VersionId'])
    raw = response['Body'].read(2*1024*1024+1)
    require(len(raw)==head['ContentLength'], 'state size changed')
    value = json.loads(raw)
    require(isinstance(value.get('serial'),int) and value.get('lineage'), 'invalid state lineage')
    return {'key':key,'version':head['VersionId'],'lineage':value['lineage'],'serial':value['serial'],'sha256':sha(raw)}

def role_name(config):
    ident=config['workspace_identity']; request=ident['request']; wid=request['workspace_id']
    suffix=sha(f"{config['aws_account_id']}/{config['aws_region']}/{ident['ml_project_name']}/{wid}".encode())[:10]
    return f"{config['resource_prefix'][:12]}-run-ws-{wid[:24]}-{suffix}"

def capacity(base,client,config):
    ec2=client(base,'ec2')
    images=ec2.describe_images(ImageIds=[config.get('ami_id','ami-03c3da4cfa8e8943a')],Owners=['137112412989'])['Images']
    require(len(images)==1 and images[0]['State']=='available' and images[0]['Architecture']=='x86_64'
            and images[0]['Name']=='al2023-ami-2023.12.20260930.0-kernel-6.1-x86_64'
            and images[0]['EnaSupport'],'reviewed AMI provenance/capability mismatch')
    info=ec2.describe_instance_types(InstanceTypes=['r8i.2xlarge'])['InstanceTypes'][0]
    require(info['VCpuInfo']['DefaultVCpus']==8 and info['MemoryInfo']['SizeInMiB']==65536,'capacity metadata mismatch')
    subnet=ec2.describe_subnets(SubnetIds=[config['subnet_id']])['Subnets'][0]
    require(subnet['AvailabilityZone']=='us-east-1a','reviewed subnet zone mismatch')
    offered=ec2.describe_instance_type_offerings(LocationType='availability-zone',Filters=[
        {'Name':'location','Values':[subnet['AvailabilityZone']]},{'Name':'instance-type','Values':['r8i.2xlarge']}])
    require(offered['InstanceTypeOfferings'] and not offered.get('NextToken'),'instance type not offered')
    security=ec2.describe_security_groups(GroupIds=[config['security_group_id']])['SecurityGroups'][0]
    require(security['VpcId']==subnet['VpcId'] and not security['IpPermissions'],'network must have no inbound rules')
    require(any(p['IpProtocol']=='-1' and any(r['CidrIp']=='0.0.0.0/0' for r in p.get('IpRanges',[])) for p in security['IpPermissionsEgress']),'reviewed outbound package/Git/SSM access missing')
    routes=ec2.describe_route_tables(Filters=[{'Name':'association.subnet-id','Values':[config['subnet_id']]}])
    require(not routes.get('NextToken') and len(routes['RouteTables'])==1 and any(r.get('DestinationCidrBlock')=='0.0.0.0/0'
            and r.get('GatewayId','').startswith('igw-') and r['State']=='active' for r in routes['RouteTables'][0]['Routes']),'reviewed public outbound route missing')
    quota=client(base,'service-quotas').get_service_quota(ServiceCode='ec2',QuotaCode='L-1216C47A')['Quota']['Value']
    active=ec2.describe_instances(Filters=[{'Name':'instance-state-name','Values':['pending','running','stopping','stopped','shutting-down']}],MaxResults=100)
    require(not active.get('NextToken'),'quota inventory incomplete')
    instances=[i for r in active['Reservations'] for i in r['Instances']]
    # Conservative standard-family ceiling includes stopped instances. Dedicated
    # host/reservation/other-family use is not silently discounted.
    types=sorted({i['InstanceType'] for i in instances})
    cpus={} if not types else {t['InstanceType']:t['VCpuInfo']['DefaultVCpus'] for t in ec2.describe_instance_types(InstanceTypes=types)['InstanceTypes']}
    require(quota-sum(cpus[i['InstanceType']] for i in instances)>=8,'remaining observed CPU quota cannot fit default; no silent fallback')
    return {'quota':quota,'account_instances':len(instances),'instance_type':'r8i.2xlarge','cpus':8,'memory_mb':65536,'capacity_available':'unverified'}

def bound_instance(base,client,config,instance_id):
    result=client(base,'ec2').describe_instances(InstanceIds=[instance_id])
    items=[i for r in result['Reservations'] for i in r['Instances']]
    require(len(items)==1,'instance lookup not unique')
    item=items[0]; tags={t['Key']:t['Value'] for t in item.get('Tags',[])}
    expected={'GuardId':config['guard']['guard_id'],'WorkspaceId':config['workspace_identity']['request']['workspace_id'],
              'LeaseId':config['lease']['id'],'ExpiresAt':config['lease']['expires_at'],'LeaseStart':config['lease']['starts_at'],
              'LaunchBefore':config['lease']['launch_before'],'ManagedBy':'opentofu','Project':config['project_name'],'Root':'runner'}
    require(all(tags.get(k)==v for k,v in expected.items()),'instance ownership/lease mismatch')
    require(item['ImageId']==config.get('ami_id','ami-03c3da4cfa8e8943a') and item['InstanceType']=='r8i.2xlarge'
            and item['SubnetId']==config['subnet_id'] and {s['GroupId'] for s in item['SecurityGroups']}=={config['security_group_id']}
            and item['IamInstanceProfile']['Arn']==f"arn:aws:iam::{config['aws_account_id']}:instance-profile/{role_name(config)}",'instance image/network/profile mismatch')
    require(item['State']['Name']=='running' and utc(config['lease']['starts_at'])<=dt.datetime.now(dt.timezone.utc)<utc(config['lease']['expires_at'])-dt.timedelta(minutes=5),'instance is not connectable within usable lease')
    return item

def connect(target_name,config_path,instance_id):
    config=read(config_path); ts=boundary['targets'](); require(target_name in ts,'unknown target')
    target=ts[target_name]; env=boundary['environment'](target); boundary['identity'](target,env)
    validate_config(config,target,'launch'); base,client,_=sessions(target)
    bound_instance(base,client,config,instance_id)
    bounded(90,lambda:observe_guard(base,client,config))
    server=client(base,'ssm').describe_instance_information(Filters=[{'Key':'InstanceIds','Values':[instance_id]}])
    require(len(server['InstanceInformationList'])==1 and server['InstanceInformationList'][0]['PingStatus']=='Online'
            and server['InstanceInformationList'][0]['AgentVersion']=='3.3.5226.0','SSM agent not online at reviewed version')
    require(run(['session-manager-plugin','--version'],env,10).strip()=='1.2.835.0','install pinned operator Session Manager plugin')
    require(run(['aws','--version'],env,10).startswith('aws-cli/2.36.14 '),'operator AWS CLI pin differs')
    argv=['aws','--profile',target['profile'],'--region',target['region'],'ssm','start-session','--target',instance_id,'--document-name',role_name(config)+'-terminal']
    os.dup2(3,0); os.close(3)
    os.execvpe(argv[0],argv,env)

def handoff(target_name,plan_directory,instance_id,output):
    directory=checked_path(plan_directory); m=read(directory/'review.json'); config=read(directory/'config.tfvars.json')
    require(m['stage']=='launch' and m['target_name']==target_name and read(directory/'apply-result.json')['status']=='success','successful exact launch receipt required')
    require(m['source']==source() and sha(canon(config))==m['config_sha256'],'launch source/config mismatch')
    require(read(directory/'launched-owned.json')['instance_id']==instance_id,'handoff differs from exact launched instance')
    target,env,base,client,identities,state=context(target_name,'launch',config)
    bound_instance(base,client,config,instance_id)
    observation,_=bounded(90,lambda:observe_guard(base,client,config))
    request=config['workspace_identity']['request']; common={k:request[k] for k in ('schema_version','provider','account_scope','region','workspace_id')}
    item={**common,'kind':'handoff','request_sha256':sha(canon(request)),'toolbox_profile':request['toolbox_profile'],
          'image_reference':config.get('ami_id','ami-03c3da4cfa8e8943a'),
          'bootstrap_sha256':sha(base64.b64decode(next(r['values']['user_data_base64'] for r in read(directory/'plan.json')['planned_values']['root_module']['resources'] if r['address']=='aws_instance.workspace[0]'))),
          'machine_id':instance_id,'user':'workspace','project_directory':'/workspaces/'+request['workspace_id'],
          'storage':request['storage'],'identity':{'mode':'instance_role','selector':f"arn:aws:iam::{target['account_id']}:role/{role_name(config)}"},
          'terminal':{'method':'ssm','argv':['aws','--profile',target['profile'],'--region',target['region'],'ssm','start-session','--target',instance_id,'--document-name',role_name(config)+'-terminal']},
          'lifetime':{'started_at':config['lease']['starts_at'],'expires_at':config['lease']['expires_at'],
                      'guard_active_at':m['guard_iam']['guard_active_at'],'guard_id':config['guard']['guard_id'],'expiry_action':'terminate'}}
    write(checked_path(output),item)
    run([sys.executable,'scripts/workspace/validate.py',str(directory/'request.json'),'--handoff',str(checked_path(output))],env,15)
    return {'handoff':str(checked_path(output).relative_to(REPO)),'native_workspace_ready':False}

def collect(target_name,plan_directory,handoff_path,guest_path,output):
    directory=checked_path(plan_directory); m=read(directory/'review.json'); config=read(directory/'config.tfvars.json')
    hand=read(handoff_path); guest=read(guest_path); request=config['workspace_identity']['request']
    require(m['stage']=='launch' and m['target_name']==target_name and m['source']==source(),'collector launch binding mismatch')
    require(read(directory/'apply-result.json')['status']=='success' and sha(canon(config))==m['config_sha256'],'collector requires exact successful launch')
    require(hand['machine_id']==read(directory/'launched-owned.json')['instance_id'],'readiness differs from exact launched instance')
    require(guest['request_sha256']==sha(canon(request)) and guest['handoff_sha256']==sha(canon(hand))
            and guest['machine_id']==hand['machine_id'] and guest['workspace_id']==request['workspace_id'],'guest record binding mismatch')
    require(0 <= (dt.datetime.now(dt.timezone.utc)-utc(guest['observed_at'])).total_seconds() <= 120,'guest record stale')
    require(guest['toolbox_zip_sha256']==config['toolbox_zip_sha256'] and guest['uid']>0 and guest['user']=='workspace','guest bootstrap/run-as mismatch')
    target,env,base,client,identities,state=context(target_name,'launch',config)
    machine=bound_instance(base,client,config,hand['machine_id']); observation,details=bounded(90,lambda:observe_guard(base,client,config))
    require(details==m['guard_iam'],'native IAM/profile/document changed')
    ssm=client(base,'ssm'); server=ssm.describe_instance_information(Filters=[{'Key':'InstanceIds','Values':[hand['machine_id']]}])['InstanceInformationList']
    require(len(server)==1 and server[0]['PingStatus']=='Online' and server[0]['AgentVersion']=='3.3.5226.0','server agent pin/offline')
    sessions=ssm.describe_sessions(State='Active',Filters=[{'key':'SessionId','value':guest['session_id']}])
    require(not sessions.get('NextToken') and len(sessions['Sessions'])==1,'terminal session observation incomplete')
    terminal=sessions['Sessions'][0]
    require(terminal['Target']==hand['machine_id'] and terminal['Owner']==target['operator_arn']
            and terminal['DocumentName']==role_name(config)+'-terminal','terminal operator/document/instance mismatch')
    facts=guest['facts']; require(facts['non_root'] and facts['project_directory_writable'] and not facts['missing_tools'],'guest toolbox failed')
    require(guest['instance_role_arn']==f"arn:aws:sts::{target['account_id']}:assumed-role/{role_name(config)}/{hand['machine_id']}",'guest native identity mismatch')
    require(facts['versions']['python']=='3.13.15' and facts['versions']['git']=='git version 2.50.1'
            and facts['versions']['uv']=='uv 0.12.23' and facts['versions']['storage_cli'].startswith('aws-cli/2.36.14 ')
            and facts['sdk_versions']['boto3']=='1.43.109','observed toolbox pins mismatch')
    require(guest['state_denied'] is True and guest['unrelated_denied'] is True and guest['output_read_observed'] is True,'native storage evidence incomplete')
    versions=dict(facts['versions'],storage_sdk='boto3 '+facts['sdk_versions']['boto3'])
    evidence=str(checked_path(guest_path).relative_to(REPO)); native=str(checked_path(output).with_suffix('.native.json').relative_to(REPO))
    common={k:request[k] for k in ('schema_version','provider','account_scope','region','workspace_id')}
    result={**common,'kind':'readiness','request_sha256':sha(canon(request)),'handoff_sha256':sha(canon(hand)),
            'observed_at':stamp(),'resources':facts['resources'],'versions':versions,
            'checks':{key:{'status':'pass','evidence':evidence if key in ('toolbox','writable_project','storage','state_denied','unrelated_denied','identity') else native}
                      for key in ('toolbox','terminal','identity','storage','state_denied','unrelated_denied','profile','deadline','writable_project')}}
    write(REPO/native,{'observed_at':stamp(),'guard':observation,'iam':details,'terminal':{'session_id':terminal['SessionId'],'owner':terminal['Owner'],'document':terminal['DocumentName'],'target':terminal['Target']},'server_agent_version':server[0]['AgentVersion']})
    write(checked_path(output),result)
    run([sys.executable,'scripts/workspace/validate.py',str(directory/'request.json'),'--handoff',str(checked_path(handoff_path)),
         '--readiness',str(checked_path(output)),'--require-ready'],env,15)
    return {'readiness':str(checked_path(output).relative_to(REPO)),'native_workspace_ready':True}

def schedule_matches(value, config, kind):
    guard=config['guard']; name=role_name(config)
    event={'kind':'sweep','guard_id':guard['guard_id']} if kind=='sweep' else {
        'kind':'lease','guard_id':guard['guard_id'],'workspace_id':config['workspace_identity']['request']['workspace_id'],'lease_id':config['lease']['id']}
    expression='rate(1 minute)' if kind=='sweep' else 'at('+stamp(utc(config['lease']['expires_at'])-dt.timedelta(minutes=5)).removesuffix('Z')+')'
    target=value['Target']
    return (value['State']=='ENABLED' and value['ScheduleExpression']==expression and value['FlexibleTimeWindow']['Mode']=='OFF'
            and value.get('ScheduleExpressionTimezone')=='UTC' and value.get('ActionAfterCompletion')=='NONE'
            and value.get('StartDate') is None and value.get('EndDate') is None
            and target['Arn']==guard['function_arn'] and target['RoleArn']==guard['invoker_role_arn']
            and json.loads(target['Input'])==event and target['RetryPolicy']=={'MaximumEventAgeInSeconds':300,'MaximumRetryAttempts':3}
            and target['DeadLetterConfig']['Arn']==guard['failure_queue_arn'])

def guard_policies(config):
    guard=config['guard']; account=config['aws_account_id']; region=config['aws_region']
    execution={'Version':'2012-10-17','Statement':[
        {'Effect':'Allow','Action':'ec2:DescribeInstances','Resource':'*'},
        {'Effect':'Allow','Action':'ec2:TerminateInstances','Resource':f'arn:aws:ec2:{region}:{account}:instance/*',
         'Condition':{'StringEquals':{'ec2:ResourceTag/GuardId':guard['guard_id'],'ec2:ResourceTag/ManagedBy':'opentofu',
                                     'ec2:ResourceTag/Project':config['project_name'],'ec2:ResourceTag/Root':'runner'}}},
        {'Effect':'Allow','Action':['logs:CreateLogStream','logs:PutLogEvents'],
         'Resource':f"arn:aws:logs:{region}:{account}:log-group:{guard['log_group']}:*"},
        {'Effect':'Allow','Action':'sqs:SendMessage','Resource':guard['failure_queue_arn']},
        {'Effect':'Deny','NotAction':['ec2:DescribeInstances','ec2:TerminateInstances','logs:CreateLogStream','logs:PutLogEvents','sqs:SendMessage'],'Resource':'*'}]}
    invoker={'Version':'2012-10-17','Statement':[
        {'Effect':'Allow','Action':'lambda:InvokeFunction','Resource':guard['function_arn']},
        {'Effect':'Allow','Action':'sqs:SendMessage','Resource':guard['failure_queue_arn']},
        {'Effect':'Deny','NotAction':['lambda:InvokeFunction','sqs:SendMessage'],'Resource':'*'}]}
    return execution, invoker

ALARM_FIELDS={'namespace':'Namespace','metric_name':'MetricName','statistic':'Statistic','period':'Period',
              'evaluation_periods':'EvaluationPeriods','threshold':'Threshold','comparison_operator':'ComparisonOperator',
              'treat_missing_data':'TreatMissingData','alarm_actions':'AlarmActions','actions_enabled':'ActionsEnabled'}

def alarm_record(alarm):
    return {**{k:alarm.get(v) for k,v in ALARM_FIELDS.items()},
            'dimensions':{item['Name']:item['Value'] for item in alarm.get('Dimensions',[])}}

def compare_platform_alarms(plan,details):
    expected={r['values']['alarm_name']:{**{k:r['values'][k] for k in ALARM_FIELDS},'dimensions':r['values'].get('dimensions') or {}}
              for r in plan['planned_values']['root_module']['resources']
              if r['address'].startswith('aws_cloudwatch_metric_alarm.workspace_guard')}
    require(len(expected)==4 and details['alarms']==expected,'guard alarm settings differ from exact reviewed platform plan')

def shared_lambda_pool(base, client):
    limits=client(base,'lambda').get_account_settings()['AccountLimit']
    require(limits['ConcurrentExecutions']>=5 and limits['UnreservedConcurrentExecutions']>=5,
            'reviewed shared Lambda pool is unavailable')
    return {key:limits[key] for key in ('ConcurrentExecutions','UnreservedConcurrentExecutions')}

def observe_guard(base, client, config):
    guard=config['guard']; scheduler=client(base,'scheduler'); iam=client(base,'iam')
    function=client(base,'lambda').get_function_configuration(FunctionName=guard['function_arn'])
    require(function['State']=='Active' and function['LastUpdateStatus']=='Successful' and
            base64.b64decode(function['CodeSha256']).hex()==guard['code_sha256'], 'guard function mismatch')
    require(function['Runtime']=='python3.13' and function['Timeout']==30 and function['Handler']=='watchdog.handler'
            and function['Environment']['Variables']=={'GUARD_ID':guard['guard_id'],'OWNER_PROJECT':config['project_name'],
                                                      'ACCOUNT_ID':config['aws_account_id'],'CODE_SHA256':guard['code_sha256']},'guard execution environment mismatch')
    require('ReservedConcurrentExecutions' not in client(base,'lambda').get_function_concurrency(FunctionName=guard['function_arn'].rsplit(':',1)[0]),'unexpected guard concurrency reservation')
    quota=shared_lambda_pool(base,client)
    invoke=client(base,'lambda').get_function_event_invoke_config(FunctionName=guard['function_arn'].rsplit(':',1)[0],Qualifier=guard['function_arn'].rsplit(':',1)[1])
    require(invoke['MaximumEventAgeInSeconds']==300 and invoke['MaximumRetryAttempts']==2
            and invoke['DestinationConfig']['OnFailure']['Destination']==guard['failure_queue_arn'],'guard asynchronous failure configuration mismatch')
    recurring=scheduler.get_schedule(Name=guard['recurring_schedule_name'],GroupName='default')
    deadline=scheduler.get_schedule(Name=role_name(config)+'-deadline',GroupName='default')
    require(schedule_matches(recurring,config,'sweep') and schedule_matches(deadline,config,'lease'),'inactive/mismatched schedule')
    armed_at=max(recurring['CreationDate'],deadline['CreationDate'])
    require(armed_at<=utc(config['lease']['starts_at']),'guard/deadline were not armed before earliest launch')
    # Capture all role trust/inline/attached policy versions, profile and document
    # for exact review and subsequent drift checks. IAM eventual visibility gets
    # six bounded read attempts, never an unconditional sleep-before-launch.
    role_records={}
    names=[guard['invoker_role_arn'].rsplit('/',1)[1],function['Role'].rsplit('/',1)[1],role_name(config),role_name(config)+'-launch']
    for name in names:
        info=iam.get_role(RoleName=name)['Role']
        inline=iam.list_role_policies(RoleName=name)
        attached=iam.list_attached_role_policies(RoleName=name)
        require(not inline.get('IsTruncated') and not attached.get('IsTruncated'),'IAM listing incomplete')
        policies={n:iam.get_role_policy(RoleName=name,PolicyName=n)['PolicyDocument'] for n in inline['PolicyNames']}
        expected_names = ({'invoke-pinned-watchdog'} if name==names[0] else {'guard-owned-termination-only'} if name==names[1]
                          else {'workspace-storage'} if name==names[2] else {'immutable-lease-launch'})
        require(set(policies)==expected_names,'unexpected or missing inline IAM policy')
        expected_attached=[config['workspace_identity']['session_policy_arn']] if name==names[2] else []
        require(sorted(p['PolicyArn'] for p in attached['AttachedPolicies'])==sorted(expected_attached),'unexpected attached IAM policy')
        expected_boundary=(config['workspace_identity']['permissions_boundary_arn'] if name==names[2] else
                           f"arn:aws:iam::{config['aws_account_id']}:policy/{config['resource_prefix']}-workspace-launch-boundary" if name==names[3] else None)
        require(info.get('PermissionsBoundary',{}).get('PermissionsBoundaryArn')==expected_boundary,'IAM permissions boundary mismatch')
        boundary_policy=None
        if expected_boundary:
            boundary_info=iam.get_policy(PolicyArn=expected_boundary)['Policy']
            boundary_policy=iam.get_policy_version(PolicyArn=expected_boundary,VersionId=boundary_info['DefaultVersionId'])['PolicyVersion']['Document']
        managed={}
        for item in attached['AttachedPolicies']:
            policy=iam.get_policy(PolicyArn=item['PolicyArn'])['Policy']
            managed[item['PolicyArn']]=iam.get_policy_version(PolicyArn=item['PolicyArn'],VersionId=policy['DefaultVersionId'])['PolicyVersion']['Document']
        role_records[name]={'trust':info['AssumeRolePolicyDocument'],'boundary':info.get('PermissionsBoundary'),'boundary_policy':boundary_policy,'inline':policies,'attached':managed}
    execution_policy, invoker_policy=guard_policies(config)
    require(role_records[names[0]]['inline']['invoke-pinned-watchdog']==invoker_policy
            and role_records[names[1]]['inline']['guard-owned-termination-only']==execution_policy,'guard IAM no longer matches reviewed termination/invocation scope')
    expected_execution_trust={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sts:AssumeRole','Principal':{'Service':'lambda.amazonaws.com'}}]}
    expected_invoker_trust={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sts:AssumeRole','Principal':{'Service':'scheduler.amazonaws.com'},
        'Condition':{'StringEquals':{'aws:SourceAccount':config['aws_account_id']},'ArnEquals':{'aws:SourceArn':f"arn:aws:scheduler:{config['aws_region']}:{config['aws_account_id']}:schedule-group/default"}}}]}
    require(role_records[names[0]]['trust']==expected_invoker_trust and role_records[names[1]]['trust']==expected_execution_trust,'guard Scheduler/Lambda trust differs from source')
    profile=iam.get_instance_profile(InstanceProfileName=role_name(config))['InstanceProfile']
    require([r['RoleName'] for r in profile['Roles']]==[role_name(config)], 'profile is not exact runtime role')
    tag_values={t['Key']:t['Value'] for t in iam.list_user_tags(UserName='sposhfi-admin')['Tags']}
    require(tag_values.get('SSMSessionRunAs','workspace')=='workspace','operator run-as override differs')
    doc=client(base,'ssm').get_document(Name=role_name(config)+'-terminal',DocumentVersion='$DEFAULT')
    inputs=json.loads(doc['Content'])['inputs']
    require(inputs['runAsEnabled'] and inputs['runAsDefaultUser']=='workspace','terminal run-as mismatch')
    alarms=client(base,'cloudwatch').describe_alarms(AlarmNames=guard['alarm_names'])
    require(not alarms.get('NextToken') and {a['AlarmName'] for a in alarms['MetricAlarms']}==set(guard['alarm_names'])
            and all(a['StateValue']=='OK' and a['ActionsEnabled'] and a['AlarmActions'] for a in alarms['MetricAlarms']), 'guard alarms not healthy')
    now=dt.datetime.now(dt.timezone.utc)
    events=client(base,'logs').filter_log_events(logGroupName=guard['log_group'],startTime=int((now-dt.timedelta(seconds=120)).timestamp()*1000),
        filterPattern='{ $.kind = "heartbeat" }',limit=100)
    require(not events.get('nextToken'),'heartbeat listing incomplete')
    matches=[]
    for event in events['events']:
        item=json.loads(event['message'])
        if item.get('kind')=='heartbeat' and all(item.get(k)==v for k,v in {
            'guard_id':guard['guard_id'],'code_sha256':guard['code_sha256'],'account':config['aws_account_id'],'region':config['aws_region']}.items()):
            if 0 <= (now-utc(item['observed_at'])).total_seconds() <= 120: matches.append(item['observed_at'])
    require(matches,'no matching fresh completed sweep heartbeat')
    details={'roles':role_records,'alarms':{a['AlarmName']:alarm_record(a) for a in alarms['MetricAlarms']},'lambda_account_limits':quota,'guard_active_at':stamp(armed_at),'profile_roles':[r['Arn'] for r in profile['Roles']],
             'document_sha256':sha(canon(json.loads(doc['Content'])))}
    return {'observed_at':stamp(now),'heartbeat_at':max(matches),'guard_id':guard['guard_id'],'code_sha256':guard['code_sha256'],
            'recurrence_enabled':True,'deadline_enabled':True,'iam_verified':True,'alarms_ok':True},details

def compare_prepared_iam(plan, details, config):
    resources={r['address']:r['values'] for r in plan['planned_values']['root_module']['resources']}
    role=role_name(config); wid=config['workspace_identity']['request']['workspace_id']
    for address,name,policy_address in [
        (f'aws_iam_role.workspace["{wid}"]',role,f'aws_iam_role_policy.workspace_storage["{wid}"]'),
        ('aws_iam_role.launch',role+'-launch','aws_iam_role_policy.launch')]:
        planned=resources[address]; observed=details['roles'][name]
        require(json.loads(planned['assume_role_policy'])==observed['trust'],'prepared trust differs from source plan')
        require(list(observed['inline'].values())==[json.loads(resources[policy_address]['policy'])],'prepared permissions differ from source plan')
    require(sha(canon(json.loads(resources['aws_ssm_document.terminal']['content'])))==details['document_sha256'],'prepared terminal differs from source plan')

def validate_config(config, target, stage):
    require(config['aws_account_id']==target['account_id'] and config['aws_region']==target['region'],'config target mismatch')
    require(config['resource_prefix']==target['inventory']['resource_prefix'],'ownership prefix mismatch')
    require(config['project_name']==target['inventory']['resource_prefix'], 'reviewed ownership project mismatch')
    require(config['state_bucket_arn']=='arn:aws:s3:::'+target['backend']['bucket'],'state bucket mismatch')
    if stage=='platform':
        require(config.get('workspace_guard') is not None,'platform guard cannot be disabled by workspace workflow')
        return
    require(config['deployer_role_arn']==target['deployment_role_arn'] and config['backend_bucket_name']==target['backend']['bucket'],'runner context mismatch')
    require(config['phase']==('retire' if stage in ('retire','cleanup') else stage),'stage mismatch')
    request=config['workspace_identity']['request']
    require(request['account_scope']==target['account_id'] and request['region']==target['region'] and
            request['operators']==[target['operator_arn']],'request operator/target mismatch')
    require(config.get('instance_type','r8i.2xlarge')=='r8i.2xlarge' and config.get('ami_id','ami-03c3da4cfa8e8943a')=='ami-03c3da4cfa8e8943a','reviewed capacity/image mismatch')
    require(request['storage']['state_uri']==f"s3://{target['backend']['bucket']}/{target['backend']['runner_prefix']}{request['workspace_id']}.tfstate",'workspace state key mismatch')
    for key in ('starts_at','launch_before','expires_at'): utc(config['lease'][key])
    require(utc(config['lease']['starts_at']) < utc(config['lease']['launch_before']) <= utc(config['lease']['starts_at'])+dt.timedelta(minutes=5),'invalid launch window')
    require(utc(config['lease']['expires_at'])==utc(config['lease']['starts_at'])+dt.timedelta(minutes=request['maximum_runtime_minutes']),'lease extends/shortens request')

def plan_scope(plan, stage):
    mutations=[]
    for item in plan.get('resource_changes',[]):
        actions=item['change']['actions']; address=item['address']
        if actions in (['no-op'],['read']): continue
        require(item.get('mode')=='managed','unexpected mutation')
        if stage=='platform':
            require('delete' not in actions,'platform deletion forbidden')
            require(('workspace_guard' in address or address.startswith(('aws_s3_bucket.project[','aws_s3_bucket_versioning.project[','aws_s3_bucket_server_side_encryption_configuration.project[','aws_s3_bucket_public_access_block.project[','aws_s3_bucket_ownership_controls.project[','aws_s3_bucket_policy.project[','aws_iam_policy.project_workspace_boundary[','aws_iam_policy.workspace_launch_boundary['))
                     or address=='aws_iam_role_policy.deployer') and not ('workload' in address), 'unreviewed platform mutation: '+address)
        elif stage=='launch':
            require(address=='aws_instance.workspace[0]' and actions==['create'],'launch must create only its prepared EC2/root volume')
            after=item['change']['after']
            require(after['instance_type']=='r8i.2xlarge' and after['ami']=='ami-03c3da4cfa8e8943a' and not after.get('key_name') and not after.get('disable_api_termination'),'unsafe launch values')
            require(len(base64.b64decode(after['user_data_base64'])) <= 16384,'EC2 user-data exceeds limit')
            root=after['root_block_device'][0]; metadata=after['metadata_options'][0]
            require(root['encrypted'] and root['delete_on_termination'] and root['volume_size']==30 and
                    metadata['http_tokens']=='required' and metadata['http_put_response_hop_limit']==1,'unsafe disk/metadata')
        elif stage=='prepare':
            require(item['type'] in ('terraform_data','aws_iam_role','aws_iam_role_policy','aws_iam_role_policy_attachment','aws_iam_instance_profile','aws_iam_user_policy','aws_ssm_document','aws_scheduler_schedule') and actions==['create'],'preparation cannot mutate existing resources or launch compute')
        elif stage=='retire':
            require((address=='aws_instance.workspace[0]' and actions==['delete']) or (address=='aws_iam_role_policy.launch' and actions==['update']),'retirement must revoke launch and terminate only owned EC2')
        else:
            require(item['type'] in ('terraform_data','aws_iam_role','aws_iam_role_policy','aws_iam_role_policy_attachment','aws_iam_instance_profile','aws_iam_user_policy','aws_ssm_document','aws_scheduler_schedule') and actions==['delete'],'cleanup cannot delete storage, guard or compute')
        mutations.append({'address':address,'actions':actions})
    require(mutations,'empty plan has no mutation scope')
    return mutations

def context(target_name, stage, config):
    ts=boundary['targets'](); require(target_name in ts,'unknown target')
    target=ts[target_name]; env=boundary['environment'](target); operator=boundary['identity'](target,env)
    validate_config(config,target,stage)
    base,client,assume=sessions(target)
    identities={'cli':operator,'sdk_operator':target['operator_arn'],'backend':target['operator_arn']}
    if stage!='platform':
        deployer,identities['sdk_deployer']=assume(base,target['deployment_role_arn'])
        if stage=='launch': _,identities['sdk_launch']=assume(deployer,f"arn:aws:iam::{target['account_id']}:role/{role_name(config)}-launch")
    else: identities['provider']=target['operator_arn']
    key=target['backend']['platform_key'] if stage=='platform' else target['backend']['runner_prefix']+config['workspace_identity']['request']['workspace_id']+'.tfstate'
    state=snapshot(base,client,target,key)
    return target,env,base,client,identities,state

def inventory(base,client,config):
    filters=[{'Name':'tag:'+k,'Values':[v]} for k,v in {
        'GuardId':config['guard']['guard_id'],'WorkspaceId':config['workspace_identity']['request']['workspace_id'],'LeaseId':config['lease']['id']}.items()]
    result=client(base,'ec2').describe_instances(Filters=filters,MaxResults=100)
    require(not result.get('NextToken'),'inventory incomplete')
    items=[i for r in result['Reservations'] for i in r['Instances']]
    live=[i for i in items if i['State']['Name']!='terminated']
    require(not live,'covered compute still remains; guard/deadline/profile must be retained')
    for operation in ('describe_volumes','describe_network_interfaces'):
        page=getattr(client(base,'ec2'),operation)(Filters=filters,MaxResults=100)
        require(not page.get('NextToken') and not page.get('Volumes',page.get('NetworkInterfaces',[])),'owned disk/interface remains; separate exact orphan review required')
    return {'observed_at':stamp(),'covered_instances':len(items),'live_compute':0,'owned_volumes':0,'owned_interfaces':0,'elastic_ips_created':False}

def remaining_owned(base,client,owned):
    ec2=client(base,'ec2')
    try:
        response=ec2.describe_instances(InstanceIds=[owned['instance_id']])
        require(all(i['State']['Name']=='terminated' for r in response['Reservations'] for i in r['Instances']),'reviewed instance remains')
    except ec2.exceptions.ClientError as exc:
        require(exc.response['Error']['Code']=='InvalidInstanceID.NotFound','instance absence unknown')
    for operation,parameter,ids,missing in [
        ('describe_volumes','VolumeIds',owned['volume_ids'],'InvalidVolume.NotFound'),
        ('describe_network_interfaces','NetworkInterfaceIds',[owned['interface_id']],'InvalidNetworkInterfaceID.NotFound')]:
        for id in ids:
            try:
                response=getattr(ec2,operation)(**{parameter:[id]})
                require(not response.get('Volumes',response.get('NetworkInterfaces',[])),'reviewed owned disk/interface remains')
            except ec2.exceptions.ClientError as exc:
                require(exc.response['Error']['Code']==missing,'owned resource absence unknown')

def platform_compute_absent(base,client,config):
    guard_id=sha(f"{config['aws_account_id']}/{config['aws_region']}/{config['resource_prefix']}/workspace-v1".encode())[:32]
    page=client(base,'ec2').describe_instances(Filters=[{'Name':'tag:'+k,'Values':[v]} for k,v in {
        'GuardId':guard_id,'Project':config['project_name'],'Root':'runner','ManagedBy':'opentofu'}.items()],MaxResults=100)
    require(not page.get('NextToken') and all(i['State']['Name']=='terminated' for r in page['Reservations'] for i in r['Instances']),
            'covered compute remains; persistent guard may not be updated or retired')

def alarm_destination(base,client,config):
    topic=config['workspace_guard']['alarm_topic_arn']
    attributes=client(base,'sns').get_topic_attributes(TopicArn=topic)['Attributes']
    require(attributes.get('TopicArn')==topic and attributes.get('Owner')==config['aws_account_id']
            and int(attributes.get('SubscriptionsConfirmed','0'))>0,'alarm destination must exist with a confirmed subscription in reviewed account')

def native_plan(target_name,stage,config_path,directory,dependency=None):
    directory=checked_path(directory); require(not directory.exists(),'plan directory already exists')
    config=read(config_path)
    dependencies=[]
    if stage in ('prepare','launch','cleanup') or (stage=='retire' and dependency):
        require(dependency is not None,'this stage requires its exact successful prior apply receipt')
        dep=checked_path(dependency); prior=read(dep/'review.json'); receipt=read(dep/'apply-result.json')
        require(prior['target_name']==target_name and prior['stage']=={'prepare':'platform','launch':'prepare','retire':'launch','cleanup':'retire'}[stage]
                and receipt['status']=='success' and prior['source']==source(),'dependency target/stage/source/apply mismatch')
        if stage!='prepare':
            old=read(dep/'config.tfvars.json')
            require(old['lease']==config['lease'] and old['workspace_identity']==config['workspace_identity'] and old['guard']==config['guard'],'dependency workspace/lease/guard mismatch')
        else:
            platform_config=read(dep/'config.tfvars.json')
            require(config['guard']['code_sha256']==platform_config['workspace_guard']['zip_sha256'],'runner guard code differs from exact platform artifact')
        dependencies=[{'directory':str(dep),'review_sha256':sha(canon(prior)),'receipt_sha256':sha(canon(receipt))}]
    target,env,base,client,identities,state=context(target_name,stage,config)
    if stage=='platform': verify_artifact(config['workspace_guard']['zip_path'],config['workspace_guard']['zip_sha256'],'guard')
    else: verify_artifact(config['toolbox_zip_path'],config['toolbox_zip_sha256'],'toolbox')
    if stage=='platform':
        platform_compute_absent(base,client,config); alarm_destination(base,client,config); shared_lambda_pool(base,client)
    details=None
    if stage=='launch':
        capacity_result=capacity(base,client,config)
        deadline=time.monotonic()+90
        for attempt in range(6):
            try: config['guard_observation'],details=bounded(max(0.01,deadline-time.monotonic()),lambda:observe_guard(base,client,config)); break
            except Exception as exc:
                if attempt==5 or time.monotonic()>=deadline: raise Failure('guard/IAM observation failed after six bounded attempts') from None
                time.sleep(2)
        require(utc(config['lease']['starts_at'])<=dt.datetime.now(dt.timezone.utc)<utc(config['lease']['launch_before']),'lease not open')
    if stage=='cleanup':
        inventory(base,client,config)
        remaining_owned(base,client,read(checked_path(dependency)/'retired-owned.json'))
    directory.mkdir(parents=True,mode=0o700)
    write(directory/'config.tfvars.json',config)
    backend={'bucket':target['backend']['bucket'],'key':state['key'],'region':target['region'],'profile':target['profile'],
             'allowed_account_ids':[target['account_id']],'encrypt':True,'use_lockfile':True}
    write(directory/'backend.json',backend)
    root=REPO/('infra/aws/platform' if stage=='platform' else 'infra/aws/runner/workspace')
    require(not any(root.glob('*.auto.tfvars*')) and not (root/'terraform.tfvars').exists(),'implicit root configuration rejected')
    env.update(TF_DATA_DIR=str(directory/'tofu-data'))
    for key in list(env):
        if key.startswith('TF_VAR_'): del env[key]
    run(['tofu',f'-chdir={root}','init','-input=false','-lockfile=readonly',f'-backend-config={directory}/backend.json','-no-color'],env)
    run(['tofu',f'-chdir={root}','validate','-no-color'],env)
    command=['tofu',f'-chdir={root}','plan','-input=false','-lock-timeout=30s','-no-color',f'-var-file={directory}/config.tfvars.json',f'-out={directory}/saved.tfplan']
    if stage=='cleanup': command.append('-destroy')
    run(command,env,240)
    raw=run(['tofu',f'-chdir={root}','show','-json',str(directory/'saved.tfplan')],env,60)
    plan=json.loads(raw); scope=plan_scope(plan,stage)
    if stage=='launch':
        compare_prepared_iam(plan,details,config)
        preparation=read(checked_path(dependency)/'review.json')
        platform_plan=read(Path(preparation['dependencies'][0]['directory'])/'plan.json')
        compare_platform_alarms(platform_plan,details)
        boundary_resource=next(r for r in platform_plan['planned_values']['root_module']['resources'] if r['address']=='aws_iam_policy.workspace_launch_boundary["active"]')
        require(json.loads(boundary_resource['values']['policy'])==details['roles'][role_name(config)+'-launch']['boundary_policy'],
                'launch boundary differs from exact reviewed platform policy')
    (directory/'plan.json').write_text(raw)
    artifacts={}
    paths=[config['workspace_guard']['zip_path']] if stage=='platform' else [config['toolbox_zip_path']]
    if stage!='platform':
        write(directory/'request.json',config['workspace_identity']['request'])
        run([sys.executable,'scripts/workspace/validate.py',str(directory/'request.json')],env,15)
    for path in paths: artifacts[str(checked_path(path))]=sha(checked_path(path).read_bytes())
    manifest={'target_name':target_name,'target':target,'stage':stage,'source':source(),'root':str(root),
              'identities':identities,'backend':backend,'state':state,'config_sha256':sha(canon(config)),
              'plan_sha256':sha((directory/'saved.tfplan').read_bytes()),'plan_json_sha256':sha(raw.encode()),
              'lock_sha256':sha((root/'.terraform.lock.hcl').read_bytes()),'tofu_version':json.loads(run(['tofu','version','-json'],env,10))['terraform_version'],
              'artifacts':artifacts,'guard_observation':config.get('guard_observation'),'guard_iam':details,'scope':scope,
              'dependencies':dependencies,
              'created_at':stamp(),'deployment_authorized':False}
    write(directory/'review.json',manifest)
    return {'evidence':str(directory.relative_to(REPO)),'review_sha256':sha(canon(manifest)),'scope':scope,'deployment_authorized':False}

def authorize(directory,expected,approval):
    directory=checked_path(directory); manifest=read(directory/'review.json')
    require(expected==sha(canon(manifest)) and len(approval.strip())>=12,'explicit exact review hash and approval statement required')
    write(directory/'authorization.json',{'review_sha256':expected,'plan_sha256':manifest['plan_sha256'],'scope':manifest['scope'],
                                         'approved_at':stamp(),'approval':approval,'single_use':True})
    return {'authorized_review_sha256':expected,'applied':False}

def apply(directory):
    directory=checked_path(directory); m=read(directory/'review.json'); authorization=read(directory/'authorization.json'); config=read(directory/'config.tfvars.json')
    require(authorization['review_sha256']==sha(canon(m)) and authorization['plan_sha256']==m['plan_sha256'] and authorization['scope']==m['scope'],'authorization does not bind exact saved plan')
    require(not (directory/'apply-started.json').exists(),'single-use authorization consumed; partial apply needs fresh inventory/plan/review')
    require(source()==m['source'] and sha(canon(config))==m['config_sha256'],'source/config drift')
    for dep in m['dependencies']:
        require(sha(canon(read(Path(dep['directory'])/'review.json')))==dep['review_sha256'] and
                sha(canon(read(Path(dep['directory'])/'apply-result.json')))==dep['receipt_sha256'],'dependency receipt changed')
    for p,h in m['artifacts'].items(): require(sha(checked_path(p).read_bytes())==h,'artifact changed')
    require(sha((directory/'saved.tfplan').read_bytes())==m['plan_sha256'] and sha((directory/'plan.json').read_bytes())==m['plan_json_sha256'],'saved plan changed')
    require(plan_scope(read(directory/'plan.json'),m['stage'])==m['scope'],'plan scope drift')
    require(sha((Path(m['root'])/'.terraform.lock.hcl').read_bytes())==m['lock_sha256'],'provider lock drift')
    target,env,base,client,identities,state=context(m['target_name'],m['stage'],config)
    require(target==m['target'] and identities==m['identities'] and state==m['state'],'target/identity/backend state changed; replan and review')
    if m['stage']=='platform':
        platform_compute_absent(base,client,config); alarm_destination(base,client,config); shared_lambda_pool(base,client)
    if m['stage']=='launch':
        observation,details=bounded(90,lambda:observe_guard(base,client,config))
        require(details==m['guard_iam'],'guard/IAM/document drift')
        require(0 <= (dt.datetime.now(dt.timezone.utc)-utc(m['guard_observation']['observed_at'])).total_seconds()<=120,'saved launch observation stale; fresh exact plan/review required')
        require(utc(config['lease']['starts_at'])<=dt.datetime.now(dt.timezone.utc)<utc(config['lease']['launch_before']),'lease closed')
    if m['stage']=='cleanup':
        absence=inventory(base,client,config)
        remaining_owned(base,client,read(Path(m['dependencies'][0]['directory'])/'retired-owned.json'))
        write(directory/'absence.json',absence)
    env.update(TF_DATA_DIR=str(directory/'tofu-data'))
    require(json.loads(run(['tofu','version','-json'],env,10))['terraform_version']==m['tofu_version'],'OpenTofu version drift')
    for k in list(env):
        if k.startswith('TF_VAR_'): del env[k]
    if m['stage']=='retire':
        before=next((r['change']['before'] for r in read(directory/'plan.json')['resource_changes'] if r['address']=='aws_instance.workspace[0]'),None)
        if before:
            owned={'instance_id':before['id'],'volume_ids':[v['volume_id'] for v in before['root_block_device']],
                   'interface_id':before['primary_network_interface_id'],'workspace_id':config['workspace_identity']['request']['workspace_id'],'lease_id':config['lease']['id']}
        else:
            require(m['dependencies'],'already expired compute requires its exact launch ownership receipt')
            owned=read(Path(m['dependencies'][0]['directory'])/'launched-owned.json')
            require(owned['lease_id']==config['lease']['id'],'launch ownership lease mismatch')
        write(directory/'retired-owned.json',owned)
    write(directory/'apply-started.json',{'review_sha256':authorization['review_sha256'],'started_at':stamp()})
    # Never replan, autoapprove a fresh plan, destroy directly, or replay after
    # interruption. Raw provider diagnostics stay out of terminal/chat logs.
    run(['tofu',f"-chdir={m['root']}",'apply','-input=false','-lock-timeout=30s','-no-color',str(directory/'saved.tfplan')],env,300)
    if m['stage']=='launch':
        value=json.loads(run(['tofu',f"-chdir={m['root']}",'output','-json','workspace_preparation'],env,30))
        instance=bound_instance(base,client,config,value['instance_id'])
        write(directory/'launched-owned.json',{'instance_id':instance['InstanceId'],
            'volume_ids':[b['Ebs']['VolumeId'] for b in instance['BlockDeviceMappings']],
            'interface_id':next(n['NetworkInterfaceId'] for n in instance['NetworkInterfaces'] if n['Attachment']['DeviceIndex']==0),
            'workspace_id':config['workspace_identity']['request']['workspace_id'],'lease_id':config['lease']['id']})
    write(directory/'apply-result.json',{'status':'success','completed_at':stamp(),'native_workspace_ready':False})
    return {'status':'success','evidence':str(directory.relative_to(REPO)),'native_workspace_ready':False}

def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description='AWS workspace exact-plan lifecycle; cloud mutation only through explicitly authorized saved apply.')
    sub=parser.add_subparsers(dest='verb',required=True)
    p=sub.add_parser('build'); p.add_argument('directory')
    p=sub.add_parser('lease'); p.add_argument('request'); p.add_argument('starts_at'); p.add_argument('output')
    p=sub.add_parser('packet'); p.add_argument('target'); p.add_argument('--storage-directory',required=True); p.add_argument('--artifacts',required=True); p.add_argument('--platform-config',required=True); p.add_argument('--alarm-topic',required=True); p.add_argument('--output',required=True)
    p=sub.add_parser('outputs'); p.add_argument('target'); p.add_argument('plan_directory'); p.add_argument('--output',required=True)
    p=sub.add_parser('plan'); p.add_argument('target'); p.add_argument('stage',choices=['platform','prepare','launch','retire','cleanup']); p.add_argument('config'); p.add_argument('directory'); p.add_argument('--dependency')
    p=sub.add_parser('authorize'); p.add_argument('directory'); p.add_argument('--review-sha256',required=True); p.add_argument('--approval',required=True)
    p=sub.add_parser('apply'); p.add_argument('directory')
    p=sub.add_parser('connect'); p.add_argument('target'); p.add_argument('config'); p.add_argument('--instance',required=True)
    p=sub.add_parser('handoff'); p.add_argument('target'); p.add_argument('plan_directory'); p.add_argument('--instance',required=True); p.add_argument('--output',required=True)
    p=sub.add_parser('collect'); p.add_argument('target'); p.add_argument('plan_directory'); p.add_argument('--handoff',required=True); p.add_argument('--guest',required=True); p.add_argument('--output',required=True)
    args=parser.parse_args()
    if args.verb=='build': result=build(args.directory)
    elif args.verb=='lease':
        result=lease(read(args.request),args.starts_at); write(checked_path(args.output),result)
    elif args.verb=='packet': result=packet(args.target,args.storage_directory,args.artifacts,args.platform_config,args.alarm_topic,args.output)
    elif args.verb=='outputs': result=outputs(args.target,args.plan_directory,args.output)
    elif args.verb=='plan': result=native_plan(args.target,args.stage,args.config,args.directory,args.dependency)
    elif args.verb=='authorize': result=authorize(args.directory,args.review_sha256,args.approval)
    elif args.verb=='connect': result=connect(args.target,args.config,args.instance)
    elif args.verb=='handoff': result=handoff(args.target,args.plan_directory,args.instance,args.output)
    elif args.verb=='collect': result=collect(args.target,args.plan_directory,args.handoff,args.guest,args.output)
    else: result=apply(args.directory)
    print(json.dumps(result,indent=2,sort_keys=True))

if __name__=='__main__':
    try: main()
    except Exception as exc:
        print('aws-workspace-lifecycle: FAIL: '+(str(exc) if isinstance(exc,Failure) else type(exc).__name__),file=sys.stderr)
        sys.exit(2)
PY
