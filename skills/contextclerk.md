Read ContextLog.md in the current working directory.

**If the file exists:**
Parse it and present a concise "where we left off" briefing:
- Most recent session header: date and branch
- Last 5 progress bullet points across all sessions
- Next: line from the most recent session, if present
- Last 10 files touched across all sessions

Keep it tight. The goal is to orient immediately for resumed work, not a full audit.

**If the file does not exist:**
1. Report that no ContextLog.md exists for this project yet.
2. Check whether ContextClerk is registered to run. Use the check for the current OS:
   - Windows: `Get-ScheduledTask -TaskName 'ContextClerk' -ErrorAction SilentlyContinue`
   - Linux (systemd): `systemctl --user list-timers contextclerk.timer` (or check for a `*/5` crontab entry running `contextclerk.sh`)
3. If found: the log will appear within 5 minutes of the next active Claude Code session. Nothing else to do.
4. If not found: offer to run the ContextClerk installer. Ask the user for the path to the ContextClerk repo if not already known, then follow the steps in its README (`README.md` on Windows, `README.linux.md` on Linux).
