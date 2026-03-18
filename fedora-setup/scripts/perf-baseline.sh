#!/bin/bash
set -euo pipefail
echo "=== Performance Baseline · $(date -I) ==="
BENCH="${HOME}/bench"
echo "--- Storage (write) ---"; dd if=/dev/zero of="$BENCH" bs=1M count=1024 oflag=direct 2>&1|tail -1
echo "--- Storage (read) ---"; dd if="$BENCH" of=/dev/null bs=1M count=1024 iflag=direct 2>&1|tail -1
rm -f "$BENCH"
echo "--- Btrfs compression ---"; compsize / 2>/dev/null|head -3||true
echo "--- Boot time ---"; systemd-analyze; systemd-analyze blame|head -5
