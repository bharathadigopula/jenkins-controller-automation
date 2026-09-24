#!/usr/bin/env bash

#==============================================================================
# ISOLATED BACKUP CLEANUP REGRESSION TESTS
#==============================================================================

set -euo pipefail
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
export BACKUP_TEST_ROOT="$temporary_directory"
export BACKUP_TEST_SOURCE="$repository_root/scripts/manage.sh"

for scenario in success archive-failure terminated resume-failure; do
  export BACKUP_TEST_SCENARIO="$scenario"
  mkdir -p "$temporary_directory/$scenario/current/secrets"
  printf 'synthetic-test-only\n' > "$temporary_directory/$scenario/current/secrets/jenkins-admin-password"
  exit_code=0
  bash <<'SCRIPT' || exit_code=$?
set -Eeuo pipefail
trap 'printf "jenkins_failure=line_%s\n" "$LINENO"' ERR
install_root="$BACKUP_TEST_ROOT/$BACKUP_TEST_SCENARIO"
backup_directory="$install_root/backups"
backup_retention_days=7
maintenance_file="$install_root/maintenance"
require_root() { :; }
wait_for_endpoint() { :; }
docker() { printf '%s\n' "$install_root"; }
curl() {
  case "${*: -1}" in
    */crumbIssuer/api/json) printf '{"crumbRequestField":"test-crumb","crumb":"synthetic"}\n' ;;
    */quietDown) printf 'paused\n' >> "$install_root/actions" ;;
    */cancelQuietDown)
      if [[ "$BACKUP_TEST_SCENARIO" == resume-failure ]]; then return 22; fi
      printf 'resumed\n' >> "$install_root/actions" ;;
    */computer/api/json*) printf '{"busyExecutors":0}\n' ;;
    */api/json*) printf '{"quietingDown":false}\n' ;;
    *) printf 'Unexpected mock request\n' >&2; return 1 ;;
  esac
}
tar() {
  case "$BACKUP_TEST_SCENARIO" in
    archive-failure) return 2 ;;
    terminated) sh -c 'kill -TERM "$PPID"' ;;
    success|resume-failure) touch "$archive_staging_path" ;;
  esac
}
eval "$(sed -n '/^backup_controller() {/,/^}/p' "$BACKUP_TEST_SOURCE")"
backup_controller
SCRIPT
  if [[ "$scenario" == success ]]; then
    [[ "$exit_code" == 0 ]]
  else
    [[ "$exit_code" != 0 ]]
  fi
  [[ $(grep -c '^paused$' "$temporary_directory/$scenario/actions") == 1 ]]
  if [[ "$scenario" == resume-failure ]]; then
    [[ -f "$temporary_directory/$scenario/maintenance" ]]
    if grep -q '^resumed$' "$temporary_directory/$scenario/actions"; then exit 1; fi
  else
    [[ $(grep -c '^resumed$' "$temporary_directory/$scenario/actions") == 1 ]]
    [[ ! -f "$temporary_directory/$scenario/maintenance" ]]
  fi
  printf 'backup_cleanup_%s=ready\n' "$scenario"
done