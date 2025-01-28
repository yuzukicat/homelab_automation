#!/usr/bin/bash

UCODE_PKG="amd-ucode"
BTRFS_MOUNT_OPTS="ssd,noatime,compress=zstd:1,space_cache=v2,autodefrag"

# Localization
# https://wiki.archlinux.org/title/Installation_guide#Localization
LANG='en_US.UTF-8'
KEYMAP='us'
# https://wiki.archlinux.org/title/Time_zone
TIMEZONE="Asia/Tokyo"

## desktop example
KERNEL_PKGS="linux-zen"
BASE_PKGS="base linux-firmware sudo python iptables-nft"
FS_PKGS="dosfstools e2fsprogs btrfs-progs"
OTHER_PKGS="man-db vim"
OTHER_PKGS="$OTHER_PKGS git base-devel archlinux-keyring adobe-source-han-sans-cn-fonts adobe-source-han-sans-hk-fonts adobe-source-han-sans-jp-fonts adobe-source-han-sans-tw-fonts adobe-source-han-serif-cn-fonts adobe-source-han-serif-hk-fonts adobe-source-han-serif-jp-fonts adobe-source-han-serif-tw-fonts noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-arphic-ukai ttf-arphic-uming ttf-dejavu ttf-firacode-nerd ttf-font-awesome ttf-jetbrains-mono ttf-nerd-fonts-symbols ttf-sarasa-gothic wqy-microhei wqy-zenhei fcitx5 fcitx5-anthy fcitx5-chinese-addons fcitx5-configtool fcitx5-gtk fcitx5-material-color fcitx5-qt plasma-meta efibootmgr alsa-firmware sof-firmware alsa-ucm-conf openssh packagekit packagekit-qt5 packagekit-qt6 appstream ufw libdbusmenu-glib bash-language-server cmake go ghc graphviz nodejs npm pnpm plantuml python-yaml typescript-language-server yaml-language-server yamllint code bash-completion bat bc bind difftastic fd fish github-cli hyfetch jq kitty konsole less man-pages mono moreutils pv starship strace tealdeer tmux tree tree-sitter trash-cli wget wl-clipboard ark compsize dolphin filelight partitionmanager gdu lrzip lzop ntfs-3g p7zip unarchiver unrar iftop mtr net-tools tcpdump traceroute wireshark-qt thunderbird telegram-desktop djvulibre glow libreoffice-fresh gwenview imagemagick kolourpaint spectacle okular xournalpp pandoc-cli btop htop iotop browserpass browserpass-firefox haveged pass pass-otp qtpass pwgen qbittorrent firefox chromium"
#KERNEL_PARAMETERS="console=ttyS0"    # this kernel parameter force output to serial port, useful for libvirt virtual machine w/o any graphis.

if [[ $(tty) == '/dev/ttyS0'  ]] ; then
    # Using serial port
    KERNEL_PARAMETERS="$KERNEL_PARAMETERS console=ttyS0"
fi

######################################################

echo "

This script is not thoroughly tested. It may wipe all hard drives connected. Make sure you have a working backup.

"
read -p "Press Enter to continue, otherwise press any other key. " start_install

if [[ -n $start_install ]] ; then
    exit 1
fi


echo "
######################################################
# Verify the boot mode
# https://wiki.archlinux.org/title/Installation_guide#Verify_the_boot_mode
######################################################
"
if [[ -e /sys/firmware/efi/efivars ]] ; then
    echo "UEFI mode OK."
else
    echo "System not booted in UEFI mode!"
    exit 1
fi


echo "
######################################################
# Check internet connection
# https://wiki.archlinux.org/title/Installation_guide#Connect_to_the_internet
######################################################
"
ping -c 1 archlinux.org > /dev/null
if [[ $? -ne 0 ]] ; then
    echo "Please check the internet connection."
    exit 1
else
    echo "Internet OK."
fi


echo "
######################################################
# Update the system clock
# https://wiki.archlinux.org/title/Installation_guide#Update_the_system_clock
######################################################
"
timedatectl set-ntp true

echo "
######################################################
# EFI boot settings
# https://man.archlinux.org/man/efibootmgr.8
######################################################
"
efibootmgr --unicode
efi_boot_id=" "
while [[ -n $efi_boot_id ]]; do
    echo -e "\nDo you want to delete any boot entries?: "
    read -p "Enter boot number (empty to skip): " efi_boot_id
    if [[ -n $efi_boot_id ]] ; then
        efibootmgr --bootnum $efi_boot_id --delete-bootnum --unicode
    fi
done

echo "
######################################################
# Partition disks
# https://wiki.archlinux.org/title/Installation_guide#Partition_the_disks
######################################################
"
umount -R /mnt
devices=$(lsblk --nodeps --paths --list --noheadings --sort=size --output=name,size,model | grep --invert-match "loop" | cat --number)

device_id=" "
while [[ -n $device_id ]]; do
    echo -e "Choose device to format:"
    echo "$devices"
    read -p "Enter a number (empty to skip): " device_id
    if [[ -n $device_id ]] ; then
        device=$(echo "$devices" | awk "\$1 == $device_id { print \$2}")
        fdisk "$device"
    fi
done

partitions=$(lsblk --paths --list --noheadings --output=name,size,model | grep --invert-match "loop" | cat --number)

# EFI partition
echo -e "\n\nTell me the EFI partition number:"
echo "$partitions"
read -p "Enter a number: " efi_id
efi_part=$(echo "$partitions" | awk "\$1 == $efi_id { print \$2}")

# root partition
echo -e "\n\nTell me the root partition number:"
echo "$partitions"
read -p "Enter a number: " root_id
root_part=$(echo "$partitions" | awk "\$1 == $root_id { print \$2}")

# Wipe existing LUKS header
# https://wiki.archlinux.org/title/Dm-crypt/Drive_preparation#Wipe_LUKS_header
# Erase all keys
cryptsetup erase $root_part 2> /dev/null
# Make sure there is no active slots left
cryptsetup luksDump $root_part 2> /dev/null
# Remove LUKS header to prevent cryptsetup from detecting it
wipefs --all $root_part 2> /dev/null


echo "
######################################################
# Format the partitions
# https://wiki.archlinux.org/title/Installation_guide#Format_the_partitions
######################################################
"
# EFI partition
echo "Formatting EFI partition ..."
echo "Running command: mkfs.fat -n boot -F 32 $efi_part"
# create fat32 partition with name(label) boot
mkfs.fat -n boot -F 32 "$efi_part"


echo "
######################################################
# Encrypt the root partion
# https://wiki.archlinux.org/title/Dm-crypt/Device_encryption
######################################################
"
# passphrase
echo -e "\nRunning cryptsetup ..."
# SSD usually report their sector size as 512 bytes, even though they use larger sector size.
# So add --sector-size 4096 force create a LUKS2 container with 4K sector size.
# If the sector size is wrong cryptsetup will abort with an error.
# To re-encrypt with correct sector size see
# https://wiki.archlinux.org/title/Advanced_Format#dm-crypt
cryptsetup --type luks2 --verify-passphrase --sector-size 4096 --verbose luksFormat "$root_part"
echo -e "\nDecrypting root partition ..."
cryptsetup open "$root_part" cryptroot

# e.g. boot_block=/dev/sdX2
root_block=$root_part
root_part=/dev/mapper/cryptroot


# format root partition
echo -e "\n\nFormatting root partition ..."
echo "Running command: mkfs.btrfs -L ArchLinux -f $root_part"
# create root partition with label ArchLinux
mkfs.btrfs -L ArchLinux -f "$root_part"
# create subvlumes
echo "Creating btrfs subvolumes ..."
mount "$root_part" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@pacman_pkgs
mkdir /mnt/@/{efi,home,.snapshots}
mkdir -p /mnt/@/var/log
mkdir -p /mnt/@/var/cache/pacman/pkg
umount "$root_part"

# mount all partitions
echo -e "\nMounting all partitions ..."
mount -o "$BTRFS_MOUNT_OPTS",subvol=@ "$root_part" /mnt
# https://wiki.archlinux.org/title/Security#Mount_options
# Mount file system with nodev,nosuid,noexec except /home partition.
home_mount_opts="$BTRFS_MOUNT_OPTS,nodev"
mount -o "$home_mount_opts,subvol=@home" "$root_part" /mnt/home
mount -o "$BTRFS_MOUNT_OPTS,nodev,nosuid,noexec,subvol=@snapshots" "$root_part" /mnt/.snapshots
mount -o "$BTRFS_MOUNT_OPTS,nodev,nosuid,noexec,subvol=@var_log" "$root_part" /mnt/var/log
mount -o "$BTRFS_MOUNT_OPTS,nodev,nosuid,noexec,subvol=@pacman_pkgs" "$root_part" /mnt/var/cache/pacman/pkg
mount "$efi_part" /mnt/efi


echo "
######################################################
# Install packages
# https://wiki.archlinux.org/title/Installation_guide#Install_essential_packages
######################################################
"
pacstrap -K /mnt $BASE_PKGS $KERNEL_PKGS $FS_PKGS $UCODE_PKG $OTHER_PKGS


echo "
######################################################
# Generate fstab
# https://wiki.archlinux.org/title/Installation_guide#Fstab
######################################################
"
echo -e "Generating fstab ..."
genfstab -U /mnt >> /mnt/etc/fstab
echo "Removing subvolid entry in fstab ..."
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab


echo "
######################################################
# Set time zone
# https://wiki.archlinux.org/title/Installation_guide#Time_zone
######################################################
"
echo -e "Setting time zone ..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
arch-chroot /mnt hwclock --systohc

echo "
######################################################
# Set locale
# https://wiki.archlinux.org/title/Installation_guide#Localization
######################################################
"
echo -e "Setting locale ..."
# uncomment en_US.UTF-8 UTF-8
arch-chroot /mnt sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
# uncomment other UTF-8 locales
if [[ $LANG != 'en_US.UTF-8' ]] ; then
    arch-chroot /mnt sed -i "s/^#$LANG UTF-8/$LANG UTF-8/" /etc/locale.gen
fi
arch-chroot /mnt locale-gen
echo "LANG=$LANG" > /mnt/etc/locale.conf
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf

echo "
######################################################
# Set network
# https://wiki.archlinux.org/title/Installation_guide#Network_configuration
######################################################
"
echo -e "Setting network ..."
echo -e "\n\nPlease tell me the hostname:"
read hostname
echo "$hostname" > /mnt/etc/hostname
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
echo -e "Copying iso network configuration ..."
cp /etc/systemd/network/20-ethernet.network /mnt/etc/systemd/network/20-ethernet.network
echo "Enabling systemd-resolved.service and systemd-networkd.service ..."
arch-chroot /mnt systemctl enable systemd-resolved.service
arch-chroot /mnt systemctl enable systemd-networkd.service
arch-chroot /mnt pacman --noconfirm -S iwd
arch-chroot /mnt systemctl enable iwd.service


# reload partition table
partprobe &> /dev/null
# wait for partition table update
sleep 1
root_uuid=$(lsblk -dno UUID $root_block)


echo "
######################################################
# Disk encryption
# https://wiki.archlinux.org/title/Dm-crypt
######################################################
"
# kernel cmdline parameters for encrypted root partition
kernel_cmd="root=/dev/mapper/cryptroot"

# /etc/crypttab.initramfs for root
echo -e "\nConfiguring /etc/crypttab.iniramfs for encrypted root ..."
echo "cryptroot  UUID=$root_uuid  -  password-echo=no,x-systemd.device-timeout=0,timeout=0,no-read-workqueue,no-write-workqueue,discard"  >>  /mnt/etc/crypttab.initramfs


# mkinitcpio
# https://wiki.archlinux.org/title/Dm-crypt/System_configuration#mkinitcpio
echo "Editing mkinitcpio ..."
sed -i '/^HOOKS=/ s/ keyboard//' /mnt/etc/mkinitcpio.conf
sed -i '/^HOOKS=/ s/ udev//' /mnt/etc/mkinitcpio.conf
sed -i '/^HOOKS=/ s/ keymap//' /mnt/etc/mkinitcpio.conf
sed -i '/^HOOKS=/ s/ consolefont//' /mnt/etc/mkinitcpio.conf
sed -i '/^HOOKS=/ s/base/base systemd keyboard/' /mnt/etc/mkinitcpio.conf
sed -i '/^HOOKS=/ s/block/sd-vconsole block sd-encrypt/' /mnt/etc/mkinitcpio.conf


# btrfs as root
# https://wiki.archlinux.org/title/Btrfs#Mounting_subvolume_as_root
kernel_cmd="$kernel_cmd rootfstype=btrfs rootflags=subvol=/@ rw"
# modprobe.blacklist=pcspkr will disable PC speaker (beep) globally
# https://wiki.archlinux.org/title/PC_speaker#Globally
kernel_cmd="$kernel_cmd modprobe.blacklist=pcspkr $KERNEL_PARAMETERS zswap.enabled=0"


# Fallback kernel cmdline parameters (without SELinux, VFIO)
echo "$kernel_cmd" > /mnt/etc/kernel/cmdline_fallback


echo "
######################################################
# VFIO kernel parameters
# https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#Enabling_IOMMU
######################################################
"
if [[ $(grep -e 'vendor_id.*GenuineIntel' /proc/cpuinfo | wc -l) -ge 1 ]] ; then
    # for intel cpu
    kernel_cmd="$kernel_cmd intel_iommu=on iommu=pt"
else
    # amd cpu
    kernel_cmd="$kernel_cmd iommu=pt"
fi
# load vfio-pci module early
# https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#mkinitcpio
sed -i '/^MODULES=/ s/)/ vfio_pci vfio vfio_iommu_type1)/' /mnt/etc/mkinitcpio.conf


echo "
######################################################
# Setup unified kernel image
# https://wiki.archlinux.org/title/Unified_kernel_image
######################################################
"
arch-chroot /mnt mkdir -p /efi/EFI/Linux
for KERNEL in $KERNEL_PKGS
do
    # Edit default_uki= and fallback_uki=
    sed -i -E "s@^(#|)default_uki=.*@default_uki=\"/efi/EFI/Linux/ArchLinux-$KERNEL.efi\"@" /mnt/etc/mkinitcpio.d/$KERNEL.preset
    sed -i -E "s@^(#|)fallback_uki=.*@fallback_uki=\"/efi/EFI/Linux/ArchLinux-$KERNEL-fallback.efi\"@" /mnt/etc/mkinitcpio.d/$KERNEL.preset
    # Edit default_options= and fallback_options=
    sed -i -E "s@^(#|)default_options=.*@default_options=\"--splash /usr/share/systemd/bootctl/splash-arch.bmp\"@" /mnt/etc/mkinitcpio.d/$KERNEL.preset
    sed -i -E "s@^(#|)fallback_options=.*@fallback_options=\"-S autodetect --cmdline /etc/kernel/cmdline_fallback\"@" /mnt/etc/mkinitcpio.d/$KERNEL.preset
    # comment out default_image= and fallback_image=
    sed -i -E "s@^(#|)default_image=.*@#&@" /mnt/etc/mkinitcpio.d/$KERNEL.preset
    sed -i -E "s@^(#|)fallback_image=.*@#&@" /mnt/etc/mkinitcpio.d/$KERNEL.preset
done

# remove leftover initramfs-*.img from /boot or /efi
rm /mnt/efi/initramfs-*.img 2>/dev/null
rm /mnt/boot/initramfs-*.img 2>/dev/null

echo "$kernel_cmd" > /mnt/etc/kernel/cmdline
echo "Regenerating the initramfs ..."
arch-chroot /mnt mkinitcpio -P


echo "
######################################################
# Set up UFEI boot the unified kernel image directly
# https://wiki.archlinux.org/title/Unified_kernel_image#Directly_from_UEFI
######################################################
"
efi_dev=$(lsblk --noheadings --output PKNAME $efi_part)
efi_part_num=$(echo $efi_part | grep -Eo '[0-9]+$')
arch-chroot /mnt pacman --noconfirm -S --needed efibootmgr

bootorder=""
echo "Creating UEFI boot entries for each unified kernel image ..."
for KERNEL in $KERNEL_PKGS
do
    # Add $KERNEL to boot loader
    arch-chroot /mnt efibootmgr --create --disk /dev/${efi_dev} --part ${efi_part_num} --label "ArchLinux-$KERNEL" --loader "EFI\\Linux\\ArchLinux-$KERNEL.efi" --quiet --unicode
    # Get new added boot entry BootXXXX*
    bootnum=$(efibootmgr --unicode | awk "/\sArchLinux-$KERNEL\s/ { print \$1}")
    # Get the hex number
    bootnum=${bootnum:4:4}
    # Add bootnum to bootorder
    if [[ -z $bootorder ]] ; then
        bootorder="$bootnum"
    else
        bootorder="$bootorder,$bootnum"
    fi

    # Add $KERNEL-fallback to boot loader
    arch-chroot /mnt efibootmgr --create --disk /dev/${efi_dev} --part ${efi_part_num} --label "ArchLinux-$KERNEL-fallback" --loader "EFI\\Linux\\ArchLinux-$KERNEL-fallback.efi" --quiet --unicode
    # Get new added boot entry BootXXXX*
    bootnum=$(efibootmgr --unicode | awk "/\sArchLinux-$KERNEL-fallback\s/ { print \$1}")
    # Get the hex number
    bootnum=${bootnum:4:4}
    # Add bootnum to bootorder
    bootorder="$bootorder,$bootnum"
done
arch-chroot /mnt efibootmgr --bootorder ${bootorder} --quiet --unicode

echo -e "\n\n"
arch-chroot /mnt efibootmgr --unicode
echo -e "\n\nDo you want to change boot order?: "
read -p "Enter boot order (empty to skip): " boot_order
if [[ -n $boot_order ]] ; then
    echo -e "\n"
    arch-chroot /mnt efibootmgr --bootorder ${boot_order} --unicode
    echo -e "\n"
fi


echo "
######################################################
# Firewalld
# https://wiki.archlinux.org/title/firewalld
######################################################
"
arch-chroot /mnt pacman --noconfirm -S --needed firewalld
arch-chroot /mnt systemctl enable firewalld.service
echo "Set default firewall zone to drop."
arch-chroot /mnt firewall-offline-cmd --set-default-zone=drop


echo "
######################################################
# User account
# https://wiki.archlinux.org/title/Users_and_groups
######################################################
"
# add wheel group to sudoer
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/ s/# //' /mnt/etc/sudoers

read -p "Tell me your username: " username
arch-chroot /mnt useradd -m -G wheel "$username"
arch-chroot /mnt passwd "$username"

echo "Enter root password"
arch-chroot /mnt passwd

echo -e "\n\nNow you could reboot or chroot into the new system at /mnt to do further changes.\n\n"
