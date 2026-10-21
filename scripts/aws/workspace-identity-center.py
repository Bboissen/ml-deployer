"""Guided IAM Identity Center sign-in: long portal sessions without static keys.

Console-only steps are printed with their exact clicks; scriptable steps are
reviewed as one scope and applied only with a confirmation bound to its hash.
"""
import argparse
import configparser
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path.cwd().resolve()
sys.path.insert(0, str(Path(__file__).resolve().parent))
import workspace_target
from workspace_setup import Console, clean
from workspace_terminal import interactive as user_terminal

B = vars(workspace_target)
require = B['require']
PERMISSION_SET = 'MlDeployerOperator'
OPERATOR_ROLE = 'ml-deployer-operator'
OPERATOR_POLICY = 'arn:aws:iam::aws:policy/AdministratorAccess'
ROLE_SESSION = 'PT12H'
CONSOLE = 'https://{region}.console.aws.amazon.com/'
MANUAL = {
    'organization': ('Create the organization (management account)', [
        'Open {console}organizations/v2/home?region={region}',
        'Click "Create an organization" and confirm. A one-account organization changes no billing.']),
    'instance': ('Enable the IAM Identity Center organization instance', [
        'Open {console}singlesignon/home?region={region}',
        'Click "Enable", then "Enable" on "Enable IAM Identity Center with AWS Organizations".',
        'Do not choose an account instance: it cannot grant AWS account access.']),
    'settings': ('Set the portal session and first sign-in email (console only; no API exists)', [
        'Open {console}singlesignon/home?region={region}#/instances/settings',
        'Authentication tab > Session duration (User interactive sessions) > Configure > {days} days > Save.',
        'Authentication tab > Standard authentication > Configure > tick "Send email OTP" > Save.',
        'Keep MFA: "Require them to register an MFA device at sign in".']),
}


def names(value, label, pattern=r'[A-Za-z0-9_+=,.@-]{1,64}'):
    require(isinstance(value, str) and re.fullmatch(pattern, value), 'invalid ' + label)
    return value


def manual(ui, key, region, days):
    title, lines = MANUAL[key]
    ui.status('next', 'Owner console step: ' + title)
    for line in lines:
        text = line.format(console=CONSOLE.format(region=region), region=region, days=days)
        (ui.command if text.startswith('Open ') else ui.hint)(text)


def error_code(error):
    return getattr(error, 'response', {}).get('Error', {}).get('Code', '')


def observe(client, account, region, user):
    """Read-only account state; never returns credentials or API error text."""
    organizations = client('organizations')
    try:
        org = organizations.describe_organization()['Organization']
    except Exception as error:
        require(error_code(error) == 'AWSOrganizationsNotInUseException', 'organization state unavailable: ' + B['error_category'](str(error)))
        return {'missing': 'organization'}
    require(org['MasterAccountId'] == account, 'run this from the organization management account')
    require(org['FeatureSet'] == 'ALL', 'enable all AWS Organizations features first')
    sso = client('sso-admin')
    instances = sso.list_instances()['Instances']
    if not instances:
        return {'missing': 'instance', 'organization_id': org['Id']}
    require(len(instances) == 1 and instances[0].get('Status', 'ACTIVE') == 'ACTIVE', 'expected exactly one active Identity Center instance')
    instance = instances[0]
    state = {'missing': None, 'organization_id': org['Id'], 'instance_arn': instance['InstanceArn'],
             'identity_store_id': instance['IdentityStoreId'], 'user_id': None, 'permission_set_arn': None,
             'inline_policy': None, 'role_arn': None, 'role_trust': None, 'role_policies': [], 'assigned': False}
    store = client('identitystore')
    try:
        state['user_id'] = store.get_user_id(IdentityStoreId=instance['IdentityStoreId'], AlternateIdentifier={
            'UniqueAttribute': {'AttributePath': 'userName', 'AttributeValue': user}})['UserId']
    except Exception as error:
        require(error_code(error) == 'ResourceNotFoundException', 'Identity Center user lookup failed')
    paginator = sso.get_paginator('list_permission_sets')
    for page in paginator.paginate(InstanceArn=instance['InstanceArn']):
        for arn in page['PermissionSets']:
            described = sso.describe_permission_set(InstanceArn=instance['InstanceArn'], PermissionSetArn=arn)['PermissionSet']
            if described['Name'] == PERMISSION_SET:
                require(described.get('SessionDuration') == ROLE_SESSION, 'existing ' + PERMISSION_SET + ' session duration differs')
                state['permission_set_arn'] = arn
                inline = sso.get_inline_policy_for_permission_set(InstanceArn=instance['InstanceArn'], PermissionSetArn=arn)['InlinePolicy']
                state['inline_policy'] = json.loads(inline) if inline else None
    iam = client('iam')
    try:
        role = iam.get_role(RoleName=OPERATOR_ROLE)['Role']
        state['role_arn'] = role['Arn']
        document = role['AssumeRolePolicyDocument']
        state['role_trust'] = json.loads(document) if isinstance(document, str) else document
        state['role_policies'] = [p['PolicyArn'] for p in iam.list_attached_role_policies(RoleName=OPERATOR_ROLE)['AttachedPolicies']]
    except Exception as error:
        require(error_code(error) == 'NoSuchEntity', 'operator role lookup failed')
    if state['permission_set_arn'] and state['user_id']:
        assignments = sso.list_account_assignments(InstanceArn=instance['InstanceArn'], AccountId=account,
                                                   PermissionSetArn=state['permission_set_arn'])['AccountAssignments']
        state['assigned'] = any(a['PrincipalType'] == 'USER' and a['PrincipalId'] == state['user_id'] for a in assignments)
    return state


def documents(account, partition='aws'):
    role_arn = 'arn:' + partition + ':iam::' + account + ':role/' + OPERATOR_ROLE
    # Only the AWS-reserved role of this exact permission set, in any Identity
    # Center region path, may assume the stable owner-managed operator role.
    trust = {'Version': '2012-10-17', 'Statement': [{
        'Sid': 'IdentityCenterPermissionSet', 'Effect': 'Allow',
        'Principal': {'AWS': 'arn:' + partition + ':iam::' + account + ':root'}, 'Action': 'sts:AssumeRole',
        'Condition': {'ArnLike': {'aws:PrincipalArn': 'arn:' + partition + ':iam::' + account +
                                  ':role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_' + PERMISSION_SET + '_*'}}}]}
    inline = {'Version': '2012-10-17', 'Statement': [{
        'Sid': 'AssumeWorkspaceOperatorOnly', 'Effect': 'Allow', 'Action': 'sts:AssumeRole', 'Resource': role_arn}]}
    return role_arn, trust, inline


def profile_blocks(args, account, state):
    session = args.new_profile
    start = args.start_url or 'https://' + state['identity_store_id'] + '.awsapps.com/start'
    return {
        'sso-session ' + session: {'sso_start_url': start, 'sso_region': args.region,
                                   'sso_registration_scopes': 'sso:account:access'},
        'profile ' + session + '-portal': {'sso_session': session, 'sso_account_id': account,
                                           'sso_role_name': PERMISSION_SET, 'region': args.region},
        'profile ' + session: {'role_arn': documents(account)[0], 'source_profile': session + '-portal',
                               'role_session_name': args.user, 'region': args.region},
    }


def config_path():
    return Path(os.environ.get('AWS_CONFIG_FILE', str(Path.home()/'.aws/config')))


def config_changes(blocks):
    """Only absent sections are added; an existing different section is never edited."""
    config, _ = B['profile_documents']()
    missing = {}
    for section, values in blocks.items():
        if config.has_section(section):
            require(dict(config.items(section)) == values, 'AWS config section [' + section + '] exists with other values; choose another --new-profile')
        else:
            missing[section] = values
    return missing


def plan(args, account, state):
    role_arn, trust, inline = documents(account)
    actions = []
    if not state['user_id']:
        actions.append({'action': 'create-user', 'user': args.user, 'email': args.email, 'display_name': args.display_name})
    if not state['permission_set_arn']:
        actions.append({'action': 'create-permission-set', 'name': PERMISSION_SET, 'session_duration': ROLE_SESSION})
    if state['inline_policy'] != inline:
        actions.append({'action': 'put-inline-policy', 'permission_set': PERMISSION_SET, 'policy': inline})
    if not state['role_arn']:
        actions.append({'action': 'create-role', 'role': OPERATOR_ROLE, 'trust': trust})
    else:
        require(state['role_arn'] == role_arn and state['role_trust'] == trust,
                'existing ' + OPERATOR_ROLE + ' differs from the reviewed trust; inspect it in the IAM console')
    if OPERATOR_POLICY not in state['role_policies']:
        actions.append({'action': 'attach-role-policy', 'role': OPERATOR_ROLE, 'policy_arn': OPERATOR_POLICY})
    if not state['assigned']:
        actions.append({'action': 'assign', 'user': args.user, 'account': account, 'permission_set': PERMISSION_SET})
    elif any(a['action'] == 'put-inline-policy' for a in actions):
        actions.append({'action': 'provision', 'account': account, 'permission_set': PERMISSION_SET})
    blocks = profile_blocks(args, account, state)
    missing = config_changes(blocks)
    if missing:
        actions.append({'action': 'write-aws-config', 'path': str(config_path()), 'sections': missing})
    scope = {'kind': 'identity-center-setup', 'account_id': account, 'region': args.region,
             'instance_arn': state['instance_arn'], 'actions': actions}
    return scope, B['digest'](B['canonical'](scope))[:16]


def wait_status(read, label, seconds=300):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        status = read()
        if status['Status'] == 'SUCCEEDED': return status
        require(status['Status'] == 'IN_PROGRESS', label + ' failed: ' + clean(status.get('FailureReason', 'unknown'))[:200])
        time.sleep(3)
    raise B['Failure'](label + ' still in progress; rerun this command to continue')


def apply(client, args, account, state, scope):
    sso, store, iam = client('sso-admin'), client('identitystore'), client('iam')
    instance = state['instance_arn']; done = []
    role_arn, trust, inline = documents(account)
    for item in scope['actions']:
        kind = item['action']
        if kind == 'create-user':
            given, _, family = args.display_name.partition(' ')
            state['user_id'] = store.create_user(IdentityStoreId=state['identity_store_id'], UserName=args.user,
                DisplayName=args.display_name, Name={'GivenName': given, 'FamilyName': family or given},
                Emails=[{'Value': args.email, 'Type': 'work', 'Primary': True}])['UserId']
        elif kind == 'create-permission-set':
            state['permission_set_arn'] = sso.create_permission_set(InstanceArn=instance, Name=PERMISSION_SET,
                Description='ml-deployer operator sign-in; may only assume ' + OPERATOR_ROLE,
                SessionDuration=ROLE_SESSION)['PermissionSet']['PermissionSetArn']
        elif kind == 'put-inline-policy':
            sso.put_inline_policy_to_permission_set(InstanceArn=instance, PermissionSetArn=state['permission_set_arn'],
                                                     InlinePolicy=json.dumps(inline))
        elif kind == 'create-role':
            iam.create_role(RoleName=OPERATOR_ROLE, AssumeRolePolicyDocument=json.dumps(trust), MaxSessionDuration=3600,
                            Description='ml-deployer operator assumed from Identity Center permission set ' + PERMISSION_SET,
                            Tags=[{'Key': 'ManagedBy', 'Value': 'ml-deployer-identity-center'}])
        elif kind == 'attach-role-policy':
            iam.attach_role_policy(RoleName=OPERATOR_ROLE, PolicyArn=OPERATOR_POLICY)
        elif kind == 'assign':
            request = sso.create_account_assignment(InstanceArn=instance, TargetId=account, TargetType='AWS_ACCOUNT',
                PermissionSetArn=state['permission_set_arn'], PrincipalType='USER',
                PrincipalId=state['user_id'])['AccountAssignmentCreationStatus']
            wait_status(lambda: sso.describe_account_assignment_creation_status(InstanceArn=instance,
                AccountAssignmentCreationRequestId=request['RequestId'])['AccountAssignmentCreationStatus'], 'account assignment')
        elif kind == 'provision':
            request = sso.provision_permission_set(InstanceArn=instance, PermissionSetArn=state['permission_set_arn'],
                                                   TargetId=account, TargetType='AWS_ACCOUNT')['PermissionSetProvisioningStatus']
            wait_status(lambda: sso.describe_permission_set_provisioning_status(InstanceArn=instance,
                ProvisionPermissionSetRequestId=request['RequestId'])['PermissionSetProvisioningStatus'], 'permission set provisioning')
        elif kind == 'write-aws-config':
            write_config(item['sections'])
        done.append(kind)
    return done


def write_config(sections):
    """Append absent sections atomically; existing profiles keep their exact bytes."""
    path = config_path()
    original = path.read_bytes() if path.exists() else b''
    text = original.decode()
    if text and not text.endswith('\n'): text += '\n'
    for section, values in sections.items():
        text += '\n[' + section + ']\n' + ''.join(k + ' = ' + v + '\n' for k, v in values.items())
    path.parent.mkdir(mode=0o700, exist_ok=True)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(text); stream.flush(); os.fsync(stream.fileno())
        if path.exists(): os.chmod(temporary, path.stat().st_mode & 0o777)
        require((path.read_bytes() if path.exists() else b'') == original, 'AWS config changed during setup; rerun')
        os.replace(temporary, path)
    finally:
        if temporary.exists(): temporary.unlink()
    parsed = configparser.RawConfigParser(); parsed.read(path)
    require(all(dict(parsed.items(s)) == v for s, v in sections.items()), 'AWS config verification failed')


def describe(ui, scope, digest):
    ui.status('next', 'Review: ' + str(len(scope['actions'])) + ' change(s) in account ' + scope['account_id'] + ' (' + scope['region'] + ')')
    for item in scope['actions']:
        detail = {k: v for k, v in item.items() if k not in ('action', 'policy', 'trust', 'sections')}
        if 'sections' in item: detail['sections'] = sorted(item['sections'])
        ui.hint('- ' + item['action'] + ' ' + json.dumps(detail, sort_keys=True))
    ui.hint('Permission set ' + PERMISSION_SET + ' (' + ROLE_SESSION + ') may only assume ' + OPERATOR_ROLE +
            ', which holds AdministratorAccess like a typical deployer operator; its trust accepts only that permission set.')
    ui.hint('Scope hash ' + digest + '. Noninteractive approval: --authorization "approve scope ' + digest + '"')


def receipt(scope, digest, done, state):
    directory = ROOT/'evidence/aws/identity-center'
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    path = directory/('setup-' + uuid.uuid4().hex + '.json')
    B['write'](path, {'scope': scope, 'scope_hash': digest, 'completed': done, 'observed_at': B['now'](),
                      'user_id': state['user_id'], 'permission_set_arn': state['permission_set_arn']})
    return path


def run(args, client=None, ui=None):
    ui = ui or Console(stream=sys.stderr)
    names(args.profile, 'admin profile'); names(args.new_profile, 'new profile', r'[A-Za-z0-9_-]{1,48}')
    names(args.user, 'user name', r'[A-Za-z0-9_.@-]{1,64}')
    require(args.profile not in (args.new_profile, args.new_profile + '-portal'), 'the new profile must differ from the admin profile')
    require(args.email is None or re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+', args.email), 'invalid email address')
    require(args.start_url is None or re.fullmatch(r'https://[a-z0-9-]+\.awsapps\.com/start/?', args.start_url), 'invalid access portal URL')
    require(7 <= args.days <= 90, 'choose a portal session between 7 and 90 days')
    # Role and console links below are commercial-partition (aws) only.
    require(re.fullmatch(r'(?:us|eu|ap|ca|sa|me|af|il|mx)-[a-z]+-[0-9]+', args.region), 'choose a commercial AWS region')
    B['profile_environment'](args.profile, args.region)
    if client is None:
        import boto3
        from botocore.config import Config
        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        config = Config(connect_timeout=5, read_timeout=20, retries={'total_max_attempts': 3})
        client = lambda service: session.client(service, region_name=args.region, config=config)
    try:
        account = client('sts').get_caller_identity()['Account']
    except Exception as error:
        raise B['Failure']('admin profile sign-in failed: ' + B['error_category'](str(error)) +
                           '; run ./workspace login --profile ' + args.profile + ' --region ' + args.region) from None
    ui.status('done', 'Signed in to account ' + account + ' with admin profile ' + args.profile)
    state = observe(client, account, args.region, args.user)
    for key in ('organization', 'instance'):
        if state['missing'] == key:
            manual(ui, key, args.region, args.days)
            ui.hint('Then rerun this command; it continues from here.')
            return {'status': 'owner_step_required', 'step': key}
        ui.status('done', MANUAL[key][0])
    if not args.settings_confirmed:
        manual(ui, 'settings', args.region, args.days)
        terminal = user_terminal()
        if not (terminal and ui.confirm('Are both settings saved in the console?')):
            ui.hint('Rerun when done; add --settings-confirmed when running without a terminal.')
            return {'status': 'owner_step_required', 'step': 'settings'}
    ui.status('done', 'Portal session ' + str(args.days) + ' days and email OTP confirmed by the owner')
    if not state['user_id']:
        require(args.email and args.display_name, 'a new Identity Center user needs --email and --display-name')
    scope, digest = plan(args, account, state)
    if scope['actions']:
        describe(ui, scope, digest)
        if args.authorization is not None:
            require(args.authorization.strip() == 'approve scope ' + digest, 'authorization does not match this review; nothing changed')
        else:
            require(user_terminal(), 'confirm interactively or pass --authorization "approve scope ' + digest + '"')
            if not ui.confirm('Apply these changes?'):
                ui.status('wait', 'Nothing changed')
                return {'status': 'declined', 'scope_hash': digest}
        done = apply(client, args, account, state, scope)
        path = receipt(scope, digest, done, state)
        ui.status('done', 'Applied ' + str(len(done)) + ' change(s); receipt ' + str(path.relative_to(ROOT)))
    else:
        ui.status('done', 'Identity Center user, permission set, operator role and profiles already match')
    start = profile_blocks(args, account, state)['sso-session ' + args.new_profile]['sso_start_url']
    ui.status('next', 'First sign-in (once): open the portal, sign in as ' + args.user + ', use the emailed code, set a password and MFA')
    ui.command(start)
    ui.status('next', 'Then sign in from this machine; it lasts for the portal session (' + str(args.days) + ' days)')
    ui.command('./workspace login --profile ' + args.new_profile + ' --region ' + args.region)
    ui.hint('Use "profile": "' + args.new_profile + '" in a project file. Anyone using this computer account can deploy '
            'until the session ends; revoke it in Identity Center (Users > ' + args.user + ' > Active sessions) or with aws sso logout.')
    return {'status': 'ready_for_first_sign_in', 'profile': args.new_profile, 'start_url': start,
            'operator_role_arn': documents(account)[0], 'scope_hash': digest if scope['actions'] else None}


def parser():
    result = argparse.ArgumentParser(prog='workspace identity-center', description=__doc__)
    result.add_argument('--profile', required=True, help='existing admin profile in the management account (console or SSO sign-in)')
    result.add_argument('--region', required=True, help='Identity Center region')
    result.add_argument('--user', required=True, help='Identity Center user name to create or reuse')
    result.add_argument('--email', help='email for a new user; the first sign-in code is sent there')
    result.add_argument('--display-name', help='"Given Family" for a new user')
    result.add_argument('--new-profile', default='ml-deployer-sso', help='profile to add (default ml-deployer-sso)')
    result.add_argument('--start-url', help='custom access portal URL, when the default d-... URL was renamed')
    result.add_argument('--days', type=int, default=30, help='portal session length you set in the console (default 30)')
    result.add_argument('--settings-confirmed', action='store_true', help='console session/email settings are saved')
    result.add_argument('--authorization', help='"approve scope HASH" from this exact review')
    return result


if __name__ == '__main__':
    try:
        print(json.dumps(run(parser().parse_args()), indent=2, sort_keys=True))
    except Exception as exc:
        # API error text is untrusted; report only its category. Every step is
        # observed again on rerun, so a partial apply continues safely.
        reason = str(exc) if isinstance(exc, B['Failure']) else B['error_category'](str(exc)) + '; rerun to observe and continue'
        print('identity-center: ' + reason, file=sys.stderr)
        sys.exit(2)
