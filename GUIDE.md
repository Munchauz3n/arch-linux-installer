# Arch Linux with BTRFS File System and Full Disk Encryption

## Pre-installation

### Connect to the internet
Ensure your network interface is listed and enabled, for example with **ip-link**:

- For wireless, make sure the wireless card is not blocked with rfkill.
- Connect to the network:
 - Ethernet—plug in the cable.
 - Wi-Fi—authenticate to the wireless network using iwctl.
```
iwctl station <Your Staion Name(wlan0, wlp2s0, etc.)> connect <Network Name>
```
- Configure your network connection:
 - DHCP: dynamic IP address and DNS server assignment (provided by systemd-networkd and systemd-resolved) should work out of the box for wired and wireless network interfaces.
 - Static IP address: follow Network configuration#Static IP address.
- The connection may be verified with ping:
```
ping archlinux.org
```

### Disk Layout

``` Bash
+----------------------+----------------------+----------------------+
| EFI system partition | Swap partition       | System partition     |
| unencrypted          | LUKS2-encrypted      | LUKS1-encrypted      |
|                      |                      |                      |
| /efi                  | [SWAP]               | /                    |
| /dev/sda1            | /dev/sda2            | /dev/sda3            |
+----------------------+----------------------+----------------------+

```

### Partition Drive
First select the drive you want to partition, or example /dev/sda, /dev/nvme0n1, etc. and remove any lingering information related to the previously installed partition.

```
sgdisk --zap-all /dev/sda # /dev/nvme0n1
```

Next we be will be using the sgdisk utility from the gptfdisk package. Other alternatives are fdisk, gdisk, etc. We are going to utilize the swap partition with suspend-to-disk support (hibernation) so make sure its size is 2 GB more than the RAM size. Example for 16 GB RAM the swap partition will be 18 GB (16 + 2).

```
sgdisk --clear \
       --new=1:0:+512MiB --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+18GiB  --typecode=2:8200 --change-name=2:cryptswap \
       --new=3:0:0       --typecode=3:8300 --change-name=3:cryptsystem \
       /dev/sda # /dev/nvme0n1
```

In the command above we are setting 512 MB for the UEFI partion, 18 GB for the swap and the rest is for the system/root partition. The partition typecodes are as follows:
ef00 - EFI System
8200 - Linux swap
8300 - Linux filesystem

### Format EFI Partition
Format the first (EFI) partition using the (required) FAT32 filesystem.

```
mkfs.vfat -F 32 -n EFI /dev/sda1 # /dev/nvme0n1p1
```

### Encrypt System Partition
Create the LUKS1 encrypted container on the last partition where the /boot directory will be located (GRUB does not support booting from LUKS2 as of October 2020). The "--align-payload" value has been used as per this ["How to optimise encrypted filesystems on an SSD?"](https://www.spinics.net/lists/dm-crypt/msg02421.htmlhttp:// "How to optimise encrypted filesystems on an SSD?") on the dm-crypt mailing list.

```
cryptsetup luksFormat --type luks1 --iter-time 5000 --align-payload=8192 /dev/sda3 # /dev/nvme0n1p3
```

After creating the encrypted container, open it. Note that once we open this device we are giving it a name of "system." Thus "cryptsystem" is the encrypted system partition, while "system" is the name we are using once it has been opened in an unencrypted state. These names are arbitrary (Linux doesn't care what we use) but they help us keep things organized during this process.

```
cryptsetup open /dev/sda3 system # /dev/nvme0n1p3
```

### Create and Mount System BTRFS Subvolumes
First we create a top-level BTRFS subvolume. Note that the top-level entity in BTRFS nomenclature is still referred to as a subvolume, despite being at the top-level.
We will create and mount this subvolume, create some new subvolumes inside it, and then switch to those subvolumes as our proper, mounted filesystems. Doing this will enable us to treat our root filesystem as a snapshotable object.
Top-level subvolume creation.

```
mkfs.btrfs --force --label system /dev/mapper/system
```

Use the /mnt directory as temporarily mount point for our top-level volume. We are using the decrypted filesystem label to mount our subvolume, which is distinct from the partition labels used earlier.

```
mount -t btrfs LABEL=system /mnt
```

Create subvolumes at /mnt/root, /mnt/home, /mnt/snapshots and any additional subvolumes you wish to use as mount points.

```
btrfs subvolume create /mnt/root
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/snapshots
```

Umount everything.

```
umount -R /mnt
```

Remount just the subvolumes under our top-level subvolume.

```
mount -t btrfs -o subvol=root,defaults,x-mount.mkdir,compress=lzo,ssd,noatime LABEL=system /mnt
mount -t btrfs -o subvol=home,defaults,x-mount.mkdir,compress=lzo,ssd,noatime LABEL=system /mnt/home
mount -t btrfs -o subvol=snapshots,defaults,x-mount.mkdir,compress=lzo,ssd,noatime LABEL=system /mnt/.snapshots
```

### Encrypt and Initialize Swap Partition
Create the LUKS2 encrypted container.

```
cryptsetup luksFormat --align-payload=8192 /dev/sda2 # /dev/nvme0n1p2
```

After creating the encrypted container, open it. Again, using partition labels to identify the partition and going from "cryptswap" to just "swap".

```
cryptsetup open /dev/sda2 swap # /dev/nvme0n1p2
```

Initialize and enable the decrypted container as swap area.

```
mkswap -L swap /dev/mapper/swap
swapon -L swap
```

### Mount EFI partition
Create a mountpoint for the EFI system partition at /efi for compatibility with grub-install and mount it.

```
mkdir /mnt/efi
mount /dev/sda1 /mnt/efi # /dev/nvme0n1p1
```

## Installation

### Install base packages

```
pacstrap /mnt base base-devel linux linux-firmware util-linux man-db man-pages texinfo openssh sudo \
         zsh zsh-completions gptfdisk vim iwd usbutils cryptsetup grub efibootmgr btrfs-progs terminus-font \
         ttf-dejavu ttf-liberation
```

- Enable microcode updates, grub-mkconfig will automatically detect microcode updates and configure appropriately.

```
pacstrap /mnt intel-ucode # For Intel processor
pacstrap /mnt amd-ucode # For AMD processor
```

### Configure the system

- Generate Fstab.

```
genfstab -L -p /mnt >> /mnt/etc/fstab
```

- Change root.

```
arch-chroot /mnt
```

- Set default editor to vim.

```
echo "export EDITOR=/usr/bin/vim" > /etc/skel/.profile
```

- Set timezone, locales, keyboard and fonts.

```
# Set local time.
ln -sf /usr/share/zoneinfo/<YourContinent>/<YourCity> /etc/localtime
hwclock --systohc

# Set the system locale.
vim /etc/locale.gen (uncomment en_GB.UTF-8, en_US.UTF-8 UTF-8 and any other needed locales)
locale-gen

echo "LANG=en_GB.UTF-8" > /etc/locale.conf

#  Set the keyboard layout. Available layouts can be listed with: ls /usr/share/kbd/keymaps/**/*.map.gz
loadkeys uk
echo "KEYMAP=uk" > /etc/vconsole.conf

# Console fonts are located in /usr/share/kbd/consolefonts/
setfont eurlatgr
echo "FONT=eurlatgr" >> /etc/vconsole.conf
```

- Set the hostname.

```
echo <myhostname> > /etc/hostname

vim /etc/hosts
127.0.0.1       localhost
::1             localhost ipv6-localhost ipv6-loopback
127.0.1.1       <myhostname>.localdomain <myhostname>
```

- Set the root password.

```
passwd
```

- (Laptop) Set battery charge thresholds. Values will be stored in battery microcontroller and will survive reboot, but reset if you remove the battery.

```
echo 40 > /sys/class/power_supply/BAT0/charge_start_threshold
echo 80 > /sys/class/power_supply/BAT0/charge_stop_threshold
```

### (Optinal) Add users

- Create new user with its home directory and set his password.

```
useradd --create-home <name>
passwd <name>
```

- (Optional) To allow user to gain root access uncomment the “wheel” group in /etc/sudoers.

```
visudo
----
%wheel ALL=(ALL) ALL

# Add the user to the wheel group:
gpasswd -a name wheel
```

### Configuring mkinitcpio

- Add the **keyboard**, **sd-vconsole**, **sd-encrypt** and **btrfs** hooks to initial ramdisk (/etc/mkinitcpio.conf)

```
HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt btrfs filesystems fsck)
```

- The btrfs-check tool cannot be used on a mounted file system. To be able to use btrfs-check without booting from a live USB, add it to the initial ramdisk - [Btrfs - Corruption recovery](https://wiki.archlinux.org/index.php/Btrfs#Corruption_recovery").

```
BINARIES=(/usr/bin/btrfs)
```

- For early loading of the KMS (Kernel Mode Setting) driver for video.

```
# i915 - for Intel graphics.
# amdgpu - for AMDGPU, or radeon when using the legacy ATI driver.
# nouveau - for the open-source Nouveau driver.
# mgag200 - for Matrox graphics.

MODULES=(i915)
```

- Recreate initramfs.

```
mkinitcpio -P
```

### Configuring GRUB

- Set the kernel parameters, so that the initramfs can unlock the encrypted partitions.

```
GRUB_CMDLINE_LINUX_DEFAULT="... rd.luks.name=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX=swap resume=/dev/mapper/swap ..."
GRUB_CMDLINE_LINUX="... rd.luks.name=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX=system root=/dev/mapper/system ..."

# Where XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX is the UUID of the UUID of the corresponding LUKS partition.
# It can be fetch using below commands for the swap and system partitions respectively:
lsblk -dno UUID /dev/sda2 # /dev/nvme0n1p2
lsblk -dno UUID /dev/sda3 # /dev/nvme0n1p3

# Automated commands with sed.
sed  -i "/GRUB_CMDLINE_LINUX_DEFAULT/ s/\(.*\)\"/\1 rd.luks.name=$(lsblk -dno UUID /dev/sda2)=swap resume=\/dev\/mapper\/swap\"/" /etc/default/grub # /dev/nvme0n1p2
sed  -i "/GRUB_CMDLINE_LINUX/ s/\(.*\)\"/\1rd.luks.name=$(lsblk -dno UUID /dev/sda3)=system root=\/dev\/mapper\/system\"/" /etc/default/grub # /dev/nvme0n1p3
```

- Configure GRUB to allow booting from /boot on a LUKS1 encrypted partition (/etc/default/grub).

```
GRUB_ENABLE_CRYPTODISK=y
```

- (Thinkpad X230) Mute Button. The mute button does not work properly on most ThinkPads and IdeaPads with a newer kernel. To properly handle the mute button add 'acpi_osi=Linux' parameter to the GRUB CMDLINE.

```
GRUB_CMDLINE_LINUX="acpi_osi=Linux"
```

- Install GRUB in /efi and create configuration file.

```
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg
```
	
- Restruct /boot permissions.

```
chmod 700 /boot
```

### (Recommended) Create keyfiles. 
In order for GRUB to open the LUKS partition without having the user enter his passphrase twice, we will use a keyfiles embedded in the initramfs.

- Create keys and save them in /etc/cryptsetup-keys.d and add then to the LUKS partitions.

```
mkdir /etc/cryptsetup-keys.d && chmod 700 /etc/cryptsetup-keys.d

dd bs=512 count=4 if=/dev/urandom of=/etc/cryptsetup-keys.d/cryptswap.key
chmod 600 /dev/sda2 /etc/cryptsetup-keys.d/cryptswap.key
cryptsetup -v luksAddKey -i 1 /dev/sda2 /etc/cryptsetup-keys.d/cryptswap.key # /dev/nvme0n1p2

dd bs=512 count=4 if=/dev/urandom of=/etc/cryptsetup-keys.d/cryptsystem.key
chmod 600 /dev/sda2 /etc/cryptsetup-keys.d/cryptsystem.key
cryptsetup -v luksAddKey -i 1 /dev/sda3 /etc/cryptsetup-keys.d/cryptsystem.key # /dev/nvme0n1p3
```


- Add the keys to the initramfs (/etc/mkinitcpio.conf).

```
FILES=(/etc/cryptsetup-keys.d/cryptswap.key /etc/cryptsetup-keys.d/cryptsystem.key)
```

- Add the keys to the grub configuration (/etc/default/grub).

```
GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name= ... rd.luks.key=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX=/etc/cryptsetup-keys.d/cryptswap.key ... resume= ..."
GRUB_CMDLINE_LINUX="rd.luks.name= ... rd.luks.key=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX=/etc/cryptsetup-keys.d/cryptsystem.key ... root= ..."

# Where XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX is the UUID of the UUID of the corresponding LUKS partition.
# It can be fetch using below commands for the swap and system partitions respectively:
lsblk -dno UUID /dev/sda2 # /dev/nvme0n1p2
lsblk -dno UUID /dev/sda3 # /dev/nvme0n1p3

# Automated commands with sed.
sed  -i "/GRUB_CMDLINE_LINUX_DEFAULT/ s/\(.*\)\"/\1 rd.luks.key=$(lsblk -dno UUID /dev/sda2)=\/etc\/cryptsetup-keys.d\/cryptswap.key\"/" /etc/default/grub # /dev/nvme0n1p2
sed  -i "/GRUB_CMDLINE_LINUX/ s/\(.*\)\"/\1 rd.luks.key=$(lsblk -dno UUID /dev/sda3)=\/etc\/cryptsetup-keys.d\/cryptsystem.key\"/" /etc/default/grub # /dev/nvme0n1p3
```

- Recreate initramfs and generate new GRUB configuration file.

```
mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg
```

### Install essential packages

- Useful services.

```
pacman -S acpid acpi lm_sensors ntp dbus cronie

systemctl enable acpid
systemctl enable ntpd
```

- ALSA (Advanced Linux Sound Architecture) utilities.

```
pacman -S alsa-utils
```

### Install GUI environment

- Xorg display server and xinitrc.

```
pacman -S xorg-server xorg-xinit
```

- Xorg relates packages:
 - **xorg-xset** - Xorg user preference utility.
 - **xorg-xprop** - Xorg property displayer.
 - **xorg-xrandr** - Xorg primitive command line interface to RandR extension.
 - **xorg-xclock** - Xorg clock.
 - **xdg-utils** - Command line tools that assist applications with a variety of desktop integration tasks.

```
pacman -S xorg-xset xorg-xprop xorg-xrandr xorg-xclock xdg-utils
```

- Video drivers.
 - **vesa** - Driver does not provide acceleration but will work with most hardware. It can be installed as a fallback to other drivers if for whatever reason they fail.
 - **xf86-video-intel** - intall for Intel integrated graphics.
 - **xf86-video-nouveau** - intall for NVidia GPUs.
 - **xf86-video-amdgpu** - intall for AMD GPUs from GCN 3 and newer (Radeon Rx 300 or higher).
 - **xf86-video-ati** - intall AMD GPUs from GCN 2 and older.

```
pacman -S xf86-video-vesa xf86-video-intel

# Identify your card:
lspci | grep -e VGA -e 3D

# Install hardware specific drivers:
pacman -S xf86-video-intel
```

- (Optinal) Vulkan drivers.
 - **vulkan-icd-loader** - Vulkan Installable Client Driver (ICD) Loader.
 - **vulkan-intel** - intall for Intel integrated graphics.
 - **nvidia-utils** - intall for NVidia GPUs.
 - **vulkan-radeon** - intall for AMD GPUs.

```

pacman -S vulkan-icd-loader vulkan-radeon
```

- Laptop touchpad support.

```
pacman -S xf86-input-synaptics
```

- Laptops with touchscreen and Wacom stylus.

```
pacman -S xf86-input-libinput xf86-input-wacom
```

- Minimal gnome installation.

```
pacman -S baobab cheese eog evince file-roller gdm gedit gnome-backgrounds gnome-calculator \
          gnome-calendar gnome-clocks gnome-control-center gnome-logs gnome-menus gnome-remote-desktop \
          gnome-screenshot gnome-session gnome-settings-daemon gnome-shell gnome-shell-extensions \
          gnome-system-monitor gnome-terminal gnome-themes-extra gnome-user-docs gnome-user-share \
          gnome-video-effects gnome-weather gnome-bluetooth gnome-icon-theme gnome-icon-theme-extras \
          gvfs mutter nautilus yelp xdg-user-dirs guake pulseaudio pavucontrol networkmanager
```

- Using iwd as the Wi-Fi backend in the NetworkManager.

```
vim /etc/NetworkManager/conf.d/wifi-backend.conf
----
[device]
wifi.backend=iwd
```

- Enable the network Manager service.

```
systemctl enable NetworkManager.service
```
