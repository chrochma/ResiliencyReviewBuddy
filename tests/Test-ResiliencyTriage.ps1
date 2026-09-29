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

Write-Host 'TUI helpers' -ForegroundColor Cyan
$ansi = "$([char]27)[91mHello$([char]27)[0m World"
Assert-That ((Get-RtVisibleLength (Limit-RtLine $ansi 7)) -eq 7) 'Limit-RtLine keeps visible width'
Assert-That ((Format-RtCell 'abcdefgh' 5) -eq 'abcd…') 'Format-RtCell truncates'
Assert-That ((Format-RtCell 'ab' 4) -eq 'ab  ') 'Format-RtCell pads'
$wrap = Split-RtWrap 'one two three four five six seven' 10 2
Assert-That ($wrap.Count -eq 2 -and $wrap[-1].EndsWith('…')) 'Split-RtWrap limits lines'

Write-Host ''
if ($script:failures) { Write-Host "$($script:failures) test(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed.' -ForegroundColor Green
