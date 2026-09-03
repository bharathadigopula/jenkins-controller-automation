#==============================================================================
# PINNED JENKINS CONTROLLER IMAGE
#==============================================================================

#==============================================================================
# JENKINS CONTROLLER BASE IMAGE
#==============================================================================

FROM jenkins/jenkins:2.568.3-lts-jdk21

#==============================================================================
# ROOT IMAGE ASSEMBLY
#==============================================================================

USER root

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