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
export GITHUB_REGISTRY_TOKEN
export GITHUB_TOKEN

JENKINS_ADMIN_PASSWORD=$(< /run/secrets/jenkins_admin_password)
GITHUB_REGISTRY_TOKEN=$(< /run/secrets/github_registry_token)
GITHUB_TOKEN=$(< /run/secrets/github_token)

#==============================================================================
# SECRET VALIDATION
#==============================================================================

if [[ -z "$JENKINS_ADMIN_PASSWORD" || -z "$GITHUB_REGISTRY_TOKEN" || -z "$GITHUB_TOKEN" ]]; then
  printf 'Jenkins administrator, GitHub SCM, and registry credentials are required.\n' >&2
  exit 1
fi

#==============================================================================
# CONTROLLER EXECUTION
#==============================================================================

exec /usr/local/bin/jenkins.sh