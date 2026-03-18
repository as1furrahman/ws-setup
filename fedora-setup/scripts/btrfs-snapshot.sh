#!/bin/bash
set -euo pipefail
SNAP_ROOT="/.snapshots"
VERIFIED_LOG="$SNAP_ROOT/.verified"
PROJECTS_DIR="__PROJECTS_MOUNT__"
TS=$(date +%Y%m%d-%H%M%S)
MAX=5

SPACE=$(btrfs filesystem usage / --raw 2>/dev/null | awk '/Free/{print $3; exit}')
MIN_FREE=$((10 * 1024 * 1024 * 1024))
if [ "${SPACE:-0}" -lt "$MIN_FREE" ]; then
    echo "  ✗ Less than 10 GiB free — run 'btrfs-snapshot clean' first"
    exit 1
fi

snap() {
    local src="$1" dst="$2" label="${3:-manual}"
    btrfs subvolume snapshot -r "$src" "${dst}/${TS}_${label}" >/dev/null
    echo "  ✓ ${dst}/${TS}_${label}"
}
check_health() {
    local errors=0
    local failed; failed=$(systemctl --failed --no-pager --no-legend | wc -l)
    [ "$failed" -eq 0 ] || { echo "  ✗ $failed failed service(s)"; errors=$((errors+1)); }
    local se; se=$(getenforce 2>/dev/null || echo "unknown")
    [ "$se" = "Enforcing" ] || { echo "  ✗ SELinux: $se"; errors=$((errors+1)); }
    local berr; berr=$(btrfs device stats / 2>/dev/null | grep -v ' 0$' | wc -l)
    [ "$berr" -eq 0 ] || { echo "  ✗ Btrfs: $berr error(s)"; errors=$((errors+1)); }
    return $errors
}
mark_verified() { touch "$VERIFIED_LOG"; echo "$1" >> "$VERIFIED_LOG"; echo "  ★ Group $1 VERIFIED"; }
last_verified() { [ -f "$VERIFIED_LOG" ] && tail -1 "$VERIFIED_LOG" || echo ""; }
do_coordinated_snap() {
    local label="$1" verified=false
    if [ "${2:-yes}" = "yes" ]; then
        echo "Verifying system health..."; check_health && { echo "  ✓ Healthy"; verified=true; } || echo "  ⚠ Issues — snapshot NOT verified"
    fi
    snap / "$SNAP_ROOT/root" "$label"
    snap /home "$SNAP_ROOT/home" "$label"
    if findmnt -t btrfs "$PROJECTS_DIR" &>/dev/null; then
        snap "$PROJECTS_DIR" "$SNAP_ROOT/projects" "$label"
    fi
    $verified && mark_verified "$TS"
    echo "Done. Group: $TS"
}
case "${1:-help}" in
    pre-upgrade) echo "Creating pre-upgrade snapshots..."; do_coordinated_snap "pre-upgrade" ;;
    group) do_coordinated_snap "${2:-manual}" ;;
    root|home|projects) src="/"; [ "$1" = "home" ] && src="/home"; [ "$1" = "projects" ] && src="$PROJECTS_DIR"; snap "$src" "$SNAP_ROOT/$1" "${2:-manual}" ;;
    verify) echo "Health check..."; check_health && echo "  ✓ Healthy" || { echo "  ✗ Failed"; exit 1; } ;;
    list) for d in root home projects; do [ -d "$SNAP_ROOT/$d" ] || continue; echo "$d:"; ls -1 "$SNAP_ROOT/$d/"; done ;;
    clean) keep=${2:-$MAX}; for d in root home projects; do dir="$SNAP_ROOT/$d"; [ -d "$dir" ] || continue; count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d|wc -l); if [ "$count" -gt "$keep" ]; then find "$dir" -maxdepth 1 -mindepth 1 -type d|sort|head -n $((count-keep))|while read -r s; do btrfs subvolume delete "$s">/dev/null; echo "  Deleted: $(basename "$s")"; done; fi; done ;;
    rollback) echo "Boot Live USB, mount subvolid=5, restore from /.snapshots/"; last_verified && echo "Last verified: $(last_verified)" ;;
    *) echo "Usage: btrfs-snapshot {pre-upgrade|group|verify|list|clean|rollback}" ;;
esac
