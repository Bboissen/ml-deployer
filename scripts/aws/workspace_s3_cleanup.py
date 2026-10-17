"""Manually reviewed deletion of workload versions; never infrastructure state."""
import importlib.util
import os
from pathlib import Path
import re
import time
import uuid

from workspace_storage import LEGACY, prefixes, workload_bucket
from workspace_terminal import interactive

spec = importlib.util.spec_from_file_location('cleanup_deploy', Path(__file__).with_name('workspace-deploy.py'))
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
MAX_ITEMS = 100000
MAX_BYTES = 8 * 1024**2
SECONDS = 300


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def context(W, config):
    L, P = W['L'], W['P']
    project = P.validate_project(L, config)
    P.supported_profile(L, project['region'])
    operation = D.latest(L, config)
    P.operation_status(L, config, operation)
    scope = L['read'](operation/'scope.json')
    deployment = L['read'](operation/'deployment.json')
    require(scope['deployment_sha256'] == L['sha'](L['canon'](deployment)) and
            scope['configuration_sha256'] == L['sha'](L['canon'](project)) and
            L['prior_source'](scope['source']), 'cleanup deployment binding changed')
    target = scope['target']
    require(target['profile'] == project['profile'] and target['region'] == project['region'] and
            target['account_id'] == deployment['account_id'] and
            target['backend'] == deployment['backend'] and
            target['inventory']['buckets'] == [deployment['names']['workload_bucket']], 'cleanup target differs from project')
    prefix = project['project'][:12]+'-'+L['sha'](f"{target['account_id']}/{target['region']}/{project['project']}".encode())[:10]
    require(target['inventory']['resource_prefix'] == prefix, 'cleanup project ownership differs')
    registry = L['checked_path'](L['REPO']/'evidence/aws/projects'/prefix)
    binding = L['read'](registry/'foundation.json')
    return project, target, registry, binding


def inactive(L, registry):
    require(not list(registry.glob('*-active.json')),
            'project has an active or unresolved operation; use status/resume/cancel before S3 cleanup')


def storage_guard(s3, target, bucket):
    require(bucket != target['backend']['bucket'] and bucket in target['inventory']['buckets'],
            'state or unreviewed bucket cannot be cleaned')
    owner = {'Bucket': bucket, 'ExpectedBucketOwner': target['account_id']}
    location = s3.get_bucket_location(**owner).get('LocationConstraint') or 'us-east-1'
    require(location == target['region'] and s3.get_bucket_versioning(**owner).get('Status') == 'Enabled',
            'workload bucket region/versioning differs')
    return owner


def inventory(L, s3, owner, selected, deadline):
    """Bounded, exact versions/markers/upload IDs; never use a blanket delete."""
    versions, uploads = [], []
    for prefix in selected:
        for operation, fields, markers in (
            ('list_object_versions', ('Versions', 'DeleteMarkers'), ('KeyMarker', 'VersionIdMarker')),
            ('list_multipart_uploads', ('Uploads',), ('KeyMarker', 'UploadIdMarker')),
        ):
            arguments = {**owner, 'Prefix': prefix}
            arguments['MaxKeys' if operation == 'list_object_versions' else 'MaxUploads'] = 1000
            seen = set()
            for _ in range(1000):
                require(time.monotonic() < deadline, 'S3 cleanup inventory exceeded its time bound')
                page = getattr(s3, operation)(**arguments)
                require(type(page.get('IsTruncated')) is bool, 'S3 inventory completeness was not reported')
                for field in fields:
                    for item in page.get(field, []):
                        key = item['Key']
                        require(isinstance(key, str) and key.startswith(prefix) and len(key.encode()) <= 1024,
                                'S3 inventory returned an object outside the reviewed prefix')
                        if field == 'Uploads':
                            identifier = item['UploadId']
                            require(isinstance(identifier, str) and re.fullmatch(r'[!-~]{1,2048}', identifier), 'invalid S3 upload identity')
                            uploads.append({'Key': key, 'UploadId': identifier})
                        else:
                            identifier = item['VersionId']
                            require(isinstance(identifier, str) and identifier != 'null' and
                                    re.fullmatch(r'[!-~]{1,1024}', identifier), 'immutable S3 version identity required')
                            size = item.get('Size', 0)
                            require(type(size) is int and size >= 0, 'invalid S3 version size')
                            versions.append({'Key': key, 'VersionId': identifier, 'bytes': size, 'delete_marker': field == 'DeleteMarkers'})
                        require(len(versions)+len(uploads) <= MAX_ITEMS, 'S3 cleanup inventory exceeds 100000 entries')
                if not page.get('IsTruncated'):
                    break
                marker = tuple(page.get('Next'+name) for name in markers)
                require(all(isinstance(v, str) and v for v in marker) and marker not in seen,
                        'incomplete or repeated S3 pagination marker')
                seen.add(marker)
                arguments.update(zip(markers, marker))
            else:
                raise ValueError('S3 cleanup pagination exceeds its page bound')
    versions.sort(key=lambda v: (v['Key'], v['VersionId']))
    uploads.sort(key=lambda v: (v['Key'], v['UploadId']))
    require(len({(v['Key'], v['VersionId']) for v in versions}) == len(versions) and
            len({(v['Key'], v['UploadId']) for v in uploads}) == len(uploads), 'duplicate S3 inventory identities')
    result = {'versions': versions, 'uploads': uploads}
    require(len(L['canon'](result)) <= MAX_BYTES, 'S3 cleanup inventory exceeds eight MiB')
    return result


def clean(W, config, include_datasets=False, dry_run=False):
    L = W['L']
    project, target, registry, binding = context(W, config)
    with D.locked(L, L['REPO']/'evidence/aws/locks'/(target['inventory']['resource_prefix']+'.lock')):
        inactive(L, registry)
        packet = L['REPO']/'evidence/aws/s3-cleanup'/uuid.uuid4().hex
        packet.mkdir(parents=True, mode=0o700)
        L['write'](packet/'target.json', {'target_name': 'aws-'+target['inventory']['resource_prefix'], 'target': target})
        os.environ['WORKSPACE_CONFIG'] = str(packet/'target.json')
        L['boundary']['targets']()
        L['boundary']['profile_environment'](target['profile'], target['region'])
        O = D.extensions(L)['onboarding']
        platform = O.verify_retained(L, binding, target)
        layout = platform.get('storage_layout', LEGACY)
        slug = project['project']; workspace = slug+'-'+project['workspace']
        entry = platform['ml_projects'].get(slug, {})
        bucket = target['inventory']['buckets'][0]
        require(entry.get('ml_project_name') == slug and entry.get('storage_mode', 'auto') == 'auto' and
                not entry.get('assignment') and bucket == workload_bucket(target['account_id'], target['region'], slug, layout),
                'cleanup requires this project\'s managed workload bucket; external storage is protected')
        base, client, _ = L['sessions'](target)
        s3 = client(base, 's3')
        owner = storage_guard(s3, target, bucket)
        data, results = prefixes(slug, workspace, layout)
        selected = [results] + ([data] if include_datasets else [])
        objects = inventory(L, s3, owner, selected, time.monotonic()+SECONDS)
        cache = L['checked_path'](registry/'dataset.json')
        if include_datasets and cache.exists(): L['read'](cache)
        cached = cache.read_bytes() if include_datasets and cache.exists() else None
        review = {'kind': 's3-cleanup', 'cleanup_id': packet.name, 'reviewed_at': L['stamp'](),
                  'account_id': target['account_id'], 'region': target['region'],
                  'operator_arn': target['operator_arn'], 'bucket': bucket, 'prefixes': selected,
                  'workspace_id': workspace, 'include_datasets': include_datasets, **objects,
                  'dataset_cache_sha256': L['sha'](cached) if cached is not None else None,
                  'foundation_sha256': L['sha'](L['canon'](binding)), 'source': L['source']()}
        L['write'](packet/'review.json', review)
        if not dry_run:
            require(review['source']['working_tree_sha256'] == L['sha'](b''), 'cleanup requires clean committed source')
        digest = L['sha'](L['canon'](review))
        D.say('WARNING: S3 cleanup permanently deletes the reviewed object versions, delete markers and unfinished uploads. This cannot be undone.')
        D.say('  account/region: '+target['account_id']+' / '+target['region'])
        D.say('  profile/operator: '+target['profile']+' / '+target['operator_arn'])
        D.say('  bucket: '+bucket)
        for prefix in selected:
            D.say('  delete under: s3://'+bucket+'/'+prefix)
        D.say('  %d versions/markers (%d bytes); %d unfinished uploads' %
              (len(objects['versions']), sum(v['bytes'] for v in objects['versions']), len(objects['uploads'])))
        if include_datasets:
            D.say('  Includes shared project datasets. A later Deploy must upload them again from the configured source.')
        D.say('  Buckets, infrastructure state, local source data and deployment evidence are retained.')
        D.say('  Exact inventory: '+str(packet/'review.json'))
        summary = {'scope_sha256': digest, 'review_file': str(packet/'review.json'), 'cloud_mutations': False}
        if dry_run:
            return dict(summary, status='preview')
        if not objects['versions'] and not objects['uploads'] and cached is None:
            return dict(summary, status='empty')
        answer = 'delete '+digest[:16]
        if not interactive():
            D.say('S3 cleanup requires an interactive terminal and manual confirmation; no objects were deleted.')
            return dict(summary, status='confirmation_required')
        D.say('Type '+answer+' to delete exactly this inventory, or press Enter to stop:')
        try:
            confirmed = input('> ')
        except (EOFError, KeyboardInterrupt):
            confirmed = ''
        if confirmed.strip() != answer:
            return dict(summary, status='cancelled')
        L['write'](packet/'authorization.json', {'scope_sha256': digest, 'answer': confirmed.strip(), 'authorized_at': L['stamp']()})
        receipt = {'status': 'in_progress', 'scope_sha256': digest, 'verified': False, 'cloud_mutations': False,
                   'deleted_versions': 0, 'aborted_uploads': 0, 'dataset_cache_archived': False}
        D.atomic(L, packet/'receipt.json', receipt, exclusive=True)
        try:
            D.say('S3 cleanup: rechecking ownership and the reviewed inventory')
            require(L['source']() == review['source'] and review['source']['working_tree_sha256'] == L['sha'](b''),
                    'cleanup requires unchanged clean committed source')
            inactive(L, registry)
            O.verify_retained(L, binding, target)
            require(L['read'](registry/'foundation.json') == binding, 'retained foundation changed during review')
            storage_guard(s3, target, bucket)
            deadline = time.monotonic()+SECONDS
            require(inventory(L, s3, owner, selected, deadline) == objects, 'S3 contents changed during review; run cleanup again for a new review')
            require(L['read'](packet/'review.json') == review, 'cleanup review changed')
            if cached is not None:
                require(cache.read_bytes() == cached, 'retained dataset cache changed during review')
                # Keep the manifest as evidence before any deletion, including
                # partial failures, so later Deploy cannot reuse deleted data.
                L['checked_path'](cache)
                os.replace(cache, L['checked_path'](packet/'dataset-cache.json'))
                receipt['dataset_cache_archived'] = True
            for index, upload in enumerate(objects['uploads']):
                require(time.monotonic() < deadline, 'S3 cleanup exceeded its time bound')
                L['write'](packet/('upload-%06d-intent.json' % index), upload)
                receipt['cloud_mutations'] = True
                D.atomic(L, packet/'receipt.json', receipt)
                s3.abort_multipart_upload(**owner, **upload)
                try:
                    parts = s3.list_parts(**owner, **upload)
                    require(not parts.get('Parts') and parts.get('IsTruncated') is False, 'aborted S3 upload still has parts or unknown completeness; review cleanup again')
                except Exception as error:
                    if getattr(error, 'response', {}).get('Error', {}).get('Code') != 'NoSuchUpload': raise
                L['write'](packet/('upload-%06d-aborted.json' % index), upload)
                receipt['aborted_uploads'] += 1
            for start in range(0, len(objects['versions']), 1000):
                require(time.monotonic() < deadline, 'S3 cleanup exceeded its time bound')
                batch = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in objects['versions'][start:start+1000]]
                D.say('S3 cleanup: deleting versions %d-%d of %d' % (start+1, start+len(batch), len(objects['versions'])))
                L['write'](packet/('batch-%06d-intent.json' % start), batch)
                receipt['cloud_mutations'] = True
                D.atomic(L, packet/'receipt.json', receipt)
                response = s3.delete_objects(**owner, Delete={'Objects': batch, 'Quiet': False})
                deleted = response.get('Deleted', [])
                reported = {(v['Key'], v['VersionId']) for v in deleted}
                requested = {(v['Key'], v['VersionId']) for v in batch}
                confirmed = [v for v in batch if (v['Key'], v['VersionId']) in reported]
                L['write'](packet/('batch-%06d-response.json' % start),
                           {'confirmed_deleted': confirmed, 'error_count': len(response.get('Errors', [])),
                            'unconfirmed': [v for v in batch if (v['Key'], v['VersionId']) not in reported]})
                receipt['deleted_versions'] += len(confirmed)
                require(not response.get('Errors') and len(deleted) == len(batch) and reported == requested,
                        'S3 did not confirm every reviewed version deletion; inspect the receipt and review remaining objects again')
            D.say('S3 cleanup: verifying selected prefixes are empty')
            remaining = inventory(L, s3, owner, selected, deadline)
            require(not remaining['versions'] and not remaining['uploads'], 'S3 cleanup could not verify empty selected prefixes; new or remaining objects were preserved')
            receipt.update(status='success', verified=True)
        except BaseException as error:
            receipt['status'] = 'failure'
            receipt['error_type'] = type(error).__name__
            receipt['next'] = 'Inspect this receipt and rerun clean-s3 to review the remaining inventory; partial deletion cannot be undone.'
            raise
        finally:
            receipt['completed_at'] = L['stamp']()
            D.atomic(L, packet/'receipt.json', receipt)
            D.say('S3 cleanup: '+receipt['status']+'; receipt: '+str(packet/'receipt.json'))
        return dict(receipt, receipt_file=str(packet/'receipt.json'))
