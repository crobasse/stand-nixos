#!/usr/bin/env bash
# ==============================================================================
# Auto-installateur NixOS + Photo Stand exécuté au boot de l'image Netboot iPXE.
#
# Étapes automatiques :
#   1. Attend le réseau et lit les paramètres noyau iPXE (`stand.repo`, etc.)
#   2. Sélectionne (et confirme) le disque cible
#   3. Partitionne + formate automatiquement (UEFI GPT ou BIOS Legacy MBR)
#   4. Clone `stand-nixos` dans /mnt/etc/stand-nixos
#   5. Génère `host/hardware-configuration.nix` + `local.nix`
#   6. Installe NixOS complet (`nixos-install --flake /mnt/etc/stand-nixos#stand`)
#   7. Redémarre sur le disque local (prêt à l'emploi : i3 + Firefox + Docker Compose)
# ==============================================================================

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

step()    { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[ERREUR]${NC} $*"; }

part_path() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

on_error() {
  echo ""
  fail "L'installation a échoué (ligne $1)."
  echo "Vous pouvez inspecter les logs ou relancer manuellement : photostand-netboot-installer"
  echo "Ouverture d'un shell de dépannage..."
  exec bash
}
trap 'on_error $LINENO' ERR

clear || true
echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  Photo Stand — Auto-installateur NixOS (Netboot iPXE)${NC}"
echo -e "${BOLD}======================================================================${NC}"
echo "  SSH de dépannage disponible : root@<IP> (mot de passe : stand)"
echo "  Terminal alternatif         : Alt+F2"
echo ""

# ------------------------------------------------------------------------------
# 1. Lecture des paramètres noyau iPXE (/proc/cmdline)
# ------------------------------------------------------------------------------
CMD_REPO=""
CMD_REF="main"
CMD_DISK=""
CMD_STAND_ID=""
CMD_PRIMARY_IP=""
CMD_PROFILES=""
CMD_STORAGE_ENDPOINT=""
CMD_AUTO_WIPE="0"

read -ra CMDLINE_TOKENS < /proc/cmdline
for token in "${CMDLINE_TOKENS[@]}"; do
  case "$token" in
    stand.repo=*)             CMD_REPO="${token#stand.repo=}" ;;
    stand.ref=*)              CMD_REF="${token#stand.ref=}" ;;
    stand.disk=*)             CMD_DISK="${token#stand.disk=}" ;;
    stand.id=*)               CMD_STAND_ID="${token#stand.id=}" ;;
    stand.primary_ip=*)       CMD_PRIMARY_IP="${token#stand.primary_ip=}" ;;
    stand.profiles=*)         CMD_PROFILES="${token#stand.profiles=}" ;;
    stand.storage_endpoint=*) CMD_STORAGE_ENDPOINT="${token#stand.storage_endpoint=}" ;;
    stand.auto_wipe=*)        CMD_AUTO_WIPE="${token#stand.auto_wipe=}" ;;
  esac
done

# ------------------------------------------------------------------------------
# 2. Attente du réseau
# ------------------------------------------------------------------------------
step "[1/7] Vérification de la connexion réseau..."
NET_OK=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 https://github.com >/dev/null 2>&1; then
    NET_OK=1
    break
  fi
  echo "  Attente du réseau / DHCP ($i/30)..."
  sleep 2
done

if [ "$NET_OK" -ne 1 ]; then
  warn "Réseau non joignable automatiquement (vérifiez le câble Ethernet ou configurez via nmtui)."
  read -r -p "Appuyez sur Entrée une fois le réseau prêt (ou tapez 'nmtui') : " net_ans
  if [ "$net_ans" = "nmtui" ]; then
    nmtui || true
  fi
fi
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || echo "inconnue")"
success "Réseau prêt (IP locale : $LAN_IP)."

# ------------------------------------------------------------------------------
# 3. Paramètres dépôt & disque cible
# ------------------------------------------------------------------------------
step "[2/7] Configuration de l'installation..."

while [ -z "$CMD_REPO" ]; do
  read -r -p "URL du dépôt Git stand-nixos (ex: https://github.com/user/stand-nixos.git) : " CMD_REPO
done

echo "  Dépôt stand-nixos : $CMD_REPO (ref : $CMD_REF)"

if [ -z "$CMD_DISK" ]; then
  echo ""
  echo "Disques disponibles sur cette machine :"
  lsblk -d -p -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr[0-9]|zram' || lsblk -d -p -o NAME,SIZE,MODEL,TRAN
  echo ""
  while [ -z "$CMD_DISK" ] || [ ! -b "$CMD_DISK" ]; do
    read -r -p "Disque cible à effacer pour installer NixOS (ex: /dev/nvme0n1 ou /dev/sda) : " CMD_DISK
    if [ ! -b "$CMD_DISK" ]; then
      warn "'$CMD_DISK' n'est pas un périphérique bloc valide."
    fi
  done
fi

if [ ! -b "$CMD_DISK" ]; then
  fail "Disque cible introuvable : $CMD_DISK"
  exit 1
fi

BOOT_MODE="bios"
if [ -d /sys/firmware/efi/efivars ]; then
  BOOT_MODE="uefi"
fi

echo ""
echo -e "${BOLD}Récapitulatif avant effacement :${NC}"
echo "  - Disque cible    : $CMD_DISK ($(lsblk -dn -o SIZE,MODEL "$CMD_DISK" 2>/dev/null || true))"
echo "  - Mode de boot    : $BOOT_MODE"
echo "  - Dépôt Config    : $CMD_REPO @ $CMD_REF"
[ -n "$CMD_STAND_ID" ]   && echo "  - Stand ID        : $CMD_STAND_ID"
[ -n "$CMD_PRIMARY_IP" ] && echo "  - Primary IP      : $CMD_PRIMARY_IP"
[ -n "$CMD_PROFILES" ]   && echo "  - Profils Docker  : $CMD_PROFILES"
echo ""

if [ "$CMD_AUTO_WIPE" != "1" ]; then
  warn "TOUTES LES DONNÉES SUR $CMD_DISK SERONT EFFACÉES !"
  read -r -p "Tapez OUI en majuscules pour confirmer l'installation : " CONFIRM
  if [ "$CONFIRM" != "OUI" ]; then
    echo "Installation annulée. Ouverture d'un shell..."
    exec bash
  fi
fi

# ------------------------------------------------------------------------------
# 4. Partitionnement, formatage et montage
# ------------------------------------------------------------------------------
step "[3/7] Partitionnement et formatage de $CMD_DISK ($BOOT_MODE)..."

umount -R /mnt 2>/dev/null || true
wipefs -af "$CMD_DISK"

if [ "$BOOT_MODE" = "uefi" ]; then
  parted -s "$CMD_DISK" -- mklabel gpt
  parted -s "$CMD_DISK" -- mkpart ESP fat32 1MiB 513MiB
  parted -s "$CMD_DISK" -- set 1 esp on
  parted -s "$CMD_DISK" -- mkpart primary ext4 513MiB 100%

  udevadm settle
  sleep 1

  BOOT_PART="$(part_path "$CMD_DISK" 1)"
  ROOT_PART="$(part_path "$CMD_DISK" 2)"

  mkfs.fat -F 32 -n ESP "$BOOT_PART"
  mkfs.ext4 -F -L nixos "$ROOT_PART"

  mount "$ROOT_PART" /mnt
  mkdir -p /mnt/boot
  mount -o umask=0077 "$BOOT_PART" /mnt/boot
else
  parted -s "$CMD_DISK" -- mklabel msdos
  parted -s "$CMD_DISK" -- mkpart primary ext4 1MiB 100%
  parted -s "$CMD_DISK" -- set 1 boot on

  udevadm settle
  sleep 1

  ROOT_PART="$(part_path "$CMD_DISK" 1)"
  mkfs.ext4 -F -L nixos "$ROOT_PART"
  mount "$ROOT_PART" /mnt
fi
success "Disque partitionné et monté sur /mnt."

# ------------------------------------------------------------------------------
# 5. Clonage de stand-nixos sur le système cible
# ------------------------------------------------------------------------------
step "[4/7] Clonage de $CMD_REPO ($CMD_REF) vers /mnt/etc/stand-nixos..."
mkdir -p /mnt/etc
rm -rf /mnt/etc/stand-nixos
git clone "$CMD_REPO" /mnt/etc/stand-nixos
git -C /mnt/etc/stand-nixos checkout "$CMD_REF"
success "Dépôt stand-nixos cloné dans /mnt/etc/stand-nixos."

# ------------------------------------------------------------------------------
# 6. Génération hardware-configuration.nix + local.nix
# ------------------------------------------------------------------------------
step "[5/7] Génération de host/hardware-configuration.nix et local.nix..."
mkdir -p /mnt/etc/stand-nixos/host
nixos-generate-config --root /mnt --show-hardware-config > /mnt/etc/stand-nixos/host/hardware-configuration.nix

# Construction de local.nix avec le bootloader détecté + éventuelles surcharges iPXE
STAND_OVERRIDES=""
[ -n "$CMD_STAND_ID" ]         && STAND_OVERRIDES="${STAND_OVERRIDES}    standId = \"${CMD_STAND_ID}\";"$'\n'
[ -n "$CMD_PRIMARY_IP" ]       && STAND_OVERRIDES="${STAND_OVERRIDES}    primaryIp = \"${CMD_PRIMARY_IP}\";"$'\n'
[ -n "$CMD_STORAGE_ENDPOINT" ] && STAND_OVERRIDES="${STAND_OVERRIDES}    storageEndpoint = \"${CMD_STORAGE_ENDPOINT}\";"$'\n'
if [ -n "$CMD_PROFILES" ]; then
  PROFILES_LIST="$(echo "$CMD_PROFILES" | awk -F, '{printf "[ "; for (i=1; i<=NF; i++) printf "\"%s\" ", $i; printf "]"}')"
  STAND_OVERRIDES="${STAND_OVERRIDES}    composeProfiles = ${PROFILES_LIST};"$'\n'
fi

cat > /mnt/etc/stand-nixos/local.nix <<EOF
# Généré automatiquement par l'auto-installateur Netboot iPXE
{
  install = {
    bootloader = "${BOOT_MODE}";
    grubDevice = "${CMD_DISK}";
  };
$(if [ -n "$STAND_OVERRIDES" ]; then
  echo "  stand = {"
  printf "%s" "$STAND_OVERRIDES"
  echo "  };"
fi)
}
EOF

git -C /mnt/etc/stand-nixos add -f host/hardware-configuration.nix local.nix
success "Configuration matérielle et locale générées."

# ------------------------------------------------------------------------------
# 7. Installation complète de NixOS + Photo Stand sur le disque
# ------------------------------------------------------------------------------
step "[6/7] Installation de NixOS + Photo Stand sur $CMD_DISK (cela peut prendre quelques minutes)..."
nixos-install \
  --no-root-passwd \
  --root /mnt \
  --flake "/mnt/etc/stand-nixos#stand" \
  --option experimental-features "nix-command flakes"

# Rendre /etc/stand-nixos accessible au groupe wheel (utilisateur `stand`)
chmod -R g+rwX /mnt/etc/stand-nixos || true
success "NixOS et le Photo Stand ont été installés sur $CMD_DISK !"

# ------------------------------------------------------------------------------
# 8. Démontage et redémarrage sur le disque local
# ------------------------------------------------------------------------------
step "[7/7] Finalisation et redémarrage sur le disque local..."
sync
umount -R /mnt

echo ""
echo -e "${GREEN}${BOLD}======================================================================${NC}"
echo -e "${GREEN}${BOLD}  Installation terminée avec succès !${NC}"
echo -e "${GREEN}${BOLD}======================================================================${NC}"
echo "  Au redémarrage (depuis le disque local, plus besoin d'iPXE) :"
echo "  - NixOS démarre i3 + Firefox en plein écran sur le frontend"
echo "  - Les dépôts de services sont clonés et Docker Compose démarre automatiquement"
echo "  - Pour mettre à jour plus tard : stand-ctl prod update"
echo ""
echo "Redémarrage automatique dans 10 secondes (Ctrl+C pour annuler)..."
sleep 10
reboot
