{
  description = "Zentrale MicroVM Sandbox für SolidJS, Rust/Tauri, Android & SailfishOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }: {
    lib.mkDevSandbox = {
      name,
      hostname ? "dev-vm",
      # Adresse, an die alle weitergeleiteten Ports auf dem Host gebunden werden.
      # Jede VM bekommt ihre eigene aus 127.0.0.0/8 (z.B. 127.0.10.1, 127.0.10.2, …):
      # dann kollidieren weder SSH noch App-Ports zwischen parallel laufenden VMs,
      # und nichts davon ist im LAN erreichbar. Leer ("") bindet an alle Interfaces.
      hostAddress ? "127.0.0.1",
      sshPort ? 2222,
      ports ? [],
      vcpu ? 4,
      mem ? 4096,
      diskSize ? 16384,
      profiles ? [ "solid" ],
      extraPackages ? (pkgs: []),
      extraEnv ? {},
      # Nur für das Profil "android": überschreibt einzelne Felder von androidDefaults.
      android ? {},
      # Nur für das Profil "sailfish": überschreibt einzelne Felder von sailfishDefaults.
      sailfish ? {}
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      workspacePath = "/workspaces/${name}";
      hasProfile = p: builtins.elem p profiles;
      needsNode = (hasProfile "solid") || (hasProfile "tauri");

      # Profile:
      #   solid       Node, pnpm
      #   playwright  Chromium/Firefox aus Nix plus ihre Bibliotheken
      #   pocketbase  PocketBase, backend/pb_data auf /persist
      #   tauri       Rust-Toolchain, WebKitGTK & Co., Tauri-CLI
      #   rustup      mit tauri: rustup statt der Rust-Toolchain aus Nix (für Cross-Targets wie Android)
      #   desktop     virtueller Bildschirm :99, D-Bus-Session-Werkzeuge, gnome-keyring/libsecret
      #   android     Android-SDK/NDK/Emulator aus Nix, JDK 21, KVM für den Emulator
      #   flatpak     flatpak + flatpak-builder (Flatpak-Dienst und Portal im Gast)
      #   sailfish    Anbindung an das Sailfish SDK auf dem Host: Build-Engine und Emulator
      #               per SSH über 10.0.2.2, das SDK-Verzeichnis read-only unter
      #               /opt/sailfish-sdk; dazu qmllint, Python, RPM-Werkzeuge
      androidDefaults = {
        platformVersions = [ "35" "36" ];
        buildToolsVersion = "36.0.0";
        ndkVersion = "27.2.12479018";
        # Das Emulator-Image; seine Plattform muss in platformVersions stehen.
        systemImagePlatform = "35";
        systemImageType = "google_apis";
        abi = "x86_64";
      };
      androidConfig = androidDefaults // android;

      # Das SDK selbst (Docker-Build-Engine, VirtualBox-Emulator) bleibt auf dem Host;
      # der Gast erreicht dessen 127.0.0.1 über SLiRP als 10.0.2.2.
      sailfishDefaults = {
        engineSshPort = 2222;
        emulatorSshPort = 2223;
      };
      sailfishConfig = sailfishDefaults // sailfish;
      sailfishSdkMount = "/opt/sailfish-sdk";

      vmSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.microvm
          ({ config, lib, pkgs, ... }:
          let
            androidSdk = (pkgs.androidenv.composeAndroidPackages {
              inherit (androidConfig) platformVersions;
              buildToolsVersions = [ androidConfig.buildToolsVersion ];
              includeNDK = true;
              ndkVersions = [ androidConfig.ndkVersion ];
              includeEmulator = true;
              includeSystemImages = true;
              systemImageTypes = [ androidConfig.systemImageType ];
              abiVersions = [ androidConfig.abi ];
            }).androidsdk;
            androidHome = "${androidSdk}/libexec/android-sdk";
          in {
            networking.hostName = hostname;
            system.stateVersion = "24.11";

            assertions = [{
              assertion = !(hasProfile "sailfish")
                || !(builtins.elem sshPort [ sailfishConfig.engineSshPort sailfishConfig.emulatorSshPort ]);
              message = "sshPort ${toString sshPort} gehört auf dem Host schon der Sailfish-Build-Engine bzw. dem Emulator; einen anderen wählen.";
            }];

            # Das Android-SDK steht unter Googles Lizenz und ist unfrei.
            nixpkgs.config = lib.mkIf (hasProfile "android") {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };

            # Der Emulator braucht /dev/kvm im Gast: verschachtelte Virtualisierung,
            # auf dem Host einmal `kvm_intel nested=1` bzw. `kvm_amd nested=1`.
            boot.kernelModules = lib.optionals (hasProfile "android") [ "kvm-intel" "kvm-amd" ];

            microvm = {
              hypervisor = "qemu";
              inherit vcpu mem;

              shares = [
                {
                  proto = "9p";
                  tag = "workspace";
                  source = "./.";
                  mountPoint = workspacePath;
                  securityModel = "none";
                }
                {
                  proto = "9p";
                  tag = "ro-store";
                  source = "/nix/store";
                  mountPoint = "/nix/.ro-store";
                  securityModel = "none";
                }
              ] ++ lib.optional (hasProfile "sailfish") {
                # Ein Symlink, den run-microvm auf das SDK des Hosts setzt: dessen Pfad
                # steht erst zur Laufzeit fest ($SAILFISH_SDK_PATH bzw. .env).
                proto = "9p";
                tag = "sailfish-sdk";
                source = ".microvm-state/sailfish-sdk";
                mountPoint = sailfishSdkMount;
                securityModel = "none";
                readOnly = true;
              };

              volumes = [{
                image = ".microvm-state/persistent.img";
                mountPoint = "/persist";
                size = diskSize;
              }];

              interfaces = [{
                type = "user";
                id = "usernet";
                mac = "02:00:00:00:00:01";
              }];

              forwardPorts = map (p: { from = "host"; host.address = hostAddress; host.port = p.host; guest.port = p.guest; })
                ([ { host = sshPort; guest = 22; } ] ++ (map (p: { host = p; guest = p; }) ports));
            };

            fileSystems."/home/dev" = {
              device = "/persist/home-dev";
              fsType = "none";
              options = [ "bind" "X-mount.mkdir" ];
            };

            users.groups.dev.gid = 1000;
            users.users.dev = {
              isNormalUser = true;
              uid = 1000;
              group = "dev";
              extraGroups = [ "wheel" ] ++ lib.optional (hasProfile "android") "kvm";
              shell = pkgs.bashInteractive;
            };
            security.sudo.wheelNeedsPassword = false;

            # GUI-Programme ohne Bildschirm: ein virtueller auf :99 (DISPLAY steht unten).
            systemd.tmpfiles.rules = lib.optionals (hasProfile "desktop") [ "d /tmp/.X11-unix 1777 root root -" ];
            systemd.services.xvfb = lib.mkIf (hasProfile "desktop") {
              description = "Virtual X display :99";
              wantedBy = [ "multi-user.target" ];
              after = [ "systemd-tmpfiles-setup.service" ];
              serviceConfig = {
                User = "dev";
                ExecStart = "${pkgs.xvfb}/bin/Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp";
                Restart = "on-failure";
              };
            };

            services.flatpak.enable = hasProfile "flatpak";
            xdg.portal = lib.mkIf (hasProfile "flatpak") {
              enable = true;
              extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
              config.common.default = "*";
            };

            services.openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = false;
                X11Forwarding = true;
              };
              authorizedKeysFiles = lib.mkForce [ ".ssh/authorized_keys" ];
            };

            programs.nix-ld = {
              enable = true;
              libraries = with pkgs; [
                stdenv.cc.cc zlib openssl icu libatomic_ops
              ] ++ lib.optionals (hasProfile "playwright") [
                nss nspr cairo pango atk at-spi2-atk cups dbus libdrm mesa
                libxkbcommon alsa-lib glib expat libx11 libxcomposite libxdamage
                libxext libxfixes libxrandr libxcb libxshmfence
                gtk3 gdk-pixbuf libxt libxcursor libxi libxrender
                freetype fontconfig pciutils ffmpeg
              ];
            };

            fonts.packages = lib.optionals (hasProfile "playwright") (with pkgs; [
              dejavu_fonts
              liberation_ttf
              noto-fonts-color-emoji
            ]);

            environment.systemPackages = with pkgs; [
              git git-lfs curl gnupg less procps unzip zip xz bash-completion
              just
            ]
            ++ lib.optionals needsNode [ nodejs pnpm ]
            ++ lib.optionals (hasProfile "pocketbase") [ pocketbase ]
            ++ lib.optionals (hasProfile "playwright") [ playwright-driver.browsers firefox ]
            ++ lib.optionals (hasProfile "tauri") ([
              gcc pkg-config cargo-tauri
              glib glib-networking gtk3 webkitgtk_4_1 libsoup_3 cairo pango gdk-pixbuf atk at-spi2-core
              libappindicator librsvg openssl dbus zlib harfbuzz
            ] ++ (if hasProfile "rustup" then [ rustup ] else [ rustc cargo rustfmt clippy rust-analyzer ]))
            ++ lib.optionals (hasProfile "desktop") [
              xvfb dbus gnome-keyring libsecret desktop-file-utils xdg-utils xorg.xauth
            ]
            ++ lib.optionals (hasProfile "android") [ androidSdk jdk21 ]
            ++ lib.optionals (hasProfile "flatpak") [ flatpak-builder ]
            # Gebaut wird in der Build-Engine (sb2, mb2); hier nur, was der Editor und die
            # Skripte drumherum brauchen. Kein Qt aus Nix zum Bauen: das wäre 5.15, das
            # Target hat 5.6 -- IntelliSense nimmt die Header aus dem SDK-Sysroot.
            ++ lib.optionals (hasProfile "sailfish") [
              openssh rsync python3 gcc gdb rpm file
              qt5.qtdeclarative  # qmllint
            ]
            ++ (extraPackages pkgs);

            environment.sessionVariables = {
              DEVCONTAINER = "true";
              HISTFILE = "/home/dev/.bash_history";
            }
            // lib.optionalAttrs needsNode {
              VITE_HOST = "0.0.0.0";
              VITE_DEV_HOST = "0.0.0.0";
              PNPM_HOME = "/home/dev/.local/share/pnpm";
              PNPM_CONFIG_STORE_DIR = "${workspacePath}/node_modules/.pnpm-store";
            }
            // lib.optionalAttrs (hasProfile "playwright") {
              PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
              PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
              PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
            }
            // lib.optionalAttrs (hasProfile "tauri") {
              PKG_CONFIG_PATH = (lib.makeSearchPathOutput "dev" "lib/pkgconfig" ([
                pkgs.openssl
                pkgs.webkitgtk_4_1
                pkgs.gtk3
                pkgs.libsoup_3
                pkgs.glib
                pkgs.pango
                pkgs.cairo
                pkgs.gdk-pixbuf
                pkgs.at-spi2-core
                pkgs.harfbuzz
                pkgs.librsvg
                pkgs.dbus
                pkgs.zlib
              ] ++ (extraPackages pkgs))) + ":${pkgs.zlib.dev}/share/pkgconfig";
              # Ohne glib-networking kann WebKitGTK kein TLS.
              GIO_EXTRA_MODULES = "${pkgs.glib-networking}/lib/gio/modules";
            }
            // lib.optionalAttrs (hasProfile "desktop") {
              # Kein Accessibility-Bus in der VM: sagen statt GTK in den Timeout laufen lassen.
              NO_AT_BRIDGE = "1";
            }
            // lib.optionalAttrs (hasProfile "android") {
              ANDROID_HOME = androidHome;
              ANDROID_SDK_ROOT = androidHome;
              NDK_HOME = "${androidHome}/ndk/${androidConfig.ndkVersion}";
              ANDROID_NDK_ROOT = "${androidHome}/ndk/${androidConfig.ndkVersion}";
              JAVA_HOME = "${pkgs.jdk21.home}";
              # aapt2 aus Maven ist ein fremdes Binary; das aus dem SDK läuft hier.
              GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${androidConfig.buildToolsVersion}/aapt2";
              # Welches Image ein AVD braucht, für `avdmanager create avd -k "$ANDROID_SYSTEM_IMAGE"`.
              ANDROID_SYSTEM_IMAGE = "system-images;android-${androidConfig.systemImagePlatform};${androidConfig.systemImageType};${androidConfig.abi}";
            }
            // lib.optionalAttrs (hasProfile "sailfish") {
              IN_SAILFISH_SANDBOX = "true";
              SAILFISH_SDK_PATH = sailfishSdkMount;
              # Kopie des SDK-Schlüssels mit Rechten, die ssh akzeptiert (sandbox-setup).
              SAILFISH_SDK_SSH_KEY = "/home/dev/.ssh/sailfish-sdk";
              SAILFISH_ENGINE_HOST = "10.0.2.2";
              SAILFISH_ENGINE_PORT = toString sailfishConfig.engineSshPort;
              SAILFISH_EMULATOR_HOST = "10.0.2.2";
              SAILFISH_EMULATOR_PORT = toString sailfishConfig.emulatorSshPort;
            }
            // extraEnv;

            environment.interactiveShellInit = ''
              export PATH="${workspacePath}/node_modules/.bin:/home/dev/.local/bin:${lib.optionalString (hasProfile "rustup") "/home/dev/.cargo/bin:"}$PATH"
              ${lib.optionalString (hasProfile "desktop") ''
                # SSH X11-Forwarding erhält Vorrang vor dem internen Xvfb :99
                export DISPLAY="''${DISPLAY:-:99}"
              ''}
              alias jump="just"
              alias j="just"
              shopt -s histappend
              export PROMPT_COMMAND="history -a; ''${PROMPT_COMMAND:-}"
              cd ${workspacePath} 2>/dev/null || true
            '';

            systemd.services.sandbox-setup = {
              description = "Prepare Persistent Home, SSH Key, Git Config and Isolated Dirs";
              wantedBy = [ "multi-user.target" ];
              before = [ "sshd.service" ];
              after = [ "local-fs.target" ];
              unitConfig = {
                RequiresMountsFor = [ "/persist" workspacePath "/home/dev" ]
                  ++ lib.optional (hasProfile "sailfish") sailfishSdkMount;
              };
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              path = [ pkgs.gnugrep pkgs.coreutils pkgs.util-linux pkgs.git ];
              script = ''
                mkdir -p /persist/home-dev/.ssh
                ENV_FILE="${workspacePath}/.env"
                rm -f /persist/home-dev/.ssh/authorized_keys

                if [ -f "$ENV_FILE" ]; then
                  PUBKEY=$(grep -E "^[[:space:]]*DEV_SSH_PUBKEY=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d "\r\"'")
                  if [ -n "$PUBKEY" ]; then
                    echo "$PUBKEY" > /persist/home-dev/.ssh/authorized_keys
                    chmod 600 /persist/home-dev/.ssh/authorized_keys
                  fi

                  GIT_NAME=$(grep -E "^[[:space:]]*GIT_USER_NAME=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d "\r\"'")
                  GIT_MAIL=$(grep -E "^[[:space:]]*GIT_USER_EMAIL=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d "\r\"'")
                  if [ -n "$GIT_NAME" ]; then
                    git config --file /persist/home-dev/.gitconfig user.name "$GIT_NAME"
                  fi
                  if [ -n "$GIT_MAIL" ]; then
                    git config --file /persist/home-dev/.gitconfig user.email "$GIT_MAIL"
                  fi
                fi

                git config --file /persist/home-dev/.gitconfig --replace-all safe.directory "${workspacePath}"
                chown 1000:1000 /persist/home-dev/.gitconfig 2>/dev/null || true

                chmod 700 /persist/home-dev/.ssh
                chmod 755 /persist/home-dev
                chown -R 1000:1000 /persist/home-dev

                ${lib.optionalString needsNode ''
                  mkdir -p /persist/node_modules ${workspacePath}/node_modules
                  chown 1000:1000 /persist/node_modules
                  if ! mountpoint -q ${workspacePath}/node_modules; then
                    mount --bind /persist/node_modules ${workspacePath}/node_modules
                  fi
                  chown 1000:1000 ${workspacePath}/node_modules
                ''}

                ${lib.optionalString (hasProfile "pocketbase") ''
                  if [ -d "${workspacePath}/backend" ]; then
                    mkdir -p /persist/pb_data ${workspacePath}/backend/pb_data
                    chown 1000:1000 /persist/pb_data
                    if ! mountpoint -q ${workspacePath}/backend/pb_data; then
                      mount --bind /persist/pb_data ${workspacePath}/backend/pb_data
                    fi
                    chown 1000:1000 ${workspacePath}/backend/pb_data
                  fi
                ''}

                ${lib.optionalString (hasProfile "tauri") ''
                  mkdir -p /persist/cargo-target ${workspacePath}/target
                  chown 1000:1000 /persist/cargo-target
                  if ! mountpoint -q ${workspacePath}/target; then
                    mount --bind /persist/cargo-target ${workspacePath}/target
                  fi
                  chown 1000:1000 ${workspacePath}/target
                ''}

                ${lib.optionalString (hasProfile "sailfish") ''
                  # Über 9p behält der Schlüssel Eigentümer und Rechte des Hosts.
                  install -m 600 -o 1000 -g 1000 ${sailfishSdkMount}/vmshare/ssh/private_keys/sdk \
                    /persist/home-dev/.ssh/sailfish-sdk \
                    || echo "sandbox-setup: kein SDK-Schlüssel unter ${sailfishSdkMount}/vmshare/ssh/private_keys" >&2
                ''}
              '';
            };
          })
        ];
      };
      runner = vmSystem.config.microvm.declaredRunner;
    in
      pkgs.writeShellScriptBin "run-microvm" ''
        mkdir -p .microvm-state
        # Wo das Projekt auf dem Host liegt; der Gast sieht es nur unter ${workspacePath}.
        pwd -P > .microvm-state/host-workspace
        ${nixpkgs.lib.optionalString (hasProfile "sailfish") ''
          sdk="''${SAILFISH_SDK_PATH:-}"
          if [ -z "$sdk" ] && [ -f .env ]; then
            sdk=$(grep -E "^[[:space:]]*SAILFISH_SDK_PATH=" .env | tail -n 1 | cut -d= -f2- | tr -d "\r\"'")
          fi
          sdk="''${sdk:-$HOME/SailfishOS}"
          sdk="''${sdk//\$HOME/$HOME}"
          if [ ! -d "$sdk/vmshare" ]; then
            echo "run-microvm: kein Sailfish SDK unter $sdk -- SAILFISH_SDK_PATH setzen" >&2
            exit 1
          fi
          ln -sfn "$(realpath "$sdk")" .microvm-state/sailfish-sdk
        ''}
        exec ${runner}/bin/microvm-run "$@"
      '';
  };
}

