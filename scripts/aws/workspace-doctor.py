"""Local readiness report: managed tools, AWS identity, GitHub access, project."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path.cwd().resolve()
sys.path.insert(0, str(Path(__file__).resolve().parent))
import workspace_lifecycle

L = vars(workspace_lifecycle)
B = L['boundary']


def load(name, label):
    spec = importlib.util.spec_from_file_location(label, ROOT/'scripts/aws'/name)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module


P = load('workspace-config.py', 'aws_workspace_config')
A = load('workstation-auth.py', 'aws_workstation_auth')
D = load('workspace-deploy.py', 'aws_deploy')
READY, ACTION, UNKNOWN = 'Ready', 'Action needed', 'Unknown'


class Report:
    def __init__(self):
        self.rows = []
        self.debug = []

    def add(self, check, state, detail, command=None):
        self.rows.append({'check': check, 'state': state, 'detail': detail, 'next': command})

    def note(self, line):
        self.debug.append(line)

    @property
    def ready(self):
        return all(row['state'] == READY for row in self.rows)


def shell(path):
    text = str(path)
    return text if re.fullmatch(r'[A-Za-z0-9_./-]+', text) else "'" + text.replace("'", "'\\''") + "'"


def cli(config=None):
    return './workspace' if config is None else './workspace ' + shell(config)


def repository_route(url):
    if re.match(r'git@github\.com:', url): return 'private'
    if re.match(r'https://', url): return 'public'
    return 'unknown'


def check_aws(report, project):
    profile, region = project['profile'], project['region']
    login = cli() + ' login --profile ' + shell(profile) + ' --region ' + region
    try:
        method = A.profile_method(profile, region)
    except Exception as exc:
        report.add('AWS identity', ACTION, 'profile "' + profile + '": ' + text_of(exc), login); return
    if method == 'new':
        report.add('AWS identity', ACTION, 'profile "' + profile + '" has no native login yet', login); return
    try:
        result = A.auth_check(profile, region)
    except Exception as exc:
        reason = text_of(exc)
        state = UNKNOWN if 'timed out' in reason else ACTION
        report.add('AWS identity', state, 'profile "' + profile + '": ' + reason, login); return
    identity = result['identity']
    report.add('AWS identity', READY, 'account ' + identity['Account'] + ' as ' + identity['Arn'] +
               '; login does not prove infrastructure permissions')


def text_of(exc):
    if isinstance(exc, (B['Failure'], ValueError)): return str(exc)
    return 'check failed: ' + type(exc).__name__


def check_github(report, project):
    repository = project['repository']; route = repository_route(repository['url'])
    if route == 'public':
        if not shutil.which('git'):
            report.add('GitHub access', ACTION, 'public repository needs the git command to resolve its branch or tag',
                       'install git with your OS package manager'); return
        try:
            resolved = P.git_ref(L, repository)
        except Exception as exc:
            report.add('GitHub access', ACTION, 'public repository: ' + text_of(exc),
                       'check the URL and ref; private repositories use the git@github.com: SSH URL'); return
        report.add('GitHub access', READY, 'public repository; no GitHub login needed; ' + repository['ref'] +
                   ' resolves to ' + resolved['revision'][:12]); return
    if route != 'public' and route != 'private':
        report.add('GitHub access', ACTION, 'repository URL must be https://github.com/... or git@github.com:...'); return
    missing = [tool for tool in ('ssh-keygen', 'gh') if not shutil.which(tool)]
    if 'gh' in missing:
        report.add('GitHub access', ACTION, 'private repository needs the managed GitHub CLI', cli() + ' setup --github'); return
    if missing:
        report.add('GitHub access', ACTION, 'private repository needs ssh-keygen (OpenSSH client) for its read-only deploy key',
                   'install openssh-client with your OS package manager'); return
    try:
        result = B['request'](['gh', 'auth', 'status', '--hostname', 'github.com', '--active'], os.environ.copy(), 30)
    except subprocess.TimeoutExpired:
        report.add('GitHub access', UNKNOWN, 'GitHub login check timed out', cli() + ' github-login'); return
    if result.returncode != 0:
        report.add('GitHub access', ACTION, 'private repository: no active GitHub login on this workstation', cli() + ' github-login'); return
    report.add('GitHub access', READY, 'GitHub login active; Deploy registers a read-only deploy key and needs repository admin permission')


def check_project(report, config):
    try:
        project = P.validate_project(L, config)
        P.supported_profile(L, project['region'])
        dataset = P.dataset_metadata(L, project['dataset']['source'], config.parent)
    except Exception as exc:
        report.add('Project config', ACTION, str(config) + ': ' + text_of(exc), 'edit the file and run ' + cli(config) + ' doctor')
        return None
    if dataset['adapter'] == 'local':
        size = dataset['bytes']; unit = 'bytes' if size < 1024**2 else '%.1f MiB' % (size/1024**2)
        detail = 'dataset %s: %d files, %s' % (dataset['source'], dataset['files'], unit if size < 1024**2 else unit)
    else:
        detail = 'remote dataset ' + dataset['source'] + '; size verified during Deploy'
    report.add('Project config', READY, str(config) + '; ' + detail + '; ' + project.get('mode', 'job') + ' mode, ' +
               str(project['maximum_runtime_minutes']) + ' minute maximum')
    return project


def check_operation(report, config):
    pointer = D.selection(L, P, config)
    if not pointer.exists():
        report.add('Last operation', READY, 'none yet for this configuration; the next command reviews a new scope'); return
    try:
        directory = L['checked_path'](L['read'](pointer)['directory'])
        result = L['read'](directory/'result.json') if (directory/'result.json').exists() else None
        status = L['read'](directory/'status.json') if (directory/'status.json').exists() else None
    except Exception as exc:
        report.add('Last operation', UNKNOWN, 'operation record unreadable: ' + text_of(exc), cli(config) + ' status'); return
    report.note('last operation directory: ' + str(directory))
    if result:
        if result['status'] in ('success', 'cancelled') and result.get('cleanup_status') in ('success', 'not_needed'):
            where = ('; outputs at ' + result['output_uri']) if result.get('output_uri') else ''
            report.add('Last operation', READY, result['status'] + ', compute cleanup ' + result['cleanup_status'] + where); return
        if result['status'] == 'workspace_ready':
            report.add('Last operation', ACTION, 'workspace compute is still running until cancel or expiry', cli(config) + ' cancel'); return
        report.add('Last operation', ACTION, result['status'] + ' with cleanup ' + str(result.get('cleanup_status')) +
                   '; reconcile before another launch', cli(config) + ' resume'); return
    if status:
        report.add('Last operation', ACTION, 'interrupted at stage ' + status['stage'] + ' (' + status['state'] + ')',
                   cli(config) + ' resume'); return
    report.add('Last operation', READY, 'reviewed scope saved; nothing launched yet')


def debug_lines(report, config):
    names = sorted(k for k in os.environ if k.startswith(('AWS_', 'TF_', 'GH_', 'GITHUB_')))
    report.note('environment variable names (values never shown): ' + (', '.join(names) or 'none'))
    try:
        documents, credentials = B['profile_documents']()
        profiles = sorted({s.replace('profile ', '', 1) for s in documents.sections()} | set(credentials.sections()))
        report.note('AWS profile names: ' + (', '.join(profiles) or 'none'))
    except Exception as exc:
        report.note('AWS profile files unreadable: ' + text_of(exc))
    for tool in ('aws', 'tofu', 'uv', 'gh', 'git', 'session-manager-plugin'):
        path = shutil.which(tool)
        if not path: report.note(tool + ': not on PATH'); continue
        try:
            out = subprocess.run([tool, '--version'] if tool != 'tofu' else [tool, 'version'], capture_output=True, text=True, timeout=15,
                                 env={**os.environ, 'CHECKPOINT_DISABLE': '1'}).stdout.strip().splitlines()
        except (OSError, subprocess.TimeoutExpired):
            out = []
        report.note(tool + ': ' + path + ' (' + (out[0][:80] if out else 'no version output') + ')')
    report.note('python: ' + sys.executable + ' ' + sys.version.split()[0])
    report.note('repository root: ' + str(ROOT))
    free = shutil.disk_usage(ROOT).free
    report.note('free disk: %.1f GiB' % (free/1024**3))
    if config is not None: report.note('configuration: ' + str(config))


def render(report):
    width = max(len(row['check']) for row in report.rows)
    lines = ['AWS workspace doctor']
    for row in report.rows:
        lines.append('  %-*s  %-13s  %s' % (width, row['check'], row['state'], row['detail']))
        if row['next'] and row['state'] != READY:
            lines.append('  %-*s  %-13s  next: %s' % (width, '', '', row['next']))
    if report.debug:
        lines.append('Debug (bounded, redacted)')
        lines.extend('  ' + line for line in report.debug)
    return '\n'.join(lines)


def doctor(config, tools_detail, debug):
    report = Report()
    report.add('Managed tools', READY, tools_detail)
    project = None
    if config is None:
        report.add('AWS identity', UNKNOWN, 'pass PROJECT.json to check its AWS profile', cli() + ' doctor PROJECT.json')
        report.add('GitHub access', UNKNOWN, 'public repositories need no login; pass PROJECT.json to check a private one')
        report.add('Project config', UNKNOWN, 'no configuration selected', 'cp infra/aws/project.example.json /path/project.json')
    else:
        project = check_project(report, config)
        if project:
            check_aws(report, project)
            check_github(report, project)
            check_operation(report, config)
    if debug: debug_lines(report, config)
    text = render(report)
    if report.ready:
        text += '\n\nReady' + (': review and deploy with ' + cli(config) if config else ': run ' + cli() + ' doctor PROJECT.json before deploying')
    else:
        text += '\n\nAction needed: resolve the items above, then run ' + cli(config) + ' doctor again'
    return report, text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', nargs='?')
    parser.add_argument('--tools-detail', required=True)
    parser.add_argument('--debug', action='store_true')
    args = parser.parse_args()
    config = Path(args.config).absolute() if args.config else None
    report, text = doctor(config, args.tools_detail, args.debug)
    print(text)
    sys.exit(0 if report.ready else 1)


if __name__ == '__main__':
    main()
