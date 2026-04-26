# ContextClerk Setup

## Paste this into Claude to install

Open a Claude Code session (any project), paste the block below, and hit Enter.

---

Set up ContextClerk on this machine.

ContextClerk is a Claude Code session logger. It runs every 5 minutes via Windows Task
Scheduler, reads Claude session transcripts, uses the claude CLI to write structured
progress notes, and appends SESSION_LOG.md to each project. This gives you persistent
context across sessions without manual effort.

The repo is at: **[PASTE REPO PATH HERE, e.g. C:\Git\Github\ContextClerk]**

Run these steps in order, confirming each before proceeding:

1. Run install.ps1 from the repo root. This registers the Windows Task Scheduler task
   'ContextClerk' to run contextclerk.ps1 every 5 minutes.

2. Copy skills\contextclerk.md from the repo to $env:USERPROFILE\.claude\skills\contextclerk.md
   This installs the /contextclerk skill, available in all future Claude Code sessions.

3. Add the following section to $env:USERPROFILE\.claude\CLAUDE.md:

   ## ContextClerk
   At the start of each session, if SESSION_LOG.md exists in the project root, read it
   to orient yourself on recent work, active branch, and files recently touched.
   The /contextclerk skill surfaces a formatted summary on demand.

Report the outcome of each step.

---

## Manual steps (if you prefer)

1. `.\install.ps1` — registers the scheduled task
2. Copy `skills\contextclerk.md` to `~\.claude\skills\contextclerk.md`
3. Add the CLAUDE.md snippet above to `~\.claude\CLAUDE.md`

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName 'ContextClerk' -Confirm:$false
Remove-Item ~\.claude\skills\contextclerk.md
```

Remove the ContextClerk section from `~\.claude\CLAUDE.md` manually.
