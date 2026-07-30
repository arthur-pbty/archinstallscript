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
    echo "[ERROR] Pas de connexion internet. Connecte-toi avec iwctl d'abord."
    exit 1
fi
echo "[OK] Connexion internet établie."

# 3. Synchronisation horloge et dépôts
echo "[INFO] Préparation du système..."
timedatectl set-ntp true
pacman -Syy --noconfirm

# 4. Nettoyage nucléaire et Partitionnement
if [[ $DISK == *"nvme"* ]] || [[ $DISK == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"
    PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1"
    PART_ROOT="${DISK}2"
fi

echo "[INFO] Nettoyage nucléaire de $DISK..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
dmsetup remove_all 2>/dev/null || true

wipefs -a -f "$DISK"* 2>/dev/null || true
wipefs -a -f "$DISK" 2>/dev/null || true

dd if=/dev/zero of="$DISK" bs=1M count=10 conv=fsync 2>/dev/null || true
DISK_SIZE_SECTORS=$(blockdev --getsz "$DISK")
dd if=/dev/zero of="$DISK" bs=512 count=10 seek=$((DISK_SIZE_SECTORS - 10)) conv=fsync 2>/dev/null || true

partprobe "$DISK" 2>/dev/null || true
blockdev --rereadpt "$DISK" 2>/dev/null || true
udevadm settle
sleep 3

echo "[INFO] Création des nouvelles partitions sur $DISK..."
sgdisk -o "$DISK"
sgdisk -n 1:0:+300M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8300 "$DISK"

partprobe "$DISK" 2>/dev/null || true
blockdev --rereadpt "$DISK" 2>/dev/null || true
udevadm settle
sleep 3

if [ ! -b "$PART_EFI" ] || [ ! -b "$PART_ROOT" ]; then
    echo "[ERROR] Les partitions $PART_EFI ou $PART_ROOT n'existent pas."
    lsblk
    exit 1
fi
echo "[OK] Partitions créées et détectées : EFI=$PART_EFI, ROOT=$PART_ROOT"

# 5. Formatage et Montage BTRFS optimisé
echo "[INFO] Formatage BTRFS avec compression ZSTD..."
mkfs.fat -F32 "$PART_EFI"
mkfs.btrfs -f "$PART_ROOT"

mount -o noatime,compress=zstd:1,space_cache=v2 "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_EFI" /mnt/boot

# 6. Installation du système strict minimum et optimisé
echo "[INFO] Installation des paquets (Noyau ZEN, Hyprland, Wayland, Opti Laptop)..."
pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware btrfs-progs \
    networkmanager sudo git neovim \
    $MICROCODE power-profiles-daemon thermald acpi acpid brightnessctl \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
    mesa wayland xdg-desktop-portal xdg-desktop-portal-hyprland \
    hyprland wofi waybar swaybg ttf-jetbrains-mono-nerd

# 7. Génération fstab optimisée
echo "[INFO] Génération du fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 8. Configuration système dans le chroot
echo "[INFO] Configuration du système..."
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
ARCHCONF

if [ -n "$MICROCODE_IMG" ]; then
cat << ARCHCONF2 >> /boot/loader/entries/arch.conf
initrd  /$MICROCODE_IMG
ARCHCONF2
fi

cat << ARCHOPTS >> /boot/loader/entries/arch.conf
options root=UUID=\$ROOT_UUID rw rootflags=compress=zstd:1 quiet loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 nvme_core.default_ps_max_latency_us=0 pcie_aspm=power_save
ARCHOPTS
bootctl update

# Services modernes pour laptop
systemctl enable NetworkManager
systemctl enable power-profiles-daemon
systemctl enable thermald
systemctl enable acpid

# Installation de Ghostty via AUR (yay)
echo "[INFO] Installation de yay et ghostty..."
sudo -u $USERNAME bash -c "cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"
sudo -u $USERNAME bash -c "yay -S --noconfirm ghostty-git || yay -S --noconfirm ghostty || true"

# Configuration Hyprland & Login TTY
USER_HOME="/home/$USERNAME"
mkdir -p \$USER_HOME/.config/hypr
mkdir -p \$USER_HOME/.config/waybar

# Suppression de l'ancien fichier lua s'il existe
rm -f \$USER_HOME/.config/hypr/hyprland.lua

cp -r /etc/xdg/waybar/* \$USER_HOME/.config/waybar/ 2>/dev/null || true

# Création de la configuration Hyprland (Syntaxe Hyprland standard)
cat << 'HYPRCONF' > \$USER_HOME/.config/hypr/hyprland.conf
# Configuration de base Hyprland
monitor=,preferred,auto,1

 $terminal = ghostty
 $fileManager = thunar
 $menu = wofi --show drun

# Autostart
exec-once = waybar
exec-once = swaybg -c '#000000'

# Environment variables
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

# Look and Feel
general {
    gaps_in = 5
    gaps_out = 20
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    resize_on_border = false
    allow_tearing = false
    layout = dwindle
}

decoration {
    rounding = 10
    rounding_power = 2
    active_opacity = 1.0
    inactive_opacity = 1.0
    shadow {
        enabled = true
        range = 4
        render_power = 3
        color = 0xee1a1a1a
    }
    blur {
        enabled = true
        size = 3
        passes = 1
        vibrancy = 0.1696
    }
}

animations {
    enabled = true
    bezier = easeOutQuint,0.23,1,0.32,1
    bezier = easeInOutCubic,0.65,0.05,0.36,1
    bezier = linear,0,0,1,1
    bezier = almostLinear,0.5,0.5,0.75,1
    bezier = quick,0.15,0,0.1,1
    bezier = easy,1,238.1191,24.21279333
    animation = global,1,10,default
    animation = border,1,5.39,easeOutQuint
    animation = windows,1,4.79,easy
    animation = windowsIn,1,4.1,easy,popin 87%
    animation = windowsOut,1,1.49,linear,popin 87%
    animation = fadeIn,1,1.73,almostLinear
    animation = fadeOut,1,1.46,almostLinear
    animation = fade,1,3.03,quick
    animation = layers,1,3.81,easeOutQuint
    animation = layersIn,1,4,easeOutQuint,fade
    animation = layersOut,1,1.5,linear,fade
    animation = fadeLayersIn,1,1.79,almostLinear
    animation = fadeLayersOut,1,1.39,almostLinear
    animation = workspaces,1,1.94,almostLinear,fade
    animation = workspacesIn,1,1.21,almostLinear,fade
    animation = workspacesOut,1,1.94,almostLinear,fade
    animation = zoomFactor,1,7,quick
}

dwindle {
    preserve_split = true
}

master {
    new_status = master
}

misc {
    force_default_wallpaper = -1
    disable_hyprland_logo = true
}

# Input
input {
    kb_layout = fr
    kb_variant =
    kb_model =
    kb_options =
    kb_rules =
    follow_mouse = 1
    sensitivity = 0
    touchpad {
        natural_scroll = true
        tap-to-click = true
    }
}

gestures {
    workspace_swipe = true
}

# Keybindings
 $mainMod = SUPER

bind = $mainMod, Return, exec, $terminal
bind = $mainMod, W, killactive, 
bind = $mainMod, M, exit, 
bind = $mainMod, E, exec, $fileManager
bind = $mainMod, V, togglefloating, 
bind = $mainMod, Space, exec, $menu
bind = $mainMod, P, pseudo, 
bind = $mainMod, J, togglesplit, 

bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

bind = $mainMod, S, togglespecialworkspace, magic
bind = $mainMod SHIFT, S, movetoworkspace, special:magic

bind = $mainMod, mouse_down, workspace, e+1
bind = $mainMod, mouse_up, workspace, e-1

bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# Laptop multimedia keys
bindle = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
bindle = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindle = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindle = , XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindle = , XF86MonBrightnessUp, exec, brightnessctl -e4 -n2 set 5%+
bindle = , XF86MonBrightnessDown, exec, brightnessctl -e4 -n2 set 5%-

bindl = , XF86AudioNext, exec, playerctl next
bindl = , XF86AudioPause, exec, playerctl play-pause
bindl = , XF86AudioPlay, exec, playerctl play-pause
bindl = , XF86AudioPrev, exec, playerctl previous

# Windows and workspaces rules
windowrule = suppressmaximizeevents, class:.*
windowrule = nofocus, class:^$,title:^$,xwayland:1,floating:1,fullscreen:0,pinned:0
windowrule = move 20 monitor_h-120, class:hyprland-run
HYPRCONF

# Lancement auto de Hyprland sur TTY1
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
echo "   INSTALLATION TERMINEE AVEC SUCCES !"
echo "=================================================="
echo "Redémarrage dans 3 secondes..."
sleep 3
reboot