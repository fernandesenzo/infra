#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'deploy-website: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  die "usage: deploy-website.sh <artifact-directory>"
fi

artifact_dir=$1

: "${SSH_TARGET:?set SSH_TARGET to user@host}"
: "${REMOTE_WEBSITE_DIR:?set the remote website parent directory}"
: "${DEPLOY_ID:?set DEPLOY_ID to a unique identifier}"

[[ -d "$artifact_dir" ]] || die "artifact directory does not exist"
[[ -f "$artifact_dir/index.html" ]] || die "artifact must contain index.html at its root"

REMOTE_WEBSITE_DIR=${REMOTE_WEBSITE_DIR%/}

[[ "$REMOTE_WEBSITE_DIR" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die "REMOTE_WEBSITE_DIR must be a specific absolute path with valid components"

[[ ! "$REMOTE_WEBSITE_DIR" =~ (^|/)\.\.?(/|$) ]] \
  || die "REMOTE_WEBSITE_DIR cannot contain . or .. path components"

[[ "$DEPLOY_ID" =~ ^[A-Za-z0-9_-]+$ ]] \
  || die "DEPLOY_ID contains unsupported characters"

staging_dir="$REMOTE_WEBSITE_DIR/.incoming-$DEPLOY_ID"

ssh "$SSH_TARGET" \
  "mkdir -p '$REMOTE_WEBSITE_DIR' && rm -rf -- '$staging_dir' && mkdir -p -- '$staging_dir'"

if ! tar -C "$artifact_dir" -czf - . |
  ssh "$SSH_TARGET" "tar -xzf - -C '$staging_dir'"; then
  ssh "$SSH_TARGET" "rm -rf -- '$staging_dir'" || true
  die "failed to upload artifact"
fi

if ! ssh "$SSH_TARGET" \
  "REMOTE_WEBSITE_DIR='$REMOTE_WEBSITE_DIR' DEPLOY_ID='$DEPLOY_ID' bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

website_dir=$REMOTE_WEBSITE_DIR
staging_dir="$website_dir/.incoming-$DEPLOY_ID"
current_dir="$website_dir/current"
previous_dir="$website_dir/previous"

if [[ ! -f "$staging_dir/index.html" ]]; then
  printf 'staged artifact is missing index.html\n' >&2
  exit 1
fi

rm -rf -- "$previous_dir"

if [[ -e "$current_dir" ]]; then
  mv -- "$current_dir" "$previous_dir"
fi

if ! mv -- "$staging_dir" "$current_dir"; then
  if [[ ! -e "$current_dir" && -e "$previous_dir" ]]; then
    mv -- "$previous_dir" "$current_dir"
  fi
  printf 'failed to activate new website; restored previous version if available\n' >&2
  exit 1
fi

printf 'website deployed successfully\n'
REMOTE_SCRIPT
then
  ssh "$SSH_TARGET" "rm -rf -- '$staging_dir'" || true
  exit 1
fi
