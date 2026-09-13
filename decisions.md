# Design Decisions

This file documents key decisions made while building the solution, along with assumptions, alternatives considered, trade-offs, and known limitations for each.

## Decision 1: Do not publish PostgreSQL/Redis ports at all (not even to 127.0.0.1)

Assumption: local debugging access to postgres/redis from the host is not required outside of docker exec.

Alternative considered: publish to 127.0.0.1 only (as the environment originally had it), reasoning that loopback-only binding is reasonably safe.

Trade-off: the task requirement is explicit ("Do not publish app, PostgreSQL or Redis ports"), and a loopback-restricted port is still a published port from Docker's perspective and would fail a strict port-isolation check. Removing publication entirely means debugging requires docker exec -it postgres psql ... instead of a host-side client, which is slightly less convenient during development.

Limitation: no direct host GUI tool (e.g. pgAdmin from Windows) can connect without either temporarily re-adding a port or exec-ing into the container.

## Decision 2: Disable Redis persistence for the counter (--save "" --appendonly no)

Assumption: /counter is a simple demo counter, not business-critical data; losing its value on restart is acceptable.

Alternative considered: enable AOF (--appendonly yes) so the counter value survives restarts, matching the treatment given to PostgreSQL data.

Trade-off: enabling persistence adds disk I/O overhead and a small amount of complexity (AOF file management, potential corruption-recovery scenarios) for a value that has no real consequence if reset to zero. Disabling it keeps redis simpler and faster, at the cost of the counter not surviving a restart.

Limitation: if /counter were ever repurposed to track something meaningful (e.g. a rate limiter with compliance implications), this decision would need to be revisited.

## Decision 3: Verify port isolation via docker inspect rather than docker compose port

Assumption: validate.sh needs a check that fails loudly and correctly when a port is accidentally published, not one that always passes.

Alternative considered: keep using docker compose port <service> <port> and treat any non-empty output as "published" (string-matching instead of exit-code-matching).

Trade-off: docker inspect --format '{{json .NetworkSettings.Ports}}' queries Docker's own ground-truth state directly, which is more verbose but unambiguous (null vs a HostPort key). String-matching docker compose port output would have been more fragile and tied to its specific "invalid IP:0" wording, which is not a documented, stable output format.

Limitation: this check only verifies the current running container's state; it does not statically check docker-compose.yml for a ports: key that simply hasn't been applied yet (e.g. before docker compose up).

## Decision 4: Use a 20-request sample for load-distribution checks, asserting participation not exact ratio

Assumption: NGINX's default round-robin will eventually route to both backends; a validation script needs a sample large enough to demonstrate this reliably without being flaky.

Alternative considered: assert an exact or near-exact 50/50 split (e.g. within 1 request of parity), which was the original informal expectation.

Trade-off: an early manual test with only 6 requests showed a 5:1 split purely by chance (see troubleshooting.md Issue 2), which would have made a strict-parity assertion fail intermittently even when the system is working correctly. Asserting "at least 2 distinct instance IDs observed in 20 requests" is a weaker but far more reliable signal of correct behavior, and avoids flaky CI failures caused by natural variance.

Limitation: this does not prove perfectly even load balancing under sustained production traffic, only that both instances are reachable and participating.

## Decision 5: Use pg_dump custom format (-F c) instead of plain SQL for backups

Assumption: backups will be restored using pg_restore against the same or a compatible PostgreSQL version, not manually reviewed as SQL text.

Alternative considered: pg_dump with plain SQL output (-F p), restored via psql < backup.sql.

Trade-off: custom format (-F c) is compressed, supports parallel restore, and allows selective restore of specific tables/objects via pg_restore, at the cost of not being human-readable/diffable like plain SQL. Since the requirement is only to prove a working backup/restore cycle (not to version-control schema changes via SQL diffs), custom format's operational advantages outweighed the readability trade-off.

Limitation: custom-format dumps are not portable to non-PostgreSQL databases and require pg_restore specifically, not a generic SQL client.

## Decision 6: Prove persistence by recreating containers without -v, and separately test full-recovery-from-backup with a real DELETE

Assumption: the task distinguishes two different guarantees that must each be proven separately: (a) data survives normal container lifecycle operations, and (b) a backup can recover data after real data loss.

Alternative considered: only test docker compose down / up (without -v) and call that sufficient proof of backup and restore working.

Trade-off: down/up without -v only proves the volume persists across container recreation - it does not exercise pg_dump or pg_restore at all, so it cannot prove backups are usable. The chosen approach runs both tests: a container-recreation cycle for persistence (Issue 4 in troubleshooting.md), and a separate destructive test that creates a marker record, backs it up, deletes it with a direct SQL DELETE (simulating real data loss, not just a restart), and restores it from the backup file to prove pg_restore actually recovers lost data.

Limitation: the destructive test currently targets a single table (records) via a manual DELETE; a full disaster-recovery drill would also test recovering from a completely dropped database or a deleted volume.

## Decision 7: Use CMD-based health checks with tools already present in each base image

Assumption: health checks should not require installing extra packages into images, to keep images minimal and avoid unnecessary attack surface.

Alternative considered: install a dedicated healthcheck utility (e.g. curl or wget) into the Python app images specifically for health checking.

Trade-off: the app healthcheck uses python -c "import urllib.request; ..." since Python and its standard library are already present in the app image - no extra install needed. postgres uses pg_isready (ships with the postgres image). redis uses redis-cli (ships with the redis image). This avoids adding curl/wget as extra dependencies purely for health checks, keeping images smaller, at the minor cost of a slightly less common/readable healthcheck command for the Python services compared to a plain curl call.

Limitation: if the app's Python entrypoint or urllib behavior ever changes significantly, the healthcheck command would need to be revisited alongside it, since it is tightly coupled to the app image's runtime rather than being a fully independent, generic check.
