# ContextClerk on Linux

This is the Linux/bash port of ContextClerk. It behaves identically to the Windows
PowerShell version (`contextclerk.ps1`) - it reads Claude Code session transcripts under
`~/.claude/projects`, calls the Claude CLI to write a structured progress summary, and
appends that summary to `ContextLog.md` in each project repo. At the start of your next
session, Claude reads the log and picks up where you left off.

The Windows files (`contextclerk.ps1`, `install.ps1`, `contextclerk.vbs`, `update-logs.ps1`)
are unchanged and remain the reference. The Linux port lives in:

| File              | Role                                                        |
|-------------------|-------------------------------------------------------------|
| `contextclerk.sh` | The monitor/summariser (port of `contextclerk.ps1`)         |
| `install.sh`      | Registers a systemd **user** timer (port of `install.ps1`)  |

## Requirements

- Linux with `bash` 4+ (developed against bash 5.2 on Raspberry Pi OS / Debian trixie)
- Claude Code installed and on `PATH` as `claude`
- [`jq`](https://jqlang.github.io/jq/) for JSON parsing: `sudo apt install jq`
- `systemd` with a running user instance (default on modern desktop/server distros),
  **or** `cron` (see the cron alternative below)

## Install

The easiest way is to hand setup to Claude Code. Clone the repo, then paste the block below
into a Claude Code session, substituting the actual path where you cloned the repo:

---

Set up ContextClerk (Linux). The repo is cloned at: /path/to/ContextClerk

ContextClerk is a Claude Code session logger. It runs every 5 minutes via a systemd user
timer, reads Claude session transcripts, uses the claude CLI to write structured progress
notes, and appends ContextLog.md to each project directory, giving you persistent context
across sessions.

Run these steps in order, confirming each before proceeding:

1. Ensure jq is installed (`sudo apt install jq`).

2. Run `./contextclerk.sh --force` from the repo root. This does an initial backfill of
   ContextLog.md for all existing Claude Code projects and may take a few minutes.

3. Run `./install.sh` from the repo root. This registers the systemd user timer
   `contextclerk.timer` to run contextclerk.sh every 5 minutes.

4. Copy `skills/contextclerk.md` to `~/.claude/skills/contextclerk.md`. This installs the
   /contextclerk skill, available in all future Claude Code sessions.

5. Add the following to `~/.claude/CLAUDE.md`:

   ## ContextClerk
   At the start of each session, if ContextLog.md exists in the project root, read it
   to orient yourself on recent work, active branch, and files recently touched.
   The /contextclerk skill surfaces a formatted summary on demand.

Report the outcome of each step.

--- end of paste block ---

### Manual install

```bash
# 0. Install jq (one-off)
sudo apt install jq

# 1. Backfill existing projects
./contextclerk.sh --force

# 2. Register the systemd user timer (every 5 minutes)
./install.sh

# 3. Install the skill
cp skills/contextclerk.md ~/.claude/skills/contextclerk.md
```

Then add the `CLAUDE.md` snippet above manually.

## Headless boxes: enable lingering

A systemd **user** timer only runs while you have an active login session. On a headless
machine (e.g. a Raspberry Pi you SSH into and then disconnect), enable lingering once so the
timer keeps firing across logouts and reboots:

```bash
sudo loginctl enable-linger "$USER"
```

`install.sh` prints this reminder when lingering is not already enabled.

## Usage

Once installed, ContextClerk runs silently in the background. Useful commands:

```bash
systemctl --user list-timers contextclerk.timer   # next/last run
journalctl --user -u contextclerk.service -f       # live log output
systemctl --user start contextclerk.service        # run once, now
```

In a Claude Code session, run `/contextclerk` for a formatted "where we left off" summary.

## Cron alternative

If you prefer cron over systemd, skip `install.sh` and add a crontab entry instead:

```bash
crontab -e
# then add (adjust the path):
*/5 * * * * /path/to/ContextClerk/contextclerk.sh >> "$HOME/.claude/contextclerk.log" 2>&1
```

cron jobs run regardless of login state, so no lingering step is needed. Ensure `claude`
and `jq` are resolvable from cron's minimal `PATH` (cron does not source your shell profile);
the simplest fix is to put `PATH=/usr/local/bin:/usr/bin:/bin` at the top of the crontab, or
adjust to wherever `claude` lives (`command -v claude`).

## Uninstall

```bash
./install.sh --uninstall
rm ~/.claude/skills/contextclerk.md
```

Remove the ContextClerk section from `~/.claude/CLAUDE.md` manually. If you used cron, remove
the crontab line instead of running `--uninstall`.

## Notes on the port

- All path handling uses forward slashes; transcript `cwd` values are already POSIX paths.
- Sessions that ran in an ephemeral worktree (`.claude/worktrees/...`) are remapped to the
  parent project root so the log entry survives worktree teardown - same as the Windows version.
- `ContextLog.md` files are written with LF line endings (the PowerShell version writes CRLF).
- Summarisation uses `claude --print --no-session-persistence --model haiku`, identical to
  the Windows version. State lives in `~/.claude/contextclerk-state.json` (shared schema).
