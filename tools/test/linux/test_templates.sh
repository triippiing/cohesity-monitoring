#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
units=$here/../../../linux/systemd; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in cohesity-collector.service cohesity-collector.timer cohesity-node-exporter.service cohesity-prometheus.service cohesity-grafana.service; do
  assert_file "$units/$f"
  render_template "$units/$f" "$tmp/$f" ROOT=/opt/sm USER=cohesity PWSH=/usr/bin/pwsh LISTEN=127.0.0.1:9182 RETENTION=180 INTERVAL=5 RUNTIME=240 \
    || { echo "FAIL render $f"; FAILED=1; }
  assert_not_grep "$tmp/$f" '__[A-Z]*__'
done
assert_grep "$tmp/cohesity-collector.service" '^ExecStart=/usr/bin/pwsh -NoProfile -NonInteractive -File /opt/sm/Export-CohesityMetrics.ps1 -All -NonInteractive$'
assert_grep "$tmp/cohesity-collector.service" '^RuntimeMaxSec=240$'
assert_grep "$tmp/cohesity-collector.service" '^TimeoutStartSec=240$'
assert_grep "$tmp/cohesity-collector.service" '^SuccessExitStatus=2$'
assert_grep "$tmp/cohesity-collector.timer" '^OnUnitActiveSec=5min$'
assert_grep "$tmp/cohesity-node-exporter.service" -- '--web.listen-address=127.0.0.1:9182'
assert_grep "$tmp/cohesity-prometheus.service" -- '--storage.tsdb.retention.time=180d --web.listen-address=127.0.0.1:9090'
assert_grep "$tmp/cohesity-grafana.service" '^Environment=GF_PATHS_LOGS=/opt/sm/grafana/data/log$'
for f in cohesity-collector.service cohesity-node-exporter.service cohesity-prometheus.service cohesity-grafana.service; do
  assert_grep "$tmp/$f" '^NoNewPrivileges=true$'; assert_grep "$tmp/$f" '^User=cohesity$'
done
exit "${FAILED:-0}"
