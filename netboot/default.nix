# Image NixOS Netboot iPXE — Auto-installateur One-Shot.
#
# Légère (sans Xorg/Firefox/Docker en RAM) : on netboot UNE SEULE FOIS sur un PC
# vierge en indiquant l'URL du repo `stand-nixos`. L'image partitionne le disque,
# installe NixOS complet + le stand (Docker, i3, Firefox, services systemd), puis
# redémarre directement sur le disque local prêt à l'emploi.
{
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  installerScript = pkgs.writeShellApplication {
    name = "photostand-netboot-installer";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      util-linux
      parted
      e2fsprogs
      dosfstools
      git
      openssh
      curl
      gawk
      gnugrep
      iproute2
      networkmanager
      nix
      nixos-install-tools
    ];
    text = builtins.readFile ./installer.sh;
  };
in
{
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
  ];

  system.stateVersion = "24.11";
  networking.hostName = "photostand-installer";
  time.timeZone = "Europe/Paris";
  console.keyMap = "fr";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Image iPXE légère et rapide (zstd, sans ZFS ni docs)
  boot.initrd.compressor = "zstd";
  boot.supportedFilesystems.zfs = lib.mkForce false;
  documentation.enable = false;
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  documentation.info.enable = false;

  # Accès SSH de dépannage si besoin pendant l'installation
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  users.users.root = {
    initialHashedPassword = lib.mkForce null;
    password = "stand";
  };

  environment.systemPackages = [
    installerScript
    pkgs.git
    pkgs.parted
    pkgs.curl
    pkgs.htop
    pkgs.vim
  ];

  # Lance automatiquement l'installateur sur tty1 au démarrage iPXE
  # (Alt+F2 et SSH restent disponibles pour le debug)
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  systemd.services.photostand-netboot-installer = {
    description = "Auto-installateur NixOS + Photo Stand (Netboot iPXE)";
    after = [
      "network-online.target"
      "systemd-udev-settle.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "idle";
      ExecStart = "${installerScript}/bin/photostand-netboot-installer";
      StandardInput = "tty-force";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      Restart = "no";
    };
  };
}
