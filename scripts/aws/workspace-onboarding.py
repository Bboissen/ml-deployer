"""AWS foundation/access preparation around the existing guarded plan engine."""
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid


def canonical_operator(L, identity, iam=None):
    account, arn = identity['Account'], identity['Arn']
    if ':assumed-role/' in arn:
        L['require'](iam is not None, 'resolve the account-native role with IAM before onboarding')
        name = arn.split(':assumed-role/')[1].split('/')[0]
        role = iam.get_role(RoleName=name)['Role']
        L['require'](role['RoleName'] == name and re.fullmatch(
            r'arn:aws:iam::'+account+r':role/[A-Za-z0-9_+=,.@/-]+', role['Arn']), 'operator role/account mismatch')
        arn = role['Arn']
        # AWS owns SSO role grants; attaching arbitrary inline policies to them
        # would be overwritten by permission-set provisioning.
        L['require']('/aws-reserved/sso.amazonaws.com/' not in arn,
                     'SSO requires an owner-managed non-reserved operator role; STS login alone is insufficient')
    L['require'](re.fullmatch(r'arn:aws:iam::'+account+r':(?:user|role)/[A-Za-z0-9_+=,.@/-]+', arn), 'unsupported account-native operator')
    return arn


def target(deployment, operator):
    project = deployment['configuration']['project']; names = deployment['names']
    prefix = names['resource_prefix']
    return {'profile': deployment['configuration']['profile'], 'account_id': deployment['account_id'],
            'region': deployment['configuration']['region'], 'operator_arn': operator,
            'deployment_role_arn': names['deployer_role_arn'], 'backend': deployment['backend'],
            'inventory': {'resource_prefix': prefix, 'buckets': [names['workload_bucket']], 'repositories': [],
                          'roles': [prefix+'-workspace-deployer', prefix+'-workspace-watchdog', prefix+'-workspace-watchdog-invoke'],
                          'policies': [prefix+'-ws-'+project+'-boundary', prefix+'-workspace-launch-boundary', prefix+'-session-manager-minimal']}}


def pages(L, api, operation, result, **arguments):
    items = []; tokens = set()
    for _ in range(100):
        response = getattr(api, operation)(**arguments)
        items.extend(response.get(result, []))
        L['require'](len(items) <= 100000, 'provider inventory exceeds bounded pagination')
        token = response.get('NextToken')
        if not token: return items
        L['require'](token not in tokens, 'repeated provider continuation token')
        tokens.add(token); arguments['NextToken'] = token
    raise ValueError('provider inventory pagination exhausted')


def capacity(L, base, client, region, maximum_hourly_usd=None):
    catalog = L['supported_sizes'](); ec2 = client(base, 'ec2')
    images = ec2.describe_images(ImageIds=[L['TOOLBOX']['ami_id']], Owners=['137112412989'])['Images']
    L['require'](len(images) == 1 and images[0]['State'] == 'available' and images[0]['Architecture'] == 'x86_64'
                 and images[0]['Name'] == L['TOOLBOX']['ami_name'] and images[0]['EnaSupport'], 'supported image provenance differs')
    reservations = pages(L, ec2, 'describe_instances', 'Reservations', MaxResults=100,
                         Filters=[{'Name':'instance-state-name','Values':['pending','running','stopping','stopped','shutting-down']}])
    instances = [i for r in reservations for i in r['Instances']]
    types = sorted(set(catalog) | {i['InstanceType'] for i in instances})
    observed = {}
    for offset in range(0, len(types), 100):
        for item in pages(L, ec2, 'describe_instance_types', 'InstanceTypes', InstanceTypes=types[offset:offset+100]):
            observed[item['InstanceType']] = item
    L['require'](set(observed) == set(types), 'instance capacity inventory incomplete')
    quota = client(base, 'service-quotas').get_service_quota(ServiceCode='ec2', QuotaCode='L-1216C47A')['Quota']['Value']
    # Conservative: do not discount other families, stopped or reserved use.
    used = sum(observed[i['InstanceType']]['VCpuInfo']['DefaultVCpus'] for i in instances)
    zones = sorted(z['ZoneName'] for z in ec2.describe_availability_zones()['AvailabilityZones']
                   if z['State'] == 'available' and z.get('OptInStatus') in (None, 'opt-in-not-required', 'opted-in'))
    offerings = pages(L, ec2, 'describe_instance_type_offerings', 'InstanceTypeOfferings',
                      LocationType='availability-zone', Filters=[{'Name':'instance-type','Values':list(catalog)}])
    prices = {}; pricing = client(base, 'pricing')
    for sku in catalog:
        products = pages(L, pricing, 'get_products', 'PriceList', ServiceCode='AmazonEC2',
                         Filters=[{'Type':'TERM_MATCH','Field':key,'Value':value} for key,value in {
                             'regionCode':region, 'instanceType':sku, 'operatingSystem':'Linux',
                             'tenancy':'Shared', 'preInstalledSw':'NA', 'capacitystatus':'Used'}.items()], MaxResults=100)
        rates = []
        for raw in products:
            product = json.loads(raw)
            for term in product.get('terms', {}).get('OnDemand', {}).values():
                for dimension in term['priceDimensions'].values():
                    if dimension['unit'] == 'Hrs': rates.append(float(dimension['pricePerUnit']['USD']))
        L['require'](rates and len(set(rates)) == 1 and rates[0] > 0, 'current unambiguous On-Demand price required')
        prices[sku] = rates[0]
    candidates = []
    for sku, size in catalog.items():
        info = observed[sku]
        L['require'](info['VCpuInfo']['DefaultVCpus'] == size['cpus'] and info['MemoryInfo']['SizeInMiB'] >= size['memory_mb']
                     and 'x86_64' in info['ProcessorInfo']['SupportedArchitectures'], 'supported SKU metadata changed')
        available = sorted({x['Location'] for x in offerings if x['InstanceType'] == sku} & set(zones))
        if size['cpus'] <= quota-used and available and (maximum_hourly_usd is None or prices[sku] <= maximum_hourly_usd):
            candidates.append({**size, 'policy':'ram-first', 'instance_type':sku, 'availability_zone':available[0],
                               'hourly_usd':prices[sku]})
    L['require'](candidates, 'no supported RAM-first SKU fits remaining quota/offering/selected price ceiling')
    candidates.sort(key=lambda x:(-x['memory_mb'], -x['cpus'], x['instance_type']))
    return {'selected':candidates[0], 'candidates':candidates, 'quota_vcpus':quota, 'observed_used_vcpus':used,
            'observed_at':L['stamp'](), 'capacity_available':'unverified',
            'cost_exclusions':['gp3 root disk', 'public IPv4', 'retained S3/state', 'requests/transfer', 'guard/logs/SNS/Secrets Manager']}


def prepare(L, deployment, directory, artifacts, observed_capacity, operator):
    """No cloud mutation; generated inputs never contain secret material."""
    directory = L['checked_path'](directory); project = deployment['configuration']['project']
    selected = target(deployment, operator); prefix = selected['inventory']['resource_prefix']
    size = observed_capacity['selected']
    L['require'](size['instance_type'] in L['supported_sizes']() and
                 all(size[k] == L['supported_sizes']()[size['instance_type']][k] for k in ('cpus','memory_mb','disk_gb')),
                 'capacity not in supported catalog')
    L['require'](size['availability_zone'].startswith(selected['region']) and size['hourly_usd'] > 0, 'invalid discovered offering/price')
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    topic = f"arn:aws:sns:{selected['region']}:{selected['account_id']}:{prefix}-workspace-alerts"
    bootstrap = {'aws_account_id':selected['account_id'], 'aws_region':selected['region'],
                 'project_name':prefix, 'state_bucket_name':selected['backend']['bucket']}
    platform = {'aws_account_id':selected['account_id'], 'aws_region':selected['region'], 'project_name':prefix,
                'resource_prefix':prefix, 'state_bucket_arn':'arn:aws:s3:::'+selected['backend']['bucket'],
                'availability_zone':size['availability_zone'], 'deployer_principal_arns':[operator],
                'ml_projects':{project:{'ml_project_name':project,'storage_mode':'auto'}}, 'provision_alert_topic':True,
                'workspace_guard':{'zip_path':artifacts['guard_zip_path'], 'zip_sha256':artifacts['guard_zip_sha256'], 'alarm_topic_arn':topic}}
    L['foundation']['config'](platform, selected)
    for name, value in {'bootstrap.tfvars.json':bootstrap, 'platform.tfvars.json':platform,
                        'target.json':selected, 'capacity.json':observed_capacity, 'artifacts.json':artifacts}.items():
        L['write'](directory/name, value)
    return {'directory':str(directory), 'target':selected, 'cloud_mutations':False}


def bind_plan(L, directory, authorization):
    review = L['read'](directory/'review.json')
    L['authorize'](str(directory), L['sha'](L['canon'](review)), authorization)
    return L['apply'](str(directory))


def capture(L, target_name, directory, output):
    review = L['read'](directory/'review.json'); config = L['read'](directory/'config.tfvars.json')
    receipt = L['read'](directory/'apply-result.json')
    L['require'](receipt['status']=='success' and L['prior_source'](review['source']), 'successful committed foundation required')
    selected, environment, base, client, _, state = L['context'](target_name, review['stage'], config)
    L['require'](selected == review['target'] and state == receipt['state'], 'foundation ownership/state lineage changed')
    environment['TF_DATA_DIR'] = str(directory/'tofu-data')
    value = json.loads(L['run'](['tofu', '-chdir='+review['root'], 'output', '-json'], environment, 30))
    platform, guard = (value[k]['value'] for k in ('workspace_platform','workspace_guard'))
    L['require'](platform['aws_account_id']==selected['account_id'] and platform['aws_region']==selected['region']
                 and platform['deployer_role_arn']==selected['deployment_role_arn']
                 and platform['state_bucket_arn']=='arn:aws:s3:::'+selected['backend']['bucket']
                 and guard['code_sha256']==config['workspace_guard']['zip_sha256'], 'foundation outputs differ')
    L['write'](output, value)
    return {'plan_directory':str(directory), 'outputs_file':str(output), 'outputs_sha256':L['sha'](output.read_bytes())}


def verify_retained(L, binding, selected):
    directory = L['checked_path'](binding['plan_directory'])
    review = L['read'](directory/'review.json'); receipt = L['read'](directory/'apply-result.json')
    L['require'](review['target']==selected and review['stage'] in ('fresh-platform','workspace-access') and receipt['status']=='success'
                 and L['prior_source'](review['source']), 'retained foundation ownership/source mismatch')
    for name, field in (('saved.tfplan','plan_sha256'),('plan.json','plan_json_sha256')):
        L['require'](L['sha']((directory/name).read_bytes())==review[field], 'retained saved plan changed')
    authorization = L['read'](directory/'authorization.json'); started = L['read'](directory/'apply-started.json')
    L['require'](authorization['review_sha256']==started['review_sha256']==L['sha'](L['canon'](review))
                 and authorization['plan_sha256']==review['plan_sha256'], 'retained authorization mismatch')
    config = L['read'](directory/'config.tfvars.json')
    L['require'](L['sha'](L['canon'](config))==review['config_sha256'], 'retained inputs changed')
    outputs = L['checked_path'](binding['outputs_file'])
    L['require'](L['sha'](outputs.read_bytes())==binding['outputs_sha256'], 'retained output capture changed')
    base, client, _ = L['sessions'](selected)
    state = L['snapshot'](base, client, selected, selected['backend']['platform_key'])
    L['require'](state == receipt['state'], 'retained state version/lineage differs; reconcile instead of adopting')
    platform = L['read'](outputs)['workspace_platform']['value']
    L['require'](platform['state_bucket_arn']=='arn:aws:s3:::'+selected['backend']['bucket'] and
                 platform['deployer_role_arn']==selected['deployment_role_arn'], 'retained output scope differs')
    L['platform_compute_absent'](base, client, config)
    return config


def onboard_key(L, deployment, selected, directory, authorization):
    """Explicitly authorized read-only GitHub deploy key + native secret only."""
    L['require'](len(authorization.strip()) >= 12, 'repository/secret scope authorization required')
    repository = deployment['repository']['url']
    match = re.fullmatch(r'(?:git@github\.com:|https://github\.com/)([A-Za-z0-9_-]+/[A-Za-z0-9_.-]+)\.git', repository)
    L['require'](match is not None, 'reviewed GitHub repository required')
    owner_repo = match[1]; directory = L['checked_path'](directory); directory.mkdir(mode=0o700, exist_ok=False)
    base, client, _ = L['sessions'](selected)
    info = subprocess.run(['gh','api','repos/'+owner_repo], capture_output=True, text=True, timeout=30)
    L['require'](info.returncode==0 and json.loads(info.stdout).get('permissions',{}).get('admin') is True,
                 'repository administrator grant required for read-only deploy-key registration')
    spec = importlib.util.spec_from_file_location('workspace_ram', L['REPO']/'scripts/aws/workspace_ram.py')
    ram = importlib.util.module_from_spec(spec); spec.loader.exec_module(ram)
    identifier = uuid.uuid4().hex; cfg = deployment['configuration']
    name = cfg['project']+'/workspaces/'+deployment['names']['workspace_id']+'/git/'+identifier
    L['write'](directory/'intent.json', {'repository':owner_repo, 'secret_name':name, 'operation_id':identifier,
                                       'authorization':authorization, 'read_only':True})
    with ram.key_directory() as temporary:
        key = temporary/'key'
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-C','workspace-'+identifier,'-f',str(key)],
                       check=True, capture_output=True, timeout=10)
        public = key.with_suffix('.pub').read_text().strip()
        fingerprint = 'SHA256:'+base64.b64encode(hashlib.sha256(base64.b64decode(public.split()[1])).digest()).decode().rstrip('=')
        request = subprocess.run(['gh','api','--method','POST','repos/'+owner_repo+'/keys','--input','-'],
                                 input=json.dumps({'title':'workspace-'+identifier,'key':public,'read_only':True}),
                                 capture_output=True, text=True, timeout=30)
        L['require'](request.returncode==0, 'deploy-key registration uncertain; reconcile the recorded title before retrying')
        registered = json.loads(request.stdout)
        L['require'](registered['read_only'] is True and registered['key'].split()[:2]==public.split()[:2], 'registered deploy key differs')
        L['write'](directory/'github-key.json', {'repository':owner_repo,'key_id':registered['id'],'title':registered['title'],
                                               'public_key_fingerprint':fingerprint,'revocation_owner':'operator'})
        # A timeout is uncertain; never compensate by deleting an unverified key
        # or replaying registration. The intent and exact ID support reconciliation.
        result = client(base,'secretsmanager').create_secret(Name=name, ClientRequestToken=identifier,
            SecretString=key.read_text(), Tags=[{'Key':'ManagedBy','Value':'workspace-controller'},
                                                {'Key':'OperationId','Value':identifier}])
        L['require'](result['Name']==name and result['VersionId']==identifier, 'secret creation reference mismatch')
        reference = {'secret_arn':result['ARN'],'version_id':result['VersionId'],'public_key_fingerprint':fingerprint}
        L['write'](directory/'reference.json',reference)
    return reference


def provision(L, target_name, packet, authorization, retained=None):
    """Sequential exact plans/applies; capture dependencies without operator copies."""
    packet = L['checked_path'](packet); selected = L['read'](packet/'target.json')
    if retained:
        verify_retained(L, retained, selected)
        return retained
    bootstrap = packet/'bootstrap'
    platform = packet/'platform'
    if not (bootstrap/'apply-result.json').exists():
        L['require'](not (bootstrap/'apply-started.json').exists(),
                     'bootstrap apply outcome uncertain; reconcile its local state before continuing')
        if not bootstrap.exists():
            L['foundation']['bootstrap_plan'](target_name,str(packet/'bootstrap.tfvars.json'),str(bootstrap))
        bind_plan(L, bootstrap, authorization)
    if not (platform/'apply-result.json').exists():
        L['require'](not (platform/'apply-started.json').exists(),
                     'platform apply outcome uncertain; reconcile the versioned state before continuing')
        if not platform.exists():
            L['native_plan'](target_name,'fresh-platform',str(packet/'platform.tfvars.json'),str(platform),str(bootstrap))
        bind_plan(L, platform, authorization)
    return capture(L, target_name, platform, packet/'outputs.json')


def access(L, target_name, binding, project, reference, directory, authorization):
    platform = L['read'](L['checked_path'](binding['plan_directory'])/'config.tfvars.json')
    if platform.get('workspace_git_secret_arns',{}).get(project)==[reference['secret_arn']]: return binding
    platform = copy.deepcopy(platform)
    platform.setdefault('workspace_git_secret_arns',{})[project] = [reference['secret_arn']]
    directory = L['checked_path'](directory)
    inputs = directory.parent/'access.tfvars.json'; L['write'](inputs, platform)
    L['native_plan'](target_name,'workspace-access',str(inputs),str(directory),binding['plan_directory'])
    bind_plan(L, directory, authorization)
    return capture(L, target_name, directory, directory.parent/'access-outputs.json')
