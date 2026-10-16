"""Non-root project setup/run and declared versioned output persistence."""
import hashlib
import importlib.util
import io
import math
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import shutil
import signal
import stat
import subprocess
import time

LOG_BYTES=8*1024*1024
MANIFEST_BYTES=64*1024*1024
DATA_OBJECTS=100000
spec=importlib.util.spec_from_file_location('workspace_files',Path(__file__).with_name('workspace_files.py'))
files=importlib.util.module_from_spec(spec); spec.loader.exec_module(files)


def receipt_bytes(receipt):
    return (json.dumps(receipt,sort_keys=True)+'\n').encode()

def require(condition,reason):
    if not condition: raise ValueError(reason)

def relative(path):
    require(isinstance(path,str) and path and not path.startswith(('/','-')) and '\\' not in path and
            all(p not in ('','.','..','.git') for p in path.split('/')), 'relative path without traversal required')
    return path

def validate(job):
    require(os.geteuid()>0 and pwd.getpwuid(os.geteuid()).pw_name=='workspace','run as non-root workspace')
    require(set(job)=={'repository','workspace_id','account_id','region','run_id','commands','outputs','dataset_manifest','timeout_seconds','output_uri','mode'},'closed generic job required')
    require(re.fullmatch(r'[a-z0-9-]{3,48}',job['workspace_id']) and re.fullmatch(r'[0-9a-f]{32}',job['run_id']) and
            re.fullmatch(r'[0-9]{12}',job['account_id']), 'invalid job scope')
    require(job['mode'] in ('job','workspace') and type(job['timeout_seconds']) is int and 30<=job['timeout_seconds']<=1800,'invalid mode/timeout')
    require(set(job['commands'])=={'setup','run'},'explicit setup/run required')
    for argv in job['commands'].values():
        require(isinstance(argv,list) and 1<=len(argv)<=64 and all(isinstance(a,str) and a and not any(ord(c)<32 for c in a) for a in argv)
                and not argv[0].startswith('-'),'argument-array commands required')
    repository=job['repository']
    require(re.fullmatch(r'(?:https://github\.com/|git@github\.com:)[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\.git',repository['url'])
            and re.fullmatch(r'[0-9a-f]{40}',repository['revision']),'pinned credential-free GitHub repository required')
    require(set(job['outputs'])=={'paths','maximum_bytes'} and 0<job['outputs']['maximum_bytes']<=5*1024**4,'bounded output policy required')
    for path in job['outputs']['paths']: relative(path)
    require(len(set(job['outputs']['paths']))==len(job['outputs']['paths']),'duplicate outputs')
    require(isinstance(job['output_uri'],str) and re.fullmatch(r's3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/projects/[a-z0-9-]+/workspaces/'+job['workspace_id']+'/output/'+job['run_id']+'/',
            job['output_uri']),'unique output prefix required')
    manifest=job['dataset_manifest']
    require(set(manifest)=={'bucket','manifest_key','manifest_version_id','manifest_sha256'} and manifest['bucket']==job['output_uri'][5:].split('/',1)[0] and
            isinstance(manifest['manifest_version_id'],str) and re.fullmatch(r'[!-~]{1,1024}',manifest['manifest_version_id']) and manifest['manifest_version_id']!='null' and
            re.fullmatch(r'[0-9a-f]{64}',manifest['manifest_sha256']) and relative(manifest['manifest_key']).startswith(data_prefix(job)),'versioned dataset manifest in the job bucket/data prefix required')
    require(not any(os.environ.get(k) for k in ('AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_PROFILE')),'native role credentials required')

def data_prefix(job):
    return job['output_uri'][5:].split('/',1)[1].split('/workspaces/',1)[0]+'/data/'

def fetch(s3,account,bucket,key,version,deadline,sink,size=None):
    """Stream one exact object version into sink; the manifest alone has no known size."""
    response=s3.get_object(Bucket=bucket,Key=key,VersionId=version,ExpectedBucketOwner=account)
    try:
        length=response['ContentLength']
        require(response.get('VersionId')==version and (length==size if size is not None else length<=MANIFEST_BYTES),'dataset version/size differs')
        return files.stream_hash(response['Body'],length,deadline,sink=sink)
    finally: response['Body'].close()

def stage_data(s3,job,data,deadline):
    """Download every manifest object by exact version and checksum, then make the tree read-only."""
    manifest=job['dataset_manifest']; account=job['account_id']; bucket=manifest['bucket']; raw=io.BytesIO()
    require(fetch(s3,account,bucket,manifest['manifest_key'],manifest['manifest_version_id'],deadline,raw)==manifest['manifest_sha256'],'dataset manifest checksum differs')
    value=json.loads(raw.getvalue())
    require(isinstance(value,dict) and value.get('schema_version')=='1.0.0' and value.get('kind')=='dataset-manifest' and value.get('bucket')==bucket and
            isinstance(value.get('objects'),list) and 0<len(value['objects'])<=DATA_OBJECTS,'dataset manifest schema differs')
    paths=set(); total=0
    for item in value['objects']:
        require(isinstance(item,dict) and set(item)=={'path','bytes','sha256','key','version_id'} and type(item['bytes']) is int and item['bytes']>=0 and
                isinstance(item['sha256'],str) and re.fullmatch(r'[0-9a-f]{64}',item['sha256']) and isinstance(item['version_id'],str) and
                item['version_id'] not in ('','null') and relative(item['key']).startswith(data_prefix(job)) and relative(item['path']) not in paths,
                'dataset manifest object differs')
        paths.add(item['path']); total+=item['bytes']
    require(value.get('total_bytes')==total,'dataset manifest total differs')
    require(total<shutil.disk_usage(data.parent).free,'dataset does not fit the free workspace disk')
    data.mkdir(mode=0o700)
    for item in value['objects']:
        target=data/item['path']; target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with target.open('xb') as stream:
            require(fetch(s3,account,bucket,item['key'],item['version_id'],deadline,stream,item['bytes'])==item['sha256'],'dataset object checksum differs')
    for path in data.rglob('*'): path.chmod(0o555 if path.is_dir() else 0o444)
    data.chmod(0o555)
    return total

def execute(argv,environment,log,deadline,directory=None):
    process=subprocess.Popen(argv,cwd=directory,env=environment,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    selector=selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ); written=log.tell()
    try:
        while selector.get_map():
            if time.monotonic()>=deadline: raise subprocess.TimeoutExpired(argv,0)
            for key,_ in selector.select(min(0.2,max(0,deadline-time.monotonic()))):
                data=os.read(key.fileobj.fileno(),65536)
                if not data: selector.unregister(key.fileobj); break
                remaining=LOG_BYTES-written
                if remaining>0: log.write(data[:remaining]); written+=min(remaining,len(data))
        return process.wait(timeout=max(0.01,deadline-time.monotonic()))
    finally:
        try: os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: pass
        # The leader can exit while descendants ignore SIGTERM. Always finish
        # the owned process group before hashing or uploading project outputs.
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait(timeout=5)
        selector.close(); process.stdout.close()

def output_files(project,paths,maximum):
    selected={}; total=0
    for name in paths:
        item=project/relative(name)
        require(not any(p.is_symlink() for p in (item,*item.parents) if p.is_relative_to(project)),'output symlink unsupported')
        require(item.exists() and (item.is_file() or item.is_dir()),'declared output missing/special')
        for path in ([item] if item.is_file() else sorted(item.rglob('*'))):
            require(not path.is_symlink(),'output tree symlink unsupported')
            if path.is_dir(): continue
            require(stat.S_ISREG(path.lstat().st_mode),'output special file unsupported')
            key=relative(path.relative_to(project).as_posix())
            if key in selected: continue
            total+=path.stat().st_size; require(total<=maximum and len(selected)<100000,'output bytes/file-count bound exceeded')
            selected[key]=path
    require(selected,'declared outputs contain no files'); return sorted(selected.items())

def persist(s3,account,bucket,key,path):
    before=path.stat(); digest=hashlib.sha256()
    part_size=max(8*1024*1024,math.ceil(before.st_size/10000/(8*1024*1024))*(8*1024*1024))
    require(part_size<=64*1024*1024,'output object exceeds 640 GiB bounded transfer capability')
    from boto3.s3.transfer import TransferConfig
    with files.local_file(path) as stream:
        initial=files.local_stamp(stream)
        for data in iter(lambda:stream.read(8*1024*1024),b''): digest.update(data)
        require(files.local_stamp(stream)==initial,'output changed while hashing')
        stream.seek(0)
        s3.upload_fileobj(stream,bucket,key,ExtraArgs={'ExpectedBucketOwner':account,'Metadata':{'sha256':digest.hexdigest()}},
                       Config=TransferConfig(multipart_threshold=8*1024*1024,multipart_chunksize=part_size,max_concurrency=1,use_threads=False))
        require(files.local_stamp(stream)==initial,'output changed during upload')
    require(path.stat()==before,'output changed during upload')
    head=s3.head_object(Bucket=bucket,Key=key,ExpectedBucketOwner=account)
    require(head.get('VersionId') not in (None,'','null') and head['ContentLength']==before.st_size,'versioned output required')
    return {'key':key,'version_id':head['VersionId'],'bytes':before.st_size,'sha256':digest.hexdigest()}

def run(job,root=Path('/workspaces')):
    validate(job)
    bootstrap=json.loads(Path('/var/lib/workspace/bootstrap-success.json').read_text())
    require(bootstrap['workspace_id']==job['workspace_id'],'bootstrap mismatch')
    import boto3
    from botocore.config import Config
    session=boto3.Session(region_name=job['region']); require(session.get_credentials().method=='iam-role','native role required')
    settings=Config(connect_timeout=3,read_timeout=10,retries={'total_max_attempts':2})
    identity=session.client('sts',config=settings).get_caller_identity()
    require(identity['Account']==job['account_id'] and ':assumed-role/' in identity['Arn'],'runtime identity mismatch')
    directory=root/job['workspace_id']/job['run_id']; directory.mkdir(mode=0o700,parents=True,exist_ok=False)
    project=directory/'project'; manifest=job['dataset_manifest']
    environment={'HOME':'/home/workspace','PATH':'/opt/workspace/sdk/bin:/usr/local/bin:/usr/bin:/bin',
        'AWS_REGION':job['region'],'AWS_DEFAULT_REGION':job['region'],'PYTHONDONTWRITEBYTECODE':'1','GIT_TERMINAL_PROMPT':'0',
        'DATA_MANIFEST_URI':'s3://'+manifest['bucket']+'/'+manifest['manifest_key'],
        'DATA_MANIFEST_VERSION_ID':manifest['manifest_version_id'],'DATA_MANIFEST_SHA256':manifest['manifest_sha256'],
        'OUTPUT_URI':job['output_uri'],'RUN_ID':job['run_id']}
    repository=job['repository']
    clone=['bash','/opt/workspace/scripts/aws/clone-project.sh',repository['url'],repository['revision'],str(project)]
    if 'credential' in repository:
        ref=repository['credential']; clone=['bash','/opt/workspace/scripts/aws/workspace-ssh.sh',repository['url'],repository['revision'],str(project),
            ref['secret_arn'],ref['version_id'],ref['public_key_fingerprint'],job['region'],job['account_id']]
    receipt={'schema_version':'1.0.0','run_id':job['run_id'],'repository_commit':repository['revision'],'user':'workspace',
        'instance_role_arn':identity['Arn'],'bootstrap':bootstrap,'commands':job['commands'],'dataset_manifest':manifest,
        'infrastructure_ready':True,'setup_exit':None,'job_exit':None,'outputs_persisted':False,'output_objects':[],
        'credential_removed_before_setup':False,'dataset_staged':False,'dataset_staged_bytes':None,'mode':job['mode']}
    deadline=time.monotonic()+job['timeout_seconds']; log_path=directory/'job.log'
    s3=session.client('s3',config=settings); bucket,prefix=job['output_uri'][5:].split('/',1)
    with log_path.open('xb') as log:
        stage='clone'
        try:
            require(execute(clone,environment,log,min(deadline,time.monotonic()+300))==0,'clone failed')
            require(subprocess.check_output(['git','-C',str(project),'rev-parse','HEAD'],env=environment,timeout=10).decode().strip()==repository['revision'],'checkout differs')
            receipt['credential_removed_before_setup']=True
            # Contract v1: verified read-only inputs outside the checkout and an
            # empty private output directory exist before any project command.
            stage='data'; output=project/'outputs'; output.mkdir(mode=0o700); output.chmod(0o700)
            environment.update(DATA_DIR=str(directory/'data'),OUTPUT_DIR=str(output))
            receipt['dataset_staged_bytes']=stage_data(s3,job,directory/'data',deadline); receipt['dataset_staged']=True
            stage='setup'; receipt['setup_exit']=execute(job['commands']['setup'],environment,log,deadline,project)
            if receipt['setup_exit']==0 and job['mode']=='job':
                stage='job'; receipt['job_exit']=execute(job['commands']['run'],environment,log,deadline,project)
        except subprocess.TimeoutExpired: receipt[stage+'_exit' if stage in ('setup','job') else 'clone_exit']=124
        except Exception as error: receipt['execution_error']={'stage':stage,'type':type(error).__name__}
    try:
        # Reserve space for log references and errors. Count encoded metadata
        # once per file, rather than repeatedly serializing the growing receipt.
        metadata_bytes=len(receipt_bytes(receipt))+16*1024
        for name,path in output_files(project,job['outputs']['paths'],job['outputs']['maximum_bytes']):
            key=prefix+'files/'+name
            maximum_record={'path':name,'key':key,'version_id':'x'*1024,'bytes':path.stat().st_size,'sha256':'x'*64}
            require(metadata_bytes+len(receipt_bytes(maximum_record))+2<=files.EXECUTION_RECEIPT_BYTES,
                    'output metadata exceeds execution receipt limit')
            record={'path':name,**persist(s3,job['account_id'],bucket,key,path)}
            metadata_bytes+=len(receipt_bytes(record))+2
            receipt['output_objects'].append(record)
        receipt['outputs_persisted']=True
    except Exception as error: receipt['output_error']=type(error).__name__
    try: receipt['log_object']=persist(s3,job['account_id'],bucket,prefix+'job.log',log_path)
    except Exception as error: receipt['log_error']=type(error).__name__
    encoded=receipt_bytes(receipt)
    require(len(encoded)<=files.EXECUTION_RECEIPT_BYTES,'execution receipt exceeds byte limit')
    response=s3.put_object(Bucket=bucket,Key=prefix+'execution.json',Body=encoded,
        ContentType='application/json',ExpectedBucketOwner=job['account_id'])
    require(response.get('VersionId') not in (None,'','null'),'durable execution receipt required')
    return 0 if receipt['setup_exit']==0 and (job['mode']=='workspace' or (receipt['job_exit']==0 and receipt['outputs_persisted'])) else 1
