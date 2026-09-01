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
resource_root_url="${5:-http://jenkins-resources.localhost:8080}"
bind_address="${6:-127.0.0.1}"
restore_archive="${7:-}"
secret_bundle="${8:-}"
jenkins_authority=${jenkins_url#*://}
jenkins_host=${jenkins_authority%%:*}
resource_root_authority=${resource_root_url#*://}
resource_root_host=${resource_root_authority%%:*}

case "$action" in
  validate|dry-run|deploy|verify|status|scan|diagnose|backup|restore|rollback|test-restore) ;;
  *) printf 'Unsupported Jenkins lifecycle action.\n' >&2; exit 2 ;;
esac

if [[ ! "$automation_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'A GitHub owner/repository value is required.\n' >&2
  exit 1
fi

if [[ ! "$automation_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'An immutable semantic version tag is required.\n' >&2
  exit 1
fi

if [[ ! "$jenkins_url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ || \
  ! "$resource_root_url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ || \
  "$jenkins_host" == "$resource_root_host" ]]; then
  printf 'Jenkins and resource root URLs must use distinct valid hosts.\n' >&2
  exit 1
fi

if [[ "$action" != "validate" && "$action" != "dry-run" ]]; then
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
curl --fail --location --silent --show-error \
  "https://github.com/$automation_repository/archive/refs/tags/$automation_ref.tar.gz" \
  --output "$temporary_directory/automation.tar.gz"
mkdir "$temporary_directory/source"
tar --extract --gzip --file "$temporary_directory/automation.tar.gz" \
  --directory "$temporary_directory/source" --strip-components=1

#==============================================================================
# VERSIONED AUTOMATION EXECUTION
#==============================================================================

manage_script="$temporary_directory/source/scripts/manage.sh"
manage_environment=(
  env
  "AUTOMATION_REF=$automation_ref"
  "JENKINS_URL=$jenkins_url"
  "JENKINS_RESOURCE_ROOT_URL=$resource_root_url"
  "JENKINS_BIND_ADDRESS=$bind_address"
)

if [[ "$action" == "deploy" ]]; then
  sudo -n bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  printf 'jenkins_deploy=ready\n'
  sudo -n "${manage_environment[@]}" bash "$manage_script" "$action" "$secret_bundle"
elif [[ "$action" == "validate" || "$action" == "dry-run" ]]; then
  bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  "${manage_environment[@]}" bash "$manage_script" "$action"
else
  sudo -n "${manage_environment[@]}" "JENKINS_RESTORE_ARCHIVE=$restore_archive" bash "$manage_script" "$action"
fi