Read SESSION_LOG.md in the current working directory.

**If the file exists:**
Parse it and present a concise "where we left off" briefing:
- Most recent session header: date, branch, session ID
- Last 5 progress bullet points across all sessions
- Last 10 files touched across all sessions
- Any compaction events in the most recent session

Keep it tight. The goal is to orient immediately for resumed work, not a full audit.

**If the file does not exist:**
1. Report that no SESSION_LOG.md exists for this project yet.
2. Check whether the ContextClerk scheduled task is registered:
   `Get-ScheduledTask -TaskName 'ContextClerk' -ErrorAction SilentlyContinue`
3. If found: the log will appear within 5 minutes of the next active Claude Code session. Nothing else to do.
4. If not found: offer to run the ContextClerk installer. Ask the user for the path to the ContextClerk repo if not already known, then follow the steps in its setup.md.
