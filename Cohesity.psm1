# Cohesity.psm1 - shared helpers for the Cohesity DataProtect REST API (v2 at /v2, v1 at /irisservices/api/v1).
# Compatible with Windows PowerShell 5.1 and PowerShell 7.x.
#
# Read-only by construction: Invoke-CohesityApi only sends GET. The one POST in this module is the
# access-token login (POST /irisservices/api/v1/public/accessTokens), which changes nothing on the cluster.
#
# Exit code convention used by the scripts that import this module:
#   0 = OK / idle, 1 = informational (runs active, recoveries running),
#   2 = attention or API error, 3 = usage / configuration error.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

function New-CohesityError {
    # Category: Usage | Config | Auth | Connection | Api
    param([Parameter(Mandatory)][string]$Message, [string]$Category = 'Api', [int]$HttpStatus = 0)
    $ex = New-Object System.Exception $Message
    $ex.Data['CohesityCategory'] = $Category
    $ex.Data['HttpStatus'] = $HttpStatus
    return $ex
}

function Get-CohesityErrorCategory {
    param([Parameter(Mandatory)]$ErrorRecordOrException)
    $ex = $ErrorRecordOrException
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    if ($ex.Data.Contains('CohesityCategory')) { return [string]$ex.Data['CohesityCategory'] }
    return 'Api'
}

function Get-HttpStatusFromError {
    param($ErrorRecord)
    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) { return 0 }
    try { return [int]$responseProperty.Value.StatusCode } catch { return 0 }
}

function Get-CohesityErrorText {
    # Cohesity answers errors with {"errorCode": "...", "message": "..."}; fall back to the exception text.
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails
    if ($null -ne $detail -and $detail.Message) {
        try {
            $json = $detail.Message | ConvertFrom-Json
            $message = $json.PSObject.Properties['message']
            if ($null -ne $message -and $message.Value) { return [string]$message.Value }
        } catch { }
        return ([string]$detail.Message).Trim()
    }
    return $ErrorRecord.Exception.Message
}

# ---------------------------------------------------------------------------
# Configuration and credentials
# ---------------------------------------------------------------------------

function Get-CohesityDefaultConfigPath {
    param([string]$ScriptRoot)
    if (-not [string]::IsNullOrWhiteSpace($env:COHESITY_CONFIG)) { return $env:COHESITY_CONFIG }
    return (Join-Path $ScriptRoot 'Cohesity.config.json')
}

function Get-OptionalValue {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value)) { return $Default }
    return $property.Value
}

function Import-CohesityConfig {
    <#
    .SYNOPSIS
    Loads the estate configuration (clusters, transport, output) from JSON.
    Relative paths in the file are resolved against the config file's directory.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-CohesityError "Config file not found: $Path. Copy Cohesity.config.example.json to Cohesity.config.json or set COHESITY_CONFIG." 'Config')
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw (New-CohesityError "Config file $Path is not valid JSON: $($_.Exception.Message)" 'Config')
    }

    $configDir = Split-Path -Parent (Resolve-Path -LiteralPath $Path).ProviderPath
    $defaults = Get-OptionalValue $raw 'Defaults' $null

    $outputDir = Get-OptionalValue $defaults 'OutputDirectory' 'Reports'
    if (-not [System.IO.Path]::IsPathRooted($outputDir)) { $outputDir = Join-Path $configDir $outputDir }

    # windows_exporter textfile directory; relative paths (default 'metrics') sit next to the config file.
    $textfileDir = Get-OptionalValue $defaults 'TextfileDirectory' 'metrics'
    if (-not [System.IO.Path]::IsPathRooted($textfileDir)) { $textfileDir = Join-Path $configDir $textfileDir }

    $servers = @(Get-OptionalValue $raw 'Servers' @())
    if ($servers.Count -eq 0) { throw (New-CohesityError "Config file $Path defines no Servers." 'Config') }

    $resolved = foreach ($s in $servers) {
        $name = Get-OptionalValue $s 'Name' $null
        $hostName = Get-OptionalValue $s 'Host' $null
        if (-not $name -or -not $hostName) { throw (New-CohesityError "Every entry in Servers needs Name and Host ($Path)." 'Config') }

        $credFile = Get-OptionalValue $s 'CredentialFile' $null
        if ($credFile -and -not [System.IO.Path]::IsPathRooted($credFile)) { $credFile = Join-Path $configDir $credFile }

        [pscustomobject]@{
            Name                 = [string]$name
            Host                 = [string]$hostName
            # ApiKey: the credential's password is a Cohesity API key, sent in the apiKey header.
            # Password: the credential is a user name and password, exchanged for an access token.
            AuthMode             = [string](Get-OptionalValue $s 'AuthMode' (Get-OptionalValue $defaults 'AuthMode' 'ApiKey'))
            # Login domain for Password mode: LOCAL for a local user, or the Active Directory domain.
            Domain               = [string](Get-OptionalValue $s 'Domain' (Get-OptionalValue $defaults 'Domain' 'LOCAL'))
            Scheme               = [string](Get-OptionalValue $s 'Scheme' (Get-OptionalValue $defaults 'Scheme' 'https'))
            Port                 = [int](Get-OptionalValue $s 'Port' (Get-OptionalValue $defaults 'Port' 0))
            SkipCertificateCheck = [bool](Get-OptionalValue $s 'SkipCertificateCheck' (Get-OptionalValue $defaults 'SkipCertificateCheck' $false))
            TimeoutSec           = [int](Get-OptionalValue $s 'TimeoutSec' (Get-OptionalValue $defaults 'TimeoutSec' 60))
            CredentialFile       = $credFile
        }
    }

    foreach ($r in $resolved) {
        if ($r.Scheme -notin @('http', 'https')) { throw (New-CohesityError "Server $($r.Name): Scheme must be http or https." 'Config') }
        if ($r.AuthMode -notin @('ApiKey', 'Password')) { throw (New-CohesityError "Server $($r.Name): AuthMode must be ApiKey or Password." 'Config') }
    }

    # Collector state (alert bookmark, run first-seen times, cached slow checks) and the raw alert archive.
    $stateDir = Get-OptionalValue $defaults 'StateDirectory' 'state'
    if (-not [System.IO.Path]::IsPathRooted($stateDir)) { $stateDir = Join-Path $configDir $stateDir }
    $alertDir = Get-OptionalValue $defaults 'AlertLogDirectory' 'events'
    if (-not [System.IO.Path]::IsPathRooted($alertDir)) { $alertDir = Join-Path $configDir $alertDir }

    [pscustomobject]@{
        Path              = $Path
        OutputDirectory   = $outputDir
        TextfileDirectory = $textfileDir
        StateDirectory    = $stateDir
        AlertLogDirectory = $alertDir
        CollectAlerts     = [bool](Get-OptionalValue $defaults 'CollectAlerts' $true)
        AlertLogRetentionDays = [int](Get-OptionalValue $defaults 'AlertLogRetentionDays' 90)
        DisabledChecks    = @(Get-OptionalValue $defaults 'DisabledChecks' @())
        RetentionDays     = [int](Get-OptionalValue $defaults 'RetentionDays' 30)
        Servers           = @($resolved)
    }
}

function Select-CohesityServer {
    <#
    .SYNOPSIS
    Picks clusters by -Server names, -All, or (interactive only) a numbered menu.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string[]]$Server,
        [switch]$All,
        [switch]$NonInteractive
    )

    $servers = @($Config.Servers)
    if ($All) { return $servers }

    if ($Server -and $Server.Count -gt 0) {
        $selected = foreach ($wanted in $Server) {
            $match = @($servers | Where-Object { $_.Name -ieq $wanted -or $_.Host -ieq $wanted })
            if ($match.Count -eq 0) {
                throw (New-CohesityError "Server '$wanted' is not in $($Config.Path). Known: $(($servers | ForEach-Object Name) -join ', ')" 'Usage')
            }
            $match[0]
        }
        return @($selected | Sort-Object Name -Unique)
    }

    if ($NonInteractive) { throw (New-CohesityError 'Specify -Server <name[,name]> or -All when running with -NonInteractive.' 'Usage') }

    Write-Host ''
    Write-Host 'Available Cohesity clusters' -ForegroundColor White
    for ($i = 0; $i -lt $servers.Count; $i++) {
        Write-Host ("{0}. {1} [{2}]" -f ($i + 1), $servers[$i].Name, $servers[$i].Host)
    }
    Write-Host 'A. All clusters'

    $selection = Read-Host 'Select clusters (for example: 1,2 or A)'
    if ([string]::IsNullOrWhiteSpace($selection)) { throw (New-CohesityError 'No cluster selection was entered.' 'Usage') }
    if ($selection.Trim() -match '^(?i:a|all)$') { return $servers }

    $indexes = foreach ($entry in ($selection -split ',')) {
        $number = 0
        if (-not [int]::TryParse($entry.Trim(), [ref]$number)) {
            throw (New-CohesityError "Invalid selection '$entry'. Enter A or comma-separated cluster numbers, for example 1,2." 'Usage')
        }
        if ($number -lt 1 -or $number -gt $servers.Count) {
            throw (New-CohesityError "Cluster number $number is outside the valid range 1-$($servers.Count)." 'Usage')
        }
        $number - 1
    }
    return @($indexes | Select-Object -Unique | ForEach-Object { $servers[$_] })
}

function New-CohesityCredentialFile {
    <#
    .SYNOPSIS
    Saves an API credential with Export-Clixml. On Windows the secret is DPAPI-encrypted and can only be
    read back by the same user account on the same machine, so create it as the account that runs the
    scheduled task. For AuthMode ApiKey enter any user name (e.g. apikey) and the API key as the password;
    for AuthMode Password enter the Cohesity user name and password.
    .EXAMPLE
    Import-Module .\Cohesity.psm1; New-CohesityCredentialFile -Path .\creds\cohesity-01.xml
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$UserName)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $message = 'Cohesity API credential (ApiKey mode: any user name, the API key as the password)'
    $cred = if ($UserName) { Get-Credential -UserName $UserName -Message $message } else { Get-Credential -Message $message }
    if ($null -eq $cred) { throw (New-CohesityError 'No credential entered.' 'Usage') }
    $cred | Export-Clixml -LiteralPath $Path
    Write-Host "Saved credential for $($cred.UserName) to $Path"
}

function Get-CohesityCredential {
    <#
    .SYNOPSIS
    Credential precedence: -Credential parameter, then the server's CredentialFile, then an
    interactive prompt (not allowed with -NonInteractive).
    #>
    param(
        [Parameter(Mandatory)]$ServerConfig,
        [PSCredential]$Credential,
        [switch]$NonInteractive
    )
    if ($null -ne $Credential) { return $Credential }

    # A configured but missing credential file is fatal only for unattended runs; interactively we prompt.
    $credFileMissing = $ServerConfig.CredentialFile -and -not (Test-Path -LiteralPath $ServerConfig.CredentialFile -PathType Leaf)
    if ($credFileMissing -and $NonInteractive) {
        throw (New-CohesityError "Credential file for $($ServerConfig.Name) not found: $($ServerConfig.CredentialFile). Create it with New-CohesityCredentialFile." 'Config')
    }
    if ($ServerConfig.CredentialFile -and -not $credFileMissing) {
        try {
            $imported = Import-Clixml -LiteralPath $ServerConfig.CredentialFile
        } catch {
            throw (New-CohesityError "Cannot read credential file for $($ServerConfig.Name) (it must be created by the same user on the same machine): $($_.Exception.Message)" 'Config')
        }
        if ($imported -isnot [PSCredential]) { throw (New-CohesityError "Credential file for $($ServerConfig.Name) does not contain a PSCredential." 'Config') }
        return $imported
    }

    if ($NonInteractive) {
        throw (New-CohesityError "No CredentialFile configured for $($ServerConfig.Name) and -NonInteractive was given." 'Config')
    }
    $prompted = Get-Credential -Message ("Enter API credentials for {0} [{1}] (AuthMode {2})" -f $ServerConfig.Name, $ServerConfig.Host, $ServerConfig.AuthMode)
    if ($null -eq $prompted) { throw (New-CohesityError "No credentials supplied for $($ServerConfig.Name)." 'Usage') }
    return $prompted
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

$script:IsCore = $PSVersionTable.PSEdition -eq 'Core'
$script:V1 = '/irisservices/api/v1/public'

function Enable-LegacyCertificateBypass {
    # Windows PowerShell 5.1 only: Invoke-RestMethod has no -SkipCertificateCheck there.
    if ($script:IsCore) { return }
    if (-not ([System.Management.Automation.PSTypeName]'CohesityTrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class CohesityTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object CohesityTrustAllCertsPolicy
}

if (-not $script:IsCore) {
    # Windows PowerShell 5.1 defaults to TLS 1.0/1.1 on older .NET builds; Cohesity clusters require TLS 1.2.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

function Get-CohesityAuthHeader {
    param([Parameter(Mandatory)]$Connection)
    if ($Connection.Server.AuthMode -eq 'ApiKey') { return @{ apiKey = $Connection.Credential.GetNetworkCredential().Password } }
    if ($Connection.Token) { return @{ Authorization = ('Bearer ' + $Connection.Token) } }
    return @{}
}

function Invoke-CohesityHttp {
    # Single HTTP call with consistent error classification. No retry here.
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][ValidateSet('Get', 'Post')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [string]$Body,
        [switch]$NoAuth
    )
    $headers = @{ Accept = 'application/json' }
    if (-not $NoAuth) { foreach ($h in (Get-CohesityAuthHeader $Connection).GetEnumerator()) { $headers[$h.Key] = $h.Value } }
    $params = @{
        Method      = $Method
        Uri         = $Connection.BaseUri + $Path
        Headers     = $headers
        TimeoutSec  = $Connection.Server.TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.ContentType = 'application/json'
        $params.Body = $Body
    }
    if ($script:IsCore -and $Connection.Server.SkipCertificateCheck) { $params.SkipCertificateCheck = $true }

    try {
        return Invoke-RestMethod @params
    } catch {
        $status = Get-HttpStatusFromError $_
        $category = 'Api'
        if ($status -eq 401 -or $status -eq 403) { $category = 'Auth' }
        elseif ($status -eq 0) { $category = 'Connection' }   # DNS, refused, TLS, timeout
        $text = Get-CohesityErrorText $_
        throw (New-CohesityError ("{0} {1} failed{2}: {3}" -f $Method.ToUpperInvariant(), $Path, $(if ($status) { " (HTTP $status)" } else { '' }), $text) $category $status)
    }
}

function Test-TransientError {
    param($Exception)
    $category = Get-CohesityErrorCategory $Exception
    $status = [int]$Exception.Data['HttpStatus']
    return ($category -eq 'Connection' -or $status -in @(408, 429, 500, 502, 503, 504))
}

function Connect-Cohesity {
    <#
    .SYNOPSIS
    Opens a connection: ApiKey mode needs no login; Password mode exchanges the credential for an access
    token. Either way one authenticated GET proves the credential works before any check runs.
    #>
    param(
        [Parameter(Mandatory)]$ServerConfig,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    if ($ServerConfig.SkipCertificateCheck) { Enable-LegacyCertificateBypass }

    $baseUri = if ($ServerConfig.Port -gt 0) { "{0}://{1}:{2}" -f $ServerConfig.Scheme, $ServerConfig.Host, $ServerConfig.Port }
               else { "{0}://{1}" -f $ServerConfig.Scheme, $ServerConfig.Host }

    $connection = [pscustomobject]@{
        Server     = $ServerConfig
        BaseUri    = $baseUri
        Credential = $Credential
        Token      = $null
    }
    if ($ServerConfig.AuthMode -eq 'Password') { Open-CohesitySession $connection }
    Invoke-CohesityApi -Connection $connection -Path '/v2/clusters/state' | Out-Null
    return $connection
}

function Open-CohesitySession {
    param([Parameter(Mandatory)]$Connection)

    $userName = $Connection.Credential.UserName
    $domain = $Connection.Server.Domain
    # DOMAIN\user and user@domain override the configured Domain.
    if ($userName -match '^([^\\]+)\\(.+)$') { $domain = $Matches[1]; $userName = $Matches[2] }
    elseif ($userName -match '^([^@]+)@(.+)$') { $userName = $Matches[1]; $domain = $Matches[2] }
    $body = @{
        domain   = $domain
        username = $userName
        password = $Connection.Credential.GetNetworkCredential().Password
    } | ConvertTo-Json -Compress

    $response = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $response = Invoke-CohesityHttp -Connection $Connection -Method Post -Path "$script:V1/accessTokens" -Body $body -NoAuth
            break
        } catch {
            if ($attempt -eq 2 -or -not (Test-TransientError $_.Exception)) { throw }
            Start-Sleep -Seconds 3
        }
    }

    # Never echo the login response: it carries the token.
    $tokenProperty = if ($null -ne $response) { $response.PSObject.Properties['accessToken'] } else { $null }
    if ($null -eq $tokenProperty -or [string]::IsNullOrWhiteSpace([string]$tokenProperty.Value)) {
        throw (New-CohesityError "Login for $userName returned no access token." 'Auth')
    }
    $Connection.Token = [string]$tokenProperty.Value
}

function Invoke-CohesityApi {
    <#
    .SYNOPSIS
    GET with one retry on transient failures and, in Password mode, one re-login on 401 (tokens expire).
    Path is the full path from the cluster root, e.g. '/v2/stats/cluster-storage' or
    '/irisservices/api/v1/public/alerts'. There is deliberately no Method parameter: this package only reads.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Path
    )
    $reloggedIn = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-CohesityHttp -Connection $Connection -Method Get -Path $Path
        } catch {
            $ex = $_.Exception
            if ($Connection.Server.AuthMode -eq 'Password' -and [int]$ex.Data['HttpStatus'] -eq 401 -and -not $reloggedIn) {
                $reloggedIn = $true
                Open-CohesitySession $Connection
                continue
            }
            if ($attempt -lt 3 -and (Test-TransientError $ex)) { Start-Sleep -Seconds (2 * $attempt); continue }
            throw
        }
    }
}

function Get-CohesityPagedCollection {
    <#
    .SYNOPSIS
    Reads a v2 cookie-paged endpoint until no paginationCookie comes back, e.g.
    Get-CohesityPagedCollection -Connection $c -Path '/v2/data-protect/protection-groups' -CollectionName 'protectionGroups'
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CollectionName,
        [int]$PageSize = 1000,
        [string]$CountParameter = 'maxResultCount',
        [string]$CookieParameter = 'paginationCookie',
        [int]$MaxPages = 50
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $cookie = $null
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $uri = '{0}{1}{2}={3}' -f $Path, $separator, $CountParameter, $PageSize
        if ($cookie) { $uri += '&{0}={1}' -f $CookieParameter, [uri]::EscapeDataString($cookie) }
        $response = Invoke-CohesityApi -Connection $Connection -Path $uri
        foreach ($item in @(Get-OptionalValue $response $CollectionName @())) { $items.Add($item) }
        $cookie = [string](Get-OptionalValue $response $CookieParameter '')
        if (-not $cookie) { break }
    }
    return $items.ToArray()
}

function Disconnect-Cohesity {
    # Access tokens simply expire; nothing to call. Drop the token so the object cannot be reused by mistake.
    param($Connection)
    if ($null -eq $Connection) { return }
    $Connection.Token = $null
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Get-CohesityTimestamp {
    # One UTC ISO-8601 timestamp per run, culture independent.
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-CohesityUsecs {
    # Cohesity times are microseconds since the epoch (*Usecs); returns ISO-8601 UTC or ''.
    param($Usecs)
    if ($null -eq $Usecs -or [double]$Usecs -le 0) { return '' }
    return [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$Usecs / 1000)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-CohesityReportPath {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Prefix)
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    return (Join-Path $Directory ("{0}-{1}.csv" -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Remove-CohesityOldReport {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Prefix, [int]$RetentionDays)
    if ($RetentionDays -le 0 -or -not (Test-Path -LiteralPath $Directory)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter "$Prefix-*.csv" -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-CohesityUsageError {
    # Writes to stderr without throwing, so callers can 'exit 3' reliably.
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("ERROR: $Message")
}

Export-ModuleMember -Function @(
    'New-CohesityError', 'Get-CohesityErrorCategory',
    'Get-CohesityDefaultConfigPath', 'Import-CohesityConfig', 'Select-CohesityServer',
    'New-CohesityCredentialFile', 'Get-CohesityCredential',
    'Connect-Cohesity', 'Disconnect-Cohesity', 'Invoke-CohesityApi', 'Get-CohesityPagedCollection',
    'Get-CohesityTimestamp', 'ConvertFrom-CohesityUsecs', 'Get-CohesityReportPath', 'Remove-CohesityOldReport',
    'Write-CohesityUsageError', 'Get-OptionalValue'
)
