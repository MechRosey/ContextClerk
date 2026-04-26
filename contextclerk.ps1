# ContextClerk - https://github.com/MechRosey/ContextClerk
# Monitors Claude Code session transcripts and appends structured summaries
# to SESSION_LOG.md in each project repo.
#
# Designed to run via Windows Task Scheduler every 5 minutes.
# Zero dependencies. No AI calls. Read-only access to transcript files.

param(
    [switch]$Force
)

$StateFile    = Join-Path $env:USERPROFILE '.claude\contextclerk-state.json'
$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$ToolRepo     = 'https://github.com/MechRosey/ContextClerk'

function Load-State {
    if (-not (Test-Path $StateFile)) { return @{} }
    $raw = Get-Content $StateFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return @{} }
    if ($null -eq $obj) { return @{} }
    $ht  = @{}
    $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = [int]$_.Value.lastLine }
    return $ht
}

function Save-State([hashtable]$st) {
    $inner = @{}
    foreach ($k in $st.Keys) { $inner[$k] = @{ lastLine = $st[$k] } }
    $inner | ConvertTo-Json -Depth 2 | Set-Content $StateFile -Encoding UTF8
}

function Format-Tokens([object]$n) {
    if ($null -eq $n) { return '?' }
    $i = [int]$n
    if ($i -ge 1000) { return "$([math]::Round($i / 1000, 1))K" }
    return "$i"
}

function Parse-Timestamp([string]$ts) {
    $dt = $null
    try { $dt = [datetime]::Parse($ts).ToLocalTime() } catch {}
    return $dt
}

# -----------------------------------------------------------------------

$state     = Load-State
$dirty     = $false
$resetLogs = [System.Collections.Generic.HashSet[string]]::new()

if (-not (Test-Path $ProjectsRoot)) { exit 0 }

Get-ChildItem $ProjectsRoot -Recurse -Filter '*.jsonl' | Where-Object {
    $_.FullName -notmatch '\\subagents\\'
} | Sort-Object LastWriteTime | ForEach-Object {

    $jsonlPath = $_.FullName
    $lastLine  = if ($Force) { 0 } elseif ($state.ContainsKey($jsonlPath)) { $state[$jsonlPath] } else { 0 }

    $allLines = @(Get-Content $jsonlPath -Encoding UTF8)
    $total    = $allLines.Count
    if ($total -le $lastLine) { return }

    $newLines = $allLines[$lastLine..($total - 1)]

    $cwd         = $null
    $branch      = $null
    $sessionId   = $null
    $firstTs     = $null
    $summaries   = @()
    $filesSet    = [System.Collections.Generic.HashSet[string]]::new()
    $compactions = @()

    foreach ($line in $newLines) {
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $obj) { continue }

        if ($obj.cwd       -and -not $cwd)       { $cwd       = $obj.cwd }
        if ($obj.gitBranch)                       { $branch    = $obj.gitBranch } # last value wins; want current branch at end of session
        if ($obj.sessionId -and -not $sessionId)  { $sessionId = $obj.sessionId }
        if ($obj.timestamp -and -not $firstTs)    { $firstTs   = $obj.timestamp }

        $type    = $obj.type
        $subtype = $obj.subtype

        if ($type -eq 'system' -and $subtype -eq 'away_summary' -and $obj.content) {
            $text = $obj.content -replace '\s*\(disable recaps in /config\)\s*$', ''
            $summaries += [PSCustomObject]@{ ts = $obj.timestamp; content = $text }
        }

        if ($type -eq 'system' -and $subtype -eq 'compact_boundary' -and $obj.compactMetadata) {
            $meta        = $obj.compactMetadata
            $compactions += [PSCustomObject]@{
                ts         = $obj.timestamp
                trigger    = $meta.trigger
                preTokens  = $meta.preTokens
                postTokens = $meta.postTokens
            }
        }

        if ($type -eq 'assistant') {
            $content = $obj.message.content
            if ($content -is [array]) {
                foreach ($block in $content) {
                    if ($block.type -eq 'tool_use') {
                        if (($block.name -eq 'Write' -or $block.name -eq 'Edit' -or $block.name -eq 'MultiEdit') -and
                            $block.input.file_path) {
                            [void]$filesSet.Add($block.input.file_path)
                        }
                        if ($block.name -eq 'NotebookEdit' -and $block.input.notebook_path) {
                            [void]$filesSet.Add($block.input.notebook_path)
                        }
                    }
                }
            }
        }
    }

    # Nothing worth logging
    if ($summaries.Count -eq 0 -and $filesSet.Count -eq 0 -and $compactions.Count -eq 0) {
        $state[$jsonlPath] = $total
        $dirty = $true
        return
    }

    if (-not $cwd -or -not (Test-Path $cwd -PathType Container)) {
        $state[$jsonlPath] = $total
        $dirty = $true
        return
    }

    $logPath    = Join-Path $cwd 'SESSION_LOG.md'
    $logExists  = Test-Path $logPath
    $firstWrite = -not $logExists -or ($Force -and -not $resetLogs.Contains($logPath))

    if ($firstWrite) {
        $header = @"
# SESSION LOG
# Generated by: ContextClerk ($ToolRepo)
# Project: $cwd
#
# Quick reference for Claude:
#   Last 10 files touched : (Select-String "^\s{2}-\s" .\SESSION_LOG.md).Line | Select-Object -Last 10
#   Latest progress notes : (Select-String "^- \d\d:\d\d" .\SESSION_LOG.md).Line | Select-Object -Last 5
#   Compaction points     : Select-String "^\- \d\d:\d\d .* tokens" .\SESSION_LOG.md
#   Work on a branch      : Select-String "\[branch: dev\]" .\SESSION_LOG.md -A 20

"@
        Set-Content $logPath $header -Encoding UTF8
        if ($Force) { [void]$resetLogs.Add($logPath) }

        if (-not $logExists) {
            $gitignore = Join-Path $cwd '.gitignore'
            if (Test-Path $gitignore) {
                $existing = Get-Content $gitignore -Raw -Encoding UTF8
                if ($existing -notmatch 'SESSION_LOG') {
                    Add-Content $gitignore "`nSESSION_LOG.md" -Encoding UTF8
                }
            } else {
                Set-Content $gitignore 'SESSION_LOG.md' -Encoding UTF8
            }
        }
    }

    $dt       = Parse-Timestamp $firstTs
    $dateStr  = if ($dt) { $dt.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
    $shortId  = if ($sessionId -and $sessionId.Length -ge 8) { $sessionId.Substring(0, 8) } else { '?' }
    $branchPart = if ($branch -and $branch -ne 'HEAD') { " [branch: $branch]" } else { '' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## $dateStr$branchPart {session: $shortId}")

    if ($summaries.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Progress')
        foreach ($s in $summaries) {
            $t    = Parse-Timestamp $s.ts
            $time = if ($t) { $t.ToString('HH:mm') } else { '??' }
            [void]$sb.AppendLine("- $time $($s.content)")
        }
    }

    if ($filesSet.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Files Modified')
        foreach ($f in ($filesSet | Sort-Object)) {
            [void]$sb.AppendLine("  - $f")
        }
    }

    if ($compactions.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Compactions')
        foreach ($c in $compactions) {
            $t    = Parse-Timestamp $c.ts
            $time = if ($t) { $t.ToString('HH:mm') } else { '??' }
            $pre  = Format-Tokens $c.preTokens
            if ($c.postTokens) {
                $post = Format-Tokens $c.postTokens
                [void]$sb.AppendLine("- $time $($c.trigger) ($pre -> $post tokens)")
            } else {
                [void]$sb.AppendLine("- $time $($c.trigger) ($pre tokens)")
            }
        }
    }

    Add-Content $logPath $sb.ToString() -Encoding UTF8

    $state[$jsonlPath] = $total
    $dirty = $true
}

if ($dirty) { Save-State $state }
