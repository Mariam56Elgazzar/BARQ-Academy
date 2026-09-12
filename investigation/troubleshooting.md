# Troubleshooting Journal - Part 1 Investigation

## Session 1: Initial Log Discovery
**Time:** 11:00 UTC+2  
**Task:** Find and analyze the three logs

### Actions
1. Located logs in \logs\ folder (not root folder)
   - access.log (JSON format, ~720 lines)
   - error.log (NGINX format, ~50 lines)
   - Combined into single document for analysis

2. Attempted initial PowerShell analysis
   - Get-ChildItem to list files ✅
   - Get-Content to read logs ✅
   - Select-String to search patterns ✅

### Findings
- 720 total HTTP requests
- 47 connection refused errors (early logs)
- 20 x 503 Service Unavailable errors (/ready endpoint)
- 8 x 504 Gateway Timeout errors (/records endpoint)
- 3 duplicate request IDs

### Failed Attempts
1. ❌ First tried bash commands on PowerShell (ls -la)
   - Error: PowerShell doesn't recognize bash syntax
   - Solution: Used Get-ChildItem instead

2. ❌ Tried opening logs in VS Code (too large)
   - Error: JSON formatting issues with mixed log types
   - Solution: Used grep-like PowerShell commands

3. ❌ Python script with syntax error in PowerShell
   - Error: Here-string didn't close properly
   - Solution: Used multi-line here-string with proper line breaks

---

## Session 2: Deep Analysis
**Time:** 11:15 UTC+2  
**Task:** Correlate logs and identify root causes

### Actions
1. Analyzed access.log (JSON) status codes
   - Extracted 200s, 4xx, 5xx patterns
   - Found /ready consistently returns 503 for 4 minutes
   - /records returns 504 at specific timestamps

2. Analyzed error.log (NGINX)
   - All "Connection refused" errors point to 172.23.0.12:8080
   - All "upstream timed out" errors are for /records endpoint
   - Timeout value: exactly 2.001 seconds (system timeout)

3. Cross-referenced timestamps
   - lab-000122 error (11:05:02) = first connection refused
   - lab-000292 status 503 (11:12:09) = /ready starts failing
   - lab-000606 504 (11:25:14) = /records timeout begins

### Failed Attempts
1. ❌ Assumed Redis was down based on /ready returning 503
   - Error: /ready is a health check, not directly tied to Redis
   - Correction: It's a database readiness check, different issue

2. ❌ Thought database crashed during /records timeout
   - Error: /records returned 200 OK right before and after 504s
   - Correction: Not a crash, a slow query hitting timeout

3. ❌ Tried to find /app.log or application logs
   - Error: Only error.log and access.log exist
   - Correction: Flask errors must be captured elsewhere or in docker logs

### Discoveries
1. ✅ 172.23.0.12 is primary backend (has more errors)
2. ✅ 172.23.0.11 is secondary backend (round-robin load balancing)
3. ✅ System recovers naturally - not stuck in error state
4. ✅ By 11:27, all endpoints return 200 OK

---

## Session 3: Issue Documentation
**Time:** 11:30 UTC+2  
**Task:** Write root causes and evidence

### Actions
1. Created 3 issue files with detailed investigation
   - Issue 1: Connection Refused (backend crash)
   - Issue 2: 503 Unavailable (readiness check fail)
   - Issue 3: 504 Timeout (slow query)

2. Documented evidence with exact timestamps and request IDs
3. Included failed attempts to show investigation path
4. Added fix strategies for each issue

### Key Insights
1. Issues are sequential, not simultaneous
   - First: backend down (11:05-11:09)
   - Then: database not ready (11:12-11:16)
   - Finally: slow query (11:25-11:26)
   - Pattern suggests cascading failures

2. Load balancer is working
   - Requests alternate between 172.23.0.12 and 172.23.0.11
   - Pattern shows round-robin: ...12, ...11, ...12, ...11

3. No data loss detected
   - Requests that get through return 200 OK
   - No 500 Internal Server errors (would indicate application bugs)
   - All failures are infrastructure-level

---

## Remaining Questions (for Part 2+)
1. What's in the app-01 and app-02 containers?
2. Why did backend container crash initially?
3. What's the /records query doing that makes it slow?
4. How are duplicate request IDs being generated?
5. What's the proper recovery sequence?

---

## Files Created
- ✅ investigation/analysis.md (main report)
- ✅ investigation/issues/issue_01.md (connection refused)
- ✅ investigation/issues/issue_02.md (503 service unavailable)
- ✅ investigation/issues/issue_03.md (504 timeout)
- ✅ investigation/logs_backup/access.log.bak
- ✅ investigation/logs_backup/error.log.bak
- ✅ troubleshooting.md (this file)

