#Requires -Version 7.2
<#
    ResiliencyTriage.Tui - small dependency-free console UI toolkit.

    Every screen is rendered as a full frame into the alternate screen buffer (ANSI/VT),
    so there is no flicker and the original console content is restored on exit.
    Widgets: menu, checkbox list, live-filter list, detail view, line input, confirm,
    message box and a busy spinner that runs work in a background thread job.
#>

Set-StrictMode -Version Latest
$script:PrevEncoding = $null

$script:E = [char]27
$script:C = @{
    Reset     = "$([char]27)[0m"
    Bold      = "$([char]27)[1m"
    Dim       = "$([char]27)[2m"
    Reverse   = "$([char]27)[7m"
    NoReverse = "$([char]27)[27m"
    Title     = "$([char]27)[1;97;44m"
    Accent    = "$([char]27)[96m"
    Muted     = "$([char]27)[90m"
    Warn      = "$([char]27)[93m"
    Error     = "$([char]27)[91m"
    Ok        = "$([char]27)[92m"
    Critical  = "$([char]27)[1;91m"
    High      = "$([char]27)[38;5;208m"
    Medium    = "$([char]27)[93m"
    Low       = "$([char]27)[96m"
    Info      = "$([char]27)[37m"
    Active    = "$([char]27)[94m"
    Postponed = "$([char]27)[93m"
    Completed = "$([char]27)[92m"
    Dismissed = "$([char]27)[90m"
}
$script:AppTitle = 'Resiliency Review Triage'
$script:ContextLine = ''

#region Primitives

function Get-RtColor { param([string]$Name) if ($script:C.ContainsKey($Name)) { $script:C[$Name] } else { '' } }

function Set-RtContextLine { param([string]$Text) $script:ContextLine = $Text }

function Enter-RtScreen {
    <# Switches to UTF-8 output and the alternate screen buffer, hides the cursor. #>
    $script:PrevEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
    [Console]::Write("$E[?1049h$E[?25l$E[H$E[2J")
    try { [Console]::TreatControlCAsInput = $false } catch { }
}

function Exit-RtScreen {
    [Console]::Write("$E[0m$E[?25h$E[?1049l")
    if ($script:PrevEncoding) { try { [Console]::OutputEncoding = $script:PrevEncoding } catch { } }
}

function Get-RtSize {
    [pscustomobject]@{ Width = [Math]::Max([Console]::WindowWidth, 60); Height = [Math]::Max([Console]::WindowHeight, 15) }
}

function Limit-RtLine {
    <# Truncates a line to $Max visible characters while keeping ANSI sequences intact. #>
    param([string]$Text, [int]$Max)
    if (-not $Text) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    $count = 0; $i = 0
    while ($i -lt $Text.Length) {
        if ($Text[$i] -eq [char]27) {
            $m = [regex]::Match($Text.Substring($i), '^\e\[[0-9;?]*[A-Za-z]')
            if ($m.Success) { $null = $sb.Append($m.Value); $i += $m.Length; continue }
        }
        if ($count -ge $Max) { break }
        $null = $sb.Append($Text[$i]); $count++; $i++
    }
    return $sb.ToString()
}

function Get-RtVisibleLength { param([string]$Text) return ([regex]::Replace([string]$Text, '\e\[[0-9;?]*[A-Za-z]', '')).Length }

function Format-RtCell {
    <# Single-line, fixed-width cell: collapses whitespace, truncates with an ellipsis, pads. #>
    param([object]$Text, [int]$Width)
    if ($Width -le 0) { return '' }
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Width) { return $t.Substring(0, [Math]::Max($Width - 1, 0)) + '…' }
    return $t.PadRight($Width)
}

function Split-RtWrap {
    <# Word-wraps text to $Width, returning at most $MaxLines lines (last one ellipsised). #>
    param([string]$Text, [int]$Width, [int]$MaxLines = 100)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($para in ([string]$Text -split "`r?`n")) {
        $current = ''
        foreach ($word in ($para -split '\s+' | Where-Object { $_ })) {
            while ($word.Length -gt $Width) {
                if ($current) { $lines.Add($current); $current = '' }
                $lines.Add($word.Substring(0, $Width)); $word = $word.Substring($Width)
            }
            if (-not $current) { $current = $word }
            elseif (($current.Length + 1 + $word.Length) -le $Width) { $current += " $word" }
            else { $lines.Add($current); $current = $word }
        }
        if ($current) { $lines.Add($current) }
    }
    if ($lines.Count -gt $MaxLines) {
        $cut = @($lines | Select-Object -First $MaxLines)
        $cut[-1] = (Format-RtCell $cut[-1] ($Width - 1)).TrimEnd() + '…'
        return $cut
    }
    return $lines.ToArray()
}

function Write-RtFrame {
    <# Paints a full frame: every row is clipped to the window width and cleared to the end. #>
    param([string[]]$Lines)
    $size = Get-RtSize
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append("$E[H")
    for ($i = 0; $i -lt $size.Height; $i++) {
        $line = if ($i -lt $Lines.Count) { Limit-RtLine $Lines[$i] ($size.Width - 1) } else { '' }
        $null = $sb.Append($line).Append("$E[0m$E[K")
        if ($i -lt $size.Height - 1) { $null = $sb.Append("`n") }
    }
    [Console]::Write($sb.ToString())
}

function Get-RtTitleLines {
    <# Title bar + context line used by every screen. #>
    param([string]$Title)
    $w = (Get-RtSize).Width - 1
    $text = " $script:AppTitle  ›  $Title"
    @(
        "$($script:C.Title)$(Format-RtCell $text $w)$($script:C.Reset)"
        "$($script:C.Muted) $(Format-RtCell $script:ContextLine ($w - 1))$($script:C.Reset)"
        ''
    )
}

function Get-RtFooterLine {
    param([string]$Text)
    $w = (Get-RtSize).Width - 1
    "$($script:C.Reverse)$(Format-RtCell " $Text" $w)$($script:C.Reset)"
}

function New-RtScreen {
    <# Places body lines between title and footer, padding so the footer sits on the last row. #>
    param([string[]]$Top, [string[]]$Body, [string]$Footer)
    $h = (Get-RtSize).Height
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $Top) { $lines.Add($l) }
    foreach ($l in $Body) { if ($lines.Count -lt $h - 1) { $lines.Add($l) } }
    while ($lines.Count -lt $h - 1) { $lines.Add('') }
    $lines.Add((Get-RtFooterLine $Footer))
    return , $lines.ToArray()
}

function Read-RtKey {
    <#
        Waits for a key. While waiting, $OnTick is invoked every ~150 ms; when it returns $true
        (or the window was resized) $null is returned so the caller can redraw.
    #>
    param([scriptblock]$OnTick)
    $size = Get-RtSize
    while (-not [Console]::KeyAvailable) {
        Start-Sleep -Milliseconds 150
        if ($OnTick -and (& $OnTick)) { return $null }
        $now = Get-RtSize
        if ($now.Width -ne $size.Width -or $now.Height -ne $size.Height) { return $null }
    }
    return [Console]::ReadKey($true)
}

function Test-RtPrintable {
    param([ConsoleKeyInfo]$Key)
    return ($Key.KeyChar -ne [char]0) -and -not [char]::IsControl($Key.KeyChar) -and
        -not ($Key.Modifiers -band [ConsoleModifiers]::Control) -and -not ($Key.Modifiers -band [ConsoleModifiers]::Alt)
}

function Move-RtCursor {
    <# Common list navigation; returns the new index. #>
    param([ConsoleKeyInfo]$Key, [int]$Index, [int]$Count, [int]$Page)
    switch ($Key.Key) {
        'UpArrow'   { return [Math]::Max($Index - 1, 0) }
        'DownArrow' { return [Math]::Min($Index + 1, [Math]::Max($Count - 1, 0)) }
        'PageUp'    { return [Math]::Max($Index - $Page, 0) }
        'PageDown'  { return [Math]::Min($Index + $Page, [Math]::Max($Count - 1, 0)) }
        'Home'      { return 0 }
        'End'       { return [Math]::Max($Count - 1, 0) }
    }
    return $Index
}

function Get-RtScrollTop {
    param([int]$Index, [int]$Top, [int]$Visible)
    if ($Index -lt $Top) { return $Index }
    if ($Index -ge $Top + $Visible) { return $Index - $Visible + 1 }
    return $Top
}

#endregion

#region Columns

function Resolve-RtColumn {
    <#
        Computes widths for column definitions: @{ Header; Width (fixed) | Flex (weight); Value; Color }.
        Flex columns share the remaining space by weight.
    #>
    param([object[]]$Column, [int]$Available)
    $fixed = 0; $flex = 0
    foreach ($c in $Column) { if ($c.ContainsKey('Flex')) { $flex += $c.Flex } else { $fixed += $c.Width } }
    $gaps = $Column.Count - 1
    $rest = [Math]::Max($Available - $fixed - $gaps, 10)
    foreach ($c in $Column) {
        if ($c.ContainsKey('Flex')) { $c['ActualWidth'] = [Math]::Max([Math]::Floor($rest * $c.Flex / [Math]::Max($flex, 1)), 4) }
        else { $c['ActualWidth'] = $c.Width }
    }
    return , $Column
}

function Format-RtHeaderRow {
    param([object[]]$Column)
    ($Column | ForEach-Object { Format-RtCell $_.Header $_.ActualWidth }) -join ' '
}

function Format-RtRow {
    param([object[]]$Column, [object]$Item)
    $cells = foreach ($c in $Column) {
        $text = Format-RtCell (& $c.Value $Item) $c.ActualWidth
        $color = if ($c.ContainsKey('Color') -and $c.Color) { & $c.Color $Item } else { '' }
        if ($color) { "$color$text$($script:C.Reset)" } else { $text }
    }
    return ($cells -join ' ')
}

function Format-RtSelected {
    <# Highlights a row: reverse video, re-applied after inner colour resets. #>
    param([string]$Row, [int]$Width)
    $pad = [Math]::Max($Width - (Get-RtVisibleLength $Row), 0)
    $inner = $Row.Replace($script:C.Reset, "$($script:C.Reset)$($script:C.Reverse)")
    return "$($script:C.Reverse)$inner$(' ' * $pad)$($script:C.Reset)"
}

#endregion

#region Widgets

function Show-RtMessage {
    <# Message box; waits for any key. #>
    param([string]$Title, [string[]]$Lines, [string]$Footer = 'Press any key to continue')
    Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $Lines -Footer $Footer)
    do { $k = Read-RtKey } while ($null -eq $k)
}

function Read-RtConfirm {
    <# Yes/No question; Enter = default. #>
    param([string]$Title, [string[]]$Lines, [string]$Question = 'Continue?', [bool]$Default = $false)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $body = @($Lines) + @('', "$($script:C.Bold)$Question $hint$($script:C.Reset)")
    Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $body -Footer "Y yes   N no   Enter default   Esc cancel")
    while ($true) {
        $k = Read-RtKey
        if ($null -eq $k) { Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $body -Footer 'Y yes   N no   Enter default   Esc cancel'); continue }
        switch ($k.Key) {
            'Y'      { return $true }
            'N'      { return $false }
            'Enter'  { return $Default }
            'Escape' { return $false }
        }
    }
}

function Read-RtLine {
    <# Single-line text input with a default value; returns $null on Esc. #>
    param([string]$Title, [string[]]$Lines, [string]$Prompt = 'Value', [string]$Default = '', [scriptblock]$Validate)
    $text = $Default
    $errorText = ''
    while ($true) {
        $w = (Get-RtSize).Width - 4
        $shown = if ($text.Length -gt $w - $Prompt.Length - 4) { '…' + $text.Substring($text.Length - ($w - $Prompt.Length - 5)) } else { $text }
        $body = @($Lines) + @('', "$($script:C.Bold)$Prompt$($script:C.Reset): $shown$($script:C.Reverse) $($script:C.Reset)")
        if ($errorText) { $body += @('', "$($script:C.Error)$errorText$($script:C.Reset)") }
        Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $body -Footer 'Type to edit   Backspace delete   Ctrl+U clear   Enter accept   Esc cancel')
        $k = Read-RtKey
        if ($null -eq $k) { continue }
        if ($k.Key -eq 'Escape') { return $null }
        if ($k.Key -eq 'Enter') {
            if ($Validate) {
                $errorText = [string](& $Validate $text)
                if ($errorText) { continue }
            }
            return $text
        }
        if ($k.Key -eq 'Backspace') { if ($text.Length) { $text = $text.Substring(0, $text.Length - 1) }; continue }
        if ($k.Key -eq 'U' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { $text = ''; continue }
        if (Test-RtPrintable $k) { $text += $k.KeyChar; $errorText = '' }
    }
}

function Show-RtMenu {
    <#
    .SYNOPSIS
        Vertical menu; returns the chosen index or -1 on Esc.
    .PARAMETER Header
        Scriptblock returning lines rendered above the menu (re-evaluated on every redraw).
    #>
    param(
        [string]$Title,
        [string[]]$Option,
        [scriptblock]$Header,
        [string[]]$Lines,
        [int]$Index = 0,
        [scriptblock]$OnTick
    )
    while ($true) {
        $body = [System.Collections.Generic.List[string]]::new()
        if ($Header) { foreach ($l in @(& $Header)) { $body.Add([string]$l) } }
        foreach ($l in @($Lines)) { if ($null -ne $l) { $body.Add($l) } }
        if ($body.Count) { $body.Add('') }
        $w = (Get-RtSize).Width - 1
        for ($i = 0; $i -lt $Option.Count; $i++) {
            $label = "  {0}. {1}" -f ($i + 1), $Option[$i]
            if ($i -eq $Index) { $body.Add((Format-RtSelected "$($script:C.Bold)› $label$($script:C.Reset)" ([Math]::Min($w, 70)))) }
            else { $body.Add("  $label") }
        }
        Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $body -Footer '↑↓ move   Enter select   1-9 quick select   Esc back')
        $k = Read-RtKey -OnTick $OnTick
        if ($null -eq $k) { continue }
        switch ($k.Key) {
            'Enter'  { return $Index }
            'Escape' { return -1 }
            default {
                $n = 0
                if ([int]::TryParse([string]$k.KeyChar, [ref]$n) -and $n -ge 1 -and $n -le $Option.Count) { return $n - 1 }
                $Index = Move-RtCursor -Key $k -Index $Index -Count $Option.Count -Page 5
            }
        }
    }
}

function Show-RtCheckList {
    <#
    .SYNOPSIS
        Multi-select list with checkboxes. Returns the selected items, or $null on Esc.
    .PARAMETER Column
        Column definitions (see Resolve-RtColumn).
    #>
    param(
        [string]$Title,
        [object[]]$Item,
        [object[]]$Column,
        [string[]]$Lines,
        [int[]]$Preselect = @(),
        [switch]$RequireSelection
    )
    $checked = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in $Preselect) { $null = $checked.Add($p) }
    $index = 0; $top = 0; $notice = ''
    while ($true) {
        $size = Get-RtSize
        $cols = Resolve-RtColumn -Column $Column -Available ($size.Width - 7)
        $body = [System.Collections.Generic.List[string]]::new()
        foreach ($l in @($Lines)) { if ($null -ne $l) { $body.Add($l) } }
        $body.Add("$($script:C.Muted)      $(Format-RtHeaderRow $cols)$($script:C.Reset)")
        $visible = [Math]::Max($size.Height - 5 - $body.Count - 2, 3)
        $top = Get-RtScrollTop -Index $index -Top $top -Visible $visible
        for ($i = $top; $i -lt [Math]::Min($top + $visible, $Item.Count); $i++) {
            $box = if ($checked.Contains($i)) { "$($script:C.Ok)[x]$($script:C.Reset)" } else { '[ ]' }
            $row = "  $box $(Format-RtRow $cols $Item[$i])"
            $body.Add(($i -eq $index) ? (Format-RtSelected $row ($size.Width - 1)) : $row)
        }
        if ($Item.Count -gt $visible) { $body.Add("$($script:C.Muted)  … showing $($top + 1)-$([Math]::Min($top + $visible, $Item.Count)) of $($Item.Count)$($script:C.Reset)") }
        if ($notice) { $body.Add(''); $body.Add("$($script:C.Warn)$notice$($script:C.Reset)") }
        $footer = "↑↓ move   Space toggle   A all/none   Enter continue   Esc back      $($checked.Count) of $($Item.Count) selected"
        Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $body -Footer $footer)

        $k = Read-RtKey
        if ($null -eq $k) { continue }
        $notice = ''
        switch ($k.Key) {
            'Spacebar' { if (-not $checked.Remove($index)) { $null = $checked.Add($index) }; $index = [Math]::Min($index + 1, $Item.Count - 1) }
            'A' {
                if ($checked.Count -eq $Item.Count) { $checked.Clear() }
                else { for ($i = 0; $i -lt $Item.Count; $i++) { $null = $checked.Add($i) } }
            }
            'Enter' {
                if ($checked.Count -eq 0 -and $RequireSelection) { $notice = 'Select at least one entry with Space (or A for all).'; continue }
                return , @($checked | Sort-Object | ForEach-Object { $Item[$_] })
            }
            'Escape' { return $null }
            default { $index = Move-RtCursor -Key $k -Index $index -Count $Item.Count -Page $visible }
        }
    }
}

function Show-RtFilterList {
    <#
    .SYNOPSIS
        Single-select list with live type-to-filter search.
    .DESCRIPTION
        Every typed character narrows the list; all space separated terms must match the
        text returned by $SearchText. Returns @{ Item; Filter } or $null on Esc.
    .PARAMETER Banner
        Scriptblock returning notification lines (re-evaluated on every redraw).
    .PARAMETER OnTick
        Invoked while idle; return $true to force a redraw (e.g. a background job finished).
    #>
    param(
        [string]$Title,
        [object[]]$Item,
        [object[]]$Column,
        [scriptblock]$SearchText,
        [string]$Filter = '',
        [scriptblock]$Banner,
        [scriptblock]$OnTick,
        [int]$Index = 0
    )
    # Pre-compute the searchable text once.
    $haystack = @{}
    for ($i = 0; $i -lt $Item.Count; $i++) { $haystack[$i] = ([string](& $SearchText $Item[$i])).ToLowerInvariant() }
    $top = 0
    while ($true) {
        $terms = @($Filter.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
        $matchIdx = @(for ($i = 0; $i -lt $Item.Count; $i++) {
            $ok = $true
            foreach ($t in $terms) { if (-not $haystack[$i].Contains($t)) { $ok = $false; break } }
            if ($ok) { $i }
        })
        $index = [Math]::Min($index, [Math]::Max($matchIdx.Count - 1, 0))

        $size = Get-RtSize
        $cols = Resolve-RtColumn -Column $Column -Available ($size.Width - 3)
        $body = [System.Collections.Generic.List[string]]::new()
        if ($Banner) { foreach ($l in @(& $Banner)) { if ($l) { $body.Add([string]$l) } } }
        $body.Add("$($script:C.Bold)Search:$($script:C.Reset) $Filter$($script:C.Reverse) $($script:C.Reset)   $($script:C.Muted)$($matchIdx.Count) of $($Item.Count) recommendations$($script:C.Reset)")
        $body.Add('')
        $body.Add("$($script:C.Muted)  $(Format-RtHeaderRow $cols)$($script:C.Reset)")
        $visible = [Math]::Max($size.Height - 4 - $body.Count - 2, 3)
        $top = Get-RtScrollTop -Index $index -Top $top -Visible $visible
        if ($matchIdx.Count -eq 0) { $body.Add("$($script:C.Warn)  No recommendation matches '$Filter'.$($script:C.Reset)") }
        for ($j = $top; $j -lt [Math]::Min($top + $visible, $matchIdx.Count); $j++) {
            $row = "  $(Format-RtRow $cols $Item[$matchIdx[$j]])"
            $body.Add(($j -eq $index) ? (Format-RtSelected $row ($size.Width - 1)) : $row)
        }
        if ($matchIdx.Count -gt $visible) { $body.Add("$($script:C.Muted)  … showing $($top + 1)-$([Math]::Min($top + $visible, $matchIdx.Count)) of $($matchIdx.Count)$($script:C.Reset)") }
        Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $body -Footer 'Type to filter   ↑↓ PgUp PgDn move   Enter select   Backspace delete   Esc clear / back')

        $k = Read-RtKey -OnTick $OnTick
        if ($null -eq $k) { continue }
        switch ($k.Key) {
            'Enter' {
                if ($matchIdx.Count) { return [pscustomobject]@{ Item = $Item[$matchIdx[$index]]; Filter = $Filter; Index = $index } }
            }
            'Escape' { if ($Filter) { $Filter = ''; $index = 0 } else { return $null } }
            'Backspace' { if ($Filter.Length) { $Filter = $Filter.Substring(0, $Filter.Length - 1); $index = 0 } }
            { $_ -in 'UpArrow', 'DownArrow', 'PageUp', 'PageDown', 'Home', 'End' } {
                $index = Move-RtCursor -Key $k -Index $index -Count $matchIdx.Count -Page $visible
            }
            default {
                if (Test-RtPrintable $k) { $Filter += $k.KeyChar; $index = 0; $top = 0 }
            }
        }
    }
}

function Invoke-RtBusy {
    <#
    .SYNOPSIS
        Runs a script block in a thread job while showing a spinner; returns its output.
    .PARAMETER ModulePath
        Modules imported inside the job before the script block runs.
    #>
    param(
        [string]$Title,
        [string]$Message,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [string[]]$ModulePath = @()
    )
    $job = Start-ThreadJob -ScriptBlock {
        param($Modules, $Code, $ArgList)
        foreach ($m in $Modules) { Import-Module $m -Force }
        & ([scriptblock]::Create($Code)) @ArgList
    } -ArgumentList @($ModulePath), $ScriptBlock.ToString(), @($ArgumentList)

    $frames = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $f = 0
    try {
        while ($job.State -in 'NotStarted', 'Running') {
            $body = @('', "  $($script:C.Accent)$($frames[$f % $frames.Count])$($script:C.Reset)  $Message  $($script:C.Muted)($([int]$sw.Elapsed.TotalSeconds)s)$($script:C.Reset)")
            Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines $Title) -Body $body -Footer 'Working… please wait')
            $f++
            Start-Sleep -Milliseconds 120
        }
        return Receive-Job -Job $job -Wait -ErrorAction Stop
    }
    finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}

#endregion

#region Domain renderers

function Get-RtPriorityCell {
    param([string]$Priority)
    $color = switch ($Priority) { 'Critical' { $script:C.Critical } 'High' { $script:C.High } 'Medium' { $script:C.Medium } 'Low' { $script:C.Low } default { $script:C.Info } }
    return $color
}

function Get-RtStatusColor { param([string]$Status) Get-RtColor $Status }

function Get-RtStatusBar {
    <# Stacked bar: Completed / Dismissed / Postponed / Active. #>
    param([object]$Counts, [int]$Width)
    $total = [int]$Counts.Active + [int]$Counts.Postponed + [int]$Counts.Completed + [int]$Counts.Dismissed
    if ($total -eq 0) { return "$($script:C.Muted)$('░' * $Width)$($script:C.Reset)" }
    $sb = [System.Text.StringBuilder]::new(); $used = 0
    $order = @('Completed', 'Dismissed', 'Postponed', 'Active')
    for ($i = 0; $i -lt $order.Count; $i++) {
        $n = [int]$Counts.($order[$i])
        $len = if ($i -eq $order.Count - 1) { $Width - $used } else { [Math]::Round($n / $total * $Width) }
        $len = [Math]::Max([Math]::Min($len, $Width - $used), 0)
        $char = if ($order[$i] -eq 'Active') { '░' } else { '█' }
        if ($len) { $null = $sb.Append("$(Get-RtColor $order[$i])$($char * $len)$($script:C.Reset)") }
        $used += $len
    }
    return $sb.ToString()
}

function Format-RtCounts {
    param([object]$Counts)
    "{0}Active {1}{2}  {3}Postponed {4}{2}  {5}Completed {6}{2}  {7}Dismissed {8}{2}" -f `
        $script:C.Active, $Counts.Active, $script:C.Reset, $script:C.Postponed, $Counts.Postponed, $script:C.Completed, $Counts.Completed, $script:C.Dismissed, $Counts.Dismissed
}

function Get-RtOverviewLines {
    <# Progress overview (all selected reviews + one line per review). #>
    param([Parameter(Mandatory)][object]$Summary, [int]$MaxReviews = 8)
    $w = (Get-RtSize).Width - 1
    $barWidth = [Math]::Max([Math]::Min($w - 60, 50), 12)
    $o = $Summary.Overall
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$($script:C.Bold)Overall progress$($script:C.Reset)  $($script:C.Muted)(done = no longer Active: postponed, completed or dismissed)$($script:C.Reset)")
    $lines.Add("  $(Get-RtStatusBar $o.Recommendations $barWidth)  $($script:C.Bold)$($o.PercentDone)%$($script:C.Reset) done")
    $lines.Add("  Recommendations $($o.Total.ToString().PadLeft(4))   $(Format-RtCounts $o.Recommendations)")
    $lines.Add("  Resources       $($o.ResourceTotal.ToString().PadLeft(4))   $(Format-RtCounts $o.Resources)")
    if ($o.Expected -and $o.Expected -ne $o.Total) {
        $lines.Add("  $($script:C.Muted)Reviews announce $($o.Expected) recommendation(s); $($o.Total) were found linked to Advisor recommendations.$($script:C.Reset)")
    }
    $lines.Add('')
    $lines.Add("$($script:C.Bold)Per review$($script:C.Reset)")
    $nameWidth = [Math]::Max([Math]::Min($w - $barWidth - 52, 40), 16)
    $shown = 0
    foreach ($r in $Summary.PerReview) {
        if ($shown -ge $MaxReviews) { $lines.Add("  $($script:C.Muted)… $($Summary.PerReview.Count - $shown) more review(s)$($script:C.Reset)"); break }
        $rc = $r.Recommendations
        $lines.Add(("  {0} {1} {2,3}%  {3}{4,3} active{5} {6}{7,3} postp.{5} {8}{9,3} compl.{5} {10}{11,3} dism.{5}" -f `
            (Format-RtCell $r.Name $nameWidth), (Get-RtStatusBar $rc $barWidth), $r.PercentDone,
            $script:C.Active, $rc.Active, $script:C.Reset, $script:C.Postponed, $rc.Postponed, $script:C.Completed, $rc.Completed, $script:C.Dismissed, $rc.Dismissed))
        $shown++
    }
    $lines.Add("  $($script:C.Completed)█$($script:C.Reset) Completed  $($script:C.Dismissed)█$($script:C.Reset) Dismissed  $($script:C.Postponed)█$($script:C.Reset) Postponed  $($script:C.Active)░$($script:C.Reset) Active (not started / in progress)")
    return $lines.ToArray()
}

function Show-RtRecommendationDetail {
    <#
    .SYNOPSIS
        Detail view of one review recommendation. Returns 'Postponed', 'Completed', 'Dismissed' or $null.
    #>
    param([Parameter(Mandatory)][object]$Recommendation, [scriptblock]$Banner, [scriptblock]$OnTick)
    $r = $Recommendation
    $resIndex = 0; $resTop = 0
    $resources = @($r.Resources | Sort-Object @{ Expression = { @('Active', 'Postponed', 'Dismissed', 'Completed').IndexOf($_.Status) } }, ResourceName)
    while ($true) {
        $size = Get-RtSize
        $w = $size.Width - 3
        $body = [System.Collections.Generic.List[string]]::new()
        if ($Banner) { foreach ($l in @(& $Banner)) { if ($l) { $body.Add([string]$l) } } }
        foreach ($l in (Split-RtWrap $r.Title $w 2)) { $body.Add("$($script:C.Bold)$l$($script:C.Reset)") }
        $statusText = if ($r.IsMixed) { "$($r.Status) (mixed)" } else { $r.Status }
        $body.Add(("Priority: {0}{1}{2}   Status: {3}{4}{2}   Resources: {5}   Category: {6}" -f `
            (Get-RtPriorityCell $r.Priority), $r.Priority, $script:C.Reset, (Get-RtStatusColor $r.Status), $statusText, $r.Resources.Count, $r.Category))
        $body.Add("$($script:C.Muted)Review: $($r.ReviewName)   Workload: $($r.WorkloadName)$($script:C.Reset)")
        $others = if ($r.PSObject.Properties['OtherReviews']) { @($r.OtherReviews) } else { @() }
        if ($others.Count) { $body.Add("$($script:C.Muted)Also in: $($others -join ', ') (status changes apply to all)$($script:C.Reset)") }
        $body.Add("Resource status: $(Format-RtCounts $r.StatusCounts)")
        $body.Add('')
        $section = {
            param($label, $text, $max)
            if (-not $text) { return }
            $wrapped = @(Split-RtWrap $text ($w - 2) $max)
            $body.Add("$($script:C.Accent)$label$($script:C.Reset)")
            foreach ($l in $wrapped) { $body.Add("  $l") }
        }
        & $section 'Description' $r.Description 4
        & $section 'Potential benefits' $r.PotentialBenefits 2
        & $section 'Account team notes' $r.Notes 3
        if ($r.LearnMoreLink) { $body.Add("$($script:C.Accent)Learn more$($script:C.Reset)  $($r.LearnMoreLink)") }
        $body.Add('')
        $body.Add("$($script:C.Bold)Impacted resources$($script:C.Reset)")
        $cols = Resolve-RtColumn -Available ($size.Width - 4) -Column @(
            @{ Header = 'Status'; Width = 10; Value = { param($x) $x.Status }; Color = { param($x) Get-RtStatusColor $x.Status } }
            @{ Header = 'Resource'; Flex = 3; Value = { param($x) $x.ResourceName } }
            @{ Header = 'Type'; Flex = 3; Value = { param($x) $x.ResourceType } }
            @{ Header = 'Resource group'; Flex = 2; Value = { param($x) $x.ResourceGroup } }
            @{ Header = 'Subscription'; Width = 36; Value = { param($x) $x.SubscriptionId } }
            @{ Header = 'Review'; Flex = 2; Value = { param($x) if ($x.PSObject.Properties['ReviewName']) { $x.ReviewName } else { '' } } }
        )
        $body.Add("$($script:C.Muted)  $(Format-RtHeaderRow $cols)$($script:C.Reset)")
        $visible = [Math]::Max($size.Height - 4 - $body.Count - 2, 2)
        $resTop = Get-RtScrollTop -Index $resIndex -Top $resTop -Visible $visible
        for ($i = $resTop; $i -lt [Math]::Min($resTop + $visible, $resources.Count); $i++) {
            $row = "  $(Format-RtRow $cols $resources[$i])"
            $body.Add(($i -eq $resIndex) ? (Format-RtSelected $row ($size.Width - 1)) : $row)
        }
        if ($resources.Count -gt $visible) { $body.Add("$($script:C.Muted)  … $($resTop + 1)-$([Math]::Min($resTop + $visible, $resources.Count)) of $($resources.Count) (↑↓ to scroll)$($script:C.Reset)") }

        Write-RtFrame (New-RtScreen -Top (Get-RtTitleLines 'Recommendation') -Body $body -Footer 'Set status for all resources:  P Postponed   C Completed   D Dismiss        ↑↓ scroll   Esc back')
        $k = Read-RtKey -OnTick $OnTick
        if ($null -eq $k) { continue }
        switch ($k.Key) {
            'P' { return 'Postponed' }
            'C' { return 'Completed' }
            'D' { return 'Dismissed' }
            'Escape' { return $null }
            'Backspace' { return $null }
            default { $resIndex = Move-RtCursor -Key $k -Index $resIndex -Count $resources.Count -Page $visible }
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-RtColor', 'Set-RtContextLine', 'Enter-RtScreen', 'Exit-RtScreen', 'Get-RtSize', 'Limit-RtLine', 'Get-RtVisibleLength',
    'Format-RtCell', 'Split-RtWrap', 'Write-RtFrame', 'Get-RtTitleLines', 'New-RtScreen', 'Read-RtKey',
    'Resolve-RtColumn', 'Format-RtRow', 'Format-RtHeaderRow',
    'Show-RtMessage', 'Read-RtConfirm', 'Read-RtLine', 'Show-RtMenu', 'Show-RtCheckList', 'Show-RtFilterList', 'Invoke-RtBusy',
    'Get-RtPriorityCell', 'Get-RtStatusColor', 'Get-RtStatusBar', 'Format-RtCounts', 'Get-RtOverviewLines',
    'Show-RtRecommendationDetail'
)
