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
  local agent_jnlp
  local agent_secret
  local attempt

  admin_password=$(< /run/secrets/jenkins_admin_password)
  if [[ -z "$admin_password" ]]; then
    printf 'Jenkins administrator credential is required for agent bootstrap.\n' >&2
    exit 1
  fi

  umask 077
  install -d -m 0700 "$secret_directory"
  for (( attempt = 1; attempt <= 60; attempt++ )); do
    if agent_jnlp=$(curl --fail --silent --show-error \
      --user "${JENKINS_ADMIN_ID:-admin}:$admin_password" \
      "${controller_url%/}/computer/${agent_name}/jenkins-agent.jnlp" 2>/dev/null); then
      agent_secret=$(grep -o '<argument>[^<]*</argument>' <<< "$agent_jnlp" | \
        sed -n '1{s#<argument>##;s#</argument>##;p;}')
      if [[ "$agent_secret" =~ ^[[:xdigit:]]{64}$ ]]; then
        printf '%s' "$agent_secret" > "$secret_file.tmp"
        mv "$secret_file.tmp" "$secret_file"
        chown -R 1000:1000 "$secret_directory"
        unset admin_password agent_jnlp agent_secret
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