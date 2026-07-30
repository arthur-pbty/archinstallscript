#!/bin/bash

# ==============================================================================
# CONFIGURATION OBLIGATOIRE (À REMPLIR AVANT DE LANCER LE SCRIPT)
# ==============================================================================
DISK="/dev/sda"
USERNAME="archuser"
USER_PASS="motdepasse123"
ROOT_PASS="rootpassword123"
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

echo "[INFO] Nettoyage nucléaire de $DISK et démontage forcé..."

# Sécurité : empêcher de formater le disque système ou le Live USB
if findmnt --source "$DISK" -n -o TARGET > /dev/null 2>&1; then
    MOUNT_TARGET=$(findmnt --source "$DISK" -n -o TARGET)
    if [[ "$MOUNT_TARGET" == "/" || "$MOUNT_TARGET" == "/run/archiso"* ]]; then
        echo "[ERROR] Le disque $DISK est actuellement utilisé par le système ($MOUNT_TARGET)."
        echo "        Si tu es sur le Live USB, le disque cible n'est pas $DISK (vérifie avec lsblk)."
        exit 1
    fi
fi

# Démonter /mnt récursivement et de manière "paresseuse"
umount -R /mnt 2>/dev/null || true
umount -l /mnt 2>/dev/null || true

# Récupérer toutes les partitions du disque et les démonter de force
PARTITIONS=$(lsblk -lnpo NAME "$DISK" 2>/dev/null)
for part in $PARTITIONS; do
    if findmnt --source "$part" -n -o TARGET > /dev/null 2>&1; then
        echo "[INFO] Démontage forcé de $part..."
        umount -lf "$part" 2>/dev/null || true
    fi
done

# Arrêt des volumes chiffrés, LVM, et RAID qui pourraient bloquer le disque
cryptsetup close --all 2>/dev/null || true
vgchange -an 2>/dev/null || true
mdadm --stop --scan 2>/dev/null || true

# Désactiver les swaps et les mappings
swapoff -a 2>/dev/null || true
dmsetup remove_all 2>/dev/null || true

# Nettoyer les signatures et détruire les tables avec sgdisk (plus propre que dd)
echo "[INFO] Effacement des tables de partition..."
sgdisk --zap-all "$DISK" 2>/dev/null || true

# Forcer la relecture
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
echo "[INFO] Installation des paquets officiels..."
pacstrap --noconfirm /mnt base base-devel linux-zen linux-zen-headers linux-firmware btrfs-progs \
    networkmanager sudo git neovim curl wget unzip rsync \
    $MICROCODE power-profiles-daemon thermald acpi acpid brightnessctl \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
    mesa wayland xdg-desktop-portal xdg-desktop-portal-hyprland \
    hyprland wofi waybar swaybg ttf-jetbrains-mono-nerd kitty \
    bluez bluez-utils thunar playerctl \
    fastfetch btop htop ncdu yazi lazygit \
    rust cargo go zig wayland-protocols scdoc \
    fontconfig freetype2 harfbuzz libxkbcommon pkgconf

# 7. Génération fstab optimisée
echo "[INFO] Génération du fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 8. Configuration système dans le chroot
echo "[INFO] Configuration du système..."
cat > /mnt/setup.sh << EOF
#!/bin/bash
set -e

# Mise à jour de la keyring et du système
echo "[INFO] Mise à jour de la keyring et du système..."
pacman -Sy --noconfirm archlinux-keyring
pacman -Su --noconfirm

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
systemctl enable bluetooth

# Configuration SWAP (Fichier d'échange de 4 Go compatible BTRFS)
echo "[INFO] Création d'un swapfile de 4Go pour éviter le Out of Memory..."
truncate -s 0 /swapfile
chattr +C /swapfile
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

# Connexion TTY automatique
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat << GETTYCONF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \$TERM
GETTYCONF

# Configuration AUR (paru) et optimisation RAM
echo "[INFO] Configuration de sudo sans mot de passe temporaire..."
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/temp
chmod 0440 /etc/sudoers.d/temp

# Préconfiguration de paru
mkdir -p /home/$USERNAME/.config/paru
cat << PARUCONF > /home/$USERNAME/.config/paru/paru.conf
[options]
SkipReview
CleanAfter
Provides
PgpFetch
CombinedUpgrade
Makepkgflags = --noconfirm --skippgpcheck
PARUCONF
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/paru

echo "[INFO] Compilation de paru depuis les sources..."
yes | sudo -u $USERNAME bash -c "cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si --noconfirm --skippgpcheck" || echo "[WARNING] Paru install failed"

if ! command -v paru &> /dev/null; then
    echo "[ERROR] paru n'a pas pu être installé."
else
    echo "[INFO] Installation de ghostty et bluetui..."
    yes | sudo -u $USERNAME bash -c "paru -S --noconfirm --skipreview ghostty-git bluetui" || echo "[WARNING] Erreur pendant l'install de ghostty/bluetui"
fi

echo "[INFO] Restauration de la sécurité sudo..."
rm -f /etc/sudoers.d/temp

# Configuration Hyprland, Waybar & Login TTY
USER_HOME="/home/$USERNAME"
mkdir -p \$USER_HOME/.config/hypr
mkdir -p \$USER_HOME/.config/waybar

rm -f \$USER_HOME/.config/hypr/hyprland.conf

cat << 'WAYBARCONF' > \$USER_HOME/.config/waybar/config
{
    "layer": "top",
    "position": "left",
    "width": 30,
    "height": "auto",
    "spacing": 4,
    "modules-left": ["wlr/workspaces"],
    "modules-center": ["pulseaudio", "network", "bluetooth", "battery"],
    "modules-right": ["clock"],
    "wlr/workspaces": {
        "format": "{icon}",
        "on-click": "activate"
    },
    "clock": {
        "format": "{:%H\n%M\n%d\n%m}",
        "tooltip-format": "<tt>{calendar}</tt>"
    },
    "pulseaudio": {
        "format": "{volume}%\n{icon}",
        "format-muted": "MUTE",
        "format-icons": {
            "default": ["VOL"]
        }
    },
    "network": {
        "format-wifi": "WIFI\n{essid}",
        "format-ethernet": "ETH",
        "format-disconnected": "DISC"
    },
    "bluetooth": {
        "format": "BT\n{status}",
        "format-connected": "BT\n{device_alias}",
        "format-off": "BT OFF"
    },
    "battery": {
        "format": "{capacity}%\n{icon}",
        "format-icons": ["BAT"]
    }
}
WAYBARCONF

cat << 'WAYBARCSS' > \$USER_HOME/.config/waybar/style.css
* {
    font-family: "JetBrainsMono Nerd Font", monospace;
    font-size: 14px;
    color: #ffffff;
}

window#waybar {
    background-color: rgba(0, 0, 0, 1);
}

#workspaces button {
    padding: 5px 0px;
    color: #ffffff;
}

#workspaces button.active {
    color: #00ff99;
}

#clock, #pulseaudio, #network, #bluetooth, #battery {
    padding: 5px 0px;
    margin: 2px 0px;
}
WAYBARCSS

cat << 'HYPRCONF' > \$USER_HOME/.config/hypr/hyprland.lua
-- This is an example Hyprland Lua config file.
-- Refer to the wiki for more information.
-- https://wiki.hypr.land/Configuring/Start/

------------------
---- MONITORS ----
------------------

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})

---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "ghostty"
local fileManager = "thunar"
local menu        = "wofi --show drun"

-------------------
---- AUTOSTART ----
-------------------

hl.on("hyprland.start", function () 
  hl.exec_cmd("waybar")
  hl.exec_cmd("swaybg -c '#000000'")
end)

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = 20,
        border_size = 2,
        col = {
            active_border   = { colors = {"rgba(33ccffee)", "rgba(00ff99ee)"}, angle = 45 },
            inactive_border = "rgba(595959aa)",
        },
        resize_on_border = false,
        allow_tearing = false,
        layout = "dwindle",
    },
    decoration = {
        rounding       = 10,
        rounding_power = 2,
        active_opacity   = 1.0,
        inactive_opacity = 1.0,
        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = 0xee1a1a1a,
        },
        blur = {
            enabled   = true,
            size      = 3,
            passes    = 1,
            vibrancy  = 0.1696,
        },
    },
    animations = {
        enabled = true,
    },
})

hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1}    } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1}    } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1}       } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1}    } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1}     } })
hl.curve("easy",           { type = "spring", mass = 1, stiffness = 238.1191, dampening = 24.21279333 })

hl.animation({ leaf = "global",        enabled = true,  speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",        enabled = true,  speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",       enabled = true,  speed = 4.79, spring = "easy" })
hl.animation({ leaf = "windowsIn",     enabled = true,  speed = 4.1,  spring = "easy",         style = "popin 87%" })
hl.animation({ leaf = "windowsOut",    enabled = true,  speed = 1.49, bezier = "linear",       style = "popin 87%" })
hl.animation({ leaf = "fadeIn",        enabled = true,  speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true,  speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade",          enabled = true,  speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers",        enabled = true,  speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn",      enabled = true,  speed = 4,    bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true,  speed = 1.5,  bezier = "linear",       style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true,  speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true,  speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true,  speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn",  enabled = true,  speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true,  speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "zoomFactor",    enabled = true,  speed = 7,    bezier = "quick" })

hl.config({
    dwindle = {
        preserve_split = true,
    },
})

hl.config({
    master = {
        new_status = "master",
    },
})

hl.config({
    scrolling = {
        fullscreen_on_one_column = true,
    },
})

----------------
----  MISC  ----
----------------

hl.config({
    misc = {
        force_default_wallpaper = -1,
        disable_hyprland_logo   = true,
    },
})

---------------
---- INPUT ----
---------------

hl.config({
    input = {
        kb_layout  = "fr",
        kb_variant = "",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",
        follow_mouse = 1,
        sensitivity = 0,
        touchpad = {
            natural_scroll = true,
        },
    },
})

hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace"
})

---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER"

hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
local closeWindowBind = hl.bind(mainMod .. " + W", hl.dsp.window.close())
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + Space", hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))

hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

for i = 1, 10 do
    local key = i % 10
    hl.bind(mainMod .. " + " .. key,             hl.dsp.focus({ workspace = i}))
    hl.bind(mainMod .. " + SHIFT + " .. key,     hl.dsp.window.move({ workspace = i }))
end

hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true, repeating = true })
hl.bind("XF86MonBrightnessUp",  hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown",hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true })

hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },
    no_focus = true,
})

hl.window_rule({
    name  = "move-hyprland-run",
    match = { class = "hyprland-run" },
    move  = "20 monitor_h-120",
    float = true,
})
HYPRCONF

cat << 'BASHPROFILE' > \$USER_HOME/.bash_profile
if [ -z "\${WAYLAND_DISPLAY}" ] && [ "\${XDG_VTNR}" -eq 1 ]; then
    while true; do
        read -s -p "Mot de passe: " PASS
        echo ""
        if echo "\$PASS" | sudo -S -k true 2>/dev/null; then
            exec Hyprland
            break
        else
            echo "Mot de passe incorrect."
        fi
    done
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