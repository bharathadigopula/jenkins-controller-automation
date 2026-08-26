#!/usr/bin/env bash

#==============================================================================
# JENKINS CONTROLLER VALIDATION
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# REQUIRED CONTROLLER FILES
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
required_files=(
  Dockerfile
  compose.yaml
  plugins.txt
  jcasc/jenkins.yaml
  systemd/jenkins-controller.service
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$repository_root/$required_file" ]]; then
    printf 'Missing required file: %s\n' "$required_file" >&2
    exit 1
  fi
done

#==============================================================================
# CONTAINER IMAGE VALIDATION
#==============================================================================

if grep -R --line-number --extended-regexp '(FROM|image:)[[:space:]]+[^[:space:]]+:latest([[:space:]]|$)' \
  "$repository_root/Dockerfile" "$repository_root/compose.yaml"; then
  printf 'Container images must use pinned version tags.\n' >&2
  exit 1
fi

#==============================================================================
# PLUGIN CATALOGUE VALIDATION
#==============================================================================

if ! awk -F: '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 2 || $1 !~ /^[a-z0-9-]+$/ || $2 !~ /^[A-Za-z0-9._-]+$/ { invalid = 1 }
  END { exit invalid }
' "$repository_root/plugins.txt"; then
  printf 'Every Jenkins plugin must use an explicit version.\n' >&2
  exit 1
fi

if [[ "$(grep -vE '^[[:space:]]*(#|$)' "$repository_root/plugins.txt" | cut -d: -f1 | sort | uniq -d | wc -l | tr -d ' ')" != "0" ]]; then
  printf 'Duplicate Jenkins plugin identifiers are not allowed.\n' >&2
  exit 1
fi

#==============================================================================
# SECRET BUNDLE VALIDATION
#==============================================================================

valid_secret_bundle='{"admin_password":"0123456789abcdef","github_token":"github-token-at-least-twenty"}'
invalid_secret_bundle='{"admin_password":"short","github_token":"short"}'
secret_filter='
  type == "object" and
  (.admin_password | type == "string" and length >= 16 and (contains("\n") | not)) and
  (.github_token | type == "string" and length >= 20 and (contains("\n") | not))
'

jq -e "$secret_filter" <<< "$valid_secret_bundle" >/dev/null
if jq -e "$secret_filter" <<< "$invalid_secret_bundle" >/dev/null; then
  printf 'Invalid Jenkins secret bundle was accepted.\n' >&2
  exit 1
fi

#==============================================================================
# DOCKER COMPOSE VALIDATION
#==============================================================================

if docker compose version >/dev/null 2>&1; then
  temporary_directory=$(mktemp -d)
  trap 'rm -rf "$temporary_directory"' EXIT
  printf 'validation-only\n' > "$temporary_directory/admin"
  printf 'validation-only\n' > "$temporary_directory/github"
  JENKINS_ADMIN_PASSWORD_FILE="$temporary_directory/admin" \
  GITHUB_TOKEN_FILE="$temporary_directory/github" \
    docker compose --file "$repository_root/compose.yaml" config --quiet
fi

  #==============================================================================
  # VALIDATION RESULT
  #==============================================================================

printf 'jenkins_validation=ready\n'