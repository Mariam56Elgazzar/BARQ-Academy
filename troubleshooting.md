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
