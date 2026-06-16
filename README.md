# PS5 Linux Image Builder

Fork of [ps5-linux/ps5-linux-image](https://github.com/ps5-linux/ps5-linux-image) with more distros and [prebuilt images](https://git.etawen.dev/mia/ps5-linux-image/releases/tag/latest).

Builds bootable Linux USB images for PlayStation 5 using Docker containers. Each image ships the linux-ps5 kernel with the patches from [`mia/ps5-linux-patches`](https://git.etawen.dev/mia/ps5-linux-patches), the mwifiex driver for the IW620 WLAN/BT module, and per-distro PS5 setup (kexec loader entry, growpart on first boot, NetworkManager, etc).

## Prebuilt images

Pre-built `.img.xz` files for every distro below are published on the [`latest`](https://git.etawen.dev/mia/ps5-linux-image/releases/tag/latest) release. Just `xz -d` and `dd` — no local build required.

## Distributions

| Distro | Default session | Pkg fmt | Notes |
|---|---|---|---|
| Ubuntu 26.04 (Resolute) | GNOME | `.deb` | systemd, NetworkManager |
| Debian 13 (Trixie) — XFCE | XFCE | `.deb` | lightweight desktop |
| Debian 13 (Trixie) — GNOME | GNOME | `.deb` | full GNOME stack |
| Debian 13 (Trixie) — KDE | KDE Plasma | `.deb` | full KDE stack |
| Debian 13 (Trixie) — Server | tty1 autologin | `.deb` | headless, no DE |
| Debian 13 + Proxmox VE 9 | Proxmox web UI | `.deb` | KVM/LXC, pinned Debian kernel replaced with linux-ps5 |
| Arch | Sway | `.pkg.tar.zst` | rolling |
| CachyOS | Gamescope + Steam Big Picture | `.pkg.tar.zst` | Arch + `[cachyos]` repo |
| Alpine 3.21 | OpenRC tty | extracted `.deb` | musl, minimal |
| Fedora 44 — GNOME | GNOME | `.rpm` | latest Fedora |
| Fedora 44 — KDE Plasma | KDE Plasma | `.rpm` | Mesa 26.1 (PS5 GFX1013 fix) when available |
| **Bazzite** | KDE Plasma | OCI atomic | ublue-os gaming-focused Fedora |
| **Bazzite-Deck** | gamescope-session-plus | OCI atomic | Steam-Deck UI variant of Bazzite |
| **Batocera** | EmulationStation | squashfs | retro emulation distro (RetroArch + dozens of emulators) |

Default credentials on every image: user `ps5` / password `ps5` (sudo enabled, root locked). CachyOS uses `steam` / `steam`. Bazzite-Deck boots straight into the gamescope session.

### Batocera notes

- **Exit-game hotkey**: `Share` + `PS` on the DualSense (the in-game combo for "quit emulator"). Other Batocera combos use the PS button as the hotkey modifier.
- Bundled emulators (Batocera 43): PSP (PPSSPP), PS1 (DuckStation), PS2 (PCSX2), PS3 (RPCS3), PS4 (shadPS4), Switch (Ryujinx — Yuzu was DMCA'd in 2024 and removed from every distro), plus the standard retroarch lineup (NES/SNES/Genesis/N64/GameCube/Wii/etc).
- A system only appears in EmulationStation when it has at least one ROM under `/userdata/roms/<system>/`. Drop one file per system or set `display.empty=1` in `/userdata/system/batocera.conf` to force them all visible.

## Prerequisites

- Docker (with permission to run `--privileged` containers) — install as per your distro's instructions
- ~30 GB free disk space (more for `--distro all` or Bazzite/Bazzite-Deck/Batocera: ~50 GB)

Once Docker is installed, add your user to the docker group and apply it without logging out:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Quick Start

```bash
# Build a single distro
./build_image.sh --distro ubuntu2604           # default
./build_image.sh --distro debian13-kde
./build_image.sh --distro debian13-proxmox
./build_image.sh --distro fedora-kde
./build_image.sh --distro bazzite
./build_image.sh --distro bazzite-deck
./build_image.sh --distro batocera
./build_image.sh --distro cachyos              # gamescope + Steam Big Picture

# Multi-distro image (legacy: ubuntu2604 + debian13 + arch + alpine + cachyos)
./build_image.sh --distro all
```

The script auto-clones the kernel source, applies PS5 patches, compiles, and builds the image. Subsequent runs reuse cached artifacts automatically. Press Ctrl+C at any time to abort cleanly.

## Flash to USB

```bash
xz -dk output/ps5-debian13-kde.img.xz                                # if you grabbed from releases
sudo dd if=output/ps5-debian13-kde.img of=/dev/sdX bs=4M status=progress
```

After flashing, on first boot the rootfs auto-expands to fill the USB drive (see the `grow-rootfs` service in each distro's directory).

## Options

| Flag | Description | Default |
|---|---|---|
| `--distro` | Any value from the [distros table](#distributions), or `all` | `ubuntu2604` |
| `--kernel` | Path to kernel source directory | auto-clone |
| `--img-size` | Disk image size in MB | `12000`; bumped automatically for Bazzite (24 GB), Bazzite-Deck (24 GB), Batocera (16 GB), `all` (32 GB) |
| `--clean` | Remove all cached build artifacts and start fresh | off |
| `--kernel-only` | Build and package the kernel only, then exit | off |
| `--patches-ref` | Branch, tag, or commit SHA for `ps5-linux-patches` | pinned in `build_image.sh` |

## Caching

The build automatically skips stages that have already completed:

- **Kernel source** — reused if `work/linux/` exists
- **Kernel packages** — reused if `linux-ps5*.deb` / `.rpm` / `.pkg.tar.zst` files exist in `linux-bin/`
- **Root filesystem** — reused if chroot directories are populated
- **Batocera upstream image** — `.img.gz` cached at `work/cache/` (Batocera's mirror rate-limits per-IP to ~250 KB/s, so re-downloading every run is painful)

Use `--clean` to wipe everything and rebuild from scratch. The build will also suggest `--clean` if a stage fails.

## PS5-specific quirks baked into every image

- `amdgpu` modprobe options: `dpm=0 gpu_recovery=0` (Oberon GPU stays dark with stock DPM)
- DTM TA race workaround: udev rule re-triggers DRM connector detection after `amdgpu` binds, so the screen doesn't stay dark until you manually VT-toggle
- mwifiex IW620 driver auto-loads + firmware blob is staged from the FAT32 EFI partition on first boot
- `linux-ps5` kernel ships in the rootfs at `/lib/modules/<kver>` with depmod already run

## Multi-distro Image

`--distro all` builds a 32 GB image with multiple partitions (one EFI boot partition plus per-distro root filesystems). The boot partition contains kexec scripts to switch between distros at runtime. Ubuntu 26.04 is the default boot target.

(Only the `MULTI_DISTROS` list in `build_image.sh` is packed into the multi image — currently `ubuntu2604 debian13 arch alpine cachyos`. The newer distros — fedora, bazzite, batocera — are single-distro only.)

## Building the Kernel Standalone

Use `--kernel-only` to compile the PS5 kernel and produce installable packages without building a full disk image.

```bash
./build_image.sh --kernel-only                                # .deb
./build_image.sh --kernel-only --distro all                   # .deb + .rpm + .pkg.tar.zst
./build_image.sh --kernel-only --patches-ref main             # fetch from specific branch/tag
./build_image.sh --kernel-only --clean                        # wipe and rebuild from scratch
```

Output packages are written to `linux-bin/`. Install on a running PS5 Linux system:

```bash
sudo dpkg  -i linux-bin/linux-ps5_*.deb            # debian / ubuntu
sudo rpm   -Uvh --replacefiles linux-bin/linux-ps5-*.rpm   # fedora / bazzite
sudo pacman -U linux-bin/linux-ps5-*.pkg.tar.zst    # arch / cachyos
```

## Directory Layout

```
build_image.sh                  # Image builder (also supports --kernel-only)
docker/
  kernel-builder/               # Kernel compilation container
  kernel-builder-arch/          # Repackages .deb kernel as .pkg.tar.zst
  kernel-builder-rpm/           # Repackages .deb kernel as .rpm
  image-builder/
    Dockerfile                  # Image building container (distrobuilder + skopeo + umoci)
    entrypoint.sh               # Single-distro build logic
    entrypoint-multi.sh         # Multi-distro build logic
distros/
  ubuntu2604/                   # Ubuntu 26.04
  debian13-{xfce,server,gnome,kde,proxmox}/
  arch/                         # Arch Linux
  cachyos/                      # CachyOS + Gamescope/Steam
  alpine/                       # Alpine 3.21
  fedora-{gnome,kde}/           # Fedora 44
  bazzite/                      # OCI extract path (covers bazzite + bazzite-deck)
  shared/                       # Kernel postinst hooks
boot/
  cmdline.txt                   # Kernel cmdline template (__DISTRO__ placeholder)
  vram.txt                      # VRAM allocation
  kexec.sh                      # Loader stub
  kexec-{ubuntu2604,arch,alpine,cachyos}.sh
work/                           # Build artifacts (auto-created)
linux-bin/                      # Compiled kernel packages
output/                         # Final .img / .img.xz files
.forgejo/workflows/             # CI for the automated nightly release
```

## Credits

Upstream: [ps5-linux/ps5-linux-image](https://github.com/ps5-linux/ps5-linux-image), [ps5-linux/ps5-linux-patches](https://github.com/ps5-linux/ps5-linux-patches), [ps5-linux/ps5-linux-loader](https://github.com/ps5-linux/ps5-linux-loader), [ps5-linux/ps5-linux-mwifiex](https://github.com/ps5-linux/ps5-linux-mwifiex). The Mesa GFX1013 widening that makes the PS5 Oberon (CYAN_SKILLFISH revision) work in userspace was originally written by theflow.
