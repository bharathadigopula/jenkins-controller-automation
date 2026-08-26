#==============================================================================
# PINNED JENKINS CONTROLLER IMAGE
#==============================================================================

#==============================================================================
# DOCKER CLI SOURCE IMAGE
#==============================================================================

FROM docker:28.3.3-cli AS docker-cli

#==============================================================================
# JENKINS CONTROLLER BASE IMAGE
#==============================================================================

FROM jenkins/jenkins:2.528.3-lts-jdk21

#==============================================================================
# ROOT IMAGE ASSEMBLY
#==============================================================================

USER root

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
COPY scripts/container-entrypoint.sh /usr/local/bin/jenkins-controller-entrypoint

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt \
    && chmod 0755 /usr/local/bin/jenkins-controller-entrypoint

#==============================================================================
# NON ROOT RUNTIME
#==============================================================================

USER jenkins

#==============================================================================
# CONTROLLER ENTRYPOINT
#==============================================================================

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/jenkins-controller-entrypoint"]