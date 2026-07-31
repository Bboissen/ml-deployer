#!/usr/bin/env bash
# Upload a compact supervised panel (single file OR hive-partitioned dataset) to
# DigitalOcean Spaces, the canonical store for the big panels that don't fit every
# droplet's 50GB disk / 8GB RAM. Droplets then read only the subpart they need via
# the tune_mf2 `_load_panel` s3:// path (projection + fold pushdown).
#
# For the ~500MB MF2 panel the rsync data plane (scripts/do/sync_data.sh) is simpler
# and preferred; use this for MF1 / stacked-horizon / cross-family panels.
#
# Credentials are read ONLY from the environment (never files/TF/cloud-init):
#   DO_SPACES_KEY, DO_SPACES_SECRET, DO_SPACES_ENDPOINT, DO_SPACES_BUCKET
set -euo pipefail

SRC="${1:-}"
DEST_PREFIX="${2:-}"   # e.g. panels/mf2/h28  -> s3://$BUCKET/panels/mf2/h28
if [ -z "$SRC" ] || [ -z "$DEST_PREFIX" ]; then
  echo "Usage: $0 <local_file_or_dir> <dest_prefix>" >&2
  echo "  e.g. $0 ml_build/mf2/panel_full panels/mf2/h28" >&2
  exit 1
fi
for v in DO_SPACES_KEY DO_SPACES_SECRET DO_SPACES_ENDPOINT DO_SPACES_BUCKET; do
  if [ -z "${!v:-}" ]; then echo "Missing env: $v" >&2; exit 1; fi
done

# Map DO Spaces creds onto the AWS CLI (Spaces is S3-compatible) for this process only.
export AWS_ACCESS_KEY_ID="$DO_SPACES_KEY"
export AWS_SECRET_ACCESS_KEY="$DO_SPACES_SECRET"

DEST="s3://${DO_SPACES_BUCKET}/${DEST_PREFIX}"
if [ -d "$SRC" ]; then
  echo "Syncing dataset $SRC -> $DEST"
  aws --endpoint-url "$DO_SPACES_ENDPOINT" s3 sync "$SRC" "$DEST" --delete
else
  echo "Uploading file $SRC -> $DEST/"
  aws --endpoint-url "$DO_SPACES_ENDPOINT" s3 cp "$SRC" "$DEST/"
fi
echo "push-data-spaces OK: $DEST"
echo "Set  panel_uri: \"$DEST\"  in the tune config to read it from workers."
