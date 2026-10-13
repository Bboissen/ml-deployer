"""Terminal-led first use; native authentication and existing project validation."""
import copy
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import sys
import textwrap

ROOT = Path(__file__).resolve().parents[2]


class Console:
    def __init__(self, stream=None, reader=None):
        self.stream = stream or sys.stdout
        self.reader = reader or input
        self.color = self.stream.isatty() and os.environ.get('TERM') != 'dumb' and 'NO_COLOR' not in os.environ

    def paint(self, text, color):
        return '\033[' + color + 'm' + text + '\033[0m' if self.color else text

    def title(self):
        print('\n' + self.paint('AWS workspace', '1;36'), file=self.stream)
        self.hint('Setup on this machine · Ctrl+C to stop')

    def step(self, number, label):
        print('\n' + self.paint('  ' + str(number) + '/4  ' + label, '1;36'), file=self.stream, flush=True)

    def status(self, state, label):
        mark, color = {'done': ('✓', '32'), 'next': ('›', '36'), 'error': ('!', '31'), 'wait': ('○', '33')}[state]
        print('  ' + self.paint(mark, color) + ' ' + label, file=self.stream, flush=True)

    def hint(self, text):
        width = min(96, shutil.get_terminal_size((80, 24)).columns)
        print(self.paint(textwrap.fill(text, width=max(30, width), initial_indent='  ', subsequent_indent='  '), '90'),
              file=self.stream, flush=True)

    def ask(self, label, default=None, parse=str, validate=None):
        while True:
            prompt = '  ' + label + (' [' + str(default) + ']' if default is not None else '') + ': '
            raw = self.reader(self.paint(prompt, '36')).strip()
            if not raw and default is not None: raw = str(default)
            try:
                if not raw: raise ValueError('a value is required')
                value = parse(raw)
                if validate: validate(value)
                return value
            except (ValueError, TypeError) as exc:
                # Parsers here never embed rejected input in their error text.
                self.status('error', 'Enter a whole number' if parse is int else str(exc))

    def confirm(self, label):
        def yes_no(value):
            if value.lower() not in ('y', 'yes', 'n', 'no'): raise ValueError('answer y or n')
        return self.ask(label + ' (y/n)', 'y', validate=yes_no).lower() in ('y', 'yes')


def support():
    spec = importlib.util.spec_from_file_location('setup_doctor', ROOT/'scripts/aws/workspace-doctor.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def checked_config(path):
    path = Path(path).absolute()
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('project configuration must not use symlinks')
    if path.exists() and (not path.is_file() or path.stat().st_uid != os.getuid()):
        raise ValueError('project file must be owned by your user')
    return path


def argv(text):
    try:
        parts = shlex.split(text)
    except ValueError:
        raise ValueError('use matching quotes around arguments with spaces') from None
    if not parts or any(part in (';', '|', '||', '&&', '>', '>>', '<', '&') for part in parts):
        raise ValueError('enter one executable and its arguments; shell operators are unsupported')
    return parts


def create_project(config, ui, M):
    """Collect ordinary settings, validate them, then atomically save once."""
    from jsonschema import Draft202012Validator
    config = checked_config(config)
    if config.exists() and config.stat().st_size > 16*1024*1024:
        raise ValueError('project configuration exceeds the 16 MiB input limit')
    before = config.read_bytes() if config.exists() else None
    template = M.L['load_json'](ROOT/'infra/aws/project.example.json')
    defaults = copy.deepcopy(template)
    if before is not None:
        original = M.L['load_json'](config)
        schema = M.L['load_json'](ROOT/'shared/workspace/project.schema.json')
        # Do not silently remove unknown fields from an existing configuration.
        if not isinstance(original, dict) or set(original) - set(schema['properties']):
            raise ValueError('existing project has unknown fields; preserve it and choose a new project path')
        for error in Draft202012Validator(schema).iter_errors(original):
            if error.validator in ('additionalProperties', 'type', 'required'):
                raise ValueError('existing project structure is invalid; preserve it and choose a new project path')
        if not ui.confirm('Repair this existing project file?'): return None
        defaults.update(original)
    else:
        defaults['profile'] = 'my-workspace'
        defaults['project'] = 'my-project'
    schema = M.L['load_json'](ROOT/'shared/workspace/project.schema.json')
    value = copy.deepcopy(defaults)

    def field(label, keys, default=None, parse=str, extra=None):
        definition = schema
        for key in keys: definition = definition['properties'][key]
        validator = Draft202012Validator({**definition, '$defs': schema['$defs']})
        def validate(answer):
            if not validator.is_valid(answer): raise ValueError('invalid ' + label.lower() + '; check the expected format')
            if extra:
                try: extra(answer)
                except M.B['Failure'] as exc: raise ValueError(str(exc)) from None
        if default is not None:
            try: validate(parse(str(default)))
            except (ValueError, TypeError): default = None
        answer = ui.ask(label, default, parse, validate)
        target = value
        for key in keys[:-1]: target = target[key]
        target[keys[-1]] = answer
        return answer

    ui.hint('Answer here; make creates project.json for you. Press Enter to keep a value in brackets.')
    field('Project name', ('project',), defaults['project'])
    def workspace_name(answer):
        if len(value['project'] + '-' + answer) > 48: raise ValueError('project and workspace names must total at most 47 characters')
    field('Workspace name', ('workspace',), defaults['workspace'], extra=workspace_name)
    def profile_name(answer):
        if answer == 'default': raise ValueError('choose a named AWS profile, such as my-workspace')
    field('AWS profile', ('profile',), defaults['profile'], extra=profile_name)
    ui.hint('Supported CPU workspace region: us-east-1')
    field('AWS region', ('region',), defaults['region'], extra=lambda region: M.P.supported_profile(M.L, region))
    field('Mode (job or workspace)', ('mode',), defaults.get('mode', 'job'))
    field('Maximum runtime in minutes', ('maximum_runtime_minutes',), defaults['maximum_runtime_minutes'], int)

    ui.hint('Your ML repository. Commands run there later, when you approve Deploy.')
    def changed(keys, answer):
        candidate = copy.deepcopy(template); target = candidate
        for key in keys[:-1]: target = target[key]
        target[keys[-1]] = answer
        M.P.validate_project_value(M.L, candidate)
    def repository(answer):
        changed(('repository', 'url'), answer)
        if answer.endswith('/owner/project.git') or answer.endswith(':owner/project.git'):
            raise ValueError('enter your actual repository URL')
    url_default = defaults['repository']['url']
    if 'owner/project.git' in url_default: url_default = None
    field('GitHub repository URL', ('repository', 'url'), url_default, extra=repository)
    def ref(answer):
        changed(('repository', 'ref'), answer)
    field('Branch, tag or commit', ('repository', 'ref'), defaults['repository']['ref'], extra=ref)
    field('Setup command', ('commands', 'setup'), shlex.join(defaults['commands']['setup']), argv,
          lambda answer: changed(('commands', 'setup'), answer))
    field('Run command', ('commands', 'run'), shlex.join(defaults['commands']['run']), argv,
          lambda answer: changed(('commands', 'run'), answer))
    def output_paths(answer):
        changed(('outputs', 'paths'), answer)
    field('Output folders (comma-separated)', ('outputs', 'paths'), ', '.join(defaults['outputs']['paths']),
          lambda text: [p.strip() for p in text.split(',')], output_paths)

    ui.hint('Dataset already on this server, or an S3/HTTPS source. Relative paths use the project file folder.')
    def dataset(answer):
        M.P.dataset_metadata(M.L, answer, config.parent)
    source = defaults['dataset']['source']
    if before is None: source = None
    field('Dataset path or URL', ('dataset', 'source'), source,
          lambda text: str(Path(text).expanduser()) if '://' not in text else text, dataset)
    project = M.P.validate_project_value(M.L, value)
    M.P.supported_profile(M.L, project['region'])
    checked_config(config)
    if before is not None and config.read_bytes() != before:
        raise ValueError('project file changed while you answered; nothing was overwritten')
    old_mask = os.umask(0o077)
    try:
        M.D.atomic({**M.L, 'checked_path': checked_config}, config, project, exclusive=before is None)
    finally:
        os.umask(old_mask)
    ui.status('done', 'Project saved')
    ui.hint(str(config))
    return project


def setup_project(config, ui, doctor, M=None):
    """Skip completed setup; carry out selected missing actions in this terminal."""
    M = M or support()
    ui.step(2, 'Project')
    project = None
    if config.is_file():
        try:
            project = M.P.validate_project(M.L, config)
            M.P.supported_profile(M.L, project['region'])
            M.P.dataset_metadata(M.L, project['dataset']['source'], config.parent)
        except (ValueError, OSError, M.B['Failure']):
            ui.status('wait', 'Project configuration needs attention')
    if project is None:
        project = create_project(config, ui, M)
        if project is None: return False
    else:
        ui.status('done', 'Existing project is valid')

    ui.step(3, 'Sign in')
    ui.status('next', 'Checking saved sign-ins…')
    report, _ = M.doctor(config, 'verified', False)
    rows = {row['check']: row for row in report.rows}
    aws = rows.get('AWS identity', {})
    if aws.get('state') == M.READY:
        ui.status('done', 'AWS profile ' + project['profile'] + ' is signed in')
    elif ui.confirm('Sign in to AWS now?'):
        def login_method(value):
            if value not in ('auto', 'console', 'sso'): raise ValueError('choose auto, console or sso')
        method = ui.ask('AWS login (auto, console or sso)', 'auto', validate=login_method)
        try:
            M.A.login(project['profile'], project['region'], method,
                      bool(os.environ.get('SSH_CONNECTION') or os.environ.get('SSH_CLIENT')))
        except M.B['Failure'] as exc:
            raise ValueError(str(exc)) from None
        ui.status('done', 'AWS sign-in verified')
    else:
        ui.status('wait', 'AWS sign-in deferred; run make again to continue')
    if project['repository']['url'].startswith('git@github.com:'):
        github = rows.get('GitHub access', {})
        if github.get('state') == M.READY:
            ui.status('done', 'GitHub sign-in ready')
        elif ui.confirm('Sign in to GitHub for this private repository?'):
            # Reuse the existing locked installer and native browser login.
            import subprocess
            subprocess.run(['bash', str(ROOT/'workspace'), 'setup', '--github'], check=True)
            M.A.github_login()
            ui.status('done', 'GitHub sign-in verified')
    else:
        ui.status('done', 'Public repository · no GitHub sign-in needed')
    with doctor.lock:
        doctor.cached = None
    return True
