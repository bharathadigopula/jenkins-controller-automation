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
  systemd/jenkins-controller-backup.service
  systemd/jenkins-controller-backup.timer
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

if ! grep -Fq 'USER jenkins' "$repository_root/Dockerfile" || \
  ! grep -Fq 'chown 1000:1000 ' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'chmod 0400 ' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'secrets/jenkins-admin-password' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'secrets/github-token' "$repository_root/scripts/manage.sh"; then
  printf 'Root-managed Jenkins secret files must be readable only by container UID 1000.\n' >&2
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
# MANAGED BACKUP VALIDATION
#==============================================================================

if ! grep -Fq 'jenkins-controller-backup.timer' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'JENKINS_BACKUP_RETENTION_DAYS' "$repository_root/scripts/manage.sh"; then
  printf 'Jenkins backup scheduling and retention must be managed in versioned automation.\n' >&2
  exit 1
fi

if ! grep -Fq 'systemctl restart jenkins-controller.service' "$repository_root/scripts/manage.sh"; then
  printf 'Deployment must restart the Jenkins service to activate each immutable release.\n' >&2
  exit 1
fi

#==============================================================================
# OCI OUTPUT BUDGET VALIDATION
#==============================================================================

if ! grep -Fq 'apt-get update >/dev/null' "$repository_root/scripts/install-docker.sh" || \
  ! grep -Fq 'docker version >/dev/null' "$repository_root/scripts/install-docker.sh" || \
  ! grep -Fq 'docker compose version >/dev/null' "$repository_root/scripts/install-docker.sh"; then
  printf 'Routine installer output must remain quiet so OCI retains diagnostics.\n' >&2
  exit 1
fi

#==============================================================================
# OCI BOOTSTRAP PAYLOAD VALIDATION
#==============================================================================

sample_arguments=$(jq -cn '[
  "deploy",
  "bharathadigopula/jenkins-controller-automation",
  "v1.0.7",
  "https://jenkins.bharathcloudops.com",
  "10.10.10.68",
  "",
  "{\"admin_password\":\"AAAAAAAAAAAAAAAAAAAAAAAA\",\"github_token\":\"github-token-at-least-twenty\"}"
]')
argument_line=$(jq -r '[.[] | @sh] | "set -- " + join(" ")' <<< "$sample_arguments")
rendered_size=$(printf '%s\n%s' "$argument_line" "$(cat "$repository_root/scripts/bootstrap.sh")" | wc -c | tr -d ' ')
if (( rendered_size > 4096 )); then
  printf 'Rendered Jenkins bootstrap exceeds the OCI 4096-byte inline limit.\n' >&2
  exit 1
fi

#==============================================================================
# COMPREHENSIVE VERIFICATION VALIDATION
#==============================================================================

for readiness_marker in \
  jenkins_service=ready \
  jenkins_authentication=ready \
  jenkins_metrics=ready \
  jenkins_configuration=ready \
  jenkins_backup_timer=ready; do
  if ! grep -Fq "$readiness_marker" "$repository_root/scripts/manage.sh"; then
    printf 'Missing Jenkins verification marker: %s\n' "$readiness_marker" >&2
    exit 1
  fi
done

if ! grep -Fq -- '--user ' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'admin_password_file' "$repository_root/scripts/manage.sh" || \
  ! grep -F 'local controller_origin=' "$repository_root/scripts/manage.sh" | \
    grep -Fq 'JENKINS_BIND_ADDRESS'; then
  printf 'Protected Jenkins metrics must use the managed administrator credential.\n' >&2
  exit 1
fi

if ! grep -Fq 'controller_origin/prometheus/' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "grep -Fq 'default_jenkins_version'" "$repository_root/scripts/manage.sh"; then
  printf 'Jenkins metrics verification must follow the pinned Prometheus plugin contract.\n' >&2
  exit 1
fi

#==============================================================================
# VALIDATION RESULT
#==============================================================================

printf 'jenkins_validation=ready\n'