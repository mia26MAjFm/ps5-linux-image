#!/usr/bin/env bash

# PS5 Image Validator & Comparison Tool
# Usage: ./check_image.sh <image> [baseline_image]

# If one image is provided: Checks for completeness and bootability.
# If two images are provided: Compares the second (new) against the first (original).

TARGET="$1"
[ -n "$TARGET" ] && [ ! -f "$TARGET" ] && [ -f "output/$TARGET" ] && TARGET="output/$TARGET"

BASELINE="$2"
[ -n "$BASELINE" ] && [ ! -f "$BASELINE" ] && [ -f "output/$BASELINE" ] && BASELINE="output/$BASELINE"

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <image_to_check> [baseline_image]"
    exit 1
fi

if [[ ! -f "$TARGET" ]]; then
    echo "Error: Image file '$TARGET' does not exist."
    exit 1
fi

MODE="check"
if [[ -n "$BASELINE" ]]; then
    if [[ ! -f "$BASELINE" ]]; then
        echo "Error: Baseline image '$BASELINE' does not exist."
        exit 1
    fi
    MODE="compare"
    # In compare mode, TARGET is the 'original' and BASELINE is the 'new' to match original script behavior
    ORIG="$TARGET"
    NEW="$BASELINE"
else
    NEW="$TARGET"
fi

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BOLD}=================================================================${NC}"
if [[ "$MODE" == "compare" ]]; then
    echo -e "${BOLD} PS5 IMAGE COMPARISON REPORT ${NC}"
else
    echo -e "${BOLD} PS5 IMAGE VALIDATION REPORT ${NC}"
fi
echo -e "${BOLD}=================================================================${NC}"
[[ "$MODE" == "compare" ]] && echo "Original:  $ORIG"
echo "Target:    $NEW"
echo "Date:      $(date)"
echo -e "${BOLD}=================================================================${NC}"

# Function to get partition info
get_part_info() {
    local img="$1"
    local type="$2" # "EFI System" or "Linux filesystem"
    fdisk -l "$img" | grep "$type" | head -n 1 | awk '{print $2}'
}

get_part_layout() {
    local img="$1"
    fdisk -l "$img" | awk '
        /^Device[[:space:]]+Start[[:space:]]+End/ { in_parts=1; next }
        in_parts && NF >= 6 {
            type=$6
            for (i = 7; i <= NF; i++) type = type " " $i
            print $2, $3, $4, $5, type
        }' | sort -n
}

efi_file_size() {
    local img="$1"
    local offset="$2"
    local file="$3"
    local tmpdir dest
    tmpdir="$(mktemp -d)"
    dest="$tmpdir/$file"
    if mcopy -o -i "$img@@$offset" "::$file" "$dest" 2>/dev/null; then
        stat -c '%s' "$dest"
    fi
    rm -rf "$tmpdir"
}

# --- 1. Partition Table Analysis ---
echo -e "${BOLD}[1] Partition Table Analysis${NC}"
if [[ "$MODE" == "compare" ]]; then
    ORIG_FDISK=$(get_part_layout "$ORIG")
    NEW_FDISK=$(get_part_layout "$NEW")

    if [[ "$ORIG_FDISK" == "$NEW_FDISK" ]]; then
        echo -e "  [${GREEN}PASS${NC}] Partition layouts match exactly."
    else
        echo -e "  [${YELLOW}WARN${NC}] Partition layouts differ!"
    fi
fi

EFI_START_NEW=$(get_part_info "$NEW" "EFI System")
ROOT_START_NEW=$(get_part_info "$NEW" "Linux filesystem")

if [[ -z "$EFI_START_NEW" ]]; then
    echo -e "  [${RED}FAIL${NC}] No EFI partition found in target image."
else
    echo -e "  [${GREEN}PASS${NC}] EFI partition found at sector $EFI_START_NEW."
fi

if [[ -z "$ROOT_START_NEW" ]]; then
    echo -e "  [${RED}FAIL${NC}] No Linux Root partition found in target image."
else
    echo -e "  [${GREEN}PASS${NC}] Root partition found at sector $ROOT_START_NEW."
fi

# Extract Offsets
EFI_OFFSET_NEW=$((EFI_START_NEW * 512))
ROOT_OFFSET_NEW=$((ROOT_START_NEW * 512))

echo ""
echo -e "${BOLD}[2] EFI Partition (Bootability) Analysis${NC}"
echo "  Target Offset: $EFI_OFFSET_NEW bytes"

# Check for essential boot files
REQUIRED_FILES=("bzImage" "initrd.img" "kexec.sh")
MISSING_FILES=()

# Get file list from target image
MDIR_OUTPUT=$(mdir -i "$NEW@@$EFI_OFFSET_NEW" -/ 2>/dev/null)

if [[ -z "$MDIR_OUTPUT" ]]; then
    echo -e "  [${RED}FAIL${NC}] Could not read EFI partition. Is it formatted correctly?"
    MISSING_FILES=("${REQUIRED_FILES[@]}")
else
    for file in "${REQUIRED_FILES[@]}"; do
        FILE_BASE="${file%.*}"
        FILE_EXT="${file##*.}"
        # Match case-insensitive and handle FAT 8.3 space padding
        if ! echo "$MDIR_OUTPUT" | grep -qiE "($file|$FILE_BASE\s+$FILE_EXT)"; then
            MISSING_FILES+=("$file")
        fi
    done

    if [ ${#MISSING_FILES[@]} -eq 0 ]; then
        echo -e "  [${GREEN}PASS${NC}] Essential boot files found: ${REQUIRED_FILES[*]}"
    else
        echo -e "  [${RED}FAIL${NC}] Missing essential boot files: ${RED}${MISSING_FILES[*]}${NC}"
    fi
fi

# Comparison of bzImage if in compare mode
if [[ "$MODE" == "compare" ]]; then
    EFI_START_ORIG=$(get_part_info "$ORIG" "EFI System")
    EFI_OFFSET_ORIG=$((EFI_START_ORIG * 512))
    ORIG_SIZE_BZ=$(efi_file_size "$ORIG" "$EFI_OFFSET_ORIG" "bzImage")
    NEW_SIZE_BZ=$(efi_file_size "$NEW" "$EFI_OFFSET_NEW" "bzImage")
    if [[ -n "$NEW_SIZE_BZ" && -n "$ORIG_SIZE_BZ" ]]; then
        echo "  bzImage size comparison: Orig($ORIG_SIZE_BZ) vs New($NEW_SIZE_BZ)"
    fi
fi

echo ""
echo -e "${BOLD}[3] Root Filesystem (Completeness) Analysis${NC}"
echo "  Target Offset: $ROOT_OFFSET_NEW bytes"

get_root_usage() {
    local img="$1"
    local start="$2"
    local tmp_sb=".${img##*/}_sb.bin"
    dd if="$img" bs=512 skip="$start" count=128 2>/dev/null > "$tmp_sb"
    local blocks_free=$(dumpe2fs -h "$tmp_sb" 2>/dev/null | grep "Free blocks:" | awk '{print $3}')
    local blocks_total=$(dumpe2fs -h "$tmp_sb" 2>/dev/null | grep "Block count:" | awk '{print $3}')
    rm -f "$tmp_sb"
    if [[ -z "$blocks_total" || -z "$blocks_free" ]]; then
        echo "0"
        return
    fi
    echo $(( (blocks_total - blocks_free) * 4096 / 1024 / 1024 ))
}

MB_USED_NEW=$(get_root_usage "$NEW" "$ROOT_START_NEW")

if [[ "$MODE" == "compare" ]]; then
    ROOT_START_ORIG=$(get_part_info "$ORIG" "Linux filesystem")
    MB_USED_ORIG=$(get_root_usage "$ORIG" "$ROOT_START_ORIG")
    echo "  Root Partition Disk Usage:"
    echo "    Original: $MB_USED_ORIG MB used"
    echo "    Target:   $MB_USED_NEW MB used"

    # Tolerance check: If new is < 80% of original, it's suspicious
    THRESHOLD=$((MB_USED_ORIG * 80 / 100))
    if [ "$MB_USED_NEW" -lt "$THRESHOLD" ]; then
        echo -e "  [${RED}FAIL${NC}] Target build is significantly smaller than original ($MB_USED_NEW MB vs $MB_USED_ORIG MB)."
    else
        echo -e "  [${GREEN}PASS${NC}] Root partition payload size seems reasonable compared to original."
    fi
else
    echo "  Root Partition Disk Usage: $MB_USED_NEW MB used"
    # Basic sanity check for standalone: should have at least 100MB of data? 
    # Or just check if it's > 0.
    if [ "$MB_USED_NEW" -gt 50 ]; then
        echo -e "  [${GREEN}PASS${NC}] Root partition contains data ($MB_USED_NEW MB)."
    else
        echo -e "  [${YELLOW}WARN${NC}] Root partition is very small ($MB_USED_NEW MB). Is this expected?"
    fi
fi

echo ""
echo -e "${BOLD}=================================================================${NC}"
echo -e "${BOLD} VERDICT ${NC}"
echo -e "${BOLD}=================================================================${NC}"

FAILED=0
if [ ${#MISSING_FILES[@]} -gt 0 ]; then FAILED=1; fi
if [[ "$MODE" == "compare" ]] && [ "$MB_USED_NEW" -lt "$THRESHOLD" ]; then FAILED=1; fi
if [[ "$MODE" == "check" ]] && [ "$MB_USED_NEW" -lt 5 ]; then FAILED=1; fi
if [[ -z "$EFI_START_NEW" || -z "$ROOT_START_NEW" ]]; then FAILED=1; fi

if [ "$FAILED" -eq 1 ]; then
    echo -e " [${RED}!!!${NC}] ${RED}${BOLD}RESULT: INCOMPLETE OR NON-BOOTABLE.${NC}"
    echo " The image is missing essential components or data."
else
    echo -e " [${GREEN}OK${NC}] ${GREEN}${BOLD}RESULT: LOOKS GOOD.${NC}"
    if [[ "$MODE" == "compare" ]]; then
        echo " The new build is suitable for testing and comparable to original."
    else
        echo " The image contains essential boot files and root filesystem data."
    fi
fi
echo -e "${BOLD}=================================================================${NC}"
