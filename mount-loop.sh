#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# pkexec does *not* reliably preserve the caller's working directory.
# When we re-exec via pkexec/sudo we pass the original PWD via NW_ORIG_PWD
# and restore it here so relative paths continue to work.
if [ -n "${NW_ORIG_PWD-}" ] && [ -d "${NW_ORIG_PWD}" ]; then
    cd "${NW_ORIG_PWD}" || true
fi

log_info() { printf '[+] %s\n' "$*"; }
log_warn() { printf '[!] %s\n' "$*" >&2; }
log_err()  { printf '[x] %s\n' "$*" >&2; }

die() { log_err "$*"; exit 1; }

ensure_root() {
    # Only escalate when we are about to execute an operation that actually requires privileges.
    if [ "${EUID}" -eq 0 ]; then
        return 0
    fi

    # Resolve script path as robustly as possible (helps when invoked via relative paths).
    local SELF="$0"
    if [[ "$SELF" != */* ]]; then
        SELF=$(command -v -- "$SELF" 2>/dev/null || echo "$SELF")
    fi
    if command -v realpath >/dev/null 2>&1; then
        SELF=$(realpath -- "$SELF" 2>/dev/null || echo "$SELF")
    elif command -v readlink >/dev/null 2>&1; then
        SELF=$(readlink -f -- "$SELF" 2>/dev/null || echo "$SELF")
    fi

    if command -v pkexec >/dev/null 2>&1; then
        # Preserve current working directory across pkexec.
        exec pkexec /usr/bin/env NW_ORIG_PWD="$PWD" "$SELF" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        # sudo usually preserves PWD, but we do this for consistency.
        exec sudo /usr/bin/env NW_ORIG_PWD="$PWD" "$SELF" "$@"
    else
        die "This script requires elevated privileges, but neither pkexec nor sudo is available."
    fi
}

# Function to display help message
show_help() {
    echo "Usage: $0 [OPTION]... [FILE]"
    echo "Set up loop devices for a given file, create new files of specified or random size, or create a ramdisk of specified size."
    echo ""
    echo "  --help                     display this help and exit"
    echo "  automount <Size>           automatically create a file of specified size in /tmp and set it up as a loop device."
    echo "  automountfs <Size>         same as automount but also create a filesystem and mount it."
    echo "  faultymount <Size> <BlockNumbers>      create a loop device with specified faulty blocks."
    echo "  faultymountfs <Size> <BlockNumbers>    same as faultymount but also create a filesystem and mount it."
    echo "  polymount <N> <Size>       create N files in /tmp of specified size and set them up as loop devices."
    echo "  polymountfs <N> <Size>     same as polymount but also create filesystems and mount them."
    echo "  polymount rand <N> <MinSize> <MaxSize>          create N files with random sizes in /tmp."
    echo "  polymountfs rand <N> <MinSize> <MaxSize>        same as above but also create filesystems and mount them."
    echo "  custompolymount <BaseDir> <N> <Size>            like polymount, but create files under BaseDir instead of /tmp."
    echo "  custompolymountfs <BaseDir> <N> <Size>          same as above but with filesystems and mounts."
    echo "  custompolymount rand <BaseDir> <N> <MinSize> <MaxSize>   random sizes, base directory configurable."
    echo "  custompolymountfs rand <BaseDir> <N> <MinSize> <MaxSize> same as above but with filesystems and mounts."
    echo "  custommount / custommountfs                     aliases for custompolymount / custompolymountfs."
    echo "  tmpfsmount <Size>          create a ramdisk of specified size as a loop device."
    echo "  tmpfsmountfs <Size>        same as tmpfsmount but also create a filesystem and mount it."
    echo "  tmpfspolymount <N> <Size>   create N tmpfs-backed files of specified size and set them up as loop devices."
    echo "  tmpfspolymountfs <N> <Size> same as tmpfspolymount but also create filesystems and mount them."
    echo "  tmpfspolymount rand <N> <MinSize> <MaxSize>   like polymount rand, but using a shared tmpfs as backing store."
    echo "  tmpfspolymountfs rand <N> <MinSize> <MaxSize> same as above but with filesystems and mounts."
    echo "  <FilePath>                 path to the existing file to set up as a loop device"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/your/file.img                 Set up an existing file as a loop device."
    echo "  $0 automount 1G                           Create a 1G-sized file in /tmp and set it up as a loop device."
    echo "  $0 automountfs 1G                         Same as above but also create a filesystem and mount it."
    echo "  $0 polymount 5 1G                         Create 5 1G-sized files in /tmp and set them up as loop devices."
    echo "  $0 custompolymount /workspace 5 1G        Same as polymount, but images under /workspace."
    echo "  $0 tmpfsmount 1G                          Create a 1G ramdisk and set it up as a loop device."
    echo "  $0 tmpfsmountfs 1G                        Same as above but also create a filesystem and mount it."
    echo ""
    echo "Note: This script requires elevated permissions. It will attempt to use pkexec or sudo."
}

require_cmds() {
    local missing=0
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            log_err "Missing required command: $c"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 1
}

# Convert size specification to bytes
convert_size_to_bytes() {
    local SIZE=$1
    local UNIT
    local NUMBER
    UNIT=$(echo "$SIZE" | sed -E 's/[0-9\.]+//g' | tr '[:lower:]' '[:upper:]')
    NUMBER=$(echo "$SIZE" | sed -E 's/[^0-9\.]//g')

    if [ -z "$NUMBER" ]; then
        die "Invalid size value: $SIZE"
    fi

    case "$UNIT" in
        G|GB)
            BYTE_SIZE=$(awk "BEGIN {printf \"%.0f\", $NUMBER * 1024 * 1024 * 1024}")
            ;;
        M|MB)
            BYTE_SIZE=$(awk "BEGIN {printf \"%.0f\", $NUMBER * 1024 * 1024}")
            ;;
        K|KB)
            BYTE_SIZE=$(awk "BEGIN {printf \"%.0f\", $NUMBER * 1024}")
            ;;
        '')
            BYTE_SIZE=$(awk "BEGIN {printf \"%.0f\", $NUMBER}")
            ;;
        *)
            die "Unknown size unit: $UNIT"
            ;;
    esac

    echo "$BYTE_SIZE"
}

# Generate a random size within specified range
generate_random_size() {
    local MIN_SIZE_BYTES=$1
    local MAX_SIZE_BYTES=$2
    local RANGE=$((MAX_SIZE_BYTES - MIN_SIZE_BYTES + 1))

    if [ "$RANGE" -le 0 ]; then
        die "Invalid size range."
    fi

    # Seed once per invocation; good enough for sizes.
    local RANDOM_BYTES
    RANDOM_BYTES=$(awk -v min="$MIN_SIZE_BYTES" -v range="$RANGE" 'BEGIN{srand(); print int(min+rand()*range)}')
    echo "$RANDOM_BYTES"
}

# Function to set up the loop device (optionally create filesystem and mount)
setup_loop_device() {
    local FILEPATH="$1"
    local CREATE_FS="$2"
    local LOOPDEVICE
    local MOUNTPOINT

    LOOPDEVICE=$(losetup -fP --show "$FILEPATH") || die "Error creating the loop device."
    log_info "Loop device set up: $LOOPDEVICE"

    if [ "$CREATE_FS" = true ]; then
        # Create a filesystem on the loop device
        if ! mkfs.ext4 -q "$LOOPDEVICE" >/dev/null 2>&1; then
            losetup -d "$LOOPDEVICE" || true
            die "Failed to create filesystem on $LOOPDEVICE"
        fi

        # Create a temporary mount point
        MOUNTPOINT=$(mktemp -d)

        # Mount the loop device
        if ! mount "$LOOPDEVICE" "$MOUNTPOINT"; then
            losetup -d "$LOOPDEVICE" || true
            rmdir "$MOUNTPOINT" || true
            die "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
        fi
        log_info "Loop device mounted at $MOUNTPOINT"

        echo "Press [Enter] to unmount and detach the loop device."
        read -r

        # Unmount and clean up
        umount "$MOUNTPOINT" || true
        rmdir "$MOUNTPOINT" || true
    else
        echo "Press [Enter] to detach the loop device."
        read -r
    fi

    cleanup "$LOOPDEVICE" "$FILEPATH"
}

# Function for cleanup: detaching the loop device, and deleting the file
cleanup() {
    local LOOPDEVICE=$1
    local FILEPATH=$2

    losetup -d "$LOOPDEVICE" || true
    log_info "Loop device detached: $LOOPDEVICE"

    if [[ "$FILEPATH" == /tmp/*.img ]]; then
        rm -f "$FILEPATH" || true
        log_info "Temporary file deleted: $FILEPATH"
    fi
}

# Function to automatically create a file of a specified size and set up as a loop device
automount() {
    local GUID
    local FILENAME
    local FILEPATH
    local FILESIZE=$1
    local CREATE_FS=$2

    local BYTE_SIZE
    GUID=$(uuidgen)
    FILENAME="${GUID}.img"
    FILEPATH="/tmp/${FILENAME}"
    BYTE_SIZE=$(convert_size_to_bytes "$FILESIZE")

    if ! dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek="$BYTE_SIZE" status=none; then
        die "Failed to create file $FILEPATH"
    fi

    setup_loop_device "$FILEPATH" "$CREATE_FS"
}

# Function to create a ramdisk as a loop device (optionally create filesystem and mount)
tmpfsmount() {
    local RAMDISK_SIZE=$1
    local CREATE_FS=$2

    local BYTE_SIZE
    local TMPDIR
    local FILEPATH
    BYTE_SIZE=$(convert_size_to_bytes "$RAMDISK_SIZE")

    TMPDIR=$(mktemp -d)
    if [ ! -d "$TMPDIR" ]; then
        die "Failed to create temporary directory."
    fi

    if ! mount -t tmpfs -o "size=${BYTE_SIZE}" tmpfs "$TMPDIR"; then
        rmdir "$TMPDIR" || true
        die "Failed to mount tmpfs at $TMPDIR"
    fi
    log_info "Ramdisk mounted at $TMPDIR"

    FILEPATH="${TMPDIR}/ramdisk.img"

    if ! dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek="$BYTE_SIZE" status=none; then
        umount "$TMPDIR" || true
        rmdir "$TMPDIR" || true
        die "Failed to create file $FILEPATH"
    fi

    setup_loop_device "$FILEPATH" "$CREATE_FS"

    # Clean up ramdisk
    umount "$TMPDIR" || true
    rmdir "$TMPDIR" || true
    log_info "Ramdisk unmounted and cleaned up."
}

# Create loop devices with files of specified or random sizes (optionally create filesystem and mount)
polymount() {
    local CREATE_FS=$1
    shift

    if [ "$1" == "rand" ]; then
        if [ "$#" -ne 4 ]; then
            die "Usage: $0 polymount rand <N> <MinSize> <MaxSize>"
        fi
        local N=$2
        local MIN_SIZE_BYTES
        local MAX_SIZE_BYTES
        MIN_SIZE_BYTES=$(convert_size_to_bytes "$3")
        MAX_SIZE_BYTES=$(convert_size_to_bytes "$4")
    else
        if [ "$#" -ne 2 ]; then
            die "Usage: $0 polymount <N> <Size>"
        fi
        local N=$1
        local SIZE_BYTES
        SIZE_BYTES=$(convert_size_to_bytes "$2")
    fi

    declare -a LOOPDEVICES=()
    declare -a FILEPATHS=()
    declare -a MOUNTPOINTS=()

    for ((i=1; i<=N; i++)); do
        local BYTE_SIZE
        if [ "$1" == "rand" ]; then
            BYTE_SIZE=$(generate_random_size "$MIN_SIZE_BYTES" "$MAX_SIZE_BYTES")
        else
            BYTE_SIZE="$SIZE_BYTES"
        fi

        local GUID
        local FILENAME
        local FILEPATH
        local LOOPDEVICE
        GUID=$(uuidgen)
        FILENAME="${GUID}.img"
        FILEPATH="/tmp/${FILENAME}"

        if ! dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek="$BYTE_SIZE" status=none; then
            log_err "Failed to create file $FILEPATH"
            continue
        fi

        LOOPDEVICE=$(losetup -fP --show "$FILEPATH") || {
            log_err "Error creating loop device for $FILEPATH."
            rm -f "$FILEPATH" || true
            continue
        }
        log_info "Loop device set up: $LOOPDEVICE"

        if [ "$CREATE_FS" = true ]; then
            if ! mkfs.ext4 -q "$LOOPDEVICE" >/dev/null 2>&1; then
                log_err "Failed to create filesystem on $LOOPDEVICE"
                losetup -d "$LOOPDEVICE" || true
                rm -f "$FILEPATH" || true
                continue
            fi

            local MOUNTPOINT
            MOUNTPOINT=$(mktemp -d)
            if ! mount "$LOOPDEVICE" "$MOUNTPOINT"; then
                log_err "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
                losetup -d "$LOOPDEVICE" || true
                rm -f "$FILEPATH" || true
                rmdir "$MOUNTPOINT" || true
                continue
            fi
            log_info "Loop device mounted at $MOUNTPOINT"
            MOUNTPOINTS+=("$MOUNTPOINT")
        else
            MOUNTPOINTS+=("")
        fi

        LOOPDEVICES+=("$LOOPDEVICE")
        FILEPATHS+=("$FILEPATH")
    done

    echo "All loop devices set up. Press [Enter] to detach all loop devices."
    read -r

    for i in "${!LOOPDEVICES[@]}"; do
        if [ "$CREATE_FS" = true ] && [ -n "${MOUNTPOINTS[$i]}" ]; then
            umount "${MOUNTPOINTS[$i]}" || true
            rmdir "${MOUNTPOINTS[$i]}" || true
        fi
        losetup -d "${LOOPDEVICES[$i]}" || true
        log_info "Loop device detached: ${LOOPDEVICES[$i]}"
        rm -f "${FILEPATHS[$i]}" || true
        log_info "Temporary file deleted: ${FILEPATHS[$i]}"
    done
}

# NEW: Create loop devices like polymount, but with configurable base directory
# Usage:
#   custompolymount <BaseDir> <N> <Size>
#   custompolymount rand <BaseDir> <N> <MinSize> <MaxSize>
custompolymount() {
    local CREATE_FS=$1
    shift

    local RAND_MODE=false

    if [ "$1" == "rand" ]; then
        # custompolymount rand <BaseDir> <N> <MinSize> <MaxSize>
        if [ "$#" -ne 5 ]; then
            die "Usage: $0 custompolymount rand <BaseDir> <N> <MinSize> <MaxSize>"
        fi
        RAND_MODE=true
        local BASEDIR="$2"
        local N="$3"
        local MIN_SIZE_BYTES
        local MAX_SIZE_BYTES
        MIN_SIZE_BYTES=$(convert_size_to_bytes "$4")
        MAX_SIZE_BYTES=$(convert_size_to_bytes "$5")
    else
        # custompolymount <BaseDir> <N> <Size>
        if [ "$#" -ne 3 ]; then
            die "Usage: $0 custompolymount <BaseDir> <N> <Size>"
        fi
        local BASEDIR="$1"
        local N="$2"
        local SIZE_BYTES
        SIZE_BYTES=$(convert_size_to_bytes "$3")
    fi

    if [ ! -d "$BASEDIR" ]; then
        die "Base directory does not exist or is not a directory: $BASEDIR"
    fi

    declare -a LOOPDEVICES=()
    declare -a FILEPATHS=()
    declare -a MOUNTPOINTS=()

    for ((i=1; i<=N; i++)); do
        local BYTE_SIZE
        if [ "$RAND_MODE" = true ]; then
            BYTE_SIZE=$(generate_random_size "$MIN_SIZE_BYTES" "$MAX_SIZE_BYTES")
        else
            BYTE_SIZE="$SIZE_BYTES"
        fi

        local GUID
        local FILENAME
        local FILEPATH
        local LOOPDEVICE
        GUID=$(uuidgen)
        FILENAME="${GUID}.img"
        FILEPATH="${BASEDIR}/${FILENAME}"

        if ! dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek="$BYTE_SIZE" status=none; then
            log_err "Failed to create file $FILEPATH"
            continue
        fi

        LOOPDEVICE=$(losetup -fP --show "$FILEPATH") || {
            log_err "Error creating loop device for $FILEPATH."
            rm -f "$FILEPATH" || true
            continue
        }
        log_info "Loop device set up: $LOOPDEVICE (file: $FILEPATH, size=${BYTE_SIZE} bytes)"

        if [ "$CREATE_FS" = true ]; then
            if ! mkfs.ext4 -q "$LOOPDEVICE" >/dev/null 2>&1; then
                log_err "Failed to create filesystem on $LOOPDEVICE"
                losetup -d "$LOOPDEVICE" || true
                rm -f "$FILEPATH" || true
                continue
            fi

            local MOUNTPOINT
            MOUNTPOINT=$(mktemp -d)
            if ! mount "$LOOPDEVICE" "$MOUNTPOINT"; then
                log_err "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
                losetup -d "$LOOPDEVICE" || true
                rm -f "$FILEPATH" || true
                rmdir "$MOUNTPOINT" || true
                continue
            fi
            log_info "Loop device mounted at $MOUNTPOINT"

            MOUNTPOINTS+=("$MOUNTPOINT")
        else
            MOUNTPOINTS+=("")
        fi

        LOOPDEVICES+=("$LOOPDEVICE")
        FILEPATHS+=("$FILEPATH")
    done

    echo "All custom-polymount loop devices set up. Press [Enter] to detach all loop devices."
    read -r

    for i in "${!LOOPDEVICES[@]}"; do
        if [ "$CREATE_FS" = true ] && [ -n "${MOUNTPOINTS[$i]}" ]; then
            umount "${MOUNTPOINTS[$i]}" || true
            rmdir "${MOUNTPOINTS[$i]}" || true
        fi
        losetup -d "${LOOPDEVICES[$i]}" || true
        log_info "Loop device detached: ${LOOPDEVICES[$i]}"

        rm -f "${FILEPATHS[$i]}" || true
        log_info "Backing file deleted: ${FILEPATHS[$i]}"
    done
}

# Function to set up a loop device with faulty blocks
setup_faulty_loop_device() {
    local FILEPATH="$1"
    local CREATE_FS="$2"
    local FAULTY_BLOCKS="$3"

    local LOOPDEVICE
    local MOUNTPOINT
    local DM_DEVICE_NAME
    local MAPPED_DEVICE

    LOOPDEVICE=$(losetup -fP --show "$FILEPATH") || die "Error creating the loop device."
    log_info "Loop device set up: $LOOPDEVICE"

    # Get total number of blocks
    local BLOCK_SIZE=512  # Standard block size
    local TOTAL_SIZE
    local TOTAL_BLOCKS
    TOTAL_SIZE=$(blockdev --getsize64 "$LOOPDEVICE")
    TOTAL_BLOCKS=$((TOTAL_SIZE / BLOCK_SIZE))

    # Parse faulty blocks
    parse_faulty_blocks "$FAULTY_BLOCKS" "$TOTAL_BLOCKS"

    # Create Device Mapper table
    create_dm_table "$LOOPDEVICE" "$TOTAL_BLOCKS"

    # Create Device Mapper device
    DM_DEVICE_NAME="faulty-loop-$(basename "$LOOPDEVICE")"
    printf '%b' "$DM_TABLE" | dmsetup create "$DM_DEVICE_NAME" >/dev/null

    MAPPED_DEVICE="/dev/mapper/$DM_DEVICE_NAME"
    log_info "Faulty loop device created: $MAPPED_DEVICE"

    if [ "$CREATE_FS" = true ]; then
        if ! mkfs.ext4 -q "$MAPPED_DEVICE" >/dev/null 2>&1; then
            dmsetup remove "$DM_DEVICE_NAME" || true
            losetup -d "$LOOPDEVICE" || true
            die "Failed to create filesystem on $MAPPED_DEVICE"
        fi

        MOUNTPOINT=$(mktemp -d)
        if ! mount "$MAPPED_DEVICE" "$MOUNTPOINT"; then
            dmsetup remove "$DM_DEVICE_NAME" || true
            losetup -d "$LOOPDEVICE" || true
            rmdir "$MOUNTPOINT" || true
            die "Failed to mount $MAPPED_DEVICE at $MOUNTPOINT"
        fi
        log_info "Faulty loop device mounted at $MOUNTPOINT"

        echo "Press [Enter] to unmount and detach the loop device."
        read -r

        umount "$MOUNTPOINT" || true
        rmdir "$MOUNTPOINT" || true
    else
        echo "Press [Enter] to detach the loop device."
        read -r
    fi

    dmsetup remove "$DM_DEVICE_NAME" || true
    losetup -d "$LOOPDEVICE" || true
    log_info "Faulty loop device detached and cleaned up."

    if [[ "$FILEPATH" == /tmp/*.img ]]; then
        rm -f "$FILEPATH" || true
        log_info "Temporary file deleted: $FILEPATH"
    fi
}

# Create multiple loop devices backed by a single tmpfs (optional filesystem + mount).
# Usage (analog zu polymount):
#   tmpfspolymount <N> <Size>
#   tmpfspolymount rand <N> <MinSize> <MaxSize>
tmpfspolymount() {
    local CREATE_FS=$1
    shift

    local RAND_MODE=false
    declare -a SIZES=()
    local TOTAL_BYTES=0

    if [ "$1" == "rand" ]; then
        if [ "$#" -ne 4 ]; then
            die "Usage: $0 tmpfspolymount rand <N> <MinSize> <MaxSize>"
        fi

        RAND_MODE=true
        local N=$2
        local MIN_SIZE_BYTES
        local MAX_SIZE_BYTES
        MIN_SIZE_BYTES=$(convert_size_to_bytes "$3")
        MAX_SIZE_BYTES=$(convert_size_to_bytes "$4")

        # Größen vorab auswürfeln und aufsummieren
        for ((i=1; i<=N; i++)); do
            local SIZE_BYTES
            SIZE_BYTES=$(generate_random_size "$MIN_SIZE_BYTES" "$MAX_SIZE_BYTES")
            SIZES[$i]="$SIZE_BYTES"
            TOTAL_BYTES=$((TOTAL_BYTES + SIZE_BYTES))
        done
    else
        if [ "$#" -ne 2 ]; then
            die "Usage: $0 tmpfspolymount <N> <Size>"
        fi

        local N=$1
        local SIZE_BYTES
        SIZE_BYTES=$(convert_size_to_bytes "$2")
        TOTAL_BYTES=$((N * SIZE_BYTES))
    fi

    local TMPDIR
    TMPDIR=$(mktemp -d)
    if [ ! -d "$TMPDIR" ]; then
        die "Failed to create temporary directory."
    fi

    # Gemeinsames tmpfs für alle N Images
    if ! mount -t tmpfs -o size=${TOTAL_BYTES} tmpfs "$TMPDIR"; then
        rmdir "$TMPDIR" || true
        die "Failed to mount tmpfs at $TMPDIR"
    fi
    log_info "tmpfs mounted at $TMPDIR (size=${TOTAL_BYTES} bytes)"

    declare -a LOOPDEVICES=()
    declare -a FILEPATHS=()
    declare -a MOUNTPOINTS=()

    for ((i=1; i<=N; i++)); do
        local BYTE_SIZE
        if [ "$RAND_MODE" = true ]; then
            BYTE_SIZE="${SIZES[$i]}"
        else
            BYTE_SIZE="$SIZE_BYTES"
        fi

        local GUID
        local FILENAME
        local FILEPATH
        local LOOPDEVICE
        GUID=$(uuidgen)
        FILENAME="${GUID}.img"
        FILEPATH="$TMPDIR/${FILENAME}"

        if ! dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek="$BYTE_SIZE" status=none; then
            log_err "Failed to create file $FILEPATH"
            continue
        fi

        LOOPDEVICE=$(losetup -fP --show "$FILEPATH") || {
            log_err "Error creating loop device for $FILEPATH."
            rm -f "$FILEPATH" || true
            continue
        }
        log_info "Loop device set up: $LOOPDEVICE (size=${BYTE_SIZE} bytes)"

        if [ "$CREATE_FS" = true ]; then
            if ! mkfs.ext4 -q "$LOOPDEVICE" >/dev/null 2>&1; then
                log_err "Failed to create filesystem on $LOOPDEVICE"
                losetup -d "$LOOPDEVICE" || true
                rm -f "$FILEPATH" || true
                continue
            fi

            local MOUNTPOINT
            MOUNTPOINT=$(mktemp -d)
            if ! mount "$LOOPDEVICE" "$MOUNTPOINT"; then
                log_err "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
                losetup -d "$LOOPDEVICE" || true
                rm -f "$FILEPATH" || true
                rmdir "$MOUNTPOINT" || true
                continue
            fi
            log_info "Loop device mounted at $MOUNTPOINT"

            MOUNTPOINTS+=("$MOUNTPOINT")
        else
            MOUNTPOINTS+=("")
        fi

        LOOPDEVICES+=("$LOOPDEVICE")
        FILEPATHS+=("$FILEPATH")
    done

    echo "All tmpfs-backed loop devices set up. Press [Enter] to detach all loop devices."
    read -r

    for i in "${!LOOPDEVICES[@]}"; do
        if [ "$CREATE_FS" = true ] && [ -n "${MOUNTPOINTS[$i]}" ]; then
            umount "${MOUNTPOINTS[$i]}" || true
            rmdir "${MOUNTPOINTS[$i]}" || true
        fi
        losetup -d "${LOOPDEVICES[$i]}" || true
        log_info "Loop device detached: ${LOOPDEVICES[$i]}"

        rm -f "${FILEPATHS[$i]}" || true
        log_info "Backing file deleted: ${FILEPATHS[$i]}"
    done

    umount "$TMPDIR" || true
    rmdir "$TMPDIR" || true
    log_info "tmpfs $TMPDIR unmounted and cleaned up."
}

# Function to parse faulty blocks and create an array
parse_faulty_blocks() {
    local FAULTY_BLOCKS_STR="$1"
    local TOTAL_BLOCKS="$2"
    FAULTY_BLOCKS_ARRAY=()

    IFS=',' read -ra ADDR <<< "$FAULTY_BLOCKS_STR"
    for BLOCK_SPEC in "${ADDR[@]}"; do
        if [[ "$BLOCK_SPEC" == *"-"* ]]; then
            IFS='-' read -ra RANGE <<< "$BLOCK_SPEC"
            START=${RANGE[0]}
            END=${RANGE[1]}
            if [ "$START" -gt "$END" ] || [ "$END" -ge "$TOTAL_BLOCKS" ]; then
                die "Invalid block range: $BLOCK_SPEC"
            fi
            FAULTY_BLOCKS_ARRAY+=("$START-$END")
        else
            if [ "$BLOCK_SPEC" -ge "$TOTAL_BLOCKS" ]; then
                die "Invalid block number: $BLOCK_SPEC"
            fi
            FAULTY_BLOCKS_ARRAY+=("$BLOCK_SPEC")
        fi
    done
}

# Function to create Device Mapper table
create_dm_table() {
    local LOOPDEVICE="$1"
    local TOTAL_BLOCKS="$2"
    DM_TABLE=""
    local CURRENT_BLOCK=0

    # Sort faulty blocks
    local SORTED_BLOCKS
    # shellcheck disable=SC2207
    SORTED_BLOCKS=($(printf '%s\n' "${FAULTY_BLOCKS_ARRAY[@]}" | sort -n -t '-' -k1,1))

    for BLOCK_SPEC in "${SORTED_BLOCKS[@]}"; do
        if [[ "$BLOCK_SPEC" == *"-"* ]]; then
            IFS='-' read -ra RANGE <<< "$BLOCK_SPEC"
            START=${RANGE[0]}
            END=${RANGE[1]}
        else
            START="$BLOCK_SPEC"
            END="$BLOCK_SPEC"
        fi

        # Add normal blocks before the faulty block
        if [ "$CURRENT_BLOCK" -lt "$START" ]; then
            LENGTH=$((START - CURRENT_BLOCK))
            DM_TABLE+="$CURRENT_BLOCK $LENGTH linear $LOOPDEVICE $CURRENT_BLOCK\n"
            CURRENT_BLOCK=$START
        fi

        # Add faulty block
        LENGTH=$((END - START + 1))
        DM_TABLE+="$CURRENT_BLOCK $LENGTH error\n"
        CURRENT_BLOCK=$((END + 1))
    done

    # Add remaining normal blocks
    if [ "$CURRENT_BLOCK" -lt "$TOTAL_BLOCKS" ]; then
        LENGTH=$((TOTAL_BLOCKS - CURRENT_BLOCK))
        DM_TABLE+="$CURRENT_BLOCK $LENGTH linear $LOOPDEVICE $CURRENT_BLOCK\n"
    fi
}

# Updated automount function to handle faulty blocks
automount_faulty() {
    local GUID
    local FILENAME
    local FILEPATH
    local FILESIZE=$1
    local CREATE_FS=$2
    local FAULTY_BLOCKS=$3

    local BYTE_SIZE
    GUID=$(uuidgen)
    FILENAME="${GUID}.img"
    FILEPATH="/tmp/${FILENAME}"
    BYTE_SIZE=$(convert_size_to_bytes "$FILESIZE")

    if ! dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek="$BYTE_SIZE" status=none; then
        die "Failed to create file $FILEPATH"
    fi

    setup_faulty_loop_device "$FILEPATH" "$CREATE_FS" "$FAULTY_BLOCKS"
}

# Main logic
ORIG_ARGS=("$@")

case "${1-}" in
    --help)
        show_help
        ;;
    automount)
        if [ "$#" -ne 2 ]; then
            show_help
            die "Usage: $0 automount <Size>"
        fi
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen
        automount "$2" false
        ;;
    automountfs)
        if [ "$#" -ne 2 ]; then
            show_help
            die "Usage: $0 automountfs <Size>"
        fi
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen mkfs.ext4 mount umount
        automount "$2" true
        ;;
    faultymount)
        if [ "$#" -ne 3 ]; then
            show_help
            die "Usage: $0 faultymount <Size> <BlockNumbers>"
        fi
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen dmsetup blockdev
        automount_faulty "$2" false "$3"
        ;;
    faultymountfs)
        if [ "$#" -ne 3 ]; then
            show_help
            die "Usage: $0 faultymountfs <Size> <BlockNumbers>"
        fi
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen dmsetup blockdev mkfs.ext4 mount umount
        automount_faulty "$2" true "$3"
        ;;
    polymount)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen
        shift
        polymount false "$@"
        ;;
    polymountfs)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen mkfs.ext4 mount umount
        shift
        polymount true "$@"
        ;;
    custompolymount)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen
        shift
        custompolymount false "$@"
        ;;
    custompolymountfs)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen mkfs.ext4 mount umount
        shift
        custompolymount true "$@"
        ;;
    # Aliases: custommount == custompolymount
    custommount)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen
        shift
        custompolymount false "$@"
        ;;
    custommountfs)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen mkfs.ext4 mount umount
        shift
        custompolymount true "$@"
        ;;
    tmpfsmount)
        if [ "$#" -ne 2 ]; then
            show_help
            die "Usage: $0 tmpfsmount <Size>"
        fi
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd mount umount
        tmpfsmount "$2" false
        ;;
    tmpfspolymount)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen mount umount
        shift
        tmpfspolymount false "$@"
        ;;
    tmpfspolymountfs)
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd uuidgen mount umount mkfs.ext4
        shift
        tmpfspolymount true "$@"
        ;;
    tmpfsmountfs)
        if [ "$#" -ne 2 ]; then
            show_help
            die "Usage: $0 tmpfsmountfs <Size>"
        fi
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup dd mount umount mkfs.ext4
        tmpfsmount "$2" true
        ;;
    *)
        if [ "$#" -ne 1 ]; then
            show_help
            die "Unknown/invalid command."
        fi
        if [ ! -e "$1" ]; then
            die "File does not exist: $1"
        fi
        ensure_root "${ORIG_ARGS[@]}"
        require_cmds losetup
        setup_loop_device "$1" false
        ;;
esac
