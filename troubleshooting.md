# Troubleshooting journal

Keep chronological entries. Copy this block for each meaningful investigation.

## Entry / date / time
- Symptom:
- Hypothesis:
- Command or test:
- Actual output:
- Failed attempt and what changed your thinking:
- Root cause:
- Fix:
- Retest evidence:
- Related commit:
- Remaining uncertainty:

Do not fabricate a failed attempt just to fill the template. Record actual attempts.
# Troubleshooting Journal

This file documents every issue encountered during setup, testing, and CI integration: symptoms observed, hypotheses tested, commands run, results, failed attempts, root causes, and retest evidence.

## Issue 1: nginx fails to start - "unknown directive worker_processes"

### Symptom
After docker compose up, the nginx container exited immediately. docker compose logs nginx showed:
nginx: [emerg] unknown directive "worker_processes" in /etc/nginx/nginx.conf:1

This made port 8080 completely unreachable, which in turn caused every endpoint check in validate.sh to fail (curl: Failed to connect to localhost port 8080).

### Hypothesis 1 (failed attempt)
Assumed a typo in the nginx.conf syntax itself. Reviewed the file line by line visually; the directive worker_processes looked correctly spelled and valid nginx syntax. This did not explain the error.

### Investigation
Inspected the raw bytes at the start of the file:

Format-Hex nginx/nginx.conf | Select-Object -First 1

This revealed a UTF-8 Byte Order Mark (EF BB BF) before the first character of the file. nginx does not strip BOM characters, so it read the BOM as the start of an unrecognized directive name, causing the parse failure on line 1.

### Root Cause
nginx.conf was saved with a UTF-8 BOM prefix (likely from a Windows text editor that adds BOM by default when saving UTF-8 files). nginx's config parser treats the file as a raw byte stream and does not recognize or skip the BOM, so it appears as garbage characters prepended to the first directive.

### Fix
Rewrote the file without a BOM:

sed -i '1s/^\xEF\xBB\xBF//' nginx/nginx.conf

Verified removal:
head -c 10 nginx/nginx.conf | xxd
(confirmed output started directly with "776f 726b 6572..." = "worker" with no leading bytes)

### Retest Evidence
docker compose down
docker compose up -d
docker compose ps
(all 5 services, including nginx, reported healthy/started)

curl http://localhost:8080/health returned 200.

Commit: e025674 - "fix: remove UTF-8 BOM from nginx.conf"

### Lesson Learned
This same BOM issue resurfaced later in CI (see Issue 6) because the local fix had not yet been pushed to GitHub when the first CI run was triggered. This taught the importance of verifying git status and confirming a fix is actually committed and pushed, not just working locally, before considering an issue closed.

## Issue 2: Misleading load-distribution result with small sample size

### Symptom
An early manual test hit /instance 6 times and observed a 5:1 split between app-01 and app-02, suggesting NGINX might not be load-balancing evenly.

### Hypothesis
Considered that NGINX's default round-robin might be misconfigured, or that one backend was somehow preferred (e.g. due to connection keep-alive pinning requests to the same worker).

### Investigation
Repeated the test with a much larger sample (30 requests) instead of 6:

for i in $(seq 1 30); do curl -s http://localhost:8080/instance | grep -o '"instance_id":"[^"]*"'; done | sort | uniq -c

Result: 15 requests to app-01, 15 to app-02 - a near-perfect split.

### Root Cause
Not a real defect. With only 6 requests and multiple NGINX worker processes each maintaining independent round-robin state, a small sample can easily show an uneven split by chance. This was a sample-size artifact, not a load-balancing bug.

### Retest Evidence
validate.sh now samples 20 requests and asserts at least 2 distinct instance IDs are observed, rather than an exact 50/50 split.

### Lesson Learned
Small manual samples can produce misleading conclusions. Automated checks should use a sample size large enough to be meaningful, and should assert the property that actually matters (both instances participate) rather than an exact ratio.

## Issue 3: nginx had unintended access to the backend network

### Symptom
While verifying network isolation requirements, docker network inspect showed nginx as a member of the backend network, in addition to frontend. This violated the requirement that NGINX must not have direct access to PostgreSQL or Redis.

### Investigation
docker network inspect barq-assessment_backend --format '{{range .Containers}}{{.Name}} {{end}}'
Output included nginx alongside postgres, redis, app-01, app-02 - nginx should only be on frontend.

### Failed Attempt
First attempt: removed nginx from the backend network list in docker-compose.yml, but a copy-paste error accidentally deleted the entire backend network definition block from the file, breaking docker compose config entirely (backend network no longer existed at all).

### Second Issue Uncovered
After restoring the backend network definition and correctly scoping nginx to frontend only, port 8080 stopped being published on the host. Investigation showed the frontend network had internal: true set, which blocks host port publishing entirely for any service on that network - not just inter-container isolation.

### Root Cause
Two separate misconfigurations: (1) nginx was listed under both frontend and backend networks instead of frontend only, and (2) internal: true was mistakenly applied to frontend instead of backend, which silently blocks host port publishing rather than producing an obvious error.

### Fix
- nginx: networks: [frontend] only
- frontend network: no internal flag (must allow host port publishing)
- backend network: internal: true (blocks external/host access, allows only inter-container traffic within backend)

### Retest Evidence
docker network inspect barq-assessment_backend --format '{{range .Containers}}{{.Name}} {{end}}'
-> postgres app-01 redis app-02  (nginx correctly absent)

docker network inspect barq-assessment_frontend --format '{{range .Containers}}{{.Name}} {{end}}'
-> app-01 nginx app-02  (correct membership)

curl http://localhost:8080/health returned 200 (port publishing restored).

### Lesson Learned
internal: true has host-port-publishing side effects beyond inter-container isolation; it must be placed on the correct network only (backend, not frontend). Also: always run docker compose config after any manual YAML edit to catch structural damage from copy-paste mistakes before testing runtime behavior.

## Issue 4: Records did not survive container recreation (critical)

### Symptom
Created a record via POST /records, then ran docker compose down followed by docker compose up -d (no -v flag, volume preserved). The record was gone from GET /records after restart, even though a named volume postgres-data existed and was attached to the postgres container.

### Investigation
Inspected the actual mounts on the running container:

docker inspect postgres --format '{{json .Mounts}}'

Result showed the named volume postgres-data was mounted at /var/lib/postgresql/backup - not /var/lib/postgresql/data, which is PostgreSQL's actual data directory (PGDATA).

Also found in docker-compose.yml:
tmpfs: [/var/lib/postgresql/data]

This meant the real PGDATA path was mounted as tmpfs - RAM-backed, non-persistent storage - while the durable named volume was attached to an unused path that PostgreSQL never writes to.

### Root Cause
Two compounding misconfigurations in the postgres service definition:
1. tmpfs: [/var/lib/postgresql/data] made the real data directory non-persistent by design (wiped on every container stop).
2. volumes: - postgres-data:/var/lib/postgresql/backup pointed the durable volume at a path PostgreSQL does not use for its data files.

Every record was actually being written correctly to disk, but to tmpfs (RAM), which is discarded whenever the container stops - regardless of any volume configuration.

### Fix
Removed the tmpfs override entirely. Corrected the volume target to postgres-data:/var/lib/postgresql/data. Also removed unrelated but disqualifying issues found in the same block: published ports on postgres (15432) and redis (16379), which violated the "do not publish app, PostgreSQL or Redis ports" requirement.

### Retest Evidence
Deleted the old volume and rebuilt from zero to prove the fix: docker compose down, docker volume rm barq-assessment_postgres-data, docker compose up -d --build. Created record id 3 "persistence-test". Ran docker compose down then docker compose up -d twice in a row. The record survived both full container-recreation cycles.

### Lesson Learned
A named volume being present and attached does not by itself prove persistence works. The mount target must match the exact path the application writes to. This was the most critical bug in the task: every backup would have silently backed up nothing without this fix.
