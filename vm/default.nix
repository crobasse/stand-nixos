# Option de test en VM QEMU (`nix run .#vm`).
# Importe exactement le même socle `modules/base-system.nix` que le PC réel,
# avec uniquement les surcharges nécessaires au test isolé en VM.
{
  lib,
  modulesPath,
  standConfig,
  ...
}:

let
  ports = standConfig.vm.ports;
in
{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    ../modules/base-system.nix
  ];

  networking.hostName = "photostand-vm";
  networking.useDHCP = true;

  # Accès console & SSH pratique pour le debug dans la VM de test uniquement
  users.users.root.password = "stand";
  services.getty.autologinUser = "root";
  services.openssh.settings = {
    PermitRootLogin = "yes";
    PasswordAuthentication = true;
  };

  # Surcharges spécifiques à la VM de test (sans modifier la config prod de config.nix)
  services.photostand = {
    stand = {
      composeProfiles = lib.mkForce standConfig.vm.composeProfiles;
      primaryIp = lib.mkForce "127.0.0.1";
      puid = lib.mkForce 0;
      pgid = lib.mkForce 0;
    };
    mockPrinter = lib.mkForce standConfig.vm.mockPrinter;
    captureBindSource = "/mnt/capture";
    # En VM headless (graphics = false), on désactive X11/i3 ; en mode GUI (`test gui`), on l'active.
    kiosk.enable = lib.mkOverride 900 standConfig.vm.graphics;
    camera.enable = lib.mkOverride 900 false;
  };

  # Ressources et port-forwarding de la VM QEMU
  virtualisation = {
    memorySize = standConfig.vm.memorySize;
    cores = standConfig.vm.cores;
    diskSize = standConfig.vm.diskSize;
    graphics = standConfig.vm.graphics;

    # Partage du dossier capture entre l'hôte (./vm-capture) et la VM (/mnt/capture)
    sharedDirectories.capture = {
      source = standConfig.vm.hostCaptureDir;
      target = "/mnt/capture";
    };

    # Redirection des ports VM -> PC hôte (127.0.0.1)
    forwardPorts = [
      {
        from = "host";
        host.port = ports.frontend;
        guest.port = 80;
      }
      {
        from = "host";
        host.port = ports.jobSvc;
        guest.port = 8080;
      }
      {
        from = "host";
        host.port = ports.s3Api;
        guest.port = 9000;
      }
      {
        from = "host";
        host.port = ports.s3Console;
        guest.port = 9001;
      }
      {
        from = "host";
        host.port = ports.rabbitmqUi;
        guest.port = 15672;
      }
      {
        from = "host";
        host.port = ports.pgadmin;
        guest.port = 5050;
      }
      {
        from = "host";
        host.port = ports.ssh;
        guest.port = 22;
      }
    ];
  };

  # Message d'accueil dans la console de la VM
  users.motd = ''
    ======================================================================
      Photo Stand — VM NixOS de test
    ======================================================================
      Le projet démarre automatiquement en arrière-plan (sync Git + Docker Compose).
      Au premier démarrage, les images Docker et les services sont construits (~2-5 min).

      Commandes utiles dans la VM :
        stand-status                                 # État systemd + docker ps
        stand-logs [service]                         # Logs Docker Compose
        journalctl -u photostand-sync-repos -f       # Suivre le clonage Git
        journalctl -u photostand-compose -f          # Suivre le build/démarrage
        journalctl -u photostand-mock-printer -f     # Logs de l'imprimante simulée
        stand-restart                                # Resync Git + redémarrage stack

      Accès depuis ton PC hôte :
        Frontend      : http://127.0.0.1:${toString ports.frontend}
        Job API       : http://127.0.0.1:${toString ports.jobSvc}
        S3 Console    : http://127.0.0.1:${toString ports.s3Console}  (minioadmin / minioadmin)
        RabbitMQ UI   : http://127.0.0.1:${toString ports.rabbitmqUi} (guest / guest)
        pgAdmin       : http://127.0.0.1:${toString ports.pgadmin}    (admin@admin.com / admin)
        SSH           : ssh -p ${toString ports.ssh} root@127.0.0.1   (mot de passe : stand)

      Dossier photos (sur l'hôte) :
        ${standConfig.vm.hostCaptureDir}/${standConfig.stand.standId}/watch/
    ======================================================================
  '';
}
