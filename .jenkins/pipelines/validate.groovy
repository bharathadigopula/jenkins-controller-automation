//==============================================================================
// JENKINS CONTROLLER AUTOMATION VALIDATION
//==============================================================================

@Library('jenkins-pipeline-templates@v1.4.0') _

repositoryValidationPipeline(
    githubRepository: 'bharathadigopula/jenkins-controller-automation',
    shellSearchPath: 'scripts',
    validationScript: 'scripts/validate.sh',
    validationCommands: [
        'bash scripts/check-latest-versions.sh',
        'bash scripts/manage.sh dry-run',
        'test "$(wc -c < scripts/bootstrap.sh)" -le 4096',
        'docker compose build'
    ],
    validateWorkflows: true,
    timeoutMinutes: 30
)