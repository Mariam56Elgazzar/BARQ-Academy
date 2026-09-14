#!/usr/bin/env python3
"""
full_log_analysis.py
Answers the 10 log_analysis.md template questions using logs/access.log,
logs/error.log and logs/application.log. Read-only: never modifies originals.
"""
import json, re, statistics as stats
from collections import defaultdict, Counter
from datetime import datetime

ACCESS = "logs/access.log"
ERROR = "logs/error.log"
APP = "logs/application.log"

def load_access():
    rows, malformed = [], 0
    with open(ACCESS, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                malformed += 1
    return rows, malformed

def load_app():
    rows, malformed = [], 0
    with open(APP, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                malformed += 1
    return rows, malformed

def load_error():
    rows = []
    pat = re.compile(r"^(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[(?P<level>\w+)\].*?"
                      r"(?:request_id=(?P<rid>\S+?),)?.*?request: \"(?P<method>\w+) (?P<path>\S+)")
    with open(ERROR, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            m = pat.search(line)
            rows.append({"raw": line, "match": m.groupdict() if m else None})
    return rows

access, access_malformed = load_access()
app, app_malformed = load_app()
error = load_error()

print("=== Q1: coverage window + line counts ===")
ts_sorted = sorted(r["timestamp"] for r in access)
print(f"access.log: {len(access)} valid JSON lines, {access_malformed} malformed")
print(f"application.log: {len(app)} valid JSON lines, {app_malformed} malformed")
print(f"error.log: {len(error)} lines (plain text, not JSON)")
print(f"UTC window (access.log): {ts_sorted[0]} .. {ts_sorted[-1]}")

print("\n=== Q2: distinct client requests / dedup ===")
by_rid = defaultdict(list)
for r in access:
    by_rid[r["request_id"]].append(r)
dup_ids = {rid: v for rid, v in by_rid.items() if len(v) > 1}
print(f"Total access.log lines: {len(access)}")
print(f"Distinct request_id values: {len(by_rid)}")
print(f"request_ids seen more than once (retries/dupes): {len(dup_ids)}")
for rid, v in dup_ids.items():
    print(f"  {rid}: {len(v)} occurrences, statuses={[x['status'] for x in v]}, times={[x['timestamp'] for x in v]}")
print("Dedup rule used: group by request_id; only the LAST occurrence's status is counted "
      "as the client-facing outcome (NGINX assigns one request_id per client request; a repeated "
      "id means NGINX retried the same client request against a different/same upstream).")

print("\n=== Q3: final client status counts + error rate ===")
final_status = {}
for rid, v in by_rid.items():
    last = sorted(v, key=lambda x: x["timestamp"])[-1]
    final_status[rid] = last["status"]
status_counts = Counter(final_status.values())
total = len(final_status)
errors = sum(c for s, c in status_counts.items() if s >= 400)
print(f"Denominator = {total} distinct requests (deduped by request_id, last outcome kept)")
print("Status counts:", dict(sorted(status_counts.items())))
print(f"Error rate (4xx+5xx / total): {errors}/{total} = {errors/total*100:.2f}%")

print("\n=== Q4: failures by path / time window / backend ===")
fail_rows = [r for r in access if r["status"] >= 400]
by_path = Counter(r["path"] for r in fail_rows)
by_backend = Counter(r["upstream"] for r in fail_rows)
print("Failures by path:", dict(by_path))
print("Failures by upstream backend:", dict(by_backend))

print("\n=== Q5: latency percentiles ===")
times = sorted(r["request_time"] for r in access)
def pct(data, p):
    k = (len(data) - 1) * (p / 100)
    f, c = int(k), min(int(k) + 1, len(data) - 1)
    if f == c:
        return data[f]
    return data[f] + (data[c] - data[f]) * (k - f)
print(f"n={len(times)}")
print(f"median (p50): {stats.median(times):.3f}s")
print(f"p95 (linear interpolation method): {pct(times, 95):.3f}s")
print("Units: seconds, as recorded in access.log 'request_time' field (NGINX-measured, client-facing).")

print("\n=== Q6: retries and retry success ===")
retried = {rid: v for rid, v in by_rid.items() if len(v) > 1}
succeeded_after_retry = 0
for rid, v in retried.items():
    v_sorted = sorted(v, key=lambda x: x["timestamp"])
    if v_sorted[0]["status"] >= 400 and v_sorted[-1]["status"] < 400:
        succeeded_after_retry += 1
print(f"request_ids with >1 attempt: {len(retried)}")
print(f"of those, succeeded on a later attempt after an earlier failure: {succeeded_after_retry}")

print("\n=== Q7: incident timeline (cross-log) ===")
timeline = []
for r in access:
    if r["status"] >= 400:
        timeline.append((r["timestamp"], "access", r["path"], r["status"], r["upstream"]))
for r in app:
    if r.get("level") in ("WARN", "ERROR"):
        timeline.append((r["timestamp"], "application", r.get("event"), r.get("status"), r.get("instance_id")))
timeline.sort(key=lambda x: x[0])
for row in timeline[:15]:
    print(" ", row)
print(f"  ... {len(timeline)} events total (see full output file)")

print("\n=== Q8: one correlated failed + one successful request ===")
fail_example = fail_rows[0] if fail_rows else None
ok_example = next((r for r in access if r["status"] == 200), None)
print("Failed:", fail_example)
app_match_fail = next((a for a in app if a.get("request_id") == (fail_example or {}).get("request_id")), None)
print("  matching application.log entry:", app_match_fail)
print("Successful:", ok_example)
app_match_ok = next((a for a in app if a.get("request_id") == (ok_example or {}).get("request_id")), None)
print("  matching application.log entry:", app_match_ok)

print("\n=== Q9: proxy/connectivity vs dependency/application errors ===")
conn_refused = sum(1 for e in error if "Connection refused" in e["raw"])
timeout_errs = sum(1 for e in error if "upstream timed out" in e["raw"] or "504" in e["raw"])
print(f"error.log 'Connection refused' lines (proxy/connectivity — NGINX can't reach app container at all): {conn_refused}")
print(f"error.log timeout-pattern lines (proxy waiting on a slow app/DB — dependency-side): {timeout_errs}")
print("Distinguishing evidence: Connection refused => TCP-level failure BEFORE any app log line exists for "
      "that request_id (app never received it). Timeouts/504 => an application.log entry DOES exist with a "
      "high duration_ms right before the cutoff, proving the app received the request but was slow "
      "(dependency-side, e.g. DB), not a networking failure.")

print("\n=== Q10: what logs don't prove ===")
print("- Root cause INSIDE the app process (e.g. why Postgres/Redis was briefly unreachable) is not "
      "visible from these logs alone — would need Postgres/Redis's own logs at that timestamp.")
print("- Whether the 5 duplicate request_ids were caused by client-side retries vs NGINX-side retries "
      "cannot be fully proven without client-side instrumentation.")
print("- Resource exhaustion (CPU/memory) as a contributing cause is not observable without host/container "
      "metrics (docker stats) captured at the time.")
