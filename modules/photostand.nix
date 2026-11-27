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

  staticEnvFile = pkgs.writeText "photostand.env" envFileContent;

  syncReposScript = pkgs.writeShellScript "photostand-sync-repos" ''
    set -euo pipefail

    export PATH="${
      lib.makeBinPath [
        pkgs.git
        pkgs.openssh
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.curl
        pkgs.jq
        pkgs.nix
      ]
    }:$PATH"

    ${lib.optionalString (cfg.gitSshKeyFile != null) ''
      export GIT_SSH_COMMAND="ssh -i ${lib.escapeShellArg cfg.gitSshKeyFile} -o StrictHostKeyChecking=accept-new"
    ''}

    mkdir -p ${lib.escapeShellArg cfg.dataDir}

    # Attendre brièvement que la résolution DNS soit prête (utile au boot QEMU / iPXE)
    for i in $(seq 1 20); do
      if curl -fsS --max-time 3 https://github.com >/dev/null 2>&1; then
        break
      fi
      echo "[sync-repos] Attente du réseau ($i/20)..."
      sleep 2
    done

    AUTO_UPDATE="${lib.boolToString cfg.autoUpdateRepos}"

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
      elif [ "$AUTO_UPDATE" = "true" ]; then
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

    USE_DYNAMIC_CONFIG=false

    ${lib.optionalString cfg.dynamicConfigFromCmdline ''
      # Lecture des paramètres noyau iPXE : stand.repo=..., stand.ref=..., stand.id=...,
      # stand.primary_ip=..., stand.profiles=..., stand.storage_endpoint=...
      CMDLINE_REPO=""
      CMDLINE_REF="main"
      CMDLINE_STAND_ID=""
      CMDLINE_PRIMARY_IP=""
      CMDLINE_PROFILES=""
      CMDLINE_STORAGE_ENDPOINT=""

      read -ra CMDLINE_TOKENS < /proc/cmdline
      for token in "''${CMDLINE_TOKENS[@]}"; do
        case "$token" in
          stand.repo=*)             CMDLINE_REPO="''${token#stand.repo=}" ;;
          stand.ref=*)              CMDLINE_REF="''${token#stand.ref=}" ;;
          stand.id=*)               CMDLINE_STAND_ID="''${token#stand.id=}" ;;
          stand.primary_ip=*)       CMDLINE_PRIMARY_IP="''${token#stand.primary_ip=}" ;;
          stand.profiles=*)         CMDLINE_PROFILES="''${token#stand.profiles=}" ;;
          stand.storage_endpoint=*) CMDLINE_STORAGE_ENDPOINT="''${token#stand.storage_endpoint=}" ;;
        esac
      done

      if [ -n "$CMDLINE_REPO" ]; then
        echo "[sync-repos] Mode iPXE dynamique : récupération de stand-nixos depuis $CMDLINE_REPO ($CMDLINE_REF)..."
        sync_one "stand-nixos" "$CMDLINE_REPO" "$CMDLINE_REF"

        STAND_CFG_FILE="${cfg.dataDir}/stand-nixos/config.nix"
        if [ -f "$STAND_CFG_FILE" ]; then
          CFG_JSON="$(nix --extra-experimental-features nix-command eval --json --impure --expr "import $STAND_CFG_FILE")"
          AUTO_UPDATE="$(echo "$CFG_JSON" | jq -r '.autoUpdateRepos // true')"

          while IFS=$'\t' read -r rname rurl rref; do
            sync_one "$rname" "$rurl" "$rref"
          done < <(echo "$CFG_JSON" | jq -r '.repos | to_entries[] | [.key, .value.url, (.value.ref // "main")] | @tsv')

          DYN_PROFILES="$(echo "$CFG_JSON" | jq -r '(.stand.composeProfiles // ["primary"]) | join(",")')"
          DYN_STAND_ID="$(echo "$CFG_JSON" | jq -r '.stand.standId // "stand-1"')"
          DYN_PRIMARY_IP="$(echo "$CFG_JSON" | jq -r '.stand.primaryIp // "localhost"')"
          DYN_STORAGE_ENDPOINT="$(echo "$CFG_JSON" | jq -r '.stand.storageEndpoint // "minio:9000"')"
          DYN_PUID="$(echo "$CFG_JSON" | jq -r '.stand.puid // 1000')"
          DYN_PGID="$(echo "$CFG_JSON" | jq -r '.stand.pgid // 100')"
          DYN_WIN_VER="$(echo "$CFG_JSON" | jq -r '.stand.printVm.windowsVersion // "10"')"
          DYN_WIN_RAM="$(echo "$CFG_JSON" | jq -r '.stand.printVm.ram // "4G"')"
          DYN_WIN_CPUS="$(echo "$CFG_JSON" | jq -r '.stand.printVm.cpus // 2')"
          DYN_WIN_DISK="$(echo "$CFG_JSON" | jq -r '.stand.printVm.disk // "40G"')"
          DYN_USB_ARGS="$(echo "$CFG_JSON" | jq -r '.stand.printVm.usbArgs // "-device usb-host,vendorid=0x04cb,productid=0x5007"')"
          DYN_PRINTER_NAME="$(echo "$CFG_JSON" | jq -r '.stand.printVm.printerName // ""')"
          DYN_PAPER_W="$(echo "$CFG_JSON" | jq -r '.stand.printVm.paperWidthInches // "6.0"')"
          DYN_PAPER_H="$(echo "$CFG_JSON" | jq -r '.stand.printVm.paperHeightInches // "4.0"')"
          DYN_BROKER_HOST="$(echo "$CFG_JSON" | jq -r '.stand.printVm.brokerHost // "rabbitmq.stand.local"')"
          DYN_PRINT_STORAGE="$(echo "$CFG_JSON" | jq -r '.stand.printVm.storageEndpoint // "minio.stand.local:9000"')"

          # Surcharges optionnelles passées au boot iPXE
          [ -n "$CMDLINE_PROFILES" ]         && DYN_PROFILES="$CMDLINE_PROFILES"
          [ -n "$CMDLINE_STAND_ID" ]         && DYN_STAND_ID="$CMDLINE_STAND_ID"
          [ -n "$CMDLINE_PRIMARY_IP" ]       && DYN_PRIMARY_IP="$CMDLINE_PRIMARY_IP"
          [ -n "$CMDLINE_STORAGE_ENDPOINT" ] && DYN_STORAGE_ENDPOINT="$CMDLINE_STORAGE_ENDPOINT"

          printf '%s\n' \
            "COMPOSE_PROFILES=$DYN_PROFILES" \
            "STAND_ID=$DYN_STAND_ID" \
            "PRIMARY_IP=$DYN_PRIMARY_IP" \
            "STORAGE_ENDPOINT=$DYN_STORAGE_ENDPOINT" \
            "PUID=$DYN_PUID" \
            "PGID=$DYN_PGID" \
            "PRINT_VM_WINDOWS_VERSION=$DYN_WIN_VER" \
            "PRINT_VM_RAM=$DYN_WIN_RAM" \
            "PRINT_VM_CPUS=$DYN_WIN_CPUS" \
            "PRINT_VM_DISK=$DYN_WIN_DISK" \
            "PRINTER_USB_ARGS=$DYN_USB_ARGS" \
            "PRINTER_NAME=$DYN_PRINTER_NAME" \
            "PAPER_WIDTH_INCHES=$DYN_PAPER_W" \
            "PAPER_HEIGHT_INCHES=$DYN_PAPER_H" \
            "PRINT_BROKER_HOST=$DYN_BROKER_HOST" \
            "PRINT_STORAGE_ENDPOINT=$DYN_PRINT_STORAGE" \
            > ${lib.escapeShellArg "${infraDir}/.env"}
          USE_DYNAMIC_CONFIG=true
        else
          echo "[sync-repos] Attention : $STAND_CFG_FILE introuvable dans $CMDLINE_REPO, repli sur la config embarquée."
        fi
      fi
    ''}

    if [ "$USE_DYNAMIC_CONFIG" = "false" ]; then
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: repo:
          "sync_one ${lib.escapeShellArg name} ${lib.escapeShellArg repo.url} ${lib.escapeShellArg repo.ref}"
        ) cfg.repos
      )}

      # Copier le fichier .env déclaratif pour stand-infra/docker-compose.yml
      cp -f ${staticEnvFile} ${lib.escapeShellArg "${infraDir}/.env"}
      chmod 0644 ${lib.escapeShellArg "${infraDir}/.env"}

      ${lib.optionalString cfg.dynamicConfigFromCmdline ''
        # Appliquer d'éventuelles surcharges noyau iPXE même sans stand.repo
        [ -n "$CMDLINE_PROFILES" ]         && sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=$CMDLINE_PROFILES|" ${lib.escapeShellArg "${infraDir}/.env"}
        [ -n "$CMDLINE_STAND_ID" ]         && sed -i "s|^STAND_ID=.*|STAND_ID=$CMDLINE_STAND_ID|" ${lib.escapeShellArg "${infraDir}/.env"}
        [ -n "$CMDLINE_PRIMARY_IP" ]       && sed -i "s|^PRIMARY_IP=.*|PRIMARY_IP=$CMDLINE_PRIMARY_IP|" ${lib.escapeShellArg "${infraDir}/.env"}
        [ -n "$CMDLINE_STORAGE_ENDPOINT" ] && sed -i "s|^STORAGE_ENDPOINT=.*|STORAGE_ENDPOINT=$CMDLINE_STORAGE_ENDPOINT|" ${lib.escapeShellArg "${infraDir}/.env"}
      ''}
    fi

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

    dynamicConfigFromCmdline = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Active la lecture de stand.repo / stand.ref / stand.id / stand.primary_ip / stand.profiles depuis /proc/cmdline (mode netboot iPXE).";
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

    environment.pathsToLink = [ "/libexec/docker/cli-plugins" ];

    environment.systemPackages = with pkgs; [
      docker-compose
      docker-buildx
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
        pkgs.docker-buildx
        pkgs.util-linux
        pkgs.coreutils
        pkgs.gnugrep
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

        EFFECTIVE_STAND_ID=${lib.escapeShellArg cfg.stand.standId}
        if [ -f ${lib.escapeShellArg "${infraDir}/.env"} ]; then
          ENV_STAND_ID="$(grep -E '^STAND_ID=' ${lib.escapeShellArg "${infraDir}/.env"} | head -n1 | cut -d= -f2- || true)"
          [ -n "$ENV_STAND_ID" ] && EFFECTIVE_STAND_ID="$ENV_STAND_ID"
        fi

        mkdir -p "${infraDir}/volumes/capture/$EFFECTIVE_STAND_ID/watch"
        mkdir -p "${infraDir}/volumes/capture/$EFFECTIVE_STAND_ID/processed"
        mkdir -p "${infraDir}/volumes/capture/$EFFECTIVE_STAND_ID/failed"
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
