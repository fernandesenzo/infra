#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'deploy-napkin: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  die "usage: deploy-napkin.sh <ghcr-image-reference>"
fi

new_image=$1

: "${SSH_TARGET:?set SSH_TARGET to user@host}"
: "${REMOTE_INFRA_DIR:?set REMOTE_INFRA_DIR to the Infra directory on the VPS}"

[[ "$SSH_TARGET" =~ ^[A-Za-z0-9._@-]+$ ]] \
  || die "SSH_TARGET contains unsupported characters"

[[ "$REMOTE_INFRA_DIR" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die "REMOTE_INFRA_DIR must be a specific absolute path with valid components"

[[ ! "$REMOTE_INFRA_DIR" =~ (^|/)\.\.?(/|$) ]] \
  || die "REMOTE_INFRA_DIR cannot contain . or .. path components"

[[ "$new_image" =~ ^ghcr\.io/fernandesenzo/napkin:sha-[0-9a-f]{40}$ ]] \
  || die "image must be ghcr.io/fernandesenzo/napkin:sha-<40-character-commit-sha>"

ssh "$SSH_TARGET" \
  "REMOTE_INFRA_DIR='$REMOTE_INFRA_DIR' NEW_NAPKIN_IMAGE='$new_image' bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

die() {
  printf 'deploy-napkin: %s\n' "$*" >&2
  exit 1
}

readonly image_repository='ghcr.io/fernandesenzo/napkin'
readonly compose_file="$REMOTE_INFRA_DIR/compose/napkin.yml"
readonly compose_env="$REMOTE_INFRA_DIR/config/compose.env"
readonly project_name='infra'
readonly health_timeout_seconds=60
readonly health_poll_seconds=2

[[ -f "$compose_file" ]] || die "Compose file not found: $compose_file"
[[ -f "$compose_env" ]] || die "Compose environment file not found: $compose_env"
[[ -w "$compose_env" ]] || die "Compose environment file is not writable: $compose_env"

compose() {
  local image_ref=$1
  shift

  NAPKIN_IMAGE="$image_ref" docker compose \
    --project-name "$project_name" \
    --project-directory "$REMOTE_INFRA_DIR/compose" \
    --file "$compose_file" \
    --env-file "$compose_env" \
    "$@"
}

napkin_image_line_count=$(grep -c '^NAPKIN_IMAGE=' "$compose_env" || true)
(( napkin_image_line_count <= 1 )) \
  || die "compose.env must not contain duplicate NAPKIN_IMAGE= lines"

old_image=$(sed -n 's/^NAPKIN_IMAGE=//p' "$compose_env")
if [[ -n "$old_image" && ! "$old_image" =~ ^ghcr\.io/fernandesenzo/napkin:sha-[0-9a-f]{40}$ ]]; then
  die "current NAPKIN_IMAGE must be empty or an immutable SHA-tagged Napkin image"
fi

set_napkin_image() {
  local image_ref=$1
  local temporary_file

  temporary_file=$(mktemp "$compose_env.XXXXXX")

  if ! awk -v image_ref="$image_ref" '
    /^NAPKIN_IMAGE=/ {
      print "NAPKIN_IMAGE=" image_ref
      replaced++
      next
    }
    { print }
    END {
      if (replaced > 1) exit 1
      if (replaced == 0) print "NAPKIN_IMAGE=" image_ref
    }
  ' "$compose_env" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi

  if ! chmod --reference="$compose_env" "$temporary_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi

  if ! mv -- "$temporary_file" "$compose_env"; then
    rm -f -- "$temporary_file"
    return 1
  fi
}

wait_for_napkin_health() {
  local image_ref=$1
  local elapsed=0
  local container_id
  local health_status

  while (( elapsed < health_timeout_seconds )); do
    container_id=$(compose "$image_ref" ps --quiet napkin)

    if [[ -n "$container_id" ]]; then
      health_status=$(docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
        "$container_id")

      case "$health_status" in
        healthy)
          return 0
          ;;
        unhealthy|no-healthcheck)
          return 1
          ;;
      esac
    fi

    sleep "$health_poll_seconds"
    elapsed=$((elapsed + health_poll_seconds))
  done

  return 1
}

show_napkin_logs() {
  local image_ref=$1
  compose "$image_ref" logs --no-color --tail 100 napkin >&2 || true
}

prune_napkin_images() {
  local keep_current=$1
  local keep_previous=${2:-}
  local local_image

  while IFS= read -r local_image; do
    [[ "$local_image" == "$image_repository":* ]] || continue
    [[ "$local_image" == "$keep_current" || "$local_image" == "$keep_previous" ]] && continue

    docker image rm "$local_image" >/dev/null || {
      printf 'deploy-napkin: could not remove old local image %s\n' "$local_image" >&2
    }
  done < <(docker image ls "$image_repository" --format '{{.Repository}}:{{.Tag}}')
}

printf 'Pulling candidate image %s\n' "$NEW_NAPKIN_IMAGE"
compose "$NEW_NAPKIN_IMAGE" pull napkin

printf 'Activating candidate image\n'
if compose "$NEW_NAPKIN_IMAGE" up --detach napkin \
  && wait_for_napkin_health "$NEW_NAPKIN_IMAGE"; then
  set_napkin_image "$NEW_NAPKIN_IMAGE" \
    || die "Napkin is healthy, but could not record NAPKIN_IMAGE in compose.env"

  if [[ "$old_image" != "$NEW_NAPKIN_IMAGE" ]]; then
    prune_napkin_images "$NEW_NAPKIN_IMAGE" "$old_image"
  fi
  printf 'Napkin deployed and healthy: %s\n' "$NEW_NAPKIN_IMAGE"
  exit 0
fi

printf 'Candidate Napkin image did not become healthy\n' >&2
show_napkin_logs "$NEW_NAPKIN_IMAGE"

if [[ -z "$old_image" || "$old_image" == "$NEW_NAPKIN_IMAGE" ]]; then
  printf 'No different previous Napkin image is configured; automatic rollback is unavailable\n' >&2
  exit 1
fi

printf 'Rolling back to %s\n' "$old_image" >&2
if compose "$old_image" up --detach napkin \
  && wait_for_napkin_health "$old_image"; then
  docker image rm "$NEW_NAPKIN_IMAGE" >/dev/null || true
  printf 'Rollback succeeded; previous Napkin image is healthy\n' >&2
  exit 1
fi

printf 'Rollback image also failed to become healthy\n' >&2
show_napkin_logs "$old_image"
docker image rm "$NEW_NAPKIN_IMAGE" >/dev/null || true
exit 1
REMOTE_SCRIPT
