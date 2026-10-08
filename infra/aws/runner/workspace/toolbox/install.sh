#!/usr/bin/env bash
set -euo pipefail
umask 022
export PATH=/opt/workspace/sdk/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1
workspace_id="$(cat /var/lib/workspace/workspace-id)"
[[ "$workspace_id" =~ ^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$ ]]
systemctl stop amazon-ssm-agent
rm -f /var/lib/workspace/bootstrap-success.json
dnf --releasever=2023.12.20260930 --setopt=gpgcheck=1 --setopt=timeout=20 --setopt=retries=2 install -y \
  python3.13-3.13.15-1.amzn2023.0.1 python3.13-devel-3.13.15-1.amzn2023.0.1 \
  python3.13-pip-24.2-259.amzn2023.0.8 git-2.50.1-1.amzn2023.0.1 git-core-2.50.1-1.amzn2023.0.1 \
  gcc-11.5.0-5.amzn2023.0.5 make-4.3-5.amzn2023.0.2 \
  curl-minimal-8.21.0-5.amzn2023.0.2 unzip-6.0-68.amzn2023.0.2 \
  amazon-ssm-agent-3.3.5226.0-1.amzn2023

download() {
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 5 --max-time 90 --retry 2 --output "$3" "$1"
  printf '%s  %s\n' "$2" "$3" | sha256sum --check --status
}
download https://github.com/astral-sh/uv/releases/download/0.12.23/uv-x86_64-unknown-linux-gnu.tar.gz \
  9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6 /var/lib/workspace/uv.tar.gz
python3.13 - <<'PY'
import tarfile
with tarfile.open('/var/lib/workspace/uv.tar.gz') as archive:
    archive.extractall('/var/lib/workspace', filter='data')
PY
install -m 0755 /var/lib/workspace/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv
download https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.36.14.zip \
  43b34875482244039716cc3725d1f60e7d47ef3cfb2a19e114759a46db24dc30 /var/lib/workspace/awscli.zip
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
pins=json.load(open('/opt/workspace/rpm-pins.json'))
for name,pin in pins.items():
    actual=subprocess.check_output(['rpm','-q','--qf','%{VERSION}-%{RELEASE}',name],text=True)
    if actual != pin['ver']+'-'+pin['rel']: raise ValueError('RPM pin mismatch: '+name)
PY
test "$(python --version)" = 'Python 3.13.15'
test "$(git --version)" = 'git version 2.50.1'
read -r uv_tool uv_version uv_build < <(uv --version)
test "$uv_tool $uv_version" = 'uv 0.12.23'
aws --version | /usr/bin/grep -q '^aws-cli/2.36.14 '
python -c 'import boto3,botocore; assert boto3.__version__ == botocore.__version__ == "1.43.109"'
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
