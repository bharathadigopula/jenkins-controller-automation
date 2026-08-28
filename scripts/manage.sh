#!/usr/bin/env bash

#==============================================================================
# JENKINS CONTROLLER LIFECYCLE
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# LIFECYCLE INPUTS
#==============================================================================

action="${1:-validate}"
secret_bundle="${2:-}"
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install_root="${JENKINS_INSTALL_ROOT:-/opt/jenkins-controller}"
release_ref="${AUTOMATION_REF:-local}"
release_key=${release_ref//[^a-zA-Z0-9._-]/-}
release_path="$install_root/releases/$release_key"
backup_directory="${JENKINS_BACKUP_DIRECTORY:-/var/backups/jenkins-controller}"
backup_retention_days="${JENKINS_BACKUP_RETENTION_DAYS:-7}"
health_failure_file="${JENKINS_HEALTH_FAILURE_FILE:-/run/jenkins-controller-health-failures}"
maintenance_file="${JENKINS_MAINTENANCE_FILE:-/run/jenkins-controller-maintenance}"

#==============================================================================
# CONTROLLER VALIDATION
#==============================================================================

validate_controller() {
  bash "$source_root/scripts/validate.sh"
}

#==============================================================================
# ROOT PRIVILEGE VALIDATION
#==============================================================================

require_root() {
  if (( EUID != 0 )); then
    printf '%s must run as root.\n' "$action" >&2
    exit 1
  fi
}

#==============================================================================
# RELEASE ENVIRONMENT
#==============================================================================

write_environment() {
  docker_gid=$(stat --format '%g' /var/run/docker.sock)
  cat > "$release_path/.env" <<EOF
DOCKER_GID=$docker_gid
GITHUB_TOKEN_FILE=./secrets/github-token
JENKINS_ADMIN_ID=${JENKINS_ADMIN_ID:-admin}
JENKINS_ADMIN_PASSWORD_FILE=./secrets/jenkins-admin-password
JENKINS_BIND_ADDRESS=${JENKINS_BIND_ADDRESS:-127.0.0.1}
JENKINS_CONTROLLER_VERSION=2.568.2-lts-jdk21
JENKINS_URL=${JENKINS_URL:-http://localhost:8080}
EOF
  chmod 0600 "$release_path/.env"
}

#==============================================================================
# CONTROLLER DEPLOYMENT
#==============================================================================

deploy_controller() {
  require_root
  if ! jq -e '
    type == "object" and
    (.admin_password | type == "string" and length >= 16 and (contains("\n") | not)) and
    (.github_token | type == "string" and length >= 20 and (contains("\n") | not))
  ' <<< "$secret_bundle" >/dev/null; then
    printf 'Secret bundle must contain admin_password and github_token.\n' >&2
    exit 1
  fi

  validate_controller
  docker compose version >/dev/null
  install -d -m 0755 "$install_root/releases"
  rm -rf "$release_path"
  install -d -m 0755 "$release_path"
  cp -a "$source_root/." "$release_path/"
  install -d -m 0700 "$release_path/secrets"
  jq -r '.admin_password' <<< "$secret_bundle" > "$release_path/secrets/jenkins-admin-password"
  jq -r '.github_token' <<< "$secret_bundle" > "$release_path/secrets/github-token"
  chown 1000:1000 "$release_path/secrets/jenkins-admin-password" "$release_path/secrets/github-token"
  chmod 0400 "$release_path/secrets/jenkins-admin-password" "$release_path/secrets/github-token"
  write_environment

  if [[ -L "$install_root/current" ]]; then
    ln -sfn "$(readlink -f "$install_root/current")" "$install_root/previous"
  fi

  ln -sfn "$release_path" "$install_root/current"
  install -m 0644 "$release_path/systemd/jenkins-controller.service" /etc/systemd/system/jenkins-controller.service
  install -m 0644 "$release_path/systemd/jenkins-controller-backup.service" /etc/systemd/system/jenkins-controller-backup.service
  install -m 0644 "$release_path/systemd/jenkins-controller-backup.timer" /etc/systemd/system/jenkins-controller-backup.timer
  install -m 0644 "$release_path/systemd/jenkins-controller-health.service" /etc/systemd/system/jenkins-controller-health.service
  install -m 0644 "$release_path/systemd/jenkins-controller-health.timer" /etc/systemd/system/jenkins-controller-health.timer
  systemctl daemon-reload
  systemctl enable jenkins-controller.service
  touch "$maintenance_file"
  rm -f "$health_failure_file"
  trap 'rm -f "$maintenance_file"' EXIT
  systemctl stop jenkins-controller-health.timer >/dev/null 2>&1 || true
  if ! systemctl restart jenkins-controller.service; then
    journalctl --unit jenkins-controller.service --no-pager --lines 200 >&2
    return 1
  fi
  systemctl enable --now jenkins-controller-backup.timer
  systemctl enable --now jenkins-controller-health.timer
  printf 'jenkins_deploy=ready\n'
  verify_controller
  rm -f "$maintenance_file"
  trap - EXIT
  printf 'jenkins_deploy=ready\n'
}

#==============================================================================
# CONTROLLER HEALTH VERIFICATION
#==============================================================================

wait_for_endpoint() {
  local endpoint="$1"
  local password_file="${2:-}"
  local attempt

  for (( attempt = 1; attempt <= 120; attempt++ )); do
    if [[ -n "$password_file" ]] && curl --fail --silent --show-error \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$password_file")" "$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -z "$password_file" ]] && curl --fail --silent --show-error "$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  printf 'Jenkins did not become ready at %s.\n' "$endpoint" >&2
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps >&2 || true
  return 1
}

wait_for_metrics() {
  local endpoint="$1"
  local password_file="$2"
  local attempt
  local metrics_content_type="unavailable"
  local metrics_details
  local metrics_size="0"

  printf 'jenkins_metrics_wait=started\n'
  for (( attempt = 1; attempt <= 120; attempt++ )); do
    if metrics_details=$(curl --fail --silent --show-error --output /dev/null \
      --write-out $'%{content_type}\n%{size_download}' \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$password_file")" "$endpoint" 2>/dev/null); then
      metrics_content_type=${metrics_details%%$'\n'*}
      metrics_size=${metrics_details##*$'\n'}
      if [[ "$metrics_content_type" =~ ^(text/plain|application/openmetrics-text)(\;|$) && \
        "$metrics_size" =~ ^[0-9]+$ && "$metrics_size" != "0" ]]; then
        return 0
      fi
    fi
    if (( attempt % 6 == 0 )); then
      printf 'jenkins_metrics_wait=attempt_%s\n' "$attempt"
    fi
    sleep 5
  done

  printf 'Jenkins Prometheus metrics did not become ready: content_type=%q size=%s.\n' \
    "$metrics_content_type" "$metrics_size" >&2
  return 1
}

show_controller_diagnostics() {
  local container_id

  container_id=$(docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --all --quiet jenkins)
  if [[ -n "$container_id" ]]; then
    docker inspect --format 'jenkins_container={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' \
      "$container_id" >&2 || true
  fi
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    logs --no-color --tail 20 jenkins >&2 || true
}

verify_controller() {
  local anonymous_status
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local controller_jobs
  local expected_controller_image
  local expected_controller_version
  local running_controller_version

  if [[ "$(docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --services --filter status=running | sort)" != "jenkins" ]]; then
    printf 'Jenkins Compose service is not running.\n' >&2
    show_controller_diagnostics
    return 1
  fi

  wait_for_endpoint "$controller_origin/login"
  expected_controller_image=$(sed -n 's/^JENKINS_CONTROLLER_VERSION=//p' "$install_root/current/.env")
  expected_controller_version=${expected_controller_image%-lts-jdk21}
  running_controller_version=$(curl --fail --silent --show-error \
    --dump-header - --output /dev/null "$controller_origin/login" | \
    tr -d '\r' | sed -n 's/^X-Jenkins:[[:space:]]*//Ip' | tail -n 1)
  if [[ "$running_controller_version" != "$expected_controller_version" ]]; then
    printf 'Running Jenkins version %s does not match active release %s.\n' \
      "${running_controller_version:-unknown}" "$expected_controller_version" >&2
    return 1
  fi
  wait_for_metrics "$controller_origin/prometheus/" "$admin_password_file"
  anonymous_status=$(curl --silent --output /dev/null --write-out '%{http_code}' "$controller_origin/manage")
  if [[ "$anonymous_status" != "403" ]]; then
    printf 'Anonymous Jenkins management access returned HTTP %s instead of 403.\n' "$anonymous_status" >&2
    return 1
  fi
  if ! docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    exec --no-TTY jenkins test -f /var/jenkins_home/jenkins.install.InstallUtil.lastExecVersion; then
    printf 'Jenkins initialization state is unavailable.\n' >&2
    return 1
  fi
  if ! docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    exec --no-TTY jenkins sh -c \
      "grep -Fq '<id>github-token</id>' /var/jenkins_home/credentials.xml && grep -Fq '<id>github-scm</id>' /var/jenkins_home/credentials.xml"; then
    printf 'Jenkins managed credentials were not provisioned.\n' >&2
    return 1
  fi
  controller_jobs=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/api/json?tree=jobs[name]")
  if ! jq -e '
    [.jobs[].name] as $jobs |
    ($jobs | index("configure-production-jenkins")) != null and
    ($jobs | index("configure-production-monitoring")) != null
  ' <<< "$controller_jobs" >/dev/null; then
    printf 'Jenkins managed production jobs were not provisioned.\n' >&2
    return 1
  fi
  if ! systemctl is-enabled --quiet jenkins-controller-backup.timer || \
    ! systemctl is-active --quiet jenkins-controller-backup.timer; then
    printf 'Jenkins backup timer is not enabled and active.\n' >&2
    return 1
  fi
  if [[ -f "$install_root/current/systemd/jenkins-controller-health.timer" ]]; then
    if ! systemctl is-enabled --quiet jenkins-controller-health.timer || \
      ! systemctl is-active --quiet jenkins-controller-health.timer; then
      printf 'Jenkins health timer is not enabled and active.\n' >&2
      return 1
    fi
    printf 'jenkins_health_timer=ready\n'
  fi
  printf 'jenkins_service=ready\n'
  printf 'jenkins_version=%s\n' "$running_controller_version"
  printf 'jenkins_authentication=ready\n'
  printf 'jenkins_metrics=ready\n'
  printf 'jenkins_configuration=ready\n'
  printf 'jenkins_jobs=ready\n'
  printf 'jenkins_backup_timer=ready\n'
  printf 'jenkins_verify=ready\n'
}

#==============================================================================
# CONTROLLER BACKUP
#==============================================================================

backup_controller() {
  require_root
  install -d -m 0700 "$backup_directory"
  archive_path="$backup_directory/jenkins-home-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  volume_path=$(docker volume inspect jenkins-controller_jenkins-home --format '{{ .Mountpoint }}')
  touch "$maintenance_file"
  systemctl stop jenkins-controller.service
  trap 'systemctl start jenkins-controller.service; rm -f "$maintenance_file"' EXIT
  tar --create --gzip --file "$archive_path" --directory "$volume_path" .
  chmod 0600 "$archive_path"
  systemctl start jenkins-controller.service
  rm -f "$maintenance_file"
  trap - EXIT
  find "$backup_directory" -maxdepth 1 -type f -name 'jenkins-home-*.tar.gz' \
    -mtime "+$backup_retention_days" -delete
  printf 'jenkins_backup_archive=%s\n' "$archive_path"
  printf 'jenkins_backup=ready\n'
}

#==============================================================================
# CONTROLLER RESTORE
#==============================================================================

restore_controller() {
  require_root
  archive_path="${JENKINS_RESTORE_ARCHIVE:-}"
  if [[ ! "$archive_path" =~ ^${backup_directory}/jenkins-home-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ || ! -f "$archive_path" ]]; then
    printf 'JENKINS_RESTORE_ARCHIVE must identify an existing managed backup.\n' >&2
    exit 1
  fi
  volume_path=$(docker volume inspect jenkins-controller_jenkins-home --format '{{ .Mountpoint }}')
  touch "$maintenance_file"
  systemctl stop jenkins-controller.service
  trap 'systemctl start jenkins-controller.service; rm -f "$maintenance_file"' EXIT
  find "$volume_path" -mindepth 1 -delete
  tar --extract --gzip --file "$archive_path" --directory "$volume_path"
  systemctl start jenkins-controller.service
  rm -f "$maintenance_file"
  trap - EXIT
  verify_controller
  printf 'jenkins_restore=ready\n'
}

#==============================================================================
# CONTROLLED RESTORE TEST
#==============================================================================

test_restore_controller() {
  backup_controller
  printf 'jenkins_test_restore=ready\n'
  JENKINS_RESTORE_ARCHIVE="$archive_path" restore_controller
  printf 'jenkins_test_restore=ready\n'
}

#==============================================================================
# CONTROLLER HEALTH RECOVERY
#==============================================================================

recover_controller() {
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local failures=0

  require_root
  if [[ -f "$maintenance_file" ]]; then
    rm -f "$health_failure_file"
    printf 'jenkins_health=maintenance\n'
    return 0
  fi
  if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    "$controller_origin/login" >/dev/null 2>&1; then
    rm -f "$health_failure_file"
    printf 'jenkins_health=ready\n'
    return 0
  fi

  if [[ -f "$health_failure_file" ]]; then
    failures=$(<"$health_failure_file")
    if [[ ! "$failures" =~ ^[0-9]+$ ]]; then
      failures=0
    fi
  fi
  failures=$((failures + 1))
  printf '%s\n' "$failures" > "$health_failure_file"

  if (( failures < 3 )); then
    printf 'jenkins_health=degraded failure_count=%s\n' "$failures"
    return 0
  fi

  printf 'jenkins_health=restarting failure_count=%s\n' "$failures"
  systemctl restart jenkins-controller.service
  wait_for_endpoint "$controller_origin/login"
  rm -f "$health_failure_file"
  printf 'jenkins_health=recovered\n'
}

#==============================================================================
# CONTROLLER STATUS
#==============================================================================

status_controller() {
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local service_state
  local backup_timer_state
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local health_timer_state
  local running_controller_version

  service_state=$(systemctl is-active jenkins-controller.service || true)
  backup_timer_state=$(systemctl is-active jenkins-controller-backup.timer || true)
  health_timer_state=unavailable
  if [[ -f "$install_root/current/systemd/jenkins-controller-health.timer" ]]; then
    health_timer_state=$(systemctl is-active jenkins-controller-health.timer || true)
  fi

  printf 'jenkins_status=ready\n'
  printf 'jenkins_systemd=%s\n' "$service_state"
  printf 'jenkins_backup_timer=%s\n' "$backup_timer_state"
  printf 'jenkins_health_timer=%s\n' "$health_timer_state"
  running_controller_version=$(curl --connect-timeout 3 --max-time 10 --silent --show-error \
    --dump-header - --output /dev/null "$controller_origin/login" 2>/dev/null | \
    tr -d '\r' | sed -n 's/^X-Jenkins:[[:space:]]*//Ip' | tail -n 1)
  printf 'jenkins_version=%s\n' "${running_controller_version:-unavailable}"
  if [[ -r "$admin_password_file" ]]; then
    curl --connect-timeout 3 --max-time 10 --silent --show-error \
      --output /dev/null \
      --write-out $'jenkins_metrics_http_code=%{http_code}\njenkins_metrics_content_type=%{content_type}\njenkins_metrics_size=%{size_download}\njenkins_metrics_redirect=%{redirect_url}\n' \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
      "$controller_origin/prometheus/" 2>/dev/null || printf 'jenkins_metrics_probe=failed\n'
  else
    printf 'jenkins_metrics_probe=missing_password_file\n'
  fi
  show_controller_diagnostics

  if [[ "$service_state" != "active" || "$backup_timer_state" != "active" || \
    "$health_timer_state" == "inactive" || "$health_timer_state" == "failed" ]]; then
    printf 'Jenkins controller or a managed timer is not active.\n' >&2
    return 1
  fi
}

#==============================================================================
# CONTROLLER ROLLBACK
#==============================================================================

rollback_controller() {
  require_root
  if [[ ! -L "$install_root/previous" ]]; then
    printf 'No previous Jenkins release is available.\n' >&2
    exit 1
  fi
  previous_release=$(readlink -f "$install_root/previous")
  current_release=$(readlink -f "$install_root/current")
  systemctl disable --now jenkins-controller-health.timer >/dev/null 2>&1 || true
  ln -sfn "$previous_release" "$install_root/current"
  ln -sfn "$current_release" "$install_root/previous"

  if [[ -f "$previous_release/systemd/jenkins-controller-health.service" && \
    -f "$previous_release/systemd/jenkins-controller-health.timer" ]]; then
    install -m 0644 "$previous_release/systemd/jenkins-controller-health.service" /etc/systemd/system/jenkins-controller-health.service
    install -m 0644 "$previous_release/systemd/jenkins-controller-health.timer" /etc/systemd/system/jenkins-controller-health.timer
    systemctl daemon-reload
    systemctl enable --now jenkins-controller-health.timer
  else
    rm -f /etc/systemd/system/jenkins-controller-health.service /etc/systemd/system/jenkins-controller-health.timer
    systemctl daemon-reload
  fi

  systemctl restart jenkins-controller.service
  verify_controller
  printf 'jenkins_rollback=ready\n'
}

#==============================================================================
# ACTION ROUTING
#==============================================================================

case "$action" in
  validate)
    validate_controller
    ;;
  dry-run)
    validate_controller
    printf 'Would deploy release %s to %s.\n' "$release_ref" "$release_path"
    printf 'jenkins_dry_run=ready\n'
    ;;
  deploy|upgrade)
    deploy_controller
    ;;
  verify)
    verify_controller
    ;;
  status)
    status_controller
    ;;
  recover)
    recover_controller
    ;;
  backup)
    backup_controller
    ;;
  restore)
    restore_controller
    ;;
  rollback)
    rollback_controller
    ;;
  test-restore)
    test_restore_controller
    ;;
  *)
    printf 'Unsupported Jenkins lifecycle action: %s\n' "$action" >&2
    exit 2
    ;;
esac