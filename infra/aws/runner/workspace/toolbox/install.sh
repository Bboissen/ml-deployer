#!/usr/bin/env bash
set -euo pipefail
umask 022
export PATH=/opt/workspace/sdk/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1
workspace_id="$(cat /var/lib/workspace/workspace-id)"
[[ "$workspace_id" =~ ^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$ ]]
systemctl stop amazon-ssm-agent
rm -f /var/lib/workspace/bootstrap-success.json
mapfile -t pins < <(python3 - <<'PY'
import json
p=json.load(open('/opt/workspace/versions.json'))
print(p['releasever'])
for name,pin in sorted(p['rpms'].items()): print(name+'-'+pin['ver']+'-'+pin['rel'])
for tool in ('uv','aws_cli'):
    for field in ('url','sha256'): print(p[tool][field])
PY
)
rpm_count=$((${#pins[@]}-5))
test "$rpm_count" -gt 0
dnf --releasever="${pins[0]}" --setopt=gpgcheck=1 --setopt=timeout=20 --setopt=retries=2 install -y "${pins[@]:1:rpm_count}"

download() {
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 5 --max-time 90 --retry 2 --output "$3" "$1"
  printf '%s  %s\n' "$2" "$3" | sha256sum --check --status
}
download "${pins[rpm_count+1]}" "${pins[rpm_count+2]}" /var/lib/workspace/uv.tar.gz
python3.13 - <<'PY'
import tarfile
with tarfile.open('/var/lib/workspace/uv.tar.gz') as archive:
    archive.extractall('/var/lib/workspace', filter='data')
PY
install -m 0755 /var/lib/workspace/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv
download "${pins[rpm_count+3]}" "${pins[rpm_count+4]}" /var/lib/workspace/awscli.zip
unzip -q -o /var/lib/workspace/awscli.zip -d /var/lib/workspace/awscli
/var/lib/workspace/awscli/aws/install --update
uv venv --python /usr/bin/python3.13 /opt/workspace/sdk
uv pip sync --python /opt/workspace/sdk/bin/python --only-binary :all: --require-hashes /opt/workspace/sdk-requirements.lock
id workspace >/dev/null 2>&1 || useradd --create-home --shell /bin/bash workspace
usermod --lock workspace
install -d -o workspace -g workspace -m 0750 "/workspaces/$workspace_id"
# The platform image may have provisioned this rule; it must not survive.
rm -f /etc/sudoers.d/ssm-agent-users
gpasswd -d workspace wheel >/dev/null 2>&1 || true
gpasswd -d ssm-user wheel >/dev/null 2>&1 || true
cat > /etc/profile.d/workspace.sh <<'PROFILE'
export PATH=/opt/workspace/sdk/bin:/usr/local/bin:$PATH
export PYTHONDONTWRITEBYTECODE=1
export AWS_REGION="$(cat /var/lib/workspace/region)"
export AWS_DEFAULT_REGION="$AWS_REGION"
PROFILE
python3.13 - <<'PY'
import json, subprocess
pins=json.load(open('/opt/workspace/versions.json'))
for name,pin in pins['rpms'].items():
    actual=subprocess.check_output(['rpm','-q','--qf','%{VERSION}-%{RELEASE}',name],text=True)
    if actual != pin['ver']+'-'+pin['rel']: raise ValueError('RPM pin mismatch: '+name)
assert subprocess.check_output(['python','--version'],text=True).strip() == 'Python '+pins['rpms']['python3.13']['ver']
assert subprocess.check_output(['git','--version'],text=True).strip() == 'git version '+pins['rpms']['git']['ver']
assert subprocess.check_output(['ssh','-V'],stderr=subprocess.STDOUT,text=True).startswith('OpenSSH_'+pins['rpms']['openssh-clients']['ver'])
assert subprocess.check_output(['uv','--version'],text=True).split()[:2] == ['uv',pins['uv']['version']]
assert subprocess.check_output(['aws','--version'],text=True).startswith('aws-cli/'+pins['aws_cli']['version']+' ')
import boto3,botocore
assert boto3.__version__ == botocore.__version__ == pins['sdk_version']
PY
runuser -u workspace -- env PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 \
  /opt/workspace/sdk/bin/python /opt/workspace/scripts/workspace/probe-toolbox.py aws "/workspaces/$workspace_id" \
  > /var/lib/workspace/toolbox-observation.json
rm -f /var/lib/workspace/bootstrap-failed
# This records toolbox completion only, not native terminal/storage/guard readiness.
python - <<'PY'
import datetime, json, pathlib
p=pathlib.Path('/var/lib/workspace')
record={'toolbox_sha256':(p/'toolbox-sha256').read_text().strip(),
        'workspace_id':(p/'workspace-id').read_text().strip(),
        'completed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'native_workspace_ready':False}
(p/'bootstrap-success.json').write_text(json.dumps(record,sort_keys=True)+'\n')
PY
systemctl enable --now amazon-ssm-agent
