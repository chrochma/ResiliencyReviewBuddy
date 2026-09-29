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
    [switch]$Demo
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
$ctx = $null
if ($Demo) {
    Write-Host '  Demo mode: fictional data, no Azure calls.' -ForegroundColor Yellow
    $ctx = [pscustomobject]@{ Account = 'demo@contoso.com'; TenantId = '00000000-0000-0000-0000-000000000000'; SubscriptionName = 'demo'; SubscriptionId = '' }
}
else {
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

#endregion

#region State and helpers

$state = [pscustomobject]@{
    Context         = $ctx
    Subscriptions   = @()
    AllReviews      = @()
    FailedSubs      = @()
    SelectedReviews = @()
    Recommendations = @()
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
        @{ Header = 'Published'; Width = 10; Value = { param($r) if ($r.PublishedAt) { ([datetime]$r.PublishedAt).ToString('yyyy-MM-dd') } else { '' } } }
        @{ Header = 'Subscription'; Flex = 2; Value = { param($r) if ($r.SubscriptionName) { $r.SubscriptionName } else { $r.SubscriptionId } } }
    )
    $intro = @(
        "Found $($Clr.Bold)$($state.AllReviews.Count)$($Clr.Reset) resiliency review(s) in $($state.Subscriptions.Count) subscription(s). Select the reviews to work with:"
        ''
    )
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
    if ($Demo) {
        $raw = $state.DemoData.Raw
        $reviews = $state.SelectedReviews
        $state.Recommendations = @(Invoke-RtBusy -Title 'Loading' -Message 'Loading review recommendations (demo)…' -ModulePath $azModule `
            -ArgumentList $raw, $reviews -ScriptBlock {
                param($Raw, $Reviews)
                Start-Sleep -Milliseconds 600
                ConvertTo-RtRecommendation -RawRecommendation $Raw -Review $Reviews
            })
        return
    }
    $scan = @($state.Subscriptions.SubscriptionId)
    $state.Recommendations = @(Invoke-RtBusy -Title 'Loading' -Message "Loading recommendations of $($state.SelectedReviews.Count) review(s)…" -ModulePath $azModule `
        -ArgumentList (Get-Token), $state.SelectedReviews, $scan -ScriptBlock {
            param($Token, $Reviews, $Scan)
            Get-RtReviewRecommendation -Token $Token -Review $Reviews -ScanSubscription $Scan
        })
}

function Get-FriendlyReason { param([string]$Reason) ($Reason -creplace '([a-z])([A-Z])', '$1 $2') }

function Add-Notice {
    param([string]$Text)
    $state.Notices.Insert(0, $Text)
    while ($state.Notices.Count -gt 4) { $state.Notices.RemoveAt($state.Notices.Count - 1) }
    $state.History.Add(([regex]::Replace($Text, '\e\[[0-9;?]*[A-Za-z]', '')))
}

function Update-Jobs {
    <# Collects finished background updates, applies them locally and reports. Returns $true on change. #>
    $changed = $false
    foreach ($t in @($state.Jobs)) {
        if ($t.Job.State -in 'NotStarted', 'Running') { continue }
        $results = @()
        $jobError = ''
        try { $results = @(Receive-Job -Job $t.Job -ErrorAction Stop) } catch { $jobError = $_.Exception.Message }
        Remove-Job -Job $t.Job -Force -ErrorAction SilentlyContinue
        $null = $state.Jobs.Remove($t)
        $changed = $true

        $ok = @($results | Where-Object Success)
        $failed = @($results | Where-Object { -not $_.Success })
        # Apply the new status locally for every resource that was updated in Azure.
        $okIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($o in $ok) { $null = $okIds.Add([string]$o.RecommendationArmId) }
        foreach ($res in $t.Recommendation.Resources) {
            if ($okIds.Contains([string]$res.RecommendationArmId)) { $res.Status = ConvertTo-RtStatusBucket $t.Status; $res.RawStatus = $t.Status }
        }
        Update-RtRecommendationStatus -Recommendation $t.Recommendation

        $title = Format-RtCell $t.Recommendation.Title 48
        if ($jobError) {
            Add-Notice "$($Clr.Error)✗ $($t.Status) · $($title.Trim()) : background job failed - $jobError$($Clr.Reset)"
            continue
        }
        $logHint = ''
        if ($failed.Count) {
            $logDir = Join-Path $ExportPath 'logs'
            $null = New-Item -ItemType Directory -Path $logDir -Force
            $log = Join-Path $logDir ('failed-{0}-{1}.csv' -f $t.Status, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $failed | Select-Object ResourceName, RecommendationArmId, Message | Export-Csv -Path $log -NoTypeInformation -Encoding utf8BOM
            $logHint = "  $($Clr.Muted)(details: $log)$($Clr.Reset)"
        }
        $color = if ($failed.Count) { $Clr.Warn } else { $Clr.Ok }
        Add-Notice ("{0}✓ {1} · {2} : {3} resource(s) updated, {4} failed/skipped{5}{6}" -f $color, $t.Status, $title.Trim(), $ok.Count, $failed.Count, $Clr.Reset, $logHint)
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
    $running = @($state.Jobs | Where-Object { $_.Recommendation -eq $Recommendation })
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
        "$($Clr.Muted)$($Recommendation.ReviewName)$($Clr.Reset)"
        ''
        "New status : $($Clr.Bold)$Status$($Clr.Reset)"
    )
    if ($detail) { $lines += $detail }
    $lines += "Resources  : $($targets.Count) will be updated" + $(if ($already) { ", $already already $Status (skipped)" } else { '' })
    $lines += ''
    $lines += "$($Clr.Muted)The update runs in the background - you can keep triaging. Resources that no longer exist are skipped and reported.$($Clr.Reset)"
    if (-not (Read-RtConfirm -Title 'Confirm status change' -Lines $lines -Question "Set $($targets.Count) resource(s) to $Status in Azure Advisor?")) { return }

    try {
        $job = Start-RtStatusUpdateJob -Token (Get-Token) -Recommendation $Recommendation -Resource $targets -Status $Status `
            -DismissReason $reason -PostponedUntil $until -Demo:$Demo
        $state.Jobs.Add($job)
        Add-Notice ("$($Clr.Accent)» Started: {0} · {1} ({2} resource(s))$($Clr.Reset)" -f $Status, (Format-RtCell $Recommendation.Title 48).Trim(), $targets.Count)
    }
    catch {
        Show-RtMessage -Title 'Error' -Lines @("$($Clr.Error)Could not start the update: $($_.Exception.Message)$($Clr.Reset)")
    }
}

function Invoke-Triage {
    $multiReview = $state.SelectedReviews.Count -gt 1
    while ($true) {
        # Critical first, then High, Medium, Low; open work before closed work.
        $statusRank = @{ Active = 0; Postponed = 1; Dismissed = 2; Completed = 3 }
        $items = @($state.Recommendations | Sort-Object PriorityRank, @{ Expression = { $statusRank[$_.Status] } }, @{ Expression = { $_.Resources.Count }; Descending = $true }, Title)
        if (-not $items) { Show-RtMessage -Title 'Triage' -Lines @('The selected reviews have no recommendations.'); return }
        $cols = @(
            @{ Header = 'Priority'; Width = 13; Value = { param($r) "● $($r.Priority)" }; Color = { param($r) Get-RtPriorityCell $r.Priority } }
            @{ Header = 'Status'; Width = 11; Value = { param($r) if ($r.IsMixed) { "$($r.Status)*" } else { $r.Status } }; Color = { param($r) Get-RtStatusColor $r.Status } }
            @{ Header = 'Res.'; Width = 5; Value = { param($r) $r.Resources.Count.ToString().PadLeft(4) } }
            @{ Header = 'Recommendation'; Flex = 4; Value = { param($r) $r.Title } }
            @{ Header = 'Description'; Flex = 3; Value = { param($r) $r.Description }; Color = { param($r) Get-RtColor 'Muted' } }
        )
        if ($multiReview) { $cols += @{ Header = 'Review'; Flex = 2; Value = { param($r) $r.ReviewName } } }

        $pick = Show-RtFilterList -Title 'Triage recommendations' -Item $items -Column $cols -Filter $state.Filter -Index $state.ListIndex `
            -Banner { & $banner; "$(Get-RtColor 'Muted')* = resources of this recommendation have different states$(Get-RtColor 'Reset')" } -OnTick $onTick `
            -SearchText { param($r) '{0} {1} {2} {3} {4} {5}' -f $r.Title, $r.Description, $r.Priority, $r.Status, $r.ReviewName, $r.WorkloadName }
        if ($null -eq $pick) { $state.Filter = ''; $state.ListIndex = 0; return }
        $state.Filter = $pick.Filter
        $state.ListIndex = $pick.Index

        $action = Show-RtRecommendationDetail -Recommendation $pick.Item -Banner $banner -OnTick $onTick
        if ($action) { Invoke-SetStatus -Recommendation $pick.Item -Status $action }
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
        'Triage recommendations  (search, open, set Postponed / Completed / Dismissed)'
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
    Write-Host ''
}

#endregion
