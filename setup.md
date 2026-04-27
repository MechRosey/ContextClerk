# Installation

Paste the block below into Claude Code.

---

Set up ContextClerk. Clone the repo if you haven't already:
  git clone git@github.com:MechRosey/ContextClerk.git
Then tell me the local path where it was cloned.

ContextClerk is a Claude Code session logger. It runs every 5 minutes via Windows Task
Scheduler, reads Claude session transcripts, uses the claude CLI to write structured
progress notes, and appends ContextClerk.md to each project directory, giving you
persistent context across sessions.

Run these steps in order, confirming each before proceeding:

1. Run contextclerk.ps1 -Force from the repo root. This does an initial backfill of
   ContextClerk.md for all existing Claude Code projects and may take a few minutes.

2. Run install.ps1 from the repo root. This registers the Windows Task Scheduler task
   'ContextClerk' to run contextclerk.ps1 every 5 minutes.

3. Copy skills\contextclerk.md from the repo to $env:USERPROFILE\.claude\skills\contextclerk.md
   This installs the /contextclerk skill, available in all future Claude Code sessions.

4. Add the following to $env:USERPROFILE\.claude\CLAUDE.md:

   ## ContextClerk
   At the start of each session, if ContextClerk.md exists in the project root, read it
   to orient yourself on recent work, active branch, and files recently touched.
   The /contextclerk skill surfaces a formatted summary on demand.

Report the outcome of each step.

---

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName 'ContextClerk' -Confirm:$false
Remove-Item $env:USERPROFILE\.claude\skills\contextclerk.md
```

Remove the ContextClerk section from `$env:USERPROFILE\.claude\CLAUDE.md` manually.
