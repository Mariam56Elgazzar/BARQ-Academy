import json
from collections import Counter

print("=" * 70)
print("BARQ DEVOPS LOGS ANALYSIS")
print("=" * 70)

# Access Log
print("\n[1] ACCESS LOG ANALYSIS")
print("-" * 70)

try:
    with open('logs/access.log', 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    
    logs = []
    for line in lines:
        try:
            if line.strip():
                logs.append(json.loads(line))
        except:
            pass
    
    print(f"Total requests: {len(logs)}")
    
    status_codes = [log['status'] for log in logs]
    status_dist = Counter(status_codes)
    
    print(f"\nStatus Codes:")
    for status in sorted(status_dist.keys()):
        count = status_dist[status]
        print(f"  {status}: {count}")
    
    print(f"\nErrors by endpoint:")
    for log in logs:
        if log['status'] >= 400:
            print(f"  {log['timestamp']} | {log['path']} | Status: {log['status']}")
    
    request_ids = [log['request_id'] for log in logs]
    duplicates = {rid: count for rid, count in Counter(request_ids).items() if count > 1}
    print(f"\nDuplicate request IDs: {len(duplicates)}")
    if duplicates:
        for rid, count in list(duplicates.items())[:5]:
            print(f"    {rid}: {count}x")
    
except Exception as e:
    print(f"Error: {e}")

# Error Log
print("\n[2] ERROR LOG ANALYSIS")
print("-" * 70)

try:
    with open('logs/error.log', 'r', encoding='utf-8', errors='ignore') as f:
        error_lines = f.readlines()
    
    print(f"Total error lines: {len(error_lines)}")
    
    conn_refused = len([l for l in error_lines if 'Connection refused' in l])
    timeout_errors = len([l for l in error_lines if 'timed out' in l])
    
    print(f"Connection refused errors: {conn_refused}")
    print(f"Timeout errors: {timeout_errors}")
    
except Exception as e:
    print(f"Error: {e}")

print("\n" + "=" * 70)
