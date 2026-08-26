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

bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
AUTOMATION_REF="$automation_ref" \
JENKINS_URL="$jenkins_url" \
JENKINS_BIND_ADDRESS="$bind_address" \
  bash "$temporary_directory/source/scripts/manage.sh" "$action" "$secret_bundle"