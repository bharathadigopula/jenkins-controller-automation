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
  Dockerfile.agent
  compose.yaml
  plugins.txt
  jcasc/jenkins.yaml
  scripts/agent-entrypoint.sh
  scripts/check-latest-versions.sh
  systemd/jenkins-controller-backup.service
  systemd/jenkins-controller-backup.timer
  systemd/jenkins-controller-health.service
  systemd/jenkins-controller-health.timer
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
  "$repository_root/Dockerfile" "$repository_root/Dockerfile.agent" "$repository_root/compose.yaml"; then
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
# CONTROLLER AND AGENT ISOLATION VALIDATION
#==============================================================================

if ! grep -Fq 'numExecutors: 0' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'name: platform-agent' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'numExecutors: 1' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'labelString: platform docker' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq '.displayName == "platform-agent" and .numExecutors == 1 and .offline == false' "$repository_root/scripts/manage.sh"; then
  printf 'Build execution must use the single platform Docker agent, not the controller.\n' >&2
  exit 1
fi

controller_compose=$(sed -n '/^[[:space:]]*jenkins:/,/^[[:space:]]*platform-agent:/p' "$repository_root/compose.yaml")
agent_compose=$(sed -n '/^[[:space:]]*platform-agent:/,/^secrets:/p' "$repository_root/compose.yaml")
if grep -Fq '/var/run/docker.sock' <<< "$controller_compose" || \
  ! grep -Fq '/var/run/docker.sock' <<< "$agent_compose" || \
  ! grep -Fq 'cpus: "0.50"' <<< "$agent_compose" || \
  ! grep -Fq 'memory: 2048M' <<< "$agent_compose" || \
  ! grep -Fq -- "--groups \"\$docker_socket_gid\"" "$repository_root/scripts/agent-entrypoint.sh" || \
  ! grep -Fq -- '--reuid 1000' "$repository_root/scripts/agent-entrypoint.sh"; then
  printf 'Docker access and constrained resources must belong only to the platform agent.\n' >&2
  exit 1
fi

if ! grep -Fq 'hudson.model.DirectoryBrowserSupport.CSP=' "$repository_root/compose.yaml" || \
  ! grep -Eq '^ansicolor:[A-Za-z0-9._-]+$' "$repository_root/plugins.txt"; then
  printf 'Jenkins CSP and pinned ANSI console rendering must be enabled.\n' >&2
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

backup_function=$(sed -n '/backup_controller()/,/^}/p' "$repository_root/scripts/manage.sh")
if grep -Fq 'systemctl stop jenkins-controller.service' <<< "$backup_function" || \
  ! grep -Fq 'quietDown' <<< "$backup_function" || \
  ! grep -Fq 'cancelQuietDown' <<< "$backup_function" || \
  ! grep -Fq "cookie_jar=\$(mktemp)" <<< "$backup_function" || \
  ! grep -Fq -- "--cookie \"\$cookie_jar\"" <<< "$backup_function" || \
  ! grep -Fq -- "--cookie-jar \"\$cookie_jar\"" <<< "$backup_function" || \
  ! grep -Fq '.partial' <<< "$backup_function" || \
  ! grep -Fq 'EnvironmentFile=/opt/jenkins-controller/current/.env' "$repository_root/systemd/jenkins-controller-backup.service"; then
  printf 'Scheduled backups must remain online, preserve the CSRF session, drain executors, and publish archives atomically.\n' >&2
  exit 1
fi

if ! grep -Fq 'systemctl restart jenkins-controller.service' "$repository_root/scripts/manage.sh"; then
  printf 'Deployment must restart the Jenkins service to activate each immutable release.\n' >&2
  exit 1
fi

if ! grep -Fq 'systemctl enable --now jenkins-controller-health.timer' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'failures < 3' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins-controller-maintenance' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'systemctl restart jenkins-controller.service' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'EnvironmentFile=/opt/jenkins-controller/current/.env' "$repository_root/systemd/jenkins-controller-health.service" || \
  ! grep -Fq 'OnUnitInactiveSec=1m' "$repository_root/systemd/jenkins-controller-health.timer" || \
  grep -Fq 'Requires=jenkins-controller.service' "$repository_root/systemd/jenkins-controller-health.service"; then
  printf 'Jenkins health recovery must use a managed timer and consecutive failure threshold.\n' >&2
  exit 1
fi

if grep -Fq 'Requires=jenkins-controller.service' "$repository_root/systemd/jenkins-controller-backup.service"; then
  printf 'Jenkins backup must not be lifecycle-coupled to the controller service.\n' >&2
  exit 1
fi

if ! grep -Fq 'service_state" != "active' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'backup_timer_state" != "active' "$repository_root/scripts/manage.sh"; then
  printf 'Jenkins status must fail when the controller or backup timer is inactive.\n' >&2
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

if grep -Eq '^[[:space:]]*(crumbIssuer:|excludeClientIPFromCrumb:)' \
  "$repository_root/jcasc/jenkins.yaml"; then
  printf 'Jenkins 2.555.1 and newer reject the deprecated JCasC crumbIssuer configuration.\n' >&2
  exit 1
fi

if ! grep -Fq 'defaultVersion: v1.3.0' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'credentials('"'"'github-scm'"'"')' "$repository_root/jcasc/jenkins.yaml"; then
  printf 'JCasC must provision the pinned shared library and managed production jobs.\n' >&2
  exit 1
fi

for managed_job in \
  configure-production-jenkins \
  configure-production-monitoring \
  operate-production-oci-infrastructure \
  operate-production-host-network \
  operate-production-ingress-connector \
  validate-github-pipeline-templates \
  validate-jenkins-pipeline-templates \
  validate-shared-host-automation \
  validate-terraform-oci-modules; do
  if ! grep -Fq "pipelineJob('$managed_job')" "$repository_root/jcasc/jenkins.yaml"; then
    printf 'Missing repository-managed Jenkins job: %s\n' "$managed_job" >&2
    exit 1
  fi
done

for pipeline_path in \
  .jenkins/pipelines/jenkins-controller.groovy \
  .jenkins/pipelines/monitoring-stack.groovy \
  .jenkins/pipelines/host-network.groovy \
  .jenkins/pipelines/ingress-connector.groovy \
  .jenkins/pipelines/production-infrastructure.groovy \
  .jenkins/pipelines/validate.groovy; do
  if ! grep -Fq "scriptPath('$pipeline_path')" "$repository_root/jcasc/jenkins.yaml"; then
    printf 'Missing organized Jenkins pipeline path: %s\n' "$pipeline_path" >&2
    exit 1
  fi
done

for readiness_marker in \
  jenkins_service=ready \
  jenkins_authentication=ready \
  jenkins_metrics=ready \
  jenkins_configuration=ready \
  jenkins_jobs=ready \
  jenkins_backup_timer=ready \
  jenkins_health_timer=ready; do
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
  ! grep -Fq 'application/openmetrics-text' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq '%{size_download}' "$repository_root/scripts/manage.sh" || \
  ! grep -F 'wait_for_metrics ' "$repository_root/scripts/manage.sh" | \
    grep -Fq 'controller_origin/prometheus/'; then
  printf 'Jenkins metrics verification must validate non-empty Prometheus content.\n' >&2
  exit 1
fi

if ! grep -Fq 'X-Jenkins:' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_version=%s' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'journalctl --unit jenkins-controller.service' "$repository_root/scripts/manage.sh"; then
  printf 'Deployment must report build diagnostics and verify the running Jenkins version.\n' >&2
  exit 1
fi

if ! sed -n '/deploy_controller()/,/^}/p' "$repository_root/scripts/manage.sh" | \
  grep -Fq "touch \"\$maintenance_file\"" || \
  ! sed -n '/deploy_controller()/,/^}/p' "$repository_root/scripts/manage.sh" | \
    grep -Fq 'systemctl stop jenkins-controller-health.timer' || \
  ! sed -n '/deploy_controller()/,/^}/p' "$repository_root/scripts/manage.sh" | \
    grep -Fq "trap 'rm -f \"\$maintenance_file\"' EXIT"; then
  printf 'Deployment must suppress watchdog recovery until verification completes.\n' >&2
  exit 1
fi

if ! grep -Fq 'jenkins_metrics_http_code=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_metrics_content_type=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_metrics_size=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq -- '--max-time 10' "$repository_root/scripts/manage.sh"; then
  printf 'Status must report bounded Jenkins metrics response diagnostics.\n' >&2
  exit 1
fi

if [[ "$(grep -Fc "printf 'jenkins_deploy=ready" "$repository_root/scripts/manage.sh")" != "2" ]] || \
  [[ "$(grep -Fc "printf 'jenkins_test_restore=ready" "$repository_root/scripts/manage.sh")" != "2" ]] || \
  ! grep -Fq 'jenkins_metrics_wait=attempt_' "$repository_root/scripts/manage.sh"; then
  printf 'Long Jenkins lifecycle actions must retain required markers and bounded progress output.\n' >&2
  exit 1
fi

#==============================================================================
# VALIDATION RESULT
#==============================================================================

printf 'jenkins_validation=ready\n'