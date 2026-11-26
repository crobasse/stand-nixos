# Configuration pour déployer un vrai PC stand sur une installation fraîche de NixOS
# (utilisée à la fois par `./stand-ctl install` ET par l'auto-installateur Netboot iPXE).
{
  lib,
  pkgs,
  standConfig,
  ...
}:

let
  hardwareConfigPath = ./hardware-configuration.nix;
  hasHardwareConfig = builtins.pathExists hardwareConfigPath;

  installCfg = standConfig.install or { };
  bootloader = installCfg.bootloader or "uefi";
  grubDevice = installCfg.grubDevice or "nodev";

  standCtlWrapper = pkgs.writeShellScriptBin "stand-ctl" ''
    export STAND_NIXOS_DIR="''${STAND_NIXOS_DIR:-/etc/stand-nixos}"
    if [ -x "$STAND_NIXOS_DIR/stand-ctl" ]; then
      exec "$STAND_NIXOS_DIR/stand-ctl" "$@"
    else
      exec ${pkgs.bash}/bin/bash ${../stand-ctl} "$@"
    fi
  '';
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
        Sur une installation fraîche de NixOS, lancez `./stand-ctl install` ou copiez :
          cp /etc/nixos/hardware-configuration.nix ./host/hardware-configuration.nix
          git add -f ./host/hardware-configuration.nix
        Puis relancez :
          sudo nixos-rebuild switch --flake .#stand
      '';
    }
  ];

  # Bootloader : UEFI (systemd-boot) par défaut, ou BIOS Legacy (GRUB) si détecté par l'installateur iPXE
  boot.loader =
    if bootloader == "bios" then
      {
        grub = {
          enable = true;
          device = grubDevice;
        };
      }
    else
      {
        systemd-boot.enable = lib.mkDefault true;
        efi.canTouchEfiVariables = lib.mkDefault true;
      };

  # KVM requis pour le profil `print-vm` (VM Windows + passthrough USB Fujifilm DX100)
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];

  networking.hostName = lib.mkDefault standConfig.stand.standId;
  networking.networkmanager.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    standCtlWrapper
    usbutils # lsusb pour vérifier l'ID USB de l'imprimante (ex: 04cb:5007)
    vim
    htop
  ];
}
