# Security Review

This document covers implemented security measures and known risks in the current solution, and separately lists production-grade improvements that were out of scope for this lab environment.

## 1. Secrets

Implemented: Database credentials are supplied via environment variables in config/app.env (git-ignored) and docker-compose.yml environment blocks, not hardcoded in application code or Dockerfiles. A config/app.env.example is provided with placeholder values so the repo is runnable without real secrets committed.

Risk: the current lab password (BarqLabOnly_...) is still visible in docker-compose.yml itself for postgres's POSTGRES_PASSWORD, since Compose requires it there to initialize the image. This is acceptable for a lab environment with a clearly fake/synthetic password, but would be a real risk if it were a production credential.

Production improvement: use Docker secrets, a vault (HashiCorp Vault, AWS Secrets Manager), or at minimum inject via a git-ignored .env file referenced with env_file, never inline in a committed compose file.

## 2. Ports

Implemented: only NGINX is published to the host (127.0.0.1:8080). PostgreSQL and Redis have no ports: entry at all in docker-compose.yml, verified via docker inspect showing {"5432/tcp":null} and {"6379/tcp":null} (see troubleshooting.md Issue 5 for how this was verified reliably).

Risk: this was not the initial state - postgres and redis were originally published to 127.0.0.1:15432 and 127.0.0.1:16379. Loopback-only binding is safer than 0.0.0.0 but is still a published port and does not meet the task's explicit requirement. This was caught and fixed, but shows how easy it is to leave a "mostly safe" port exposed.

Production improvement: enforce port-isolation as an automated policy check (e.g. a CI step that fails if any service other than the reverse proxy has a ports: key), rather than relying on manual review.

## 3. Container user

Implemented: the app Dockerfile creates a dedicated non-root user (group app, uid/gid 10001) and copies application code with --chown=app:app, so app-01 and app-02 do not run as root.

Risk: hadolint (run in CI as an optional check) flagged DL3002 "Last USER should not be root" for the Dockerfile - this needs verification that the final effective user in the running container is actually the non-root app user and not root from a later instruction overriding it.

Production improvement: explicitly set USER app as the last relevant instruction before CMD/ENTRYPOINT if not already guaranteed, and verify at runtime with docker exec app-01 whoami. Also consider read-only root filesystems (read_only: true) with explicit tmpfs mounts for any directories that need write access.

## 4. Base images

Implemented: all images are pinned to a specific version and digest (e.g. postgres:16-alpine@sha256:..., redis:7.4-alpine@sha256:..., nginx:1.28-alpine@sha256:..., python:3.12-slim-bookworm@sha256:...), not floating tags like latest or postgres:16. Alpine/slim variants were chosen to minimize image size and attack surface.

Risk: pinning to a digest means security patches released for the same tag are not automatically picked up; the pinned digest could become stale and miss CVE fixes over time.

Production improvement: run automated image scanning (e.g. Trivy or Grype) in CI against the pinned digests on a schedule (not just at build time), and have a process for reviewing and bumping pinned digests when patches are released. hadolint is already wired into CI as a Dockerfile linter (extra credit); a full image vulnerability scan would be a natural next addition.

## 5. Networks

Implemented: two Docker networks separate concerns - frontend (nginx, app-01, app-02) and backend (internal: true - app-01, app-02, postgres, redis). NGINX has no membership in backend, so it cannot reach PostgreSQL or Redis directly even at the network layer, regardless of application-level routing.

Risk: this was misconfigured twice during development - once with nginx mistakenly added to backend, and once with internal: true mistakenly applied to frontend instead of backend (see troubleshooting.md Issue 3). Both were silent failures (no error was thrown; behavior just quietly stopped being correct or ports stopped publishing), which is a general risk with Compose network configuration.

Production improvement: add an automated network-topology assertion to validate.sh or a dedicated CI step that runs docker network inspect on both networks and asserts exact expected membership, catching this class of misconfiguration automatically rather than by manual review.

## 6. Backup and restore

Implemented: backup.sh runs pg_dump -F c inside the postgres container and copies the dump to the host; restore.sh copies a dump back in and runs pg_restore --clean --if-exists. This was proven end-to-end: created a marker record, backed it up, deleted it with a direct SQL DELETE, confirmed it was gone, restored from the backup, and confirmed the exact same record (same id) reappeared.

Risk: backups are manual and stored unencrypted in a local backups/ directory that is not automatically retained, rotated, or shipped off-host. A single disk failure would destroy both the live database and every local backup simultaneously.

Production improvement: automate backups on a schedule (cron or a scheduled CI/CD job), encrypt backups at rest, ship them to separate storage (e.g. S3 with versioning), and implement a retention policy. Also periodically test restores in an isolated environment, not just at development time, to catch backup-format or version-drift issues before they are needed in a real incident.

## 7. Monitoring and logging

Implemented: the app logs structured JSON per request (timestamp, level, service, event, instance_id, request_id, method, path, status, duration_ms), which makes log correlation across app-01/app-02 straightforward (see log_analysis.md). Docker healthchecks are configured for every service (app, postgres, redis) so docker compose ps surfaces unhealthy containers immediately.

Risk: logs only exist as container stdout, visible via docker compose logs. There is no log aggregation, retention, alerting, or dashboarding - if a container is removed (docker compose down without preserving logs elsewhere), its history is gone. There is also no metrics collection (request rates, error rates, latency percentiles) beyond what can be manually derived from raw logs.

Production improvement: ship logs to a centralized system (e.g. Loki, ELK, or a managed service) with retention and alerting rules (e.g. alert on sustained 5xx rate or on a backend reporting unhealthy). Add a metrics endpoint (e.g. Prometheus-format /metrics) and dashboards for request rate, error rate, and latency per instance.

## 8. Availability and single points of failure

Implemented: two application instances (app-01, app-02) behind NGINX provide redundancy at the app tier - failure_test.sh proves that stopping one instance leaves the service available via the other, with automatic recovery once the stopped instance restarts (see troubleshooting.md and failure_test.sh output: 5/10 requests succeeded during the outage, full recovery within 4 seconds).

Risk: PostgreSQL and Redis are each a single instance - both are single points of failure. If the postgres container or its host disk fails, the entire API loses read/write capability for /records regardless of how many app instances are running, since restart_policy: "no" as currently configured. NGINX itself is also a single instance and a single point of failure for all traffic.

Production improvement: PostgreSQL would need a replication setup (e.g. primary plus standby with automatic failover, or a managed service like RDS Multi-AZ). Redis would need Sentinel or Cluster mode for HA. NGINX would need to run as multiple replicas behind a load balancer or use a cloud load balancer directly. Additionally, restart policies should be reconsidered for production (e.g. unless-stopped or on-failure with a retry limit) rather than "no", so transient failures recover automatically instead of requiring manual intervention.
