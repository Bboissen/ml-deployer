#!/usr/bin/env bash
# Full pinned VM installer in local AL2023; exact disposable-container cleanup.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
test $# -eq 1 || { echo 'Usage: test-workspace-installer.sh NEW_EVIDENCE_DIRECTORY' >&2; exit 2; }
directory="$(realpath -m "$1")"
[[ "$directory" == "$PWD/evidence/aws/"* && ! -e "$directory" ]] || exit 2
[[ "$(df -Pk "$PWD" | awk 'NR==2 {print $4}')" -ge 2097152 ]] || { echo 'installer test needs 2 GiB free' >&2; exit 2; }
mkdir -m 0700 "$directory"
image="$(jq -r .installer_image infra/aws/runner/workspace/toolbox/versions.json)"
name="aws-toolbox-offline-$(date -u +%Y%m%dT%H%M%S)-$$"
printf '%s\n' "$name" > "$directory/container-name"
status=0
cleanup() {
  original=$?
  identifier="$(docker container ls --all --filter "name=^/$name$" --format '{{.ID}}')"
  if [[ -n "$identifier" ]]; then
    owner="$(docker inspect --format '{{index .Config.Labels "workspace.offline-test"}}' "$identifier")"
    [[ "$owner" == "$name" ]] || { echo 'container ownership differs; cleanup refused' >&2; exit 2; }
    docker rm --force --volumes "$identifier" >> "$directory/installer.log" 2>&1
    remaining="$(docker container ls --all --filter "id=$identifier" --format '{{.ID}}')"
    [[ -z "$remaining" ]] || { echo 'owned container remains' >&2; exit 2; }
    printf '%s\n' "$identifier" > "$directory/deleted-container-id"
  fi
  printf '{"container_name":"%s","cleanup_verified":true,"image":"pre-existing --pull=never; preserved","exit_code":%s}\n' "$name" "$original" > "$directory/cleanup.json"
  df -Pk "$PWD" > "$directory/free-after.txt"
  exit "$original"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
timeout --signal=TERM --kill-after=15s 720s docker run --name "$name" --label "workspace.offline-test=$name" --pull=never \
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
# The EXIT trap removes only this labelled container and its volumes on every
# outcome; existing images and historical deployment evidence are preserved.
printf '{"passed":%s,"exit_code":%s,"cloud_mutations":false,"systemctl":"stubbed"}\n' \
  "$([[ "$status" == 0 ]] && echo true || echo false)" "$status" > "$directory/result.json"
echo "test-aws-workspace-installer: $([[ "$status" == 0 ]] && echo PASS || echo FAIL); evidence=$directory"
exit "$status"
