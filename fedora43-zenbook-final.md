# Fedora 43 Workstation — Definitive Deployment Guide
## ASUS Zenbook S 13 OLED (UM5302TA) · Samsung 990 Pro 1TB

**SELinux enforcing · Stability-first**

---

## How to Use This Guide

Follow each phase in order — every step builds on the previous one.

| Phase | What | When |
|---|---|---|
| A | BIOS and hardware preparation | Before installing Fedora |
| B | Fedora installation | Anaconda installer |
| C | Btrfs subvolume architecture | From live USB, immediately after install |
| D | First boot, update, firmware | First boot into installed system |
| E | Kernel, sysctl, DNF, systemd | Post-update configuration |
| F | Hardware synchronization | CPU, GPU, power, suspend, thermal |
| G | OLED display optimization | Display pipeline tuning |
| H | GNOME minimalism | Shell, Tracker, keybindings |
| I | Development environment | Packages, Python, Go, Git, Podman, SSH, Ollama |
| J | Snapshot automation and tools | Scripts, timers, health dashboard |
| K | Backup, baseline, maintenance | BorgBackup, perf-baseline, checklists |

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

**Advanced → CPU Configuration.** Enable SVM (for Podman/KVM). Enable CPPC (mandatory for `amd-pstate-epp`). Verify 8C/16T active. Enable C-state support (C6 and deeper).

**Advanced → NVMe/Storage.** Confirm the 990 Pro appears in NVMe mode (not RAID/RST).

**Advanced → Graphics.** Set iGPU as Primary. Disable Panel Self-Refresh (PSR) if exposed — PSR causes OLED flicker under `amdgpu`.

**Advanced → Power.** Set thermal profile to Performance if available, else Balanced.

**Security.** Enable TPM 2.0 (fTPM via AMD PSP). Leave Secure Boot keys at defaults.

### A.3 SSD Preparation (Optional — Skip for New Drives)

If the 990 Pro was previously used, Secure Erase from the Fedora live USB:

```bash
sudo nvme id-ctrl /dev/nvme0n1 | grep -E "^(mn|fr|sn)"
sudo nvme format /dev/nvme0n1 --ses=1 --force
sudo nvme smart-log /dev/nvme0n1
```

Verify firmware is **4B2QJXD7** or later (earlier firmware had wear and performance bugs).

---

## Phase B — Fedora Installation

### B.1 Partition Table

Boot the Fedora 43 Workstation live USB. In Anaconda, select **Custom** (Manual Partitioning):

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

Let Anaconda create its default layout on the Btrfs partition. We restructure it in Phase C.

**Begin Installation.** After Anaconda finishes, **do not reboot** — proceed directly to Phase C from the live environment.

---

## Phase C — Btrfs Subvolume Architecture

Done from the **live USB**, immediately after Anaconda finishes.

### C.1 Subvolume Design

| Subvolume | Mount | Snapshot Policy | Special Options | Why |
|---|---|---|---|---|
| `@` | `/` | Pre-upgrade + weekly | Standard | OS isolation |
| `@home` | `/home` | Pre-upgrade + weekly | Standard | Dotfiles, app state |
| `@snapshots` | `/.snapshots` | Never (avoids recursion) | Standard | Snapshot storage |
| `@var_log` | `/var/log` | Never | `compress=zstd:3` | Write-once logs compress 80–90% |
| `@var_cache` | `/var/cache` | Never | Standard | Fully regenerable (DNF, flatpak) |
| `@var_tmp` | `/var/tmp` | Never | Standard | Transient build artifacts |
| `@containers` | `/var/lib/containers` | Never | `nodatacow` | Podman overlay: disables CoW to eliminate write amplification. No checksums, but images are SHA256-verified |
| `@projects` | `~/projects` | Pre-upgrade + weekly | Standard | Independent lifecycle from OS and home |

### C.2 Create the Subvolumes

```bash
# Mount the top-level Btrfs volume
lsblk -f /dev/nvme0n1
# Look for: nvme0n1p4 → btrfs

sudo mkdir -p /mnt/btrfs
sudo mount -o subvolid=5 /dev/nvme0n1p4 /mnt/btrfs
cd /mnt/btrfs

# Inspect Anaconda's defaults
sudo btrfs subvolume list .
ls
# Fedora 43 may place files directly on the top-level (no subvolumes)
# OR create root/ and home/ subvolumes — adapt the next step accordingly
```

```bash
# If Anaconda created root/ and home/ subvolumes:
#   sudo mv root @
#   sudo mv home @home
# If Anaconda put everything on the top-level (no subvolumes):
sudo btrfs subvolume snapshot . @
sudo btrfs subvolume create @home
# Move home data into @home
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
sudo mkdir -p @/home @/.snapshots @/var/log @/var/cache @/var/tmp @/var/lib/containers

# Create snapshot category directories
sudo mkdir -p @snapshots/root @snapshots/home @snapshots/projects

# Verify — should show 8 subvolumes
sudo btrfs subvolume list .
COUNT=$(sudo btrfs subvolume list . | wc -l)
[ "$COUNT" -eq 8 ] && echo "✓ All 8 subvolumes created" || echo "✗ Found $COUNT subvolumes (expected 8)"
```

### C.3 Write the fstab

```bash
# Gather UUIDs
EFI_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p1)
BOOT_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p2)
SWAP_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p3)
BTRFS_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p4)

echo "EFI:   $EFI_UUID"
echo "Boot:  $BOOT_UUID"
echo "Swap:  $SWAP_UUID"
echo "Btrfs: $BTRFS_UUID"
# Verify all four are populated before proceeding
```

```bash
sudo tee @/etc/fstab << EOF
# /etc/fstab — Fedora 43 · UM5302TA · Btrfs
# $(date -I)

# Non-Btrfs
UUID=$EFI_UUID   /boot/efi  vfat   umask=0077,shortname=winnt  0 2
UUID=$BOOT_UUID  /boot      ext4   defaults                     0 2
UUID=$SWAP_UUID  none       swap   defaults                     0 0

# Btrfs subvolumes (Samsung 990 Pro)
UUID=$BTRFS_UUID /                    btrfs subvol=@,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120              0 0
UUID=$BTRFS_UUID /home                btrfs subvol=@home,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120           0 0
UUID=$BTRFS_UUID /.snapshots          btrfs subvol=@snapshots,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120      0 0
UUID=$BTRFS_UUID /var/log             btrfs subvol=@var_log,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,commit=120        0 0
UUID=$BTRFS_UUID /var/cache           btrfs subvol=@var_cache,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120      0 0
UUID=$BTRFS_UUID /var/tmp             btrfs subvol=@var_tmp,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120        0 0
UUID=$BTRFS_UUID /var/lib/containers  btrfs subvol=@containers,nodatacow,noatime,ssd,discard=async,space_cache=v2                      0 0
UUID=$BTRFS_UUID /home/asif/projects  btrfs subvol=@projects,compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120,nofail  0 0
EOF
```

**`commit=120`** — Btrfs metadata flush interval (default 30s). Batching to 120s reduces SSD write operations for bursty dev workloads. Tradeoff: up to 120s of uncommitted metadata on power loss — acceptable on a battery-backed laptop with NVMe power-loss protection. `@containers` omits it because `nodatacow` bypasses the journal.

**`nofail`** on `@projects` — the user account `asif` is created by GNOME initial-setup during first boot. The `/home/asif` directory doesn't exist when systemd parses fstab, so this mount would fail and stall boot without `nofail`. Phase D.1 mounts it manually after user creation.

### C.4 Rebuild initramfs and Boot

```bash
# Mount @ as a proper subvolume root (grub2-probe needs this)
sudo mkdir -p /mnt/root
sudo mount -o subvol=@ /dev/nvme0n1p4 /mnt/root

sudo mount --bind /dev /mnt/root/dev
sudo mount --bind /proc /mnt/root/proc
sudo mount --bind /sys /mnt/root/sys
sudo mount --bind /run /mnt/root/run
sudo mount /dev/nvme0n1p2 /mnt/root/boot
sudo mount /dev/nvme0n1p1 /mnt/root/boot/efi
sudo chroot /mnt/root

dracut --force --regenerate-all
grub2-mkconfig -o /boot/grub2/grub.cfg
exit

cd /
sudo umount -R /mnt/root
sudo umount -R /mnt/btrfs
sudo reboot
```

Remove the USB drive. The system boots: GRUB → Fedora.

---

## Phase D — First Boot

### D.1 Initial Setup and Mount Points

Complete the GNOME first-run wizard. Open a terminal.

```bash
mkdir -p ~/projects
sudo systemctl daemon-reload
sudo mount -a

# Fix ownership — subvolume was created as root in Phase C
sudo chown $USER:$USER ~/projects

# Restore SELinux labels — subvolume roots created in Phase C have wrong context
sudo restorecon -Rv /var/log /var/cache /var/tmp /var/lib/containers /.snapshots ~/projects

# Verify all 8 Btrfs subvolumes
findmnt -t btrfs
MOUNTS=$(findmnt -t btrfs --noheadings | wc -l)
[ "$MOUNTS" -ge 8 ] && echo "✓ All $MOUNTS Btrfs mounts present" || echo "✗ Only $MOUNTS/8 — check fstab"
```

### D.2 Verify SELinux

```bash
getenforce
# Expected: Enforcing
```

**Never disable SELinux.** If a tool is blocked, fix it with a targeted policy module (Phase E.9).

### D.3 Full System Update

```bash
sudo dnf upgrade -y --refresh
sudo reboot
```

### D.4 Firmware Updates

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr update            # Checks and applies in one step

# Verify AMD CPU microcode loaded
journalctl -b | grep microcode
```

---

## Phase E — System Configuration

### E.1 DNF Configuration

Speed up package operations and keep 4 kernel versions for rollback safety. `metadata_expire=172800` (48 hours) reduces mirror hits. `keepcache=True` stores downloaded RPMs locally so reinstalls don't re-download.

```bash
sudo tee /etc/dnf/dnf.conf << 'EOF'
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
EOF
```

### E.2 RPM Fusion and Multimedia Codecs

Fedora ships `ffmpeg-free` (patent-encumbered codecs removed). RPM Fusion provides the full `ffmpeg` with H.264, HEVC, and AAC support. The Mesa VA-API and Vulkan drivers enable hardware video decoding on the Radeon 680M — without them, video playback uses CPU, which burns battery and generates heat on the OLED panel.

```bash
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm

sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
sudo dnf install -y \
  gstreamer1-plugins-bad-free gstreamer1-plugins-ugly \
  gstreamer1-plugin-libav libva-utils mesa-va-drivers mesa-vulkan-drivers

vainfo
# Should list VAProfileH264Main, VAProfileHEVCMain, VAProfileAV1Profile0
```

**Verify:** `vainfo` should list at least H264, HEVC, and AV1 profiles. Play a 4K YouTube video in Firefox — `htop` should show low CPU usage (under 20%) with GPU doing the decode work.

### E.3 Kernel Parameters

Fedora 43 Workstation installs GRUB2 as the default bootloader. systemd-boot binaries ship with the `systemd` package but are not configured as the active loader. This guide uses GRUB2 exclusively.

```bash
SWAP_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p3)
echo "Swap UUID: $SWAP_UUID"
[ -n "$SWAP_UUID" ] || { echo "ERROR: Could not detect swap UUID"; exit 1; }

# grubby is Fedora's kernel argument manager — no manual editing needed.
# It modifies BLS entries directly. New kernels inherit from existing entries.
PARAMS="amd_pstate=active amd_iommu=on iommu=pt transparent_hugepage=madvise"
PARAMS+=" nowatchdog nmi_watchdog=0 workqueue.power_efficient=1 pcie_aspm=default"
PARAMS+=" mitigations=auto resume=UUID=$SWAP_UUID"

sudo grubby --update-kernel=ALL --args="$PARAMS"
sudo grubby --default-kernel --info | grep args    # Confirm params applied
```

| Parameter | Purpose |
|---|---|
| `amd_pstate=active` | Hardware-guided EPP frequency scaling via CPPC v2 |
| `amd_iommu=on iommu=pt` | IOMMU passthrough for Podman device access |
| `transparent_hugepage=madvise` | THP only for apps that opt in (NumPy, PyTorch) |
| `nowatchdog nmi_watchdog=0` | Disable watchdog timers — saves power and CPU interrupts |
| `workqueue.power_efficient=1` | Consolidate kernel work for deeper C-states on battery |
| `pcie_aspm=default` | BIOS-validated PCIe link power management for NVMe and WiFi |
| `mitigations=auto` | Keep CPU security mitigations at kernel defaults |
| `resume=UUID=<SWAP_UUID>` | Swap partition for hibernation resume |

```bash
sudo reboot
```

**Verify after reboot:**

```bash
cat /proc/cmdline
# Confirm all parameters are present
for p in amd_pstate amd_iommu transparent_hugepage nowatchdog workqueue.power_efficient pcie_aspm resume; do
    grep -q "$p" /proc/cmdline && echo "✓ $p" || echo "✗ $p MISSING"
done
```

### E.4 sysctl Tuning

These kernel parameters optimize virtual memory for an NVMe-backed dev laptop, enable BBR congestion control for better network throughput, and apply baseline security hardening.

```bash
sudo tee /etc/sysctl.d/90-zenbook.conf << 'EOF'
# === Virtual Memory ===
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 300
vm.vfs_cache_pressure = 50
vm.max_map_count = 262144

# === Network (BBR + optimized buffers) ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096

# === Kernel ===
# SysRq bitmask 150 = 128+16+4+2: reboot, sync, keyboard(SAK), log-level
# Intentionally excludes terminate-all(64), remount-ro(32), memory-dump(8)
kernel.sysrq = 150
kernel.panic = 10
kernel.dmesg_restrict = 1

# === Security hardening ===
kernel.unprivileged_bpf_disabled = 1
kernel.kptr_restrict = 1

# === Filesystem ===
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF

sudo sysctl --system
```

**Key values explained:** `swappiness=10` — prefer keeping data in RAM, only swap under real pressure (16 GB RAM is generous for dev work). `dirty_ratio=15` / `dirty_background_ratio=5` — start flushing dirty pages at 5% of RAM in the background, block writes at 15%; keeps the NVMe busy without risking large data loss. `vfs_cache_pressure=50` — retain inode/dentry caches longer (helps repeated builds and file searches). `max_map_count=262144` — required for large ML model memory maps (PyTorch, Ollama). `tcp_fastopen=3` — enable TFO for both client and server connections (faster API/webhook round-trips). `inotify` limits — VS Code, Webpack, and other file watchers need high limits for large project trees.

**Verify:**

```bash
sysctl vm.swappiness net.ipv4.tcp_congestion_control kernel.sysrq fs.inotify.max_user_watches
```

### E.5 DNS-over-TLS

Encrypts DNS queries so your ISP or network operator cannot see which domains you resolve. `opportunistic` means: use TLS when the resolver supports it, fall back to plain DNS if it doesn't — no hard failures on captive portals or hotel WiFi.

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
resolvectl status
```

**Verify:** `resolvectl status` should show your configured DNS servers and `DNSOverTLS: opportunistic`. Test with `resolvectl query fedoraproject.org` — the response should come from Cloudflare or Quad9, not your ISP's resolver.

### E.6 Firewall for Development

Opens common development ports on localhost only — external machines cannot reach them. SSH is opened to the local network for remote access (e.g., from a desktop). The ports: 3000 (Node/React dev server), 5000 (Flask), 6006 (TensorBoard), 8000 (Django/FastAPI), 8080 (general dev), 8888 (Jupyter), 11434 (Ollama API).

```bash
sudo firewall-cmd --set-default-zone=home

for port in 3000 5000 6006 8000 8080 8888 11434; do
  sudo firewall-cmd --permanent --zone=home \
    --add-rich-rule="rule family=ipv4 source address=127.0.0.1/32 port port=$port protocol=tcp accept"
done

# SSH: open to local network for remote access to this laptop.
# Harden sshd separately: sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# To restrict SSH to localhost only (like dev ports above), replace with:
#   sudo firewall-cmd --permanent --zone=home \
#     --add-rich-rule="rule family=ipv4 source address=127.0.0.1/32 port port=22 protocol=tcp accept"
sudo firewall-cmd --permanent --zone=home --add-service=ssh
sudo firewall-cmd --permanent --zone=trusted --add-interface=podman0
sudo firewall-cmd --reload
```

**Verify:** `sudo firewall-cmd --zone=home --list-all` should show your rich rules and SSH. Test: `curl -s http://localhost:11434` after Ollama is running (Phase I.8).

### E.7 systemd Service Optimization

Disable services that waste resources on a developer laptop with no printer and no local network discovery. `mask` prevents a service from starting even as a dependency; `disable` just removes the auto-start but allows manual activation.

```bash
# Disable unnecessary
sudo systemctl disable --now cups.service cups.socket cups.path 2>/dev/null        # Printing (no printer)
sudo systemctl disable --now cups-browsed.service 2>/dev/null                       # Printer discovery
sudo systemctl mask ModemManager.service                                            # Cellular modem (none present)
sudo systemctl disable --now avahi-daemon.service avahi-daemon.socket               # mDNS/Bonjour (not needed)
sudo systemctl disable --now abrtd.service abrt-journal-core.service abrt-oops.service 2>/dev/null  # Crash reporter
sudo systemctl mask remote-fs.target                                                # Network filesystems (NFS/CIFS)
sudo systemctl disable --now pcscd.service pcscd.socket 2>/dev/null                 # Smart card reader (none present)

# Verify critical services
echo "=== System services ==="
for svc in NetworkManager firewalld power-profiles-daemon fwupd \
           systemd-oomd systemd-resolved systemd-journald bluetooth; do
    printf "  %-28s %s\n" "$svc" "$(systemctl is-enabled $svc 2>/dev/null || echo 'NOT FOUND')"
done
echo "=== User services ==="
for svc in pipewire pipewire-pulse; do
    printf "  %-28s %s\n" "$svc" "$(systemctl --user is-enabled $svc 2>/dev/null || echo 'NOT FOUND')"
done
```

All critical services should show `enabled`. If you later need printing, unmask cups: `sudo systemctl unmask cups.service && sudo systemctl enable --now cups`.

### E.8 systemd-oomd Tuning for ML Workloads

`systemd-oomd` monitors memory pressure across cgroups and kills the most memory-hungry process before the kernel OOM killer freezes your session. Default thresholds are too aggressive for ML inference — a large model can briefly spike swap and memory pressure without actually being stuck. These values give Ollama and Python workloads more headroom: 95% swap usage and 70% memory pressure sustained for 30 seconds before oomd intervenes.

```bash
sudo mkdir -p /etc/systemd/oomd.conf.d

sudo tee /etc/systemd/oomd.conf.d/ml-workload.conf << 'EOF'
[OOM]
SwapUsedLimit=95%
DefaultMemoryPressureLimit=70%
DefaultMemoryPressureDurationUSec=30s
EOF

sudo systemctl restart systemd-oomd
```

**Verify:** `oomctl` shows the current configuration and monitored cgroups. To see oomd in action (non-destructive): `journalctl -u systemd-oomd -f` in one terminal while running a memory-intensive task in another.

### E.9 SELinux Workflow

SELinux blocks processes from accessing resources outside their expected policy. When something is denied, it logs an AVC (Access Vector Cache) message. The workflow: find the denial, generate a targeted policy module, install it. This is surgical — you're granting exactly the permission that was denied, not opening the floodgates.

```bash
# Step 1: Find recent denials (read first to understand what was blocked)
sudo ausearch -m AVC --start recent

# Step 2: Generate + install a targeted policy module in one pipeline
sudo ausearch -m AVC --start recent | audit2allow -M my-local-fix && \
sudo semodule -i my-local-fix.pp && \
rm -f my-local-fix.te my-local-fix.pp

# Podman rootless — required for containers to manage cgroups
sudo setsebool -P container_manage_cgroup true
```

**Common scenario:** Ollama writes to a non-standard path → SELinux denies it → `ausearch` shows the AVC → `audit2allow` generates a `.pp` module → `semodule -i` installs it → Ollama works. If you see no AVCs but something still fails, check `journalctl -t setroubleshoot` for human-readable explanations.

Never set SELinux to permissive or disabled.

### E.10 journald, Core Dumps, tmpfs

**journald** — cap persistent logs at 500 MB and runtime (RAM) logs at 100 MB to prevent log bloat from consuming the Btrfs root. `RateLimitBurst=10000` is high enough that build output and container logs won't get dropped. `ForwardToSyslog=no` avoids duplicate logging since journald is the primary.

```bash
# journald
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
```

**Core dumps** — store externally (not in journal) with a 1 GB cap. `ProcessSizeMax=2G` means processes using more than 2 GB of memory won't generate dumps (ML models would produce enormous useless cores).

```bash
# Core dumps
sudo mkdir -p /etc/systemd/coredump.conf.d
sudo tee /etc/systemd/coredump.conf.d/limits.conf << 'EOF'
[Coredump]
Storage=external
MaxUse=1G
ProcessSizeMax=2G
EOF
```

**tmpfs** — mount `/tmp` as a RAM-backed filesystem capped at 4 GB. Build artifacts and temp files stay in RAM for speed and vanish on reboot. `nosuid,nodev` prevents privilege escalation via temp files.

```bash
# tmpfs for /tmp
sudo systemctl enable tmp.mount 2>/dev/null
sudo mkdir -p /etc/systemd/system/tmp.mount.d
sudo tee /etc/systemd/system/tmp.mount.d/size.conf << 'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=4G
EOF
sudo systemctl daemon-reload
```

**Verify:** `journalctl --disk-usage` (should be well under 500 MB on a fresh system). `findmnt /tmp` should show `tmpfs` with `size=4G`.

### E.11 Hibernation

Hibernation writes all RAM contents to swap and powers off completely — zero battery drain. On resume, the kernel reads swap back into RAM and restores your session. This requires the `resume=UUID=<SWAP_UUID>` kernel parameter (set in E.3) and the `resume` dracut module (E.12).

```bash
# Step 1: Verify kernel parameter
grep -q "resume=" /proc/cmdline && echo "resume: OK" || echo "Add resume=UUID=<SWAP_UUID> to kernel cmdline (see E.3)"

# Step 2: Verify swap is large enough (must be ≥ used RAM)
free -h | awk '/Swap/{print "Swap: " $2}'
```

The `resume` dracut module is configured in E.12 below.

**Test hibernation** (save all work first):

```bash
sudo systemctl hibernate
```

The laptop should power off completely (not just sleep). Press the power button — it should resume to your exact session. If it boots fresh instead of resuming, the `resume=` parameter or dracut module is misconfigured. If hibernation hangs, check `journalctl -b -1 | grep -i hibernate` from the previous boot for clues.

### E.12 dracut Initramfs Optimization

dracut builds the initramfs — the tiny filesystem the kernel loads before mounting root. This config: compresses it with zstd (fastest decompression), includes the `btrfs` module (required to mount your root filesystem) and `resume` module (required for hibernation), loads AMD GPU and MediaTek WiFi firmware early (so the display and network work immediately), and omits modules for network storage you'll never use (NFS, iSCSI, multipath).

```bash
sudo mkdir -p /etc/dracut.conf.d

sudo tee /etc/dracut.conf.d/performance.conf << 'EOF'
compress="zstd"
add_dracutmodules+=" btrfs resume "
early_microcode="yes"
omit_dracutmodules+=" nfs iscsi fcoe fcoe-uefi multipath "
install_optional_items+=" /lib/firmware/amdgpu/* /lib/firmware/mediatek/* "
EOF

# Set plymouth theme before rebuilding (dracut embeds the active theme)
sudo plymouth-set-default-theme spinner

sudo dracut --force --regenerate-all
```

**Verify:** `lsinitrd | head -20` shows the initramfs contents. Confirm `btrfs` and `resume` appear in the module list: `lsinitrd | grep -E "btrfs|resume"`.

### E.13 Boot Experience

Reduce the GRUB menu timeout from 5s to 2s (enough to press a key if needed, but doesn't waste time on every boot). `gfxterm` renders the menu with the GPU for proper resolution on the OLED panel instead of fallback text mode.

```bash
sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
sudo sed -i 's/^GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT="gfxterm"/' /etc/default/grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

**After reboot:** the GRUB menu should appear briefly (2 seconds) in high resolution, then boot straight into Fedora with a smooth Plymouth spinner animation. Total boot time target: under 10 seconds to the login screen. Measure with `systemd-analyze` (covered in K.2).

---

## Phase F — Hardware-Software Synchronization

### F.1 Power Profiles

`power-profiles-daemon` is the central orchestrator — it coordinates CPU, GPU, NVMe, WiFi, and fan behavior in a single command. Do not install TLP or auto-cpufreq alongside it; they will fight over the same sysfs knobs and create unpredictable behavior.

| Subsystem | Performance (AC) | Balanced (Battery) | Power Saver |
|---|---|---|---|
| CPU EPP | `performance` | `balance_performance` | `power` |
| CPU Boost | Full 4.7 GHz | Firmware-limited | Disabled |
| GPU Clock | Up to 2200 MHz | Dynamic 500–2200 MHz | 500 MHz floor |
| NVMe APST | PS0–PS1 (active) | PS0–PS3 | PS0–PS4 (deepest) |
| WiFi Power Save | Off | On | Aggressive |
| Fan Profile | Aggressive cooling | Balanced | Silent |

**How to use:**

```bash
# Check current profile
powerprofilesctl get

# Switch manually
powerprofilesctl set performance    # Plug in, compiling, running inference
powerprofilesctl set balanced       # General use on battery
powerprofilesctl set power-saver    # Reading, writing, light browsing

# List available profiles
powerprofilesctl list
```

You can also switch profiles from the GNOME top bar → Power menu (battery icon). F.2 below automates switching based on AC/battery state, so in daily use you rarely need to switch manually.

**Test:** Run `powerprofilesctl set performance`, then check: `cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference` — should read `performance`. Switch to `power-saver` and check again — should read `power`.

### F.2 Automatic Profile Switching

This udev rule watches the power supply: plug in AC → switch to Performance; unplug → switch to Balanced. You never have to remember to change profiles.

```bash
sudo tee /etc/udev/rules.d/85-power-profile.rules << 'EOF'
SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_TYPE}=="Mains", ENV{POWER_SUPPLY_ONLINE}=="1", RUN+="/usr/bin/powerprofilesctl set performance"
SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_TYPE}=="Mains", ENV{POWER_SUPPLY_ONLINE}=="0", RUN+="/usr/bin/powerprofilesctl set balanced"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=power_supply
```

**Test:** Unplug the charger → `powerprofilesctl get` should say `balanced`. Plug it back in → should say `performance`. If it doesn't trigger, check `sudo udevadm monitor --property` while plugging/unplugging.

### F.3 Verify CPU

Confirm the `amd-pstate-epp` driver is active (not the older `acpi-cpufreq`). The EPP (Energy Performance Preference) value reflects the current power profile. Boost should be `1` (enabled) on AC.

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver       # Expected: amd-pstate-epp
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference  # performance/balance_performance/power
cat /sys/devices/system/cpu/cpufreq/boost                     # 1 = boost enabled
```

If `scaling_driver` shows `acpi-cpufreq`, the `amd_pstate=active` kernel parameter from E.3 is not being applied — recheck `/proc/cmdline`. To see real-time frequencies across all cores: `watch -n 0.5 cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`.

### F.4 Verify GPU and NVMe

Confirm the `amdgpu` kernel driver is loaded (not `radeon`), VA-API hardware decoding works (critical for video playback without CPU drain on OLED), and the 990 Pro's Autonomous Power State Transition (APST) is enabled (lets the SSD enter low-power states during idle).

```bash
lspci -k | grep -A3 VGA            # Should show: Kernel driver in use: amdgpu
vainfo 2>/dev/null | head -5       # Should list VA-API profiles (H264, HEVC, AV1)
sudo nvme get-feature /dev/nvme0n1 -f 0x0c -H   # APST feature — should show Enabled
# If APST disabled: add nvme_core.default_ps_max_latency_us=5000 to cmdline
```

If `vainfo` shows errors, the Mesa VA-API drivers from E.2 may not be installed. If APST is disabled, the BIOS may have turned it off — the kernel parameter override forces it back on with a 5ms latency tolerance.

### F.5 WiFi Power Save

Value `2` means "disable WiFi power save" — the radio stays fully active even on battery. The MT7922 chip's power save mode introduces latency spikes (50–200ms) that are noticeable during SSH sessions, API calls, and real-time collaboration. The power cost is small (~0.3W) compared to the OLED panel (~2W).

```bash
sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
sudo systemctl restart NetworkManager
```

**Verify:** `iw dev wlan0 get power_save` should show `Power save: off`. If you want to re-enable power save for extended battery life (e.g., reading on a plane), change the value to `3` and restart NetworkManager.

### F.6 Bluetooth Power

`AutoEnable=true` powers on the Bluetooth adapter at boot (so your peripherals reconnect automatically). `dual` mode supports both classic Bluetooth and BLE. `FastConnectable` reduces reconnection time for previously paired devices at a small power cost.

```bash
# BlueZ reads /etc/bluetooth/main.conf — edit the existing file
sudo sed -i 's/^#\?AutoEnable.*/AutoEnable=true/' /etc/bluetooth/main.conf
sudo sed -i 's/^#\?ControllerMode.*/ControllerMode = dual/' /etc/bluetooth/main.conf
sudo sed -i 's/^#\?FastConnectable.*/FastConnectable = true/' /etc/bluetooth/main.conf

sudo systemctl restart bluetooth
```

**Verify:** `bluetoothctl show` should show `Powered: yes`. If you don't use Bluetooth peripherals, you can skip this entirely and save ~0.5W by disabling the adapter: `sudo systemctl disable bluetooth`.

### F.7 PipeWire Audio

PipeWire replaces PulseAudio and JACK. The `quantum` is the audio buffer size in samples — larger values mean higher latency but fewer glitches. `1024` at 48 kHz = ~21ms latency, which is imperceptible for general use and media playback but avoids the pops and clicks that occur with smaller buffers on this hardware. If you do real-time audio work (DAW, MIDI), drop `quantum` to `256` and `min-quantum` to `64`.

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

**Verify:** `pw-top` shows real-time audio graph activity. Play a YouTube video or music file — audio should be clean with no pops. `pw-metadata -n settings` shows the active quantum value.

### F.8 Suspend/Resume (S0ix)

This laptop uses S0ix ("Modern Standby") instead of the traditional S3 deep sleep. S0ix keeps the SoC in a very low power state while allowing wake-on-event (WiFi, USB). The USB wakeup rule prevents rogue USB devices from waking the laptop during suspend — a common cause of "battery drained overnight" on Zenbooks.

```bash
cat /sys/power/mem_sleep   # Expected: [s2idle] deep — s2idle is the active choice
# If it shows [s2idle] only (no "deep"), that's normal for this hardware

# Fix S0ix drain — suppress USB wakeup
sudo tee /etc/udev/rules.d/90-usb-wakeup.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTR{power/wakeup}="disabled"
EOF
sudo udevadm control --reload-rules
```

**Test suspend/resume:** Close the lid and wait 30 seconds. Open it — should resume instantly. Check drain: `upower -i /sys/class/power_supply/BAT0` before and after a 1-hour suspend. S0ix on the UM5302TA typically drains 1–3% per hour. If drain exceeds 5%/hour, check `sudo cat /sys/kernel/debug/pmc_core/substate_requirements` (needs `debugfs` mounted) for devices blocking deep S0ix.

### F.9 PowerTop

PowerTop analyzes power consumption per device and process. Run it on battery for accurate readings — on AC, many power-saving features are intentionally disabled by `power-profiles-daemon`.

```bash
sudo dnf install -y powertop
sudo powertop                          # Interactive analysis (run on battery)
sudo powertop --html=powertop-report.html   # Generate HTML report
```

Review the "Tunables" tab for suggested optimizations. Some are already handled by this guide (USB autosuspend, NVMe APST, WiFi power save). Do not blindly run `powertop --auto-tune` — it enables every possible power saving, including ones that break suspend, cause WiFi drops, or introduce input lag. Apply individual suggestions only after understanding what they do.

### F.10 Thermal Reality Check

Thin ultrabook — under sustained all-core load, expect throttling at ~80–85°C, stabilizing at 3.0–3.5 GHz. This is normal. Use remote GPU for heavy compute. This laptop excels at development, light inference, and orchestration.

**Monitor thermals:**

```bash
# Real-time temperature (requires lm_sensors from I.1)
sudo sensors-detect --auto         # One-time setup — detects sensor chips
watch -n 1 sensors                 # Live temperatures (Tctl = CPU package temp)

# Track frequencies during a build (run in another terminal)
watch -n 0.5 "grep MHz /proc/cpuinfo | sort -t: -k2 -rn | head -4"

# Quick stress test (2 minutes, all cores — requires stress-ng from I.1)
stress-ng --cpu 16 --timeout 120 --metrics-brief
# While running, watch temperatures with: sensors
# Normal: Tctl ramps to 80-85°C, frequencies settle at 3.0-3.5 GHz
```

If temperatures exceed 95°C or the laptop shuts down, verify BIOS thermal tables are current (Phase A.1) and that air vents are unobstructed. Elevating the laptop 1–2 cm with a stand improves cooling by 3–5°C under load.

---

## Phase G — OLED Display Optimization

### G.1 Scaling

**200% integer scaling** — Settings → Displays → Scale → 200%. Pixel-perfect, zero GPU overhead. Effective resolution 1440×900.

**150% fractional** (alternative):

```bash
gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
# Then set 150% in Settings → Displays — gives 1920×1200 effective
```

### G.2 Font Rendering

PenTile Diamond Pixel ≠ RGB stripe. Standard LCD subpixel rendering (ClearType-style) assumes red-green-blue subpixels in a row — OLED PenTile has a diamond arrangement with alternating red/blue subpixels sharing green. Using `rgba` subpixel rendering on this panel produces visible color fringing on text edges. `grayscale` antialiasing treats each pixel as a single unit, which is the correct choice for PenTile at 2880×1800 (255 PPI).

```bash
gsettings set org.gnome.desktop.interface font-antialiasing 'grayscale'
gsettings set org.gnome.desktop.interface font-hinting 'slight'
```

**Verify:** Open a text editor and zoom to 200%. Text edges should be clean gray gradients, not colored fringes. If you see red/blue shimmer on letter edges, the setting didn't apply — check with `gsettings get org.gnome.desktop.interface font-antialiasing`.

### G.3 Wayland Environment Variables

Applied in Phase I.6 (`~/.bashrc`):

```
ELECTRON_OZONE_PLATFORM_HINT=auto   # Electron apps use Wayland natively
QT_QPA_PLATFORM=wayland             # Qt apps use Wayland
MOZ_ENABLE_WAYLAND=1                # Firefox Wayland
```

---

## Phase H — GNOME Minimalism

### H.1 Remove Unnecessary Applications

```bash
sudo dnf remove -y \
  gnome-maps gnome-contacts gnome-weather gnome-clocks gnome-tour \
  gnome-connections gnome-characters gnome-font-viewer gnome-abrt \
  mediawriter rhythmbox totem cheese simple-scan yelp \
  gnome-photos gnome-music gnome-boxes gnome-calendar \
  libreoffice-* fedora-bookmarks fedora-chromium-config 2>/dev/null
```

**Do not remove:** `gnome-shell`, `gnome-control-center`, `ptyxis`/`gnome-terminal`, `nautilus`, `gnome-text-editor`, `gnome-system-monitor`, `gnome-disk-utility`, `gnome-calculator`, `evince`, `gnome-software`, `file-roller`, `loupe`/`eog`, `baobab`.

### H.2 Complete GNOME Configuration

```bash
# --- Appearance (OLED) ---
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
gsettings set org.gnome.desktop.background picture-options 'none'
gsettings set org.gnome.desktop.background primary-color '#000000'
gsettings set org.gnome.desktop.screensaver picture-options 'none'
gsettings set org.gnome.desktop.screensaver primary-color '#000000'

# --- Interface ---
gsettings set org.gnome.desktop.interface enable-hot-corners false
gsettings set org.gnome.desktop.interface clock-show-date true
gsettings set org.gnome.desktop.interface show-battery-percentage true
gsettings set org.gnome.desktop.sound event-sounds false

# --- OLED Power (3 min idle → panel off → zero power) ---
gsettings set org.gnome.desktop.session idle-delay 180
gsettings set org.gnome.desktop.screensaver lock-enabled true
gsettings set org.gnome.desktop.screensaver lock-delay 0

# --- Night Light ---
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature 3500

# --- Window Management ---
gsettings set org.gnome.desktop.wm.preferences resize-with-right-button true
gsettings set org.gnome.mutter workspaces-only-on-primary false

# --- Privacy ---
gsettings set org.gnome.system.location enabled false
gsettings set org.gnome.desktop.privacy report-technical-problems false
gsettings set org.gnome.desktop.privacy recent-files-max-age 7
gsettings set org.gnome.desktop.privacy remove-old-temp-files true
gsettings set org.gnome.desktop.privacy old-files-age 7

# --- Search Providers ---
gsettings set org.gnome.desktop.search-providers disabled \
  "['org.gnome.Software.desktop', 'org.gnome.Characters.desktop', 'org.gnome.Calendar.desktop', 'org.gnome.clocks.desktop', 'org.gnome.Weather.desktop']"
```

### H.3 Tracker3 Indexing

Tracker3 is GNOME's file indexer — it powers Nautilus search and the Activities search bar. By default it crawls your entire home directory, which wastes CPU on `node_modules`, `.venv`, build artifacts, and container layers. This config restricts indexing to the four directories you'd actually search (Desktop, Documents, Pictures, Downloads) and tells Tracker to skip any directory containing common development markers. `crawling-interval -1` means "only index on-demand" — Tracker won't wake up periodically to rescan.

```bash
gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories \
  "['&DESKTOP', '&DOCUMENTS', '&PICTURES', '&DOWNLOAD']"

gsettings set org.freedesktop.Tracker3.Miner.Files ignored-directories-with-content \
  "['.trackerignore', '.git', '.hg', '.svn', 'node_modules', '__pycache__', '.venv', 'venv', '.tox', '.mypy_cache', '.pytest_cache', '.cargo', 'target', '.gradle', 'build', 'dist', '.eggs', '.cache', '.local']"

gsettings set org.freedesktop.Tracker3.Miner.Files index-on-battery false
gsettings set org.freedesktop.Tracker3.Miner.Files index-removable-devices false
gsettings set org.freedesktop.Tracker3.Miner.Files crawling-interval -1

touch ~/projects/.trackerignore
```

**Verify:** `tracker3 status` shows the indexer state. `tracker3 daemon -k` forces a stop if it's consuming CPU during setup. The `.trackerignore` sentinel in `~/projects` ensures the entire projects tree is skipped even if you later add it to indexed directories.

### H.4 Keyboard Shortcuts

```bash
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
  "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ \
  name 'Terminal'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ \
  command 'ptyxis'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ \
  binding '<Super>Return'
```

### H.5 Extensions Policy

Zero extensions. Only exception: `gnome-shell-extension-appindicator` from Fedora repos if needed.

---

## Phase I — Development Environment

### I.1 System Packages

```bash
sudo dnf groupinstall -y "Development Tools" "C Development Tools and Libraries"

sudo dnf install -y \
  gcc gcc-c++ gfortran make cmake ninja-build meson \
  clang llvm lld \
  python3-devel python3.12 python3.11 \
  golang rust cargo \
  openssl-devel libffi-devel zlib-devel bzip2-devel \
  readline-devel sqlite-devel xz-devel tk-devel \
  blas-devel lapack-devel openblas-devel hdf5-devel \
  git git-lfs git-delta \
  podman podman-compose buildah skopeo \
  htop btop iotop-c powertop \
  tmux neovim \
  jq yq \
  ripgrep fd-find bat eza fzf \
  ShellCheck strace perf stress-ng \
  lm_sensors nvme-cli smartmontools \
  btrfs-progs compsize \
  wget2 curl rsync bc \
  wl-clipboard \
  audit policycoreutils-python-utils \
  borgbackup
```

### I.2 Flatpak and VS Code

```bash
# Ensure full Flathub (Fedora ships a filtered subset)
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

flatpak install -y flathub com.visualstudio.code

# Grant VS Code filesystem access (Flatpak sandbox restricts it)
flatpak override --user com.visualstudio.code \
  --filesystem=home \
  --filesystem=/tmp \
  --filesystem=xdg-run/podman:ro \
  --env=ELECTRON_OZONE_PLATFORM_HINT=auto
```

### I.3 Git Configuration

```bash
git config --global user.name "Asif"
git config --global user.email "your-email@example.com"

# Delta for syntax-highlighted diffs
git config --global core.pager "delta"
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate true
git config --global delta.dark true
git config --global delta.line-numbers true
git config --global delta.side-by-side true

# Performance for large repos
git config --global core.fsmonitor true
git config --global core.untrackedCache true
git config --global feature.manyFiles true

# Workflow
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global merge.conflictstyle zdiff3

# SSH commit signing (key generated in I.7 — config is safe to set now)
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

### I.4 Python Environment

`require-virtualenv = true` is a safety net — `pip install` will refuse to install packages globally, forcing you to create a virtualenv first. This prevents polluting the system Python (which Fedora tools depend on) and avoids the "externally managed" error that Python 3.12+ throws when you try to install into the system site-packages.

```bash
mkdir -p ~/.config/pip
cat > ~/.config/pip/pip.conf << 'EOF'
[global]
require-virtualenv = true
EOF
```

**Usage:** for every project, create a virtualenv: `python3 -m venv .venv && source .venv/bin/activate`. Inside the venv, `pip install` works normally. To install a global tool as an exception: `pip install --break-system-packages <tool>` (use sparingly).

### I.5 Podman Rootless

Rootless Podman requires subordinate UID/GID ranges so containers can map users without root privileges. Fedora usually configures these during user creation, but subvolume-based setups can miss it.

```bash
# Ensure subordinate UID/GID ranges exist (required for rootless containers)
grep -q "^asif:" /etc/subuid || sudo usermod --add-subuids 100000-165535 asif
grep -q "^asif:" /etc/subgid || sudo usermod --add-subgids 100000-165535 asif

mkdir -p ~/.config/containers
cat > ~/.config/containers/registries.conf << 'EOF'
unqualified-search-registries = ["docker.io", "quay.io", "ghcr.io"]
EOF

podman system migrate   # Apply subuid/subgid changes without reboot
podman run --rm docker.io/hello-world
```

### I.6 Shell Configuration

```bash
cat >> ~/.bashrc << 'BASHRC'

# --- History ---
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT="%F %T "
shopt -s histappend

# --- fzf ---
eval "$(fzf --bash)"

# --- Compute thread binding ---
export OPENBLAS_NUM_THREADS=8
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
export NUMEXPR_MAX_THREADS=8

# --- Go ---
export GOPATH=$HOME/go
export GOBIN=$HOME/go/bin
export PATH=$PATH:$GOBIN

# --- Wayland ---
export ELECTRON_OZONE_PLATFORM_HINT=auto
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1

# --- Aliases ---
alias upgrade='sudo /usr/local/bin/safe-upgrade'
alias health='sudo /usr/local/bin/system-health'
alias snap='sudo /usr/local/bin/btrfs-snapshot'
alias top='btop'
alias ls='eza --group-directories-first'
alias ll='eza -la --group-directories-first --git'
alias cat='bat --plain'
alias grep='rg'
alias find='fd'

PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
BASHRC

source ~/.bashrc
```

### I.7 SSH for Remote GPU

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

Host gpu
    HostName <gpu-server-ip>
    User <username>
    ForwardAgent yes
    # LocalForward 8888 localhost:8888
    # LocalForward 6006 localhost:6006
EOF

chmod 600 ~/.ssh/config

if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -C "asif@zenbook" -f ~/.ssh/id_ed25519 -N ""
    echo "Public key (add to GitHub / remote servers):"
    cat ~/.ssh/id_ed25519.pub
fi
```

### I.8 Ollama (Local LLM)

Ollama runs local language models on the Radeon 680M iGPU. The resource limits keep it to one model at a time — with 16 GB shared RAM, loading multiple models causes swap thrashing.

```bash
curl -fsSL https://ollama.com/install.sh | sh

# Configure BEFORE starting — avoids a wasted startup with defaults
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/resources.conf << 'EOF'
[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama

# Verify
systemctl is-active ollama && echo "✓ Ollama running" || echo "✗ Ollama failed to start"
curl -s http://localhost:11434 | head -1
```

---

## Phase J — Snapshot Automation and Tools

### J.1 Snapshot Manager

**Why coordinated snapshots matter.** Subvolumes are independent, but dependencies are not. A project in `@projects` depends on packages in `@` (root) and configs in `@home`. Rolling back one subvolume without rolling back the others can leave you in a state where restored files don't match the current system. The solution: always snapshot all three together so you can roll them all back as a unit.

**Verification gate.** A snapshot is only useful if it was taken when the system was healthy. Before creating coordinated snapshots, the script runs health checks (no failed services, SELinux enforcing, Btrfs clean, all subvolumes mounted). If the checks pass, the snapshot group is marked **verified** in `/.snapshots/.verified`. If checks fail, the snapshot is still taken (you might want it anyway) but is NOT marked verified. Rollback always recommends the most recent verified group — no guessing.

```bash
sudo tee /usr/local/bin/btrfs-snapshot << 'SCRIPT'
#!/bin/bash
set -euo pipefail

SNAP_ROOT="/.snapshots"
VERIFIED_LOG="$SNAP_ROOT/.verified"
TS=$(date +%Y%m%d-%H%M%S)
MAX=5

snap() {
    local src="$1" dst="$2" label="${3:-manual}"
    btrfs subvolume snapshot -r "$src" "${dst}/${TS}_${label}" >/dev/null
    echo "  ✓ ${dst}/${TS}_${label}"
}

# Health checks — returns 0 if system is healthy, 1 if not
check_health() {
    local errors=0

    # 1. No failed systemd services
    local failed
    failed=$(systemctl --failed --no-pager --no-legend | wc -l)
    [ "$failed" -eq 0 ] || { echo "  ✗ $failed failed service(s)"; errors=$((errors+1)); }

    # 2. SELinux enforcing
    local se
    se=$(getenforce 2>/dev/null || echo "unknown")
    [ "$se" = "Enforcing" ] || { echo "  ✗ SELinux: $se (expected Enforcing)"; errors=$((errors+1)); }

    # 3. Btrfs clean
    local berr
    berr=$(btrfs device stats / 2>/dev/null | grep -v ' 0$' | wc -l)
    [ "$berr" -eq 0 ] || { echo "  ✗ Btrfs: $berr device error(s)"; errors=$((errors+1)); }

    # 4. All 8 Btrfs subvolumes mounted
    local mounts
    mounts=$(findmnt -t btrfs --noheadings | wc -l)
    [ "$mounts" -ge 8 ] || { echo "  ✗ Only $mounts/8 Btrfs subvolumes mounted"; errors=$((errors+1)); }

    return $errors
}

mark_verified() {
    local ts="$1"
    touch "$VERIFIED_LOG"
    echo "$ts" >> "$VERIFIED_LOG"
    echo "  ★ Group $ts marked VERIFIED"
}

last_verified() {
    [ -f "$VERIFIED_LOG" ] && tail -1 "$VERIFIED_LOG" || echo ""
}

is_verified() {
    local ts="$1"
    [ -f "$VERIFIED_LOG" ] && grep -qx "$ts" "$VERIFIED_LOG"
}

do_coordinated_snap() {
    local label="$1"
    local verified=false

    if [ "${2:-yes}" = "yes" ]; then
        echo "Verifying system health..."
        if check_health; then
            echo "  ✓ System healthy"
            verified=true
        else
            echo "  ⚠ Health check failed — snapshot taken but NOT verified"
        fi
    fi

    snap / "$SNAP_ROOT/root" "$label"
    snap /home "$SNAP_ROOT/home" "$label"
    snap /home/asif/projects "$SNAP_ROOT/projects" "$label"

    $verified && mark_verified "$TS"
    echo "Done. Group: $TS"
}

case "${1:-help}" in
    pre-upgrade)
        echo "Creating coordinated pre-upgrade snapshots..."
        do_coordinated_snap "pre-upgrade"
        ;;
    group)
        label="${2:-manual}"
        echo "Creating coordinated snapshot group..."
        do_coordinated_snap "$label"
        ;;
    root|home|projects)
        src="/"; [ "$1" = "home" ] && src="/home"; [ "$1" = "projects" ] && src="/home/asif/projects"
        echo "Warning: single-subvolume snapshot (not verified). Use 'group' for coordinated snapshots."
        snap "$src" "$SNAP_ROOT/$1" "${2:-manual}"
        ;;
    verify)
        echo "Running health checks against live system..."
        if check_health; then
            echo "  ✓ System healthy"
            # Find the most recent snapshot group and mark it verified
            latest=$(find "$SNAP_ROOT/root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1 | xargs -r basename)
            if [ -n "$latest" ]; then
                lts=${latest%%_*}
                mark_verified "$lts"
            else
                echo "  No snapshots found to verify."
            fi
        else
            echo "  ✗ Health check failed — fix issues before marking snapshots as verified"
            exit 1
        fi
        ;;
    list)
        echo "=== Snapshot Groups ==="
        echo "(★ = verified healthy at time of snapshot)"
        echo ""
        for d in root home projects; do
            [ -d "$SNAP_ROOT/$d" ] || continue
            find "$SNAP_ROOT/$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r s; do
                name=$(basename "$s")
                ts=${name%%_*}
                label=${name#*_}
                echo "$ts|$d|$label"
            done
        done | sort -t'|' -k1 | while IFS='|' read -r ts subvol label; do
            if [ "${PREV_TS:-}" != "$ts" ]; then
                [ -n "${PREV_TS:-}" ] && echo ""
                if is_verified "$ts"; then
                    echo "  ★ [$ts] $label  (VERIFIED)"
                else
                    echo "  ○ [$ts] $label"
                fi
                PREV_TS="$ts"
            fi
            echo "    ✓ $subvol"
        done
        echo ""
        LV=$(last_verified)
        [ -n "$LV" ] && echo "Last verified group: $LV" || echo "No verified groups yet. Run: btrfs-snapshot verify"
        ;;
    clean)
        keep=${2:-$MAX}
        for d in root home projects; do
            dir="$SNAP_ROOT/$d"; [ -d "$dir" ] || continue
            count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d | wc -l)
            if [ "$count" -gt "$keep" ]; then
                find "$dir" -maxdepth 1 -mindepth 1 -type d | sort | head -n $((count - keep)) | \
                    while read -r s; do
                        btrfs subvolume delete "$s" >/dev/null
                        echo "  Deleted: $(basename "$s")"
                    done
            fi
        done
        # Clean orphaned verified entries
        if [ -f "$VERIFIED_LOG" ]; then
            tmp=$(mktemp)
            while read -r vts; do
                find "$SNAP_ROOT/root" -maxdepth 1 -name "${vts}_*" -type d 2>/dev/null | grep -q . && echo "$vts"
            done < "$VERIFIED_LOG" > "$tmp"
            mv "$tmp" "$VERIFIED_LOG"
        fi
        ;;
    rollback)
        echo ""
        echo "=== COORDINATED ROLLBACK ==="
        LV=$(last_verified)
        if [ -n "$LV" ]; then
            # Find the full snapshot name for the verified timestamp
            LV_NAME=$(find "$SNAP_ROOT/root" -maxdepth 1 -name "${LV}_*" -type d 2>/dev/null | sort | tail -1 | xargs -r basename)
            echo ""
            echo "Last verified group: $LV_NAME"
            echo "  (System was healthy when this snapshot was taken)"
        else
            echo ""
            echo "⚠ No verified groups found. You will need to choose manually."
        fi
        echo ""
        echo "Boot Fedora Live USB, then:"
        echo ""
        echo "  sudo mount -o subvolid=5 /dev/nvme0n1p4 /mnt"
        echo "  ls /mnt/@snapshots/root/      # find your target group"
        echo "  cat /mnt/@snapshots/.verified  # verified timestamps"
        echo ""
        TGT="${LV_NAME:-<GROUP>}"
        echo "Restore using: $TGT"
        echo ""
        echo "  # Shelve current subvolumes"
        echo "  sudo mv /mnt/@ /mnt/@.broken"
        echo "  sudo mv /mnt/@home /mnt/@home.broken"
        echo "  sudo mv /mnt/@projects /mnt/@projects.broken"
        echo ""
        echo "  # Restore coordinated group (writable snapshots from read-only originals)"
        echo "  sudo btrfs subvolume snapshot /mnt/@snapshots/root/$TGT /mnt/@"
        echo "  sudo btrfs subvolume snapshot /mnt/@snapshots/home/$TGT /mnt/@home"
        echo "  sudo btrfs subvolume snapshot /mnt/@snapshots/projects/$TGT /mnt/@projects"
        echo ""
        echo "  # Reboot and verify, then clean up:"
        echo "  sudo btrfs subvolume delete /mnt/@.broken"
        echo "  sudo btrfs subvolume delete /mnt/@home.broken"
        echo "  sudo btrfs subvolume delete /mnt/@projects.broken"
        ;;
    *) echo "Usage: btrfs-snapshot {pre-upgrade|group [label]|verify|root|home|projects|list|clean [N]|rollback} [label]" ;;
esac
SCRIPT

sudo chmod +x /usr/local/bin/btrfs-snapshot
```

### J.2 Safe Upgrade

The upgrade flow is: verify current state → snapshot (marked verified) → upgrade → verify again. If the post-upgrade verify fails, you know exactly which verified group to roll back to.

```bash
sudo tee /usr/local/bin/safe-upgrade << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Fedora Safe Upgrade ==="

echo "[1/5] Pre-upgrade snapshots (with health verification)..."
/usr/local/bin/btrfs-snapshot pre-upgrade

echo "[2/5] Upgrading packages..."
dnf upgrade -y --refresh "$@"

echo "[3/5] Checking firmware..."
fwupdmgr refresh 2>/dev/null || true
fwupdmgr update 2>/dev/null || echo "  No firmware updates (or requires reboot)."

echo "[4/5] Post-upgrade health check..."
echo "  Kernel: $(uname -r)"
FAILED=$(systemctl --failed --no-pager --no-legend | wc -l)
BERR=$(btrfs device stats / 2>/dev/null | grep -v ' 0$' | wc -l)
SE=$(getenforce 2>/dev/null || echo "unknown")
echo "  Failed services: $FAILED"
echo "  Btrfs errors:    $BERR"
echo "  SELinux:         $SE"

echo "[5/5] Verdict..."
if [ "$FAILED" -eq 0 ] && [ "$BERR" -eq 0 ] && [ "$SE" = "Enforcing" ]; then
    echo "  ✓ System healthy after upgrade. Reboot when ready."
else
    echo "  ⚠ Issues detected after upgrade."
    echo "  If problems persist after reboot, roll back:"
    echo "    sudo btrfs-snapshot rollback"
fi
SCRIPT

sudo chmod +x /usr/local/bin/safe-upgrade
```

### J.3 System Health Dashboard

```bash
sudo tee /usr/local/bin/system-health << 'SCRIPT'
#!/bin/bash
set -euo pipefail

G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e "  ${G}✓${N} $1"; }
warn() { echo -e "  ${Y}⚠${N} $1"; }
err()  { echo -e "  ${R}✗${N} $1"; }
info() { echo -e "  ${C}→${N} $1"; }

echo ""
echo "════════════════════════════════════════════"
echo "  System Health · $(date '+%Y-%m-%d %H:%M')"
echo "════════════════════════════════════════════"

echo ""; echo "Kernel & Boot"
info "Kernel: $(uname -r) · Uptime: $(uptime -p)"
FAILED=$(systemctl --failed --no-pager --no-legend | wc -l)
[ "$FAILED" -eq 0 ] && ok "No failed services" || err "$FAILED failed service(s)"

SE=$(getenforce 2>/dev/null || echo "unknown")
[ "$SE" = "Enforcing" ] && ok "SELinux: Enforcing" || warn "SELinux: $SE"

echo ""; echo "CPU & Thermal"
info "Driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null) · EPP: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null) · Profile: $(powerprofilesctl get 2>/dev/null)"
if command -v sensors &>/dev/null; then
    T=$(sensors 2>/dev/null | grep -iE "tctl|tdie" | head -1 | sed -n 's/.*+\([0-9]*\)\..*/\1/p')
    [ -n "$T" ] && { [ "$T" -lt 75 ] && ok "CPU: ${T}°C" || warn "CPU: ${T}°C"; }
fi

echo ""; echo "Memory"
info "$(free -h | awk '/Mem:/{printf "RAM: %s/%s (%s available)", $3, $2, $7}')"

echo ""; echo "Storage"
info "Root: $(df -h / | awk 'NR==2{print $5, "used,", $4, "free"}')"
if command -v nvme &>/dev/null; then
    WEAR=$(nvme smart-log /dev/nvme0n1 2>/dev/null | awk '/percentage_used/{print $3}' | tr -d '%')
    [ -n "$WEAR" ] && { [ "$WEAR" -lt 5 ] && ok "SSD wear: ${WEAR}%" || warn "SSD wear: ${WEAR}%"; }
fi
BERR=$(btrfs device stats / 2>/dev/null | grep -v ' 0$' | wc -l)
[ "$BERR" -eq 0 ] && ok "Btrfs: clean" || err "Btrfs: $BERR error(s)"

BAT=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
BSTAT=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)
[ -n "$BAT" ] && { echo ""; echo "Battery"; info "${BAT}% ($BSTAT)"; }

echo ""; echo "Snapshots"
for d in root home projects; do
    [ -d "/.snapshots/$d" ] || continue
    C=$(find "/.snapshots/$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    L=$(find "/.snapshots/$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1 | xargs -r basename 2>/dev/null)
    info "$d: $C snapshot(s)${L:+, latest: $L}"
done
echo ""; echo "════════════════════════════════════════════"; echo ""
SCRIPT

sudo chmod +x /usr/local/bin/system-health
```

### J.4 Automated Timers

```bash
# Weekly coordinated snapshot
sudo tee /etc/systemd/system/btrfs-snap-weekly.service << 'EOF'
[Unit]
Description=Weekly coordinated snapshot (root + home + projects)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-snapshot group weekly
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
sudo systemctl enable --now btrfs-scrub@-.timer
```

---

## Phase K — Backup, Baseline, and Maintenance

### K.1 BorgBackup

Btrfs snapshots are not backups — they don't protect against hardware failure, theft, or filesystem corruption.

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
    --exclude '/home/asif/projects/*/.venv' \
    --exclude '/home/asif/projects/*/node_modules' \
    --exclude '*.pyc' --exclude '__pycache__'

borg prune --stats --keep-daily 7 --keep-weekly 4 --keep-monthly 6 "$BORG_REPO"
borg compact "$BORG_REPO"
echo "Backup complete."
SCRIPT

sudo chmod +x /usr/local/bin/backup-borg
```

### K.2 Performance Baseline

```bash
sudo tee /usr/local/bin/perf-baseline << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Performance Baseline · $(date -I) ==="
BENCH_FILE="${HOME:-/home/asif}/bench"

echo "--- Storage (write) ---"
dd if=/dev/zero of="$BENCH_FILE" bs=1M count=1024 oflag=direct 2>&1 | tail -1

echo "--- Storage (read) ---"
dd if="$BENCH_FILE" of=/dev/null bs=1M count=1024 iflag=direct 2>&1 | tail -1
rm -f "$BENCH_FILE"

echo "--- Btrfs compression ---"
compsize / 2>/dev/null | head -3 || echo "  (compsize not available)"

echo "--- Boot time ---"
systemd-analyze
systemd-analyze blame | head -5
SCRIPT

sudo chmod +x /usr/local/bin/perf-baseline
```

### K.3 Post-Deployment Verification

Run this once after completing all phases. Every check should pass.

```bash
echo "=== Deployment Verification ==="

echo ""; echo "Subvolumes:"
findmnt -t btrfs --noheadings -o TARGET | sort | sed 's/^/  ✓ /'
MOUNTS=$(findmnt -t btrfs --noheadings | wc -l)
[ "$MOUNTS" -ge 8 ] && echo "  ($MOUNTS/8 mounted)" || echo "  ✗ Only $MOUNTS/8 — check fstab"

echo ""; echo "Kernel params:"
for p in amd_pstate amd_iommu transparent_hugepage nowatchdog workqueue.power_efficient pcie_aspm resume; do
    grep -q "$p" /proc/cmdline && echo "  ✓ $p" || echo "  ✗ $p MISSING"
done

echo ""; echo "Hardware:"
echo "  CPU driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo 'MISSING')"
echo "  Power profile: $(powerprofilesctl get 2>/dev/null || echo 'MISSING')"
echo "  SELinux: $(getenforce)"
echo "  Session: $XDG_SESSION_TYPE"

echo ""; echo "Timers:"
systemctl list-timers --no-pager | grep -E "fstrim|btrfs|snap" | awk '{printf "  ✓ %s\n", $NF}'

echo ""; echo "Scripts:"
for s in btrfs-snapshot safe-upgrade system-health perf-baseline backup-borg; do
    [ -x "/usr/local/bin/$s" ] && echo "  ✓ $s" || echo "  ✗ $s missing or not executable"
done
```

### K.4 Monthly Maintenance

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

### K.5 Annual Review

```
1. Review kernel parameters (new kernels change defaults)
2. Review disabled services (new Fedora features)
3. mokutil --sb-state                     # Secure Boot
4. Test suspend/resume after kernel updates
5. sudo perf-baseline                     # Compare against initial
6. borg check $BORG_REPO                  # Backup integrity
7. sudo ausearch -m AVC --start this-month  # SELinux denials
```

---

## Appendix — Configuration Reference

### Kernel Command Line

```
amd_pstate=active amd_iommu=on iommu=pt transparent_hugepage=madvise nowatchdog nmi_watchdog=0 workqueue.power_efficient=1 pcie_aspm=default mitigations=auto resume=UUID=<SWAP_UUID>
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
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
```

### Btrfs Mount Options

| Type | Options |
|---|---|
| Standard | `compress=zstd:1,noatime,ssd,discard=async,space_cache=v2,commit=120` |
| Logs | `compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,commit=120` |
| Containers | `nodatacow,noatime,ssd,discard=async,space_cache=v2` |

### Deployed Scripts

| Script | Purpose |
|---|---|
| `btrfs-snapshot` | Verified coordinated snapshot manager (group, verify, rollback) |
| `safe-upgrade` | Verify → snapshot → upgrade → verify → verdict |
| `system-health` | Color-coded system health dashboard |
| `perf-baseline` | Performance benchmark |
| `backup-borg` | BorgBackup to external drive |

### Active Timers

| Timer | Schedule | Purpose |
|---|---|---|
| `fstrim.timer` | Weekly | SSD TRIM |
| `btrfs-scrub@-.timer` | Monthly | Data integrity |
| `btrfs-snap-weekly.timer` | Sunday 3 AM | Coordinated snapshot (root + home + projects) |
| `btrfs-snap-clean.timer` | 1st of month | Snapshot cleanup |

---

*Fedora 43 Workstation · ASUS Zenbook S 13 OLED UM5302TA · Samsung 990 Pro 1TB*
*SELinux enforcing · Definitive Deployment Guide*
