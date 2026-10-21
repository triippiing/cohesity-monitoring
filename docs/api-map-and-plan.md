# API map and plan

`docs/api-map.html` is the full inventory of the read-only Cohesity endpoints (v2 and v1 public), grouped by area, that this package was planned from. This file records what the collector uses and why.

## Choices

- **Direct to each cluster, not Helios.** The same model as StorSafe: one monitoring host polls every cluster on its own management address. Helios would need an internet path and a different auth model.
- **v2 first, v1 where v2 has no equivalent.** v2 covers protection groups, runs, recoveries, sources, targets, storage domains, nodes, patches and views. v1 is still the only source for cluster capacity and performance counters (`cluster?fetchStats=true`), cluster service status, alerts, the alert and SLA summaries, archive (vault) usage, capacity by consumer and licence usage.
- **Read-only by construction.** `Cohesity.psm1` sends GETs only; the one POST is the access-token login in AuthMode Password. A Viewer-role account is enough for every call.
- **Bounded cost per run.** Protection groups come from one paged call with `includeLastRunInfo=true`, which carries each group's last backup, replication and archive result, so there is no per-group call in the normal case. Per-item calls are capped: run progress for up to 50 running runs, object detail for up to 20 failed or warned groups (200 objects).
- **Cadences.** Health, capacity, protection and alerts every run (5 minutes); inventory every 15 minutes; configuration, licence and patches every 60 minutes, cached in `state\` in between.

## Endpoints used

| Check | Endpoint |
|---|---|
| connect test | GET /v2/clusters/state |
| cluster | GET v1 /cluster?fetchStats=true |
| status | GET v1 /cluster/status |
| storage | GET /v2/stats/cluster-storage |
| nodes | GET /v2/clusters/nodes?fetchStats=true |
| storagedomains | GET /v2/storage-domains?includeStats=true |
| alertstats | GET v1 /stats/alerts |
| alerts | GET v1 /alerts?alertStateList=kOpen; GET v1 /alerts?startDateUsecs=...&endDateUsecs=... |
| protectiongroups | GET /v2/data-protect/protection-groups?includeLastRunInfo=true (paged) |
| runs | GET /v2/data-protect/runs/summary?startTimeUsecs=... |
| runprogress | GET /v2/data-protect/runs/{id}/progress |
| sla | GET v1 /stats/protectionRuns/lastRun |
| failedobjects | GET /v2/data-protect/protection-groups/{id}/runs?numRuns=1&includeObjectDetails=true |
| recoveries | GET /v2/data-protect/recoveries?startTimeUsecs=... |
| protectionsummary | GET v1 /stats/protectionSummary |
| sources | GET /v2/data-protect/sources/registrations |
| externaltargets | GET /v2/data-protect/external-targets |
| vaultstats | GET v1 /stats/vaults |
| views | GET /v2/file-services/views-summary |
| antivirus | GET /v2/antivirus-service/infected-files |
| policies | GET /v2/data-protect/policies |
| remoteclusters | GET /v2/remote-clusters |
| consumers | GET v1 /stats/consumers?consumerType=kProtectionRuns |
| license | GET v1 /licenseUsage |
| patches | GET /v2/patch-management/applied-patches; GET /v2/patch-management/available-patches |

v1 is `/irisservices/api/v1/public`.

## Not used, on purpose

Anything returning credentials (`includeSourceCredentials`, `includeEncryptedCredentials`), KMS and encryption keys, API keys, users and roles, audit logs, and every endpoint that starts work (source refresh, target tests, log or support bundle downloads).

## Possible later additions

Per-object protection history (`/v2/data-protect/objects/runs`), tenant breakdowns for multi-tenant clusters, DataLock/WORM retention reporting, and the Helios fleet APIs if a SaaS path is ever allowed.
