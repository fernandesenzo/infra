#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'shortener-env: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  die 'usage: shortener-env.sh <remote-infra-directory> (application values are read from stdin)'
fi

infra_dir=$1

[[ "$infra_dir" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die 'Infra directory must be a specific absolute path with valid components'

[[ ! "$infra_dir" =~ (^|/)\.\.?(/|$) ]] \
  || die 'Infra directory cannot contain . or .. path components'

config_dir="$infra_dir/config"
[[ -d "$config_dir" && ! -L "$config_dir" ]] \
  || die 'config directory is missing or is not a real directory; run infra setup first'

target_file="$config_dir/shortener.env"
[[ ! -L "$target_file" ]] || die "refusing to update symlink: $target_file"
[[ ! -e "$target_file" || -f "$target_file" ]] \
  || die "environment path is not a regular file: $target_file"

app_env=''
server_port=''
allowed_origins=''
seen_app_env=0
seen_server_port=0
seen_allowed_origins=0

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" == *=* ]] || die 'expected KEY=value lines on stdin'

  key=${line%%=*}
  value=${line#*=}

  [[ "$value" != *$'\r'* ]] || die "$key must be a single-line value"

  case "$key" in
    APP_ENV)
      (( seen_app_env == 0 )) || die 'duplicate APP_ENV input'
      app_env=$value
      seen_app_env=1
      ;;
    SERVER_PORT)
      (( seen_server_port == 0 )) || die 'duplicate SERVER_PORT input'
      server_port=$value
      seen_server_port=1
      ;;
    ALLOWED_ORIGINS)
      (( seen_allowed_origins == 0 )) || die 'duplicate ALLOWED_ORIGINS input'
      allowed_origins=$value
      seen_allowed_origins=1
      ;;
    *)
      die "unsupported Shortener environment key: $key"
      ;;
  esac
done

(( seen_app_env == 1 )) || die 'APP_ENV was not provided'
(( seen_server_port == 1 )) || die 'SERVER_PORT was not provided'
(( seen_allowed_origins == 1 )) || die 'ALLOWED_ORIGINS was not provided'

[[ -n "$app_env" ]] || die 'APP_ENV cannot be empty'
[[ "$server_port" =~ ^[0-9]{1,5}$ ]] || die 'SERVER_PORT must be a number between 1 and 65535'
port_number=$((10#$server_port))
(( port_number > 0 && port_number <= 65535 )) \
  || die 'SERVER_PORT must be a number between 1 and 65535'
[[ -n "$allowed_origins" ]] || die 'ALLOWED_ORIGINS cannot be empty'

umask 077
temporary_file=$(mktemp "$config_dir/.shortener-env.XXXXXX") \
  || die "could not create a temporary file in $config_dir"
trap 'rm -f -- "$temporary_file"' EXIT
chmod 600 "$temporary_file"

keys=('APP_ENV' 'SERVER_PORT' 'ALLOWED_ORIGINS')
values=("$app_env" "$server_port" "$allowed_origins")
counts=(0 0 0)

write_assignment() {
  local key=$1
  local value=$2
  printf '%s=%s\n' "$key" "$value" >> "$temporary_file"
}

if [[ -f "$target_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    matched=0

    for index in 0 1 2; do
      key=${keys[$index]}
      pattern="^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*="

      if [[ "$line" =~ $pattern ]]; then
        counts[$index]=$((counts[$index] + 1))
        (( counts[$index] == 1 )) \
          || die "duplicate $key entries in $target_file; resolve duplicates before retrying"

        write_assignment "$key" "${values[$index]}"
        matched=1
        break
      fi
    done

    if (( matched == 0 )); then
      printf '%s\n' "$line" >> "$temporary_file"
    fi
  done < "$target_file"
fi

for index in 0 1 2; do
  if (( counts[$index] == 0 )); then
    write_assignment "${keys[$index]}" "${values[$index]}"
  fi
done

mv -f -- "$temporary_file" "$target_file" \
  || die "could not atomically replace $target_file"

printf 'Updated Shortener application settings in %s (Redis settings preserved)\n' "$target_file"
