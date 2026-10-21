<#
.SYNOPSIS
Lists the objects that failed, or finished with warnings, in the last run of each Cohesity protection group.

.DESCRIPTION
Clusters, transport and credential files come from Cohesity.config.json (or -ConfigPath /
$env:COHESITY_CONFIG). Interactive by default; for Task Scheduler use -All (or -Server) with
-NonInteractive and a CredentialFile per server (see New-CohesityCredentialFile in Cohesity.psm1).

Read-only: GETs only (plus the access-token login in AuthMode Password). Only groups whose last run failed
or succeeded with warnings are opened (one runs call each), so the report stays cheap on a large cluster.
-IncludeWarnings adds objects that succeeded with warnings.

Exit codes: 0 no failed objects, 1 failed objects found, 2 API error, 3 usage or config error.

.EXAMPLE
.\Get-CohesityFailedObjects.ps1 -Server COHESITY-01
.EXAMPLE
.\Get-CohesityFailedObjects.ps1 -All -NonInteractive -IncludeWarnings
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Server,
    [switch]$All,
    [PSCredential]$Credential,
    [switch]$NonInteractive,
    [switch]$IncludeWarnings,
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

    if (-not $CsvPath) { $CsvPath = Get-CohesityReportPath -Directory $config.OutputDirectory -Prefix 'Cohesity-Failed-Objects' }
} catch {
    Write-CohesityUsageError $_.Exception.Message
    exit 3
}

$runTimestamp = Get-CohesityTimestamp
$rows = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()
$columns = 'Timestamp,Server,Host,ProtectionGroup,Environment,RunStart,Object,ObjectEnvironment,Source,Result,Attempts,EndTime,Message'

function Add-ErrorRow {
    param($ServerConfig, [string]$Group, [string]$Stage, [string]$Message)
    $errors.Add([pscustomobject]@{
        Timestamp = $runTimestamp; Server = $ServerConfig.Name; Host = $ServerConfig.Host
        ProtectionGroup = $Group; Stage = $Stage; Error = $Message
    })
}

function Format-Usecs {
    param($Value)
    if ($null -eq $Value -or [double]$Value -le 0) { return '' }
    return ConvertFrom-CohesityUsecs $Value
}

foreach ($s in $selectedServers) {
    $connection = $null
    Write-Host "Checking $($s.Name) [$($s.Host)]..." -ForegroundColor Cyan

    try {
        $connection = Connect-Cohesity -ServerConfig $s -Credential $credentialByName[$s.Name]

        # Groups with their last run; only failed or warned runs are opened.
        $groups = @(Get-CohesityPagedCollection -Connection $connection -CollectionName 'protectionGroups' `
            -Path '/v2/data-protect/protection-groups?isDeleted=false&includeLastRunInfo=true&pruneSourceIds=true&pruneExcludedSourceIds=true')
        foreach ($g in $groups) {
            $name = [string](Get-OptionalValue $g 'name' '')
            $backup = Get-OptionalValue (Get-OptionalValue $g 'lastRun' $null) 'localBackupInfo' $null
            $status = ([string](Get-OptionalValue $backup 'status' '')).ToLowerInvariant()
            if ($status -notin @('failed', 'succeededwithwarning')) { continue }

            try {
                # GET protection-groups/{id}/runs -> runs[].objects[] : object{name,environment,sourceName},
                # localSnapshotInfo{snapshotInfo{status,warnings,endTimeUsecs}, failedAttempts[]{message,endTimeUsecs}}
                $response = Invoke-CohesityApi -Connection $connection -Path ('/v2/data-protect/protection-groups/{0}/runs?numRuns=1&includeObjectDetails=true' -f [uri]::EscapeDataString([string](Get-OptionalValue $g 'id' '')))
                $listed = 0
                foreach ($run in @(@(Get-OptionalValue $response 'runs' @()) | Select-Object -First 1)) {
                    foreach ($o in @(Get-OptionalValue $run 'objects' @())) {
                        $snap = Get-OptionalValue $o 'localSnapshotInfo' $null
                        $info = Get-OptionalValue $snap 'snapshotInfo' $null
                        $attempts = @(Get-OptionalValue $snap 'failedAttempts' @())
                        $warnings = @(Get-OptionalValue $info 'warnings' @())
                        $objStatus = ([string](Get-OptionalValue $info 'status' '')).ToLowerInvariant()
                        $failed = $objStatus -match 'fail' -or ($attempts.Count -gt 0 -and $objStatus -notmatch 'succe')
                        if (-not $failed -and -not ($IncludeWarnings -and $warnings.Count -gt 0)) { continue }
                        $listed++
                        $message = if ($attempts.Count -gt 0) { Get-OptionalValue $attempts[-1] 'message' '' } elseif ($warnings.Count -gt 0) { $warnings -join ' | ' } else { '' }
                        $end = Get-OptionalValue $info 'endTimeUsecs' $null
                        if ($null -eq $end -and $attempts.Count -gt 0) { $end = Get-OptionalValue $attempts[-1] 'endTimeUsecs' $null }
                        $object = Get-OptionalValue $o 'object' $null
                        $rows.Add([pscustomobject]@{
                            Timestamp         = $runTimestamp
                            Server            = $s.Name
                            Host              = $s.Host
                            ProtectionGroup   = $name
                            Environment       = Get-OptionalValue $g 'environment' ''
                            RunStart          = Format-Usecs (Get-OptionalValue $backup 'startTimeUsecs' $null)
                            Object            = Get-OptionalValue $object 'name' ''
                            ObjectEnvironment = Get-OptionalValue $object 'environment' ''
                            Source            = Get-OptionalValue $object 'sourceName' ''
                            Result            = $(if ($failed) { 'Failed' } else { 'Warning' })
                            Attempts          = $attempts.Count
                            EndTime           = Format-Usecs $end
                            Message           = $message
                        })
                    }
                }

                # Cross-check: a failed run with no failed object parsed means the response format changed.
                $expected = [int](Get-OptionalValue $backup 'failedObjectsCount' 0)
                if ($status -eq 'failed' -and $expected -gt 0 -and $listed -eq 0) {
                    Add-ErrorRow $s $name 'Cross-check' ("Last run reports failedObjectsCount={0} but no failed object was parsed." -f $expected)
                }
            } catch {
                Add-ErrorRow $s $name 'Read last run objects' $_.Exception.Message
            }
        }
    } catch {
        Add-ErrorRow $s '' 'Login or list protection groups' $_.Exception.Message
    } finally {
        Disconnect-Cohesity $connection
    }
}

$rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
if ($rows.Count -eq 0) {
    # Keep a header-only CSV so downstream readers always find a file.
    $columns | Set-Content -LiteralPath $CsvPath -Encoding UTF8
}
if (-not $PSBoundParameters.ContainsKey('CsvPath')) {
    Remove-CohesityOldReport -Directory $config.OutputDirectory -Prefix 'Cohesity-Failed-Objects' -RetentionDays $config.RetentionDays
}

$failedRows = @($rows | Where-Object Result -eq 'Failed')
Write-Host ''
Write-Host 'Failed objects (last run of each group)' -ForegroundColor White
if ($rows.Count -eq 0) {
    Write-Host 'No failed objects in the last run of any protection group.' -ForegroundColor Green
} else {
    $rows | Select-Object Server, ProtectionGroup, Object, Result, Attempts, Message | Format-Table -AutoSize -Wrap | Out-Host
}

Write-Host ''
Write-Host ("Failed objects : {0}" -f $failedRows.Count) -ForegroundColor $(if ($failedRows.Count -gt 0) { 'Yellow' } else { 'Green' })
if ($IncludeWarnings) { Write-Host ("Warnings       : {0}" -f ($rows.Count - $failedRows.Count)) }
Write-Host ("API errors     : {0}" -f $errors.Count) -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ("CSV report     : {0}" -f $CsvPath)

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host 'Errors' -ForegroundColor Red
    $errors | Format-Table Server, ProtectionGroup, Stage, Error -AutoSize -Wrap | Out-Host
    exit 2
}
if ($failedRows.Count -gt 0) { exit 1 }
exit 0
