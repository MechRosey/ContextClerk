#!/usr/bin/env bash
# ContextClerk installer (Linux)
# Registers a systemd *user* timer to run contextclerk.sh every 5 minutes.
# Run once after cloning the repo. The Windows equivalent is install.ps1.
#
# Usage:
#   ./install.sh                 install/enable the timer (default 5 min)
#   ./install.sh --interval 10   custom interval in minutes
#   ./install.sh --uninstall     stop and remove the timer + service

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/contextclerk.sh"
INTERVAL_MINUTES=5
UNIT_NAME="contextclerk"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$UNIT_DIR/$UNIT_NAME.service"
TIMER_FILE="$UNIT_DIR/$UNIT_NAME.timer"

UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --interval) shift; INTERVAL_MINUTES="${1:-5}" ;;
        --interval=*) INTERVAL_MINUTES="${1#*=}" ;;
        --uninstall) UNINSTALL=1 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if (( UNINSTALL )); then
    systemctl --user disable --now "$UNIT_NAME.timer" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl --user daemon-reload
    echo "ContextClerk timer removed."
    echo "To also remove the skill:   rm \"\$HOME/.claude/skills/contextclerk.md\""
    exit 0
fi

[ -f "$SCRIPT_PATH" ] || { echo "Script not found: $SCRIPT_PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required. Install it with: sudo apt install jq" >&2; exit 1; }
chmod +x "$SCRIPT_PATH"

mkdir -p "$UNIT_DIR"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ContextClerk - append Claude Code session summaries to ContextLog.md

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run ContextClerk every $INTERVAL_MINUTES minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL_MINUTES}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME.timer"

echo "ContextClerk installed. Timer '$UNIT_NAME.timer' runs contextclerk.sh every $INTERVAL_MINUTES minutes."
echo "Script   : $SCRIPT_PATH"
echo ""
echo "Status   : systemctl --user list-timers $UNIT_NAME.timer"
echo "Logs     : journalctl --user -u $UNIT_NAME.service -f"
echo "Run now  : systemctl --user start $UNIT_NAME.service"
echo ""

if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
    echo "NOTE: user services only run while you are logged in. To run on a headless"
    echo "      box across logouts/reboots, enable lingering once (needs sudo):"
    echo "          sudo loginctl enable-linger $USER"
fi
echo "To remove: $0 --uninstall"
