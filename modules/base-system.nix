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
  ];

  system.stateVersion = lib.mkDefault "24.11";
  time.timeZone = lib.mkDefault "Europe/Paris";
  console.keyMap = lib.mkDefault "fr";

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
  };
}
