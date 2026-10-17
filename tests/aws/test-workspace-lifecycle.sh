#!/usr/bin/env bash
# No account API calls. Preserve every test run under ignored evidence/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec "${WORKSPACE_PYTHON:-python3}" - <<'PY'
import base64
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
from unittest.mock import Mock, patch
import botocore.exceptions as sdk_errors

sys.dont_write_bytecode=True
ROOT=Path.cwd()
sys.path.insert(0, str(ROOT/'scripts/aws'))
OUT=ROOT/'evidence/aws/tests/cd'/ (dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'-'+str(os.getpid()))
OUT.mkdir(parents=True)

def module(path):
    text=(ROOT/path).read_text()
    if path.endswith('.sh'): text=text.split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
    ns={'__name__':'offline_test','__file__':str(ROOT/path)}; exec(compile(text,path,'exec'),ns); return ns

fake_boto=types.ModuleType('boto3'); fake_cfg=types.ModuleType('botocore.config'); fake_cfg.Config=lambda **kwargs:kwargs
with patch.dict(sys.modules,{'boto3':fake_boto,'botocore.config':fake_cfg}):
    GUARD=module('infra/aws/runner/workspace/watchdog.py.tftpl')
LIFE=module('scripts/aws/workspace_lifecycle.py')
WORKSPACE=module('scripts/aws/workspace.py')
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

class SDKSessionBoundary(unittest.TestCase):
    def setUp(self):
        self.target={'profile':'offline','region':'us-east-1','account_id':'000000000000',
                     'operator_arn':'arn:aws:iam::000000000000:user/operator'}
        self.responses={}
        self.identity={'Account':self.target['account_id'],'Arn':self.target['operator_arn']}
        self.calls=[]
        def client(service,**kwargs):
            self.calls.append((service,kwargs))
            region,endpoint=self.responses.get(service,('us-east-1','https://'+service+'.us-east-1.amazonaws.com'))
            return types.SimpleNamespace(meta=types.SimpleNamespace(region_name=region,endpoint_url=endpoint),
                                         get_caller_identity=lambda:self.identity)
        self.session=types.SimpleNamespace(client=client)
        self.boto=types.SimpleNamespace(__version__='1.43.109',Session=lambda **kwargs:self.session)
        self.core=types.SimpleNamespace(__version__='1.43.109',exceptions=sdk_errors)
    def sessions(self):
        with patch.dict(sys.modules,{'boto3':self.boto,'botocore':self.core,'botocore.config':fake_cfg}):
            return LIFE['sessions'](self.target)
    def test_expired_or_missing_native_login_prints_the_selected_recovery_command(self):
        errors=(sdk_errors.LoginRefreshRequired(), sdk_errors.LoginTokenLoadError(error_msg='SENTINEL_SECRET'),
                sdk_errors.UnauthorizedSSOTokenError(), sdk_errors.SSOTokenLoadError(error_msg='SENTINEL_SECRET'))
        for error in errors:
            for stage in ('session','client','identity'):
                with self.subTest(error=type(error).__name__,stage=stage):
                    session=Mock()
                    if stage=='session': session.side_effect=error
                    elif stage=='client': session.return_value.client.side_effect=error
                    else:
                        sts=session.return_value.client.return_value
                        sts.meta=types.SimpleNamespace(region_name='us-east-1',endpoint_url='https://sts.us-east-1.amazonaws.com')
                        sts.get_caller_identity.side_effect=error
                    with patch.object(self.boto,'Session',session),self.assertRaises(LIFE['Failure']) as caught:
                        self.sessions()
                    self.assertIn('./workspace login --profile offline --region us-east-1',str(caught.exception))
                    self.assertIn('fresh review',str(caught.exception)); self.assertNotIn('SENTINEL',str(caught.exception))
                    session.assert_called_once_with(profile_name='offline',region_name='us-east-1')
    def test_permission_errors_are_not_reported_as_expired_login(self):
        error=sdk_errors.ClientError({'Error':{'Code':'AccessDenied','Message':'SENTINEL_SECRET'}},'GetCallerIdentity')
        with patch.object(self.boto,'Session',side_effect=error),self.assertRaises(sdk_errors.ClientError) as caught:
            self.sessions()
        self.assertIs(caught.exception,error)
    def test_standard_global_iam_is_accepted(self):
        self.responses['iam']=('aws-global','https://iam.amazonaws.com')
        base,client,_=self.sessions()
        self.assertEqual(client(base,'iam').meta.region_name,'aws-global')
        self.assertEqual(self.calls[-1][1]['region_name'],'us-east-1')
    def test_connections_are_reused_only_within_the_same_session_and_service(self):
        base,client,_=self.sessions()
        first=client(base,'ec2')
        self.assertIs(client(base,'ec2'),first)
        self.assertEqual([s for s,_ in self.calls].count('ec2'),1)
        self.assertIsNot(client(base,'s3'),first)
        assumed=types.SimpleNamespace(client=self.session.client)
        other=client(assumed,'ec2')
        self.assertIsNot(other,first)
        self.assertIs(client(assumed,'ec2'),other)
        self.assertEqual([s for s,_ in self.calls].count('ec2'),2)
        # Reusing a transport never reuses a prior API response.
        self.identity={'Account':'changed','Arn':'changed'}
        self.assertEqual(client(base,'sts').get_caller_identity()['Account'],'changed')
    def test_rejected_clients_are_not_cached(self):
        base,client,_=self.sessions()
        self.responses['ec2']=('us-west-2','https://ec2.us-west-2.amazonaws.com')
        with self.assertRaises(LIFE['Failure']): client(base,'ec2')
        self.responses.pop('ec2')
        self.assertEqual(client(base,'ec2').meta.region_name,'us-east-1')
    def test_new_role_trust_retries_are_bounded_and_keep_the_exact_identity(self):
        base,client,assume=self.sessions(); sts=client(base,'sts')
        class Denied(Exception): response={'Error':{'Code':'AccessDenied'}}
        arn='arn:aws:iam::000000000000:role/launch'
        expected='arn:aws:sts::000000000000:assumed-role/launch/workspace-preflight'
        identity={'Account':self.target['account_id'],'Arn':expected}
        assumed=types.SimpleNamespace(client=lambda *a,**k:types.SimpleNamespace(meta=sts.meta,get_caller_identity=lambda:identity))
        self.boto.Session=lambda **kwargs:assumed
        credentials={'Credentials':{'AccessKeyId':'synthetic','SecretAccessKey':'synthetic','SessionToken':'synthetic'}}
        for failures in (0,2,6):
            sts.assume_role=Mock(side_effect=[Denied() for _ in range(failures)]+[credentials])
            with self.subTest(failures=failures),patch.object(LIFE['time'],'sleep') as sleep:
                if failures==6:
                    with self.assertRaises(Denied): assume(base,arn)
                else:
                    self.assertEqual(assume(base,arn),(assumed,expected))
                self.assertEqual(sleep.call_count,min(failures,5))
                for call in sts.assume_role.call_args_list:
                    self.assertEqual(call.kwargs,{'RoleArn':arn,'RoleSessionName':'workspace-preflight','DurationSeconds':900})
        sts.assume_role=Mock(side_effect=ValueError('invalid request'))
        with patch.object(LIFE['time'],'sleep') as sleep,self.assertRaises(ValueError): assume(base,arn)
        sleep.assert_not_called()
        sts.assume_role=Mock(return_value=credentials); identity['Arn']=expected.replace('/launch/','/other/')
        with self.assertRaisesRegex(LIFE['Failure'],'assumed identity mismatch'): assume(base,arn)
    def test_global_iam_requires_exact_endpoint_and_partition(self):
        for endpoint in ('https://iam.amazonaws.com.evil.example','http://iam.amazonaws.com','https://sts.amazonaws.com'):
            with self.subTest(endpoint=endpoint):
                self.responses['iam']=('aws-global',endpoint)
                base,client,_=self.sessions()
                with self.assertRaises(LIFE['Failure']): client(base,'iam')
        self.responses['iam']=('aws-global','https://iam.amazonaws.com')
        self.target['operator_arn']='arn:aws-us-gov:iam::000000000000:user/operator'
        self.identity['Arn']=self.target['operator_arn']
        base,client,_=self.sessions()
        with self.assertRaises(LIFE['Failure']): client(base,'iam')
    def test_regional_services_cannot_use_global_or_other_region(self):
        for service in ('ec2','s3','sts','lambda','scheduler','ssm','logs'):
            for region in ('aws-global','us-west-2'):
                with self.subTest(service=service,region=region):
                    self.responses={}
                    self.responses[service]=(region,'https://'+service+'.amazonaws.com')
                    if service=='sts':
                        with self.assertRaises(LIFE['Failure']): self.sessions()
                    else:
                        base,client,_=self.sessions()
                        with self.assertRaises(LIFE['Failure']): client(base,service)
    def test_regional_endpoint_override_is_rejected(self):
        self.responses['ec2']=('us-east-1','https://example.com')
        base,client,_=self.sessions()
        with self.assertRaises(LIFE['Failure']): client(base,'ec2')
    def test_global_iam_exception_does_not_relax_operator_identity(self):
        self.identity['Account']='111111111111'
        with self.assertRaises(LIFE['Failure']): self.sessions()

class HeartbeatObservation(unittest.TestCase):
    def setUp(self):
        account='000000000000'; prefix='ml-infra'
        self.config={'aws_account_id':account,'aws_region':'us-east-1','resource_prefix':prefix,'project_name':prefix,
                     'deployer_role_arn':f'arn:aws:iam::{account}:role/{prefix}-workspace-deployer',
                     'workspace_identity':{'ml_project_name':'demo','request':{'operators':['arn:aws:iam::000000000000:user/operator'],'workspace_id':'demo-dev-01'},
                     'permissions_boundary_arn':f'arn:aws:iam::{account}:policy/{prefix}-ws-demo-boundary',
                     'session_policy_arn':f'arn:aws:iam::{account}:policy/{prefix}-session-manager-minimal'},
                     'lease':{'id':'b'*32,'starts_at':LIFE['stamp'](T),'expires_at':LIFE['stamp'](T+dt.timedelta(hours=1))},
                     'guard':{'guard_id':'a'*32,'code_sha256':'d'*64,
                     'function_arn':f'arn:aws:lambda:us-east-1:{account}:function:{prefix}-workspace-watchdog:1',
                     'invoker_role_arn':f'arn:aws:iam::{account}:role/{prefix}-workspace-watchdog-invoke',
                     'recurring_schedule_name':prefix+'-workspace-watchdog-sweep','log_group':'/aws/lambda/'+prefix+'-workspace-watchdog',
                     'failure_queue_arn':f'arn:aws:sqs:us-east-1:{account}:{prefix}-workspace-watchdog-failures','alarm_names':['offline-alarm']}}
        config=self.config; guard=config['guard']; role=LIFE['role_name'](config)
        names=[guard['invoker_role_arn'].rsplit('/',1)[1],prefix+'-workspace-watchdog',role,role+'-launch']
        execution,invoker=LIFE['guard_policies'](config)
        trusts={names[0]:{'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sts:AssumeRole','Principal':{'Service':'scheduler.amazonaws.com'},
                 'Condition':{'StringEquals':{'aws:SourceAccount':account},'ArnEquals':{'aws:SourceArn':f'arn:aws:scheduler:us-east-1:{account}:schedule-group/default'}}}]},
                names[1]:{'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sts:AssumeRole','Principal':{'Service':'lambda.amazonaws.com'}}]},
                names[2]:{},names[3]:{}}
        boundaries={names[2]:config['workspace_identity']['permissions_boundary_arn'],names[3]:f'arn:aws:iam::{account}:policy/{prefix}-workspace-launch-boundary'}
        policies={names[0]:{'invoke-pinned-watchdog':invoker},names[1]:{'guard-owned-termination-only':execution},
                  names[2]:{'workspace-storage':{}},names[3]:{'immutable-lease-launch':{}}}
        self.deployer_policy={'Version':'2012-10-17','Statement':[
            {'Sid':'DenyReviewedOperatorPolicyMutation','Effect':'Deny','Action':'iam:*',
             'Resource':config['workspace_identity']['request']['operators']}]}
        policies[prefix+'-workspace-deployer']={'workspace-deployer':self.deployer_policy}
        self.role_created_at=T-dt.timedelta(minutes=2)
        self.schedule_created_at=T-dt.timedelta(minutes=1)
        def get_role(RoleName):
            value={'AssumeRolePolicyDocument':trusts[RoleName],'CreateDate':self.role_created_at,'RoleId':'offline-role-id'}
            if RoleName in boundaries: value['PermissionsBoundary']={'PermissionsBoundaryArn':boundaries[RoleName]}
            return {'Role':value}
        def schedule(Name,**kwargs):
            sweep=Name==guard['recurring_schedule_name']
            event={'kind':'sweep','guard_id':guard['guard_id']} if sweep else {
                'kind':'lease','guard_id':guard['guard_id'],'workspace_id':'demo-dev-01','lease_id':config['lease']['id']}
            expression='rate(1 minute)' if sweep else 'at('+LIFE['stamp'](T+dt.timedelta(minutes=55)).removesuffix('Z')+')'
            return {'State':'ENABLED','ScheduleExpression':expression,'ScheduleExpressionTimezone':'UTC','ActionAfterCompletion':'NONE',
                    'FlexibleTimeWindow':{'Mode':'OFF'},'CreationDate':self.schedule_created_at,
                    'Target':{'Arn':guard['function_arn'],'RoleArn':guard['invoker_role_arn'],'Input':json.dumps(event),
                    'RetryPolicy':{'MaximumEventAgeInSeconds':300,'MaximumRetryAttempts':3},'DeadLetterConfig':{'Arn':guard['failure_queue_arn']}}}
        # Every service is injected. No boto3 Session, CLI or account API fallback.
        self.clients={
            'iam':types.SimpleNamespace(get_role=get_role,
                list_role_policies=lambda RoleName:{'PolicyNames':list(policies[RoleName])},
                list_attached_role_policies=lambda RoleName:{'AttachedPolicies':[{'PolicyArn':config['workspace_identity']['session_policy_arn']}] if RoleName==role else []},
                get_role_policy=lambda RoleName,PolicyName:{'PolicyDocument':policies[RoleName][PolicyName]},
                get_policy=lambda **k:{'Policy':{'DefaultVersionId':'v1'}},get_policy_version=lambda **k:{'PolicyVersion':{'Document':{}}},
                get_instance_profile=lambda **k:{'InstanceProfile':{'Roles':[{'RoleName':role,'Arn':'offline-role-arn'}]}},list_user_tags=lambda **k:{'Tags':[]}),
            'lambda':types.SimpleNamespace(get_function_configuration=lambda **k:{'State':'Active','LastUpdateStatus':'Successful',
                'CodeSha256':base64.b64encode(bytes.fromhex(guard['code_sha256'])).decode(),'Runtime':'python3.13','Timeout':30,'Handler':'watchdog.handler',
                'Environment':{'Variables':{'GUARD_ID':guard['guard_id'],'OWNER_PROJECT':prefix,'ACCOUNT_ID':account,'CODE_SHA256':guard['code_sha256']}},
                'Role':f'arn:aws:iam::{account}:role/'+names[1]},get_function_concurrency=lambda **k:{},
                get_account_settings=lambda:{'AccountLimit':{'ConcurrentExecutions':5,'UnreservedConcurrentExecutions':5}},
                get_function_event_invoke_config=lambda **k:{'MaximumEventAgeInSeconds':300,'MaximumRetryAttempts':2,'DestinationConfig':{'OnFailure':{'Destination':guard['failure_queue_arn']}}}),
            'scheduler':types.SimpleNamespace(get_schedule=schedule),
            'ssm':types.SimpleNamespace(get_document=lambda **k:{'Content':json.dumps({'inputs':{'runAsEnabled':True,'runAsDefaultUser':'workspace'}})}),
            'cloudwatch':types.SimpleNamespace(describe_alarms=lambda **k:{'MetricAlarms':[{'AlarmName':'offline-alarm','StateValue':'OK','ActionsEnabled':True,'AlarmActions':['offline-topic']}]}),
        }
    def event(self,**changes):
        guard=self.config['guard']
        return {'message':json.dumps({'kind':'heartbeat','guard_id':guard['guard_id'],'code_sha256':guard['code_sha256'],
                'account':self.config['aws_account_id'],'region':self.config['aws_region'],'observed_at':LIFE['stamp'](T),**changes})}
    def observe(self,pages,admission=T,ticks=None,heartbeat_max_age=120):
        self.calls=[]; responses=iter(pages); instants=iter([T,admission])
        class Clock(dt.datetime):
            @classmethod
            def now(cls,tz=None): return next(instants)
        def logs(**kwargs):
            self.calls.append(kwargs); value=next(responses)
            if isinstance(value,Exception): raise value
            return value
        self.clients['logs']=types.SimpleNamespace(filter_log_events=logs)
        with patch.dict(LIFE,{'dt':types.SimpleNamespace(datetime=Clock,timedelta=dt.timedelta,timezone=dt.timezone)}):
            if ticks is None: return LIFE['observe_guard'](None,lambda _,service:self.clients[service],self.config,heartbeat_max_age)
            with patch.object(LIFE['time'],'monotonic',side_effect=ticks):
                return LIFE['observe_guard'](None,lambda _,service:self.clients[service],self.config,heartbeat_max_age)
    def test_planning_freshness_budget_is_stricter_than_runtime_admission(self):
        for age in (30,31):
            pages=[{'events':[self.event(observed_at=LIFE['stamp'](T-dt.timedelta(seconds=age)))]}]
            self.observe(pages)
            if age==30: self.observe(pages,heartbeat_max_age=30)
            else:
                with self.assertRaisesRegex(LIFE['Failure'],'no matching fresh'):
                    self.observe(pages,heartbeat_max_age=30)
    def test_single_page_complete_heartbeat(self):
        observation,_=self.observe([{'events':[self.event()]}])
        self.assertEqual(observation['heartbeat_at'],LIFE['stamp'](T)); self.assertEqual(len(self.calls),1)
    def test_immediate_lease_requires_guard_before_launch_role_existed(self):
        self.config['lease']['starts_at']=LIFE['stamp'](T-dt.timedelta(minutes=2))
        self.role_created_at=T-dt.timedelta(seconds=30)
        _,details=self.observe([{'events':[self.event()]}])
        self.assertEqual(details['earliest_launch_at'],LIFE['stamp'](self.role_created_at))
        self.assertEqual(details['launch_role_id'],'offline-role-id')
        for instant in (self.role_created_at+dt.timedelta(microseconds=1),T+dt.timedelta(seconds=1)):
            self.schedule_created_at=instant
            with self.subTest(instant=instant),self.assertRaisesRegex(LIFE['Failure'],'before earliest launch'):
                self.observe([])
    def test_future_role_creation_cannot_admit(self):
        self.role_created_at=T+dt.timedelta(seconds=1)
        with self.assertRaisesRegex(LIFE['Failure'],'creation time is in the future'):
            self.observe([])
    def test_existing_future_lease_keeps_its_reviewed_opening(self):
        _,details=self.observe([{'events':[self.event()]}])
        self.assertEqual(details['earliest_launch_at'],self.config['lease']['starts_at'])
    def test_launch_identity_must_match_saved_preparation_state(self):
        _,details=self.observe([{'events':[self.event()]}])
        role=LIFE['role_name'](self.config); wid=self.config['workspace_identity']['request']['workspace_id']
        resources=[]
        for address,name,policy in ((f'aws_iam_role.workspace["{wid}"]',role,f'aws_iam_role_policy.workspace_storage["{wid}"]'),
                                    ('aws_iam_role.launch',role+'-launch','aws_iam_role_policy.launch')):
            observed=details['roles'][name]
            resources.extend([{'address':address,'values':{'assume_role_policy':json.dumps(observed['trust']),
                'unique_id':details['launch_role_id'],'create_date':details['launch_role_created_at']}},
                {'address':policy,'values':{'policy':json.dumps(next(iter(observed['inline'].values())))}}])
        resources.append({'address':'aws_ssm_document.terminal','values':{'content':self.clients['ssm'].get_document()['Content']}})
        plan={'planned_values':{'root_module':{'resources':resources}}}
        LIFE['compare_prepared_iam'](plan,details,self.config)
        for key,value in (('launch_role_id','replacement-role'),('launch_role_created_at',LIFE['stamp'](T))):
            with self.subTest(key=key),self.assertRaisesRegex(LIFE['Failure'],'identity differs'):
                LIFE['compare_prepared_iam'](plan,{**details,key:value},self.config)
    def test_retained_foundation_without_operator_denial_cannot_launch(self):
        denial=copy.deepcopy(self.deployer_policy['Statement'][0])
        for change in ({'Effect':'Allow'},{'Action':'iam:PutUserPolicy'},{'Resource':'arn:aws:iam::000000000000:user/other'},
                       {'Condition':{'Bool':{'aws:MultiFactorAuthPresent':'true'}}}):
            self.deployer_policy['Statement']=[{**denial,**change}]
            with self.subTest(change=change),self.assertRaisesRegex(LIFE['Failure'],'reviewed workspace-access IAM migration'):
                self.observe([])
            self.assertEqual(self.calls,[])
    def test_sdk_schedule_dates_in_local_time_are_serialized_as_utc(self):
        original=self.clients['scheduler'].get_schedule
        for offset in (2,-6,14):
            def local_schedule(**kwargs):
                result=original(**kwargs)
                result['CreationDate']=result['CreationDate'].astimezone(dt.timezone(dt.timedelta(hours=offset)))
                return result
            self.clients['scheduler'].get_schedule=local_schedule
            _,details=self.observe([{'events':[self.event()]}])
            self.assertEqual(details['guard_active_at'],LIFE['stamp'](T-dt.timedelta(minutes=1)))
    def test_empty_or_partial_page_continues_with_fixed_query(self):
        for first in ([],[self.event(region='foreign')]):
            with self.subTest(first=first):
                observation,_=self.observe([{'events':first,'nextToken':'page-two'},{'events':[self.event()]}])
                self.assertEqual(observation['heartbeat_at'],LIFE['stamp'](T)); self.assertEqual(len(self.calls),2)
                expected={'logGroupName':self.config['guard']['log_group'],'startTime':int((T-dt.timedelta(seconds=120)).timestamp()*1000),
                          'filterPattern':'{ $.kind = "heartbeat" }','limit':100}
                self.assertEqual(self.calls,[expected,{**expected,'nextToken':'page-two'}])
    def test_stale_future_wrong_scope_and_lease_results_cannot_admit(self):
        for change in ({'observed_at':LIFE['stamp'](T-dt.timedelta(seconds=121))},{'observed_at':LIFE['stamp'](T+dt.timedelta(seconds=1))},
                       {'guard_id':'foreign'},{'code_sha256':'e'*64},{'account':'111111111111'},{'region':'us-west-2'},{'kind':'lease_result'}):
            with self.subTest(change=change),self.assertRaisesRegex(LIFE['Failure'],'no matching fresh'):
                self.observe([{'events':[],'nextToken':'page-two'},{'events':[self.event(**change)]}])
    def test_heartbeat_age_is_checked_after_pagination(self):
        with self.assertRaisesRegex(LIFE['Failure'],'no matching fresh'):
            self.observe([{'events':[],'nextToken':'page-two'},{'events':[self.event(observed_at=LIFE['stamp'](T-dt.timedelta(seconds=110)))]}],
                         admission=T+dt.timedelta(seconds=11))
    def test_repeated_or_cyclic_tokens_fail_even_after_a_match(self):
        for tokens in (['a','a'],['a','b','a']):
            with self.subTest(tokens=tokens),self.assertRaisesRegex(LIFE['Failure'],'repeated heartbeat continuation'):
                self.observe([{'events':[self.event()],'nextToken':token} for token in tokens])
            self.assertEqual(len(self.calls),len(tokens))
    def test_page_budget_exhaustion_stops_before_later_heartbeat(self):
        with self.assertRaisesRegex(LIFE['Failure'],'page bound exhausted'):
            self.observe([{'events':[],'nextToken':str(i)} for i in range(10)]+[{'events':[self.event()]}])
        self.assertEqual(len(self.calls),10)
    def test_complete_results_at_page_and_event_limits_are_accepted(self):
        cases=[[{'events':[],'nextToken':str(i)} for i in range(9)]+[{'events':[self.event()]}],
               [{'events':[self.event()]*100,'nextToken':str(i)} for i in range(4)]+[{'events':[self.event()]*100}]]
        for pages in cases:
            with self.subTest(pages=len(pages)):
                observation,_=self.observe(pages)
                self.assertEqual(observation['heartbeat_at'],LIFE['stamp'](T)); self.assertEqual(len(self.calls),len(pages))
    def test_event_budget_exhaustion_fails_even_after_a_match(self):
        with self.assertRaisesRegex(LIFE['Failure'],'event bound exhausted'):
            self.observe([{'events':[self.event()]*100,'nextToken':str(i)} for i in range(5)]+[{'events':[self.event()]}])
        self.assertEqual(len(self.calls),6)
    def test_elapsed_collection_budget_rejects_response(self):
        with self.assertRaisesRegex(LIFE['Failure'],'time bound exhausted'):
            self.observe([{'events':[self.event()]}],ticks=[0,0,31])
        self.assertEqual(len(self.calls),1)
    def test_malformed_pages_records_and_tokens_fail_closed(self):
        cases=[{}, {'events':None}, {'events':[self.event()]*101}, {'events':[None]}, {'events':[{'message':'[]'}]},
               {'events':[{'message':'not-json'}]}, {'events':[self.event(observed_at='invalid')]},
               *[{'events':[],'nextToken':token} for token in ('',None,7,[])]]
        for value in cases:
            with self.subTest(value=value),self.assertRaises((LIFE['Failure'],ValueError)):
                self.observe([value])
    def test_inaccessible_logs_cannot_admit(self):
        with self.assertRaisesRegex(RuntimeError,'offline access denied'):
            self.observe([RuntimeError('offline access denied')])
        self.assertEqual(len(self.calls),1)

class LaunchTiming(unittest.TestCase):
    """Exercise real plan/authorization/apply sequencing with delayed native calls."""
    def setUp(self):
        self.directory=OUT/self.id().rsplit('.',1)[1]; self.directory.mkdir()
        self.launch=self.directory/'launch'; self.preparation=self.directory/'prepare'; self.preparation.mkdir()
        self.elapsed=0; self.calls=[]; self.apply_init_seconds=15; self.heartbeat_mode='scheduled'
        self.native_run=LIFE['run']
        self.fixture=HeartbeatObservation(); self.fixture.setUp()
        self.config=copy.deepcopy(self.fixture.config)
        self.config['lease']['launch_before']=LIFE['stamp'](T+dt.timedelta(minutes=5))
        artifact=self.directory/'toolbox.zip'; artifact.write_bytes(b'offline-artifact')
        self.config.update(toolbox_zip_path=str(artifact),toolbox_zip_sha256=LIFE['sha'](artifact.read_bytes()))
        self.input=self.directory/'input.json'; LIFE['write'](self.input,self.config)
        self.target={'backend':{'bucket':'offline-state'},'region':'us-east-1','profile':'offline','account_id':'000000000000'}
        self.state={'key':'offline.tfstate','serial':1}
        prior={'stage':'prepare','target_name':'offline','source':LIFE['source'](),'target':self.target}
        LIFE['write'](self.preparation/'review.json',prior)
        LIFE['write'](self.preparation/'apply-result.json',{'status':'success'})
        LIFE['write'](self.preparation/'config.tfvars.json',self.config)
        self.plan={'resource_changes':[{'address':'aws_instance.workspace[0]','mode':'managed','type':'aws_instance',
            'change':{'actions':['create'],'after':{'instance_type':'r8i.2xlarge','ami':LIFE['TOOLBOX']['ami_id'],
            'user_data_base64':'','root_block_device':[{'encrypted':True,'delete_on_termination':True,'volume_size':30}],
            'metadata_options':[{'http_tokens':'required','http_put_response_hop_limit':1}]}}}]}
        platform={'planned_values':{'root_module':{'resources':[{
            'address':'aws_iam_policy.workspace_launch_boundary["active"]','values':{'policy':'{}'}}]}}}
        owner=self
        class Clock(dt.datetime):
            @classmethod
            def now(cls,tz=None): return T+dt.timedelta(seconds=owner.elapsed)
        def logs(**kwargs):
            self.calls.append('observe')
            # Reproduce the 68-second-old initial heartbeat from the live failure.
            when=T-dt.timedelta(seconds=68)
            if self.heartbeat_mode=='future': when=T+dt.timedelta(hours=1)
            elif self.heartbeat_mode=='fresh' or (self.heartbeat_mode=='scheduled' and self.elapsed>=25):
                when=T+dt.timedelta(seconds=int(self.elapsed//20)*20)
            return {'events':[self.fixture.event(observed_at=LIFE['stamp'](when))]}
        self.fixture.clients['logs']=types.SimpleNamespace(filter_log_events=logs)
        def context(*args):
            if (self.launch/'review.json').exists(): self.advance(14)
            return self.target,{'TF_VAR_ambient':'removed'},None,lambda _,service:self.fixture.clients[service],{},self.state
        self.patches=patch.dict(LIFE,{
            'dt':types.SimpleNamespace(datetime=Clock,timedelta=dt.timedelta,timezone=dt.timezone),
            'time':types.SimpleNamespace(monotonic=lambda:self.elapsed,sleep=self.advance),
            'context':context,'run':self.run_command,'capacity':lambda *a:None,
            'verify_artifact':lambda *a:None,
            'runner_provider_scope':lambda *a:None,'compare_prepared_iam':lambda *a:None,
            'reviewed_platform_plan':lambda *a:(platform,[]),'compare_platform_alarms':lambda *a:None,
            'bound_instance':lambda *a:{'InstanceId':'i-offline','BlockDeviceMappings':[{'Ebs':{'VolumeId':'vol-offline'}}],
                'NetworkInterfaces':[{'NetworkInterfaceId':'eni-offline','Attachment':{'DeviceIndex':0}}]},
            'snapshot':lambda *a:self.state})
        self.patches.start(); self.addCleanup(self.patches.stop)
    def advance(self,seconds): self.elapsed+=seconds
    def run_command(self,args,env,seconds=None):
        if 'version' in args: return json.dumps({'terraform_version':'offline'})
        self.assertFalse(any(k.startswith('TF_VAR_') for k in env))
        if args[0]!='tofu': return ''
        if 'init' in args:
            applying='-reconfigure' in args
            self.calls.append('apply-init' if applying else 'plan-init')
            self.assertFalse((self.launch/'apply-started.json').exists())
            self.advance(self.apply_init_seconds if applying else 20)
        elif 'validate' in args: self.calls.append('validate'); self.advance(3)
        elif 'plan' in args:
            self.calls.append('plan'); self.advance(14)
            (self.launch/'saved.tfplan').write_bytes(b'immutable-offline-plan')
        elif 'show' in args: return json.dumps(self.plan)
        elif 'apply' in args:
            self.calls.append('apply')
            self.assertTrue((self.launch/'apply-started.json').exists())
            saved=LIFE['read'](self.launch/'config.tfvars.json')['guard_observation']
            self.assertTrue(all(0 <= (T+dt.timedelta(seconds=self.elapsed)-LIFE['utc'](saved[k])).total_seconds()<=120
                                for k in ('observed_at','heartbeat_at')))
        elif 'output' in args: return json.dumps({'instance_id':'i-offline'})
        else: self.fail('unexpected native command')
        return ''
    def prepare(self):
        LIFE['native_plan']('offline','launch',self.input,self.launch,self.preparation)
        review=LIFE['read'](self.launch/'review.json')
        LIFE['authorize'](self.launch,LIFE['sha'](LIFE['canon'](review)),'Explicit offline timing test')
        return review
    def test_initialization_precedes_observation_and_old_heartbeat_waits_for_next_sweep(self):
        self.prepare()
        immutable={name:(self.launch/name).read_bytes() for name in ('saved.tfplan','config.tfvars.json','review.json','authorization.json')}
        result=LIFE['apply'](self.launch)
        self.assertEqual(result['status'],'success')
        self.assertEqual(self.calls,['plan-init','validate','observe','observe','plan','apply-init','observe','apply'])
        self.assertEqual(self.elapsed,68)
        for name,content in immutable.items(): self.assertEqual((self.launch/name).read_bytes(),content)
        with self.assertRaisesRegex(LIFE['Failure'],'single-use authorization consumed'): LIFE['apply'](self.launch)
    def test_slow_apply_initialization_rejects_saved_heartbeat_despite_fresh_live_readback(self):
        review=self.prepare(); self.apply_init_seconds=60
        with self.assertRaisesRegex(LIFE['Failure'],'saved launch heartbeat/observation lacks apply headroom'):
            LIFE['apply'](self.launch)
        self.assertNotIn('apply',self.calls); self.assertFalse((self.launch/'apply-started.json').exists())
        now=T+dt.timedelta(seconds=self.elapsed)
        self.assertEqual((now-LIFE['utc'](review['guard_observation']['observed_at'])).total_seconds(),88)
        self.assertEqual((now-LIFE['utc'](review['guard_observation']['heartbeat_at'])).total_seconds(),93)
    def test_future_and_missing_recent_heartbeats_exhaust_bounded_readiness_without_plan(self):
        for mode in ('future','old'):
            with self.subTest(mode=mode):
                self.launch=self.directory/mode; self.heartbeat_mode=mode; self.elapsed=0; self.calls=[]
                with self.assertRaisesRegex(LIFE['Failure'],'90-second readiness bound'):
                    LIFE['native_plan']('offline','launch',self.input,self.launch,self.preparation)
                self.assertLessEqual(self.elapsed,113)
                self.assertFalse((self.launch/'saved.tfplan').exists())
                self.assertFalse((self.launch/'apply-started.json').exists())
    def test_ready_guard_adds_no_sleep(self):
        self.heartbeat_mode='fresh'
        with patch.object(LIFE['time'],'sleep',side_effect=AssertionError('ready guard must not sleep')):
            self.prepare(); LIFE['apply'](self.launch)
        self.assertEqual(self.calls.count('observe'),2)
    def test_live_guard_drift_still_rejects_immutable_plan(self):
        self.prepare(); self.fixture.role_created_at-=dt.timedelta(seconds=1)
        with self.assertRaisesRegex(LIFE['Failure'],'guard/IAM/document drift'): LIFE['apply'](self.launch)
        self.assertNotIn('apply',self.calls); self.assertFalse((self.launch/'apply-started.json').exists())
    def test_native_admission_errors_are_classified_without_raw_diagnostics(self):
        for message,category in (
            ('Launch requires fresh matching native\n guard/deadline/IAM/heartbeat/alarm readback.','guard_admission_failed'),
            ('Launch lease is not open; review a fresh lease/plan instead of extending it.','lease_window_closed'),
            ('unrecognized provider error','request_failed_unknown')):
            response=types.SimpleNamespace(returncode=1,stderr=message+' SENTINEL_SECRET',stdout='')
            with patch.dict(LIFE['boundary'],{'request':lambda *a:response}):
                with self.assertRaisesRegex(LIFE['Failure'],'^command failed; '+category+'$'):
                    # Use the real wrapper rather than this fixture's delayed CLI.
                    self.native_run(['tofu','apply'],{})

class ProjectConfiguration(unittest.TestCase):
    def setUp(self):
        self.environment=patch.dict(os.environ); self.environment.start()
        self.directory=OUT/self._testMethodName; self.directory.mkdir()
        self.value=json.loads((ROOT/'infra/aws/workspace.example.json').read_text())
        self.target=self.value['target']
        foundation=self.directory/'foundation'; foundation.mkdir()
        outputs={'workspace_platform':{'value':{'aws_account_id':self.target['account_id'],'aws_region':self.target['region'],
                 'deployer_role_arn':self.target['deployment_role_arn'],'state_bucket_arn':'arn:aws:s3:::'+self.target['backend']['bucket'],
                 'subnet_id':'subnet-00000000000000001','security_group_id':'sg-00000000000000001'}},
                 'workspace_guard':{'value':{'guard_id':'a'*32,'code_sha256':'d'*64}}}
        LIFE['write'](foundation/'outputs.json',outputs)
        LIFE['write'](foundation/'review.json',{'stage':'fresh-platform','source':LIFE['source'](),'target_name':self.value['target_name'],'target':self.target})
        LIFE['write'](foundation/'apply-result.json',{'status':'success'})
        LIFE['write'](foundation/'config.tfvars.json',{'ml_projects':{'demo':{}},'workspace_guard':{'zip_sha256':'d'*64}})
        self.value['foundation']={'plan_directory':str(foundation),'outputs_file':str(foundation/'outputs.json'),
                                 'outputs_sha256':LIFE['sha']((foundation/'outputs.json').read_bytes())}
        members={p.name:p.read_bytes() for p in (ROOT/'infra/aws/runner/workspace/toolbox').iterdir() if p.is_file()}
        for name in ('scripts/workspace/probe-toolbox.py','shared/workspace/toolbox.json','scripts/aws/clone-project.sh','scripts/aws/workspace-guest-observe.sh','scripts/aws/workspace-ssh.sh','scripts/aws/workspace-job.sh','scripts/aws/workspace_files.py'):
            members[name]=(ROOT/name).read_bytes()
        zip_path=self.directory/'toolbox.zip'; hash=LIFE['archive'](zip_path,members)
        LIFE['write'](self.directory/'artifacts.json',{'source':LIFE['source'](),'toolbox_zip_path':str(zip_path),'toolbox_zip_sha256':hash})
        self.value['artifacts']=str(self.directory/'artifacts.json')
        self.path=self.directory/'project.json'; LIFE['write'](self.path,self.value)
    def tearDown(self): self.environment.stop()
    def render(self):
        value,target=WORKSPACE['configuration'](str(self.path))
        with patch.dict(WORKSPACE['L'],{'sessions':lambda *_:self.fail('offline render called AWS')}):
            WORKSPACE['render'](value,target,str(self.directory/'run'),'2026-10-08T23:55:00Z')
        return LIFE['read'](self.directory/'run/runner.json')
    def test_complete_production_handoff_from_single_configuration(self):
        config=self.render(); request=config['workspace_identity']['request']
        plan={'planned_values':{'root_module':{'resources':[{'address':'aws_instance.workspace[0]',
              'values':{'user_data_base64':base64.b64encode(b'production-shaped bootstrap').decode()}}]}}}
        instant=dt.datetime(2026,10,8,23,54,tzinfo=dt.timezone.utc)
        for offset in (2,-6,14):
            review={'guard_iam':{'guard_active_at':LIFE['stamp'](instant.astimezone(dt.timezone(dt.timedelta(hours=offset))))}}
            hand=LIFE['render_handoff'](self.target,config,review,plan,'i-00000000000000001')
            path=self.directory/('handoff-'+str(offset)+'.json'); LIFE['write'](path,hand)
            subprocess.run([sys.executable,'scripts/workspace/validate.py',str(self.directory/'run/request.json'),
                            '--handoff',str(path)],check=True,capture_output=True)
            self.assertEqual(hand['lifetime']['guard_active_at'],'2026-10-08T23:54:00Z')
            self.assertEqual(hand['bootstrap_sha256'],LIFE['sha'](b'production-shaped bootstrap'))
        review={'guard_iam':{'guard_active_at':'2026-10-08T23:55:30Z','earliest_launch_at':'2026-10-08T23:55:40Z'}}
        hand=LIFE['render_handoff'](self.target,config,review,plan,'i-00000000000000001')
        path=self.directory/'immediate-handoff.json'; LIFE['write'](path,hand)
        subprocess.run([sys.executable,'scripts/workspace/validate.py',str(self.directory/'run/request.json'),
                        '--handoff',str(path)],check=True,capture_output=True)
        self.assertEqual(hand['lifetime']['started_at'],'2026-10-08T23:55:40Z')
        self.assertEqual(hand['lifetime']['expires_at'],config['lease']['expires_at'])
        commands=WORKSPACE['guest_commands'](self.value,config)
        self.assertIn(self.value['repository']['revision'],commands['clone'])
        self.assertEqual(commands['storage'],request['storage'])
        self.assertEqual(hand['lifetime']['expires_at'],'2026-10-09T00:55:00Z')
    def test_config_target_replaces_old_registry_without_changing_it(self):
        registry=ROOT/'evidence/aws/targets.json'
        before=registry.read_bytes() if registry.exists() else None
        value,target=WORKSPACE['configuration'](str(self.path))
        self.assertEqual(WORKSPACE['L']['boundary']['targets'](),{value['target_name']:target})
        self.assertEqual(registry.read_bytes() if registry.exists() else None,before)
    def test_changed_outputs_are_rejected_without_native_calls(self):
        path=Path(self.value['foundation']['outputs_file']); path.write_text('{}\n')
        with self.assertRaisesRegex(WORKSPACE['L']['Failure'],'outputs changed'): self.render()
        self.assertFalse((self.directory/'run').exists())
    def test_config_drift_and_repeat_render_preserve_run(self):
        self.render()
        with self.assertRaises(WORKSPACE['L']['Failure']): self.render()
        changed=copy.deepcopy(self.value); changed['maximum_runtime_minutes']=30
        with self.assertRaisesRegex(WORKSPACE['L']['Failure'],'configuration changed'):
            WORKSPACE['run_configuration'](changed,str(self.directory/'run'))
    def test_generated_runner_cannot_bypass_single_configuration(self):
        config=self.render(); config['lease']['expires_at']='2026-10-10T00:55:00Z'
        (self.directory/'run/runner.json').write_bytes(LIFE['canon'](config))
        with self.assertRaisesRegex(WORKSPACE['L']['Failure'],'rendered inputs changed'):
            WORKSPACE['run_configuration'](self.value,str(self.directory/'run'))
    def test_unknown_configuration_and_unsupported_sizing_are_rejected(self):
        for change in ({'extra':True},{'sizing':{**self.value['sizing'],'instance_type':'r8i.4xlarge'}}):
            path=self.directory/('changed-'+str(len(change))+str(len(json.dumps(change)))+'.json')
            LIFE['write'](path,{**self.value,**change})
            with self.assertRaises(WORKSPACE['L']['Failure']): WORKSPACE['configuration'](str(path))
    def test_ssh_configuration_requires_exact_regional_credential_reference(self):
        for field,value in (('secret_arn',self.value['repository']['credential']['secret_arn'].replace('us-east-1','us-west-2')),
                            ('version_id','AWSCURRENT'),('public_key_fingerprint','unreviewed')):
            changed=copy.deepcopy(self.value); changed['repository']['credential'][field]=value
            path=self.directory/('invalid-'+field+'.json'); LIFE['write'](path,changed)
            with self.assertRaises(WORKSPACE['L']['Failure']): WORKSPACE['configuration'](str(path))
    def test_ssh_commands_contain_only_public_credential_metadata(self):
        config=self.render(); commands=WORKSPACE['guest_commands'](self.value,config)
        self.assertIn('workspace-ssh.sh',commands['clone'])
        self.assertIn(self.value['repository']['credential']['version_id'],commands['clone'])
        self.assertNotIn('PRIVATE KEY',commands['clone'])
        self.assertEqual(config['workspace_git_credential'],self.value['repository']['credential'])
    def test_toolbox_manifest_matches_compiled_sdk_lock(self):
        lock=(ROOT/'infra/aws/runner/workspace/toolbox/sdk-requirements.lock').read_text()
        for package in ('boto3','botocore'):
            self.assertIn(package+'=='+LIFE['TOOLBOX']['sdk_version']+' ',lock)

class Boundary(unittest.TestCase):
    def test_operator_access_migration_cannot_grant_new_permissions(self):
        document={'Sid':'ManageReviewedNonRootTerminalDocuments','Effect':'Allow','Action':['ssm:GetDocument'],
                  'Resource':'arn:aws:ssm:us-east-1:000000000000:document/reviewed-terminal'}
        for kind in ('user','role'):
            principal='arn:aws:iam::000000000000:'+kind+'/reviewed-operator'
            actions=['iam:'+action+kind.title()+suffix for action,suffix in
                     (('Put','Policy'),('Delete','Policy'),('Get','Policy'),('List','Tags'))]
            before={'Version':'2012-10-17','Statement':[document,
                {'Sid':'ManageReviewedNamedOperatorWorkspaceGrant','Effect':'Allow','Action':actions,'Resource':principal}]}
            denial={'Sid':'DenyReviewedOperatorPolicyMutation','Effect':'Deny','Action':'iam:*','Resource':principal}
            variables={'deployer_principal_arns':{'value':[principal]}}
            for expand_document in (False,True):
                updated=copy.deepcopy(document)
                if expand_document: updated['Resource']=[document['Resource'],document['Resource'].removesuffix('-terminal')+'-job']
                after={**before,'Statement':[updated,denial]}
                LIFE['deployer_access_scope'](before,after,variables)
                change={'actions':['update'],'before':{'policy':json.dumps(before)},'after':{'policy':json.dumps(after)}}
                item={'address':'aws_iam_role_policy.deployer','mode':'managed','change':change}
                plan={'variables':{**variables,'workspace_git_secret_arns':{'value':{}}},'resource_changes':[item]}
                self.assertEqual(LIFE['plan_scope'](plan,'workspace-access'),[{'address':item['address'],'actions':['update']}])
                item['address']='aws_iam_policy.project_workspace_boundary["unselected"]'
                with self.assertRaisesRegex(LIFE['Failure'],'exact project boundary'):
                    LIFE['plan_scope'](plan,'workspace-access')
                for change in ({'Effect':'Allow'},{'Resource':principal+'-other'},{'Action':'iam:PutRolePolicy'}):
                    changed={**after,'Statement':[updated,{**denial,**change}]}
                    with self.subTest(kind=kind,change=change), self.assertRaises(LIFE['Failure']):
                        LIFE['deployer_access_scope'](before,changed,variables)
                with self.assertRaises(LIFE['Failure']): LIFE['deployer_access_scope'](before,after,{})

    def test_operator_alias_cannot_run_compute_or_assume_the_deployer(self):
        alias={'alias':'operator','expressions':{'region':{'references':['var.aws_region']},
                                              'allowed_account_ids':{'references':['var.aws_account_id']}}}
        resources=[{'mode':'managed','type':'aws_iam_user_policy','address':'aws_iam_user_policy.operator','provider_config_key':'aws.operator'},
                   {'mode':'managed','type':'aws_instance','address':'aws_instance.workspace','provider_config_key':'aws'}]
        plan={'configuration':{'provider_config':{'aws.operator':alias},'root_module':{'resources':resources}}}
        LIFE['runner_provider_scope'](plan)
        for resource in resources:
            original=resource['provider_config_key']; resource['provider_config_key']='aws' if original=='aws.operator' else 'aws.operator'
            with self.assertRaises(LIFE['Failure']): LIFE['runner_provider_scope'](plan)
            resource['provider_config_key']=original
        alias['expressions']['assume_role']={'constant_value':{'role_arn':'unreviewed'}}
        with self.assertRaises(LIFE['Failure']): LIFE['runner_provider_scope'](plan)

    def test_credential_planning_targets_one_existing_project(self):
        config={'ml_projects':{'demo':{}},'workspace_git_secret_arns':{'demo':['reviewed-arn']}}
        self.assertEqual(LIFE['credential_plan_target'](config),'-target=aws_iam_policy.project_workspace_boundary["demo"]')
        for projects in ({},{'demo':[],'foreign':[]},{'foreign':[]}):
            with self.subTest(projects=projects),self.assertRaises(LIFE['Failure']):
                LIFE['credential_plan_target']({**config,'workspace_git_secret_arns':projects})
    def test_credential_access_scope_preserves_every_other_permission(self):
        arn='arn:aws:secretsmanager:us-east-1:000000000000:secret:demo/workspaces/demo-dev-01/git/aws-workspace-e2e-ABCdef'
        before={'Version':'2012-10-17','Statement':[
            {'Sid':'DenyOtherActionsIncludingDeletionAndAdministration','Effect':'Deny','NotAction':['s3:GetObject'],'Resource':['*']},
            {'Sid':'DenyStateStorage','Effect':'Deny','Action':['s3:*'],'Resource':['arn:aws:s3:::state']}]}
        after=copy.deepcopy(before); after['Statement'][0]['NotAction']+=['secretsmanager:GetSecretValue','kms:Decrypt']
        after['Statement'] += [
            {'Sid':'ReadReviewedGitCredentials','Effect':'Allow','Action':['secretsmanager:GetSecretValue'],'Resource':[arn]},
            {'Sid':'DenyOtherGitCredentials','Effect':'Deny','Action':['secretsmanager:GetSecretValue'],'NotResource':[arn]}]
        after['Statement']+=LIFE['git_decryption_statements']([arn])
        plan={'variables':{'workspace_git_secret_arns':{'value':{'demo':[arn]}}},'resource_changes':[
            {'address':'aws_iam_policy.project_workspace_boundary["demo"]','mode':'managed','change':{
                'actions':['update'],'before':{'policy':json.dumps(before),'name':'same'},'after':{'policy':json.dumps(after),'name':'same'}}}]}
        self.assertEqual(len(LIFE['plan_scope'](plan,'workspace-access')),1)
        legacy=copy.deepcopy(after);legacy['Statement']=legacy['Statement'][:-4]
        legacy['Statement'][0]['NotAction'].remove('kms:Decrypt')
        plan['resource_changes'][0]['change']['before']['policy']=json.dumps(legacy)
        self.assertEqual(len(LIFE['plan_scope'](plan,'workspace-access')),1)
        plan['resource_changes'][0]['change']['before']['policy']=json.dumps(before)
        after['Statement'][1]['Effect']='Allow'
        plan['resource_changes'][0]['change']['after']['policy']=json.dumps(after)
        with self.assertRaisesRegex(LIFE['Failure'],'unrelated permissions'): LIFE['plan_scope'](plan,'workspace-access')
        plan['resource_changes'][0]['address']='aws_lambda_function.workspace_guard["active"]'
        with self.assertRaisesRegex(LIFE['Failure'],'exact project boundary'): LIFE['plan_scope'](plan,'workspace-access')
        plan['resource_changes'][0]['address']='aws_iam_role_policy.deployer'
        plan['resource_changes'][0]['change']['after']['policy']=None
        with self.assertRaisesRegex(LIFE['Failure'],'known exact deployer policy'): LIFE['plan_scope'](plan,'workspace-access')
    def test_job_access_can_only_add_its_document_resource(self):
        arn='arn:aws:ssm:us-east-1:000000000000:document/demo-run-ws-*-terminal'
        before={'Version':'2012-10-17','Statement':[
            {'Sid':'ManageReviewedNonRootTerminalDocuments','Effect':'Allow','Action':['ssm:CreateDocument','ssm:GetDocument'],'Resource':arn},
            {'Sid':'Unrelated','Effect':'Allow','Action':'iam:GetRole','Resource':'reviewed'}]}
        after=copy.deepcopy(before); after['Statement'][0]['Resource']=[arn,arn.removesuffix('-terminal')+'-job']
        after['Statement'][0]['Action'].reverse()
        item={'address':'aws_iam_role_policy.deployer','mode':'managed','change':{'actions':['update'],
            'before':{'name':'same','policy':json.dumps(before)},'after':{'name':'same','policy':json.dumps(after)}}}
        plan={'variables':{'workspace_git_secret_arns':{'value':{'demo':['reviewed']}}},'resource_changes':[item]}
        self.assertEqual(len(LIFE['plan_scope'](plan,'workspace-access')),1)
        for changed in ({**after,'Statement':after['Statement']+[{'Sid':'Extra','Effect':'Allow','Action':'*','Resource':'*'}]},
                        {**after,'Statement':[{**after['Statement'][0],'Action':['ssm:*']},after['Statement'][1]]},
                        {**after,'Statement':[{**after['Statement'][0],'Resource':['*']},after['Statement'][1]]}):
            item['change']['after']['policy']=json.dumps(changed)
            with self.assertRaises(LIFE['Failure']): LIFE['plan_scope'](plan,'workspace-access')
    def test_naive_dates_cannot_be_labeled_utc(self):
        with self.assertRaisesRegex(LIFE['Failure'],'timezone-aware'): LIFE['stamp'](dt.datetime(2026,10,8))
    def test_native_terminal_command_passes_shared_handoff_contract(self):
        request=json.loads((ROOT/'shared/workspace/fixtures/aws-request.json').read_text())
        handoff=json.loads((ROOT/'shared/workspace/fixtures/aws-handoff.json').read_text())
        target={'profile':'reviewed-operator','region':request['region']}
        config={'resource_prefix':'ml-infra','aws_account_id':request['account_scope'],'aws_region':request['region'],
                'workspace_identity':{'ml_project_name':'demo','request':request}}
        handoff['terminal']['argv']=LIFE['terminal_argv'](target,config,handoff['machine_id'])
        path=OUT/'native-terminal-handoff.json';LIFE['write'](path,handoff)
        subprocess.run([sys.executable,'scripts/workspace/validate.py',str(ROOT/'shared/workspace/fixtures/aws-request.json'),
                        '--handoff',str(path)],check=True,capture_output=True)
        self.assertEqual(handoff['terminal']['argv'][handoff['terminal']['argv'].index('--profile')+1],target['profile'])
        self.assertEqual(handoff['terminal']['argv'][handoff['terminal']['argv'].index('--target')+1],handoff['machine_id'])
    def test_changed_schedule_timezone_or_end_closes_guard(self):
        config={'guard':{'guard_id':'a'*32,'function_arn':'function','invoker_role_arn':'role','failure_queue_arn':'queue'},
                'aws_account_id':'000000000000','aws_region':'us-east-1','resource_prefix':'ml-infra',
                'workspace_identity':{'ml_project_name':'demo','request':{'operators':['arn:aws:iam::000000000000:user/operator'],'workspace_id':'demo-dev-01'}}}
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
    def test_new_topic_unknown_arn_is_bound_to_reviewed_name_account_and_region(self):
        fields={key:None for key in LIFE['ALARM_FIELDS']}; fields.update(dimensions={})
        fields.pop('alarm_actions')
        topic='arn:aws:sns:us-east-1:000000000000:ml-infra-workspace-alerts'
        resources=[{'address':'aws_cloudwatch_metric_alarm.workspace_guard'+str(i),
                    'values':{**fields,'alarm_name':'alarm'+str(i)}} for i in range(4)]
        plan={'planned_values':{'root_module':{'resources':resources+[
            {'address':'aws_sns_topic.workspace_alerts[0]','values':{'name':'ml-infra-workspace-alerts'}}]}},
            'variables':{key:{'value':value} for key,value in {
                'aws_account_id':'000000000000','aws_region':'us-east-1','provision_alert_topic':True}.items()},
            'resource_changes':[{'address':r['address'],'change':{'after_unknown':{'alarm_actions':True}}} for r in resources]}
        details={'alarms':{'alarm'+str(i):{**fields,'alarm_actions':[topic]} for i in range(4)}}
        LIFE['compare_platform_alarms'](plan,details)
        for fault in ('topic','account','region','not-provisioned','missing-unknown-flag','other-field'):
            changed=copy.deepcopy(plan)
            if fault=='topic': changed['planned_values']['root_module']['resources'][-1]['values']['name']='other-topic'
            elif fault in ('account','region'):
                changed['variables']['aws_account_id' if fault=='account' else 'aws_region']['value']='other'
            elif fault=='not-provisioned': changed['variables']['provision_alert_topic']['value']=False
            elif fault=='missing-unknown-flag': changed['resource_changes'][0]['change']['after_unknown']={}
            else: changed['planned_values']['root_module']['resources'][0]['values'].pop('period')
            with self.subTest(fault=fault),self.assertRaises(LIFE['Failure']):
                LIFE['compare_platform_alarms'](changed,details)
    def platform_chain(self,change=None):
        folder=OUT/('platform-chain-'+str(len(list(OUT.glob('platform-chain-*')))))
        folder.mkdir()
        target={'account_id':'000000000000','region':'us-east-1'}
        source=LIFE['source'](); edge=[]
        config={'workspace_guard':{'zip_sha256':'a'*64},'workspace_git_secret_arns':{}}
        for name in ('foundation','access-one','access-two'):
            directory=folder/name;directory.mkdir()
            current=copy.deepcopy(config)
            if name!='foundation': current['workspace_git_secret_arns']={'demo':['reviewed']}
            if change: change(name,current)
            plan={'resource_changes':[],'planned_values':{'root_module':{'resources':[
                {'address':'retained-platform'}] if name=='foundation' else []}}}
            scope=[]
            if name!='foundation':
                scope=[{'address':'aws_iam_role_policy.deployer','actions':['update']}]
                plan['resource_changes']=[{'address':scope[0]['address'],'mode':'managed','change':{'actions':['update']}}]
            LIFE['write'](directory/'config.tfvars.json',current);LIFE['write'](directory/'plan.json',plan)
            (directory/'saved.tfplan').write_bytes(b'offline immutable plan')
            review={'target_name':'offline','target':target,'source':source,
                'stage':'fresh-platform' if name=='foundation' else 'workspace-access','dependencies':edge,
                'config_sha256':LIFE['sha'](LIFE['canon'](current)),
                'plan_json_sha256':LIFE['sha']((directory/'plan.json').read_bytes()),
                'plan_sha256':LIFE['sha']((directory/'saved.tfplan').read_bytes()),'scope':scope}
            receipt={'status':'success'}
            LIFE['write'](directory/'review.json',review);LIFE['write'](directory/'apply-result.json',receipt)
            edge=[{'directory':str(directory),'review_sha256':LIFE['sha'](LIFE['canon'](review)),
                   'receipt_sha256':LIFE['sha'](LIFE['canon'](receipt))}]
        return {'target_name':'offline','target':target,'dependencies':edge},folder
    def test_targeted_access_chain_recovers_exact_full_platform(self):
        preparation,_=self.platform_chain()
        plan,bindings=LIFE['reviewed_platform_plan'](preparation)
        self.assertEqual(plan['planned_values']['root_module']['resources'],[{'address':'retained-platform'}])
        self.assertEqual(len(bindings),3)
    def test_iam_only_access_chain_needs_no_git_secret(self):
        preparation,_=self.platform_chain(lambda _name,config:config.update(workspace_git_secret_arns={}))
        plan,bindings=LIFE['reviewed_platform_plan'](preparation)
        self.assertEqual(plan['planned_values']['root_module']['resources'],[{'address':'retained-platform'}])
        self.assertEqual(len(bindings),3)
    def test_platform_chain_rejects_changed_receipts_plans_and_inputs(self):
        for filename in ('review.json','apply-result.json','plan.json','saved.tfplan','config.tfvars.json'):
            with self.subTest(filename=filename):
                preparation,folder=self.platform_chain()
                path=folder/'foundation'/filename;path.write_bytes(path.read_bytes()+b' ')
                # Canonical receipt hashes ignore harmless whitespace; alter semantics.
                if filename in ('review.json','apply-result.json','config.tfvars.json'):
                    value=json.loads(path.read_text());value['status']='failure';path.write_text(json.dumps(value))
                with self.assertRaises(LIFE['Failure']):LIFE['reviewed_platform_plan'](preparation)
        preparation,_=self.platform_chain(lambda name,c:c.update(workspace_guard={'zip_sha256':'b'*64}) if name=='access-two' else None)
        with self.assertRaisesRegex(LIFE['Failure'],'retained platform inputs'):LIFE['reviewed_platform_plan'](preparation)
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
    def test_platform_accepts_new_storage_and_terminal_prerequisites(self):
        for address in ('aws_iam_policy.session_manager','aws_s3_bucket_lifecycle_configuration.project["demo"]','terraform_data.project_storage_checks["demo"]'):
            item={'address':address,'mode':'managed','change':{'actions':['create']}}
            self.assertEqual(LIFE['plan_scope']({'resource_changes':[item]},'platform'),[{'address':address,'actions':['create']}])
    def test_platform_prerequisites_cannot_modify_existing_resources(self):
        for address in ('aws_iam_policy.session_manager','aws_s3_bucket_lifecycle_configuration.project["demo"]','terraform_data.project_storage_checks["demo"]'):
            for actions in (['update'],['delete'],['delete','create']):
                item={'address':address,'mode':'managed','change':{'actions':actions}}
                with self.assertRaises(LIFE['Failure']): LIFE['plan_scope']({'resource_changes':[item]},'platform')
    def test_platform_rejects_historical_runtime_policy_update(self):
        item={'address':'aws_iam_policy.runtime_boundary','mode':'managed','change':{'actions':['update']}}
        with self.assertRaisesRegex(LIFE['Failure'],'unreviewed platform mutation'): LIFE['plan_scope']({'resource_changes':[item]},'platform')
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
        config={'guard':{'guard_id':OWN['GuardId']},'workspace_identity':{'request':{'operators':['arn:aws:iam::000000000000:user/operator'],'workspace_id':TAGS['WorkspaceId']}},'lease':{'id':TAGS['LeaseId']}}
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
                             'runner_provider_scope':lambda *a:None,
                             'run':lambda *a:called.append(a)}):
            with self.assertRaises(LIFE['Failure']): LIFE['apply'](directory)
        self.assertEqual(called,[]); self.assertFalse((directory/'apply-started.json').exists())

class AccessRecovery(unittest.TestCase):
    def setUp(self):
        self.directory=OUT/self.id().rsplit('.',1)[1]; self.directory.mkdir()
        self.principal='arn:aws:iam::000000000000:user/operator'
        self.address='aws_iam_role_policy.deployer'
        document={'Sid':'ManageReviewedNonRootTerminalDocuments','Effect':'Allow','Action':['ssm:GetDocument'],
                  'Resource':'arn:aws:ssm:us-east-1:000000000000:document/owned-terminal'}
        self.before={'Version':'2012-10-17','Statement':[document,
            {'Sid':'ManageReviewedNamedOperatorWorkspaceGrant','Effect':'Allow',
             'Action':['iam:PutUserPolicy','iam:DeleteUserPolicy','iam:GetUserPolicy','iam:ListUserTags'],'Resource':self.principal}]}
        self.after={'Version':'2012-10-17','Statement':[document,
            {'Sid':'DenyReviewedOperatorPolicyMutation','Effect':'Deny','Action':['iam:*'],'Resource':[self.principal]}]}
        self.config={'deployer_principal_arns':[self.principal],'workspace_git_secret_arns':{}}
        self.target={'account_id':'000000000000','backend':{'bucket':'owned-state'}}
        attributes={'id':'deployer:deployer','name':'deployer','role':'deployer','policy':json.dumps(self.before)}
        self.plan={'variables':{k:{'value':v} for k,v in self.config.items()},
            'resource_changes':[{'address':self.address,'mode':'managed','change':{'actions':['update'],
                'before':attributes,'after':{**attributes,'policy':json.dumps(self.after)}}}],
            'planned_values':{'root_module':{'resources':[{'address':self.address,'mode':'managed',
                'values':{**attributes,'policy':json.dumps(self.after)}}]}}}
        self.baseline={'lineage':'owned-lineage','serial':7,'resources':[
            {'mode':'managed','type':'aws_iam_role_policy','name':'deployer','instances':[{'attributes':attributes}]},
            {'mode':'managed','type':'aws_s3_bucket','name':'project','instances':[{'index_key':'demo',
                'attributes':{'id':'owned-workload','bucket':'owned-workload'}}]}]}
        self.current=copy.deepcopy(self.baseline); self.current['serial']=8
        self.baseline_raw=LIFE['canon'](self.baseline)
        self.original={'key':'platform.tfstate','version':'before','lineage':'owned-lineage','serial':7,
                       'sha256':LIFE['sha'](self.baseline_raw)}
        LIFE['write'](self.directory/'plan.json',self.plan); LIFE['write'](self.directory/'config.tfvars.json',self.config)
        (self.directory/'saved.tfplan').write_bytes(b'original access plan')
        self.review={'stage':'workspace-access','target_name':'offline','target':self.target,'source':LIFE['source'](),
            'root':str(LIFE['stage_root']('workspace-access')),'backend':{'key':'platform.tfstate'},'state':self.original,
            'config_sha256':LIFE['sha'](LIFE['canon'](self.config)),'scope':LIFE['plan_scope'](self.plan,'workspace-access'),
            'plan_sha256':LIFE['sha'](b'original access plan'),
            'plan_json_sha256':LIFE['sha']((self.directory/'plan.json').read_bytes())}
        LIFE['write'](self.directory/'review.json',self.review)
        digest=LIFE['sha'](LIFE['canon'](self.review))
        LIFE['authorize'](self.directory,digest,'Authorized exact offline IAM migration')
        LIFE['write'](self.directory/'apply-started.json',{'review_sha256':digest})
    def recover(self):
        raw=LIFE['canon'](self.current)
        state={**self.original,'version':'after','serial':self.current['serial'],'lineage':self.current['lineage'],
               'sha256':LIFE['sha'](raw)}
        api=types.SimpleNamespace(get_object=lambda **kw:{'Body':io.BytesIO(self.baseline_raw if kw['VersionId']=='before' else raw)})
        with patch.dict(LIFE,{'platform_compute_absent':lambda *_:None}):
            return LIFE['recovery_context'](self.directory,'offline','workspace-access',self.config,self.target,
                                            state,None,lambda *_:api)
    def completed_plan(self):
        plan=copy.deepcopy(self.plan); change=plan['resource_changes'][0]['change']
        change['actions']=['no-op']; change['before']=copy.deepcopy(change['after'])
        return plan
    def test_targeted_recovery_preserves_full_foundation_and_finishes_only_original_policy(self):
        recovery=self.recover()
        self.assertEqual(recovery['owned'],[self.address,'aws_s3_bucket.project["demo"]'])
        self.assertEqual(LIFE['plan_scope'](self.plan,'workspace-access',recovery),self.review['scope'])
        self.current['resources'][0]['instances'][0]['attributes']['policy']=json.dumps(self.after)
        recovery=self.recover()
        self.assertEqual(LIFE['plan_scope'](self.completed_plan(),'workspace-access',recovery),[])
    def test_access_recovery_rejects_unrelated_state_or_ownership_changes(self):
        original=copy.deepcopy(self.current)
        for mutate in (
            lambda s:s['resources'].pop(),
            lambda s:s['resources'].append(copy.deepcopy(s['resources'][1])),
            lambda s:s['resources'][1]['instances'][0]['attributes'].update(bucket='foreign'),
            lambda s:s['resources'][0]['instances'][0]['attributes'].update(role='foreign'),
            lambda s:s['resources'][0]['instances'][0].update(status='tainted'),
            lambda s:s.update(lineage='foreign'),lambda s:s.update(serial=6)):
            self.current=copy.deepcopy(original); mutate(self.current)
            with self.subTest(state=self.current), self.assertRaises(LIFE['Failure']): self.recover()
    def test_access_recovery_rejects_foreign_policy_and_changed_original_state_version(self):
        self.current['resources'][0]['instances'][0]['attributes']['policy']='{"Statement":[]}'
        with self.assertRaisesRegex(LIFE['Failure'],'unreviewed policy'):self.recover()
        self.current=copy.deepcopy(self.baseline)
        self.baseline_raw+=b' '
        with self.assertRaisesRegex(LIFE['Failure'],'state version changed'):self.recover()
    def test_recovered_plan_cannot_expand_or_omit_reviewed_changes(self):
        recovery=self.recover()
        for mutate in (
            lambda p:p['resource_changes'][0].update(address='aws_iam_role_policy.foreign'),
            lambda p:p['resource_changes'][0]['change'].update(actions=['delete','create']),
            lambda p:p['resource_changes'][0]['change']['after'].update(policy='{"Statement":[]}'),
            lambda p:p['resource_changes'][0]['change']['after'].update(role='foreign'),
            lambda p:p.update(resource_changes=[])):
            plan=copy.deepcopy(self.plan); mutate(plan)
            with self.subTest(plan=plan),self.assertRaises(LIFE['Failure']): LIFE['plan_scope'](plan,'workspace-access',recovery)
    def test_successful_noop_recovery_retains_full_platform_ancestry(self):
        preparation,folder=Boundary().platform_chain()
        directory=folder/'access-two'; plan=self.completed_plan()
        (directory/'plan.json').write_bytes(LIFE['canon'](plan))
        review=LIFE['read'](directory/'review.json')
        review.update(scope=[],recovery=self.recover(),plan_json_sha256=LIFE['sha']((directory/'plan.json').read_bytes()))
        (directory/'review.json').write_bytes(LIFE['canon'](review))
        preparation['dependencies'][0]['review_sha256']=LIFE['sha'](LIFE['canon'](review))
        full,bindings=LIFE['reviewed_platform_plan'](preparation)
        self.assertEqual(full['planned_values']['root_module']['resources'],[{'address':'retained-platform'}])
        self.assertEqual(len(bindings),3)

class Foundation(unittest.TestCase):
    F=LIFE['foundation']
    def test_guard_default_environment_decryption_keeps_termination_scope(self):
        config={'aws_account_id':'000000000000','aws_region':'us-east-1','project_name':'demo',
                'guard':{'guard_id':'a'*32,'log_group':'/aws/lambda/guard','failure_queue_arn':'offline-queue','function_arn':'offline-function'}}
        execution,_=LIFE['guard_policies'](config)
        self.assertIn('kms:Decrypt',execution['Statement'][-1]['NotAction'])
        self.assertFalse(any(s['Effect']=='Allow' and 'kms:' in str(s['Action']) for s in execution['Statement']))
        terminate=next(s for s in execution['Statement'] if s.get('Action')=='ec2:TerminateInstances')
        self.assertEqual(set(terminate['Condition']['StringEquals']),{'ec2:ResourceTag/GuardId','ec2:ResourceTag/ManagedBy','ec2:ResourceTag/Project','ec2:ResourceTag/Root'})
    def test_computed_deployer_policy_comes_from_applied_compiler(self):
        planned={'aws_iam_role.deployer':{'name':'deployer'},'aws_iam_role_policy.deployer':{'name':'grant'}}
        grant={'name':'grant','role':'deployer','policy':'{"Statement":[]}'}
        state={'values':{'root_module':{'resources':[
            {'address':'aws_iam_role_policy.deployer','values':grant},
            {'address':'data.aws_iam_policy_document.deployer','values':{'json':grant['policy']}}]}}}
        self.assertEqual(LIFE['resolved_deployer_policy'](planned,state),grant)
        grant['policy']='{"Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'
        with self.assertRaises(LIFE['Failure']): LIFE['resolved_deployer_policy'](planned,state)
    def test_recovery_scope_accepts_owned_updates_but_rejects_compute_and_foreign_controls(self):
        owned=['aws_iam_role_policy.launch','aws_ssm_document.terminal']
        recovery={'owned':owned,'expected':owned}
        def plan(address,actions):
            return {'resource_changes':[{'address':address,'type':address.split('.')[0],'mode':'managed','change':{'actions':actions}}]}
        LIFE['plan_scope'](plan(owned[0],['update']),'prepare',recovery)
        LIFE['plan_scope'](plan(owned[1],['delete','create']),'prepare',recovery)
        for address,actions in [('aws_instance.workspace[0]',['create']),('aws_iam_role.foreign',['update']),('aws_iam_role_policy.launch',['delete'])]:
            with self.assertRaises(LIFE['Failure']): LIFE['plan_scope'](plan(address,actions),'prepare',recovery)
        for address in ('aws_iam_role.deployer','aws_s3_bucket.project["demo"]'):
            with self.assertRaises(LIFE['Failure']): LIFE['plan_scope'](plan(address,['update']),'fresh-platform',{'owned':[address]})
        self.assertEqual(LIFE['plan_scope']({'resource_changes':[]},'fresh-platform',{'owned':[]}),[])
    def test_source_upgrade_receipt_does_not_accept_uncommitted_or_foreign_source(self):
        with patch.dict(LIFE,{'source':lambda:{'revision':'b'*40,'working_tree_sha256':LIFE['sha'](b'')}}):
            self.assertFalse(LIFE['prior_source']({'revision':'a'*40,'working_tree_sha256':'c'*64}))
            with patch('subprocess.run',return_value=types.SimpleNamespace(returncode=1)):
                self.assertFalse(LIFE['prior_source']({'revision':'a'*40,'working_tree_sha256':LIFE['sha'](b'')}))
    def test_partial_recovery_binds_owned_state_and_consumed_plan(self):
        directory=OUT/'partial-recovery'; directory.mkdir()
        config={'workspace_identity':{'request':{'operators':['arn:aws:iam::000000000000:user/operator'],'workspace_id':'demo-dev-01'}},'lease':{'id':'old'}}
        address='aws_iam_role.launch'
        planned=[{'address':a,'mode':'managed','values':{'name':'owned-launch'} if a==address else {}}
                 for a in LIFE['prepared_addresses'](config)]
        plan={'planned_values':{'root_module':{'resources':planned}}}
        LIFE['write'](directory/'plan.json',plan); LIFE['write'](directory/'config.tfvars.json',config)
        (directory/'saved.tfplan').write_bytes(b'partial-plan')
        target={'account_id':'000000000000','backend':{'bucket':'state'}}
        m={'stage':'prepare','target_name':'offline','target':target,'source':LIFE['source'](),
           'root':str(LIFE['stage_root']('prepare')),'backend':{'key':'runner/demo-dev-01.tfstate'},
           'state':{'lineage':None},'config_sha256':LIFE['sha'](LIFE['canon'](config)), 'scope':[],
           'plan_sha256':LIFE['sha'](b'partial-plan'),'plan_json_sha256':LIFE['sha']((directory/'plan.json').read_bytes())}
        LIFE['write'](directory/'review.json',m); LIFE['authorize'](directory,LIFE['sha'](LIFE['canon'](m)),'Authorized bounded offline recovery')
        LIFE['write'](directory/'apply-started.json',{'review_sha256':LIFE['sha'](LIFE['canon'](m))})
        current={'resources':[{'mode':'managed','type':'aws_iam_role','name':'launch','instances':[{'attributes':{'name':'owned-launch'}}]}]}
        def recover(stage='prepare'):
            raw=LIFE['canon'](current)
            state={'key':m['backend']['key'],'version':'native-version','lineage':'owned-lineage','sha256':LIFE['sha'](raw)}
            api=types.SimpleNamespace(get_object=lambda **kw:{'Body':io.BytesIO(raw)})
            candidate=dict(config,lease={'id':'new'}) if stage=='prepare' else dict(config,phase='retire')
            return LIFE['recovery_context'](directory,'offline',stage,candidate,target,state,None,lambda *_:api)
        with patch.dict(LIFE,{'platform_compute_absent':lambda *_:None}):
            self.assertEqual(recover()['owned'],[address])
            self.assertEqual(recover('cleanup')['owned'],[address])
            current['resources'][0]['instances'][0]['attributes']['name']='foreign-launch'
            with self.assertRaises(LIFE['Failure']): recover()
            current['resources'][0]['name']='foreign'
            with self.assertRaises(LIFE['Failure']): recover()
        current['resources'][0]['name']='launch';current['resources'][0]['instances'][0]['attributes']['name']='owned-launch'
        def live(*_): raise LIFE['Failure']('covered compute remains')
        with patch.dict(LIFE,{'platform_compute_absent':live}):
            with self.assertRaises(LIFE['Failure']): recover()
            with self.assertRaises(LIFE['Failure']): recover('cleanup')
    def test_target_derivation_preserves_old_registry_and_identity(self):
        old={'account_id':'000000000000','region':'us-east-1','operator_arn':'operator','profile':'offline',
             'deployment_role_arn':'old-role','backend':{'bucket':'old-state'},'inventory':{'resource_prefix':'ml-infra'}}
        frozen=copy.deepcopy(old);new=self.F['target'](old)
        self.assertEqual(old,frozen);self.assertEqual(new['operator_arn'],old['operator_arn'])
        self.assertTrue(new['deployment_role_arn'].endswith('/ml-infra-workspace-deployer'))
        self.assertTrue(new['backend']['bucket'].endswith('-ws-v1'));self.assertEqual(new['inventory']['repositories'],[])
    def test_fresh_scope_rejects_old_iam_and_all_updates(self):
        for address,actions in [('aws_iam_policy.runtime_boundary',['create']),('aws_iam_role.deployer',['update']),('aws_iam_role.deployer',['delete','create']),('aws_instance.workspace[0]',['create']),('aws_sns_topic.alerts',['create'])]:
            item={'address':address,'mode':'managed','change':{'actions':actions}}
            with self.assertRaises(LIFE['Failure']):LIFE['plan_scope']({'resource_changes':[item]},'fresh-platform')
    def test_exact_fresh_create_scope_is_admitted(self):
        items=[{'address':address,'mode':'managed','change':{'actions':['create']}} for address in self.F['FRESH_ADDRESSES']]
        self.assertEqual(len(LIFE['plan_scope']({'resource_changes':items},'fresh-platform')),len(items))
    def test_bootstrap_requires_all_seven_protections(self):
        items=[{'address':address,'mode':'managed','change':{'actions':['create']}} for address in self.F['BOOTSTRAP_ADDRESSES']]
        self.assertEqual(len(self.F['bootstrap_scope']({'resource_changes':items})),7)
        with self.assertRaises(LIFE['Failure']):self.F['bootstrap_scope']({'resource_changes':items[:-1]})
        items[0]['change']['actions']=['update']
        with self.assertRaises(LIFE['Failure']):self.F['bootstrap_scope']({'resource_changes':items})
    def test_partial_foundation_scopes_allow_only_original_missing_creates(self):
        owned='aws_s3_bucket.state'; missing='aws_s3_bucket_versioning.state'
        items=[{'address':owned,'mode':'managed','change':{'actions':['update']}},
               {'address':missing,'mode':'managed','change':{'actions':['create']}}]
        self.assertEqual(len(self.F['bootstrap_scope']({'resource_changes':items},{'owned':[owned]})),2)
        for address,actions in [(owned,['create']),(owned,['delete']),(missing,['update']),('aws_instance.foreign',['create'])]:
            with self.assertRaises(LIFE['Failure']): self.F['bootstrap_scope']({'resource_changes':[{'address':address,'mode':'managed','change':{'actions':actions}}]},{'owned':[owned]})
        recovery={'owned':['aws_iam_role.deployer'],'expected':['aws_iam_role.deployer','aws_sns_topic.workspace_alerts[0]']}
        planned={'resource_changes':[{'address':'aws_sns_topic.workspace_alerts[0]','mode':'managed','change':{'actions':['create']}}]}
        self.assertEqual(len(LIFE['plan_scope'](planned,'fresh-platform',recovery)),1)
        planned['resource_changes'][0]['address']='aws_instance.foreign'
        with self.assertRaises(LIFE['Failure']): LIFE['plan_scope'](planned,'fresh-platform',recovery)
    def test_unknown_or_existing_names_never_count_as_absent(self):
        class Error(Exception):
            def __init__(self,code):self.response={'Error':{'Code':code}}
        def denied():raise Error('403')
        with self.assertRaises(LIFE['Failure']):self.F['missing'](denied,{'404'})
        with self.assertRaises(LIFE['Failure']):self.F['missing'](lambda:{'exists':True},{'404'})
        def missing():raise Error('404')
        self.F['missing'](missing,{'404'})
    def test_retained_same_name_iam_stops_fresh_plan(self):
        calls=[]
        api=types.SimpleNamespace(get_role=lambda **kw:calls.append(kw) or {'Role':{'retained':True}})
        with self.assertRaises(LIFE['Failure']):self.F['absent'](None,lambda *_:api,{'aws_account_id':'000000000000','resource_prefix':'ml-infra','aws_region':'us-east-1'})
        self.assertEqual(len(calls),1)
    def test_existing_operator_grant_cannot_be_overwritten(self):
        class Missing(Exception):response={'Error':{'Code':'NoSuchEntity'}}
        def missing(**kw):raise Missing()
        api=types.SimpleNamespace(get_role=missing,get_instance_profile=missing,get_user_policy=lambda **kw:{'PolicyDocument':{'old':'grant'}})
        with patch.dict(LIFE,{'role_name':lambda _: 'offline-new-workspace'}):
            with self.assertRaises(LIFE['Failure']):self.F['prepare_absent'](None,lambda *_:api,{'workspace_identity':{'request':{'operators':['arn:aws:iam::000000000000:user/operator'],'workspace_id':'offline','operators':['arn:aws:iam::000000000000:user/operator']}}})
    def test_bootstrap_plan_binds_local_state_and_never_applies(self):
        directory=OUT/'bootstrap-offline-plan';config_path=OUT/'bootstrap-offline-config.json';calls=[]
        selected={'account_id':'000000000000','region':'us-east-1','profile':'offline','operator_arn':'arn:aws:iam::000000000000:user/offline',
                  'deployment_role_arn':'old','backend':{'bucket':'old','platform_key':'platform.tfstate','runner_prefix':'runner/'},'inventory':{'resource_prefix':'ml-infra'}}
        value={'aws_account_id':'000000000000','aws_region':'us-east-1','project_name':'ml-infra','state_bucket_name':self.F['target'](selected)['backend']['bucket']}
        LIFE['write'](config_path,value)
        class Missing(Exception):response={'Error':{'Code':'404'}}
        def head(**kw):raise Missing()
        api=types.SimpleNamespace(head_bucket=head)
        plan={'resource_changes':[{'address':a,'mode':'managed','change':{'actions':['create']}} for a in self.F['BOOTSTRAP_ADDRESSES']]}
        def run(args,*_):
            calls.append(args)
            if args[1:]==['version','-json']:return json.dumps({'terraform_version':'1.12.3'})
            if 'plan' in args:Path(next(a.split('=',1)[1] for a in args if a.startswith('-out='))).write_bytes(b'offline-plan')
            if 'show' in args:return json.dumps(plan)
            return ''
        with patch.dict(LIFE,{'run':run,'sessions':lambda _:(None,lambda *_:api,None)}),patch.dict(LIFE['boundary'],{'targets':lambda:{'aws-offline':selected},'environment':lambda _: {},'identity':lambda *_:selected['operator_arn']}):
            self.F['bootstrap_plan']('aws-offline',str(config_path),str(directory))
        m=LIFE['read'](directory/'review.json')
        self.assertEqual(m['backend'],{'path':str(directory/'bootstrap.tfstate')});self.assertFalse(m['deployment_authorized'])
        self.assertFalse(any('apply' in call for call in calls));self.assertFalse((directory/'authorization.json').exists())
    def test_changed_bootstrap_plan_cannot_reach_native_context(self):
        directory=OUT/'bootstrap-tamper';directory.mkdir()
        LIFE['write'](directory/'config.tfvars.json',{});LIFE['write'](directory/'backend.json',{'path':str(directory/'bootstrap.tfstate')})
        LIFE['write'](directory/'plan.json',{});(directory/'saved.tfplan').write_bytes(b'tampered')
        m={'root':str(ROOT/'infra/aws/bootstrap/workspace'),'backend':{'path':str(directory/'bootstrap.tfstate')},'stage':'bootstrap',
           'source':LIFE['source'](),'config_sha256':LIFE['sha'](LIFE['canon']({})),'plan_sha256':'a'*64,'scope':[]}
        LIFE['write'](directory/'review.json',m);LIFE['authorize'](directory,LIFE['sha'](LIFE['canon'](m)),'Explicit offline fixture approval')
        calls=[]
        with patch.dict(self.F,{'bootstrap_context':lambda *a:calls.append(a)}):
            with self.assertRaises(LIFE['Failure']):LIFE['apply'](directory)
        self.assertEqual(calls,[]);self.assertFalse((directory/'apply-started.json').exists())
    def test_fresh_root_cannot_disable_guard(self):
        selected=self.F['target']({'account_id':'000000000000','region':'us-east-1','operator_arn':'operator','backend':{},'inventory':{'resource_prefix':'ml-infra'}})
        value={'aws_account_id':selected['account_id'],'aws_region':selected['region'],'resource_prefix':'ml-infra','project_name':'ml-infra','state_bucket_arn':'arn:aws:s3:::'+selected['backend']['bucket'],'workspace_guard':None}
        with self.assertRaises(LIFE['Failure']):self.F['config'](value,selected)

def evaluate(document,action,resource,context):
    # Covers only emitted IAM operators; does not attest SCP/account/live rights.
    def values(value): return value if isinstance(value,list) else [value]
    allowed=False
    for statement in document['Statement']:
        key='Action' if 'Action' in statement else 'NotAction'
        matched=any(fnmatch.fnmatchcase(action.lower(),p.lower()) for p in values(statement[key]))
        if matched==(key=='NotAction'): continue
        resource_key='Resource' if 'Resource' in statement else 'NotResource'
        resource_matched=any(fnmatch.fnmatchcase(resource,p) for p in values(statement[resource_key]))
        if resource_matched==(resource_key=='NotResource'): continue
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

def iam_cases(runner,platform,config,git_runner,git_platform,fresh_platform):
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
    for plan,address in [(git_runner,'aws_iam_role_policy.workspace_storage["fraud-detection-dev-01"]'),
                         (git_platform,'aws_iam_policy.project_workspace_boundary["demo"]')]:
        policy=json.loads(resource(plan,address)['policy'])
        secret=next(s['Resource'][0] for s in policy['Statement'] if s['Sid']=='ReadReviewedGitCredentials')
        check(policy,'secretsmanager:GetSecretValue',secret,{},True)
        for other in (secret+'other',secret.replace(':us-east-1:',':us-west-2:'),secret.replace(':000000000000:',':999999999999:')):
            check(policy,'secretsmanager:GetSecretValue',other,{},False)
        for action in ('secretsmanager:PutSecretValue','secretsmanager:UpdateSecret','secretsmanager:DeleteSecret','iam:PutRolePolicy'):
            check(policy,action,secret,{},False)
        key='arn:aws:kms:us-east-1:000000000000:key/reviewed-secret-key'
        decryption={'kms:ViaService':'secretsmanager.us-east-1.amazonaws.com','kms:EncryptionContext:SecretARN':secret}
        check(policy,'kms:Decrypt',key,decryption,True)
        for bad in ({},dict(decryption,**{'kms:ViaService':'ec2.us-east-1.amazonaws.com'}),
                    dict(decryption,**{'kms:EncryptionContext:SecretARN':secret+'foreign'})):
            check(policy,'kms:Decrypt',key,bad,False)
        for other in (key.replace(':us-east-1:',':us-west-2:'),key.replace(':000000000000:',':999999999999:')):
            check(policy,'kms:Decrypt',other,decryption,False)
        for action in ('kms:Encrypt','kms:GenerateDataKey'):
            check(policy,action,key,decryption,False)
    for plan,address in [(runner,'aws_iam_role_policy.workspace_storage["fraud-detection-dev-01"]'),
                         (fresh_platform,'aws_iam_policy.project_workspace_boundary["demo"]')]:
        check(json.loads(resource(plan,address)['policy']),'secretsmanager:GetSecretValue',secret,{},False)
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
    for name in ('scripts/workspace/probe-toolbox.py','shared/workspace/toolbox.json','scripts/aws/clone-project.sh','scripts/aws/workspace-guest-observe.sh','scripts/aws/workspace-ssh.sh','scripts/aws/workspace-job.sh','scripts/aws/workspace_files.py'): members[name]=(ROOT/name).read_bytes()
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
    for root,testdir,varfile in [('infra/aws/runner/workspace','../../../../tests/aws/workspace',config_path),('infra/aws/platform','../../../tests/aws/guard',platform_path),('infra/aws/bootstrap/workspace','../../../../tests/aws/foundation/bootstrap',None),('infra/aws/platform/workspace','../../../../tests/aws/foundation/platform',platform_path)]:
        label={'infra/aws/runner/workspace':'runner','infra/aws/platform':'platform','infra/aws/bootstrap/workspace':'fresh-bootstrap','infra/aws/platform/workspace':'fresh-platform'}[root]
        env={k:v for k,v in os.environ.items() if not k.startswith(('AWS_','TF_'))}
        env.update(TF_DATA_DIR=str(OUT/(label+'-data')),AWS_EC2_METADATA_DISABLED='true',PYTHONDONTWRITEBYTECODE='1')
        for phase,args in [('init',['init','-backend=false','-lockfile=readonly','-input=false','-no-color']),('test',['test','-test-directory='+testdir,*(['-var-file='+str(varfile)] if varfile else []),'-json','-verbose','-no-color'])]:
            log=OUT/(label+'-'+phase+'.log')
            with log.open('w') as f: result=subprocess.run(['tofu','-chdir='+root,*args],env=env,stdout=f,stderr=subprocess.STDOUT,timeout=180)
            if result.returncode: raise RuntimeError(label+' '+phase+' failed: '+str(log.relative_to(ROOT)))
        events=[json.loads(line) for line in log.read_text().splitlines()]
        plans[label]={e['@testrun']:e['test_plan'] for e in events if e.get('type')=='test_plan'}
    fresh=plans['fresh-platform']['independent_workspace_platform']
    LIFE['plan_scope'](fresh,'fresh-platform')
    LIFE['foundation']['bootstrap_scope'](plans['fresh-bootstrap']['protected_new_backend'])
    fresh_addresses={r['address'] for r in fresh['planned_values']['root_module']['resources'] if r['mode']=='managed'}
    if fresh_addresses!=LIFE['foundation']['FRESH_ADDRESSES']:raise AssertionError('fresh root creates unexpected/missing resources')
    runner=plans['runner']['guarded_launch_is_encrypted_disposable_and_tagged']
    LIFE['runner_provider_scope'](runner)
    # Validate the entire production handoff against rendered OpenTofu user-data,
    # rather than splicing one command into a prevalidated handoff fixture.
    request=config['workspace_identity']['request']
    activation=start-dt.timedelta(minutes=1)
    activation=activation.astimezone(dt.timezone(dt.timedelta(hours=2)))
    handoff=LIFE['render_handoff']({'account_id':config['aws_account_id'],'region':config['aws_region'],'profile':'reviewed-operator'},
                                 config,{'guard_iam':{'guard_active_at':LIFE['stamp'](activation)}},runner,'i-00000000000000001')
    LIFE['write'](OUT/'production-request.json',request); LIFE['write'](OUT/'production-handoff.json',handoff)
    subprocess.run([sys.executable,'scripts/workspace/validate.py',str(OUT/'production-request.json'),
                    '--handoff',str(OUT/'production-handoff.json')],check=True,capture_output=True,timeout=15)
    resources={r['address']:r for r in runner['configuration']['root_module']['resources']}
    if 'instance_initiated_shutdown_behavior' in resources['aws_instance.workspace'].get('expressions',{}):
        raise AssertionError('guest-shutdown setting triggers forbidden ModifyInstanceAttribute after RunInstances')
    depends=resources['aws_instance.workspace'].get('depends_on',[])
    for name in ('aws_scheduler_schedule.workspace_deadline','aws_iam_role_policy.launch','aws_iam_instance_profile.workspace','aws_ssm_document.terminal','aws_ssm_document.job','aws_iam_user_policy.operator'):
        if name not in depends: raise AssertionError('missing guard/identity/terminal ordering: '+name)
    if 'aws_scheduler_schedule.workspace_deadline' not in resources['aws_iam_role.launch'].get('depends_on',[]):
        raise AssertionError('launch identity can exist before the expiry schedule')
    LIFE['plan_scope']({'resource_changes':[r for r in runner['resource_changes'] if r['address']=='aws_instance.workspace[0]']},'launch')
    return {'workspace_mocked_plans':len(plans['runner']),'workspace_mocked_apply_cases':1,'platform_mocked_plans':len(plans['platform']),'fresh_foundation_mocked_plans':len(plans['fresh-platform'])+len(plans['fresh-bootstrap']),
            'production_handoff_validated':True,
            'iam_cases':iam_cases(runner,plans['platform']['persistent_sweep_failure_path_and_runtime_ceiling'],config,
                                  plans['runner']['git_runtime_reads_only_workspace_secret'],
                                  plans['fresh-platform']['git_boundary_reads_only_reviewed_secret'],fresh)}

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
