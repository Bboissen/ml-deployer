"""Assisted native authentication; never collect or print credentials."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import termios

sys.dont_write_bytecode = True
ROOT = Path.cwd().resolve()
sys.path.insert(0, str(Path(__file__).resolve().parent))
import workspace_target
from workspace_terminal import interactive as user_terminal, ssh_session

B = vars(workspace_target)
require = B['require']


def selection(profile, region):
    require(re.fullmatch(r'[A-Za-z0-9_+=,.@-]+', profile) and profile != 'default',
            'choose an explicit non-default AWS profile')
    require(re.fullmatch(r'[a-z]{2}(-gov)?-[a-z]+-[0-9]+', region), 'invalid AWS region')


def identity(value):
    require(isinstance(value, dict) and set(value) == {'Account', 'Arn'}, 'invalid identity response')
    account, arn = value['Account'], value['Arn']
    require(isinstance(account, str) and re.fullmatch(r'[0-9]{12}', account), 'invalid identity account')
    require(isinstance(arn, str) and re.fullmatch(
        r'arn:(aws|aws-us-gov|aws-cn):(?:iam::' + account + r':(?:user|role)|sts::' + account + r':assumed-role)/[A-Za-z0-9_+=,.@/-]+', arn),
        'use a named IAM user or role; root identity is unsupported')
    require(':assumed-role/' not in arn or re.fullmatch(r'[A-Za-z0-9_+=,.@-]+/[A-Za-z0-9_+=,.@-]+', arn.split(':assumed-role/', 1)[1]),
            'assumed role identity needs an exact role and session')
    return value


def observe(command, env, label):
    try:
        result = B['request'](command, env, 30)
    except subprocess.TimeoutExpired:
        raise B['Failure'](label + ' identity request timed out; check the selected login/credential process') from None
    if result.returncode != 0:
        category = B['error_category'](result.stderr)
        failure = B['LoginRequired'] if category in ('expired_login', 'missing_login') else B['Failure']
        raise failure(label + ': ' + category + '; run login for the selected profile or ask the account owner about its permissions') from None
    try:
        return identity(json.loads(result.stdout))
    except (json.JSONDecodeError, TypeError):
        raise B['Failure'](label + ' returned an invalid identity response') from None


def sdk_identity(profile, region):
    import boto3
    from botocore.config import Config
    session = boto3.Session(profile_name=profile, region_name=region)
    result = session.client('sts', config=Config(connect_timeout=5, read_timeout=10,
                           retries={'max_attempts': 0})).get_caller_identity()
    return identity({key: result[key] for key in ('Account', 'Arn')})


def auth_check(profile, region):
    selection(profile, region)
    env = B['profile_environment'](profile, region)
    cli = observe(['aws', '--profile', profile, '--region', region, '--no-cli-pager',
                   '--cli-connect-timeout', '5', '--cli-read-timeout', '10', 'sts', 'get-caller-identity',
                   '--query', '{Account:Account,Arn:Arn}', '--output', 'json'], env, 'AWS CLI')
    sdk = observe([sys.executable, str(ROOT/'scripts/aws/workstation-auth.py'), '_sdk-identity',
                   '--profile', profile, '--region', region], env, 'AWS SDK')
    def principal(value):
        arn = value['Arn']
        # Independent AssumeRole calls may have different session names while
        # selecting the same account/role. Never discard the role component.
        return (value['Account'], arn.rsplit('/', 1)[0] if ':assumed-role/' in arn else arn)
    require(principal(cli) == principal(sdk), 'AWS CLI and SDK resolve different identities; repair the selected profile before deploying')
    return {'version': 1, 'status': 'authenticated', 'profile': profile, 'region': region,
            'identity': cli, 'sdk_identity': sdk, 'cli_sdk_principal_match': True,
            'backend_identity': 'pending_foundation_preflight',
            'provider_identity': 'pending_saved_plan_preflight', 'deployment_authorized': False}


def profile_method(profile, region):
    # The same conflict boundary applies before native tools create a new profile.
    B['check_environment']()
    config, credentials = B['profile_documents']()
    section = 'profile ' + profile
    if not config.has_section(section) and not credentials.has_section(profile):
        return 'new'
    fields = dict(config.items(section)) if config.has_section(section) else {}
    if not credentials.has_section(profile) and set(fields) <= {'region', 'output'}:
        return 'new'
    B['profile_environment'](profile, region)
    if config.has_option(section, 'sso_session') or config.has_option(section, 'sso_start_url'):
        return 'sso'
    if config.has_option(section, 'login_session'):
        return 'console'
    raise B['Failure']('this profile uses a credential process, temporary credentials or a source profile; renew its original native login instead')


def ensure_login(profile, region, allow_login=True):
    """Recover native sign-in before an operation has a reviewed authorization."""
    selection(profile, region)
    try:
        return auth_check(profile, region)
    except B['LoginRequired']:
        command = './workspace login --profile ' + profile + ' --region ' + region
        require(allow_login and user_terminal(), 'AWS sign-in is needed; run ' + command + '; then retry this command')
    # Refuse unsupported credential sources before offering a native browser flow.
    profile_method(profile, region)
    from workspace_setup import Console
    ui = Console(stream=sys.stderr)
    ui.status('next', 'AWS sign-in expired or is missing for ' + profile + ' in ' + region)
    try:
        accepted = ui.confirm('Sign in to AWS now and continue?')
    except (EOFError, KeyboardInterrupt):
        accepted = False
    require(accepted, 'AWS sign-in cancelled; operation stopped before review')
    result = login(profile, region, 'auto', ssh_session())
    ui.status('done', 'AWS sign-in verified; continuing to a fresh review')
    return result


def native_profiles(region):
    """Named console/SSO profiles; AWS_PROFILE first when it is one of them."""
    B['check_environment']()
    config, _ = B['profile_documents']()
    names = sorted(s[len('profile '):] for s in config.sections() if s.startswith('profile '))
    found = []
    for name in names:
        if name == 'default' or not re.fullmatch(r'[A-Za-z0-9_+=,.@-]{1,128}', name): continue
        try:
            if profile_method(name, region) in ('console', 'sso'): found.append(name)
        except B['Failure']:
            continue
    selected = os.environ.get('AWS_PROFILE')
    return [selected] + [n for n in found if n != selected] if selected in found else found


def interactive(command):
    require(user_terminal(), 'login needs an interactive terminal for browser consent/MFA; run this command in your terminal')
    # A relay such as RTK can capture stdout/stderr even with terminal stdin.
    # Give native authentication the actual terminal for both its prompt and
    # answer, and discard typeahead left over from earlier setup questions.
    # In the pinned CLI an empty remote-login answer crashes its code decoder.
    sys.stdout.flush(); sys.stderr.flush()
    # Reopen for writing too: redirected terminal stdin may be read-only.
    with open(os.ttyname(sys.stdin.fileno()), 'r+b', buffering=0) as terminal:
        termios.tcflush(terminal, termios.TCIFLUSH)
        if command[:2] == ['aws', 'login'] and '--remote' in command:
            terminal.write(b'\nSign in at the AWS link below, then paste the browser\'s authorization code\n'
                           b'at the waiting terminal prompt and press Enter. Ctrl+C cancels.\n')
        # Native login output (including device URLs) goes only to the user's terminal.
        require(subprocess.call(command, stdin=terminal, stdout=terminal, stderr=terminal) == 0,
                'native login did not finish; rerun it in your terminal and paste the code only when prompted')


def login(profile, region, method, remote):
    selection(profile, region)
    existing = profile_method(profile, region)
    method = (existing if existing != 'new' else 'console') if method == 'auto' else method
    require(existing in ('new', method), 'login method conflicts with the selected profile; use another profile name')
    if method == 'sso':
        if existing == 'new':
            interactive(['aws', 'configure', 'sso', '--profile', profile])
            require(profile_method(profile, region) == 'sso', 'SSO profile configuration did not finish')
        command = ['aws', 'sso', 'login', '--profile', profile, '--region', region]
        if remote:
            command += ['--no-browser', '--use-device-code']
    else:
        command = ['aws', 'login', '--profile', profile, '--region', region]
        if remote:
            command.append('--remote')
    interactive(command)
    return auth_check(profile, region)


def github_login():
    require(not any(key in os.environ for key in ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')),
            'remove ambient GitHub tokens before native browser login')
    interactive(['gh', 'auth', 'login', '--hostname', 'github.com', '--web', '--git-protocol', 'https'])
    result = B['request'](['gh', 'auth', 'status', '--hostname', 'github.com', '--active'], os.environ.copy(), 30)
    require(result.returncode == 0, 'GitHub login could not be verified')
    return {'version': 1, 'status': 'github_authenticated', 'hostname': 'github.com',
            'runtime_repository_access': 'pending_deploy_key_onboarding'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    for action in ('login', 'auth-check', '_sdk-identity'):
        command = commands.add_parser(action)
        command.add_argument('--profile', required=True)
        command.add_argument('--region', required=True)
        if action == 'login':
            command.add_argument('--method', choices=('auto', 'console', 'sso'), default='auto')
            command.add_argument('--remote', action='store_true')
    commands.add_parser('github-login')
    args = parser.parse_args()
    if args.action == 'login':
        result = login(args.profile, args.region, args.method, args.remote)
    elif args.action == 'auth-check':
        result = auth_check(args.profile, args.region)
    elif args.action == '_sdk-identity':
        selection(args.profile, args.region)
        try:
            result = sdk_identity(args.profile, args.region)
        except Exception as exc:
            # Never propagate credential-process output or SDK exception text.
            raise B['Failure']('SDK: ' + B['error_category'](str(exc))) from None
    else:
        result = github_login()
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(str(exc) if isinstance(exc, B['Failure']) else 'authentication command failed; check your native profile configuration', file=sys.stderr)
        sys.exit(2)
