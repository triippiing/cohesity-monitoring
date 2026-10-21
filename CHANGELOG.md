# Changelog

## 1.0.0 (2026-10-21)

First release: the StorSafe monitoring package (5.2.1) ported to Cohesity DataProtect, with the same layout, installers, control scripts, theme and dashboard style.

- Collector `Export-CohesityMetrics.ps1` for Cohesity clusters over the v2 and v1 public REST APIs, read-only (GETs, plus the access-token login in AuthMode Password). Checks for cluster health, capacity, performance, nodes, storage domains, protection groups and their last backup, replication and archive runs, runs in the last 24 hours and their progress, SLA, failed objects, recoveries, alerts, sources, external targets, views, antivirus, policies, remote clusters, capacity by consumer, licence and patches, on three cadences (every run, 15 and 60 minutes).
- Two auth modes per cluster: `ApiKey` (default) and `Password` (access token, one re-login on expiry). Credentials stay in DPAPI (Windows) or mode 0600 Export-Clixml (Linux) files under `creds\`.
- Alerts: open alerts by severity and category every run, the 20 newest open critical and warning alerts, counters of new alerts, and a daily raw CSV archive per cluster in `events\`.
- Reports: `Get-CohesityActivity.ps1` (runs, replication, archive, recoveries and cluster operations needing attention or in progress) and `Get-CohesityFailedObjects.ps1` (objects that failed or warned in each group's last run).
- Five dashboards with the StorSafe banner, pill section headers and Business Text card sections: Fleet, Activity, Instance, Patch Management and Alerts.
- Test kit: a mock Cohesity API (one cluster per port, both auth modes, paging, token expiry, refuses anything but GET and the login), the dashboard query validator and renderer, and the Linux script tests.
- Dashboard tables now place columns in the intended order after a rename (the organize transformation keys on the original field names), and progress bars are never coloured as a warning.
