{
  description = "Configuration NixOS réplicable pour déployer un Photo Stand (+ VM QEMU + Netboot iPXE + CLI stand-ctl)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Fusionne la config versionnée (config.nix) avec les surcharges machine (local.nix)
      baseConfig = import ./config.nix;
      localConfig = if builtins.pathExists ./local.nix then import ./local.nix else { };
      standConfig = nixpkgs.lib.recursiveUpdate baseConfig localConfig;

      ports = standConfig.vm.ports;
      netbootCfg = standConfig.netboot;

      # 1. Cible principale : vrai PC stand sur une installation fraîche de NixOS (avec i3 + Firefox)
      standSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit standConfig; };
        modules = [ ./host/default.nix ];
      };

      # 2. Option de test : VM QEMU headless (console série)
      vmSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit standConfig; };
        modules = [ ./vm/default.nix ];
      };

      # 3. Option de test : VM QEMU graphique (teste aussi i3 + Firefox plein écran)
      vmGuiSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit standConfig; };
        modules = [
          ./vm/default.nix
          (
            { lib, ... }:
            {
              virtualisation.graphics = lib.mkForce true;
              virtualisation.resolution = {
                x = 1280;
                y = 800;
              };
              services.photostand.kiosk.enable = lib.mkForce true;
            }
          )
        ];
      };

      # 4. Image Netboot iPXE (boot réseau en RAM, aucune installation NixOS requise)
      netbootSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit standConfig; };
        modules = [ ./netboot/default.nix ];
      };

      netbootBuild = netbootSystem.config.system.build;
      netbootKernelParams = builtins.concatStringsSep " " netbootSystem.config.boot.kernelParams;
      netbootTimeoutMs = toString (netbootCfg.promptTimeoutSeconds * 1000);

      # Script iPXE interactif : permet de saisir l'URL du repo `stand-nixos` au boot
      # pour installer NixOS + Photo Stand en une seule passe sur le disque local.
      customIpxeScript = pkgs.writeText "netboot.ipxe" ''
        #!ipxe
        # Photo Stand — Auto-installateur NixOS via iPXE (un seul netboot, puis boot disque local)

        isset ''${stand_repo}      || set stand_repo ${netbootCfg.repoUrl}
        isset ''${stand_ref}       || set stand_ref ${netbootCfg.repoRef}
        isset ''${stand_disk}      || set stand_disk ${netbootCfg.defaultDisk}
        isset ''${stand_id}        || set stand_id
        isset ''${stand_ip}        || set stand_ip
        isset ''${stand_profiles}  || set stand_profiles
        isset ''${stand_auto_wipe} || set stand_auto_wipe ${if netbootCfg.autoWipe then "1" else "0"}

        echo ============================================================
        echo   Photo Stand — Auto-installateur NixOS (iPXE)
        echo ============================================================
        isset ''${stand_repo} && echo Repo stand-nixos : ''${stand_repo} (''${stand_ref}) || echo Repo stand-nixos : (sera demande au demarrage)
        isset ''${stand_disk} && echo Disque cible     : ''${stand_disk} || echo Disque cible     : (choix interactif au demarrage)
        echo
        prompt --key c --timeout ${netbootTimeoutMs} Appuyez sur [c] (${toString netbootCfg.promptTimeoutSeconds}s) pour saisir/modifier l'URL du repo... && goto configure || goto boot

        :configure
        echo
        echo -n URL du repo stand-nixos [''${stand_repo}] : 
        read stand_repo
        echo -n Branche / tag / commit  [''${stand_ref}]  : 
        read stand_ref
        echo -n Disque cible (ex: /dev/nvme0n1, vide=menu) [''${stand_disk}] : 
        read stand_disk
        echo -n ID du stand (optionnel, ex: stand-1)     : 
        read stand_id
        echo -n IP du PC principal (optionnel)           : 
        read stand_ip
        echo -n Profils Docker (optionnel, ex: primary,print-vm) : 
        read stand_profiles

        :boot
        set extra_args
        isset ''${stand_repo}      && set extra_args ''${extra_args} stand.repo=''${stand_repo} ||
        isset ''${stand_ref}       && set extra_args ''${extra_args} stand.ref=''${stand_ref} ||
        isset ''${stand_disk}      && set extra_args ''${extra_args} stand.disk=''${stand_disk} ||
        isset ''${stand_id}        && set extra_args ''${extra_args} stand.id=''${stand_id} ||
        isset ''${stand_ip}        && set extra_args ''${extra_args} stand.primary_ip=''${stand_ip} ||
        isset ''${stand_profiles}  && set extra_args ''${extra_args} stand.profiles=''${stand_profiles} ||
        isset ''${stand_auto_wipe} && set extra_args ''${extra_args} stand.auto_wipe=''${stand_auto_wipe} ||

        echo
        echo Chargement du noyau NixOS...
        kernel bzImage init=${netbootBuild.toplevel}/init ${netbootKernelParams} ''${extra_args} initrd=initrd
        echo Chargement de l'installateur NixOS...
        initrd initrd
        boot
      '';

      # Dossier prêt à servir par n'importe quel serveur HTTP/iPXE :
      #   bzImage, initrd, netboot.ipxe
      netbootBundle = pkgs.linkFarm "photostand-netboot" [
        {
          name = "bzImage";
          path = "${netbootBuild.kernel}/bzImage";
        }
        {
          name = "initrd";
          path = "${netbootBuild.netbootRamdisk}/initrd";
        }
        {
          name = "netboot.ipxe";
          path = customIpxeScript;
        }
      ];

      vmDrv = vmSystem.config.system.build.vm;
      vmGuiDrv = vmGuiSystem.config.system.build.vm;

      mkVmRunner =
        {
          name,
          drv,
          modeLabel,
        }:
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            set -euo pipefail

            CAPTURE_DIR=${nixpkgs.lib.escapeShellArg standConfig.vm.hostCaptureDir}
            STAND_ID=${nixpkgs.lib.escapeShellArg standConfig.stand.standId}
            STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/stand-nixos"

            mkdir -p "$STATE_DIR"
            mkdir -p "$CAPTURE_DIR/$STAND_ID/watch" \
                     "$CAPTURE_DIR/$STAND_ID/processed" \
                     "$CAPTURE_DIR/$STAND_ID/failed"

            export NIX_DISK_IMAGE="''${NIX_DISK_IMAGE:-$STATE_DIR/photostand-vm.qcow2}"

            cat <<EOF
            ======================================================================
              Démarrage de la VM NixOS de test (${modeLabel}) — Photo Stand
            ======================================================================
              Dossier de dépôt photos (hôte) : $CAPTURE_DIR/$STAND_ID/watch/
              Disque persistant VM           : $NIX_DISK_IMAGE

              URLs sur ton PC hôte (disponibles dès que Docker Compose a démarré) :
                - Frontend    : http://127.0.0.1:${toString ports.frontend}
                - Job API     : http://127.0.0.1:${toString ports.jobSvc}
                - S3 API      : http://127.0.0.1:${toString ports.s3Api}
                - S3 Console  : http://127.0.0.1:${toString ports.s3Console} (minioadmin / minioadmin)
                - RabbitMQ UI : http://127.0.0.1:${toString ports.rabbitmqUi} (guest / guest)
                - pgAdmin     : http://127.0.0.1:${toString ports.pgadmin} (admin@admin.com / admin)
                - SSH VM      : ssh -p ${toString ports.ssh} root@127.0.0.1 (mdp: stand)

              Raccourcis i3 (mode GUI) :
                - Super+F      : basculer plein écran (afficher/cacher i3status)
                - Super+Entrée : ouvrir un terminal
                - Super+D      : lanceur d'applications (dmenu)
                - Super+B      : rouvrir Firefox sur le frontend

              Quitter la VM (mode console) : Ctrl+A puis X
              Réinitialiser la VM          : ./stand-ctl test reset
            ======================================================================
            EOF

            exec ${drv}/bin/run-photostand-vm-vm "$@"
          '';
        };

      runVmWrapper = mkVmRunner {
        name = "run-photostand-vm";
        drv = vmDrv;
        modeLabel = "console";
      };

      runVmGuiWrapper = mkVmRunner {
        name = "run-photostand-vm-gui";
        drv = vmGuiDrv;
        modeLabel = "GUI i3 + Firefox";
      };

      netbootServeWrapper = pkgs.writeShellApplication {
        name = "serve-photostand-netboot";
        runtimeInputs = [
          pkgs.python3
          pkgs.iproute2
          pkgs.gawk
        ];
        text = ''
          set -euo pipefail
          PORT="''${1:-8000}"
          LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || echo "127.0.0.1")"

          cat <<EOF
          ======================================================================
            Serveur HTTP Netboot iPXE — Photo Stand
          ======================================================================
            Dossier servi : ${netbootBundle}
            Port          : $PORT

            Dans votre shell iPXE ou serveur DHCP/PXE, utilisez :
              chain http://$LAN_IP:$PORT/netboot.ipxe

            Ou pour pré-remplir l'URL du repo directement en iPXE :
              set stand_repo https://github.com/<user>/stand-nixos.git
              chain http://$LAN_IP:$PORT/netboot.ipxe

            Ctrl+C pour arrêter le serveur HTTP.
          ======================================================================
          EOF

          exec python3 -m http.server "$PORT" --bind 0.0.0.0 --directory ${netbootBundle}
        '';
      };

      standCtlPkg = pkgs.writeShellApplication {
        name = "stand-ctl";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.git
          pkgs.openssh
          pkgs.gnugrep
          pkgs.iproute2
        ];
        text = ''
          exec ${pkgs.bash}/bin/bash ${./stand-ctl} "$@"
        '';
      };
    in
    {
      # Modules NixOS réutilisables (si vous préférez intégrer dans un /etc/nixos existant)
      nixosModules = {
        photostand = ./modules/photostand.nix;
        kiosk-i3 = ./modules/kiosk-i3.nix;
        camera-tether = ./modules/camera-tether.nix;
        base-system = ./modules/base-system.nix;
        default = self.nixosModules.photostand;
      };

      # Configurations NixOS complètes
      nixosConfigurations = {
        # Déploiement réel sur un NixOS frais : sudo nixos-rebuild switch --flake .#stand
        stand = standSystem;
        # VM de test headless : ./stand-ctl test
        stand-vm = vmSystem;
        # VM de test graphique avec i3 + Firefox : ./stand-ctl test gui
        stand-vm-gui = vmGuiSystem;
        # Image Netboot iPXE en RAM : ./stand-ctl netboot build
        stand-netboot = netbootSystem;
      };

      packages.${system} = {
        vm = vmDrv;
        vm-gui = vmGuiDrv;
        netboot = netbootBundle;
        stand-ctl = standCtlPkg;
        default = standCtlPkg;
      };

      apps.${system} = {
        ctl = {
          type = "app";
          program = "${standCtlPkg}/bin/stand-ctl";
        };
        vm = {
          type = "app";
          program = "${runVmWrapper}/bin/run-photostand-vm";
        };
        vm-gui = {
          type = "app";
          program = "${runVmGuiWrapper}/bin/run-photostand-vm-gui";
        };
        netboot-serve = {
          type = "app";
          program = "${netbootServeWrapper}/bin/serve-photostand-netboot";
        };
        default = self.apps.${system}.ctl;
      };
    };
}
