<#
.SYNOPSIS
Collects Cohesity cluster health, capacity, protection group runs, SLA, replication, archival, recoveries,
sources, alerts and configuration and writes them in Prometheus text format for the windows_exporter
(or node_exporter) textfile collector.

.DESCRIPTION
Read-only. Every call is a GET (v2 at /v2, v1 at /irisservices/api/v1/public), plus, in AuthMode Password,
the access-token login POST, which changes nothing on the cluster. Cohesity.psm1 has no way to send any other
method.

Run it from Task Scheduler (or the systemd timer) every 5 minutes with -All -NonInteractive (CredentialFile
per cluster in Cohesity.config.json). The .prom file is written to a temp name and renamed so that the
exporter never reads a half-written file.

Checks run on three cadences:
  - every run: cluster health and capacity, storage domains, nodes, protection groups and their last runs
    (local, replication, archival), runs in the last 24 hours, running-run progress, SLA, failed objects,
    recoveries, alerts;
  - every 15 minutes: protected/unprotected object summary, sources, external targets, archive usage, views,
    antivirus findings;
  - every 60 minutes: configuration and inventory that rarely changes (policies, remote clusters, capacity
    by consumer, licence, patches).
Results of the slower checks are cached in the state folder and re-emitted on the runs in between.

Settings (all optional, under Defaults in Cohesity.config.json):
  StateDirectory         'state'   collector state: alert bookmark, run first-seen times, check cache
  CollectAlerts          true      read new alerts every run (counters, recent list, raw archive)
  AlertLogDirectory      'events'  daily raw CSV archive of new alerts, per cluster
  AlertLogRetentionDays  90        archive files older than this are deleted
  DisabledChecks         []        check names to skip, e.g. ["antivirus","views"]

Output directory precedence: -TextfileDirectory, then Defaults.TextfileDirectory in the config
(relative paths resolve against the config file's folder), then the 'metrics' folder next to the config.

Parallel mode: with more than two clusters the collector runs one child process per cluster, -MaxParallel at a
time (default: one per four clusters, at most 8), each writing metrics\cohesity-<cluster>.prom; cohesity.prom then
only carries the collector's own summary. -MaxParallel 1 forces the single-process mode.

Exit codes: 0 all checks succeeded, 2 a cluster or check failed (metrics still written), 3 usage/config error.

.EXAMPLE
.\Export-CohesityMetrics.ps1 -All -NonInteractive
.EXAMPLE
.\Export-CohesityMetrics.ps1 -Server COHESITY-01 -TextfileDirectory .\out   # interactive test run
.EXAMPLE
.\Export-CohesityMetrics.ps1 -All -NonInteractive -Refresh   # ignore the cache and run every check now
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Server,
    [switch]$All,
    [PSCredential]$Credential,
    [switch]$NonInteractive,
    [string]$TextfileDirectory,
    [string]$FileName = 'cohesity.prom',
    [switch]$Refresh,
    [int]$MaxParallel = 0,

    [ValidateSet('http', 'https')][string]$Scheme,
    [int]$Port = -1,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$script:PackageVersion = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -ErrorAction Stop | Select-Object -First 1).Trim() } catch { 'unknown' }
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Cohesity.psm1') -Force -DisableNameChecking
} catch {
    [Console]::Error.WriteLine("ERROR: Cannot load Cohesity.psm1 from ${PSScriptRoot}: $($_.Exception.Message)")
    exit 3
}

try {
    if (-not $ConfigPath) { $ConfigPath = Get-CohesityDefaultConfigPath -ScriptRoot $PSScriptRoot }
    $config = Import-CohesityConfig -Path $ConfigPath

    foreach ($s in $config.Servers) {
        if ($Scheme) { $s.Scheme = $Scheme }
        if ($Port -ge 0) { $s.Port = $Port }
        if ($SkipCertificateCheck) { $s.SkipCertificateCheck = $true }
    }

    $selectedServers = @(Select-CohesityServer -Config $config -Server $Server -All:$All -NonInteractive:$NonInteractive)

    $credentialByName = @{}
    foreach ($s in $selectedServers) {
        $credentialByName[$s.Name] = Get-CohesityCredential -ServerConfig $s -Credential $Credential -NonInteractive:$NonInteractive
    }

    if (-not $TextfileDirectory) { $TextfileDirectory = $config.TextfileDirectory }
    foreach ($dir in @($TextfileDirectory, $config.StateDirectory)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
} catch {
    Write-CohesityUsageError $_.Exception.Message
    exit 3
}

# ---------------------------------------------------------------------------
# Metric builder: keeps HELP/TYPE once per metric family, in first-seen order.
# While a cached check runs, $script:capture records its samples so they can be replayed later.
# ---------------------------------------------------------------------------
$families = [ordered]@{}
$script:capture = $null

function ConvertTo-LabelValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

function Add-Sample {
    param([string]$Name, [string]$Help, [string]$Type, [string]$Line)
    if (-not $families.Contains($Name)) {
        $families[$Name] = [pscustomobject]@{ Help = $Help; Type = $Type; Samples = [System.Collections.Generic.List[string]]::new() }
    }
    $families[$Name].Samples.Add($Line)
}

function Add-Metric {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Help,
        [Parameter(Mandatory)][AllowNull()]$Value,
        [System.Collections.IDictionary]$Labels = @{},
        [string]$Type = 'gauge'
    )
    if ($null -eq $Value -or [string]$Value -eq '') { return }
    $number = 0.0
    if ($Value -is [bool]) { $number = [double][int]$Value }
    elseif (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return }

    $labelText = ''
    if ($Labels.Count -gt 0) {
        $pairs = foreach ($key in $Labels.Keys) { '{0}="{1}"' -f $key, (ConvertTo-LabelValue $Labels[$key]) }
        $labelText = '{' + ($pairs -join ',') + '}'
    }
    $line = '{0}{1} {2}' -f $Name, $labelText, $number.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    Add-Sample $Name $Help $Type $line
    if ($null -ne $script:capture) { $script:capture.Add([pscustomobject]@{ n = $Name; h = $Help; t = $Type; s = $line }) }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$v1 = '/irisservices/api/v1/public'

function Get-Prop {
    # Dotted path lookup that tolerates missing properties: Get-Prop $obj 'stats.usagePerfStats.readIos'.
    # Arrays are unrolled, so wrap the call in @() when a list is expected.
    param($Object, [string]$Path, $Default = $null)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Get-Array {
    # A list property of a response (Get-Array $r 'protectionGroups'), or the response itself when it is a bare JSON array.
    # Read the property directly: returning it through a function would unroll a one-element array.
    param($Response, [string]$Name)
    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Array]) { return $Response }
    if (-not $Name) { return @($Response) }
    $property = $Response.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

function Get-CleanState {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().ToLowerInvariant()
}

function ConvertTo-Env {
    # kVMware -> vmware, kPhysicalFiles -> physicalfiles: the environment label without Cohesity's k prefix.
    param($Value)
    $text = [string]$Value
    if ($text -cmatch '^k[A-Z]') { $text = $text.Substring(1) }
    return $text.ToLowerInvariant()
}

function ConvertTo-Flag {
    # true/false in any of the forms the API uses (bool, "true", 1) -> 1/0; anything else -> $null.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [int]$Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('true', '1', 'yes', 'enabled', 'on')) { return 1 }
    if ($text -in @('false', '0', 'no', 'disabled', 'off')) { return 0 }
    return $null
}

function ConvertFrom-Usecs {
    # Microseconds since the epoch (or a duration in microseconds) -> seconds; 0 or missing -> $null.
    param($Value)
    if ($null -eq $Value -or [double]$Value -le 0) { return $null }
    return [Math]::Floor([double]$Value / 1000000)
}

function Get-Duration {
    param($StartUsecs, $EndUsecs)
    if ($null -eq $StartUsecs -or $null -eq $EndUsecs -or [double]$StartUsecs -le 0 -or [double]$EndUsecs -lt [double]$StartUsecs) { return $null }
    return ([double]$EndUsecs - [double]$StartUsecs) / 1000000
}

function Get-ShortText {
    param($Text, [int]$Max = 200)
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...' }
    return $t
}

function Add-Count {
    param([hashtable]$Table, $Key, [double]$Amount = 1)
    if ($Table.ContainsKey($Key)) { $Table[$Key] += $Amount } else { $Table[$Key] = $Amount }
}

function New-Label {
    # New-Label $l 'group' $name 'status' $status -> [ordered]@{ cluster = ...; group = ...; status = ... }
    $labels = [ordered]@{ cluster = $args[0].cluster }
    for ($i = 1; $i -lt $args.Count; $i += 2) { $labels[[string]$args[$i]] = $args[$i + 1] }
    return $labels
}

function Get-SafeFileName {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9._-]', '_')
}

function Read-JsonState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { Write-Warning "Ignoring unreadable state file ${Path}: $($_.Exception.Message)"; return $null }
}

function Write-JsonState {
    param([string]$Path, $Object)
    $temp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($temp, ($Object | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Get-UsecsAgo {
    param([double]$Hours)
    return [long](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $Hours * 3600000) * 1000)
}

function Update-FirstSeen {
    # Remembers when the collector first saw each key (e.g. a running run or recovery); keys no longer present
    # are dropped. Returns key -> Unix time.
    param([string]$Path, [string[]]$Keys)
    $now = Get-UnixNow
    $old = @{}
    $saved = Read-JsonState $Path
    if ($null -ne $saved) { foreach ($p in $saved.PSObject.Properties) { $old[$p.Name] = [long]$p.Value } }
    $current = [ordered]@{}
    foreach ($k in $Keys) {
        if (-not $k -or $current.Contains($k)) { continue }
        $current[$k] = if ($old.ContainsKey($k)) { $old[$k] } else { $now }
    }
    Write-JsonState $Path $current
    return $current
}

# Lookups shared between checks within one cluster run ($x is a per-cluster hashtable).
function Get-Groups {
    param($c, [hashtable]$x)
    if (-not $x.ContainsKey('Groups')) {
        $x.Groups = @(Get-CohesityPagedCollection -Connection $c -CollectionName 'protectionGroups' `
            -Path '/v2/data-protect/protection-groups?isDeleted=false&includeLastRunInfo=true&pruneSourceIds=true&pruneExcludedSourceIds=true&includeTenants=true')
    }
    return $x.Groups
}

function Get-PolicyNames {
    param($c, [hashtable]$x)
    if (-not $x.ContainsKey('PolicyNames')) {
        $names = @{}
        $x.Policies = @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/data-protect/policies?includeTenants=true') 'policies')
        foreach ($p in $x.Policies) { $names[[string](Get-OptionalValue $p 'id' '')] = [string](Get-OptionalValue $p 'name' '') }
        $x.PolicyNames = $names
    }
    return $x.PolicyNames
}

function Get-DomainNames {
    param($c, [hashtable]$x)
    if (-not $x.ContainsKey('DomainNames')) {
        $names = @{}
        try {
            foreach ($d in @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/storage-domains') 'storageDomains')) {
                $names[[string](Get-OptionalValue $d 'id' '')] = [string](Get-OptionalValue $d 'name' '')
            }
        } catch { Write-Verbose "storage domain names: $($_.Exception.Message)" }
        $x.DomainNames = $names
    }
    return $x.DomainNames
}

function Get-RunsSummary {
    # Every run that started in the last 24 hours (v2 runs summary), fetched once per cluster run.
    param($c, [hashtable]$x)
    if (-not $x.ContainsKey('Runs')) {
        $x.Runs = @(Get-Array (Invoke-CohesityApi -Connection $c -Path ('/v2/data-protect/runs/summary?startTimeUsecs={0}' -f (Get-UsecsAgo 24))) 'protectionRunsSummary')
    }
    return $x.Runs
}

# Run states that mean "in progress" (the v2 status enum: Accepted, Running, Canceled, Canceling, Failed, Missed,
# Succeeded, SucceededWithWarning, OnHold, Finalizing, Skipped, Paused).
$activeRunStates = @('accepted', 'running', 'canceling', 'onhold', 'finalizing', 'paused')

# Per-run and per-group detail calls are capped so a busy cluster cannot blow the collection interval.
$maxRunDetails = 50
$maxFailedGroups = 20
$maxFailedObjects = 200

function Add-RunTargetMetrics {
    # Replication and archival results of one run (a group's last run): one series set per target.
    param($l, [string]$Group, $Run)
    foreach ($t in @(Get-Prop $Run 'replicationInfo.replicationTargetResults' @())) {
        $tl = New-Label $l 'group' $Group 'target' (Get-OptionalValue $t 'clusterName' '')
        Add-Metric 'cohesity_replication_last_status' 'Status of the group''s last replication to this target (1 for the current status label).' 1 (New-Label $l 'group' $Group 'target' (Get-OptionalValue $t 'clusterName' '') 'status' (Get-CleanState (Get-OptionalValue $t 'status' '')))
        Add-Metric 'cohesity_replication_last_start_timestamp_seconds' 'Start of the group''s last replication to this target (Unix time).' (ConvertFrom-Usecs (Get-OptionalValue $t 'startTimeUsecs' $null)) $tl
        Add-Metric 'cohesity_replication_last_end_timestamp_seconds' 'End of the group''s last replication to this target (Unix time; absent while it runs).' (ConvertFrom-Usecs (Get-OptionalValue $t 'endTimeUsecs' $null)) $tl
        Add-Metric 'cohesity_replication_last_sla_violated' 'The group''s last replication to this target violated its SLA (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $t 'isSlaViolated' $null)) $tl
        Add-Metric 'cohesity_replication_last_percent' 'Progress of the group''s last replication to this target, in percent.' (Get-OptionalValue $t 'percentageCompleted' $null) $tl
        Add-Metric 'cohesity_replication_last_logical_bytes' 'Logical bytes transferred by the group''s last replication to this target.' (Get-Prop $t 'stats.logicalBytesTransferred' $null) $tl
        Add-Metric 'cohesity_replication_last_physical_bytes' 'Physical bytes transferred by the group''s last replication to this target.' (Get-Prop $t 'stats.physicalBytesTransferred' $null) $tl
    }
    foreach ($t in @(Get-Prop $Run 'archivalInfo.archivalTargetResults' @())) {
        $tl = New-Label $l 'group' $Group 'target' (Get-OptionalValue $t 'targetName' '')
        Add-Metric 'cohesity_archive_last_status' 'Status of the group''s last archive to this target (1 for the current status label).' 1 (New-Label $l 'group' $Group 'target' (Get-OptionalValue $t 'targetName' '') 'target_type' (Get-OptionalValue $t 'targetType' '') 'status' (Get-CleanState (Get-OptionalValue $t 'status' '')))
        Add-Metric 'cohesity_archive_last_start_timestamp_seconds' 'Start of the group''s last archive to this target (Unix time).' (ConvertFrom-Usecs (Get-OptionalValue $t 'startTimeUsecs' $null)) $tl
        Add-Metric 'cohesity_archive_last_end_timestamp_seconds' 'End of the group''s last archive to this target (Unix time; absent while it runs).' (ConvertFrom-Usecs (Get-OptionalValue $t 'endTimeUsecs' $null)) $tl
        Add-Metric 'cohesity_archive_last_sla_violated' 'The group''s last archive to this target violated its SLA (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $t 'isSlaViolated' $null)) $tl
        Add-Metric 'cohesity_archive_last_logical_bytes' 'Logical bytes transferred by the group''s last archive to this target.' (Get-Prop $t 'stats.logicalBytesTransferred' $null) $tl
        Add-Metric 'cohesity_archive_last_physical_bytes' 'Physical bytes transferred by the group''s last archive to this target.' (Get-Prop $t 'stats.physicalBytesTransferred' $null) $tl
        Add-Metric 'cohesity_archive_last_transfer_rate_bytes_per_second' 'Average logical transfer rate of the group''s last archive to this target.' (Get-Prop $t 'stats.avgLogicalTransferRateBps' $null) $tl
    }
}

# ---------------------------------------------------------------------------
# Alerts: open alerts every run (counts and the 20 most recent critical/warning), plus new alerts since the last
# run (counters by severity and a raw daily CSV archive, like an event log).
# ---------------------------------------------------------------------------
function ConvertTo-Severity {
    param($Value)
    switch -Regex (Get-CleanState $Value) {
        'crit' { return 'critical' }
        'warn' { return 'warning' }
        'info' { return 'info' }
    }
    $s = Get-CleanState $Value
    if ($s) { return $s }
    return 'unknown'
}

function ConvertTo-CsvField {
    param($Value)
    return '"' + ([string]$Value).Replace('"', '""').Replace("`r", ' ').Replace("`n", ' ') + '"'
}

function Invoke-AlertCheck {
    param($c, $l, [hashtable]$x)
    $clusterFile = Get-SafeFileName $l.cluster
    $statePath = Join-Path $config.StateDirectory ("alerts-{0}.json" -f $clusterFile)
    $state = Read-JsonState $statePath
    $counts = @{}; $seen = @{}; $since = Get-UsecsAgo 24
    if ($null -ne $state) {
        $since = [long](Get-OptionalValue $state 'SinceUsecs' $since)
        $countsObj = Get-OptionalValue $state 'Counts' $null
        if ($null -ne $countsObj) { foreach ($p in $countsObj.PSObject.Properties) { $counts[$p.Name] = [double]$p.Value } }
        foreach ($id in @(Get-OptionalValue $state 'SeenIds' @())) { $seen[[string]$id] = $true }
    }

    # Open alerts: counts by severity and category, and the newest critical/warning ones for the dashboards.
    $open = @(Get-Array (Invoke-CohesityApi -Connection $c -Path "$v1/alerts?maxAlerts=1000&alertStateList=kOpen") '')
    $openCounts = @{}
    foreach ($sev in @('critical', 'warning', 'info')) { $openCounts["$sev|"] = 0 }
    foreach ($a in $open) {
        $sev = ConvertTo-Severity (Get-OptionalValue $a 'severity' '')
        Add-Count $openCounts ("{0}|{1}" -f $sev, (ConvertTo-Env (Get-OptionalValue $a 'alertCategory' '')))
    }
    $bySeverity = @{ critical = 0; warning = 0; info = 0 }
    foreach ($key in $openCounts.Keys) {
        $sev, $category = $key.Split('|', 2)
        Add-Count $bySeverity $sev $openCounts[$key]
        if ($category) { Add-Metric 'cohesity_alerts_open_by_category' 'Open alerts by severity and category.' $openCounts[$key] (New-Label $l 'severity' $sev 'category' $category) }
    }
    foreach ($sev in $bySeverity.Keys) { Add-Metric 'cohesity_alerts_open' 'Open alerts by severity.' $bySeverity[$sev] (New-Label $l 'severity' $sev) }
    $recent = @($open | Where-Object { (ConvertTo-Severity (Get-OptionalValue $_ 'severity' '')) -in @('critical', 'warning') } |
        Sort-Object { [double](Get-OptionalValue $_ 'latestTimestampUsecs' 0) } -Descending | Select-Object -First 20)
    foreach ($a in $recent) {
        Add-Metric 'cohesity_alert_recent' 'Newest open critical and warning alerts (value is the latest occurrence as Unix time).' (ConvertFrom-Usecs (Get-OptionalValue $a 'latestTimestampUsecs' $null)) (New-Label $l `
            'severity' (ConvertTo-Severity (Get-OptionalValue $a 'severity' '')) 'category' (ConvertTo-Env (Get-OptionalValue $a 'alertCategory' '')) `
            'code' (Get-OptionalValue $a 'alertCode' '') 'name' (Get-Prop $a 'alertDocument.alertName' '') 'id' (Get-OptionalValue $a 'id' '') `
            'message' (Get-ShortText (Get-Prop $a 'alertDocument.alertDescription' '')) 'occurrences' (Get-OptionalValue $a 'dedupCount' ''))
    }

    # New alerts (any state) first raised since the last run. The window overlaps by an hour and ids already seen are skipped.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000
    $fresh = @(Get-Array (Invoke-CohesityApi -Connection $c -Path ("$v1/alerts?maxAlerts=1000&startDateUsecs={0}&endDateUsecs={1}" -f ($since - 3600000000), $now)) '')
    $newRows = @($fresh | Where-Object { -not $seen.ContainsKey([string](Get-OptionalValue $_ 'id' '')) } | Sort-Object { [double](Get-OptionalValue $_ 'firstTimestampUsecs' 0) })
    $newBySeverity = @{}
    foreach ($a in $newRows) {
        $sev = ConvertTo-Severity (Get-OptionalValue $a 'severity' '')
        Add-Count $counts $sev
        Add-Count $newBySeverity $sev
    }

    # Raw archive: one CSV per cluster per day (collector's date), header written once.
    if ($newRows.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $config.AlertLogDirectory -PathType Container)) { New-Item -ItemType Directory -Path $config.AlertLogDirectory -Force | Out-Null }
        $archive = Join-Path $config.AlertLogDirectory ("Cohesity-Alerts-{0}-{1}.csv" -f $clusterFile, (Get-Date -Format 'yyyyMMdd'))
        $out = [System.Collections.Generic.List[string]]::new()
        if (-not (Test-Path -LiteralPath $archive)) { $out.Add('"FirstSeen","Latest","Severity","State","Category","Code","Id","Name","Description"') }
        foreach ($a in $newRows) {
            $out.Add((@((ConvertFrom-CohesityUsecs (Get-OptionalValue $a 'firstTimestampUsecs' $null)), (ConvertFrom-CohesityUsecs (Get-OptionalValue $a 'latestTimestampUsecs' $null)),
                (ConvertTo-Severity (Get-OptionalValue $a 'severity' '')), (Get-OptionalValue $a 'alertState' ''), (Get-OptionalValue $a 'alertCategory' ''),
                (Get-OptionalValue $a 'alertCode' ''), (Get-OptionalValue $a 'id' ''), (Get-Prop $a 'alertDocument.alertName' ''),
                (Get-Prop $a 'alertDocument.alertDescription' '')) | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
        }
        [System.IO.File]::AppendAllText($archive, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $cutoff = (Get-Date).AddDays(-$config.AlertLogRetentionDays)
        Get-ChildItem -LiteralPath $config.AlertLogDirectory -Filter ("Cohesity-Alerts-{0}-*.csv" -f $clusterFile) -File |
            Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    foreach ($sev in @('critical', 'warning', 'info')) { if (-not $counts.ContainsKey($sev)) { $counts[$sev] = 0 } }
    foreach ($sev in $counts.Keys) {
        Add-Metric 'cohesity_alerts_total' 'Alerts raised, seen by the collector, by severity (counter since the state file was created).' $counts[$sev] (New-Label $l 'severity' $sev) 'counter'
        $n = if ($newBySeverity.ContainsKey($sev)) { $newBySeverity[$sev] } else { 0 }
        Add-Metric 'cohesity_alerts_new' 'Alerts first seen in this collector run, by severity.' $n (New-Label $l 'severity' $sev)
    }

    $ids = @($fresh | ForEach-Object { [string](Get-OptionalValue $_ 'id' '') } | Where-Object { $_ })
    Write-JsonState $statePath ([ordered]@{ SinceUsecs = $now; Counts = $counts; SeenIds = @($ids | Select-Object -Last 5000) })
}

# ---------------------------------------------------------------------------
# Checks. Each is independent; a failure is recorded in cohesity_check_success and does not stop the others.
# Each scriptblock gets ($c = connection, $l = base labels, $x = per-cluster lookup cache).
# ---------------------------------------------------------------------------
$checks = [ordered]@{
    # ---- Cluster health and capacity (every run) ----
    'cluster' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path "$v1/cluster?fetchStats=true"
        $info = New-Label $l 'name' (Get-OptionalValue $r 'name' '') 'id' (Get-OptionalValue $r 'id' '') 'version' (Get-OptionalValue $r 'clusterSoftwareVersion' '') `
            'patch' (Get-OptionalValue $r 'patchVersion' '') 'type' (ConvertTo-Env (Get-OptionalValue $r 'clusterType' '')) 'deployment' (ConvertTo-Env (Get-OptionalValue $r 'clusterDeploymentType' ''))
        Add-Metric 'cohesity_info' 'Cluster name, id, software version and patch (value is always 1).' 1 $info
        Add-Metric 'cohesity_cluster_nodes' 'Nodes in the cluster.' (Get-OptionalValue $r 'nodeCount' $null) (New-Label $l)
        Add-Metric 'cohesity_cluster_encryption_enabled' 'Encryption at rest enabled.' (ConvertTo-Flag (Get-OptionalValue $r 'encryptionEnabled' $null)) (New-Label $l)
        Add-Metric 'cohesity_cluster_upgrade_aborted' 'The last software upgrade was aborted (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $r 'isUpgradeAborted' $null)) (New-Label $l)
        Add-Metric 'cohesity_cluster_patch_apply_aborted' 'The last patch apply was aborted (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $r 'isPatchApplyAborted' $null)) (New-Label $l)
        $clock = Get-OptionalValue $r 'currentTimeMsecs' $null
        if ($null -ne $clock) {
            Add-Metric 'cohesity_time_seconds' 'Cluster clock (Unix time).' ([double]$clock / 1000) (New-Label $l)
            Add-Metric 'cohesity_time_offset_seconds' 'Cluster clock minus the collector host clock, in seconds.' ([double]$clock / 1000 - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000) (New-Label $l)
        }
        # usagePerfStats: the I/O counters cover the last 30 seconds, so divide by 30 for per-second rates.
        $u = Get-Prop $r 'stats.usagePerfStats' $null
        Add-Metric 'cohesity_cluster_capacity_bytes' 'Physical capacity of all storage devices, after space reserved for cluster services.' (Get-OptionalValue $u 'physicalCapacityBytes' $null) (New-Label $l)
        Add-Metric 'cohesity_cluster_usable_capacity_bytes' 'Minimum usable capacity after erasure coding or replication factor.' (Get-OptionalValue $u 'minUsablePhysicalCapacityBytes' $null) (New-Label $l)
        Add-Metric 'cohesity_cluster_used_bytes' 'Data stored locally after deduplication and compression, including resiliency (EC/RF).' (Get-OptionalValue $u 'totalPhysicalUsageBytes' $null) (New-Label $l)
        Add-Metric 'cohesity_cluster_system_capacity_bytes' 'Capacity as computed by statfs.' (Get-OptionalValue $u 'systemCapacityBytes' $null) (New-Label $l)
        Add-Metric 'cohesity_cluster_system_used_bytes' 'Usage as computed by statfs.' (Get-OptionalValue $u 'systemUsageBytes' $null) (New-Label $l)
        foreach ($io in @(@('read', 'numBytesRead', 'readIos', 'readLatencyMsecs'), @('write', 'numBytesWritten', 'writeIos', 'writeLatencyMsecs'))) {
            $bytes = Get-OptionalValue $u $io[1] $null; $ios = Get-OptionalValue $u $io[2] $null; $lat = Get-OptionalValue $u $io[3] $null
            Add-Metric 'cohesity_cluster_throughput_bytes_per_second' 'Cluster throughput over the last 30 seconds.' $(if ($null -ne $bytes) { [double]$bytes / 30 }) (New-Label $l 'op' $io[0])
            Add-Metric 'cohesity_cluster_iops' 'Cluster I/O operations per second over the last 30 seconds.' $(if ($null -ne $ios) { [double]$ios / 30 }) (New-Label $l 'op' $io[0])
            Add-Metric 'cohesity_cluster_latency_seconds' 'Cluster I/O latency over the last 30 seconds.' $(if ($null -ne $lat) { [double]$lat / 1000 }) (New-Label $l 'op' $io[0])
        }
        Add-Metric 'cohesity_cluster_data_reduction_ratio' 'Data reduction ratio (logical data in / physical data written), N:1.' (Get-Prop $r 'stats.dataReductionRatio' $null) (New-Label $l)
        $d = Get-Prop $r 'stats.dataUsageStats' $null
        foreach ($kind in @(@('data_in', 'dataInBytes'), @('data_in_after_dedup', 'dataInBytesAfterDedup'), @('data_written', 'dataWrittenBytes'),
                            @('local_written', 'localDataWrittenBytes'), @('cloud_written', 'cloudDataWrittenBytes'), @('logical', 'totalLogicalUsageBytes'),
                            @('consumed', 'storageConsumedBytes'), @('local_physical', 'localTotalPhysicalUsageBytes'), @('cloud_physical', 'cloudTotalPhysicalUsageBytes'))) {
            Add-Metric 'cohesity_cluster_data_bytes' 'Cluster data usage by kind (data_in = before reduction; data_written = after dedupe and compression).' (Get-OptionalValue $d $kind[1] $null) (New-Label $l 'kind' $kind[0])
        }
    }
    'status' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path "$v1/cluster/status"
        $stopped = @(Get-Array $r 'stoppedServices')
        Add-Metric 'cohesity_cluster_stopped_services' 'Cluster services that are stopped (0 on a healthy cluster).' $stopped.Count (New-Label $l)
        foreach ($svc in $stopped) { Add-Metric 'cohesity_cluster_stopped_service' 'A stopped cluster service (value is always 1).' 1 (New-Label $l 'service' (ConvertTo-Env $svc)) }
        Add-Metric 'cohesity_cluster_services_synced' 'Services are in sync across nodes (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $r 'servicesSynced' $null)) (New-Label $l)
        $op = ConvertTo-Env (Get-OptionalValue $r 'currentOperation' 'kNone')
        Add-Metric 'cohesity_cluster_operation' 'Operation in progress on the cluster (1 for the current label; none when idle).' 1 (New-Label $l 'operation' $op)
        foreach ($n in @(Get-Array $r 'nodeStatuses')) {
            $nl = New-Label $l 'node_id' (Get-OptionalValue $n 'id' '') 'ip' (Get-OptionalValue $n 'ip' '')
            Add-Metric 'cohesity_node_in_cluster' 'Node is part of the cluster (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $n 'inCluster' $null)) $nl
            Add-Metric 'cohesity_node_maintenance_mode' 'Node is in maintenance mode (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $n 'inMaintenanceMode' $null)) $nl
            Add-Metric 'cohesity_node_marked_for_removal' 'Node is marked for removal (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $n 'markedForRemoval' $null)) $nl
            Add-Metric 'cohesity_node_last_upgrade_timestamp_seconds' 'When the node was last upgraded (Unix time).' (Get-OptionalValue $n 'lastUpgradeTimeSecs' $null) $nl
            Add-Metric 'cohesity_node_status_info' 'Node software version, active operation and uptime text (value is always 1).' 1 (New-Label $l 'node_id' (Get-OptionalValue $n 'id' '') 'ip' (Get-OptionalValue $n 'ip' '') `
                'version' (Get-OptionalValue $n 'softwareVersion' '') 'operation' (ConvertTo-Env (Get-OptionalValue $n 'activeOperation' '')) 'uptime' (Get-OptionalValue $n 'uptime' ''))
        }
    }
    'storage' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path '/v2/stats/cluster-storage'
        Add-Metric 'cohesity_storage_capacity_bytes' 'Total capacity of the cluster.' (Get-OptionalValue $r 'totalCapacityBytes' $null) (New-Label $l)
        Add-Metric 'cohesity_storage_used_bytes' 'Local storage in use.' (Get-OptionalValue $r 'localUsageBytes' $null) (New-Label $l)
        Add-Metric 'cohesity_storage_available_bytes' 'Local storage available.' (Get-OptionalValue $r 'localAvailableBytes' $null) (New-Label $l)
        foreach ($k in @(@('data_protect', 'logical', 'dataProtectionLogicalUsageBytes'), @('data_protect', 'physical', 'dataProtectionPhysicalUsageBytes'),
                         @('file_services', 'logical', 'fileServicesLogicalUsageBytes'), @('file_services', 'physical', 'fileServicesPhysicalUsageBytes'))) {
            Add-Metric 'cohesity_storage_service_bytes' 'Storage used by service (data protection, file services), logical and physical.' (Get-OptionalValue $r $k[2] $null) (New-Label $l 'service' $k[0] 'kind' $k[1])
        }
    }
    'nodes' = {
        param($c, $l, $x)
        foreach ($n in @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/clusters/nodes?fetchStats=true') '')) {
            $name = [string](Get-OptionalValue $n 'hostName' (Get-OptionalValue $n 'ip' (Get-OptionalValue $n 'id' '')))
            $nl = New-Label $l 'node' $name
            Add-Metric 'cohesity_node_info' 'Node identity, model and software version (value is always 1).' 1 (New-Label $l 'node' $name 'node_id' (Get-OptionalValue $n 'id' '') 'ip' (Get-OptionalValue $n 'ip' '') `
                'version' (Get-OptionalValue $n 'nodeSoftwareVersion' '') 'model' (Get-OptionalValue $n 'productModel' '') 'hardware' (Get-OptionalValue $n 'hardwareModel' '') `
                'serial' (Get-OptionalValue $n 'cohesityNodeSerial' '') 'type' (Get-OptionalValue $n 'nodeType' ''))
            Add-Metric 'cohesity_node_offline_disks' 'Offline disks in the node.' (Get-OptionalValue $n 'offlineDiskCount' 0) $nl
            Add-Metric 'cohesity_node_capacity_bytes' 'Maximum physical capacity of the node.' (Get-OptionalValue $n 'maxPhysicalCapacityBytes' $null) $nl
            Add-Metric 'cohesity_node_used_bytes' 'Data stored on the node after reduction, including resiliency.' (Get-Prop $n 'stats.usagePerfStats.totalPhysicalUsageBytes' $null) $nl
            Add-Metric 'cohesity_node_removal' 'Node removal state (1 for the current label; dontremove is normal).' 1 (New-Label $l 'node' $name 'state' (Get-CleanState (Get-OptionalValue $n 'removalState' 'DontRemove')))
            foreach ($t in @(Get-Array $n 'diskCountByTier')) {
                Add-Metric 'cohesity_node_disks' 'Disks in the node by storage tier.' (Get-OptionalValue $t 'count' $null) (New-Label $l 'node' $name 'tier' (Get-OptionalValue $t 'storageTier' ''))
            }
        }
    }
    'storagedomains' = {
        param($c, $l, $x)
        foreach ($d in @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/storage-domains?includeStats=true&includeTenants=true') 'storageDomains')) {
            $name = [string](Get-OptionalValue $d 'name' '')
            $dl = New-Label $l 'domain' $name
            Add-Metric 'cohesity_storage_domain_info' 'Storage domain (View Box) settings (value is always 1).' 1 (New-Label $l 'domain' $name 'domain_id' (Get-OptionalValue $d 'id' '') `
                'partition' (Get-OptionalValue $d 'clusterPartitionName' '') 'encryption' (Get-Prop $d 'storagePolicy.encryptionType' '') `
                'node_failures_tolerated' (Get-Prop $d 'storagePolicy.numNodeFailuresTolerated' '') 'disk_failures_tolerated' (Get-Prop $d 'storagePolicy.numDiskFailuresTolerated' ''))
            Add-Metric 'cohesity_storage_domain_quota_bytes' 'Physical quota (hard limit) of the storage domain.' (Get-Prop $d 'physicalQuota.hardLimitBytes' $null) $dl
            Add-Metric 'cohesity_storage_domain_quota_alert_bytes' 'Physical quota alert limit of the storage domain.' (Get-Prop $d 'physicalQuota.alertLimitBytes' $null) $dl
            $s = Get-OptionalValue $d 'stats' $null
            foreach ($kind in @(@('logical', 'totalLogicalUsageBytes'), @('data_in', 'dataInBytes'), @('data_in_after_dedup', 'dataInBytesAfterDedup'),
                                @('data_written', 'dataWrittenBytes'), @('local_physical', 'localTotalPhysicalUsageBytes'), @('cloud_physical', 'cloudTotalPhysicalUsageBytes'),
                                @('consumed', 'storageConsumedBytes'), @('unique_physical', 'uniquePhysicalDataBytes'))) {
                Add-Metric 'cohesity_storage_domain_bytes' 'Storage domain usage by kind (data_in before reduction, data_in_after_dedup after dedupe, data_written after dedupe and compression).' (Get-OptionalValue $s $kind[1] $null) (New-Label $l 'domain' $name 'kind' $kind[0])
            }
            Add-Metric 'cohesity_storage_domain_files' 'Files in the storage domain.' (Get-OptionalValue $s 'numFiles' $null) $dl
        }
    }
    'alertstats' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path ("$v1/stats/alerts?startTimeUsecs={0}&endTimeUsecs={1}" -f (Get-UsecsAgo 24), ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000))
        foreach ($bucket in @(@('hardware', 'numHardware'), @('software', 'numSoftware'), @('dataservice', 'NumDataService'), @('maintenance', 'NumMaintenance'))) {
            foreach ($sev in @('Critical', 'Warning', 'Info')) {
                Add-Metric 'cohesity_alerts_active' 'Active alerts in the last 24 hours, by bucket and severity.' (Get-OptionalValue $r ($bucket[1] + $sev + 'Alerts') $null) (New-Label $l 'bucket' $bucket[0] 'severity' $sev.ToLowerInvariant())
            }
        }
    }
    'alerts' = { param($c, $l, $x); Invoke-AlertCheck $c $l $x }

    # ---- Protection (every run) ----
    'protectiongroups' = {
        param($c, $l, $x)
        $policyNames = Get-PolicyNames $c $x
        $domainNames = Get-DomainNames $c $x
        foreach ($g in (Get-Groups $c $x)) {
            $name = [string](Get-OptionalValue $g 'name' '')
            $gl = New-Label $l 'group' $name
            $policyId = [string](Get-OptionalValue $g 'policyId' '')
            $domainId = [string](Get-OptionalValue $g 'storageDomainId' '')
            Add-Metric 'cohesity_group_info' 'Protection group: environment, policy and storage domain (value is always 1).' 1 (New-Label $l 'group' $name 'group_id' (Get-OptionalValue $g 'id' '') `
                'env' (ConvertTo-Env (Get-OptionalValue $g 'environment' '')) 'policy' $(if ($policyNames.ContainsKey($policyId)) { $policyNames[$policyId] } else { $policyId }) `
                'domain' $(if ($domainNames.ContainsKey($domainId)) { $domainNames[$domainId] } else { $domainId }) 'priority' (ConvertTo-Env (Get-OptionalValue $g 'priority' '')))
            Add-Metric 'cohesity_group_active' 'Group is active (1) or an inactive replica copy (0).' (ConvertTo-Flag (Get-OptionalValue $g 'isActive' $null)) $gl
            Add-Metric 'cohesity_group_paused' 'Group is paused: no new runs are scheduled (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $g 'isPaused' $null)) $gl
            Add-Metric 'cohesity_group_protected_objects' 'Objects protected by the group.' (Get-OptionalValue $g 'numProtectedObjects' $null) $gl

            $run = Get-OptionalValue $g 'lastRun' $null
            if ($null -eq $run) { continue }
            $b = Get-OptionalValue $run 'localBackupInfo' $null
            if ($null -eq $b) { $b = Get-OptionalValue $run 'originalBackupInfo' $null }
            if ($null -ne $b) {
                $status = Get-CleanState (Get-OptionalValue $b 'status' '')
                Add-Metric 'cohesity_group_last_run_status' 'Status of the group''s last backup run (1 for the current status label).' 1 (New-Label $l 'group' $name 'status' $status 'run_type' (ConvertTo-Env (Get-OptionalValue $b 'runType' '')))
                Add-Metric 'cohesity_group_last_run_ok' 'The group''s last backup run succeeded, with or without warnings (1), is running (absent) or did not (0).' $(if ($status -in $activeRunStates) { $null } else { [int]($status -in @('succeeded', 'succeededwithwarning')) }) $gl
                Add-Metric 'cohesity_group_last_run_sla_violated' 'The group''s last backup run violated its SLA (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $b 'isSlaViolated' $null)) $gl
                Add-Metric 'cohesity_group_last_run_start_timestamp_seconds' 'Start of the group''s last backup run (Unix time).' (ConvertFrom-Usecs (Get-OptionalValue $b 'startTimeUsecs' $null)) $gl
                Add-Metric 'cohesity_group_last_run_end_timestamp_seconds' 'End of the group''s last backup run (Unix time; absent while it runs).' (ConvertFrom-Usecs (Get-OptionalValue $b 'endTimeUsecs' $null)) $gl
                Add-Metric 'cohesity_group_last_run_duration_seconds' 'Duration of the group''s last finished backup run.' (Get-Duration (Get-OptionalValue $b 'startTimeUsecs' $null) (Get-OptionalValue $b 'endTimeUsecs' $null)) $gl
                foreach ($result in @(@('successful', 'successfulObjectsCount'), @('failed', 'failedObjectsCount'), @('skipped', 'skippedObjectsCount'), @('cancelled', 'cancelledObjectsCount'))) {
                    Add-Metric 'cohesity_group_last_run_objects' 'Objects in the group''s last backup run, by result.' (Get-OptionalValue $b $result[1] $null) (New-Label $l 'group' $name 'result' $result[0])
                }
                Add-Metric 'cohesity_group_last_run_logical_bytes' 'Logical size of the objects in the group''s last backup run.' (Get-Prop $b 'localSnapshotStats.logicalSizeBytes' $null) $gl
                Add-Metric 'cohesity_group_last_run_read_bytes' 'Bytes read by the group''s last backup run.' (Get-Prop $b 'localSnapshotStats.bytesRead' $null) $gl
                Add-Metric 'cohesity_group_last_run_written_bytes' 'Bytes written by the group''s last backup run (after reduction).' (Get-Prop $b 'localSnapshotStats.bytesWritten' $null) $gl
            }
            Add-RunTargetMetrics $l $name $run
        }
    }
    'runs' = {
        param($c, $l, $x)
        $runs = Get-RunsSummary $c $x
        $byGroupStatus = @{}; $byStatus = @{}; $written = @{}; $read = @{}; $sla = @{}
        foreach ($s in @('succeeded', 'succeededwithwarning', 'failed', 'running', 'canceled', 'missed')) { $byStatus[$s] = 0 }
        foreach ($r in $runs) {
            $group = [string](Get-OptionalValue $r 'protectionGroupName' '')
            $status = Get-CleanState (Get-OptionalValue $r 'status' '')
            Add-Count $byGroupStatus ("{0}|{1}" -f $group, $status)
            Add-Count $byStatus $status
            Add-Count $written $group ([double](Get-OptionalValue $r 'bytesWritten' 0))
            Add-Count $read $group ([double](Get-OptionalValue $r 'logicalSizeBytes' 0))
            if ((ConvertTo-Flag (Get-OptionalValue $r 'isSlaViolated' $null)) -eq 1) { Add-Count $sla $group }
        }
        foreach ($s in $byStatus.Keys) { Add-Metric 'cohesity_runs_24h' 'Backup runs started in the last 24 hours, by status.' $byStatus[$s] (New-Label $l 'status' $s) }
        foreach ($key in $byGroupStatus.Keys) {
            $group, $status = $key.Split('|', 2)
            Add-Metric 'cohesity_group_runs_24h' 'Backup runs of the group started in the last 24 hours, by status.' $byGroupStatus[$key] (New-Label $l 'group' $group 'status' $status)
        }
        foreach ($group in $written.Keys) {
            Add-Metric 'cohesity_group_24h_written_bytes' 'Bytes written by the group''s runs in the last 24 hours.' $written[$group] (New-Label $l 'group' $group)
            Add-Metric 'cohesity_group_24h_logical_bytes' 'Logical size protected by the group''s runs in the last 24 hours.' $read[$group] (New-Label $l 'group' $group)
            Add-Metric 'cohesity_group_24h_sla_violations' 'Runs of the group in the last 24 hours that violated the SLA.' $(if ($sla.ContainsKey($group)) { $sla[$group] } else { 0 }) (New-Label $l 'group' $group)
        }

        # Runs in progress: one series set per run, with the time the collector first saw it.
        $active = @($runs | Where-Object { (Get-CleanState (Get-OptionalValue $_ 'status' '')) -in $activeRunStates })
        $firstSeen = Update-FirstSeen (Join-Path $config.StateDirectory ("runs-{0}.json" -f (Get-SafeFileName $l.cluster))) @($active | ForEach-Object { [string](Get-OptionalValue $_ 'id' '') })
        Add-Metric 'cohesity_runs_active' 'Backup runs in progress.' $active.Count (New-Label $l)
        foreach ($r in $active) {
            $id = [string](Get-OptionalValue $r 'id' '')
            $group = [string](Get-OptionalValue $r 'protectionGroupName' '')
            $rl = New-Label $l 'group' $group 'run_id' $id
            Add-Metric 'cohesity_run_info' 'A backup run in progress (value is always 1).' 1 (New-Label $l 'group' $group 'run_id' $id 'env' (ConvertTo-Env (Get-OptionalValue $r 'environment' '')) `
                'status' (Get-CleanState (Get-OptionalValue $r 'status' '')) 'full' $(if ((ConvertTo-Flag (Get-OptionalValue $r 'isFullRun' $null)) -eq 1) { 'yes' } else { 'no' }))
            Add-Metric 'cohesity_run_start_timestamp_seconds' 'Start of the run (Unix time).' (ConvertFrom-Usecs (Get-OptionalValue $r 'startTimeUsecs' $null)) $rl
            if ($firstSeen.Contains($id)) { Add-Metric 'cohesity_run_first_seen_timestamp_seconds' 'When the collector first saw the run in progress (Unix time).' $firstSeen[$id] $rl }
            Add-Metric 'cohesity_run_objects' 'Objects in the run.' (Get-OptionalValue $r 'totalObjectsCount' $null) $rl
            Add-Metric 'cohesity_run_objects_done' 'Objects of the run protected so far.' (Get-OptionalValue $r 'successObjectsCount' $null) $rl
            Add-Metric 'cohesity_run_written_bytes' 'Bytes written by the run so far.' (Get-OptionalValue $r 'bytesWritten' $null) $rl
            Add-Metric 'cohesity_run_logical_bytes' 'Logical size of the run.' (Get-OptionalValue $r 'logicalSizeBytes' $null) $rl
        }
    }
    'runprogress' = {
        param($c, $l, $x)
        $active = @(Get-RunsSummary $c $x | Where-Object { (Get-CleanState (Get-OptionalValue $_ 'status' '')) -in $activeRunStates })
        $detailed = 0
        foreach ($r in ($active | Select-Object -First $maxRunDetails)) {
            $id = [string](Get-OptionalValue $r 'id' '')
            $group = [string](Get-OptionalValue $r 'protectionGroupName' '')
            $p = Invoke-CohesityApi -Connection $c -Path ('/v2/data-protect/runs/{0}/progress' -f [uri]::EscapeDataString($id))
            $detailed++
            $parts = @()
            $local = Get-OptionalValue $p 'localRun' $null
            if ($null -ne $local) { $parts += , @('backup', '', $local) }
            foreach ($t in @(Get-Array $p 'replicationRun')) { $parts += , @('replication', (Get-OptionalValue $t 'clusterName' ''), $t) }
            foreach ($t in @(Get-Array $p 'archivalRun')) { $parts += , @('archive', (Get-OptionalValue $t 'targetName' ''), $t) }
            foreach ($part in $parts) {
                $pl = New-Label $l 'group' $group 'run_id' $id 'task' $part[0] 'target' $part[1]
                Add-Metric 'cohesity_run_progress_percent' 'Progress of a running run''s task (backup, replication, archive), in percent.' (Get-OptionalValue $part[2] 'percentageCompleted' $null) $pl
                Add-Metric 'cohesity_run_remaining_seconds' 'Expected remaining time of a running run''s task, as reported by the cluster.' (ConvertFrom-Usecs (Get-OptionalValue $part[2] 'expectedRemainingTimeUsecs' $null)) $pl
            }
        }
        Add-Metric 'cohesity_runs_detailed' 'Running runs whose progress was read this run (capped).' $detailed (New-Label $l)
    }
    'sla' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path ("$v1/stats/protectionRuns/lastRun?fromTimeSecs={0}" -f ((Get-UnixNow) - 7 * 86400))
        Add-Metric 'cohesity_last_runs' 'Last run of every protection job (past 7 days), by result.' (Get-OptionalValue $r 'numRunsMetSla' $null) (New-Label $l 'result' 'met_sla')
        Add-Metric 'cohesity_last_runs' 'Last run of every protection job (past 7 days), by result.' (Get-OptionalValue $r 'numRunsFailedSla' $null) (New-Label $l 'result' 'failed_sla')
        Add-Metric 'cohesity_last_runs' 'Last run of every protection job (past 7 days), by result.' (Get-OptionalValue $r 'numRunsFailed' $null) (New-Label $l 'result' 'failed')
        Add-Metric 'cohesity_last_runs_objects_failed' 'Objects that failed in the last run of every job.' (Get-OptionalValue $r 'numObjectsFailed' $null) (New-Label $l)
        foreach ($e in @(Get-Array $r 'statsByEnv')) {
            $env = ConvertTo-Env (Get-OptionalValue $e 'environment' '')
            Add-Metric 'cohesity_last_runs_env_objects' 'Objects in the last run of every job, by environment and result.' (Get-OptionalValue $e 'numObjectsMetSla' $null) (New-Label $l 'env' $env 'result' 'met_sla')
            Add-Metric 'cohesity_last_runs_env_objects' 'Objects in the last run of every job, by environment and result.' (Get-OptionalValue $e 'numObjectsFailedSla' $null) (New-Label $l 'env' $env 'result' 'failed_sla')
            Add-Metric 'cohesity_last_runs_env_objects' 'Objects in the last run of every job, by environment and result.' (Get-OptionalValue $e 'numObjectsFailed' $null) (New-Label $l 'env' $env 'result' 'failed')
        }
    }
    'failedobjects' = {
        param($c, $l, $x)
        # Objects that failed in the last run of groups whose last run failed or finished with warnings (capped).
        $groups = @(Get-Groups $c $x | Where-Object {
            (Get-CleanState (Get-Prop $_ 'lastRun.localBackupInfo.status' '')) -in @('failed', 'succeededwithwarning') } | Select-Object -First $maxFailedGroups)
        $emitted = 0
        foreach ($g in $groups) {
            $name = [string](Get-OptionalValue $g 'name' '')
            $r = Invoke-CohesityApi -Connection $c -Path ('/v2/data-protect/protection-groups/{0}/runs?numRuns=1&includeObjectDetails=true' -f [uri]::EscapeDataString([string](Get-OptionalValue $g 'id' '')))
            foreach ($run in @(Get-Array $r 'runs' | Select-Object -First 1)) {
                foreach ($o in @(Get-Array $run 'objects')) {
                    $snap = Get-Prop $o 'localSnapshotInfo' $null
                    $attempts = @(Get-Array $snap 'failedAttempts')
                    $status = Get-CleanState (Get-Prop $snap 'snapshotInfo.status' '')
                    $warnings = @(Get-Prop $snap 'snapshotInfo.warnings' @())
                    $failed = $status -match 'fail' -or ($attempts.Count -gt 0 -and $status -notmatch 'succe')
                    if (-not $failed -and $warnings.Count -eq 0) { continue }
                    if ($emitted -ge $maxFailedObjects) { break }
                    $emitted++
                    $message = if ($attempts.Count -gt 0) { Get-OptionalValue $attempts[-1] 'message' '' } elseif ($warnings.Count -gt 0) { $warnings[0] } else { '' }
                    $when = Get-Prop $snap 'snapshotInfo.endTimeUsecs' $null
                    if ($null -eq $when -and $attempts.Count -gt 0) { $when = Get-OptionalValue $attempts[-1] 'endTimeUsecs' $null }
                    Add-Metric 'cohesity_failed_object_info' 'Object that failed (or warned) in the last run of a group whose run failed or warned (value is the end time as Unix time, or 1).' `
                        $(if ($null -ne (ConvertFrom-Usecs $when)) { ConvertFrom-Usecs $when } else { 1 }) (New-Label $l 'group' $name 'object' (Get-Prop $o 'object.name' '') `
                        'env' (ConvertTo-Env (Get-Prop $o 'object.environment' '')) 'source' (Get-Prop $o 'object.sourceName' '') `
                        'result' $(if ($failed) { 'failed' } else { 'warning' }) 'attempts' $attempts.Count 'message' (Get-ShortText $message))
                }
            }
        }
        Add-Metric 'cohesity_failed_objects_listed' 'Failed or warning objects listed this run (capped).' $emitted (New-Label $l)
    }
    'recoveries' = {
        param($c, $l, $x)
        $all = @(Get-Array (Invoke-CohesityApi -Connection $c -Path ('/v2/data-protect/recoveries?startTimeUsecs={0}&includeTenants=true' -f (Get-UsecsAgo 24))) 'recoveries')
        $counts = @{}
        foreach ($r in $all) { Add-Count $counts ("{0}|{1}" -f (Get-OptionalValue $r 'recoveryAction' ''), (Get-CleanState (Get-OptionalValue $r 'status' ''))) }
        foreach ($key in $counts.Keys) {
            $action, $status = $key.Split('|', 2)
            Add-Metric 'cohesity_recoveries_24h' 'Recoveries started in the last 24 hours, by action and status.' $counts[$key] (New-Label $l 'action' $action 'status' $status)
        }
        $running = @($all | Where-Object { (Get-CleanState (Get-OptionalValue $_ 'status' '')) -in $activeRunStates })
        Add-Metric 'cohesity_recoveries_active' 'Recoveries in progress.' $running.Count (New-Label $l)
        foreach ($r in $running) {
            Add-Metric 'cohesity_recovery_info' 'A recovery in progress (value is its start time as Unix time).' (ConvertFrom-Usecs (Get-OptionalValue $r 'startTimeUsecs' $null)) (New-Label $l `
                'name' (Get-OptionalValue $r 'name' '') 'action' (Get-OptionalValue $r 'recoveryAction' '') 'env' (ConvertTo-Env (Get-OptionalValue $r 'snapshotEnvironment' '')) `
                'status' (Get-CleanState (Get-OptionalValue $r 'status' '')) 'user' (Get-Prop $r 'creationInfo.userName' ''))
        }
    }

    # ---- Inventory (every 15 minutes) ----
    'protectionsummary' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path "$v1/stats/protectionSummary"
        Add-Metric 'cohesity_objects' 'Objects on registered sources, protected or not.' (Get-OptionalValue $r 'numObjectsProtected' $null) (New-Label $l 'protected' 'yes')
        Add-Metric 'cohesity_objects' 'Objects on registered sources, protected or not.' (Get-OptionalValue $r 'numObjectsUnprotected' $null) (New-Label $l 'protected' 'no')
        Add-Metric 'cohesity_object_bytes' 'Size of the objects on registered sources, protected or not.' (Get-OptionalValue $r 'protectedSizeBytes' $null) (New-Label $l 'protected' 'yes')
        Add-Metric 'cohesity_object_bytes' 'Size of the objects on registered sources, protected or not.' (Get-OptionalValue $r 'unprotectedSizeBytes' $null) (New-Label $l 'protected' 'no')
        foreach ($e in @(Get-Array $r 'statsByEnv')) {
            $env = ConvertTo-Env (Get-OptionalValue $e 'envType' '')
            Add-Metric 'cohesity_objects_by_env' 'Objects by environment, protected or not.' (Get-OptionalValue $e 'protectedCount' $null) (New-Label $l 'env' $env 'protected' 'yes')
            Add-Metric 'cohesity_objects_by_env' 'Objects by environment, protected or not.' (Get-OptionalValue $e 'unprotectedCount' $null) (New-Label $l 'env' $env 'protected' 'no')
            Add-Metric 'cohesity_object_bytes_by_env' 'Object size by environment, protected or not.' (Get-OptionalValue $e 'protectedSizeBytes' $null) (New-Label $l 'env' $env 'protected' 'yes')
            Add-Metric 'cohesity_object_bytes_by_env' 'Object size by environment, protected or not.' (Get-OptionalValue $e 'unprotectedSizeBytes' $null) (New-Label $l 'env' $env 'protected' 'no')
        }
    }
    'sources' = {
        param($c, $l, $x)
        # Never ask for includeSourceCredentials: this check only needs names, types and refresh state.
        $regs = @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/data-protect/sources/registrations?includeTenants=true') 'registrations')
        $byEnv = @{}
        foreach ($s in $regs) {
            $env = ConvertTo-Env (Get-OptionalValue $s 'environment' '')
            Add-Count $byEnv $env
            $sl = New-Label $l 'source' (Get-OptionalValue $s 'name' '') 'env' $env
            $auth = Get-CleanState (Get-Prop $s 'sourceInfo.authenticationStatus' (Get-OptionalValue $s 'authenticationStatus' ''))
            Add-Metric 'cohesity_source_status' 'Registration and refresh status of a source (1 for the current label).' 1 (New-Label $l 'source' (Get-OptionalValue $s 'name' '') 'env' $env 'status' $auth)
            $refreshed = Get-Prop $s 'sourceInfo.lastRefreshedTimeMsecs' (Get-OptionalValue $s 'lastRefreshedTimeMsecs' $null)
            Add-Metric 'cohesity_source_last_refresh_timestamp_seconds' 'When the source was last refreshed (Unix time).' $(if ($null -ne $refreshed -and [double]$refreshed -gt 0) { [Math]::Floor([double]$refreshed / 1000) }) $sl
            $registered = Get-Prop $s 'sourceInfo.registrationTimeMsecs' (Get-OptionalValue $s 'registrationTimeMsecs' $null)
            Add-Metric 'cohesity_source_registered_timestamp_seconds' 'When the source was registered (Unix time).' $(if ($null -ne $registered -and [double]$registered -gt 0) { [Math]::Floor([double]$registered / 1000) }) $sl
        }
        foreach ($env in $byEnv.Keys) { Add-Metric 'cohesity_sources' 'Registered sources by environment.' $byEnv[$env] (New-Label $l 'env' $env) }
    }
    'externaltargets' = {
        param($c, $l, $x)
        foreach ($t in @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/data-protect/external-targets') 'externalTargets')) {
            $status = Get-CleanState (Get-OptionalValue $t 'status' '')
            Add-Metric 'cohesity_external_target_info' 'Archive or tiering target (value is always 1).' 1 (New-Label $l 'target' (Get-OptionalValue $t 'name' '') 'target_id' (Get-OptionalValue $t 'id' '') `
                'purpose' (Get-OptionalValue $t 'purposeType' '') 'ownership' (Get-OptionalValue $t 'ownershipContext' '') 'status' $status 'worm' $(if ((ConvertTo-Flag (Get-OptionalValue $t 'isWormCapable' $null)) -eq 1) { 'yes' } else { 'no' }) `
                'error' (Get-ShortText (Get-OptionalValue $t 'errorMessage' '')))
            Add-Metric 'cohesity_external_target_registered' 'Target is registered (1) or unregistering/unregistered (0).' ([int]($status -eq 'registered')) (New-Label $l 'target' (Get-OptionalValue $t 'name' ''))
        }
    }
    'vaultstats' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path "$v1/stats/vaults"
        foreach ($p in @(@('aws', 'awsUsageBytes'), @('azure', 'azureUsageBytes'), @('gcp', 'gcpUsageBytes'), @('nas', 'nasUsageBytes'), @('oracle', 'oracleUsageBytes'), @('qstar', 'qstarUsageBytes'), @('s3c', 's3cUsageBytes'))) {
            Add-Metric 'cohesity_archive_usage_bytes' 'Data stored on archive targets, by provider.' (Get-OptionalValue $r $p[1] $null) (New-Label $l 'provider' $p[0])
        }
        foreach ($v in @(Get-Array $r 'vaultStatsList')) {
            Add-Metric 'cohesity_vault_usage_bytes' 'Data stored on an archive target.' (Get-OptionalValue $v 'usageBytes' $null) (New-Label $l 'target' (Get-OptionalValue $v 'name' '') 'type' (ConvertTo-Env (Get-OptionalValue $v 'type' '')))
        }
    }
    'views' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path '/v2/file-services/views-summary'
        foreach ($k in @(@('total', 'totalViews'), @('protected', 'protectedViews'), @('replicated_in', 'replicatedInViews'), @('replicated_out', 'replicatedOutViews'))) {
            Add-Metric 'cohesity_views' 'SmartFiles views, by kind.' (Get-OptionalValue $r $k[1] $null) (New-Label $l 'kind' $k[0])
        }
        foreach ($k in @(@('logical', 'logicalUsageBytes'), @('consumed', 'storageConsumedBytes'), @('written', 'dataWrittenBytes'))) {
            Add-Metric 'cohesity_views_bytes' 'SmartFiles view usage, by kind.' (Get-OptionalValue $r $k[1] $null) (New-Label $l 'kind' $k[0])
        }
        Add-Metric 'cohesity_views_files' 'Files in all views.' (Get-OptionalValue $r 'numFiles' $null) (New-Label $l)
    }
    'antivirus' = {
        param($c, $l, $x)
        $files = @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/antivirus-service/infected-files?maxCount=1000') 'infectedFiles')
        $counts = @{}
        foreach ($f in $files) { Add-Count $counts ("{0}|{1}" -f (Get-OptionalValue $f 'viewName' ''), (Get-CleanState (Get-OptionalValue $f 'state' ''))) }
        Add-Metric 'cohesity_av_infected_files_found' 'Infected files found by the antivirus service.' $files.Count (New-Label $l)
        foreach ($key in $counts.Keys) {
            $view, $state = $key.Split('|', 2)
            Add-Metric 'cohesity_av_infected_files' 'Infected files by view and state.' $counts[$key] (New-Label $l 'view' $view 'state' $state)
        }
    }

    # ---- Configuration (every 60 minutes) ----
    'policies' = {
        param($c, $l, $x)
        Get-PolicyNames $c $x | Out-Null
        foreach ($p in $x.Policies) {
            $pl = New-Label $l 'policy' (Get-OptionalValue $p 'name' '')
            Add-Metric 'cohesity_policy_info' 'Protection policy (value is always 1).' 1 (New-Label $l 'policy' (Get-OptionalValue $p 'name' '') 'policy_id' (Get-OptionalValue $p 'id' '') `
                'replicated' $(if ((ConvertTo-Flag (Get-OptionalValue $p 'isReplicated' $null)) -eq 1) { 'yes' } else { 'no' }) 'datalock' (Get-OptionalValue $p 'dataLock' ''))
            Add-Metric 'cohesity_policy_groups' 'Protection groups using the policy.' (Get-OptionalValue $p 'numProtectionGroups' $null) $pl
            Add-Metric 'cohesity_policy_protected_objects' 'Objects protected with the policy.' (Get-OptionalValue $p 'numProtectedObjects' $null) $pl
            Add-Metric 'cohesity_policy_replication_targets' 'Replication targets in the policy.' (@(Get-Prop $p 'remoteTargetPolicy.replicationTargets' @()).Count) $pl
            Add-Metric 'cohesity_policy_archive_targets' 'Archive targets in the policy.' (@(Get-Prop $p 'remoteTargetPolicy.archivalTargets' @()).Count) $pl
        }
    }
    'remoteclusters' = {
        param($c, $l, $x)
        $remotes = @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/remote-clusters') 'remoteClusters')
        Add-Metric 'cohesity_remote_clusters' 'Registered remote (replication) clusters.' $remotes.Count (New-Label $l)
        foreach ($r in $remotes) {
            Add-Metric 'cohesity_remote_cluster_info' 'Registered remote cluster (value is always 1).' 1 (New-Label $l 'remote' (Get-OptionalValue $r 'clusterName' '') 'remote_id' (Get-OptionalValue $r 'clusterId' '') `
                'purpose' ((@(Get-Array $r 'purpose') | ForEach-Object { [string]$_ }) -join ',') 'encryption' (Get-OptionalValue $r 'effectiveAesEncryptionMode' ''))
            Add-Metric 'cohesity_remote_cluster_tls_enabled' 'TLS is enabled to the remote cluster (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $r 'tlsEnabled' $null)) (New-Label $l 'remote' (Get-OptionalValue $r 'clusterName' ''))
        }
    }
    'consumers' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path "$v1/stats/consumers?consumerType=kProtectionRuns&maxCount=1000&fetchProtectionPolicy=true"
        foreach ($s in @(Get-Array $r 'statsList')) {
            $name = [string](Get-OptionalValue $s 'name' '')
            foreach ($kind in @(@('data_in', 'dataInBytes'), @('data_in_after_dedup', 'dataInBytesAfterDedup'), @('data_written', 'dataWrittenBytes'),
                                @('local_physical', 'localTotalPhysicalUsageBytes'), @('cloud_physical', 'cloudTotalPhysicalUsageBytes'), @('consumed', 'storageConsumedBytes'))) {
                Add-Metric 'cohesity_consumer_bytes' 'Storage consumed by each protection group (consumer), by kind.' (Get-Prop $s ('stats.' + $kind[1]) $null) (New-Label $l 'group' $name 'kind' $kind[0])
            }
        }
    }
    'license' = {
        param($c, $l, $x)
        $r = Invoke-CohesityApi -Connection $c -Path "$v1/licenseUsage"
        foreach ($u in @(Get-Array $r 'licensedUsage')) {
            $fl = New-Label $l 'feature' (Get-OptionalValue $u 'featureName' '')
            Add-Metric 'cohesity_license_entitled_gib' 'Licensed (entitled) capacity per feature, GiB.' (Get-OptionalValue $u 'capacityGib' $null) $fl
            Add-Metric 'cohesity_license_expiry_timestamp_seconds' 'When the feature licence expires (Unix time).' (Get-OptionalValue $u 'expiryTime' $null) $fl
        }
        $used = @{}
        $usage = Get-OptionalValue $r 'usage' $null
        if ($null -ne $usage) {
            foreach ($p in $usage.PSObject.Properties) {
                foreach ($f in @($p.Value)) { Add-Count $used ([string](Get-OptionalValue $f 'featureName' '')) ([double](Get-OptionalValue $f 'currentUsageGiB' 0)) }
            }
        }
        foreach ($feature in $used.Keys) { Add-Metric 'cohesity_license_used_gib' 'Licensed capacity in use per feature, GiB.' $used[$feature] (New-Label $l 'feature' $feature) }
        foreach ($o in @(Get-Array $r 'featureOverUsage')) {
            Add-Metric 'cohesity_license_overused_gib' 'Capacity used beyond the licence per feature, GiB.' (Get-OptionalValue $o 'overusedGib' $null) (New-Label $l 'feature' (Get-OptionalValue $o 'featureName' ''))
        }
    }
    'patches' = {
        param($c, $l, $x)
        $applied = @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/patch-management/applied-patches') '')
        Add-Metric 'cohesity_patches_installed' 'Patches applied to the cluster.' $applied.Count (New-Label $l)
        foreach ($p in $applied) {
            $when = Get-OptionalValue $p 'appliedTimeMsecs' $null
            Add-Metric 'cohesity_patch_info' 'Applied patch (value is the time it was applied as Unix time, or 1).' $(if ($null -ne $when -and [double]$when -gt 0) { [Math]::Floor([double]$when / 1000) } else { 1 }) (New-Label $l `
                'service' (Get-OptionalValue $p 'service' (Get-OptionalValue $p 'component' '')) 'version' (Get-OptionalValue $p 'version' '') 'level' (Get-OptionalValue $p 'patchLevel' ''))
        }
        $available = @(Get-Array (Invoke-CohesityApi -Connection $c -Path '/v2/patch-management/available-patches') '')
        Add-Metric 'cohesity_patches_available' 'Patches available to apply (downloaded to the cluster).' $available.Count (New-Label $l)
    }
}

# Minutes between runs of the slower checks; anything not listed runs every time.
$checkIntervalMinutes = @{
    protectionsummary = 15; sources = 15; externaltargets = 15; vaultstats = 15; views = 15; antivirus = 15
    policies = 60; remoteclusters = 60; consumers = 60; license = 60; patches = 60
}
$disabledChecks = @($config.DisabledChecks | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
if (-not $config.CollectAlerts) { $disabledChecks += 'alerts' }
foreach ($name in $disabledChecks) { if (-not $checks.Contains($name)) { Write-Warning "DisabledChecks: unknown check '$name' (known: $($checks.Keys -join ', '))" } }

# ---------------------------------------------------------------------------
# Write helper: UTF-8 without BOM, LF line endings, atomic rename.
# ---------------------------------------------------------------------------
function Write-MetricsFile {
    param([string]$Path)
    $lines = [System.Collections.Generic.List[string]]::new()
    $seriesSeen = @{}
    foreach ($name in $families.Keys) {
        $f = $families[$name]
        $lines.Add("# HELP $name $($f.Help)")
        $lines.Add("# TYPE $name $($f.Type)")
        foreach ($sample in $f.Samples) {
            # windows_exporter rejects the whole file if a series appears twice, so keep the first of any duplicate.
            $series = $sample.Substring(0, $sample.LastIndexOf(' '))
            if ($seriesSeen.ContainsKey($series)) { continue }
            $seriesSeen[$series] = $true
            $lines.Add($sample)
        }
    }
    $temp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($temp, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
    return $seriesSeen.Count
}

function Get-ServerMetricsFileName { param([string]$Name) return ("cohesity-{0}.prom" -f (Get-SafeFileName $Name)) }

# ---------------------------------------------------------------------------
# Parallel mode: one child process per cluster, each writing its own .prom file.
# The exporter reads every *.prom in the directory, so the files add up to one scrape.
# ---------------------------------------------------------------------------
$isChild = [bool]$env:COHESITY_COLLECTOR_CHILD
if ($MaxParallel -le 0) { $MaxParallel = if ($selectedServers.Count -le 2) { 1 } else { [Math]::Min(8, [Math]::Ceiling($selectedServers.Count / 4.0)) } }
if ($Credential) { $MaxParallel = 1 }   # an explicit credential cannot be handed to child processes

if ($MaxParallel -gt 1 -and $selectedServers.Count -gt 1 -and -not $isChild) {
    $exe = (Get-Process -Id $PID).Path
    $commonArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-ConfigPath', $ConfigPath, '-NonInteractive', '-TextfileDirectory', $TextfileDirectory, '-MaxParallel', '1')
    if ($Scheme) { $commonArgs += @('-Scheme', $Scheme) }
    if ($Port -ge 0) { $commonArgs += @('-Port', [string]$Port) }
    if ($SkipCertificateCheck) { $commonArgs += '-SkipCertificateCheck' }
    if ($Refresh) { $commonArgs += '-Refresh' }
    $env:COHESITY_COLLECTOR_CHILD = '1'

    $started = Get-UnixNow
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $selectedServers) { $pending.Enqueue($s) }
    $running = @{}; $exitCodes = [ordered]@{}
    try {
        while ($pending.Count -gt 0 -or $running.Count -gt 0) {
            while ($pending.Count -gt 0 -and $running.Count -lt $MaxParallel) {
                $s = $pending.Dequeue()
                $argList = ($commonArgs + @('-Server', $s.Name, '-FileName', (Get-ServerMetricsFileName $s.Name))) |
                    ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
                $running[$s.Name] = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru
            }
            Start-Sleep -Milliseconds 500
            foreach ($name in @($running.Keys)) {
                if ($running[$name].HasExited) { $exitCodes[$name] = $running[$name].ExitCode; $running.Remove($name) }
            }
        }
    } finally {
        foreach ($proc in $running.Values) { try { $proc.Kill() } catch { } }
    }

    # Summary file: the collector's own metrics, plus per-cluster exit codes. Stale per-cluster files are removed.
    foreach ($name in $exitCodes.Keys) {
        Add-Metric 'cohesity_collector_server_exit_code' 'Exit code of the per-cluster collector process (0 OK, 2 a check failed, 3 config error).' $exitCodes[$name] ([ordered]@{ cluster = $name })
    }
    Add-Metric 'cohesity_collector_parallel_processes' 'Cluster collector processes run at a time.' $MaxParallel @{}
    Add-Metric 'cohesity_collector_last_run_timestamp_seconds' 'Unix time the collector last completed.' (Get-UnixNow) @{}
    Add-Metric 'cohesity_collector_run_duration_seconds' 'Wall-clock time of the whole collector run.' ((Get-UnixNow) - $started) @{}
    Add-Metric 'cohesity_collector_info' 'Installed Cohesity monitoring package version (value is always 1).' 1 ([ordered]@{ version = $script:PackageVersion })
    $keep = @($selectedServers | ForEach-Object { Get-ServerMetricsFileName $_.Name }) + @($FileName)
    Get-ChildItem -LiteralPath $TextfileDirectory -Filter 'cohesity-*.prom' -File | Where-Object { $keep -notcontains $_.Name } | Remove-Item -Force -ErrorAction SilentlyContinue
    $count = Write-MetricsFile (Join-Path $TextfileDirectory $FileName)
    $failed = @($exitCodes.Values | Where-Object { $_ -ne 0 }).Count
    Write-Host ("Ran {0} cluster collector(s), {1} at a time, in {2}s; {3} failed. Summary: {4}" -f $exitCodes.Count, $MaxParallel, ((Get-UnixNow) - $started), $failed, (Join-Path $TextfileDirectory $FileName))
    if ($failed -gt 0) { exit 2 }
    exit 0
}

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------
$anyFailure = $false
foreach ($s in $selectedServers) {
    $labels = [ordered]@{ cluster = $s.Name }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $connection = $null
    try {
        $connection = Connect-Cohesity -ServerConfig $s -Credential $credentialByName[$s.Name]
        Add-Metric 'cohesity_up' 'API login and a first authenticated call succeeded (1) or failed (0).' 1 $labels
    } catch {
        $anyFailure = $true
        Add-Metric 'cohesity_up' 'API login and a first authenticated call succeeded (1) or failed (0).' 0 $labels
        Write-Warning "$($s.Name): $($_.Exception.Message)"
        continue
    }

    $cachePath = Join-Path $config.StateDirectory ("checkcache-{0}.json" -f (Get-SafeFileName $s.Name))
    $cache = @{}
    if (-not $Refresh) {
        $saved = Read-JsonState $cachePath
        if ($null -ne $saved) { foreach ($p in $saved.PSObject.Properties) { $cache[$p.Name] = $p.Value } }
    }
    $lookups = @{}

    try {
        foreach ($name in $checks.Keys) {
            if ($disabledChecks -contains $name) { continue }
            $now = Get-UnixNow
            $interval = if ($checkIntervalMinutes.ContainsKey($name)) { $checkIntervalMinutes[$name] } else { 0 }
            $ok = 1
            $lastSuccess = $now

            if ($interval -gt 0 -and $cache.ContainsKey($name) -and ($now - [long]$cache[$name].ts) -lt ($interval * 60 - 30)) {
                # Replay the cached samples from the last successful run.
                foreach ($sample in @($cache[$name].samples)) { Add-Sample $sample.n $sample.h $sample.t $sample.s }
                $lastSuccess = [long]$cache[$name].ts
            } else {
                if ($interval -gt 0) { $script:capture = [System.Collections.Generic.List[object]]::new() }
                try {
                    & $checks[$name] $connection $labels $lookups
                    if ($interval -gt 0) { $cache[$name] = [pscustomobject]@{ ts = $now; samples = $script:capture.ToArray() } }
                } catch {
                    $ok = 0
                    $anyFailure = $true
                    if ($cache.ContainsKey($name)) { $cache.Remove($name) }
                    Write-Warning "$($s.Name) [$name]: $($_.Exception.Message)"
                } finally {
                    $script:capture = $null
                }
            }
            Add-Metric 'cohesity_check_success' 'Collector check succeeded (1) or failed (0).' $ok ([ordered]@{ cluster = $s.Name; check = $name })
            if ($ok -eq 1) { Add-Metric 'cohesity_check_last_success_timestamp_seconds' 'When the check last succeeded (older than now for cached checks).' $lastSuccess ([ordered]@{ cluster = $s.Name; check = $name }) }
        }
    } finally {
        Disconnect-Cohesity $connection
        try { Write-JsonState $cachePath $cache } catch { Write-Warning "$($s.Name): cannot save check cache: $($_.Exception.Message)" }
        $timer.Stop()
        Add-Metric 'cohesity_collect_duration_seconds' 'Time spent collecting from the cluster.' $timer.Elapsed.TotalSeconds $labels
    }
}
# Unlabelled summary metrics belong to the top-level process only; in parallel mode the parent writes them.
if (-not $isChild) {
    Add-Metric 'cohesity_collector_last_run_timestamp_seconds' 'Unix time the collector last completed.' (Get-UnixNow) @{}
    Add-Metric 'cohesity_collector_info' 'Installed Cohesity monitoring package version (value is always 1).' 1 ([ordered]@{ version = $script:PackageVersion })
    # A per-cluster file from an earlier parallel run would duplicate this file's series, so drop it.
    foreach ($s in $selectedServers) {
        $stale = Join-Path $TextfileDirectory (Get-ServerMetricsFileName $s.Name)
        if ($stale -ne (Join-Path $TextfileDirectory $FileName) -and (Test-Path -LiteralPath $stale)) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
    }
}

$target = Join-Path $TextfileDirectory $FileName
$count = Write-MetricsFile $target
Write-Host ("Wrote {0} samples for {1} cluster(s) to {2}" -f $count, $selectedServers.Count, $target)
if ($anyFailure) { exit 2 }
exit 0
