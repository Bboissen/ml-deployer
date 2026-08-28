#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'verify-provider-digests: ERROR: %s\n' "$1" >&2
  exit 2
}

(( $# == 4 )) || fail "usage: $0 sha256:DIGEST AWS_REPOSITORY GCP_REPOSITORY AZURE_REPOSITORY"
readonly EXPECTED_DIGEST="$1"
shift
[[ "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "expected digest is invalid"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker buildx version >/dev/null 2>&1 || fail "docker buildx is required"

providers=(aws gcp azure)
repositories=("$1" "$2" "$3")

for index in 0 1 2; do
  provider="${providers[$index]}"
  repository="${repositories[$index]}"
  case "$provider" in
    aws)
      [[ "$repository" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
        fail "AWS repository must be an untagged ECR repository"
      ;;
    gcp)
      [[ "$repository" =~ ^[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
        fail "GCP repository must be an untagged Artifact Registry repository"
      ;;
    azure)
      [[ "$repository" =~ ^[a-z0-9]{5,50}\.azurecr\.io/[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
        fail "Azure repository must be an untagged ACR repository"
      ;;
  esac
  raw_manifest="$(docker buildx imagetools inspect --raw "${repository}@${EXPECTED_DIGEST}")" ||
    fail "${provider} repository does not expose the expected digest"
  actual_digest="$(printf '%s' "$raw_manifest" | sha256sum | cut -d' ' -f1)"
  [[ "sha256:${actual_digest}" == "$EXPECTED_DIGEST" ]] || fail "${provider} registry returned different manifest bytes"
  printf '%s %s@%s PASS\n' "$provider" "$repository" "$EXPECTED_DIGEST"
done

printf 'All provider-local repositories expose identical manifest bytes. Verification was read-only.\n'
