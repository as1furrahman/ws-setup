#!/bin/bash
set -euo pipefail
echo "=== Fedora Safe Upgrade ==="
echo "[1/5] Snapshots..."; /usr/local/bin/btrfs-snapshot pre-upgrade
echo "[2/5] Upgrading..."; dnf upgrade -y --refresh "$@"
echo "[3/5] Firmware..."; fwupdmgr refresh 2>/dev/null||true; fwupdmgr update 2>/dev/null||true
echo "[4/5] Health check..."
FAILED=$(systemctl --failed --no-pager --no-legend|wc -l)
BERR=$(btrfs device stats / 2>/dev/null|grep -v ' 0$'|wc -l)
SE=$(getenforce 2>/dev/null||echo unknown)
echo "  Failed: $FAILED | Btrfs errors: $BERR | SELinux: $SE"
echo "[5/5] Verdict..."
[ "$FAILED" -eq 0 ] && [ "$BERR" -eq 0 ] && [ "$SE" = "Enforcing" ] && echo "  ✓ Healthy" || echo "  ⚠ Issues detected"
