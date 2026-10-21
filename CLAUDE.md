# CLAUDE.md

Guidance for Claude Code (and people) working in this repository. Read README.md first: it is the
operator-facing document and describes the stack, install, maintenance and every metric.

## What this is

A monitoring package for Cohesity DataProtect clusters: a PowerShell collector polls each cluster's REST
API (v2 at `/v2`, v1 at `/irisservices/api/v1/public`) and writes Prometheus text files; windows_exporter,
Prometheus and Grafana run on one Windows host. A clone of this repository is an install folder. It is a
port of the StorSafe monitoring package and keeps its layout, installers, control scripts, theme and
dashboard style one-to-one, so both can run on one host (README: "Running next to StorSafe monitoring").
Target estate: several clusters (Cohesity 7.x), one monitoring host per site, collector running as a
scheduled task under Windows PowerShell 5.1. The same package also installs on one Linux host (RHEL
family 8/9, Debian 12, Ubuntu LTS; x86_64, systemd): `linux/install.sh` sets up node_exporter and systemd
units and a timer, and the collector runs under PowerShell 7 as the `cohesity` service account.

## Hard rules

- **Read-only against the clusters.** Every API call is a GET, plus in AuthMode Password the access-token
  login (`POST .../accessTokens`). `Invoke-CohesityApi` has no Method parameter on purpose. Never add
  calls that change cluster state or start work on it (refreshes, tests, downloads, cancels, config
  writes). The collector account is a Viewer-role user, so a write would fail anyway.
- **No secrets, no site data in git.** Credentials (API key, or user and password) live only in DPAPI
  files under `creds\` (`New-CohesityCredentialFile`), never in scripts, config or docs. (On Linux there is
  no DPAPI: the files are unencrypted Export-Clixml, protected by `creds/` mode 0700 and files 0600 owned
  by the service user.) `Cohesity.config.json` is git-ignored; only `Cohesity.config.example.json` with
  template names is committed. Never request `includeSourceCredentials` or `includeEncryptedCredentials`
  (the mock rejects both), and do not collect encryption keys, KMS settings, API keys or user lists.
- **Windows PowerShell 5.1 compatibility** for everything the scheduled task runs. No PowerShell 7-only
  syntax (`??`, ternary, `-Parallel`). Every query goes in the URL; no GET has a body. Test on `pwsh`
  here, but keep 5.1 in mind.
- **Install path without spaces**, `127.0.0.1` rather than `localhost` in URLs, and operators run
  things from cmd.exe: give `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` forms in docs.
- **Shell scripts** (`linux\`, `tools\test\linux\`): every script that is executed starts with
  `#!/usr/bin/env bash` and `set -euo pipefail`; the sourced libraries (`linux/lib.sh`,
  `tools/test/linux/helpers.sh`) carry the shebang only and set no options. All pass shellcheck with no
  warnings and keep LF endings (`.gitattributes` enforces that). Unit templates in `linux\systemd\` use
  only the placeholders `__ROOT__`, `__USER__`, `__PWSH__`, `__LISTEN__`, `__RETENTION__`, `__INTERVAL__`
  and `__RUNTIME__`; a placeholder left in a rendered unit is an installer error. Distro package names
  appear only in `icu_package_line` in `linux/install.sh` (the hint the PowerShell step prints).

## Layout

- Root: the package (`Export-CohesityMetrics.ps1` collector, `Cohesity.psm1` client, installer,
  `Get-CohesityInstallers.ps1`, `CohesityMonitoringControl.ps1`, report scripts, `monitoring\`).
- `linux\`: the Linux host: `install.sh` (`--collector-only` for a host that already runs Prometheus and
  Grafana), `get-installers.sh`, `cohesity-control.sh`, `lib.sh` (shared functions) and `systemd\` (unit and
  timer templates the installer renders). The install folder is the same package, extracted from the
  tar.gz or cloned to `/opt/cohesity-monitoring`; `monitoring\prometheus.yml` and the Grafana
  provisioning are shared with Windows. `node_exporter\`, `prometheus\` and `grafana\` are unpacked
  into it at install and are git-ignored.
- `tools\build-dashboards.py` generates `monitoring\dashboards\*.json` and, in `monitoring\dashboards-html\`, the
  variants that use the Business Text panel plugin (card sections: a row of stats drawn as one panel). **Edit the generator, never the
  JSON.** Colours come from `monitoring\theme.example.json`; `Publish-CohesityDashboards.ps1` (run by both
  installers) writes `monitoring\dashboards-live\`, the folder Grafana loads, in a site's git-ignored
  `monitoring\theme.json`. A site's brand, colours and logo never go in git. `tools\build-package.py` builds `dist\Cohesity-monitoring-v<VERSION>.zip` and `.tar.gz`.
- `tools\test\`: mock Cohesity API (`mock_api.py`), test config, dashboard query validator, README with
  the test procedure. No real cluster is needed or reachable from a cloud session.
- `tools\test\linux\`: tests of the Linux scripts (`run.sh` runs every `test_*.sh`) and `smoke.sh` (an
  install against the mock API). `.github\workflows\ci.yml` runs lint, the test kit, the container smoke
  tests and a full systemd install.
- `docs\`: API map and plan, review of the original scripts, dashboard design notes and decisions.
  `docs\images\`: README screenshots rendered from the mock API (template names only).

## How the collector is built

`$checks` is an ordered hashtable of script blocks, one per API area, each `param($c, $l, $x)`
(connection, base labels, per-cluster lookup cache: protection groups, policies, storage domains and the
24-hour runs summary are fetched once per cluster run and shared). Checks are independent: a failure sets
`cohesity_check_success{check} 0` and the rest continue. Emit metrics with `Add-Metric name help value
labels` and build labels with `New-Label $l 'k' v ...`. The base label is `cluster` (the config `Name`).
API times are microseconds (`*Usecs`, use `ConvertFrom-Usecs`) or milliseconds (`*Msecs`); v1
`usagePerfStats` I/O counters cover 30 seconds. Cadences: every run, 15 min, 60 min (cached in
`state\checkcache-*.json`). Per-cluster state in `state\` (`alerts-*` bookmark, seen ids and counters;
`runs-*` first-seen times of running runs). Per-run and per-group detail calls are capped (50 running
runs, 20 failed groups, 200 failed objects). Parallel mode spawns one child process per cluster with
`-Server` and `-FileName cohesity-<cluster>.prom`; collector-wide metrics are written only by the parent.

## Workflow for a change

1. Make the change; keep the style of the surrounding code (comment density, helper use, naming).
2. Run the test kit in `tools\test\README.md` (mock API, collector run, `promtool check metrics`,
   dashboard validator must report `errors 0`). Syntax-check every `.ps1`/`.psm1` with the PowerShell
   parser. If `linux\` changed, also run `bash tools/test/linux/run.sh` and shellcheck.
3. If a dashboard changed, regenerate with `python3 tools/build-dashboards.py` and commit the JSON.
4. If anything user-visible changed: bump `VERSION`, add a `CHANGELOG.md` entry, update README.md
   (metrics reference, settings table, cadence table) in the same commit.
5. Commit to `main` (or a branch and PR). Tags and GitHub Releases are created by the maintainer
   (`git tag -a vX.Y.Z` + push); the zip and tar.gz from `tools/build-package.py` are the release assets.

## Decisions already made (don't re-open without asking)

- Same stack and shape as StorSafe monitoring (collector → windows_exporter/node_exporter textfile →
  Prometheus → Grafana), no Alertmanager; alerting via Grafana rules (table in README).
- Config keeps StorSafe's `Servers` key and `-Server` parameters for parity; the metric label is
  `cluster`. Auth per cluster: `AuthMode` `ApiKey` (default, `apiKey` header) or `Password` (v1 access
  token, one re-login on 401).
- Dashboards: Fleet, Activity, Instance (cluster picker, one URL per cluster), Patch Management, Alerts
  (StorSafe's Events). Alerts are read from v1 `alerts`: open ones every run, new ones since the last run
  as counters and a daily CSV archive in `events\`.
- Helios (SaaS) is not used: the collector talks to each cluster directly.

## Testing notes

`pwsh` 7, Python 3 and a Prometheus/promtool binary are enough; see `tools\test\README.md`. The mock
serves one cluster per port (`mock_api.py 18080 18081`), accepts both auth modes (user `mon`, password
and API key `pw`), pages the protection groups, answers 405 to anything but GET and the login POST, and
with `--expire` expires the token once to exercise the re-login. Running the real collector against real
clusters is the maintainer's job; a cloud session cannot reach them.

`bash tools/test/linux/run.sh` needs `pwsh` on the `PATH`, the mock API on ports 18080-18081 and root (the
installer tests); the kit's `prometheus-test.yml` needs Prometheus 3. `smoke.sh` installs collector-only
into a temporary folder without systemd; `smoke.sh --services` installs the full stack as systemd
services in `/opt/cohesity-monitoring` and needs a systemd host (a throwaway VM or a CI runner).
