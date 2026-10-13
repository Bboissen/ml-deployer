"""One reviewed AWS Deploy, durable operations and ownership-aware recovery."""
from contextlib import contextmanager
import base64
import copy
import datetime as dt
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time
import uuid
from workspace_terminal import interactive


def say(line):
    """Human-readable progress on stderr; stdout stays machine-readable JSON."""
    print(line, file=sys.stderr, flush=True)


def describe_scope(scope):
    target=scope['target']; selected=scope['capacity']['selected']; dataset=scope['dataset']; repository=scope['repository']
    lines=['Deployment scope '+scope['operation_id'],
        '  account:     '+target['account_id']+' as '+target['operator_arn'],
        '  region/zone: '+target['region']+' / '+selected['availability_zone'],
        '  repository:  '+repository['url']+' @ '+repository['revision'][:12]+(' (private deploy key will be registered)' if scope['new_private_access'] else ''),
        '  dataset:     %d file(s), %.1f MiB from %s' % (len(dataset['inventory']),dataset['total_bytes']/1024**2,dataset['source'].get('source','')),
        '  compute:     '+selected['instance_type']+' at %.4f USD/hour, at most %d minutes (about %.2f USD)' % (selected['hourly_usd'],scope['maximum_runtime_minutes'],scope['estimated_compute_usd']),
        '  mode:        '+scope['mode']+'; cleanup: '+scope['cleanup'],
        '  foundation:  '+('reuse retained foundation' if scope['foundation'] else 'create new foundation (state/workload buckets, network, IAM, expiry guard)'),
        '  outputs:     '+', '.join(scope['outputs']['paths'])+' (at most %d MiB)' % (scope['outputs']['maximum_bytes']//1024**2 or 1),
        '  retained after the job: '+'; '.join(scope['retained_resources']),
        '  not in the quote: '+'; '.join(scope['additional_cost_scope']) if isinstance(scope['additional_cost_scope'],list) else '  not in the quote: '+str(scope['additional_cost_scope'])]
    migration=scope.get('foundation_iam_migration')
    if migration and migration.get('required'): lines.append('  includes a reviewed tightening of the retained deployer IAM policy')
    return lines


def confirm(L,scope):
    """One interactive confirmation of the displayed scope; never implicit."""
    if not interactive(): return None
    for line in describe_scope(scope): say(line)
    say('Type deploy to launch exactly this scope, or press Enter to stop without any cloud change.')
    try: answer=input('> ')
    except EOFError: answer=''
    if answer.strip()!='deploy':
        say('Stopped; nothing was launched. Rerun the same command to confirm later.'); return None
    return 'Interactive confirmation of scope '+L['sha'](L['canon'](scope))[:16]+' at '+L['stamp']()


def describe_result(config,result):
    status=result.get('status'); lines=['Outcome: '+str(status)]
    if 'setup_exit' in result:
        lines.append('  infrastructure ready: %s; setup exit: %s; job exit: %s; outputs persisted: %s' % (
            result.get('infrastructure_ready'),result.get('setup_exit'),result.get('job_exit'),result.get('outputs_persisted')))
        lines.append('  compute cleanup: %s; outputs verified after compute deletion: %s' % (
            result.get('cleanup_status'),result.get('verified_after_compute_deletion')))
    if result.get('output_uri'): lines.append('  outputs: '+result['output_uri'])
    if result.get('error'): lines.append('  error: '+str(result['error'].get('reason') or result['error'].get('type')))
    command='./workspace '+str(config)
    if status=='review_required': lines.append('  next: review the scope above, then rerun '+command+' and type deploy, or pass --authorization TEXT')
    elif status=='success': lines.append('  next: a second Deploy reuses the retained data; '+command+' logs shows events')
    elif status=='workspace_ready': lines.append('  next: '+command+' connect; '+command+' cancel ends compute before expiry')
    elif status in ('failure','cancelled') and result.get('cleanup_status') in ('success','not_needed'): lines.append('  next: owned compute is gone; fix the cause and run '+command+' for a new review')
    elif status in ('failure','cancelled','cancellation_requested'): lines.append('  next: '+command+' resume reconciles owned resources; provider expiry stays armed')
    return lines


def extensions(L):
    modules={}
    for name in ('config','onboarding','ingest','e2e'):
        spec=importlib.util.spec_from_file_location(name,L['REPO']/('scripts/aws/workspace-'+name+'.py'))
        value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value); modules[name]=value
    return modules


def atomic(L,path,value,exclusive=False):
    path=L['checked_path'](path); path.parent.mkdir(parents=True,mode=0o700,exist_ok=True)
    temporary=path.with_name('.'+path.name+'-'+uuid.uuid4().hex)
    try:
        with temporary.open('xb') as stream:
            stream.write(L['canon'](value)); stream.flush(); os.fsync(stream.fileno())
        if exclusive:
            os.link(temporary,path); temporary.unlink()
        else: os.replace(temporary,path)
        descriptor=os.open(path.parent,os.O_RDONLY)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    finally:
        if temporary.exists(): temporary.unlink()


@contextmanager
def locked(L,path):
    path=L['checked_path'](path); path.parent.mkdir(parents=True,mode=0o700,exist_ok=True)
    descriptor=os.open(path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        try: fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('workspace/project is busy; use status or cancel') from None
        yield
    finally: os.close(descriptor)


class Journal:
    def __init__(self,L,directory,scope_hash):
        self.L=L; self.directory=L['checked_path'](directory); self.scope_hash=scope_hash
        self.path=self.directory/'journal'; self.path.mkdir(mode=0o700,exist_ok=True); self.records=[]
        previous=None
        for number,path in enumerate(sorted(self.path.glob('*.json')),1):
            value=L['read'](path)
            L['require'](number<=10000 and path.name==f'{number:06}.json' and value['sequence']==number and
                         value['scope_sha256']==scope_hash and value['previous_sha256']==previous,'journal sequence/scope/hash-chain drift')
            self.records.append(value); previous=L['sha'](L['canon'](value))
    def record(self,stage,state,detail=None):
        value={'sequence':len(self.records)+1,'stage':stage,'state':state,'scope_sha256':self.scope_hash,
            'previous_sha256':self.L['sha'](self.L['canon'](self.records[-1])) if self.records else None,
            'observed_at':self.L['stamp'](),'detail':detail}
        path=self.path/f"{value['sequence']:06}.json"
        atomic(self.L,path,value,exclusive=True)
        self.records.append(value); atomic(self.L,self.directory/'status.json',value)
        say('stage %-12s %s' % (stage,state))
        return value
    def latest(self,stage): return next((r for r in reversed(self.records) if r['stage']==stage),None)
    def stage(self,name,callback,reconcile=None):
        old=self.latest(name)
        if old and old['state']=='completed': return old['detail']
        self.L['require'](not (self.directory/'cancel.json').exists(),'cancel requested')
        if old and old['state'] in ('started','unknown'):
            self.L['require'](reconcile is not None,'uncertain '+name+'; resume must reconcile owned resources before another mutation')
            result=reconcile()
        else:
            self.record(name,'started')
            try: result=callback()
            except BaseException as error:
                self.record(name,'unknown',{'error_type':type(error).__name__}); raise
        self.record(name,'completed',result); return result


def selection(L,P,config):
    project=P.validate_project(L,config)
    return L['REPO']/'evidence/aws/selections'/(L['sha'](L['canon']({'path':str(Path(config).absolute()),'project':project}))+'.json')


def latest(L,config):
    P=extensions(L)['config']; pointer=selection(L,P,config)
    L['require'](pointer.exists(),'no operation for this configuration; run deploy to prepare its review')
    return L['checked_path'](L['read'](pointer)['directory'])


def prepare(W,config,directory=None):
    L=W['L']; modules=extensions(L); P,O,I= (modules[k] for k in ('config','onboarding','ingest'))
    if directory:
        status=P.operation_status(L,config,directory); directory=L['checked_path'](directory)
        if (directory/'scope.json').exists(): return directory,L['read'](directory/'scope.json')
    else:
        result=P.configure(L,config); directory=L['REPO']/result['operation_directory']
    deployment=L['read'](directory/'deployment.json'); project=deployment['configuration']
    # Resolve session to the native IAM role before root trust/grants are built.
    provisional=O.target(deployment,deployment['operator_arn']); base,client,_=L['sessions'](provisional)
    operator=O.canonical_operator(L,{'Account':deployment['account_id'],'Arn':deployment['operator_arn']},client(base,'iam'))
    selected=O.target(deployment,operator)
    registry=L['REPO']/'evidence/aws/projects'/deployment['names']['resource_prefix']
    retained=L['read'](registry/'foundation.json') if (registry/'foundation.json').exists() else None
    platform=O.verify_retained(L,retained,selected) if retained else None
    migration=O.iam_migration(L,retained,selected) if retained else None
    capacity=O.capacity(L,base,client,project['region'],project['resources'].get('maximum_hourly_usd'),
                        availability_zone=platform['availability_zone'] if platform else None)
    adapter=I.source_adapter({**deployment['dataset'],'maximum_bytes':project['dataset'].get('maximum_bytes',640*1024**3)},client(base,'s3'),project['region'])
    records=adapter.inventory(time.monotonic()+3600); total=sum(r['bytes'] for r in records)
    L['require'](total<=project['dataset'].get('maximum_bytes',total),'dataset exceeds configured transfer ceiling')
    reference_path=registry/(deployment['names']['workspace_id']+'-repository.json')
    reference=L['read'](reference_path) if reference_path.exists() else None
    if reference: L['require'](reference['url']==deployment['repository']['url'],'retained repository differs; review rotation separately')
    scope={'schema_version':'1.0.0','kind':'aws-deploy-scope','operation_id':directory.name,'source':L['source'](),
        'configuration_sha256':L['sha'](L['canon'](project)),'deployment_sha256':L['sha'](L['canon'](deployment)),
        'target':selected,'capacity':capacity,'repository':deployment['repository'],
        'dataset':{'inventory':records,'total_bytes':total,'source':deployment['dataset']},
        'foundation':retained,'foundation_iam_migration':migration,'registry_directory':str(registry),'repository_reference':reference,
        'retained_resources':['encrypted versioned state bucket','encrypted versioned workload bucket','no-ingress VPC/subnet/IGW',
            'deployer/project boundaries','provider watchdog/schedules/alarms/queue/logs','encrypted SNS topic/customer-managed rotating KMS key'],
        'new_private_access':deployment['repository']['url'].startswith('git@') and not reference,
        'outputs':{'paths':project['outputs']['paths'],'maximum_bytes':project['outputs'].get('maximum_bytes',100*1024*1024)},
        'maximum_runtime_minutes':project['maximum_runtime_minutes'],'max_ec2_launches':1,
        'estimated_compute_usd':capacity['selected']['hourly_usd']*project['maximum_runtime_minutes']/60,
        'additional_cost_scope':capacity['cost_exclusions'],'transfer_policy':'selected source hash + upload + independent version reads; no cross-region transfer',
        'mode':project['mode'],'cleanup':'owned compute after job' if project['mode']=='job' else 'explicit cancel or absolute expiry',
        'native_acceptance':False,'cloud_mutations':False}
    L['write'](directory/'scope.json',scope)
    atomic(L,selection(L,P,config),{'directory':str(directory)})
    return directory,scope


def validate_operation(W,config,directory):
    L=W['L']; P=extensions(L)['config']; directory=L['checked_path'](directory)
    P.operation_status(L,config,directory); scope=L['read'](directory/'scope.json')
    L['require'](L['prior_source'](scope['source']),'operation source is not an accepted committed ancestor')
    L['require'](scope['operation_id']==directory.name and scope['configuration_sha256']==L['sha'](L['canon'](P.validate_project(L,config)))
                 and scope['deployment_sha256']==L['sha']((L['canon'](L['read'](directory/'deployment.json')))), 'operation scope/input drift')
    task=L['read'](directory/'task-authorization.json')
    L['require'](task['scope_sha256']==L['sha'](L['canon'](scope)) and len(task['authorization'].strip())>=12,'task authorization does not bind scope')
    return directory,scope,task


def apply_stage(L,name,stage,inputs,folder,authorization,dependency=None,recover_from=None):
    if (folder/'apply-result.json').exists():
        L['require'](L['read'](folder/'apply-result.json')['status']=='success','unsuccessful apply receipt')
        return str(folder)
    L['require'](not (folder/'apply-started.json').exists(),'uncertain '+stage+' apply; reconcile its state before retry')
    if not folder.exists(): L['native_plan'](name,stage,str(inputs),str(folder),dependency,recover_from)
    review=L['read'](folder/'review.json')
    if not (folder/'authorization.json').exists(): L['authorize'](str(folder),L['sha'](L['canon'](review)),authorization)
    L['apply'](str(folder)); return str(folder)


def cleanup_runner(L,name,control,config,authorization):
    E=extensions(L)['e2e']
    def applied(stage,inputs,dependency=None,recover_from=None):
        return Path(apply_stage(L,name,stage,inputs,control/stage,authorization,dependency,recover_from))
    result=E.cleanup_runner(L,name,control,config,applied)
    if result['cleanup_status']=='success':
        base,client,_=L['sessions'](L['boundary']['targets']()[name])
        L['inventory'](base,client,config)
        if (control/'retire/retired-owned.json').exists(): L['remaining_owned'](base,client,L['read'](control/'retire/retired-owned.json'))
    return result


def abort_outputs(L,s3,scope,job,directory):
    bucket=scope['target']['inventory']['buckets'][0]; prefix=job['output_uri'][5:].split('/',1)[1]
    response=s3.list_multipart_uploads(Bucket=bucket,Prefix=prefix,ExpectedBucketOwner=scope['target']['account_id'],MaxUploads=1000)
    L['require'](not response.get('IsTruncated'),'output multipart ownership inventory exceeds bound')
    aborted=[]
    for item in response.get('Uploads',[]):
        L['require'](item['Key'].startswith(prefix),'output upload ownership differs')
        s3.abort_multipart_upload(Bucket=bucket,Key=item['Key'],UploadId=item['UploadId'],ExpectedBucketOwner=scope['target']['account_id'])
        aborted.append({'key':item['Key'],'upload_id':item['UploadId']})
    L['write'](directory/('output-upload-cleanup-'+uuid.uuid4().hex+'.json'),{'aborted':aborted})


def execute(W,config,directory,scope,task,resume=False):
    L=W['L']; modules=extensions(L); O,I,E=(modules[k] for k in ('onboarding','ingest','e2e'))
    selected=scope['target']; prefix=selected['inventory']['resource_prefix']; name='aws-'+prefix
    project=L['read'](directory/'project.json'); deployment=L['read'](directory/'deployment.json'); authorization=task['authorization']
    registry=L['checked_path'](scope['registry_directory']); active=registry/(deployment['names']['workspace_id']+'-active.json')
    with locked(L,L['REPO']/'evidence/aws/locks'/(prefix+'.lock')):
        if active.exists(): L['require'](L['read'](active)['operation_id']==directory.name,'another operation owns this workspace; resume or cancel it')
        else: atomic(L,active,{'operation_id':directory.name,'directory':str(directory)})
        journal=Journal(L,directory,task['scope_sha256']); control=directory/'workspace'
        technical=directory/'runtime.json'; identity_file=directory/'target-config.json'
        if not identity_file.exists(): L['write'](identity_file,{'target_name':name,'target':selected})
        os.environ['WORKSPACE_CONFIG']=str(identity_file)
        base,client,_=L['sessions'](selected); s3=client(base,'s3')
        result={'status':'failure','operation_id':directory.name,'infrastructure_ready':False,'setup_exit':None,'job_exit':None,
                'outputs_persisted':False,'cleanup_status':'not_needed','verified_after_compute_deletion':False}
        runner=L['read'](control/'runner.json') if (control/'runner.json').exists() else None
        job=L['read'](directory/'job.json') if (directory/'job.json').exists() else None
        def cancelled(): return (directory/'cancel.json').exists()
        old_handlers={sig:signal.signal(sig,lambda *_: (_ for _ in ()).throw(InterruptedError('controller interrupted'))) for sig in (signal.SIGTERM,signal.SIGINT)}
        try:
            if resume and (control/'launch/apply-started.json').exists():
                # Reconciliation preserves evidence, never replays RunInstances or
                # SendCommand after controller loss. Capture any durable result.
                if job and (control/'launch/launched-owned.json').exists():
                    instance=L['read'](control/'launch/launched-owned.json')['instance_id']
                    verified=E.verify_generic_result(L,L['read'](technical),selected,job,runner,instance,s3,directory/'before' if not (directory/'before/verification.json').exists() else directory/('recovered-output-'+uuid.uuid4().hex))
                    result.update({k:verified['execution'][k] for k in ('infrastructure_ready','setup_exit','job_exit','outputs_persisted')})
                    result.update(instance_id=instance,output_uri=job['output_uri'])
                raise InterruptedError('resumed launch reconciled; finish owned cleanup without another launch')
            artifacts=journal.stage('artifacts',lambda:L['build'](str(directory/'artifacts')),
                                    lambda:L['read'](directory/'artifacts/artifacts.json'))
            def foundation():
                packet=directory/'foundation'
                if not packet.exists(): O.prepare(L,deployment,packet,artifacts,scope['capacity'],selected['operator_arn'])
                return O.provision(L,name,packet,authorization,scope['foundation'])
            binding=journal.stage('foundation',foundation,foundation)
            atomic(L,registry/'foundation.json',binding)
            if 'foundation_iam_migration' not in scope:
                L['require'](not O.iam_migration(L,binding,selected)['required'],
                             'retained IAM migration is outside this authorization; prepare a new deploy review')
            migration=scope.get('foundation_iam_migration')
            if migration and migration['required']:
                def migrate():
                    return O.migrate_iam(L,name,binding,selected,migration,directory/'foundation-iam',authorization)
                binding=journal.stage('foundation-iam',migrate,migrate)
                atomic(L,registry/'foundation.json',binding)
            def repository():
                reference=scope['repository_reference']
                if reference: return reference['credential']
                if scope['new_private_access']: return O.onboard_key(L,deployment,selected,directory/'repository-access',authorization)
                return None
            reference=journal.stage('repository',repository,lambda:O.reconcile_key(L,deployment,selected,directory/'repository-access',authorization) if scope['new_private_access'] else repository())
            if reference:
                atomic(L,registry/(deployment['names']['workspace_id']+'-repository.json'),{'url':deployment['repository']['url'],'credential':reference})
                def access(): return O.access(L,name,binding,project['project'],reference,directory/'access',authorization)
                binding=journal.stage('access',access,access)
                atomic(L,registry/'foundation.json',binding)
            adapter=I.source_adapter({**deployment['dataset'],'maximum_bytes':project['dataset'].get('maximum_bytes',640*1024**3)},s3,project['region'])
            adapter.cancelled=cancelled
            L['require'](adapter.inventory(time.monotonic()+3600)==scope['dataset']['inventory'],'selected source changed; prepare a new review')
            previous=L['read'](registry/'dataset.json') if (registry/'dataset.json').exists() else None
            if previous:
                content=[{k:r[k] for k in ('path','bytes','sha256')} for r in scope['dataset']['inventory']]
                if previous['content_sha256']!=L['sha'](I.canonical(content)): previous=None
            def ingestion():
                nonlocal previous
                attempts=[p for p in directory.glob('ingestion*') if p.is_dir()]
                for attempt in attempts:
                    I.incomplete(L,s3,attempt,selected['account_id'])
                    if (attempt/'manifest.json').exists(): previous=L['read'](attempt/'manifest.json')
                output=directory/('ingestion-'+uuid.uuid4().hex if attempts else 'ingestion')
                return I.ingest(L,deployment,s3,output,adapter=adapter,previous=previous,inventory=scope['dataset']['inventory'])
            manifest=journal.stage('ingestion',ingestion,ingestion)
            atomic(L,registry/'dataset.json',manifest)
            value={'version':1,'target_name':name,'target':selected,'project':project['project'],'workspace_id':deployment['names']['workspace_id'],
                'repository':{'url':deployment['repository']['url'],'revision':deployment['repository']['revision']},
                'sizing':{k:scope['capacity']['selected'][k] for k in ('policy','instance_type','cpus','memory_mb','disk_gb','availability_zone')},
                'maximum_runtime_minutes':project['maximum_runtime_minutes'],'foundation':binding,'artifacts':str(directory/'artifacts/artifacts.json'),
                'job':{'commands':project['commands'],'outputs':scope['outputs'],
                    'dataset_manifest':{k:manifest[k] for k in ('bucket','manifest_key','manifest_version_id','manifest_sha256')},
                    'timeout_seconds':min(1800,(project['maximum_runtime_minutes']-10)*60)}}
            if reference: value['repository']['credential']=reference
            # Keep compatibility configuration closed; mode is carried by job only.
            if not technical.exists(): L['write'](technical,value)
            L['require'](L['read'](technical)==value,'generated runtime changed')
            os.environ['WORKSPACE_CONFIG']=str(technical)
            if reference: E.verify_ssh(L,base,client,value,selected)
            else: E.verify_public(L,value)
            starts=dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=5)
            if not control.exists(): W['render'](value,selected,str(control),L['stamp'](starts))
            runner=L['read'](control/'runner.json'); starts=L['utc'](runner['lease']['starts_at'])
            if not job:
                job=E.payload(value,selected,directory.name); job['mode']=project['mode']; L['write'](directory/'job.json',job)
            L['require'](len(base64.b64encode(L['canon'](job)))<=16384,'job arguments exceed reviewed SSM document bound')
            current=O.capacity(L,base,client,project['region'],project['resources'].get('maximum_hourly_usd'),
                               availability_zone=runner['availability_zone'])
            L['require'](any(c['instance_type']==runner['instance_type'] and c['hourly_usd']<=scope['capacity']['selected']['hourly_usd'] for c in current['candidates']),
                         'selected capacity/price no longer fits reviewed scope')
            def applied(stage,dep=None):
                runner['phase']='retire' if stage=='cleanup' else stage
                inputs=control/(stage+'-inputs.json')
                if not inputs.exists(): L['write'](inputs,runner)
                return apply_stage(L,name,stage,inputs,control/stage,authorization,dep)
            journal.stage('prepare',lambda:applied('prepare',binding['plan_directory']),lambda:applied('prepare',binding['plan_directory']))
            if reference: E.verify_credential_access(L,base,client,value,selected,runner,directory)
            while dt.datetime.now(dt.timezone.utc)<starts:
                L['require'](not cancelled(),'cancel requested'); time.sleep(min(2,(starts-dt.datetime.now(dt.timezone.utc)).total_seconds()))
            journal.stage('launch',lambda:applied('launch',str(control/'prepare')))
            instance=L['read'](control/'launch/launched-owned.json')['instance_id']; result['infrastructure_ready']=True
            journal.stage('job',lambda:E.run_command(L,base,client,selected,runner,control/'launch',instance,job,directory/'execution',cancelled=cancelled))
            verified=journal.stage('verify',lambda:E.verify_generic_result(L,value,selected,job,runner,instance,s3,directory/'before'))
            result.update({k:verified['execution'][k] for k in ('infrastructure_ready','setup_exit','job_exit','outputs_persisted')})
            result['output_uri']=job['output_uri']; result['instance_id']=instance
            if project['mode']=='workspace' and result['setup_exit']==0:
                result.update(status='workspace_ready',cleanup_status='retained_until_cancel_or_expiry')
        except BaseException as error:
            result['error']=E.safe_error(error); journal.record('controller','interrupted',result['error'])
        finally:
            for sig in old_handlers: signal.signal(sig,signal.SIG_IGN)
            if cancelled(): result['status']='cancelled'
            if result['status']!='workspace_ready':
                try:
                    cleaned=cleanup_runner(L,name,control,runner,authorization) if runner else {'cleanup_status':'not_needed'}
                    result.update(cleaned); journal.record('cleanup','completed',cleaned)
                    if job: abort_outputs(L,s3,scope,job,directory)
                    if result['outputs_persisted'] and (directory/'before/verification.json').exists():
                        E.verify_generic_result(L,L['read'](technical),selected,job,runner,result['instance_id'],s3,directory/('after-'+uuid.uuid4().hex),L['read'](directory/'before/verification.json'))
                        result['verified_after_compute_deletion']=True
                    if not cancelled() and result['setup_exit']==0 and result['job_exit']==0 and result['outputs_persisted'] and result['verified_after_compute_deletion']:
                        result['status']='success'
                    if (control/'prepare/apply-started.json').exists() and result['cleanup_status']=='success': active.unlink()
                    elif not (control/'prepare/apply-started.json').exists():
                        uncertain_access=any(journal.latest(stage) and journal.latest(stage)['state'] in ('started','unknown') for stage in ('foundation-iam','repository','access'))
                        completed=journal.latest('foundation') and journal.latest('foundation')['state']=='completed'
                        uncertain_foundation=not completed and any(p.name=='apply-started.json' and not (p.parent/'apply-result.json').exists() for p in (directory/'foundation').rglob('apply-started.json'))
                        if not uncertain_access and not uncertain_foundation: active.unlink()
                except BaseException as error:
                    result.update(cleanup_status='unknown',cleanup_error=E.safe_error(error),recovery='use resume; provider expiry remains armed')
                    journal.record('cleanup','unknown',result['cleanup_error'])
            atomic(L,directory/'result.json',result); journal.record('operation',result['status'],result)
            for sig,handler in old_handlers.items(): signal.signal(sig,handler)
        return result


def deploy(W,config,directory=None,authorization=None):
    L=W['L']
    if authorization and directory is None: directory=latest(L,config)
    directory,scope=prepare(W,config,directory)
    if not authorization: authorization=confirm(L,scope)
    if not authorization: return {'status':'review_required','operation_directory':str(directory),'review':scope,'cloud_mutations':False}
    L['require'](len(authorization.strip())>=12 and L['source']()['working_tree_sha256']==L['sha'](b''),'task authorization and clean committed source required')
    task={'scope_sha256':L['sha'](L['canon'](scope)),'authorization':authorization,'authorized_at':L['stamp']()}
    L['write'](directory/'task-authorization.json',task)
    return execute(W,config,directory,scope,task)


def completed_result(L,directory):
    result_path=directory/'result.json'
    if result_path.exists():
        result=L['read'](result_path)
        if result['status'] in ('success','cancelled') and result['cleanup_status'] in ('success','not_needed'):
            return result
    return None


def resume(W,config,directory):
    directory,scope,task=validate_operation(W,config,directory)
    result=completed_result(W['L'],directory)
    if result is not None: return result
    return execute(W,config,directory,scope,task,resume=True)


def cancel(W,config,directory):
    L=W['L']; directory,scope,task=validate_operation(W,config,directory)
    result=completed_result(L,directory)
    if result is not None: return result
    if not (directory/'cancel.json').exists(): L['write'](directory/'cancel.json',{'requested_at':L['stamp'](),'scope_sha256':task['scope_sha256']})
    try: return execute(W,config,directory,scope,task,resume=True)
    except ValueError as error:
        if 'busy' in str(error): return {'status':'cancellation_requested','provider_expiry':'retained'}
        raise
