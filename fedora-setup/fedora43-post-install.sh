#!/bin/bash
###############################################################################
# Fedora 43 Post-Installation Script
# ASUS Zenbook S 13 OLED (UM5302TA) · Samsung 990 Pro 1TB
#
# Automates Phases D–K from fedora43-zenbook-final.md
# Run AFTER completing Phases A–C (BIOS, install, Btrfs subvolumes)
#
# Usage:
#   sudo ./fedora43-post-install.sh --all
#   sudo ./fedora43-post-install.sh --phase d,e,f
#   sudo ./fedora43-post-install.sh --dry-run --all
#   sudo ./fedora43-post-install.sh --list
###############################################################################
set -uo pipefail

# ─── Colors & Output ────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

ok()   { echo -e "  ${GRN}✓${RST} $1"; }
err()  { echo -e "  ${RED}✗${RST} $1"; }
warn() { echo -e "  ${YEL}⚠${RST} $1"; }
info() { echo -e "  ${CYN}→${RST} $1"; }
hdr()  { echo -e "\n${BLD}═══ $1 ═══${RST}\n"; }
sub()  { echo -e "\n${BLD}--- $1 ---${RST}"; }

LOG_FILE="${HOME}/fedora-setup.log"
DRY_RUN=false
SELECTED_PHASES=""

# ─── Logging ────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Fedora 43 Post-Install · $(date -Is) ===" >> "$LOG_FILE"

# ─── CLI Parsing ────────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all          Run all phases (D–K)"
    echo "  --phase X,Y    Run specific phases (e.g., --phase d,e,f)"
    echo "  --dry-run      Show what would be done without executing"
    echo "  --list         List all available phases"
    echo "  --help         Show this help"
    exit 0
}

list_phases() {
    echo "Available phases:"
    echo "  d  - First Boot (mount points, SELinux, update)"
    echo "  e  - System Configuration (DNF, kernel, sysctl, security)"
    echo "  f  - Hardware Optimization (power, GPU, NVMe, battery)"
    echo "  g  - OLED Display (scaling, fonts, ABR, burn-in)"
    echo "  h  - GNOME Minimalism (remove bloat, configure, Tracker)"
    echo "  i  - Development Environment (packages, tools, shell)"
    echo "  j  - Snapshot Automation (scripts, timers)"
    echo "  k  - Backup & Maintenance (Borg, baseline, verification)"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)      SELECTED_PHASES="d,e,f,g,h,i,j,k"; shift ;;
        --phase)    SELECTED_PHASES="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --list)     list_phases ;;
        --help|-h)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$SELECTED_PHASES" ]] && { echo "Error: specify --all or --phase X,Y"; usage; }

should_run() { echo ",$SELECTED_PHASES," | grep -qi ",$1,"; }

run() {
    if $DRY_RUN; then
        echo -e "  ${YEL}[DRY-RUN]${RST} $*"
    else
        eval "$@"
    fi
}

# ─── Root Check ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
    echo "Error: This script must be run as root (sudo)."
    echo "  sudo $0 $*"
    exit 1
fi

# ─── Auto-Detection ────────────────────────────────────────────────────────
hdr "Auto-Detecting System Configuration"

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")

SWAP_UUID=$(blkid -t TYPE=swap -s UUID -o value 2>/dev/null | head -1 || echo "")
BTRFS_UUID=$(findmnt -n -o UUID / 2>/dev/null || echo "")
NVME_DEV=$(lsblk -dno NAME,TRAN 2>/dev/null | awk '$2=="nvme"{print $1; exit}' || echo "")
BAT_DEV=$(ls /sys/class/power_supply/ 2>/dev/null | grep -i bat | head -1 || echo "")
CPU_DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
GPU_DRIVER=$(lspci -k 2>/dev/null | awk '/VGA/{found=1} found && /Kernel driver/{print $NF; exit}' || echo "unknown")
HOSTNAME_CURRENT=$(hostnamectl hostname 2>/dev/null || hostname)
TOTAL_RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "16")

info "User:       ${BLD}$REAL_USER${RST} ($REAL_HOME)"
info "Hostname:   ${BLD}$HOSTNAME_CURRENT${RST}"
info "Swap UUID:  ${BLD}${SWAP_UUID:-NOT FOUND}${RST}"
info "Btrfs UUID: ${BLD}${BTRFS_UUID:-NOT FOUND}${RST}"
info "NVMe:       ${BLD}${NVME_DEV:-NOT FOUND}${RST}"
info "Battery:    ${BLD}${BAT_DEV:-NOT FOUND}${RST}"
info "CPU Driver: ${BLD}$CPU_DRIVER${RST}"
info "GPU Driver: ${BLD}$GPU_DRIVER${RST}"
info "RAM:        ${BLD}${TOTAL_RAM_GB} GB${RST}"

# ─── Interactive Setup ──────────────────────────────────────────────────────
hdr "Interactive Setup — Please Answer the Following"

ask() {
    local var="$1" prompt="$2" default="$3"
    local response
    read -rp "$(echo -e "  ${CYN}?${RST} ${prompt} [${default}]: ")" response
    eval "$var=\"${response:-$default}\""
}

ask GIT_NAME       "Your full name (for Git)"              "$REAL_USER"
ask GIT_EMAIL      "Your email (for Git commits)"          "${REAL_USER}@${HOSTNAME_CURRENT}"
ask GPU_SERVER_IP  "Remote GPU server IP (or 'skip')"      "skip"
ask GPU_SERVER_USER "Remote GPU server username"            "$REAL_USER"
ask BATTERY_THRESHOLD "Battery charge limit % (60-100)"    "80"
ask BORG_LOCAL     "BorgBackup local repo path (or 'skip')" "/run/media/${REAL_USER}/backup-drive/borg-zenbook"
ask BORG_REMOTE    "BorgBackup remote repo (or 'skip')"    "skip"
ask DISABLE_IPV6   "Disable IPv6? (yes/no)"                "no"

echo ""
info "Configuration saved. Starting in 3 seconds... (Ctrl+C to abort)"
$DRY_RUN || sleep 3

###############################################################################
# PHASE D — First Boot
###############################################################################
phase_d() {
    hdr "Phase D — First Boot"

    sub "D.1 Mount Points & Ownership"
    run "sudo -u $REAL_USER mkdir -p $REAL_HOME/projects"
    run "systemctl daemon-reload"
    run "mount -a 2>/dev/null || true"
    run "chown $REAL_USER:$REAL_USER $REAL_HOME/projects"
    run "restorecon -Rv /var/log /var/cache /var/tmp /var/lib/containers /.snapshots $REAL_HOME/projects 2>/dev/null || true"

    MOUNTS=$(findmnt -t btrfs --noheadings 2>/dev/null | wc -l)
    [[ "$MOUNTS" -ge 8 ]] && ok "All $MOUNTS Btrfs mounts present" || warn "Only $MOUNTS/8 Btrfs mounts"

    sub "D.2 Verify SELinux"
    SE=$(getenforce 2>/dev/null || echo "unknown")
    [[ "$SE" == "Enforcing" ]] && ok "SELinux: Enforcing" || err "SELinux: $SE (should be Enforcing)"

    sub "D.3 Full System Update"
    run "dnf upgrade -y --refresh"

    sub "D.4 Firmware Updates"
    run "fwupdmgr refresh --force 2>/dev/null || true"
    run "fwupdmgr update 2>/dev/null || warn 'No firmware updates or needs reboot'"

    ok "Phase D complete"
}

###############################################################################
# PHASE E — System Configuration
###############################################################################
phase_e() {
    hdr "Phase E — System Configuration"

    sub "E.1 DNF Configuration"
    run "tee /etc/dnf/dnf.conf << 'CONF'
[main]
max_parallel_downloads=10
fastestmirror=True
keepcache=True
installonly_limit=4
skip_if_unavailable=True
install_weak_deps=True
clean_requirements_on_remove=True
defaultyes=True
metadata_expire=172800
CONF"

    sub "E.2 RPM Fusion & Codecs"
    run "dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm"
    run "dnf swap -y ffmpeg-free ffmpeg --allowerasing 2>/dev/null || true"
    run "dnf install -y gstreamer1-plugins-bad-free gstreamer1-plugins-ugly gstreamer1-plugin-libav libva-utils mesa-va-drivers mesa-vulkan-drivers"

    sub "E.3 Kernel Parameters"
    if [[ -n "$SWAP_UUID" ]]; then
        PARAMS="amd_pstate=active amd_iommu=on iommu=pt transparent_hugepage=madvise"
        PARAMS+=" nowatchdog nmi_watchdog=0 workqueue.power_efficient=1 pcie_aspm=default"
        PARAMS+=" mitigations=auto resume=UUID=$SWAP_UUID"
        run "grubby --update-kernel=ALL --args=\"$PARAMS\""
        ok "Kernel params applied (ASPM overridden to force in Phase F)"
    else
        warn "Swap UUID not found — skipping resume= parameter"
    fi

    sub "E.4 sysctl Tuning"
    run "tee /etc/sysctl.d/90-zenbook.conf << 'SYSCTL'
vm.swappiness = 10
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
SYSCTL"
    run "sysctl --system 2>/dev/null"

    sub "E.5 DNS-over-TLS"
    run "mkdir -p /etc/systemd/resolved.conf.d"
    run "tee /etc/systemd/resolved.conf.d/performance.conf << 'DNS'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google
DNSOverTLS=opportunistic
Cache=yes
CacheFromLocalhost=yes
DNSSEC=allow-downgrade
DNS"
    run "systemctl restart systemd-resolved"

    sub "E.6 Firewall for Development"
    run "firewall-cmd --set-default-zone=home 2>/dev/null || true"
    for port in 3000 5000 6006 8000 8080 8888 11434; do
        run "firewall-cmd --permanent --zone=home --add-rich-rule='rule family=ipv4 source address=127.0.0.1/32 port port=$port protocol=tcp accept' 2>/dev/null || true"
    done
    run "firewall-cmd --permanent --zone=home --add-service=ssh 2>/dev/null || true"
    run "firewall-cmd --permanent --zone=trusted --add-interface=podman0 2>/dev/null || true"
    run "firewall-cmd --reload 2>/dev/null || true"

    sub "E.7 systemd Service Optimization"
    run "systemctl disable --now cups.service cups.socket cups.path 2>/dev/null || true"
    run "systemctl disable --now cups-browsed.service 2>/dev/null || true"
    run "systemctl mask ModemManager.service 2>/dev/null || true"
    run "systemctl disable --now avahi-daemon.service avahi-daemon.socket 2>/dev/null || true"
    run "systemctl disable --now abrtd.service abrt-journal-core.service abrt-oops.service 2>/dev/null || true"
    run "systemctl mask remote-fs.target 2>/dev/null || true"
    run "systemctl disable --now pcscd.service pcscd.socket 2>/dev/null || true"

    sub "E.8 systemd-oomd Tuning"
    run "mkdir -p /etc/systemd/oomd.conf.d"
    run "tee /etc/systemd/oomd.conf.d/ml-workload.conf << 'OOM'
[OOM]
SwapUsedLimit=95%
DefaultMemoryPressureLimit=70%
DefaultMemoryPressureDurationUSec=30s
OOM"
    run "systemctl restart systemd-oomd 2>/dev/null || true"

    sub "E.10 journald, Core Dumps, tmpfs"
    run "mkdir -p /etc/systemd/journald.conf.d"
    run "tee /etc/systemd/journald.conf.d/optimize.conf << 'JRN'
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
Compress=yes
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no
JRN"
    run "systemctl restart systemd-journald"
    run "mkdir -p /etc/systemd/coredump.conf.d"
    run "tee /etc/systemd/coredump.conf.d/limits.conf << 'CORE'
[Coredump]
Storage=external
MaxUse=1G
ProcessSizeMax=2G
CORE"
    run "systemctl enable tmp.mount 2>/dev/null || true"
    run "mkdir -p /etc/systemd/system/tmp.mount.d"
    run "tee /etc/systemd/system/tmp.mount.d/size.conf << 'TMP'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=4G
TMP"
    run "systemctl daemon-reload"

    sub "E.12 dracut Initramfs Optimization"
    run "mkdir -p /etc/dracut.conf.d"
    run "tee /etc/dracut.conf.d/performance.conf << 'DRACUT'
compress=\"zstd\"
add_dracutmodules+=\" btrfs resume \"
early_microcode=\"yes\"
omit_dracutmodules+=\" nfs iscsi fcoe fcoe-uefi multipath \"
install_optional_items+=\" /lib/firmware/amdgpu/* /lib/firmware/mediatek/* \"
DRACUT"
    run "plymouth-set-default-theme spinner 2>/dev/null || true"
    run "dracut --force --regenerate-all 2>/dev/null || true"

    sub "E.13 Boot Experience"
    run "sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub"
    run "sed -i 's/^GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT=\"gfxterm\"/' /etc/default/grub"
    run "grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true"

    sub "E.14 SSH Hardening"
    run "tee /etc/ssh/sshd_config.d/hardened.conf << 'SSH'
PasswordAuthentication no
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
LoginGraceTime 30
SSH"
    run "systemctl restart sshd 2>/dev/null || true"

    sub "E.15 fail2ban"
    run "dnf install -y fail2ban"
    run "tee /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
F2B"
    run "systemctl enable --now fail2ban"

    sub "E.16 Automatic Security Updates"
    run "dnf install -y dnf-automatic"
    run "tee /etc/dnf/automatic.conf << 'AUTO'
[commands]
upgrade_type = security
apply_updates = yes
download_updates = yes

[emitters]
emit_via = stdio
AUTO"
    run "systemctl enable --now dnf-automatic-install.timer"

    sub "E.17 USBGuard"
    run "dnf install -y usbguard"
    run "usbguard generate-policy > /etc/usbguard/rules.conf 2>/dev/null || true"
    run "systemctl enable --now usbguard 2>/dev/null || true"

    sub "E.18 Additional sysctl Hardening"
    run "tee -a /etc/sysctl.d/90-zenbook.conf << 'SYSCTL2'

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
SYSCTL2"
    run "sysctl --system 2>/dev/null"

    sub "E.19 Core Dump Restriction"
    run "echo 'fs.suid_dumpable = 0' >> /etc/sysctl.d/90-zenbook.conf"
    run "sysctl -p /etc/sysctl.d/90-zenbook.conf 2>/dev/null || true"
    run "echo '* hard core 0' >> /etc/security/limits.conf"

    sub "E.20 DNSSEC Strict Mode"
    run "sed -i 's/^DNSSEC=allow-downgrade/DNSSEC=yes/' /etc/systemd/resolved.conf.d/performance.conf"
    run "systemctl restart systemd-resolved"

    sub "E.21 Chrony NTP Hardening (NTS)"
    run "mkdir -p /etc/chrony.conf.d"
    run "tee /etc/chrony.conf.d/hardened.conf << 'NTP'
server time.cloudflare.com iburst nts
server nts.netnod.se iburst nts
server ptbtime1.ptb.de iburst nts
minsources 2
maxchange 100 1 1
makestep 1.0 3
NTP"
    run "systemctl restart chronyd 2>/dev/null || true"

    sub "E.22 Audit Rules"
    run "tee /etc/audit/rules.d/sensitive.rules << 'AUDIT'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /sbin/insmod -p x -k kernel_modules
-w /sbin/modprobe -p x -k kernel_modules
AUDIT"
    run "augenrules --load 2>/dev/null || true"

    if [[ "$DISABLE_IPV6" == "yes" ]]; then
        sub "E.23 Disable IPv6"
        run "grubby --update-kernel=ALL --args='ipv6.disable=1'"
        warn "IPv6 disabled — takes effect after reboot"
    fi

    ok "Phase E complete"
}

###############################################################################
# PHASE F — Hardware
###############################################################################
phase_f() {
    hdr "Phase F — Hardware-Software Synchronization"

    sub "F.2 Automatic Profile Switching"
    run "tee /etc/udev/rules.d/85-power-profile.rules << 'UDEV'
SUBSYSTEM==\"power_supply\", ENV{POWER_SUPPLY_TYPE}==\"Mains\", ENV{POWER_SUPPLY_ONLINE}==\"1\", RUN+=\"/usr/bin/powerprofilesctl set performance\"
SUBSYSTEM==\"power_supply\", ENV{POWER_SUPPLY_TYPE}==\"Mains\", ENV{POWER_SUPPLY_ONLINE}==\"0\", RUN+=\"/usr/bin/powerprofilesctl set balanced\"
UDEV"
    run "udevadm control --reload-rules"

    sub "F.5 WiFi Power Save Off"
    run "tee /etc/NetworkManager/conf.d/wifi-powersave.conf << 'WIFI'
[connection]
wifi.powersave = 2
WIFI"
    run "systemctl restart NetworkManager 2>/dev/null || true"

    sub "F.6 Bluetooth Power"
    run "sed -i 's/^#\?AutoEnable.*/AutoEnable=true/' /etc/bluetooth/main.conf 2>/dev/null || true"
    run "sed -i 's/^#\?ControllerMode.*/ControllerMode = dual/' /etc/bluetooth/main.conf 2>/dev/null || true"
    run "sed -i 's/^#\?FastConnectable.*/FastConnectable = true/' /etc/bluetooth/main.conf 2>/dev/null || true"
    run "systemctl restart bluetooth 2>/dev/null || true"

    sub "F.7 PipeWire Audio"
    run "sudo -u $REAL_USER mkdir -p $REAL_HOME/.config/pipewire/pipewire.conf.d"
    run "sudo -u $REAL_USER tee $REAL_HOME/.config/pipewire/pipewire.conf.d/performance.conf << 'PW'
context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 44100 48000 ]
    default.clock.quantum = 1024
    default.clock.min-quantum = 512
    default.clock.max-quantum = 2048
}
PW"

    sub "F.8 Suspend/Resume (S0ix)"
    run "tee /etc/udev/rules.d/90-usb-wakeup.rules << 'SUSP'
ACTION==\"add\", SUBSYSTEM==\"usb\", DRIVERS==\"usb\", ATTR{power/wakeup}=\"disabled\"
SUSP"
    run "udevadm control --reload-rules"

    sub "F.11 GPU Power Cap"
    run "tee /etc/udev/rules.d/86-amdgpu-power.rules << 'GPU'
ACTION==\"add\", SUBSYSTEM==\"drm\", KERNEL==\"card0\", RUN+=\"/bin/bash -c 'echo 15000000 > /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap'\"
GPU"

    sub "F.12 NVMe I/O Scheduler"
    run "tee /etc/udev/rules.d/60-io-scheduler.rules << 'NVME'
ACTION==\"add|change\", KERNEL==\"nvme[0-9]*\", ATTR{queue/scheduler}=\"none\"
NVME"
    run "udevadm control --reload-rules"

    sub "F.13 Battery Charge Threshold"
    if [[ -n "$BAT_DEV" ]]; then
        run "echo $BATTERY_THRESHOLD > /sys/class/power_supply/$BAT_DEV/charge_control_end_threshold 2>/dev/null || warn 'Battery threshold not supported by this kernel'"
        run "tee /etc/systemd/system/battery-charge-threshold.service << BATTSVC
[Unit]
Description=Set battery charge threshold
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
Restart=on-failure
RestartSec=5
ExecStart=/bin/bash -c 'echo $BATTERY_THRESHOLD > /sys/class/power_supply/$BAT_DEV/charge_control_end_threshold'

[Install]
WantedBy=multi-user.target
BATTSVC"
        run "systemctl daemon-reload"
        run "systemctl enable battery-charge-threshold.service"
        run "tee /etc/udev/rules.d/87-battery-threshold.rules << BATT
ACTION==\"change\", SUBSYSTEM==\"power_supply\", ATTR{type}==\"Battery\", ATTR{charge_control_end_threshold}=\"$BATTERY_THRESHOLD\"
BATT"
        ok "Battery threshold set to ${BATTERY_THRESHOLD}% (persistent via systemd + udev)"
    else
        warn "No battery detected — skipping"
    fi

    sub "F.14 PCIe ASPM Force"
    run "grubby --update-kernel=ALL --args='pcie_aspm=force pcie_aspm.policy=powersupersave'"

    sub "F.15 Deep CPU Idle States"
    run "grubby --update-kernel=ALL --args='processor.max_cstate=9 amd_pstate.shared_mem=1'"

    ok "Phase F complete (reboot needed for kernel params)"
}

###############################################################################
# PHASE G — OLED Display
###############################################################################
phase_g() {
    hdr "Phase G — OLED Display Optimization"

    sub "G.1 Scaling & G.2 Font Rendering"
    run "sudo -u $REAL_USER gsettings set org.gnome.desktop.interface font-antialiasing 'grayscale'"
    run "sudo -u $REAL_USER gsettings set org.gnome.desktop.interface font-hinting 'slight'"

    sub "G.4 ABR and PSR Tuning"
    run "grubby --update-kernel=ALL --args='amdgpu.dcdebugmask=0x10 amdgpu.abmlevel=0'"

    sub "G.5 Burn-in Prevention"
    run "sudo -u $REAL_USER gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 300"
    run "sudo -u $REAL_USER gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 900"

    ok "Phase G complete"
}

###############################################################################
# PHASE H — GNOME
###############################################################################
phase_h() {
    hdr "Phase H — GNOME Minimalism"

    sub "H.1 Remove Bloat"
    run "dnf remove -y gnome-maps gnome-contacts gnome-weather gnome-clocks gnome-tour gnome-connections gnome-characters gnome-font-viewer gnome-abrt mediawriter rhythmbox totem cheese simple-scan yelp gnome-photos gnome-music gnome-boxes gnome-calendar libreoffice-* fedora-bookmarks fedora-chromium-config 2>/dev/null || true"

    sub "H.2 GNOME Settings"
    local GS="sudo -u $REAL_USER gsettings set"
    run "$GS org.gnome.desktop.interface color-scheme 'prefer-dark'"
    run "$GS org.gnome.desktop.interface gtk-theme 'Adwaita-dark'"
    run "$GS org.gnome.desktop.background picture-options 'none'"
    run "$GS org.gnome.desktop.background primary-color '#000000'"
    run "$GS org.gnome.desktop.screensaver picture-options 'none'"
    run "$GS org.gnome.desktop.screensaver primary-color '#000000'"
    run "$GS org.gnome.desktop.interface enable-hot-corners false"
    run "$GS org.gnome.desktop.interface clock-show-date true"
    run "$GS org.gnome.desktop.interface show-battery-percentage true"
    run "$GS org.gnome.desktop.sound event-sounds false"
    run "$GS org.gnome.desktop.session idle-delay 180"
    run "$GS org.gnome.desktop.screensaver lock-enabled true"
    run "$GS org.gnome.desktop.screensaver lock-delay 0"
    run "$GS org.gnome.settings-daemon.plugins.color night-light-enabled true"
    run "$GS org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true"
    run "$GS org.gnome.settings-daemon.plugins.color night-light-temperature 3500"
    run "$GS org.gnome.desktop.wm.preferences resize-with-right-button true"
    run "$GS org.gnome.mutter workspaces-only-on-primary false"
    run "$GS org.gnome.system.location enabled false"
    run "$GS org.gnome.desktop.privacy report-technical-problems false"
    run "$GS org.gnome.desktop.privacy recent-files-max-age 7"
    run "$GS org.gnome.desktop.privacy remove-old-temp-files true"
    run "$GS org.gnome.desktop.privacy old-files-age 7"

    sub "H.3 Tracker3"
    run "$GS org.freedesktop.Tracker3.Miner.Files index-recursive-directories \"['&DESKTOP', '&DOCUMENTS', '&PICTURES', '&DOWNLOAD']\""
    run "$GS org.freedesktop.Tracker3.Miner.Files index-on-battery false"
    run "$GS org.freedesktop.Tracker3.Miner.Files index-removable-devices false"
    run "$GS org.freedesktop.Tracker3.Miner.Files crawling-interval -1"
    run "sudo -u $REAL_USER touch $REAL_HOME/projects/.trackerignore"

    sub "H.4 Keyboard Shortcuts"
    run "$GS org.gnome.settings-daemon.plugins.media-keys custom-keybindings \"['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']\""
    run "$GS org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Terminal'"
    run "$GS org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'ghostty'"
    run "$GS org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>Return'"

    sub "H.6 GNOME Memory Optimization"
    run "$GS org.gnome.software download-updates false"
    run "$GS org.gnome.software download-updates-notify false"

    sub "H.7 Nautilus Performance"
    run "$GS org.gnome.nautilus.preferences show-hidden-files false"
    run "$GS org.gnome.nautilus.preferences default-folder-viewer 'list-view'"
    run "$GS org.gnome.nautilus.list-view default-zoom-level 'small'"
    run "$GS org.gtk.Settings.FileChooser sort-directories-first true"

    ok "Phase H complete"
}

###############################################################################
# PHASE I — Development Environment
###############################################################################
phase_i() {
    hdr "Phase I — Development Environment"

    sub "I.1 System Packages"
    run "dnf groupinstall -y 'Development Tools' 'C Development Tools and Libraries'"
    run "dnf install -y gcc gcc-c++ gfortran make cmake ninja-build meson clang llvm lld python3-devel python3.12 python3.11 golang rust cargo openssl-devel libffi-devel zlib-devel bzip2-devel readline-devel sqlite-devel xz-devel tk-devel blas-devel lapack-devel openblas-devel hdf5-devel git git-lfs git-delta podman podman-compose buildah skopeo btop iotop-c powertop tmux neovim jq yq ripgrep fd-find bat eza fzf ShellCheck strace perf stress-ng lm_sensors nvme-cli smartmontools btrfs-progs compsize wget2 curl rsync bc wl-clipboard audit policycoreutils-python-utils borgbackup"

    sub "I.2 Flatpak & VS Code"
    run "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
    run "flatpak install -y flathub com.visualstudio.code 2>/dev/null || true"
    run "flatpak override --user com.visualstudio.code --filesystem=home --filesystem=/tmp --filesystem=xdg-run/podman:ro --env=ELECTRON_OZONE_PLATFORM_HINT=auto 2>/dev/null || true"

    sub "I.3 Git Configuration"
    run "sudo -u $REAL_USER git config --global user.name '$GIT_NAME'"
    run "sudo -u $REAL_USER git config --global user.email '$GIT_EMAIL'"
    run "sudo -u $REAL_USER git config --global core.pager delta"
    run "sudo -u $REAL_USER git config --global interactive.diffFilter 'delta --color-only'"
    run "sudo -u $REAL_USER git config --global delta.navigate true"
    run "sudo -u $REAL_USER git config --global delta.dark true"
    run "sudo -u $REAL_USER git config --global delta.line-numbers true"
    run "sudo -u $REAL_USER git config --global delta.side-by-side true"
    run "sudo -u $REAL_USER git config --global core.fsmonitor true"
    run "sudo -u $REAL_USER git config --global core.untrackedCache true"
    run "sudo -u $REAL_USER git config --global feature.manyFiles true"
    run "sudo -u $REAL_USER git config --global init.defaultBranch main"
    run "sudo -u $REAL_USER git config --global pull.rebase true"
    run "sudo -u $REAL_USER git config --global merge.conflictstyle zdiff3"
    run "sudo -u $REAL_USER git config --global gpg.format ssh"
    run "sudo -u $REAL_USER git config --global commit.gpgsign true"
    run "sudo -u $REAL_USER git config --global tag.gpgsign true"

    sub "I.4 Python Environment"
    run "sudo -u $REAL_USER mkdir -p $REAL_HOME/.config/pip"
    run "sudo -u $REAL_USER tee $REAL_HOME/.config/pip/pip.conf << 'PIP'
[global]
require-virtualenv = true
PIP"

    sub "I.5 Podman Rootless"
    run "grep -q '^${REAL_USER}:' /etc/subuid || usermod --add-subuids 100000-165535 $REAL_USER"
    run "grep -q '^${REAL_USER}:' /etc/subgid || usermod --add-subgids 100000-165535 $REAL_USER"
    run "sudo -u $REAL_USER mkdir -p $REAL_HOME/.config/containers"
    run "sudo -u $REAL_USER tee $REAL_HOME/.config/containers/registries.conf << 'REG'
unqualified-search-registries = [\"docker.io\", \"quay.io\", \"ghcr.io\"]
REG"
    run "sudo -u $REAL_USER podman system migrate 2>/dev/null || true"

    sub "I.6 Shell Configuration"
    if ! grep -q "# --- Fedora 43 Post-Install ---" "$REAL_HOME/.bashrc" 2>/dev/null; then
        run "sudo -u $REAL_USER tee -a $REAL_HOME/.bashrc << 'BASHRC'

# --- Fedora 43 Post-Install ---
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT=\"%F %T \"
shopt -s histappend

eval \"\$(fzf --bash)\"

export OPENBLAS_NUM_THREADS=8
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
export NUMEXPR_MAX_THREADS=8
export GOPATH=\$HOME/go
export GOBIN=\$HOME/go/bin
export PATH=\$PATH:\$GOBIN
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
BASHRC"
        ok "Shell config appended to .bashrc"
    else
        warn ".bashrc already configured — skipping"
    fi

    sub "I.7 SSH Keys"
    if [[ ! -f "$REAL_HOME/.ssh/id_ed25519" ]]; then
        run "sudo -u $REAL_USER mkdir -p $REAL_HOME/.ssh/sockets"
        run "chmod 700 $REAL_HOME/.ssh $REAL_HOME/.ssh/sockets"
        info "Generating SSH key (you may be prompted for a passphrase)..."
        if ! $DRY_RUN; then
            sudo -u "$REAL_USER" ssh-keygen -t ed25519 -C "${REAL_USER}@${HOSTNAME_CURRENT}" -f "$REAL_HOME/.ssh/id_ed25519"
        fi
        run "sudo -u $REAL_USER git config --global user.signingkey $REAL_HOME/.ssh/id_ed25519.pub"
    else
        ok "SSH key already exists"
    fi

    # SSH config
    run "sudo -u $REAL_USER tee $REAL_HOME/.ssh/config << SSHCFG
Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
    ServerAliveInterval 30
    ServerAliveCountMax 10
    Compression yes
    IdentityFile ~/.ssh/id_ed25519
    GSSAPIAuthentication no
    PasswordAuthentication no
    AddKeysToAgent yes
SSHCFG"

    if [[ "$GPU_SERVER_IP" != "skip" ]]; then
        run "sudo -u $REAL_USER tee -a $REAL_HOME/.ssh/config << GPUCFG

Host gpu
    HostName $GPU_SERVER_IP
    User $GPU_SERVER_USER
    ForwardAgent yes
GPUCFG"
    fi
    run "chmod 600 $REAL_HOME/.ssh/config"

    sub "I.8 Ollama (Local LLM)"
    run "curl -fsSL https://ollama.com/install.sh | sh"
    run "mkdir -p /etc/systemd/system/ollama.service.d"
    run "tee /etc/systemd/system/ollama.service.d/resources.conf << 'OLLAMA'
[Service]
Environment=\"OLLAMA_NUM_PARALLEL=1\"
Environment=\"OLLAMA_MAX_LOADED_MODELS=1\"
Environment=\"OLLAMA_FLASH_ATTENTION=1\"
OLLAMA"
    run "systemctl daemon-reload"
    run "systemctl enable --now ollama 2>/dev/null || true"

    sub "I.9 zram Swap"
    run "dnf install -y zram-generator"
    run "tee /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAM"
    run "systemctl daemon-reload"

    sub "I.10 Podman Lingering"
    run "loginctl enable-linger $REAL_USER 2>/dev/null || true"

    sub "I.11 Node.js via fnm"
    run "sudo -u $REAL_USER bash -c 'curl -fsSL https://fnm.vercel.app/install | bash' 2>/dev/null || true"

    sub "I.12 Podman-Docker Compatibility"
    run "dnf install -y podman-docker"

    sub "I.13 Neovim Configuration"
    if [[ ! -d "$REAL_HOME/.config/nvim" ]]; then
        run "sudo -u $REAL_USER git clone https://github.com/nvim-lua/kickstart.nvim.git $REAL_HOME/.config/nvim 2>/dev/null || true"
    else
        warn "Neovim config already exists — skipping"
    fi

    sub "I.14 tmux Configuration"
    run "sudo -u $REAL_USER tee $REAL_HOME/.tmux.conf << 'TMUX'
set -g default-terminal \"tmux-256color\"
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
bind | split-window -h -c \"#{pane_current_path}\"
bind - split-window -v -c \"#{pane_current_path}\"
TMUX"

    sub "I.15 Python uv"
    run "sudo -u $REAL_USER bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' 2>/dev/null || true"

    sub "I.16 Rust via rustup"
    info "Replacing system rust/cargo with rustup..."
    run "dnf remove -y rust cargo 2>/dev/null || true"
    run "sudo -u $REAL_USER bash -c \"curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y\" 2>/dev/null || true"

    sub "I.17 Global .gitignore"
    run "sudo -u $REAL_USER mkdir -p $REAL_HOME/.config/git"
    run "sudo -u $REAL_USER tee $REAL_HOME/.config/git/ignore << 'GIGN'
.DS_Store
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
.venv/
GIGN"
    run "sudo -u $REAL_USER git config --global core.excludesfile $REAL_HOME/.config/git/ignore"

    sub "I.18 Starship Prompt"
    run "curl -sS https://starship.rs/install.sh | sh -s -- -y 2>/dev/null || true"
    if ! grep -q 'starship init bash' "$REAL_HOME/.bashrc" 2>/dev/null; then
        run "sudo -u $REAL_USER tee -a $REAL_HOME/.bashrc << 'STAR'
eval \"\$(starship init bash)\"
STAR"
    fi

    sub "I.19 Ghostty Terminal"
    run "dnf copr enable -y pgdev/ghostty"
    run "dnf install -y ghostty"

    ok "Phase I complete"
}

###############################################################################
# PHASE J — Snapshot Automation
###############################################################################
phase_j() {
    hdr "Phase J — Snapshot Automation and Tools"

    sub "J.1 Snapshot Manager"
    run "tee /usr/local/bin/btrfs-snapshot << 'SNAPSCRIPT'
#!/bin/bash
set -euo pipefail
SNAP_ROOT=\"/.snapshots\"
VERIFIED_LOG=\"\$SNAP_ROOT/.verified\"
TS=\$(date +%Y%m%d-%H%M%S)
MAX=5

SPACE=\$(btrfs filesystem usage / --raw 2>/dev/null | awk '/Free/{print \$3; exit}')
MIN_FREE=\$((10 * 1024 * 1024 * 1024))
if [ \"\${SPACE:-0}\" -lt \"\$MIN_FREE\" ]; then
    echo \"  ✗ Less than 10 GiB free — run 'btrfs-snapshot clean' first\"
    exit 1
fi

snap() {
    local src=\"\$1\" dst=\"\$2\" label=\"\${3:-manual}\"
    btrfs subvolume snapshot -r \"\$src\" \"\${dst}/\${TS}_\${label}\" >/dev/null
    echo \"  ✓ \${dst}/\${TS}_\${label}\"
}
check_health() {
    local errors=0
    local failed; failed=\$(systemctl --failed --no-pager --no-legend | wc -l)
    [ \"\$failed\" -eq 0 ] || { echo \"  ✗ \$failed failed service(s)\"; errors=\$((errors+1)); }
    local se; se=\$(getenforce 2>/dev/null || echo \"unknown\")
    [ \"\$se\" = \"Enforcing\" ] || { echo \"  ✗ SELinux: \$se\"; errors=\$((errors+1)); }
    local berr; berr=\$(btrfs device stats / 2>/dev/null | grep -v ' 0\$' | wc -l)
    [ \"\$berr\" -eq 0 ] || { echo \"  ✗ Btrfs: \$berr error(s)\"; errors=\$((errors+1)); }
    local mounts; mounts=\$(findmnt -t btrfs --noheadings | wc -l)
    [ \"\$mounts\" -ge 8 ] || { echo \"  ✗ Only \$mounts/8 Btrfs subvolumes\"; errors=\$((errors+1)); }
    return \$errors
}
mark_verified() { touch \"\$VERIFIED_LOG\"; echo \"\$1\" >> \"\$VERIFIED_LOG\"; echo \"  ★ Group \$1 VERIFIED\"; }
last_verified() { [ -f \"\$VERIFIED_LOG\" ] && tail -1 \"\$VERIFIED_LOG\" || echo \"\"; }
is_verified() { [ -f \"\$VERIFIED_LOG\" ] && grep -qx \"\$1\" \"\$VERIFIED_LOG\"; }
do_coordinated_snap() {
    local label=\"\$1\" verified=false
    if [ \"\${2:-yes}\" = \"yes\" ]; then
        echo \"Verifying system health...\"; check_health && { echo \"  ✓ Healthy\"; verified=true; } || echo \"  ⚠ Issues — snapshot NOT verified\"
    fi
    snap / \"\$SNAP_ROOT/root\" \"\$label\"
    snap /home \"\$SNAP_ROOT/home\" \"\$label\"
    snap /home/asif/projects \"\$SNAP_ROOT/projects\" \"\$label\"
    \$verified && mark_verified \"\$TS\"
    echo \"Done. Group: \$TS\"
}
case \"\${1:-help}\" in
    pre-upgrade) echo \"Creating pre-upgrade snapshots...\"; do_coordinated_snap \"pre-upgrade\" ;;
    group) do_coordinated_snap \"\${2:-manual}\" ;;
    root|home|projects) src=\"/\"; [ \"\$1\" = \"home\" ] && src=\"/home\"; [ \"\$1\" = \"projects\" ] && src=\"/home/asif/projects\"; snap \"\$src\" \"\$SNAP_ROOT/\$1\" \"\${2:-manual}\" ;;
    verify) echo \"Health check...\"; check_health && ok \"Healthy\" || { err \"Failed\"; exit 1; } ;;
    list) for d in root home projects; do [ -d \"\$SNAP_ROOT/\$d\" ] || continue; echo \"\$d:\"; ls -1 \"\$SNAP_ROOT/\$d/\"; done ;;
    clean) keep=\${2:-\$MAX}; for d in root home projects; do dir=\"\$SNAP_ROOT/\$d\"; [ -d \"\$dir\" ] || continue; count=\$(find \"\$dir\" -maxdepth 1 -mindepth 1 -type d|wc -l); if [ \"\$count\" -gt \"\$keep\" ]; then find \"\$dir\" -maxdepth 1 -mindepth 1 -type d|sort|head -n \$((count-keep))|while read -r s; do btrfs subvolume delete \"\$s\">/dev/null; echo \"  Deleted: \$(basename \"\$s\")\"; done; fi; done ;;
    rollback) echo \"Boot Live USB, mount subvolid=5, restore from /.snapshots/\"; last_verified && echo \"Last verified: \$(last_verified)\" ;;
    *) echo \"Usage: btrfs-snapshot {pre-upgrade|group|verify|list|clean|rollback}\" ;;
esac
SNAPSCRIPT"
    run "chmod +x /usr/local/bin/btrfs-snapshot"

    sub "J.2 Safe Upgrade"
    run "tee /usr/local/bin/safe-upgrade << 'UPGSCRIPT'
#!/bin/bash
set -euo pipefail
echo \"=== Fedora Safe Upgrade ===\"
echo \"[1/5] Snapshots...\"; /usr/local/bin/btrfs-snapshot pre-upgrade
echo \"[2/5] Upgrading...\"; dnf upgrade -y --refresh \"\$@\"
echo \"[3/5] Firmware...\"; fwupdmgr refresh 2>/dev/null||true; fwupdmgr update 2>/dev/null||true
echo \"[4/5] Health check...\"
FAILED=\$(systemctl --failed --no-pager --no-legend|wc -l)
BERR=\$(btrfs device stats / 2>/dev/null|grep -v ' 0\$'|wc -l)
SE=\$(getenforce 2>/dev/null||echo unknown)
echo \"  Failed: \$FAILED | Btrfs errors: \$BERR | SELinux: \$SE\"
echo \"[5/5] Verdict...\"
[ \"\$FAILED\" -eq 0 ] && [ \"\$BERR\" -eq 0 ] && [ \"\$SE\" = \"Enforcing\" ] && echo \"  ✓ Healthy\" || echo \"  ⚠ Issues detected\"
UPGSCRIPT"
    run "chmod +x /usr/local/bin/safe-upgrade"

    sub "J.3 System Health Dashboard"
    run "tee /usr/local/bin/system-health << 'HEALTHSCRIPT'
#!/bin/bash
set -euo pipefail
G='\\033[0;32m'; Y='\\033[0;33m'; R='\\033[0;31m'; C='\\033[0;36m'; N='\\033[0m'
ok(){ echo -e \"  \${G}✓\${N} \$1\"; }; warn(){ echo -e \"  \${Y}⚠\${N} \$1\"; }; err(){ echo -e \"  \${R}✗\${N} \$1\"; }; info(){ echo -e \"  \${C}→\${N} \$1\"; }
echo \"\"; echo \"════════════════════════════════════════════\"
echo \"  System Health · \$(date '+%Y-%m-%d %H:%M')\"
echo \"════════════════════════════════════════════\"
echo \"\"; echo \"Kernel & Boot\"
info \"Kernel: \$(uname -r) · Uptime: \$(uptime -p)\"
FAILED=\$(systemctl --failed --no-pager --no-legend|wc -l)
[ \"\$FAILED\" -eq 0 ] && ok \"No failed services\" || err \"\$FAILED failed\"
SE=\$(getenforce 2>/dev/null||echo unknown)
[ \"\$SE\" = \"Enforcing\" ] && ok \"SELinux: Enforcing\" || warn \"SELinux: \$SE\"
echo \"\"; echo \"Storage\"
info \"Root: \$(df -h /|awk 'NR==2{print \$5, \"used,\", \$4, \"free\"}')\"
BERR=\$(btrfs device stats / 2>/dev/null|grep -v ' 0\$'|wc -l)
[ \"\$BERR\" -eq 0 ] && ok \"Btrfs: clean\" || err \"Btrfs: \$BERR error(s)\"
BAT=\$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null|head -1)
[ -n \"\$BAT\" ] && { echo \"\"; echo \"Battery\"; info \"\${BAT}%\"; }
echo \"\"; echo \"════════════════════════════════════════════\"; echo \"\"
HEALTHSCRIPT"
    run "chmod +x /usr/local/bin/system-health"

    sub "J.4 Automated Timers"
    run "tee /etc/systemd/system/btrfs-snap-weekly.service << 'SVC'
[Unit]
Description=Weekly coordinated snapshot
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot group weekly
ExecStartPost=/usr/bin/notify-send -u low \"Btrfs Snapshot\" \"Weekly snapshot complete\"
SVC"
    run "tee /etc/systemd/system/btrfs-snap-weekly.timer << 'TMR'
[Unit]
Description=Weekly coordinated snapshot
[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
TMR"
    run "tee /etc/systemd/system/btrfs-snap-clean.service << 'SVC2'
[Unit]
Description=Monthly snapshot cleanup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot clean 5
SVC2"
    run "tee /etc/systemd/system/btrfs-snap-clean.timer << 'TMR2'
[Unit]
Description=Monthly snapshot cleanup
[Timer]
OnCalendar=*-*-01 04:00:00
Persistent=true
[Install]
WantedBy=timers.target
TMR2"
    run "systemctl daemon-reload"
    run "systemctl enable --now btrfs-snap-weekly.timer btrfs-snap-clean.timer"
    run "systemctl enable --now fstrim.timer"
    run "systemctl enable --now btrfs-scrub@-.timer 2>/dev/null || true"

    ok "Phase J complete"
}

###############################################################################
# PHASE K — Backup & Maintenance
###############################################################################
phase_k() {
    hdr "Phase K — Backup, Baseline, and Maintenance"

    sub "K.1 BorgBackup Script"
    if [[ "$BORG_LOCAL" != "skip" ]]; then
        run "tee /usr/local/bin/backup-borg << BORGSCRIPT
#!/bin/bash
set -euo pipefail
export BORG_REPO=$BORG_LOCAL
[ -d \"\\\$BORG_REPO\" ] || { echo \"Backup drive not mounted\"; exit 1; }
borg create --stats --progress --compression zstd,3 \"\\\${BORG_REPO}::zenbook-\\\$(date +%Y%m%d-%H%M%S)\" /home/$REAL_USER /etc --exclude '/home/$REAL_USER/.cache' --exclude '/home/$REAL_USER/.local/share/containers' --exclude '/home/$REAL_USER/projects/*/.venv' --exclude '/home/$REAL_USER/projects/*/node_modules' --exclude '*.pyc' --exclude '__pycache__'
borg prune --stats --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \"\\\$BORG_REPO\"
borg compact \"\\\$BORG_REPO\"
echo \"Backup complete.\"
BORGSCRIPT"
        run "chmod +x /usr/local/bin/backup-borg"
    fi

    sub "K.2 Performance Baseline"
    run "tee /usr/local/bin/perf-baseline << 'PERF'
#!/bin/bash
set -euo pipefail
echo \"=== Performance Baseline · \$(date -I) ===\"
BENCH=\"\${HOME}/bench\"
echo \"--- Storage (write) ---\"; dd if=/dev/zero of=\"\$BENCH\" bs=1M count=1024 oflag=direct 2>&1|tail -1
echo \"--- Storage (read) ---\"; dd if=\"\$BENCH\" of=/dev/null bs=1M count=1024 iflag=direct 2>&1|tail -1
rm -f \"\$BENCH\"
echo \"--- Btrfs compression ---\"; compsize / 2>/dev/null|head -3||true
echo \"--- Boot time ---\"; systemd-analyze; systemd-analyze blame|head -5
PERF"
    run "chmod +x /usr/local/bin/perf-baseline"

    sub "K.7 Flatpak Auto-Update Timer"
    run "tee /etc/systemd/system/flatpak-update.service << 'FLAT'
[Unit]
Description=Flatpak auto-update
[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update -y --noninteractive
FLAT"
    run "tee /etc/systemd/system/flatpak-update.timer << 'FLATTMR'
[Unit]
Description=Weekly Flatpak update
[Timer]
OnCalendar=Wed *-*-* 04:00:00
Persistent=true
[Install]
WantedBy=timers.target
FLATTMR"
    run "systemctl enable --now flatpak-update.timer"

    sub "K.8 SMART Monitoring"
    run "dnf install -y smartmontools 2>/dev/null || true"
    run "systemctl enable --now smartd 2>/dev/null || true"

    sub "K.9 Remote Backup"
    if [[ "$BORG_REMOTE" != "skip" ]]; then
        run "tee /usr/local/bin/backup-borg-remote << REMOTESCRIPT
#!/bin/bash
set -euo pipefail
export BORG_REPO=$BORG_REMOTE
borg create --stats --compression zstd,3 \"\\\${BORG_REPO}::zenbook-\\\$(date +%Y%m%d-%H%M%S)\" /home/$REAL_USER /etc --exclude '/home/$REAL_USER/.cache' --exclude '/home/$REAL_USER/.local/share/containers' --exclude '/home/$REAL_USER/projects/*/.venv' --exclude '/home/$REAL_USER/projects/*/node_modules' --exclude '*.pyc' --exclude '__pycache__'
borg prune --stats --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \"\\\$BORG_REPO\"
borg compact \"\\\$BORG_REPO\"
REMOTESCRIPT"
        run "chmod +x /usr/local/bin/backup-borg-remote"
        run "tee /etc/systemd/system/backup-borg-remote.service << 'RSVC'
[Unit]
Description=Weekly remote BorgBackup
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-borg-remote
RSVC"
        run "tee /etc/systemd/system/backup-borg-remote.timer << 'RTMR'
[Unit]
Description=Weekly remote backup
[Timer]
OnCalendar=Sat *-*-* 02:00:00
Persistent=true
[Install]
WantedBy=timers.target
RTMR"
        run "systemctl enable --now backup-borg-remote.timer"
    fi

    ok "Phase K complete"
}

###############################################################################
# MAIN EXECUTION
###############################################################################
hdr "Fedora 43 Post-Installation Script"
echo -e "  Phases: ${BLD}${SELECTED_PHASES}${RST}"
echo -e "  Dry-run: ${BLD}${DRY_RUN}${RST}"
echo -e "  Log: ${BLD}${LOG_FILE}${RST}"

should_run d && phase_d
should_run e && phase_e
should_run f && phase_f
should_run g && phase_g
should_run h && phase_h
should_run i && phase_i
should_run j && phase_j
should_run k && phase_k

hdr "All Done!"
echo ""
info "Log saved to: $LOG_FILE"
info "Reboot to apply kernel parameters and udev rules:"
echo -e "  ${BLD}sudo reboot${RST}"
echo ""
info "After reboot, verify with:"
echo -e "  ${BLD}sudo system-health${RST}"
echo -e "  ${BLD}sudo btrfs-snapshot verify${RST}"
echo ""
