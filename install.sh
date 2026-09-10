#!/bin/bash

set -Eeuo pipefail

# ============================================================
# Simple Automatic Arch Linux Installer
#
# Modes:
#   erase = completely wipe selected disk
#   all   = install only into unallocated space
#
# Filesystem:
#   ext4
#
# Boot:
#   UEFI + GRUB
#
# Kernel:
#   linux-zen
#
# ============================================================

HOSTNAME="Arch"
TIMEZONE="Europe/Rome"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# WARNING:
# This password is intentionally set here because that is how
# the original script was configured.
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
# Colors / output helpers
# ------------------------------------------------------------

RED=""
GREEN=""
YELLOW=""
RESET=""

error() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

info() {
    echo "==> $*"
}

warn() {
    echo "WARNING: $*"
}

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root."
fi

# ------------------------------------------------------------
# UEFI check
# ------------------------------------------------------------

if [[ ! -d /sys/firmware/efi ]]; then
    error "The Arch ISO was not booted in UEFI mode.

Boot the Arch USB in UEFI mode and run the installer again."
fi

# ------------------------------------------------------------
# Required commands
# ------------------------------------------------------------

REQUIRED_COMMANDS=(
    lsblk
    sfdisk
    fdisk
    mkfs.ext4
    mkfs.fat
    mkswap
    swapon
    swapoff
    pacstrap
    genfstab
    arch-chroot
    blkid
    blockdev
    mount
    umount
    findmnt
    awk
    grep
    sed
    sync
    reboot
    ping
    partprobe
    udevadm
)

info "Checking required commands..."

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command not found: $cmd"
    fi
done

# ------------------------------------------------------------
# Network check
# ------------------------------------------------------------

check_network() {
    info "Checking internet connection..."

    # First test raw connectivity.
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then

        # Then test DNS.
        if ping -c 1 -W 3 archlinux.org >/dev/null 2>&1; then
            info "Internet connection OK."
            return 0
        fi

        error "Internet connectivity works, but DNS is not working.

Try:

    ping -c 1 1.1.1.1
    ping -c 1 archlinux.org

If the first works and the second fails, fix DNS before
running the installer again."
    fi

    error "No internet connection.

Check your network connection in the Arch ISO.

For Wi-Fi, use:

    iwctl

Then connect to your network and run the installer again."
}

# ------------------------------------------------------------
# Partition path helper
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

# ------------------------------------------------------------
# Wait for partition to appear
# ------------------------------------------------------------

wait_for_partition() {
    local part="$1"

    info "Waiting for $part to appear..."

    for _ in {1..30}; do
        if [[ -b "$part" ]]; then
            return 0
        fi

        sleep 0.5
        udevadm settle 2>/dev/null || true
    done

    error "Partition did not appear: $part"
}

# ------------------------------------------------------------
# Refresh partition table
# ------------------------------------------------------------

refresh_partition_table() {
    local disk="$1"

    partprobe "$disk" 2>/dev/null || true
    udevadm settle
    sleep 1
}

# ------------------------------------------------------------
# Find available partition number
# ------------------------------------------------------------

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

    error "No free GPT partition number available."
}

# ------------------------------------------------------------
# Check whether disk contains mounted partitions
# ------------------------------------------------------------

check_disk_not_mounted() {
    local disk="$1"

    if lsblk -nrpo NAME,MOUNTPOINT "$disk" |
        awk '$2 != "" {found=1} END {exit !found}'
    then
        error "The selected disk has mounted partitions.

Unmount them before running the installer."
    fi
}

# ------------------------------------------------------------
# Display disks
# ------------------------------------------------------------

show_disks() {
    echo
    echo "============================================================"
    echo " Available disks"
    echo "============================================================"
    echo

    mapfile -t DISKS < <(
        lsblk -dpno NAME,SIZE,MODEL,TYPE |
        awk '$4 == "disk" {print}'
    )

    if [[ ${#DISKS[@]} -eq 0 ]]; then
        echo
        echo "lsblk output:"
        lsblk -o NAME,SIZE,TYPE,MODEL
        echo
        error "No physical disks were detected by the Arch ISO."
    fi

    for i in "${!DISKS[@]}"; do
        printf "%2d) %s\n" "$((i + 1))" "${DISKS[$i]}"
    done

    echo
}

# ============================================================
# DISK SELECTION
# ============================================================

show_disks

read -r -p "Choose disk number: " DISK_NUMBER

if ! [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]]; then
    error "Invalid disk number."
fi

if (( DISK_NUMBER < 1 || DISK_NUMBER > ${#DISKS[@]} )); then
    error "Invalid disk number."
fi

DISK_LINE="${DISKS[$((DISK_NUMBER - 1))]}"
DISK="$(awk '{print $1}' <<< "$DISK_LINE")"

echo
echo "Selected disk:"
echo "  $DISK_LINE"
echo

# ------------------------------------------------------------
# Prevent selecting the running ISO
# ------------------------------------------------------------

ROOT_SOURCE="$(findmnt -no SOURCE / 2>/dev/null || true)"

if [[ -n "$ROOT_SOURCE" ]]; then
    case "$ROOT_SOURCE" in
        "$DISK"|"$DISK"*)
            error "The selected disk appears to contain the currently running Arch ISO.

Choose the actual installation disk."
            ;;
    esac
fi

# ------------------------------------------------------------
# Check disk is not mounted
# ------------------------------------------------------------

check_disk_not_mounted "$DISK"

# ============================================================
# MODE SELECTION
# ============================================================

echo "Choose installation mode:"
echo
echo "  erase = completely erase the selected disk"
echo "  all   = install only into unallocated space"
echo

read -r -p "Mode (erase/all): " MODE

case "$MODE" in
    erase|all)
        ;;
    *)
        error "Mode must be exactly 'erase' or 'all'."
        ;;
esac

# ============================================================
# FINAL SAFETY CONFIRMATION
# ============================================================

echo
echo "============================================================"
echo " WARNING"
echo "============================================================"
echo
echo "Disk : $DISK"
echo "Mode : $MODE"
echo

if [[ "$MODE" == "erase" ]]; then
    echo "ERASE mode will DESTROY ALL DATA on:"
    echo
    echo "    $DISK"
    echo
else
    echo "ALL mode will only create partitions inside unallocated"
    echo "space on:"
    echo
    echo "    $DISK"
    echo
    echo "Existing partitions will NOT be formatted."
fi

echo
read -r -p "Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo
    echo "Installation cancelled."
    exit 0
fi

# ============================================================
# NOW CHECK NETWORK
# ============================================================

check_network

# ============================================================
# VARIABLES
# ============================================================

EFI_PART=""
SWAP_PART=""
ROOT_PART=""

# ============================================================
# ERASE MODE
# ============================================================

if [[ "$MODE" == "erase" ]]; then

    echo
    echo "============================================================"
    echo " ERASE MODE"
    echo "============================================================"
    echo

    info "Wiping existing partition table..."

    sfdisk --wipe always "$DISK" <<'EOF'
label: gpt

size=1G, type=U, name="EFI"
size=4G, type=S, name="swap"
size=, type=L, name="root"
EOF

    refresh_partition_table "$DISK"

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
    echo "============================================================"
    echo " ALL MODE"
    echo "============================================================"
    echo

    info "Looking for unallocated space..."

    SECTOR_SIZE="$(blockdev --getss "$DISK")"

    if [[ -z "$SECTOR_SIZE" || "$SECTOR_SIZE" -le 0 ]]; then
        error "Could not determine disk sector size."
    fi

    # --------------------------------------------------------
    # Find largest free region
    # --------------------------------------------------------

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
        awk '
            $1 ~ /^[0-9]+$/ &&
            $2 ~ /^[0-9]+$/ {
                print $1, $2
            }
        '
    )

    if [[ -z "$BEST_START" || -z "$BEST_END" ]]; then
        error "No unallocated space was found on $DISK.

ALL mode will not modify existing partitions."
    fi

    # --------------------------------------------------------
    # Align to 1 MiB
    # --------------------------------------------------------

    ALIGN=$((1024 * 1024 / SECTOR_SIZE))

    (( ALIGN < 1 )) && ALIGN=1

    ALIGNED_START=$(
        ((BEST_START + ALIGN - 1) / ALIGN) * ALIGN
    )

    ALIGNED_END=$(
        ((BEST_END + 1) / ALIGN) * ALIGN - 1
    )

    if (( ALIGNED_END < ALIGNED_START )); then
        error "Free space is too small after alignment."
    fi

    AVAILABLE_SECTORS=$((ALIGNED_END - ALIGNED_START + 1))

    # --------------------------------------------------------
    # Partition sizes
    # --------------------------------------------------------

    EFI_SECTORS=$((1024 * 1024 * 1024 / SECTOR_SIZE))
    SWAP_SECTORS=$((4 * 1024 * 1024 * 1024 / SECTOR_SIZE))

    ROOT_MIN_SECTORS=$(
        2 * 1024 * 1024 * 1024 / SECTOR_SIZE
    )

    REQUIRED_SECTORS=$(
        EFI_SECTORS +
        SWAP_SECTORS +
        ROOT_MIN_SECTORS
    )

    if (( AVAILABLE_SECTORS < REQUIRED_SECTORS )); then
        error "The largest unallocated area is too small.

ALL mode requires at least:
  1 GiB EFI
  4 GiB swap
  2 GiB root"
    fi

    # --------------------------------------------------------
    # Partition numbers
    # --------------------------------------------------------

    NEXT_PART="$(next_free_partition_number "$DISK")"

    EFI_NUMBER="$NEXT_PART"
    SWAP_NUMBER="$((NEXT_PART + 1))"
    ROOT_NUMBER="$((NEXT_PART + 2))"

    EFI_START="$ALIGNED_START"
    EFI_END=$((EFI_START + EFI_SECTORS - 1))

    SWAP_START=$((EFI_END + 1))
    SWAP_END=$((SWAP_START + SWAP_SECTORS - 1))

    ROOT_START=$((SWAP_END + 1))
    ROOT_END="$ALIGNED_END"

    EFI_PART="$(part_path "$DISK" "$EFI_NUMBER")"
    SWAP_PART="$(part_path "$DISK" "$SWAP_NUMBER")"
    ROOT_PART="$(part_path "$DISK" "$ROOT_NUMBER")"

    # --------------------------------------------------------
    # Show exactly what will be created
    # --------------------------------------------------------

    echo
    echo "Free space selected:"
    echo
    echo "  EFI : $EFI_PART"
    echo "        1 GiB"
    echo
    echo "  SWAP: $SWAP_PART"
    echo "        4 GiB"
    echo
    echo "  ROOT: $ROOT_PART"
    echo "        remaining free space"
    echo

    info "Creating partitions inside free space..."

    sfdisk --append --no-reread "$DISK" <<EOF
${EFI_NUMBER}: start=${EFI_START}, size=${EFI_SECTORS}, type=U, name="EFI"
${SWAP_NUMBER}: start=${SWAP_START}, size=${SWAP_SECTORS}, type=S, name="swap"
${ROOT_NUMBER}: start=${ROOT_START}, size=$((ROOT_END - ROOT_START + 1)), type=L, name="root"
EOF

    refresh_partition_table "$DISK"

    wait_for_partition "$EFI_PART"
    wait_for_partition "$SWAP_PART"
    wait_for_partition "$ROOT_PART"

fi

# ============================================================
# VERIFY PARTITIONS
# ============================================================

echo
echo "============================================================"
echo " New partitions"
echo "============================================================"
echo

echo "EFI : $EFI_PART"
echo "SWAP: $SWAP_PART"
echo "ROOT: $ROOT_PART"
echo

for part in "$EFI_PART" "$SWAP_PART" "$ROOT_PART"; do
    if [[ ! -b "$part" ]]; then
        error "Expected partition does not exist: $part"
    fi
done

# ============================================================
# FORMAT
# ============================================================

echo
echo "============================================================"
echo " Formatting"
echo "============================================================"
echo

info "Formatting root as ext4..."

mkfs.ext4 -F "$ROOT_PART"

info "Formatting swap..."

mkswap "$SWAP_PART"

info "Formatting EFI partition as FAT32..."

mkfs.fat -F 32 "$EFI_PART"

# ============================================================
# MOUNT
# ============================================================

echo
echo "============================================================"
echo " Mounting"
echo "============================================================"
echo

info "Mounting root..."

mount "$ROOT_PART" /mnt

info "Mounting EFI..."

mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

info "Enabling swap..."

swapon "$SWAP_PART"

# ============================================================
# INSTALL ARCH
# ============================================================

echo
echo "============================================================"
echo " Installing Arch Linux"
echo "============================================================"
echo

info "Installing packages..."

pacstrap -K /mnt "${PACKAGES[@]}"

# ============================================================
# FSTAB
# ============================================================

info "Generating fstab..."

genfstab -U /mnt > /mnt/etc/fstab

# ============================================================
# CONFIGURE SYSTEM
# ============================================================

echo
echo "============================================================"
echo " Configuring installed system"
echo "============================================================"
echo

arch-chroot /mnt /bin/bash <<EOF
set -Eeuo pipefail

# ------------------------------------------------------------
# Timezone
# ------------------------------------------------------------

ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# ------------------------------------------------------------
# Locale
# ------------------------------------------------------------

sed -i 's/^#${LOCALE} UTF-8/${LOCALE} UTF-8/' /etc/locale.gen

locale-gen

echo 'LANG=${LOCALE}' > /etc/locale.conf

# ------------------------------------------------------------
# Keyboard
# ------------------------------------------------------------

echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf

# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

echo '${HOSTNAME}' > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# ------------------------------------------------------------
# Initramfs
# ------------------------------------------------------------

mkinitcpio -P

# ------------------------------------------------------------
# Root password
# ------------------------------------------------------------

echo 'root:${ROOT_PASSWORD}' | chpasswd

# ------------------------------------------------------------
# NetworkManager
# ------------------------------------------------------------

systemctl enable NetworkManager

# ------------------------------------------------------------
# GRUB os-prober
# ------------------------------------------------------------

if grep -q '^#GRUB_DISABLE_OS_PROBER=false' /etc/default/grub; then
    sed -i \
        's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' \
        /etc/default/grub
elif ! grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

# ------------------------------------------------------------
# GRUB UEFI installation
# ------------------------------------------------------------

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB

# ------------------------------------------------------------
# GRUB configuration
# ------------------------------------------------------------

grub-mkconfig -o /boot/grub/grub.cfg

EOF

# ============================================================
# FINISH
# ============================================================

echo
echo "============================================================"
echo " Finishing installation"
echo "============================================================"
echo

info "Syncing disks..."

sync

info "Disabling swap..."

swapoff "$SWAP_PART" 2>/dev/null || true

info "Unmounting..."

umount -R /mnt

echo
echo "============================================================"
echo "        ARCH LINUX INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Disk : $DISK"
echo "Mode : $MODE"
echo
echo "Remove the Arch USB when the computer restarts."
echo

read -r -p "Press ENTER to reboot..."

reboot
