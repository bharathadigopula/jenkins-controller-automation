#!/usr/bin/env bash

#==============================================================================
# VERSIONED JENKINS BOOTSTRAP
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# BOOTSTRAP INPUTS
#==============================================================================

action="${1:-validate}"
automation_repository="${2:-}"
automation_ref="${3:-}"
jenkins_url="${4:-http://localhost:8080}"
bind_address="${5:-127.0.0.1}"
secret_bundle="${6:-}"

#==============================================================================
# ACTION VALIDATION
#==============================================================================

if [[ "$action" != "validate" && "$action" != "dry-run" && "$action" != "deploy" && "$action" != "verify" ]]; then
  printf 'Usage: %s validate|dry-run|deploy|verify repository ref url bind-address [secret]\n' "$0" >&2
  exit 2
fi

#==============================================================================
# REPOSITORY VALIDATION
#==============================================================================

if [[ ! "$automation_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'A GitHub owner/repository value is required.\n' >&2
  exit 1
fi

#==============================================================================
# RELEASE VALIDATION
#==============================================================================

if [[ ! "$automation_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'An immutable semantic version tag is required.\n' >&2
  exit 1
fi

#==============================================================================
# DEPLOYMENT PRIVILEGES
#==============================================================================

if [[ "$action" == "deploy" || "$action" == "verify" ]]; then
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true; then
    printf '%s requires non-interactive sudo access.\n' "$action" >&2
    exit 1
  fi
fi

#==============================================================================
# VERSIONED SOURCE DOWNLOAD
#==============================================================================

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
archive_url="https://github.com/$automation_repository/archive/refs/tags/$automation_ref.tar.gz"
curl --fail --location --silent --show-error "$archive_url" --output "$temporary_directory/automation.tar.gz"
mkdir "$temporary_directory/source"
tar --extract --gzip --file "$temporary_directory/automation.tar.gz" \
  --directory "$temporary_directory/source" --strip-components=1

#==============================================================================
# VERSIONED AUTOMATION EXECUTION
#==============================================================================

manage_environment=(
  "AUTOMATION_REF=$automation_ref"
  "JENKINS_URL=$jenkins_url"
  "JENKINS_BIND_ADDRESS=$bind_address"
)
manage_script="$temporary_directory/source/scripts/manage.sh"

if [[ "$action" == "deploy" ]]; then
  sudo -n bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  sudo -n env "${manage_environment[@]}" bash "$manage_script" "$action" "$secret_bundle"
elif [[ "$action" == "verify" ]]; then
  sudo -n env "${manage_environment[@]}" bash "$manage_script" "$action"
else
  bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  env "${manage_environment[@]}" bash "$manage_script" "$action" "$secret_bundle"
fi