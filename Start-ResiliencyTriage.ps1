#Requires -Version 7.2
<#
.SYNOPSIS
    Resiliency Review Triage - PowerShell TUI to track, export and triage Azure Advisor resiliency reviews.

.DESCRIPTION
    1. Reuses an existing Azure context (after asking) or signs in.
    2. Finds the resiliency reviews shared with you in Azure Advisor and lets you pick one,
       several or all of them.
    3. Shows the progress of the selected reviews (Active / Postponed / Completed / Dismissed).
    4. Exports all recommendations - or only selected priorities - as a task-planner CSV.
    5. Triage: live-filter the recommendations, open one and set Postponed, Completed or
       Dismissed on every impacted resource. The update runs as a background job; the TUI
       reports how many resources succeeded and how many failed (e.g. deleted resources).

.PARAMETER TenantId
    Tenant to sign in to when a new sign-in is needed (or when the current context is in another tenant).

.PARAMETER SubscriptionId
    Limits the scan to these subscriptions. Default: every enabled subscription of the tenant.

.PARAMETER UseDeviceAuthentication
    Uses the device code flow for sign-in (e.g. on a jump host without browser).

.PARAMETER ExportPath
    Folder for CSV exports and failure logs. Default: .\exports next to this script.

.PARAMETER Demo
    Runs with fictional data and simulated updates - no Azure access needed.

.PARAMETER Proxy
    Proxy URL (e.g. http://proxy.contoso.com:8080). Default: the system proxy (incl. PAC).
    Either way the proxy is authenticated with your Windows user (Kerberos/NTLM).

.PARAMETER ProxyCredential
    Credential for the proxy when your Windows user is not accepted.

.PARAMETER LargeLoadThreshold
    Resources above which the tool asks before loading the resources of a recommendation (default 10000).

.EXAMPLE
    .\Start-ResiliencyTriage.ps1

.EXAMPLE
    .\Start-ResiliencyTriage.ps1 -TenantId contoso.onmicrosoft.com -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    .\Start-ResiliencyTriage.ps1 -Demo
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string[]]$SubscriptionId,
    [switch]$UseDeviceAuthentication,
    [string]$ExportPath = (Join-Path $PSScriptRoot 'exports'),
    [switch]$Demo,
    [string]$Proxy,
    [pscredential]$ProxyCredential,
    [int]$LargeLoadThreshold = 10000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$azModule = Join-Path $PSScriptRoot 'modules\ResiliencyTriage.Azure.psm1'
$tuiModule = Join-Path $PSScriptRoot 'modules\ResiliencyTriage.Tui.psm1'
Import-Module $azModule -Force
Import-Module $tuiModule -Force

if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    throw 'Resiliency Review Triage is an interactive TUI and needs a real console (no redirected input/output).'
}

#region Sign-in (plain console, before the TUI takes over the screen)

function Write-Banner {
    Write-Host ''
    Write-Host '  ╔══════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '  ║   Resiliency Review Triage  ·  Azure Advisor     ║' -ForegroundColor Cyan
    Write-Host '  ╚══════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''
}

Write-Banner
$logFile = Initialize-RtLog -Folder (Join-Path $ExportPath 'logs')
Write-RtLog "Parameters: Demo=$([bool]$Demo) TenantId='$TenantId' Subscriptions=$(@($SubscriptionId | Where-Object { $_ }).Count) Proxy='$Proxy' ProxyCredential=$([bool]$ProxyCredential)"
$ctx = $null
if ($Demo) {
    Write-Host '  Demo mode: fictional data, no Azure calls.' -ForegroundColor Yellow
    $ctx = [pscustomobject]@{ Account = 'demo@contoso.com'; TenantId = '00000000-0000-0000-0000-000000000000'; SubscriptionName = 'demo'; SubscriptionId = '' }
}
else {
    # Authenticate to a corporate proxy with the user context before any web call (HTTP 407).
    $proxyUri = Set-RtProxy -Proxy $Proxy -Credential $ProxyCredential
    Write-RtLog ($proxyUri ? "Proxy for ARM: $proxyUri" : 'No proxy for ARM (direct connection)')
    if ($proxyUri) {
        $who = if ($ProxyCredential) { $ProxyCredential.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }
        Write-Host ("  Proxy        : {0} (authenticating as {1})" -f $proxyUri, $who) -ForegroundColor DarkGray
        Write-Host ''
    }
    Assert-RtAzModule
    $ctx = Get-RtAzContextInfo
    if ($ctx) {
        Write-Host '  An existing Azure context was found:' -ForegroundColor Green
        Write-Host ("    Account      : {0} ({1})" -f $ctx.Account, $ctx.AccountType)
        Write-Host ("    Tenant       : {0}" -f $ctx.TenantId)
        Write-Host ("    Subscription : {0} ({1})" -f $ctx.SubscriptionName, $ctx.SubscriptionId)
        Write-Host ''
        $reuse = $true
        if ($TenantId -and $TenantId -ne $ctx.TenantId -and $TenantId -notmatch '\.') {
            Write-Host "  The context belongs to another tenant than -TenantId $TenantId." -ForegroundColor Yellow
        }
        $answer = Read-Host '  Reuse this context? [Y/n]'
        if ($answer -and $answer -notmatch '^(y|yes|j|ja)$') { $reuse = $false }
        if (-not $reuse) { $ctx = $null }
        Write-RtLog "Existing context for tenant $($ctx ? $ctx.TenantId : '-') reused: $reuse"
    }
    else {
        Write-Host '  No Azure context found - starting sign-in.' -ForegroundColor Yellow
    }
    if (-not $ctx) {
        $ctx = Connect-RtAzure -TenantId $TenantId -UseDeviceAuthentication:$UseDeviceAuthentication
        if (-not $ctx) { throw 'Sign-in did not produce an Azure context.' }
        Write-Host ("  Signed in as {0} (tenant {1})." -f $ctx.Account, $ctx.TenantId) -ForegroundColor Green
    }
    # Fail early if no ARM token can be obtained for the context.
    $null = Get-RtArmToken
}
Write-Host "  Activity log : $logFile" -ForegroundColor DarkGray

#endregion

#region State and helpers

$state = [pscustomobject]@{
    Context         = $ctx
    Subscriptions   = @()
    AllReviews      = @()
    FailedSubs      = @()
    SelectedReviews = @()
    Recommendations = @()
    Verified        = @{}   # recommendation ARM ID -> status verified in this session
    VerifiedKeys    = [System.Collections.Generic.HashSet[string]]::new()
    DemoResources   = @{}
    Jobs            = [System.Collections.Generic.List[object]]::new()
    Notices         = [System.Collections.Generic.List[string]]::new()
    History         = [System.Collections.Generic.List[string]]::new()
    Filter          = ''
    ListIndex       = 0
    DemoData        = $null
}
$Clr = @{}
foreach ($n in 'Reset', 'Bold', 'Muted', 'Ok', 'Warn', 'Error', 'Accent') { $Clr[$n] = Get-RtColor $n }

function Get-Token { if ($Demo) { return '' } return Get-RtArmToken }

function Update-ContextLine {
    $mode = if ($Demo) { '   ·   DEMO MODE' } else { '' }
    $sel = if ($state.SelectedReviews.Count) { "   ·   Reviews: $($state.SelectedReviews.Count) selected" } else { '' }
    Set-RtContextLine ("Account: {0}   ·   Tenant: {1}{2}{3}" -f $state.Context.Account, $state.Context.TenantId, $sel, $mode)
}

function Import-Reviews {
    <# Discovers subscriptions and resiliency reviews. #>
    if ($Demo) {
        $state.DemoData = New-RtDemoData
        $null = Invoke-RtBusy -Title 'Loading' -Message 'Looking for resiliency reviews (demo)…' -ScriptBlock { Start-Sleep -Milliseconds 800 }
        $state.AllReviews = @($state.DemoData.Reviews)
        $state.Subscriptions = @($state.AllReviews | Select-Object SubscriptionId, @{ n = 'Name'; e = { $_.SubscriptionName } } -Unique)
        return
    }
    $result = Invoke-RtBusy -Title 'Loading' -Message 'Scanning subscriptions for Azure Advisor resiliency reviews…' -ModulePath $azModule `
        -ArgumentList (Get-Token), @($SubscriptionId) -ScriptBlock {
            param($Token, $Only)
            $subs = @(Get-RtSubscription -Token $Token)
            if ($Only) {
                $known = @($subs | Where-Object { $_.SubscriptionId -in $Only })
                $missing = @($Only | Where-Object { $_ -notin $known.SubscriptionId } | ForEach-Object { [pscustomobject]@{ SubscriptionId = $_; Name = $_; TenantId = '' } })
                $subs = @($known) + @($missing)
            }
            $reviews = if ($subs) { Get-RtReview -Token $Token -Subscription $subs } else { [pscustomobject]@{ Reviews = @(); FailedSubscriptions = @() } }
            [pscustomobject]@{ Subscriptions = $subs; Reviews = @($reviews.Reviews); Failed = @($reviews.FailedSubscriptions) }
        }
    $state.Subscriptions = @($result.Subscriptions)
    $state.AllReviews = @($result.Reviews)
    $state.FailedSubs = @($result.Failed)
}

function Select-Reviews {
    <# Checkbox selection of reviews; returns $false when the user backs out. #>
    $cols = @(
        @{ Header = 'Review'; Flex = 3; Value = { param($r) $r.ReviewName } }
        @{ Header = 'Workload'; Flex = 2; Value = { param($r) $r.WorkloadName } }
        @{ Header = 'Status'; Width = 11; Value = { param($r) $r.ReviewStatus } }
        @{ Header = 'Recs'; Width = 5; Value = { param($r) $r.RecommendationsCount } }
        @{ Header = 'Resources'; Width = 9; Value = { param($r) if ($r.PSObject.Properties['ItemCount'] -and $null -ne $r.ItemCount) { '{0:n0}' -f $r.ItemCount } else { '' } } }
        @{ Header = 'Published'; Width = 10; Value = { param($r) if ($r.PublishedAt) { ([datetime]$r.PublishedAt).ToString('yyyy-MM-dd') } else { '' } } }
        @{ Header = 'Subscription'; Flex = 2; Value = { param($r) if ($r.SubscriptionName) { $r.SubscriptionName } else { $r.SubscriptionId } } }
    )
    $intro = @(
        "Found $($Clr.Bold)$($state.AllReviews.Count)$($Clr.Reset) resiliency review(s) in $($state.Subscriptions.Count) subscription(s). Select the reviews to work with:"
    )
    if ($state.FailedSubs.Count) {
        $intro += "$($Clr.Warn)$($state.FailedSubs.Count) subscription(s) could not be read - reviews there may be missing. Details: $logFile$($Clr.Reset)"
    }
    $viaRecs = @($state.AllReviews | Where-Object { $_.PSObject.Properties['Source'] -and $_.Source -eq 'Recommendations' }).Count
    if ($viaRecs) { $intro += "$($Clr.Muted)$viaRecs review(s) found only via their recommendations (status 'Unknown': review resource not readable).$($Clr.Reset)" }
    $intro += ''
    $pre = @()
    if ($state.SelectedReviews.Count) {
        for ($i = 0; $i -lt $state.AllReviews.Count; $i++) { if ($state.AllReviews[$i].ReviewId -in $state.SelectedReviews.ReviewId) { $pre += $i } }
    }
    elseif ($state.AllReviews.Count -eq 1) { $pre = @(0) }
    $picked = Show-RtCheckList -Title 'Select reviews' -Item $state.AllReviews -Column $cols -Lines $intro -Preselect $pre -RequireSelection
    if ($null -eq $picked) { return $false }
    $state.SelectedReviews = @($picked)
    Update-ContextLine
    return $true
}

function Import-Recommendations {
    <# Loads recommendations with resource counts only; resources follow on demand (Import-Resources). #>
    if ($Demo) {
        $raw = $state.DemoData.Raw
        $reviews = $state.SelectedReviews
        $full = @(Invoke-RtBusy -Title 'Loading' -Message 'Loading review recommendations (demo)…' -ModulePath $azModule `
            -ArgumentList $raw, $reviews -ScriptBlock {
                param($Raw, $Reviews)
                Start-Sleep -Milliseconds 600
                ConvertTo-RtRecommendation -RawRecommendation $Raw -Review $Reviews
            })
        # Same shape as online: counts now, resources later.
        $state.DemoResources = @{}
        foreach ($rec in $full) {
            $state.DemoResources[$rec.Key] = $rec.Resources
            $rec.StatusCounts = [pscustomobject][ordered]@{ Active = $rec.StatusCounts.Active; Postponed = $rec.StatusCounts.Postponed; Completed = $rec.StatusCounts.Completed; Dismissed = $rec.StatusCounts.Dismissed }
            $rec.Resources = [System.Collections.Generic.List[object]]::new()
            $rec.ResourcesLoaded = $false
        }
        $state.Recommendations = @($full | ForEach-Object { $_ })
    }
    else {
        $scan = @($state.Subscriptions.SubscriptionId)
        $state.Recommendations = @(Invoke-RtBusy -Title 'Loading' -Message "Loading recommendations of $($state.SelectedReviews.Count) review(s)…" -ModulePath $azModule `
            -ArgumentList (Get-Token), $state.SelectedReviews, $scan -ScriptBlock {
                param($Token, $Reviews, $Scan)
                Get-RtRecommendationSummary -Token $Token -Review $Reviews -ScanSubscription $Scan
            })
    }
    # Resource Graph lags a few minutes: reload resources changed in this session and keep the verified status.
    $changed = @($state.Recommendations | Where-Object { $state.VerifiedKeys.Contains($_.Key) })
    if ($changed) { $null = Import-Resources -Recommendation $changed -NoConfirm }
}

function Import-Resources {
    <# Loads the affected resources of recommendations that only have counts yet. Returns $false if cancelled. #>
    param([object[]]$Recommendation, [switch]$NoConfirm)
    $todo = @($Recommendation | Where-Object { -not $_.ResourcesLoaded })
    if (-not $todo) { return $true }
    $n = [int](($todo | Measure-Object ResourceCount -Sum).Sum)
    if (-not $NoConfirm -and $n -gt $LargeLoadThreshold) {
        $minutes = [Math]::Ceiling($n / 1000 * 4 / 60)
        $lines = @(
            ("$($Clr.Warn){0:n0} affected resources have to be loaded for this change.$($Clr.Reset)" -f $n)
            ''
            "This takes about $minutes minute(s). The status change itself then updates every resource."
        )
        if (-not (Read-RtConfirm -Title 'Large recommendation' -Lines $lines -Question 'Load the resources?' -Default $true)) { return $false }
    }
    if ($Demo) {
        $null = Invoke-RtBusy -Title 'Loading' -Message ("Loading {0:n0} affected resource(s) (demo)…" -f $n) -ScriptBlock { Start-Sleep -Milliseconds 400 }
        $loaded = @($todo | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Resources = @($state.DemoResources[$_.Key]) } })
    }
    else {
        $scan = @($state.Subscriptions.SubscriptionId)
        $loaded = @(Invoke-RtBusy -Title 'Loading' -Message ("Loading {0:n0} affected resource(s)…" -f $n) -ModulePath $azModule `
            -ArgumentList (Get-Token), $todo, $state.SelectedReviews, $scan -ScriptBlock {
                param($Token, $Recs, $Reviews, $Scan)
                Get-RtRecommendationResource -Token $Token -Recommendation $Recs -Review $Reviews -ScanSubscription $Scan
            })
    }
    Set-RtRecommendationResource -Target @($state.Recommendations) -Loaded $loaded -Requested $todo
    # Keep statuses verified in this session (Resource Graph may still show the old one).
    foreach ($rec in $todo) {
        $hit = $false
        foreach ($res in $rec.Resources) {
            $v = $state.Verified[([string]$res.RecommendationArmId).ToLowerInvariant()]
            if ($v) { $res.RawStatus = $v; $res.Status = ConvertTo-RtStatusBucket $v; $hit = $true }
        }
        if ($hit) { Update-RtRecommendationStatus -Recommendation $rec }
    }
    return $true
}

function Get-FriendlyReason { param([string]$Reason) ($Reason -creplace '([a-z])([A-Z])', '$1 $2') }

function Add-Notice {
    param([string]$Text)
    $state.Notices.Insert(0, $Text)
    while ($state.Notices.Count -gt 4) { $state.Notices.RemoveAt($state.Notices.Count - 1) }
    $state.History.Add(([regex]::Replace($Text, '\e\[[0-9;?]*[A-Za-z]', '')))
}

function Find-RtResourceEntry {
    <# All loaded resource entries (with their recommendation) for the given recommendation ARM IDs. #>
    param([string[]]$ArmId)
    $ids = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ArmId), [StringComparer]::OrdinalIgnoreCase)
    foreach ($rec in $state.Recommendations) {
        foreach ($res in $rec.Resources) {
            if ($ids.Contains([string]$res.RecommendationArmId)) { [pscustomobject]@{ Recommendation = $rec; Resource = $res } }
        }
    }
}

function Update-Jobs {
    <# Collects finished background updates, applies the verified status locally and reports. Returns $true on change. #>
    $changed = $false
    foreach ($t in @($state.Jobs)) {
        if ($t.Job.State -in 'NotStarted', 'Running') { continue }
        $results = @()
        $jobError = ''
        try { $results = @(Receive-Job -Job $t.Job -ErrorAction Stop) } catch { $jobError = $_.Exception.Message }
        Remove-Job -Job $t.Job -Force -ErrorAction SilentlyContinue
        $null = $state.Jobs.Remove($t)
        $changed = $true

        $targets = @($results | Where-Object Kind -eq 'Target')
        $ok = @($targets | Where-Object Success)
        $failed = @($targets | Where-Object { -not $_.Success })
        $unverified = @($ok | Where-Object { -not $_.Verified })

        # Apply the status Azure reports now (re-read after the update) to every loaded entry.
        $touched = [System.Collections.Generic.HashSet[object]]::new()
        $null = $touched.Add($t.Recommendation)
        $siblingChanged = 0
        $byId = @{}
        foreach ($r in $results) { $byId[([string]$r.RecommendationArmId).ToLowerInvariant()] = $r }
        foreach ($e in @(Find-RtResourceEntry -ArmId @($byId.Keys))) {
            $r = $byId[([string]$e.Resource.RecommendationArmId).ToLowerInvariant()]
            $actual = [string]$r.ActualStatus
            if (-not $actual -and $r.Kind -eq 'Target' -and $r.Success) { $actual = $t.Status }
            if (-not $actual) { continue }
            $state.Verified[([string]$e.Resource.RecommendationArmId).ToLowerInvariant()] = $actual
            $null = $state.VerifiedKeys.Add($e.Recommendation.Key)
            $bucket = ConvertTo-RtStatusBucket $actual
            if ($r.Kind -eq 'Sibling' -and $bucket -ne $e.Resource.Status) { $siblingChanged++ }
            $e.Resource.Status = $bucket; $e.Resource.RawStatus = $actual
            $null = $touched.Add($e.Recommendation)
        }
        foreach ($rec in $touched) { Update-RtRecommendationStatus -Recommendation $rec }

        $title = (Format-RtCell $t.Recommendation.Title 48).Trim()
        if ($jobError) {
            Add-Notice "$($Clr.Error)✗ $($t.Status) · $title : background job failed - $jobError$($Clr.Reset)"
            continue
        }
        $logHint = ''
        if ($failed.Count -or $unverified.Count) {
            $logDir = Join-Path $ExportPath 'logs'
            $null = New-Item -ItemType Directory -Path $logDir -Force
            $log = Join-Path $logDir ('update-{0}-{1}.csv' -f $t.Status, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $targets | Select-Object ResourceName, Success, Verified, ActualStatus, Message, RecommendationArmId |
                Export-Csv -Path $log -NoTypeInformation -Encoding utf8BOM
            $logHint = "  $($Clr.Muted)(details: $log)$($Clr.Reset)"
        }
        $color = if ($failed.Count) { $Clr.Warn } else { $Clr.Ok }
        $mark = if ($failed.Count) { '!' } else { '✓' }
        $extra = ''
        if ($unverified.Count) { $extra += ", $($unverified.Count) not yet confirmed" }
        if ($siblingChanged) { $extra += ", Azure also changed $siblingChanged related item(s)" }
        Add-Notice ("{0}{1} {2} · {3} : {4} of {5} resource(s) verified {2}, {6} failed{7}{8}{9}" -f $color, $mark, $t.Status, $title, $ok.Count, $targets.Count, $failed.Count, $extra, $Clr.Reset, $logHint)
    }
    return $changed
}
$onTick = { Update-Jobs }
$banner = {
    $lines = @()
    if ($state.Jobs.Count) {
        $n = ($state.Jobs | Measure-Object ResourceCount -Sum).Sum
        $lines += "$($Clr.Accent)⟳ $($state.Jobs.Count) background update(s) running ($n resource(s))…$($Clr.Reset)"
    }
    foreach ($n in $state.Notices) { $lines += $n }
    if ($lines) { $lines += '' }
    $lines
}

#endregion

#region Screens

function Invoke-Export {
    param([switch]$ByPriority)
    $recs = @($state.Recommendations)
    $priorities = $null
    if ($ByPriority) {
        $items = @($recs | Group-Object Priority | ForEach-Object {
            [pscustomobject]@{ Priority = $_.Name; Count = $_.Count; Rank = Get-RtPriorityRank $_.Name }
        } | Sort-Object Rank)
        $cols = @(
            @{ Header = 'Priority'; Width = 15; Value = { param($x) $x.Priority }; Color = { param($x) Get-RtPriorityCell $x.Priority } }
            @{ Header = 'Recommendations'; Width = 16; Value = { param($x) $x.Count } }
        )
        $picked = Show-RtCheckList -Title 'Export by priority' -Item $items -Column $cols -Lines @('Select the priorities to export:', '') -RequireSelection
        if ($null -eq $picked) { return }
        $priorities = @($picked.Priority)
    }
    $scope = Show-RtMenu -Title 'Export' -Lines @('Which recommendations should be exported?') -Option @(
        'Only Active recommendations (open work - recommended for task import)'
        'All statuses (Active, Postponed, Completed, Dismissed)'
    )
    if ($scope -lt 0) { return }
    $statuses = if ($scope -eq 0) { @('Active') } else { $null }

    $suffix = if ($priorities) { '-' + ($priorities -join '-') } else { '-All' }
    $default = Join-Path $ExportPath ('ResiliencyTasks{0}-{1}.csv' -f $suffix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $path = Read-RtLine -Title 'Export' -Lines @('CSV file for the task import (UTF-8, one row per recommendation):') -Prompt 'File' -Default $default -Validate {
        param($p)
        if ([string]::IsNullOrWhiteSpace($p)) { return 'Please enter a file name.' }
        if ($p -notmatch '\.csv$') { return 'The file name must end with .csv' }
    }
    if (-not $path) { return }
    $set = @($recs | Where-Object { (-not $priorities -or $_.Priority -in $priorities) -and (-not $statuses -or $_.Status -in $statuses) })
    $missing = @($set | Where-Object { -not $_.ResourcesLoaded })
    if ($missing) {
        $n = [int](($missing | Measure-Object ResourceCount -Sum).Sum)
        $q = Read-RtConfirm -Title 'Export' -Lines @(('The CSV always contains the resource counts. Listing the resource IDs requires loading {0:n0} resource(s) first.' -f $n)) `
            -Question 'Include the impacted resource IDs?' -Default ($n -le $LargeLoadThreshold)
        if ($q -and -not (Import-Resources -Recommendation $missing -NoConfirm)) { return }
    }
    try {
        $res = Export-RtRecommendation -Recommendation $recs -Path $path -Priority $priorities -Status $statuses
        Show-RtMessage -Title 'Export' -Lines @(
            "$($Clr.Ok)✓ Exported $($res.Count) recommendation(s).$($Clr.Reset)"
            ''
            "File: $($res.Path)"
            ''
            "$($Clr.Muted)Columns: TaskName, Bucket (review), Priority, Status, Description, Labels, Workload, impacted resource counts and IDs, …$($Clr.Reset)"
        )
    }
    catch {
        Show-RtMessage -Title 'Export' -Lines @("$($Clr.Error)Export failed: $($_.Exception.Message)$($Clr.Reset)")
    }
}

function Invoke-SetStatus {
    <# Collects the status parameters, confirms and starts the background update. #>
    param([object]$Recommendation, [string]$Status)
    $running = @($state.Jobs | Where-Object { $_.Recommendation.Key -eq $Recommendation.Key })
    if ($running) {
        Show-RtMessage -Title 'Update running' -Lines @("$($Clr.Warn)An update for this recommendation is still running. Wait until it has finished.$($Clr.Reset)")
        return
    }
    $targets = @($Recommendation.Resources | Where-Object { $_.Status -ne $Status })
    $already = $Recommendation.Resources.Count - $targets.Count
    if (-not $targets) {
        Show-RtMessage -Title 'Nothing to do' -Lines @("All $($Recommendation.Resources.Count) resource(s) of this recommendation are already $Status.")
        return
    }

    $reason = 'Other'; $until = (Get-Date).AddDays(90); $detail = ''
    if ($Status -eq 'Dismissed') {
        $reasons = @(Get-RtDismissReason)
        $i = Show-RtMenu -Title 'Dismiss reason' -Lines @("Why is '$($Recommendation.Title)' dismissed?") -Option @($reasons | ForEach-Object { Get-FriendlyReason $_ })
        if ($i -lt 0) { return }
        $reason = $reasons[$i]; $detail = "Reason     : $(Get-FriendlyReason $reason)"
    }
    elseif ($Status -eq 'Postponed') {
        $days = @(30, 60, 90, 180, 365)
        $opts = @($days | ForEach-Object { '{0} days (until {1})' -f $_, (Get-Date).AddDays($_).ToString('yyyy-MM-dd') }) + 'Custom date…'
        $i = Show-RtMenu -Title 'Postpone' -Lines @('Postpone until when? The recommendation becomes Active again afterwards.') -Option $opts -Index 2
        if ($i -lt 0) { return }
        if ($i -lt $days.Count) { $until = (Get-Date).Date.AddDays($days[$i]) }
        else {
            $text = Read-RtLine -Title 'Postpone' -Prompt 'Date (yyyy-MM-dd)' -Default (Get-Date).AddDays(90).ToString('yyyy-MM-dd') -Validate {
                param($v)
                $d = [datetime]::MinValue
                if (-not [datetime]::TryParse($v, [ref]$d)) { return 'Not a valid date.' }
                if ($d.Date -le (Get-Date).Date) { return 'The date must be in the future.' }
            }
            if (-not $text) { return }
            $until = ([datetime]$text).Date
        }
        $detail = "Until      : $($until.ToString('yyyy-MM-dd'))"
    }

    $lines = @(
        "$($Clr.Bold)$($Recommendation.Title)$($Clr.Reset)"
        "$($Clr.Muted)Review: $(@($Recommendation.ReviewName) + @($Recommendation.PSObject.Properties['OtherReviews'] ? $Recommendation.OtherReviews : @()) -join ', ')$($Clr.Reset)"
        ''
        "New status : $($Clr.Bold)$Status$($Clr.Reset)"
    )
    if ($detail) { $lines += $detail }
    $lines += "Resources  : $($targets.Count) will be updated" + $(if ($already) { ", $already already $Status (skipped)" } else { '' })

    # Other loaded recommendations on the same resources with the same type: Azure may change them too.
    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $targets) { $null = $keys.Add(('{0}|{1}' -f $r.ResourceId, $r.RecommendationTypeId)) }
    $own = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Recommendation.Resources) { $null = $own.Add([string]$r.RecommendationArmId) }
    $siblings = @(foreach ($rec in $state.Recommendations) {
        foreach ($r in $rec.Resources) {
            if ($own.Contains([string]$r.RecommendationArmId)) { continue }
            if ($r.RecommendationTypeId -and $keys.Contains(('{0}|{1}' -f $r.ResourceId, $r.RecommendationTypeId))) { $r }
        }
    })
    if ($siblings) {
        $lines += "$($Clr.Warn)Note: $($siblings.Count) other recommendation(s) on the same resource(s) share this recommendation type.$($Clr.Reset)"
        $lines += "$($Clr.Warn)      Azure may change them as well - the tool re-reads and reports them.$($Clr.Reset)"
    }
    $lines += ''
    $lines += "$($Clr.Muted)The update runs in the background - you can keep triaging. Every resource is re-read afterwards, so the result reflects the real status.$($Clr.Reset)"
    if (-not (Read-RtConfirm -Title 'Confirm status change' -Lines $lines -Question "Set $($targets.Count) resource(s) to $Status in Azure Advisor?")) { return }

    try {
        $job = Start-RtStatusUpdateJob -Token (Get-Token) -Recommendation $Recommendation -Resource $targets -Status $Status `
            -DismissReason $reason -PostponedUntil $until -Sibling $siblings -Demo:$Demo
        $state.Jobs.Add($job)
        Add-Notice ("$($Clr.Accent)» Started: {0} · {1} ({2} resource(s))$($Clr.Reset)" -f $Status, (Format-RtCell $Recommendation.Title 48).Trim(), $targets.Count)
    }
    catch {
        Show-RtMessage -Title 'Error' -Lines @("$($Clr.Error)Could not start the update: $($_.Exception.Message)$($Clr.Reset)")
    }
}

function Select-StatusAction {
    <# Status picker for one recommendation: returns 'Postponed', 'Completed', 'Dismissed', 'Details' or $null. #>
    param([object]$Recommendation)
    $r = $Recommendation
    $header = {
        & $banner
        "$($Clr.Bold)$($r.Title)$($Clr.Reset)"
        ("Priority: {0}{1}{2}   Current status: {3}{4}{2}   Resources: {5}" -f (Get-RtPriorityCell $r.Priority), $r.Priority, $Clr.Reset,
            (Get-RtStatusColor $r.Status), $(if ($r.IsMixed) { "$($r.Status) (mixed)" } else { $r.Status }), $r.ResourceCount)
        "Resource status: $(Format-RtCounts $r.StatusCounts)"
        "$($Clr.Muted)Review: $($r.ReviewName)$($Clr.Reset)"
        if ($r.OtherReviews.Count) { "$($Clr.Muted)Also in: $($r.OtherReviews -join ', ') (updated together)$($Clr.Reset)" }
        if (-not $r.ResourcesLoaded) { "$($Clr.Muted)Counts from Resource Graph - the affected resources are loaded when you pick a status or the details.$($Clr.Reset)" }
        ''
        'Change the status of all resources of this recommendation to:'
    }
    $states = @('Completed', 'Postponed', 'Dismissed')
    $opts = @($states | ForEach-Object {
        $n = $r.ResourceCount - [int]$r.StatusCounts.$_
        if ($n) { '{0,-10} ({1:n0} of {2:n0} resource(s) will change)' -f $_, $n, $r.ResourceCount } else { '{0,-10} (current - all resources already {0})' -f $_ }
    }) + 'Show details and impacted resources'
    $i = Show-RtMenu -Title 'Set status' -Header $header -Option $opts -OnTick $onTick
    if ($i -lt 0) { return $null }
    if ($i -lt $states.Count) { return $states[$i] }
    return 'Details'
}

function Invoke-Triage {
    while ($true) {
        # One row per recommendation (duplicates across reviews merged into the most recent review).
        # Critical first, then High, Medium, Low; open work before closed work.
        $statusRank = @{ Active = 0; Postponed = 1; Dismissed = 2; Completed = 3 }
        $views = @(Merge-RtDuplicateRecommendation -Recommendation @($state.Recommendations) -Review @($state.SelectedReviews))
        $items = @($views | Sort-Object PriorityRank, @{ Expression = { $statusRank[$_.Status] } }, @{ Expression = { $_.ResourceCount }; Descending = $true }, Title)
        if (-not $items) { Show-RtMessage -Title 'Triage' -Lines @('The selected reviews have no recommendations.'); return }
        $cols = @(
            @{ Header = 'Priority'; Width = 13; Value = { param($r) "● $($r.Priority)" }; Color = { param($r) Get-RtPriorityCell $r.Priority } }
            @{ Header = 'Status'; Width = 11; Value = { param($r) if ($r.IsMixed) { "$($r.Status)*" } else { $r.Status } }; Color = { param($r) Get-RtStatusColor $r.Status } }
            @{ Header = 'Res.'; Width = 7; Value = { param($r) ('{0:n0}' -f $r.ResourceCount).PadLeft(6) } }
            @{ Header = 'Recommendation'; Flex = 5; Value = { param($r) $r.Title } }
            @{ Header = 'Review'; Flex = 3; Value = { param($r) if ($r.OtherReviews.Count) { "(+$($r.OtherReviews.Count)) $($r.ReviewName)" } else { $r.ReviewName } } }
            @{ Header = 'Description'; Flex = 2; Value = { param($r) $r.Description }; Color = { param($r) Get-RtColor 'Muted' } }
        )

        $pick = Show-RtFilterList -Title "Recommendations ($($items.Count)) - type to search titles" -Item $items -Column $cols -Filter $state.Filter -Index $state.ListIndex `
            -Banner { & $banner; "$(Get-RtColor 'Muted')Enter = change status of all resources   * = resources have different states   (+n) = also in n more review(s), updated together$(Get-RtColor 'Reset')" } -OnTick $onTick `
            -SearchText { param($r) $r.Title }
        if ($null -eq $pick) { $state.Filter = ''; $state.ListIndex = 0; return }
        $state.Filter = $pick.Filter
        $state.ListIndex = $pick.Index

        $action = Select-StatusAction -Recommendation $pick.Item
        if (-not $action) { continue }
        if (-not (Import-Resources -Recommendation @($pick.Item.Members))) { continue }
        # Rebuild the row from the now loaded copies (all reviews).
        $view = @(Merge-RtDuplicateRecommendation -Recommendation @($pick.Item.Members) -Review @($state.SelectedReviews))[0]
        if ($action -eq 'Details') { $action = Show-RtRecommendationDetail -Recommendation $view -Banner $banner -OnTick $onTick }
        if ($action) { Invoke-SetStatus -Recommendation $view -Status $action }
    }
}

function Wait-Jobs {
    <# Waits for running background updates before leaving the tool. #>
    $frames = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'); $f = 0
    while ($state.Jobs.Count) {
        $null = Update-Jobs
        $body = @('', "  $(Get-RtColor 'Accent')$($frames[$f % 10])$(Get-RtColor 'Reset')  Waiting for $($state.Jobs.Count) background update(s) to finish…", '') + @($state.Notices)
        Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines 'Finishing') -Body $body -Footer 'Please wait - updates are being written to Azure Advisor')
        $f++
        Start-Sleep -Milliseconds 150
    }
}

#endregion

#region Main loop

Update-ContextLine
Enter-RtScreen
try {
    Import-Reviews
    if (-not $state.AllReviews.Count) {
        $lines = @(
            "$($Clr.Warn)No Azure Advisor resiliency reviews were found in $($state.Subscriptions.Count) subscription(s).$($Clr.Reset)"
            ''
            'Reviews are published by your Microsoft account team (CSA / CSAM) into a subscription of your tenant.'
            'Make sure you have Reader access on that subscription, or pass it with -SubscriptionId.'
        )
        if ($state.FailedSubs.Count) { $lines += '', "$($Clr.Muted)$($state.FailedSubs.Count) subscription(s) could not be read (e.g. missing permissions).$($Clr.Reset)" }
        Show-RtMessage -Title 'No reviews' -Lines $lines -Footer 'Press any key to exit'
        return
    }
    if (-not (Select-Reviews)) { return }
    Import-Recommendations

    $menu = @(
        'Triage recommendations  (list all, search by title, set Completed / Postponed / Dismissed)'
        'Export all recommendations  (CSV for task planner import)'
        'Export recommendations filtered by priority  (CSV)'
        'Reload data from Azure'
        'Change review selection'
        'Quit'
    )
    $choice = 0
    while ($true) {
        $header = {
            $summary = Get-RtSummary -Recommendation @($state.Recommendations) -Review @($state.SelectedReviews)
            $maxReviews = [Math]::Max((Get-RtSize).Height - 26, 1)
            @(& $banner) + @(Get-RtOverviewLines -Summary $summary -MaxReviews $maxReviews)
        }
        $choice = Show-RtMenu -Title 'Overview' -Header $header -Option $menu -Index ([Math]::Max($choice, 0)) -OnTick $onTick
        switch ($choice) {
            0 { Invoke-Triage }
            1 { Invoke-Export }
            2 { Invoke-Export -ByPriority }
            3 {
                if ($state.Jobs.Count) { Wait-Jobs }
                Import-Reviews
                $state.SelectedReviews = @($state.AllReviews | Where-Object { $_.ReviewId -in $state.SelectedReviews.ReviewId })
                if (-not $state.SelectedReviews.Count -and -not (Select-Reviews)) { return }
                Import-Recommendations
            }
            4 {
                if ($state.Jobs.Count) { Wait-Jobs }
                if (Select-Reviews) { $state.Filter = ''; $state.ListIndex = 0; Import-Recommendations }
            }
            default {
                if ($choice -lt 0 -and -not (Read-RtConfirm -Title 'Quit' -Lines @() -Question 'Quit Resiliency Review Triage?' -Default $true)) { $choice = 0; continue }
                if ($state.Jobs.Count) { Wait-Jobs }
                return
            }
        }
    }
}
catch {
    Write-RtLog "Fatal: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)" -Level ERROR
    throw
}
finally {
    Exit-RtScreen
    # Never leave updates half-way; they are short-lived, so wait for them silently.
    foreach ($t in @($state.Jobs)) { $null = $t.Job | Wait-Job }
    if ($state.Jobs.Count) { $null = Update-Jobs }
    if ($state.History.Count) {
        Write-Host ''
        Write-Host '  Session summary' -ForegroundColor Cyan
        foreach ($h in $state.History) { Write-Host "   $h" }
    }
    Write-RtLog 'Session ended'
    Write-Host ''
    Write-Host "  Activity log: $logFile" -ForegroundColor DarkGray
    Write-Host ''
}

#endregion
