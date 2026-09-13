# Architecture

See `architecture.png` (or `architecture.pdf`) at the repository root for the full diagram.

It shows: client -> nginx (host port, currently 8080/8090) -> app-01/app-02(/app-03) round-robin,
apps -> postgres + redis over the backend network (service names, not container IPs),
the frontend/backend network split, the named postgres-data volume, and each service's
healthcheck relationship.

Remaining single points of failure not covered by this topology: single postgres instance
(no replication/failover), single redis instance, single nginx instance — see
security_review.md for production follow-ups.