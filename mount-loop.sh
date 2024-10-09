#!/bin/bash

# Function to display help message
show_help() {
    echo "Usage: $0 [OPTION]... [FILE]"
    echo "Set up loop devices for a given file, create new files of specified or random size, or create a ramdisk of specified size."
    echo ""
    echo "  --help                     display this help and exit"
    echo "  automount <Size>           automatically create a file of specified size and set it up as a loop device."
    echo "  automountfs <Size>         same as automount but also create a filesystem and mount it."
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
    echo "  $0 polymount 5 1G                         Create 5 1G-sized files and set them up as loop devices."
    echo "  $0 polymountfs 5 1G                       Same as above but also create filesystems and mount them."
    echo "  $0 tmpfsmount 1G                          Create a 1G ramdisk and set it up as a loop device."
    echo "  $0 tmpfsmountfs 1G                        Same as above but also create a filesystem and mount it."
    echo ""
    echo "Note: Run this script with root permissions or using sudo."
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

    LOOPDEVICE=$(sudo losetup -fP --show "$FILEPATH")
    if [ -z "$LOOPDEVICE" ]; then
        echo "Error creating the loop device."
        exit 1
    fi
    echo "Loop device set up: $LOOPDEVICE"

    if [ "$CREATE_FS" = true ]; then
        # Create a filesystem on the loop device
        sudo mkfs.ext4 "$LOOPDEVICE" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "Failed to create filesystem on $LOOPDEVICE"
            sudo losetup -d "$LOOPDEVICE"
            exit 1
        fi

        # Create a temporary mount point
        MOUNTPOINT=$(mktemp -d)

        # Mount the loop device
        sudo mount "$LOOPDEVICE" "$MOUNTPOINT"
        if [ $? -ne 0 ]; then
            echo "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
            sudo losetup -d "$LOOPDEVICE"
            rmdir "$MOUNTPOINT"
            exit 1
        fi
        echo "Loop device mounted at $MOUNTPOINT"

        echo "Press [Enter] to unmount and detach the loop device."
        read

        # Unmount and clean up
        sudo umount "$MOUNTPOINT"
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

    sudo losetup -d "$LOOPDEVICE"
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
    COUNT=$(awk "BEGIN {printf \"%.0f\", $BYTE_SIZE / (1024 * 1024)}")

    if [ "$COUNT" -le 0 ]; then
        echo "Size too small to create a file." >&2
        exit 1
    fi

    dd if=/dev/zero of="$FILEPATH" bs=1M count=$COUNT status=progress
    if [ $? -ne 0 ]; then
        echo "Failed to create file $FILEPATH"
        exit 1
    fi

    setup_loop_device "$FILEPATH" "$CREATE_FS"
}

# New function to create a ramdisk as a loop device (optionally create filesystem and mount)
tmpfsmount() {
    RAMDISK_SIZE=$1
    CREATE_FS=$2

    BYTE_SIZE=$(convert_size_to_bytes "$RAMDISK_SIZE")

    TMPDIR=$(mktemp -d)
    if [ ! -d "$TMPDIR" ]; then
        echo "Failed to create temporary directory."
        exit 1
    fi

    sudo mount -t tmpfs -o size=${BYTE_SIZE} tmpfs $TMPDIR
    if [ $? -ne 0 ]; then
        echo "Failed to mount tmpfs at $TMPDIR"
        rmdir "$TMPDIR"
        exit 1
    fi
    echo "Ramdisk mounted at $TMPDIR"

    FILEPATH="${TMPDIR}/ramdisk.img"
    COUNT=$(awk "BEGIN {printf \"%.0f\", $BYTE_SIZE / (1024 * 1024)}")

    dd if=/dev/zero of="$FILEPATH" bs=1M count=$COUNT status=progress
    if [ $? -ne 0 ]; then
        echo "Failed to create file $FILEPATH"
        sudo umount "$TMPDIR"
        rmdir "$TMPDIR"
        exit 1
    fi

    setup_loop_device "$FILEPATH" "$CREATE_FS"

    # Clean up ramdisk
    sudo umount "$TMPDIR"
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

        COUNT=$(awk "BEGIN {printf \"%.0f\", $SIZE_BYTES / (1024 * 1024)}")
        if [ "$COUNT" -le 0 ]; then
            echo "Generated size too small, skipping."
            continue
        fi

        GUID=$(uuidgen)
        FILENAME="${GUID}.img"
        FILEPATH="/tmp/${FILENAME}"

        dd if=/dev/zero of="$FILEPATH" bs=1M count=$COUNT status=progress
        if [ $? -ne 0 ]; then
            echo "Failed to create file $FILEPATH"
            continue
        fi

        LOOPDEVICE=$(sudo losetup -fP --show "$FILEPATH")
        if [ -z "$LOOPDEVICE" ]; then
            echo "Error creating loop device for $FILEPATH."
            rm -f "$FILEPATH"
            continue
        fi
        echo "Loop device set up: $LOOPDEVICE"

        if [ "$CREATE_FS" = true ]; then
            sudo mkfs.ext4 "$LOOPDEVICE" >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo "Failed to create filesystem on $LOOPDEVICE"
                sudo losetup -d "$LOOPDEVICE"
                rm -f "$FILEPATH"
                continue
            fi

            MOUNTPOINT=$(mktemp -d)
            sudo mount "$LOOPDEVICE" "$MOUNTPOINT"
            if [ $? -ne 0 ]; then
                echo "Failed to mount $LOOPDEVICE at $MOUNTPOINT"
                sudo losetup -d "$LOOPDEVICE"
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
            sudo umount "${MOUNTPOINTS[$i]}"
            rmdir "${MOUNTPOINTS[$i]}"
        fi
        sudo losetup -d "${LOOPDEVICES[$i]}"
        echo "Loop device detached: ${LOOPDEVICES[$i]}"
        rm -f "${FILEPATHS[$i]}"
        echo "Temporary file deleted: ${FILEPATHS[$i]}"
    done
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

