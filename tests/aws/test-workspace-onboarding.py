"""Different native scopes, RAM-key faults, capacity and retained lineage offline."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]; os.chdir(ROOT)
def module(name):
    spec=importlib.util.spec_from_file_location(name, ROOT/'scripts/aws'/name)
    result=importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result
W=module('workspace.py'); O=module('workspace-onboarding.py'); R=module('workspace_ram.py'); L=W.L

class Onboarding(unittest.TestCase):
    def test_reserved_ssm_prefixes_migrate_only_the_owned_document_names(self):
        operator='arn:aws:iam::111111111111:user/operator'
        target={'operator_arn':operator,'deployment_role_arn':'arn:aws:iam::111111111111:role/deployer'}
        for prefix in ('aws-example','amazon-example','amzn-example','AWSSupport-example','demand'):
            with self.subTest(prefix=prefix),tempfile.TemporaryDirectory(dir=ROOT/'evidence') as temporary:
                name=prefix+'-run-ws-project-hash'
                safe=L['ssm_name'](name)
                self.assertFalse(safe.lower().startswith(('aws','amazon','amzn')))
                self.assertEqual(L['ssm_name'](safe),safe)
                arn='arn:aws:ssm:us-east-1:111111111111:document/'
                before={'Version':'2012-10-17','Statement':[
                    {'Sid':'ManageReviewedNonRootTerminalDocuments','Effect':'Allow','Action':['ssm:CreateDocument'],
                     'Resource':[arn+name+'-terminal',arn+name+'-job']},
                    {'Sid':'DenyReviewedOperatorPolicyMutation','Effect':'Deny','Action':['iam:*'],'Resource':[operator]}]}
                after=copy.deepcopy(before)
                after['Statement'][0]['Resource']=[arn+safe+'-terminal',arn+safe+'-job']
                L['deployer_access_scope'](before,after,{})
                bad=copy.deepcopy(after); bad['Statement'][0]['Resource'].append(arn+'other-project-*')
                with self.assertRaisesRegex(L['Failure'],'unrelated document resources'):
                    L['deployer_access_scope'](before,bad,{})
                L['write'](Path(temporary)/'config.tfvars.json',{'deployer_principal_arns':[operator]})
                iam=types.SimpleNamespace(get_role_policy=lambda **_: {'RoleName':'deployer','PolicyName':'deployer','PolicyDocument':before})
                with patch.dict(L,{'sessions':lambda _: (None,lambda *args:iam,None)}):
                    review=O.iam_migration(L,{'plan_directory':temporary},target)
                self.assertEqual(review['required'],safe!=name)

    def test_iam_migration_reviews_only_exact_operator_tightening(self):
        operator='arn:aws:iam::111111111111:user/operator'; role='demand-workspace-deployer'
        target={'operator_arn':operator,'deployment_role_arn':'arn:aws:iam::111111111111:role/'+role}
        old={'Version':'2012-10-17','Statement':[
            {'Sid':'ManageReviewedNonRootTerminalDocuments','Effect':'Allow','Action':['ssm:GetDocument'],
             'Resource':['arn:aws:ssm:us-east-1:111111111111:document/demand-terminal']},
            {'Sid':'ManageReviewedNamedOperatorWorkspaceGrant','Effect':'Allow',
             'Action':['iam:PutUserPolicy','iam:DeleteUserPolicy','iam:GetUserPolicy','iam:ListUserTags'],'Resource':[operator]}]}
        observed={'RoleName':role,'PolicyName':role,'PolicyDocument':old}
        iam=types.SimpleNamespace(get_role_policy=lambda **kwargs:observed)
        with tempfile.TemporaryDirectory(dir=ROOT/'evidence') as temporary:
            directory=Path(temporary); L['write'](directory/'config.tfvars.json',{'deployer_principal_arns':[operator]})
            binding={'plan_directory':str(directory)}
            with patch.dict(L,{'sessions':lambda _: (None,lambda *args:iam,None)}):
                review=O.iam_migration(L,binding,target)
                self.assertTrue(review['required'])
                self.assertEqual(review['operator_arns'],[operator])
                self.assertEqual(review['before_policy_sha256'],L['sha'](L['canon'](old)))
                bad=copy.deepcopy(old); bad['Statement'][-1]['Resource']=['arn:aws:iam::111111111111:user/other']
                observed['PolicyDocument']=bad
                with self.assertRaisesRegex(L['Failure'],'unrelated permissions'): O.iam_migration(L,binding,target)
                new=copy.deepcopy(old); new['Statement'][-1]={'Sid':'DenyReviewedOperatorPolicyMutation','Effect':'Deny','Action':'iam:*','Resource':operator}
                observed['PolicyDocument']=new
                self.assertFalse(O.iam_migration(L,binding,target)['required'])
                new['Statement'][-1]['Resource']='arn:aws:iam::111111111111:user/other'
                with self.assertRaisesRegex(L['Failure'],'separately reviewed'): O.iam_migration(L,binding,target)

    def test_iam_migration_rejects_policy_drift_before_saving_plan(self):
        target={'operator_arn':'arn:aws:iam::111111111111:user/operator',
                'deployment_role_arn':'arn:aws:iam::111111111111:role/demand-workspace-deployer'}
        reviewed={'required':True,'operator_arns':[target['operator_arn']],'role_arn':target['deployment_role_arn'],
                  'before_policy_sha256':'a'*64}
        with tempfile.TemporaryDirectory(dir=ROOT/'evidence') as temporary:
            with patch.object(O,'iam_migration',return_value={**reviewed,'before_policy_sha256':'b'*64}),\
                 patch.object(O,'apply_access',side_effect=AssertionError('planned unreviewed drift')):
                with self.assertRaisesRegex(L['Failure'],'changed after review'):
                    O.migrate_iam(L,'target',{},target,reviewed,Path(temporary)/'migration','approved bounded migration')

    def test_iam_saved_plan_preserves_git_inputs_and_binds_refreshed_before_policy(self):
        before={'Statement':[{'Sid':'retained'}]}
        reviewed={'before_policy_sha256':L['sha'](L['canon'](before))}
        platform={'deployer_principal_arns':['operator'],'workspace_git_secret_arns':{'project':['secret']}}
        for fault in (None,'policy-drift','boundary-change'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory(dir=ROOT/'evidence') as temporary:
                root=Path(temporary); folder=root/'foundation-iam'; applies=[]; targeted=[]
                binding={'plan_directory':str(root/'retained-platform')}
                def plan(name,stage,inputs,directory,dependency,**options):
                    targeted.append(options)
                    self.assertEqual(L['read'](inputs),platform)
                    self.assertEqual(dependency,binding['plan_directory'])
                    Path(directory).mkdir()
                    prior=before if fault!='policy-drift' else {'Statement':[{'Sid':'changed'}]}
                    changes=[{'mode':'managed','address':'aws_iam_role_policy.deployer',
                              'change':{'actions':['update'],'before':{'policy':json.dumps(prior)}}}]
                    if fault=='boundary-change':
                        changes.append({'mode':'managed','address':'aws_iam_policy.project_workspace_boundary["project"]',
                                        'change':{'actions':['update']}})
                    L['write'](Path(directory)/'plan.json',{'resource_changes':changes})
                    L['write'](Path(directory)/'review.json',{'scope':[{'address':r['address'],'actions':['update']} for r in changes]})
                def apply(_L,directory,authorization):
                    applies.append(directory); L['write'](directory/'apply-result.json',{'status':'success'})
                with patch.dict(L,{'native_plan':plan}),patch.object(O,'bind_plan',side_effect=apply),\
                     patch.object(O,'capture',return_value={'plan_directory':str(folder)}):
                    if fault:
                        with self.assertRaisesRegex(L['Failure'],'saved plan differs'):
                            O.apply_access(L,'target',binding,platform,folder,'approved bounded migration',iam_review=reviewed)
                        self.assertEqual(applies,[])
                    else:
                        result=O.apply_access(L,'target',binding,platform,folder,'approved bounded migration',iam_review=reviewed)
                        self.assertEqual(result['plan_directory'],str(folder)); self.assertEqual(applies,[folder])
                self.assertEqual(targeted,[{'deployer_only':True}])

    def test_access_recovery_uses_new_plans_and_preserves_consumed_attempts(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'evidence') as temporary:
            root=Path(temporary); initial=root/'access'; initial.mkdir()
            L['write'](initial/'apply-started.json',{'review_sha256':'a'*64})
            binding={'plan_directory':str(root/'original-platform')}; platform={'deployer_principal_arns':['operator']}
            plans=[]; applies=[]
            def plan(name,stage,inputs,folder,dependency,recover_from=None):
                plans.append({'directory':folder,'dependency':dependency,'recover_from':recover_from,'stage':stage})
                Path(folder).mkdir()
            def apply(_L,folder,authorization):
                applies.append(folder); L['write'](folder/'apply-started.json',{'review_sha256':'b'*64})
                if len(applies)==1: raise TimeoutError('lost recovery response')
                L['write'](folder/'apply-result.json',{'status':'success'})
            def capture(_L,name,folder,output):
                L['write'](output,{'workspace_platform':{}})
                return {'plan_directory':str(folder),'outputs_file':str(output),'outputs_sha256':L['sha'](output.read_bytes())}
            with patch.dict(L,{'native_plan':plan}),patch.object(O,'bind_plan',side_effect=apply),patch.object(O,'capture',side_effect=capture):
                with self.assertRaises(TimeoutError): O.apply_access(L,'target',binding,platform,initial,'approved bounded migration')
                first=O.recovered_folder(L,root,'access')
                result=O.apply_access(L,'target',binding,platform,initial,'approved bounded migration')
                again=O.apply_access(L,'target',binding,platform,initial,'approved bounded migration')
            self.assertEqual(result,again)
            self.assertEqual(len(plans),2); self.assertEqual(len(applies),2)
            self.assertEqual(plans[0]['recover_from'],str(initial)); self.assertEqual(plans[1]['recover_from'],str(first))
            self.assertTrue(all(p['dependency']==binding['plan_directory'] and p['stage']=='workspace-access' for p in plans))
            self.assertNotEqual(result['plan_directory'],str(initial))
            self.assertTrue((initial/'apply-started.json').exists()); self.assertTrue((first/'apply-started.json').exists())

    def test_interruption_after_authorization_reuses_exact_plan_binding(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'evidence') as temporary:
            directory=Path(temporary); review={'plan_sha256':'a'*64,'scope':[]}
            L['write'](directory/'review.json',review)
            L['authorize'](str(directory),L['sha'](L['canon'](review)),'authorized bounded test')
            with patch.dict(L,{'apply':lambda path:{'status':'success'},
                               'authorize':lambda *_:self.fail('immutable authorization was rewritten')}):
                self.assertEqual(O.bind_plan(L,directory,'authorized bounded test'),{'status':'success'})
                with self.assertRaisesRegex(L['Failure'],'authorization differs'):
                    O.bind_plan(L,directory,'different authorization')
    def test_user_role_paths_and_sso_owner_boundary(self):
        identity={'Account':'111111111111','Arn':'arn:aws:iam::111111111111:user/team/operator'}
        self.assertEqual(O.canonical_operator(L,identity),identity['Arn'])
        identity['Arn']='arn:aws:sts::111111111111:assumed-role/Operator/session'
        iam=types.SimpleNamespace(get_role=lambda **_: {'Role':{'RoleName':'Operator','Arn':'arn:aws:iam::111111111111:role/team/Operator'}})
        self.assertEqual(O.canonical_operator(L,identity,iam),'arn:aws:iam::111111111111:role/team/Operator')
        with self.assertRaises(L['Failure']): O.canonical_operator(L,identity)
        iam.get_role=lambda **_: {'Role':{'RoleName':'Operator','Arn':'arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/Operator'}}
        with self.assertRaisesRegex(L['Failure'],'owner-managed'): O.canonical_operator(L,identity,iam)
        self.assertTrue(L['operator_matches']('arn:aws:iam::111111111111:role/team/Operator',identity['Arn']))
        self.assertFalse(L['operator_matches']('arn:aws:iam::222222222222:role/team/Operator',identity['Arn']))
    def test_two_projects_render_closed_fresh_scope(self):
        for account,project,kind in [('111111111111','demand','user'),('222222222222','fraud','role')]:
            deployment={'configuration':{'project':project,'profile':'temporary','region':'us-east-1'},'account_id':account,
                'names':{'resource_prefix':project+'-1234567890','workload_bucket':W.P.workload_bucket(account,'us-east-1',project),
                         'deployer_role_arn':f'arn:aws:iam::{account}:role/{project}-1234567890-workspace-deployer'},
                'backend':{'bucket':project+'-tofu-state-'+account+'-us-east-1-ws-v1','region':'us-east-1',
                           'platform_key':'aws/'+account+'/us-east-1/platform/platform.tfstate','runner_prefix':'aws/'+account+'/us-east-1/runner/'}}
            operator=f'arn:aws:iam::{account}:{kind}/team/operator'; selected=O.target(deployment,operator)
            self.assertEqual(L['foundation']['target'](selected),selected)
            with tempfile.TemporaryDirectory(dir=ROOT/'evidence') as temporary:
                result=O.prepare(L,deployment,Path(temporary)/'foundation',{'guard_zip_path':'guard.zip','guard_zip_sha256':'a'*64},
                    {'selected':{**L['supported_sizes']()['r8i.4xlarge'],'instance_type':'r8i.4xlarge','availability_zone':'us-east-1b','hourly_usd':1}},operator)
                target_name='aws-'+selected['inventory']['resource_prefix']
                target_config=Path(temporary)/'target-config.json'
                L['write'](target_config,{'target_name':target_name,'target':L['read'](Path(result['directory'])/'target.json')})
                with patch.dict(os.environ,{'WORKSPACE_CONFIG':str(target_config)}):
                    validated=L['boundary']['targets']()[target_name]
                self.assertEqual(validated,selected)
                self.assertEqual(validated['inventory']['schedule_groups'],['default'])
                config=L['read'](Path(result['directory'])/'platform.tfvars.json')
                self.assertEqual(list(config['ml_projects']),[project])
                plan={'variables':{'ml_projects':{'value':config['ml_projects']},'provision_alert_topic':{'value':True}},
                      'resource_changes':[{'mode':'managed','address':f'aws_s3_bucket.project["{project}"]','change':{'actions':['create']}}]}
                self.assertEqual(len(L['plan_scope'](plan,'fresh-platform')),1)
                plan['resource_changes'][0]['address']='aws_s3_bucket.project["foreign"]'
                with self.assertRaises(L['Failure']): L['plan_scope'](plan,'fresh-platform')
    def test_capacity_ranks_ram_and_applies_only_explicit_price_limit(self):
        catalog=L['supported_sizes']()
        def types_(**kw): return {'InstanceTypes':[{'InstanceType':s,'VCpuInfo':{'DefaultVCpus':catalog[s]['cpus']},
            'MemoryInfo':{'SizeInMiB':catalog[s]['cpus']*8192},'ProcessorInfo':{'SupportedArchitectures':['x86_64']}} for s in kw['InstanceTypes']]}
        ec2=types.SimpleNamespace(describe_images=lambda **_: {'Images':[{'Name':L['TOOLBOX']['ami_name'],'State':'available','Architecture':'x86_64','EnaSupport':True}]},
            describe_instances=lambda **kw: {'Reservations':[],'NextToken':'next'} if 'NextToken' not in kw else {'Reservations':[]},
            describe_instance_types=types_,describe_availability_zones=lambda: {'AvailabilityZones':[{'ZoneName':'us-east-1b','State':'available'}]},
            describe_instance_type_offerings=lambda **_: {'InstanceTypeOfferings':[{'InstanceType':s,'Location':'us-east-1b'} for s in catalog]})
        quota=types.SimpleNamespace(get_service_quota=lambda **_: {'Quota':{'Value':32}})
        def prices(**kw):
            sku=next(x['Value'] for x in kw['Filters'] if x['Field']=='instanceType')
            return {'PriceList':[json.dumps({'terms':{'OnDemand':{'x':{'priceDimensions':{'x':{'unit':'Hrs','pricePerUnit':{'USD':str(catalog[sku]['cpus']/8)}}}}}}})]}
        price=types.SimpleNamespace(get_products=prices)
        client=lambda _,service: {'ec2':ec2,'service-quotas':quota,'pricing':price}[service]
        self.assertEqual(O.capacity(L,None,client,'us-east-1')['selected']['instance_type'],'r8i.8xlarge')
        self.assertEqual(O.capacity(L,None,client,'us-east-1',1)['selected']['instance_type'],'r8i.2xlarge')
        with self.assertRaises(L['Failure']): O.capacity(L,None,client,'us-east-1',0.1)
        ec2.describe_availability_zones=lambda: {'AvailabilityZones':[{'ZoneName':zone,'State':'available'} for zone in ('us-east-1a','us-east-1b')]}
        ec2.describe_instance_type_offerings=lambda **_: {'InstanceTypeOfferings':[{'InstanceType':s,'Location':zone} for s in catalog for zone in ('us-east-1a','us-east-1b')]}
        self.assertEqual(O.capacity(L,None,client,'us-east-1')['selected']['availability_zone'],'us-east-1a')
        self.assertEqual(O.capacity(L,None,client,'us-east-1',availability_zone='us-east-1b')['selected']['availability_zone'],'us-east-1b')
        with self.assertRaisesRegex(L['Failure'],'availability zone'):
            O.capacity(L,None,client,'us-east-1',availability_zone='us-east-1c')
        ec2.describe_instance_type_offerings=lambda **_: {'InstanceTypeOfferings':[{'InstanceType':s,'Location':'us-east-1a'} for s in catalog]}
        with self.assertRaisesRegex(L['Failure'],'no supported'):
            O.capacity(L,None,client,'us-east-1',availability_zone='us-east-1b')
    def test_repeated_pagination_stops(self):
        api=types.SimpleNamespace(list=lambda **_: {'Items':[],'NextToken':'same'})
        with self.assertRaises(L['Failure']): O.pages(L,api,'list','Items')

class RAM(unittest.TestCase):
    def test_linux_removes_key_on_error_and_refuses_disk_fallback(self):
        with patch.object(R.platform,'system',return_value='Linux'),patch.object(R.subprocess,'check_output',return_value=b'tmpfs\n'):
            with self.assertRaises(RuntimeError):
                with R.key_directory() as path:
                    (path/'key').write_text('test-only'); raise RuntimeError('interrupted')
            self.assertFalse(path.exists())
        with patch.object(R.platform,'system',return_value='Linux'),patch.object(R.subprocess,'check_output',return_value=b'ext4'):
            with self.assertRaises(ValueError):
                with R.key_directory(): pass
    def test_macos_format_failure_detaches_only_created_device(self):
        calls=[]
        def run(argv,**kw):
            calls.append(argv)
            if argv[0]=='diskutil': raise subprocess.CalledProcessError(1,argv)
        with patch.object(R.platform,'system',return_value='Darwin'),patch.object(R.subprocess,'check_output',return_value=b'/dev/disk97\n'),patch.object(R.subprocess,'run',side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                with R.key_directory(): pass
        self.assertEqual(calls[-1],['hdiutil','detach','/dev/disk97'])

if __name__=='__main__': unittest.main(verbosity=2)
