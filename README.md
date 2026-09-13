# BARQ DevOps Internship Task - Solution

Flask API (2 instances) behind NGINX, backed by PostgreSQL and Redis, fully containerized with Docker Compose.

## Architecture

Host:8080 -> nginx -> app-01 and app-02 -> postgres and redis (internal only)

- frontend network: nginx, app-01, app-02
- backend network (internal: true): app-01, app-02, postgres, redis
- Only NGINX is published to the host (127.0.0.1:8080). PostgreSQL and Redis are never published.
- Named volume postgres-data mounted at /var/lib/postgresql/data for PostgreSQL persistence.

See architecture.png for the full request-flow diagram.

## Prerequisites

- Docker Desktop (or Docker Engine + Compose plugin)
- Bash (Git Bash on Windows, or native on macOS/Linux)

## Setup

git clone https://github.com/Mariam56Elgazzar/BARQ-Academy.git
cd BARQ-Academy
cp config/app.env.example config/app.env

Edit config/app.env if needed. Never commit real secrets.

## Build and Start

docker compose up -d --build
docker compose ps

Confirm all 5 services report healthy.

## Stop and Clean Up

docker compose down
(stop, keep volume, data persists)

docker compose down -v
(stop AND delete volume, full reset, data lost)

## Test

### Full validation suite

chmod +x validate.sh
./validate.sh

Checks: public endpoint reachability, all required endpoints, PostgreSQL/Redis readiness, load distribution across both backend instances, and that PostgreSQL/Redis ports are NOT published to the host.

### Failure and recovery test

chmod +x failure_test.sh
./failure_test.sh

Or target the other instance:
TARGET_CONTAINER=app-02 ./failure_test.sh

Stops one backend instance, confirms the service stays available via the other instance, measures errors during the outage, restarts the stopped instance, and confirms it rejoins traffic.

## Backup and Restore

chmod +x backup.sh restore.sh

Create a backup (saved to backups/barq_backup_TIMESTAMP.dump):
./backup.sh

Restore from a specific backup:
./restore.sh barq_backup_20260912_161941.dump

Backup uses pg_dump custom format run inside the postgres container; restore uses pg_restore --clean --if-exists. See troubleshooting.md for the full persistence-proof walkthrough.

## CI

GitHub Actions workflow at .github/workflows/ci.yml runs on every push and pull request: checkout, validate docker-compose.yml syntax, build images, start environment, wait for all services healthy, run validate.sh, tear down.

Latest passing run: https://github.com/Mariam56Elgazzar/BARQ-Academy/actions/runs/34759320816
Final commit: db677b3a54e0184e548e4e94463471dadb5c677b

## Endpoints

- / : basic app response
- /health : process liveness
- /ready : PostgreSQL + Redis readiness
- /instance : identifies which backend instance responded
- /records : POST to create, GET to list PostgreSQL records
- /counter : Redis-backed counter, increments per call

## Documentation

- troubleshooting.md : investigation journal, failed attempts, root causes
- log_analysis.md : log analysis and correlated findings
- decisions.md : design decisions, alternatives, trade-offs
- security_review.md : security risks and improvements
- AI_USAGE.md : AI tool usage disclosure

## Known Limitations and Production Considerations

- Single PostgreSQL instance, no replication or automatic failover (see security_review.md)
- Redis persistence disabled, acceptable for a non-critical counter (documented in decisions.md)
- Backups are manual, not scheduled; production would need automated retained backups
