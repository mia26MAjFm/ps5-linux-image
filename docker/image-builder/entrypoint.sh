#!/bin/bash
set -ex

DISTRO="${DISTRO:-ubuntu2604}"
# Bazzite ships large (~10 GB rootfs after OCI unpack), bump the default img.
case "${DISTRO}" in
    bazzite*)  IMG_SIZE="${IMG_SIZE:-20000}" ;;
    batocera*) IMG_SIZE="${IMG_SIZE:-16000}" ;;
    *)         IMG_SIZE="${IMG_SIZE:-12000}" ;;
esac
SKIP_CHROOT="${SKIP_CHROOT:-false}"
STAGING="/tmp/build-staging"
ROOT_LABEL="${DISTRO}"
EFI_LABEL="boot"
CHROOT="/build/chroot"
IMG="/output/ps5-${DISTRO}.img"

if [ "$SKIP_CHROOT" = "true" ] && [ -d "$CHROOT/bin" ]; then
    echo "=== Reusing cached $DISTRO rootfs ==="
else
    echo "=== Building $DISTRO rootfs ==="
    # --- Stage files for distrobuilder's copy generators ---
    rm -rf "$STAGING"
    mkdir -p "$STAGING/debs"
    cp /repo/distros/shared/zz-update-boot      "$STAGING/"
    # Generate per-distro fstab with partition labels
    cat <<EOF > "$STAGING/fstab"
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL /boot/efi vfat defaults 0 1
EOF
    cp /repo/distros/${DISTRO}/nm-dns.conf       "$STAGING/" 2>/dev/null || true

    case "$DISTRO" in
        ubuntu*|debian*|mint*)
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            cp /kernel-debs/*.deb                          "$STAGING/debs/"
            ;;
        fedora*)
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            mkdir -p "$STAGING/rpms"
            cp /kernel-debs/*.rpm                          "$STAGING/rpms/"
            ;;
        alpine)
            cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
            cp /repo/distros/alpine/grow-rootfs.openrc     "$STAGING/"
            ;;
        devuan*)
            # Devuan: same deb/debootstrap pipeline, but the boot-time
            # grow-rootfs is a sysv init script (no systemd here) instead
            # of a .service unit.
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.sysv  "$STAGING/"
            # Pre-provisioned wifi (test builds only — strip before push)
            [ -f /repo/distros/${DISTRO}/wifi.nmconnection ] && \
                cp /repo/distros/${DISTRO}/wifi.nmconnection "$STAGING/"
            cp /kernel-debs/*.deb                          "$STAGING/debs/"
            # Ubuntu's debootstrap (the one bundled in this builder image)
            # doesn't ship a script for any Devuan codename, so it bails on
            # `excalibur` / `daedalus` etc. with "No such script". Excalibur
            # is built on top of Debian 13 Trixie's archive layout, so
            # symlinking the suite onto debootstrap's trixie script gives
            # us a functional bootstrap path without touching the Dockerfile.
            DEVUAN_RELEASE=$(awk '/^[[:space:]]*release:/ {print $2; exit}' \
                /repo/distros/${DISTRO}/image.yaml)
            if [ -n "$DEVUAN_RELEASE" ] && [ ! -e "/usr/share/debootstrap/scripts/$DEVUAN_RELEASE" ]; then
                ln -sf trixie "/usr/share/debootstrap/scripts/$DEVUAN_RELEASE"
            fi
            ;;
        artix*)
            # Artix bootstraps from its live ISO (no upstream tarball);
            # the only staged files are the init-specific grow-rootfs
            # pair and the linux-ps5 .pkg.tar.zst kernel. Pick the right
            # variant by DISTRO name — openrc by default, runit when the
            # distro is explicitly artix-runit or a -runit derivative
            # like artix-hyprland-lightcrimson.
            case "$DISTRO" in
                artix-runit|artix-hyprland-lightcrimson)
                    cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
                    cp /repo/distros/${DISTRO}/grow-rootfs.runit "$STAGING/"
                    ;;
                *)
                    cp /repo/distros/artix-openrc/grow-rootfs        "$STAGING/"
                    cp /repo/distros/artix-openrc/grow-rootfs.openrc "$STAGING/"
                    ;;
            esac
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                    "$STAGING/pkgs/"
            ;;
        arch)
            cp /repo/distros/arch/grow-rootfs              "$STAGING/"
            cp /repo/distros/arch/grow-rootfs.service      "$STAGING/"
            cp /repo/distros/arch/first-boot-setup         "$STAGING/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                  "$STAGING/pkgs/"
            ;;
        miaos*)
            # MiaOS recipe is self-contained in distros/miaos/image.yaml
            # (gamescope + Steam + KDE post-install via distrobuilder actions).
            # Only the patched kernel needs staging here.
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                  "$STAGING/pkgs/"
            ;;
        cachyos)
            mkdir -p "$STAGING/files"
            cp /repo/distros/cachyos/files/grow-rootfs                "$STAGING/files/"
            cp /repo/distros/cachyos/files/grow-rootfs.service        "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot-setup           "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot.service         "$STAGING/files/"
            cp /repo/distros/cachyos/files/gamescope-session-ps5      "$STAGING/files/"
            cp /repo/distros/cachyos/files/steamos-session-select     "$STAGING/files/"
            cp /repo/distros/cachyos/files/return-to-gaming-mode.desktop "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-display.lua            "$STAGING/files/"
            cp /repo/distros/cachyos/files/plasma-workspace-env-ps5.sh "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-tty-session.sh         "$STAGING/files/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                             "$STAGING/pkgs/"
            ;;
    esac

    # --- Build rootfs ---
    rm -rf "$CHROOT"/* "$CHROOT"/.[!.]* 2>/dev/null || true

    case "$DISTRO" in
        batocera*)
            # Batocera is a Buildroot-based emulation distro. It ships as a
            # single .img.gz with FAT32 boot + ext4 SHARE partitions; the OS
            # itself lives in a squashfs file (`/boot/batocera`) on the FAT32.
            # We unsquash, swap our PS5 kernel + modules in, and let the rest
            # of the standard image-builder flow pack everything onto ext4.
            BATOCERA_VER="${BATOCERA_VER:-43}"
            BATOCERA_BUILD="${BATOCERA_BUILD:-20260430}"
            BATOCERA_URL="${BATOCERA_URL:-https://mirrors.o2switch.fr/batocera/x86_64/stable/last/batocera-x86_64-${BATOCERA_VER}-${BATOCERA_BUILD}.img.gz}"

            echo "=== Batocera: locate / download $BATOCERA_VER ($BATOCERA_BUILD) ==="
            # /build/cache is per-run temp. The workflow symlinks /build/cache/
            # persistent -> /data/cache/ps5/downloads, so the .img.gz can be
            # pre-staged or survive between runs. The mirror rate-limits per-IP
            # to ~250KB/s sustained (4MB/s burst), so re-downloading every run
            # is unacceptably slow.
            # The workflow hard-links /data/cache/ps5/downloads/* into
            # image/work/cache before the build container starts, so the
            # image appears as /build/cache/batocera-*.img.gz inside.
            CACHED="/build/cache/batocera-${BATOCERA_VER}-${BATOCERA_BUILD}.img.gz"
            if [ ! -s "$CACHED" ]; then
                echo ">> No cached image, downloading (this will be slow due to mirror rate-limiting)"
                wget --tries=3 -O "$CACHED.part" "$BATOCERA_URL"
                mv "$CACHED.part" "$CACHED"
            fi
            echo ">> Using $CACHED ($(du -h "$CACHED" | cut -f1))"

            echo "=== Batocera: decompress + loop ==="
            BAT_IMG=/build/batocera-src.img
            gunzip -c "$CACHED" > "$BAT_IMG"
            BATLOOP=$(losetup -Pf --show "$BAT_IMG")
            sleep 1
            # kpartx fallback in case partition kernel events didn't fire
            [ -e "${BATLOOP}p1" ] || kpartx -av "$BATLOOP"
            BAT_MNT=$(mktemp -d)
            BAT_PART1=""
            for p in "${BATLOOP}p1" "/dev/mapper/$(basename "$BATLOOP")p1"; do
                [ -e "$p" ] && BAT_PART1="$p" && break
            done
            mount -o ro "$BAT_PART1" "$BAT_MNT"

            BAT_SQUASH=""
            for c in /boot/batocera /batocera /boot/batocera.update; do
                [ -f "$BAT_MNT$c" ] && BAT_SQUASH="$BAT_MNT$c" && break
            done
            if [ -z "$BAT_SQUASH" ]; then
                echo "ERROR: squashfs not found in batocera image:"
                find "$BAT_MNT" -maxdepth 3 -type f | head -30
                exit 1
            fi
            echo "=== Batocera: unsquashfs $BAT_SQUASH -> $CHROOT ==="
            unsquashfs -f -d "$CHROOT" "$BAT_SQUASH"

            # Batocera ships a SECOND squashfs (boot/rufomaculata) with the
            # libretro cores, mame binary, and other emulator assets. At
            # runtime it's mounted as a second overlayfs layer on top of the
            # main batocera squashfs. We don't do overlay — just unsquash
            # rufomaculata on top of $CHROOT so the unified view is realised
            # on the ext4 root. Without this, /usr/lib/libretro/ doesn't
            # exist and EmulationStation reports "no games start" because
            # retroarch fails to load any core.
            if [ -f "$BAT_MNT/boot/rufomaculata" ]; then
                echo "=== Batocera: unsquashfs boot/rufomaculata (libretro + mame) -> $CHROOT ==="
                unsquashfs -f -d "$CHROOT" "$BAT_MNT/boot/rufomaculata"
            else
                echo "WARN: boot/rufomaculata not found — emulator cores will be missing"
            fi

            umount "$BAT_MNT"
            rmdir "$BAT_MNT"
            kpartx -dv "$BATLOOP" 2>/dev/null || true
            losetup -d "$BATLOOP"
            rm -f "$BAT_IMG"

            echo "=== Batocera: install linux-ps5 kernel + modules ==="
            KSTAGE=/tmp/bat-kernel-staging
            rm -rf "$KSTAGE"; mkdir -p "$KSTAGE"
            # The kernel-builder ships a single combined linux-ps5_*.deb
            # (Provides: linux-image-X) — there is no linux-image-*.deb on
            # disk, so target the actual filename pattern.
            shopt -s nullglob
            for deb in /kernel-debs/linux-ps5*.deb /kernel-debs/linux-image-*.deb; do
                [ -f "$deb" ] && dpkg-deb -x "$deb" "$KSTAGE"
            done
            shopt -u nullglob
            KVER=$(ls -1 "$KSTAGE/lib/modules" 2>/dev/null | head -1)
            if [ -z "$KVER" ]; then
                echo "ERROR: no kernel modules found after dpkg-deb -x of /kernel-debs/*.deb"
                ls -la /kernel-debs/
                exit 1
            fi
            rm -rf "$CHROOT"/lib/modules/*
            cp -a "$KSTAGE/lib/modules/$KVER" "$CHROOT/lib/modules/"
            mkdir -p "$CHROOT/boot/efi"
            cp "$KSTAGE/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage"
            # depmod -b runs from outside the chroot — Batocera's busybox
            # depmod may not be present, and host depmod handles -b cleanly.
            depmod -a -b "$CHROOT" "$KVER" || true
            # Stage WLAN firmware loader + module autoload (same files the
            # debian/fedora paths get from /kernel-debs/staging via .deb).
            for src in usr/local/sbin etc/modules-load.d etc/systemd/system; do
                [ -d "$KSTAGE/$src" ] || continue
                mkdir -p "$CHROOT/$src"
                cp -an "$KSTAGE/$src/." "$CHROOT/$src/" || true
            done

            echo "=== Batocera: PS5 modprobe quirks ==="
            mkdir -p "$CHROOT/etc/modprobe.d" "$CHROOT/etc/modules-load.d"
            cat > "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" <<MODPROBE
options amdgpu dpm=0 gpu_recovery=0
MODPROBE
            # uinput is needed by Batocera's hotkeygen (for virtual keyboard
            # events when launching games). It's not autoloaded by default on
            # PS5, so hotkeygen crashes with 'UInputError: /dev/uinput does
            # not exist'. Force-load on boot.
            cat > "$CHROOT/etc/modules-load.d/uinput.conf" <<MODPROBE
uinput
MODPROBE

            echo "=== Batocera: build initrd via host mkinitramfs ==="
            # Host (image-builder, ubuntu:24.04) has initramfs-tools. Trick
            # it into building for our PS5 kernel by symlinking the chroot's
            # modules into /lib/modules/$KVER, then unlinking after.
            #
            # initramfs-tools default behaviour: autodetect kernel modules
            # from /sys on the BUILD HOST — which is a docker container with
            # no USB, no amdgpu, no real disks. The resulting initrd would
            # ship without xhci_pci / usb_storage / ext4 / amdgpu drivers,
            # and the PS5 hangs silently when the kernel tries to find the
            # USB root partition. Override with an explicit modules list +
            # MODULES=most so initramfs-tools includes everything the PS5
            # actually needs at boot.
            mkdir -p /lib/modules
            ln -sfn "$CHROOT/lib/modules/$KVER" "/lib/modules/$KVER"

            cat > /etc/initramfs-tools/modules <<'INITMODS'
# USB host controllers (PS5 boot drive is on USB 3 — xhci is the must-have).
xhci_pci
xhci_hcd
ehci_pci
ehci_hcd
ohci_pci
ohci_hcd
# USB storage class + UAS (faster path).
usb_storage
uas
sd_mod
# Filesystems for root + EFI.
ext4
vfat
nls_iso8859-1
nls_cp437
# Common HID so a USB keyboard works at the initramfs shell if we drop there.
usbhid
hid_generic
INITMODS
            # Force MODULES=most (curated full driver set, no autodetect).
            sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

            mkinitramfs -k "$KVER" -o "$CHROOT/boot/efi/initrd.img"
            rm -f "/lib/modules/$KVER"
            rm -rf "$KSTAGE"

            echo "=== Batocera: patch configgen to bind HOTKEY combos on gamepad ==="
            # Upstream Batocera's libretroControllers.py only sets
            # input_enable_hotkey_btn — the hotkey "enable" button — and never
            # binds input_exit_emulator_btn / input_menu_toggle_btn /
            # input_save_state_btn / input_load_state_btn. The keyboard-side
            # bindings (escape = exit, f1 = menu) work fine but on a DualSense
            # there's no way out of a game without sshing in and pkill'ing
            # retroarch. Patch the function to also bind start/select/L1/R1.
            PYFILE="$CHROOT/usr/lib/python3.12/site-packages/configgen/generators/libretro/libretroControllers.py"
            if [ -f "$PYFILE" ]; then
                python3 - "$PYFILE" <<'PYPATCH'
import sys
p = sys.argv[1]
src = open(p).read()
old = "        retroconfig.save('input_enable_hotkey_btn', controllers[0].inputs['hotkey'].id)"
extra = '''
        # PS5: map HOTKEY combos to gamepad — upstream sets only the
        # enable button, leaving exit-emulator unbound on gamepad. Without
        # this, gamepad users can't exit a retroarch game without sshing
        # in and pkill'ing retroarch.
        for batocera_key, retroarch_key in [
            ('start', 'input_exit_emulator_btn'),
            ('select', 'input_menu_toggle_btn'),
            ('pageup', 'input_load_state_btn'),
            ('pagedown', 'input_save_state_btn'),
        ]:
            if batocera_key in controllers[0].inputs:
                retroconfig.save(retroarch_key, controllers[0].inputs[batocera_key].id)'''
if old in src and extra not in src:
    open(p, 'w').write(src.replace(old, old + extra))
    print('  patched libretroControllers.py')
else:
    print('  skipped (line not found or already patched)')
PYPATCH
            else
                echo "  WARN: $PYFILE missing — configgen patch skipped"
            fi

            echo "=== Batocera: fstab + users ==="
            # NOTE the FAT32 boot partition is mounted at /boot (not
            # /boot/efi like the other distros) because batocera-part —
            # which S11share uses to autodetect the SHARE partition by
            # 'partition next to /boot' — greps /proc/mounts for /boot.
            # If we mount at /boot/efi the SHARE auto-detection silently
            # fails and S11share falls back to a 256 MB tmpfs at
            # /userdata, which won't fit Steam / save data / anything.
            # PS5 loader reads bzImage / cmdline.txt from the FAT32
            # partition's root regardless of where Linux mounts it.
            mkdir -p "$CHROOT/boot"
            cat > "$CHROOT/etc/fstab" <<FSTAB
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL  /boot vfat defaults 0 1
LABEL=SHARE       /userdata ext4 defaults 0 2
FSTAB

            echo "=== Batocera: first-boot SHARE partition creator ==="
            # Batocera's design splits the disk into:
            #   sda1 = rootfs (this image, ~15 GB)
            #   sda2 = /boot FAT32
            #   sda3 = /userdata SHARE (everything user-facing — games,
            #           BIOS, Steam flatpak, screenshots, saves)
            # The image only ships sda1+sda2. On first boot, expand the
            # GPT backup header to the actual disk end (so parted/sgdisk
            # see the full free space) then carve sda3 = SHARE out of
            # the remainder. Self-disables after running.
            cat > "$CHROOT/usr/local/sbin/ps5-share-init" <<'PS5SHARE'
#!/bin/sh
# First-boot: create the SHARE partition + fs if missing, so /userdata
# is a real disk-backed mount (916 GB on a 1 TB drive) instead of the
# 256 MB tmpfs fallback in /etc/init.d/S11share.
set -e
ROOT_DEV=$(findmnt -no SOURCE /)
DISK=$(/usr/bin/batocera-part prefix "$ROOT_DEV")
SHARE_NUM=$(/usr/bin/batocera-part share_internal_num)
SHARE_DEV="${DISK}${SHARE_NUM}"
[ -b "$DISK" ] || exit 0
# already created on a previous boot?
if [ -b "$SHARE_DEV" ] && blkid -L SHARE >/dev/null 2>&1; then
    exit 0
fi
echo "ps5-share-init: extending GPT + creating $SHARE_DEV"
sgdisk -e "$DISK"
partprobe "$DISK"
sleep 1
sgdisk -n "$SHARE_NUM":0:0 -c "$SHARE_NUM":share -t "$SHARE_NUM":8300 "$DISK"
partprobe "$DISK"
sleep 1
mkfs.ext4 -L SHARE -F "$SHARE_DEV"
PS5SHARE
            chmod +x "$CHROOT/usr/local/sbin/ps5-share-init"
            # Hook into Batocera's init order: run BEFORE S11share so
            # S11share's batocera-part share_internal call finds the
            # partition we just created.
            cat > "$CHROOT/etc/init.d/S07ps5share" <<'INITSHARE'
#!/bin/sh
# First-boot SHARE partition creator — see /usr/local/sbin/ps5-share-init
case "$1" in
    start|"") /usr/local/sbin/ps5-share-init >> /tmp/ps5-share-init.log 2>&1 ;;
    stop|restart|reload|*) ;;
esac
INITSHARE
            chmod +x "$CHROOT/etc/init.d/S07ps5share"

            # First-boot defaults for /userdata/system/batocera.conf — set
            # display.empty=1 so every system (PSP, PS1, PS2, PS3, PS4,
            # Switch, etc) is visible in EmulationStation even before
            # ROMs are loaded. S12 runs after S11share has populated
            # /userdata. Idempotent: only sets a key if not already
            # present, so the user remains free to flip it back.
            cat > "$CHROOT/etc/init.d/S12ps5defaults" <<'INITDEF'
#!/bin/sh
case "$1" in
    start|"")
        CONF=/userdata/system/batocera.conf
        [ -f "$CONF" ] || exit 0
        grep -qE '^display\.empty=' "$CONF" || echo 'display.empty=1' >> "$CONF"
        ;;
esac
INITDEF
            chmod +x "$CHROOT/etc/init.d/S12ps5defaults"

            # Batocera ships root passwordless. Leave root usable (a lot of
            # Batocera scripts assume root) but ALSO add a ps5 user so the
            # release-page convention works.
            if ! grep -q "^ps5:" "$CHROOT/etc/passwd"; then
                echo "ps5:x:1000:1000:PS5:/home/ps5:/bin/sh" >> "$CHROOT/etc/passwd"
                echo "ps5:!::0:99999:7:::"                   >> "$CHROOT/etc/shadow"
                echo "ps5:x:1000:"                           >> "$CHROOT/etc/group"
                mkdir -p "$CHROOT/home/ps5"
                chroot "$CHROOT" /bin/sh -c "chown -R 1000:1000 /home/ps5" 2>/dev/null || true
            fi
            # Both root and ps5 get pw 'ps5' — Batocera's chpasswd is busybox.
            chroot "$CHROOT" /bin/sh -c "printf 'ps5\nps5\n' | passwd ps5 2>/dev/null; printf 'ps5\nps5\n' | passwd root 2>/dev/null" || true

            echo "=== Batocera: grow-rootfs first-boot service ==="
            mkdir -p "$CHROOT/usr/local/sbin" "$CHROOT/etc/systemd/system"
            cat > "$CHROOT/usr/local/sbin/grow-rootfs" <<'GROW'
#!/bin/sh
set -e
ROOT=$(findmnt -no SOURCE / || mount | awk '$3=="/"{print $1; exit}')
DISK=$(lsblk -no PKNAME "$ROOT" 2>/dev/null | head -1)
PARTNUM=$(echo "$ROOT" | grep -oE '[0-9]+$' || true)
[ -z "$DISK" ] || [ -z "$PARTNUM" ] && exit 0
growpart "/dev/$DISK" "$PARTNUM" || true
resize2fs "$ROOT" || true
GROW
            chmod +x "$CHROOT/usr/local/sbin/grow-rootfs"
            cat > "$CHROOT/etc/systemd/system/grow-rootfs.service" <<SVC
[Unit]
Description=Grow rootfs to fill disk (first boot)
ConditionPathExists=/usr/local/sbin/grow-rootfs
ConditionFirstBoot=yes
After=local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/grow-rootfs
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SVC
            # Batocera switched to systemd in v33+. Try systemctl enable;
            # tolerate buildroot quirks where /etc/systemd/system layout
            # differs.
            mkdir -p "$CHROOT/etc/systemd/system/sysinit.target.wants"
            ln -sf ../grow-rootfs.service \
                "$CHROOT/etc/systemd/system/sysinit.target.wants/grow-rootfs.service"
            ;;
        artix*)
            # Artix Linux: Arch derivative without systemd. The project
            # ships ISOs (artix-base-{openrc,runit,dinit,s6}-…iso) but no
            # bootstrap tarball, so we extract the live airootfs squashfs
            # from the ISO and customize it in chroot. Pacman + Artix
            # repos already work inside the airootfs (it's a fully
            # functional rootfs the live env runs on).
            case "$DISTRO" in
                artix-runit) ARTIX_INIT="runit" ;;
                artix-openrc) ARTIX_INIT="openrc" ;;
                # Pre-riced Hyprland build defaults to runit (sv units pair
                # cleanly with greetd / Hyprland's seatd dependency).
                artix-hyprland-lightcrimson) ARTIX_INIT="runit" ;;
            esac
            ARTIX_INIT="${ARTIX_INIT:-openrc}"
            # Artix only keeps a small window of dated ISO builds online; the
            # mirror prunes older ones, so hardcoding ARTIX_BUILD bitrots fast.
            # Scrape the mirror index for the newest matching ISO instead.
            if [ -z "${ARTIX_URL:-}" ]; then
                ARTIX_INDEX="https://mirror1.artixlinux.org/iso/"
                ARTIX_BUILD=$(wget -q -O - "$ARTIX_INDEX" \
                    | grep -oE "artix-base-${ARTIX_INIT}-[0-9]{8}-x86_64\.iso" \
                    | sort -u | tail -1 \
                    | grep -oE "[0-9]{8}")
                [ -n "$ARTIX_BUILD" ] || { echo "ERROR: no Artix $ARTIX_INIT ISO on mirror"; exit 1; }
                ARTIX_URL="${ARTIX_INDEX}artix-base-${ARTIX_INIT}-${ARTIX_BUILD}-x86_64.iso"
            else
                ARTIX_BUILD=$(echo "$ARTIX_URL" | grep -oE "[0-9]{8}")
            fi

            echo "=== Artix: locate / download $ARTIX_INIT build $ARTIX_BUILD ==="
            CACHED="/build/cache/artix-base-${ARTIX_INIT}-${ARTIX_BUILD}-x86_64.iso"
            # Validate cached ISO against the mirror's Content-Length. Without
            # this, a previous run that died mid-download (curl/wget killed,
            # disk full, etc) leaves a truncated file at $CACHED — the next
            # run sees it's non-zero, skips the download, and silently fails
            # later at unsquashfs / mount-loop. Re-download if short.
            if [ -s "$CACHED" ]; then
                EXPECTED=$(wget -q -S --spider "$ARTIX_URL" 2>&1 \
                    | awk 'tolower($1) == "content-length:" {print $2}' \
                    | tail -1 | tr -d '\r')
                ACTUAL=$(stat -c%s "$CACHED")
                if [ -n "$EXPECTED" ] && [ "$ACTUAL" -lt "$EXPECTED" ]; then
                    echo ">> Cached ISO is partial ($ACTUAL B < $EXPECTED B), discarding"
                    rm -f "$CACHED"
                fi
            fi
            if [ ! -s "$CACHED" ]; then
                echo ">> No cached ISO, downloading"
                wget --tries=3 -O "$CACHED.part" "$ARTIX_URL"
                mv "$CACHED.part" "$CACHED"
            fi
            echo ">> Using $CACHED ($(du -h "$CACHED" | cut -f1))"

            echo "=== Artix: mount ISO + locate airootfs.sfs ==="
            ARTIX_MNT=$(mktemp -d)
            mount -o ro,loop "$CACHED" "$ARTIX_MNT"
            # Artix ISOs put the airootfs squashfs under either
            # /arch/x86_64/airootfs.sfs (current) or /arch/boot/x86_64/
            # (older). Probe both.
            ARTIX_SFS=""
            for c in /arch/x86_64/airootfs.sfs /arch/boot/x86_64/airootfs.sfs /LiveOS/rootfs.img /LiveOS/squashfs.img; do
                [ -f "$ARTIX_MNT$c" ] && ARTIX_SFS="$ARTIX_MNT$c" && break
            done
            if [ -z "$ARTIX_SFS" ]; then
                echo "ERROR: airootfs squashfs not found in Artix ISO:"
                find "$ARTIX_MNT" -maxdepth 4 -name '*.sfs' -o -name '*.img' | head -20
                exit 1
            fi

            echo "=== Artix: unsquashfs $ARTIX_SFS -> $CHROOT ==="
            unsquashfs -f -d "$CHROOT" "$ARTIX_SFS"

            umount "$ARTIX_MNT"
            rmdir "$ARTIX_MNT"

            echo "=== Artix: strip live-iso scaffolding ==="
            # Live ISOs ship calamares + archiso/artools install scripts
            # we don't want on a flashed root. They're harmless if left,
            # but bloat the image and may auto-start on TTY1.
            rm -rf "$CHROOT/etc/skel/Desktop" \
                   "$CHROOT/etc/calamares" \
                   "$CHROOT/etc/runlevels"/*/calamares* 2>/dev/null || true
            # The live ISO autostarts a "live" user shell on tty1. Disable.
            rm -f "$CHROOT/etc/runit/runsvdir/default/agetty-autologin-tty1" \
                  "$CHROOT/etc/runlevels/default/agetty-autologin-tty1" \
                  "$CHROOT/etc/init.d/agetty-autologin-tty1" 2>/dev/null || true
            # Remove the `artix` live user entries if present (lives in
            # /etc/passwd of the airootfs).
            if [ -f "$CHROOT/etc/passwd" ]; then
                sed -i '/^artix:/d;/^live:/d' "$CHROOT/etc/passwd" "$CHROOT/etc/shadow" "$CHROOT/etc/group" 2>/dev/null || true
            fi

            echo "=== Artix: stage linux-ps5 + grow-rootfs ==="
            mkdir -p "$CHROOT/var/cache/ps5-pkgs"
            cp "$STAGING/pkgs/"*.pkg.tar.zst "$CHROOT/var/cache/ps5-pkgs/"
            install -Dm755 "$STAGING/grow-rootfs"        "$CHROOT/usr/local/sbin/grow-rootfs"
            case "$ARTIX_INIT" in
                runit)
                    install -Dm755 "$STAGING/grow-rootfs.runit" \
                        "$CHROOT/etc/runit/1.d/grow-rootfs"
                    ;;
                *)
                    install -Dm755 "$STAGING/grow-rootfs.openrc" \
                        "$CHROOT/etc/init.d/grow-rootfs"
                    ;;
            esac
            # Pre-provisioned wifi (test builds only — strip before push).
            # NM requires mode 0600 on keyfiles; anything looser is silently
            # ignored.
            if [ -f /repo/distros/artix-openrc/wifi.nmconnection ]; then
                install -Dm600 /repo/distros/artix-openrc/wifi.nmconnection \
                    "$CHROOT/etc/NetworkManager/system-connections/wifi.nmconnection"
            fi

            echo "=== Artix: enter chroot for pacman + service setup ==="
            cleanup_artix_mounts() {
                for m in dev sys proc; do
                    mountpoint -q "$CHROOT/$m" && umount "$CHROOT/$m" || true
                done
            }
            trap cleanup_artix_mounts RETURN ERR EXIT
            mount --bind /proc "$CHROOT/proc"
            mount --bind /sys  "$CHROOT/sys"
            mount --bind /dev  "$CHROOT/dev"
            rm -f "$CHROOT/etc/resolv.conf"
            cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

            chroot "$CHROOT" env ARTIX_INIT="$ARTIX_INIT" DISTRO="$DISTRO" /bin/bash -e <<'ARTIX_IN'
                # Pacman 7 Landlock sandbox is unsupported under QEMU/docker.
                sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf 2>/dev/null || true

                # The live ISO's pacman config has [system] [world] [galaxy]
                # already wired; make sure keyrings are populated for fresh
                # installs from those repos.
                pacman-key --init
                pacman-key --populate artixlinux 2>/dev/null || pacman-key --populate artix 2>/dev/null || true
                # Refresh package DBs against current mirrors.
                pacman -Syy --noconfirm

                # Desktop: sway (Wayland tiling WM) + greetd autologin.
                # No X server — xwayland alone handles legacy X11 clients.
                # Per-init suffix for the Artix service-glue subpackages
                # (NetworkManager-openrc vs -runit, etc.).
                SFX="$ARTIX_INIT"

                # Per-distro WM stack. The default Artix builds ship sway
                # (small, lean, no surprises). The lightcrimson rice on top
                # of Hyprland is its own distro target; install Hyprland +
                # the ml4w-lightcrimson runtime deps instead of sway.
                case "$DISTRO" in
                    artix-hyprland-lightcrimson)
                        WM_PKGS="hyprland hyprlock hypridle hyprpaper hyprpicker
                                 xdg-desktop-portal-hyprland xorg-xwayland
                                 waybar swaync wofi rofi-wayland walker
                                 kitty alacritty foot
                                 grim slurp wl-clipboard cliphist
                                 brightnessctl pamixer playerctl
                                 fastfetch btop zsh fish starship
                                 ttf-jetbrains-mono-nerd noto-fonts-emoji
                                 papirus-icon-theme bibata-cursor-theme
                                 gtk3 gtk4 qt5ct qt6ct
                                 polkit-gnome network-manager-applet pavucontrol
                                 unzip zip rsync zoxide cava"
                        ;;
                    *)
                        WM_PKGS="sway swaybg swayidle swaylock waybar foot wofi
                                 xdg-desktop-portal-wlr xorg-xwayland"
                        ;;
                esac

                pacman -S --noconfirm --needed --overwrite '*' \
                    $WM_PKGS \
                    greetd \
                    mesa vulkan-radeon libva-mesa-driver \
                    libinput xkeyboard-config \
                    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils \
                    networkmanager networkmanager-$SFX network-manager-applet \
                    elogind-$SFX \
                    openssh openssh-$SFX \
                    sudo bash nano vim htop wget curl git base-devel \
                    e2fsprogs parted gptfdisk \
                    polkit dbus dbus-$SFX seatd \
                    kexec-tools kmod \
                    ttf-dejavu ttf-liberation noto-fonts noto-fonts-cjk noto-fonts-emoji fontconfig \
                    linux-firmware \
                    || true

                # The live ISO ships the mainline `linux` kernel + headers
                # pre-installed; linux-ps5 conflicts with both at the
                # package level. Force-remove with -Rdd (skip dependency
                # checks; nothing depending on /boot/vmlinuz-linux can run
                # on PS5 hardware anyway). Ignore failure if either is
                # already gone on older ISO snapshots.
                pacman -Rdd --noconfirm linux linux-headers linux-api-headers 2>/dev/null || true

                # Install our patched kernel + modules.
                pacman -U --noconfirm --overwrite '*' /var/cache/ps5-pkgs/*.pkg.tar.zst
                rm -rf /var/cache/ps5-pkgs

                # Pre-configure repo.etawen.dev so users can `pacman -Syu`
                # for kernel updates after first boot.
                curl -fsSL https://repo.etawen.dev/key.asc | pacman-key --add - 2>/dev/null || true
                pacman-key --lsign-key E40FB2409C9AD5243762294293AB12C4159FEDAB 2>/dev/null || true
                if ! grep -q "^\[ps5\]" /etc/pacman.conf; then
                    cat >> /etc/pacman.conf <<ETAWEN

[ps5]
SigLevel = Required DatabaseRequired
Server = https://repo.etawen.dev/arch
ETAWEN
                fi

                # mkinitcpio: drop autodetect so the initramfs covers the
                # PS5's hardware, not the build host's (matches the arch
                # path's recipe).
                sed -i 's/ autodetect//' /etc/mkinitcpio.conf
                KVER=$(ls -1t /lib/modules | head -1)
                mkinitcpio -k "$KVER" -g "/boot/initramfs-${KVER}.img" || true
                mkdir -p /boot/efi
                cp "/boot/vmlinuz-$KVER"            /boot/efi/bzImage
                cp "/boot/initramfs-${KVER}.img"    /boot/efi/initrd.img

                # SSH
                sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'               /etc/ssh/sshd_config
                sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

                # Service wiring — branch by init system.
                if [ "$ARTIX_INIT" = "runit" ]; then
                    # Runit: each -runit subpackage drops /etc/runit/sv/<svc>/.
                    # Activate by symlinking into the default runsvdir.
                    mkdir -p /etc/runit/runsvdir/default
                    for svc in dbus elogind seatd NetworkManager sshd greetd; do
                        [ -d "/etc/runit/sv/$svc" ] && \
                            ln -sfn "/etc/runit/sv/$svc" "/etc/runit/runsvdir/default/$svc"
                    done
                    # grow-rootfs is a one-shot stage-1 hook (installed by host
                    # at /etc/runit/1.d/grow-rootfs) — no symlink needed.
                else
                    # OpenRC: -openrc subpackages drop /etc/init.d/<svc>; plug into runlevels.
                    rc-update add dbus default        || true
                    rc-update add elogind boot        || true
                    rc-update add seatd default       || true
                    rc-update add NetworkManager default || true
                    rc-update add sshd default        || true
                    rc-update add greetd default      || true
                    rc-update add grow-rootfs default || true
                fi

                # Default user (ps5 / ps5). plugdev is a Debian-ism not
                # pre-created on Artix — the udev removable-device rules
                # there target the `uucp`/`input` groups instead, so skip
                # the missing group rather than fight it.
                if ! id ps5 >/dev/null 2>&1; then
                    useradd -m -s /bin/bash -G wheel,video,audio,input,seat ps5
                fi
                echo "ps5:ps5" | chpasswd
                passwd -l root
                echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

                # greetd: autologin ps5 -> exec the WM. Single Wayland session,
                # no display manager UI. WM binary depends on the variant.
                case "$DISTRO" in
                    artix-hyprland-lightcrimson) GREETD_CMD="Hyprland" ;;
                    *)                           GREETD_CMD="sway" ;;
                esac
                mkdir -p /etc/greetd
                cat > /etc/greetd/config.toml <<GREETD
[terminal]
vt = 1

[default_session]
command = "$GREETD_CMD"
user = "ps5"
GREETD

                # amdgpu options — PS5 Oberon GPU needs dpm disabled.
                mkdir -p /etc/modprobe.d
                cat > /etc/modprobe.d/ps5-amdgpu.conf <<AMDGPU
options amdgpu dpm=0 gpu_recovery=0
AMDGPU

                # Hold linux-ps5 against upstream replacement.
                sed -i '/^IgnorePkg/d' /etc/pacman.conf
                sed -i '/^\[options\]/a IgnorePkg = linux-ps5' /etc/pacman.conf

                # vconsole.conf needed by mkinitcpio sd-vconsole hook.
                [ -f /etc/vconsole.conf ] || echo "KEYMAP=us" > /etc/vconsole.conf

                # Pre-riced variants: bake dotfiles into /etc/skel so any
                # freshly-created user (including the `ps5` account above)
                # gets the rice on first login. The chroot is already
                # online — DNS was wired up before this heredoc started,
                # so git/curl reach the upstreams.
                case "$DISTRO" in
                    artix-hyprland-lightcrimson)
                        # yurihikari/ml4w-lightcrimson-dotfiles only ships the
                        # ML4W overrides (.config/hypr is a symlink into
                        # .mydotfiles/com.ml4w.dotfiles/.config/hypr which
                        # contains only colors.conf + assets). For a working
                        # Hyprland session we need the full ML4W base
                        # underneath. mylinuxforwork/dotfiles ships the
                        # canonical profile at share/dotfiles/.
                        TMP=$(mktemp -d)
                        git clone --depth 1 https://github.com/mylinuxforwork/dotfiles.git \
                            "$TMP/ml4w-base" || true
                        git clone --depth 1 https://github.com/yurihikari/ml4w-lightcrimson-dotfiles.git \
                            "$TMP/lightcrimson" || true

                        mkdir -p /etc/skel/.config /etc/skel/.local/share /etc/skel/.mydotfiles

                        # Stage 1 — ML4W's default Hyprland profile from
                        # share/dotfiles/. Layout may shift over time; copy
                        # whatever's there into the skel .config.
                        if [ -d "$TMP/ml4w-base/share/dotfiles" ]; then
                            cp -aL "$TMP/ml4w-base/share/dotfiles/." \
                                /etc/skel/.config/ 2>/dev/null || true
                        fi

                        # Stage 2 — overlay the lightcrimson rice. Use
                        # rsync -aL so the repo's symlink-into-.mydotfiles
                        # layout flattens into a single concrete tree.
                        if [ -d "$TMP/lightcrimson/.config" ]; then
                            rsync -aL --exclude='.git/' \
                                "$TMP/lightcrimson/.config/" \
                                /etc/skel/.config/ 2>/dev/null || \
                            cp -arLf "$TMP/lightcrimson/.config/." \
                                /etc/skel/.config/ 2>/dev/null || true
                        fi
                        if [ -d "$TMP/lightcrimson/.mydotfiles" ]; then
                            cp -aL "$TMP/lightcrimson/.mydotfiles/." \
                                /etc/skel/.mydotfiles/ 2>/dev/null || true
                        fi

                        rm -rf "$TMP"

                        # Refresh the existing ps5 home from the now-populated
                        # skel — useradd already ran above with an empty skel,
                        # so the dotfiles wouldn't have copied otherwise.
                        if id ps5 >/dev/null 2>&1; then
                            cp -an /etc/skel/. /home/ps5/ 2>/dev/null || true
                            chown -R ps5:ps5 /home/ps5
                        fi
                        ;;
                esac
ARTIX_IN
            cleanup_artix_mounts
            trap - RETURN ERR EXIT
            ;;
        bazzite*)
            # Bazzite is an OCI atomic image; bypass distrobuilder entirely.
            # DISTRO=bazzite      -> ghcr.io/ublue-os/bazzite:stable
            # DISTRO=bazzite-deck -> ghcr.io/ublue-os/bazzite-deck:stable
            # Anything else after `bazzite-` is treated as the same uBlue
            # image-name pattern (bazzite-gnome, bazzite-nvidia, ...).
            case "$DISTRO" in
                bazzite)      REF="ghcr.io/ublue-os/bazzite:stable" ;;
                bazzite-*)    REF="ghcr.io/ublue-os/${DISTRO}:stable" ;;
                *)            REF="ghcr.io/ublue-os/bazzite:stable" ;;
            esac
            echo "=== Bazzite: skopeo copy $REF ==="
            OCI=$(mktemp -d)
            skopeo copy --override-os linux --override-arch amd64 \
                "docker://$REF" "oci:$OCI:bazzite"
            echo "=== umoci unpack -> $CHROOT ==="
            UNPACK=$(mktemp -d)
            umoci unpack --keep-dirlinks --image "$OCI:bazzite" "$UNPACK"
            # umoci layout: $UNPACK/{config.json, rootfs/}
            mv "$UNPACK/rootfs"/* "$CHROOT/" 2>/dev/null || true
            mv "$UNPACK/rootfs"/.[!.]* "$CHROOT/" 2>/dev/null || true
            rm -rf "$UNPACK" "$OCI"
            # ostree convention: /usr/etc holds the defaults; /etc is empty in
            # the image. Promote /usr/etc to /etc so the system boots normally.
            if [ -d "$CHROOT/usr/etc" ]; then
                cp -an "$CHROOT/usr/etc/." "$CHROOT/etc/" || true
                rm -rf "$CHROOT/usr/etc"
            fi
            # Stage PS5 kernel RPMs + grow-rootfs. /opt and /home are ostree
            # symlinks in Bazzite, /var is a real dir — drop staging files there.
            mkdir -p "$CHROOT/var/cache/ps5-rpms"
            cp /kernel-debs/*.rpm "$CHROOT/var/cache/ps5-rpms/"
            # /usr/local is a symlink to /var/usrlocal in ostree-based systems;
            # mkdir the target before cp to avoid following-symlink-on-missing.
            mkdir -p "$CHROOT/var/usrlocal/sbin"
            cp /repo/distros/bazzite/grow-rootfs       "$CHROOT/var/usrlocal/sbin/grow-rootfs"
            chmod +x "$CHROOT/var/usrlocal/sbin/grow-rootfs"
            cp /repo/distros/bazzite/grow-rootfs.service "$CHROOT/etc/systemd/system/grow-rootfs.service"
            # Chroot in: disable ostree stack, install PS5 kernel, user setup.
            # Trap to always umount, even if the chroot script exits early.
            cleanup_bazzite_mounts() {
                for m in dev sys proc; do
                    mountpoint -q "$CHROOT/$m" && umount "$CHROOT/$m" || true
                done
            }
            trap cleanup_bazzite_mounts RETURN ERR EXIT
            mount --bind /proc "$CHROOT/proc"
            mount --bind /sys  "$CHROOT/sys"
            mount --bind /dev  "$CHROOT/dev"
            # Bazzite has no /etc/resolv.conf inside the chroot (symlink target
            # doesn't exist yet) — provide a working one so dnf can reach mirrors.
            rm -f "$CHROOT/etc/resolv.conf"
            cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
            chroot "$CHROOT" /bin/bash -e <<"BAZIN"
                # Disable rpm-ostree services — we're a flat fs now.
                systemctl mask rpm-ostreed.service rpm-ostree-countme.service rpm-ostree-bootstatus.service 2>/dev/null || true
                # Drop the embedded ostree object store + deploy tree. With
                # rpm-ostree masked, the running rootfs is the flat OCI
                # extract — /sysroot/ostree/repo/objects/ is a deduplicated
                # second copy of the same content (~5GB+), and /ostree/
                # deploy/ holds yet another. Wiping them shrinks the disk
                # image roughly in half. Leave the dir skeleton in case
                # anything probes for it.
                rm -rf /sysroot/ostree/repo/objects \
                       /sysroot/ostree/repo/refs \
                       /sysroot/ostree/deploy
                mkdir -p /sysroot/ostree/repo/objects \
                         /sysroot/ostree/repo/refs/heads
                # Bazzite/rpm-ostree convention: /root is a symlink to
                # /var/roothome which doesn't exist in the OCI extract.
                # dracut's hostonly enumeration follows the symlink, hits
                # ENOENT, fails with `dracut-install: ERROR: installing '/root'`.
                # Make /root a real dir so dracut + the kernel postinst's own
                # dracut call both work.
                mkdir -p /var/roothome
                if [ -L /root ]; then
                    rm -f /root
                    mkdir -m 0700 /root
                fi
                # Install PS5 kernel via rpm --replacefiles (handles the file-
                # level conflict between our /usr/include/* headers and
                # Bazzite's kernel-headers; see fedora image.yaml comment).
                # Bazzite ships kernel modules as a dir; our rpm wants a symlink.
                rm -rf /lib/modules/*
                rpm -Uvh --replacefiles --replacepkgs --nodeps /var/cache/ps5-rpms/*.rpm
                rm -rf /var/cache/ps5-rpms

                # Pre-configure repo.etawen.dev so users can
                # `dnf upgrade linux-ps5` after first boot. Per-package
                # gpgcheck=0 (alien-converted RPMs aren't per-package
                # signed); repodata IS signed by the mia PGP key.
                cat > /etc/yum.repos.d/etawen-ps5.repo <<ETAWEN
[etawen-ps5]
name=Etawen PS5 kernel repo
baseurl=https://repo.etawen.dev/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://repo.etawen.dev/key.asc
ETAWEN
                # PS5-specific dracut overrides. Two real-world problems we
                # hit when booting bazzite-deck on FLAVA3 PS5 hardware:
                #
                #  (1) bazzite's stock dracut config force-includes vfio,
                #      vfio-pci, and vfio_iommu_type1 in the initramfs (it
                #      ships with GPU-passthrough use cases in mind). On
                #      PS5, vfio-pci can grab the Oberon GPU at
                #      0000:20:00.0 before amdgpu's modalias fires, and
                #      amdgpu's pci_probe then returns -EINVAL.
                #
                #  (2) If amdgpu itself lands in initramfs, it probes before
                #      amd_atl (which only loads later via a CPU-feature
                #      modalias). amdgpu's RAS init then sees no ATL and
                #      bails the same way. Both miaos and the upstream
                #      Arch path defer amdgpu until after switch_root and
                #      it probes cleanly — so do the same here.
                #
                # We also intentionally do NOT write the historical
                # `options amdgpu dpm=0 gpu_recovery=0` modprobe.d file.
                # It was a workaround for older linux-ps5 amdgpu and is
                # now actively harmful on CYAN_SKILLFISH (PS5 Oberon):
                # disabling DPM at probe time triggers the -EINVAL we see
                # on bazzite-deck. Default dpm=-1 works correctly on real
                # PS5 hardware (confirmed live on miaos at .109/.50 — same
                # kernel binary, no dpm override, amdgpu probe succeeds,
                # display lights up).
                mkdir -p /etc/dracut.conf.d
                cat > /etc/dracut.conf.d/99-ps5.conf <<DRACUT
omit_drivers+=" vfio vfio_iommu_type1 vfio-pci amdgpu "
DRACUT

                # Build the initrd, then deploy bzImage+initrd to /boot/efi/
                # for the PS5 kexec loader. (zz-update-boot is the deb-flow
                # helper; bazzite never stages it, so we inline the copies.)
                # --no-hostonly: don't tailor the initramfs to the build
                # host's hardware (the runners are not AMD GPUs); we want
                # a generic initramfs that works on PS5.
                KVER=$(ls -1t /lib/modules | head -1)
                dracut -f --no-hostonly --no-hostonly-cmdline \
                    --kver "$KVER" "/boot/initrd.img-$KVER"
                mkdir -p /boot/efi
                cp "/boot/vmlinuz-$KVER" /boot/efi/bzImage
                cp "/boot/initrd.img-$KVER" /boot/efi/initrd.img

                # Suppress first-boot wizards. plasma-setup.service runs on every
                # boot until /etc/plasma-setup-done exists, and its bootutil
                # rewrites SDDM autologin to User=plasma-setup (clobbering our
                # User=ps5) and starts the Plasma OOBE wizard, which prompts the
                # user to create a fresh account. Our build pre-creates ps5; the
                # wizard is unwanted.
                touch /etc/plasma-setup-done
                systemctl mask plasma-setup.service 2>/dev/null || true

                # bazzite-hardware-setup.service runs on every boot until the
                # marker files in /etc/bazzite/ match the image-info.json. Seed
                # them so the script exits at its early-return; also mask it
                # outright since the script calls `rpm-ostree kargs` which fails
                # against our masked rpm-ostreed. The script's other work
                # (zram, IOMMU karg, hw-specific kargs) isn't applicable on PS5
                # anyway — we set our own cmdline in /boot/efi/cmdline.txt.
                mkdir -p /etc/bazzite
                jq -r '."image-name"'     < /usr/share/ublue-os/image-info.json > /etc/bazzite/image_name
                jq -r '."image-branch"'   < /usr/share/ublue-os/image-info.json > /etc/bazzite/image_branch
                jq -r '."fedora-version"' < /usr/share/ublue-os/image-info.json > /etc/bazzite/fedora_version
                grep -oP '^HWS_VER=\K[0-9]+' /usr/libexec/bazzite-hardware-setup > /etc/bazzite/hws_version
                systemctl mask bazzite-hardware-setup.service 2>/dev/null || true

                # User setup. Bazzite exposes video/audio/input/render via
                # systemd-userdbd, so `getent group video` returns a row —
                # and `groupadd -f` short-circuits as "already exists" and
                # does nothing. But useradd reads /etc/group directly (no
                # NSS), sees an empty file, and bails with "group X does not
                # exist". Materialize each group into /etc/group ourselves,
                # preserving the NSS-assigned GID when there is one so
                # existing file ownerships in the rootfs stay correct.
                passwd -l root
                # Ensure /etc/gshadow exists with the right perms; useradd
                # refuses to "prepare new entry" silently if it's missing.
                [ -e /etc/gshadow ] || { touch /etc/gshadow; chmod 0 /etc/gshadow; }
                for g in wheel video audio input render; do
                    if ! grep -q "^${g}:" /etc/group; then
                        gid=$(getent group "$g" 2>/dev/null | cut -d: -f3 || true)
                        if [ -z "$gid" ]; then
                            # Pick the next free system gid (100-999).
                            gid=$(awk -F: 'BEGIN{m=100} $3>=100 && $3<1000 && $3>m {m=$3} END{print m+1}' /etc/group)
                        fi
                        echo "${g}:x:${gid}:" >> /etc/group
                    fi
                    # Always make sure /etc/gshadow has a row.
                    grep -q "^${g}:" /etc/gshadow || echo "${g}:!::" >> /etc/gshadow
                done
                if ! id ps5 >/dev/null 2>&1; then
                    useradd -m -s /bin/bash -G wheel,video,audio,input,render ps5
                fi
                echo "ps5:ps5" | chpasswd
                sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

                # Install pieces Bazzite's slim OCI image is missing.
                #   cloud-utils-growpart + parted: grow-rootfs needs growpart
                #     and partprobe — without them the rootfs stays sized to
                #     the build image (~10GB) on whatever USB it lands on.
                #   plasma-systemmonitor + ksystemstats: standard Plasma
                #     "System Monitor" app. Bazzite's container drops it.
                #   kdiff3 / gwenview / ark / okular / spectacle: rest of
                #     the Plasma utilities most people expect.
                #   chrony: NTP. PS5's RTC is wrong on boot; without an NTP
                #     client the system clock is years off and TLS breaks.
                dnf install -y --setopt=install_weak_deps=False \
                    cloud-utils-growpart parted \
                    plasma-systemmonitor ksystemstats \
                    kdiff3 gwenview ark okular spectacle \
                    chrony \
                    || echo "WARN: dnf install failed; some pkgs may be missing"

                # Services
                systemctl enable grow-rootfs.service NetworkManager sshd 2>/dev/null || true
                # Time sync. Prefer systemd-timesyncd if present (lighter);
                # fall back to chrony (which we just dnf-installed).
                systemctl enable systemd-timesyncd 2>/dev/null \
                    || systemctl enable chronyd 2>/dev/null || true
                # Virtual terminals. Bazzite's preset disables getty@tty2-6;
                # explicitly enable them so Ctrl+Alt+F2..F6 give text consoles.
                for n in 2 3 4 5 6; do
                    systemctl enable getty@tty${n}.service 2>/dev/null || true
                done
                # Default DM (Bazzite ships KDE Plasma + SDDM)
                systemctl enable sddm 2>/dev/null || systemctl enable gdm 2>/dev/null || true
                # resolv.conf -> systemd-resolved stub
                rm -f /etc/resolv.conf
                ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                # Steam Deck UI's "Switch to Desktop" button calls SteamOS-
                # Manager's SetTemporarySession(s) dbus method, which writes
                # Session=<bare-alias> (literally "desktop"/"gamescope") into
                # /etc/sddm.conf.d/zzt-steamos-temp-login.conf. That conf
                # sorts AFTER zz-steamos-autologin.conf so it wins precedence
                # at autologin time — but SDDM has no `desktop.desktop`
                # session to resolve the alias to, so the button silently
                # no-ops and the user stays on gamescope. (The bash
                # steamos-session-select tool works fine because it resolves
                # aliases itself before writing — only the dbus path is
                # broken.) Fix it with alias symlinks SDDM can follow.
                for cand in plasma-steamos-wayland-oneshot.desktop \
                            gnome-wayland-oneshot.desktop plasma.desktop; do
                    if [ -e "/usr/share/wayland-sessions/$cand" ]; then
                        ln -sf "$cand" /usr/share/wayland-sessions/desktop.desktop
                        break
                    fi
                done
                for cand in gamescope-session.desktop gamescope-session-plus.desktop; do
                    if [ -e "/usr/share/wayland-sessions/$cand" ]; then
                        ln -sf "$cand" /usr/share/wayland-sessions/gamescope.desktop
                        break
                    fi
                done
                # Autologin straight into Bazzite's gamescope session (Steam
                # Big-Picture / Deck UI) — Bazzite is gaming-focused, and a
                # field report said it landed on the Plasma desktop instead
                # of gamemode. Pick whichever gamescope session file exists,
                # fall back to plasma if Bazzite stripped them.
                mkdir -p /etc/sddm.conf.d
                SESSION=plasma
                for s in gamescope-session-plus.desktop gamescope-session.desktop steam-wayland.desktop; do
                    if [ -e "/usr/share/wayland-sessions/$s" ] || [ -e "/usr/share/xsessions/$s" ]; then
                        SESSION="${s%.desktop}"
                        break
                    fi
                done
                cat > /etc/sddm.conf.d/autologin.conf <<SDDM
[Autologin]
User=ps5
Session=$SESSION
SDDM

                # Gamescope-session fallback. Field report: bazzite-deck boots
                # to a black screen on PS5 because gamescope can't grab the
                # display (PSP/TA + Salina HDMI bridge weirdness — workaround
                # is `steamos-session-select plasma` from a VT). Automate it:
                # first-boot oneshot waits 60s for a gamescope process; if
                # nothing shows up, flip the session to plasma and bounce
                # SDDM. Only arm this when the chosen session is gamescope-
                # flavoured. After first boot the user owns session choice
                # via the standard steamos-session-select tool + the desktop
                # shortcut we drop below.
                case "$SESSION" in gamescope*|steam-wayland*)
                    mkdir -p /usr/local/sbin /etc/systemd/system/graphical.target.wants
                    cat > /usr/local/sbin/ps5-gamescope-recovery <<'POKE'
#!/bin/bash
# Wait up to 60s for gamescope to actually grab a display. If it doesn't,
# the user is staring at a black screen — fall back to plasma and bounce
# the display manager so they get a usable login session.
for _ in $(seq 1 60); do
    sleep 1
    pgrep -x gamescope >/dev/null 2>&1 && exit 0
done
logger -t ps5-gamescope-recovery "gamescope didn't start within 60s, switching to plasma"
runuser -u ps5 -- steamos-session-select plasma 2>/dev/null \
    || sed -i 's/^Session=.*/Session=plasma/' /etc/sddm.conf.d/autologin.conf
systemctl restart sddm
POKE
                    chmod +x /usr/local/sbin/ps5-gamescope-recovery
                    cat > /etc/systemd/system/ps5-gamescope-recovery.service <<RECOV
[Unit]
Description=Fall back to plasma if gamescope can't grab a display (first boot)
After=graphical.target
ConditionFirstBoot=yes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-gamescope-recovery
RemainAfterExit=no

[Install]
WantedBy=graphical.target
RECOV
                    ln -sf ../ps5-gamescope-recovery.service \
                        /etc/systemd/system/graphical.target.wants/ps5-gamescope-recovery.service

                    # Desktop shortcut so the user can opt back into gamescope
                    # after a recovery (or after switching to plasma manually).
                    mkdir -p /home/ps5/Desktop
                    cat > /home/ps5/Desktop/Switch-to-Gamescope.desktop <<DESK
[Desktop Entry]
Version=1.0
Type=Application
Name=Switch to Gamescope (Big Picture)
Comment=Switch the autologin session back to gamescope / Steam Deck UI
Exec=bash -c 'steamos-session-select gamescope && systemctl restart sddm'
Icon=steam
Terminal=false
Categories=System;
DESK
                    chmod +x /home/ps5/Desktop/Switch-to-Gamescope.desktop
                    chown -R ps5:ps5 /home/ps5/Desktop 2>/dev/null || \
                        chown -R 1000:1000 /home/ps5/Desktop
                    ;;
                esac

                # DTM TA race workaround. amdgpu's display-topology TA
                # (Trusted Application) loads async via PSP; if DRM probes
                # connectors before that finishes, you get
                #   [drm] Failed to add display topology, DTM TA is not initialized
                # and the screen stays dark until the user manually toggles
                # VT (ctrl+alt+F7 -> ctrl+alt+F1) which forces a re-probe.
                # Mimic that automatically: after amdgpu binds, wait a beat
                # then re-trigger DRM connector detection.
                mkdir -p /usr/local/sbin /etc/udev/rules.d
                cat > /usr/local/sbin/ps5-amdgpu-reprobe <<'POKE'
#!/bin/sh
# Wait for PSP/TA firmware to settle, then re-probe DRM connectors.
# Equivalent of the ctrl+alt+F7 / ctrl+alt+F1 dance.
(
    sleep 3
    for c in /sys/class/drm/card*-*/status; do
        [ -w "$c" ] && echo detect > "$c"
    done
) &
POKE
                chmod +x /usr/local/sbin/ps5-amdgpu-reprobe
                cat > /etc/udev/rules.d/70-ps5-amdgpu-reprobe.rules <<'UDEV'
# Re-trigger DRM hotplug after amdgpu binds, so the DTM TA-not-initialized
# race doesn't leave the user with a dark screen until they manually VT-cycle.
SUBSYSTEM=="drm", ACTION=="add", KERNEL=="card[0-9]*", RUN+="/usr/local/sbin/ps5-amdgpu-reprobe"
UDEV
BAZIN
            # explicit cleanup (the trap covers the failure path)
            cleanup_bazzite_mounts
            trap - RETURN ERR EXIT
            ;;
        *)
            YAML="/repo/distros/${DISTRO}/image.yaml"
            distrobuilder build-dir "$YAML" "$CHROOT" --with-post-files --cache-dir /build/cache --cleanup=false
            ;;
    esac
fi

# --- Post-distrobuilder fixups ---
case "$DISTRO" in
    ubuntu*|debian*|mint*|fedora*|bazzite*|batocera*)
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
        ;;
    devuan*)
        # No systemd-resolved on Devuan. resolvconf creates
        # /etc/resolvconf/run/resolv.conf at boot; NetworkManager writes
        # through to it (rc-manager=resolvconf). Point /etc/resolv.conf
        # at that path so name resolution works as soon as NM brings up
        # an interface.
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /etc/resolvconf/run/resolv.conf "$CHROOT/etc/resolv.conf"
        ;;
    artix*)
        # No systemd-resolved on Artix either. NetworkManager writes
        # /etc/resolv.conf directly when dns=default (the openrc-nm
        # default). Drop the build-container's resolv.conf so NM has
        # a clean slate to populate on first boot.
        rm -f "$CHROOT/etc/resolv.conf"
        : > "$CHROOT/etc/resolv.conf"
        ;;
esac

# --- ps5-linux-tools: fan + boost services ---
# Without /dev/icc fan control the PS5 runs at default (loud) fan curve;
# without /dev/mp1 boost the CPU/GPU stay at base clocks. ps5-linux-tools
# ships ps5_control (the binary that pokes both devices) and two systemd
# oneshots that bring them on at boot. Same recipe as the upstream README's
# install.sh — we just bake it into every image instead of asking the user
# to run it manually after first boot.
PS5TOOLS_REF="${PS5TOOLS_REF:-main}"
echo "=== ps5-linux-tools: build + install fan/boost services ==="
PS5TOOLS_DIR=/tmp/ps5-linux-tools
rm -rf "$PS5TOOLS_DIR"
git clone --depth 1 --branch "$PS5TOOLS_REF" \
    https://github.com/ps5-linux/ps5-linux-tools "$PS5TOOLS_DIR"
( cd "$PS5TOOLS_DIR" && make ps5_control m2_init )

install -Dm755 "$PS5TOOLS_DIR/ps5_control" "$CHROOT/usr/local/sbin/ps5_control"
install -Dm755 "$PS5TOOLS_DIR/m2_init"     "$CHROOT/usr/local/sbin/m2_init"

# Preserve the source tree at /opt/ps5-linux-tools so README-style commands
# (cd ps5-linux-tools && ./m2_install.sh, etc.) work on first boot without
# needing internet to re-clone.
#
# On Fedora-atomic / bazzite, /opt is a symlink to var/opt. mkdir -p on the
# symlink dangles because var/opt doesn't exist in the chroot yet, so resolve
# the symlink first and mkdir the actual target.
OPT_DEST=$(readlink -f "$CHROOT/opt" 2>/dev/null || echo "$CHROOT/opt")
mkdir -p "$OPT_DEST"
cp -a "$PS5TOOLS_DIR" "$OPT_DEST/ps5-linux-tools"
rm -rf "$OPT_DEST/ps5-linux-tools/.git"

case "$DISTRO" in
    alpine)
        # Alpine ships ps5fan/ps5boost via the OpenRC path in
        # post-files actions of its image.yaml; skip the systemd drop.
        :
        ;;
    devuan*)
        # Devuan is sysvinit. Drop /etc/init.d scripts and enable them
        # with update-rc.d during chroot below. The actual update-rc.d
        # call happens in image.yaml post-packages for the distro-built
        # units (ssh, NM, etc.) — for ps5fan/ps5boost we wire them up
        # here since they're staged outside the distrobuilder flow.
        cat > "$CHROOT/etc/init.d/ps5fan" <<'PS5FAN_SYSV'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ps5fan
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: PS5 fan control
### END INIT INFO
case "$1" in
    start) [ -e /dev/icc ] && /usr/local/sbin/ps5_control --fan on ;;
    stop)  [ -e /dev/icc ] && /usr/local/sbin/ps5_control --fan off ;;
    restart|force-reload) $0 stop; $0 start ;;
esac
exit 0
PS5FAN_SYSV
        cat > "$CHROOT/etc/init.d/ps5boost" <<'PS5BOOST_SYSV'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ps5boost
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: PS5 CPU/GPU boost mode
### END INIT INFO
case "$1" in
    start) [ -e /dev/mp1 ] && /usr/local/sbin/ps5_control --boost on ;;
    stop)  [ -e /dev/mp1 ] && /usr/local/sbin/ps5_control --boost off ;;
    restart|force-reload) $0 stop; $0 start ;;
esac
exit 0
PS5BOOST_SYSV
        chmod +x "$CHROOT/etc/init.d/ps5fan" "$CHROOT/etc/init.d/ps5boost"
        # update-rc.d may not be on PATH outside the chroot; run inside.
        chroot "$CHROOT" /usr/sbin/update-rc.d ps5fan defaults  >/dev/null 2>&1 || true
        chroot "$CHROOT" /usr/sbin/update-rc.d ps5boost defaults >/dev/null 2>&1 || true
        ;;
    artix-runit)
        # Artix runit: drop runit service trees and symlink into the
        # default runsvdir. Runit's run scripts are foreground-loop
        # daemons; ps5fan/ps5boost are one-shots, so do the work then
        # `exec pause` (or sleep infinity if no pause) to keep the
        # supervisor happy.
        mkdir -p "$CHROOT/etc/runit/sv/ps5fan"   "$CHROOT/etc/runit/sv/ps5boost"
        mkdir -p "$CHROOT/etc/runit/runsvdir/default"

        cat > "$CHROOT/etc/runit/sv/ps5fan/run" <<'PS5FAN_RUNIT'
#!/bin/sh
exec 2>&1
if [ -e /dev/icc ]; then
    /usr/local/sbin/ps5_control --fan on
fi
# Stay running so runsv keeps the service "up"; the one-shot effect is
# already applied. `sleep infinity` is portable across busybox/coreutils.
exec sleep infinity
PS5FAN_RUNIT

        cat > "$CHROOT/etc/runit/sv/ps5boost/run" <<'PS5BOOST_RUNIT'
#!/bin/sh
exec 2>&1
if [ -e /dev/mp1 ]; then
    /usr/local/sbin/ps5_control --boost on
fi
exec sleep infinity
PS5BOOST_RUNIT

        chmod +x "$CHROOT/etc/runit/sv/ps5fan/run" \
                 "$CHROOT/etc/runit/sv/ps5boost/run"
        ln -sfn /etc/runit/sv/ps5fan   "$CHROOT/etc/runit/runsvdir/default/ps5fan"
        ln -sfn /etc/runit/sv/ps5boost "$CHROOT/etc/runit/runsvdir/default/ps5boost"
        ;;
    artix*)
        # Artix OpenRC. Drop /etc/init.d openrc-run scripts and
        # rc-update them into the default runlevel.
        cat > "$CHROOT/etc/init.d/ps5fan" <<'PS5FAN_OPENRC'
#!/sbin/openrc-run
description="PS5 fan control"
depend() { need localmount; after dev-settle; }
start() {
    [ -e /dev/icc ] || { ebegin "PS5 fan: /dev/icc missing"; eend 0; return 0; }
    ebegin "Enabling PS5 fan control"
    /usr/local/sbin/ps5_control --fan on
    eend $?
}
stop() {
    [ -e /dev/icc ] || return 0
    ebegin "Disabling PS5 fan control"
    /usr/local/sbin/ps5_control --fan off
    eend $?
}
PS5FAN_OPENRC
        cat > "$CHROOT/etc/init.d/ps5boost" <<'PS5BOOST_OPENRC'
#!/sbin/openrc-run
description="PS5 CPU/GPU boost mode"
depend() { need localmount; after dev-settle; }
start() {
    [ -e /dev/mp1 ] || { ebegin "PS5 boost: /dev/mp1 missing"; eend 0; return 0; }
    ebegin "Enabling PS5 boost mode"
    /usr/local/sbin/ps5_control --boost on
    eend $?
}
stop() {
    [ -e /dev/mp1 ] || return 0
    ebegin "Disabling PS5 boost mode"
    /usr/local/sbin/ps5_control --boost off
    eend $?
}
PS5BOOST_OPENRC
        chmod +x "$CHROOT/etc/init.d/ps5fan" "$CHROOT/etc/init.d/ps5boost"
        chroot "$CHROOT" /sbin/rc-update add ps5fan default  >/dev/null 2>&1 || true
        chroot "$CHROOT" /sbin/rc-update add ps5boost default >/dev/null 2>&1 || true
        ;;
    *)
        # systemd distros: drop the service files and enable them.
        install -Dm644 "$PS5TOOLS_DIR/systemd/ps5fan.service" \
            "$CHROOT/etc/systemd/system/ps5fan.service"
        install -Dm644 "$PS5TOOLS_DIR/systemd/ps5boost.service" \
            "$CHROOT/etc/systemd/system/ps5boost.service"
        mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
        ln -sf ../ps5fan.service \
            "$CHROOT/etc/systemd/system/multi-user.target.wants/ps5fan.service"
        ln -sf ../ps5boost.service \
            "$CHROOT/etc/systemd/system/multi-user.target.wants/ps5boost.service"
        ;;
esac
rm -rf "$PS5TOOLS_DIR"

# --- Alpine kernel gap: no kernel installed via image.yaml ---
# Extract kernel from .deb, copy modules + bzImage, then chroot to run mkinitfs
if [ "$DISTRO" = "alpine" ]; then
    echo "=== Alpine: installing kernel from .deb artifacts ==="

    ALPINE_STAGING="/tmp/alpine-kernel-staging"
    rm -rf "$ALPINE_STAGING"
    mkdir -p "$ALPINE_STAGING"
    # Kernel-builder ships linux-ps5_*.deb (a single combined deb that
    # provides linux-image-*). The old linux-image-*.deb pattern matches
    # nothing on disk; keep both so an upstream naming shift doesn't
    # silently break alpine again.
    shopt -s nullglob
    for deb in /kernel-debs/linux-ps5*.deb /kernel-debs/linux-image-*.deb; do
        [ -f "$deb" ] || continue
        dpkg-deb -x "$deb" "$ALPINE_STAGING"
    done
    shopt -u nullglob

    KVER=$(ls -1 "$ALPINE_STAGING/lib/modules" 2>/dev/null | head -1)

    if [ -n "$KVER" ]; then
        # Resolve the real modules path (Alpine may use usr-merge: /lib -> usr/lib)
        if [ -L "$CHROOT/lib" ]; then
            MODDIR="$CHROOT/usr/lib/modules"
        else
            MODDIR="$CHROOT/lib/modules"
        fi
        mkdir -p "$MODDIR"
        rm -rf "$MODDIR/$KVER"
        cp -a "$ALPINE_STAGING/lib/modules/$KVER" "$MODDIR/"
        mkdir -p "$CHROOT/boot"
        cp "$ALPINE_STAGING/boot/vmlinuz-$KVER" "$CHROOT/boot/vmlinuz-$KVER"
        echo ">> Alpine: modules copied to $MODDIR/$KVER"
    fi
    rm -rf "$ALPINE_STAGING"

    if [ -n "$KVER" ]; then
        chroot "$CHROOT" depmod -a "$KVER" 2>/dev/null || true

        mount --bind /dev  "$CHROOT/dev"
        mount --bind /proc "$CHROOT/proc"
        mount --bind /sys  "$CHROOT/sys"
        chroot "$CHROOT" mkinitfs -k "$KVER" -o "/boot/initrd.img-$KVER" "$KVER" || true
        umount "$CHROOT/sys" "$CHROOT/proc" "$CHROOT/dev"

        # Populate /boot/efi/ for boot partition assembly
        mkdir -p "$CHROOT/boot/efi"
        cp "$CHROOT/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage"
        if [ -f "$CHROOT/boot/initrd.img-$KVER" ]; then
            cp "$CHROOT/boot/initrd.img-$KVER" "$CHROOT/boot/efi/initrd.img"
        else
            INITRD=$(ls -1t "$CHROOT"/boot/initramfs-* "$CHROOT"/boot/initrd* 2>/dev/null | head -1)
            if [ -n "$INITRD" ]; then
                cp "$INITRD" "$CHROOT/boot/efi/initrd.img"
            else
                echo "WARNING: No initrd found for alpine after mkinitfs"
            fi
        fi
        echo ">> Alpine: kernel $KVER staged to boot/efi/"
    else
        echo "WARNING: No kernel modules found in .deb for alpine"
    fi
fi

# --- Create GPT disk image ---
echo "=== Creating ${IMG_SIZE}MB disk image ==="
TMPIMG="/build/ps5-${DISTRO}.img"
dd if=/dev/zero of="$TMPIMG" bs=1M count=$IMG_SIZE conv=fsync status=progress

parted -s "$TMPIMG" mklabel gpt
parted -s "$TMPIMG" mkpart primary ext4  500MiB 100%
parted -s "$TMPIMG" mkpart primary fat32 1MiB   500MiB
parted -s "$TMPIMG" set 2 esp on

# Ensure the free loop device node exists (udev doesn't run inside containers,
# so when the kernel allocates a new loop number it may lack a /dev node)
LOOP_PATH=$(losetup -f)
if [ ! -e "$LOOP_PATH" ]; then
    LOOP_NUM=${LOOP_PATH#/dev/loop}
    mknod "$LOOP_PATH" b 7 "$LOOP_NUM"
fi

LOOPDEV=$(losetup -f --show "$TMPIMG")
# Use kpartx to create partition device mappings (more reliable in containers)
kpartx -av "$LOOPDEV"
sleep 1

# kpartx creates /dev/mapper/loopXp1, /dev/mapper/loopXp2
LOOP_BASE=$(basename "$LOOPDEV")
PART1="/dev/mapper/${LOOP_BASE}p1"
PART2="/dev/mapper/${LOOP_BASE}p2"

echo "=== Formatting partitions ==="
mkfs.ext4 -L "$ROOT_LABEL" -m 1  "$PART1"
mkfs.vfat -n "$EFI_LABEL"  -F32  "$PART2"

mkdir -p /tmp/usb_root /tmp/usb_efi
mount "$PART1" /tmp/usb_root
mount "$PART2" /tmp/usb_efi

echo "=== Copying rootfs to image ==="
cp -a "$CHROOT"/* /tmp/usb_root/
sync

echo "=== Assembling boot partition ==="
mv /tmp/usb_root/boot/efi/* /tmp/usb_efi/ 2>/dev/null || true
sed "s|__DISTRO__|$ROOT_LABEL|" /repo/boot/cmdline.txt > /tmp/usb_efi/cmdline.txt
cp /repo/boot/vram.txt     /tmp/usb_efi/
cp /repo/boot/kexec.sh     /tmp/usb_efi/
sync

umount /tmp/usb_root /tmp/usb_efi
rmdir  /tmp/usb_root /tmp/usb_efi
kpartx -dv "$LOOPDEV"
losetup -d "$LOOPDEV"

# Move finished image to output volume
mv "$TMPIMG" "$IMG"
sync

echo "========================================"
echo "Done! $IMG (${IMG_SIZE}MB)"
echo "Flash: sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "========================================"
