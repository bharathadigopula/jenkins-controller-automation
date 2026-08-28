#!/usr/bin/env bash

#==============================================================================
# LATEST VERSION PIN VALIDATION
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# REPOSITORY PATHS
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

#==============================================================================
# JENKINS CORE VALIDATION
#==============================================================================

latest_jenkins_version=$(curl --fail --location --silent --show-error \
  https://updates.jenkins.io/stable/latestCore.txt)
pinned_jenkins_image=$(sed -n 's/^FROM jenkins\/jenkins:\([^[:space:]]*\)$/\1/p' \
  "$repository_root/Dockerfile")
pinned_jenkins_version=${pinned_jenkins_image%-lts-jdk21}

if [[ "$pinned_jenkins_version" != "$latest_jenkins_version" ]]; then
  printf 'Jenkins LTS pin %s is not latest stable %s.\n' \
    "$pinned_jenkins_version" "$latest_jenkins_version" >&2
  exit 1
fi

for version_file in \
  "$repository_root/.env.example" \
  "$repository_root/compose.yaml" \
  "$repository_root/scripts/manage.sh"; do
  if ! grep -Fq "$pinned_jenkins_image" "$version_file"; then
    printf 'Jenkins image pin %s is inconsistent in %s.\n' \
      "$pinned_jenkins_image" "$version_file" >&2
    exit 1
  fi
done

#==============================================================================
# JENKINS PLUGIN VALIDATION
#==============================================================================

update_center_file="$temporary_directory/update-center.json"
curl --fail --location --silent --show-error \
  https://updates.jenkins.io/stable/update-center.actual.json \
  --output "$update_center_file"

while IFS=: read -r plugin_name pinned_plugin_version; do
  if [[ -z "$plugin_name" || "$plugin_name" == \#* ]]; then
    continue
  fi

  latest_plugin_version=$(jq -r --arg plugin_name "$plugin_name" \
    '.plugins[$plugin_name].version // empty' "$update_center_file")
  if [[ -z "$latest_plugin_version" ]]; then
    printf 'Plugin %s is absent from the stable update center.\n' "$plugin_name" >&2
    exit 1
  fi
  if [[ "$pinned_plugin_version" != "$latest_plugin_version" ]]; then
    printf 'Plugin %s pin %s is not latest stable %s.\n' \
      "$plugin_name" "$pinned_plugin_version" "$latest_plugin_version" >&2
    exit 1
  fi
done < "$repository_root/plugins.txt"

#==============================================================================
# DOCKER PACKAGE VALIDATION
#==============================================================================

latest_package_version() {
  local package_name="$1"
  local package_file="$2"

  awk -v target="$package_name" '
    $0 == "Package: " target { package_found = 1; next }
    package_found && /^Version:/ { print $2; package_found = 0 }
  ' "$package_file" | sort -V | tail -n 1
}

for architecture in amd64 arm64; do
  package_file="$temporary_directory/docker-$architecture-packages"
  curl --fail --silent --show-error \
    "https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-$architecture/Packages.gz" | \
    gzip -dc > "$package_file"

  for package_name in containerd.io docker-buildx-plugin docker-ce docker-compose-plugin; do
    latest_version=$(latest_package_version "$package_name" "$package_file")
    printf '%s=%s\n' "$package_name" "$latest_version" >> \
      "$temporary_directory/latest-$architecture"
  done
done

if ! cmp --silent "$temporary_directory/latest-amd64" "$temporary_directory/latest-arm64"; then
  printf 'Latest Docker package versions differ between AMD64 and ARM64.\n' >&2
  exit 1
fi

pinned_containerd_version=$(sed -n "s/^containerd_version=\"\${CONTAINERD_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")
pinned_docker_buildx_version=$(sed -n "s/^docker_buildx_version=\"\${DOCKER_BUILDX_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")
pinned_docker_compose_version=$(sed -n "s/^docker_compose_version=\"\${DOCKER_COMPOSE_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")
pinned_docker_engine_version=$(sed -n "s/^docker_engine_version=\"\${DOCKER_ENGINE_VERSION:-\(.*\)}\"$/\1/p" \
  "$repository_root/scripts/install-docker.sh")

while IFS='=' read -r package_name latest_version; do
  case "$package_name" in
    containerd.io)
      pinned_version="$pinned_containerd_version"
      ;;
    docker-buildx-plugin)
      pinned_version="$pinned_docker_buildx_version"
      ;;
    docker-ce)
      pinned_version="$pinned_docker_engine_version"
      ;;
    docker-compose-plugin)
      pinned_version="$pinned_docker_compose_version"
      ;;
  esac

  if [[ "$pinned_version" != "$latest_version" ]]; then
    printf '%s pin %s is not latest stable %s.\n' \
      "$package_name" "$pinned_version" "$latest_version" >&2
    exit 1
  fi
done < "$temporary_directory/latest-amd64"

pinned_docker_cli_image=$(sed -n 's/^FROM docker:\([^[:space:]]*\) AS docker-cli$/\1/p' \
  "$repository_root/Dockerfile")
expected_docker_cli_image=${pinned_docker_engine_version#*:}
expected_docker_cli_image=${expected_docker_cli_image%%-*}-cli

if [[ "$pinned_docker_cli_image" != "$expected_docker_cli_image" ]]; then
  printf 'Docker CLI image pin %s does not match Engine %s.\n' \
    "$pinned_docker_cli_image" "$pinned_docker_engine_version" >&2
  exit 1
fi

printf 'latest_version_pins=ready\n'