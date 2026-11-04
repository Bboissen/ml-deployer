"""Terminal-led first use; native authentication and existing project validation."""
from contextlib import contextmanager
import copy
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import sys
import textwrap
import threading
import time
from workspace_terminal import ssh_session, terminal_output

ROOT = Path(__file__).resolve().parents[2]


def clean(text):
    """Strip control and escape characters: paths and API text never style the terminal."""
    return ''.join(c if c.isprintable() and c not in '\x1b\x9b' else ' ' for c in str(text))


def duration(seconds):
    return '%.0fs' % seconds if seconds < 60 else '%dm%02ds' % (seconds // 60, seconds % 60)


class Console:
    """Step-by-step terminal: one mark per finished step, a timed spinner while working."""
    MARKS = {'done': ('✓', 'ok', '32'), 'next': ('›', '>', '36'), 'error': ('!', '!', '31'), 'wait': ('○', '-', '33')}

    def __init__(self, stream=None, reader=None):
        self.stream = stream or sys.stdout
        self.reader = reader or input
        self.live = terminal_output(self.stream) and os.environ.get('TERM') != 'dumb'
        self.color = self.live and 'NO_COLOR' not in os.environ
        encoding = (getattr(self.stream, 'encoding', None) or 'utf-8').lower().replace('-', '')
        self.unicode = encoding == 'utf8'

    def paint(self, text, color):
        return '\033[' + color + 'm' + text + '\033[0m' if self.color else text

    def mark(self, state):
        symbol, ascii_symbol, color = self.MARKS[state]
        return self.paint(symbol if self.unicode else ascii_symbol, color)

    def title(self):
        print('\n' + self.paint('AWS workspace', '1;36'), file=self.stream)
        self.hint('Setup on this machine · Ctrl+C to stop')

    def step(self, number, label):
        print('\n' + self.paint('  ' + str(number) + '/4  ' + label, '1;36'), file=self.stream, flush=True)

    def status(self, state, label, seconds=None):
        timing = '  ' + self.paint(duration(seconds), '90') if seconds is not None and seconds >= 1 else ''
        print('  ' + self.mark(state) + ' ' + clean(label) + timing, file=self.stream, flush=True)

    def hint(self, text):
        width = min(96, shutil.get_terminal_size((80, 24)).columns)
        print(self.paint(textwrap.fill(clean(text), width=max(30, width), initial_indent='  ', subsequent_indent='  '), '90'),
              file=self.stream, flush=True)

    def command(self, text):
        # Keep commands and links intact when the terminal is narrow.
        print('  ' + self.paint(clean(text), '36'), file=self.stream, flush=True)

    @contextmanager
    def busy(self, label):
        """Spin with elapsed time while a step runs; the caller prints the final mark."""
        started = time.monotonic(); stop = threading.Event()
        def spin():
            frames = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' if self.unicode else '|/-\\'; index = 0
            while not stop.wait(0.1):
                line = '  ' + self.paint(frames[index % len(frames)], '36') + ' ' + label + '  ' + duration(time.monotonic() - started)
                self.stream.write('\r\033[2K' + line); self.stream.flush(); index += 1
        if self.live:
            thread = threading.Thread(target=spin, daemon=True); thread.start()
        else:
            self.status('next', label)
        try:
            yield lambda: time.monotonic() - started
        finally:
            stop.set()
            if self.live:
                thread.join(); self.stream.write('\r\033[2K'); self.stream.flush()

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


DEFAULT_PROFILE = 'ml-deployer'


def given_or_asked(ui, label, given, parse, validate):
    """A flag value passes the same checks as an answer; without one, ask until valid."""
    if given is None: return ui.ask(label, None, parse, validate)
    value = parse(given); validate(value)
    return value


def failure_text(M, check):
    """Run one check; controller failures become retryable answer errors."""
    def run(answer):
        try: check(answer)
        except M.B['Failure'] as exc: raise ValueError(str(exc)) from None
    return run


def github_login(ui, M):
    # Reuse the existing locked installer and native browser login.
    import subprocess
    subprocess.run(['bash', str(ROOT/'workspace'), 'setup', '--github'], check=True)
    failure_text(M, lambda _: M.A.github_login())(None)
    ui.status('done', 'GitHub sign-in verified')


def github_ready(ui, M, scripted):
    """Repository settings come from the GitHub API, which needs gh signed in."""
    if shutil.which('gh'):
        import subprocess
        try:
            command = ['gh', 'auth', 'status', '--hostname', 'github.com', '--active']
            if M.B['request'](command, os.environ.copy(), 30).returncode == 0: return
        except (OSError, subprocess.TimeoutExpired):
            pass
    if not scripted and not ui.confirm('Sign in to GitHub to read your repository settings?'):
        raise ValueError('GitHub sign-in is needed to read the repository settings; run make again when ready')
    github_login(ui, M)


def aws_profile(ui, M, region, scripted):
    """AWS_PROFILE or the only native profile; a new profile name when none exists; ask only between several."""
    names = []
    failure_text(M, lambda _: names.extend(M.A.native_profiles(region)))(None)
    if not names: return DEFAULT_PROFILE
    if len(names) == 1 or os.environ.get('AWS_PROFILE') == names[0]: return names[0]
    if scripted: raise ValueError('several AWS profiles found; add --profile NAME')
    def listed(answer):
        if answer not in names: raise ValueError('choose one of the listed AWS profiles')
    return ui.ask('AWS profile (' + ', '.join(names) + ')', names[0], validate=listed)


def create_project(config, ui, M, repo=None, dataset=None, profile=None):
    """Derive settings from GitHub and AWS, ask only for what cannot be derived, then save once."""
    from jsonschema import Draft202012Validator
    config = checked_config(config)
    if config.exists() and config.stat().st_size > 16*1024*1024:
        raise ValueError('project configuration exceeds the 16 MiB input limit')
    before = config.read_bytes() if config.exists() else None
    template = M.L['load_json'](ROOT/'infra/aws/project.example.json')
    schema = M.L['load_json'](ROOT/'shared/workspace/project.schema.json')
    scripted = repo is not None and dataset is not None
    existing = {}
    if before is not None:
        original = M.L['load_json'](config)
        # Do not silently remove unknown fields from an existing configuration.
        if not isinstance(original, dict) or set(original) - set(schema['properties']):
            raise ValueError('existing project has unknown fields; preserve it and choose a new project path')
        for error in Draft202012Validator(schema).iter_errors(original):
            if error.validator in ('additionalProperties', 'type', 'required'):
                raise ValueError('existing project structure is invalid; preserve it and choose a new project path')
        if repo is None and dataset is None and profile is None and not ui.confirm('Repair this existing project file?'):
            return None
        existing = original

    def kept(keys, check=None):
        """An existing value that is still valid on its own; None means derive it again."""
        current, definition = existing, schema
        for key in keys:
            if not isinstance(current, dict) or key not in current: return None
            current, definition = current[key], definition['properties'][key]
        if not Draft202012Validator({**definition, '$defs': schema['$defs']}).is_valid(current): return None
        try:
            if check: check(current)
        except (ValueError, M.B['Failure']):
            return None
        return copy.deepcopy(current)

    def supported(region): M.P.supported_profile(M.L, region)
    def named(name): M.A.selection(name, value['region'])
    def runnable(commands):
        if any(argv[0].startswith('-') for argv in commands.values()): raise ValueError('invalid command')
    def dataset_ok(source): M.P.dataset_metadata(M.L, source, config.parent)

    value = {**copy.deepcopy(template), **copy.deepcopy(existing)}
    value['region'] = kept(('region',), supported) or template['region']
    value['commands'] = kept(('commands',), runnable) or template['commands']
    previous = kept(('repository', 'url'))
    try:
        previous_name = M.P.repository_name(previous) if previous and 'owner/project.git' not in previous else None
    except ValueError:
        previous_name = None
    ui.hint('Two answers: your GitHub repository and dataset. Everything else comes from GitHub and AWS.')
    if repo is None: repo = previous_name
    github_ready(ui, M, scripted)
    facts = {}
    def same(name): return previous_name is not None and name.lower() == previous_name.lower()
    def lookup(name):
        ref = kept(('repository', 'ref'), lambda r: M.L['require'](M.P.valid_ref(r), 'invalid ref')) if same(name) else None
        facts.update(M.P.github_repository(M.L, name, ref, value['commands']))
    given_or_asked(ui, 'GitHub repository (OWNER/NAME or URL)', repo, M.P.repository_name, failure_text(M, lookup))
    # Keep a chosen SSH URL (it also works for public repositories); otherwise visibility decides.
    url = previous if same(facts['name']) and previous.startswith('git@') else facts['url']
    value['repository'] = {'url': url, 'ref': facts['ref']}
    value['project'] = kept(('project',)) or M.P.project_slug(facts['name'].split('/')[1])
    value['workspace'] = kept(('workspace',)) or template['workspace']
    if profile is not None:
        failure_text(M, named)(profile)
    value['profile'] = profile or kept(('profile',), named) or aws_profile(ui, M, value['region'], scripted)
    value['mode'] = kept(('mode',)) or 'job'
    value['maximum_runtime_minutes'] = kept(('maximum_runtime_minutes',)) or template['maximum_runtime_minutes']
    value['outputs'] = kept(('outputs',)) or template['outputs']
    value['resources'] = kept(('resources',)) or template['resources']
    source = kept(('dataset', 'source'), dataset_ok) if dataset is None else None
    if source is None:
        ui.hint('Dataset already on this server, or an S3/HTTPS source. Relative paths use the project file folder.')
        source = given_or_asked(ui, 'Dataset path or URL', dataset,
                                lambda text: str(Path(text).expanduser()) if '://' not in text else text,
                                failure_text(M, dataset_ok))
    value['dataset'] = {**(kept(('dataset',)) or {}), 'source': source}
    try:
        project = M.P.validate_project_value(M.L, value)
    except M.B['Failure'] as exc:
        raise ValueError(str(exc)) from None
    M.P.supported_profile(M.L, project['region'])
    checked_config(config)
    if before is not None and config.read_bytes() != before:
        raise ValueError('project file changed while you answered; nothing was overwritten')
    M.D.atomic({**M.L, 'checked_path': checked_config}, config, project, exclusive=before is None)
    ui.status('done', 'Project saved')
    ui.hint(str(config))
    summary(ui, M, project, facts)
    return project


def summary(ui, M, project, facts):
    """One view of every derived value; the file or flags change them."""
    repository = project['repository']
    access = 'private, SSH deploy key' if repository['url'].startswith('git@') else 'public, HTTPS'
    ui.status('done', 'Repository ' + facts['name'] + ' (' + access + ') at ' + repository['ref'])
    ui.status('done', 'Project ' + project['project'] + ' · workspace ' + project['workspace'] +
              ' · AWS profile ' + project['profile'] + ' in ' + project['region'])
    ui.status('done', project['mode'].capitalize() + ': ' + ' then '.join(shlex.join(argv) for argv in project['commands'].values()) +
              ' · up to ' + str(project['maximum_runtime_minutes']) + ' min · outputs ' + ', '.join(project['outputs']['paths']))
    ui.status('done', 'Dataset ' + project['dataset']['source'])
    todo = M.P.makefile_todo(facts)
    if todo:
        ui.status('wait', 'To do: ' + todo)
        ui.hint(M.P.MAKEFILE_GUIDE)
        ui.command(M.P.MAKEFILE_DOC)
    ui.hint('To change a value, edit the project file above or rerun with --repo, --dataset or --profile.')


def setup_project(config, ui, doctor, M=None, remote=None, repo=None, dataset=None, profile=None):
    """Skip completed setup; carry out selected missing actions in this terminal.

    With --repo and --dataset nothing is asked: native logins start directly.
    """
    M = M or support()
    scripted = repo is not None and dataset is not None
    ui.step(2, 'Project')
    project = None
    if config.is_file():
        try:
            project = M.P.validate_project(M.L, config)
            M.P.supported_profile(M.L, project['region'])
            M.P.dataset_metadata(M.L, project['dataset']['source'], config.parent)
        except (ValueError, OSError, M.B['Failure']):
            ui.status('wait', 'Project configuration needs attention')
    if project is None or repo is not None or dataset is not None or profile is not None:
        project = create_project(config, ui, M, repo, dataset, profile)
        if project is None: return False
    else:
        ui.status('done', 'Existing project is valid')

    ui.step(3, 'Sign in')
    with ui.busy('Checking saved sign-ins') as elapsed:
        report, _ = M.doctor(config, 'verified', False)
    ui.status('done', 'Sign-ins checked', elapsed())
    rows = {row['check']: row for row in report.rows}
    aws = rows.get('AWS identity', {})
    if aws.get('state') == M.READY:
        ui.status('done', 'AWS profile ' + project['profile'] + ' is signed in')
    elif scripted or ui.confirm('Sign in to AWS now?'):
        def login_method(value):
            if value not in ('auto', 'console', 'sso'): raise ValueError('choose auto, console or sso')
        if not scripted:
            ui.hint('Console sign-in lasts at most 12 hours. For longer unattended jobs, IAM Identity Center keeps one '
                    'sign-in for up to 90 days; an account administrator sets it up once with:')
            ui.command('./workspace identity-center --profile ADMIN_PROFILE --region ' + project['region'] + ' --user NAME')
        method = 'auto' if scripted else ui.ask('AWS login (auto, console or sso)', 'auto', validate=login_method)
        try:
            M.A.login(project['profile'], project['region'], method,
                      ssh_session() if remote is None else remote)
        except M.B['Failure'] as exc:
            raise ValueError(str(exc)) from None
        ui.status('done', 'AWS sign-in verified')
    else:
        ui.status('wait', 'AWS sign-in deferred; run make again to continue')
    if project['repository']['url'].startswith('git@github.com:'):
        github = rows.get('GitHub access', {})
        if github.get('state') == M.READY:
            ui.status('done', 'GitHub sign-in ready')
        elif scripted or ui.confirm('Sign in to GitHub for this private repository?'):
            github_login(ui, M)
    else:
        ui.status('done', 'Public repository · no GitHub sign-in needed')
    with doctor.lock:
        doctor.cached = None
    return True
