# Configuration centrale et réplicable du projet Photo Stand
# Ce fichier définit la configuration réelle du stand (utilisée lors du déploiement
# sur une installation fraîche de NixOS), ainsi qu'une section `vm` dédiée
# uniquement aux surcharges de test en VM QEMU.
{
  # ---------------------------------------------------------------------------
  # Dépôts Git clonés automatiquement au démarrage dans /var/lib/photostand/
  # Note : les noms de dossiers cibles (stand-*) correspondent aux chemins
  # relatifs utilisés dans stand-infra/docker-compose.yml (../stand-*).
  # Pour une réplicabilité stricte, remplacez `ref = "main"` par un tag ou SHA.
  # ---------------------------------------------------------------------------
  repos = {
    stand-infra = {
      url = "https://github.com/crobasse/stand-infra.git";
      ref = "main";
    };
    stand-frontend = {
      url = "https://github.com/crobasse/stand-frontend.git";
      ref = "main";
    };
    stand-job-svc = {
      url = "https://github.com/crobasse/stand-job-svc.git";
      ref = "main";
    };
    stand-ingest-svc = {
      url = "https://github.com/crobasse/stand-ingest-svc.git";
      ref = "main";
    };
    stand-print-svc = {
      url = "https://github.com/crobasse/print-svc.git";
      ref = "main";
    };
  };

  # Si true, exécute `git fetch` + checkout sur `ref` à chaque boot (si réseau dispo).
  # Si false, ne clone que si le dossier n'existe pas encore.
  autoUpdateRepos = true;

  # Optionnel : chemin vers une clé SSH privée sur la machine cible si les dépôts
  # Git sont privés (avec des URLs git@github.com:...). Laisser `null` en HTTPS public.
  gitSshKeyFile = null;

  # ---------------------------------------------------------------------------
  # Paramètres du stand RÉEL (PC NixOS physique) injectés dans stand-infra/.env
  # ---------------------------------------------------------------------------
  stand = {
    # Identifiant unique du stand (dossier capture : volumes/capture/<standId>/watch)
    standId = "stand-1";

    # Profils Docker Compose actifs sur le PC physique :
    # - PC principal Linux avec imprimante USB : [ "primary" "print-vm" ]
    # - PC principal sans imprimante (ou imprimante Windows externe) : [ "primary" ]
    # - PC secondaire (ingest uniquement) : [ "secondary" ]
    composeProfiles = [
      "primary"
      "print-vm"
    ];

    # IP du PC principal sur le réseau local (utilisée par le navigateur pour
    # joindre job-svc :8080 et les URLs présignées S3 :9000).
    # En single-PC local uniquement : "localhost" ou "127.0.0.1".
    # En réseau local (plusieurs postes / tablettes) : mettre l'IP LAN (ex: "192.168.1.100").
    primaryIp = "localhost";

    # Endpoint S3 interne pour ingest-svc ("minio:9000" en primary, "<PRIMARY_IP>:9000" en secondary)
    storageEndpoint = "minio:9000";

    # UID/GID du conteneur ingest-svc sur le PC physique (correspond à l'utilisateur `stand`)
    puid = 1000;
    pgid = 100;

    # Options utilisées lorsque le profil "print-vm" est actif
    printVm = {
      windowsVersion = "10";
      ram = "4G";
      cpus = 2;
      disk = "40G";
      usbArgs = "-device usb-host,vendorid=0x04cb,productid=0x5007";
      printerName = "FUJIFILM DX100";
      paperWidthInches = "6.0";
      paperHeightInches = "4.0";
      brokerHost = "rabbitmq.stand.local";
      storageEndpoint = "minio.stand.local:9000";
    };
  };

  # ---------------------------------------------------------------------------
  # Interface graphique kiosque (i3 + Firefox en plein écran sur le frontend)
  # ---------------------------------------------------------------------------
  kiosk = {
    enable = true;
    keymap = "us";
  };

  # ---------------------------------------------------------------------------
  # Option de test uniquement : VM QEMU (`./stand-ctl test` ou `./stand-ctl test gui`)
  # Réutilise exactement le même socle + `repos` + `standId` que le PC réel,
  # en surchargeant uniquement les paramètres nécessaires à l'isolation VM.
  # ---------------------------------------------------------------------------
  vm = {
    memorySize = 4096; # Mo de RAM (4 Go recommandés pour les builds .NET + Node)
    cores = 4;
    diskSize = 20480; # Mo de disque qcow2 sparse (20 Go pour les images Docker)
    graphics = false; # false = console série dans le terminal (Ctrl+A puis X pour quitter)

    # Dans la VM de test, on n'active pas `print-vm` (Windows 40 Go + nested KVM)
    # et on utilise le worker mock ci-dessous à la place.
    composeProfiles = [ "primary" ];

    # Worker mock d'impression (remplace stand-print-svc Windows pour tester en VM)
    mockPrinter = {
      enable = true;
      delayPerPhotoSeconds = 2.0;
      errorRate = 0.0;
    };

    # Dossier sur ton PC hôte partagé avec la VM pour déposer des photos .jpg
    # (hors du dépôt pour ne jamais être copié dans le Nix store)
    hostCaptureDir = "/tmp/photostand-vm-capture";

    # Ports exposés sur ton PC hôte (127.0.0.1:<port>) -> VM
    # IMPORTANT : jobSvc (8080) et s3Api (9000) doivent conserver 8080 et 9000
    # car stand-infra/docker-compose.yml construit les URLs avec :8080 et :9000.
    ports = {
      frontend = 8088; # http://127.0.0.1:8088 -> VM:80 (port > 1024 sans root)
      jobSvc = 8080; # http://127.0.0.1:8080 -> VM:8080
      s3Api = 9000; # http://127.0.0.1:9000 -> VM:9000
      s3Console = 9001; # http://127.0.0.1:9001 -> VM:9001
      rabbitmqUi = 15672; # http://127.0.0.1:15672 -> VM:15672
      pgadmin = 5050; # http://127.0.0.1:5050 -> VM:5050
      ssh = 2222; # ssh -p 2222 root@127.0.0.1
    };
  };
}
