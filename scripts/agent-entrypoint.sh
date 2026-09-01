#!/usr/bin/env bash

#==============================================================================
# JENKINS PLATFORM AGENT BOOTSTRAP
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# AGENT SETTINGS
#==============================================================================

agent_name=${JENKINS_AGENT_NAME:-platform-agent}
controller_url=${JENKINS_URL:-http://jenkins:8080}
secret_directory=/run/jenkins-agent-secret
secret_file=$secret_directory/secret

#==============================================================================
# REMOTING SECRET BOOTSTRAP
#==============================================================================

bootstrap_agent() {
  local admin_password
  local agent_secret
  local attempt
  local cookie_jar
  local crumb
  local crumb_field
  local crumb_response

  admin_password=$(< /run/secrets/jenkins_admin_password)
  if [[ -z "$admin_password" ]]; then
    printf 'Jenkins administrator credential is required for agent bootstrap.\n' >&2
    exit 1
  fi

  umask 077
  install -d -m 0700 "$secret_directory"
  if [[ ! "$agent_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    printf 'Jenkins agent name is invalid.\n' >&2
    exit 1
  fi
  cookie_jar=$(mktemp)
  trap 'rm -f "$cookie_jar"' EXIT
  for (( attempt = 1; attempt <= 60; attempt++ )); do
    if crumb_response=$(curl --fail --silent --show-error \
      --user "${JENKINS_ADMIN_ID:-admin}:$admin_password" \
      --cookie "$cookie_jar" \
      --cookie-jar "$cookie_jar" \
      "${controller_url%/}/crumbIssuer/api/json" 2>/dev/null); then
      crumb_field=$(sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p' <<< "$crumb_response")
      crumb=$(sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' <<< "$crumb_response")
      agent_secret=$(curl --fail --silent --show-error \
        --user "${JENKINS_ADMIN_ID:-admin}:$admin_password" \
        --cookie "$cookie_jar" \
        --header "$crumb_field:$crumb" \
        --data-urlencode "script=print(jenkins.model.Jenkins.get().getComputer('${agent_name}').getJnlpMac())" \
        "${controller_url%/}/scriptText" 2>/dev/null || true)
      if [[ "$agent_secret" =~ ^[[:xdigit:]]{64}$ ]]; then
        printf '%s' "$agent_secret" > "$secret_file.tmp"
        mv "$secret_file.tmp" "$secret_file"
        chown -R 1000:1000 "$secret_directory"
        rm -f "$cookie_jar"
        trap - EXIT
        unset admin_password agent_secret crumb crumb_field crumb_response
        printf 'jenkins_agent_bootstrap=ready\n'
        return 0
      fi
    fi
    sleep 2
  done

  printf 'Jenkins agent secret could not be retrieved.\n' >&2
  exit 1
}

#==============================================================================
# PLATFORM AGENT EXECUTION
#==============================================================================

run_agent() {
  local docker_socket_gid

  if [[ ! -s "$secret_file" ]]; then
    printf 'Jenkins agent secret is unavailable.\n' >&2
    exit 1
  fi
  if [[ ! -S /var/run/docker.sock ]]; then
    printf 'Docker socket is unavailable.\n' >&2
    exit 1
  fi

  export JENKINS_SECRET
  JENKINS_SECRET=$(< "$secret_file")
  docker_socket_gid=$(stat --format '%g' /var/run/docker.sock)
  export HOME=/home/jenkins
  exec setpriv \
    --reuid 1000 \
    --regid 1000 \
    --groups "$docker_socket_gid" \
    --no-new-privs \
    /usr/local/bin/jenkins-agent
}

#==============================================================================
# ENTRYPOINT DISPATCH
#==============================================================================

case "${1:-run}" in
  bootstrap)
    bootstrap_agent
    ;;
  run)
    run_agent
    ;;
  *)
    exec "$@"
    ;;
esac