# Arch Linux Auto-Install Script (Hyprland + Laptop Optimisé)

Script d'installation automatisée d'Arch Linux sans LUKS, avec BTRFS, systemd-boot et Hyprland.

## 🚀 Utilisation

Démarre sur la clé USB d'installation d'Arch Linux. Une fois sur le terminal root :

### 1. Configurer le clavier en Français
```bash
loadkeys fr-latin9
```

### 2. Se connecter au Wi-Fi (Requis pour télécharger le script)
```bash
iwctl
```
Une fois dans le prompt `iwctl` :
1. Cherche le nom de ton interface (souvent `wlan0`) : `device list`
2. Scanne les réseaux : `station wlan0 scan`
3. Affiche les réseaux : `station wlan0 get-networks`
4. Connecte-toi : `station wlan0 connect "TON_SSID_WIFI"` (remplace par le nom de ton réseau)
5. Tape ton mot de passe Wi-Fi quand demandé.
6. Quitte iwctl : `quit`

### 3. Télécharger et lancer le script
```bash
pacman -Sy --noconfirm git
git clone https://github.com/arthur-pbty/archinstallscript.git
cd archinstallscript
```

### 4. Vérifier les variables
Avant de lancer, vérifie que le disque cible et les mots de passe sont bons :
```bash
nano install.sh
```
*(Modifie les variables en haut du fichier, sauvegarde avec Ctrl+O, Entrée, quitte avec Ctrl+X)*

### 5. Lancer l'installation
```bash
chmod +x install.sh
./install.sh
```
Le PC s'éteindra/redémarrera tout seul à la fin.