{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.photostand;

  repoSubmodule = lib.types.submodule {
    options = {
      url = lib.mkOption {
        type = lib.types.str;
        description = "URL Git du dépôt (HTTPS ou SSH).";
      };
      ref = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Branche, tag ou hash de commit à déployer.";
      };
    };
  };

  infraDir = "${cfg.dataDir}/stand-infra";

  envFileContent = ''
    COMPOSE_PROFILES=${lib.concatStringsSep "," cfg.stand.composeProfiles}
    STAND_ID=${cfg.stand.standId}
    PRIMARY_IP=${cfg.stand.primaryIp}
    STORAGE_ENDPOINT=${cfg.stand.storageEndpoint}
    PUID=${toString cfg.stand.puid}
    PGID=${toString cfg.stand.pgid}
    PRINT_VM_WINDOWS_VERSION=${cfg.stand.printVm.windowsVersion}
    PRINT_VM_RAM=${cfg.stand.printVm.ram}
    PRINT_VM_CPUS=${toString cfg.stand.printVm.cpus}
    PRINT_VM_DISK=${cfg.stand.printVm.disk}
    PRINTER_USB_ARGS=${cfg.stand.printVm.usbArgs}
    PRINTER_NAME=${cfg.stand.printVm.printerName}
    PAPER_WIDTH_INCHES=${cfg.stand.printVm.paperWidthInches}
    PAPER_HEIGHT_INCHES=${cfg.stand.printVm.paperHeightInches}
    PRINT_BROKER_HOST=${cfg.stand.printVm.brokerHost}
    PRINT_STORAGE_ENDPOINT=${cfg.stand.printVm.storageEndpoint}
  '';

  syncReposScript = pkgs.writeShellScript "photostand-sync-repos" ''
    set -euo pipefail

    export PATH="${
      lib.makeBinPath [
        pkgs.git
        pkgs.openssh
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.curl
      ]
    }:$PATH"

    ${lib.optionalString (cfg.gitSshKeyFile != null) ''
      export GIT_SSH_COMMAND="ssh -i ${lib.escapeShellArg cfg.gitSshKeyFile} -o StrictHostKeyChecking=accept-new"
    ''}

    mkdir -p ${lib.escapeShellArg cfg.dataDir}

    # Attendre brièvement que la résolution DNS soit prête (utile au boot QEMU)
    for i in $(seq 1 15); do
      if curl -fsS --max-time 3 https://github.com >/dev/null 2>&1; then
        break
      fi
      echo "[sync-repos] Attente du réseau ($i/15)..."
      sleep 2
    done

    sync_one() {
      local name="$1"
      local url="$2"
      local ref="$3"
      local dest="${cfg.dataDir}/$name"

      if [ ! -d "$dest/.git" ]; then
        echo "[sync-repos] Clonage de $name ($url @ $ref)..."
        rm -rf "$dest"
        git clone "$url" "$dest"
        git -C "$dest" checkout "$ref"
      elif [ "${lib.boolToString cfg.autoUpdateRepos}" = "true" ]; then
        echo "[sync-repos] Mise à jour de $name ($url @ $ref)..."
        git -C "$dest" remote set-url origin "$url"
        if git -C "$dest" fetch --all --tags --prune; then
          if git -C "$dest" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
            git -C "$dest" checkout -B "$ref" "origin/$ref"
          else
            git -C "$dest" checkout "$ref"
          fi
        else
          echo "[sync-repos] Attention : fetch échoué pour $name, conservation de la version locale."
        fi
      else
        echo "[sync-repos] $name déjà présent (autoUpdateRepos=false)."
      fi
    }

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: repo:
        "sync_one ${lib.escapeShellArg name} ${lib.escapeShellArg repo.url} ${lib.escapeShellArg repo.ref}"
      ) cfg.repos
    )}

    # Générer le fichier .env déclaratif pour stand-infra/docker-compose.yml
    cat > ${lib.escapeShellArg "${infraDir}/.env"} <<'EOF'
    ${envFileContent}
    EOF

    echo "[sync-repos] Tous les dépôts et .env sont prêts."
  '';

  mockPrinterPython = pkgs.python3.withPackages (ps: [ ps.pika ]);

  standStatusBin = pkgs.writeShellScriptBin "stand-status" ''
    echo "=== Services systemd Photo Stand ==="
    systemctl --no-pager -l status photostand-sync-repos photostand-compose ${
      lib.optionalString cfg.mockPrinter.enable "photostand-mock-printer"
    } || true
    echo ""
    echo "=== Conteneurs Docker ==="
    ${pkgs.docker-compose}/bin/docker-compose -f ${lib.escapeShellArg "${infraDir}/docker-compose.yml"} ps || true
  '';

  standLogsBin = pkgs.writeShellScriptBin "stand-logs" ''
    if [ $# -eq 0 ]; then
      ${pkgs.docker-compose}/bin/docker-compose -f ${lib.escapeShellArg "${infraDir}/docker-compose.yml"} logs -f --tail=100
    else
      ${pkgs.docker-compose}/bin/docker-compose -f ${lib.escapeShellArg "${infraDir}/docker-compose.yml"} logs -f --tail=100 "$@"
    fi
  '';

  standSyncBin = pkgs.writeShellScriptBin "stand-sync" ''
    systemctl start photostand-sync-repos.service
  '';

  standRestartBin = pkgs.writeShellScriptBin "stand-restart" ''
    systemctl restart photostand-sync-repos.service
    systemctl restart photostand-compose.service
    ${lib.optionalString cfg.mockPrinter.enable "systemctl restart photostand-mock-printer.service"}
  '';
in
{
  options.services.photostand = {
    enable = lib.mkEnableOption "Stack Photo Stand (repos Git + Docker Compose + mock printer optionnel)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/photostand";
      description = "Répertoire racine contenant les dépôts clonés (stand-infra, stand-frontend, etc.).";
    };

    repos = lib.mkOption {
      type = lib.types.attrsOf repoSubmodule;
      description = "Dépôts Git à cloner dans dataDir/<nom>.";
    };

    autoUpdateRepos = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Mettre à jour les dépôts vers leur `ref` configurée à chaque démarrage.";
    };

    gitSshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin vers une clé SSH privée si les dépôts Git sont privés.";
    };

    captureBindSource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Répertoire optionnel (ex: partage 9p /mnt/capture en VM) à bind-mounter sur stand-infra/volumes/capture.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Ouvrir les ports nécessaires dans le pare-feu NixOS.";
    };

    stand = {
      standId = lib.mkOption {
        type = lib.types.str;
        default = "stand-1";
      };
      composeProfiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "primary" ];
      };
      primaryIp = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
      };
      storageEndpoint = lib.mkOption {
        type = lib.types.str;
        default = "minio:9000";
      };
      puid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
      };
      pgid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
      };
      printVm = {
        windowsVersion = lib.mkOption {
          type = lib.types.str;
          default = "10";
        };
        ram = lib.mkOption {
          type = lib.types.str;
          default = "4G";
        };
        cpus = lib.mkOption {
          type = lib.types.int;
          default = 2;
        };
        disk = lib.mkOption {
          type = lib.types.str;
          default = "40G";
        };
        usbArgs = lib.mkOption {
          type = lib.types.str;
          default = "-device usb-host,vendorid=0x04cb,productid=0x5007";
        };
        printerName = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        paperWidthInches = lib.mkOption {
          type = lib.types.str;
          default = "6.0";
        };
        paperHeightInches = lib.mkOption {
          type = lib.types.str;
          default = "4.0";
        };
        brokerHost = lib.mkOption {
          type = lib.types.str;
          default = "rabbitmq.stand.local";
        };
        storageEndpoint = lib.mkOption {
          type = lib.types.str;
          default = "minio.stand.local:9000";
        };
      };
    };

    mockPrinter = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Activer le worker Python simulant stand-print-svc sur RabbitMQ.";
      };
      delayPerPhotoSeconds = lib.mkOption {
        type = lib.types.float;
        default = 2.0;
        description = "Délai simulé en secondes par photo (multiplié par le nombre de copies).";
      };
      errorRate = lib.mkOption {
        type = lib.types.float;
        default = 0.0;
        description = "Probabilité d'erreur simulée par photo (0.0 à 1.0).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
      autoPrune.enable = false;
    };

    environment.systemPackages = with pkgs; [
      docker-compose
      git
      curl
      jq
      standStatusBin
      standLogsBin
      standSyncBin
      standRestartBin
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      80 # Frontend (Nginx)
      5050 # pgAdmin
      5432 # PostgreSQL
      5672 # RabbitMQ AMQP
      8006 # print-vm noVNC (si profil print-vm)
      8080 # job-svc API
      9000 # RustFS / S3 API
      9001 # RustFS / S3 Console
      15672 # RabbitMQ Management UI
    ];

    # 1. Cloner / synchroniser les dépôts Git et générer stand-infra/.env
    systemd.services.photostand-sync-repos = {
      description = "Synchronise les dépôts Git Photo Stand et génère stand-infra/.env";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "10min";
        ExecStart = syncReposScript;
      };
    };

    # 2. Démarrer automatiquement la stack stand-infra via Docker Compose au boot
    systemd.services.photostand-compose = {
      description = "Stack Docker Compose Photo Stand (stand-infra)";
      after = [
        "docker.service"
        "network-online.target"
        "photostand-sync-repos.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "docker.service"
        "photostand-sync-repos.service"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        DOCKER_BUILDKIT = "1";
        COMPOSE_DOCKER_CLI_BUILD = "1";
      };

      path = [
        pkgs.docker
        pkgs.docker-compose
        pkgs.util-linux
        pkgs.coreutils
      ];

      preStart = ''
        mkdir -p ${lib.escapeShellArg "${infraDir}/volumes/db"}
        mkdir -p ${lib.escapeShellArg "${infraDir}/volumes/capture"}

        ${lib.optionalString (cfg.captureBindSource != null) ''
          if mountpoint -q ${lib.escapeShellArg cfg.captureBindSource}; then
            if ! mountpoint -q ${lib.escapeShellArg "${infraDir}/volumes/capture"}; then
              mount --bind ${lib.escapeShellArg cfg.captureBindSource} ${lib.escapeShellArg "${infraDir}/volumes/capture"}
            fi
          fi
        ''}

        mkdir -p ${lib.escapeShellArg "${infraDir}/volumes/capture/${cfg.stand.standId}/watch"}
        mkdir -p ${lib.escapeShellArg "${infraDir}/volumes/capture/${cfg.stand.standId}/processed"}
        mkdir -p ${lib.escapeShellArg "${infraDir}/volumes/capture/${cfg.stand.standId}/failed"}
      '';

      script = ''
        cd ${lib.escapeShellArg infraDir}
        docker-compose --env-file .env up -d --build --remove-orphans
      '';

      preStop = ''
        cd ${lib.escapeShellArg infraDir}
        docker-compose --env-file .env down
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "25min";
        TimeoutStopSec = "3min";
      };
    };

    # 3. Worker mock optionnel remplaçant stand-print-svc (Windows) pour tester la chaîne complète
    systemd.services.photostand-mock-printer = lib.mkIf cfg.mockPrinter.enable {
      description = "Mock PrintSvc (simule l'impression sur RabbitMQ print.jobs -> print.status)";
      after = [ "photostand-compose.service" ];
      wants = [ "photostand-compose.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PYTHONUNBUFFERED = "1";
        BROKER_HOST = "127.0.0.1";
        BROKER_PORT = "5672";
        BROKER_USER = "guest";
        BROKER_PASS = "guest";
        JOBS_QUEUE = "print.jobs";
        RESULTS_QUEUE = "print.status";
        MOCK_PRINT_DELAY_SECONDS = toString cfg.mockPrinter.delayPerPhotoSeconds;
        MOCK_PRINT_ERROR_RATE = toString cfg.mockPrinter.errorRate;
      };

      serviceConfig = {
        ExecStart = "${mockPrinterPython}/bin/python3 ${../scripts/mock-printer.py}";
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
