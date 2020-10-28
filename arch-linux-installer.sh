#!/bin/bash

# Dependencies.
declare -a DEPENDNECIES=(
  "awk" "grep" "sed" "sgdisk" "lscpu" "lspci" "lsblk" "bc" "openssl"
  "whiptail" "mkfs.vfat" "mkfs.btrfs" "pacstrap"
)

# Temp work directory.
declare TMPDIR="/mnt"

# Source URL.
declare SRCURL="http://os.archlinuxarm.org"

# Global variables.
declare -a TMPLIST=()
declare CONFIGURATION=""

# List of available user environments.
declare -a ENVIRONMENTS=(
  "Console" "Bare console environment" "on"
  "GNOME" "Modern and simple desktop - minimal installation" "off"
#  "KDE" "Flashy desktop with many features - minimal installation" "off"
#  "XFCE" "Reliable and fast desktop - minimal installation" "off"
)

declare RAMSIZE=""
declare DISKSIZE=""
declare FREESPACE=""

declare EFISIZE="512"
declare SWAPSIZE=""
declare SYSTEMSIZE="0"

declare DRIVE=""
declare NAME=""
declare FULLNAME=""
declare PASSWORD=""
declare CONFIRMPASSWORD=""
declare ROOTPASSWORD="root"
declare CONFIRMROOTPASSWORD="root"
declare USERGROUPS=""
declare HOSTNAME="arhlinux"
declare ENVIRONMENT=""

declare -a DEVICES=()
declare DEVICE=""
declare -a TIMEZONES=()
declare TIMEZONE=""
declare -a LOCALES=()
declare LOCALE=""
declare -a CLIKEYMAPS=()
declare CLIKEYMAP=""
declare -a CLIFONTS=()
declare CLIFONT=""

declare CHASSIS=""
declare CPU=""
declare GPU=""
declare CRYPTSWAP=""
declare CRYPTSYSTEM=""

# ============================================================================
# Functions
# ============================================================================
msg() {
  declare -A types=(
    ['error']='red'
    ['warning']='yellow'
    ['info']='green'
    ['debug']='blue'
  )
  declare -A colors=(
    ['black']='\E[1;47m'
    ['red']='\E[1;31m'
    ['green']='\E[1;32m'
    ['yellow']='\E[1;33m'
    ['blue']='\E[1;34m'
    ['magenta']='\E[1;35m'
    ['cyan']='\E[1;36m'
    ['white']='\E[1;37m'
  )
  local bold="\E[1;1m"
  local default="\E[1;0m"

  # First argument is the type and 2nd is the actual message.
  local type=$1
  local message=$2

  local color=${colors[${types[${type}]}]}

  if [[ ${type} == "info" ]]; then
    printf "${color}==>${default}${bold} ${message}${default}\n" "$@" >&2
  elif [[ ${type} == "debug" ]]; then
    printf "${color}  ->${default}${bold} ${message}${default}\n" "$@" >&2
  elif [[ ${type} == "warning" ]]; then
    printf "${color}WARNING:${default}${bold} ${message}${default}\n" "$@" >&2
  elif [[ ${type} == "error" ]]; then
    printf "${color}ERROR:${default}${bold} ${message}${default}\n" "$@" >&2
  fi
}

prepare() {
  msg info "Getting ${DRIVE} ready..."
  local partitions=($(lsblk ${DRIVE} -no KNAME | grep -E ${DEVICE}.*[0-9]+))

  for partition in ${partitions[@]}; do
    msg debug "umount partition /dev/${partition} ..."
    umount /dev/${partition} 1> /dev/null 2>&1
  done

  msg debug "Removing any lingering information from previous partitions..."
  sgdisk --zap-all ${DRIVE} 1> /dev/null 2>&1

  msg debug "Creating partition table..."
  sgdisk --clear \
       --new=1:0:+${EFISIZE}MiB    --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+${SWAPSIZE}GiB   --typecode=2:8200 --change-name=2:cryptswap \
       --new=3:0:+${SYSTEMSIZE}GiB --typecode=3:8300 --change-name=3:cryptsystem \
       ${DRIVE} 1> /dev/null 2>&1

  partitions=($(lsblk ${DRIVE} -no KNAME | grep -E ${DEVICE}.*[0-9]+))

  msg debug "Encrypting Swap partition..."
  cryptsetup luksFormat --align-payload=8192 \
             /dev/${partitions[1]} 1> /dev/null 2>&1
  cryptsetup open /dev/${partitions[1]} system 1> /dev/null 2>&1

  msg debug "Initializing Swap partition..."
  mkswap -L swap /dev/mapper/swap 1> /dev/null 2>&1
  swapon -L swap 1> /dev/null 2>&1

  msg debug "Encrypting System partition..."
  cryptsetup luksFormat --type luks1 --iter-time 5000 --align-payload=8192 \
             /dev/${partitions[2]} 1> /dev/null 2>&1
  cryptsetup open /dev/${partitions[2]} system 1> /dev/null 2>&1

  msg debug "Creating and mounting System BTRFS Subvolumes..."
  mkfs.btrfs --force --label system /dev/mapper/system  1> /dev/null 2>&1

  mount -t btrfs LABEL=system ${TMPDIR}  1> /dev/null 2>&1
  btrfs subvolume create ${TMPDIR}/root  1> /dev/null 2>&1
  btrfs subvolume create ${TMPDIR}/home  1> /dev/null 2>&1
  btrfs subvolume create ${TMPDIR}/snapshots  1> /dev/null 2>&1
  umount -R ${TMPDIR}  1> /dev/null 2>&1

  local options="defaults,x-mount.mkdir,compress=lzo,ssd,noatime"

  mount -t btrfs -o subvol=root,${options} \
        LABEL=system ${TMPDIR}  1> /dev/null 2>&1
  mount -t btrfs -o subvol=home,${options} \
        LABEL=system ${TMPDIR}/home  1> /dev/null 2>&1
  mount -t btrfs -o subvol=snapshots,${options} \
        LABEL=system ${TMPDIR}/.snapshots  1> /dev/null 2>&1

  msg debug "Formating EFI partition..."
  mkfs.vfat  /dev/${partitions[0]} -F 32 -n EFI 1> /dev/null 2>&1

  msg debug "Mounting EFI partition..."
  mkdir ${TMPDIR}/efi  1> /dev/null 2>&1
  mount /dev/${partitions[0]} ${TMPDIR}/efi 1> /dev/null 2>&1

  # Find out the chassis type.
  case $(cat /sys/class/dmi/id/chassis_type) in
    3) CHASSIS="Desktop" ;;
    9) CHASSIS="Laptop" ;;
    10) CHASSIS="Notebook" ;;
    *) msg warning "Failed to determine chassis type!" ;;
  esac

  # Find out the CPU vendor.
  case $(lscpu | awk '/Vendor ID:/ { print $3 }') in
    "AuthenticAMD") CPU="AMD" ;;
    "GenuineIntel") CPU="Intel" ;;
    *) msg warning "Failed to determine CPU vendor!" ;;
  esac

  # Find out the GPU vendor.
  case $(lspci | grep -E "VGA|3D") in
    *"Advanced Micro Devices"*) GPU="AMD" ;;
    *"ATI Technologies"*) GPU="AMD" ;;
    *"NVIDIA Corporation"*) GPU="NVidia" ;;
    *"Intel Corporation"*) GPU="Intel" ;;
    *) msg warning "Failed to determine GPU vendor!" ;;
  esac

  # Save the encrypted partitions for later use.
  CRYPTSWAP="/dev/${partitions[1]}"
  CRYPTSYSTEM="/dev/${partitions[2]}"

  msg debug "Done"
}

insconsole() {
  msg debug "Enabling network and resolve deamon services..."
  systemctl enable systemd-networkd.service
  systemctl enable systemd-resolved.service
}

insgnome() {
  msg debug "Installing Xorg display server and xinitrc..."
  pacman -S xorg-server xorg-xinit

  msg debug "Installing Xorg relates packages..."
  pacman -S xorg-xset xorg-xprop xorg-xrandr xorg-xclock xdg-utils

  msg debug "Installing video drivers..."
  pacman -S xf86-video-vesa

  [[ ${GPU} == "AMD" ]] && pacman -S xf86-video-amdgpu
  [[ ${GPU} == "NVidia" ]] && pacman -S xf86-video-nouveau
  [[ ${GPU} == "Intel" ]] && pacman -S xf86-video-intel

  msg debug "Installing Vulkan drivers..."
  pacman -S vulkan-icd-loader vulkan-radeon

  if [[ ${CHASSIS} == "Laptop" || ${CHASSIS} == "Notebook" ]]; then
    msg debug "Laptop/Netbook touchpad packages..."
    pacman -S xf86-input-synaptics
  fi

  # Packages for touchscreen and wacom stylus.
  pacman -S xf86-input-libinput xf86-input-wacom

  msg debug "Installing GNOME packages..."
  pacman -S baobab cheese eog evince file-roller gdm gedit gnome-backgrounds \
            gnome-calculator gnome-calendar gnome-clocks gnome-control-center \
            gnome-logs gnome-menus gnome-remote-desktop gnome-screenshot \
            gnome-session gnome-settings-daemon gnome-shell gnome-shell-extensions \
            gnome-system-monitor gnome-terminal gnome-themes-extra gnome-user-docs \
            gnome-user-share gnome-video-effects gnome-weather gnome-bluetooth \
            gnome-icon-theme gnome-icon-theme-extras gvfs mutter nautilus yelp \
            xdg-user-dirs guake pulseaudio pavucontrol networkmanager

  msg debug "Configuring NetworkManager to use iwd as the Wi-Fi backend..."
  echo "[device]" > /etc/NetworkManager/conf.d/wifi-backend.conf
  echo "wifi.backend=iwd" > /etc/NetworkManager/conf.d/wifi-backend.conf

  msg debug "Enabling the NetworkManager service..."
  systemctl enable NetworkManager.service
}

installation() {
  msg info "Creating installation..."

  msg debug "Installing base packages..."
  pacstrap ${TMPDIR} base base-devel linux linux-firmware util-linux usbutils \
           man-db man-pages texinfo openssh sudo zsh zsh-completions gptfdisk \
           vim iwd cryptsetup grub efibootmgr btrfs-progs acpi lm_sensors ntp \
           dbus alsa-utils cronie terminus-font ttf-dejavu ttf-liberation \
           1> /dev/null 2>&1

  # Enabling microcode updates, grub-mkconfig will automatically detect
  # microcode updates and configure appropriately.
  if [[ ${CPU} == "AMD" ]]; then
    pacstrap ${TMPDIR} amd-ucode 1> /dev/null 2>&1
  elif [[ ${CPU} == "Intel" ]]; then
    pacstrap ${TMPDIR} intel-ucode 1> /dev/null 2>&1
  fi

  msg debug "Generate fstab..."
  genfstab -L -p ${TMPDIR} >> ${TMPDIR}/etc/fstab 1> /dev/null 2>&1

  msg debug "Change root"
  arch-chroot ${TMPDIR} 1> /dev/null 2>&1

  msg debug "Setting password for root ..."
  awk -i inplace -F: "BEGIN {OFS=FS;} \
      \$1 == \"root\" {\$2=\"$(openssl passwd -6 ${ROOTPASSWORD})\"} 1" \
      /etc/shadow 1> /dev/null 2>&1

  echo "KEYMAP=${CLIKEYMAP}" > /etc/vconsole.conf
  echo "FONT=${CLIFONT}" >> /etc/vconsole.conf

  echo ${HOSTNAME} > /etc/hostname
  echo "127.0.0.1       localhost" >> /etc/hosts
  echo "::1             localhost ipv6-localhost ipv6-loopback" >> /etc/hosts
  echo "127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts

  if [ ! -z ${NAME} ]; then
    msg debug "Setting user ${NAME}..."
    useradd --create-home ${NAME} 1> /dev/null 2>&1
    awk -i inplace -F: "BEGIN {OFS=FS;} \
        \$1 == \"${NAME}\" {\$2=\"$(openssl passwd -6 ${PASSWORD})\"} 1" \
        /etc/shadow 1> /dev/null 2>&1
    usermod -aG ${USERGROUPS} ${NAME} 1> /dev/null 2>&1
    chfn -f "${FULLNAME}" ${NAME} 1> /dev/null 2>&1
  fi

  msg debug "Set timezone, locales, keyboard, fonts and hostname..."
  ln -sf /usr/share/zoneinfo/"${TIMEZONE}" /etc/localtime 1> /dev/null 2>&1
  hwclock --systohc 1> /dev/null 2>&1

  sed -i s/"#${LOCALE}"/"${LOCALE}"/g /etc/locale.gen 1> /dev/null 2>&1
  sed -i s/"LANG=.*"/"LANG=${LOCALE}"/g /etc/locale.conf 1> /dev/null 2>&1
  locale-gen 1> /dev/null 2>&1

  if [[ ${CHASSIS} == "Laptop" || ${CHASSIS} == "Notebook" ]]; then
    msg debug "Setting battery charge thresholds [40 - 80]..."
    echo 40 > /sys/class/power_supply/BAT0/charge_start_threshold
    echo 80 > /sys/class/power_supply/BAT0/charge_stop_threshold
  fi

  msg debug "Configuring initramfs..."

  # The btrfs-check tool cannot be used on a mounted file system. To be able
  # to use btrfs-check without booting from a live USB, add it BINARIES.
  #
  # https://wiki.archlinux.org/index.php/Btrfs#Corruption_recovery
  sed -i 's/^BINARIES=\(.*\)/BINARIES=\(\/usr\/bin\/btrfs\)/g' \
      /etc/mkinitcpio.conf 1> /dev/null 2>&1

  local hooks="base systemd autodetect keyboard sd-vconsole modconf block"
  hooks+=" sd-encrypt btrfs filesystems fsck"

  sed -i "s/^HOOKS=\(.*\)/HOOKS=\(${hooks}\)/g" \
      /etc/mkinitcpio.conf 1> /dev/null 2>&1

  local module=""

  # For early loading of the KMS (Kernel Mode Setting) driver for video.
  [[ ${GPU} == "AMD" ]] && module="amdgpu"
  [[ ${GPU} == "NVidia" ]] && module="nouveau"
  [[ ${GPU} == "Intel" ]] && module="i915"

  sed -i "s/^MODULES=\(.*\)/MODULES=\(${module}\)/g" \
      /etc/mkinitcpio.conf 1> /dev/null 2>&1

  msg debug "Configuring GRUB..."

  # Set the kernel parameters, so initramfs can unlock the encrypted partitions.
  local cmdline="rd.luks.name=$(lsblk -dno UUID ${CRYPTSWAP})=swap"
  cmdline+=" resume=/dev/mapper/swap"

  sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\(.*\)\"/\1 ${cmdline//\//\\/}\"/" \
      /etc/default/grub 1> /dev/null 2>&1

  cmdline="rd.luks.name=$(lsblk -dno UUID ${CRYPTSYSTEM})=system"
  cmdline+=" root=/dev/mapper/system"

  sed -i "/^GRUB_CMDLINE_LINUX=/ s/\(.*\)\"/\1${cmdline//\//\\/}\"/" \
      /etc/default/grub 1> /dev/null 2>&1

  # Configure GRUB to allow booting from /boot on a LUKS1 encrypted partition.
  sed -i s/"^#GRUB_ENABLE_CRYPTODISK=y"/"GRUB_ENABLE_CRYPTODISK=y"/g \
      /etc/default/grub 1> /dev/null 2>&1

  # Restruct /boot permissions.
  chmod 700 /boot

  msg debug "Creating crypt keys..."

  local cryptdir="/etc/cryptsetup-keys.d"
  mkdir ${cryptdir} && chmod 700 ${cryptdir}

  dd bs=512 count=4 if=/dev/urandom of=${cryptdir}/cryptswap.key 1> /dev/null 2>&1
  chmod 600 /dev/sda2 ${cryptdir}/cryptswap.key 1> /dev/null 2>&1
  cryptsetup -v luksAddKey -i 1 ${CRYPTSWAP} \
             ${cryptdir}/cryptswap.key 1> /dev/null 2>&1

  dd bs=512 count=4 if=/dev/urandom of=${cryptdir}/cryptsystem.key 1> /dev/null 2>&1
  chmod 600 /dev/sda2 ${cryptdir}/cryptsystem.key 1> /dev/null 2>&1

  cryptsetup -v luksAddKey -i 1 ${CRYPTSYSTEM} \
             ${cryptdir}/cryptsystem.key 1> /dev/null 2>&1

  # Add the keys to the initramfs.
  local files="${cryptdir}/cryptswap.key ${cryptdir}/cryptsystem.key"
  sed -i "s/^FILES=\(.*\)/FILES=\(${files}\)/g" \
      /etc/mkinitcpio.conf 1> /dev/null 2>&1

  # Add the keys to the grub configuration
  cmdline="rd.luks.key=$(lsblk -dno UUID ${CRYPTSWAP})=${cryptdir}/cryptswap.key"
  sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\(.*\)\"/\1 ${cmdline//\//\\/}\"/" \
      /etc/default/grub 1> /dev/null 2>&1

  cmdline="rd.luks.key=$(lsblk -dno UUID ${CRYPTSYSTEM})=${cryptdir}/cryptsystem.key"
  sed -i "/^GRUB_CMDLINE_LINUX=/ s/\(.*\)\"/\1 ${cmdline//\//\\/}\"/" \
      /etc/default/grub 1> /dev/null 2>&1

  msg debug "Recreate initramfs..."
  mkinitcpio -P 1> /dev/null 2>&1

  msg debug "Installing GRUB in /efi and creating configuration file..."
  grub-install --target=x86_64-efi --efi-directory=/efi \
               --bootloader-id=GRUB --recheck 1> /dev/null 2>&1
  grub-mkconfig -o /boot/grub/grub.cfg 1> /dev/null 2>&1

  msg debug "Enabling NTP(Network Time Protocol) deamon service..."
  systemctl enable ntpd

  msg debug "Installing desktop environment..."
  [[ ${ENVORONMENT} == "Console" ]] && insconsole
  [[ ${ENVORONMENT} == "GNOME" ]] && insgnome

  # Exit chroot
  arch-chroot / 1> /dev/null 2>&1

  msg debug "Install complete"
}

cleanup() {
  msg info "Cleanup..."

  umount -R ${TMPDIR}

  msg debug "Done"
}


# ============================================================================
# MAIN
# ============================================================================
if [ "${EUID}" -ne 0 ]; then
  msg error "Script requires root privalages!"
  exit 1
fi

# Checks for dependencies
for cmd in "${DEPENDNECIES[@]}"; do
  if ! [[ -f "/bin/${cmd}" || -f "/sbin/${cmd}" || \
          -f "/usr/bin/${cmd}" || -f "/usr/sbin/${cmd}" ]] ; then
    msg error "${cmd} command is missing! Please install the relevant package."
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# Retrieve a list with curently available devices
TMPLIST=($(lsblk -dn -o NAME))

for i in ${TMPLIST[@]}; do
  DEVICES+=("${i}" "")
done

DEVICE=$(whiptail --title "Arch Linux Installer" \
 --menu "Choose drive - Be sure the correct device is selected!" 20 50 10 \
 "${DEVICES[@]}" 3>&2 2>&1 1>&3)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a device has been chosen.
[ -z "${DEVICE}" ] && { clear; msg error "Empty value!"; exit 1; }

DRIVE="/dev/${DEVICE}"
CONFIGURATION+="  Drive = ${DRIVE}\n"

# -----------------------------------------------------------------------------
# Find out the total disk size (GiB).
DISKSIZE=$(sgdisk -p ${DRIVE} | grep "Disk ${DRIVE//\//\\/}" | awk '{ print $5 }')
FREESPACE=${DISKSIZE}

EFISIZE=$(whiptail --clear --title "Arch Linux Installer" \
  --inputbox "EFI partition size: (MiB) (Free space: ${FREESPACE} GiB)" 8 60 \
  ${EFISIZE} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a device has been chosen.
[ -z "${EFISIZE}" ] && { clear; msg error "Empty value!"; exit 1; }

if [[ ! "${EFISIZE}" =~ ^[0-9]+$ ]]; then
  clear; msg error "EFI size contains invalid characters."; exit 1
fi

# Update free space size.
FREESPACE=$( bc <<< "scale = 1; ${FREESPACE} - (${EFISIZE} / 1024)")

# -----------------------------------------------------------------------------
# Calculate physical RAM size.
for mem in /sys/devices/system/memory/memory*; do
  [[ "$(cat ${mem}/online)" != "1" ]] && continue
  RAMSIZE=$((RAMSIZE + $((0x$(cat /sys/devices/system/memory/block_size_bytes)))));
done

# Convert the bytes to MiB.
RAMSIZE=$(bc <<< "${RAMSIZE} / 1024^2")

# Recommended swap sizes:
#
# RAM < 2 GB: [No Hibernation] - equal to RAM.
#             [With Hibernation] - double the size of RAM.
# RAM > 2 GB: [No Hibernation] - equal to the rounded square root of the RAM.
#             [With Hibernation] - RAM plus the rounded square root of the RAM.
if [[ $(bc <<< "${RAMSIZE} < 2048") -eq 1 ]]; then
  SWAPSIZE=$(bc <<< "${RAMSIZE} * 2")
elif [[ $(bc <<< "${RAMSIZE} >= 2048") -eq 1 ]]; then
  SWAPSIZE=$(bc <<< "${RAMSIZE} / 1024") # To GiB
  SWAPSIZE=$(bc <<< "scale = 1; ${SWAPSIZE} + sqrt(${SWAPSIZE})")
  SWAPSIZE=$(bc <<< "((${SWAPSIZE} + 0.5) / 1) * 1024") # Round & convert to MiB.
fi

SWAPSIZE=$(whiptail --clear --title "Arch Linux Installer" \
  --inputbox "SWAP partition size: (MiB) (Free space: ${FREESPACE} GiB)" 8 60 \
  ${SWAPSIZE} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a device has been chosen.
[ -z "${SWAPSIZE}" ] && { clear; msg error "Empty value!"; exit 1; }

if [[ ! "${SWAPSIZE}" =~ ^[0-9]+$ ]]; then
  clear; msg error "SWAP size contains invalid characters."; exit 1
fi

# Update free space size.
FREESPACE=$( bc <<< "scale = 1; ${FREESPACE} - (${SWAPSIZE} / 1024)")

# -----------------------------------------------------------------------------
SYSTEMSIZE=$(whiptail --clear --title "Arch Linux Installer" --inputbox \
  "SYSTEM partition size: (GiB) (Free space: ${FREESPACE} GiB)
  0 == Use all available free space." \
  10 60 ${SYSTEMSIZE} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a device has been chosen.
[ -z "${SYSTEMSIZE}" ] && { clear; msg error "Empty value!"; exit 1; }

if [[ ! "${SYSTEMSIZE}" =~ [0-9]+([.][0-9]+)?$ ]]; then
  clear; msg error "SYSTEM size contains invalid characters."; exit 1
fi

# -----------------------------------------------------------------------------
whiptail --clear --title "Arch Linux Installer" \
  --yesno "Add new user?" 7 30 3>&1 1>&2 2>&3 3>&-

if [[ $? == 255 ]]; then
  clear && msg info "Installation aborted..." && exit 1;
elif [[ $? == 0 ]]; then
  NAME=$(whiptail --clear --title "Arch Linux Installer" \
    --inputbox "Enter username: (usernames must be all lowercase)" \
    8 60 ${NAME} 3>&1 1>&2 2>&3 3>&-)

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

  if [[ "${NAME}" =~ [A-Z] ]] || [[ "${NAME}" == *['!'@#\$%^\&*()_+]* ]]; then
    clear; msg error "Username contains invalid characters."; exit 1
  fi

  # Check if a name has been entered.
  [ -z "${NAME}" ] && { clear; msg error "Empty value!"; exit 1; }

  FULLNAME=$(whiptail --clear --title "Arch Linux Installer" \
    --inputbox "Enter Full Name for ${NAME}:" 8 50 "${FULLNAME}" \
    3>&1 1>&2 2>&3 3>&-)

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

  # Check if a user name has been entered.
  [ -z "${FULLNAME}" ] && { clear; msg error "Empty value!"; exit 1; }

  USERGROUPS=$(whiptail --clear --title "Arch Linux Installer" \
    --inputbox "Enter additional groups for ${NAME} in a comma seperated list:
 (empty if none) (default: wheel)" 8 90 \
    3>&1 1>&2 2>&3 3>&-)

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

  PASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
    --passwordbox "Enter Password for ${NAME}:(default is 'alarm')" 8 60 \
    ${PASSWORD} 3>&1 1>&2 2>&3 3>&-)

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

  # Check if a password has been entered.
  [ -z "${PASSWORD}" ] && { clear; msg error "Empty value!"; exit 1; }

  CONFIRMPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
    --passwordbox "Confirm Password for ${NAME}:(default is 'alarm')" 8 60 \
    ${CONFIRMPASSWORD} 3>&1 1>&2 2>&3 3>&-)

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

  if [[ "${PASSWORD}" != "${CONFIRMPASSWORD}" ]]; then
    clear; msg error "User passwords do not match!"; exit 1
  fi

  CONFIGURATION+="  Username = ${NAME} (${FULLNAME})\n"
  CONFIGURATION+="  Additional usergroups = ${USERGROUPS}\n"
  CONFIGURATION+="  Password for ${NAME} = (password hidden)\n"
fi

# -----------------------------------------------------------------------------
ROOTPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Enter Root Password:(default is 'root')" 8 60 \
  ${ROOTPASSWORD} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a root password has been entered.
[ -z "${ROOTPASSWORD}" ] && { clear; msg error "Empty value!"; exit 1; }

# -----------------------------------------------------------------------------
CONFIRMROOTPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Confirm Root Password:(default is 'root')" 8 60 \
  ${CONFIRMROOTPASSWORD} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

if [[ "${ROOTPASSWORD}" != "${CONFIRMROOTPASSWORD}" ]]; then
  clear; msg "Root passwords do not match!"; exit 1
fi

# -----------------------------------------------------------------------------
HOSTNAME=$(whiptail --clear --title "Arch Linux Installer" \
  --inputbox "Enter desired hostname for this system:" 8 50 ${HOSTNAME} \
  3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a host name has been entered.
[ -z "${HOSTNAME}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  Hostname = ${HOSTNAME}\n"

# -----------------------------------------------------------------------------
# Retrieve a list with available timezones.
TMPLIST=($(timedatectl list-timezones))

for i in ${TMPLIST[@]}; do
  TIMEZONES+=("${i}" "")
done

TIMEZONE=$(whiptail --clear --title "Arch Linux Installer" \
  --menu "Choose your timezone!" 20 50 15 \
  "${TIMEZONES[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a timezone has been chosen.
[ -z "${TIMEZONE}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  Timezone = ${TIMEZONE}\n"

# -----------------------------------------------------------------------------
# Retrieve a list with available locales.
TMPLIST=(\
  $(awk '/^#.*UTF-8/{print $1}' /etc/locale.gen | tail -n +2 | sed -e 's/^#*//')\
)

for i in ${TMPLIST[@]}; do
  LOCALES+=("${i}" "")
done

LOCALE=$(whiptail --clear --title "Arch Linux Installer" \
  --menu "Choose your locale!" 20 50 15 \
  "${LOCALES[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a locale has been chosen.
[ -z "${LOCALE}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  Locale = ${LOCALE}\n"

# -----------------------------------------------------------------------------
# Retrieve a list with available keyboard layouts.
TMPLIST=($(localectl list-keymaps))

for i in ${TMPLIST[@]}; do
  CLIKEYMAPS+=("${i}" "")
done

CLIKEYMAP=$(whiptail --clear --title "Arch Linux Installer" \
  --menu "Choose your TTY keyboard layout:" 20 50 15 \
  "${CLIKEYMAPS[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a keymap has been chosen.
[ -z "${CLIKEYMAP}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  TTY Keyboard layout = ${CLIKEYMAP}"

# -----------------------------------------------------------------------------
ENVIRONMENT=$(whiptail --clear --title "Arch Linux Installer" \
  --radiolist "Pick desktop environment (press space):" 15 80 \
  $(bc <<< "${#ENVIRONMENTS[@]} / 3") "${ENVIRONMENTS[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# -----------------------------------------------------------------------------
# Verify configuration
whiptail --clear --title "Arch Linux Installer" \
  --yesno "Is the below information correct:\n${CONFIGURATION}" 20 70 \
  3>&1 1>&2 2>&3 3>&-

case $? in
  0) clear; msg info "Proceeding....";;
  1|255) clear; msg info "Installation aborted...."; exit 1;;
esac

RUNTIME=$(date +%s)
prepare && installation && cleanup
RUNTIME=$(echo ${RUNTIME} $(date +%s) | awk '{ printf "%0.2f",($2-$1)/60 }')

msg info "Time: ${RUNTIME} minutes"
