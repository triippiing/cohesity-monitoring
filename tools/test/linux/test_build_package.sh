#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
tmp=$(mktemp -d); made_config=0
trap 'rm -rf "$tmp"; if [[ $made_config -eq 1 ]]; then rm -f "$repo/Cohesity.config.json"; fi' EXIT
repo=$here/../../..; ver=$(cat "$repo/VERSION")
# a site's config in the folder the archives are built from (a clone that runs as an install) must stay out of both
if [[ ! -e $repo/Cohesity.config.json ]]; then echo '{}' > "$repo/Cohesity.config.json"; made_config=1; fi
python3 "$repo/tools/build-package.py" > /dev/null
assert_file "$repo/dist/Cohesity-monitoring-v$ver.tar.gz"
tar -tzvf "$repo/dist/Cohesity-monitoring-v$ver.tar.gz" > "$tmp/list"
assert_grep "$tmp/list" '^-rwxr-xr-x .* CohesityMonitoring/linux/get-installers.sh$'
assert_grep "$tmp/list" '^-rw-r--r-- .* CohesityMonitoring/linux/systemd/cohesity-collector.timer$'
assert_grep "$tmp/list" ' CohesityMonitoring/Export-CohesityMetrics.ps1$'
assert_not_grep "$tmp/list" ' CohesityMonitoring/tools/'
assert_not_grep "$tmp/list" ' CohesityMonitoring/\.\(github\|superpowers\)/'
assert_grep "$tmp/list" ' CohesityMonitoring/monitoring/grafana/cohesity-datasource.yaml$'
python3 -c "import zipfile,sys; print('\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))" "$repo/dist/Cohesity-monitoring-v$ver.zip" > "$tmp/zlist"
zipn=$(grep -c . "$tmp/zlist")
assert_eq "$zipn" "$(grep -c '^-' "$tmp/list")" "the zip has as many entries as the tar has files"
assert_eq "$(grep -c . "$tmp/list")" "$(grep -c ' root/root ' "$tmp/list")" "every tar entry is owned by root/root"
# the tar names the folders, so root's umask cannot change the layout on extraction; the zip does not
assert_grep "$tmp/list" '^drwxr-xr-x .* CohesityMonitoring/monitoring/dashboards/$'
assert_grep "$tmp/list" '^drwxr-xr-x .* CohesityMonitoring/$'
assert_eq "$(grep -c '^d' "$tmp/list")" "$(grep -c '^drwxr-xr-x ' "$tmp/list")" "every tar folder is 0755"
# a folder comes before the files in it
first=$(grep -n ' CohesityMonitoring/monitoring/dashboards/$' "$tmp/list" | cut -d: -f1 || true)
second=$(grep -n -m 1 ' CohesityMonitoring/monitoring/dashboards/[^/][^/]*$' "$tmp/list" | cut -d: -f1 || true)
[[ -n $first && -n $second && $first -lt $second ]] || assert_fail "the dashboards folder entry precedes its files" "folder on line '$first', first file on line '$second'"
assert_not_grep "$tmp/list" ' CohesityMonitoring/Cohesity.config.json$'
assert_grep "$tmp/list" ' CohesityMonitoring/Cohesity.config.example.json$'
assert_not_grep "$tmp/zlist" '^CohesityMonitoring/Cohesity.config.json$'
assert_grep "$tmp/zlist" '^CohesityMonitoring/Cohesity.config.example.json$'
assert_grep "$repo/monitoring/prometheus.yml" "regex: 'cohesity_.\*|windows_textfile_.\*|node_textfile_.\*'"
assert_grep "$repo/.gitattributes" '^linux/\*\* text eol=lf$'
exit "${FAILED:-0}"
