#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export WORKSPACE_TARGET_SCRIPT="${REPO_ROOT}/scripts/aws/workspace-target.sh"
export WORKSPACE_TARGET_TEMPLATE="${REPO_ROOT}/infra/aws/targets.example.json"
exec python3 - <<'PY'
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = os.environ["WORKSPACE_TARGET_SCRIPT"]
TEMPLATE = json.loads(Path(os.environ["WORKSPACE_TARGET_TEMPLATE"]).read_text())


class Targets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="aws-target-offline-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "infra/aws/platform").mkdir(parents=True)
        (self.root / "infra/aws/platform/provider.tf").write_text("# test only\n")
        (self.root / "evidence/aws").mkdir(parents=True)
        self.config = json.loads(json.dumps(TEMPLATE))
        self.save()
        self.native = self.root / "native-config"
        self.native.write_text("[profile personal-temporary]\ncredential_process = approved-existing-login\n[profile lab-temporary]\ncredential_process = approved-existing-login\n")
        self.creds = self.root / "native-credentials"
        self.creds.write_text("")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "aws"
        fake.write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['FAKE_AWS_CALLS'],'a') as f: f.write(json.dumps(args)+'\\n')
profile=args[args.index('--profile')+1] if '--profile' in args else os.environ['AWS_PROFILE']
mode=os.environ.get('FAKE_MODE','ok')
if mode in ('expired','missing'):
 print('session expired SENTINEL_SECRET' if mode=='expired' else 'Unable to locate credentials SENTINEL_SECRET',file=sys.stderr);sys.exit(255)
account='111111111111' if profile=='personal-temporary' else '222222222222'
if mode=='wrong-account':account='333333333333'
if 'get-caller-identity' in args:
 arn='arn:aws:sts::'+account+':assumed-role/WorkspaceOperator/session'
 if mode=='wrong-role':arn=arn.replace('WorkspaceOperator','OtherRole')
 print(json.dumps({'account':account,'arn':arn}));sys.exit(0)
if mode=='direct-command':
 print(json.dumps({'argv':args,'profile':os.environ['AWS_PROFILE'],'region':os.environ['AWS_REGION'],'stdin':sys.stdin.read()}));sys.exit(0)
if mode=='state' and 'head-object' in args:
 print(json.dumps({'version':'immutable-version','size':600}));sys.exit(0)
if mode=='state' and 'get-object' in args:
 print(json.dumps({'lineage':'test-lineage','serial':7,'outputs':{'password':'SENTINEL_SECRET'},'resources':[{'mode':'managed','type':'aws_iam_role','name':'runtime','instances':[{'attributes':{'id':'test-role','password':'SENTINEL_SECRET'}}]}]}));print('null');sys.exit(0)
if mode=='no-such-resource':print('NoSuchEntity: resource not found SENTINEL_SECRET',file=sys.stderr);sys.exit(254)
if mode=='denied':print('AccessDenied SENTINEL_SECRET',file=sys.stderr);sys.exit(254)
if 'list-roles' in args: print(json.dumps({'items':[],'more':True,'marker':'next-page'}))
else: print('{}')
''')
        fake.chmod(0o700)
        git = self.bin / "git"
        git.write_text("#!/usr/bin/env bash\nif [[ \"$1\" == rev-parse ]]; then printf '%s\\n' 982a236b37906518d47892ba9141338368c5336a; elif [[ \"$1\" == diff ]]; then printf '%s' \"${FAKE_SOURCE_DATA:-}\"; fi\n")
        git.chmod(0o700)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('AWS_', 'TF_VAR_', 'TF_CLI_ARGS')) and k not in ('TF_DATA_DIR','TF_WORKSPACE','TF_CLI_CONFIG_FILE','BOTO_CONFIG')}
        self.env.update(PATH=str(self.bin)+os.pathsep+self.env['PATH'],AWS_CONFIG_FILE=str(self.native),AWS_SHARED_CREDENTIALS_FILE=str(self.creds),FAKE_AWS_CALLS=str(self.root/'calls'))

    def save(self):
        (self.root / 'evidence/aws/targets.json').write_text(json.dumps(self.config))

    def run_cli(self, *args, success=True, **env):
        p = subprocess.run(['bash',SCRIPT,*args],cwd=self.root,env={**self.env,**env},capture_output=True,text=True,timeout=30)
        self.assertEqual(p.returncode,0 if success else 2,p.stdout+p.stderr)
        return json.loads(p.stdout) if success else p

    def calls(self):
        p = self.root / 'calls'
        return [json.loads(v) for v in p.read_text().splitlines()] if p.exists() else []

    def blocked(self, phrase, **env):
        p = self.run_cli('preflight','aws-personal',success=False,**env)
        self.assertIn(phrase,p.stderr)
        self.assertNotIn('SENTINEL_SECRET',p.stderr)
        self.assertTrue(all('get-caller-identity' in c for c in self.calls()))

    def test_explicit_list_has_no_api_calls(self):
        self.assertEqual([t['target'] for t in self.run_cli('list')],['aws-lab','aws-personal'])
        self.assertEqual(self.calls(),[])

    def test_two_targets_in_parallel_have_distinct_contexts(self):
        before = hashlib.sha256(self.native.read_bytes()).hexdigest()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            futures = [pool.submit(self.run_cli,'context',n,'platform') for n in ('aws-personal','aws-lab')]
            contexts = [f.result() for f in futures]
        self.assertNotEqual(contexts[0]['data_dir'],contexts[1]['data_dir'])
        self.assertNotEqual(contexts[0]['backend']['bucket'],contexts[1]['backend']['bucket'])
        for c in contexts:
            p = Path(c['data_dir']).parent
            text = (p/'backend.hcl').read_text()
            self.assertIn(c['configuration']['profile'],text)
            self.assertIn(c['configuration']['account_id'],text)
            self.assertEqual(c['provider_environment']['AWS_PROFILE'],c['backend']['profile'])
            self.assertEqual(c['provider_environment']['TF_VAR_aws_account_id'],c['configuration']['account_id'])
        self.assertEqual(hashlib.sha256(self.native.read_bytes()).hexdigest(),before)

    def test_changed_binding_cannot_reuse_backend_or_evidence(self):
        first = self.run_cli('context','aws-personal','platform')
        self.config['targets']['aws-personal']['backend']['bucket']='another-reviewed-state'
        self.save()
        second = self.run_cli('context','aws-personal','platform')
        self.assertNotEqual(first['data_dir'],second['data_dir'])
        self.assertTrue(Path(first['data_dir']).parent.exists())

    def test_root_and_changed_source_cannot_reuse_initialization(self):
        platform=self.run_cli('context','aws-personal','platform')
        runner=self.run_cli('context','aws-personal','runner')
        changed=self.run_cli('context','aws-personal','platform',FAKE_SOURCE_DATA='changed source')
        self.assertEqual(len({c['data_dir'] for c in (platform,runner,changed)}),3)

    def test_backend_for_another_account_is_rejected(self):
        self.config['targets']['aws-personal']['backend']['platform_key']='aws/222222222222/us-east-1/platform/platform.tfstate'
        self.save()
        self.blocked('backend keys must match')
        self.assertEqual(self.calls(),[])

    def test_account_mismatch_stops_before_inventory(self):
        self.blocked('account mismatch',FAKE_MODE='wrong-account')

    def test_role_mismatch_stops_before_inventory(self):
        self.blocked('identity mismatch',FAKE_MODE='wrong-role')

    def test_expired_login_is_redacted(self):
        self.blocked('expired_login',FAKE_MODE='expired')
        evidence=''.join(p.read_text() for p in (self.root/'evidence/aws').rglob('*.json'))
        self.assertNotIn('SENTINEL_SECRET',evidence)

    def test_missing_login(self):
        self.blocked('missing_login',FAKE_MODE='missing')

    def test_missing_profile_has_no_default_fallback(self):
        self.native.write_text('[default]\ncredential_process = default-login\n')
        self.blocked('native profile is missing')
        self.assertEqual(self.calls(),[])

    def test_missing_target_field_stops_before_authentication(self):
        del self.config['targets']['aws-personal']['operator_arn']
        self.save()
        self.blocked('missing or unknown target fields')
        self.assertEqual(self.calls(),[])

    def test_conflicting_ambient_sources(self):
        for key in ('AWS_ACCESS_KEY_ID','AWS_PROFILE','AWS_ENDPOINT_URL','TF_DATA_DIR','TF_VAR_aws_region','TF_CLI_ARGS_init'):
            self.blocked('conflicting environment',**{key:'SENTINEL_SECRET'})
        self.assertEqual(self.calls(),[])

    def test_conflicting_native_sources(self):
        self.native.write_text('[profile personal-temporary]\nlogin_session = existing-user\ncredential_process = approved-login\n')
        self.blocked('conflicting native credential sources')

    def test_long_lived_native_key_rejected_without_logging(self):
        self.native.write_text('[profile personal-temporary]\nregion=us-east-1\n')
        self.creds.write_text('[personal-temporary]\naws_access_key_id=SENTINEL_SECRET\naws_secret_access_key=SENTINEL_SECRET\n')
        self.blocked('long-lived')

    def test_read_only_permission_failures_are_unknown(self):
        result=self.run_cli('preflight','aws-personal',FAKE_MODE='denied')
        self.assertEqual(result['deployment_rights'],'unverified')
        self.assertTrue(all(c['status']=='unknown' for c in result['checks']))
        self.assertTrue(all(c['error'] in ('permission_unknown','state_metadata_unavailable') for c in result['checks']))
        self.assertLess(len(self.calls()),50)
        self.assertNotIn('SENTINEL_SECRET',''.join(p.read_text() for p in (self.root/'evidence/aws').rglob('*.json')))

    def test_missing_resource_is_not_misreported_as_missing_login(self):
        result=self.run_cli('preflight','aws-personal',FAKE_MODE='no-such-resource')
        self.assertTrue(all(c.get('error')!='missing_login' for c in result['checks']))
        self.assertIn('resource_lookup_unknown',{c.get('error') for c in result['checks']})

    def test_one_page_is_explicitly_incomplete(self):
        result=self.run_cli('preflight','aws-personal')
        roles=json.loads((self.root/result['evidence']/'roles.json').read_text())
        self.assertTrue(roles['data']['more'])
        self.assertIn('incomplete',result['coverage'])
        self.assertTrue(all('--no-paginate' in c for c in self.calls()))

    def test_state_lineage_is_version_pinned_and_redacted(self):
        result=self.run_cli('preflight','aws-personal',FAKE_MODE='state')
        summary=json.loads((self.root/result['evidence']/'platform-state-summary.json').read_text())
        self.assertEqual(summary['lineage'],'test-lineage')
        self.assertEqual(summary['serial'],7)
        calls=[c for c in self.calls() if 'get-object' in c]
        self.assertEqual(len(calls),1)
        self.assertIn('immutable-version',calls[0])
        self.assertNotIn('SENTINEL_SECRET',''.join(p.read_text() for p in (self.root/'evidence/aws').rglob('*.json')))

    def test_exec_sdk_environment_and_stdin(self):
        p=subprocess.run(['bash',SCRIPT,'exec','aws-lab','--','python3','-c',"import json,os,sys; print(json.dumps([os.environ['AWS_PROFILE'],os.environ['AWS_REGION'],os.environ['TF_VAR_aws_account_id'],sys.stdin.read()]))"],input='stdin works',text=True,capture_output=True,cwd=self.root,env=self.env,timeout=30)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(json.loads(p.stdout),['lab-temporary','us-west-2','222222222222','stdin works'])

    def test_open_tofu_execution_and_cli_overrides_closed(self):
        for command in (['tofu','apply'],['aws','--profile','another','sts','get-caller-identity']):
            self.run_cli('exec','aws-personal','--',*command,success=False)

    def test_direct_aws_forbidden_prefixes_and_value_forms_never_execute(self):
        # These shortest fixtures were accepted by installed AWS CLI 2.36.14
        # using credential-free skeleton-input parsing, including = value forms.
        # Check every longer prefix through each full spelling. The fake records
        # all invocations before parsing; it does not decide abbreviation validity.
        flags=(('--profile','--prof','another'),('--region','--reg','us-west-2'),
               ('--endpoint-url','--endpoint','https://example.invalid'),
               ('--no-sign-request','--no-sign',None),
               ('--cli-input-json','--cli-input-j','{}'),
               ('--cli-input-yaml','--cli-input-y','{}'))
        for full, shortest, value in flags:
            for length in range(len(shortest),len(full)+1):
                option=full[:length]
                forms=([option,value],[option+'='+value]) if value is not None else ([option],)
                for form in forms:
                    with self.subTest(option=option,form=form):
                        before=len(self.calls())
                        p=self.run_cli('exec','aws-personal','--','aws','sts','get-caller-identity',*form,success=False)
                        self.assertIn('command overrides selected AWS target',p.stderr)
                        calls=self.calls()[before:]
                        self.assertEqual(len(calls),1,'only initial target identity may execute')
                        self.assertEqual(calls[0][:4],['--profile','personal-temporary','--region','us-east-1'])
                        self.assertIn('get-caller-identity',calls[0])

    def test_reviewed_override_reproduction_before_service_never_executes(self):
        for options in (['--prof','another','--reg','us-west-2','--endpoint','https://example.invalid','--no-sign'],
                        ['--prof=another','--reg=us-west-2','--endpoint=https://example.invalid','--no-sign']):
            with self.subTest(options=options):
                before=len(self.calls())
                p=self.run_cli('exec','aws-personal','--','aws',*options,'sts','get-caller-identity',success=False)
                self.assertIn('command overrides selected AWS target',p.stderr)
                self.assertEqual(len(self.calls()[before:]),1)

    def test_direct_aws_keeps_target_safe_arguments_and_stdin(self):
        command=['aws','ecr','describe-repositories','--registry-id','222222222222','--output=json']
        p=subprocess.run(['bash',SCRIPT,'exec','aws-lab','--',*command],input='stdin works',
                         cwd=self.root,env={**self.env,'FAKE_MODE':'direct-command'},capture_output=True,text=True,timeout=30)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(json.loads(p.stdout),{'argv':command[1:],'profile':'lab-temporary',
                                             'region':'us-west-2','stdin':'stdin works'})
        self.assertEqual(len(self.calls()),2)
        self.assertEqual(self.calls()[-1],command[1:])

    def test_no_bootstrap_migration_or_context_tampering(self):
        self.run_cli('context','aws-personal','bootstrap',success=False)
        c=self.run_cli('context','aws-personal','platform')
        (Path(c['data_dir']).parent/'backend.hcl').write_text('different backend')
        self.run_cli('context','aws-personal','platform',success=False)

    def test_evidence_symlink_escape_rejected(self):
        (self.root/'evidence/aws/targets.json').unlink()
        (self.root/'outside.json').write_text(json.dumps(self.config))
        (self.root/'evidence/aws/targets.json').symlink_to(self.root/'outside.json')
        self.run_cli('list',success=False)

    def test_evidence_symlink_to_another_target_is_rejected(self):
        other=self.root/'evidence/aws/aws-lab'
        other.mkdir()
        (self.root/'evidence/aws/aws-personal').symlink_to(other)
        self.run_cli('identity','aws-personal',success=False)
        self.assertEqual(list(other.iterdir()),[])


unittest.main(verbosity=2)
PY
