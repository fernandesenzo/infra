#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'redis-env: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  die 'usage: redis-env.sh <remote-infra-directory> (Redis values are read from stdin)'
fi

infra_dir=$1

[[ "$infra_dir" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die 'Infra directory must be a specific absolute path with valid components'

[[ ! "$infra_dir" =~ (^|/)\.\.?(/|$) ]] \
  || die 'Infra directory cannot contain . or .. path components'

if ! IFS= read -r redis_addr; then
  die 'Redis address was not provided on stdin'
fi

if ! IFS= read -r redis_password; then
  die 'Redis password was not provided on stdin'
fi

if IFS= read -r unexpected_input; then
  die 'unexpected extra input on stdin'
fi

[[ "$redis_addr" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] \
  || die 'Redis address must use the host:port format, such as redis:6379'

redis_port=${redis_addr##*:}
(( 10#$redis_port > 0 && 10#$redis_port <= 65535 )) \
  || die 'Redis port must be between 1 and 65535'

[[ -n "$redis_password" ]] || die 'Redis password cannot be empty'
[[ "$redis_password" != *$'\n'* && "$redis_password" != *$'\r'* ]] \
  || die 'Redis password must be a single-line value'

config_dir="$infra_dir/config"
umask 077
mkdir -p -- "$config_dir" \
  || die "could not create config directory; ensure the deploy user can write under $infra_dir"

[[ -d "$config_dir" && ! -L "$config_dir" ]] \
  || die 'config path must be a real directory, not a symlink'

# Start with an unused element so strict mode also works with macOS's older Bash.
staged_files=('')
target_files=('')

cleanup() {
  local staged_file
  local index
  for ((index = 1; index < ${#staged_files[@]}; index++)); do
    staged_file=${staged_files[$index]}
    if [[ -n "$staged_file" ]]; then
      rm -f -- "$staged_file"
    fi
  done
}
trap cleanup EXIT

write_env_assignment() {
  local output_file=$1
  local format=$2
  local key=$3
  local value=$4
  local escaped_value

  if [[ "$format" == raw ]]; then
    # Compose's raw env_file format passes the value through without dotenv parsing.
    printf '%s=%s\n' "$key" "$value" >> "$output_file"
  elif [[ "$key" == REDIS_PASSWORD ]]; then
    # Double-quote and escape dotenv syntax so $, quotes, and backslashes survive Compose parsing.
    escaped_value=${value//\\/\\\\}
    escaped_value=${escaped_value//\"/\\\"}
    escaped_value=${escaped_value//\$/\\\$}
    printf '%s="%s"\n' "$key" "$escaped_value" >> "$output_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$output_file"
  fi
}

stage_env_file() {
  local target_file=$1
  local format=$2
  shift 2

  local -a keys=()
  local -a values=()
  local -a counts=()
  local temporary_file
  local line
  local key
  local pattern
  local matched
  local index

  while (($# > 0)); do
    keys+=("$1")
    values+=("$2")
    counts[$(( ${#keys[@]} - 1 ))]=0
    shift 2
  done

  [[ ! -L "$target_file" ]] || die "refusing to update symlink: $target_file"
  [[ ! -e "$target_file" || -f "$target_file" ]] \
    || die "environment path is not a regular file: $target_file"

  temporary_file=$(mktemp "$config_dir/.env-update.XXXXXX") \
    || die "could not create a temporary file in $config_dir"
  staged_files+=("$temporary_file")
  target_files+=("$target_file")
  chmod 600 "$temporary_file"

  if [[ -f "$target_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      matched=0

      for ((index = 0; index < ${#keys[@]}; index++)); do
        key=${keys[$index]}
        pattern="^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*="

        if [[ "$line" =~ $pattern ]]; then
          counts[$index]=$((counts[$index] + 1))
          (( counts[$index] == 1 )) \
            || die "duplicate $key entries in $target_file; resolve duplicates before retrying"

          write_env_assignment "$temporary_file" "$format" "$key" "${values[$index]}"
          matched=1
          break
        fi
      done

      if (( matched == 0 )); then
        printf '%s\n' "$line" >> "$temporary_file"
      fi
    done < "$target_file"
  fi

  for ((index = 0; index < ${#keys[@]}; index++)); do
    key=${keys[$index]}
    if (( counts[$index] == 0 )); then
      write_env_assignment "$temporary_file" "$format" "$key" "${values[$index]}"
    fi
  done
}

stage_env_file "$config_dir/compose.env" compose \
  REDIS_PASSWORD "$redis_password"
stage_env_file "$config_dir/shortener.env" raw \
  REDIS_ADDR "$redis_addr" \
  REDIS_PASSWORD "$redis_password"
stage_env_file "$config_dir/napkin.env" raw \
  REDIS_ADDR "$redis_addr" \
  REDIS_PASSWORD "$redis_password"

for ((index = 1; index < ${#target_files[@]}; index++)); do
  mv -f -- "${staged_files[$index]}" "${target_files[$index]}" \
    || die "could not atomically replace ${target_files[$index]}"
  staged_files[$index]=''
done

printf 'Redis environment files were created or updated under %s/config (password omitted)\n' "$infra_dir"
