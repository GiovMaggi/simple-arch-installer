#!/bin/bash
set -Eeuo pipefail

# Configuration
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
  fuse3
  ntfs-3g
)

# Helper Functions
error() {
  echo
  echo '============================================================'
  echo ' ERROR'
  echo '============================================================'
  echo
  echo "$*"
  echo
  exit 1
}

info() {
  echo "==> $*"
}

part_path() {
  case "$1" in
    /dev/nvme*|/dev/mmcblk*|/dev/loop*) printf '%sp%s\n' "$1" "$2" ;;
    *)                              printf '%s%s\n' "$1" "$2" ;;
  esac
}

wait_for_partition() {
  local p="$1"
  info "Waiting for $p..."
  for _ in {1..30}; do
    [[ -b "$p" ]] && return 0
    udevadm settle 2>/dev/null || true
    sleep .5
  done
  error "Partition did not appear: $p"
}

reload_partition_table() {
  partprobe "$1" 2>/dev/null || true
  udevadm settle
  sleep 1
}

next_free_partition_number() {
  local d="$1" n p
  for n in $(seq 1 128); do
    p="$(part_path "$d" "$n")"
    if ! lsblk -nrpo NAME "$d" | grep -Fxq "$p"; then
      echo "$n"
      return
    fi
  done
  error 'No free partition number is available.'
}

check_disk_not_mounted() {
  if lsblk -nrpo MOUNTPOINT "$1" | grep -qv '^$'; then
    error 'The selected disk has mounted partitions.\n\nUnmount them before running the installer.'
  fi
}

build_other_os_entries() {
  local arch="$1" out="$2" esp uuid mp file rel label dir key
  declare -A seen=()
  : > "$out"
  
  printf '%s\n' '#!/bin/sh' 'case "$grub_platform" in efi) ;; *) exit 0;; esac' >> "$out"
  
  while read -r esp; do
    [[ -b "$esp" && "$esp" != "$arch" ]] || continue
    uuid="$(blkid -s UUID -o value "$esp" 2>/dev/null || true)"
    [[ -n "$uuid" ]] || continue
    
    mp="$(mktemp -d /tmp/esp-probe.XXXXXX)"
    mount -o ro "$esp" "$mp" 2>/dev/null || { rmdir "$mp"; continue; }
    
    while IFS= read -r -d '' file; do
      rel="${file#"$mp"}"
      label=''
      case "${rel,,}" in
        /efi/microsoft/boot/bootmgfw.efi) label='Windows Boot Manager' ;;
        /efi/*/shimx64.efi)             dir="$(basename "$(dirname "$rel")")"; label="${dir^} Linux Bootloader" ;;
        /efi/*/grubx64.efi)             dir="$(basename "$(dirname "$rel")")"; label="${dir^} GRUB Bootloader" ;;
        /efi/*/systemd-bootx64.efi)     dir="$(basename "$(dirname "$rel")")"; label="${dir^} systemd-boot" ;;
        *) continue ;;
      esac
      
      key="$uuid:${rel,,}"
      [[ -n "${seen[$key]+x}" ]] && continue
      seen[$key]=1
      
      cat >> "$out" <<EOT
menuentry '$label' {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root $uuid
    chainloader $rel
}
EOT
    done < <(find "$mp/EFI" -type f -iname '*.efi' -print0 2>/dev/null)
    
    umount -l "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
  done < <(lsblk -nrpo NAME,FSTYPE,TYPE | awk '$2=="vfat"&&$3=="part"{print $1}')
  
  chmod 755 "$out"
}

# Prompt for the new user *before* starting disk operations
echo
read -r -p 'Enter username for the new account: ' NEW_USER
[[ -n "$NEW_USER" ]] || error 'Username cannot be empty.'

# System Checks
[[ $EUID -eq 0 ]] || error 'This installer must be run as root.'
[[ -d /sys/firmware/efi ]] || error 'The Arch ISO was not booted in UEFI mode.'

for c in lsblk sfdisk fdisk mkfs.ext4 mkfs.fat mkswap swapon swapoff pacstrap genfstab arch-chroot blkid blockdev mount umount findmnt awk grep sed partprobe udevadm find mktemp; do
  command -v "$c" >/dev/null 2>&1 || error "Required command not found: $c"
done

info 'UEFI boot detected.'
info 'Required commands are available.'

# Disk Selection
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{m=$4;for(i=5;i<=NF;i++)m=m" " $i;if(m=="")m="Unknown";printf "%s|%s|%s\n",$1,$2,m}')
[[ ${#DISKS[@]} -gt 0 ]] || { lsblk -o NAME,SIZE,TYPE,MODEL; error 'No physical disks were detected.'; }

for i in "${!DISKS[@]}"; do
  IFS='|' read -r n s m <<< "${DISKS[$i]}"
  printf '%2d) %-16s %-8s %s\n' "$((i+1))" "$n" "$s" "$m"
done

echo
read -r -p 'Choose disk number: ' DN
[[ "$DN" =~ ^[0-9]+$ ]] && ((DN >= 1 && DN <= ${#DISKS[@]})) || error 'Invalid disk number.'

IFS='|' read -r DISK DISK_SIZE DISK_MODEL <<< "${DISKS[$((DN-1))]}"
ROOT_SOURCE="$(findmnt -no SOURCE / 2>/dev/null || true)"

case "$ROOT_SOURCE" in
  "$DISK"|"$DISK"*) error 'The selected disk contains the currently running Arch ISO.' ;;
esac

check_disk_not_mounted "$DISK"

echo
echo 'Installation mode: erase = destroy disk, all = preserve partitions/use free space'
read -r -p 'Choose mode (erase/all): ' MODE
[[ "$MODE" == "erase" || "$MODE" == "all" ]] || error "Mode must be exactly 'erase' or 'all'."

echo
echo "Selected disk : $DISK"
echo "Disk size     : $DISK_SIZE"
echo "Mode          : $MODE"
[[ "$MODE" == "erase" ]] && echo 'WARNING: ERASE MODE WILL DESTROY ALL DATA ON THIS DISK.'

read -r -p 'Type YES to continue: ' CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo 'Installation cancelled.'; exit 0; }

# Partitioning Strategy
EFI_PART=''
SWAP_PART=''
ROOT_PART=''

if [[ "$MODE" == "erase" ]]; then
  sfdisk --wipe always "$DISK" <<'EOT'
label: gpt
size=1G, type=U, name="EFI"
size=4G, type=S, name="swap"
type=L, name="root"
EOT

  reload_partition_table "$DISK"
  EFI_PART="$(part_path "$DISK" 1)"
  SWAP_PART="$(part_path "$DISK" 2)"
  ROOT_PART="$(part_path "$DISK" 3)"
  
  wait_for_partition "$EFI_PART"
  wait_for_partition "$SWAP_PART"
  wait_for_partition "$ROOT_PART"
else
  SECTOR_SIZE="$(blockdev --getss "$DISK")"
  [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] && ((SECTOR_SIZE > 0)) || error 'Invalid sector size.'
  
  BEST_START=''
  BEST_END=''
  BEST_SECTORS=0

  while read -r START END; do
    [[ "$START" =~ ^[0-9]+$ && "$END" =~ ^[0-9]+$ ]] || continue
    ((END >= START)) || continue
    CUR=$((END - START + 1))
    if ((CUR > BEST_SECTORS)); then
      BEST_START="$START"
      BEST_END="$END"
      BEST_SECTORS="$CUR"
    fi
  done < <(sfdisk --list-free "$DISK" 2>/dev/null | awk '$1~/^[0-9]+$/&&$2~/^[0-9]+$/{print $1,$2}')

  [[ -n "$BEST_START" ]] || error 'No usable unallocated space was found.'
  
  ALIGNMENT=$((1024 * 1024 / SECTOR_SIZE))
  ((ALIGNMENT < 1)) && ALIGNMENT=1
  
  ALIGNED_START=$(((BEST_START + ALIGNMENT - 1) / ALIGNMENT * ALIGNMENT))
  ALIGNED_END=$(((BEST_END + 1) / ALIGNMENT * ALIGNMENT - 1))
  
  ((ALIGNED_END >= ALIGNED_START)) || error 'Free space is too small after alignment.'
  
  AVAILABLE=$((ALIGNED_END - ALIGNED_START + 1))
  EFI_SECTORS=$((1024 * 1024 * 1024 / SECTOR_SIZE))
  SWAP_SECTORS=$((4 * 1024 * 1024 * 1024 / SECTOR_SIZE))
  ROOT_MIN=$((2 * 1024 * 1024 * 1024 / SECTOR_SIZE))
  
  ((AVAILABLE >= EFI_SECTORS + SWAP_SECTORS + ROOT_MIN)) || error 'Largest free-space region is too small.'

  N="$(next_free_partition_number "$DISK")"
  E=$N
  S=$((N + 1))
  R=$((N + 2))

  EFI_START=$ALIGNED_START
  EFI_END=$((EFI_START + EFI_SECTORS - 1))
  SWAP_START=$((EFI_END + 1))
  SWAP_END=$((SWAP_START + SWAP_SECTORS - 1))
  ROOT_START=$((SWAP_END + 1))
  ROOT_END=$ALIGNED_END
  ROOT_SECTORS=$((ROOT_END - ROOT_START + 1))

  EFI_PART="$(part_path "$DISK" "$E")"
  SWAP_PART="$(part_path "$DISK" "$S")"
  ROOT_PART="$(part_path "$DISK" "$R")"

  sfdisk --append "$DISK" <<EOT
$E : start=$EFI_START, size=$EFI_SECTORS, type=U, name="EFI"
$S : start=$SWAP_START, size=$SWAP_SECTORS, type=S, name="swap"
$R : start=$ROOT_START, size=$ROOT_SECTORS, type=L, name="root"
EOT

  reload_partition_table "$DISK"
  wait_for_partition "$EFI_PART"
  wait_for_partition "$SWAP_PART"
  wait_for_partition "$ROOT_PART"
fi

for p in "$EFI_PART" "$SWAP_PART" "$ROOT_PART"; do
  [[ -b "$p" ]] || error "Expected partition does not exist: $p"
done

# Formatting and Mounting
mkfs.ext4 -F "$ROOT_PART"
mkswap "$SWAP_PART"
mkfs.fat -F 32 "$EFI_PART"

mkdir -p /mnt
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
swapon "$SWAP_PART"

# Installation & Base Setup
pacstrap -K /mnt "${PACKAGES[@]}"
genfstab -U /mnt > /mnt/etc/fstab

build_other_os_entries "$EFI_PART" /mnt/etc/grub.d/25-other-os

mkdir -p /mnt/run/other-esps
IDX=0
while read -r ESP; do
  [[ -b "$ESP" && "$ESP" != "$EFI_PART" ]] || continue
  IDX=$((IDX + 1))
  mkdir -p "/mnt/run/other-esps/$IDX"
  mount -o ro "$ESP" "/mnt/run/other-esps/$IDX" 2>/dev/null || { rmdir "/mnt/run/other-esps/$IDX"; IDX=$((IDX - 1)); }
done < <(lsblk -nrpo NAME,FSTYPE,TYPE | awk '$2=="vfat"&&$3=="part"{print $1}')

# Chroot System Configuration (passing configuration variables)
NEW_USER="$NEW_USER" TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" KEYMAP="$KEYMAP" HOSTNAME="$HOSTNAME" arch-chroot /mnt /bin/bash <<'EOT'
set -Eeuo pipefail

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen

echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

mkinitcpio -P
echo "root:1234" | chpasswd

# Create user, add to wheel group, and set password to 1234
useradd -m -G wheel -s /bin/bash "$NEW_USER"
echo "${NEW_USER}:1234" | chpasswd

# Enable passwordless sudo for the wheel group
sed -i 's/^# *%wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

systemctl enable NetworkManager

if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
  sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
  echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck

# Run os-prober and generate grub config right before exiting chroot
os-prober || true
grub-mkconfig -o /boot/grub/grub.cfg
EOT

# Clean Unmounting & Finalization
umount -Rl /mnt/run/other-esps 2>/dev/null || true
rm -rf /mnt/run/other-esps 2>/dev/null || true

sync
swapoff "$SWAP_PART" 2>/dev/null || true
umount -R /mnt
sync

echo
echo 'ARCH LINUX INSTALLATION COMPLETE'
echo 'Arch EFI was kept separate; existing ESPs were only read.'
read -r -p 'Press ENTER to reboot...'
reboot
