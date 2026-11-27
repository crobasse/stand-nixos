# stand-nixos — Déploiement NixOS réplicable d'un Photo Stand (+ VM de test)

Ce dépôt permet de mettre en place un **Photo Stand complet** sur une installation fraîche de NixOS de manière reproductible, et inclut une **VM QEMU optionnelle** pour tester la même configuration sans toucher à ton PC.

Tout se pilote via l'outil CLI **`./stand-ctl`**.

## Architecture

```text
stand-nixos/
├── stand-ctl                 # CLI de contrôle (install, prod, test, menu interactif)
├── config.nix                # Configuration par défaut (URLs/refs Git, stand réel, options VM)
├── local.nix                 # (généré par `stand-ctl install`, ignoré par Git) surcharges locales
├── flake.nix                 # Cibles : `#stand` (PC réel), `#stand-vm` / `#vm` (test), `#ctl`
├── modules/
│   ├── photostand.nix        # Module systemd (Docker, sync Git, Docker Compose, mock printer optionnel)
│   ├── kiosk-i3.nix          # Session i3 + Firefox en plein écran sur le frontend (masque i3status)
│   └── base-system.nix       # Socle NixOS commun partagé entre le PC réel et la VM de test
├── host/
│   └── default.nix           # Configuration pour un PC physique NixOS frais (`nixosConfigurations.stand`)
├── vm/
│   └── default.nix           # Option de test en VM QEMU (`nixosConfigurations.stand-vm`)
├── netboot/
│   └── default.nix           # Image Netboot iPXE en RAM (`nixosConfigurations.stand-netboot`)
└── scripts/
    └── mock-printer.py       # Mock RabbitMQ simulant stand-print-svc sans Windows (utilisé en VM)
```

---

## Utilisation de `stand-ctl`

```bash
cd stand-nixos
./stand-ctl           # Ouvre le menu interactif
./stand-ctl help      # Affiche toutes les sous-commandes
```

### 1. Installer & configurer sur une installation fraîche de NixOS

```bash
git clone <url-de-stand-nixos>
cd stand-nixos
./stand-ctl install
```

L'assistant :
1. Copie `/etc/nixos/hardware-configuration.nix` vers `host/hardware-configuration.nix`.
2. Pose les questions essentielles (`standId`, profil `primary+print-vm` / `primary` / `secondary`, `primaryIp`, imprimante USB, clé SSH si dépôts privés) et génère `local.nix` (sans toucher à `config.nix`).
3. Propose d'appliquer immédiatement `sudo nixos-rebuild switch --flake .#stand` (avec les flags flakes activés automatiquement).

> **Alternative modulaire** : si vous préférez conserver votre `/etc/nixos` existant (bureau GNOME/KDE, utilisateurs, bootloader), importez simplement `stand-nixos.nixosModules.photostand` dans votre configuration.

### 2. Lancer et contrôler la version de production

```bash
./stand-ctl prod                 # Démarre la stack de production (sync Git + Docker Compose)
./stand-ctl prod status          # État systemd + conteneurs Docker
./stand-ctl prod logs [service]  # Logs Docker Compose en direct (ex: job-svc)
./stand-ctl prod restart         # Re-synchronise les dépôts Git et redémarre
./stand-ctl prod stop            # Arrête la stack
./stand-ctl prod rebuild         # Réapplique config.nix / local.nix via nixos-rebuild switch
./stand-ctl prod update          # git pull stand-nixos + nixos-rebuild switch + resync services
```

### 3. Lancer et contrôler la version de test (VM QEMU isolée)

Ne modifie rien sur ton PC hôte. La VM exécute le même socle `modules/base-system.nix` + `modules/photostand.nix`, avec port-forwarding sur `127.0.0.1` et l'imprimante simulée (`mockPrinter`).

```bash
./stand-ctl test         # Construit et démarre la VM de test (mode console)
./stand-ctl test gui     # Démarre la VM en mode graphique (teste i3 + Firefox plein écran)
./stand-ctl test ssh     # Ouvre un shell SSH dans la VM (mot de passe : stand)
./stand-ctl test reset   # Supprime le disque persistant pour repartir d'une VM vierge
./stand-ctl test build   # Construit la VM sans la lancer
```

### 4. Interface kiosque i3 + Firefox (PC réel & `./stand-ctl test gui`)

Au démarrage graphique, LightDM connecte automatiquement l'utilisateur `stand` sur **i3**, qui :
- Désactive la mise en veille de l'écran (`xset s off -dpms`).
- Ouvre **Firefox en plein écran** (`for_window [class="(?i)firefox"] fullscreen enable`), ce qui **masque `i3status`**.
- Affiche une page d'attente auto-rafraîchie si le frontend Docker est encore en cours de démarrage, puis bascule automatiquement sur le frontend.

Contrôles i3 disponibles à tout moment (touche `Super` = touche Windows) :

| Raccourci | Action |
| :--- | :--- |
| `Super + F` | Quitter / remettre le plein écran (révèle `i3status`) |
| `Super + Entrée` | Ouvrir un terminal (`alacritty`) |
| `Super + D` | Lanceur d'applications (`dmenu`) |
| `Super + B` | Rouvrir Firefox sur le frontend |
| `Super + 1..5` | Changer de workspace (le workspace 2 affiche `i3status` sans toucher à Firefox) |
| `Super + Shift + Q` | Fermer la fenêtre active |
| `Super + Shift + R` | Redémarrer i3 |

### 5. Auto-installation en un seul Netboot iPXE (PC vierge → Stand prêt à l'emploi)

Permet de démarrer un PC vierge **une seule fois** via iPXE : l'image légère (sans Xorg/Docker en RAM) partitionne automatiquement le disque (UEFI GPT ou BIOS Legacy MBR), clone `stand-nixos` dans `/etc/stand-nixos`, installe NixOS complet + Docker + i3 + Firefox, puis redémarre sur le disque local **prêt à l'emploi**.

```bash
./stand-ctl netboot build        # Génère result-netboot/{bzImage,initrd,netboot.ipxe}
./stand-ctl netboot serve 8000   # Sert l'image en HTTP sur le réseau local
```

Sur le PC cible en iPXE (ou via serveur DHCP/PXE) :

```ipxe
chain http://<IP-SERVEUR>:8000/netboot.ipxe
```

Au démarrage iPXE, appuie sur **`c`** (ou pré-remplis `netboot.repoUrl` dans `config.nix`) pour indiquer :
- l'**URL du dépôt `stand-nixos`** (`stand.repo=...`)
- optionnellement : `stand.ref`, `stand.disk` (ex: `/dev/nvme0n1` ; sinon choix interactif avec liste des disques), `stand.id`, `stand.primary_ip`, `stand.profiles`, `stand.auto_wipe=1` (mode 100 % sans confirmation).

Exemple en mode totalement automatisé depuis iPXE :

```ipxe
set stand_repo https://github.com/<user>/stand-nixos.git
set stand_disk /dev/nvme0n1
set stand_auto_wipe 1
chain http://<IP-SERVEUR>:8000/netboot.ipxe
```

Une fois le PC redémarré sur son disque local :
- Plus besoin de serveur iPXE : NixOS démarre i3 + Firefox en plein écran et lance les services Docker automatiquement.
- La commande `stand-ctl` est directement disponible dans le `PATH` (ex: `stand-ctl prod update`).

---

#### Accès depuis ton PC hôte (mode VM)

| Service | URL depuis l'hôte | Identifiants |
| :--- | :--- | :--- |
| Frontend | http://127.0.0.1:8088 | — |
| Job API (Swagger) | http://127.0.0.1:8080 | — |
| RustFS / S3 Console | http://127.0.0.1:9001 | `minioadmin` / `minioadmin` |
| RabbitMQ Management | http://127.0.0.1:15672 | `guest` / `guest` |
| pgAdmin | http://127.0.0.1:5050 | `admin@admin.com` / `admin` |
| SSH dans la VM | `./stand-ctl test ssh` (port 2222) | `stand` |

#### Tester le flux complet (Ingest → Galerie → Impression → SSE)

1. Copiez une photo `.jpg` dans `/tmp/photostand-vm-capture/stand-1/watch/`.
2. `ingest-svc` applique les watermarks, redimensionne et upload vers S3.
3. Ouvrez **http://127.0.0.1:8088**, sélectionnez la photo et lancez une impression.
4. `photostand-mock-printer` consomme `print.jobs` et renvoie `printing` puis `done` sur `print.status` (SSE en temps réel).
5. Pour quitter la console QEMU : `Ctrl+A` puis `X` (ou `poweroff` dans la VM).
