#!/bin/bash
# Builds a combined linux-ps5 .deb from staged artifacts in /out/staging.
# Runs inside the kernel-builder container; output goes to /out.
set -e

STAGING="/out/staging"
KVER=$(ls -1 "$STAGING/lib/modules" | head -1)
VER="${KVER%%-*}"
ARCH=amd64

PKG=$(mktemp -d)
mkdir -p "$PKG/DEBIAN"
mkdir -p "$PKG/boot"
mkdir -p "$PKG/lib/modules"

cp "$STAGING/boot/bzImage"  "$PKG/boot/vmlinuz-$KVER"
cp "$STAGING/System.map"    "$PKG/boot/System.map-$KVER"
cp "$STAGING/.config"       "$PKG/boot/config-$KVER"
cp -a "$STAGING/lib/modules/$KVER" "$PKG/lib/modules/"

# PS5 mwifiex modprobe config + modules-load + ps5-stage-firmware
# systemd unit, staged by build.sh into /out/staging.
if [ -d "$STAGING/etc" ]; then
    mkdir -p "$PKG/etc"
    cp -a "$STAGING/etc/." "$PKG/etc/"
fi
# ps5-stage-firmware script lives in /usr/local/sbin (referenced by the
# unit above). Stage that branch too.
if [ -d "$STAGING/usr" ]; then
    mkdir -p "$PKG/usr"
    cp -a "$STAGING/usr/." "$PKG/usr/"
fi

# Kernel headers (for out-of-tree module builds).
# We ship them under /usr/lib/modules/<kver>/build/. The conventional Debian
# convenience symlink /lib/modules/<kver>/build -> /usr/lib/modules/.../build
# is intentionally NOT created here — alien's deb->rpm conversion mangles it
# into a directory-vs-symlink conflict on rpm install. Out-of-tree builds can
# point KERNELDIR= at /usr/lib/modules/<kver>/build/ explicitly, or recreate
# the symlink post-install if they want the legacy path.
if [ -d "$STAGING/headers" ]; then
    cp -a "$STAGING/headers/usr" "$PKG/usr"
    mkdir -p "$PKG/usr/lib/modules/$KVER"
    cp -a "$STAGING/headers/lib/modules/$KVER/build" "$PKG/usr/lib/modules/$KVER/build"
fi

cat > "$PKG/DEBIAN/control" << CTRL
Package: linux-ps5
Version: $VER
Architecture: $ARCH
Maintainer: PS5 Linux
Provides: linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Conflicts: linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Replaces: linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Description: PS5 Linux kernel $KVER (image + modules + headers + libc-dev)
CTRL

cat > "$PKG/DEBIAN/postinst" << 'POSTINST'
#!/bin/bash
set -e
KVER="$(ls -1t /lib/modules | head -1)"
echo ">> linux-ps5 postinst: kernel $KVER"

# Rebuild initramfs (use whichever tool the host provides).
if command -v update-initramfs >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with update-initramfs for $KVER"
    update-initramfs -c -k "$KVER"
elif command -v mkinitcpio >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with mkinitcpio for $KVER"
    mkinitcpio -k "$KVER" -g "/boot/initrd.img-$KVER"
elif command -v dracut >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with dracut for $KVER"
    dracut -f --kver "$KVER" "/boot/initrd.img-$KVER"
elif command -v mkinitfs >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with mkinitfs for $KVER"
    mkinitfs -o "/boot/initrd.img-$KVER" "$KVER"
else
    echo ">> No initramfs tool found; skipping initramfs build"
fi

# Copy kernel + initrd to EFI partition (only the bits that exist).
if [ -d /boot/efi ]; then
    if [ -f "/boot/vmlinuz-$KVER" ]; then
        echo ">> Copying /boot/vmlinuz-$KVER -> /boot/efi/bzImage"
        cp "/boot/vmlinuz-$KVER" /boot/efi/bzImage
    fi
    if [ -f "/boot/initrd.img-$KVER" ]; then
        echo ">> Copying /boot/initrd.img-$KVER -> /boot/efi/initrd.img"
        cp "/boot/initrd.img-$KVER" /boot/efi/initrd.img
    else
        echo ">> /boot/initrd.img-$KVER not built yet; deferring initrd copy"
    fi
    echo ">> Kernel $KVER files deployed (where available) to /boot/efi"
else
    echo ">> /boot/efi not found, skipping EFI deploy"
fi
POSTINST
chmod 755 "$PKG/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "$PKG" "/out/linux-ps5_${VER}_${ARCH}.deb"
rm -rf "$PKG"
