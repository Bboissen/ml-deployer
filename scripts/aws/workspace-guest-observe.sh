#!/usr/bin/env bash
# Run inside the reviewed non-root SSM session. Read-only cloud probes; fixture
# transfer and output writes have their own later milestone-E authorization.
set -euo pipefail
exec /opt/workspace/sdk/bin/python - "$@" <<'PY'
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

def require(value,reason):
    if not value: raise ValueError(reason)

def canonical(value): return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()

def denied(call):
    try: call()
    except ClientError as exc:
        return exc.response['Error']['Code'] in ('AccessDenied','AccessDeniedException','UnauthorizedOperation')
    return False

try:
    p=argparse.ArgumentParser(description='Observe toolbox, native instance identity, versioned fixture and denied namespaces without writing objects.')
    p.add_argument('request'); p.add_argument('handoff'); p.add_argument('--fixture-key',required=True)
    p.add_argument('--fixture-version',required=True); p.add_argument('--fixture-sha256',required=True)
    p.add_argument('--unrelated-bucket',required=True); p.add_argument('--session-id',required=True)
    args=p.parse_args(); request=json.load(open(args.request)); handoff=json.load(open(args.handoff))
    require(os.getuid()!=0 and subprocess.check_output(['id','-un'],text=True).strip()=='workspace','session is not workspace user')
    require(not any(k in os.environ for k in ('AWS_PROFILE','AWS_DEFAULT_PROFILE','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_WEB_IDENTITY_TOKEN_FILE','AWS_CONTAINER_CREDENTIALS_RELATIVE_URI')),'instance-native credentials required')
    require(handoff['request_sha256']==hashlib.sha256(canonical(request)).hexdigest(),'request/handoff mismatch')
    success=json.load(open('/var/lib/workspace/bootstrap-success.json'))
    require(success['workspace_id']==request['workspace_id'],'bootstrap workspace mismatch')
    require(subprocess.run(['systemctl','is-active','--quiet','workspace-bootstrap.service']).returncode==0,'bootstrap service failed')
    require(subprocess.run(['systemctl','is-active','--quiet','amazon-ssm-agent']).returncode==0,'agent not active')
    directory=handoff['project_directory']
    module=importlib.util.spec_from_file_location('toolbox','/opt/workspace/scripts/workspace/probe-toolbox.py')
    toolbox=importlib.util.module_from_spec(module); module.loader.exec_module(toolbox)
    facts=toolbox.probe('aws',directory)
    require(not facts['missing_tools'] and facts['non_root'] and facts['project_directory_writable'] and facts['python_supported'] and facts['venv_available'],'toolbox probe failed')
    require(all(facts['resources'][key]>=request['resources'][key] for key in request['resources']),'usable capacity below request')
    session=boto3.Session(region_name=request['region'])
    config=Config(connect_timeout=3,read_timeout=5,retries={'total_max_attempts':2})
    identity=session.client('sts',config=config).get_caller_identity()
    expected=handoff['identity']['selector'].rsplit('/',1)[1]
    require(identity['Account']==request['account_scope'] and identity['Arn']==f"arn:aws:sts::{request['account_scope']}:assumed-role/{expected}/{handoff['machine_id']}",'instance role identity mismatch')
    s3=session.client('s3',config=config)
    data_uri=request['storage']['data_uri']; bucket=data_uri.split('/')[2]; prefix='/'.join(data_uri.split('/')[3:])
    require(args.fixture_key.startswith(prefix) and args.fixture_version and args.fixture_version!='null','fixture must be an authorized immutable version in data namespace')
    response=s3.get_object(Bucket=bucket,Key=args.fixture_key,VersionId=args.fixture_version,ExpectedBucketOwner=request['account_scope'])
    require(response['ContentLength']<=1048576,'acceptance fixture exceeds bound')
    content=response['Body'].read(1048577)
    require(hashlib.sha256(content).hexdigest()==args.fixture_sha256,'fixture checksum mismatch')
    output=request['storage']['output_uri']; out_prefix='/'.join(output.split('/')[3:])
    s3.list_objects_v2(Bucket=bucket,Prefix=out_prefix,MaxKeys=1,ExpectedBucketOwner=request['account_scope'])
    state_bucket=request['storage']['state_uri'].split('/')[2]
    require(args.unrelated_bucket not in (bucket,state_bucket),'negative bucket must be separately known to exist')
    state_denied=denied(lambda:s3.list_objects_v2(Bucket=state_bucket,MaxKeys=1,ExpectedBucketOwner=request['account_scope']))
    unrelated_denied=denied(lambda:s3.list_objects_v2(Bucket=args.unrelated_bucket,MaxKeys=1,ExpectedBucketOwner=request['account_scope']))
    require(state_denied and unrelated_denied,'negative storage checks did not return explicit access denial')
    record={'observed_at':dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'request_sha256':hashlib.sha256(canonical(request)).hexdigest(),'handoff_sha256':hashlib.sha256(canonical(handoff)).hexdigest(),
            'session_id':args.session_id,'machine_id':handoff['machine_id'],'workspace_id':request['workspace_id'],
            'uid':os.getuid(),'user':'workspace','facts':facts,'instance_role_arn':identity['Arn'],
            'toolbox_zip_sha256':success['toolbox_sha256'],'fixture_version':args.fixture_version,'fixture_sha256':args.fixture_sha256,
            'state_denied':state_denied,'unrelated_denied':unrelated_denied,'output_read_observed':True}
    print(json.dumps(record,sort_keys=True))
except Exception as exc:
    # Do not print credential/provider payloads or underlying raw diagnostics.
    print('aws-workspace-guest-observe: FAIL: '+type(exc).__name__,file=sys.stderr)
    sys.exit(2)
PY
