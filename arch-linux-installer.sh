#!/bin/bash

# Dependencies.
declare -a DEPENDNECIES=(
  "awk" "grep" "sed" "sgdisk" "lscpu" "lspci" "lsblk" "bc" "openssl" "wipefs" "parted"
  "arch-chroot" "pacstrap" "genfstab" "whiptail" "mkfs.vfat" "mkfs.btrfs"
)

# Temp work directory.
declare TMPDIR="/mnt"

# Global variables.
declare -a TMPLIST=()
declare CONFIGURATION=""

# List of additional bootloader kernel parameters.
declare -a KERNELPARAMS=(
  "acpi_osi=Linux" "Tell BIOS that it's running Linux" "off"
  "acpi_backlight=vendor" "First probe vendor specific backlight drives" "off"
)

# List of available user environments.
declare -a ENVIRONMENTS=(
  "Console" "Bare console environment" "on"
  "GNOME" "Modern and simple desktop - minimal installation" "off"
#  "KDE" "Flashy desktop with many features - minimal installation" "off"
#  "XFCE" "Reliable and fast desktop - minimal installation" "off"
)

# List of possible processor microcodes.
declare -a MICROCODES=(
  "AMD" "Install and enable AMD CPUs microcode updates in bootloader" "off"
  "Intel" "Install and enable Intel CPUs microcode updates in bootloader" "off"
)

# List of possible video drivers.
declare -a VIDEODRIVERS=(
  "AMD" "Intall for AMD GPUs from GCN 3 and newer (Radeon Rx 300 or higher)" "off"
  "ATI" "Intall for AMD GPUs from GCN 2 and older" "off"
  "NVidia" "Intall for NVidia GPUs" "off"
  "Intel" "Intall for Intel integrated graphics" "off"
)

# List of possible hardware video acceleration drivers.
declare -a HWVIDEOACCELERATION=(
  "Mesa VA-API" "Video Acceleration API drivers for Nvidia and AMD GPUs" "off"
  "Mesa VDPAU" "Video Decode and Presentation API for Unix drivers for Nvidia and AMD GPUs" "off"
  "Intel VA-API(>= Broadwell)" "Video Acceleration API drivers for Intel GPUs (>= Broadwell)" "off"
  "Intel VA-API(<= Haswell)" "Video Acceleration API drivers for Intel GPUs (<= Haswell)" "off"
)

# List of possible additional packages.
declare -a EXTRAPKGS=(
  "Touchpad" "Install for touchpad support via the synaptics driver" "off"
  "Touchscreen" "Install for touchscreen support via the libinput driver" "off"
  "Wacom" "Install for Wacon stylus support" "off"
)

declare DRIVE=""

declare FREESPACE=""
declare EFISIZE="512"
declare SWAPSIZE=""
declare SYSTEMSIZE="0"

declare SWAPPASSWORD=""
declare SYSTEMPASSWORD=""
declare PASSWORD=""
declare ROOTPASSWORD="root"
declare CONFIRMPASSWORD=""

declare USERNAME=""
declare FULLNAME=""
declare USERGROUPS=""
declare HOSTNAME="arhlinux"
declare ENVIRONMENT=""

declare -a DEVICES=()
declare DEVICE=""
declare -a TIMEZONES=()
declare TIMEZONE=""
declare -a LOCALES=()
declare LANG=""
declare -a CLIKEYMAPS=()
declare CLIKEYMAP=""
declare -a CLIFONTS=()
declare CLIFONT=""

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
    printf "${color}==>WARNING:${default}${bold} ${message}${default}\n" "$@" >&2
  elif [[ ${type} == "error" ]]; then
    printf "${color}==>ERROR:${default}${bold} ${message}${default}\n" "$@" >&2
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
  wipefs -a ${DRIVE} 1> /dev/null 2>&1

  msg debug "Creating partition table..."
  sgdisk --clear \
       --new=1:0:+${EFISIZE}MiB    --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+${SWAPSIZE}MiB   --typecode=2:8200 --change-name=2:cryptswap \
       --new=3:0:+${SYSTEMSIZE}MiB --typecode=3:8300 --change-name=3:cryptsystem \
       ${DRIVE} 1> /dev/null 2>&1

  partitions=($(lsblk ${DRIVE} -no KNAME | grep -E ${DEVICE}.*[0-9]+))

  msg debug "Encrypting Swap partition..."
  echo -n "${SWAPPASSWORD}" | cryptsetup luksFormat --align-payload=8192 \
                                         /dev/${partitions[1]} - 1> /dev/null 2>&1
  echo -n "${SWAPPASSWORD}" | cryptsetup open /dev/${partitions[1]} swap - \
                                         1> /dev/null 2>&1

  msg debug "Initializing Swap partition..."
  mkswap -L swap /dev/mapper/swap 1> /dev/null 2>&1
  swapon -L swap 1> /dev/null 2>&1

  msg debug "Encrypting System partition..."
  echo -n "${SYSTEMPASSWORD}" | cryptsetup luksFormat --type luks1 --iter-time 5000 \
                                           --align-payload=8192 /dev/${partitions[2]} - \
                                           1> /dev/null 2>&1
  echo -n "${SYSTEMPASSWORD}" | cryptsetup open /dev/${partitions[2]} system - \
                                           1> /dev/null 2>&1

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

  # Save the encrypted partitions for later use.
  CRYPTSWAP="/dev/${partitions[1]}"
  CRYPTSYSTEM="/dev/${partitions[2]}"

  msg debug "Done"
}

console_setup() {
  msg debug "Installing ACPI daemon..."
  pacstrap ${TMPDIR} acpid 1> /dev/null 2>&1

  msg debug "Enabling ACPI deamon service..."
  arch-chroot ${TMPDIR} systemctl enable acpid.service 1> /dev/null 2>&1

  msg debug "Enabling volume/mic controls in /etc/acpi/events/ ..."
  msg warning "Disable volume/mic controls in Xorg to prevent conflicts!"

  echo "event=button/volumeup" > ${TMPDIR}/etc/acpi/events/vol-up
  echo "action=amixer set Master 5+" >> ${TMPDIR}/etc/acpi/events/vol-up

  echo "event=button/volumedown" > ${TMPDIR}/etc/acpi/events/vol-down
  echo "action=amixer set Master 5-" >> ${TMPDIR}/etc/acpi/events/vol-down

  echo "event=button/mute" > ${TMPDIR}/etc/acpi/events/vol-mute
  echo "action=amixer set Master toggle" >> ${TMPDIR}/etc/acpi/events/vol-mute

  echo "event=button/f20" > ${TMPDIR}/etc/acpi/events/mic-mute
  echo "action=amixer set Capture toggle" >> ${TMPDIR}/etc/acpi/events/mic-mute

  msg debug "Setting wired and wireless DHCP configurations..."
	cat <<-__EOF__ > ${TMPDIR}/etc/systemd/network/99-ethernet.network
		[Match]
		Name=en*
		Name=eth*

		[Network]
		DHCP=true
		IPv6PrivacyExtensions=true

		[DHCP]
		RouteMetric=512
	__EOF__

	cat <<-__EOF__ > ${TMPDIR}/etc/systemd/network/99-wireless.network
		[Match]
		Name=wlp*
		Name=wlan*

		[Network]
		DHCP=true
		IPv6PrivacyExtensions=true

		[DHCP]
		RouteMetric=1024
	__EOF__

  msg debug "Enabling networkd and resolved services..."
  arch-chroot ${TMPDIR} systemctl enable systemd-networkd.service 1> /dev/null 2>&1
  arch-chroot ${TMPDIR} systemctl enable systemd-resolved.service 1> /dev/null 2>&1
}

common_desktop_setup() {
  msg debug "Installing Xorg display server and xinitrc..."
  pacstrap ${TMPDIR} xorg-server xorg-xinit 1> /dev/null 2>&1

  msg debug "Installing Xorg relates packages..."
  pacstrap ${TMPDIR} xorg-xset xorg-xprop xorg-xrandr xorg-xclock  xdg-utils 1> /dev/null 2>&1

  msg debug "Installing video drivers..."
  pacstrap ${TMPDIR} xf86-video-vesa 1> /dev/null 2>&1

  [[ ${VIDEODRIVERS[@]} == *"AMD"* ]] && pacstrap ${TMPDIR} xf86-video-amdgpu 1> /dev/null 2>&1
  [[ ${VIDEODRIVERS[@]} == *"ATI"* ]] && pacstrap ${TMPDIR} xf86-video-ati 1> /dev/null 2>&1
  [[ ${VIDEODRIVERS[@]} == *"NVidia"* ]] && pacstrap ${TMPDIR} xf86-video-nouveau 1> /dev/null 2>&1
  [[ ${VIDEODRIVERS[@]} == *"Intel"* ]] && pacstrap ${TMPDIR} xf86-video-intel 1> /dev/null 2>&1

  if [[ ${VIDEODRIVERS[@]} == *"AMD"* ]]; then
    msg debug "Installing Vulkan drivers for AMD..."
    pacstrap ${TMPDIR} vulkan-icd-loader vulkan-radeon 1> /dev/null 2>&1
  fi

  if [[ ${VIDEODRIVERS[@]} == *"Intel"* ]]; then
    msg debug "Installing Vulkan drivers for Intel..."
    pacstrap ${TMPDIR} vulkan-icd-loader vulkan-intel 1> /dev/null 2>&1
  fi

  if [[ ${HWVIDEOACCELERATION[@]} == *"Mesa VA-API"* ]]; then
    msg debug "Installing Mesa VA-API drivers..."
    pacstrap ${TMPDIR} libva-mesa-driver 1> /dev/null 2>&1
  fi

  if [[ ${HWVIDEOACCELERATION[@]} == *"Mesa VDPAU"* ]]; then
    msg debug "Installing Mesa VDPAU drivers..."
    pacstrap ${TMPDIR} mesa-vdpau 1> /dev/null 2>&1
  fi

  if [[ ${HWVIDEOACCELERATION[@]} == *"Intel VA-API(>= Broadwell)"* ]]; then
    msg debug "Installing Intel VA-API drivers for Broadwell and newer graphics..."
    pacstrap ${TMPDIR} intel-media-driver 1> /dev/null 2>&1
  fi

  if [[ ${HWVIDEOACCELERATION[@]} == *"Intel VA-API(<= Haswell)"* ]]; then
    msg debug "Installing Intel VA-API drivers for Haswell and older graphics..."
    pacstrap ${TMPDIR} libva-intel-driver 1> /dev/null 2>&1
  fi

  if [[ ${EXTRAPKGS[@]} == *"Touchpad"* ]]; then
    msg debug "Installing touchpad packages..."
    pacstrap ${TMPDIR} xf86-input-synaptics 1> /dev/null 2>&1
  fi

  if [[ ${EXTRAPKGS[@]} == *"Touchscreen"* ]]; then
    msg debug "Installing touchscreen packages..."
    pacstrap ${TMPDIR} xf86-input-libinput 1> /dev/null 2>&1
  fi

  if [[ ${EXTRAPKGS[@]} == *"Wacom"* ]]; then
    msg debug "Installing Wacon packages..."
    pacstrap ${TMPDIR} xf86-input-wacom 1> /dev/null 2>&1
  fi
}

gnome_desktop_setup() {
  msg debug "Installing GNOME packages..."
  pacstrap ${TMPDIR} baobab cheese eog evince file-roller gdm gedit gnome-backgrounds \
     gnome-calculator gnome-calendar gnome-clocks gnome-control-center gnome-logs gnome-menus \
     gnome-remote-desktop gnome-screenshot gnome-session gnome-settings-daemon gnome-shell \
     gnome-shell-extensions gnome-system-monitor gnome-terminal gnome-tweaks gnome-themes-extra \
     gnome-user-docs gnome-user-share gnome-video-effects gnome-weather gnome-bluetooth \
     gnome-icon-theme gnome-icon-theme-extras gvfs mutter nautilus yelp xdg-user-dirs guake \
     pulseaudio pavucontrol networkmanager 1> /dev/null 2>&1

  msg debug "Enabling the GDM service..."
  arch-chroot ${TMPDIR} systemctl enable gdm.service 1> /dev/null 2>&1

  msg debug "Configuring NetworkManager to use iwd as the Wi-Fi backend..."
  echo "[device]" > ${TMPDIR}/etc/NetworkManager/conf.d/wifi-backend.conf
  echo "wifi.backend=iwd" >> ${TMPDIR}/etc/NetworkManager/conf.d/wifi-backend.conf

  msg debug "Disabling the wpa_supplicant service..."
  arch-chroot ${TMPDIR} systemctl disable wpa_supplicant.service 1> /dev/null 2>&1

  msg debug "Enabling the NetworkManager service..."
  arch-chroot ${TMPDIR} systemctl enable NetworkManager.service 1> /dev/null 2>&1
}

installation() {
  msg info "Creating installation..."

  msg debug "Installing base packages..."
  pacstrap ${TMPDIR} base base-devel linux linux-firmware util-linux usbutils \
           man-db man-pages texinfo bash-completion openssh sudo gptfdisk \
           vim iwd cryptsetup grub efibootmgr btrfs-progs acpi lm_sensors ntp \
           dbus alsa-utils cronie terminus-font ttf-dejavu ttf-liberation \
           1> /dev/null 2>&1

  # Enabling microcode updates, grub-mkconfig will automatically detect
  # microcode updates and configure appropriately.
  [[ ${MICROCODES[@]} == *"AMD"* ]] && pacstrap ${TMPDIR} amd-ucode 1> /dev/null 2>&1
  [[ ${MICROCODES[@]} == *"Intel"* ]] && pacstrap ${TMPDIR} intel-ucode 1> /dev/null 2>&1

  msg debug "Generate fstab..."
  genfstab -L -p ${TMPDIR} >> ${TMPDIR}/etc/fstab

  msg debug "Setting password for root ..."
  awk -i inplace -F: "BEGIN {OFS=FS;} \
      \$1 == \"root\" {\$2=\"$(openssl passwd -6 ${ROOTPASSWORD})\"} 1" \
      ${TMPDIR}/etc/shadow 1> /dev/null 2>&1

  msg debug "Set timezone, locales, keyboard, fonts and hostname..."
  arch-chroot ${TMPDIR} ln -sf /usr/share/zoneinfo/"${TIMEZONE}" \
                               /etc/localtime 1> /dev/null 2>&1
  arch-chroot ${TMPDIR} hwclock --systohc 1> /dev/null 2>&1

  for locale in "${LOCALES[@]//\"}"; do
    sed -i s/"#${locale}"/"${locale}"/g ${TMPDIR}/etc/locale.gen 1> /dev/null 2>&1
  done

  echo "LANG=${LANG}" > ${TMPDIR}/etc/locale.conf
  arch-chroot ${TMPDIR} locale-gen 1> /dev/null 2>&1

  echo "KEYMAP=${CLIKEYMAP}" > ${TMPDIR}/etc/vconsole.conf
  echo "FONT=${CLIFONT}" >> ${TMPDIR}/etc/vconsole.conf

  echo ${HOSTNAME} > ${TMPDIR}/etc/hostname
  echo "127.0.0.1       localhost" >> ${TMPDIR}/etc/hosts
  echo "::1             localhost ipv6-localhost ipv6-loopback" >> ${TMPDIR}/etc/hosts
  echo "127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}" >> ${TMPDIR}/etc/hosts

  # Enable users of group 'wheel' to execute any command.
  sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' \
      ${TMPDIR}/etc/sudoers 1> /dev/null 2>&1

  if [ ! -z ${USERNAME} ]; then
    msg debug "Setting user ${USERNAME}..."
    arch-chroot ${TMPDIR} useradd -m -G wheel,storage,optical,scanner \
        -s /bin/bash ${USERNAME} 1> /dev/null 2>&1
    awk -i inplace -F: "BEGIN {OFS=FS;} \
        \$1 == \"${USERNAME}\" {\$2=\"$(openssl passwd -6 ${PASSWORD})\"} 1" \
        ${TMPDIR}/etc/shadow 1> /dev/null 2>&1
    arch-chroot ${TMPDIR} usermod -aG ${USERGROUPS} ${USERNAME} 1> /dev/null 2>&1
    arch-chroot ${TMPDIR} chfn -f "${FULLNAME}" ${USERNAME} 1> /dev/null 2>&1
  fi

  msg debug "Configuring initramfs..."

  # The btrfs-check tool cannot be used on a mounted file system. To be able
  # to use btrfs-check without booting from a live USB, add it BINARIES.
  #
  # https://wiki.archlinux.org/index.php/Btrfs#Corruption_recovery
  sed -i 's/^BINARIES=\(.*\)/BINARIES=\(\/usr\/bin\/btrfs\)/g' \
      ${TMPDIR}/etc/mkinitcpio.conf 1> /dev/null 2>&1

  local hooks="base systemd autodetect keyboard sd-vconsole modconf block"
  hooks+=" sd-encrypt btrfs filesystems fsck"

  sed -i "s/^HOOKS=\(.*\)/HOOKS=\(${hooks}\)/g" \
      ${TMPDIR}/etc/mkinitcpio.conf 1> /dev/null 2>&1

  local module=""

  # For early loading of the KMS (Kernel Mode Setting) driver for video.
  if [[ ${VIDEODRIVERS[@]} == *"AMD"* ]]; then
    [[ -z ${module} ]] && module+="amdgpu" || module+=" amdgpu"
  fi

  if [[ ${VIDEODRIVERS[@]} == *"ATI"* ]]; then
    [[ -z ${module} ]] && module+="radeon" || module+=" radeon"
  fi

  if [[ ${VIDEODRIVERS[@]} == *"NVidia"* ]]; then
    [[ -z ${module} ]] && module+="nouveau" || module+=" nouveau"
  fi

  if [[ ${VIDEODRIVERS[@]} == *"Intel"* ]]; then
    [[ -z ${module} ]] && module+="i915" || module+=" i915"
  fi

  sed -i "s/^MODULES=\(.*\)/MODULES=\(${module}\)/g" \
      ${TMPDIR}/etc/mkinitcpio.conf 1> /dev/null 2>&1

  msg debug "Configuring GRUB..."

  local cmdline="${KERNELPARAMS[@]//\"}"
  sed -i "/^GRUB_CMDLINE_LINUX=/ s/\(.*\)\"/\1${cmdline}\"/" \
      ${TMPDIR}/etc/default/grub 1> /dev/null 2>&1

  # Set the kernel parameters, so initramfs can unlock the encrypted partitions.
  [[ ! -z ${cmdline} ]] && cmdline=" rd.luks.name=$(lsblk -dno UUID ${CRYPTSYSTEM})=system"
  [[ -z ${cmdline} ]] && cmdline="rd.luks.name=$(lsblk -dno UUID ${CRYPTSYSTEM})=system"
  cmdline+=" root=/dev/mapper/system"

  sed -i "/^GRUB_CMDLINE_LINUX=/ s/\(.*\)\"/\1${cmdline//\//\\/}\"/" \
      ${TMPDIR}/etc/default/grub 1> /dev/null 2>&1

  cmdline=" rd.luks.name=$(lsblk -dno UUID ${CRYPTSWAP})=swap"
  cmdline+=" resume=/dev/mapper/swap"

  sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\(.*\)\"/\1${cmdline//\//\\/}\"/" \
      ${TMPDIR}/etc/default/grub 1> /dev/null 2>&1

  # Configure GRUB to allow booting from /boot on a LUKS1 encrypted partition.
  sed -i s/"^#GRUB_ENABLE_CRYPTODISK=y"/"GRUB_ENABLE_CRYPTODISK=y"/g \
      ${TMPDIR}/etc/default/grub 1> /dev/null 2>&1

  # Restruct /boot permissions.
  chmod 700 ${TMPDIR}/boot

  msg debug "Creating crypt keys..."

  local cryptdir="/etc/cryptsetup-keys.d"
  mkdir ${TMPDIR}${cryptdir} && chmod 700 ${TMPDIR}${cryptdir} 1> /dev/null 2>&1

  dd bs=512 count=4 if=/dev/urandom of=${TMPDIR}${cryptdir}/cryptswap.key 1> /dev/null 2>&1
  chmod 600 ${TMPDIR}${cryptdir}/cryptswap.key 1> /dev/null 2>&1

  echo -n "${SWAPPASSWORD}" | cryptsetup -v luksAddKey -i 1 ${CRYPTSWAP} \
      ${TMPDIR}${cryptdir}/cryptswap.key - 1> /dev/null 2>&1

  dd bs=512 count=4 if=/dev/urandom of=${TMPDIR}${cryptdir}/cryptsystem.key 1> /dev/null 2>&1
  chmod 600 ${TMPDIR}${cryptdir}/cryptsystem.key 1> /dev/null 2>&1

  echo -n "${SYSTEMPASSWORD}" | cryptsetup -v luksAddKey -i 1 ${CRYPTSYSTEM} \
      ${TMPDIR}${cryptdir}/cryptsystem.key - 1> /dev/null 2>&1

  # Add the keys to the initramfs.
  local files="${cryptdir}/cryptswap.key ${cryptdir}/cryptsystem.key"
  sed -i "s/^FILES=\(.*\)/FILES=\(${files//\//\\/}\)/g" \
      ${TMPDIR}/etc/mkinitcpio.conf 1> /dev/null 2>&1

  # Add the keys to the grub configuration
  cmdline="rd.luks.key=$(lsblk -dno UUID ${CRYPTSWAP})=${cryptdir}/cryptswap.key"
  sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\(.*\)\"/\1 ${cmdline//\//\\/}\"/" \
      ${TMPDIR}/etc/default/grub 1> /dev/null 2>&1

  cmdline="rd.luks.key=$(lsblk -dno UUID ${CRYPTSYSTEM})=${cryptdir}/cryptsystem.key"
  sed -i "/^GRUB_CMDLINE_LINUX=/ s/\(.*\)\"/\1 ${cmdline//\//\\/}\"/" \
      ${TMPDIR}/etc/default/grub 1> /dev/null 2>&1

  msg debug "Recreate initramfs..."
  arch-chroot ${TMPDIR} mkinitcpio -P 1> /dev/null 2>&1

  msg debug "Installing GRUB in /efi and creating configuration file..."
  arch-chroot ${TMPDIR} grub-install --target=x86_64-efi --efi-directory=/efi \
                                     --bootloader-id=GRUB --recheck 1> /dev/null 2>&1
  arch-chroot ${TMPDIR} grub-mkconfig -o /boot/grub/grub.cfg 1> /dev/null 2>&1

  msg debug "Enabling NTP(Network Time Protocol) deamon service..."
  arch-chroot ${TMPDIR} systemctl enable ntpd 1> /dev/null 2>&1

  msg debug "Enabling the iwd service..."
  arch-chroot ${TMPDIR} systemctl enable iwd.service 1> /dev/null 2>&1

  msg debug "Installing desktop environment..."
  [[ ${ENVIRONMENT} == "Console" ]] && { console_setup }
  [[ ${ENVIRONMENT} == "GNOME" ]] && { common_desktop_setup && gnome_desktop_setup }

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
FREESPACE=$(sgdisk -p ${DRIVE} | awk '/Sector size/ { print $4 }' | awk -F'/' '{ print $1 }')
FREESPACE=$(bc <<< "$(sgdisk -p ${DRIVE} | awk '/last usable sector/ { print $10 }') * ${FREESPACE}")
FREESPACE=$(bc <<< "${FREESPACE} / 1024^2")

EFISIZE=$(whiptail --clear --title "Arch Linux Installer" \
  --inputbox "EFI partition size: (MiB) (Free space: ${FREESPACE} MiB)" 8 60 \
  ${EFISIZE} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a size has been chosen.
[ -z "${EFISIZE}" ] && { clear; msg error "Empty value!"; exit 1; }

# Check if a size is zero.
[[ "${EFISIZE}" -eq 0 ]] && { clear; msg error "Zero value!"; exit 1; }

if [[ ! "${EFISIZE}" =~ ^[0-9]+$ ]]; then
  clear; msg error "EFI size contains invalid characters."; exit 1
elif [[ ${EFISIZE} -gt ${FREESPACE} ]]; then
  clear; msg "Choosen EFI size is more than the available free space!"; exit 1
fi

# Update free space size.
FREESPACE=$(bc <<< "${FREESPACE} - ${EFISIZE}")
CONFIGURATION+="  EFI partition size = ${EFISIZE} (MiB)\n"

# -----------------------------------------------------------------------------
# Calculate physical RAM size.
for mem in /sys/devices/system/memory/memory*; do
  [[ "$(cat ${mem}/online)" != "1" ]] && continue
  SWAPSIZE=$((SWAPSIZE + $((0x$(cat /sys/devices/system/memory/block_size_bytes)))));
done

# Convert the bytes to MiB.
SWAPSIZE=$(bc <<< "${SWAPSIZE} / 1024^2")

# Recommended swap sizes:
#
# RAM < 2 GB: [No Hibernation] - equal to RAM.
#             [With Hibernation] - double the size of RAM.
# RAM > 2 GB: [No Hibernation] - equal to the rounded square root of the RAM.
#             [With Hibernation] - RAM plus the rounded square root of the RAM.
if [[ $(bc <<< "${SWAPSIZE} < 2048") -eq 1 ]]; then
  SWAPSIZE=$(bc <<< "${SWAPSIZE} * 2")
elif [[ $(bc <<< "${SWAPSIZE} >= 2048") -eq 1 ]]; then
  SWAPSIZE=$(bc <<< "${SWAPSIZE} / 1024") # To GiB
  SWAPSIZE=$(bc <<< "scale = 1; ${SWAPSIZE} + sqrt(${SWAPSIZE})")
  SWAPSIZE=$(bc <<< "((${SWAPSIZE} + 0.5) / 1) * 1024") # Round & convert to MiB.
fi

SWAPSIZE=$(whiptail --clear --title "Arch Linux Installer" \
  --inputbox "SWAP partition size: (MiB) (Free space: ${FREESPACE} MiB)" 8 60 \
  ${SWAPSIZE} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a size has been chosen.
[ -z "${SWAPSIZE}" ] && { clear; msg error "Empty value!"; exit 1; }

# Check if a size is zero.
[[ "${SWAPSIZE}" -eq 0 ]] && { clear; msg error "Zero value!"; exit 1; }

if [[ ! "${SWAPSIZE}" =~ ^[0-9]+$ ]]; then
  clear; msg error "SWAP size contains invalid characters."; exit 1
elif [[ ${SWAPSIZE} -gt ${FREESPACE} ]]; then
  clear; msg "Choosen SWAP size is more than the available free space!"; exit 1
fi

# Update free space size.
FREESPACE=$(bc <<< "${FREESPACE} - ${SWAPSIZE}")
CONFIGURATION+="  SWAP partition size = ${SWAPSIZE} (MiB)\n"

# -----------------------------------------------------------------------------
SWAPPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Enter SWAP partition password:" 8 60 \
  ${SWAPPASSWORD} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a root password has been entered.
[ -z "${SWAPPASSWORD}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIRMPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Confirm SWAP partition password:" 8 60 \
  3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

if [[ "${SWAPPASSWORD}" != "${CONFIRMPASSWORD}" ]]; then
  clear; msg error "SWAP passwords do not match!"; exit 1
fi

CONFIGURATION+="  Password for SWAP partition = (password hidden)\n"

# -----------------------------------------------------------------------------
SYSTEMSIZE=$(whiptail --clear --title "Arch Linux Installer" --inputbox \
  "SYSTEM partition size: (MiB) (Free space: ${FREESPACE} MiB)
  0 == Use all available free space" 10 60 ${SYSTEMSIZE} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a size has been chosen.
[ -z "${SYSTEMSIZE}" ] && { clear; msg error "Empty value!"; exit 1; }

if [[ ! "${SYSTEMSIZE}" =~ ^[0-9]+$ ]]; then
  clear; msg error "SYSTEM size contains invalid characters."; exit 1
elif [[ ${SYSTEMSIZE} -gt ${FREESPACE} ]]; then
  clear; msg "Choosen SYSTEM size is more than the available free space!"; exit 1
fi

CONFIGURATION+="  SYSTEM partition size = ${SYSTEMSIZE} (MiB)\n"

# -----------------------------------------------------------------------------
SYSTEMPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Enter SYSTEM partition password:" 8 60 \
  ${SYSTEMPASSWORD} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a root password has been entered.
[ -z "${SYSTEMPASSWORD}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIRMPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Confirm SYSTEM partition password:" 8 60 \
  3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

if [[ "${SYSTEMPASSWORD}" != "${CONFIRMPASSWORD}" ]]; then
  clear; msg error "SYSTEM passwords do not match!"; exit 1
fi

CONFIGURATION+="  Password for SYSTEM partition = (password hidden)\n"

# -----------------------------------------------------------------------------
whiptail --clear --title "Arch Linux Installer" \
  --yesno "Add new user?" 7 30 3>&1 1>&2 2>&3 3>&-

case $? in
  0) USERNAME=$(whiptail --clear --title "Arch Linux Installer" \
       --inputbox "Enter username: (usernames must be all lowercase)" \
       8 60 ${USERNAME} 3>&1 1>&2 2>&3 3>&-)

     # Check whiptail window return value.
     [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

     if [[ "${USERNAME}" =~ [A-Z] ]] || [[ "${USERNAME}" == *['!'@#\$%^\&*()_+]* ]]; then
       clear; msg error "Username contains invalid characters."; exit 1
     fi

     # Check if a name has been entered.
     [ -z "${USERNAME}" ] && { clear; msg error "Empty value!"; exit 1; }

     FULLNAME=$(whiptail --clear --title "Arch Linux Installer" \
       --inputbox "Enter Full Name for ${USERNAME}:" 8 50 "${FULLNAME}" \
       3>&1 1>&2 2>&3 3>&-)

     # Check whiptail window return value.
     [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

     # Check if a user name has been entered.
     [ -z "${FULLNAME}" ] && { clear; msg error "Empty value!"; exit 1; }

     USERGROUPS=$(whiptail --clear --title "Arch Linux Installer" --inputbox \
       "Enter additional groups for ${USERNAME} in a comma seperated list:(default is wheel)" \
       8 90 "wheel" 3>&1 1>&2 2>&3 3>&-)

     # Check whiptail window return value.
     [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

     PASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
       --passwordbox "Enter Password for ${USERNAME}:" 8 60 \
       ${PASSWORD} 3>&1 1>&2 2>&3 3>&-)

     # Check whiptail window return value.
     [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

     # Check if a password has been entered.
     [ -z "${PASSWORD}" ] && { clear; msg error "Empty value!"; exit 1; }

     CONFIRMPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
       --passwordbox "Confirm Password for ${USERNAME}:" 8 60 \
       3>&1 1>&2 2>&3 3>&-)

     # Check whiptail window return value.
     [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

     if [[ "${PASSWORD}" != "${CONFIRMPASSWORD}" ]]; then
       clear; msg error "User passwords do not match!"; exit 1
     fi

     CONFIGURATION+="  Username = ${USERNAME} (${FULLNAME})\n"
     CONFIGURATION+="  Additional usergroups = ${USERGROUPS}\n"
     CONFIGURATION+="  Password for ${USERNAME} = (password hidden)\n"
     ;;
  255) clear; msg info "Installation aborted...."; exit 1;;
esac

# -----------------------------------------------------------------------------
CONFIRMPASSWORD=${ROOTPASSWORD}

ROOTPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Enter Root Password:(default is 'root')" 8 60 \
  ${ROOTPASSWORD} 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a root password has been entered.
[ -z "${ROOTPASSWORD}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIRMPASSWORD=$(whiptail --clear --title "Arch Linux Installer" \
  --passwordbox "Confirm Root Password:(default is 'root')" 8 60 ${CONFIRMPASSWORD} \
  3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

if [[ "${ROOTPASSWORD}" != "${CONFIRMPASSWORD}" ]]; then
  clear; msg error "Root passwords do not match!"; exit 1
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
  --menu "Choose your timezone:" 20 50 12 \
  "${TIMEZONES[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a timezone has been chosen.
[ -z "${TIMEZONE}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  Timezone = ${TIMEZONE}\n"

# -----------------------------------------------------------------------------
# Retrieve a list with available locales.
LOCALES=($(awk '/^#.*UTF-8/ { print $0 }' /etc/locale.gen | \
           tail -n +2 | sed -e 's/^#*//'))

LANG=$(whiptail --clear --title "Arch Linux Installer" \
  --menu "Choose your language:" 20 50 12 \
  "${LOCALES[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a timezone has been chosen.
[ -z "${LANG}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  Language = ${LANG}\n"

# -----------------------------------------------------------------------------
# Retrieve a list with available locales.
LOCALES=($(awk '/^#.*UTF-8/ { print $0 " off" }' /etc/locale.gen | \
           tail -n +2 | sed -e 's/^#*//'))

LOCALES=($(whiptail --clear --title "Arch Linux Installer" \
  --checklist "Choose your locales:" 20 50 12 \
  "${LOCALES[@]}" 3>&1 1>&2 2>&3 3>&-))

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a locale has been chosen.
[ ${#LOCALES[@]} -eq 0 ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  Locales = ${LOCALES[@]}\n"

# -----------------------------------------------------------------------------
# Retrieve a list with available keyboard layouts.
TMPLIST=($(localectl list-keymaps))

for i in ${TMPLIST[@]}; do
  CLIKEYMAPS+=("${i}" "")
done

CLIKEYMAP=$(whiptail --clear --title "Arch Linux Installer" \
  --menu "Choose your TTY keyboard layout:" 20 50 12 \
  "${CLIKEYMAPS[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# Check if a keymap has been chosen.
[ -z "${CLIKEYMAP}" ] && { clear; msg error "Empty value!"; exit 1; }

CONFIGURATION+="  TTY Keyboard layout = ${CLIKEYMAP}"

# -----------------------------------------------------------------------------
MICROCODES=($(whiptail --clear --title "Arch Linux Installer" \
  --checklist "Pick CPU microcodes (press space):" 15 80 \
  $(bc <<< "${#MICROCODES[@]} / 3") "${MICROCODES[@]}" 3>&1 1>&2 2>&3 3>&-))

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# -----------------------------------------------------------------------------
KERNELPARAMS=($(whiptail --clear --title "Arch Linux Installer" \
  --checklist "Pick kernel boot parameters (press space):" 15 80 \
  $(bc <<< "${#KERNELPARAMS[@]} / 3") "${KERNELPARAMS[@]}" 3>&1 1>&2 2>&3 3>&-))

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

# -----------------------------------------------------------------------------
ENVIRONMENT=$(whiptail --clear --title "Arch Linux Installer" \
  --radiolist "Pick desktop environment (press space):" 15 80 \
  $(bc <<< "${#ENVIRONMENTS[@]} / 3") "${ENVIRONMENTS[@]}" 3>&1 1>&2 2>&3 3>&-)

# Check whiptail window return value.
[[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

if [[ ${ENVIRONMENT} == "GNOME" ]]; then
  VIDEODRIVERS=($(whiptail --clear --title "Arch Linux Installer" \
    --checklist "Pick video drivers (press space):" 15 90 \
    $(bc <<< "${#VIDEODRIVERS[@]} / 3") "${VIDEODRIVERS[@]}" 3>&1 1>&2 2>&3 3>&-))

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

  HWVIDEOACCELERATION=($(whiptail --clear --title "Arch Linux Installer" \
    --checklist "Pick hardware video acceleration drivers (press space):" 15 115 \
    $(bc <<< "${#HWVIDEOACCELERATION[@]} / 3") "${HWVIDEOACCELERATION[@]}" 3>&1 1>&2 2>&3 3>&-))

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }

  EXTRAPKGS=($(whiptail --clear --title "Arch Linux Installer" \
    --checklist "Pick additional packages (press space):" 15 80 \
    $(bc <<< "${#EXTRAPKGS[@]} / 3") "${EXTRAPKGS[@]}" 3>&1 1>&2 2>&3 3>&-))

  # Check whiptail window return value.
  [[ $? == +(1|255) ]] && { clear; msg info "Installation aborted..."; exit 1; }
fi

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
