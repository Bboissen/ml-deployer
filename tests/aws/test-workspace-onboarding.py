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
