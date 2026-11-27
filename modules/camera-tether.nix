# Module NixOS : tethering USB-C Canon EOS (R6 Mark II) via gphoto2
# + aperçu instantané hors-frontend (style Canon EOS Utility) via imv.
#
# Flux :
#   Canon R6 Mk II (USB-C PTP)
#     ├─ Garde une copie sur la carte SD (capturetarget=1 + --keep)
#     ├─ Configure automatiquement le mode JPEG si demandé (imageformat)
#     └─ Télécharge chaque JPEG ->
#          1. Copie atomique vers /var/lib/photostand/preview/ (aperçu live imv)
#          2. Déplacement atomique vers stand-infra/volumes/capture/<STAND_ID>/watch/
{
  config,
  lib,
  pkgs,
  ...
}:

let
  psCfg = config.services.photostand;
  cfg = psCfg.camera;

  infraDir = "${psCfg.dataDir}/stand-infra";
  stagingDir = "${psCfg.dataDir}/camera-staging";
  previewDir = "${psCfg.dataDir}/preview";
  historyDir = "${previewDir}/history";

  # Hook appelé par `gphoto2 --capture-tethered` à chaque photo téléchargée
  cameraHookScript = pkgs.writeShellApplication {
    name = "photostand-camera-hook";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      findutils
    ];
    text = ''
      set -euo pipefail

      ACTION="''${ACTION:-}"
      ARGUMENT="''${ARGUMENT:-}"

      if [ "$ACTION" != "download" ] || [ -z "$ARGUMENT" ] || [ ! -f "$ARGUMENT" ]; then
        exit 0
      fi

      BASENAME="$(basename "$ARGUMENT")"
      EXT_LOWER="$(printf '%s' "''${BASENAME##*.}" | tr '[:upper:]' '[:lower:]')"

      # Ne garder que les JPEG (ignorer .cr3, .mov, etc. — déjà sauvegardés sur SD via --keep)
      if [ "$EXT_LOWER" != "jpg" ] && [ "$EXT_LOWER" != "jpeg" ]; then
        echo "[camera-hook] Fichier non-JPEG ignoré : $BASENAME"
        rm -f "$ARGUMENT"
        exit 0
      fi

      # Lire STAND_ID, PUID et PGID effectifs depuis stand-infra/.env
      STAND_ID=${lib.escapeShellArg psCfg.stand.standId}
      PUID=${toString psCfg.stand.puid}
      PGID=${toString psCfg.stand.pgid}
      ENV_FILE=${lib.escapeShellArg "${infraDir}/.env"}
      if [ -f "$ENV_FILE" ]; then
        v="$(grep -E '^STAND_ID=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
        [ -n "$v" ] && STAND_ID="$v"
        v="$(grep -E '^PUID=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
        [ -n "$v" ] && PUID="$v"
        v="$(grep -E '^PGID=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
        [ -n "$v" ] && PGID="$v"
      fi

      WATCH_DIR="${infraDir}/volumes/capture/$STAND_ID/watch"
      PREVIEW_DIR=${lib.escapeShellArg previewDir}
      HISTORY_DIR=${lib.escapeShellArg historyDir}
      HISTORY_LIMIT=${toString cfg.preview.historyLimit}

      mkdir -p "$WATCH_DIR" "$HISTORY_DIR"
      chmod 0755 "$PREVIEW_DIR" "$HISTORY_DIR"

      # 1. Copier d'abord pour l'aperçu instantané (avant qu'ingest-svc ne déplace le fichier)
      ${lib.optionalString cfg.preview.enable ''
        TMP_HIST="$HISTORY_DIR/.tmp-$BASENAME"
        HIST_FILE="$HISTORY_DIR/$BASENAME"
        cp -f "$ARGUMENT" "$TMP_HIST"
        chmod 0644 "$TMP_HIST"
        mv -f "$TMP_HIST" "$HIST_FILE"
        ln -sfn "$HIST_FILE" "$PREVIEW_DIR/latest.jpg"

        # Déclenchement atomique du watcher i3 (imv-msg)
        TMP_EVT="$PREVIEW_DIR/.tmp-latest-path"
        printf '%s\n' "$HIST_FILE" > "$TMP_EVT"
        chmod 0644 "$TMP_EVT"
        mv -f "$TMP_EVT" "$PREVIEW_DIR/.latest-path"

        # Limiter l'historique d'aperçu aux N dernières photos
        if [ "$HISTORY_LIMIT" -gt 0 ]; then
          # Supprime les plus anciens fichiers JPEG au-delà de HISTORY_LIMIT
          mapfile -t ALL_HIST < <(ls -1t "$HISTORY_DIR"/*.jpg "$HISTORY_DIR"/*.jpeg "$HISTORY_DIR"/*.JPG "$HISTORY_DIR"/*.JPEG 2>/dev/null || true)
          if [ "''${#ALL_HIST[@]}" -gt "$HISTORY_LIMIT" ]; then
            for old in "''${ALL_HIST[@]:$HISTORY_LIMIT}"; do
              rm -f "$old"
            done
          fi
        fi
      ''}

      # 2. Déplacer atomiquement dans watch/ avec les bons droits pour ingest-svc
      chown "$PUID:$PGID" "$ARGUMENT" 2>/dev/null || true
      chmod 0664 "$ARGUMENT"
      mv -f "$ARGUMENT" "$WATCH_DIR/$BASENAME"
      echo "[camera-hook] JPEG prêt -> $WATCH_DIR/$BASENAME"
    '';
  };

  # Boucle principale de tethering USB-C (gère débranchement / veille / changement batterie)
  tetherDaemonScript = pkgs.writeShellApplication {
    name = "photostand-camera-tether";
    runtimeInputs = with pkgs; [
      gphoto2
      coreutils
      gnugrep
      gnused
    ];
    text = ''
      set -euo pipefail

      STAGING_DIR=${lib.escapeShellArg stagingDir}
      PREVIEW_DIR=${lib.escapeShellArg previewDir}
      HISTORY_DIR=${lib.escapeShellArg historyDir}
      KEEP_ON_SD="${lib.boolToString cfg.keepOnSdCard}"
      WANTED_FORMAT=${lib.escapeShellArg (if cfg.imageFormat != null then cfg.imageFormat else "")}

      mkdir -p "$STAGING_DIR" "$PREVIEW_DIR" "$HISTORY_DIR"
      chmod 0755 "$PREVIEW_DIR" "$HISTORY_DIR"

      echo "[camera-tether] Service démarré. En attente d'un boîtier Canon en USB-C..."
      WAS_WAITING=0

      while true; do
        DETECTED="$(gphoto2 --auto-detect 2>/dev/null | grep -E 'usb:[0-9]+,[0-9]+' || true)"
        if [ -z "$DETECTED" ]; then
          if [ "$WAS_WAITING" -eq 0 ]; then
            echo "[camera-tether] Aucun appareil photo détecté en USB. Attente..."
            WAS_WAITING=1
          fi
          sleep 2
          continue
        fi

        WAS_WAITING=0
        echo "[camera-tether] Appareil détecté : $DETECTED"

        # 1. Configurer l'enregistrement sur la carte SD (pour garder un backup sur le boîtier)
        if [ "$KEEP_ON_SD" = "true" ]; then
          if gphoto2 --set-config capturetarget=1 >/dev/null 2>&1; then
            echo "[camera-tether] capturetarget=1 (Carte SD) activé."
          else
            echo "[camera-tether] Info : impossible de définir capturetarget=1 (vérifiez le boîtier)."
          fi
        fi

        # 2. Configurer automatiquement le format image (ex: "Large Fine JPEG") si demandé
        if [ -n "$WANTED_FORMAT" ]; then
          if gphoto2 --set-config-value "/main/imgsettings/imageformat=$WANTED_FORMAT" >/dev/null 2>&1; then
            echo "[camera-tether] Format image configuré automatiquement sur : $WANTED_FORMAT"
          else
            echo "[camera-tether] Attention : impossible de définir imageformat='$WANTED_FORMAT' (lancez 'gphoto2 --get-config /main/imgsettings/imageformat' pour voir les valeurs supportées)."
          fi
        fi

        # 3. Lancer la capture tethered (télécharge dans staging, puis hook déplace vers preview + watch)
        GPHOTO_ARGS=(
          --capture-tethered
          --filename "$STAGING_DIR/%Y%m%d-%H%M%S-%f.%C"
          --hook-script "${cameraHookScript}/bin/photostand-camera-hook"
        )
        if [ "$KEEP_ON_SD" = "true" ]; then
          GPHOTO_ARGS+=(--keep)
        fi

        echo "[camera-tether] Écoute des déclenchements en cours..."
        # `|| true` car gphoto2 quitte en erreur si le boîtier est éteint/débranché : on boucle proprement
        gphoto2 "''${GPHOTO_ARGS[@]}" || true

        echo "[camera-tether] Connexion appareil interrompue. Nouvelle détection dans 2s..."
        sleep 2
      done
    '';
  };

  # Watcher côté session graphique i3 : met à jour la fenêtre imv-x11 instantanément à chaque photo
  previewWatcherScript = pkgs.writeShellApplication {
    name = "photostand-camera-preview-watcher";
    runtimeInputs = with pkgs; [
      coreutils
      inotify-tools
      imv
      i3
      procps
    ];
    text = ''
      set -euo pipefail

      PREVIEW_DIR=${lib.escapeShellArg previewDir}
      HISTORY_DIR=${lib.escapeShellArg historyDir}
      EVT_FILE="$PREVIEW_DIR/.latest-path"
      MODE=${lib.escapeShellArg cfg.preview.mode}
      WINDOW_TITLE="Photo Stand — Apercu Canon"
      PID_FILE="/tmp/photostand-imv.pid"

      mkdir -p "$PREVIEW_DIR" "$HISTORY_DIR" 2>/dev/null || true

      is_imv_running() {
        [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
      }

      launch_or_update() {
        local photo="$1"
        [ -f "$photo" ] || return 0

        if is_imv_running; then
          local pid
          pid="$(cat "$PID_FILE")"
          imv-msg "$pid" open "$photo" >/dev/null 2>&1 || true
          imv-msg "$pid" goto -1 >/dev/null 2>&1 || true
        else
          # Ouvre imv-x11 avec tout l'historique de session et saute sur la dernière photo
          imv-x11 \
            -s shrink \
            -b 111318 \
            -d \
            -w "$WINDOW_TITLE" \
            "$HISTORY_DIR" >/dev/null 2>&1 &
          local pid=$!
          echo "$pid" > "$PID_FILE"
          # Laisser imv ouvrir son socket IPC puis aller sur la dernière photo
          sleep 0.4
          imv-msg "$pid" goto -1 >/dev/null 2>&1 || true
        fi

        if [ "$MODE" = "popup" ]; then
          i3-msg "[title=\"^$WINDOW_TITLE\"] focus" >/dev/null 2>&1 || true
        fi
      }

      # Si une photo existe déjà au lancement de la session, ouvrir l'aperçu si en mode workspace
      if [ "$MODE" = "workspace" ] && [ -f "$EVT_FILE" ]; then
        EXISTING="$(cat "$EVT_FILE" 2>/dev/null || true)"
        [ -n "$EXISTING" ] && launch_or_update "$EXISTING"
      fi

      # Attente événementielle (<50ms, 0% CPU) sur chaque nouvelle photo JPEG capturée
      while true; do
        if [ ! -d "$PREVIEW_DIR" ]; then
          sleep 2
          continue
        fi
        inotifywait -q -m -e moved_to,close_write --format '%f' "$PREVIEW_DIR" | while read -r fname; do
          if [ "$fname" = ".latest-path" ] && [ -f "$EVT_FILE" ]; then
            PHOTO_PATH="$(cat "$EVT_FILE" 2>/dev/null || true)"
            [ -n "$PHOTO_PATH" ] && launch_or_update "$PHOTO_PATH"
          fi
        done
        sleep 1
      done
    '';
  };

  # Commande manuelle / raccourci i3 (Super+P) pour ouvrir ou afficher l'aperçu Canon
  openPreviewBin = pkgs.writeShellApplication {
    name = "stand-camera-preview";
    runtimeInputs = with pkgs; [
      coreutils
      imv
      i3
    ];
    text = ''
      set -euo pipefail

      HISTORY_DIR=${lib.escapeShellArg historyDir}
      WINDOW_TITLE="Photo Stand — Apercu Canon"
      PID_FILE="/tmp/photostand-imv.pid"

      if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        i3-msg "[title=\"^$WINDOW_TITLE\"] focus" >/dev/null 2>&1 || true
        exit 0
      fi

      if ls -1 "$HISTORY_DIR"/*.jpg "$HISTORY_DIR"/*.jpeg "$HISTORY_DIR"/*.JPG "$HISTORY_DIR"/*.JPEG >/dev/null 2>&1; then
        imv-x11 \
          -s shrink \
          -b 111318 \
          -d \
          -w "$WINDOW_TITLE" \
          "$HISTORY_DIR" >/dev/null 2>&1 &
        pid=$!
        echo "$pid" > "$PID_FILE"
        sleep 0.4
        imv-msg "$pid" goto -1 >/dev/null 2>&1 || true
      else
        echo "Aucune photo capturée pour l'instant dans $HISTORY_DIR."
      fi
    '';
  };

  cameraStatusBin = pkgs.writeShellScriptBin "stand-camera-status" ''
    echo "=== Appareils USB détectés (gphoto2) ==="
    ${pkgs.gphoto2}/bin/gphoto2 --auto-detect || true
    echo ""
    echo "=== Service photostand-camera-tether ==="
    systemctl --no-pager -l status photostand-camera-tether.service || true
    echo ""
    echo "=== Dernières photos reçues (${historyDir}) ==="
    ls -lht ${lib.escapeShellArg historyDir} 2>/dev/null | head -n 10 || echo "(aucune)"
  '';
in
{
  options.services.photostand.camera = {
    enable = lib.mkEnableOption "Tethering USB-C appareil photo Canon (gphoto2) + aperçu instantané hors-frontend";

    keepOnSdCard = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Active capturetarget=1 (carte SD) et --keep pour conserver toutes les photos sur la carte SD du boîtier.";
    };

    imageFormat = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "Large Fine JPEG";
      description = "Format image configuré automatiquement au branchement via /main/imgsettings/imageformat (null pour ne pas modifier le réglage du boîtier).";
    };

    preview = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ouvre un aperçu instantané (imv) de chaque JPEG capturé, en dehors du frontend (style Canon EOS Utility).";
      };

      mode = lib.mkOption {
        type = lib.types.enum [
          "workspace"
          "popup"
        ];
        default = "workspace";
        description = ''
          - "workspace" : ouvre l'aperçu dans le workspace i3 2:Apercu (ne dérange pas la prise de commande sur le frontend, accessible via Super+2 / Super+P ou déplaçable sur un 2e écran).
          - "popup" : affiche l'aperçu en fenêtre flottante au premier plan dès qu'une photo arrive.
        '';
      };

      historyLimit = lib.mkOption {
        type = lib.types.int;
        default = 100;
        description = "Nombre maximal de derniers JPEG conservés dans l'historique d'aperçu local.";
      };
    };

    previewWatcherBin = lib.mkOption {
      type = lib.types.path;
      internal = true;
      readOnly = true;
      default = "${previewWatcherScript}/bin/photostand-camera-preview-watcher";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      gphoto2
      imv
      inotify-tools
      cameraStatusBin
      openPreviewBin
    ];

    # Règle udev pour les boîtiers Canon (vendor 04a9) : accès utilisateur & hotplug propre
    services.udev.packages = [ pkgs.libgphoto2 ];
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="04a9", MODE="0666", GROUP="plugdev"
    '';
    users.groups.plugdev = { };

    # Création des dossiers de preview accessibles en lecture par l'utilisateur i3 (`stand`)
    systemd.tmpfiles.rules = [
      "d ${previewDir} 0755 root root -"
      "d ${historyDir} 0755 root root -"
      "d ${stagingDir} 0755 root root -"
    ];

    systemd.services.photostand-camera-tether = {
      description = "Tethering USB-C Canon EOS -> Photo Stand (gphoto2)";
      after = [ "local-fs.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${tetherDaemonScript}/bin/photostand-camera-tether";
        Restart = "always";
        RestartSec = "3s";
      };
    };
  };
}
