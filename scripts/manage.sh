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
JENKINS_CONTROLLER_VERSION=2.528.3-lts-jdk21
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
  chmod 0600 "$release_path/secrets/jenkins-admin-password" "$release_path/secrets/github-token"
  write_environment

  if [[ -L "$install_root/current" ]]; then
    ln -sfn "$(readlink -f "$install_root/current")" "$install_root/previous"
  fi

  ln -sfn "$release_path" "$install_root/current"
  install -m 0644 "$release_path/systemd/jenkins-controller.service" /etc/systemd/system/jenkins-controller.service
  systemctl daemon-reload
  systemctl enable --now jenkins-controller.service
  verify_controller
  printf 'jenkins_deploy=ready\n'
}

#==============================================================================
# CONTROLLER HEALTH VERIFICATION
#==============================================================================

verify_controller() {
  curl --fail --silent --show-error http://127.0.0.1:8080/login >/dev/null
  curl --fail --silent --show-error http://127.0.0.1:8080/prometheus >/dev/null
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
  systemctl stop jenkins-controller.service
  trap 'systemctl start jenkins-controller.service' EXIT
  tar --create --gzip --file "$archive_path" --directory "$volume_path" .
  chmod 0600 "$archive_path"
  systemctl start jenkins-controller.service
  trap - EXIT
  printf 'jenkins_backup=%s\n' "$archive_path"
}

#==============================================================================
# CONTROLLER RESTORE
#==============================================================================

restore_controller() {
  require_root
  archive_path="${JENKINS_RESTORE_ARCHIVE:-}"
  if [[ ! -f "$archive_path" ]]; then
    printf 'JENKINS_RESTORE_ARCHIVE must identify an existing backup.\n' >&2
    exit 1
  fi
  volume_path=$(docker volume inspect jenkins-controller_jenkins-home --format '{{ .Mountpoint }}')
  systemctl stop jenkins-controller.service
  trap 'systemctl start jenkins-controller.service' EXIT
  find "$volume_path" -mindepth 1 -delete
  tar --extract --gzip --file "$archive_path" --directory "$volume_path"
  systemctl start jenkins-controller.service
  trap - EXIT
  verify_controller
  printf 'jenkins_restore=ready\n'
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
  ln -sfn "$previous_release" "$install_root/current"
  ln -sfn "$current_release" "$install_root/previous"
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
  backup)
    backup_controller
    ;;
  restore)
    restore_controller
    ;;
  rollback)
    rollback_controller
    ;;
  *)
    printf 'Usage: %s validate|dry-run|deploy|upgrade|verify|backup|restore|rollback [secret-json]\n' "$0" >&2
    exit 2
    ;;
esac