# Socle NixOS commun partagé entre :
# - un vrai PC stand (`host/default.nix`)
# - la VM de test QEMU (`vm/default.nix`)
#
# Tout ce qui est configuré ici est testé à l'identique dans la VM.
{
  lib,
  standConfig,
  ...
}:

{
  imports = [
    ./photostand.nix
    ./kiosk-i3.nix
    ./camera-tether.nix
  ];

  system.stateVersion = lib.mkDefault "24.11";
  time.timeZone = lib.mkDefault "Europe/Paris";
  console.keyMap = lib.mkDefault standConfig.kiosk.keymap;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  services.openssh.enable = lib.mkDefault true;

  # Utilisateur opérateur du stand (partagé entre le PC physique et la VM GUI)
  users.users.stand = {
    isNormalUser = true;
    uid = lib.mkDefault standConfig.stand.puid;
    description = "Opérateur Photo Stand";
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
      "kvm"
      "plugdev"
    ];
    initialPassword = "stand";
  };

  # Activation de la stack Photo Stand depuis config.nix
  services.photostand = {
    enable = true;
    repos = standConfig.repos;
    autoUpdateRepos = standConfig.autoUpdateRepos;
    gitSshKeyFile = standConfig.gitSshKeyFile;
    stand = standConfig.stand;
    openFirewall = true;

    # Interface graphique i3 + Firefox en plein écran sur le frontend
    kiosk = {
      enable = lib.mkDefault standConfig.kiosk.enable;
      user = lib.mkDefault "stand";
      keymap = lib.mkDefault standConfig.kiosk.keymap;
    };

    # Tethering USB-C Canon EOS R6 Mk II + aperçu instantané hors-frontend
    camera = {
      enable = lib.mkDefault standConfig.camera.enable;
      captureTarget = lib.mkDefault (standConfig.camera.captureTarget or "0");
      keepOnSdCard = lib.mkDefault standConfig.camera.keepOnSdCard;
      imageFormat = lib.mkDefault standConfig.camera.imageFormat;
      preview = {
        enable = lib.mkDefault standConfig.camera.preview.enable;
        mode = lib.mkDefault standConfig.camera.preview.mode;
        historyLimit = lib.mkDefault standConfig.camera.preview.historyLimit;
      };
    };
  };
}
