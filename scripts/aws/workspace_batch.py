"""One reviewed batch of short-config jobs, run one at a time with bounded retries."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import signal
import time
import uuid

import workspace_target
from workspace_terminal import interactive

spec = importlib.util.spec_from_file_location('batch_deploy', Path(__file__).with_name('workspace-deploy.py'))
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
say = D.say
MAX_JOBS = 100
SLOT_SECONDS = 60
RETRY_SECONDS = 300


class Stop(Exception):
    """The batch pauses durably; rerunning the same authorized command continues it."""


def job_name(path):
    stem = Path(path).name.removesuffix('.json')
    return stem.removesuffix('-project') or stem


def caller_path(value):
    # The wrapper changes to the repository root; resolve against the caller.
    return Path(os.environ.get('WORKSPACE_CALLER_DIR') or Path.cwd(), value).absolute()


def pin(scope):
    """Fields every attempt must repeat exactly; ids, observations and leases excluded."""
    selected = scope['capacity']['selected']
    return {'source': scope['source'], 'configuration_sha256': scope['configuration_sha256'],
            'target': scope['target'], 'repository': scope['repository'],
            'dataset': [{k: r[k] for k in ('path', 'bytes', 'sha256')} for r in scope['dataset']['inventory']],
            'disk': scope['disk'], 'outputs': scope['outputs'], 'mode': scope['mode'],
            'maximum_runtime_minutes': scope['maximum_runtime_minutes'], 'max_ec2_launches': scope['max_ec2_launches'],
            'size': {k: selected[k] for k in ('instance_type', 'availability_zone', 'cpus', 'memory_mb', 'disk_gb')},
            'data_uri': scope.get('storage', {}).get('data_uri'),
            'retained_foundation': bool(scope['foundation']),
            # IAM migration and operator rebinding each need their own interactive deploy review.
            'foundation_change': bool((scope.get('foundation_iam_migration') or {}).get('required') or scope.get('foundation_operator_rebinding')),
            'new_private_access': scope['new_private_access']}


def selection(L, configs, projects, options):
    key = {'configs': [str(c) for c in configs], 'projects': projects, 'options': options}
    return L['REPO']/'evidence/aws/batch-selections'/(L['sha'](L['canon'](key))+'.json')


def latest_pointer(L):
    return L['REPO']/'evidence/aws/batch-selections/latest.json'


def review(W, configs, options, allow_login):
    """Prepare every job's own scope now; the batch scope pins what later attempts must repeat."""
    L, P, A = W['L'], W['P'], W['A']
    L['require'](1 <= len(configs) <= MAX_JOBS, 'a batch has 1 through %d project files' % MAX_JOBS)
    names = [job_name(c) for c in configs]
    L['require'](all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', n) for n in names), 'project file names must give job names of letters, digits, dot, dash or underscore')
    L['require'](len(set(configs)) == len(configs) and len(set(names)) == len(names), 'each project file and job name must be unique')
    L['require'](L['source']()['working_tree_sha256'] == L['sha'](b''), 'clean committed source required')
    projects = [P.validate_project(L, str(c)) for c in configs]
    for profile, region in sorted({(p['profile'], p['region']) for p in projects}):
        A.ensure_login(profile, region, allow_login=allow_login)
    jobs = []
    for number, (name, config, project) in enumerate(zip(names, configs, projects), 1):
        say('batch review: preparing %s (%d/%d)' % (name, number, len(configs)))
        operation, scope = D.prepare(W, str(config))
        fixed = pin(scope)
        L['require'](scope['mode'] == 'job', name+': a batch runs job mode only; use ./workspace PROJECT.json for a workspace')
        L['require'](fixed['retained_foundation'] and not fixed['foundation_change'] and not fixed['new_private_access'],
                     name+': a batch reuses the retained foundation and deploy key; run ./workspace '+str(config)+' once first')
        jobs.append({'name': name, 'config': str(config), 'review_operation': str(operation),
                     'scope_sha256': L['sha'](L['canon'](scope)), 'pin': fixed,
                     'hourly_usd': scope['capacity']['selected']['hourly_usd'],
                     'estimated_compute_usd': scope['estimated_compute_usd'],
                     'dataset_bytes': scope['dataset']['total_bytes'], 'run': shlex.join(project['commands']['run']),
                     'registry': scope['registry_directory'],
                     'workspace_id': L['read'](operation/'deployment.json')['names']['workspace_id'],
                     'cost_exclusions': scope['additional_cost_scope']})
    identifier = uuid.uuid4().hex
    directory = L['inside'](L['REPO']/'evidence/aws/batches'/identifier)
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    batch = {'schema_version': '1.0.0', 'kind': 'aws-batch-scope', 'batch_id': identifier, 'source': L['source'](),
             'created_at': L['stamp'](), 'max_parallel': 1, **options,
             'estimated_compute_usd': round(sum(j['estimated_compute_usd'] for j in jobs), 4), 'jobs': jobs}
    L['write'](directory/'batch.json', batch)
    D.atomic(L, selection(L, configs, projects, options), {'directory': str(directory)})
    D.atomic(L, latest_pointer(L), {'directory': str(directory)})
    return directory, batch


def describe(batch, batch_sha256):
    jobs = batch['jobs']; width = max(len(j['name']) for j in jobs)
    targets = sorted({(j['pin']['target']['account_id'], j['pin']['target']['region'], j['pin']['target']['operator_arn']) for j in jobs})
    lines = ['Batch %s: %d job(s), one at a time, each with its own reviewed scope' % (batch['batch_id'], len(jobs)),
             *['  account:     %s / %s as %s' % target for target in targets],
             '  source:      ml-deployer '+batch['source']['revision'][:12]+'; every job reuses its retained foundation, deploy key and datasets']
    for job in jobs:
        size = job['pin']['size']
        lines.append('  %-*s  %s in %s at %.4f USD/hour, at most %d min (about %.2f USD); dataset %.1f MiB; scope %s' % (
            width, job['name'], size['instance_type'], size['availability_zone'], job['hourly_usd'],
            job['pin']['maximum_runtime_minutes'], job['estimated_compute_usd'], job['dataset_bytes']/1024**2, job['scope_sha256'][:16]))
        lines.append('  %-*s  run: %s' % (width, '', job['run']))
    lines += ['  estimate:    about %.2f USD of compute for one attempt of every job; AWS billing is authoritative' % batch['estimated_compute_usd'],
              '  retries:     at most %d launch attempt(s) per job, only when its job never started' % batch['launch_attempts'],
              '  stops on:    %d consecutive job failure(s), expired sign-in, scope drift or unconfirmed cleanup' % batch['max_consecutive_failures'],
              '  not in the quote: '+'; '.join(jobs[0]['cost_exclusions']),
              '  batch scope: '+batch_sha256[:16]]
    return lines


def confirm(L, batch, batch_sha256):
    """One interactive confirmation of the displayed batch; never implicit."""
    if not interactive(): return None
    say('Type run to launch exactly this batch, or press Enter to stop without any cloud change.')
    try: answer = input('> ')
    except EOFError: answer = ''
    if answer.strip() != 'run':
        say('Stopped; nothing was launched.'); return None
    return 'Interactive confirmation of batch '+batch_sha256[:16]+' at '+L['stamp']()


def progress(batch, journal):
    """Rebuild job states, the compute estimate and the failure streak from the batch journal alone."""
    jobs = {j['name']: {'status': 'pending', 'attempts': []} for j in batch['jobs']}
    streak = 0
    for record in journal.records:
        if record['stage'] == 'batch' and record['state'] == 'continued': streak = 0
        if not record['stage'].startswith('job '): continue
        job = jobs[record['stage'][4:]]
        if record['state'] == 'attempt': job['attempts'].append(dict(record['detail']))
        elif record['state'] == 'outcome':
            job['attempts'][-1].update(record['detail']); kind = record['detail']['kind']
            if kind in ('success', 'failed', 'cancelled'): job['status'] = kind
            if kind == 'launch' and sum(a.get('kind') == 'launch' for a in job['attempts']) >= batch['launch_attempts']:
                job['status'] = 'skipped'
            streak = 0 if kind == 'success' else streak+1 if kind == 'failed' else streak
    # An attempt counts at its estimate once its launch may have started.
    estimate = sum(a['counted_usd'] if 'kind' in a else a['estimated_compute_usd'] for j in jobs.values() for a in j['attempts'])
    return {'jobs': jobs, 'streak': streak, 'estimate': round(estimate, 4)}


def manifest(L, directory, batch, journal, status, reason=None):
    state = progress(batch, journal); jobs = []
    for job in batch['jobs']:
        entry = state['jobs'][job['name']]; last = entry['attempts'][-1] if entry['attempts'] else {}
        jobs.append({'name': job['name'], 'config': job['config'], 'status': entry['status'], 'attempts': len(entry['attempts']),
                     'estimated_compute_usd': round(sum(a.get('counted_usd', a['estimated_compute_usd']) for a in entry['attempts']), 4),
                     **{k: last.get(k) for k in ('operation_id', 'operation_directory', 'scope_sha256', 'output_uri', 'job_exit')}})
    value = {'status': status, 'reason': reason, 'batch_id': batch['batch_id'], 'batch_directory': str(directory),
             'batch_sha256': journal.scope_hash, 'estimated_compute_usd': state['estimate'], 'jobs': jobs}
    D.atomic(L, directory/'manifest.json', value)
    return value


def signed_in(W, target):
    try: W['A'].auth_check(target['profile'], target['region'])
    except workspace_target.LoginRequired: return False
    return True


def wait_for_slot(W, job):
    """Wait until no other controller or operation holds the workspace and the pinned size fits the quota."""
    L = W['L']; target = job['pin']['target']; size = job['pin']['size']; waiting = None
    lock = L['REPO']/'evidence/aws/locks'/(target['inventory']['resource_prefix']+'.lock')
    active = Path(job['registry'])/(job['workspace_id']+'-active.json')
    while True:
        if not signed_in(W, target): raise Stop('AWS sign-in expired; run ./workspace login --profile %s --region %s, then rerun this batch' % (target['profile'], target['region']))
        try:
            with D.locked(L, lock): owned = active.exists()
        except ValueError: reason = 'another controller is using this project'
        else:
            if owned: raise Stop(job['name']+': another operation owns this workspace; resume or cancel it, then rerun this batch')
            base, client, _ = L['sessions'](target)
            quota, used, _ = D.extensions(L)['onboarding'].vcpu_usage(L, base, client)
            if quota-used >= size['cpus']: return
            reason = '%s needs %d vCPUs; %d of the %d vCPU quota are in use' % (size['instance_type'], size['cpus'], used, quota)
        if reason != waiting: say('batch waiting: '+reason); waiting = reason
        time.sleep(SLOT_SECONDS)


def classify(result):
    if result.get('recovery_required') or result.get('cleanup_status') not in ('success', 'not_needed'): return 'unsettled'
    if result['status'] in ('success', 'cancelled'): return result['status']
    if result.get('job_exit') is not None: return 'failed'
    if (result.get('error') or {}).get('type') == 'InterruptedError': return 'interrupted'
    # Retry only when the job never started: capacity, IAM propagation or lease timing.
    if not result.get('infrastructure_ready'): return 'launch'
    return 'failed'


def settle(W, job, directory, result):
    """Resume an operation whose cleanup is unconfirmed once; never relaunch."""
    if classify(result) == 'unsettled':
        try: result = D.resume(W, job['config'], directory)
        except workspace_target.LoginRequired: raise Stop('AWS sign-in expired during cleanup; sign in, then rerun this batch') from None
        if classify(result) == 'unsettled':
            raise Stop(job['name']+': cleanup is not confirmed; run ./workspace '+job['config']+' resume, then rerun this batch')
    return result


def outcome(W, journal, job, directory, attempt, result, kind):
    launched = (Path(directory)/'workspace/launch/apply-started.json').exists()
    detail = {'kind': kind, 'status': result.get('status'), 'operation_id': Path(directory).name,
              'counted_usd': attempt['estimated_compute_usd'] if launched else 0,
              **{k: result.get(k) for k in ('infrastructure_ready', 'setup_exit', 'job_exit', 'output_uri', 'error')}}
    journal.record('job '+job['name'], 'outcome', detail)


def attempt_job(W, journal, batch, job, state):
    """One attempt: recover an open one, or check, prepare and launch a fresh scope."""
    L = W['L']; entry = state['jobs'][job['name']]
    open_attempt = entry['attempts'][-1] if entry['attempts'] and 'kind' not in entry['attempts'][-1] else None
    if open_attempt:
        directory = Path(open_attempt['operation_directory'])
        if not (directory/'task-authorization.json').exists():
            # Interrupted before its authorization: no cloud change was possible.
            return outcome(W, journal, job, directory, open_attempt, {'status': 'abandoned'}, 'abandoned')
        result = settle(W, job, directory, {'cleanup_status': 'unknown'})
        kind = classify(result)
        # Reconciliation reports an interruption; the job itself simply reruns.
        return outcome(W, journal, job, directory, open_attempt, result, kind)
    wait_for_slot(W, job)
    try: directory, scope = D.prepare(W, job['config'], instance_type=job['pin']['size']['instance_type'])
    except workspace_target.Failure as error: raise Stop(job['name']+': '+str(error)) from None
    fresh = pin(scope); drift = sorted(k for k in fresh if fresh[k] != job['pin'][k])
    if scope['capacity']['selected']['hourly_usd'] > job['hourly_usd']: drift.append('hourly price')
    if drift: raise Stop(job['name']+': scope differs from the batch review ('+', '.join(drift)+'); prepare a new batch review')
    scope_sha256 = L['sha'](L['canon'](scope)); number = len(entry['attempts'])+1
    attempt = {'attempt': number, 'operation_directory': str(directory), 'scope_sha256': scope_sha256,
               'estimated_compute_usd': scope['estimated_compute_usd']}
    journal.record('job '+job['name'], 'attempt', attempt)
    authorization = 'batch %s job %s attempt %d: approve scope %s' % (journal.scope_hash[:16], job['name'], number, scope_sha256[:16])
    try: result = D.deploy(W, job['config'], directory, authorization)
    except workspace_target.LoginRequired: raise Stop('AWS sign-in expired before launch; sign in, then rerun this batch') from None
    result = settle(W, job, directory, result)
    kind = classify(result)
    outcome(W, journal, job, directory, attempt, result, kind)
    if kind == 'cancelled': raise Stop(job['name']+': cancelled; rerunning this batch continues with the next job')
    if kind == 'interrupted': raise Stop('controller interrupted; rerun this batch to continue')
    launches = sum(a.get('kind') == 'launch' for a in entry['attempts'])+1
    if kind == 'launch' and launches < batch['launch_attempts']:
        say('batch %s: launch attempt %d failed before the job started; retrying in %d s' % (job['name'], launches, RETRY_SECONDS*launches))
        time.sleep(RETRY_SECONDS*launches)


def run(W, directory, batch, authorization):
    L = W['L']; batch_sha256 = L['sha'](L['canon'](batch))
    L['require'](len(authorization.strip()) >= 12 and batch_sha256[:16] in authorization,
                 'authorization must contain batch scope '+batch_sha256[:16]+' printed by the review; rerun without --authorization to see it')
    L['require'](L['source']() == batch['source'], 'source differs from the batch review; prepare a new batch review')
    with D.locked(L, L['REPO']/'evidence/aws/locks'/('batch-'+batch['batch_id']+'.lock')):
        journal = D.Journal(L, directory, batch_sha256)
        last = next((r for r in reversed(journal.records) if r['stage'] == 'batch'), None)
        if last and last['state'] == 'completed': return manifest(L, directory, batch, journal, 'completed')
        journal.record('batch', 'continued' if last else 'authorized', None if last else {'authorization': authorization})
        def interrupted(*_): raise Stop('controller interrupted; rerun this batch to continue')
        # A deploy installs its own handlers while it runs and restores these after.
        handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            for job in batch['jobs']:
                while True:
                    state = progress(batch, journal)
                    if state['jobs'][job['name']]['status'] != 'pending': break
                    if state['streak'] >= batch['max_consecutive_failures']:
                        raise Stop('%d consecutive job failures; inspect them, then rerun this batch to continue' % state['streak'])
                    attempt_job(W, journal, batch, job, state)
                    manifest(L, directory, batch, journal, 'running')
        except (Stop, workspace_target.Failure, ValueError) as stop:
            # Reviewed messages only; provider exceptions keep their own top-level report.
            journal.record('batch', 'stopped', {'reason': str(stop)})
            return manifest(L, directory, batch, journal, 'stopped', str(stop))
        finally:
            for sig, handler in handlers.items(): signal.signal(sig, handler)
        journal.record('batch', 'completed')
        return manifest(L, directory, batch, journal, 'completed')


def status(W, value):
    L = W['L']
    L['require'](value or latest_pointer(L).exists(), 'no batch yet; review one with ./workspace batch PROJECT.json ...')
    directory = L['checked_path'](L['REPO']/'evidence/aws/batches'/value if value else L['read'](latest_pointer(L))['directory'])
    L['require'](directory.is_dir(), 'unknown batch id')
    batch = L['read'](directory/'batch.json'); journal = D.Journal(L, directory, L['sha'](L['canon'](batch)))
    if not journal.records: return {'status': 'review_required', 'batch_directory': str(directory), 'batch_sha256': journal.scope_hash}
    last = next(r for r in reversed(journal.records) if r['stage'] == 'batch')
    try:
        with D.locked(L, L['REPO']/'evidence/aws/locks'/('batch-'+batch['batch_id']+'.lock')): running = False
    except ValueError: running = True
    if running: return manifest(L, directory, batch, journal, 'running')
    if last['state'] in ('completed', 'stopped'): return manifest(L, directory, batch, journal, last['state'], (last['detail'] or {}).get('reason'))
    return manifest(L, directory, batch, journal, 'stopped', 'controller ended unexpectedly; rerun this batch to continue')


def describe_result(command, result):
    lines = ['Batch outcome: %s; estimated compute about %.2f USD' % (result['status'], result['estimated_compute_usd'])]
    if result.get('reason'): lines.append('  reason: '+result['reason'])
    for job in result['jobs']:
        lines.append('  %-10s %s%s' % (job['status'], job['name'], '  '+job['output_uri'] if job.get('output_uri') else ''))
    if result['status'] == 'stopped': lines.append('  next: fix the reason, then rerun '+command+' with the same --authorization')
    return lines


def main(W, argv):
    L = W['L']
    if argv[:1] == ['status']:
        parser = argparse.ArgumentParser(prog='workspace batch status', description='Show a batch manifest (default: the latest batch).')
        parser.add_argument('batch', nargs='?', help='batch id'); args = parser.parse_args(argv[1:])
        L['require'](args.batch is None or (len(args.batch) == 32 and all(c in '0123456789abcdef' for c in args.batch)), 'invalid batch id')
        result = status(W, args.batch)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    parser = argparse.ArgumentParser(prog='workspace batch', description='Review N short project files once, then run them one at a time.')
    parser.add_argument('configs', nargs='+', metavar='PROJECT.json')
    parser.add_argument('--launch-attempts', type=int, default=3, help='attempts per job when the job never started (1-5, default 3)')
    parser.add_argument('--max-failures', type=int, default=2, help='stop after this many consecutive job failures (default 2)')
    parser.add_argument('--authorization', help='run or continue the reviewed batch; must quote its batch scope hash')
    args = parser.parse_args(argv)
    L['require'](1 <= args.launch_attempts <= 5 and 1 <= args.max_failures <= 100, 'launch attempts are 1 through 5, max failures 1 through 100')
    configs = [caller_path(c) for c in args.configs]
    options = {'launch_attempts': args.launch_attempts, 'max_consecutive_failures': args.max_failures}
    command = './workspace batch '+shlex.join(map(str, configs))
    if args.authorization:
        projects = [W['P'].validate_project(L, str(c)) for c in configs]
        pointer = selection(L, configs, projects, options)
        L['require'](pointer.exists(), 'no batch review for these project files and options; rerun without --authorization')
        directory = L['checked_path'](L['read'](pointer)['directory']); batch = L['read'](directory/'batch.json')
        result = run(W, directory, batch, args.authorization)
    else:
        directory, batch = review(W, configs, options, allow_login=True)
        batch_sha256 = L['sha'](L['canon'](batch))
        for line in describe(batch, batch_sha256): say(line)
        authorization = confirm(L, batch, batch_sha256)
        if not authorization:
            print(json.dumps({'status': 'review_required', 'batch_directory': str(directory), 'batch_sha256': batch_sha256,
                              'review': batch, 'cloud_mutations': False}, indent=2, sort_keys=True))
            say('  next: rerun '+command+' --authorization "approve batch '+batch_sha256[:16]+'"; long batches belong in a systemd user unit')
            return 0
        result = run(W, directory, batch, authorization)
    print(json.dumps(result, indent=2, sort_keys=True))
    for line in describe_result(command, result): say(line)
    return 0 if result['status'] == 'completed' and all(j['status'] == 'success' for j in result['jobs']) else 1
