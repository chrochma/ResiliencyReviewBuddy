#Requires -Version 7.2
<#
.SYNOPSIS
    Offline smoke tests for Resiliency Review Triage (demo data, no Azure calls).
.EXAMPLE
    .\tests\Test-ResiliencyTriage.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules\ResiliencyTriage.Azure.psm1') -Force
Import-Module (Join-Path $root 'modules\ResiliencyTriage.Tui.psm1') -Force

$script:failures = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failures++ }
}

Write-Host 'Syntax' -ForegroundColor Cyan
foreach ($f in Get-ChildItem $root -Recurse -Include *.ps1, *.psm1) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    Assert-That (-not $errors) "parses: $($f.Name)"
}

Write-Host 'Status mapping' -ForegroundColor Cyan
Assert-That ((ConvertTo-RtStatusBucket 'New') -eq 'Active') 'New -> Active'
Assert-That ((ConvertTo-RtStatusBucket 'Pending') -eq 'Active') 'Pending -> Active'
Assert-That ((ConvertTo-RtStatusBucket 'Approved') -eq 'Active') 'Approved -> Active'
Assert-That ((ConvertTo-RtStatusBucket 'Rejected') -eq 'Dismissed') 'Rejected -> Dismissed'
Assert-That ((ConvertTo-RtStatusBucket 'Postponed') -eq 'Postponed') 'Postponed stays'
Assert-That ((ConvertTo-RtStatusBucket 'Completed') -eq 'Completed') 'Completed stays'

Write-Host 'Grouping and summary' -ForegroundColor Cyan
$demo = New-RtDemoData
$recs = @(ConvertTo-RtRecommendation -RawRecommendation $demo.Raw -Review $demo.Reviews)
$resourceTotal = ($recs | ForEach-Object { $_.Resources.Count } | Measure-Object -Sum).Sum
Assert-That ($recs.Count -eq 30) "30 review recommendations grouped (got $($recs.Count))"
Assert-That ($resourceTotal -eq $demo.Raw.Count) 'every raw recommendation is assigned to one group'
Assert-That ($recs[0].Priority -eq 'Critical') 'sorted with Critical first'
$ranks = @($recs.PriorityRank)
Assert-That ((@($ranks | Sort-Object) -join ',') -eq ($ranks -join ',')) 'sorted by priority rank'

$summary = Get-RtSummary -Recommendation $recs -Review $demo.Reviews
$o = $summary.Overall
Assert-That (($o.Recommendations.Active + $o.Recommendations.Postponed + $o.Recommendations.Completed + $o.Recommendations.Dismissed) -eq $o.Total) 'recommendation buckets add up'
Assert-That ($o.ResourceTotal -eq $resourceTotal) 'resource buckets add up'
Assert-That ($summary.PerReview.Count -eq 3) 'one summary per review'

# Review matching by name only (review.id missing) must still work.
$byName = $demo.Raw[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$byName.properties.review = [pscustomobject]@{ name = $demo.Reviews[0].ReviewName }
Assert-That (@(ConvertTo-RtRecommendation -RawRecommendation @($byName) -Review $demo.Reviews).Count -eq 1) 'review matched by name'

Write-Host 'Mixed status aggregation' -ForegroundColor Cyan
$rec = $recs | Where-Object { $_.Resources.Count -ge 2 } | Select-Object -First 1
$rec.Resources[0].Status = 'Completed'; $rec.Resources[1].Status = 'Dismissed'
foreach ($r in @($rec.Resources | Select-Object -Skip 2)) { $r.Status = 'Completed' }
Update-RtRecommendationStatus -Recommendation $rec
Assert-That ($rec.IsMixed -and $rec.Status -eq 'Dismissed') 'Completed + Dismissed -> mixed, Dismissed'
foreach ($r in $rec.Resources) { $r.Status = 'Completed' }
Update-RtRecommendationStatus -Recommendation $rec
Assert-That ((-not $rec.IsMixed) -and $rec.Status -eq 'Completed') 'all Completed -> Completed'

Write-Host 'Duplicates across reviews' -ForegroundColor Cyan
$views = @(Merge-RtDuplicateRecommendation -Recommendation $recs -Review $demo.Reviews)
$titles = @($recs.Title | Sort-Object -Unique)
Assert-That ($views.Count -eq $titles.Count) "one row per title ($($views.Count))"
$vm = $views | Where-Object Title -eq 'Deploy VMs across Availability Zones'
Assert-That ($vm.ReviewName -eq 'WARA - Contoso Web Shop') 'shown for the most recent review'
Assert-That ($vm.OtherReviews.Count -eq 2) 'other reviews listed'
$expectedRes = ($recs | Where-Object Title -eq $vm.Title | ForEach-Object { $_.Resources.Count } | Measure-Object -Sum).Sum
Assert-That ($vm.Resources.Count -eq $expectedRes) 'resources of all reviews included (status applies to all)'
Assert-That (@($views | Where-Object { $_.Resources.Count -eq 0 }).Count -eq 0) 'no empty rows'

Write-Host 'Summary first, resources on demand' -ForegroundColor Cyan
# Resource Graph summary rows (one per recommendation and raw status) built from the demo data.
$countRows = foreach ($rec in $recs) {
    foreach ($g in ($rec.Resources | Group-Object Status)) {
        [pscustomobject]@{ rid = "/subscriptions/x/providers/Microsoft.Advisor/resiliencyReviews/$($rec.ReviewId)"; rname = $rec.ReviewName; typeId = $rec.RecommendationTypeId; label = $rec.Label; groupKey = $rec.Label; pri = $rec.Priority; st = $g.Name; n = $g.Count }
    }
}
$textRows = foreach ($rec in $recs) {
    [pscustomobject]@{ rid = "/subscriptions/x/providers/Microsoft.Advisor/resiliencyReviews/$($rec.ReviewId)"; rname = $rec.ReviewName; typeId = $rec.RecommendationTypeId; label = $rec.Label; groupKey = $rec.Label; pri = $rec.Priority; description = $rec.Description; priority = $rec.Priority; problem = ''; solution = ''; benefits = ''; notes = ''; link = ''; category = $rec.Category }
}
$sum = @(ConvertFrom-RtSummaryRow -CountRow @($countRows) -TextRow @($textRows) -Review $demo.Reviews)
Assert-That ($sum.Count -eq $recs.Count) "summary: one recommendation per group ($($sum.Count))"
$bad = @($sum | Where-Object { $k = $_.Key; $full = $recs | Where-Object Key -eq $k; -not $full -or $full.ResourceCount -ne $_.ResourceCount -or $full.Status -ne $_.Status -or $full.Priority -ne $_.Priority })
Assert-That ($bad.Count -eq 0) 'summary keys, counts, status and priority match the resource-level data'
Assert-That (@($sum | Where-Object ResourcesLoaded).Count -eq 0) 'summary has no resources loaded'
# Same label twice in one review with different priorities -> two recommendations (portal shows both).
$r0 = $recs[0]; $rid0 = "/subscriptions/x/providers/Microsoft.Advisor/resiliencyReviews/$($r0.ReviewId)"
$twin = @(
    [pscustomobject]@{ rid = $rid0; rname = $r0.ReviewName; typeId = 't'; label = 'Same title'; groupKey = 'Same title'; pri = 'Critical'; st = 'New'; n = 16 }
    [pscustomobject]@{ rid = $rid0; rname = $r0.ReviewName; typeId = 't'; label = 'Same title'; groupKey = 'Same title'; pri = 'High'; st = 'Completed'; n = 14 }
)
$twinRecs = @(ConvertFrom-RtSummaryRow -CountRow $twin -Review $demo.Reviews)
Assert-That ($twinRecs.Count -eq 2 -and ($twinRecs | Where-Object Priority -eq 'Critical').Status -eq 'Active') 'same label with different priority stays separate'
Assert-That (@(Merge-RtDuplicateRecommendation -Recommendation $twinRecs -Review $demo.Reviews).Count -eq 2) 'triage view keeps both priorities'
# Detail view with exactly one other review (single string must not break .Count under StrictMode).
& (Get-Module ResiliencyTriage.Tui) {
    function script:Read-RtKey { param($OnTick) [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27; Modifiers = 0 } }
    function script:Write-RtFrame { param($Frame) }
    function script:Get-RtSize { [pscustomobject]@{ Width = 160; Height = 45 } }
}
$detail = @(Merge-RtDuplicateRecommendation -Recommendation @($twinRecs[0]) -Review $demo.Reviews)[0]
$detail.OtherReviews = @('Other review')
$ok = $true; try { $null = Show-RtRecommendationDetail -Recommendation $detail } catch { $ok = $false }
Assert-That $ok 'detail view works with exactly one other review'
Import-Module (Join-Path $root 'modules\ResiliencyTriage.Tui.psm1') -Force
$sumOverall = (Get-RtSummary -Recommendation $sum -Review $demo.Reviews).Overall
Assert-That ($sumOverall.ResourceTotal -eq $resourceTotal) 'overview counts work without resources'
$sumViews = @(Merge-RtDuplicateRecommendation -Recommendation $sum -Review $demo.Reviews)
$sv = $sumViews | Where-Object Title -eq 'Deploy VMs across Availability Zones'
Assert-That ($sv.ResourceCount -eq $vm.ResourceCount -and -not $sv.ResourcesLoaded -and $sv.Status -eq $vm.Status) 'merged row sums the counts of all reviews'
Set-RtRecommendationResource -Target $sum -Loaded @($recs | Where-Object Title -eq $sv.Title) -Requested @($sv.Members)
$sv2 = @(Merge-RtDuplicateRecommendation -Recommendation @($sv.Members) -Review $demo.Reviews)[0]
Assert-That ($sv2.ResourcesLoaded -and $sv2.Resources.Count -eq $sv.ResourceCount) 'resources loaded on demand for all copies'
Assert-That (@($sum | Where-Object ResourcesLoaded).Count -eq $sv.Members.Count) 'only the requested recommendation was loaded'
$gone = $sum | Where-Object { -not $_.ResourcesLoaded } | Select-Object -First 1
Set-RtRecommendationResource -Target $sum -Loaded @() -Requested @($gone)
Assert-That ($gone.ResourcesLoaded -and $gone.ResourceCount -eq 0) 'requested but nothing found -> loaded, 0 resources'
$csv2 = Join-Path ([IO.Path]::GetTempPath()) ("rt-test-{0}.csv" -f [guid]::NewGuid().ToString('N'))
try {
    $null = Export-RtRecommendation -Recommendation @($sum | Where-Object { -not $_.ResourcesLoaded } | Select-Object -First 3) -Path $csv2
    $row = @(Import-Csv $csv2)[0]
    Assert-That ([int]$row.ImpactedResourceCount -gt 0 -and -not $row.ImpactedResources) 'export of summary rows: counts without resource IDs'
}
finally { Remove-Item $csv2 -ErrorAction SilentlyContinue }
Write-Host 'Export' -ForegroundColor Cyan
$csv = Join-Path ([IO.Path]::GetTempPath()) ("rt-test-{0}.csv" -f [guid]::NewGuid().ToString('N'))
try {
    $all = Export-RtRecommendation -Recommendation $recs -Path $csv
    Assert-That ($all.Count -eq $recs.Count) 'export all'
    $filtered = Export-RtRecommendation -Recommendation $recs -Path $csv -Priority Critical, High -Status Active
    $rows = @(Import-Csv $csv)
    Assert-That ($filtered.Count -eq $rows.Count -and $rows.Count -gt 0) "export filtered ($($rows.Count) rows)"
    Assert-That (-not ($rows | Where-Object { $_.Priority -notin 'Critical', 'High' -or $_.Status -ne 'Active' })) 'filter respected'
    Assert-That ($rows[0].PSObject.Properties.Name -contains 'TaskName') 'task planner columns present'
}
finally { Remove-Item $csv -ErrorAction SilentlyContinue }

Write-Host 'Background status update (demo)' -ForegroundColor Cyan
$target = $recs | Where-Object { $_.Resources.ResourceName -match 'deleted' } | Select-Object -First 1
$expectedFail = @($target.Resources | Where-Object ResourceName -match 'deleted').Count
$tracker = Start-RtStatusUpdateJob -Recommendation $target -Resource $target.Resources -Status Dismissed -DismissReason RiskIsAcceptable -Demo
$results = @($tracker.Job | Wait-Job -Timeout 60 | Receive-Job)
Remove-Job $tracker.Job -Force
Assert-That ($results.Count -eq $target.Resources.Count) 'one result per resource'
Assert-That (@($results | Where-Object { -not $_.Success }).Count -eq $expectedFail) "deleted resources reported as failed ($expectedFail)"
Assert-That (@($results | Where-Object Success).Count -eq ($target.Resources.Count - $expectedFail)) 'remaining resources succeeded'
Assert-That (-not ($results | Where-Object { $_.Kind -ne 'Target' })) 'no sibling results without siblings'

$sib = @($recs | Where-Object { $_ -ne $target } | Select-Object -First 1 | ForEach-Object { $_.Resources[0] })
$tracker = Start-RtStatusUpdateJob -Recommendation $target -Resource $target.Resources[0] -Status Completed -Sibling $sib -Demo
$results = @($tracker.Job | Wait-Job -Timeout 60 | Receive-Job)
Remove-Job $tracker.Job -Force
Assert-That (@($results | Where-Object Kind -eq 'Sibling').Count -eq 1) 'sibling re-read reported'

Write-Host 'Update verification' -ForegroundColor Cyan
$o = Get-RtUpdateOutcome -Target Completed -ActualStatus Completed -PatchError 'HTTP 404 PATCH : '
Assert-That ($o.Success -and $o.Verified) 'PATCH 404 but status Completed -> success (verified)'
$o = Get-RtUpdateOutcome -Target Completed -ActualStatus Completed
Assert-That ($o.Success -and $o.Verified) 'PATCH ok + status Completed -> success'
$o = Get-RtUpdateOutcome -Target Dismissed -ActualStatus Rejected -PatchError 'HTTP 409'
Assert-That ($o.Success) 'legacy Rejected counts as Dismissed'
$o = Get-RtUpdateOutcome -Target Completed -ActualStatus '' -PatchError 'HTTP 404 PATCH : ' -ReadError 'HTTP 404 GET : '
Assert-That (-not $o.Success -and $o.Message -match 'no longer exists') 'deleted resource -> failed'
$o = Get-RtUpdateOutcome -Target Completed -ActualStatus New -PatchError 'HTTP 403 PATCH : '
Assert-That (-not $o.Success) 'PATCH 403 and status unchanged -> failed'
$o = Get-RtUpdateOutcome -Target Completed -ActualStatus '' -ReadError 'timeout'
Assert-That ($o.Success -and -not $o.Verified) 'PATCH ok but re-read failed -> success, unverified'

Write-Host 'Resource Graph enrichment' -ForegroundColor Cyan
$arm = [pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st1/providers/Microsoft.Advisor/recommendations/abc'; name = 'abc'
    properties = [pscustomobject]@{ recommendationStatus = 'Completed'; recommendationTypeId = 't'; review = [pscustomobject]@{ id = $demo.Reviews[0].ReviewId; name = 'x' }
        shortDescription = [pscustomobject]@{ problem = 'CX Observer Personalized Recommendation' } } }
$graph = @(
    [pscustomobject]@{ name = 'ABC'; subscriptionId = 's'; properties = [pscustomobject]@{ label = 'Ensure ZRS'; description = 'desc'; recommendationStatus = 'New' } }
    [pscustomobject]@{ name = 'only-graph'; id = '/subscriptions/s/providers/Microsoft.Advisor/recommendations/only-graph'; subscriptionId = 's'; properties = [pscustomobject]@{ label = 'Other'; recommendationStatus = 'New'; review = [pscustomobject]@{ id = $demo.Reviews[0].ReviewId } } }
)
$merged = @(Merge-RtRecommendationSource -Arm @($arm) -Graph $graph)
Assert-That ($merged.Count -eq 2) 'ARM + Graph-only rows merged'
Assert-That ($merged[0].properties.label -eq 'Ensure ZRS' -and $merged[0].properties.recommendationStatus -eq 'Completed') 'label from Graph, status from ARM'
$g = @(ConvertTo-RtRecommendation -RawRecommendation $merged -Review $demo.Reviews)
Assert-That ($g.Count -eq 2 -and ($g.Title -contains 'Ensure ZRS')) 'enriched titles used for grouping'
$noLabel = @($arm, ($arm | ConvertTo-Json -Depth 10 | ConvertFrom-Json)); $noLabel[1].name = 'def'
foreach ($x in $noLabel) { $x.properties.PSObject.Properties.Remove('label'); $x.properties.PSObject.Properties.Remove('description') }
Assert-That (@(ConvertTo-RtRecommendation -RawRecommendation $noLabel -Review $demo.Reviews).Count -eq 2) 'untitled items are never merged'
Assert-That ((Get-RtResourceTypeFromId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st1') -eq 'Microsoft.Storage/storageAccounts') 'resource type from ID'
Assert-That ((Get-RtResourceTypeFromId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Sql/servers/sq/databases/db') -eq 'Microsoft.Sql/servers/databases') 'nested resource type from ID'

Write-Host 'Legacy duplicate objects' -ForegroundColor Cyan
$rev = [pscustomobject]@{ id = $demo.Reviews[0].ReviewId }
$vnet = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vn1'
$current = [pscustomobject]@{ id = "$vnet/providers/Microsoft.Advisor/recommendations/hash1"; name = 'hash1'
    properties = [pscustomobject]@{ label = 'Flow logs'; recommendationTypeId = 't'; recommendationStatus = 'Completed'; review = $rev; resourceMetadata = [pscustomobject]@{ resourceId = $vnet } } }
$legacy = [pscustomobject]@{ id = "$vnet/providers/Microsoft.Advisor/recommendations/0000-guid"; name = '0000-guid'
    properties = [pscustomobject]@{ label = 'Flow logs'; recommendationTypeId = 't'; review = $rev; resourceMetadata = $null; trackedProperties = [pscustomobject]@{ state = 'Completed' } } }
$l = @(ConvertTo-RtRecommendation -RawRecommendation @($legacy, $current) -Review $demo.Reviews)
Assert-That ($l.Count -eq 1 -and $l[0].Resources.Count -eq 1) 'legacy + current object on one resource counted once'
Assert-That ($l[0].Resources[0].RecommendationName -eq 'hash1' -and $l[0].Status -eq 'Completed') 'current object preferred'
$lo = @(ConvertTo-RtRecommendation -RawRecommendation @($legacy) -Review $demo.Reviews)
Assert-That ($lo[0].Status -eq 'Completed') 'legacy-only status from trackedProperties.state'

Write-Host 'TUI helpers' -ForegroundColor Cyan
$ansi = "$([char]27)[91mHello$([char]27)[0m World"
Assert-That ((Get-RtVisibleLength (Limit-RtLine $ansi 7)) -eq 7) 'Limit-RtLine keeps visible width'
Assert-That ((Format-RtCell 'abcdefgh' 5) -eq 'abcd…') 'Format-RtCell truncates'
Assert-That ((Format-RtCell 'ab' 4) -eq 'ab  ') 'Format-RtCell pads'
$wrap = Split-RtWrap 'one two three four five six seven' 10 2
Assert-That ($wrap.Count -eq 2 -and $wrap[-1].EndsWith('…')) 'Split-RtWrap limits lines'

Write-Host 'Proxy' -ForegroundColor Cyan
$px = Set-RtProxy -Proxy 'http://127.0.0.1:3128'
Assert-That ($px -and $px.Port -eq 3128) 'explicit proxy used for ARM'
Assert-That ([System.Net.Http.HttpClient]::DefaultProxy.Credentials -eq [System.Net.CredentialCache]::DefaultNetworkCredentials) 'proxy authenticates with the Windows user'
$null = Set-RtProxy -Proxy 'http://127.0.0.1:3128' -Credential ([pscredential]::new('bob', (ConvertTo-SecureString 'pw' -AsPlainText -Force)))
Assert-That ([System.Net.Http.HttpClient]::DefaultProxy.Credentials.UserName -eq 'bob') 'explicit proxy credential'

Write-Host ''
if ($script:failures) { Write-Host "$($script:failures) test(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed.' -ForegroundColor Green
