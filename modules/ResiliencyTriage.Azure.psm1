#Requires -Version 7.2
<#
    ResiliencyTriage.Azure - data layer for Azure Advisor resiliency reviews.

    Reviews and their recommendations have no Az.Advisor cmdlets, so everything is a raw
    ARM call with a bearer token from Az.Accounts. Plain REST (instead of Invoke-AzRestMethod)
    keeps the calls usable from parallel runspaces and background thread jobs.

    Lifecycle (api-version 2026-03-01-preview):
      * resiliencyReviews             - the review published by the Microsoft account team
      * Microsoft.Advisor/recommendations with properties.review
                                      - one recommendation per impacted resource, linked to the review
      * PATCH recommendationStatus    - New (Active) / Postponed / Dismissed / Completed
#>

Set-StrictMode -Version Latest

$script:ReviewApiVersions   = @('2026-03-01-preview', '2026-02-01-preview', '2025-05-01-preview')
$script:AdvisorApiVersion   = '2026-03-01-preview'
$script:GraphApiVersion     = '2022-10-01'
$script:SubscriptionApi     = '2022-12-01'

$script:PriorityRank = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Informational = 4 }

# Process-wide activity log. A static .NET type is shared by the TUI, thread jobs and
# ForEach-Object -Parallel runspaces without copying functions around.
if (-not ('ResiliencyTriage.RtLog' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace ResiliencyTriage {
    public static class RtLog {
        static readonly object Gate = new object();
        static readonly LinkedList<string> Buffer = new LinkedList<string>();
        public static string Path;
        public static void Write(string level, string message) {
            string line = string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1,3}] {2,-5} {3}", DateTime.Now, Environment.CurrentManagedThreadId, level, message);
            lock (Gate) {
                Buffer.AddLast(line);
                while (Buffer.Count > 500) Buffer.RemoveFirst();
                if (!string.IsNullOrEmpty(Path)) { try { System.IO.File.AppendAllText(Path, line + Environment.NewLine); } catch { } }
            }
        }
        public static string[] Recent(int count) {
            lock (Gate) {
                var all = new List<string>(Buffer);
                int start = Math.Max(0, all.Count - count);
                return all.GetRange(start, all.Count - start).ToArray();
            }
        }
    }
}
'@
}

$script:DismissReasons = @(
    'RiskIsAcceptable'
    'AnAlternativeSolutionIsAlreadyInPlace'
    'ExcessiveCostInvestmentRequired'
    'TooComplexOrImpracticalToImplement'
    'IncompatibleWithTheCurrentConfiguration'
    'ImplementationStepsAreUnclear'
    'Other'
)

#region Helpers

function Initialize-RtLog {
    <# Starts the session log file; returns its path. #>
    param([Parameter(Mandatory)][string]$Folder)
    $null = New-Item -ItemType Directory -Path $Folder -Force
    $path = Join-Path $Folder ('session-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [ResiliencyTriage.RtLog]::Path = $path
    Write-RtLog "Session started - PowerShell $($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    return $path
}

function Write-RtLog {
    <# Adds a line to the activity log (file + in-memory buffer shown by the TUI). #>
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'HTTP')][string]$Level = 'INFO')
    [ResiliencyTriage.RtLog]::Write($Level, $Message)
}

function Get-RtRecentLog {
    <# Latest activity log lines. #>
    param([int]$Count = 10)
    @([ResiliencyTriage.RtLog]::Recent($Count))
}

function Get-RtProp {
    <# StrictMode-safe property read (supports dotted paths) for ConvertFrom-Json objects. #>
    param([object]$InputObject, [Parameter(Mandatory)][string]$Name, [object]$Default = '')
    $current = $InputObject
    foreach ($part in $Name.Split('.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $Default }
            $current = $current[$part]
            continue
        }
        if ($current.PSObject.Properties.Name -notcontains $part) { return $Default }
        $current = $current.$part
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Get-RtDismissReason {
    <# Dismiss reasons accepted by the Advisor recommendation PATCH API. #>
    return @($script:DismissReasons)
}

function Get-RtPriorityRank {
    param([string]$Priority)
    if ($Priority -and $script:PriorityRank.ContainsKey($Priority)) { return $script:PriorityRank[$Priority] }
    return 5
}

function ConvertTo-RtStatusBucket {
    <# Collapses every Advisor / legacy triage status into the four portal buckets. #>
    param([string]$Status)
    switch -Regex ($Status) {
        '^(Postponed)$'            { return 'Postponed' }
        '^(Completed)$'            { return 'Completed' }
        '^(Dismissed|Rejected)$'   { return 'Dismissed' }
        default                    { return 'Active' }   # New, Active, Pending, NotStarted, InProgress, Accepted, Approved
    }
}

function Get-RtResourceGroupFromId {
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)') { return $Matches[1] }
    return ''
}

#endregion

#region Authentication / token

function Set-RtProxy {
    <#
    .SYNOPSIS
        Lets every web call of this process authenticate to a proxy (fixes HTTP 407).
    .DESCRIPTION
        PowerShell 7 picks up the system proxy (incl. PAC) but does not send credentials to it.
        This sets the process-wide default proxy credentials to the signed-in Windows user
        (Kerberos/NTLM), or to -Credential. Parallel runspaces and thread jobs share it.
    .OUTPUTS
        The proxy URI used for Azure Resource Manager, or $null when no proxy applies.
    #>
    param([string]$Proxy, [pscredential]$Credential)
    $cred = if ($Credential) { $Credential.GetNetworkCredential() } else { [System.Net.CredentialCache]::DefaultNetworkCredentials }
    if ($Proxy) {
        $wp = [System.Net.WebProxy]::new($Proxy, $true)
        $wp.Credentials = $cred
        [System.Net.Http.HttpClient]::DefaultProxy = $wp
    }
    $default = [System.Net.Http.HttpClient]::DefaultProxy
    $default.Credentials = $cred
    # Legacy WebRequest stack (used by some modules, e.g. PowerShellGet v2).
    try { [System.Net.WebRequest]::DefaultWebProxy = $default } catch { }

    $target = [uri]'https://management.azure.com/'
    try {
        if ($default.IsBypassed($target)) { return $null }
        $used = $default.GetProxy($target)
        if ($used -and $used.Host -ne $target.Host) { return $used }
    } catch { }
    return $null
}

function Assert-RtAzModule {
    <# Makes sure Az.Accounts is present and imported; offers an install when missing. #>
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host 'The Az.Accounts module is required but not installed.' -ForegroundColor Yellow
        $answer = Read-Host 'Install Az.Accounts for the current user now? [Y/n]'
        if ($answer -and $answer -notmatch '^(y|yes)$') { throw 'Az.Accounts is required. Install it with: Install-Module Az.Accounts -Scope CurrentUser' }
        Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue
}

function Get-RtAzContextInfo {
    <# Returns a summary of the current Az context or $null when not signed in. #>
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) { return $null }
    [pscustomobject]@{
        Account          = [string]$ctx.Account.Id
        AccountType      = [string]$ctx.Account.Type
        TenantId         = [string]$ctx.Tenant.Id
        SubscriptionName = if ($ctx.Subscription) { [string]$ctx.Subscription.Name } else { '' }
        SubscriptionId   = if ($ctx.Subscription) { [string]$ctx.Subscription.Id } else { '' }
        Environment      = [string]$ctx.Environment.Name
    }
}

function Connect-RtAzure {
    <# Interactive sign-in; returns the new context summary. #>
    param([string]$TenantId, [switch]$UseDeviceAuthentication)
    $params = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($TenantId) { $params['TenantId'] = $TenantId }
    if ($UseDeviceAuthentication) { $params['UseDeviceAuthentication'] = $true }
    Write-RtLog "Connect-AzAccount (tenant '$TenantId', device code: $([bool]$UseDeviceAuthentication))"
    $null = Connect-AzAccount @params
    return Get-RtAzContextInfo
}

function Get-RtArmToken {
    <# Returns a plain-text ARM bearer token for the current context (handles SecureString tokens). #>
    $params = @{ ResourceUrl = 'https://management.azure.com/'; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ((Get-Command Get-AzAccessToken).Parameters.ContainsKey('AsSecureString')) { $params['AsSecureString'] = $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $token = (Get-AzAccessToken @params).Token
    Write-RtLog ("ARM token acquired in {0:n1}s" -f $sw.Elapsed.TotalSeconds)
    if ($token -is [securestring]) { $token = ConvertFrom-SecureString -SecureString $token -AsPlainText }
    return [string]$token
}

#endregion

#region ARM REST

function Invoke-RtArm {
    <#
    .SYNOPSIS
        Sends an ARM request with a bearer token and returns the parsed body.
    .DESCRIPTION
        Retries throttling (429), transient 5xx responses and network errors/timeouts. Throws on any other error;
        the exception message starts with 'HTTP <code>' so callers can react to it.
        With -AllPages the 'value' arrays of all pages (nextLink) are concatenated.
        Self-contained (only needs Get-RtProp) so it can be recreated in parallel runspaces.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path,
        [string]$ApiVersion,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT')][string]$Method = 'GET',
        [object]$Body,
        [switch]$AllPages
    )
    $uri = if ($Path -match '^https://') { $Path } else { "https://management.azure.com$Path" }
    if ($ApiVersion) { $uri += ($uri.Contains('?') ? '&' : '?') + "api-version=$ApiVersion" }
    $headers = @{ Authorization = "Bearer $Token" }
    $payload = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { $null }

    $items = [System.Collections.Generic.List[object]]::new()
    $page = 0
    while ($uri) {
        $attempt = 0
        $page++
        # Log without host/query noise (never the token or body).
        $short = ($uri -replace '^https://management\.azure\.com', '' -replace '\?.*$', '')
        if ($short.Length -gt 140) { $short = $short.Substring(0, 60) + '…' + $short.Substring($short.Length - 79) }
        if ($page -gt 1) { $short += " (page $page)" }
        while ($true) {
            $attempt++
            [ResiliencyTriage.RtLog]::Write('HTTP', "-> $Method $short")
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $req = @{ Uri = $uri; Method = $Method; Headers = $headers; SkipHttpErrorCheck = $true; ErrorAction = 'Stop'; TimeoutSec = 100 }
            if ($payload) { $req['Body'] = $payload; $req['ContentType'] = 'application/json' }
            try { $resp = Invoke-WebRequest @req }
            catch {
                [ResiliencyTriage.RtLog]::Write('ERROR', ("<- {0} {1} failed after {2:n1}s: {3}" -f $Method, $short, $sw.Elapsed.TotalSeconds, $_.Exception.Message))
                if ("$_" -match '407') { throw "Proxy authentication failed (HTTP 407). Your Windows user was rejected by the proxy - run again with -ProxyCredential (Get-Credential) or -Proxy <url>. Details: $_" }
                # Timeouts and dropped connections (busy proxies) are worth another try; PATCH is idempotent here.
                if ($attempt -le 3) {
                    [ResiliencyTriage.RtLog]::Write('WARN', "Network error - retry $attempt in $(2 * $attempt)s")
                    Start-Sleep -Seconds (2 * $attempt)
                    continue
                }
                throw
            }
            $code = [int]$resp.StatusCode
            [ResiliencyTriage.RtLog]::Write('HTTP', ("<- {0} {1} {2} in {3:n1}s" -f $code, $Method, $short, $sw.Elapsed.TotalSeconds))
            if (($code -eq 429 -or $code -ge 500) -and $attempt -le 4) {
                $wait = 2 * $attempt
                $retryAfter = $resp.Headers['Retry-After']
                if ($retryAfter) { $null = [int]::TryParse([string]@($retryAfter)[0], [ref]$wait) }
                [ResiliencyTriage.RtLog]::Write('WARN', "HTTP $code - retry $attempt in ${wait}s")
                Start-Sleep -Seconds ([Math]::Min([Math]::Max($wait, 1), 30))
                continue
            }
            break
        }
        if ($code -ge 400) {
            $msg = [string]$resp.Content
            try {
                $err = $resp.Content | ConvertFrom-Json -ErrorAction Stop
                $errMsg = Get-RtProp $err 'error.message'
                $errCode = Get-RtProp $err 'error.code'
                if ($errMsg) { $msg = "$errCode - $errMsg" }
            } catch { }
            throw "HTTP $code $Method : $msg"
        }
        $content = [string]$resp.Content
        if ([string]::IsNullOrWhiteSpace($content)) { break }
        $parsed = $content | ConvertFrom-Json -Depth 50
        if (-not $AllPages) { return $parsed }

        if ($parsed.PSObject.Properties.Name -contains 'value') { foreach ($i in @($parsed.value)) { $items.Add($i) } }
        else { $items.Add($parsed) }
        $uri = [string](Get-RtProp $parsed 'nextLink')
    }
    return , $items.ToArray()
}

function Get-RtSubscription {
    <# Readable subscriptions visible to the token's tenant. #>
    param([Parameter(Mandatory)][string]$Token)
    $subs = Invoke-RtArm -Token $Token -Path '/subscriptions' -ApiVersion $script:SubscriptionApi -AllPages
    Write-RtLog "Subscriptions visible: $(@($subs).Count)"
    # Warned / PastDue subscriptions are still readable; only Disabled / Deleted are skipped.
    @($subs | Where-Object { (Get-RtProp $_ 'state') -notin 'Disabled', 'Deleted' } | ForEach-Object {
        [pscustomobject]@{ SubscriptionId = [string]$_.subscriptionId; Name = [string]$_.displayName; TenantId = [string](Get-RtProp $_ 'tenantId') }
    })
}

function Invoke-RtGraphQuery {
    <# Azure Resource Graph query over REST (no Az.ResourceGraph dependency); pages through all rows. #>
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)][string[]]$SubscriptionId)
    $rows = [System.Collections.Generic.List[object]]::new()
    # ARG accepts at most 1000 subscriptions per request.
    for ($i = 0; $i -lt $SubscriptionId.Count; $i += 1000) {
        $chunk = @($SubscriptionId[$i..([Math]::Min($i + 999, $SubscriptionId.Count - 1))])
        $skip = $null
        do {
            $options = @{ resultFormat = 'objectArray'; '$top' = 1000 }
            if ($skip) { $options['$skipToken'] = $skip }
            $res = Invoke-RtArm -Token $Token -Method POST -Path '/providers/Microsoft.ResourceGraph/resources' `
                -ApiVersion $script:GraphApiVersion -Body @{ subscriptions = $chunk; query = $Query; options = $options }
            foreach ($r in @(Get-RtProp $res 'data' @())) { $rows.Add($r) }
            Write-RtLog "Resource Graph: $($rows.Count) row(s) so far (subscriptions $($i + 1)-$($i + $chunk.Count) of $($SubscriptionId.Count))"
            $skip = [string](Get-RtProp $res '$skipToken')
        } while ($skip)
    }
    return $rows.ToArray()
}

#endregion

#region Reviews

function ConvertTo-RtIsoDate {
    <# Normalizes a date (DateTime from ConvertFrom-Json or string) to sortable ISO 8601 text. #>
    param([object]$Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) {
        return $d.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return [string]$Value
}

function New-RtReviewObject {
    <# Review object from an ARM or Resource Graph resiliencyReviews item. #>
    param([object]$Item, [string]$SubscriptionId, [string]$SubscriptionName, [string]$Source)
    $p = Get-RtProp $Item 'properties' $null
    [pscustomobject]@{
        ReviewId             = [string](Get-RtProp $Item 'name')
        ReviewName           = [string](Get-RtProp $p 'reviewName')
        WorkloadName         = [string](Get-RtProp $p 'workloadName')
        ReviewStatus         = [string](Get-RtProp $p 'reviewStatus')
        RecommendationsCount = [int](Get-RtProp $p 'recommendationsCount' 0)
        PublishedAt          = ConvertTo-RtIsoDate (Get-RtProp $p 'publishedAt')
        UpdatedAt            = ConvertTo-RtIsoDate (Get-RtProp $p 'updatedAt')
        SubscriptionId       = $SubscriptionId
        SubscriptionName     = $SubscriptionName
        ResourceId           = [string](Get-RtProp $Item 'id')
        Source               = $Source
        ItemCount            = $null
    }
}

function Get-RtReview {
    <#
    .SYNOPSIS
        Finds every resiliency review the signed-in user can see.
    .DESCRIPTION
        Three sources are combined so no review is missed:
          1. ARM list per subscription (live, parallel; failures are retried and reported)
          2. Resource Graph 'microsoft.advisor/resiliencyreviews' (one query for all subscriptions)
          3. Review references on Advisor recommendations (reviews whose review resource sits in a
             subscription you cannot read, but whose recommendations you can)
    .OUTPUTS
        Reviews plus the subscriptions that could not be read.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][object[]]$Subscription,
        [int]$ThrottleLimit = 12,
        [switch]$SkipGraph
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $subName = @{}
    foreach ($s in $Subscription) { $subName[([string]$s.SubscriptionId).ToLowerInvariant()] = [string]$s.Name }
    $fns = @{}
    foreach ($n in 'Invoke-RtArm', 'Get-RtProp', 'ConvertTo-RtIsoDate', 'New-RtReviewObject') { $fns[$n] = (Get-Item "function:$n").ScriptBlock.ToString() }
    $apiVersions = $script:ReviewApiVersions
    $total = @($Subscription).Count
    $progress = [hashtable]::Synchronized(@{ Done = 0 })
    Write-RtLog "Step 1/3: listing resiliency reviews in $total subscription(s) (parallel $ThrottleLimit)"

    $results = $Subscription | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        Set-StrictMode -Version Latest
        foreach ($e in ($using:fns).GetEnumerator()) { Set-Item "function:$($e.Key)" ([scriptblock]::Create($e.Value)) }
        $sub = $_
        $items = $null; $lastError = ''
        foreach ($api in $using:apiVersions) {
            try {
                $items = Invoke-RtArm -Token $using:Token -Path "/subscriptions/$($sub.SubscriptionId)/providers/Microsoft.Advisor/resiliencyReviews" -ApiVersion $api -AllPages
                break
            }
            catch {
                $lastError = $_.Exception.Message
                # Only an unsupported api-version is worth another attempt.
                if ($lastError -notmatch 'InvalidApiVersion|NoRegisteredProviderFound|api-version') { break }
            }
        }
        $prog = $using:progress
        [System.Threading.Monitor]::Enter($prog.SyncRoot)
        try { $prog.Done++; $n = $prog.Done } finally { [System.Threading.Monitor]::Exit($prog.SyncRoot) }
        if ($n % 10 -eq 0 -or $n -eq $using:total) { [ResiliencyTriage.RtLog]::Write('INFO', "Scanned $n of $($using:total) subscription(s)") }
        if ($null -eq $items) {
            [ResiliencyTriage.RtLog]::Write('WARN', "Reviews of $($sub.Name) ($($sub.SubscriptionId)) not readable: $lastError")
            [pscustomobject]@{ Kind = 'Error'; SubscriptionId = $sub.SubscriptionId; Name = $sub.Name; Message = $lastError }
            return
        }
        if (@($items).Count) { [ResiliencyTriage.RtLog]::Write('INFO', "$(@($items).Count) review(s) in $($sub.Name)") }
        foreach ($item in @($items)) {
            $r = New-RtReviewObject -Item $item -SubscriptionId $sub.SubscriptionId -SubscriptionName $sub.Name -Source 'ARM'
            $r | Add-Member -NotePropertyName Kind -NotePropertyValue 'Review' -PassThru
        }
    }

    $byId = [ordered]@{}
    $errors = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($results)) {
        if ($r.Kind -eq 'Error') { $errors.Add($r); continue }
        $r.PSObject.Properties.Remove('Kind')
        $byId[$r.ReviewId.ToLowerInvariant()] = $r
    }
    $errors = $errors.ToArray()
    Write-RtLog ("ARM: {0} review(s), {1} subscription(s) not readable ({2:n1}s)" -f $byId.Count, $errors.Count, $sw.Elapsed.TotalSeconds)

    if (-not $SkipGraph) {
        $ids = @($Subscription.SubscriptionId)
        try {
            Write-RtLog 'Step 2/3: Resource Graph - resiliency reviews'
            $rows = @(Invoke-RtGraphQuery -Token $Token -SubscriptionId $ids -Query "advisorresources | where type =~ 'microsoft.advisor/resiliencyreviews' | project id, name, subscriptionId, properties")
            $added = 0
            foreach ($row in $rows) {
                $key = ([string]$row.name).ToLowerInvariant()
                if ($byId.Contains($key)) { continue }
                $sid = [string]$row.subscriptionId
                $byId[$key] = New-RtReviewObject -Item $row -SubscriptionId $sid -SubscriptionName ($subName[$sid.ToLowerInvariant()] ?? $sid) -Source 'ResourceGraph'
                $added++
                Write-RtLog "Resource Graph added review '$($byId[$key].ReviewName)' (missing in the ARM list)" -Level WARN
            }
            Write-RtLog "Resource Graph: $($rows.Count) review(s), $added not returned by ARM"

            Write-RtLog 'Step 3/3: Resource Graph - reviews referenced by recommendations'
            $query = @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where isnotempty(properties.review)
| extend rid = tostring(properties.review.id), rname = tostring(properties.review.name)
| summarize recs = dcount(tostring(properties.label)), subs = make_set(subscriptionId, 20), workload = take_any(tostring(properties.resourceWorkload.name)) by rid, rname
"@
            $refs = @(Invoke-RtGraphQuery -Token $Token -SubscriptionId $ids -Query $query)
            $added = 0
            foreach ($ref in $refs) {
                $rid = ([string]$ref.rid).TrimEnd('/').Split('/')[-1].ToLowerInvariant()
                if (-not $rid -or $byId.Contains($rid)) { continue }
                if (@($byId.Values | Where-Object { $_.ReviewName -and $_.ReviewName -eq [string]$ref.rname }).Count) { continue }
                $sid = [string]@($ref.subs)[0]
                $byId[$rid] = [pscustomobject]@{
                    ReviewId             = $rid
                    ReviewName           = [string]$ref.rname
                    WorkloadName         = [string]$ref.workload
                    ReviewStatus         = 'Unknown'
                    RecommendationsCount = [int]$ref.recs
                    PublishedAt          = ''
                    UpdatedAt            = ''
                    SubscriptionId       = $sid
                    SubscriptionName     = ($subName[$sid.ToLowerInvariant()] ?? $sid)
                    ResourceId           = ''
                    Source               = 'Recommendations'
                    ItemCount            = $null
                }
                $added++
                Write-RtLog "Review '$($ref.rname)' found only via its recommendations (review resource not readable)" -Level WARN
            }
            Write-RtLog "Recommendations reference $($refs.Count) review(s), $added not found before"
            # Affected resources per review, counted like the summary (legacy copies once).
            $itemQuery = @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where isnotempty(properties.review)
| extend rid = tostring(properties.review.id), rname = tostring(properties.review.name)
| extend label = tostring(properties.label), typeId = tostring(properties.recommendationTypeId), resId = tostring(properties.resourceMetadata.resourceId)
| extend resKey = tolower(iff(isnotempty(resId), resId, extract('(?i)^(.+)/providers/microsoft\\.advisor/recommendations/', 1, id)))
| extend resKey = iff(isempty(resKey), tolower(id), resKey), groupKey = iff(isempty(label), name, label)
| summarize by rid, rname, typeId, groupKey, resKey
| summarize items = count() by rid, rname
"@
            $refs = @(Invoke-RtGraphQuery -Token $Token -SubscriptionId $ids -Query $itemQuery)
            foreach ($rv in $byId.Values) {
                $n = 0
                foreach ($ref in $refs) {
                    $rid = ([string]$ref.rid).TrimEnd('/').Split('/')[-1]
                    if ($rid -eq $rv.ReviewId -or ($rv.ReviewName -and [string]$ref.rname -eq $rv.ReviewName)) { $n += [int]$ref.items }
                }
                $rv.ItemCount = $n
            }
        }
        catch { Write-RtLog "Resource Graph review discovery failed: $($_.Exception.Message)" -Level WARN }
    }

    $reviews = @($byId.Values | Sort-Object -Property @{ Expression = { $_.PublishedAt }; Descending = $true }, ReviewName)
    Write-RtLog ("Found {0} review(s) in {1:n1}s" -f $reviews.Count, $sw.Elapsed.TotalSeconds)
    [pscustomobject]@{ Reviews = $reviews; FailedSubscriptions = $errors }
}
#endregion

#region Recommendations

function ConvertTo-RtKqlString {
    <# Quoted KQL string literal. #>
    param([string]$Value)
    "'" + ([string]$Value).Replace('\', '\\').Replace("'", "\'") + "'"
}

function Get-RtReviewFilterKql {
    <# KQL lines that add rid / rname and keep only rows of the given reviews (by review ID or name). #>
    param([object[]]$Review = @())
    $out = "| extend rid = tostring(properties.review.id), rname = tostring(properties.review.name)`n"
    if (-not $Review) { return $out }
    $ids = @($Review | Where-Object ReviewId | ForEach-Object { ConvertTo-RtKqlString $_.ReviewId.ToLowerInvariant() }) -join ', '
    $names = @($Review | Where-Object ReviewName | ForEach-Object { ConvertTo-RtKqlString $_.ReviewName }) -join ', '
    $conds = @()
    if ($ids) { $conds += "rid in~ ($ids)"; $conds += "tostring(split(rid, '/')[-1]) in~ ($ids)" }
    if ($names) { $conds += "rname in~ ($names)" }
    if ($conds) { $out += "| where $($conds -join ' or ')`n" }
    return $out
}

function Get-RtGraphReviewRecommendation {
    <#
    .SYNOPSIS
        Review-linked Advisor recommendations from Resource Graph.
    .DESCRIPTION
        The ARM list API omits title (label), description, benefits and notes of review
        recommendations; Resource Graph has them. Used to enrich the live ARM data.
    #>
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string[]]$SubscriptionId, [object[]]$Review = @(), [string]$ItemFilter)
    $extra = if ($ItemFilter) { "| where $ItemFilter`n" } else { '' }
    $query = @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where isnotempty(properties.review)
$(Get-RtReviewFilterKql -Review $Review)$extra| project id, name, subscriptionId, properties
"@
    @(Invoke-RtGraphQuery -Token $Token -Query $query -SubscriptionId $SubscriptionId)
}

function Merge-RtRecommendationSource {
    <#
    .SYNOPSIS
        Merges live ARM recommendations with Resource Graph rows (matched by recommendation name).
    .DESCRIPTION
        ARM wins for the status (Resource Graph lags a few minutes). Missing text fields are
        copied from Resource Graph. Rows only present in Resource Graph are added as they are.
    #>
    param([AllowEmptyCollection()][object[]]$Arm = @(), [AllowEmptyCollection()][object[]]$Graph = @())
    $textFields = 'label', 'description', 'potentialBenefits', 'notes', 'learnMoreLink'
    $byName = @{}
    foreach ($g in $Graph) { $n = [string](Get-RtProp $g 'name'); if ($n) { $byName[$n.ToLowerInvariant()] = $g } }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $Arm) {
        $n = [string](Get-RtProp $a 'name')
        $null = $seen.Add($n)
        $g = if ($n) { $byName[$n.ToLowerInvariant()] } else { $null }
        $p = Get-RtProp $a 'properties' $null
        if ($g -and $p) {
            foreach ($f in $textFields) {
                $v = [string](Get-RtProp $g "properties.$f")
                if ($v -and -not [string](Get-RtProp $p $f)) { $p | Add-Member -NotePropertyName $f -NotePropertyValue $v -Force }
            }
        }
        $a
    }
    foreach ($g in $Graph) { if (-not $seen.Contains([string](Get-RtProp $g 'name'))) { $g } }
}

function Get-RtResourceTypeFromId {
    <# 'Microsoft.Storage/storageAccounts' from a resource ID (nested types included). #>
    param([string]$ResourceId)
    if ($ResourceId -notmatch '(?i)/providers/([^/]+)/(.+)$') {
        if ($ResourceId -match '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+$') { return 'Microsoft.Resources/resourceGroups' }
        if ($ResourceId -match '(?i)^/subscriptions/[^/]+$') { return 'Microsoft.Resources/subscriptions' }
        return ''
    }
    $ns = $Matches[1]; $parts = $Matches[2].Split('/')
    $types = for ($i = 0; $i -lt $parts.Count; $i += 2) { $parts[$i] }
    return "$ns/$($types -join '/')"
}

function Get-RtRawReviewRecommendation {
    <# Reads every Advisor recommendation with a review back-reference from the given subscriptions (parallel). #>
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string[]]$SubscriptionId, [int]$ThrottleLimit = 12)
    $armFn = ${function:Invoke-RtArm}.ToString()
    $propFn = ${function:Get-RtProp}.ToString()
    $api = $script:AdvisorApiVersion

    $SubscriptionId | Sort-Object -Unique | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        Set-StrictMode -Version Latest
        ${function:Invoke-RtArm} = [scriptblock]::Create($using:armFn)
        ${function:Get-RtProp} = [scriptblock]::Create($using:propFn)
        $sub = $_
        try {
            $items = Invoke-RtArm -Token $using:Token -Path "/subscriptions/$sub/providers/Microsoft.Advisor/recommendations" -ApiVersion $using:api -AllPages
        }
        catch { [ResiliencyTriage.RtLog]::Write('WARN', "Advisor recommendations of $sub not readable: $($_.Exception.Message)"); return }
        $linked = @($items | Where-Object { Get-RtProp $_ 'properties.review' $null })
        [ResiliencyTriage.RtLog]::Write('INFO', "Subscription $($sub): $(@($items).Count) Advisor recommendation(s), $($linked.Count) linked to reviews")
        $linked
    }
}

function ConvertTo-RtRecommendation {
    <#
    .SYNOPSIS
        Groups per-resource Advisor recommendations into review recommendations.
    .DESCRIPTION
        One review recommendation = same review + same recommendation type (+ label).
        Each group keeps its impacted resources with their individual Advisor status.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawRecommendation,
        [Parameter(Mandatory)][object[]]$Review
    )
    # Reviews can be referenced by ID (last segment of review.id) or by name.
    $lookup = @{}
    foreach ($r in $Review) {
        if ($r.ReviewId) { $lookup["id:$($r.ReviewId.ToLowerInvariant())"] = $r; $lookup["name:$($r.ReviewId.ToLowerInvariant())"] = $r }
        if ($r.ReviewName) { $lookup["name:$($r.ReviewName.ToLowerInvariant())"] = $r }
    }

    $groups = [ordered]@{}
    $resIndex = @{}   # group|resource -> entry (fast duplicate lookup for large reviews)
    foreach ($raw in $RawRecommendation) {
        $p = Get-RtProp $raw 'properties' $null
        $revId = ([string](Get-RtProp $p 'review.id')).TrimEnd('/').Split('/')[-1].ToLowerInvariant()
        $revName = ([string](Get-RtProp $p 'review.name')).ToLowerInvariant()
        $review = $null
        if ($revId -and $lookup.ContainsKey("id:$revId")) { $review = $lookup["id:$revId"] }
        elseif ($revName -and $lookup.ContainsKey("name:$revName")) { $review = $lookup["name:$revName"] }
        if (-not $review) { continue }

        $title = [string](Get-RtProp $p 'label')
        $typeId = [string](Get-RtProp $p 'recommendationTypeId')
        $key = '{0}|{1}|{2}' -f $review.ReviewId, $typeId, $title
        if (-not $title) {
            # No label: the short description is generic for review items, so never group on it.
            $title = [string](Get-RtProp $p 'shortDescription.problem')
            if (-not $title) { $title = '(untitled recommendation)' }
            $key += '|' + [string](Get-RtProp $raw 'name')
        }

        if (-not $groups.Contains($key)) {
            $priority = [string](Get-RtProp $p 'trackedProperties.priority')
            if (-not $priority) { $priority = [string](Get-RtProp $p 'priority') }
            if (-not $priority) { $priority = [string](Get-RtProp $p 'impact' 'Medium') }
            $description = [string](Get-RtProp $p 'description')
            if (-not $description) { $description = [string](Get-RtProp $p 'shortDescription.solution') }
            $groups[$key] = [pscustomobject]@{
                Key                  = $key
                ReviewId             = $review.ReviewId
                ReviewName           = $review.ReviewName
                WorkloadName         = $review.WorkloadName
                Title                = $title
                Description          = $description
                PotentialBenefits    = [string](Get-RtProp $p 'potentialBenefits')
                Notes                = [string](Get-RtProp $p 'notes')
                LearnMoreLink        = [string](Get-RtProp $p 'learnMoreLink')
                Category             = [string](Get-RtProp $p 'category')
                RecommendationTypeId = $typeId
                Priority             = $priority
                PriorityRank         = Get-RtPriorityRank $priority
                Label                = [string](Get-RtProp $p 'label')
                ItemName             = if (Get-RtProp $p 'label') { '' } else { [string](Get-RtProp $raw 'name') }
                Resources            = [System.Collections.Generic.List[object]]::new()
                ResourcesLoaded      = $true
                ResourceCount        = 0
                Status               = 'Active'
                IsMixed              = $false
                StatusCounts         = $null
            }
        }

        $armId = [string](Get-RtProp $raw 'id')
        $resourceId = [string](Get-RtProp $p 'resourceMetadata.resourceId')
        if (-not $resourceId -and $armId -match '(?i)^(.+)/providers/Microsoft\.Advisor/recommendations/') { $resourceId = $Matches[1] }
        $subId = if ($armId -match '(?i)^/subscriptions/([^/]+)') { $Matches[1] } else { $review.SubscriptionId }
        # Current model has recommendationStatus; legacy triage copies only trackedProperties.state.
        $isCurrent = [bool](Get-RtProp $p 'recommendationStatus')
        $rawStatus = [string](Get-RtProp $p 'recommendationStatus')
        if (-not $rawStatus) { $rawStatus = [string](Get-RtProp $p 'customerState') }
        if (-not $rawStatus) { $rawStatus = [string](Get-RtProp $p 'trackedProperties.state' 'New') }
        # impactedField/impactedValue are unreliable for review items, the resource ID is not.
        $resType = Get-RtResourceTypeFromId $resourceId
        if (-not $resType) { $resType = [string](Get-RtProp $p 'impactedField') }
        $resName = if ($resourceId) { $resourceId.TrimEnd('/').Split('/')[-1] } else { [string](Get-RtProp $p 'impactedValue') }

        # Advisor can hold a legacy and a current object for the same resource; the portal counts it once.
        $resKey = if ($resourceId) { $resourceId.TrimEnd('/').ToLowerInvariant() } else { $armId.ToLowerInvariant() }
        $updated = [datetime]::MinValue
        $null = [datetime]::TryParse([string](Get-RtProp $p 'lastUpdated'), [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$updated)
        $existing = $resIndex["$key|$resKey"]
        if ($existing) {
            $better = ($isCurrent -and -not $existing.IsCurrent) -or ($isCurrent -eq $existing.IsCurrent -and $updated -gt $existing.LastUpdated)
            if (-not $better) { continue }
            $null = $groups[$key].Resources.Remove($existing)
        }
        $entry = [pscustomobject]@{
            ResourceKey         = $resKey
            IsCurrent           = $isCurrent
            LastUpdated         = $updated
            RecommendationArmId = $armId
            RecommendationName  = [string](Get-RtProp $raw 'name')
            RecommendationTypeId = $typeId
            ReviewName          = $review.ReviewName
            SubscriptionId      = $subId
            ResourceId          = $resourceId
            ResourceName        = $resName
            ResourceType        = $resType
            ResourceGroup       = Get-RtResourceGroupFromId $resourceId
            Status              = ConvertTo-RtStatusBucket $rawStatus
            RawStatus           = $rawStatus
            PostponedUntil      = [string](Get-RtProp $p 'postponedUntilDateTime')
            DismissReason       = [string](Get-RtProp $p 'recommendationDismissReason')
        }
        $groups[$key].Resources.Add($entry)
        $resIndex["$key|$resKey"] = $entry
    }

    $list = @($groups.Values)
    foreach ($rec in $list) { Update-RtRecommendationStatus -Recommendation $rec }
    return @($list | Sort-Object PriorityRank, Title)
}

function Update-RtRecommendationStatus {
    <# Recomputes the aggregated status of a review recommendation from its resources. #>
    param([Parameter(Mandatory)][object]$Recommendation)
    $counts = [ordered]@{ Active = 0; Postponed = 0; Completed = 0; Dismissed = 0 }
    $loaded = -not $Recommendation.PSObject.Properties['ResourcesLoaded'] -or $Recommendation.ResourcesLoaded
    if ($loaded) { foreach ($r in $Recommendation.Resources) { $counts[$r.Status]++ } }
    elseif ($Recommendation.StatusCounts) { foreach ($k in @($counts.Keys)) { $counts[$k] = [int]$Recommendation.StatusCounts.$k } }
    if ($Recommendation.PSObject.Properties['ResourceCount']) { $Recommendation.ResourceCount = [int](($counts.Values | Measure-Object -Sum).Sum) }
    $present = @($counts.Keys | Where-Object { $counts[$_] -gt 0 })
    $Recommendation.StatusCounts = [pscustomobject]$counts
    $Recommendation.IsMixed = $present.Count -gt 1
    # Mixed recommendations fall into the most "open" bucket so nothing unfinished hides.
    $Recommendation.Status = if (-not $present) { 'Active' } else { @(@('Active', 'Postponed', 'Dismissed', 'Completed') | Where-Object { $_ -in $present })[0] }
}

function Get-RtReviewRecommendation {
    <#
    .SYNOPSIS
        Loads and groups the recommendations of the selected reviews.
    .PARAMETER ScanSubscription
        Subscriptions in scope. Resource Graph narrows them down to those that actually hold
        review-linked recommendations; the review subscriptions are always included.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][object[]]$Review,
        [Parameter(Mandatory)][string[]]$ScanSubscription,
        [int]$MaxLiveItem = 5000
    )
    $targets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Review) { $null = $targets.Add($r.SubscriptionId) }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RtLog "Loading recommendations of $(@($Review).Count) review(s): $((@($Review.ReviewName) -join ', '))"
    $graph = @()
    try {
        Write-RtLog "Step 1/3: Resource Graph query over $(@($ScanSubscription).Count) subscription(s)"
        $graph = @(Get-RtGraphReviewRecommendation -Token $Token -SubscriptionId $ScanSubscription -Review $Review)
        foreach ($g in $graph) { $null = $targets.Add([string]$g.subscriptionId) }
        Write-RtLog ("Resource Graph: {0} recommendation(s) in {1} subscription(s) ({2:n1}s)" -f $graph.Count, $targets.Count, $sw.Elapsed.TotalSeconds)
    }
    catch {
        # Resource Graph unavailable -> scan every subscription in scope (titles may be generic).
        Write-RtLog "Resource Graph failed, falling back to scanning all $(@($ScanSubscription).Count) subscription(s): $($_.Exception.Message)" -Level WARN
        foreach ($s in $ScanSubscription) { $null = $targets.Add($s) }
    }
    if ($graph.Count -and $targets.Count) {
        # The Advisor list API returns ALL recommendations of a subscription (100 per page) - with
        # tens of thousands that takes many minutes. Those subscriptions use the Resource Graph status.
        try {
            $sizes = @(Invoke-RtGraphQuery -Token $Token -SubscriptionId @($targets) -Query "advisorresources | where type =~ 'microsoft.advisor/recommendations' | summarize n = count() by subscriptionId")
            foreach ($z in $sizes) {
                if ([int]$z.n -gt $MaxLiveItem) {
                    $null = $targets.Remove([string]$z.subscriptionId)
                    Write-RtLog ("Subscription {0}: {1:n0} Advisor items - using Resource Graph status (may lag a few minutes)" -f $z.subscriptionId, [int]$z.n)
                }
            }
        }
        catch { Write-RtLog "Resource Graph size check failed: $($_.Exception.Message)" -Level WARN }
    }
    Write-RtLog "Step 2/3: reading live status from Advisor in $($targets.Count) subscription(s)"
    $arm = if ($targets.Count) { @(Get-RtRawReviewRecommendation -Token $Token -SubscriptionId @($targets)) } else { @() }
    Write-RtLog ("Advisor: {0} review-linked recommendation(s) ({1:n1}s)" -f $arm.Count, $sw.Elapsed.TotalSeconds)
    $raw = @(Merge-RtRecommendationSource -Arm $arm -Graph $graph)
    Write-RtLog "Step 3/3: grouping $($raw.Count) item(s)"
    $result = ConvertTo-RtRecommendation -RawRecommendation $raw -Review $Review
    Write-RtLog ("Loaded {0} recommendation(s) in {1:n1}s" -f @($result).Count, $sw.Elapsed.TotalSeconds)
    return $result
}

function ConvertFrom-RtSummaryRow {
    <#
    .SYNOPSIS
        Builds review recommendations (counts only, no resources) from the Resource Graph summary.
    .PARAMETER CountRow
        rid, rname, typeId, label, groupKey, st, n  (one row per recommendation and raw status)
    .PARAMETER TextRow
        rid, rname, typeId, label, groupKey + text columns (one row per recommendation)
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CountRow,
        [AllowEmptyCollection()][object[]]$TextRow = @(),
        [Parameter(Mandatory)][object[]]$Review
    )
    $lookup = @{}
    foreach ($r in $Review) {
        if ($r.ReviewId) { $lookup["id:$($r.ReviewId.ToLowerInvariant())"] = $r; $lookup["name:$($r.ReviewId.ToLowerInvariant())"] = $r }
        if ($r.ReviewName) { $lookup["name:$($r.ReviewName.ToLowerInvariant())"] = $r }
    }
    $rowKey = { param($x) ('{0}|{1}|{2}|{3}|{4}' -f $x.rid, $x.rname, $x.typeId, $x.label, $x.groupKey).ToLowerInvariant() }
    $texts = @{}
    foreach ($t in $TextRow) { $texts[(& $rowKey $t)] = $t }

    $groups = [ordered]@{}
    foreach ($c in $CountRow) {
        $revId = ([string]$c.rid).TrimEnd('/').Split('/')[-1].ToLowerInvariant()
        $revName = ([string]$c.rname).ToLowerInvariant()
        $review = if ($revId -and $lookup.ContainsKey("id:$revId")) { $lookup["id:$revId"] } elseif ($revName -and $lookup.ContainsKey("name:$revName")) { $lookup["name:$revName"] } else { $null }
        if (-not $review) { continue }
        $label = [string]$c.label
        $typeId = [string]$c.typeId
        # Same key as ConvertTo-RtRecommendation, so loaded resources can be matched later.
        $key = '{0}|{1}|{2}' -f $review.ReviewId, $typeId, $label
        if (-not $label) { $key += '|' + [string]$c.groupKey }
        if (-not $groups.Contains($key)) {
            $t = $texts[(& $rowKey $c)]
            $get = { param($n) if ($t -and $t.PSObject.Properties[$n]) { [string]$t.$n } else { '' } }
            $title = if ($label) { $label } else { & $get 'problem' }
            if (-not $title) { $title = '(untitled recommendation)' }
            $priority = & $get 'priority'
            if (-not $priority) { $priority = 'Medium' }
            $description = & $get 'description'
            if (-not $description) { $description = & $get 'solution' }
            $groups[$key] = [pscustomobject]@{
                Key                  = $key
                ReviewId             = $review.ReviewId
                ReviewName           = $review.ReviewName
                WorkloadName         = $review.WorkloadName
                Title                = $title
                Description          = $description
                PotentialBenefits    = & $get 'benefits'
                Notes                = & $get 'notes'
                LearnMoreLink        = & $get 'link'
                Category             = & $get 'category'
                RecommendationTypeId = $typeId
                Priority             = $priority
                PriorityRank         = Get-RtPriorityRank $priority
                Label                = $label
                ItemName             = if ($label) { '' } else { [string]$c.groupKey }
                Resources            = [System.Collections.Generic.List[object]]::new()
                ResourcesLoaded      = $false
                ResourceCount        = 0
                Status               = 'Active'
                IsMixed              = $false
                StatusCounts         = [pscustomobject][ordered]@{ Active = 0; Postponed = 0; Completed = 0; Dismissed = 0 }
            }
        }
        $bucket = ConvertTo-RtStatusBucket ([string]$c.st)
        $groups[$key].StatusCounts.$bucket += [int]$c.n
    }
    $list = @($groups.Values)
    foreach ($rec in $list) { Update-RtRecommendationStatus -Recommendation $rec }
    return @($list | Sort-Object PriorityRank, Title)
}

function Get-RtRecommendationSummary {
    <#
    .SYNOPSIS
        Recommendations of the selected reviews with resource counts per status - no resources.
    .DESCRIPTION
        Two Resource Graph queries that aggregate on the server, so even reviews with hundreds of
        thousands of affected resources load in seconds. Like the portal, a resource is counted once
        (current object preferred over a legacy copy, then the most recently updated).
        Resources are loaded on demand with Get-RtRecommendationResource.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][object[]]$Review,
        [Parameter(Mandatory)][string[]]$ScanSubscription
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RtLog "Loading recommendation summary of $(@($Review).Count) review(s): $((@($Review.ReviewName) -join ', '))"
    $base = @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where isnotempty(properties.review)
$(Get-RtReviewFilterKql -Review $Review)| extend label = tostring(properties.label), typeId = tostring(properties.recommendationTypeId)
| extend groupKey = iff(isempty(label), name, label)
"@
    $countQuery = $base + @"

| extend resId = tostring(properties.resourceMetadata.resourceId)
| extend resKey = tolower(iff(isnotempty(resId), resId, extract('(?i)^(.+)/providers/microsoft\\.advisor/recommendations/', 1, id)))
| extend resKey = iff(isempty(resKey), tolower(id), resKey)
| extend st = coalesce(tostring(properties.recommendationStatus), tostring(properties.customerState), tostring(properties.trackedProperties.state), 'New')
| extend rank = iff(isnotempty(tostring(properties.recommendationStatus)), 10000000000, 0) + coalesce(datetime_diff('second', todatetime(properties.lastUpdated), datetime(2000-01-01)), 0)
| summarize arg_max(rank, st) by rid, rname, typeId, label, groupKey, resKey
| summarize n = count() by rid, rname, typeId, label, groupKey, st
"@
    $textQuery = $base + @"

| extend description = tostring(properties.description), solution = tostring(properties.shortDescription.solution), problem = tostring(properties.shortDescription.problem), benefits = tostring(properties.potentialBenefits), notes = tostring(properties.notes), link = tostring(properties.learnMoreLink), category = tostring(properties.category), priority = coalesce(tostring(properties.trackedProperties.priority), tostring(properties.priority), tostring(properties.impact))
| summarize description = max(description), solution = max(solution), problem = max(problem), benefits = max(benefits), notes = max(notes), link = max(link), category = max(category), priority = max(priority) by rid, rname, typeId, label, groupKey
"@
    Write-RtLog 'Step 1/2: Resource Graph - resource counts per recommendation and status'
    $counts = @(Invoke-RtGraphQuery -Token $Token -SubscriptionId $ScanSubscription -Query $countQuery)
    Write-RtLog 'Step 2/2: Resource Graph - recommendation texts'
    $texts = @(Invoke-RtGraphQuery -Token $Token -SubscriptionId $ScanSubscription -Query $textQuery)
    $result = @(ConvertFrom-RtSummaryRow -CountRow $counts -TextRow $texts -Review $Review)
    $total = ($result | ForEach-Object ResourceCount | Measure-Object -Sum).Sum
    Write-RtLog ("Loaded {0} recommendation(s) with {1:n0} resource(s) in {2:n1}s" -f $result.Count, [int]$total, $sw.Elapsed.TotalSeconds)
    return $result
}

function Get-RtRecommendationResource {
    <#
    .SYNOPSIS
        Loads the affected resources of the given recommendations (Resource Graph).
    .OUTPUTS
        Recommendations with ResourcesLoaded = $true (same Key as the summary objects).
        Other recommendations of the same reviews that happen to match are returned too.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][object[]]$Recommendation,
        [Parameter(Mandatory)][object[]]$Review,
        [Parameter(Mandatory)][string[]]$ScanSubscription
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ids = @($Recommendation.ReviewId | Sort-Object -Unique)
    $reviews = @($Review | Where-Object { $_.ReviewId -in $ids })
    $expected = ($Recommendation | ForEach-Object { [int]$_.ResourceCount } | Measure-Object -Sum).Sum
    Write-RtLog ("Loading {0:n0} resource(s) of {1} recommendation(s)" -f [int]$expected, @($Recommendation).Count)
    $filter = ''
    # Many recommendations -> load the whole reviews instead of a huge filter.
    if (@($Recommendation).Count -le 200) {
        $conds = @()
        $labelled = @($Recommendation | Where-Object Label)
        if ($labelled) {
            $types = @($labelled.RecommendationTypeId | Sort-Object -Unique | ForEach-Object { ConvertTo-RtKqlString $_ }) -join ', '
            $labels = @($labelled.Label | Sort-Object -Unique | ForEach-Object { ConvertTo-RtKqlString $_ }) -join ', '
            $conds += "(tostring(properties.recommendationTypeId) in~ ($types) and tostring(properties.label) in~ ($labels))"
        }
        $names = @($Recommendation | Where-Object ItemName | ForEach-Object { ConvertTo-RtKqlString $_.ItemName }) -join ', '
        if ($names) { $conds += "name in~ ($names)" }
        if ($conds) { $filter = $conds -join ' or ' }
    }
    $rows = @(Get-RtGraphReviewRecommendation -Token $Token -SubscriptionId $ScanSubscription -Review $reviews -ItemFilter $filter)
    $result = @(ConvertTo-RtRecommendation -RawRecommendation $rows -Review $reviews)
    Write-RtLog ("Loaded {0:n0} resource row(s) in {1:n1}s" -f $rows.Count, $sw.Elapsed.TotalSeconds)
    return $result
}

function Set-RtRecommendationResource {
    <#
    .SYNOPSIS
        Copies loaded resources into the matching (summary) recommendations by Key.
    .PARAMETER Requested
        Recommendations that were asked for; they are marked loaded even if nothing came back.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Target,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Loaded,
        [object[]]$Requested = @()
    )
    $byKey = @{}
    foreach ($l in $Loaded) { $byKey[$l.Key] = $l }
    $req = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Requested | ForEach-Object Key))
    foreach ($t in $Target) {
        $l = $byKey[$t.Key]
        if (-not $l -and -not $req.Contains($t.Key)) { continue }
        $t.Resources = [System.Collections.Generic.List[object]]::new()
        if ($l) { foreach ($r in $l.Resources) { $t.Resources.Add($r) } }
        $t.ResourcesLoaded = $true
        Update-RtRecommendationStatus -Recommendation $t
    }
}

function Merge-RtDuplicateRecommendation {
    <#
    .SYNOPSIS
        Triage view: one row per recommendation title, even if several reviews contain it.
    .DESCRIPTION
        The row shows the copy from the most recent review (PublishedAt). Its Resources
        contain the resources of every copy, so a status change updates all reviews.
        The underlying per-review recommendations stay untouched for overview and export.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Recommendation, [Parameter(Mandatory)][object[]]$Review)
    $published = @{}
    foreach ($rv in $Review) {
        $d = [datetime]::MinValue
        foreach ($v in $rv.PublishedAt, $rv.UpdatedAt) { if ($v -and [datetime]::TryParse([string]$v, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { break } }
        $published[$rv.ReviewId] = $d
    }
    $groups = [ordered]@{}
    foreach ($rec in $Recommendation) {
        $k = if ($rec.Title -and $rec.Title -ne '(untitled recommendation)') { 'title:' + ($rec.Title -replace '\s+', ' ').Trim().ToLowerInvariant() } else { 'key:' + $rec.Key }
        if (-not $groups.Contains($k)) { $groups[$k] = [System.Collections.Generic.List[object]]::new() }
        $groups[$k].Add($rec)
    }
    $views = foreach ($k in $groups.Keys) {
        $members = @($groups[$k] | Sort-Object @{ Expression = { $published[$_.ReviewId] }; Descending = $true }, ReviewName)
        $p = $members[0]
        $view = [pscustomobject]@{
            Key                  = $k
            ReviewId             = $p.ReviewId
            ReviewName           = $p.ReviewName
            WorkloadName         = $p.WorkloadName
            OtherReviews         = @($members | Select-Object -Skip 1 | ForEach-Object ReviewName | Where-Object { $_ -ne $p.ReviewName } | Select-Object -Unique)
            Members              = $members
            Title                = $p.Title
            Description          = $p.Description
            PotentialBenefits    = $p.PotentialBenefits
            Notes                = $p.Notes
            LearnMoreLink        = $p.LearnMoreLink
            Category             = $p.Category
            RecommendationTypeId = $p.RecommendationTypeId
            Priority             = $p.Priority
            PriorityRank         = $p.PriorityRank
            Resources            = [System.Collections.Generic.List[object]]::new()
            ResourcesLoaded      = -not @($members | Where-Object { $_.PSObject.Properties['ResourcesLoaded'] -and -not $_.ResourcesLoaded }).Count
            ResourceCount        = 0
            Status               = 'Active'
            IsMixed              = $false
            StatusCounts         = $null
        }
        if ($view.ResourcesLoaded) { foreach ($m in $members) { foreach ($r in $m.Resources) { $view.Resources.Add($r) } } }
        else {
            # Summary only: add up the counts of all copies.
            $sum = [ordered]@{ Active = 0; Postponed = 0; Completed = 0; Dismissed = 0 }
            foreach ($m in $members) { foreach ($k in @($sum.Keys)) { $sum[$k] += [int]$m.StatusCounts.$k } }
            $view.StatusCounts = [pscustomobject]$sum
        }
        Update-RtRecommendationStatus -Recommendation $view
        $view
    }
    return @($views | Sort-Object PriorityRank, Title)
}

function Get-RtSummary {
    <# Status buckets per review and overall, on recommendation and on resource level. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Recommendation, [Parameter(Mandatory)][object[]]$Review)
    $build = {
        param($recs, $name, $expected)
        $rc = [ordered]@{ Active = 0; Postponed = 0; Completed = 0; Dismissed = 0 }
        $res = [ordered]@{ Active = 0; Postponed = 0; Completed = 0; Dismissed = 0 }
        foreach ($r in $recs) {
            $rc[$r.Status]++
            foreach ($k in @($res.Keys)) { $res[$k] += $r.StatusCounts.$k }
        }
        $total = @($recs).Count
        [pscustomobject]@{
            Name            = $name
            Total           = $total
            Expected        = [int]$expected
            Recommendations = [pscustomobject]$rc
            Resources       = [pscustomobject]$res
            ResourceTotal   = [int](($res.Values | Measure-Object -Sum).Sum)
            # Done = no longer active (completed, dismissed or postponed), same as the portal.
            PercentDone     = if ($total) { [math]::Round((($total - $rc.Active) / $total) * 100) } else { 0 }
        }
    }
    $perReview = foreach ($rv in $Review) {
        & $build @($Recommendation | Where-Object ReviewId -eq $rv.ReviewId) $rv.ReviewName $rv.RecommendationsCount
    }
    [pscustomobject]@{
        Overall   = & $build @($Recommendation) 'All selected reviews' (($Review | Measure-Object RecommendationsCount -Sum).Sum)
        PerReview = @($perReview)
    }
}

#endregion

#region Export

function Export-RtRecommendation {
    <# Writes recommendations as a task-planner friendly CSV (one row = one task). #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Recommendation,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Priority,
        [string[]]$Status
    )
    $rows = @($Recommendation |
        Where-Object { -not $Priority -or $_.Priority -in $Priority } |
        Where-Object { -not $Status -or $_.Status -in $Status } |
        Sort-Object PriorityRank, ReviewName, Title |
        ForEach-Object {
            $rec = $_
            $resources = if ($rec.PSObject.Properties['ResourcesLoaded'] -and -not $rec.ResourcesLoaded) { '' } else { ($rec.Resources | ForEach-Object { $_.ResourceId }) -join '; ' }
            # Excel cell limit is 32767 characters.
            if ($resources.Length -gt 32000) { $resources = $resources.Substring(0, 32000) + ' ...' }
            $descParts = @($rec.Description)
            if ($rec.PotentialBenefits) { $descParts += "Potential benefits: $($rec.PotentialBenefits)" }
            if ($rec.Notes) { $descParts += "Account team notes: $($rec.Notes)" }
            if ($rec.LearnMoreLink) { $descParts += "Learn more: $($rec.LearnMoreLink)" }
            [pscustomobject][ordered]@{
                TaskName              = $rec.Title
                Bucket                = $rec.ReviewName
                Priority              = $rec.Priority
                Status                = $rec.Status
                Description           = ($descParts | Where-Object { $_ }) -join "`n"
                Labels                = (@('Resiliency', $rec.Priority, $rec.WorkloadName) | Where-Object { $_ }) -join ';'
                Workload              = $rec.WorkloadName
                ImpactedResourceCount = if ($rec.PSObject.Properties['ResourceCount']) { $rec.ResourceCount } else { $rec.Resources.Count }
                ActiveResources       = $rec.StatusCounts.Active
                PostponedResources    = $rec.StatusCounts.Postponed
                CompletedResources    = $rec.StatusCounts.Completed
                DismissedResources    = $rec.StatusCounts.Dismissed
                ImpactedResources     = $resources
                Category              = $rec.Category
                LearnMoreLink         = $rec.LearnMoreLink
                RecommendationTypeId  = $rec.RecommendationTypeId
                ReviewId              = $rec.ReviewId
            }
        })
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    # UTF-8 with BOM so Excel and most planners detect umlauts correctly.
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8BOM
    [pscustomobject]@{ Path = (Resolve-Path $Path).Path; Count = $rows.Count }
}

#endregion

#region Status update (runs in a background thread job)

function Get-RtUpdateOutcome {
    <#
    .SYNOPSIS
        Decides the result of one status change from the PATCH result and the re-read status.
    .DESCRIPTION
        The re-read status is the truth: Advisor may answer a PATCH with an error (e.g. 404
        while a sibling update is applied) and still end up in the target status.
    #>
    param([string]$Target, [string]$ActualStatus, [string]$PatchError, [string]$ReadError)
    $bucket = if ($ActualStatus) { ConvertTo-RtStatusBucket $ActualStatus } else { '' }
    $targetBucket = ConvertTo-RtStatusBucket $Target
    if ($bucket -and $bucket -eq $targetBucket) {
        $msg = if ($PatchError) { "Verified $ActualStatus (PATCH reported: $PatchError)" } else { "Updated, verified $ActualStatus." }
        return [pscustomobject]@{ Success = $true; Verified = $true; Message = $msg }
    }
    if (-not $PatchError -and -not $bucket) {
        # PATCH accepted but the re-read failed -> count it, flag it as unverified.
        return [pscustomobject]@{ Success = $true; Verified = $false; Message = "Updated, not verified ($ReadError)" }
    }
    if (-not $PatchError) {
        return [pscustomobject]@{ Success = $false; Verified = $true; Message = "PATCH accepted, but status is still $ActualStatus." }
    }
    if ($ReadError -match 'HTTP 404') {
        return [pscustomobject]@{ Success = $false; Verified = $true; Message = "Recommendation no longer exists (resource deleted?). $PatchError" }
    }
    $now = if ($ActualStatus) { " Current status: $ActualStatus." } else { '' }
    return [pscustomobject]@{ Success = $false; Verified = [bool]$ActualStatus; Message = "$PatchError$now" }
}

function Invoke-RtStatusUpdate {
    <#
    .SYNOPSIS
        Sets the Advisor status on every given resource-level recommendation and verifies it.
    .DESCRIPTION
        Recommendations on the same resource with the same type are handled one after another
        (Advisor may apply one change to all of them; parallel calls then collide with 404).
        Each item is re-read after the PATCH; the re-read status decides success.
        -Sibling items are only re-read, to detect changes Azure applied to them as well.
    .OUTPUTS
        One result per item: Kind (Target/Sibling), RecommendationArmId, ResourceName,
        Success, Verified, ActualStatus, Message.
    #>
    param(
        [string]$Token,
        [Parameter(Mandatory)][object[]]$Resource,
        [Parameter(Mandatory)][ValidateSet('Postponed', 'Completed', 'Dismissed', 'New')][string]$Status,
        [string]$DismissReason = 'Other',
        [datetime]$PostponedUntil = (Get-Date).AddDays(90),
        [object[]]$Sibling = @(),
        [int]$ThrottleLimit = 8,
        [switch]$Demo
    )
    $properties = [ordered]@{ recommendationStatus = $Status }
    if ($Status -eq 'Dismissed') { $properties['recommendationDismissReason'] = $DismissReason }
    if ($Status -eq 'Postponed') { $properties['postponedUntilDateTime'] = $PostponedUntil.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $body = @{ properties = $properties }
    $fns = @{}
    foreach ($n in 'Invoke-RtArm', 'Get-RtProp', 'ConvertTo-RtStatusBucket', 'Get-RtUpdateOutcome') { $fns[$n] = (Get-Item "function:$n").ScriptBlock.ToString() }
    $api = $script:AdvisorApiVersion
    $isDemo = [bool]$Demo
    Write-RtLog "Status update to $Status for $(@($Resource).Count) resource(s), $(@($Sibling).Count) related item(s) to re-read"

    # One work unit per resource + recommendation type; siblings ride along for the re-read.
    $units = [ordered]@{}
    foreach ($kind in 'Target', 'Sibling') {
        $list = if ($kind -eq 'Target') { $Resource } else { $Sibling }
        foreach ($r in @($list)) {
            if ($null -eq $r) { continue }
            $k = ('{0}|{1}' -f $r.ResourceId, (Get-RtProp $r 'RecommendationTypeId')).ToLowerInvariant()
            if (-not $units.Contains($k)) { $units[$k] = [System.Collections.Generic.List[object]]::new() }
            $units[$k].Add([pscustomobject]@{ Kind = $kind; Item = $r })
        }
    }

    @($units.Values) | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        foreach ($e in ($using:fns).GetEnumerator()) { Set-Item "function:$($e.Key)" ([scriptblock]::Create($e.Value)) }
        $token = $using:Token; $api = $using:api; $target = $using:Status

        $read = {
            param($res)
            $out = @{ Status = ''; Error = '' }
            try { $out.Status = [string](Get-RtProp (Invoke-RtArm -Token $token -Path $res.RecommendationArmId -ApiVersion $api) 'properties.recommendationStatus') }
            catch { $out.Error = $_.Exception.Message }
            $out
        }

        foreach ($entry in @($_ | Sort-Object { $_.Kind -ne 'Target' })) {
            $res = $entry.Item
            $result = [ordered]@{ Kind = $entry.Kind; RecommendationArmId = $res.RecommendationArmId; ResourceName = $res.ResourceName; Success = $false; Verified = $false; ActualStatus = ''; Message = '' }

            if ($using:isDemo) {
                Start-Sleep -Milliseconds (Get-Random -Minimum 150 -Maximum 600)
                if ($entry.Kind -eq 'Sibling') { $result.ActualStatus = $res.RawStatus; $result.Verified = $true }
                elseif ($res.ResourceName -match 'deleted') { $result.Verified = $true; $result.Message = 'Recommendation no longer exists (resource deleted?). HTTP 404 PATCH : ResourceNotFound' }
                else { $result.Success = $true; $result.Verified = $true; $result.ActualStatus = $target; $result.Message = "Updated, verified $target (demo)." }
                [pscustomobject]$result
                continue
            }

            if ($entry.Kind -eq 'Sibling') {
                $now = & $read $res
                $result.ActualStatus = $now.Status; $result.Verified = [bool]$now.Status; $result.Message = $now.Error
                [pscustomobject]$result
                continue
            }

            # Already in the target status (e.g. changed together with a sibling) -> nothing to PATCH.
            $before = & $read $res
            if ($before.Status -and (ConvertTo-RtStatusBucket $before.Status) -eq (ConvertTo-RtStatusBucket $target)) {
                $result.Success = $true; $result.Verified = $true; $result.ActualStatus = $before.Status
                $result.Message = "Already $($before.Status) (verified, no change needed)."
                [pscustomobject]$result
                continue
            }

            # Documented route is subscription scoped; the resource-scoped ID is the fallback.
            $patchError = ''
            $paths = @("/subscriptions/$($res.SubscriptionId)/providers/Microsoft.Advisor/recommendations/$($res.RecommendationName)")
            if ($res.RecommendationArmId -and $res.RecommendationArmId -ne $paths[0]) { $paths += $res.RecommendationArmId }
            foreach ($path in $paths) {
                try { $null = Invoke-RtArm -Token $token -Path $path -ApiVersion $api -Method PATCH -Body $using:body; $patchError = ''; break }
                catch { $patchError = $_.Exception.Message }
            }

            # Re-read until the target status shows up (Advisor applies changes asynchronously).
            $after = $null
            foreach ($delay in 1, 2, 4) {
                Start-Sleep -Seconds $delay
                $after = & $read $res
                if ($after.Status -and (ConvertTo-RtStatusBucket $after.Status) -eq (ConvertTo-RtStatusBucket $target)) { break }
                if (-not $after.Status -and $after.Error -match 'HTTP 404' -and $patchError) { break }
            }
            $outcome = Get-RtUpdateOutcome -Target $target -ActualStatus $after.Status -PatchError $patchError -ReadError $after.Error
            $result.Success = $outcome.Success; $result.Verified = $outcome.Verified; $result.ActualStatus = $after.Status; $result.Message = $outcome.Message
            [ResiliencyTriage.RtLog]::Write(($outcome.Success ? 'INFO' : 'WARN'), "Update $($res.ResourceName): $($outcome.Message)")
            [pscustomobject]$result
        }
    }
}
function Start-RtStatusUpdateJob {
    <# Starts Invoke-RtStatusUpdate as a background thread job and returns a tracking object. #>
    param(
        [string]$Token,
        [Parameter(Mandatory)][object]$Recommendation,
        [Parameter(Mandatory)][object[]]$Resource,
        [Parameter(Mandatory)][string]$Status,
        [string]$DismissReason = 'Other',
        [datetime]$PostponedUntil = (Get-Date).AddDays(90),
        [object[]]$Sibling = @(),
        [switch]$Demo
    )
    $modulePath = $PSCommandPath
    $job = Start-ThreadJob -Name ('RtUpdate-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8))) -ScriptBlock {
        param($ModulePath, $Token, $Resource, $Status, $DismissReason, $PostponedUntil, $Sibling, $Demo)
        Import-Module $ModulePath -Force
        Invoke-RtStatusUpdate -Token $Token -Resource $Resource -Status $Status -DismissReason $DismissReason `
            -PostponedUntil $PostponedUntil -Sibling $Sibling -Demo:$Demo
    } -ArgumentList $modulePath, $Token, $Resource, $Status, $DismissReason, $PostponedUntil, @($Sibling), ([bool]$Demo)
    [pscustomobject]@{
        Job            = $job
        Recommendation = $Recommendation
        Status         = $Status
        ResourceCount  = @($Resource).Count
        StartedAt      = Get-Date
    }
}

#endregion

#region Demo data

function New-RtDemoData {
    <# Fictional reviews and recommendations to try the TUI without Azure access. #>
    $subA = '00000000-aaaa-4000-8000-000000000001'
    $subB = '00000000-bbbb-4000-8000-000000000002'
    $reviews = @(
        [pscustomobject]@{ ReviewId = '11111111-1111-4111-8111-111111111111'; ReviewName = 'WARA - Contoso SAP Landscape'; WorkloadName = 'SAP Production'; ReviewStatus = 'InProgress'; RecommendationsCount = 14; PublishedAt = '2026-08-12T09:00:00Z'; UpdatedAt = '2026-09-20T10:00:00Z'; SubscriptionId = $subA; SubscriptionName = 'contoso-sap-prod'; ResourceId = '' }
        [pscustomobject]@{ ReviewId = '22222222-2222-4222-8222-222222222222'; ReviewName = 'WARA - Contoso Web Shop'; WorkloadName = 'E-Commerce'; ReviewStatus = 'New'; RecommendationsCount = 10; PublishedAt = '2026-09-01T09:00:00Z'; UpdatedAt = '2026-09-01T09:00:00Z'; SubscriptionId = $subB; SubscriptionName = 'contoso-web-prod'; ResourceId = '' }
        [pscustomobject]@{ ReviewId = '33333333-3333-4333-8333-333333333333'; ReviewName = 'WARA - Contoso Data Platform'; WorkloadName = 'Analytics'; ReviewStatus = 'Completed'; RecommendationsCount = 6; PublishedAt = '2026-05-03T09:00:00Z'; UpdatedAt = '2026-07-15T09:00:00Z'; SubscriptionId = $subA; SubscriptionName = 'contoso-sap-prod'; ResourceId = '' }
    )
    # Priority, title, description, resource type, name prefix
    $catalog = @(
        , @('Critical', 'Deploy VMs across Availability Zones', 'Virtual machines run in a single zone; a zonal outage takes the whole tier down.', 'Microsoft.Compute/virtualMachines', 'vm')
        , @('Critical', 'Enable zone redundancy for SQL Database', 'The database is not zone redundant. Switch to a zone-redundant configuration.', 'Microsoft.Sql/servers/databases', 'sqldb')
        , @('Critical', 'Configure geo-redundant backup for Recovery Services vault', 'Backups are stored locally only (LRS) and are lost in a regional disaster.', 'Microsoft.RecoveryServices/vaults', 'rsv')
        , @('High', 'Use Standard SKU and zone-redundant public IP addresses', 'Basic SKU public IPs are retired and do not support availability zones.', 'Microsoft.Network/publicIPAddresses', 'pip')
        , @('High', 'Enable soft delete and purge protection on Key Vault', 'Accidental or malicious deletion of secrets causes a full outage of dependent apps.', 'Microsoft.KeyVault/vaults', 'kv')
        , @('High', 'Use zone-redundant storage (ZRS) for storage accounts', 'LRS accounts keep all copies in one datacenter.', 'Microsoft.Storage/storageAccounts', 'st')
        , @('High', 'Configure health probes on Application Gateway backend pools', 'Without custom probes, unhealthy instances keep receiving traffic.', 'Microsoft.Network/applicationGateways', 'agw')
        , @('Medium', 'Enable Azure Service Health alerts', 'No alerts are configured for service issues, planned maintenance or health advisories.', 'Microsoft.Resources/subscriptions', 'sub')
        , @('Medium', 'Use Premium SSD v2 or Premium SSD for production disks', 'Standard HDD disks do not meet the SLA required for production workloads.', 'Microsoft.Compute/disks', 'disk')
        , @('Medium', 'Configure autoscale for App Service plans', 'Fixed instance count cannot absorb load peaks.', 'Microsoft.Web/serverFarms', 'asp')
        , @('Medium', 'Enable diagnostic settings on critical resources', 'Platform logs are not collected which slows down incident investigation.', 'Microsoft.Network/loadBalancers', 'lb')
        , @('Low', 'Tag resources with workload and criticality', 'Missing tags make it hard to map incidents to business impact.', 'Microsoft.Compute/virtualMachines', 'vm')
        , @('Low', 'Review AKS cluster upgrade channel', 'Clusters without an auto-upgrade channel drift out of support.', 'Microsoft.ContainerService/managedClusters', 'aks')
        , @('Informational', 'Document the disaster recovery runbook', 'A tested DR runbook reduces recovery time during a regional outage.', 'Microsoft.Resources/subscriptions', 'sub')
    )
    $rand = [System.Random]::new(42)
    $statuses = @('New', 'New', 'New', 'Postponed', 'Completed', 'Dismissed')
    $raw = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($rv in $reviews) {
        $take = [Math]::Min($rv.RecommendationsCount, $catalog.Count)
        for ($ci = 0; $ci -lt $take; $ci++) {
            $c = $catalog[$ci]
            $count = $rand.Next(1, 9)
            # Keep a whole recommendation in one status most of the time, mix a few.
            $baseStatus = if ($rv.ReviewStatus -eq 'Completed') { @('Completed', 'Dismissed')[$rand.Next(0, 2)] } else { $statuses[$rand.Next(0, $statuses.Count)] }
            $workloadTag = $rv.WorkloadName.Split(' ')[0].ToLowerInvariant()
            for ($i = 1; $i -le $count; $i++) {
                $n++
                $status = if ($rand.Next(0, 10) -eq 0) { 'New' } else { $baseStatus }
                $name = '{0}-{1}-{2:00}' -f $c[4], $workloadTag, $i
                if ($rand.Next(0, 9) -eq 0) { $name += '-deleted' }
                $resId = "/subscriptions/$($rv.SubscriptionId)/resourceGroups/rg-$workloadTag-prod/providers/$($c[3])/$name"
                $recName = [guid]::new(('{0:x8}-0000-4000-8000-{1:x12}' -f $n, $n)).ToString()
                $raw.Add([pscustomobject]@{
                    id         = "$resId/providers/Microsoft.Advisor/recommendations/$recName"
                    name       = $recName
                    type       = 'Microsoft.Advisor/recommendations'
                    properties = [pscustomobject]@{
                        category             = 'HighAvailability'
                        impact               = 'High'
                        impactedField        = $c[3]
                        impactedValue        = $name
                        recommendationStatus = $status
                        label                = $c[1]
                        description          = $c[2]
                        potentialBenefits    = 'Improves workload resiliency and reduces the blast radius of failures.'
                        notes                = 'Discussed in the WARA readout. Plan implementation with the platform team.'
                        learnMoreLink        = 'https://learn.microsoft.com/azure/reliability/'
                        recommendationTypeId = ('{0:x8}-1111-4111-8111-000000000000' -f ($ci + 1))
                        trackedProperties    = [pscustomobject]@{ priority = $c[0] }
                        resourceMetadata     = [pscustomobject]@{ resourceId = $resId }
                        review               = [pscustomobject]@{ id = "/subscriptions/$($rv.SubscriptionId)/providers/Microsoft.Advisor/resiliencyReviews/$($rv.ReviewId)"; name = $rv.ReviewName }
                    }
                })
            }
        }
    }
    [pscustomobject]@{ Reviews = $reviews; Raw = $raw.ToArray() }
}

#endregion

Export-ModuleMember -Function @(
    'Get-RtProp', 'Get-RtDismissReason', 'Get-RtPriorityRank', 'ConvertTo-RtStatusBucket',
    'Initialize-RtLog', 'Write-RtLog', 'Get-RtRecentLog', 'Set-RtProxy', 'Assert-RtAzModule', 'Get-RtAzContextInfo', 'Connect-RtAzure', 'Get-RtArmToken',
    'Invoke-RtArm', 'Get-RtSubscription', 'Invoke-RtGraphQuery',
    'Get-RtReview', 'Get-RtReviewRecommendation', 'Get-RtGraphReviewRecommendation', 'Merge-RtRecommendationSource', 'Get-RtResourceTypeFromId', 'ConvertTo-RtRecommendation', 'Update-RtRecommendationStatus', 'ConvertFrom-RtSummaryRow', 'Get-RtRecommendationSummary', 'Get-RtRecommendationResource', 'Set-RtRecommendationResource', 'Get-RtReviewFilterKql', 'ConvertTo-RtKqlString', 'Merge-RtDuplicateRecommendation',
    'Get-RtSummary', 'Export-RtRecommendation',
    'Get-RtUpdateOutcome', 'Invoke-RtStatusUpdate', 'Start-RtStatusUpdateJob', 'New-RtDemoData'
)
