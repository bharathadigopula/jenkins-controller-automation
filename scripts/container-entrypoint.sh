#!/usr/bin/env bash

#==============================================================================
# JENKINS CONTAINER SECRET LOADER
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# SECRET EXPORTS
#==============================================================================

export JENKINS_ADMIN_PASSWORD
export GITHUB_TOKEN

JENKINS_ADMIN_PASSWORD=$(< /run/secrets/jenkins_admin_password)
GITHUB_TOKEN=$(< /run/secrets/github_token)

#==============================================================================
# SECRET VALIDATION
#==============================================================================

if [[ -z "$JENKINS_ADMIN_PASSWORD" || -z "$GITHUB_TOKEN" ]]; then
  printf 'Jenkins administrator and GitHub credentials are required.\n' >&2
  exit 1
fi

#==============================================================================
# NON ROOT CONTROLLER EXECUTION
#==============================================================================

exec setpriv \
  --reuid="$(id -u jenkins)" \
  --regid="$(id -g jenkins)" \
  --keep-groups \
  /usr/local/bin/jenkins.sh