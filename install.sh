#!/bin/bash

# ==============================================================================
# CONFIGURATION OBLIGATOIRE (À REMPLIR AVANT DE LANCER LE SCRIPT)
# ==============================================================================
DISK="/dev/sda"             # Disque cible (ex: /dev/sda ou /dev/nvme0n1)
USERNAME="archuser"         # Ton nom d'utilisateur
USER_PASS="motdepasse123"   # Mot de passe utilisateur
ROOT_PASS="rootpassword123" # Mot de passe root
HOSTNAME="arch-laptop"
# ==============================================================================

set -e

echo "=================================================="
echo "   INSTALLATION ARCH LINUX + HYPRLAND (ZEN/OPTI)  "
echo "=================================================="

# 1. Détection automatique du matériel (CPU)
if grep -q "Intel" /proc/cpuinfo; then
    MICROCODE="intel-ucode"
    MICROCODE_IMG="intel-ucode.img"
elif grep -q "AMD" /proc/cpuinfo; then
    MICROCODE="amd-ucode"
    MICROCODE_IMG="amd-ucode.img"
else
    MICROCODE=""
    MICROCODE_IMG=""
fi

# 2. Vérification d'internet
if ! ping -c 1 archlinux.org &> /dev/null; then
    echo "❌ Erreur : Pas de connexion internet. Connecte-toi avec iwctl d'abord."
    exit 1
fi
echo "✅ Connexion internet établie."

# 3. Synchronisation horloge et dépôts
echo "⏳ Préparation du système..."
timedatectl set-ntp true
pacman -Syy --noconfirm

# 4. Partitionnement automatique
echo "⏳ Partitionnement de $DISK..."
if [[ $DISK == *"nvme"* ]] || [[ $DISK == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"
    PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1"
    PART_ROOT="${DISK}2"
fi

sgdisk -Z "$DISK"
sgdisk -n 1:0:+300M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8300 "$DISK"

# CORRECTION : Forcer la relecture et attendre que les partitions existent
partprobe "$DISK" 2>/dev/null || true
partx -u "$DISK" 2>/dev/null || true
udevadm settle

echo "⏳ Attente de l'apparition des partitions dans /dev/..."
for i in {1..10}; do
    if [ -b "$PART_EFI" ] && [ -b "$PART_ROOT" ]; then
        echo "✅ Partitions disponibles."
        break
    fi
    sleep 1
done

# Si après 10 secondes ça ne marche pas, on arrête pour ne pas effacer un mauvais disque
if [ ! -b "$PART_EFI" ] || [ ! -b "$PART_ROOT" ]; then
    echo "❌ Erreur critique : Les partitions $PART_EFI ou $PART_ROOT n'existent pas."
    echo "Voici ce que le système voit :"
    lsblk
    exit 1
fi

# 5. Formatage et Montage BTRFS optimisé
echo "⏳ Formatage BTRFS avec compression ZSTD..."
mkfs.fat -F32 "$PART_EFI"
mkfs.btrfs -f "$PART_ROOT"

mount -o noatime,compress=zstd:1,space_cache=v2 "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_EFI" /mnt/boot

# 6. Installation du système strict minimum et optimisé
echo "⏳ Installation des paquets (Noyau ZEN, Hyprland, Wayland, Opti Laptop)..."
pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware btrfs-progs \
    networkmanager sudo git neovim \
    $MICROCODE power-profiles-daemon thermald acpi acpid brightnessctl \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
    mesa wayland xdg-desktop-portal xdg-desktop-portal-hyprland \
    hyprland kitty wofi waybar hyprpaper ttf-jetbrains-mono-nerd

# 7. Génération fstab optimisée
echo "⏳ Génération du fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 8. Configuration système dans le chroot
echo "⏳ Configuration du système..."
cat > /mnt/setup.sh << EOF
#!/bin/bash
set -e

# Fuseau horaire
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# Localisation FR
sed -i 's/^#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr-latin9" > /etc/vconsole.conf

# Réseau
echo "$HOSTNAME" > /etc/hostname
cat << HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME
HOSTS

# Utilisateurs
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel,video,audio,input,storage -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

# Initramfs optimisé avec systemd
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block filesystems keyboard btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION="zstd"/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (systemd-boot) optimisé
bootctl --path=/boot install
cat << LOADERCONF > /boot/loader/loader.conf
timeout 0
console-mode max
editor no
LOADERCONF

ROOT_UUID=\$(blkid -s UUID -o value $PART_ROOT)
cat << ARCHCONF > /boot/loader/entries/arch.conf
title   Arch Linux (Zen)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
EOF

if [ -n "$MICROCODE_IMG" ]; then
cat << EOF >> /mnt/setup.sh
initrd  /$MICROCODE_IMG
EOF
fi

cat >> /mnt/setup.sh << EOF
options root=UUID=\$ROOT_UUID rw rootflags=compress=zstd:1 quiet loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 nvme_core.default_ps_max_latency_us=0 pcie_aspm=power_save
ARCHCONF
bootctl update

# Services modernes pour laptop
systemctl enable NetworkManager
systemctl enable power-profiles-daemon
systemctl enable thermald
systemctl enable acpid

# Configuration Hyprland & Login TTY
USER_HOME="/home/$USERNAME"
mkdir -p \$USER_HOME/.config/hypr
cp /etc/hypr/hyprland.conf \$USER_HOME/.config/hypr/

cat << HYPRLAND >> \$USER_HOME/.config/hypr/hyprland.conf

# --- Config perso ---
input {
    kb_layout = fr
    touchpad {
        natural_scroll = true
        tap-to-click = true
    }
}
HYPRLAND

cat << BASHPROFILE > \$USER_HOME/.bash_profile
if [ -z "\${WAYLAND_DISPLAY}" ] && [ "\${XDG_VTNR}" -eq 1 ]; then
    exec Hyprland
fi
BASHPROFILE

chown -R $USERNAME:$USERNAME \$USER_HOME
EOF

# Exécution du chroot
chmod +x /mnt/setup.sh
arch-chroot /mnt /setup.sh

# Nettoyage
rm /mnt/setup.sh
umount -R /mnt

echo "=================================================="
echo "✅ INSTALLATION TERMINÉE AVEC SUCCÈS !"
echo "=================================================="
echo "Redémarrage dans 3 secondes..."
sleep 3
reboot