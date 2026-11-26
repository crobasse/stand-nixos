{
  description = "Configuration NixOS réplicable pour déployer un Photo Stand (+ VM QEMU de test + CLI stand-ctl)";

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
      };

      packages.${system} = {
        vm = vmDrv;
        vm-gui = vmGuiDrv;
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
        default = self.apps.${system}.ctl;
      };
    };
}
