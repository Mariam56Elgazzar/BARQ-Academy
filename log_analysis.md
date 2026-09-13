# Log analysis

Use all three supplied logs. Answer every question with commands/scripts and actual output.

1. What UTC interval is covered? How many valid, malformed and duplicate lines are in each file?
2. How many distinct client requests occurred? How did you deduplicate and avoid counting retries twice?
3. What are the final client status counts and error rate? State your denominator.
4. Which paths, time windows and backends account for the failures?
5. What are the median and p95 client latencies? State the percentile method and units.
6. Which requests retried upstream? How many succeeded after retrying?
7. Build an incident timeline using evidence from access, error AND application logs.
8. Show one correlated failed request and one successful request. Include IDs and timestamps.
9. Which errors appear to be proxy/connectivity issues versus dependency/application issues? What proves it?
10. What do the logs not prove? What would you check next in a running environment?

## Commands / scripts

python investigation/full_log_analysis.py | tee investigation/full_log_analysis_output.txt

(full script: investigation/full_log_analysis.py)

## Results

1. Window: 2026-08-20T11:00:00.015Z .. 2026-08-20T11:29:57.578Z (UTC).
   access.log: 725 valid JSON lines, 1 malformed. application.log: 729 valid, 1 malformed.
   error.log: 68 plain-text lines (nginx error format, not JSON).

2. 720 distinct client requests (grouped by request_id out of 725 raw lines).
   Dedup rule: group by request_id; keep only the LAST occurrence's status as the
   client-facing outcome. 5 request_ids appeared twice, all with identical timestamps
   and identical status (200/200) - this is exact double-logging, not a genuine retry
   with a different outcome, so no request was double-counted in the final totals.

3. Denominator = 720 distinct requests. Status counts: 200:615, 404:10, 502:40, 503:47, 504:8.
   Error rate (4xx+5xx / total) = 105/720 = 14.58%.

4. Failures by path: /records:26, /counter:26, /ready:23, /missing:10, /health:10, /:10.
   Failures by backend: 172.23.0.12:8080 = 73, 172.23.0.11:8080 = 32 (one backend absorbed
   most of the outage window while it was down).

5. Median (p50) latency: 0.054s. p95: 2.001s (linear interpolation method), computed over
   all 725 access.log request_time values, in seconds.

6. 5 request_ids had more than one attempt; 0 of them succeeded on a later attempt after an
   earlier failure (all 5 duplicate pairs were 200/200 double-logs, not failure-then-success retries).

7. See investigation/full_log_analysis_output.txt for the full 209-event cross-log timeline
   (access.log failures + application.log WARN/ERROR events, merged and sorted by timestamp).

8. Correlated example - failed: lab-000001, 2026-08-20T11:00:00.015Z, GET /missing, 404,
   upstream 172.23.0.11:8080, matched in application.log (instance_id app-01, duration_ms 15.0).
   Correlated example - successful: lab-000002, 2026-08-20T11:00:02.532Z, GET /health, 200,
   upstream 172.23.0.12:8080, matched in application.log (instance_id app-02, duration_ms 32.0).

9. 59 "Connection refused" lines in error.log = proxy/connectivity failures (TCP-level, no
   matching application.log entry exists for those request_ids - the app never received them).
   8 timeout-pattern lines = dependency-side failures (an application.log entry DOES exist
   with a high duration_ms just before the cutoff, proving the app received the request but
   was slow, e.g. waiting on Postgres/Redis).

## Timeline and correlated examples

Full timeline: investigation/full_log_analysis_output.txt (Q7 section).
Correlated failed/successful pair: see item 8 above.

## Conclusions and limits

- The logs do not show root cause *inside* the app process (why Postgres/Redis was briefly
  unreachable) - would need Postgres/Redis's own logs at that timestamp.
- Whether the 5 duplicate request_ids came from client-side vs NGINX-side double-logging
  cannot be fully proven without client-side instrumentation.
- Resource exhaustion (CPU/memory) as a contributing cause is not observable without
  docker stats captured at the time.

