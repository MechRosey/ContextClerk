# ContextClerk

Persistent session memory for Claude Code on Windows.

ContextClerk runs every five minutes via Windows Task Scheduler. It reads Claude Code
session transcripts, calls the Claude CLI to write a structured progress summary, and
appends that summary to ContextLog.md in each project repo. At the start of your next
session, Claude reads the log and picks up where you left off.

## Requirements

- Windows 10/11
- Claude Code installed and on PATH as `claude`
- PowerShell 5.1+

## Install

The easiest way is to hand setup to Claude Code. Clone the repo, then paste the block
below into a Claude Code session, substituting the actual path where you cloned the repo:

---

Set up ContextClerk. The repo is cloned at: C:\path\to\ContextClerk

ContextClerk is a Claude Code session logger. It runs every 5 minutes via Windows Task
Scheduler, reads Claude session transcripts, uses the claude CLI to write structured
progress notes, and appends ContextLog.md to each project directory, giving you
persistent context across sessions.

Run these steps in order, confirming each before proceeding:

1. Run contextclerk.ps1 -Force from the repo root. This does an initial backfill of
   ContextLog.md for all existing Claude Code projects and may take a few minutes.

2. Run install.ps1 from the repo root. This registers the Windows Task Scheduler task
   ContextClerk to run contextclerk.ps1 every 5 minutes.

3. Copy skills\contextclerk.md to $env:USERPROFILE\.claude\skills\contextclerk.md
   This installs the /contextclerk skill, available in all future Claude Code sessions.

4. Add the following to $env:USERPROFILE\.claude\CLAUDE.md:

   ## ContextClerk
   At the start of each session, if ContextLog.md exists in the project root, read it
   to orient yourself on recent work, active branch, and files recently touched.
   The /contextclerk skill surfaces a formatted summary on demand.

Report the outcome of each step.

--- end of paste block ---

### Manual install

```powershell
# 1. Backfill existing projects
.\contextclerk.ps1 -Force

# 2. Register the scheduled task
.\install.ps1

# 3. Install the skill
Copy-Item skills\contextclerk.md $env:USERPROFILE\.claude\skills\contextclerk.md
```

Then add the CLAUDE.md snippet above manually.

## Usage

Once installed, ContextClerk runs silently in the background. Each project that has
Claude Code activity gets a ContextLog.md in its root. The file is appended
automatically -- you don't need to do anything.

In a Claude Code session, run /contextclerk for a formatted summary of recent activity.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName 'ContextClerk' -Confirm:$false
Remove-Item $env:USERPROFILE\.claude\skills\contextclerk.md
```

Remove the ContextClerk section from $env:USERPROFILE\.claude\CLAUDE.md manually.
