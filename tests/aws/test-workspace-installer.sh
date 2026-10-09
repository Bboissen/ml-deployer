#!/usr/bin/env bash
# Full pinned installer in local AL2023; package downloads, no AWS account APIs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
test $# -eq 1 || { echo 'Usage: test-workspace-installer.sh NEW_EVIDENCE_DIRECTORY' >&2; exit 2; }
directory="$(realpath -m "$1")"
[[ "$directory" == "$PWD/evidence/aws/"* && ! -e "$directory" ]] || exit 2
mkdir -m 0700 "$directory"
image="$(jq -r .installer_image infra/aws/runner/workspace/toolbox/versions.json)"
name="aws-toolbox-offline-$(date -u +%Y%m%dT%H%M%S)-$$"
printf '%s\n' "$name" > "$directory/container-name"
status=0
timeout --signal=TERM --kill-after=15s 720s docker run --name "$name" --pull=never \
  --mount "type=bind,src=$PWD,dst=/source,readonly" \
  --mount "type=bind,src=$directory,dst=/evidence" \
  --entrypoint /bin/bash "$image" -c '
set -euo pipefail
mkdir -p /opt/workspace /var/lib/workspace
cp -R /source/infra/aws/runner/workspace/toolbox/. /opt/workspace/
mkdir -p /opt/workspace/scripts/workspace /opt/workspace/shared/workspace
cp /source/scripts/workspace/probe-toolbox.py /opt/workspace/scripts/workspace/
cp /source/shared/workspace/toolbox.json /opt/workspace/shared/workspace/
printf "demo-dev-01\n" > /var/lib/workspace/workspace-id
printf "us-east-1\n" > /var/lib/workspace/region
sha256sum /opt/workspace/install.sh | cut -d" " -f1 > /var/lib/workspace/toolbox-sha256
systemctl() { printf "%s\n" "$*" >> /evidence/systemctl.log; }
export -f systemctl
bash /opt/workspace/install.sh
cp /var/lib/workspace/bootstrap-success.json /var/lib/workspace/toolbox-observation.json /evidence/
' > "$directory/installer.log" 2>&1 || status=$?
if ((status != 0)); then
  docker stop --timeout 5 "$name" >> "$directory/installer.log" 2>&1 || true
fi
# Retain the container and logs on failure. Successful disposable containers
# may also be inspected; this test never deletes historical evidence.
printf '{"passed":%s,"exit_code":%s,"cloud_mutations":false,"systemctl":"stubbed"}\n' \
  "$([[ "$status" == 0 ]] && echo true || echo false)" "$status" > "$directory/result.json"
echo "test-aws-workspace-installer: $([[ "$status" == 0 ]] && echo PASS || echo FAIL); evidence=$directory"
exit "$status"
