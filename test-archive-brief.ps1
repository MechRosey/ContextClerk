# test-archive-brief.ps1
# Runs 5 monthly archive brief variants against April 2026 sessions from ContextLog.md.
# Writes results to archive-brief-results.md for evaluation.

param([int]$ThrottleLimit = 4)

$claudeExe = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claudeExe) { $claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path $claudeExe)) { Write-Error "claude not found at $claudeExe"; exit 1 }

$logPath = Join-Path $PSScriptRoot 'ContextLog.md'
if (-not (Test-Path $logPath)) { Write-Error "ContextLog.md not found"; exit 1 }

# ---- Extract April 2026 session blocks ----
$lines        = Get-Content $logPath -Encoding UTF8
$targetMonth  = '2026-04'
$inBlock      = $false
$sessionBlocks = [System.Collections.Generic.List[string]]::new()
$currentBlock  = [System.Collections.Generic.List[string]]::new()

foreach ($line in $lines) {
    if ($line -match '^## (\d{4}-\d{2}-\d{2} \d{2}:\d{2})') {
        if ($currentBlock.Count -gt 0 -and $inBlock) {
            $sessionBlocks.Add(($currentBlock -join "`n").TrimEnd())
        }
        $inBlock      = $Matches[1].Substring(0, 7) -eq $targetMonth
        $currentBlock = [System.Collections.Generic.List[string]]::new()
        if ($inBlock) { $currentBlock.Add($line) }
    } elseif ($inBlock) {
        $currentBlock.Add($line)
    }
}
if ($inBlock -and $currentBlock.Count -gt 0) { $sessionBlocks.Add(($currentBlock -join "`n").TrimEnd()) }

$sessionText = $sessionBlocks -join "`n`n"
Write-Output "Extracted $($sessionBlocks.Count) April 2026 blocks ($($sessionText.Length) chars)"

$preamble = @"
You are writing a monthly archive entry for ContextLog.md, a Claude Code session development log.
This archive entry permanently replaces the individual session entries for April 2026.
It will never be summarised again, so preserve the most important context.

The following session entries cover April 2026:
---
$sessionText
---

"@

# ---- 5 prompt variants ----
$variants = @(
    [PSCustomObject]@{
        Name = 'V0-Balanced'
        Desc = 'Opening suggestion: mechanism-preserving compression, 5-8 bullets'
        Suffix = @'
Write 5-8 bullets summarizing the month's significant work.
Each bullet should capture what changed, why it changed, and the mechanism when non-obvious.
Preserve non-obvious constraints, platform quirks, and reasoning that would not be recoverable from reading the code or git history.
Skip routine progress and completions that are obvious from the work description.
If a significant design decision was made, capture the tradeoff and what was chosen.
Rules: plain "- item" bullets only. No markdown headers, bold, italics, or nested structure. ASCII only - no em dashes, curly quotes, or non-ASCII characters.
'@
    },
    [PSCustomObject]@{
        Name = 'V1-Thematic'
        Desc = 'Thematic grouping: identify 2-4 work themes, 1-3 bullets each'
        Suffix = @'
Identify 2-4 distinct work themes or initiatives from this month.
For each theme, write 1-3 bullets covering the key mechanism, decision, or non-obvious insight.
Group related work together even if spread across multiple sessions.
Rules: plain "- item" bullets only. No markdown headers, bold, italics, or nested structure. ASCII only.
'@
    },
    [PSCustomObject]@{
        Name = 'V2-Decisions'
        Desc = 'Decisions + non-obvious fixes only: what is invisible from code/git'
        Suffix = @'
Write only what would be invisible from reading the final code or git history:
decisions made and their rationale, platform quirks discovered, failed approaches that informed the solution, and constraints that forced non-obvious design choices.
Skip work that is obvious from the code or straightforwardly implemented.
3-6 bullets. Rules: plain "- item" bullets only. No markdown headers, bold, italics, or nested structure. ASCII only.
'@
    },
    [PSCustomObject]@{
        Name = 'V3-Arc'
        Desc = 'Chronological arc: problem-to-solution narrative, how understanding evolved'
        Suffix = @'
Capture the arc of this month's work: how understanding evolved, what started wrong and got corrected, what key insight unlocked progress, and where things ended.
Focus on the problem-to-solution narrative rather than listing all tasks completed.
4-7 bullets, loosely chronological. Rules: plain "- item" bullets only. No markdown headers, bold, italics, or nested structure. ASCII only.
'@
    },
    [PSCustomObject]@{
        Name = 'V4-TopInsights'
        Desc = 'Top insights ranked by future utility'
        Suffix = @'
Select the 5-7 most recall-worthy insights from this month's sessions.
An insight is recall-worthy if: knowing it would save significant debugging time on a future similar problem, it documents a non-obvious API, platform, or tool behavior, or it captures a design decision whose reasoning would otherwise be lost.
Rank by future utility, not by how much work they involved.
Rules: plain "- item" bullets only. No markdown headers, bold, italics, or nested structure. ASCII only.
'@
    },
    [PSCustomObject]@{
        Name = 'V5-TwoPart'
        Desc = 'Two-part: Arc (project narrative) + Insights (portable lessons)'
        Suffix = @'
Write two sections. Each point should appear in at most one section.

### Arc
The arc of this month's work: how understanding evolved, what failed and what unlocked progress, key decisions made and why.
Loosely chronological. Focus on the project-specific narrative -- what was attempted, what broke, what was discovered.
Every bullet must answer "what was non-obvious here?" -- if a bullet describes routine cleanup, documentation updates, or work with no decision or surprise, drop it.
Preserve attribution accurately: if the source says the user caught or requested something, it was the agent that made the mistake, not the user.
If the month had no significant decisions or surprises, write nothing here.

### Insights
Portable lessons from this month: non-obvious API, tool, platform, or language behaviours that would help on a different project with a similar problem.
Not "we did X" -- "X is how this class of thing works."
Before writing each Insights bullet, check whether the same mechanism already appears in Arc in any form -- if it does, omit it from Insights entirely.
If nothing portable was learned, write nothing here.

IMPORTANT: ASCII characters only throughout. Do not use em dashes (--), curly quotes, or any non-ASCII character. Use a plain hyphen or comma instead.

Rules for both sections:
- Plain "- item" bullets only
- Do not pad thin sections -- an empty section is better than a vague bullet
- If a section has no bullets, still output the header followed by a blank line

Output exactly these two headers, each followed by bullets or a blank line:
### Arc
### Insights
'@
    }
)

# ---- Run in parallel ----
$pending = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($v in $variants) {
    while (@(Get-Job -State Running).Count -ge $ThrottleLimit) { Start-Sleep -Milliseconds 200 }
    $prompt = $preamble + $v.Suffix
    $job = Start-Job -ScriptBlock {
        param($exe, $promptText)
        ($promptText | & $exe --print --no-session-persistence --model haiku 2>$null) -join "`n"
    } -ArgumentList $claudeExe, $prompt
    $pending.Add([PSCustomObject]@{ job = $job; variant = $v })
    Write-Output "  Started $($v.Name)"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($p in $pending) {
    Wait-Job $p.job | Out-Null
    $out = (Receive-Job $p.job).Trim()
    Remove-Job $p.job
    $results.Add([PSCustomObject]@{ variant = $p.variant; output = $out })
    Write-Output "  Done    $($p.variant.Name)  ($($out.Length) chars)"
}

# ---- Write results file ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Monthly Archive Brief - Test Results")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Input: $($sessionBlocks.Count) April 2026 session blocks, $($sessionText.Length) chars total")
[void]$sb.AppendLine("")

foreach ($r in $results) {
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## $($r.variant.Name)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Brief:** $($r.variant.Desc)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($r.output)
    [void]$sb.AppendLine("")
}

$outPath = Join-Path $PSScriptRoot 'archive-brief-results.md'
Set-Content $outPath $sb.ToString().TrimEnd() -Encoding UTF8
Write-Output ""
Write-Output "Results: $outPath"
