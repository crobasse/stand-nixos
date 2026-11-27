# Module NixOS : session graphique i3 + Firefox en plein écran sur le frontend.
#
# - Autologin graphique (LightDM) sur i3
# - Lance Firefox automatiquement sur le frontend (avec écran d'attente auto-redirection
#   si Docker Compose est encore en cours de démarrage)
# - Force Firefox en plein écran i3 (`fullscreen enable`) pour masquer i3status par défaut
# - Conserve tous les contrôles de base i3 (Mod+f pour afficher i3status / quitter le plein écran,
#   Mod+Return pour un terminal, Mod+d pour dmenu, Mod+1..9 pour les workspaces, Mod+b pour rouvrir
#   le frontend, etc.)
{
  config,
  lib,
  pkgs,
  ...
}:

let
  psCfg = config.services.photostand;
  cfg = psCfg.kiosk;

  defaultFrontendUrl =
    if lib.elem "primary" psCfg.stand.composeProfiles then
      "http://127.0.0.1"
    else
      "http://${psCfg.stand.primaryIp}";

  frontendUrl = if cfg.url != null then cfg.url else defaultFrontendUrl;

  # Page d'attente locale affichée uniquement si le frontend n'est pas encore prêt au boot.
  # Vérifie toutes les 2 secondes et redirige automatiquement dès que Nginx répond.
  waitingPage = pkgs.writeText "photostand-waiting.html" ''
    <!doctype html>
    <html lang="fr">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Photo Stand — Démarrage...</title>
        <style>
          body {
            margin: 0;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            background: #111318;
            color: #f4f4f5;
            font-family: system-ui, -apple-system, sans-serif;
            text-align: center;
          }
          .spinner {
            width: 44px;
            height: 44px;
            border: 4px solid #27272a;
            border-top-color: #f4f4f5;
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin-bottom: 20px;
          }
          @keyframes spin { to { transform: rotate(360deg); } }
          p { color: #a1a1aa; margin: 6px 0; }
          a {
            margin-top: 18px;
            padding: 10px 18px;
            border-radius: 8px;
            background: #27272a;
            color: #f4f4f5;
            text-decoration: none;
            font-size: 14px;
          }
          .hint {
            position: fixed;
            bottom: 16px;
            font-size: 12px;
            color: #71717a;
          }
        </style>
      </head>
      <body>
        <div class="spinner"></div>
        <h1>Photo Stand</h1>
        <p id="status">Démarrage des services en cours...</p>
        <p id="target-label">Cible : ${frontendUrl}</p>
        <a id="open-link" href="${frontendUrl}">Ouvrir maintenant</a>
        <div class="hint">i3 : Super+F (quitter plein écran / voir i3status) · Super+Entrée (terminal) · Super+D (applications)</div>
        <script>
          const params = new URLSearchParams(window.location.search);
          const target = params.get("target") || ${builtins.toJSON frontendUrl};
          document.getElementById("target-label").textContent = "Cible : " + target;
          document.getElementById("open-link").href = target;
          async function check() {
            try {
              await fetch(target, { mode: "no-cors", cache: "no-store" });
              window.location.replace(target);
            } catch (_) {
              setTimeout(check, 2000);
            }
          }
          check();
        </script>
      </body>
    </html>
  '';

  launchFrontendScript = pkgs.writeShellScript "photostand-launch-frontend" ''
    TARGET=${lib.escapeShellArg frontendUrl}
    CMDLINE_PROFILES=""
    CMDLINE_PRIMARY_IP=""
    for token in $(cat /proc/cmdline); do
      case "$token" in
        stand.profiles=*)   CMDLINE_PROFILES="''${token#stand.profiles=}" ;;
        stand.primary_ip=*) CMDLINE_PRIMARY_IP="''${token#stand.primary_ip=}" ;;
      esac
    done
    if [ -n "$CMDLINE_PROFILES" ] && [[ ",$CMDLINE_PROFILES," != *",primary,"* ]] && [ -n "$CMDLINE_PRIMARY_IP" ]; then
      TARGET="http://$CMDLINE_PRIMARY_IP"
    fi
    if ${pkgs.curl}/bin/curl -fsS --max-time 2 "$TARGET" >/dev/null 2>&1; then
      exec ${pkgs.firefox}/bin/firefox --new-window "$TARGET"
    else
      exec ${pkgs.firefox}/bin/firefox --new-window "file://${waitingPage}?target=$TARGET"
    fi
  '';

  i3StatusConfig = pkgs.writeText "i3status.conf" ''
    general {
      colors = true
      interval = 5
    }

    order += "wireless _first_"
    order += "ethernet _first_"
    order += "disk /"
    order += "memory"
    order += "cpu_usage"
    order += "tztime local"

    wireless _first_ {
      format_up = "WiFi: %ip (%quality)"
      format_down = "WiFi: down"
    }

    ethernet _first_ {
      format_up = "LAN: %ip"
      format_down = "LAN: down"
    }

    disk "/" {
      format = "Disque: %avail libre"
    }

    memory {
      format = "RAM: %used / %total"
    }

    cpu_usage {
      format = "CPU: %usage"
    }

    tztime local {
      format = "%d/%m/%Y %H:%M:%S"
    }
  '';

  alacrittyConfig = pkgs.writeText "alacritty-photostand.toml" ''
    [window]
    padding = { x = 10, y = 10 }
    decorations = "Full"

    [font]
    size = 12.0

    [font.normal]
    family = "JetBrains Mono"
    style = "Regular"

    [colors.primary]
    background = "#111318"
    foreground = "#f4f4f5"

    [colors.normal]
    black   = "#18181b"
    red     = "#ef4444"
    green   = "#22c55e"
    yellow  = "#eab308"
    blue    = "#3b82f6"
    magenta = "#a855f7"
    cyan    = "#06b6d4"
    white   = "#e4e4e7"

    [colors.bright]
    black   = "#52525b"
    red     = "#f87171"
    green   = "#4ade80"
    yellow  = "#facc15"
    blue    = "#60a5fa"
    magenta = "#c084fc"
    cyan    = "#22d3ee"
    white   = "#ffffff"
  '';

  i3ConfigFile = pkgs.writeText "i3-photostand.conf" ''
    # =========================================================================
    # Configuration i3 — Photo Stand
    # Touche Mod = Super (touche Windows)
    # =========================================================================
    set $mod Mod4

    font pango:JetBrains Mono 10
    floating_modifier $mod

    # Désactiver la mise en veille / extinction d'écran sur le stand
    exec --no-startup-id ${pkgs.xset}/bin/xset s off -dpms
    exec --no-startup-id ${pkgs.xset}/bin/xset s noblank

    # Ouvrir automatiquement Firefox sur le frontend (en plein écran via la règle ci-dessous)
    for_window [class="(?i)firefox"] fullscreen enable
    exec --no-startup-id ${launchFrontendScript}

    ${lib.optionalString (psCfg.camera.enable && psCfg.camera.preview.enable) ''
      # Aperçu instantané hors-frontend des JPEG reçus du Canon (style Canon EOS Utility)
      ${
        if psCfg.camera.preview.mode == "popup" then
          ''
            for_window [title="^Photo Stand — Apercu Canon"] floating enable, resize set 1100 740, move position center
          ''
        else
          ''
            assign [title="^Photo Stand — Apercu Canon"] $ws2
          ''
      }
      exec --no-startup-id ${psCfg.camera.previewWatcherBin}
    ''}

    # --- Contrôles de base i3 ---
    # Basculer le plein écran (permet d'afficher/cacher i3status à tout moment)
    bindsym $mod+f fullscreen toggle

    # Ouvrir un terminal (Alacritty)
    bindsym $mod+Return exec ${pkgs.alacritty}/bin/alacritty --config-file ${alacrittyConfig}

    # Lanceur d'applications (dmenu)
    bindsym $mod+d exec --no-startup-id ${pkgs.dmenu}/bin/dmenu_run

    # Rouvrir le frontend Photo Stand si Firefox a été fermé
    bindsym $mod+b exec --no-startup-id ${launchFrontendScript}

    # Afficher / ouvrir l'aperçu photo Canon (imv)
    ${lib.optionalString (psCfg.camera.enable && psCfg.camera.preview.enable) ''
      bindsym $mod+p exec --no-startup-id stand-camera-preview
    ''}

    # Fermer la fenêtre active
    bindsym $mod+Shift+q kill

    # Changer le focus
    bindsym $mod+Left focus left
    bindsym $mod+Down focus down
    bindsym $mod+Up focus up
    bindsym $mod+Right focus right

    # Déplacer la fenêtre active
    bindsym $mod+Shift+Left move left
    bindsym $mod+Shift+Down move down
    bindsym $mod+Shift+Up move up
    bindsym $mod+Shift+Right move right

    # Disposition / splits / flottant
    bindsym $mod+h split h
    bindsym $mod+v split v
    bindsym $mod+s layout stacking
    bindsym $mod+w layout tabbed
    bindsym $mod+e layout toggle split
    bindsym $mod+Shift+space floating toggle
    bindsym $mod+space focus mode_toggle

    # Workspaces (passer sur le workspace 2 affiche immédiatement i3status et l'aperçu Canon)
    set $ws1 "1:Stand"
    set $ws2 "2:Apercu"
    set $ws3 "3"
    set $ws4 "4"
    set $ws5 "5"

    bindsym $mod+1 workspace $ws1
    bindsym $mod+2 workspace $ws2
    bindsym $mod+3 workspace $ws3
    bindsym $mod+4 workspace $ws4
    bindsym $mod+5 workspace $ws5

    bindsym $mod+Shift+1 move container to workspace $ws1
    bindsym $mod+Shift+2 move container to workspace $ws2
    bindsym $mod+Shift+3 move container to workspace $ws3
    bindsym $mod+Shift+4 move container to workspace $ws4
    bindsym $mod+Shift+5 move container to workspace $ws5

    # Recharger / redémarrer / quitter i3
    bindsym $mod+Shift+c reload
    bindsym $mod+Shift+r restart
    bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Quitter la session i3 ?' -B 'Oui, quitter' 'i3-msg exit'"

    # Barre de statut i3status (automatiquement masquée quand Firefox est en plein écran)
    bar {
      status_command ${pkgs.i3status}/bin/i3status -c ${i3StatusConfig}
      position bottom
    }
  '';
in
{
  options.services.photostand.kiosk = {
    enable = lib.mkEnableOption "Session graphique i3 avec Firefox en plein écran sur le frontend";

    user = lib.mkOption {
      type = lib.types.str;
      default = "stand";
      description = "Utilisateur connecté automatiquement dans la session i3.";
    };

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL du frontend ouverte par Firefox (auto-détectée selon composeProfiles si null).";
    };

    keymap = lib.mkOption {
      type = lib.types.str;
      default = "fr";
      description = "Disposition clavier X11 (ex: fr, us).";
    };
  };

  config = lib.mkIf cfg.enable {
    # OpenGL/Mesa (incluant llvmpipe en VM) requis par Alacritty et Firefox
    hardware.graphics.enable = true;

    # Polices lisibles pour Alacritty, i3, i3status et Firefox
    fonts.packages = with pkgs; [
      jetbrains-mono
      dejavu_fonts
    ];

    services.xserver = {
      enable = true;
      xkb.layout = cfg.keymap;

      displayManager.lightdm.enable = true;

      windowManager.i3 = {
        enable = true;
        configFile = i3ConfigFile;
        extraPackages = with pkgs; [
          i3status
          dmenu
          alacritty
        ];
      };
    };

    services.displayManager = {
      defaultSession = "none+i3";
      autoLogin = {
        enable = true;
        user = cfg.user;
      };
    };

    # Firefox configuré proprement sans écran de bienvenue ni popups de premier lancement
    programs.firefox = {
      enable = true;
      policies = {
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        DontCheckDefaultBrowser = true;
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        NoDefaultBookmarks = true;
        OfferToSaveLogins = false;
        PasswordManagerEnabled = false;
        Homepage = {
          URL = frontendUrl;
          StartPage = "homepage";
        };
      };
    };
  };
}
