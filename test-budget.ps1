<#
.SYNOPSIS
    Compare ContextClerk Haiku summarisation quality at multiple charBudget sizes.
    Extracts convText at each budget from one compaction segment of a session JSONL,
    runs Haiku in parallel, and prints results for manual evaluation.

.PARAMETER JsonlPath
    Path to a Claude Code session JSONL file.

.PARAMETER LogPath
    Optional path to an existing ContextLog.md to supply as prior-context to the prompt.

.PARAMETER Budgets
    Array of charBudget values to test. Default: 1000, 2000, 4000, 8000.

.PARAMETER SegmentIndex
    Which compaction segment to use. Default -1 = last (most recent) segment.
    Pass -2 to use the largest segment by line count.
#>
param(
    [Parameter(Mandatory)][string]$JsonlPath,
    [string]$LogPath      = '',
    [int[]] $Budgets      = @(1000, 2000, 4000, 8000),
    [int]   $SegmentIndex = -1
)

Set-StrictMode -Version Latest

$claudeExe = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claudeExe) { $claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path $claudeExe)) { Write-Error "claude CLI not found"; exit 1 }

# Per-block cap = budget/2; scales so longer budgets allow longer individual
# Claude explanations rather than just more short ones.
function Get-ConversationText([string[]]$lines, [int]$charBudget) {
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

                foreach ($block in ($content | Where-Object { $_.type -eq 'tool_result' })) {
                    $resultText = $null
                    if ($block.content -is [string]) { $resultText = $block.content }
                    elseif ($block.content -is [array]) {
                        $rt = $block.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
                        if ($rt) { $resultText = $rt.text }
                    }
                    if (-not $resultText) { continue }
                    foreach ($rline in ($resultText -split '\r?\n')) {
                        $rline = $rline.Trim()
                        if ($rline -match '(Passed|Failed)!.*Failed:\s+\d+.*Passed:\s+\d+') {
                            $parts.Add("Tests: $($rline.Substring(0, [math]::Min(150, $rline.Length)))"); break
                        }
                        if ($rline -match '^Build (succeeded|FAILED)') {
                            $parts.Add("Build: $rline"); break
                        }
                        if ($rline -match 'error [A-Z]+\d+:') {
                            $parts.Add("Error: $($rline.Substring(0, [math]::Min(200, $rline.Length)))"); break
                        }
                    }
                }
            }
            # Skip compaction summaries and injected skill/system reminders - not signal for the LLM
            if ($text -and $text.Length -gt 3 `
                    -and $text -notmatch '^This session is being continued' `
                    -and $text -notmatch '^# ' `
                    -and $text -notmatch '^<system-reminder>') {
                $parts.Add("User: $($text.Substring(0, [math]::Min(300, $text.Length)))")
            }
        }

        if ($obj.type -eq 'assistant') {
            $content = $obj.message.content
            if ($content -is [array]) {
                $charUsed    = 0
                $perBlockCap = [math]::Max(200, [int]($charBudget / 2))
                foreach ($tb in ($content | Where-Object { $_.type -eq 'text' -and $_.text.Length -gt 20 })) {
                    $avail    = $charBudget - $charUsed
                    if ($avail -le 0) { break }
                    $maxBlock = [math]::Min($perBlockCap, $avail)
                    if ($tb.text.Length -le $maxBlock) {
                        $snippet = $tb.text
                    } else {
                        $tailLen = [math]::Min(500, [int]($maxBlock * 0.3))
                        $headLen = $maxBlock - $tailLen - 5
                        $snippet = if ($headLen -gt 0) {
                            $tb.text.Substring(0, $headLen) + ' ... ' + $tb.text.Substring($tb.text.Length - $tailLen)
                        } else {
                            $tb.text.Substring(0, $maxBlock)
                        }
                    }
                    $parts.Add("Claude: $snippet")
                    $charUsed += $snippet.Length
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

function Build-Prompt([string]$convText, [string]$logPath) {
    $existingContext = ''
    if ($logPath -and (Test-Path $logPath)) {
        $existingContext = (Get-Content $logPath -Encoding UTF8 | Select-Object -Last 25) -join "`n"
    }
    return @"
You are writing a brief progress entry for ContextLog.md, a Claude Code session development log.

Session log so far (for context only):
---
$existingContext
---

Activity in this session:
---
$convText
---

Write as many bullets as the session warrants (typically 2-5 for an active session). Each bullet can be as long as needed to capture the root cause fully.
Code and git diffs record what changed; ContextLog should capture what the code cannot show - the hidden constraint, API quirk, platform behaviour, or reasoning that forced this specific approach.
For each bullet: state what changed, why it changed, and the mechanism when non-obvious (e.g. "fixed pixel corruption - GDI+ LockBits returns full-row stride regardless of locked region width, so using region.Width * bpp as stride silently zeroed every pixel").
If Claude tried multiple failing approaches before finding the working solution (e.g. wrong path, missing tool, incorrect invocation), note the successful approach explicitly so it can be recalled without repeating the search (e.g. "msbuild found at X - not on PATH by default").
Prefer insights and decisions that would not be obvious from reading the code or git diff. Skip test counts and build results unless the outcome was unexpected, or the passing tests confirmed that a non-obvious refactor was safe.
If the session ended mid-task or left something incomplete, add one final line starting with "Next:" describing what was interrupted or planned next.
Rules: use plain "- item" bullets only. No markdown headers, bold, italics, or nested structure. ASCII only - no em dashes, curly quotes, or any non-ASCII characters.
An empty response is perfectly valid. If nothing significant happened, respond with exactly: (nothing to log)
"@
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

# --- Main ---

Write-Host "Reading $JsonlPath ..."
$lines    = Get-Content $JsonlPath -Encoding UTF8
Write-Host "$($lines.Count) lines read."

$segments = Split-AtCompactions $lines
Write-Host "$($segments.Count) compaction segment(s) found."

$idx = if ($SegmentIndex -eq -2) {
    $maxLen = 0; $maxIdx = 0
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ($segments[$i].Count -gt $maxLen) { $maxLen = $segments[$i].Count; $maxIdx = $i }
    }
    $maxIdx
} elseif ($SegmentIndex -lt 0) {
    $segments.Count - 1
} else {
    [math]::Min($SegmentIndex, $segments.Count - 1)
}

$seg = $segments[$idx]
Write-Host "Using segment $idx of $($segments.Count - 1) ($($seg.Count) lines)`n"

# Build runs: extract convText and prompt at each budget
$runs = foreach ($budget in $Budgets) {
    $ct     = Get-ConversationText $seg $budget
    $prompt = if ($ct) { Build-Prompt $ct $LogPath } else { $null }
    [PSCustomObject]@{
        Budget   = $budget
        ConvText = $ct
        ConvLen  = if ($ct) { $ct.Length } else { 0 }
        Prompt   = $prompt
        Output   = $null
    }
}

# Haiku calls in parallel
$pending = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($run in $runs) {
    if (-not $run.Prompt) { $run.Output = '(no convText extracted)'; continue }
    $job = Start-Job -ScriptBlock {
        param($exe, $promptText)
        ($promptText | & $exe --print --no-session-persistence --model haiku 2>$null) -join "`n"
    } -ArgumentList $claudeExe, $run.Prompt
    $pending.Add([PSCustomObject]@{ Run = $run; Job = $job })
}

if ($pending.Count -gt 0) {
    Write-Host "Waiting for $($pending.Count) Haiku call(s)..."
    $pending | ForEach-Object { $_.Job | Wait-Job | Out-Null }
    foreach ($p in $pending) {
        $p.Run.Output = ($p.Job | Receive-Job).Trim()
        $p.Job | Remove-Job
    }
}

# Display results
Write-Host ""
$sep = '=' * 70
foreach ($run in $runs) {
    Write-Host $sep
    Write-Host "BUDGET: $($run.Budget) chars  |  convText extracted: $($run.ConvLen) chars"
    Write-Host $sep
    if ($run.ConvText) {
        Write-Host ""
        Write-Host "--- convText ---"
        Write-Host $run.ConvText
    }
    Write-Host ""
    Write-Host "--- Haiku output ---"
    Write-Host $run.Output
    Write-Host ""
}
