#!/bin/bash
set -e

export DOCKER_DEFAULT_PLATFORM=linux/amd64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTRO="ubuntu2604"
KERNEL_SRC=""
CLEAN=false
IMG_SIZE=12000
KERNEL_ONLY=false
PATCHES_REF="kernel-7.0.10-e00c8a7"
MWIFIEX_REF="5cfd063449f27e2f8a7d17c814a3bb21c27aa903"

MULTI_DISTROS="ubuntu2604 debian13 arch alpine cachyos"

usage() {
    echo "Usage: $0 [--distro <distro>] [--kernel <path>] [--img-size <MB>] [--clean]"
    echo ""
    echo "Options:"
    echo "  --distro     Distribution to build: ubuntu2604, debian13, devuan-sway, artix-openrc, artix-runit, artix-hyprland-lightcrimson, arch, cachyos, miaos, alpine, all (default: ubuntu2604)"
    echo "  --kernel     Path to kernel source directory (default: auto-clone to work/linux/)"
    echo "  --img-size   Disk image size in MB (default: 12000, 32000 for --distro all)"
    echo "  --clean      Remove all cached build artifacts and start from scratch"
    echo "  --clean-only Remove all cached build artifacts and exit"
    echo "  --kernel-only  Build and package the kernel only, then exit"
    echo "  --patches-ref  Branch, tag, or commit SHA for patches (default: v1.0)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --distro)    DISTRO="$2";          shift 2 ;;
        --kernel)    KERNEL_SRC="$2";      shift 2 ;;
        --img-size)  IMG_SIZE="$2";        shift 2 ;;
        --clean)     CLEAN=true;           shift ;;
        --clean-only) CLEAN=true; CLEAN_EXIT=true; shift ;;
        --kernel-only) KERNEL_ONLY=true;   shift ;;
        --patches-ref) [ -n "$2" ] && PATCHES_REF="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
LINUX_DEFAULT_DIR="$SCRIPT_DIR/work/linux"

PATCHES_REPO="https://github.com/ps5-linux/ps5-linux-patches.git"
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"

if [ -z "$KERNEL_SRC" ]; then
    KERNEL_SRC="$LINUX_DEFAULT_DIR"
fi

KERNEL_OUT="$SCRIPT_DIR/linux-bin"
OUTPUT_DIR="$SCRIPT_DIR/output"
CHROOT_DIR="$SCRIPT_DIR/work/chroot"
CACHE_DIR="$SCRIPT_DIR/work/cache"
CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/ccache}"
LOG_FILE="$SCRIPT_DIR/build.log"
DOCKER_NAME="ps5-build-$$"



if [ "$DISTRO" = "all" ] && [ "$IMG_SIZE" = "12000" ]; then
    IMG_SIZE=32000
fi

# Bazzite assembles the OCI rootfs + an embedded /sysroot/ostree/repo/objects
# (deduplicated copy of the same content) + the linux-ps5 kernel — 12GB is
# not enough. Bump the default for any bazzite* target.
case "$DISTRO" in
    bazzite*)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=24000
        fi
        ;;
    # Batocera unsquashes to ~6GB; 12GB is tight once kernel + initrd +
    # /userdata defaults are added. Bump to 16GB.
    batocera*)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=16000
        fi
        ;;
    # Gaming image: Arch base + gamescope + Steam + lib32 stack. Steam is
    # ~2 GB and dual 32/64-bit Mesa/Vulkan adds another ~1 GB. Bump from
    # 12 -> 16 GB so there's headroom for a game.
    miaos*)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=16000
        fi
        ;;
    # Pre-riced Hyprland: Artix base + Hyprland stack + ML4W base
    # dotfiles + lightcrimson overlay + nerd fonts + GTK/Qt themes
    # add ~1.5 GB on top of the bare artix-runit footprint. Bump to
    # 16 GB so there's room left for user data.
    artix-hyprland-lightcrimson)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=16000
        fi
        ;;
esac

if [ -z "$FORMAT" ]; then
    case "$DISTRO" in
        arch|cachyos|miaos*|artix*) FORMAT="arch" ;;
        fedora*|bazzite*)        FORMAT="rpm" ;;
        all)                     FORMAT="all" ;;
        *)                       FORMAT="deb" ;;
    esac
fi

KERNEL_BUILDER_PLATFORM="linux/amd64"
case "$(uname -m)" in
    aarch64|arm64) KERNEL_BUILDER_PLATFORM="linux/arm64" ;;
esac

# --- Signal trap: clean up docker containers and background jobs on exit ---
BUILD_PID=""

cleanup() {
    trap - INT TERM EXIT
    echo ""
    echo "Cleaning up..."
    docker kill "$DOCKER_NAME" 2>/dev/null || true
    [ -n "$BUILD_PID" ] && kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# --- Clean ---
if [ "$CLEAN" = true ]; then
    echo "Cleaning all build artifacts..."
    for dir in "$SCRIPT_DIR/work" "$KERNEL_OUT" "$SCRIPT_DIR/cache" "$OUTPUT_DIR"; do
        [ -d "$dir" ] && docker run --rm \
            -v "$(dirname "$dir")":/parent \
            alpine rm -rf "/parent/$(basename "$dir")"
    done
    echo "Done."
    [ "$CLEAN_EXIT" = true ] && exit 0
    echo ""
fi

# --- Auto-detect what can be skipped ---
SKIP_KERNEL=false
SKIP_CHROOT=false

case "$FORMAT" in
    arch) ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    # rpm uses alien to convert from .deb — only the .deb needs to exist
    # to skip the kernel build; the alien step runs separately below.
    rpm)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    all)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && \
          ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    *)    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
esac

if [ "$DISTRO" = "all" ]; then
    SKIP_CHROOT=true
    for d in $MULTI_DISTROS; do
        [ -d "$SCRIPT_DIR/work/chroot-$d/bin" ] || SKIP_CHROOT=false
    done
else
    [ -d "$CHROOT_DIR/bin" ] && SKIP_CHROOT=true
fi

# --- Build plan summary ---
echo ""
echo "PS5 Linux Image Builder"
echo "======================="
if [ "$KERNEL_ONLY" = true ]; then
    echo "  Mode:         kernel only"
    echo "  Format:       $FORMAT"
else
    echo "  Distro:       $DISTRO"
    [ "$DISTRO" = "all" ] && echo "                ($MULTI_DISTROS)"
    echo "  Image size:   ${IMG_SIZE}MB"
fi
if [ -f "$PATCHES_DIR/.config" ]; then
    LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"
    echo "  Kernel:       $LINUX_BRANCH"
else
    echo "  Kernel:       (will fetch)"
fi
echo "  Kernel src:   $KERNEL_SRC"
echo ""
echo "Stages:"
if [ "$SKIP_KERNEL" = true ]; then
    echo "  1. Kernel            cached"
elif [ -d "$KERNEL_SRC/.git" ]; then
    echo "  1. Kernel            build (source cached)"
else
    echo "  1. Kernel            clone + build"
fi
if [ "$KERNEL_ONLY" = false ]; then
    if [ "$SKIP_CHROOT" = true ]; then
        echo "  2. Root filesystem   cached"
    else
        echo "  2. Root filesystem   build"
    fi
    echo "  3. Disk image        build"
fi
echo ""
echo "Logs: $LOG_FILE"
echo ""

# --- Logging + stage runner ---
: > "$LOG_FILE"

SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

run_stage() {
    local name="$1"
    shift

    if [ "${CI:-}" = "true" ]; then
        echo "::group::$name"
        local rc=0
        "$@" || rc=$?
        echo "::endgroup::"
        if [ $rc -ne 0 ]; then
            echo "::error::Build failed at: $name"
            exit $rc
        fi
        return
    fi

    local status_msg="$name"
    local spin_i=0

    # Record log position so we only scan new lines for status updates
    local log_start
    log_start=$(wc -l < "$LOG_FILE")

    # Run command in background
    "$@" >> "$LOG_FILE" 2>&1 &
    BUILD_PID=$!

    # Spinner loop — pick up === status lines from the log
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        if (( spin_i % 10 == 0 )); then
            local new
            new=$(tail -n +$((log_start + 1)) "$LOG_FILE" 2>/dev/null \
                | grep -oP '(?<=^=== ).*(?= ===$)' | tail -1)
            [ -n "$new" ] && status_msg="$new"
        fi
        printf "\r  %s %-60s" "${SPIN_CHARS:spin_i%${#SPIN_CHARS}:1}" "$status_msg"
        spin_i=$((spin_i + 1))
        sleep 0.1
    done

    local rc=0
    wait "$BUILD_PID" || rc=$?
    BUILD_PID=""

    if [ $rc -eq 0 ]; then
        printf "\r  ✓ %-60s\n" "$name"
    else
        printf "\r  ✗ %-60s\n" "$status_msg"
        echo ""
        echo "Build failed at: $status_msg"
        echo "Logs: $LOG_FILE"
        echo "Try running with --clean to start fresh."
        exit 1
    fi
}

# --- Setup directories ---
mkdir -p "$KERNEL_OUT" "$OUTPUT_DIR" "$CHROOT_DIR" "$CACHE_DIR" "$CCACHE_DIR"
if [ "$DISTRO" = "all" ]; then
    for d in $MULTI_DISTROS; do
        mkdir -p "$SCRIPT_DIR/work/chroot-$d"
    done
fi

# --- Step 1: Kernel ---
# When work/linux is a symlink to a shared persistent cache (as the CI
# workflow sets up), multiple distro builds running in parallel on the
# same host all race to clone/patch/mv that shared dir. Wrap the kernel
# source + build stages in a flock so only one builds at a time; the
# others wait, then re-check SKIP_KERNEL (now true because kernel-out
# is populated by the winner) and fall straight through to image-build.
#
# Lock on the RESOLVED kernel-out path so symlinked per-task workspaces
# all serialize on the same lock file. Without readlink -f the lock
# file would live inside each task's workspace and serialize nothing.
KERNEL_LOCK="$(readlink -f "$KERNEL_OUT" 2>/dev/null || echo "$KERNEL_OUT").lock"
mkdir -p "$(dirname "$KERNEL_LOCK")"
exec 9>"$KERNEL_LOCK"
echo "  acquiring kernel-build lock: $KERNEL_LOCK"
flock 9
echo "  acquired"

# Re-evaluate SKIP_KERNEL inside the lock: if another task built the
# kernel while we were waiting, kernel-out is now populated and we
# should skip our own build.
case "$FORMAT" in
    arch) ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    rpm)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    all)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && \
          ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    *)    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
esac

if [ "$SKIP_KERNEL" = true ]; then
    printf "  ✓ %-60s\n" "Kernel packages (cached)"
else
    if [ ! -d "$KERNEL_SRC/.git" ]; then
        REPO_URL="$PATCHES_REPO"
        [ -n "$PATCHES_TOKEN" ] && REPO_URL="${PATCHES_REPO/https:\/\//https:\/\/${PATCHES_TOKEN}@}"


        mkdir -p "$PATCHES_DIR"
        run_stage "Fetch ps5-linux-patches ($PATCHES_REF)" bash -c '
            cd "'"$PATCHES_DIR"'"
            [ ! -d .git ] && git init && git remote add origin "'"$REPO_URL"'"
            git fetch --depth 1 origin "'"$PATCHES_REF"'" || git fetch origin "'"$PATCHES_REF"'"
            git reset --hard FETCH_HEAD
        '
        LINUX_TMP_DIR="${LINUX_DEFAULT_DIR}.tmp"
        for dir in "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"; do
            [ -d "$dir" ] && docker run --rm \
                -v "$(dirname "$dir")":/parent \
                alpine rm -rf "/parent/$(basename "$dir")"
        done
        LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"

        run_stage "Clone kernel $LINUX_BRANCH" \
            git clone --branch "$LINUX_BRANCH" --depth 1 "$LINUX_REPO" "$LINUX_TMP_DIR"

        run_stage "Apply patches" bash -c '
            set -e; shopt -s nullglob
            patches=("'"$PATCHES_DIR"'"/*.patch)
            [ ${#patches[@]} -eq 0 ] && { echo "No .patch files found in '"$PATCHES_DIR"'"; exit 1; }
            for p in "${patches[@]}"; do
                echo "Applying $p"
                # --recount makes git ignore hunk-header line numbers and
                # recount from content. Lets us land patches whose first
                # hunk grew without manually fixing every later @@ offset.
                git -C "'"$LINUX_TMP_DIR"'" apply --recount --exclude=Makefile "$p"
            done'

        run_stage "Copy kernel config" \
            cp "$PATCHES_DIR/.config" "$LINUX_TMP_DIR/.config"

        # Make sure the destination is gone before we rename into it. If
        # $LINUX_DEFAULT_DIR still exists (stale state from a previous run,
        # interrupted task, or a runner that reused this workspace), a
        # plain `mv linux.tmp linux` moves the source INTO linux/, and if
        # linux/linux.tmp also exists from an earlier partial run it errors
        # with "cannot overwrite linux/linux.tmp: Directory not empty".
        # The docker-alpine-rm guard at the top of this block only fires
        # when the dir exists at script start; this catches the case where
        # the dir reappears mid-run (cache mount races, prior task leftover).
        [ -e "$LINUX_DEFAULT_DIR" ] && rm -rf "$LINUX_DEFAULT_DIR"
        mv "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"
        KERNEL_SRC="$LINUX_DEFAULT_DIR"
    else
        printf "  ✓ %-60s\n" "Kernel source (cached)"
    fi

    KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd)"

    # Wipe ONLY the format we're about to rebuild. Wiping every format
    # (which the older code did) races against parallel matrix jobs on the
    # same runner: e.g. an arch build would delete .deb artifacts that a
    # concurrent ubuntu image-build is mid-way through using, surfacing as
    # `cp /kernel-debs/*.deb: No such file or directory` in the loser.
    case "$FORMAT" in
        deb)  rm -f "$KERNEL_OUT"/*.deb ;;
        rpm)  rm -f "$KERNEL_OUT"/*.deb "$KERNEL_OUT"/*.rpm ;;
        arch) rm -f "$KERNEL_OUT"/*.pkg.tar.zst ;;
        all)  rm -f "$KERNEL_OUT"/*.deb "$KERNEL_OUT"/*.rpm "$KERNEL_OUT"/*.pkg.tar.zst ;;
    esac

    run_stage "Build kernel builder image" \
        docker build --platform "$KERNEL_BUILDER_PLATFORM" -t ps5-kernel-builder \
            -f "$SCRIPT_DIR/docker/kernel-builder/Dockerfile" "$SCRIPT_DIR"

    run_stage "Compile kernel" \
        docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
            -e MWIFIEX_REF="$MWIFIEX_REF" \
            -v "$KERNEL_SRC":/src \
            -v "$KERNEL_OUT":/out \
            -v "$CCACHE_DIR":/ccache \
            ps5-kernel-builder

    ls "$KERNEL_OUT/staging/lib/modules/" | head -1 > "$KERNEL_OUT/VERSION"

    case "$FORMAT" in deb|rpm|all)
        # RPM is built from the .deb via alien — so deb is always built first.
        run_stage "Package kernel (.deb)" \
            docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
                -v "$KERNEL_SRC":/src \
                -v "$KERNEL_OUT":/out \
                -v "$CCACHE_DIR":/ccache \
                ps5-kernel-builder \
                /package-deb.sh
    esac

    case "$FORMAT" in rpm|all)
        run_stage "Package kernel (.rpm)" \
            docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-builder \
                /package-rpm.sh
    esac

    case "$FORMAT" in arch|all)
        run_stage "Build arch packager image" \
            docker build -t ps5-kernel-packager-arch \
                -f "$SCRIPT_DIR/docker/kernel-builder-arch/Dockerfile" "$SCRIPT_DIR"
        run_stage "Package kernel (.pkg.tar.zst)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-packager-arch
    esac
fi

# Alien .deb -> .rpm runs OUTSIDE the SKIP_KERNEL block: even when the kernel
# build was skipped, the persistent cache may only have the .deb (e.g. last
# build was for a deb-based distro), and the next distro needs the .rpm.
case "$FORMAT" in
    rpm|all)
        # Two parallel builds (capacity > 1 on the runner) might both find the
        # .rpm missing and race the alien conversion. Serialize via flock and
        # re-check inside the lock so the loser just no-ops.
        if ! ls "$KERNEL_OUT"/*.rpm 1>/dev/null 2>&1; then
            run_stage "Convert kernel .deb -> .rpm (alien)" \
                flock "$KERNEL_OUT/.alien.lock" sh -c "
                    if ! ls \"$KERNEL_OUT\"/*.rpm 1>/dev/null 2>&1; then
                        docker run --rm --platform \"$KERNEL_BUILDER_PLATFORM\" --name \"$DOCKER_NAME\" \
                            -v \"$KERNEL_OUT\":/out \
                            ps5-kernel-builder \
                            /package-rpm.sh
                    fi
                "
        fi
        ;;
esac

if [ "$KERNEL_ONLY" = true ]; then
    KVER=$(cat "$KERNEL_OUT/VERSION" 2>/dev/null || echo "unknown")
    echo ""
    echo "Done! Kernel $KVER packages in $KERNEL_OUT/"
    exit 0
fi

# Release the kernel-build lock: from here on each task does its own
# image build (chroot, image-builder docker) on per-task paths, so
# parallel tasks can resume.
exec 9>&-

# --- Step 2: Build distribution image ---
run_stage "Build image builder image" \
    docker build -t ps5-image-builder -f "$SCRIPT_DIR/docker/image-builder/Dockerfile" "$SCRIPT_DIR"

if [ "$DISTRO" = "all" ]; then
    DOCKER_ARGS=(
        docker run --rm --privileged --name "$DOCKER_NAME"
        --entrypoint /entrypoint-multi.sh
        -v "$SCRIPT_DIR":/repo:ro
        -v "$KERNEL_OUT":/kernel-debs:ro
        -v "$OUTPUT_DIR":/output
        -v "$CACHE_DIR":/build/cache
        -e IMG_SIZE="$IMG_SIZE"
        -e SKIP_CHROOT="$SKIP_CHROOT"
        -e "DISTROS=$MULTI_DISTROS"
    )
    for d in $MULTI_DISTROS; do
        DOCKER_ARGS+=(-v "$SCRIPT_DIR/work/chroot-$d:/build/chroot-$d")
    done
    DOCKER_ARGS+=(ps5-image-builder)

    run_stage "Build multi-distro image (${IMG_SIZE}MB)" "${DOCKER_ARGS[@]}"

    IMG_PATH="$OUTPUT_DIR/ps5-multi.img"
else
    run_stage "Build $DISTRO image (${IMG_SIZE}MB)" \
        docker run --rm --privileged --name "$DOCKER_NAME" \
            -v "$SCRIPT_DIR":/repo:ro \
            -v "$KERNEL_OUT":/kernel-debs:ro \
            -v "$OUTPUT_DIR":/output \
            -v "$CHROOT_DIR":/build/chroot \
            -v "$CACHE_DIR":/build/cache \
            -e DISTRO="$DISTRO" \
            -e IMG_SIZE="$IMG_SIZE" \
            -e SKIP_CHROOT="$SKIP_CHROOT" \
            ps5-image-builder

    IMG_PATH="$OUTPUT_DIR/ps5-${DISTRO}.img"
fi

echo ""
echo "Done! Image: $IMG_PATH"
echo "Flash: sudo dd if=$IMG_PATH of=/dev/sdX bs=4M status=progress"
