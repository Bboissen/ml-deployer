#!/usr/bin/env bash
# No account API calls. Preserve every test run under ignored evidence/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec "${WORKSPACE_PYTHON:-python3}" - <<'PY'
import copy
import datetime as dt
import hashlib
import io
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
ROOT=Path.cwd()
OUT=ROOT/'evidence/aws/tests/cd'/ (dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'-'+str(os.getpid()))
OUT.mkdir(parents=True)

def module(path):
    text=(ROOT/path).read_text()
    if path.endswith('.sh'): text=text.split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
    ns={'__name__':'offline_test'}; exec(compile(text,path,'exec'),ns); return ns

fake_boto=types.ModuleType('boto3'); fake_cfg=types.ModuleType('botocore.config'); fake_cfg.Config=lambda **kwargs:kwargs
with patch.dict(sys.modules,{'boto3':fake_boto,'botocore.config':fake_cfg}):
    GUARD=module('infra/aws/runner/workspace/watchdog.py.tftpl')
LIFE=module('scripts/aws/workspace-lifecycle.sh')
T=dt.datetime(2026,10,8,12,tzinfo=dt.timezone.utc)
OWN={'GuardId':'a'*32,'Project':'ml-infra','Root':'runner','ManagedBy':'opentofu'}
TAGS={**OWN,'WorkspaceId':'fraud-detection-dev-01','LeaseId':'b'*32,'LeaseStart':'2026-10-08T11:00:00Z','LaunchBefore':'2026-10-08T11:05:00Z','ExpiresAt':'2026-10-08T12:00:00Z'}
EVENT={'kind':'sweep','guard_id':OWN['GuardId']}

def instance(state='running',tags=None,id='i-00000000000000001'):
    return {'InstanceId':id,'State':{'Name':state},'Tags':[{'Key':k,'Value':v} for k,v in (tags or TAGS).items()]}

class EC2:
    def __init__(self,items): self.items=items; self.terminated=[]; self.drift=False; self.missing=False; self.pages=False; self.fail=False
    def describe_instances(self,**kwargs):
        items=self.items
        if 'InstanceIds' in kwargs:
            items=[copy.deepcopy(i) for i in items if i['InstanceId'] in kwargs['InstanceIds']]
            if self.missing: items=[]
            if self.drift: items[0]['Tags'].append({'Key':'ExpiresAt','Value':'2027-01-01T00:00:00Z'})
        page={'Reservations':[{'Instances':items}]}
        if self.pages and 'InstanceIds' not in kwargs and 'NextToken' not in kwargs: page['NextToken']='next'
        return page
    def terminate_instances(self,InstanceIds):
        if self.fail: raise RuntimeError('offline termination failure')
        self.terminated.extend(InstanceIds)
        for i in self.items:
            if i['InstanceId'] in InstanceIds: i['State']['Name']='shutting-down'

class Watchdog(unittest.TestCase):
    def sweep(self,ec2,event=EVENT,now=T,**kwargs): return GUARD['sweep'](ec2,event,OWN,now,**kwargs)
    def test_margin_is_exactly_five_minutes(self):
        self.assertFalse(GUARD['due'](TAGS,T-dt.timedelta(minutes=5,seconds=1)))
        self.assertTrue(GUARD['due'](TAGS,T-dt.timedelta(minutes=5)))
    def test_pending_stopped_and_failed_bootstrap_are_terminated(self):
        for state in ('pending','running','stopped','stopping'):
            ec2=EC2([instance(state)]); self.sweep(ec2); self.assertEqual(len(ec2.terminated),1)
    def test_duplicate_events_do_not_repeat_termination(self):
        ec2=EC2([instance()]); self.sweep(ec2); self.sweep(ec2); self.assertEqual(len(ec2.terminated),1)
    def test_late_deadline_does_not_kill_newer_lease(self):
        ec2=EC2([instance(tags={**TAGS,'LeaseId':'c'*32})])
        self.sweep(ec2,dict(EVENT,kind='lease',lease_id='b'*32,workspace_id=TAGS['WorkspaceId']))
        self.assertEqual(ec2.terminated,[])
    def test_foreign_resources_are_preserved_even_if_filter_returns_them(self):
        for key in OWN:
            ec2=EC2([instance(tags={**TAGS,key:'foreign'})]); self.sweep(ec2); self.assertEqual(ec2.terminated,[])
    def test_invalid_owned_lease_is_fail_closed(self):
        for change in ({'ExpiresAt':'bad'},{'LaunchBefore':'2026-10-08T11:20:00Z'},{'LeaseId':'bad'},{'ExpiresAt':'2026-10-10T12:00:00Z'}):
            ec2=EC2([instance(tags={**TAGS,**change})]); self.sweep(ec2); self.assertEqual(len(ec2.terminated),1)
    def test_changed_tags_and_eventual_visibility_never_emit_success(self):
        for flag in ('drift','missing'):
            ec2=EC2([instance()]); setattr(ec2,flag,True)
            with self.assertRaises(ValueError): self.sweep(ec2)
            self.assertEqual(ec2.terminated,[])
    def test_failed_termination_is_not_a_completed_sweep(self):
        ec2=EC2([instance()]); ec2.fail=True
        with self.assertRaises(RuntimeError): self.sweep(ec2)
    def test_incomplete_pagination_times_out_without_heartbeat(self):
        ec2=EC2([]); ec2.pages=True; remaining=iter([20,0])
        with self.assertRaises(TimeoutError): self.sweep(ec2,remaining=lambda:next(remaining))
    def test_targeted_events_cannot_forge_full_heartbeat(self):
        fake_boto.client=lambda *a,**k:EC2([])
        env={'GUARD_ID':OWN['GuardId'],'OWNER_PROJECT':'ml-infra','ACCOUNT_ID':'000000000000','CODE_SHA256':'d'*64,'AWS_REGION':'us-east-1'}
        ctx=types.SimpleNamespace(get_remaining_time_in_millis=lambda:25000)
        with patch.dict(os.environ,env),patch('sys.stdout',new_callable=io.StringIO):
            result=GUARD['handler'](dict(EVENT,kind='lease',lease_id='b'*32,workspace_id=TAGS['WorkspaceId']),ctx)
        self.assertEqual(result['kind'],'lease_result')

class Boundary(unittest.TestCase):
    def test_changed_schedule_timezone_or_end_closes_guard(self):
        config={'guard':{'guard_id':'a'*32,'function_arn':'function','invoker_role_arn':'role','failure_queue_arn':'queue'},
                'aws_account_id':'000000000000','aws_region':'us-east-1','resource_prefix':'ml-infra',
                'workspace_identity':{'ml_project_name':'demo','request':{'workspace_id':'demo-dev-01'}}}
        value={'State':'ENABLED','ScheduleExpression':'rate(1 minute)','ScheduleExpressionTimezone':'UTC','ActionAfterCompletion':'NONE',
               'FlexibleTimeWindow':{'Mode':'OFF'},'Target':{'Arn':'function','RoleArn':'role',
               'Input':json.dumps({'kind':'sweep','guard_id':'a'*32}),'RetryPolicy':{'MaximumEventAgeInSeconds':300,'MaximumRetryAttempts':3},
               'DeadLetterConfig':{'Arn':'queue'}}}
        self.assertTrue(LIFE['schedule_matches'](value,config,'sweep'))
        for drift in ({'ScheduleExpressionTimezone':'America/Denver'},{'EndDate':T},{'StartDate':T},{'ActionAfterCompletion':'DELETE'}):
            self.assertFalse(LIFE['schedule_matches']({**value,**drift},config,'sweep'))
    def test_changed_alarm_destination_closes_guard(self):
        fields={key:None for key in LIFE['ALARM_FIELDS']};fields.update(dimensions={},alarm_actions=['reviewed-topic'])
        resources=[{'address':'aws_cloudwatch_metric_alarm.workspace_guard'+str(i),'values':{**fields,'alarm_name':'alarm'+str(i)}} for i in range(4)]
        plan={'planned_values':{'root_module':{'resources':resources}}}
        details={'alarms':{'alarm'+str(i):copy.deepcopy(fields) for i in range(4)}}
        LIFE['compare_platform_alarms'](plan,details)
        details['alarms']['alarm0']['alarm_actions']=['different-topic']
        with self.assertRaises(LIFE['Failure']): LIFE['compare_platform_alarms'](plan,details)
    def test_shared_lambda_limit_blocks_insufficient_pool(self):
        for total,unreserved in ((4,4),(5,4),(0,0)):
            api=types.SimpleNamespace(get_account_settings=lambda:{'AccountLimit':{'ConcurrentExecutions':total,'UnreservedConcurrentExecutions':unreserved}})
            with self.assertRaises(LIFE['Failure']): LIFE['shared_lambda_pool'](None,lambda *_:api)
        api=types.SimpleNamespace(get_account_settings=lambda:{'AccountLimit':{'ConcurrentExecutions':5,'UnreservedConcurrentExecutions':5}})
        self.assertEqual(LIFE['shared_lambda_pool'](None,lambda *_:api)['UnreservedConcurrentExecutions'],5)
    def test_explicit_lease_never_extends_after_reconnect(self):
        request={'maximum_runtime_minutes':60}
        a=LIFE['lease'](request,'2026-10-08T12:00:00Z'); b=LIFE['lease'](request,'2026-10-08T12:00:00Z')
        self.assertNotEqual(a['id'],b['id']); self.assertEqual(a['expires_at'],b['expires_at'])
        self.assertEqual(a['launch_before'],'2026-10-08T12:05:00Z')
    def test_zip_is_deterministic_and_never_overwrites(self):
        a,b=OUT/'a.zip',OUT/'b.zip'; members={'script':b'bounded source','lock':b'pinned'}
        self.assertEqual(LIFE['archive'](a,members),LIFE['archive'](b,members))
        with self.assertRaises(FileExistsError): LIFE['archive'](a,members)
    def test_scope_rejects_prepare_compute_and_launch_iam(self):
        def plan(address,type,actions): return {'resource_changes':[{'address':address,'type':type,'mode':'managed','change':{'actions':actions,'after':{}}}]}
        for stage,p in [('prepare',plan('aws_instance.workspace[0]','aws_instance',['create'])),('launch',plan('aws_iam_role.launch','aws_iam_role',['update'])),('cleanup',plan('aws_s3_bucket.project','aws_s3_bucket',['delete'])),('platform',plan('aws_vpc.runner','aws_vpc',['update']))]:
            with self.assertRaises(LIFE['Failure']): LIFE['plan_scope'](p,stage)
    def test_exact_authorization_hash_and_immutable_ledger(self):
        directory=OUT/'authorization'; directory.mkdir(); review={'plan_sha256':'a'*64,'scope':[{'address':'owned','actions':['create']}]}
        LIFE['write'](directory/'review.json',review)
        with self.assertRaises(LIFE['Failure']): LIFE['authorize'](directory,'b'*64,'Explicit offline approval')
        expected=LIFE['sha'](LIFE['canon'](review)); LIFE['authorize'](directory,expected,'Explicit offline approval')
        with self.assertRaises(FileExistsError): LIFE['authorize'](directory,expected,'Explicit offline approval')
        review['plan_sha256']='b'*64
        self.assertNotEqual(expected,LIFE['sha'](LIFE['canon'](review)))
    def test_apply_rejects_changed_plan_before_any_native_call(self):
        directory=OUT/'changed-plan'; directory.mkdir()
        m={'source':LIFE['source'](),'config_sha256':LIFE['sha'](LIFE['canon']({})),'artifacts':{},'dependencies':[],
           'plan_sha256':'a'*64,'scope':[]}
        LIFE['write'](directory/'review.json',m); LIFE['write'](directory/'config.tfvars.json',{})
        LIFE['write'](directory/'authorization.json',{'review_sha256':LIFE['sha'](LIFE['canon'](m)),'plan_sha256':'a'*64,'scope':[]})
        (directory/'saved.tfplan').write_bytes(b'changed')
        with self.assertRaises(LIFE['Failure']): LIFE['apply'](directory)
        self.assertFalse((directory/'apply-started.json').exists())
    def test_evidence_escape_is_rejected(self):
        with self.assertRaises(LIFE['Failure']): LIFE['checked_path'](ROOT/'outside-plan.json')
    def test_duplicate_and_nonfinite_configuration_are_rejected(self):
        for label,text in [('duplicate','{"region":"a","region":"b"}'),('nonfinite','{"cpus":NaN}')]:
            path=OUT/(label+'.json'); path.write_text(text)
            with self.assertRaises(LIFE['Failure']): LIFE['read'](path)
    def test_backend_permission_error_is_never_fresh_state(self):
        class ClientError(Exception):
            response={'Error':{'Code':'403'}}
        fake=types.SimpleNamespace(exceptions=types.SimpleNamespace(ClientError=ClientError),
            get_bucket_location=lambda **k:{'LocationConstraint':None},get_bucket_versioning=lambda **k:{'Status':'Enabled'})
        def head(**k): raise ClientError()
        fake.head_object=head
        target={'region':'us-east-1','account_id':'000000000000','backend':{'bucket':'offline-state'}}
        with self.assertRaises(LIFE['Failure']): LIFE['snapshot'](None,lambda *a:fake,target,'owned.tfstate')
    def test_deleted_state_with_history_requires_reviewed_recovery(self):
        class ClientError(Exception):
            response={'Error':{'Code':'404'}}
        fake=types.SimpleNamespace(exceptions=types.SimpleNamespace(ClientError=ClientError),
            get_bucket_location=lambda **k:{'LocationConstraint':None},get_bucket_versioning=lambda **k:{'Status':'Enabled'},
            list_object_versions=lambda **k:{'DeleteMarkers':[{'Key':'owned.tfstate'}]})
        def head(**k): raise ClientError()
        fake.head_object=head
        target={'region':'us-east-1','account_id':'000000000000','backend':{'bucket':'offline-state'}}
        with self.assertRaises(LIFE['Failure']): LIFE['snapshot'](None,lambda *a:fake,target,'owned.tfstate')
    def test_backend_snapshot_binds_version_lineage_serial_and_hash(self):
        raw=b'{"lineage":"offline-lineage","serial":7}'
        fake=types.SimpleNamespace(exceptions=types.SimpleNamespace(ClientError=RuntimeError),
            get_bucket_location=lambda **k:{'LocationConstraint':None},get_bucket_versioning=lambda **k:{'Status':'Enabled'},
            head_object=lambda **k:{'VersionId':'native-version','ContentLength':len(raw)},
            get_object=lambda **k:{'Body':io.BytesIO(raw)})
        target={'region':'us-east-1','account_id':'000000000000','backend':{'bucket':'offline-state'}}
        snapshot=LIFE['snapshot'](None,lambda *a:fake,target,'owned.tfstate')
        self.assertEqual(snapshot,{'key':'owned.tfstate','version':'native-version','lineage':'offline-lineage','serial':7,'sha256':hashlib.sha256(raw).hexdigest()})
    def test_cleanup_refuses_live_pending_and_stopped_compute(self):
        config={'guard':{'guard_id':OWN['GuardId']},'workspace_identity':{'request':{'workspace_id':TAGS['WorkspaceId']}},'lease':{'id':TAGS['LeaseId']}}
        for state in ('running','pending','stopped','shutting-down'):
            fake=EC2([instance(state)])
            with self.assertRaises(LIFE['Failure']): LIFE['inventory'](None,lambda *a:fake,config)
    def test_saved_apply_rejects_backend_state_drift_without_mutation(self):
        directory=OUT/'state-drift'; directory.mkdir(); root=directory/'root'; root.mkdir()
        (root/'.terraform.lock.hcl').write_bytes(b'offline-lock')
        plan={'resource_changes':[{'address':'aws_iam_role.launch','type':'aws_iam_role','mode':'managed','change':{'actions':['create'],'after':{}}}]}
        LIFE['write'](directory/'config.tfvars.json',{}); LIFE['write'](directory/'plan.json',plan); (directory/'saved.tfplan').write_bytes(b'offline-plan')
        m={'stage':'prepare','target_name':'offline','target':{'account':'offline'},'identities':{'sdk':'expected'},
           'state':{'serial':1},'source':LIFE['source'](),'config_sha256':LIFE['sha'](LIFE['canon']({})),'dependencies':[],'artifacts':{},
           'root':str(root),'lock_sha256':LIFE['sha'](b'offline-lock'),'plan_sha256':LIFE['sha'](b'offline-plan'),
           'plan_json_sha256':LIFE['sha']((directory/'plan.json').read_bytes()),'scope':LIFE['plan_scope'](plan,'prepare')}
        LIFE['write'](directory/'review.json',m); LIFE['authorize'](directory,LIFE['sha'](LIFE['canon'](m)),'Explicit offline approval')
        called=[]
        with patch.dict(LIFE,{'context':lambda *a:(m['target'],{},None,None,m['identities'],{'serial':2}),
                             'run':lambda *a:called.append(a)}):
            with self.assertRaises(LIFE['Failure']): LIFE['apply'](directory)
        self.assertEqual(called,[]); self.assertFalse((directory/'apply-started.json').exists())

def evaluate(document,action,resource,context):
    # Covers only emitted IAM operators; does not attest SCP/account/live rights.
    def values(value): return value if isinstance(value,list) else [value]
    allowed=False
    for statement in document['Statement']:
        key='Action' if 'Action' in statement else 'NotAction'
        matched=any(fnmatch.fnmatchcase(action.lower(),p.lower()) for p in values(statement[key]))
        if matched==(key=='NotAction'): continue
        if not any(fnmatch.fnmatchcase(resource,p) for p in values(statement['Resource'])): continue
        matched=True
        for op,items in statement.get('Condition',{}).items():
            for name,expected in items.items():
                actual=context.get(name)
                if op in ('StringEquals','ArnEquals','Bool'): ok=actual in values(expected)
                elif op in ('StringNotEquals','ArnNotEquals'): ok=actual not in values(expected)
                elif op=='DateGreaterThanEquals': ok=actual is not None and LIFE['utc'](actual)>=LIFE['utc'](expected)
                elif op=='DateLessThanEquals': ok=actual is not None and LIFE['utc'](actual)<=LIFE['utc'](expected)
                elif op=='NumericGreaterThan': ok=actual is not None and float(actual)>float(expected)
                else: raise AssertionError('unmodeled IAM operator '+op)
                matched=matched and ok
        if matched:
            if statement['Effect']=='Deny': return False
            allowed=True
    return allowed

def iam_cases(runner,platform,config):
    def resource(plan,address): return next(r['values'] for r in plan['planned_values']['root_module']['resources'] if r['address']==address)
    launch=json.loads(resource(runner,'aws_iam_role_policy.launch')['policy'])
    ceiling=json.loads(resource(platform,'aws_iam_policy.workspace_launch_boundary["active"]')['policy'])
    guard=json.loads(resource(platform,'aws_iam_role_policy.workspace_guard["active"]')['policy'])
    arn='arn:aws:ec2:us-east-1:000000000000:instance/i-00000000000000001'
    tags=resource(runner,'aws_instance.workspace[0]')['tags']
    context={**{'aws:RequestTag/'+k:v for k,v in tags.items()},'aws:CurrentTime':config['lease']['starts_at'],
             'ec2:InstanceType':'r8i.2xlarge','ec2:MetadataHttpTokens':'required','ec2:MetadataHttpPutResponseHopLimit':'1',
             'ec2:InstanceProfile':'arn:aws:iam::000000000000:instance-profile/'+LIFE['role_name'](config)}
    count=0
    def check(doc,action,resource,ctx,expected):
        nonlocal count
        if evaluate(doc,action,resource,ctx)!=expected: raise AssertionError('IAM case failed: '+action+' '+resource)
        count+=1
    check(launch,'ec2:RunInstances',arn,context,True); check(ceiling,'ec2:RunInstances',arn,context,True)
    for key in tags:
        changed={**context,'aws:RequestTag/'+key:'wrong'}; check(launch,'ec2:RunInstances',arn,changed,False)
        missing=dict(context); del missing['aws:RequestTag/'+key]; check(launch,'ec2:RunInstances',arn,missing,False)
    for time_value in (LIFE['stamp'](LIFE['utc'](config['lease']['starts_at'])-dt.timedelta(seconds=1)),LIFE['stamp'](LIFE['utc'](config['lease']['launch_before'])+dt.timedelta(seconds=1))):
        check(launch,'ec2:RunInstances',arn,{**context,'aws:CurrentTime':time_value},False)
    for key,value in [('ec2:InstanceType','m7i.large'),('ec2:MetadataHttpTokens','optional'),('ec2:MetadataHttpPutResponseHopLimit','2')]:
        check(ceiling,'ec2:RunInstances',arn,{**context,key:value},False)
    for key in ('GuardId','ManagedBy','Root','Project'):
        check(ceiling,'ec2:RunInstances',arn,{**context,'aws:RequestTag/'+key:'wrong'},False)
    check(launch,'ec2:RunInstances',arn,{**context,'ec2:InstanceProfile':'arn:aws:iam::000000000000:instance-profile/other'},False)
    check(ceiling,'ec2:RunInstances',arn.replace(':instance/',':volume/'),{'ec2:Encrypted':'false'},False)
    for action in ('ec2:StartInstances','ec2:ModifyInstanceAttribute','ec2:DeleteTags','iam:PutRolePolicy','scheduler:UpdateSchedule'):
        check(launch,action,arn,context,False)
    for dependency in ('arn:aws:ec2:us-east-1::image/ami-wrong','arn:aws:ec2:us-east-1:000000000000:subnet/subnet-other','arn:aws:ec2:us-east-1:000000000000:security-group/sg-other'):
        check(launch,'ec2:RunInstances',dependency,context,False)
    check(launch,'ec2:CreateTags',arn,{'ec2:CreateAction':'RunInstances'},True)
    check(launch,'ec2:CreateTags',arn,{},False)
    guardctx={'ec2:ResourceTag/'+k:v for k,v in {'GuardId':config['guard']['guard_id'],'ManagedBy':'opentofu','Project':'ml-infra','Root':'runner'}.items()}
    check(guard,'ec2:TerminateInstances',arn,guardctx,True)
    for key in guardctx: check(guard,'ec2:TerminateInstances',arn,{**guardctx,key:'foreign'},False)
    check(guard,'iam:PutRolePolicy','*',{},False)
    (OUT/'iam-offline.json').write_text(json.dumps({'cases':count,'passed':True,'native_rights':'unverified'},indent=2))
    return count

def tofu_tests():
    identity=json.loads((ROOT/'tests/aws/fixtures/workspace-identity.json').read_text())
    identity['request']['operators']=['arn:aws:iam::000000000000:user/sposhfi-admin']
    identity['request']['resources']={'cpus':8,'memory_mb':60000,'disk_gb':25}
    start=dt.datetime.now(dt.timezone.utc)-dt.timedelta(seconds=30)
    lease=LIFE['lease'](identity['request'],LIFE['stamp'](start))
    guard_id=hashlib.sha256(b'000000000000/us-east-1/ml-infra/workspace-v1').hexdigest()[:32]
    guard={'guard_id':guard_id,'function_arn':'arn:aws:lambda:us-east-1:000000000000:function:ml-infra-workspace-watchdog:1',
           'code_sha256':'d'*64,'invoker_role_arn':'arn:aws:iam::000000000000:role/ml-infra-workspace-watchdog-invoke',
           'recurring_schedule_name':'ml-infra-workspace-watchdog-sweep','log_group':'/aws/lambda/ml-infra-workspace-watchdog',
           'failure_queue_arn':'arn:aws:sqs:us-east-1:000000000000:ml-infra-workspace-watchdog-failures','alarm_names':['offline-alarm']}
    members={p.name:p.read_bytes() for p in (ROOT/'infra/aws/runner/workspace/toolbox').iterdir() if p.is_file()}
    for name in ('scripts/workspace/probe-toolbox.py','shared/workspace/toolbox.json','scripts/aws/clone-project.sh','scripts/aws/workspace-guest-observe.sh'): members[name]=(ROOT/name).read_bytes()
    toolbox_sha=LIFE['archive'](OUT/'toolbox.zip',members)
    config={'aws_account_id':'000000000000','aws_region':'us-east-1','resource_prefix':'ml-infra','project_name':'ml-infra',
            'backend_bucket_name':'replace-ml-infra-aws-state-unique','state_bucket_arn':'arn:aws:s3:::replace-ml-infra-aws-state-unique',
            'deployer_role_arn':'arn:aws:iam::000000000000:role/ml-infra-tofu-deployer','subnet_id':'subnet-00000000000000001',
            'security_group_id':'sg-00000000000000001','workspace_identity':identity,'guard':guard,'lease':lease,
            'toolbox_zip_path':str(OUT/'toolbox.zip'),'toolbox_zip_sha256':toolbox_sha,
            'guard_observation':{'observed_at':LIFE['stamp'](),'heartbeat_at':LIFE['stamp'](),'guard_id':guard_id,'code_sha256':'d'*64,
                                 'recurrence_enabled':True,'deadline_enabled':True,'iam_verified':True,'alarms_ok':True}}
    config_path=OUT/'runner.tfvars.json'; config_path.write_text(json.dumps(config))
    platform={'workspace_guard':{'zip_path':str(OUT/'toolbox.zip'),'zip_sha256':toolbox_sha,'alarm_topic_arn':'arn:aws:sns:us-east-1:000000000000:offline-review'}}
    platform_path=OUT/'platform.tfvars.json'; platform_path.write_text(json.dumps(platform))
    plans={}
    for root,testdir,varfile in [('infra/aws/runner/workspace','../../../../tests/aws/workspace',config_path),('infra/aws/platform','../../../tests/aws/guard',platform_path)]:
        label='runner' if root.endswith('workspace') else 'platform'
        env={k:v for k,v in os.environ.items() if not k.startswith(('AWS_','TF_'))}
        env.update(TF_DATA_DIR=str(OUT/(label+'-data')),AWS_EC2_METADATA_DISABLED='true',PYTHONDONTWRITEBYTECODE='1')
        for phase,args in [('init',['init','-backend=false','-lockfile=readonly','-input=false','-no-color']),('test',['test','-test-directory='+testdir,'-var-file='+str(varfile),'-json','-verbose','-no-color'])]:
            log=OUT/(label+'-'+phase+'.log')
            with log.open('w') as f: result=subprocess.run(['tofu','-chdir='+root,*args],env=env,stdout=f,stderr=subprocess.STDOUT,timeout=180)
            if result.returncode: raise RuntimeError(label+' '+phase+' failed: '+str(log.relative_to(ROOT)))
        events=[json.loads(line) for line in log.read_text().splitlines()]
        plans[label]={e['@testrun']:e['test_plan'] for e in events if e.get('type')=='test_plan'}
    runner=plans['runner']['guarded_launch_is_encrypted_disposable_and_tagged']
    resources={r['address']:r for r in runner['configuration']['root_module']['resources']}
    depends=resources['aws_instance.workspace'].get('depends_on',[])
    for name in ('aws_scheduler_schedule.workspace_deadline','aws_iam_role_policy.launch','aws_iam_instance_profile.workspace','aws_ssm_document.terminal','aws_iam_user_policy.operator'):
        if name not in depends: raise AssertionError('missing guard/identity/terminal ordering: '+name)
    LIFE['plan_scope']({'resource_changes':[r for r in runner['resource_changes'] if r['address']=='aws_instance.workspace[0]']},'launch')
    return {'workspace_mocked_plans':len(plans['runner']),'workspace_mocked_apply_cases':1,'platform_mocked_plans':len(plans['platform']),
            'iam_cases':iam_cases(runner,plans['platform']['persistent_sweep_failure_path_and_runtime_ceiling'],config)}

result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
require_success=result.wasSuccessful()
metadata={'scope':'offline only; no native acceptance or cloud mutation','unit_cases':result.testsRun,'unit_passed':require_success}
if require_success:
    try: metadata.update(tofu_tests(),passed=True)
    except Exception as exc: metadata.update(passed=False,error=str(exc)); print(str(exc),file=sys.stderr)
else: metadata['passed']=False
(OUT/'result.json').write_text(json.dumps(metadata,indent=2)+'\n')
print('test-aws-workspace-cd: '+('PASS' if metadata['passed'] else 'FAIL')+'; evidence='+str(OUT.relative_to(ROOT)))
sys.exit(0 if metadata['passed'] else 1)
PY
