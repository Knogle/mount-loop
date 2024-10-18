#!/bin/bash

# Check if script is running as root
if [ "$EUID" -ne 0 ]; then
    # Check for pkexec or sudo
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec "$0" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo "$0" "$@"
    else
        echo "Error: This script requires elevated privileges, but neither pkexec nor sudo is available."
        exit 1
    fi
fi

# Function to display help message
show_help() {
    echo "Usage: $0 [OPTION]... [FILE]"
    echo "Set up loop devices for a given file, create new files of specified or random size, or create a ramdisk of specified size."
    echo ""
    echo "  --help                     display this help and exit"
    echo "  automount <Size>           automatically create a file of specified size and set it up as a loop device."
    echo "  automountfs <Size>         same as automount but also create a filesystem and mount it."
    echo "  faultymount <Size> <BlockNumbers>  create a loop device with specified faulty blocks."
    echo "  faultymountfs <Size> <BlockNumbers>  same as faultymount but also create a filesystem and mount it."
    echo "  polymount <N> <Size>       create N files of specified size and set them up as loop devices."
    echo "  polymountfs <N> <Size>     same as polymount but also create filesystems and mount them."
    echo "  polymount rand <N> <MinSize> <MaxSize>  create N files with random sizes between MinSize and MaxSize, set them up as loop devices."
    echo "  polymountfs rand <N> <MinSize> <MaxSize>  same as polymount rand but also create filesystems and mount them."
    echo "  tmpfsmount <Size>          create a ramdisk of specified size as a loop device."
    echo "  tmpfsmountfs <Size>        same as tmpfsmount but also create a filesystem and mount it."
    echo "  <FilePath>                 path to the existing file to set up as a loop device"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/your/file.img                 Set up an existing file as a loop device."
    echo "  $0 automount 1G                           Create a 1G-sized file and set it up as a loop device."
    echo "  $0 automountfs 1G                         Same as above but also create a filesystem and mount it."
    echo "  $0 faultymount 1G 500,1000                Create a 1G-sized loop device with blocks 500 and 1000 faulty."
    echo "  $0 faultymountfs 1G 500-510               Same as above but also create a filesystem and mount it, blocks 500 to 510 faulty."
    echo "  $0 polymount 5 1G                         Create 5 1G-sized files and set them up as loop devices."
    echo "  $0 polymountfs 5 1G                       Same as above but also create filesystems and mount them."
    echo "  $0 tmpfsmount 1G                          Create a 1G ramdisk and set it up as a loop device."
    echo "  $0 tmpfsmountfs 1G                        Same as above but also create a filesystem and mount it."
    echo ""
    echo "Note: This script requires elevated permissions. It will attempt to use pkexec or sudo."
}

# Convert size specification to bytes
convert_size_to_bytes() {
    SIZE=$1
    UNIT=$(echo "$SIZE" | sed -E 's/[0-9\.]+//g' | tr '[:lower:]' '[:upper:]')
    NUMBER=$(echo "$SIZE" | sed -E 's/[^0-9\.]//g')

    if [ -z "$NUMBER" ]; then
        echo "Invalid size value: $SIZE" >&2
        exit 1
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
            echo "Unknown size unit: $UNIT" >&2
            exit 1
            ;;
    esac

    echo $BYTE_SIZE
}

# Generate a random size within specified range
generate_random_size() {
    MIN_SIZE_BYTES=$1
    MAX_SIZE_BYTES=$2
    RANGE=$(($MAX_SIZE_BYTES - $MIN_SIZE_BYTES + 1))

    if [ "$RANGE" -le 0 ]; then
        echo "Invalid size range." >&2
        exit 1
    fi

    RANDOM_BYTES=$(awk -v min=$MIN_SIZE_BYTES -v range=$RANGE 'BEGIN{srand(); print int(min+rand()*range)}')

    echo $RANDOM_BYTES
}

# Function to set up the loop device (optionally create filesystem and mount)
setup_loop_device() {
    FILEPATH="$1"
    CREATE_FS="$2"

    LOOPDEVICE=$(losetup -fP --show "$FILEPATH")
    if [ -z "$LOOPDEVICE" ]; then
        echo "Error creating the loop device."
        exit 1
    fi
    echo "Loop device set up: $LOOPDEVICE"

    if [ "$CREATE_FS" = true ]; then
        # Create a filesystem on the loop device
        mkfs.ext4 "$LOOPDEVICE" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "Failed to create filesystem on $LOOPDEVICE"
            losetup -d "$LOOPDEVICE"
            exit 1
        fi

        # Create a temporary mount point
        MOUNTPOINT=$(mktemp -d)

        # Mount the loop device
        mount "$LOOPDEVICE" "$MOUNTPOINT"
        if [ $? -ne 0 ]; then
            echo "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
            losetup -d "$LOOPDEVICE"
            rmdir "$MOUNTPOINT"
            exit 1
        fi
        echo "Loop device mounted at $MOUNTPOINT"

        echo "Press [Enter] to unmount and detach the loop device."
        read

        # Unmount and clean up
        umount "$MOUNTPOINT"
        rmdir "$MOUNTPOINT"
    else
        echo "Press [Enter] to detach the loop device."
        read
    fi

    cleanup "$LOOPDEVICE" "$FILEPATH"
}

# Function for cleanup: detaching the loop device, and deleting the file
cleanup() {
    LOOPDEVICE=$1
    FILEPATH=$2

    losetup -d "$LOOPDEVICE"
    echo "Loop device detached: $LOOPDEVICE"

    if [[ "$FILEPATH" == /tmp/*.img ]]; then
        rm -f "$FILEPATH"
        echo "Temporary file deleted: $FILEPATH"
    fi
}

# Function to automatically create a file of a specified size and set up as a loop device
automount() {
    GUID=$(uuidgen)
    FILENAME="${GUID}.img"
    FILEPATH="/tmp/${FILENAME}"
    FILESIZE=$1
    CREATE_FS=$2

    BYTE_SIZE=$(convert_size_to_bytes "$FILESIZE")

    dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek=$BYTE_SIZE status=none
    if [ $? -ne 0 ]; then
        echo "Failed to create file $FILEPATH"
        exit 1
    fi

    setup_loop_device "$FILEPATH" "$CREATE_FS"
}

# Function to create a ramdisk as a loop device (optionally create filesystem and mount)
tmpfsmount() {
    RAMDISK_SIZE=$1
    CREATE_FS=$2

    BYTE_SIZE=$(convert_size_to_bytes "$RAMDISK_SIZE")

    TMPDIR=$(mktemp -d)
    if [ ! -d "$TMPDIR" ]; then
        echo "Failed to create temporary directory."
        exit 1
    fi

    mount -t tmpfs -o size=${BYTE_SIZE} tmpfs $TMPDIR
    if [ $? -ne 0 ]; then
        echo "Failed to mount tmpfs at $TMPDIR"
        rmdir "$TMPDIR"
        exit 1
    fi
    echo "Ramdisk mounted at $TMPDIR"

    FILEPATH="${TMPDIR}/ramdisk.img"

    dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek=$BYTE_SIZE status=none
    if [ $? -ne 0 ]; then
        echo "Failed to create file $FILEPATH"
        umount "$TMPDIR"
        rmdir "$TMPDIR"
        exit 1
    fi

    setup_loop_device "$FILEPATH" "$CREATE_FS"

    # Clean up ramdisk
    umount "$TMPDIR"
    rmdir "$TMPDIR"
    echo "Ramdisk unmounted and cleaned up."
}

# Create loop devices with files of specified or random sizes (optionally create filesystem and mount)
polymount() {
    CREATE_FS=$1
    shift

    if [ "$1" == "rand" ]; then
        if [ "$#" -ne 4 ]; then
            echo "Usage: $0 polymount rand <N> <MinSize> <MaxSize>"
            exit 1
        fi
        N=$2
        MIN_SIZE_BYTES=$(convert_size_to_bytes $3)
        MAX_SIZE_BYTES=$(convert_size_to_bytes $4)
    else
        if [ "$#" -ne 2 ]; then
            echo "Usage: $0 polymount <N> <Size>"
            exit 1
        fi
        N=$1
        SIZE_BYTES=$(convert_size_to_bytes $2)
    fi

    declare -a LOOPDEVICES
    declare -a FILEPATHS
    declare -a MOUNTPOINTS

    for ((i=1; i<=N; i++)); do
        if [ "$1" == "rand" ]; then
            SIZE_BYTES=$(generate_random_size $MIN_SIZE_BYTES $MAX_SIZE_BYTES)
        fi

        BYTE_SIZE="$SIZE_BYTES"

        GUID=$(uuidgen)
        FILENAME="${GUID}.img"
        FILEPATH="/tmp/${FILENAME}"

        dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek=$BYTE_SIZE status=none
        if [ $? -ne 0 ]; then
            echo "Failed to create file $FILEPATH"
            continue
        fi

        LOOPDEVICE=$(losetup -fP --show "$FILEPATH")
        if [ -z "$LOOPDEVICE" ]; then
            echo "Error creating loop device for $FILEPATH."
            rm -f "$FILEPATH"
            continue
        fi
        echo "Loop device set up: $LOOPDEVICE"

        if [ "$CREATE_FS" = true ]; then
            mkfs.ext4 "$LOOPDEVICE" >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo "Failed to create filesystem on $LOOPDEVICE"
                losetup -d "$LOOPDEVICE"
                rm -f "$FILEPATH"
                continue
            fi

            MOUNTPOINT=$(mktemp -d)
            mount "$LOOPDEVICE" "$MOUNTPOINT"
            if [ $? -ne 0 ]; then
                echo "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
                losetup -d "$LOOPDEVICE"
                rm -f "$FILEPATH"
                rmdir "$MOUNTPOINT"
                continue
            fi
            echo "Loop device mounted at $MOUNTPOINT"

            MOUNTPOINTS+=("$MOUNTPOINT")
        fi

        LOOPDEVICES+=("$LOOPDEVICE")
        FILEPATHS+=("$FILEPATH")
    done

    echo "All loop devices set up. Press [Enter] to detach all loop devices."
    read

    for i in "${!LOOPDEVICES[@]}"; do
        if [ "$CREATE_FS" = true ]; then
            umount "${MOUNTPOINTS[$i]}"
            rmdir "${MOUNTPOINTS[$i]}"
        fi
        losetup -d "${LOOPDEVICES[$i]}"
        echo "Loop device detached: ${LOOPDEVICES[$i]}"
        rm -f "${FILEPATHS[$i]}"
        echo "Temporary file deleted: ${FILEPATHS[$i]}"
    done
}

# Function to set up a loop device with faulty blocks
setup_faulty_loop_device() {
    FILEPATH="$1"
    CREATE_FS="$2"
    FAULTY_BLOCKS="$3"

    LOOPDEVICE=$(losetup -fP --show "$FILEPATH")
    if [ -z "$LOOPDEVICE" ]; then
        echo "Error creating the loop device."
        exit 1
    fi
    echo "Loop device set up: $LOOPDEVICE"

    # Get total number of blocks
    BLOCK_SIZE=512  # Standard block size
    TOTAL_SIZE=$(blockdev --getsize64 "$LOOPDEVICE")
    TOTAL_BLOCKS=$((TOTAL_SIZE / BLOCK_SIZE))

    # Parse faulty blocks
    parse_faulty_blocks "$FAULTY_BLOCKS" "$TOTAL_BLOCKS"

    # Create Device Mapper table
    create_dm_table "$LOOPDEVICE" "$TOTAL_BLOCKS"

    # Create Device Mapper device
    DM_DEVICE_NAME="faulty-loop-$(basename "$LOOPDEVICE")"
    echo -e "$DM_TABLE" | dmsetup create "$DM_DEVICE_NAME"

    MAPPED_DEVICE="/dev/mapper/$DM_DEVICE_NAME"
    echo "Faulty loop device created: $MAPPED_DEVICE"

    if [ "$CREATE_FS" = true ]; then
        mkfs.ext4 "$MAPPED_DEVICE" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "Failed to create filesystem on $MAPPED_DEVICE"
            dmsetup remove "$DM_DEVICE_NAME"
            losetup -d "$LOOPDEVICE"
            exit 1
        fi

        MOUNTPOINT=$(mktemp -d)
        mount "$MAPPED_DEVICE" "$MOUNTPOINT"
        if [ $? -ne 0 ]; then
            echo "Failed to mount $MAPPED_DEVICE at $MOUNTPOINT"
            dmsetup remove "$DM_DEVICE_NAME"
            losetup -d "$LOOPDEVICE"
            rmdir "$MOUNTPOINT"
            exit 1
        fi
        echo "Faulty loop device mounted at $MOUNTPOINT"

        echo "Press [Enter] to unmount and detach the loop device."
        read

        umount "$MOUNTPOINT"
        rmdir "$MOUNTPOINT"
    else
        echo "Press [Enter] to detach the loop device."
        read
    fi

    dmsetup remove "$DM_DEVICE_NAME"
    losetup -d "$LOOPDEVICE"
    echo "Faulty loop device detached and cleaned up."

    if [[ "$FILEPATH" == /tmp/*.img ]]; then
        rm -f "$FILEPATH"
        echo "Temporary file deleted: $FILEPATH"
    fi
}

# Function to parse faulty blocks and create an array
parse_faulty_blocks() {
    FAULTY_BLOCKS_STR="$1"
    TOTAL_BLOCKS="$2"
    FAULTY_BLOCKS_ARRAY=()

    IFS=',' read -ra ADDR <<< "$FAULTY_BLOCKS_STR"
    for BLOCK_SPEC in "${ADDR[@]}"; do
        if [[ "$BLOCK_SPEC" == *"-"* ]]; then
            IFS='-' read -ra RANGE <<< "$BLOCK_SPEC"
            START=${RANGE[0]}
            END=${RANGE[1]}
            if [ "$START" -gt "$END" ] || [ "$END" -ge "$TOTAL_BLOCKS" ]; then
                echo "Invalid block range: $BLOCK_SPEC"
                exit 1
            fi
            FAULTY_BLOCKS_ARRAY+=("$START-$END")
        else
            if [ "$BLOCK_SPEC" -ge "$TOTAL_BLOCKS" ]; then
                echo "Invalid block number: $BLOCK_SPEC"
                exit 1
            fi
            FAULTY_BLOCKS_ARRAY+=("$BLOCK_SPEC")
        fi
    done
}

# Function to create Device Mapper table
create_dm_table() {
    LOOPDEVICE="$1"
    TOTAL_BLOCKS="$2"
    DM_TABLE=""
    CURRENT_BLOCK=0

    # Sort faulty blocks
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
    GUID=$(uuidgen)
    FILENAME="${GUID}.img"
    FILEPATH="/tmp/${FILENAME}"
    FILESIZE=$1
    CREATE_FS=$2
    FAULTY_BLOCKS=$3

    BYTE_SIZE=$(convert_size_to_bytes "$FILESIZE")

    dd if=/dev/zero of="$FILEPATH" bs=1 count=0 seek=$BYTE_SIZE status=none
    if [ $? -ne 0 ]; then
        echo "Failed to create file $FILEPATH"
        exit 1
    fi

    setup_faulty_loop_device "$FILEPATH" "$CREATE_FS" "$FAULTY_BLOCKS"
}

# Main logic
case "$1" in
    --help)
        show_help
        ;;
    automount)
        if [ "$#" -ne 2 ]; then
            echo "Usage: $0 automount <Size>"
            exit 1
        fi
        automount "$2" false
        ;;
    automountfs)
        if [ "$#" -ne 2 ]; then
            echo "Usage: $0 automountfs <Size>"
            exit 1
        fi
        automount "$2" true
        ;;
    faultymount)
        if [ "$#" -ne 3 ]; then
            echo "Usage: $0 faultymount <Size> <BlockNumbers>"
            exit 1
        fi
        automount_faulty "$2" false "$3"
        ;;
    faultymountfs)
        if [ "$#" -ne 3 ]; then
            echo "Usage: $0 faultymountfs <Size> <BlockNumbers>"
            exit 1
        fi
        automount_faulty "$2" true "$3"
        ;;
    polymount)
        shift
        polymount false "$@"
        ;;
    polymountfs)
        shift
        polymount true "$@"
        ;;
    tmpfsmount)
        if [ "$#" -ne 2 ]; then
            echo "Usage: $0 tmpfsmount <Size>"
            exit 1
        fi
        tmpfsmount "$2" false
        ;;
    tmpfsmountfs)
        if [ "$#" -ne 2 ]; then
            echo "Usage: $0 tmpfsmountfs <Size>"
            exit 1
        fi
        tmpfsmount "$2" true
        ;;
    *)
        if [ "$#" -ne 1 ]; then
            show_help
            exit 1
        fi
        setup_loop_device "$1" false
        ;;
esac

