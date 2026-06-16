#!/bin/bash
# Compiles the kernel and stages all artifacts into /out/staging.
# Runs inside Docker; kernel source is bind-mounted at /src.
set -e

# Clean host-built tool artifacts that may reference wrong include paths
make -C tools/objtool clean 2>/dev/null || true

make olddefconfig
make -j"$(nproc)" bzImage modules

# Stage all artifacts so downstream packagers don't need to run make
echo "=== Staging build artifacts ==="
rm -rf /out/staging
mkdir -p /out/staging/boot

cp arch/x86/boot/bzImage /out/staging/boot/
cp System.map             /out/staging/
cp .config                /out/staging/

make modules_install INSTALL_MOD_PATH=/out/staging INSTALL_MOD_STRIP=1

# Remove dangling symlinks back into the source tree
KVER=$(make -s kernelrelease)
rm -f "/out/staging/lib/modules/$KVER/build" \
      "/out/staging/lib/modules/$KVER/source"

# Stage kernel headers for out-of-tree module builds
echo "=== Staging kernel headers ==="
HDR="/out/staging/headers"
make headers_install INSTALL_HDR_PATH="$HDR/usr"

# Use the kernel's own install-extmod-build script (same as deb-pkg uses)
export srctree=/src SRCARCH=x86
CC="${CROSS_COMPILE}gcc" HOSTCC=gcc MAKE=make /src/scripts/package/install-extmod-build "$HDR/lib/modules/$KVER/build"

# ─── PS5 IW620 mwifiex driver ────────────────────────────────────────────────
# Out-of-tree module built against the kernel we just compiled. The
# ps5-linux-mwifiex repo provides a single patch on top of NXP's mwifiex
# release; building from that pin + that base produces mlan.ko / moal.ko
# staged alongside the in-tree modules.
MWIFIEX_REF="${MWIFIEX_REF:-5cfd063449f27e2f8a7d17c814a3bb21c27aa903}"   # ps5-linux/ps5-linux-mwifiex
NXP_REF="${NXP_REF:-lf-6.18.2_1.0.0}"                                   # nxp-imx/mwifiex base

echo "=== Build PS5 mwifiex (patch $MWIFIEX_REF on NXP $NXP_REF) ==="
rm -rf /tmp/mwifiex-ps5 /tmp/mwifiex-nxp
git clone --quiet https://github.com/ps5-linux/ps5-linux-mwifiex.git /tmp/mwifiex-ps5
git -C /tmp/mwifiex-ps5 checkout --quiet "$MWIFIEX_REF"
git clone --quiet --depth 1 --branch "$NXP_REF" https://github.com/nxp-imx/mwifiex.git /tmp/mwifiex-nxp
git -C /tmp/mwifiex-nxp apply /tmp/mwifiex-ps5/ps5-iw620.patch
make -C /tmp/mwifiex-nxp CONFIG_OBJTOOL= KERNELDIR=/src ARCH=x86 -j"$(nproc)"

mkdir -p "/out/staging/lib/modules/$KVER/extra/ps5-iw620"
cp /tmp/mwifiex-nxp/mlan.ko /tmp/mwifiex-nxp/moal.ko \
    "/out/staging/lib/modules/$KVER/extra/ps5-iw620/"

# modprobe config — values lifted from install.sh in ps5-linux-mwifiex.
mkdir -p /out/staging/etc/modprobe.d
cat > /out/staging/etc/modprobe.d/ps5-iw620.conf <<MODPROBE
# PS5 IW620 mwifiex
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1
MODPROBE

# Auto-load moal at boot. The NXP OOT driver doesn't expose a PCI
# MODULE_DEVICE_TABLE() that udev coldplug recognises, so without this
# the user has to `sudo modprobe moal` to bring WLAN up.
mkdir -p /out/staging/etc/modules-load.d
cat > /out/staging/etc/modules-load.d/ps5-iw620.conf <<'EOF'
moal
EOF

# Firmware staging. The PS5 WLAN firmware blob
# (nxp/pcieuartiw620_combo_v1.bin) is placed on the FAT32 EFI partition
# by ps5-linux-loader at /boot/efi/lib/nxp/. moal calls request_firmware()
# which searches /lib/firmware/, so we need a copy on boot. The blob is
# Sony-proprietary, so we can't bake it into the image.
mkdir -p /out/staging/usr/local/sbin
cat > /out/staging/usr/local/sbin/ps5-stage-firmware <<'EOF'
#!/bin/sh
set -eu
FW=nxp/pcieuartiw620_combo_v1.bin
DST=/lib/firmware/$FW
[ -e "$DST" ] && exit 0
for d in /boot/efi /efi /boot; do
    SRC="$d/lib/$FW"
    if [ -f "$SRC" ]; then
        install -Dm0644 "$SRC" "$DST"
        echo "ps5-stage-firmware: copied $SRC -> $DST"
        # Reload moal so it picks up firmware now that it exists.
        modprobe -r moal mlan 2>/dev/null || true
        modprobe moal 2>/dev/null || true
        exit 0
    fi
done
echo "ps5-stage-firmware: $FW not found on EFI partition; skipping"
exit 0
EOF
chmod +x /out/staging/usr/local/sbin/ps5-stage-firmware

mkdir -p /out/staging/etc/systemd/system/sysinit.target.wants
cat > /out/staging/etc/systemd/system/ps5-stage-firmware.service <<'EOF'
[Unit]
Description=Copy PS5 WLAN firmware from EFI partition to /lib/firmware
After=local-fs.target
Before=systemd-modules-load.service network-pre.target
ConditionPathExists=/usr/local/sbin/ps5-stage-firmware

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-firmware
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
ln -sf ../ps5-stage-firmware.service \
    /out/staging/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service

# ─── PS5 GBE driver ──────────────────────────────────────────────────────────
#
# The PS5's onboard gigabit ethernet (104d:9104) is driven in-tree by the
# `mts` driver added in ps5-linux-patches @ kernel-7.0.10-643e214 (PR #8).
# We no longer build rmuxnet/ps5-salina-gbe out-of-tree.

# Record the refs we built against (used in release-body rendering later).
echo "$MWIFIEX_REF" > /out/staging/mwifiex-ref
echo "$NXP_REF"     > /out/staging/nxp-ref

echo "=== Build artifacts staged in /out/staging ==="
