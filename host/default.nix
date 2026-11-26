# Configuration pour déployer un vrai PC stand sur une installation fraîche de NixOS.
#
# Étapes sur un NixOS fraîchement installé :
#   1. Cloner ce dépôt : git clone <url-stand-nixos> && cd stand-nixos
#   2. Copier le hardware de la machine : cp /etc/nixos/hardware-configuration.nix ./host/hardware-configuration.nix
#   3. Ajuster `config.nix` (standId, primaryIp, composeProfiles, URLs Git)
#   4. Appliquer : sudo nixos-rebuild switch --flake .#stand
{
  lib,
  pkgs,
  standConfig,
  ...
}:

let
  hardwareConfigPath = ./hardware-configuration.nix;
  hasHardwareConfig = builtins.pathExists hardwareConfigPath;
in
{
  imports = [
    ../modules/base-system.nix
  ]
  ++ lib.optional hasHardwareConfig hardwareConfigPath;

  assertions = [
    {
      assertion = hasHardwareConfig;
      message = ''
        Le fichier `host/hardware-configuration.nix` est absent.
        Sur une installation fraîche de NixOS, copiez d'abord votre configuration matérielle :
          cp /etc/nixos/hardware-configuration.nix ./host/hardware-configuration.nix
          git add -f ./host/hardware-configuration.nix   # si stand-nixos est un dépôt git
        Puis relancez :
          sudo nixos-rebuild switch --flake .#stand
      '';
    }
  ];

  # Bootloader UEFI par défaut (adaptez si la machine boot en BIOS Legacy / GRUB)
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # KVM requis pour le profil `print-vm` (VM Windows + passthrough USB Fujifilm DX100)
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];

  networking.hostName = lib.mkDefault standConfig.stand.standId;
  networking.networkmanager.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    usbutils # lsusb pour vérifier l'ID USB de l'imprimante (ex: 04cb:5007)
    vim
    htop
  ];
}
