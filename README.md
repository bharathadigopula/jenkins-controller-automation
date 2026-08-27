<!--
==============================================================================
JENKINS CONTROLLER AUTOMATION
==============================================================================
-->

# Jenkins Controller Automation

Deploy a small Jenkins controller on AMD64 or ARM64 Ubuntu with a pinned container image, Configuration as Code, native Jenkins authentication, Docker-based build tooling, systemd lifecycle management, and explicit recovery operations.

<!--
==============================================================================
CONTROLLER PROFILE
==============================================================================
-->

## Controller Profile

| Setting | Default |
| --- | --- |
| Jenkins | `2.528.3-lts-jdk21` |
| Java heap | 512 MB initial, 1 GB maximum |
| Container memory | 2 GB |
| Container CPU | 0.70 CPU |
| Executors | 1 |
| HTTP port | 8080 |

The controller is designed for a one-OCPU, 6 GB host. Keep concurrent builds at one and run toolchains in short-lived Docker containers through the mounted Docker socket.

<!--
==============================================================================
SECURITY MODEL
==============================================================================
-->

## Security Model

- Jenkins' setup wizard is disabled only because JCasC creates the administrator account.
- Anonymous access and user signup are disabled.
- Native Jenkins login remains required behind any identity-aware proxy.
- The administrator password and GitHub token are mounted as Docker secrets.
- JCasC installs a `github-token` secret-text credential for private repository access.
- The HTTP listener should bind to a private address and be published only through authenticated outbound ingress.

The deployment secret is a single-line JSON object supplied by a secret manager:

```json
{"admin_password":"replace-with-strong-password","github_token":"replace-with-token"}
```

Use a fine-grained GitHub token with only the repository metadata, contents, pull request, commit status, and checks permissions required by the managed repositories.

<!--
==============================================================================
VALIDATION AND DRY RUN
==============================================================================
-->

## Validate And Dry Run

These commands do not mutate the host:

```bash
shellcheck scripts/*.sh
bash scripts/validate.sh
bash scripts/manage.sh dry-run
bash scripts/install-docker.sh dry-run
```

CI also builds the complete controller image, resolving every pinned plugin against the pinned Jenkins core.

<!--
==============================================================================
VERSIONED DEPLOYMENT
==============================================================================
-->

## Versioned Deployment

`bootstrap.sh` stays below the OCI Run Command 4,096-byte payload limit. It downloads an immutable semantic-version archive, validates it, installs pinned Docker packages only for `deploy`, and invokes the lifecycle manager.

```bash
bash scripts/bootstrap.sh \
  dry-run \
  owner/jenkins-controller-automation \
  v1.0.4 \
  https://jenkins.example.com \
  10.0.0.20 \
  ""
```

Use `deploy` explicitly and append the secret-manager JSON as the final argument for mutation.

<!--
==============================================================================
LIFECYCLE OPERATIONS
==============================================================================
-->

## Operations

| Action | Mutation | Result |
| --- | --- | --- |
| `validate` | No | Checks pinned images, plugins, JCasC inputs, and Compose |
| `dry-run` | No | Validates and reports the release path |
| `deploy` | Yes | Builds and starts the controller through systemd |
| `upgrade` | Yes | Deploys a new release and retains the prior release |
| `verify` | No | Checks the service, authentication, metrics, initialized state, managed credentials, and backup timer |
| `status` | No | Reports systemd, backup timer, and Compose state |
| `backup` | Yes | Stops Jenkins and archives `JENKINS_HOME` |
| `restore` | Yes | Restores `JENKINS_RESTORE_ARCHIVE` |
| `rollback` | Yes | Exchanges current and previous releases |
| `test-restore` | Yes | Creates a fresh backup, restores it, and runs comprehensive verification |

`jenkins-controller-backup.timer` runs daily at 03:00 with a random delay of up to 15 minutes. Backups are written root-only under `/var/backups/jenkins-controller` and archives older than seven days are removed. Copy retained archives to durable object storage with a separate, versioned backup job.

<!--
==============================================================================
CONFIGURATION AS CODE
==============================================================================
-->

## Configuration As Code

`jcasc/jenkins.yaml` controls executor count, local authentication, authorization, CSRF protection, environment defaults, the GitHub credential, and controller URL. Change controller configuration in source and redeploy an immutable release; do not edit production settings in the Jenkins UI.

The plugin catalogue in `plugins.txt` is explicit and duplicate-checked. Update Jenkins core and plugins together, validate the image build, back up `JENKINS_HOME`, then deploy through `upgrade`.

<!--
==============================================================================
RECOVERY BOUNDARY
==============================================================================
-->

## Recovery Boundary

Jenkins must not be its own only rebuild mechanism. Preserve a manual emergency workflow outside Jenkins that can:

1. Provision or recover the host.
2. Retrieve this repository by immutable tag.
3. Retrieve the secret bundle from a secret manager.
4. Execute `dry-run` and then `deploy` through the cloud remote-command service.

Routine repository validation can move to Jenkins only after controller backup and restore have been verified.