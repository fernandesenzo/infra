#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'napkin-env: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  die 'usage: napkin-env.sh <remote-infra-directory> (application values are read from stdin)'
fi

infra_dir=$1

[[ "$infra_dir" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die 'Infra directory must be a specific absolute path with valid components'

[[ ! "$infra_dir" =~ (^|/)\.\.?(/|$) ]] \
  || die 'Infra directory cannot contain . or .. path components'

config_dir="$infra_dir/config"
[[ -d "$config_dir" && ! -L "$config_dir" ]] \
  || die 'config directory is missing or is not a real directory; run infra setup first'

target_file="$config_dir/napkin.env"
[[ ! -L "$target_file" ]] || die "refusing to update symlink: $target_file"
[[ ! -e "$target_file" || -f "$target_file" ]] \
  || die "environment path is not a regular file: $target_file"

keys=(
  'APP_ENV'
  'SERVER_PORT'
  'ALLOWED_ORIGINS'
  'RATE_LIMIT_GET_MAX'
  'RATE_LIMIT_POST_MAX'
  'RATE_LIMIT_WINDOW_SEC'
  'CODE_LENGTH'
  'MAX_CONTENT_LENGTH'
  'DEFAULT_TTL'
)
values=('' '' '' '' '' '' '' '' '')
seen=(0 0 0 0 0 0 0 0 0)

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" == *=* ]] || die 'expected KEY=value lines on stdin'

  key=${line%%=*}
  value=${line#*=}
  [[ "$value" != *$'\r'* ]] || die "$key must be a single-line value"

  matched=0
  for index in 0 1 2 3 4 5 6 7 8; do
    if [[ "$key" == "${keys[$index]}" ]]; then
      (( seen[$index] == 0 )) || die "duplicate $key input"
      values[$index]=$value
      seen[$index]=1
      matched=1
      break
    fi
  done

  (( matched == 1 )) || die "unsupported Napkin environment key: $key"
done

for index in 0 1 2 3 4 5 6 7 8; do
  (( seen[$index] == 1 )) || die "${keys[$index]} was not provided"
done

app_env=${values[0]}
server_port=${values[1]}
allowed_origins=${values[2]}
rate_limit_get_max=${values[3]}
rate_limit_post_max=${values[4]}
rate_limit_window_sec=${values[5]}
code_length=${values[6]}
max_content_length=${values[7]}

[[ -n "$app_env" ]] || die 'APP_ENV cannot be empty'
[[ "$server_port" =~ ^[0-9]{1,5}$ ]] || die 'SERVER_PORT must be a number between 1 and 65535'
port_number=$((10#$server_port))
(( port_number > 0 && port_number <= 65535 )) \
  || die 'SERVER_PORT must be a number between 1 and 65535'
[[ -n "$allowed_origins" ]] || die 'ALLOWED_ORIGINS cannot be empty'

[[ "$rate_limit_get_max" =~ ^[1-9][0-9]*$ ]] \
  || die 'RATE_LIMIT_GET_MAX must be a positive integer'
[[ "$rate_limit_post_max" =~ ^[1-9][0-9]*$ ]] \
  || die 'RATE_LIMIT_POST_MAX must be a positive integer'
[[ "$rate_limit_window_sec" =~ ^[1-9][0-9]*$ ]] \
  || die 'RATE_LIMIT_WINDOW_SEC must be a positive integer'

[[ -z "$code_length" || "$code_length" =~ ^[1-9][0-9]*$ ]] \
  || die 'CODE_LENGTH must be empty or a positive integer'
[[ -z "$max_content_length" || "$max_content_length" =~ ^[1-9][0-9]*$ ]] \
  || die 'MAX_CONTENT_LENGTH must be empty or a positive integer'

umask 077
temporary_file=$(mktemp "$config_dir/.napkin-env.XXXXXX") \
  || die "could not create a temporary file in $config_dir"
trap 'rm -f -- "$temporary_file"' EXIT
chmod 600 "$temporary_file"

values_for_file=(
  "$app_env"
  "$server_port"
  "$allowed_origins"
  "$rate_limit_get_max"
  "$rate_limit_post_max"
  "$rate_limit_window_sec"
  "$code_length"
  "$max_content_length"
  "${values[8]}"
)
counts=(0 0 0 0 0 0 0 0 0)

write_assignment() {
  local key=$1
  local value=$2
  printf '%s=%s\n' "$key" "$value" >> "$temporary_file"
}

if [[ -f "$target_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    matched=0

    for index in 0 1 2 3 4 5 6 7 8; do
      key=${keys[$index]}
      pattern="^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*="

      if [[ "$line" =~ $pattern ]]; then
        counts[$index]=$((counts[$index] + 1))
        (( counts[$index] == 1 )) \
          || die "duplicate $key entries in $target_file; resolve duplicates before retrying"

        write_assignment "$key" "${values_for_file[$index]}"
        matched=1
        break
      fi
    done

    if (( matched == 0 )); then
      printf '%s\n' "$line" >> "$temporary_file"
    fi
  done < "$target_file"
fi

for index in 0 1 2 3 4 5 6 7 8; do
  if (( counts[$index] == 0 )); then
    write_assignment "${keys[$index]}" "${values_for_file[$index]}"
  fi
done

mv -f -- "$temporary_file" "$target_file" \
  || die "could not atomically replace $target_file"

printf 'Updated Napkin application settings in %s (Redis settings preserved)\n' "$target_file"
