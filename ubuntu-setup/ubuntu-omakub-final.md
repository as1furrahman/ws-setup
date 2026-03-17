# Ubuntu 24.04 LTS — Definitive Deployment Guide
## ASUS Zenbook S 13 OLED (UM5302TA) · Samsung 990 Pro 1TB
## Layered on Omakub · AppArmor enforcing · Stability-first

---

## How to Use This Guide

Follow each phase in order — every step builds on the previous one. Omakub handles the opinionated desktop and terminal baseline; this guide adds hardware-specific tuning, security hardening, filesystem architecture, and developer tooling that Omakub does not cover.

| Phase | What | When |
|---|---|---|
| A | BIOS and hardware preparation | Before installing Ubuntu |
| B | Ubuntu 24.04 installation + Omakub bootstrap | Installer + first boot |
| C | Btrfs subvolume architecture | From live USB, immediately after install |
| D | First boot validation | After Omakub, verify hardware and system state |
| E | System and security hardening | Post-update configuration |
| F | Hardware-software synchronization | CPU, GPU, power, suspend, thermal |
| G | Display and desktop refinement | OLED tuning, Omakub-complementary GNOME tweaks |
| H | Development environment | Packages, Python, Go, Rust, Git, containers, Ollama |
| I | Snapshot automation and tools | Scripts, timers, health dashboard |
| J | Backup, baseline, maintenance | BorgBackup, perf-baseline, checklists |

### What Omakub Provides (Do Not Duplicate)

Omakub (v1.5+) installs and configures the following. This guide deliberately avoids overriding these components:

| Category | Omakub Components |
|---|---|
| Terminal | Alacritty (Tokyo Night theme, Mono Lisa font) |
| Multiplexer | Zellij |
| Shell utilities | eza, fzf, ripgrep, zoxide, bat |
| Editor | Neovim (LazyVim config), VS Code |
| Version manager | mise (Ruby, Node.js, Python, Go, Java) |
| Git tooling | lazygit, GitHub CLI (gh) |
| Containers | Docker (with MySQL and Redis) |
| Docker TUI | lazydocker |
| App launcher | Ulauncher |
| GNOME desktop | Virtual desktops (Super+1/2/3), keyboard-first workflow, window tiling |
| Applications | Chrome, Firefox, 1Password, VLC, Pinta, Xournal++ |

This guide adds what Omakub does not: filesystem architecture, kernel tuning, security hardening, power optimization, OLED display tuning, additional developer tools, snapshot/backup infrastructure, and maintenance workflows.

---

## Hardware Reference

| Component | Specification | Linux Subsystem |
|---|---|---|
| CPU | AMD Ryzen 7 6800U · Zen 3+ · 8C/16T · 2.7–4.7 GHz · 15W TDP (cTDP 12–28W) | `amd-pstate-epp`, CPPC v2 |
| GPU | AMD Radeon 680M · RDNA 2 · 12 CUs · 2200 MHz | `amdgpu`, Mesa RadeonSI/RADV |
| RAM | 16 GB LPDDR5-6400 · Dual-channel · Soldered | Kernel memory subsystem |
| Display | 13.3" Samsung AMOLED · 2880×1800 · 60 Hz · 16:10 · PenTile Diamond Pixel | `amdgpu` DC, Mutter/Wayland |
| Storage | Samsung 990 Pro 1 TB · PCIe 4.0 x4 · NVMe 2.0 | `nvme`, Btrfs |
| WiFi/BT | MediaTek MT7922 · WiFi 6E · BT 5.2 | `mt7921e` |
| Audio | Harman Kardon · Realtek ALC294 | `snd_hda_intel`, PipeWire |
| Battery | 67 Wh Li-Po | `power_supply`, `upower` |
| TPM | AMD fTPM 2.0 (PSP) | `tpm_crb` |
| Firmware | ASUS UEFI | `fwupd`, LVFS |

---

## Phase A — BIOS and Hardware Preparation

### A.1 Update BIOS Firmware

Download the latest BIOS from the ASUS UM5302TA support page. Place the file on a FAT32 USB drive. Enter BIOS with **F2** at POST → Advanced → ASUS EZ Flash 3 Utility. Critical updates for this model fix S0ix suspend drain, NVMe APST, and thermal tables.

### A.2 BIOS Settings

**Boot.** UEFI Only — disable CSM. Enable Secure Boot in Standard Mode with factory keys.

**Advanced → CPU Configuration.** Enable SVM (for Docker/KVM). Enable CPPC (mandatory for `amd-pstate-epp`). Verify 8C/16T active. Enable C-state support (C6 and deeper).

**Advanced → NVMe/Storage.** Confirm the 990 Pro appears in NVMe mode (not RAID/RST).

**Advanced → Graphics.** Set iGPU as Primary. Disable Panel Self-Refresh (PSR) if exposed — PSR causes OLED flicker under `amdgpu`.

**Advanced → Power.** Set thermal profile to Performance if available, else Balanced.

**Security.** Enable TPM 2.0 (fTPM via AMD PSP). Leave Secure Boot keys at defaults.

### A.3 SSD Preparation (Optional — Skip for New Drives)

If the 990 Pro was previously used, Secure Erase from the Ubuntu live USB:

```bash
sudo nvme id-ctrl /dev/nvme0n1 | grep -E "^(mn|fr|sn)"
sudo nvme format /dev/nvme0n1 --ses=1 --force
sudo nvme smart-log /dev/nvme0n1
```

Verify firmware is **4B2QJXD7** or later (earlier firmware had wear and performance bugs).

---

## Phase B — Ubuntu 24.04 Installation + Omakub Bootstrap

### B.1 Partition Table

Boot the Ubuntu 24.04 LTS live USB. In the installer, select **Manual Partitioning**:

| Partition | Size | Filesystem | Mount |
|---|---|---|---|
| `/dev/nvme0n1p1` | 1 GiB | FAT32 (EFI) | `/boot/efi` |
| `/dev/nvme0n1p2` | 2 GiB | ext4 | `/boot` |
| `/dev/nvme0n1p3` | 20 GiB | swap | [swap] |
| `/dev/nvme0n1p4` | ~930 GiB | Btrfs | `/` |

**1 GiB EFI** — headroom for multiple kernel generations and fwupd capsule updates.
**2 GiB ext4 /boot** — avoids all GRUB–Btrfs compression edge cases. Kernels here are Secure Boot signed.
**20 GiB swap** — 1.25× RAM for hibernation support.
**~930 GiB Btrfs** — single volume for the whole filesystem.

Let the Ubuntu installer create its default layout on the Btrfs partition. We restructure it in Phase C.

**Begin Installation.** After the installer finishes, **do not reboot** — proceed directly to Phase C from the live environment.

### B.2 Omakub Bootstrap (After Phase C and First Boot)

After completing Phase C (Btrfs subvolume setup), reboot into the installed system and complete the GNOME first-run wizard. Then install Omakub:

```bash
wget -qO- https://omakub.org/install | bash
```

Omakub will prompt for app choices (terminal, browser preferences). Let it reboot when done. **All subsequent phases in this guide assume Omakub has already been installed.**

---

## Phase C — Btrfs Subvolume Architecture

Done from the **live USB**, immediately after the Ubuntu installer finishes.

### C.1 Subvolume Design

| Subvolume | Mount | Snapshot Policy | Special Options | Why |
|---|---|---|---|---|
| `@` | `/` | Pre-upgrade + weekly | Standard | OS isolation |
| `@home` | `/home` | Pre-upgrade + weekly | Standard | Dotfiles, app state |
| `@snapshots` | `/.snapshots` | Never (avoids recursion) | Standard | Snapshot storage |
| `@var_log` | `/var/log` | Never | `compress=zstd:3` | Write-once logs compress 80–90% |
| `@var_cache` | `/var/cache` | Never | Standard | Fully regenerable (apt, flatpak) |
| `@var_tmp` | `/var/tmp` | Never | Standard | Transient build artifacts |
| `@containers` | `/var/lib/docker` | Never | `nodatacow` | Docker overlay: disables CoW to eliminate write amplification |
| `@projects` | `~/projects` | Pre-upgrade + weekly | Standard | Independent lifecycle from OS and home |

### C.2 Create the Subvolumes

```bash
lsblk -f /dev/nvme0n1

sudo mkdir -p /mnt/btrfs
sudo mount -o subvolid=5 /dev/nvme0n1p4 /mnt/btrfs
cd /mnt/btrfs

sudo btrfs subvolume list .
ls
```

```bash
# Ubuntu 24.04 may place files directly on the top-level or create @ and @home
# Adapt the following based on what the installer created:

# If Ubuntu created @ and @home subvolumes, they are already present
# If Ubuntu put everything on the top-level:
sudo btrfs subvolume snapshot . @
sudo btrfs subvolume create @home
sudo mv @/home/* @home/ 2>/dev/null || true

# Create additional subvolumes
sudo btrfs subvolume create @snapshots
sudo btrfs subvolume create @var_log
sudo btrfs subvolume create @var_cache
sudo btrfs subvolume create @var_tmp
sudo btrfs subvolume create @containers
sudo btrfs subvolume create @projects

# Move existing volatile data into their subvolumes
sudo mv @/var/log/* @var_log/ 2>/dev/null || true
sudo mv @/var/cache/* @var_cache/ 2>/dev/null || true
sudo mv @/var/tmp/* @var_tmp/ 2>/dev/null || true

# Ensure mount point directories exist inside @
sudo mkdir -p @/home @/.snapshots @/var/log @/var/cache @/var/tmp @/var/lib/docker

# Create snapshot category directories
sudo mkdir -p @snapshots/root @snapshots/home @snapshots/projects

# Verify — should show 8 subvolumes
sudo btrfs subvolume list .
COUNT=$(sudo btrfs subvolume list . | wc -l)
[ "$COUNT" -eq 8 ] && echo "All 8 subvolumes created" || echo "Found $COUNT subvolumes (expected 8)"
```

### C.3 Write the fstab

```bash
EFI_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p1)
BOOT_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p2)
SWAP_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p3)
BTRFS_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p4)

echo "EFI:   $EFI_UUID"
echo "Boot:  $BOOT_UUID"
echo "Swap:  $SWAP_UUID"
echo "Btrfs: $BTRFS_UUID"
```

```bash
sudo tee @/etc/fstab << EOF
# /etc/fstab — Ubuntu 24.04 LTS · UM5302TA · Btrfs
# $(date -I)

# Non-Btrfs
UUID=$EFI_UUID   /boot/efi  vfat   umask=0077,shortname=winnt  0 2
UUID=$BOOT_UUID  /boot      ext4   defaults                     0 2
UUID=$SWAP_UUID  none       swap   defaults                     0 0

# Btrfs subvolumes (Samsung 990 Pro)
UUID=$BTRFS_UUID /                    btrfs subvol=@,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120              0 0
UUID=$BTRFS_UUID /home                btrfs subvol=@home,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120,autodefrag  0 0
UUID=$BTRFS_UUID /.snapshots          btrfs subvol=@snapshots,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120      0 0
UUID=$BTRFS_UUID /var/log             btrfs subvol=@var_log,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,commit=120        0 0
UUID=$BTRFS_UUID /var/cache           btrfs subvol=@var_cache,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120      0 0
UUID=$BTRFS_UUID /var/tmp             btrfs subvol=@var_tmp,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120        0 0
UUID=$BTRFS_UUID /var/lib/docker      btrfs subvol=@containers,nodatacow,noatime,ssd,discard=async,space_cache=v2                      0 0
UUID=$BTRFS_UUID /home/asif/projects  btrfs subvol=@projects,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120,nofail  0 0
EOF
```

**`commit=120`** — Btrfs metadata flush interval (default 30s). Batching to 120s reduces SSD write operations for bursty dev workloads. Tradeoff: up to 120s of uncommitted metadata on power loss — acceptable on a battery-backed laptop with NVMe power-loss protection. `@containers` omits it because `nodatacow` bypasses the journal.

**`nofail`** on `@projects` — the user account `asif` is created during initial setup. The `/home/asif` directory may not exist when systemd parses fstab, so this mount would fail and stall boot without `nofail`. Phase D.1 mounts it manually after user creation.

**`autodefrag`** on `@home` — enables background defragmentation for small random writes. Improves performance for databases (SQLite, browser profiles) and dotfile-heavy workloads.

### C.4 Rebuild initramfs and Boot

```bash
sudo mkdir -p /mnt/root
sudo mount -o subvol=@ /dev/nvme0n1p4 /mnt/root

sudo mount --bind /dev /mnt/root/dev
sudo mount --bind /proc /mnt/root/proc
sudo mount --bind /sys /mnt/root/sys
sudo mount --bind /run /mnt/root/run
sudo mount /dev/nvme0n1p2 /mnt/root/boot
sudo mount /dev/nvme0n1p1 /mnt/root/boot/efi
sudo chroot /mnt/root

update-initramfs -u -k all
update-grub
exit

cd /
sudo umount -R /mnt/root
sudo umount -R /mnt/btrfs
sudo reboot
```

Remove the USB drive. The system boots: GRUB → Ubuntu → GNOME first-run wizard → install Omakub (Phase B.2).

### C.5 Btrfs Quotas

Prevent any single subvolume from consuming all disk space.

```bash
sudo btrfs quota enable /
sudo btrfs qgroup limit 500G /
sudo btrfs qgroup limit 300G /home
sudo btrfs qgroup limit 50G /var/log
sudo btrfs qgroup limit 100G /var/lib/docker
```

**Note:** Btrfs quotas add metadata overhead and can slow down heavy write workloads. Monitor with `btrfs qgroup show /`. Disable with `btrfs quota disable /` if performance degrades.

---

## Phase D — First Boot Validation

### D.1 Mount Points and Ownership

After Omakub installation and reboot, open Alacritty (Omakub's terminal).

```bash
mkdir -p ~/projects
sudo systemctl daemon-reload
sudo mount -a

sudo chown $USER:$USER ~/projects

findmnt -t btrfs
MOUNTS=$(findmnt -t btrfs --noheadings | wc -l)
[ "$MOUNTS" -ge 8 ] && echo "All $MOUNTS Btrfs mounts present" || echo "Only $MOUNTS/8 — check fstab"
```

### D.2 Verify AppArmor

```bash
sudo aa-status
# Expected: apparmor module is loaded, profiles in enforce mode
```

**Never disable AppArmor.** If a tool is blocked, create a targeted profile adjustment rather than disabling enforcement.

### D.3 Full System Update

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

### D.4 Firmware Updates

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr update

journalctl -b | grep microcode
```

### D.5 Verify Omakub Components

```bash
# Verify Omakub tools are functional
alacritty --version
zellij --version
nvim --version
mise --version
docker --version
lazygit --version
gh --version
```

---

## Phase E — System and Security Hardening

### E.1 APT Configuration

Speed up package operations and keep the cache clean.

```bash
sudo tee /etc/apt/apt.conf.d/99-performance << 'EOF'
APT::Install-Recommends "true";
APT::Install-Suggests "false";
APT::Get::Show-Versions "true";
Acquire::Languages "none";
Acquire::http::Pipeline-Depth "10";
EOF
```

### E.2 Multimedia Codecs

```bash
sudo apt install -y ubuntu-restricted-extras
sudo apt install -y gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  gstreamer1.0-libav libva-utils mesa-va-drivers mesa-vulkan-drivers \
  va-driver-all
```

### E.3 Kernel Parameters

```bash
SWAP_UUID=$(blkid -t TYPE=swap -s UUID -o value | head -1)

if [ -n "$SWAP_UUID" ]; then
    PARAMS="amd_pstate=active amd_iommu=on iommu=pt transparent_hugepage=madvise"
    PARAMS+=" nowatchdog nmi_watchdog=0 workqueue.power_efficient=1 pcie_aspm=default"
    PARAMS+=" mitigations=auto resume=UUID=$SWAP_UUID"

    sudo sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $PARAMS\"/" /etc/default/grub
    sudo update-grub
fi
```

### E.4 sysctl Tuning

```bash
sudo tee /etc/sysctl.d/90-zenbook.conf << 'EOF'
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
EOF
sudo sysctl --system
```

### E.5 DNS-over-TLS

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/performance.conf << 'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google
DNSOverTLS=opportunistic
Cache=yes
CacheFromLocalhost=yes
DNSSEC=allow-downgrade
EOF
sudo systemctl restart systemd-resolved
```

### E.6 UFW Firewall for Development

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
for port in 3000 5000 6006 8000 8080 8888 11434; do
    sudo ufw allow from 127.0.0.1 to any port $port proto tcp
done
sudo ufw allow in on docker0
sudo ufw enable
```

### E.7 systemd Service Optimization

```bash
sudo systemctl disable --now cups.service cups.socket cups.path 2>/dev/null || true
sudo systemctl disable --now cups-browsed.service 2>/dev/null || true
sudo systemctl mask ModemManager.service 2>/dev/null || true
sudo systemctl disable --now avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
sudo systemctl mask remote-fs.target 2>/dev/null || true
```

### E.8 systemd-oomd Tuning

```bash
sudo mkdir -p /etc/systemd/oomd.conf.d
sudo tee /etc/systemd/oomd.conf.d/ml-workload.conf << 'EOF'
[OOM]
SwapUsedLimit=95%
DefaultMemoryPressureLimit=70%
DefaultMemoryPressureDurationUSec=30s
EOF
sudo systemctl restart systemd-oomd 2>/dev/null || true
```

### E.9 journald, Core Dumps, tmpfs

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/optimize.conf << 'EOF'
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
Compress=yes
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no
EOF
sudo systemctl restart systemd-journald

sudo mkdir -p /etc/systemd/coredump.conf.d
sudo tee /etc/systemd/coredump.conf.d/limits.conf << 'EOF'
[Coredump]
Storage=external
MaxUse=1G
ProcessSizeMax=2G
EOF

sudo systemctl enable tmp.mount 2>/dev/null || true
sudo mkdir -p /etc/systemd/system/tmp.mount.d
sudo tee /etc/systemd/system/tmp.mount.d/size.conf << 'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=4G
EOF
sudo systemctl daemon-reload
```

### E.10 Hibernation

Hibernation writes RAM to swap and powers off completely — zero battery drain. Requires the `resume=UUID=<SWAP_UUID>` kernel parameter set in E.3.

```bash
grep -q "resume=" /proc/cmdline && echo "resume: OK" || echo "Add resume=UUID=<SWAP_UUID> to kernel cmdline (see E.3)"
free -h | awk '/Swap/{print "Swap: " $2}'
```

**Test hibernation** (save all work first):

```bash
sudo systemctl hibernate
```

### E.11 initramfs Optimization

```bash
sudo tee /etc/initramfs-tools/conf.d/performance.conf << 'EOF'
COMPRESS=zstd
RESUME=UUID=SWAP_UUID_PLACEHOLDER
EOF

SWAP_UUID=$(blkid -t TYPE=swap -s UUID -o value | head -1)
sudo sed -i "s/SWAP_UUID_PLACEHOLDER/$SWAP_UUID/" /etc/initramfs-tools/conf.d/performance.conf

sudo update-initramfs -u -k all
```

### E.12 Boot Experience

```bash
sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
sudo sed -i 's/^GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT="gfxterm"/' /etc/default/grub 2>/dev/null || true
sudo update-grub
```

### E.13 SSH Hardening

```bash
sudo apt install -y openssh-server
sudo tee /etc/ssh/sshd_config.d/hardened.conf << 'EOF'
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
EOF
sudo systemctl restart sshd 2>/dev/null || true
```

### E.14 fail2ban

```bash
sudo apt install -y fail2ban
sudo tee /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
EOF
sudo systemctl enable --now fail2ban
```

### E.15 Automatic Security Updates

```bash
sudo apt install -y unattended-upgrades
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

sudo tee /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

### E.16 Additional sysctl Hardening

```bash
sudo tee -a /etc/sysctl.d/90-zenbook.conf << 'EOF'

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
fs.suid_dumpable = 0
EOF
sudo sysctl --system
```

### E.17 Core Dump Restriction

```bash
echo "* hard core 0" | sudo tee -a /etc/security/limits.conf
```

### E.18 DNSSEC Strict Mode

Upgrade from `allow-downgrade` to strict DNSSEC validation.

```bash
sudo sed -i 's/^DNSSEC=allow-downgrade/DNSSEC=yes/' /etc/systemd/resolved.conf.d/performance.conf
sudo systemctl restart systemd-resolved
```

**Note:** Strict DNSSEC may cause failures on captive portals (hotel/airport WiFi). Temporarily revert: `sudo sed -i 's/^DNSSEC=yes/DNSSEC=allow-downgrade/' /etc/systemd/resolved.conf.d/performance.conf && sudo systemctl restart systemd-resolved`.

### E.19 Chrony NTP Hardening (NTS)

```bash
sudo apt install -y chrony
sudo tee /etc/chrony/conf.d/hardened.conf << 'EOF'
server time.cloudflare.com iburst nts
server nts.netnod.se iburst nts
server ptbtime1.ptb.de iburst nts
minsources 2
maxchange 100 1 1
makestep 1.0 3
EOF
sudo systemctl restart chronyd
```

### E.20 Audit Rules

```bash
sudo apt install -y auditd
sudo tee /etc/audit/rules.d/sensitive.rules << 'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /sbin/insmod -p x -k kernel_modules
-w /sbin/modprobe -p x -k kernel_modules
EOF
sudo augenrules --load 2>/dev/null || true
```

### E.21 Disable IPv6 (Optional)

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
sudo update-grub
sudo reboot
```

---

## Phase F — Hardware-Software Synchronization

### F.1 Power Profiles

Ubuntu 24.04 ships `power-profiles-daemon` which exposes the same `powerprofilesctl` API as Fedora's tuned-ppd. Do not install TLP or auto-cpufreq alongside it.

| Subsystem | Performance (AC) | Balanced (Battery) | Power Saver |
|---|---|---|---|
| CPU EPP | `performance` | `balance_performance` | `power` |
| CPU Boost | Full 4.7 GHz | Firmware-limited | Disabled |
| GPU Clock | Up to 2200 MHz | Dynamic 500–2200 MHz | 500 MHz floor |
| WiFi Power Save | Off | On | Aggressive |

```bash
powerprofilesctl get
powerprofilesctl set performance
powerprofilesctl list
```

### F.2 Automatic Profile Switching

```bash
sudo tee /etc/udev/rules.d/85-power-profile.rules << 'EOF'
SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_TYPE}=="Mains", ENV{POWER_SUPPLY_ONLINE}=="1", RUN+="/usr/bin/powerprofilesctl set performance"
SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_TYPE}=="Mains", ENV{POWER_SUPPLY_ONLINE}=="0", RUN+="/usr/bin/powerprofilesctl set balanced"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=power_supply
```

### F.3 Verify CPU

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
cat /sys/devices/system/cpu/cpufreq/boost
```

### F.4 Verify GPU and NVMe

```bash
lspci -k | grep -A3 VGA
vainfo 2>/dev/null | head -5
sudo nvme get-feature /dev/nvme0n1 -f 0x0c -H
```

### F.5 WiFi Power Save Off

```bash
sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
sudo systemctl restart NetworkManager
```

### F.6 Bluetooth Power

```bash
sudo sed -i 's/^#\?AutoEnable.*/AutoEnable=true/' /etc/bluetooth/main.conf
sudo sed -i 's/^#\?ControllerMode.*/ControllerMode = dual/' /etc/bluetooth/main.conf
sudo sed -i 's/^#\?FastConnectable.*/FastConnectable = true/' /etc/bluetooth/main.conf
sudo systemctl restart bluetooth
```

### F.7 PipeWire Audio

```bash
mkdir -p ~/.config/pipewire/pipewire.conf.d
cat > ~/.config/pipewire/pipewire.conf.d/performance.conf << 'EOF'
context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 44100 48000 ]
    default.clock.quantum = 1024
    default.clock.min-quantum = 512
    default.clock.max-quantum = 2048
}
EOF
systemctl --user restart pipewire pipewire-pulse
```

### F.8 Suspend/Resume (S0ix)

```bash
cat /sys/power/mem_sleep

sudo tee /etc/udev/rules.d/90-usb-wakeup.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTR{power/wakeup}="disabled"
EOF
sudo udevadm control --reload-rules
```

### F.9 GPU Power Cap

```bash
echo 15000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap

sudo tee /etc/udev/rules.d/86-amdgpu-power.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card0", RUN+="/bin/bash -c 'echo 15000000 > /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap'"
EOF
```

### F.10 NVMe I/O Scheduler

```bash
sudo tee /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
EOF
sudo udevadm control --reload-rules
```

### F.11 Battery Charge Threshold

```bash
echo 80 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold

sudo tee /etc/udev/rules.d/87-battery-threshold.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="power_supply", ATTR{type}=="Battery", ATTR{charge_control_end_threshold}="80"
EOF
```

### F.12 PCIe ASPM Force

```bash
sudo sed -i 's/pcie_aspm=default/pcie_aspm=force pcie_aspm.policy=powersupersave/' /etc/default/grub
sudo update-grub
```

**Warning:** Test thoroughly. If WiFi drops or NVMe stalls, revert to `pcie_aspm=default`.

### F.13 Deep CPU Idle States

```bash
CURRENT=$(grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub | head -1)
sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${CURRENT%\"} processor.max_cstate=9 amd_pstate.shared_mem=1\"|" /etc/default/grub
sudo update-grub
```

---

## Phase G — Display and Desktop Refinement

### G.1 Scaling

**200% integer scaling** — Settings → Displays → Scale → 200%. Pixel-perfect, zero GPU overhead. Effective resolution 1440×900.

**150% fractional** (alternative):

```bash
gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
```

### G.2 Font Rendering

PenTile Diamond Pixel layout requires grayscale antialiasing, not subpixel RGB rendering.

```bash
gsettings set org.gnome.desktop.interface font-antialiasing 'grayscale'
gsettings set org.gnome.desktop.interface font-hinting 'slight'
```

### G.3 ABR and PSR Tuning

```bash
CURRENT=$(grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub | head -1)
sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${CURRENT%\"} amdgpu.dcdebugmask=0x10 amdgpu.abmlevel=0\"|" /etc/default/grub
sudo update-grub
```

### G.4 OLED Burn-in Prevention

```bash
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 300
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 900
```

### G.5 GNOME Complementary Settings (Omakub-Safe)

These settings complement Omakub's desktop configuration without overriding its choices. Omakub sets workspace switching, app shortcuts, and themes; this section handles OLED-specific and privacy settings that Omakub does not touch.

```bash
# OLED true-black backgrounds
gsettings set org.gnome.desktop.background picture-options 'none'
gsettings set org.gnome.desktop.background primary-color '#000000'
gsettings set org.gnome.desktop.screensaver picture-options 'none'
gsettings set org.gnome.desktop.screensaver primary-color '#000000'

# Battery percentage in top bar
gsettings set org.gnome.desktop.interface show-battery-percentage true

# Disable system sounds
gsettings set org.gnome.desktop.sound event-sounds false

# Night light for OLED protection
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature 3500

# Privacy
gsettings set org.gnome.system.location enabled false
gsettings set org.gnome.desktop.privacy report-technical-problems false
gsettings set org.gnome.desktop.privacy recent-files-max-age 7
gsettings set org.gnome.desktop.privacy remove-old-temp-files true
gsettings set org.gnome.desktop.privacy old-files-age 7
```

### G.6 Tracker3 Indexing

Restrict Tracker3 to prevent CPU waste on `node_modules`, `.venv`, build artifacts.

```bash
gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories \
  "['&DESKTOP', '&DOCUMENTS', '&PICTURES', '&DOWNLOAD']"
gsettings set org.freedesktop.Tracker3.Miner.Files index-on-battery false
gsettings set org.freedesktop.Tracker3.Miner.Files index-removable-devices false
gsettings set org.freedesktop.Tracker3.Miner.Files crawling-interval -1

touch ~/projects/.trackerignore
```

### G.7 Nautilus Performance

```bash
gsettings set org.gnome.nautilus.preferences show-hidden-files false
gsettings set org.gnome.nautilus.preferences default-folder-viewer 'list-view'
gsettings set org.gnome.nautilus.list-view default-zoom-level 'small'
gsettings set org.gtk.Settings.FileChooser sort-directories-first true
```

---

## Phase H — Development Environment

### What Omakub Already Provides

Omakub installs: mise (version manager for Ruby, Node.js, Python, Go, Java), Docker, Neovim (LazyVim), VS Code, lazygit, lazydocker, gh CLI, fzf, ripgrep, eza, zoxide, bat. This phase adds everything else.

### H.1 System Packages

```bash
sudo apt install -y \
  build-essential gcc g++ gfortran make cmake ninja-build meson \
  clang llvm lld \
  python3-dev python3-venv \
  golang \
  libssl-dev libffi-dev zlib1g-dev libbz2-dev \
  libreadline-dev libsqlite3-dev libncurses-dev xz-utils tk-dev \
  libblas-dev liblapack-dev libopenblas-dev libhdf5-dev \
  git-lfs \
  btop iotop powertop \
  tmux \
  jq \
  shellcheck strace linux-tools-common linux-tools-generic stress-ng \
  lm-sensors nvme-cli smartmontools \
  btrfs-progs compsize \
  wget curl rsync bc \
  wl-clipboard \
  auditd \
  borgbackup
```

### H.2 Git Configuration Additions

Omakub configures basic Git via lazygit. This adds delta diffs, SSH signing, and performance features.

```bash
git config --global core.pager "delta"
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate true
git config --global delta.dark true
git config --global delta.line-numbers true
git config --global delta.side-by-side true

git config --global core.fsmonitor true
git config --global core.untrackedCache true
git config --global feature.manyFiles true

git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global merge.conflictstyle zdiff3

git config --global gpg.format ssh
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

### H.3 Git Delta

```bash
# Delta is not in Ubuntu repos by default — install from GitHub
DELTA_VER=$(curl -s https://api.github.com/repos/dandavison/delta/releases/latest | grep tag_name | cut -d '"' -f 4)
wget -q "https://github.com/dandavison/delta/releases/download/${DELTA_VER}/git-delta_${DELTA_VER}_amd64.deb" -O /tmp/git-delta.deb
sudo dpkg -i /tmp/git-delta.deb
rm -f /tmp/git-delta.deb
```

### H.4 Python Environment

```bash
mkdir -p ~/.config/pip
cat > ~/.config/pip/pip.conf << 'EOF'
[global]
require-virtualenv = true
EOF
```

### H.5 Python uv

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### H.6 Rust via rustup

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
rustup component add rust-analyzer clippy rustfmt
```

### H.7 SSH Keys and Configuration

```bash
mkdir -p ~/.ssh/sockets
chmod 700 ~/.ssh ~/.ssh/sockets

cat > ~/.ssh/config << 'EOF'
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
EOF
chmod 600 ~/.ssh/config

if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -C "asif@zenbook" -f ~/.ssh/id_ed25519
    echo "Public key (add to GitHub / remote servers):"
    cat ~/.ssh/id_ed25519.pub
fi

git config --global user.signingkey ~/.ssh/id_ed25519.pub
```

### H.8 Ollama (Local LLM)

```bash
curl -fsSL https://ollama.com/install.sh | sh

sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/resources.conf << 'EOF'
[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama
```

### H.9 zram Swap

```bash
sudo apt install -y systemd-zram-generator 2>/dev/null || true
sudo tee /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
sudo systemctl daemon-reload
```

If `systemd-zram-generator` is unavailable, use `zram-tools`:

```bash
sudo apt install -y zramswap
sudo sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
sudo sed -i 's/^#\?ALGORITHM=.*/ALGORITHM=zstd/' /etc/default/zramswap
sudo systemctl restart zramswap
```

### H.10 Shell Configuration Additions

Append to the shell config without conflicting with Omakub's settings. Omakub manages zsh/bash via its own dotfiles; this block is clearly delimited.

```bash
cat >> ~/.bashrc << 'BASHRC'

# --- Ubuntu 24.04 Post-Install ---
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT="%F %T "
shopt -s histappend

export OPENBLAS_NUM_THREADS=8
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
export NUMEXPR_MAX_THREADS=8

export ELECTRON_OZONE_PLATFORM_HINT=auto
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1

alias upgrade='sudo /usr/local/bin/safe-upgrade'
alias health='sudo /usr/local/bin/system-health'
alias snap='sudo /usr/local/bin/btrfs-snapshot'
alias top='btop'
# --- End Ubuntu 24.04 Post-Install ---
BASHRC
```

### H.11 Global .gitignore

```bash
mkdir -p ~/.config/git
cat > ~/.config/git/ignore << 'EOF'
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
EOF
git config --global core.excludesfile ~/.config/git/ignore
```

### H.12 tmux Configuration

```bash
cat > ~/.tmux.conf << 'EOF'
set -g default-terminal "tmux-256color"
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
bind - split-window -v -c "#{pane_current_path}"
EOF
```

### H.13 Docker Lingering

Omakub installs Docker. Enable lingering so containers run after logout.

```bash
loginctl enable-linger $(whoami)
```

---

## Phase I — Snapshot Automation and Tools

### I.1 Snapshot Manager

```bash
sudo tee /usr/local/bin/btrfs-snapshot << 'SCRIPT'
#!/bin/bash
set -euo pipefail

SNAP_ROOT="/.snapshots"
VERIFIED_LOG="$SNAP_ROOT/.verified"
TS=$(date +%Y%m%d-%H%M%S)
MAX=5

SPACE=$(btrfs filesystem usage / --raw 2>/dev/null | awk '/Free/{print $3; exit}')
MIN_FREE=$((10 * 1024 * 1024 * 1024))
if [ "${SPACE:-0}" -lt "$MIN_FREE" ]; then
    echo "  Less than 10 GiB free — run 'btrfs-snapshot clean' first"
    exit 1
fi

snap() {
    local src="$1" dst="$2" label="${3:-manual}"
    btrfs subvolume snapshot -r "$src" "${dst}/${TS}_${label}" >/dev/null
    echo "  + ${dst}/${TS}_${label}"
}

check_health() {
    local errors=0
    local failed; failed=$(systemctl --failed --no-pager --no-legend | wc -l)
    [ "$failed" -eq 0 ] || { echo "  $failed failed service(s)"; errors=$((errors+1)); }
    local aa; aa=$(sudo aa-status 2>/dev/null | head -1 || echo "unknown")
    echo "$aa" | grep -qi "apparmor module is loaded" || { echo "  AppArmor issue"; errors=$((errors+1)); }
    local berr; berr=$(btrfs device stats / 2>/dev/null | grep -v ' 0$' | wc -l)
    [ "$berr" -eq 0 ] || { echo "  Btrfs: $berr error(s)"; errors=$((errors+1)); }
    local mounts; mounts=$(findmnt -t btrfs --noheadings | wc -l)
    [ "$mounts" -ge 8 ] || { echo "  Only $mounts/8 Btrfs subvolumes"; errors=$((errors+1)); }
    return $errors
}

mark_verified() { touch "$VERIFIED_LOG"; echo "$1" >> "$VERIFIED_LOG"; echo "  * Group $1 VERIFIED"; }
last_verified() { [ -f "$VERIFIED_LOG" ] && tail -1 "$VERIFIED_LOG" || echo ""; }
is_verified() { [ -f "$VERIFIED_LOG" ] && grep -qx "$1" "$VERIFIED_LOG"; }

do_coordinated_snap() {
    local label="$1" verified=false
    if [ "${2:-yes}" = "yes" ]; then
        echo "Verifying system health..."
        check_health && { echo "  Healthy"; verified=true; } || echo "  Issues — snapshot NOT verified"
    fi
    snap / "$SNAP_ROOT/root" "$label"
    snap /home "$SNAP_ROOT/home" "$label"
    snap /home/asif/projects "$SNAP_ROOT/projects" "$label"
    $verified && mark_verified "$TS"
    echo "Done. Group: $TS"
}

case "${1:-help}" in
    pre-upgrade) echo "Creating pre-upgrade snapshots..."; do_coordinated_snap "pre-upgrade" ;;
    group) do_coordinated_snap "${2:-manual}" ;;
    root|home|projects)
        src="/"; [ "$1" = "home" ] && src="/home"; [ "$1" = "projects" ] && src="/home/asif/projects"
        snap "$src" "$SNAP_ROOT/$1" "${2:-manual}" ;;
    verify) echo "Health check..."; check_health && echo "Healthy" || { echo "Failed"; exit 1; } ;;
    list) for d in root home projects; do [ -d "$SNAP_ROOT/$d" ] || continue; echo "$d:"; ls -1 "$SNAP_ROOT/$d/"; done ;;
    clean) keep=${2:-$MAX}; for d in root home projects; do dir="$SNAP_ROOT/$d"; [ -d "$dir" ] || continue; count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d | wc -l); if [ "$count" -gt "$keep" ]; then find "$dir" -maxdepth 1 -mindepth 1 -type d | sort | head -n $((count-keep)) | while read -r s; do btrfs subvolume delete "$s" >/dev/null; echo "  Deleted: $(basename "$s")"; done; fi; done ;;
    rollback) echo "Boot Ubuntu Live USB, mount subvolid=5, restore from /.snapshots/"; last_verified && echo "Last verified: $(last_verified)" ;;
    *) echo "Usage: btrfs-snapshot {pre-upgrade|group|verify|list|clean|rollback}" ;;
esac
SCRIPT
sudo chmod +x /usr/local/bin/btrfs-snapshot
```

### I.2 Safe Upgrade

```bash
sudo tee /usr/local/bin/safe-upgrade << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Ubuntu Safe Upgrade ==="
echo "[1/5] Snapshots..."; /usr/local/bin/btrfs-snapshot pre-upgrade
echo "[2/5] Upgrading..."; apt update && apt full-upgrade -y "$@"
echo "[3/5] Firmware..."; fwupdmgr refresh 2>/dev/null || true; fwupdmgr update 2>/dev/null || true
echo "[4/5] Health check..."
FAILED=$(systemctl --failed --no-pager --no-legend | wc -l)
BERR=$(btrfs device stats / 2>/dev/null | grep -v ' 0$' | wc -l)
AA=$(aa-status 2>/dev/null | head -1 || echo "unknown")
echo "  Failed: $FAILED | Btrfs errors: $BERR | AppArmor: $AA"
echo "[5/5] Verdict..."
[ "$FAILED" -eq 0 ] && [ "$BERR" -eq 0 ] && echo "  System healthy after upgrade" || echo "  Issues detected"
SCRIPT
sudo chmod +x /usr/local/bin/safe-upgrade
```

### I.3 System Health Dashboard

```bash
sudo tee /usr/local/bin/system-health << 'SCRIPT'
#!/bin/bash
set -euo pipefail

echo ""
echo "============================================"
echo "  System Health · $(date '+%Y-%m-%d %H:%M')"
echo "============================================"

echo ""; echo "Kernel & Boot"
echo "  Kernel: $(uname -r) · Uptime: $(uptime -p)"
FAILED=$(systemctl --failed --no-pager --no-legend | wc -l)
[ "$FAILED" -eq 0 ] && echo "  [OK] No failed services" || echo "  [!!] $FAILED failed"
AA=$(aa-status 2>/dev/null | head -1 || echo "unknown")
echo "  AppArmor: $AA"

echo ""; echo "CPU & Thermal"
echo "  Driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null) · EPP: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null) · Profile: $(powerprofilesctl get 2>/dev/null)"
if command -v sensors &>/dev/null; then
    T=$(sensors 2>/dev/null | grep -iE "tctl|tdie" | head -1 | sed -n 's/.*+\([0-9]*\)\..*/\1/p')
    [ -n "$T" ] && echo "  CPU Temp: ${T}C"
fi

echo ""; echo "Memory"
echo "  $(free -h | awk '/Mem:/{printf "RAM: %s/%s (%s available)", $3, $2, $7}')"

echo ""; echo "Storage"
echo "  Root: $(df -h / | awk 'NR==2{print $5, "used,", $4, "free"}')"
if command -v nvme &>/dev/null; then
    WEAR=$(sudo nvme smart-log /dev/nvme0n1 2>/dev/null | awk '/percentage_used/{print $3}' | tr -d '%')
    [ -n "$WEAR" ] && echo "  SSD wear: ${WEAR}%"
fi
BERR=$(btrfs device stats / 2>/dev/null | grep -v ' 0$' | wc -l)
[ "$BERR" -eq 0 ] && echo "  [OK] Btrfs: clean" || echo "  [!!] Btrfs: $BERR error(s)"

BAT=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
BSTAT=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)
[ -n "$BAT" ] && { echo ""; echo "Battery"; echo "  ${BAT}% ($BSTAT)"; }

echo ""; echo "Snapshots"
for d in root home projects; do
    [ -d "/.snapshots/$d" ] || continue
    C=$(find "/.snapshots/$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    L=$(find "/.snapshots/$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1 | xargs -r basename 2>/dev/null)
    echo "  $d: $C snapshot(s)${L:+, latest: $L}"
done
echo ""; echo "============================================"; echo ""
SCRIPT
sudo chmod +x /usr/local/bin/system-health
```

### I.4 Automated Timers

```bash
# Weekly coordinated snapshot
sudo tee /etc/systemd/system/btrfs-snap-weekly.service << 'EOF'
[Unit]
Description=Weekly coordinated snapshot
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot group weekly
ExecStartPost=/usr/bin/notify-send -u low "Btrfs Snapshot" "Weekly snapshot complete"
EOF

sudo tee /etc/systemd/system/btrfs-snap-weekly.timer << 'EOF'
[Unit]
Description=Weekly coordinated snapshot
[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

# Monthly cleanup
sudo tee /etc/systemd/system/btrfs-snap-clean.service << 'EOF'
[Unit]
Description=Monthly snapshot cleanup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot clean 5
EOF

sudo tee /etc/systemd/system/btrfs-snap-clean.timer << 'EOF'
[Unit]
Description=Monthly snapshot cleanup
[Timer]
OnCalendar=*-*-01 04:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now btrfs-snap-weekly.timer btrfs-snap-clean.timer
sudo systemctl enable --now fstrim.timer
sudo systemctl enable --now btrfs-scrub@-.timer 2>/dev/null || true
```

---

## Phase J — Backup, Baseline, and Maintenance

### J.1 BorgBackup

```bash
# Initialize (plug in external USB drive)
export BORG_REPO=/run/media/asif/backup-drive/borg-zenbook
borg init --encryption=repokey $BORG_REPO
```

```bash
sudo tee /usr/local/bin/backup-borg << 'SCRIPT'
#!/bin/bash
set -euo pipefail
export BORG_REPO=/run/media/asif/backup-drive/borg-zenbook

[ -d "$BORG_REPO" ] || { echo "Backup drive not mounted"; exit 1; }

borg create --stats --progress --compression zstd,3 \
    "${BORG_REPO}::zenbook-$(date +%Y%m%d-%H%M%S)" \
    /home/asif /etc \
    --exclude '/home/asif/.cache' \
    --exclude '/home/asif/.local/share/containers' \
    --exclude '/home/asif/.local/share/docker' \
    --exclude '/home/asif/projects/*/.venv' \
    --exclude '/home/asif/projects/*/node_modules' \
    --exclude '*.pyc' --exclude '__pycache__'

borg prune --stats --keep-daily 7 --keep-weekly 4 --keep-monthly 6 "$BORG_REPO"
borg compact "$BORG_REPO"
echo "Backup complete."
SCRIPT
sudo chmod +x /usr/local/bin/backup-borg
```

### J.2 Performance Baseline

```bash
sudo tee /usr/local/bin/perf-baseline << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Performance Baseline · $(date -I) ==="
BENCH="${HOME}/bench"
echo "--- Storage (write) ---"; dd if=/dev/zero of="$BENCH" bs=1M count=1024 oflag=direct 2>&1 | tail -1
echo "--- Storage (read) ---"; dd if="$BENCH" of=/dev/null bs=1M count=1024 iflag=direct 2>&1 | tail -1
rm -f "$BENCH"
echo "--- Btrfs compression ---"; compsize / 2>/dev/null | head -3 || true
echo "--- Boot time ---"; systemd-analyze; systemd-analyze blame | head -5
SCRIPT
sudo chmod +x /usr/local/bin/perf-baseline
```

### J.3 Post-Deployment Verification

```bash
echo "=== Deployment Verification ==="

echo ""; echo "Subvolumes:"
findmnt -t btrfs --noheadings -o TARGET | sort | sed 's/^/  /'
MOUNTS=$(findmnt -t btrfs --noheadings | wc -l)
[ "$MOUNTS" -ge 8 ] && echo "  ($MOUNTS/8 mounted)" || echo "  Only $MOUNTS/8 — check fstab"

echo ""; echo "Kernel params:"
for p in amd_pstate amd_iommu transparent_hugepage nowatchdog workqueue.power_efficient pcie_aspm resume; do
    grep -q "$p" /proc/cmdline && echo "  [OK] $p" || echo "  [!!] $p MISSING"
done

echo ""; echo "Hardware:"
echo "  CPU driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo 'MISSING')"
echo "  Power profile: $(powerprofilesctl get 2>/dev/null || echo 'MISSING')"
echo "  AppArmor: $(aa-status 2>/dev/null | head -1 || echo 'MISSING')"
echo "  Session: $XDG_SESSION_TYPE"

echo ""; echo "Timers:"
systemctl list-timers --no-pager | grep -E "fstrim|btrfs|snap" | awk '{printf "  %s\n", $NF}'

echo ""; echo "Scripts:"
for s in btrfs-snapshot safe-upgrade system-health perf-baseline backup-borg; do
    [ -x "/usr/local/bin/$s" ] && echo "  [OK] $s" || echo "  [!!] $s missing or not executable"
done

echo ""; echo "Security hardening:"
systemctl is-active fail2ban &>/dev/null && echo "  [OK] fail2ban" || echo "  [!!] fail2ban"
sudo ufw status | grep -q "Status: active" && echo "  [OK] UFW active" || echo "  [!!] UFW inactive"
swapon --show | grep -q zram && echo "  [OK] zram active" || echo "  [!!] zram missing"
THRESH=$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null)
[ "$THRESH" = "80" ] && echo "  [OK] Battery threshold: 80%" || echo "  [??] Battery threshold: ${THRESH:-not set}"
cat /sys/block/nvme0n1/queue/scheduler | grep -q '\[none\]' && echo "  [OK] NVMe scheduler: none" || echo "  [!!] NVMe scheduler not optimal"
resolvectl status 2>/dev/null | grep -q DNSOverTLS && echo "  [OK] DNS-over-TLS active" || echo "  [??] DNS-over-TLS not confirmed"

echo ""; echo "Omakub components:"
for cmd in alacritty zellij nvim mise docker lazygit gh; do
    command -v "$cmd" &>/dev/null && echo "  [OK] $cmd" || echo "  [!!] $cmd missing"
done
```

### J.4 Monthly Maintenance

```
1. sudo safe-upgrade                     # Snapshot + upgrade + health
2. sudo btrfs-snapshot clean 5           # Prune snapshots
3. sudo btrfs scrub start /              # Data integrity
4. sudo fwupdmgr get-updates             # Firmware
5. journalctl -p 3 -b --no-pager | tail  # Errors
6. sudo system-health                    # Dashboard
7. flatpak update -y && flatpak uninstall --unused -y
8. backup-borg                           # Off-device backup
```

### J.5 Weekly Maintenance

```
1. sudo system-health
2. sudo btrfs device stats /
3. journalctl -p 4 -b --no-pager | tail -20
```

### J.6 Annual Review

```
1. Review kernel parameters (new kernels change defaults)
2. Review disabled services (new Ubuntu features)
3. Test suspend/resume after kernel updates
4. sudo perf-baseline                     # Compare against initial
5. borg check $BORG_REPO                  # Backup integrity
6. sudo ausearch -m AVC --start this-month # AppArmor denials
```

### J.7 Flatpak Auto-Update Timer

```bash
sudo tee /etc/systemd/system/flatpak-update.service << 'EOF'
[Unit]
Description=Flatpak auto-update
[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update -y --noninteractive
EOF

sudo tee /etc/systemd/system/flatpak-update.timer << 'EOF'
[Unit]
Description=Weekly Flatpak update
[Timer]
OnCalendar=Wed *-*-* 04:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
sudo systemctl enable --now flatpak-update.timer
```

### J.8 SMART Monitoring

```bash
sudo apt install -y smartmontools
sudo systemctl enable --now smartd
```

### J.9 Remote Backup

```bash
sudo tee /usr/local/bin/backup-borg-remote << 'SCRIPT'
#!/bin/bash
set -euo pipefail
export BORG_REPO=ssh://user@backup-server/~/borg-zenbook

borg create --stats --compression zstd,3 \
    "${BORG_REPO}::zenbook-$(date +%Y%m%d-%H%M%S)" \
    /home/asif /etc \
    --exclude '/home/asif/.cache' \
    --exclude '/home/asif/.local/share/containers' \
    --exclude '/home/asif/.local/share/docker' \
    --exclude '/home/asif/projects/*/.venv' \
    --exclude '/home/asif/projects/*/node_modules' \
    --exclude '*.pyc' --exclude '__pycache__'

borg prune --stats --keep-daily 7 --keep-weekly 4 --keep-monthly 6 "$BORG_REPO"
borg compact "$BORG_REPO"
SCRIPT
sudo chmod +x /usr/local/bin/backup-borg-remote

sudo tee /etc/systemd/system/backup-borg-remote.service << 'EOF'
[Unit]
Description=Weekly remote BorgBackup
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-borg-remote
EOF

sudo tee /etc/systemd/system/backup-borg-remote.timer << 'EOF'
[Unit]
Description=Weekly remote backup
[Timer]
OnCalendar=Sat *-*-* 02:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
sudo systemctl enable --now backup-borg-remote.timer
```

---

## Appendix — Configuration Reference

### Kernel Command Line

```
quiet splash amd_pstate=active amd_iommu=on iommu=pt transparent_hugepage=madvise nowatchdog nmi_watchdog=0 workqueue.power_efficient=1 pcie_aspm=force pcie_aspm.policy=powersupersave mitigations=auto resume=UUID=<SWAP_UUID> processor.max_cstate=9 amd_pstate.shared_mem=1 amdgpu.dcdebugmask=0x10 amdgpu.abmlevel=0
```

### /etc/sysctl.d/90-zenbook.conf

```ini
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
fs.suid_dumpable = 0
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
```

### Btrfs Mount Options

| Type | Options |
|---|---|
| Standard | `compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120` |
| Home | `compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120,autodefrag` |
| Logs | `compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,commit=120` |
| Containers | `nodatacow,noatime,ssd,discard=async,space_cache=v2` |

### Deployed Scripts

| Script | Purpose |
|---|---|
| `btrfs-snapshot` | Verified coordinated snapshot manager (group, verify, rollback) |
| `safe-upgrade` | Verify → snapshot → upgrade → verify → verdict |
| `system-health` | System health dashboard |
| `perf-baseline` | Performance benchmark |
| `backup-borg` | BorgBackup to external drive |
| `backup-borg-remote` | BorgBackup to remote SSH server |

### Active Timers

| Timer | Schedule | Purpose |
|---|---|---|
| `fstrim.timer` | Weekly | SSD TRIM |
| `btrfs-scrub@-.timer` | Monthly | Data integrity |
| `btrfs-snap-weekly.timer` | Sunday 3 AM | Coordinated snapshot (root + home + projects) |
| `btrfs-snap-clean.timer` | 1st of month | Snapshot cleanup |
| `flatpak-update.timer` | Wednesday 4 AM | Flatpak application updates |
| `apt-daily.timer` | Daily | Automatic security patches (unattended-upgrades) |
| `backup-borg-remote.timer` | Saturday 2 AM | Remote BorgBackup |

### Key Differences from Fedora 43 Deployment

| Aspect | Fedora 43 | Ubuntu 24.04 + Omakub |
|---|---|---|
| Package manager | DNF | APT |
| Security framework | SELinux (enforcing) | AppArmor (enforce) |
| Firewall | firewalld | UFW |
| Auto updates | dnf-automatic | unattended-upgrades |
| Desktop baseline | Minimal GNOME from scratch | Omakub (opinionated, pre-configured) |
| Containers | Podman (rootless) | Docker (Omakub default) |
| Terminal | Ghostty | Alacritty (Omakub default) |
| Multiplexer | tmux | Zellij (Omakub default) + tmux available |
| Version manager | Manual (fnm, rustup, etc.) | mise (Omakub) + rustup, uv |
| Kernel params | grubby | /etc/default/grub + update-grub |
| initramfs | dracut | update-initramfs |

---

*Ubuntu 24.04 LTS · ASUS Zenbook S 13 OLED UM5302TA · Samsung 990 Pro 1TB*
*Omakub + AppArmor enforcing · Definitive Deployment Guide*
