#!/bin/bash

set -Eeuo pipefail

# ============================================================
# Automatic Arch Linux Installer
#
# Modes:
#
#   erase
#       Completely erase the selected disk.
#
#   all
#       Install only into unallocated space.
#       Existing partitions are preserved.
#
# Layout:
#
#   EFI  = 1 GiB
#   SWAP = 4 GiB
#   ROOT = remaining space
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


# ============================================================
# CONFIGURATION
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


# ============================================================
# FUNCTIONS
# ============================================================

error() {
    echo
    echo "============================================================"
    echo " ERROR"
    echo "============================================================"
    echo
    echo "$*"
    echo
    exit 1
}

info() {
    echo "==> $*"
}


# ------------------------------------------------------------
# Get partition path
# ------------------------------------------------------------

part_path() {
    local disk="$1"
    local number="$2"

    case "$disk" in
        /dev/nvme*|/dev/mmcblk*|/dev/loop*)
            printf '%sp%s\n' "$disk" "$number"
            ;;
        *)
            printf '%s%s\n' "$disk" "$number"
            ;;
    esac
}


# ------------------------------------------------------------
# Wait for partition device
# ------------------------------------------------------------

wait_for_partition() {
    local partition="$1"

    info "Waiting for $partition..."

    for _ in {1..30}; do

        if [[ -b "$partition" ]]; then
            return 0
        fi

        udevadm settle 2>/dev/null || true
        sleep 0.5

    done

    error "Partition did not appear: $partition"
}


# ------------------------------------------------------------
# Reload partition table
# ------------------------------------------------------------

reload_partition_table() {
    local disk="$1"

    info "Reloading partition table..."

    partprobe "$disk" 2>/dev/null || true
    udevadm settle

    sleep 1
}


# ------------------------------------------------------------
# Find next unused partition number
# ------------------------------------------------------------

next_free_partition_number() {
    local disk="$1"

    for number in $(seq 1 128); do

        local partition
        partition="$(part_path "$disk" "$number")"

        if ! lsblk -nrpo NAME "$disk" |
            grep -Fxq "$partition"; then

            printf '%s\n' "$number"
            return 0

        fi

    done

    error "No free partition number is available."
}


# ------------------------------------------------------------
# Check mounted partitions
# ------------------------------------------------------------

check_disk_not_mounted() {
    local disk="$1"

    if lsblk -nrpo MOUNTPOINT "$disk" |
        grep -qv '^$'; then

        error "The selected disk has mounted partitions.

Unmount them before running the installer."

    fi
}


# ============================================================
# START
# ============================================================

echo
echo "============================================================"
echo " Automatic Arch Linux Installer"
echo "============================================================"
echo


# ============================================================
# ROOT CHECK
# ============================================================

if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root."
fi


# ============================================================
# UEFI CHECK
# ============================================================

if [[ ! -d /sys/firmware/efi ]]; then

    error "The Arch ISO was not booted in UEFI mode.

Reboot and select the UEFI version of the Arch USB."

fi

info "UEFI boot detected."


# ============================================================
# REQUIRED COMMANDS
# ============================================================

info "Checking required commands..."

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
    partprobe
    udevadm
)

for command_name in "${REQUIRED_COMMANDS[@]}"; do

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "Required command not found: $command_name"
    fi

done

info "Required commands are available."


# ============================================================
# DISK DETECTION
# ============================================================

echo
echo "============================================================"
echo " Available disks"
echo "============================================================"
echo

# TYPE is the third column.
#
# This correctly detects disks even if MODEL is empty.
#
# Examples:
#
#   /dev/sda
#   /dev/nvme0n1
#   /dev/vda
#   /dev/mmcblk0

mapfile -t DISKS < <(
    lsblk -dpno NAME,SIZE,TYPE,MODEL |
    awk '
        $3 == "disk" {
            if ($4 != "")
                printf "%s|%s|%s\n", $1, $2, $4
            else
                printf "%s|%s|%s\n", $1, $2, "Unknown"
        }
    '
)


# ============================================================
# VERIFY DISKS
# ============================================================

if [[ ${#DISKS[@]} -eq 0 ]]; then

    echo
    echo "The Arch ISO reported:"
    echo

    lsblk -o NAME,SIZE,TYPE,MODEL

    echo

    error "No physical disks were detected."

fi


# ============================================================
# DISPLAY DISKS
# ============================================================

for i in "${!DISKS[@]}"; do

    IFS='|' read -r NAME SIZE MODEL <<< "${DISKS[$i]}"

    printf "%2d) %-14s %-8s %s\n" \
        "$((i + 1))" \
        "$NAME" \
        "$SIZE" \
        "$MODEL"

done

echo

read -r -p "Choose disk number: " DISK_NUMBER


# ============================================================
# VALIDATE DISK SELECTION
# ============================================================

if ! [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]]; then
    error "Invalid disk number."
fi

if (( DISK_NUMBER < 1 ||
      DISK_NUMBER > ${#DISKS[@]} )); then

    error "Invalid disk number."

fi


DISK_ENTRY="${DISKS[$((DISK_NUMBER - 1))]}"

IFS='|' read -r DISK DISK_SIZE DISK_MODEL <<< "$DISK_ENTRY"


echo
echo "Selected disk:"
echo
echo "  Device : $DISK"
echo "  Size   : $DISK_SIZE"
echo "  Model  : $DISK_MODEL"
echo


# ============================================================
# PROTECT RUNNING ARCH ISO
# ============================================================

ROOT_SOURCE="$(findmnt -no SOURCE / 2>/dev/null || true)"

if [[ -n "$ROOT_SOURCE" ]]; then

    case "$ROOT_SOURCE" in

        "$DISK"|"$DISK"*)
            error "The selected disk appears to contain the currently running Arch ISO.

You cannot install Arch onto the disk containing the running ISO."
            ;;

    esac

fi


# ============================================================
# CHECK MOUNT STATUS
# ============================================================

check_disk_not_mounted "$DISK"


# ============================================================
# INSTALLATION MODE
# ============================================================

echo
echo "============================================================"
echo " Installation mode"
echo "============================================================"
echo

echo "  erase"
echo "      Completely erase the selected disk."
echo

echo "  all"
echo "      Install only into unallocated space."
echo "      Existing partitions are preserved."
echo

read -r -p "Choose mode (erase/all): " MODE


case "$MODE" in

    erase)
        ;;

    all)
        ;;

    *)
        error "Mode must be exactly 'erase' or 'all'."
        ;;

esac


# ============================================================
# FINAL CONFIRMATION
# ============================================================

echo
echo "============================================================"
echo " FINAL CONFIRMATION"
echo "============================================================"
echo

echo "Selected disk : $DISK"
echo "Disk size     : $DISK_SIZE"
echo "Mode          : $MODE"
echo


if [[ "$MODE" == "erase" ]]; then

    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
    echo "WARNING: ERASE MODE WILL DESTROY ALL DATA ON $DISK"
    echo
    echo "Every existing partition on this disk will be removed."
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

else

    echo "ALL MODE will:"
    echo
    echo "  - preserve existing partitions"
    echo "  - find the largest unallocated region"
    echo "  - create EFI + swap + root there"
    echo "  - format ONLY the newly-created partitions"
    echo

fi

echo

read -r -p "Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then

    echo
    echo "Installation cancelled."
    exit 0

fi


# ============================================================
# PARTITION VARIABLES
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

    info "Creating new GPT partition table on $DISK..."

    sfdisk --wipe always "$DISK" <<'EOF'
label: gpt

size=1G, type=U, name="EFI"
size=4G, type=S, name="swap"
size=, type=L, name="root"
EOF

    reload_partition_table "$DISK"


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

    info "Searching for unallocated space..."

    SECTOR_SIZE="$(blockdev --getss "$DISK")"

    if ! [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] ||
       (( SECTOR_SIZE == 0 )); then

        error "Could not determine the disk sector size."

    fi


    # --------------------------------------------------------
    # Find largest contiguous free region
    # --------------------------------------------------------

    BEST_START=""
    BEST_END=""
    BEST_SECTORS=0


    while read -r START END; do

        [[ "$START" =~ ^[0-9]+$ ]] || continue
        [[ "$END" =~ ^[0-9]+$ ]] || continue

        if (( END < START )); then
            continue
        fi

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


    # --------------------------------------------------------
    # Make sure free space exists
    # --------------------------------------------------------

    if [[ -z "$BEST_START" ||
          -z "$BEST_END" ]]; then

        echo
        echo "Current partition layout:"
        echo

        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"

        echo

        error "No unallocated space was found on $DISK.

ALL mode will not modify existing partitions."

    fi


    # --------------------------------------------------------
    # 1 MiB alignment
    # --------------------------------------------------------

    ALIGNMENT=$((1024 * 1024 / SECTOR_SIZE))

    if (( ALIGNMENT < 1 )); then
        ALIGNMENT=1
    fi


    ALIGNED_START=$(
        ((BEST_START + ALIGNMENT - 1) / ALIGNMENT) * ALIGNMENT
    )


    ALIGNED_END=$(
        ((BEST_END + 1) / ALIGNMENT) * ALIGNMENT - 1
    )


    if (( ALIGNED_END < ALIGNED_START )); then

        error "The available free space is too small after alignment."

    fi


    AVAILABLE_SECTORS=$(
        ALIGNED_END - ALIGNED_START + 1
    )


    # --------------------------------------------------------
    # Partition sizes
    # --------------------------------------------------------

    EFI_SECTORS=$(
        (1024 * 1024 * 1024) / SECTOR_SIZE
    )

    SWAP_SECTORS=$(
        (4 * 1024 * 1024 * 1024) / SECTOR_SIZE
    )

    ROOT_MIN_SECTORS=$(
        (2 * 1024 * 1024 * 1024) / SECTOR_SIZE
    )

    REQUIRED_SECTORS=$(
        EFI_SECTORS +
        SWAP_SECTORS +
        ROOT_MIN_SECTORS
    )


    if (( AVAILABLE_SECTORS < REQUIRED_SECTORS )); then

        AVAILABLE_GIB=$(
            awk \
                -v s="$AVAILABLE_SECTORS" \
                -v b="$SECTOR_SIZE" \
                'BEGIN {
                    printf "%.2f", (s*b)/(1024^3)
                }'
        )

        error "The largest free-space region is too small.

Available: ${AVAILABLE_GIB} GiB

Required:
  EFI  : 1 GiB
  SWAP : 4 GiB
  ROOT : at least 2 GiB"

    fi


    # --------------------------------------------------------
    # Partition numbers
    # --------------------------------------------------------

    NEXT_PART="$(next_free_partition_number "$DISK")"

    EFI_NUMBER="$NEXT_PART"
    SWAP_NUMBER="$((NEXT_PART + 1))"
    ROOT_NUMBER="$((NEXT_PART + 2))"


    # --------------------------------------------------------
    # Partition boundaries
    # --------------------------------------------------------

    EFI_START="$ALIGNED_START"

    EFI_END=$(
        EFI_START + EFI_SECTORS - 1
    )


    SWAP_START=$(
        EFI_END + 1
    )

    SWAP_END=$(
        SWAP_START + SWAP_SECTORS - 1
    )


    ROOT_START=$(
        SWAP_END + 1
    )

    ROOT_END="$ALIGNED_END"


    ROOT_SECTORS=$(
        ROOT_END - ROOT_START + 1
    )


    if (( ROOT_SECTORS < ROOT_MIN_SECTORS )); then

        error "Internal partition calculation error:
root partition is too small."

    fi


    EFI_PART="$(part_path "$DISK" "$EFI_NUMBER")"
    SWAP_PART="$(part_path "$DISK" "$SWAP_NUMBER")"
    ROOT_PART="$(part_path "$DISK" "$ROOT_NUMBER")"


    # --------------------------------------------------------
    # Show planned partitions
    # --------------------------------------------------------

    echo
    echo "Free space selected:"
    echo
    echo "  Start sector : $ALIGNED_START"
    echo "  End sector   : $ALIGNED_END"
    echo

    echo "New partitions:"
    echo
    echo "  EFI"
    echo "    Device : $EFI_PART"
    echo "    Size   : 1 GiB"
    echo

    echo "  SWAP"
    echo "    Device : $SWAP_PART"
    echo "    Size   : 4 GiB"
    echo

    echo "  ROOT"
    echo "    Device : $ROOT_PART"
    echo "    Size   : remaining free space"
    echo


    # --------------------------------------------------------
    # Create partitions
    # --------------------------------------------------------

    info "Creating partitions inside the unallocated region..."

    sfdisk --append --no-reread "$DISK" <<EOF
${EFI_NUMBER}: start=${EFI_START}, size=${EFI_SECTORS}, type=U, name="EFI"
${SWAP_NUMBER}: start=${SWAP_START}, size=${SWAP_SECTORS}, type=S, name="swap"
${ROOT_NUMBER}: start=${ROOT_START}, size=${ROOT_SECTORS}, type=L, name="root"
EOF


    reload_partition_table "$DISK"


    wait_for_partition "$EFI_PART"
    wait_for_partition "$SWAP_PART"
    wait_for_partition "$ROOT_PART"

fi


# ============================================================
# VERIFY PARTITIONS
# ============================================================

echo
echo "============================================================"
echo " Verifying partitions"
echo "============================================================"
echo


for PARTITION in \
    "$EFI_PART" \
    "$SWAP_PART" \
    "$ROOT_PART"
do

    if [[ ! -b "$PARTITION" ]]; then

        error "Expected partition does not exist:
$PARTITION"

    fi

done


info "EFI  : $EFI_PART"
info "SWAP : $SWAP_PART"
info "ROOT : $ROOT_PART"


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


info "Formatting EFI as FAT32..."

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


info "Creating /mnt/boot..."

mkdir -p /mnt/boot


info "Mounting EFI..."

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


info "Installing base system and packages..."

pacstrap -K /mnt "${PACKAGES[@]}"


# ============================================================
# FSTAB
# ============================================================

echo
echo "============================================================"
echo " Generating fstab"
echo "============================================================"
echo


genfstab -U /mnt > /mnt/etc/fstab

info "fstab generated."


# ============================================================
# CONFIGURE INSTALLED SYSTEM
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

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

hwclock --systohc


# ------------------------------------------------------------
# Locale
# ------------------------------------------------------------

sed -i \
    's/^#${LOCALE} UTF-8/${LOCALE} UTF-8/' \
    /etc/locale.gen

locale-gen

echo "LANG=${LOCALE}" > /etc/locale.conf


# ------------------------------------------------------------
# Keyboard
# ------------------------------------------------------------

echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf


# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

echo "${HOSTNAME}" > /etc/hostname


# ------------------------------------------------------------
# Hosts
# ------------------------------------------------------------

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

echo "root:${ROOT_PASSWORD}" | chpasswd


# ------------------------------------------------------------
# NetworkManager
# ------------------------------------------------------------

systemctl enable NetworkManager


# ------------------------------------------------------------
# GRUB os-prober
# ------------------------------------------------------------

if grep -q '^#GRUB_DISABLE_OS_PROBER=false' \
    /etc/default/grub; then

    sed -i \
        's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' \
        /etc/default/grub

elif ! grep -q '^GRUB_DISABLE_OS_PROBER=' \
    /etc/default/grub; then

    echo 'GRUB_DISABLE_OS_PROBER=false' \
        >> /etc/default/grub

fi


# ------------------------------------------------------------
# Install GRUB UEFI
# ------------------------------------------------------------

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB


# ------------------------------------------------------------
# Generate GRUB configuration
# ------------------------------------------------------------

grub-mkconfig \
    -o /boot/grub/grub.cfg

EOF


# ============================================================
# FINISH
# ============================================================

echo
echo "============================================================"
echo " Finalizing installation"
echo "============================================================"
echo


info "Syncing filesystems..."

sync


info "Disabling swap..."

swapoff "$SWAP_PART" 2>/dev/null || true


info "Unmounting installed system..."

umount -R /mnt


sync


# ============================================================
# COMPLETE
# ============================================================

echo
echo "============================================================"
echo "        ARCH LINUX INSTALLATION COMPLETE"
echo "============================================================"
echo

echo "Disk : $DISK"
echo "Mode : $MODE"
echo

echo "Remove the Arch USB when the computer reboots."
echo

read -r -p "Press ENTER to reboot..."

reboot
