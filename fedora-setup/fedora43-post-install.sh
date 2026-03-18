#!/bin/bash
###############################################################################
# Fedora 43 Post-Installation Script
# ASUS Zenbook S 13 OLED (UM5302TA) · Samsung 990 Pro 1TB
#
# Automates Phases D–K from fedora43-zenbook-final.md
# Run AFTER completing Phases A–C (BIOS, install, Btrfs subvolumes)
#
# Idempotent: checks current state before each action — safe to re-run.
#
# Usage:
#   sudo ./fedora43-post-install.sh --all
#   sudo ./fedora43-post-install.sh --phase d,e,f
#   sudo ./fedora43-post-install.sh --resume          # resume from last completed phase
#   sudo ./fedora43-post-install.sh --config FILE     # load config, skip prompts
#   sudo ./fedora43-post-install.sh --non-interactive # use defaults, skip prompts
#   sudo ./fedora43-post-install.sh --dry-run --all
#   sudo ./fedora43-post-install.sh --list
#   sudo ./fedora43-post-install.sh --version
###############################################################################
set -uo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors & Output ────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

ok()   { echo -e "  ${GRN}✓${RST} $1"; }
skip() { echo -e "  ${DIM}– $1 (already done)${RST}"; }
err()  { echo -e "  ${RED}✗${RST} $1"; }
warn() { echo -e "  ${YEL}⚠${RST} $1"; }
info() { echo -e "  ${CYN}→${RST} $1"; }
hdr()  { echo -e "\n${BLD}═══ $1 ═══${RST}\n"; }
sub()  { echo -e "\n${BLD}--- $1 ---${RST}"; }

LOG_FILE="${HOME}/fedora-setup.log"
STATE_FILE="/var/lib/fedora-setup-state"
DRY_RUN=false
SELECTED_PHASES=""
CONFIG_FILE=""
NON_INTERACTIVE=false
RESUME_MODE=false

# ─── Progress Counter ───────────────────────────────────────────────────────
declare -i CURRENT_PHASE=0 TOTAL_PHASES=0


# ─── Tracking ───────────────────────────────────────────────────────────────
declare -i TOTAL_OK=0 TOTAL_SKIP=0 TOTAL_WARN=0 TOTAL_ERR=0
declare -a PHASE_TIMES=()
_DAEMON_RELOAD=false

count_ok()   { ((TOTAL_OK++))   || true; ok "$@";   }
count_skip() { ((TOTAL_SKIP++)) || true; skip "$@"; }
count_warn() { ((TOTAL_WARN++)) || true; warn "$@"; }
count_err()  { ((TOTAL_ERR++))  || true; err "$@";  }

request_reload() { _DAEMON_RELOAD=true; }

flush_reload() {
    if $_DAEMON_RELOAD; then
        systemctl daemon-reload 2>/dev/null || true
        _DAEMON_RELOAD=false
    fi
}

phase_timer_start() { PHASE_START=$(date +%s); }

phase_timer_end() {
    local elapsed=$(( $(date +%s) - PHASE_START ))
    local label="$1" phase="${2:-}"
    PHASE_TIMES+=("${label}:${elapsed}s")
    info "${label} finished in ${elapsed}s"
    if ! $DRY_RUN && [[ -n "$phase" ]]; then
        echo "$phase" > "$STATE_FILE"
    fi
}

# ─── Error Trap ─────────────────────────────────────────────────────────────
trap_handler() {
    local lineno=$1 cmd=$2 rc=$3
    if [[ $rc -ne 0 ]]; then
        echo -e "\n  ${RED}✗ Command failed (line $lineno, exit $rc): $cmd${RST}" >&2
    fi
}
trap 'trap_handler ${LINENO} "${BASH_COMMAND}" $?' ERR

# ─── CLI Parsing ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --all              Run all phases (D–K)
  --phase X,Y        Run specific phases (e.g., --phase d,e,f)
  --resume           Resume from last completed phase (skips completed phases)
  --config FILE      Load config from file, skip interactive prompts
  --non-interactive  Use defaults for all prompts, skip interactive prompts
  --dry-run          Show what would be done without executing
  --list             List all available phases
  --version          Show script version
  --help             Show this help
EOF
    exit 0
}

list_phases() {
    cat <<EOF
Available phases:
  d  - First Boot (mount points, SELinux, update)
  e  - System Configuration (DNF, kernel, sysctl, security)
  f  - Hardware Optimization (power, GPU, NVMe, battery)
  g  - OLED Display (scaling, fonts, ABR, burn-in)
  h  - GNOME Minimalism (remove bloat, configure, Tracker)
  i  - Development Environment (packages, tools, shell)
  j  - Snapshot Automation (scripts, timers)
  k  - Backup & Maintenance (Borg, baseline, verification)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)              SELECTED_PHASES="d,e,f,g,h,i,j,k"; shift ;;
        --phase)            SELECTED_PHASES="${2:?--phase requires a value}"; shift 2 ;;
        --resume)            RESUME_MODE=true; shift ;;
        --config)            CONFIG_FILE="${2:?--config requires a value}"; shift 2 ;;
        --non-interactive)   NON_INTERACTIVE=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --list)              list_phases ;;
        --version)           echo "fedora-setup v${SCRIPT_VERSION}"; exit 0 ;;
        --help|-h)           usage ;;
        *)                   echo "Unknown option: $1"; usage ;;
    esac
done

if $RESUME_MODE; then
    if [[ -f "$STATE_FILE" ]]; then
        last_phase=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\n' | grep -oE '^[a-z]$' || true)
        if [[ "$last_phase" == "k" ]]; then
            echo "All phases already complete. Run with --all to re-run, or --phase X,Y for specific phases."
            exit 0
        fi
        phases_after=""
        found=0
        for p in d e f g h i j k; do
            if [[ "$p" == "$last_phase" ]]; then found=1; continue; fi
            if [[ "$found" -eq 1 ]]; then phases_after="${phases_after:+$phases_after,}$p"; fi
        done
        SELECTED_PHASES="${phases_after:-d,e,f,g,h,i,j,k}"
        info "Resuming from phase after $last_phase: $SELECTED_PHASES"
    else
        echo "No resume state found. Run with --all for full setup."
        exit 1
    fi
fi

[[ -z "$SELECTED_PHASES" ]] && { echo "Error: specify --all, --phase X,Y, or --resume"; usage; }

# ─── Logging (placed after CLI so --version/--help/--list print directly) ──
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Fedora 43 Post-Install v${SCRIPT_VERSION} · $(date -Is) ===" >> "$LOG_FILE"

# Phase dependency: e,f,g,h,i,j,k all depend on d
if ! echo ",$SELECTED_PHASES," | grep -qi ',d,'; then
    for dep_phase in e f g h i j k; do
        if echo ",$SELECTED_PHASES," | grep -qi ",$dep_phase,"; then
            warn "Phase $dep_phase requires d. Prepending d to selected phases."
            SELECTED_PHASES="d,$SELECTED_PHASES"
            break
        fi
    done
fi

should_run() { echo ",$SELECTED_PHASES," | grep -qi ",$1,"; }

# Count selected phases for progress display
for _p in d e f g h i j k; do
    should_run "$_p" && ((TOTAL_PHASES++)) || true
done

run() {
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} $*"
        return 0
    fi
    "$@"
}

run_or_warn() {
    if ! run "$@"; then
        count_warn "Non-fatal: $*"
    fi
}

# ─── Network Connectivity Check ────────────────────────────────────────────
require_network() {
    if ! curl -sf --max-time 5 --connect-timeout 3 https://fedoraproject.org > /dev/null 2>&1; then
        count_warn "No internet connectivity — $1 may fail"
        return 1
    fi
    return 0
}

# ─── Phase Progress ─────────────────────────────────────────────────────────
phase_hdr() {
    ((CURRENT_PHASE++)) || true
    echo -e "\n${BLD}═══ [$CURRENT_PHASE/$TOTAL_PHASES] $1 ═══${RST}\n"
}

# ─── Root Check ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
    echo "Error: This script must be run as root (sudo)."
    echo "  sudo $0 $*"
    exit 1
fi

# ─── Concurrent Run Protection ─────────────────────────────────────────────
LOCK_FILE="/var/lock/fedora-setup.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Error: Another instance of fedora-setup is already running."
    echo "  If this is a mistake, remove $LOCK_FILE and try again."
    exit 1
fi

# ─── Auto-Detection ────────────────────────────────────────────────────────
hdr "Auto-Detecting System Configuration"

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")

SWAP_UUID=$(blkid -t TYPE=swap -s UUID -o value 2>/dev/null | head -1 || true)
BTRFS_UUID=$(findmnt -n -o UUID / 2>/dev/null || true)
NVME_DEV=$(lsblk -dno NAME,TRAN 2>/dev/null | awk '$2=="nvme"{print $1; exit}' || true)
BAT_DEV=$(ls /sys/class/power_supply/ 2>/dev/null | grep -i bat | head -1 || true)
CPU_DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
GPU_DRIVER=$(lspci -nnk 2>/dev/null | awk '/VGA|3D|Display/{found=1} found && /Kernel driver in use:/{print $NF; exit}' || true)
GPU_DRIVER="${GPU_DRIVER:-unknown}"
HOSTNAME_CURRENT=$(hostnamectl hostname 2>/dev/null || hostname 2>/dev/null || echo "localhost")
TOTAL_RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null)
TOTAL_RAM_GB="${TOTAL_RAM_GB:-16}"

info "User:       ${BLD}$REAL_USER${RST} ($REAL_HOME)"
info "Hostname:   ${BLD}$HOSTNAME_CURRENT${RST}"
info "Swap UUID:  ${BLD}${SWAP_UUID:-NOT FOUND}${RST}"
info "Btrfs UUID: ${BLD}${BTRFS_UUID:-NOT FOUND}${RST}"
info "NVMe:       ${BLD}${NVME_DEV:-NOT FOUND}${RST}"
info "Battery:    ${BLD}${BAT_DEV:-NOT FOUND}${RST}"
info "CPU Driver: ${BLD}$CPU_DRIVER${RST}"
info "GPU Driver: ${BLD}$GPU_DRIVER${RST}"
info "RAM:        ${BLD}${TOTAL_RAM_GB} GB${RST}"

# ─── Idempotent Helpers ────────────────────────────────────────────────────

ensure_pkg() {
    local missing=()
    for pkg in "$@"; do
        rpm -q "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        run dnf install -y --skip-unavailable "${missing[@]}"
        count_ok "Installed: ${missing[*]}"
    else
        count_skip "Packages: $*"
    fi
}

ensure_file() {
    local path="$1"; shift
    local content="$*"
    if [[ -f "$path" ]] && [[ "$(cat "$path" 2>/dev/null)" == "$content" ]]; then
        count_skip "$path"
        return 1
    fi
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} write $path"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    count_ok "$path"
    return 0
}

ensure_user_file() {
    local path="$1"; shift
    local content="$*"
    if [[ -f "$path" ]] && [[ "$(cat "$path" 2>/dev/null)" == "$content" ]]; then
        count_skip "$path"
        return 1
    fi
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} write $path (as $REAL_USER)"
        return 0
    fi
    install -d -o "$REAL_USER" -g "$REAL_USER" "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    chown "$REAL_USER:$REAL_USER" "$path"
    count_ok "$path"
    return 0
}

ensure_user_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        return 0
    fi
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} mkdir $dir (as $REAL_USER)"
        return 0
    fi
    install -d -o "$REAL_USER" -g "$REAL_USER" "$dir"
}

ensure_enabled() {
    local unit="$1"
    if systemctl is-enabled "$unit" &>/dev/null; then
        count_skip "$unit enabled"
    else
        run systemctl enable --now "$unit" 2>/dev/null || true
        count_ok "$unit enabled"
    fi
}

ensure_disabled() {
    local unit="$1"
    if systemctl is-enabled "$unit" &>/dev/null 2>&1; then
        run systemctl disable --now "$unit" 2>/dev/null || true
        count_ok "$unit disabled"
    else
        count_skip "$unit already disabled"
    fi
}

ensure_masked() {
    local unit="$1"
    if systemctl is-enabled "$unit" 2>/dev/null | grep -q masked; then
        count_skip "$unit already masked"
    else
        run systemctl mask "$unit" 2>/dev/null || true
        count_ok "$unit masked"
    fi
}

user_gsettings() {
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} gsettings set $*"
        return
    fi
    local schema="$1" key="$2"; shift 2
    local desired="$*"

    local bus_addr=""
    bus_addr=$(sudo -u "$REAL_USER" bash -c \
        'grep -z DBUS_SESSION_BUS_ADDRESS /proc/$(pgrep -u "$USER" gnome-session | head -1)/environ 2>/dev/null | tr -d "\0" | cut -d= -f2-' 2>/dev/null || true)

    local -a gs_cmd
    if [[ -n "$bus_addr" ]]; then
        gs_cmd=(sudo -u "$REAL_USER" env "DBUS_SESSION_BUS_ADDRESS=$bus_addr" gsettings)
    else
        gs_cmd=(sudo -u "$REAL_USER" dbus-run-session gsettings)
    fi

    local current
    current=$("${gs_cmd[@]}" get "$schema" "$key" 2>/dev/null || true)
    local norm_current norm_desired
    norm_current=$(echo "$current" | sed "s/^'//;s/'$//")
    norm_desired=$(echo "$desired" | sed "s/^'//;s/'$//")

    if [[ "$norm_current" == "$norm_desired" ]]; then
        count_skip "gsettings $schema $key"
        return
    fi
    "${gs_cmd[@]}" set "$schema" "$key" "$desired"
    count_ok "gsettings $schema $key = $desired"
}

ensure_udev() {
    local path="$1"; shift
    local content="$*"
    if ensure_file "$path" "$content"; then
        run udevadm control --reload-rules
        run udevadm trigger
    fi
}

ensure_script() {
    local dest="$1" src="$2"
    local content
    content=$(cat "$src")
    if [[ -x "$dest" ]] && [[ "$(cat "$dest" 2>/dev/null)" == "$content" ]]; then
        count_skip "$dest"
        return
    fi
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} install $dest from $src"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    chmod +x "$dest"
    count_ok "$dest"
}

ensure_script_content() {
    local path="$1"; shift
    local content="$*"
    if [[ -x "$path" ]] && [[ "$(cat "$path" 2>/dev/null)" == "$content" ]]; then
        count_skip "$path"
        return
    fi
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} write $path"
        return
    fi
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    chmod +x "$path"
    count_ok "$path"
}

ensure_systemd_unit() {
    local path="$1"; shift
    local content="$*"
    if ensure_file "$path" "$content"; then
        request_reload
    fi
}

has_kernel_arg() {
    grubby --info=ALL 2>/dev/null | grep -q "$1"
}

# ─── Interactive Setup ──────────────────────────────────────────────────────
apply_defaults() {
    GIT_NAME="${GIT_NAME:-$REAL_USER}"
    GIT_EMAIL="${GIT_EMAIL:-${REAL_USER}@${HOSTNAME_CURRENT}}"
    GPU_SERVER_IP="${GPU_SERVER_IP:-skip}"
    GPU_SERVER_USER="${GPU_SERVER_USER:-$REAL_USER}"
    BATTERY_THRESHOLD="${BATTERY_THRESHOLD:-80}"
    BORG_LOCAL="${BORG_LOCAL:-/run/media/${REAL_USER}/backup-drive/borg-zenbook}"
    BORG_REMOTE="${BORG_REMOTE:-skip}"
    DISABLE_IPV6="${DISABLE_IPV6:-no}"
}

load_config() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "Error: config file not found: $path"
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            key="${key%"${key##*[![:space:]]}"}"
            key="${key#"${key%%[![:space:]]*}"}"
            val="${line#*=}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            case "$key" in
                GIT_NAME|GIT_EMAIL|GPU_SERVER_IP|GPU_SERVER_USER|BATTERY_THRESHOLD|BORG_LOCAL|BORG_REMOTE|DISABLE_IPV6)
                    printf -v "$key" '%s' "$val"
                    ;;
            esac
        fi
    done < "$path"
}

ask() {
    local -n _ref=$1
    local prompt="$2" default="$3" response
    read -rp "$(echo -e "  ${CYN}?${RST} ${prompt} [${default}]: ")" response
    _ref="${response:-$default}"
}

if [[ -n "$CONFIG_FILE" ]]; then
    hdr "Loading Configuration"
    load_config "$CONFIG_FILE"
    apply_defaults
    info "Config loaded from $CONFIG_FILE"
elif $NON_INTERACTIVE; then
    hdr "Non-Interactive Mode"
    apply_defaults
    info "Using default values"
else
    hdr "Interactive Setup — Please Answer the Following"
    ask GIT_NAME          "Your full name (for Git)"                "$REAL_USER"
    ask GIT_EMAIL         "Your email (for Git commits)"            "${REAL_USER}@${HOSTNAME_CURRENT}"
    ask GPU_SERVER_IP     "Remote GPU server IP (or 'skip')"        "skip"
    ask GPU_SERVER_USER   "Remote GPU server username"              "$REAL_USER"
    ask BATTERY_THRESHOLD "Battery charge limit % (60-100)"         "80"
    ask BORG_LOCAL        "BorgBackup local repo path (or 'skip')"  "/run/media/${REAL_USER}/backup-drive/borg-zenbook"
    ask BORG_REMOTE       "BorgBackup remote repo (or 'skip')"      "skip"
    ask DISABLE_IPV6      "Disable IPv6? (yes/no)"                  "no"
fi

echo ""
if [[ -n "$CONFIG_FILE" ]] || $NON_INTERACTIVE; then
    info "Starting immediately."
else
    info "Configuration saved. Starting in 3 seconds... (Ctrl+C to abort)"
    $DRY_RUN || sleep 3
fi

###############################################################################
# PHASE D — First Boot
###############################################################################
phase_d() {
    phase_timer_start
    phase_hdr "Phase D — First Boot"

    sub "D.1 Mount Points & Ownership"
    ensure_user_dir "$REAL_HOME/projects"
    run mount -a 2>/dev/null || true
    local owner
    owner=$(stat -c '%U' "$REAL_HOME/projects" 2>/dev/null || true)
    if [[ "$owner" == "$REAL_USER" ]]; then
        count_skip "projects ownership correct"
    else
        run chown "$REAL_USER:$REAL_USER" "$REAL_HOME/projects"
        count_ok "Fixed projects ownership"
    fi
    run restorecon -Rv /var/log /var/cache /var/tmp /var/lib/containers /.snapshots "$REAL_HOME/projects" 2>/dev/null || true

    local mounts expected_mounts mountable
    mounts=$(findmnt -t btrfs --noheadings 2>/dev/null | wc -l)
    expected_mounts=$(awk '$3 == "btrfs" && $4 !~ /noauto/' /etc/fstab 2>/dev/null | wc -l)
    mountable=$(awk '$3 == "btrfs" && $4 !~ /noauto/ {print $2}' /etc/fstab 2>/dev/null | while read -r mp; do [[ -d "$mp" ]] && echo "$mp"; done | wc -l)
    expected_mounts="${mountable:-${expected_mounts:-7}}"
    if [[ "$mounts" -ge "$expected_mounts" ]]; then
        count_ok "All $mounts Btrfs mounts present"
    else
        count_warn "Only $mounts/$expected_mounts Btrfs mounts (some mount targets may not exist yet)"
    fi

    sub "D.2 Verify SELinux"
    local se
    se=$(getenforce 2>/dev/null || echo "unknown")
    if [[ "$se" == "Enforcing" ]]; then
        count_ok "SELinux: Enforcing"
    else
        count_err "SELinux: $se (should be Enforcing)"
    fi

    sub "D.3 Full System Update"
    require_network "system update"
    run dnf upgrade -y --refresh

    sub "D.4 Firmware Updates"
    run fwupdmgr refresh --force 2>/dev/null || true
    run fwupdmgr update 2>/dev/null || true

    phase_timer_end "Phase D" "d"
}

###############################################################################
# PHASE E — System Configuration (split into logical sub-functions)
###############################################################################

# ─── E: System (DNF, RPM Fusion, kernel params, sysctl) ────────────────────
_phase_e_system() {
    sub "E.1 DNF Configuration"
    ensure_file /etc/dnf/dnf.conf "[main]
max_parallel_downloads=10
fastestmirror=True
keepcache=True
installonly_limit=4
skip_if_unavailable=True
install_weak_deps=True
clean_requirements_on_remove=True
defaultyes=True
metadata_expire=172800" || true

    sub "E.2 RPM Fusion & Codecs"
    require_network "RPM Fusion install"
    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        run bash -c 'dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"'
        count_ok "RPM Fusion installed"
    else
        count_skip "RPM Fusion"
    fi
    if ! rpm -q ffmpeg &>/dev/null; then
        run dnf install -y --allowerasing ffmpeg 2>/dev/null || true
    else
        count_skip "ffmpeg"
    fi
    ensure_pkg gstreamer1-plugins-bad-free gstreamer1-plugins-ugly \
               gstreamer1-plugin-libav libva-utils mesa-va-drivers mesa-vulkan-drivers

    sub "E.3 Kernel Parameters"
    if [[ -n "$SWAP_UUID" ]]; then
        local PARAMS="amd_pstate=active amd_iommu=on iommu=pt transparent_hugepage=madvise"
        PARAMS+=" nowatchdog nmi_watchdog=0 workqueue.power_efficient=1"
        PARAMS+=" nvme_core.default_ps_max_latency_us=5500"
        PARAMS+=" mitigations=auto resume=UUID=$SWAP_UUID"
        if has_kernel_arg "resume=UUID=$SWAP_UUID"; then
            count_skip "Kernel params"
        else
            run grubby --update-kernel=ALL --args="$PARAMS"
            count_ok "Kernel params applied"
        fi
    else
        count_warn "Swap UUID not found — skipping resume= parameter"
    fi

    sub "E.4 sysctl Tuning"
    if [[ -f /etc/sysctl.d/90-zenbook.conf ]]; then
        rm -f /etc/sysctl.d/90-zenbook.conf
        count_ok "Removed stale 90-zenbook.conf"
    fi
    if ensure_file /etc/sysctl.d/99-zenbook.conf "vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 300
vm.vfs_cache_pressure = 50
vm.max_map_count = 262144
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
kernel.sysrq = 150
kernel.panic = 10
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.kptr_restrict = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# === Additional Security Hardening ===
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.yama.ptrace_scope = 2
kernel.randomize_va_space = 2
fs.suid_dumpable = 0"; then
        run sysctl --system 2>/dev/null
    fi
}

# ─── E: Network (DNS, firewall) ───────────────────────────────────────────
_phase_e_network() {
    sub "E.5 DNS-over-TLS"
    if ensure_file /etc/systemd/resolved.conf.d/performance.conf "[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google
DNSOverTLS=opportunistic
Cache=yes
CacheFromLocalhost=yes
DNSSEC=yes"; then
        run systemctl restart systemd-resolved
    fi

    sub "E.6 Firewall for Development"
    local current_zone
    current_zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
    if [[ "$current_zone" != "home" ]]; then
        run firewall-cmd --set-default-zone=home 2>/dev/null || true
        count_ok "Firewall zone set to home"
    else
        count_skip "Firewall zone already home"
    fi
    local fw_changed=false
    for port in 3000 5000 6006 8000 8080 8888 11434; do
        if ! firewall-cmd --zone=home --query-rich-rule="rule family=ipv4 source address=127.0.0.1/32 port port=$port protocol=tcp accept" &>/dev/null; then
            run firewall-cmd --permanent --zone=home --add-rich-rule="rule family=ipv4 source address=127.0.0.1/32 port port=$port protocol=tcp accept" 2>/dev/null || true
            fw_changed=true
        fi
    done
    if ! firewall-cmd --zone=home --query-service=ssh &>/dev/null; then
        run firewall-cmd --permanent --zone=home --add-service=ssh 2>/dev/null || true
        fw_changed=true
    fi
    if ! firewall-cmd --zone=trusted --query-interface=podman0 &>/dev/null; then
        run firewall-cmd --permanent --zone=trusted --add-interface=podman0 2>/dev/null || true
        fw_changed=true
    fi
    if $fw_changed; then run firewall-cmd --reload 2>/dev/null || true; fi
}

# ─── E: Services (systemd, oomd, journald, dracut, boot) ──────────────────
_phase_e_services() {
    sub "E.7 systemd Service Optimization"
    for svc in cups.service cups.socket cups.path cups-browsed.service \
               avahi-daemon.service avahi-daemon.socket \
               abrtd.service abrt-journal-core.service abrt-oops.service \
               pcscd.service pcscd.socket; do
        ensure_disabled "$svc"
    done
    ensure_masked ModemManager.service
    ensure_masked remote-fs.target

    sub "E.8 systemd-oomd Tuning"
    if ensure_file /etc/systemd/oomd.conf.d/ml-workload.conf "[OOM]
SwapUsedLimit=95%
DefaultMemoryPressureLimit=70%
DefaultMemoryPressureDurationUSec=30s"; then
        run systemctl restart systemd-oomd 2>/dev/null || true
    fi

    sub "E.9 journald & Core Dumps"
    if ensure_file /etc/systemd/journald.conf.d/optimize.conf "[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
Compress=yes
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no"; then
        run systemctl restart systemd-journald
    fi

    ensure_file /etc/systemd/coredump.conf.d/limits.conf "[Coredump]
Storage=external
MaxUse=1G
ProcessSizeMax=2G" || true

    sub "E.10 tmpfs"
    ensure_enabled tmp.mount
    if ensure_systemd_unit /etc/systemd/system/tmp.mount.d/size.conf "[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=4G"; then
        : # reload is deferred
    fi

    sub "E.11 dracut Initramfs Optimization"
    if ensure_file /etc/dracut.conf.d/performance.conf 'compress="zstd"
add_dracutmodules+=" btrfs resume "
early_microcode="yes"
omit_dracutmodules+=" nfs iscsi fcoe fcoe-uefi multipath "
install_optional_items+=" /lib/firmware/amdgpu/* /lib/firmware/mediatek/* "'; then
        run plymouth-set-default-theme spinner 2>/dev/null || true
        run dracut --force --regenerate-all 2>/dev/null || true
    fi

    sub "E.12 Boot Experience"
    if grep -q '^GRUB_TIMEOUT=2$' /etc/default/grub 2>/dev/null; then
        count_skip "GRUB_TIMEOUT already 2"
    else
        run sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
        run sed -i 's/^GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT="gfxterm"/' /etc/default/grub
        run grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
        count_ok "GRUB timeout set to 2"
    fi
}

# ─── E: Security (SSH, fail2ban, USBGuard, chrony, audit) ─────────────────
_phase_e_security() {
    sub "E.13 SSH Hardening"
    if ensure_file /etc/ssh/sshd_config.d/hardened.conf "PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
LoginGraceTime 30"; then
        run systemctl restart sshd 2>/dev/null || true
    fi

    sub "E.14 fail2ban"
    ensure_pkg fail2ban
    if ensure_file /etc/fail2ban/jail.local "[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh"; then
        run systemctl restart fail2ban 2>/dev/null || true
    fi
    ensure_enabled fail2ban

    sub "E.15 Automatic Security Updates"
    ensure_pkg dnf5-plugin-automatic
    ensure_file /etc/dnf/automatic.conf "[commands]
upgrade_type = security
apply_updates = yes
download_updates = yes

[emitters]
emit_via = stdio" || true
    run bash -c 'systemctl enable --now dnf5-automatic-install.timer 2>/dev/null || systemctl enable --now dnf-automatic-install.timer 2>/dev/null || true'

    sub "E.16 USBGuard"
    ensure_pkg usbguard
    if [[ ! -s /etc/usbguard/rules.conf ]]; then
        run bash -c 'usbguard generate-policy > /etc/usbguard/rules.conf 2>/dev/null || true'
        count_ok "USBGuard policy generated"
    else
        count_skip "USBGuard policy"
    fi
    ensure_enabled usbguard

    sub "E.17 Core Dump Restriction"
    if grep -q '^\* hard core 0' /etc/security/limits.conf 2>/dev/null; then
        count_skip "Core dump restriction in limits.conf"
    else
        run bash -c "echo '* hard core 0' >> /etc/security/limits.conf"
        count_ok "Core dump restriction added"
    fi

    sub "E.18 Chrony NTP Hardening (NTS)"
    if ensure_file /etc/chrony.conf.d/hardened.conf "server time.cloudflare.com iburst nts
server nts.netnod.se iburst nts
server ptbtime1.ptb.de iburst nts
minsources 2
maxchange 100 1 1
makestep 1.0 3"; then
        run systemctl restart chronyd 2>/dev/null || true
    fi

    sub "E.19 Audit Rules"
    if ensure_file /etc/audit/rules.d/sensitive.rules "-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /sbin/insmod -p x -k kernel_modules
-w /sbin/modprobe -p x -k kernel_modules"; then
        run bash -c 'augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/sensitive.rules 2>/dev/null || true'
        run bash -c 'systemctl restart auditd 2>/dev/null || service auditd restart 2>/dev/null || true'
    fi

    if [[ "$DISABLE_IPV6" == "yes" ]]; then
        sub "E.20 Disable IPv6"
        if has_kernel_arg "ipv6.disable=1"; then
            count_skip "IPv6 already disabled"
        else
            run grubby --update-kernel=ALL --args='ipv6.disable=1'
            count_warn "IPv6 disabled — takes effect after reboot"
        fi
    fi
}

# ─── Phase E wrapper (preserves --phase e compatibility) ──────────────────
phase_e() {
    phase_timer_start
    phase_hdr "Phase E — System Configuration"

    _phase_e_system
    _phase_e_network
    _phase_e_services
    _phase_e_security

    flush_reload
    phase_timer_end "Phase E" "e"
}

###############################################################################
# PHASE F — Hardware
###############################################################################
phase_f() {
    phase_timer_start
    phase_hdr "Phase F — Hardware-Software Synchronization"

    sub "F.1 Automatic Profile Switching"
    ensure_udev /etc/udev/rules.d/85-power-profile.rules \
        'SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_TYPE}=="Mains", ENV{POWER_SUPPLY_ONLINE}=="1", RUN+="/usr/bin/powerprofilesctl set performance"
SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_TYPE}=="Mains", ENV{POWER_SUPPLY_ONLINE}=="0", RUN+="/usr/bin/powerprofilesctl set balanced"'

    sub "F.2 WiFi Power Save Off"
    if ensure_file /etc/NetworkManager/conf.d/wifi-powersave.conf "[connection]
wifi.powersave = 2"; then
        run systemctl restart NetworkManager 2>/dev/null || true
    fi

    sub "F.3 Bluetooth Power"
    if [[ -f /etc/bluetooth/main.conf ]]; then
        local bt_changed=false
        for key in AutoEnable ControllerMode FastConnectable; do
            grep -q "^${key}" /etc/bluetooth/main.conf 2>/dev/null || bt_changed=true
        done
        if $bt_changed; then
            run sed -i 's/^#\?AutoEnable.*/AutoEnable=true/' /etc/bluetooth/main.conf
            run sed -i 's/^#\?ControllerMode.*/ControllerMode = dual/' /etc/bluetooth/main.conf
            run sed -i 's/^#\?FastConnectable.*/FastConnectable = true/' /etc/bluetooth/main.conf
            run systemctl restart bluetooth 2>/dev/null || true
            count_ok "Bluetooth config"
        else
            count_skip "Bluetooth config"
        fi
    else
        count_warn "No bluetooth config found"
    fi

    sub "F.4 PipeWire Audio"
    local PW_CONF="context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 44100 48000 ]
    default.clock.quantum = 1024
    default.clock.min-quantum = 512
    default.clock.max-quantum = 2048
}"
    ensure_user_dir "$REAL_HOME/.config/pipewire/pipewire.conf.d"
    ensure_user_file "$REAL_HOME/.config/pipewire/pipewire.conf.d/performance.conf" "$PW_CONF" || true

    sub "F.5 Suspend/Resume (S0ix)"
    ensure_udev /etc/udev/rules.d/90-usb-wakeup.rules \
        'ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTR{power/wakeup}="disabled"'

    sub "F.6 GPU Power Cap"
    ensure_udev /etc/udev/rules.d/86-amdgpu-power.rules \
        'ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card0", RUN+="/bin/bash -c '"'"'echo 15000000 > /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap'"'"'"'

    sub "F.7 NVMe I/O Scheduler"
    ensure_udev /etc/udev/rules.d/60-io-scheduler.rules \
        'ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"'

    sub "F.8 Battery Charge Threshold"
    if [[ -n "$BAT_DEV" ]]; then
        run bash -c "echo '$BATTERY_THRESHOLD' > '/sys/class/power_supply/$BAT_DEV/charge_control_end_threshold'" 2>/dev/null || true

        ensure_systemd_unit /etc/systemd/system/battery-charge-threshold.service "[Unit]
Description=Set battery charge threshold
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
Restart=on-failure
RestartSec=5
ExecStart=/bin/bash -c 'echo $BATTERY_THRESHOLD > /sys/class/power_supply/$BAT_DEV/charge_control_end_threshold'

[Install]
WantedBy=multi-user.target"

        flush_reload
        ensure_enabled battery-charge-threshold.service

        ensure_udev /etc/udev/rules.d/87-battery-threshold.rules \
            "ACTION==\"change\", SUBSYSTEM==\"power_supply\", ATTR{type}==\"Battery\", ATTR{charge_control_end_threshold}=\"$BATTERY_THRESHOLD\""
        count_ok "Battery threshold set to ${BATTERY_THRESHOLD}%"
    else
        count_warn "No battery detected — skipping"
    fi

    sub "F.9 PCIe ASPM Force"
    if has_kernel_arg "pcie_aspm=force"; then
        count_skip "PCIe ASPM already forced"
    else
        run grubby --update-kernel=ALL --args='pcie_aspm=force pcie_aspm.policy=powersupersave'
        count_ok "PCIe ASPM forced"
    fi

    sub "F.10 Deep CPU Idle States"
    if has_kernel_arg "processor.max_cstate=9"; then
        count_skip "CPU idle states already configured"
    else
        run grubby --update-kernel=ALL --args='processor.max_cstate=9 amd_pstate.shared_mem=1'
        count_ok "CPU idle states configured"
    fi

    sub "F.11 Thermal Monitoring"
    ensure_pkg lm_sensors
    if [[ ! -f /etc/sensors.d/zenbook-detected.conf ]]; then
        run sensors-detect --auto &>/dev/null || true
        ensure_file /etc/sensors.d/zenbook-detected.conf "# Auto-detected by post-install script at $(date -Is)
# Review output of 'sensors' and adjust thresholds as needed" || true
        count_ok "sensors-detect completed"
    else
        count_skip "sensors already configured"
    fi
    ensure_systemd_unit /etc/systemd/system/thermal-monitor.service "[Unit]
Description=Multi-zone thermal threshold monitor
After=lm_sensors.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    alert=0; \
    for zone in /sys/class/thermal/thermal_zone*/temp; do \
        [ -f \"\$zone\" ] || continue; \
        name=\$(cat \"\${zone%/temp}/type\" 2>/dev/null || basename \"\${zone%/temp}\"); \
        temp_mc=\$(cat \"\$zone\" 2>/dev/null || echo 0); \
        temp_c=\$((temp_mc / 1000)); \
        if [ \"\$temp_c\" -gt 95 ]; then \
            logger -p daemon.crit \"THERMAL CRITICAL: \$name at \${temp_c}C\"; \
            alert=1; \
        elif [ \"\$temp_c\" -gt 85 ]; then \
            logger -p daemon.warning \"THERMAL WARNING: \$name at \${temp_c}C\"; \
        fi; \
    done; \
    if command -v nvme >/dev/null 2>&1; then \
        for dev in /dev/nvme[0-9]; do \
            [ -b \"\$dev\" ] || continue; \
            nvme_temp=\$(nvme smart-log \"\$dev\" 2>/dev/null | awk \"/^temperature/{gsub(/[^0-9]/,\\\"\\\",\\\$NF); print \\\$NF; exit}\"); \
            if [ -n \"\$nvme_temp\" ] && [ \"\$nvme_temp\" -gt 70 ]; then \
                logger -p daemon.crit \"THERMAL CRITICAL: NVMe \$(basename \"\$dev\") at \${nvme_temp}C\"; \
                alert=1; \
            fi; \
        done; \
    fi; \
    [ \"\$alert\" -eq 1 ] && wall \"THERMAL ALERT: critical temperature detected — check journalctl -t thermal-monitor\"; \
    exit 0'"

    ensure_systemd_unit /etc/systemd/system/thermal-monitor.timer "[Unit]
Description=Periodic thermal check

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target"
    flush_reload
    ensure_enabled thermal-monitor.timer

    sub "F.12 NVMe Health Tuning"
    if [[ -n "$NVME_DEV" ]]; then
        if ensure_file /etc/smartmontools/smartd_nvme.conf "/dev/$NVME_DEV -a -W 5,45,70 -m root -M exec /usr/libexec/smartmontools/smartdnotify"; then
            count_ok "NVMe SMART thresholds configured"
        fi
    else
        count_skip "NVMe health tuning (no NVMe detected)"
    fi

    phase_timer_end "Phase F (reboot needed for kernel params)" "f"
}

###############################################################################
# PHASE G — OLED Display
###############################################################################
phase_g() {
    phase_timer_start
    phase_hdr "Phase G — OLED Display Optimization"

    sub "G.1 Font Rendering"
    user_gsettings org.gnome.desktop.interface font-antialiasing 'grayscale'
    user_gsettings org.gnome.desktop.interface font-hinting 'slight'

    sub "G.2 ABR and PSR Tuning"
    if has_kernel_arg "amdgpu.abmlevel=0"; then
        count_skip "AMDGPU ABR/PSR already configured"
    else
        run grubby --update-kernel=ALL --args='amdgpu.dcdebugmask=0x10 amdgpu.abmlevel=0'
        count_ok "AMDGPU ABR/PSR configured"
    fi

    sub "G.3 Burn-in Prevention"
    user_gsettings org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 300
    user_gsettings org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 900

    phase_timer_end "Phase G" "g"
}

###############################################################################
# PHASE H — GNOME
###############################################################################
phase_h() {
    phase_timer_start
    phase_hdr "Phase H — GNOME Minimalism"

    sub "H.1 Remove Bloat"
    local bloat_pkgs=()
    for pkg in gnome-maps gnome-contacts gnome-weather gnome-clocks gnome-tour \
               gnome-connections gnome-characters gnome-font-viewer gnome-abrt \
               mediawriter rhythmbox totem cheese simple-scan yelp gnome-photos \
               gnome-music gnome-boxes gnome-calendar fedora-bookmarks \
               fedora-chromium-config; do
        rpm -q "$pkg" &>/dev/null && bloat_pkgs+=("$pkg")
    done
    if rpm -qa 'libreoffice-*' 2>/dev/null | grep -q libreoffice; then
        bloat_pkgs+=(libreoffice-\*)
    fi
    if [[ ${#bloat_pkgs[@]} -gt 0 ]]; then
        run dnf remove -y "${bloat_pkgs[@]}" 2>/dev/null || true
        count_ok "Removed ${#bloat_pkgs[@]} bloat packages"
    else
        count_skip "Bloat packages already removed"
    fi

    sub "H.2 GNOME Settings"
    user_gsettings org.gnome.desktop.interface color-scheme 'prefer-dark'
    user_gsettings org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
    user_gsettings org.gnome.desktop.background picture-options 'none'
    user_gsettings org.gnome.desktop.background primary-color '#000000'
    user_gsettings org.gnome.desktop.screensaver picture-options 'none'
    user_gsettings org.gnome.desktop.screensaver primary-color '#000000'
    user_gsettings org.gnome.desktop.interface enable-hot-corners false
    user_gsettings org.gnome.desktop.interface clock-show-date true
    user_gsettings org.gnome.desktop.interface show-battery-percentage true
    user_gsettings org.gnome.desktop.sound event-sounds false
    user_gsettings org.gnome.desktop.session idle-delay 180
    user_gsettings org.gnome.desktop.screensaver lock-enabled true
    user_gsettings org.gnome.desktop.screensaver lock-delay 0
    user_gsettings org.gnome.settings-daemon.plugins.color night-light-enabled true
    user_gsettings org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
    user_gsettings org.gnome.settings-daemon.plugins.color night-light-temperature 3500
    user_gsettings org.gnome.desktop.wm.preferences resize-with-right-button true
    user_gsettings org.gnome.mutter workspaces-only-on-primary false
    user_gsettings org.gnome.system.location enabled false
    user_gsettings org.gnome.desktop.privacy report-technical-problems false
    user_gsettings org.gnome.desktop.privacy recent-files-max-age 7
    user_gsettings org.gnome.desktop.privacy remove-old-temp-files true
    user_gsettings org.gnome.desktop.privacy old-files-age 7

    sub "H.3 Tracker3"
    user_gsettings org.freedesktop.Tracker3.Miner.Files index-recursive-directories "['&DESKTOP', '&DOCUMENTS', '&PICTURES', '&DOWNLOAD']"
    user_gsettings org.freedesktop.Tracker3.Miner.Files index-on-battery false
    user_gsettings org.freedesktop.Tracker3.Miner.Files index-removable-devices false
    user_gsettings org.freedesktop.Tracker3.Miner.Files crawling-interval -1
    if [[ -f "$REAL_HOME/projects/.trackerignore" ]]; then
        count_skip ".trackerignore"
    else
        run sudo -u "$REAL_USER" touch "$REAL_HOME/projects/.trackerignore"
        count_ok ".trackerignore created"
    fi

    sub "H.4 Keyboard Shortcuts"
    user_gsettings org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
    user_gsettings org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Terminal'
    user_gsettings org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'ghostty'
    user_gsettings org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>Return'

    sub "H.5 GNOME Memory Optimization"
    user_gsettings org.gnome.software download-updates false
    user_gsettings org.gnome.software download-updates-notify false

    sub "H.6 Nautilus Performance"
    user_gsettings org.gnome.nautilus.preferences show-hidden-files false
    user_gsettings org.gnome.nautilus.preferences default-folder-viewer 'list-view'
    user_gsettings org.gnome.nautilus.list-view default-zoom-level 'small'
    user_gsettings org.gtk.Settings.FileChooser sort-directories-first true

    phase_timer_end "Phase H" "h"
}

###############################################################################
# PHASE I — Development Environment
###############################################################################
phase_i() {
    phase_timer_start
    phase_hdr "Phase I — Development Environment"

    sub "I.1 System Packages"
    require_network "development packages"
    if ! dnf group list --installed 2>/dev/null | grep -qi "development.*tools"; then
        run bash -c 'dnf group install -y development-tools c-development 2>/dev/null || dnf group install -y "Development Tools" "C Development Tools and Libraries" 2>/dev/null || true'
        count_ok "Development Tools group"
    else
        count_skip "Development Tools group"
    fi

    local dev_pkgs=(gcc gcc-c++ gcc-gfortran make cmake ninja-build meson clang llvm lld
        python3-devel python3.12 python3.11 golang rust cargo
        openssl-devel libffi-devel zlib-ng-compat-devel bzip2-devel readline-devel sqlite-devel
        xz-devel tk-devel blas-devel lapack-devel openblas-devel hdf5-devel
        git git-lfs git-delta podman podman-compose buildah skopeo
        btop iotop-c powertop tmux neovim jq yq ripgrep fd-find bat fzf ShellCheck
        strace perf stress-ng lm_sensors nvme-cli smartmontools btrfs-progs compsize
        wget2 curl rsync bc wl-clipboard audit policycoreutils-python-utils borgbackup)
    local missing_dev=()
    for pkg in "${dev_pkgs[@]}"; do
        rpm -q "$pkg" &>/dev/null || missing_dev+=("$pkg")
    done
    if [[ ${#missing_dev[@]} -gt 0 ]]; then
        run dnf install -y --skip-unavailable "${missing_dev[@]}"
        count_ok "Installed ${#missing_dev[@]} dev packages"
    else
        count_skip "All dev packages installed"
    fi

    sub "I.2 eza"
    if command -v eza &>/dev/null; then
        count_skip "eza"
    else
        run dnf copr enable -y atim/eza 2>/dev/null || true
        if ! run dnf install -y eza 2>/dev/null; then
            info "COPR package unavailable, building from source..."
            if command -v cargo &>/dev/null; then
                run sudo -u "$REAL_USER" cargo install eza 2>/dev/null || true
                if command -v eza &>/dev/null || [[ -f "$REAL_HOME/.cargo/bin/eza" ]]; then
                    count_ok "eza installed via cargo"
                else
                    count_warn "eza build failed"
                fi
            else
                count_warn "eza unavailable — install manually: cargo install eza"
            fi
        else
            count_ok "eza installed"
        fi
    fi

    sub "I.3 Flatpak & VS Code"
    run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
    if flatpak list --app 2>/dev/null | grep -q com.visualstudio.code; then
        count_skip "VS Code Flatpak"
    else
        run flatpak install -y flathub com.visualstudio.code 2>/dev/null || true
        count_ok "VS Code Flatpak installed"
    fi
    run flatpak override --user com.visualstudio.code --filesystem=home --filesystem=/tmp --filesystem=xdg-run/podman:ro --env=ELECTRON_OZONE_PLATFORM_HINT=auto 2>/dev/null || true

    sub "I.4 Git Configuration"
    local -A git_settings=(
        ["user.name"]="$GIT_NAME"
        ["user.email"]="$GIT_EMAIL"
        ["core.pager"]="delta"
        ["interactive.diffFilter"]="delta --color-only"
        ["delta.navigate"]="true"
        ["delta.dark"]="true"
        ["delta.line-numbers"]="true"
        ["delta.side-by-side"]="true"
        ["core.fsmonitor"]="true"
        ["core.untrackedCache"]="true"
        ["feature.manyFiles"]="true"
        ["init.defaultBranch"]="main"
        ["pull.rebase"]="true"
        ["merge.conflictstyle"]="zdiff3"
        ["gpg.format"]="ssh"
        ["commit.gpgsign"]="true"
        ["tag.gpgsign"]="true"
    )
    local git_changed=false
    for key in "${!git_settings[@]}"; do
        local current_val
        current_val=$(sudo -u "$REAL_USER" git config --global --get "$key" 2>/dev/null || true)
        if [[ "$current_val" != "${git_settings[$key]}" ]]; then
            run sudo -u "$REAL_USER" git config --global "$key" "${git_settings[$key]}"
            git_changed=true
        fi
    done
    if $git_changed; then count_ok "Git config applied"; else count_skip "Git config"; fi

    sub "I.5 Python Environment"
    ensure_user_dir "$REAL_HOME/.config/pip"
    ensure_user_file "$REAL_HOME/.config/pip/pip.conf" "[global]
require-virtualenv = true" || true

    sub "I.6 Podman Rootless"
    if grep -q "^${REAL_USER}:" /etc/subuid 2>/dev/null; then
        count_skip "subuid/subgid"
    else
        run usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$REAL_USER"
        count_ok "subuid/subgid configured"
    fi
    ensure_user_dir "$REAL_HOME/.config/containers"
    ensure_user_file "$REAL_HOME/.config/containers/registries.conf" \
        'unqualified-search-registries = ["docker.io", "quay.io", "ghcr.io"]' || true

    sub "I.7 Shell Configuration"
    if grep -q "# --- Fedora 43 Post-Install ---" "$REAL_HOME/.bashrc" 2>/dev/null; then
        count_skip ".bashrc already configured"
    else
        if ! $DRY_RUN; then
            sudo -u "$REAL_USER" tee -a "$REAL_HOME/.bashrc" > /dev/null << 'BASHRC'

# --- Fedora 43 Post-Install ---
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT="%F %T "
shopt -s histappend

eval "$(fzf --bash)"

export OPENBLAS_NUM_THREADS=8
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
export NUMEXPR_MAX_THREADS=8
export GOPATH=$HOME/go
export GOBIN=$HOME/go/bin
export PATH=$PATH:$GOBIN
export ELECTRON_OZONE_PLATFORM_HINT=auto
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1

alias upgrade='sudo /usr/local/bin/safe-upgrade'
alias health='sudo /usr/local/bin/system-health'
alias snap='sudo /usr/local/bin/btrfs-snapshot'
alias top='btop'
alias ls='eza --group-directories-first'
alias ll='eza -la --group-directories-first --git'
alias cat='bat --plain'
alias grep='rg'
alias find='fd'
BASHRC
        else
            echo -e "  ${YEL}[DRY-RUN]${RST} append to .bashrc"
        fi
        count_ok "Shell config appended to .bashrc"
    fi

    sub "I.8 SSH Keys"
    if [[ -f "$REAL_HOME/.ssh/id_ed25519" ]]; then
        count_skip "SSH key exists"
    else
        ensure_user_dir "$REAL_HOME/.ssh/sockets"
        run chmod 700 "$REAL_HOME/.ssh" "$REAL_HOME/.ssh/sockets"
        info "Generating SSH key (you may be prompted for a passphrase)..."
        if ! $DRY_RUN; then
            sudo -u "$REAL_USER" ssh-keygen -t ed25519 -C "${REAL_USER}@${HOSTNAME_CURRENT}" -f "$REAL_HOME/.ssh/id_ed25519"
        fi
        run sudo -u "$REAL_USER" git config --global user.signingkey "$REAL_HOME/.ssh/id_ed25519.pub"
        count_ok "SSH key generated"
    fi

    local SSH_USER_CONF="Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
    ServerAliveInterval 30
    ServerAliveCountMax 10
    Compression yes
    IdentityFile ~/.ssh/id_ed25519
    GSSAPIAuthentication no
    PasswordAuthentication no
    AddKeysToAgent yes"
    if [[ "$GPU_SERVER_IP" != "skip" ]]; then
        SSH_USER_CONF+="

Host gpu
    HostName $GPU_SERVER_IP
    User $GPU_SERVER_USER
    ForwardAgent yes"
    fi
    ensure_user_dir "$REAL_HOME/.ssh/sockets"
    if ensure_user_file "$REAL_HOME/.ssh/config" "$SSH_USER_CONF"; then
        run chmod 600 "$REAL_HOME/.ssh/config"
    fi

    sub "I.9 Ollama (Local LLM)"
    if command -v ollama &>/dev/null; then
        count_skip "Ollama"
    else
        run bash -c 'curl -fsSL https://ollama.com/install.sh | sh'
        count_ok "Ollama installed"
    fi
    ensure_systemd_unit /etc/systemd/system/ollama.service.d/resources.conf '[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"'
    flush_reload
    ensure_enabled ollama

    sub "I.10 zram Swap"
    ensure_pkg zram-generator
    if ensure_systemd_unit /etc/systemd/zram-generator.conf "[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100"; then
        flush_reload
    fi

    sub "I.11 Podman Lingering"
    if loginctl show-user "$REAL_USER" 2>/dev/null | grep -q "Linger=yes"; then
        count_skip "Podman lingering"
    else
        run loginctl enable-linger "$REAL_USER" 2>/dev/null || true
        count_ok "Podman lingering enabled"
    fi

    sub "I.12 Node.js via fnm"
    if sudo -u "$REAL_USER" bash -c 'command -v fnm' &>/dev/null || [[ -d "$REAL_HOME/.local/share/fnm" ]]; then
        count_skip "fnm"
    else
        run sudo -u "$REAL_USER" bash -c 'curl -fsSL https://fnm.vercel.app/install | bash' 2>/dev/null || true
        count_ok "fnm installed"
    fi

    sub "I.13 Podman-Docker Compatibility"
    ensure_pkg podman-docker

    sub "I.14 Neovim Configuration"
    if [[ -d "$REAL_HOME/.config/nvim" ]]; then
        count_skip "Neovim config exists"
    else
        run sudo -u "$REAL_USER" git clone https://github.com/nvim-lua/kickstart.nvim.git "$REAL_HOME/.config/nvim" 2>/dev/null || true
        count_ok "Neovim kickstart cloned"
    fi

    sub "I.15 tmux Configuration"
    ensure_user_file "$REAL_HOME/.tmux.conf" 'set -g default-terminal "tmux-256color"
set -g history-limit 50000
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g status-interval 5
set -g focus-events on
set -sg escape-time 10
unbind C-b
set -g prefix C-a
bind C-a send-prefix
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"' || true

    sub "I.16 Python uv"
    if sudo -u "$REAL_USER" bash -c 'command -v uv' &>/dev/null || [[ -f "$REAL_HOME/.local/bin/uv" ]]; then
        count_skip "uv"
    else
        run sudo -u "$REAL_USER" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' 2>/dev/null || true
        count_ok "uv installed"
    fi

    sub "I.17 Rust via rustup"
    if sudo -u "$REAL_USER" bash -c 'command -v rustup' &>/dev/null || [[ -f "$REAL_HOME/.cargo/bin/rustup" ]]; then
        count_skip "rustup"
    else
        run dnf remove -y rust cargo 2>/dev/null || true
        run sudo -u "$REAL_USER" bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" 2>/dev/null || true
        count_ok "rustup installed"
    fi

    sub "I.18 Global .gitignore"
    ensure_user_dir "$REAL_HOME/.config/git"
    if ensure_user_file "$REAL_HOME/.config/git/ignore" ".DS_Store
*.swp
*.swo
*~
.idea/
.vscode/
*.pyc
__pycache__/
.env
.env.local
node_modules/
.venv/"; then
        run sudo -u "$REAL_USER" git config --global core.excludesfile "$REAL_HOME/.config/git/ignore"
    fi

    sub "I.19 Starship Prompt"
    if command -v starship &>/dev/null; then
        count_skip "Starship"
    else
        run bash -c 'curl -sS https://starship.rs/install.sh | sh -s -- -y 2>/dev/null || true'
        count_ok "Starship installed"
    fi
    if ! grep -q 'starship init bash' "$REAL_HOME/.bashrc" 2>/dev/null; then
        if ! $DRY_RUN; then
            sudo -u "$REAL_USER" tee -a "$REAL_HOME/.bashrc" > /dev/null << 'STAR'
eval "$(starship init bash)"
STAR
        else
            echo -e "  ${YEL}[DRY-RUN]${RST} append starship init to .bashrc"
        fi
        count_ok "Starship in .bashrc"
    else
        count_skip "Starship in .bashrc"
    fi

    sub "I.20 Ghostty Terminal"
    if command -v ghostty &>/dev/null; then
        count_skip "Ghostty"
    else
        run dnf copr enable -y pgdev/ghostty 2>/dev/null || true
        run dnf install -y ghostty 2>/dev/null || true
        if command -v ghostty &>/dev/null; then count_ok "Ghostty installed"; else count_warn "Ghostty unavailable"; fi
    fi

    flush_reload
    phase_timer_end "Phase I" "i"
}

###############################################################################
# PHASE J — Snapshot Automation
###############################################################################
phase_j() {
    phase_timer_start
    phase_hdr "Phase J — Snapshot Automation and Tools"

    local PROJECTS_MOUNT
    PROJECTS_MOUNT=$(findmnt -n -o TARGET -t btrfs 2>/dev/null | grep '/projects$' | head -1 || echo "$REAL_HOME/projects")

    sub "J.1 Snapshot Manager"
    local snap_src="$SCRIPT_DIR/scripts/btrfs-snapshot.sh"
    local snap_tmp
    snap_tmp=$(mktemp)
    export __PROJECTS_MOUNT__="$PROJECTS_MOUNT"
    envsubst '$__PROJECTS_MOUNT__' < "$snap_src" > "$snap_tmp" 2>/dev/null || sed "s|__PROJECTS_MOUNT__|$PROJECTS_MOUNT|g" "$snap_src" > "$snap_tmp"
    ensure_script_content /usr/local/bin/btrfs-snapshot "$(cat "$snap_tmp")"
    rm -f "$snap_tmp"

    sub "J.2 Safe Upgrade"
    ensure_script /usr/local/bin/safe-upgrade "$SCRIPT_DIR/scripts/safe-upgrade.sh"

    sub "J.3 System Health Dashboard"
    ensure_script /usr/local/bin/system-health "$SCRIPT_DIR/scripts/system-health.sh"

    sub "J.4 Automated Timers"

    ensure_systemd_unit /etc/systemd/system/notify-failure@.service "[Unit]
Description=Timer failure notification for %i

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo \"FAILED: %i at \$(date)\" | systemd-cat -t timer-failure -p err'
ExecStart=/bin/bash -c 'wall \"Systemd timer FAILED: %i\"'"

    ensure_systemd_unit /etc/systemd/system/btrfs-snap-weekly.service "[Unit]
Description=Weekly coordinated snapshot
OnFailure=notify-failure@%n.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot group weekly
ExecStartPost=/usr/bin/notify-send -u low \"Btrfs Snapshot\" \"Weekly snapshot complete\""

    ensure_systemd_unit /etc/systemd/system/btrfs-snap-weekly.timer "[Unit]
Description=Weekly coordinated snapshot
[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
[Install]
WantedBy=timers.target"

    ensure_systemd_unit /etc/systemd/system/btrfs-snap-clean.service "[Unit]
Description=Monthly snapshot cleanup
OnFailure=notify-failure@%n.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot clean 5"

    ensure_systemd_unit /etc/systemd/system/btrfs-snap-clean.timer "[Unit]
Description=Monthly snapshot cleanup
[Timer]
OnCalendar=*-*-01 04:00:00
Persistent=true
[Install]
WantedBy=timers.target"

    flush_reload
    ensure_enabled btrfs-snap-weekly.timer
    ensure_enabled btrfs-snap-clean.timer
    ensure_enabled fstrim.timer
    run systemctl enable --now btrfs-scrub@-.timer 2>/dev/null || true

    phase_timer_end "Phase J" "j"
}

###############################################################################
# PHASE K — Backup & Maintenance
###############################################################################
phase_k() {
    phase_timer_start
    phase_hdr "Phase K — Backup, Baseline, and Maintenance"

    sub "K.1 BorgBackup Script"
    if [[ "$BORG_LOCAL" != "skip" ]]; then
        local borg_src="$SCRIPT_DIR/scripts/backup-borg.sh"
        local borg_tmp
        borg_tmp=$(mktemp)
        export __BORG_REPO__="$BORG_LOCAL" __REAL_USER__="$REAL_USER"
        envsubst '$__BORG_REPO__ $__REAL_USER__' < "$borg_src" > "$borg_tmp" 2>/dev/null || sed -e "s|__BORG_REPO__|$BORG_LOCAL|g" -e "s|__REAL_USER__|$REAL_USER|g" "$borg_src" > "$borg_tmp"
        ensure_script_content /usr/local/bin/backup-borg "$(cat "$borg_tmp")"
        rm -f "$borg_tmp"
    fi

    sub "K.2 Performance Baseline"
    ensure_script /usr/local/bin/perf-baseline "$SCRIPT_DIR/scripts/perf-baseline.sh"

    sub "K.3 Flatpak Auto-Update Timer"
    ensure_systemd_unit /etc/systemd/system/flatpak-update.service "[Unit]
Description=Flatpak auto-update
OnFailure=notify-failure@%n.service
[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update -y --noninteractive"

    ensure_systemd_unit /etc/systemd/system/flatpak-update.timer "[Unit]
Description=Weekly Flatpak update
[Timer]
OnCalendar=Wed *-*-* 04:00:00
Persistent=true
[Install]
WantedBy=timers.target"
    flush_reload
    ensure_enabled flatpak-update.timer

    sub "K.4 SMART Monitoring"
    ensure_pkg smartmontools
    ensure_enabled smartd

    sub "K.5 Remote Backup"
    if [[ "$BORG_REMOTE" != "skip" ]]; then
        local borg_remote_src="$SCRIPT_DIR/scripts/backup-borg-remote.sh"
        local borg_remote_tmp
        borg_remote_tmp=$(mktemp)
        export __BORG_REPO__="$BORG_REMOTE" __REAL_USER__="$REAL_USER"
        envsubst '$__BORG_REPO__ $__REAL_USER__' < "$borg_remote_src" > "$borg_remote_tmp" 2>/dev/null || sed -e "s|__BORG_REPO__|$BORG_REMOTE|g" -e "s|__REAL_USER__|$REAL_USER|g" "$borg_remote_src" > "$borg_remote_tmp"
        ensure_script_content /usr/local/bin/backup-borg-remote "$(cat "$borg_remote_tmp")"
        rm -f "$borg_remote_tmp"

        ensure_systemd_unit /etc/systemd/system/backup-borg-remote.service "[Unit]
Description=Weekly remote BorgBackup
After=network-online.target
Wants=network-online.target
OnFailure=notify-failure@%n.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-borg-remote"

        ensure_systemd_unit /etc/systemd/system/backup-borg-remote.timer "[Unit]
Description=Weekly remote backup
[Timer]
OnCalendar=Sat *-*-* 02:00:00
Persistent=true
[Install]
WantedBy=timers.target"
        flush_reload
        ensure_enabled backup-borg-remote.timer
    fi

    sub "K.6 RPM Integrity Baseline"
    if [[ -f /var/log/rpm-verify-baseline.txt ]]; then
        count_skip "RPM integrity baseline"
    else
        if $DRY_RUN; then
            echo -e "  ${YEL}[DRY-RUN]${RST} rpm -Va > /var/log/rpm-verify-baseline.txt"
        else
            rpm -Va > /var/log/rpm-verify-baseline.txt 2>/dev/null || true
            count_ok "RPM integrity baseline saved"
        fi
    fi
    ensure_systemd_unit /etc/systemd/system/rpm-integrity-check.service "[Unit]
Description=RPM integrity check against baseline
OnFailure=notify-failure@%n.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    current=\$(mktemp); \
    rpm -Va > \"\$current\" 2>/dev/null || true; \
    if ! diff -q /var/log/rpm-verify-baseline.txt \"\$current\" >/dev/null 2>&1; then \
        new_changes=\$(diff /var/log/rpm-verify-baseline.txt \"\$current\" | grep \"^>\" | head -20); \
        logger -p daemon.warning -t rpm-integrity \"New RPM verification discrepancies detected\"; \
        wall \"RPM INTEGRITY: new discrepancies detected — check journalctl -t rpm-integrity\"; \
        echo \"\$new_changes\" | systemd-cat -t rpm-integrity -p warning; \
    fi; \
    rm -f \"\$current\"'"

    ensure_systemd_unit /etc/systemd/system/rpm-integrity-check.timer "[Unit]
Description=Weekly RPM integrity check

[Timer]
OnCalendar=Sun *-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target"
    flush_reload
    ensure_enabled rpm-integrity-check.timer

    sub "K.7 Post-Reboot Verification"
    ensure_systemd_unit /etc/systemd/system/post-setup-verify.service "[Unit]
Description=Post-setup health verification (runs once)
After=multi-user.target network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/post-setup-pending

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-health
ExecStartPost=/bin/rm -f /var/lib/post-setup-pending
StandardOutput=journal+console
RemainAfterExit=no

[Install]
WantedBy=multi-user.target"
    flush_reload
    run systemctl enable post-setup-verify.service 2>/dev/null || true

    phase_timer_end "Phase K" "k"
}

###############################################################################
# MAIN EXECUTION
###############################################################################
hdr "Fedora 43 Post-Installation Script  v${SCRIPT_VERSION}"
echo -e "  Phases: ${BLD}${SELECTED_PHASES}${RST}"
echo -e "  Dry-run: ${BLD}${DRY_RUN}${RST}"
echo -e "  Log: ${BLD}${LOG_FILE}${RST}"

SCRIPT_START=$(date +%s)

# Pre-run safety snapshot
if ! $DRY_RUN && command -v btrfs &>/dev/null && [[ -d "/.snapshots" ]] && [[ -x /usr/local/bin/btrfs-snapshot ]]; then
    info "Creating pre-run safety snapshot..."
    /usr/local/bin/btrfs-snapshot group pre-setup 2>/dev/null || warn "Pre-run snapshot failed (non-fatal)"
fi

should_run d && phase_d
should_run e && phase_e
should_run f && phase_f
should_run g && phase_g
should_run h && phase_h
should_run i && phase_i
should_run j && phase_j
should_run k && phase_k

# Set post-reboot verification flag
if ! $DRY_RUN; then
    touch /var/lib/post-setup-pending 2>/dev/null || true
fi

SCRIPT_ELAPSED=$(( $(date +%s) - SCRIPT_START ))

hdr "Summary"
echo -e "  ${GRN}✓ Applied:${RST}  $TOTAL_OK"
echo -e "  ${DIM}– Skipped:${RST}  $TOTAL_SKIP"
echo -e "  ${YEL}⚠ Warnings:${RST} $TOTAL_WARN"
echo -e "  ${RED}✗ Errors:${RST}   $TOTAL_ERR"
echo ""
echo -e "  ${CYN}Timing:${RST}"
for t in "${PHASE_TIMES[@]}"; do
    echo -e "    ${t%%:*}: ${BLD}${t#*:}${RST}"
done
echo -e "    ${BLD}Total: ${SCRIPT_ELAPSED}s${RST}"
echo ""

# ─── Markdown Summary Report ───────────────────────────────────────────────
REPORT_FILE="${REAL_HOME}/fedora-setup-report.md"
if ! $DRY_RUN; then
    cat > "$REPORT_FILE" <<REPORT
# Fedora 43 Post-Install Report

**Date:** $(date -Is)
**Version:** $SCRIPT_VERSION
**Phases:** $SELECTED_PHASES
**Duration:** ${SCRIPT_ELAPSED}s

| Metric | Count |
|---|---|
| ✓ Applied | $TOTAL_OK |
| – Skipped | $TOTAL_SKIP |
| ⚠ Warnings | $TOTAL_WARN |
| ✗ Errors | $TOTAL_ERR |

## Phase Timing

| Phase | Duration |
|---|---|
$(for t in "${PHASE_TIMES[@]}"; do echo "| ${t%%:*} | ${t#*:} |"; done)
| **Total** | **${SCRIPT_ELAPSED}s** |

## Next Steps

1. Reboot: \`sudo reboot\`
2. Verify: \`sudo system-health\`
3. Verify snapshots: \`sudo btrfs-snapshot verify\`
REPORT
    chown "$REAL_USER:$REAL_USER" "$REPORT_FILE"
    info "Report saved to: $REPORT_FILE"
fi

info "Log saved to: $LOG_FILE"
info "Reboot to apply kernel parameters and udev rules:"
echo -e "  ${BLD}sudo reboot${RST}"
echo ""
info "After reboot, verify with:"
echo -e "  ${BLD}sudo system-health${RST}"
echo -e "  ${BLD}sudo btrfs-snapshot verify${RST}"
echo ""

# ─── Desktop Notification on Completion ────────────────────────────────────
if ! $DRY_RUN && command -v notify-send &>/dev/null; then
    sudo -u "$REAL_USER" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
        notify-send -u normal "Fedora Setup Complete" \
        "✓ $TOTAL_OK applied, ⚠ $TOTAL_WARN warnings, ✗ $TOTAL_ERR errors (${SCRIPT_ELAPSED}s)" 2>/dev/null || true
fi
