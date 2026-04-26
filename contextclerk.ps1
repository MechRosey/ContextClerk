# ContextClerk - https://github.com/MechRosey/ContextClerk
# Monitors Claude Code session transcripts and appends structured summaries
# to SESSION_LOG.md in each project repo.
#
# Designed to run via Windows Task Scheduler every 5 minutes.
# Requires claude CLI for progress summarisation.

param(
    [switch]$Force,
    [int]$ThrottleLimit = 20
)

$StateFile    = Join-Path $env:USERPROFILE '.claude\contextclerk-state.json'
$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$ToolRepo     = 'https://github.com/MechRosey/ContextClerk'
$claudeExe    = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claudeExe) { $claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }

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

function Get-ConversationText([string[]]$lines) {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $obj) { continue }

        if ($obj.type -eq 'user') {
            $content = $obj.message.content
            $text    = $null
            if ($content -is [string]) {
                $text = $content.Trim()
            } elseif ($content -is [array]) {
                $tb = $content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
                if ($tb) { $text = $tb.text.Trim() }
            }
            if ($text -and $text.Length -gt 3) {
                $parts.Add("User: $($text.Substring(0, [math]::Min(300, $text.Length)))")
            }
        }

        if ($obj.type -eq 'assistant') {
            $content = $obj.message.content
            if ($content -is [array]) {
                $tb = $content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
                if ($tb -and $tb.text.Length -gt 20) {
                    $parts.Add("Claude: $($tb.text.Substring(0, [math]::Min(200, $tb.text.Length)))")
                }
                foreach ($cb in $content) {
                    if ($cb.type -eq 'tool_use' -and $cb.name -eq 'Bash' -and $cb.input.command -match 'git\s+commit') {
                        $cmd = $cb.input.command
                        if ($cmd -match '-m\s+"([^"]{10,})"') {
                            $parts.Add("Committed: $($Matches[1].Trim())")
                        }
                    }
                }
            }
        }
    }
    if ($parts.Count -eq 0) { return $null }
    return $parts -join "`n"
}

function Split-AtCompactions([string[]]$lines) {
    $segments = @()
    $current  = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { $current.Add($line); continue }
        if ($obj -and $obj.type -eq 'system' -and $obj.subtype -eq 'compact_boundary') {
            if ($current.Count -gt 0) {
                $segments += ,($current.ToArray())
                $current = [System.Collections.Generic.List[string]]::new()
            }
        } else {
            $current.Add($line)
        }
    }
    if ($current.Count -gt 0) { $segments += ,($current.ToArray()) }
    return $segments
}

# Builds the full LLM prompt for a file's new content.
# Reads existing log for context before any writes happen.
function Build-Prompt([string]$convText, [string]$logPath) {
    $existingContext = ''
    if ($logPath -and (Test-Path $logPath)) {
        $existingContext = (Get-Content $logPath -Encoding UTF8 | Select-Object -Last 25) -join "`n"
    }
    return @"
You are writing a brief progress entry for SESSION_LOG.md, a Claude Code session development log.

Session log so far (for context only):
---
$existingContext
---

Activity in this session:
---
$convText
---

Write 1-3 short bullet points summarising meaningful technical progress or decisions made.
Focus on what changed or was decided, not on process or navigation.
Rules: use plain "- item" bullets only. No markdown headers, bold, italics, or nested structure.
An empty response is perfectly valid. If nothing significant happened, respond with exactly: (nothing to log)
"@
}

# -----------------------------------------------------------------------

$state     = Load-State
$dirty     = $false
$resetLogs = [System.Collections.Generic.HashSet[string]]::new()

if (-not (Test-Path $ProjectsRoot)) { exit 0 }

$stateAge = if (Test-Path $StateFile) { (Get-Item $StateFile).LastWriteTime } else { [datetime]::MinValue }
$phaseStart = [System.Diagnostics.Stopwatch]::StartNew()

# Phase 1: collect work items - read files, coalesce conversation text, build prompts.
# No LLM calls here so log context is read before any writes.
$workItems = [System.Collections.Generic.List[PSCustomObject]]::new()

$cntTotal     = 0
$cntRecent    = 0
$cntNewLines  = 0
$totalNewLines = 0

$candidateFiles = @(Get-ChildItem $ProjectsRoot -Recurse -Filter '*.jsonl' | Where-Object {
    $_.FullName -notmatch '\\subagents\\'
} | Sort-Object LastWriteTime)

$cntTotal = $candidateFiles.Count

$candidateFiles | ForEach-Object {

    $jsonlPath = $_.FullName

    if ($Force -and $_.LastWriteTime -lt (Get-Date).AddDays(-90)) { return }

    if (-not $Force -and $_.LastWriteTime -le $stateAge) { return }

    $cntRecent++

    $lastLine  = if ($Force) { 0 } elseif ($state.ContainsKey($jsonlPath)) { $state[$jsonlPath] } else { 0 }

    $allLines = @(Get-Content $jsonlPath -Encoding UTF8)
    $total    = $allLines.Count
    if ($total -le $lastLine) { return }

    $cntNewLines++
    $totalNewLines += ($total - $lastLine)

    $newLines = $allLines[$lastLine..($total - 1)]

    $cwd          = $null
    $branch       = $null
    $sessionId    = $null
    $firstTs      = $null
    $sessionTitle = $null
    $filesSet     = [System.Collections.Generic.HashSet[string]]::new()
    $commitsList  = [System.Collections.Generic.List[string]]::new()
    $compactions  = @()

    foreach ($line in $newLines) {
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $obj) { continue }

        if ($obj.cwd      -and -not $cwd)      { $cwd      = $obj.cwd }
        if ($obj.gitBranch)                     { $branch   = $obj.gitBranch }
        if ($obj.sessionId -and -not $sessionId) { $sessionId = $obj.sessionId }
        if ($obj.timestamp -and -not $firstTs)  { $firstTs  = $obj.timestamp }

        $type    = $obj.type
        $subtype = $obj.subtype

        if (($type -eq 'ai-title' -or $type -eq 'custom-title') -and $obj.title) {
            $sessionTitle = $obj.title
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
                        if ($block.name -eq 'Bash' -and $block.input.command -match 'git\s+commit') {
                            $cmd = $block.input.command
                            $msg = $null
                            if ($cmd -match "(?s)<<'EOF'\r?\n(.+?)\r?\n\s*EOF") {
                                $msg = (($Matches[1] -split '\r?\n') | Where-Object { $_.Trim() -and $_ -notmatch '^Co-Authored' } | Select-Object -First 1).Trim()
                            } elseif ($cmd -match '-m\s+"([^"]{10,})"') {
                                $msg = $Matches[1].Trim()
                            }
                            if ($msg -and $msg.Length -ge 10 -and -not $commitsList.Contains($msg)) {
                                $commitsList.Add($msg)
                            }
                        }
                    }
                }
            }
        }
    }

    # Coalesce all segments into a single conversation text (one LLM call per file)
    $segments  = Split-AtCompactions $newLines
    $convParts = [System.Collections.Generic.List[string]]::new()
    foreach ($seg in $segments) {
        $t = Get-ConversationText $seg
        if ($t) { $convParts.Add($t) }
    }
    $combinedConv = if ($convParts.Count -gt 0) { $convParts -join "`n---`n" } else { $null }

    $logPath = if ($cwd) { Join-Path $cwd 'SESSION_LOG.md' } else { $null }
    $prompt  = if ($combinedConv -and $logPath) { Build-Prompt $combinedConv $logPath } else { $null }

    $workItems.Add([PSCustomObject]@{
        jsonlPath    = $jsonlPath
        total        = $total
        cwd          = $cwd
        branch       = $branch
        sessionId    = $sessionId
        firstTs      = $firstTs
        sessionTitle = $sessionTitle
        filesSet     = $filesSet
        commitsList  = $commitsList
        compactions  = $compactions
        prompt       = $prompt
        summary      = $null
    })
}

$phaseStart.Stop()
Write-Output "[ContextClerk] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "  Files found        : $cntTotal"
Write-Output "  Recently changed   : $cntRecent"
Write-Output "  With new lines     : $cntNewLines  (total new lines: $totalNewLines)"
Write-Output "  Work items queued  : $($workItems.Count)  (with LLM prompt: $(@($workItems | Where-Object { $_.prompt }).Count))"
Write-Output "  Phase 1 elapsed    : $([math]::Round($phaseStart.Elapsed.TotalSeconds, 2))s"

# Sort by session start time for chronological log order
$workItems = [System.Collections.Generic.List[PSCustomObject]]($workItems | Sort-Object {
    $dt = $null
    try { $dt = [datetime]::Parse($_.firstTs) } catch {}
    if ($dt) { $dt } else { [datetime]::MinValue }
})

# Phase 2+3: summarise files - direct call for one file, parallel Start-Job for multiple.
if ($claudeExe -and (Test-Path $claudeExe)) {
    $toSummarise = @($workItems | Where-Object { $_.prompt })

    if ($toSummarise.Count -eq 1) {
        $item        = $toSummarise[0]
        $raw         = ($item.prompt | & $claudeExe --print --model haiku 2>$null)
        $result      = ($raw | Where-Object { $_.Trim() -ne '(nothing to log)' }) -join "`n"
        $item.summary = ($result -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*\*\*' }) -join "`n"
        $item.summary = $item.summary.Trim()
    } elseif ($toSummarise.Count -gt 1) {
        $pending = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($item in $toSummarise) {
            while (@(Get-Job -State Running).Count -ge $ThrottleLimit) {
                Start-Sleep -Milliseconds 200
            }

            $job = Start-Job -ScriptBlock {
                param($exe, $promptText)
                $raw    = ($promptText | & $exe --print --no-session-persistence --model haiku 2>$null)
                $result = ($raw | Where-Object { $_.Trim() -ne '(nothing to log)' }) -join "`n"
                $result.Trim()
            } -ArgumentList $claudeExe, $item.prompt

            $pending.Add([PSCustomObject]@{ job = $job; item = $item })
        }

        foreach ($p in $pending) {
            Wait-Job $p.job | Out-Null
            $raw = (Receive-Job $p.job)
            $p.item.summary = (($raw -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*\*\*' }) -join "`n").Trim()
            Remove-Job $p.job
        }
    }
}

# Phase 4: write SESSION_LOG.md entries in file order (preserves per-project sequence)
foreach ($item in $workItems) {
    $hasSummary = -not [string]::IsNullOrWhiteSpace($item.summary)

    if (-not $hasSummary -and $item.filesSet.Count -eq 0 -and $item.commitsList.Count -eq 0 -and $item.compactions.Count -eq 0) {
        $state[$item.jsonlPath] = $item.total
        $dirty = $true
        continue
    }

    $cwd = $item.cwd
    if (-not $cwd -or -not (Test-Path $cwd -PathType Container)) {
        $state[$item.jsonlPath] = $item.total
        $dirty = $true
        continue
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
#   Last 10 commits       : (Select-String "^\s{2}-\s" (Select-String "Commits" .\SESSION_LOG.md -A 20).Line) | Select-Object -Last 10
#   Latest progress notes : (Select-String "^- " .\SESSION_LOG.md).Line | Select-Object -Last 10
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

    $dt         = Parse-Timestamp $item.firstTs
    $dateStr    = if ($dt) { $dt.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
    $shortId    = if ($item.sessionId -and $item.sessionId.Length -ge 8) { $item.sessionId.Substring(0, 8) } else { '?' }
    $branchPart = if ($item.branch -and $item.branch -ne 'HEAD') { " [branch: $($item.branch)]" } else { '' }
    $titlePart  = if ($item.sessionTitle) { " - $($item.sessionTitle)" } else { '' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## $dateStr$branchPart {session: $shortId}$titlePart")

    if ($hasSummary) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Progress')
        [void]$sb.AppendLine($item.summary)
    }

    if ($item.commitsList.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Commits')
        foreach ($c in $item.commitsList) {
            [void]$sb.AppendLine("  - $c")
        }
    }

    if ($item.filesSet.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Files Modified')
        foreach ($f in ($item.filesSet | Sort-Object)) {
            [void]$sb.AppendLine("  - $f")
        }
    }

    if ($item.compactions.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Compactions')
        foreach ($c in $item.compactions) {
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

    $state[$item.jsonlPath] = $item.total
    $dirty = $true
}

if ($dirty) { Save-State $state }
