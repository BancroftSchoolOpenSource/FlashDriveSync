#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 <PULL_DIR> <PUSH_DIR>" >&2
    exit 1
}

[ $# -eq 2 ] || usage

PULL_DIR=$(realpath -m -- "$1")
PUSH_DIR=$(realpath -m -- "$2")

if [ ! -d "$PUSH_DIR" ]; then
    echo "Error: PUSH_DIR '$PUSH_DIR' does not exist or is not a directory." >&2
    exit 1
fi

mkdir -p "$PULL_DIR"

for cmd in lsblk rsync findmnt realpath; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: '$cmd' is required but not found." >&2
        exit 1
    }
done

USE_UDISKS=0

if command -v udisksctl >/dev/null 2>&1; then
    USE_UDISKS=1
fi

RSYNC_OPTS=(-a --info=progress2 --human-readable)

ROOT_SRC=$(findmnt -no SOURCE / || true)
ROOT_DISK=""

if [ -n "$ROOT_SRC" ]; then
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)

    if [ -z "$ROOT_DISK" ]; then
        ROOT_DISK=$(basename "$ROOT_SRC")
    fi
fi

mount_partition() {
    local dev="$1"
    local existing
    local out
    local mp
    local tmp_mp

    existing=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | head -n1 || true)

    if [ -n "$existing" ]; then
        echo "$existing"
        return 0
    fi

    if [ "$USE_UDISKS" -eq 1 ]; then
        if out=$(udisksctl mount -b "$dev" --no-user-interaction 2>&1); then
            mp=$(echo "$out" | sed -n 's/.*at \(.*\)\.$/\1/p')

            if [ -n "$mp" ] && [ -d "$mp" ]; then
                echo "$mp"
                return 0
            fi
        fi
    fi

    tmp_mp="/mnt/usb-sync/$(basename "$dev")"

    sudo mkdir -p "$tmp_mp"

    if sudo mount "$dev" "$tmp_mp" 2>/dev/null; then
        echo "$tmp_mp"
        return 0
    fi

    return 1
}

unmount_partition() {
    local dev="$1"
    local mp="$2"

    if [ "$USE_UDISKS" -eq 1 ]; then
        if udisksctl unmount -b "$dev" --no-user-interaction >/dev/null 2>&1; then
            return 0
        fi
    fi

    sudo umount "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
}

dest_unique() {
    local dest="$1"
    local i=2
    local candidate="$dest"

    while [ -e "$candidate" ]; do
        candidate="${dest}__${i}"
        i=$((i + 1))
    done

    echo "$candidate"
}

merge_into_pull_dir() {
    local src_root="$1"
    local pull_dir="$2"
    local file
    local rel
    local dest
    local destdir
    local final

    while IFS= read -r -d '' file; do
        rel="${file#"$src_root"/}"
        dest="$pull_dir/$rel"
        destdir=$(dirname "$dest")

        mkdir -p "$destdir"

        final=$(dest_unique "$dest")

        rsync "${RSYNC_OPTS[@]}" -- "$file" "$final"
    done < <(find "$src_root" -type f -print0)

    while IFS= read -r -d '' dir; do
        rel="${dir#"$src_root"}"

        if [ -n "$rel" ]; then
            mkdir -p "$pull_dir$rel"
        fi
    done < <(find "$src_root" -type d -print0)
}

DISKS=$(lsblk -dn -o NAME,RM,TRAN,TYPE |
    awk '$2=="1" && $4=="disk" {print $1}')

if [ -z "$DISKS" ]; then
    echo "No removable USB drives found."
    exit 0
fi

for disk in $DISKS; do
    if [ -n "$ROOT_DISK" ] && [ "$disk" = "$ROOT_DISK" ]; then
        echo "Skipping /dev/$disk (this is the OS disk)."
        continue
    fi

    PARTS=$(lsblk -ln -o NAME,TYPE "/dev/$disk" |
        awk '$2=="part"{print $1}')

    [ -z "$PARTS" ] && PARTS="$disk"

    for part in $PARTS; do
        devpath="/dev/$part"

        echo
        echo "=== Processing $devpath ==="

        mountpoint=$(mount_partition "$devpath") || {
            echo "  Could not mount $devpath, skipping."
            continue
        }

        echo "  Mounted at: $mountpoint"

        case "$mountpoint" in
            "/"|"/boot"|"/boot/efi"|"/home"|"/var"|"/usr")
                echo "  Refusing to touch system mountpoint $mountpoint, skipping."
                continue
                ;;
        esac

        case "$PULL_DIR/" in
            "$mountpoint/"*)
                echo "  PULL_DIR is inside the USB drive, skipping."
                unmount_partition "$devpath" "$mountpoint"
                continue
                ;;
        esac

        case "$PUSH_DIR/" in
            "$mountpoint/"*)
                echo "  PUSH_DIR is inside the USB drive, skipping."
                unmount_partition "$devpath" "$mountpoint"
                continue
                ;;
        esac

        echo "  Pulling drive contents -> $PULL_DIR"
        merge_into_pull_dir "$mountpoint" "$PULL_DIR"

        echo "  Pushing missing files -> $mountpoint"
        rsync "${RSYNC_OPTS[@]}" --ignore-existing "$PUSH_DIR"/ "$mountpoint"/

        sync

        echo "  Unmounting $devpath"
        unmount_partition "$devpath" "$mountpoint"
    done
done

echo
echo "All drives processed."
