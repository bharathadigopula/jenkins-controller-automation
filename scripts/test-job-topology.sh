#!/usr/bin/env bash

#==============================================================================
# MANAGED JOB ACTIVATION REGRESSION
#==============================================================================

set -euo pipefail
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
eval "$(sed -n '/^managed_jobs_ready()/,/^}/p' "$repository_root/scripts/manage.sh")"
topology=$(jq -n '
  ["bharath-oci-host-config", "github-pipeline-templates", "jenkins-controller-automation", "jenkins-pipeline-templates", "monitoring-stack-automation", "shared-host-automation", "terraform-oci-modules", "tf-bharath-oci-infra", "clinirova"] as $validation |
  {"bharath-oci-host-config":["configure-jenkins","configure-monitoring","operate-host-network","operate-ingress-connector"],"tf-bharath-oci-infra":["operate-infrastructure"],"ignitox-wordpress":["publish-image","deploy-wordpress"],"jenkins-controller-automation":["scheduled-validation"],"monitoring-stack-automation":["scheduled-validation"],"clinirova":["publish-runtime","publish-migration","deploy"]} as $lifecycle |
  {jobs: (($validation + ($lifecycle | keys) | unique) | map(. as $folder | {name:$folder,_class:"com.cloudbees.hudson.plugins.folder.Folder",jobs:((if ($validation | index($folder)) != null then [{name:"validate",_class:"org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject"}] else [] end) + (($lifecycle[$folder] // []) | map({name:.,_class:"org.jenkinsci.plugins.workflow.job.WorkflowJob"})))}))}
')
managed_jobs_ready <<< "$topology"
extended_topology=$(jq '.jobs += [{name:"backstage-platform",_class:"com.cloudbees.hudson.plugins.folder.Folder",jobs:[]},{name:"wordpress-kubernetes-automation",_class:"com.cloudbees.hudson.plugins.folder.Folder",jobs:[]}]' <<< "$topology")
managed_jobs_ready <<< "$extended_topology"
verification=$(sed -n '/^verify_controller()/,/^}/p' "$repository_root/scripts/manage.sh")
if [[ "$verification" != *"if ! managed_jobs_ready <<< \"\$controller_jobs\"; then"* ]]; then
  printf 'Final verification must use the shared managed job topology gate.\n' >&2
  exit 1
fi
for missing_job in validate publish-runtime publish-migration deploy; do
  incomplete=$(jq --arg name "$missing_job" '(.jobs[] | select(.name == "clinirova") | .jobs) |= map(select(.name != $name))' <<< "$topology")
  if managed_jobs_ready <<< "$incomplete"; then
    printf 'Incomplete Clinirova job topology was accepted.\n' >&2
    exit 1
  fi
done
printf 'jenkins_job_topology_tests=ready\n'