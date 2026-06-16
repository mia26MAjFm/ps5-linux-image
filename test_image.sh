#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./test_image.sh <image|image-name> [options]

Boot a PS5 Linux image in QEMU by extracting bzImage/initrd from the image's
EFI partition and passing them to qemu-system-x86_64 with the raw image as the
root disk.

This is a VM smoke test, not a PS5 boot test: these images do not contain a PC
UEFI bootloader, so QEMU boots the kernel directly.

Options:
  --label <label>       Root filesystem label (default: inferred from ps5-*.img)
  --memory <size>       QEMU memory size (default: 4096M)
  --smp <n>             QEMU CPU count (default: 4)
  --disk-bus <usb|virtio|ide>
                        QEMU disk bus for the image (default: usb)
  --ssh-port <port|none>
                        Host SSH forward port (default: 2222; "none" disables)
  --gui                 Open a QEMU graphical window instead of serial-only
  --no-kvm              Do not use KVM even if /dev/kvm is available
  --smoke-timeout <sec> Run a non-interactive serial smoke test and exit when
                        userspace/login is reached, a boot failure is seen, or
                        the timeout expires. Implies --no-kvm.
  --log <path>          Write QEMU serial output to a log file in smoke mode
  --append <args>       Extra kernel command-line arguments
  --qemu-arg <arg>      Extra QEMU argument; can be specified more than once
  -h, --help            Show this help

Examples:
  ./test_image.sh output/ps5-ubuntu2604.img
  ./test_image.sh ps5-ubuntu2604.img --memory 8G
  ./test_image.sh output/ps5-multi.img --label arch
EOF
}

IMAGE="${1:-}"
if [[ -z "$IMAGE" || "$IMAGE" == "-h" || "$IMAGE" == "--help" ]]; then
    usage
    exit 0
fi
shift

if [[ ! -f "$IMAGE" && -f "output/$IMAGE" ]]; then
    IMAGE="output/$IMAGE"
fi

if [[ ! -f "$IMAGE" ]]; then
    echo "error: image '$IMAGE' does not exist" >&2
    exit 1
fi

LABEL=""
MEMORY="4096M"
SMP="4"
DISK_BUS="usb"
SSH_PORT="2222"
GUI=false
USE_KVM=true
SMOKE_TIMEOUT=""
LOG_FILE=""
EXTRA_APPEND=()
EXTRA_QEMU_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)
            LABEL="${2:?missing label}"
            shift 2
            ;;
        --memory|-m)
            MEMORY="${2:?missing memory size}"
            shift 2
            ;;
        --smp)
            SMP="${2:?missing CPU count}"
            shift 2
            ;;
        --disk-bus)
            DISK_BUS="${2:?missing disk bus}"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="${2:?missing SSH port}"
            shift 2
            ;;
        --gui)
            GUI=true
            shift
            ;;
        --no-kvm)
            USE_KVM=false
            shift
            ;;
        --smoke-timeout)
            SMOKE_TIMEOUT="${2:?missing smoke timeout}"
            USE_KVM=false
            shift 2
            ;;
        --log)
            LOG_FILE="${2:?missing log file path}"
            shift 2
            ;;
        --append)
            EXTRA_APPEND+=("${2:?missing kernel args}")
            shift 2
            ;;
        --qemu-arg)
            EXTRA_QEMU_ARGS+=("${2:?missing QEMU arg}")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

for tool in qemu-system-x86_64 fdisk mcopy mdir; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' not found in PATH" >&2
        exit 1
    fi
done

if [[ -z "$LABEL" ]]; then
    base="$(basename "$IMAGE")"
    LABEL="${base%.img}"
    LABEL="${LABEL#ps5-}"
    if [[ -z "$LABEL" || "$LABEL" == "$base" || "$LABEL" == "multi" ]]; then
        echo "error: could not infer root label from '$base'; pass --label <label>" >&2
        exit 1
    fi
fi

SECTOR_SIZE="$(fdisk -l "$IMAGE" | awk '/Sector size/ {print $4; exit}')"
SECTOR_SIZE="${SECTOR_SIZE:-512}"
EFI_START="$(fdisk -l "$IMAGE" | awk '$0 ~ /EFI System/ {print $2; exit}')"

if [[ -z "$EFI_START" ]]; then
    echo "error: could not find EFI System partition in '$IMAGE'" >&2
    exit 1
fi

EFI_OFFSET=$((EFI_START * SECTOR_SIZE))
MTOOLS_IMAGE="${IMAGE}@@${EFI_OFFSET}"
TMPDIR="$(mktemp -d -t ps5-image-qemu.XXXXXX)"
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "Image:      $IMAGE"
echo "Root label: $LABEL"
echo "EFI offset: $EFI_OFFSET bytes"
echo "Work dir:   $TMPDIR"

if ! mcopy -i "$MTOOLS_IMAGE" ::bzImage "$TMPDIR/bzImage" 2>/dev/null; then
    echo "error: EFI partition does not contain bzImage" >&2
    echo "EFI contents:" >&2
    mdir -i "$MTOOLS_IMAGE" :: >&2 || true
    exit 1
fi

if ! mcopy -i "$MTOOLS_IMAGE" ::initrd.img "$TMPDIR/initrd.img" 2>/dev/null; then
    if ! mcopy -i "$MTOOLS_IMAGE" "::initrd-${LABEL}.img" "$TMPDIR/initrd.img" 2>/dev/null; then
        echo "error: EFI partition does not contain initrd.img or initrd-${LABEL}.img" >&2
        echo "EFI contents:" >&2
        mdir -i "$MTOOLS_IMAGE" :: >&2 || true
        exit 1
    fi
fi

APPEND="root=LABEL=${LABEL} rw rootwait console=ttyS0 console=tty0 systemd.unit=multi-user.target mitigations=off"
if [[ -n "$SMOKE_TIMEOUT" ]]; then
    APPEND+=" panic=-1 systemd.show_status=true earlyprintk=serial,ttyS0,115200 keep_bootcon loglevel=7 initcall_blacklist=mp1_init"
fi
if [[ ${#EXTRA_APPEND[@]} -gt 0 ]]; then
    APPEND+=" ${EXTRA_APPEND[*]}"
fi

QEMU_ARGS=(
    -m "$MEMORY"
    -smp "$SMP"
    -kernel "$TMPDIR/bzImage"
    -initrd "$TMPDIR/initrd.img"
    -append "$APPEND"
)

case "$DISK_BUS" in
    usb)
        QEMU_ARGS+=(
            -drive "file=$IMAGE,format=raw,if=none,id=rootdisk,cache=writeback,aio=threads"
            -device qemu-xhci
            -device usb-storage,drive=rootdisk
        )
        ;;
    virtio)
        QEMU_ARGS+=(
            -drive "file=$IMAGE,format=raw,if=virtio,cache=writeback,aio=threads"
        )
        ;;
    ide)
        QEMU_ARGS+=(
            -drive "file=$IMAGE,format=raw,if=ide,cache=writeback,aio=threads"
        )
        ;;
    *)
        echo "error: unsupported disk bus '$DISK_BUS' (expected usb, virtio, or ide)" >&2
        exit 1
        ;;
esac

if [[ "$SSH_PORT" != "none" ]]; then
    QEMU_ARGS+=(
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
        -device virtio-net-pci,netdev=net0
    )
else
    QEMU_ARGS+=(
        -netdev user,id=net0
        -device virtio-net-pci,netdev=net0
    )
fi

if [[ "$GUI" == false ]]; then
    QEMU_ARGS+=(-nographic)
else
    QEMU_ARGS+=(-device virtio-vga)
fi

if [[ "$USE_KVM" == true && -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ARGS+=(-enable-kvm -cpu host)
else
    QEMU_ARGS+=(-accel tcg -cpu max)
fi

QEMU_ARGS+=("${EXTRA_QEMU_ARGS[@]}")

echo "Kernel:    $(du -h "$TMPDIR/bzImage" | awk '{print $1}')"
echo "Initrd:    $(du -h "$TMPDIR/initrd.img" | awk '{print $1}')"
echo "Disk bus:  $DISK_BUS"
if [[ "$SSH_PORT" != "none" ]]; then
    echo "SSH fwd:   host tcp/${SSH_PORT} -> guest tcp/22"
else
    echo "SSH fwd:   disabled"
fi
echo "Append:    $APPEND"
echo

if [[ -n "$SMOKE_TIMEOUT" ]]; then
    if [[ -z "$LOG_FILE" ]]; then
        LOG_FILE="$TMPDIR/qemu.log"
    fi
    SUCCESS_RE='systemd[[][0-9]+[]]: systemd .* running in system mode|Reached target .*Multi-User|Started .*OpenSSH|Ubuntu .* ttyS0| login:'
    FAIL_RE='Kernel panic|not syncing|Unable to mount root|No working init found|ALERT!|Failed to start Switch Root|Timed out waiting for device'

    echo "Smoke test: waiting up to ${SMOKE_TIMEOUT}s for userspace/login"
    echo "Log:        $LOG_FILE"
    echo

    set +e
    timeout --foreground "${SMOKE_TIMEOUT}s" qemu-system-x86_64 "${QEMU_ARGS[@]}" 2>&1 \
        | tee "$LOG_FILE" \
        | awk -v success_re="$SUCCESS_RE" -v fail_re="$FAIL_RE" '
            { print; fflush(); }
            $0 ~ fail_re { found_failure=1; exit 2 }
            $0 ~ success_re { found_success=1; exit 0 }
            END {
                if (found_success) exit 0;
                if (found_failure) exit 2;
                exit 1;
            }'
    pipe_status=("${PIPESTATUS[@]}")
    qemu_rc=${pipe_status[0]}
    rc=${pipe_status[2]}
    set -e

    if [[ "$rc" -eq 0 ]]; then
        echo "Smoke result: PASS"
        exit 0
    elif [[ "$rc" -eq 2 ]]; then
        echo "Smoke result: FAIL (boot failure pattern found)" >&2
        exit 1
    elif [[ "$qemu_rc" -eq 124 ]]; then
        echo "Smoke result: FAIL (timeout before userspace/login)" >&2
        exit 1
    else
        echo "Smoke result: FAIL (QEMU exited before userspace/login)" >&2
        exit 1
    fi
fi

echo "Starting QEMU. Press Ctrl+A then X to quit when using -nographic."
exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
