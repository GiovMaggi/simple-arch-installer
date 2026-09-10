#!/bin/bash

set -euo pipefail

# ============================================================
# Simple automatic Arch Linux installer
#
# Prompts ONLY for:
# 1. Disk
# 2. Mode: erase / all
#
# Configuration:
# Hostname: Arch
# Locale: en_US.UTF-8
# Keyboard: us
# Timezone: Europe/Rome
# Root password: 1234
#
# Packages:
# base linux-zen linux-firmware efibootmgr networkmanager
# grub base-devel os-prober linux-zen-headers sudo nano
# ============================================================

HOSTNAME="Arch"
TIMEZONE="Europe/Rome"
LOCALE="en_US.UTF-8"
KEYMAP="us"
ROOT_PASSWORD="1234"

PACKAGES=(
    base
    linux-zen
    linux-firmware
    efibootmgr
    networkmanager
    grub
    base-devel
    os-prober
    linux-zen-headers
    sudo
    nano
)

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root."
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "ERROR: The Arch ISO was not booted in UEFI mode."
    echo "Boot the USB in UEFI mode and run the installer again."
    exit 1
fi

REQUIRED_COMMANDS=(
    lsblk
    sfdisk
    fdisk
    mkfs.ext4
    mkfs.fat
    mkswap
    swapon
    pacstrap
    genfstab
    arch-chroot
    blkid
    blockdev
    curl
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

# ------------------------------------------------------------
# Internet check
# ------------------------------------------------------------

echo "Checking internet connection..."

if ! ping -c 1 -W 3 archlinux.org >/dev/null 2>&1; then
    echo "ERROR: No internet connection."
    echo "Connect to the internet and run the installer again."
    exit 1
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

part_path() {
    local disk="$1"
    local number="$2"

    case "$disk" in
        /dev/nvme*|/dev/mmcblk*|/dev/loop*)
            echo "${disk}p${number}"
            ;;
        *)
            echo "${disk}${number}"
            ;;
    esac
}

wait_for_partition() {
    local part="$1"

    for _ in {1..20}; do
        if [[ -b "$part" ]]; then
            return 0
        fi
        sleep 0.5
    done

    echo "ERROR: Partition did not appear: $part"
    exit 1
}

next_free_partition_number() {
    local disk="$1"

    for n in $(seq 1 128); do
        local part
        part="$(part_path "$disk" "$n")"

        if ! lsblk -nrpo NAME "$disk" | grep -Fxq "$part"; then
            echo "$n"
            return 0
        fi
    done

    echo "ERROR: No free GPT partition number available."
    exit 1
}

# ------------------------------------------------------------
# Show disks
# ------------------------------------------------------------

echo
echo "Available disks:"
echo

mapfile -t DISKS < <(
    lsblk -dpno NAME,SIZE,MODEL,TYPE |
    awk '$4 == "disk" {print}'
)

if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo "ERROR: No disks found."
    exit 1
fi

for i in "${!DISKS[@]}"; do
    printf "%2d) %s\n" "$((i + 1))" "${DISKS[$i]}"
done

echo
read -r -p "Choose disk number: " DISK_NUMBER

if ! [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid disk number."
    exit 1
fi

if (( DISK_NUMBER < 1 || DISK_NUMBER > ${#DISKS[@]} )); then
    echo "ERROR: Invalid disk number."
    exit 1
fi

DISK_LINE="${DISKS[$((DISK_NUMBER - 1))]}"
DISK="$(awk '{print $1}' <<< "$DISK_LINE")"

echo
echo "Selected disk: $DISK"
echo

# ------------------------------------------------------------
# Choose mode
# ------------------------------------------------------------

read -r -p "Choose mode (erase/all): " MODE

case "$MODE" in
    erase|all)
        ;;
    *)
        echo "ERROR: Mode must be exactly 'erase' or 'all'."
        exit 1
        ;;
esac

# ------------------------------------------------------------
# Make sure selected disk is not the Arch ISO itself
# ------------------------------------------------------------

ROOT_SOURCE="$(findmnt -no SOURCE /)"

if [[ "$ROOT_SOURCE" == "$DISK"* ]]; then
    echo "ERROR: The selected disk appears to contain the running Arch ISO."
    echo "Choose the actual installation disk."
    exit 1
fi

# ------------------------------------------------------------
# Variables for new partitions
# ------------------------------------------------------------

EFI_PART=""
SWAP_PART=""
ROOT_PART=""

# ============================================================
# ERASE MODE
# ============================================================

if [[ "$MODE" == "erase" ]]; then

    echo
    echo "ERASE MODE"
    echo "Creating a completely new GPT partition table on $DISK..."
    echo

    # This destroys the existing partition table.
    sfdisk --wipe always "$DISK" <<'EOF'
label: gpt
size=1G, type=U, name="EFI"
size=4G, type=S, name="swap"
size=+, type=L, name="root"
EOF

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle

    EFI_PART="$(part_path "$DISK" 1)"
    SWAP_PART="$(part_path "$DISK" 2)"
    ROOT_PART="$(part_path "$DISK" 3)"

    wait_for_partition "$EFI_PART"
    wait_for_partition "$SWAP_PART"
    wait_for_partition "$ROOT_PART"

# ============================================================
# ALL MODE
# ============================================================

else

    echo
    echo "ALL MODE"
    echo "Searching ONLY for unallocated/free space..."
    echo

    SECTOR_SIZE="$(blockdev --getss "$DISK")"

    if [[ -z "$SECTOR_SIZE" || "$SECTOR_SIZE" -le 0 ]]; then
        echo "ERROR: Could not determine disk sector size."
        exit 1
    fi

    # Find the largest contiguous unallocated region.
    #
    # sfdisk --list-free reports free, unpartitioned areas.
    # Existing partitions are never selected.
    BEST_START=""
    BEST_END=""
    BEST_SECTORS=0

    while read -r START END; do
        [[ "$START" =~ ^[0-9]+$ ]] || continue
        [[ "$END" =~ ^[0-9]+$ ]] || continue

        SECTORS=$((END - START + 1))

        if (( SECTORS > BEST_SECTORS )); then
            BEST_START="$START"
            BEST_END="$END"
            BEST_SECTORS="$SECTORS"
        fi
    done < <(
        sfdisk --list-free --no-reread "$DISK" 2>/dev/null |
        awk 'NR > 1 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {print $1, $2}'
    )

    if [[ -z "$BEST_START" || -z "$BEST_END" ]]; then
        echo "ERROR: No unallocated space exists on $DISK."
        echo "ALL mode will not modify existing partitions."
        exit 1
    fi

    # Align free-space boundaries to 1 MiB.
    ALIGN=$((1024 * 1024 / SECTOR_SIZE))

    if (( ALIGN < 1 )); then
        ALIGN=1
    fi

    ALIGNED_START=$(( ((BEST_START + ALIGN - 1) / ALIGN) * ALIGN ))
    ALIGNED_END=$(( ((BEST_END + 1) / ALIGN) * ALIGN - 1 ))

    if (( ALIGNED_END < ALIGNED_START )); then
        echo "ERROR: Free space is too small after alignment."
        exit 1
    fi

    AVAILABLE_SECTORS=$((ALIGNED_END - ALIGNED_START + 1))

    EFI_SECTORS=$((1024 * 1024 * 1024 / SECTOR_SIZE))
    SWAP_SECTORS=$((4 * 1024 * 1024 * 1024 / SECTOR_SIZE))

    # Require at least 2 GiB left for root.
    ROOT_MIN_SECTORS=$((2 * 1024 * 1024 * 1024 / SECTOR_SIZE))

    REQUIRED_SECTORS=$((EFI_SECTORS + SWAP_SECTORS + ROOT_MIN_SECTORS))

    if (( AVAILABLE_SECTORS < REQUIRED_SECTORS )); then
        echo "ERROR: The largest contiguous free area is too small."
        echo "ALL mode requires enough free space for:"
        echo " 1 GiB EFI"
        echo " 4 GiB swap"
        echo " at least 2 GiB root"
        echo
        echo "No partitions were modified."
        exit 1
    fi

    NEXT_PART="$(next_free_partition_number "$DISK")"

    EFI_START="$ALIGNED_START"
    EFI_END=$((EFI_START + EFI_SECTORS - 1))

    SWAP_START=$((EFI_END + 1))
    SWAP_END=$((SWAP_START + SWAP_SECTORS - 1))

    ROOT_START=$((SWAP_END + 1))
    ROOT_END="$ALIGNED_END"

    EFI_PART="$(part_path "$DISK" "$NEXT_PART")"
    SWAP_PART="$(part_path "$DISK" "$((NEXT_PART + 1))")"
    ROOT_PART="$(part_path "$DISK" "$((NEXT_PART + 2))")"

    echo "Free region selected:"
    echo " Start sector: $ALIGNED_START"
    echo " End sector: $ALIGNED_END"
    echo
    echo "Creating new partitions ONLY inside that free region..."

    sfdisk --append --no-reread "$DISK" <<EOF
${NEXT_PART}: start=${EFI_START}, size=${EFI_SECTORS}, type=U, name="EFI"
$((NEXT_PART + 1)): start=${SWAP_START}, size=${SWAP_SECTORS}, type=S, name="swap"
$((NEXT_PART + 2)): start=${ROOT_START}, size=$((ROOT_END - ROOT_START + 1)), type=L, name="root"
EOF

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle

    wait_for_partition "$EFI_PART"
    wait_for_partition "$SWAP_PART"
    wait_for_partition "$ROOT_PART"
fi

# ------------------------------------------------------------
# Verify that the new partitions exist
# ------------------------------------------------------------

if [[ ! -b "$EFI_PART" || ! -b "$SWAP_PART" || ! -b "$ROOT_PART" ]]; then
    echo "ERROR: New partitions were not detected."
    exit 1
fi

echo
echo "New partitions:"
echo "EFI : $EFI_PART"
echo "SWAP: $SWAP_PART"
echo "ROOT: $ROOT_PART"
echo

# ------------------------------------------------------------
# Format ONLY the new partitions
# ------------------------------------------------------------

echo "Formatting root..."
mkfs.ext4 -F "$ROOT_PART"

echo "Formatting swap..."
mkswap "$SWAP_PART"

echo "Formatting EFI..."
mkfs.fat -F 32 "$EFI_PART"

# ------------------------------------------------------------
# Mount
# ------------------------------------------------------------

echo "Mounting root..."
mount "$ROOT_PART" /mnt

echo "Mounting EFI..."
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "Enabling swap..."
swapon "$SWAP_PART"

# ------------------------------------------------------------
# Install Arch
# ------------------------------------------------------------

echo
echo "Installing Arch Linux..."
echo

pacstrap -K /mnt "${PACKAGES[@]}"

# ------------------------------------------------------------
# Generate fstab
# ------------------------------------------------------------

genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------------------------------------------
# Configure installed system
# ------------------------------------------------------------

echo
echo "Configuring installed system..."
echo

arch-chroot /mnt /bin/bash <<EOF
set -e

# Timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale
sed -i 's/^#${LOCALE} UTF-8/${LOCALE} UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=${LOCALE}' > /etc/locale.conf

# Keyboard
echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf

# Hostname
echo '${HOSTNAME}' > /etc/hostname

# Hosts file
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# Initramfs
mkinitcpio -P

# Root password
echo 'root:${ROOT_PASSWORD}' | chpasswd

# NetworkManager
systemctl enable NetworkManager

# os-prober
if grep -q '^#GRUB_DISABLE_OS_PROBER=false' /etc/default/grub; then
    sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
elif ! grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

# GRUB UEFI
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB

grub-mkconfig -o /boot/grub/grub.cfg
EOF

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

sync

swapoff "$SWAP_PART" 2>/dev/null || true

umount -R /mnt

echo
echo "============================================"
echo " Arch Linux installation completed."
echo "============================================"
echo
echo "Remove the Arch USB when the computer reboots."
echo

reboot
