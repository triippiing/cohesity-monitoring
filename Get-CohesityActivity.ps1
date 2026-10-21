<#
.SYNOPSIS
Reports Cohesity protection runs, recoveries and cluster operations in progress, and anything needing attention.

.DESCRIPTION
Clusters, transport and credential files come from Cohesity.config.json (or -ConfigPath /
$env:COHESITY_CONFIG). Interactive by default; for Task Scheduler use -All (or -Server) with
-NonInteractive and a CredentialFile per server (see New-CohesityCredentialFile in Cohesity.psm1).

Read-only: GETs only (plus the access-token login in AuthMode Password).

Rows: every backup run in progress, every backup run in the last -Hours that failed or missed its SLA, the
replication and archive state of each group's last run when it is not a success, recoveries in progress or
failed, and a cluster operation (upgrade, node add/remove) or stopped services. -IncludeAllRuns adds the
successful runs too.

Exit codes: 0 idle, 1 work active or queued, 2 attention / unknown state / API error, 3 usage or config error.

.EXAMPLE
.\Get-CohesityActivity.ps1
.EXAMPLE
.\Get-CohesityActivity.ps1 -All -NonInteractive -Hours 12
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Server,
    [switch]$All,
    [PSCredential]$Credential,
    [switch]$NonInteractive,
    [ValidateRange(1, 168)][int]$Hours = 24,
    [switch]$IncludeAllRuns,
    [string]$CsvPath,

    # Optional overrides of the config file transport settings.
    [ValidateSet('http', 'https')][string]$Scheme,
    [int]$Port = -1,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Cohesity.psm1') -Force -DisableNameChecking
} catch {
    [Console]::Error.WriteLine("ERROR: Cannot load Cohesity.psm1 from ${PSScriptRoot}: $($_.Exception.Message)")
    exit 3
}

# ---------------------------------------------------------------------------
# Setup: config, server selection and credentials. Any failure here is exit 3.
# ---------------------------------------------------------------------------
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

    if (-not $CsvPath) { $CsvPath = Get-CohesityReportPath -Directory $config.OutputDirectory -Prefix 'Cohesity-Activity' }
} catch {
    Write-CohesityUsageError $_.Exception.Message
    exit 3
}

# ---------------------------------------------------------------------------
# Status classification, pinned to the v2 run status enum (Accepted, Running, Canceled, Canceling, Failed,
# Missed, Succeeded, SucceededWithWarning, OnHold, Finalizing, Skipped, Paused) and the v1 k-prefixed forms.
# Anything not listed is 'Unknown' and is treated as needing attention.
# ---------------------------------------------------------------------------
function Get-StatusCategory {
    param([AllowNull()][AllowEmptyString()][string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) { return 'Unknown' }
    $s = $Status.Trim().ToLowerInvariant()
    if ($s -cmatch '^k[a-z]') { $s = $s.Substring(1) }
    switch -Regex ($s) {
        '^(running|finalizing|canceling|inprogress|active)$' { return 'Active' }
        '^(accepted|onhold|paused|queued|scheduled|pending)$' { return 'Queued' }
        '^(failed|missed|canceled|cancelled|failure|error)$' { return 'Attention' }
        '^(succeeded|success|successful|succeededwithwarning|warning|skipped|none|finished)$' { return 'Inactive' }
    }
    return 'Unknown'
}

function Format-Usecs {
    param($Value)
    if ($null -eq $Value -or [double]$Value -le 0) { return '' }
    return ConvertFrom-CohesityUsecs $Value
}

$runTimestamp = Get-CohesityTimestamp
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param($ServerConfig, [bool]$Reachable, [string]$Check, [string]$Object, [string]$Field,
          [string]$Status, [string]$Category, [string]$Detail = '', [string]$ErrorText = '')
    $results.Add([pscustomobject]@{
        Timestamp = $runTimestamp
        Server    = $ServerConfig.Name
        Host      = $ServerConfig.Host
        Reachable = $Reachable
        Check     = $Check
        Object    = $Object
        Field     = $Field
        Status    = $Status
        Category  = $Category
        Detail    = $Detail
        Error     = $ErrorText
    })
}

function Add-EndpointError {
    param($ServerConfig, [string]$Check, $ErrorRecord)
    $category = Get-CohesityErrorCategory $ErrorRecord
    $resultCategory = if ($category -eq 'Auth') { 'AuthError' } elseif ($category -eq 'Connection') { 'ConnectionError' } else { 'EndpointError' }
    Add-Result $ServerConfig ($category -ne 'Connection') $Check '' '' '' $resultCategory '' $ErrorRecord.Exception.Message
}

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------
foreach ($s in $selectedServers) {
    $connection = $null
    Write-Host "Checking $($s.Name) [$($s.Host)]..." -ForegroundColor Cyan

    try {
        $connection = Connect-Cohesity -ServerConfig $s -Credential $credentialByName[$s.Name]
    } catch {
        $category = Get-CohesityErrorCategory $_
        $resultCategory = if ($category -eq 'Auth') { 'AuthError' } else { 'ConnectionError' }
        Add-Result $s ($category -eq 'Auth') 'Login' '' '' '' $resultCategory '' $_.Exception.Message
        continue
    }

    try {
        $sinceUsecs = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$Hours * 3600000) * 1000

        # Cluster operation and stopped services (v1 cluster/status).
        try {
            $status = Invoke-CohesityApi -Connection $connection -Path '/irisservices/api/v1/public/cluster/status'
            $op = [string](Get-OptionalValue $status 'currentOperation' 'kNone')
            if ($op -and $op -ne 'kNone') { Add-Result $s $true 'Cluster' 'Cluster operation' 'currentOperation' $op 'Active' }
            foreach ($svc in @(Get-OptionalValue $status 'stoppedServices' @())) {
                Add-Result $s $true 'Cluster' ([string]$svc) 'service' 'stopped' 'Attention'
            }
        } catch {
            Add-EndpointError $s 'Cluster' $_
        }

        # Backup runs started in the window (v2 runs summary).
        try {
            $response = Invoke-CohesityApi -Connection $connection -Path ('/v2/data-protect/runs/summary?startTimeUsecs={0}' -f $sinceUsecs)
            $runs = @(Get-OptionalValue $response 'protectionRunsSummary' @())
            foreach ($r in ($runs | Sort-Object { [double](Get-OptionalValue $_ 'startTimeUsecs' 0) })) {
                $value = [string](Get-OptionalValue $r 'status' '')
                $category = Get-StatusCategory $value
                if ($category -eq 'Inactive' -and (Get-OptionalValue $r 'isSlaViolated' $false) -eq $true) { $category = 'Attention'; $value += ' (SLA missed)' }
                if ($category -eq 'Inactive' -and -not $IncludeAllRuns) { continue }
                $detail = 'env={0}; start={1}; end={2}; objects={3}/{4}; written={5}; run={6}' -f `
                    (Get-OptionalValue $r 'environment' ''), (Format-Usecs (Get-OptionalValue $r 'startTimeUsecs' $null)),
                    (Format-Usecs (Get-OptionalValue $r 'endTimeUsecs' $null)), (Get-OptionalValue $r 'successObjectsCount' ''),
                    (Get-OptionalValue $r 'totalObjectsCount' ''), (Get-OptionalValue $r 'bytesWritten' ''), (Get-OptionalValue $r 'id' '')
                Add-Result $s $true 'Backup runs' ([string](Get-OptionalValue $r 'protectionGroupName' '')) 'status' $value $category $detail
            }
            if ($runs.Count -eq 0) { Add-Result $s $true 'Backup runs' '' '' "No runs in the last $Hours hour(s)" 'Inactive' }
        } catch {
            Add-EndpointError $s 'Backup runs' $_
        }

        # Replication and archive state of each group's last run (only the ones that are not a plain success).
        try {
            $groups = @(Get-CohesityPagedCollection -Connection $connection -CollectionName 'protectionGroups' `
                -Path '/v2/data-protect/protection-groups?isDeleted=false&includeLastRunInfo=true&pruneSourceIds=true&pruneExcludedSourceIds=true')
            foreach ($g in $groups) {
                $name = [string](Get-OptionalValue $g 'name' '')
                if ((Get-OptionalValue $g 'isPaused' $false) -eq $true) { Add-Result $s $true 'Protection groups' $name 'isPaused' 'paused' 'Queued' 'No new runs are scheduled while the group is paused.' }
                $run = Get-OptionalValue $g 'lastRun' $null
                if ($null -eq $run) { continue }
                $tasks = @()
                foreach ($t in @(Get-OptionalValue (Get-OptionalValue $run 'replicationInfo' $null) 'replicationTargetResults' @())) { $tasks += , @('Replication', (Get-OptionalValue $t 'clusterName' ''), $t) }
                foreach ($t in @(Get-OptionalValue (Get-OptionalValue $run 'archivalInfo' $null) 'archivalTargetResults' @())) { $tasks += , @('Archive', (Get-OptionalValue $t 'targetName' ''), $t) }
                foreach ($task in $tasks) {
                    $value = [string](Get-OptionalValue $task[2] 'status' '')
                    $category = Get-StatusCategory $value
                    if ($category -eq 'Inactive' -and (Get-OptionalValue $task[2] 'isSlaViolated' $false) -eq $true) { $category = 'Attention'; $value += ' (SLA missed)' }
                    if ($category -eq 'Inactive' -and -not $IncludeAllRuns) { continue }
                    $detail = 'target={0}; start={1}; end={2}; percent={3}' -f $task[1], (Format-Usecs (Get-OptionalValue $task[2] 'startTimeUsecs' $null)),
                        (Format-Usecs (Get-OptionalValue $task[2] 'endTimeUsecs' $null)), (Get-OptionalValue $task[2] 'percentageCompleted' '')
                    Add-Result $s $true $task[0] $name 'status' $value $category $detail
                }
            }
        } catch {
            Add-EndpointError $s 'Protection groups' $_
        }

        # Recoveries in the window (v2).
        try {
            $response = Invoke-CohesityApi -Connection $connection -Path ('/v2/data-protect/recoveries?startTimeUsecs={0}' -f $sinceUsecs)
            foreach ($r in @(Get-OptionalValue $response 'recoveries' @())) {
                $value = [string](Get-OptionalValue $r 'status' '')
                $category = Get-StatusCategory $value
                if ($category -eq 'Inactive' -and -not $IncludeAllRuns) { continue }
                $detail = 'action={0}; env={1}; start={2}; user={3}' -f (Get-OptionalValue $r 'recoveryAction' ''), (Get-OptionalValue $r 'snapshotEnvironment' ''),
                    (Format-Usecs (Get-OptionalValue $r 'startTimeUsecs' $null)), (Get-OptionalValue (Get-OptionalValue $r 'creationInfo' $null) 'userName' '')
                Add-Result $s $true 'Recoveries' ([string](Get-OptionalValue $r 'name' '')) 'status' $value $category $detail
            }
        } catch {
            Add-EndpointError $s 'Recoveries' $_
        }
    } finally {
        Disconnect-Cohesity $connection
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
if (-not $PSBoundParameters.ContainsKey('CsvPath')) {
    Remove-CohesityOldReport -Directory $config.OutputDirectory -Prefix 'Cohesity-Activity' -RetentionDays $config.RetentionDays
}

$active    = @($results | Where-Object Category -eq 'Active')
$queued    = @($results | Where-Object Category -eq 'Queued')
$attention = @($results | Where-Object Category -in @('Attention', 'Unknown'))
$errors    = @($results | Where-Object Category -in @('ConnectionError', 'AuthError', 'EndpointError'))

Write-Host ''
Write-Host 'Estate summary' -ForegroundColor White
Write-Host ('Active work : {0}' -f $active.Count) -ForegroundColor $(if ($active.Count) { 'Yellow' } else { 'Green' })
Write-Host ('Queued work : {0}' -f $queued.Count) -ForegroundColor $(if ($queued.Count) { 'Yellow' } else { 'Green' })
Write-Host ('Attention   : {0}' -f $attention.Count) -ForegroundColor $(if ($attention.Count) { 'Red' } else { 'Green' })
Write-Host ('API errors  : {0}' -f $errors.Count) -ForegroundColor $(if ($errors.Count) { 'Red' } else { 'Green' })
Write-Host ("CSV report  : {0}" -f $CsvPath)

if ($active.Count -gt 0) {
    Write-Host ''
    Write-Host 'ACTIVE OPERATIONS' -ForegroundColor Yellow
    $active | Select-Object Server, Check, Object, Field, Status | Format-Table -AutoSize | Out-Host
} else {
    Write-Host ''
    Write-Host 'No active operations reported.' -ForegroundColor Green
}

if ($queued.Count -gt 0) {
    Write-Host 'QUEUED OR WAITING OPERATIONS' -ForegroundColor Yellow
    $queued | Select-Object Server, Check, Object, Field, Status | Format-Table -AutoSize | Out-Host
}

if ($attention.Count -gt 0 -or $errors.Count -gt 0) {
    Write-Host 'ITEMS REQUIRING ATTENTION' -ForegroundColor Red
    @($attention + $errors) | Select-Object Server, Check, Object, Category, Status, Detail, Error | Format-Table -AutoSize -Wrap | Out-Host
}

if ($errors.Count -gt 0 -or $attention.Count -gt 0) { exit 2 }
if ($active.Count -gt 0 -or $queued.Count -gt 0) { exit 1 }
exit 0
