#!/bin/bash
set -euo pipefail
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok(){ echo -e "  ${G}✓${N} $1"; }; warn(){ echo -e "  ${Y}⚠${N} $1"; }; err(){ echo -e "  ${R}✗${N} $1"; }; info(){ echo -e "  ${C}→${N} $1"; }
echo ""; echo "════════════════════════════════════════════"
echo "  System Health · $(date '+%Y-%m-%d %H:%M')"
echo "════════════════════════════════════════════"
echo ""; echo "Kernel & Boot"
info "Kernel: $(uname -r) · Uptime: $(uptime -p)"
FAILED=$(systemctl --failed --no-pager --no-legend|wc -l)
[ "$FAILED" -eq 0 ] && ok "No failed services" || err "$FAILED failed"
SE=$(getenforce 2>/dev/null||echo unknown)
[ "$SE" = "Enforcing" ] && ok "SELinux: Enforcing" || warn "SELinux: $SE"
echo ""; echo "Storage"
info "Root: $(df -h /|awk 'NR==2{print $5, "used,", $4, "free"}')"
BERR=$(btrfs device stats / 2>/dev/null|grep -v ' 0$'|wc -l)
[ "$BERR" -eq 0 ] && ok "Btrfs: clean" || err "Btrfs: $BERR error(s)"
echo ""; echo "Thermal"
for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$zone" ] || continue
    name=$(cat "${zone%/temp}/type" 2>/dev/null || basename "${zone%/temp}")
    temp_c=$(( $(cat "$zone" 2>/dev/null || echo 0) / 1000 ))
    if [ "$temp_c" -gt 85 ]; then
        err "$name: ${temp_c}°C"
    elif [ "$temp_c" -gt 70 ]; then
        warn "$name: ${temp_c}°C"
    else
        ok "$name: ${temp_c}°C"
    fi
done
if command -v nvme >/dev/null 2>&1; then
    for dev in /dev/nvme[0-9]; do
        [ -b "$dev" ] || continue
        nvme_temp=$(nvme smart-log "$dev" 2>/dev/null | awk '/^temperature/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
        [ -n "$nvme_temp" ] && info "NVMe $(basename "$dev"): ${nvme_temp}°C" || true
    done
fi
BAT=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null|head -1)
[ -n "$BAT" ] && { echo ""; echo "Battery"; info "${BAT}%"; }
echo ""; echo "════════════════════════════════════════════"; echo ""
