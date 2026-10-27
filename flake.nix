{
  description = "Central MicroVM sandbox for SolidJS, Rust/Tauri, Android, SailfishOS, Godot & Python/ML";

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
      # Host IP for forwarded ports. Unique 127.0.0.0/8 IPs prevent collisions across VMs. "" binds to all interfaces.
      hostAddress ? "127.0.0.1",
      sshPort ? 2222,
      ports ? [],
      vcpu ? 4,
      mem ? 4096,
      diskSize ? 16384,
      profiles ? [ "solid" ],
      extraPackages ? (pkgs: []),
      extraEnv ? {},
      # Additional NixOS modules, merged into the guest config (e.g. extra nix-ld libraries)
      extraModules ? [],
      # Workspace-relative dirs kept on /persist instead of 9p (like node_modules), e.g. [ ".venv" ]
      persistDirs ? [],
      # Host dirs outside the project, e.g. datasets. Host path from $envVar, then .env, then default.
      #   [{ tag; envVar; mountPoint; default ? ""; readOnly ? true; required ? false; }]
      # Missing optional dirs are mounted as empty dir so the VM still boots.
      hostShares ? [],
      # Overrides for profile defaults
      android ? {},
      sailfish ? {},
      godot ? {},
      nvidia ? {}
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      workspacePath = "/workspaces/${name}";
      hasProfile = p: builtins.elem p profiles;
      needsNode = (hasProfile "solid") || (hasProfile "tauri");

      # Profiles:
      #   solid       Node, pnpm
      #   playwright  Nix browsers + runtime libs
      #   pocketbase  PocketBase, backend/pb_data on /persist
      #   tauri       Rust toolchain, WebKitGTK, Tauri CLI
      #   rustup      Use rustup instead of Nix Rust (for cross-targets like Android)
      #   desktop     Xvfb :99, D-Bus, gnome-keyring/libsecret
      #   android     Android SDK/NDK/Emulator, JDK 21, nested KVM
      #   flatpak     flatpak + flatpak-builder + XDG portal
      #   sailfish    Connects to host Sailfish SDK via SLiRP (10.0.2.2) & read-only /opt/sailfish-sdk mount
      #   godot       Official Godot binary (via nix-ld), Mesa software rendering, .godot/ on /persist
      #   nvidia      VFIO passthrough of a host NVIDIA GPU (exclusive while the VM runs), driver + libcuda via nix-ld
      androidDefaults = {
        platformVersions = [ "35" "36" ];
        buildToolsVersion = "36.0.0";
        ndkVersion = "27.2.12479018";
        systemImagePlatform = "35"; # Must be included in platformVersions
        systemImageType = "google_apis";
        abi = "x86_64";
      };
      androidConfig = androidDefaults // android;

      # SDK runs on the host; guest reaches host 127.0.0.1 via SLiRP at 10.0.2.2
      sailfishDefaults = {
        engineSshPort = 2222;
        emulatorSshPort = 2223;
      };
      sailfishConfig = sailfishDefaults // sailfish;
      sailfishSdkMount = "/opt/sailfish-sdk";

      # Use official release binary to exactly match GitHub export templates
      godotDefaults = {
        version = "4.7.2";
        hash = "sha256-yt0yBOcoo10/E623/Q15AmNrefa5XEDCZetztsNTKeQ=";
      };
      godotConfig = godotDefaults // godot;

      # Host PCI addresses of all functions in the GPU's IOMMU group (GPU + HDMI audio), e.g. "0000:01:00.0".
      # Find them with: lspci -D -nn | grep -i nvidia
      nvidiaDefaults = {
        pciDevices = [];
        # Open kernel modules, required for Blackwell (RTX 50xx) and recommended since Turing
        open = true;
        # Attribute of boot.kernelPackages.nvidiaPackages
        driver = "stable";
      };
      nvidiaConfig = nvidiaDefaults // nvidia;

      hostShareDefaults = { default = ""; readOnly = true; required = false; };
      hostShareList = map (s: hostShareDefaults // s) hostShares;

      vmSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.microvm
        ] ++ extraModules ++ [
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

            # Godot dlopens X11/Wayland/GL/Vulkan/audio libs provided via nix-ld
            godotBin = pkgs.runCommand "godot-${godotConfig.version}" {
              nativeBuildInputs = [ pkgs.unzip ];
              src = pkgs.fetchurl {
                url = "https://github.com/godotengine/godot/releases/download/${godotConfig.version}-stable/Godot_v${godotConfig.version}-stable_linux.x86_64.zip";
                inherit (godotConfig) hash;
              };
            } ''
              unzip -q "$src"
              install -Dm755 Godot_v${godotConfig.version}-stable_linux.x86_64 $out/bin/godot
            '';
          in {
            networking.hostName = hostname;
            system.stateVersion = "24.11";

            nix.settings.experimental-features = [ "nix-command" "flakes" ];

            assertions = [{
              assertion = !(hasProfile "sailfish")
                || !(builtins.elem sshPort [ sailfishConfig.engineSshPort sailfishConfig.emulatorSshPort ]);
              message = "sshPort ${toString sshPort} conflicts with Sailfish build engine or emulator on host.";
            } {
              assertion = !(hasProfile "nvidia") || nvidiaConfig.pciDevices != [];
              message = "Profile nvidia needs nvidia.pciDevices (host PCI addresses of the GPU's IOMMU group).";
            }];

            nixpkgs.config = lib.mkMerge [
              (lib.mkIf (hasProfile "android") {
                allowUnfree = true;
                android_sdk.accept_license = true;
              })
              (lib.mkIf (hasProfile "nvidia") { allowUnfree = true; })
            ];

            # Requires nested virtualization enabled on the host
            boot.kernelModules = lib.optionals (hasProfile "android") [ "kvm-intel" "kvm-amd" ];

            # Mesa software rendering (llvmpipe/lavapipe), also for GL apps on Xvfb / ssh -X
            hardware.graphics.enable = lib.mkDefault (hasProfile "godot" || hasProfile "desktop" || hasProfile "nvidia");

            # Only the kernel module and userspace libs; no X server is started
            services.xserver.videoDrivers = lib.mkIf (hasProfile "nvidia") [ "nvidia" ];
            hardware.nvidia = lib.mkIf (hasProfile "nvidia") {
              inherit (nvidiaConfig) open;
              package = config.boot.kernelPackages.nvidiaPackages.${nvidiaConfig.driver};
              nvidiaSettings = false;
              # Keeps the GPU initialized between CUDA processes in the headless guest
              nvidiaPersistenced = true;
            };

            microvm = {
              hypervisor = "qemu";
              inherit vcpu mem;

              # q35 instead of the microvm machine: PCIe root complex with room for large GPU BARs
              qemu.machine = lib.mkIf (hasProfile "nvidia") "q35";
              devices = lib.optionals (hasProfile "nvidia") (map (path: { bus = "pci"; inherit path; }) nvidiaConfig.pciDevices);

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
                # Symlink created at runtime by run-microvm
                proto = "9p";
                tag = "sailfish-sdk";
                source = ".microvm-state/sailfish-sdk";
                mountPoint = sailfishSdkMount;
                securityModel = "none";
                readOnly = true;
              } ++ map (s: {
                # Symlink created at runtime by run-microvm
                proto = "9p";
                inherit (s) tag mountPoint readOnly;
                source = ".microvm-state/shares/${s.tag}";
                securityModel = "none";
              }) hostShareList;

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
                # Common C libs for Python wheels & Node native addons
                glib libxml2 libxslt sqlite libffi xz bzip2 zstd
              ] ++ lib.optionals (hasProfile "playwright") [
                nss nspr cairo pango atk at-spi2-atk cups dbus libdrm mesa
                libxkbcommon alsa-lib glib expat libx11 libxcomposite libxdamage
                libxext libxfixes libxrandr libxcb libxshmfence
                gtk3 gdk-pixbuf libxt libxcursor libxi libxrender
                freetype fontconfig pciutils ffmpeg
              ] ++ lib.optionals (hasProfile "godot") [
                libx11 libxcursor libxext libxi libxinerama libxrandr libxrender libxkbcommon
                libGL vulkan-loader wayland libdecor
                alsa-lib libpulseaudio dbus fontconfig udev
              ] ++ lib.optionals (hasProfile "nvidia") [
                # libcuda.so.1 / libnvidia-ml.so.1 for pip wheels (PyTorch ships its own CUDA runtime)
                config.hardware.nvidia.package
              ];
            };

            fonts.packages = lib.optionals (hasProfile "playwright") (with pkgs; [
              dejavu_fonts
              liberation_ttf
              noto-fonts-color-emoji
            ]);

            environment.systemPackages = with pkgs; [
              python3 uv nodejs pnpm
              bash-completion
              curl diffutils file gcc git git-lfs gnumake fd fzf gnupg jq less patch pkg-config procps ripgrep sqlite tree unzip wget which xz zip
              just mise
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
              xvfb dbus gnome-keyring libsecret desktop-file-utils xdg-utils xauth
            ]
            ++ lib.optionals (hasProfile "android") [ androidSdk jdk21 ]
            ++ lib.optionals (hasProfile "flatpak") [ flatpak-builder ]
            ++ lib.optionals (hasProfile "godot") [ godotBin vulkan-tools mesa-demos ]
            # Builds happen in the SDK build engine; headers come from SDK sysroot
            ++ lib.optionals (hasProfile "sailfish") [
              openssh rsync python3 gcc gdb rpm file
              qt5.qtdeclarative # qmllint
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
              # Required for WebKitGTK TLS support
              GIO_EXTRA_MODULES = "${pkgs.glib-networking}/lib/gio/modules";
            }
            // lib.optionalAttrs (hasProfile "desktop") {
              # Prevent GTK timeouts waiting for non-existent accessibility bus
              NO_AT_BRIDGE = "1";
            }
            // lib.optionalAttrs (hasProfile "android") {
              ANDROID_HOME = androidHome;
              ANDROID_SDK_ROOT = androidHome;
              NDK_HOME = "${androidHome}/ndk/${androidConfig.ndkVersion}";
              ANDROID_NDK_ROOT = "${androidHome}/ndk/${androidConfig.ndkVersion}";
              JAVA_HOME = "${pkgs.jdk21.home}";
              # Force Gradle to use Nix SDK's patched aapt2 instead of Maven binary
              GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${androidConfig.buildToolsVersion}/aapt2";
              ANDROID_SYSTEM_IMAGE = "system-images;android-${androidConfig.systemImagePlatform};${androidConfig.systemImageType};${androidConfig.abi}";
            }
            // lib.optionalAttrs (hasProfile "sailfish") {
              IN_SAILFISH_SANDBOX = "true";
              SAILFISH_SDK_PATH = sailfishSdkMount;
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
                # Prefer SSH X11 forwarding over internal Xvfb :99
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

                ${lib.optionalString (hasProfile "godot") ''
                  # Keep import cache off 9p for performance and version isolation
                  mkdir -p /persist/godot-cache ${workspacePath}/.godot
                  chown 1000:1000 /persist/godot-cache
                  if ! mountpoint -q ${workspacePath}/.godot; then
                    mount --bind /persist/godot-cache ${workspacePath}/.godot
                  fi
                  chown 1000:1000 ${workspacePath}/.godot
                ''}

                ${lib.concatMapStrings (d: ''
                  mkdir -p "/persist/dirs/${d}" "${workspacePath}/${d}"
                  chown 1000:1000 "/persist/dirs/${d}"
                  if ! mountpoint -q "${workspacePath}/${d}"; then
                    mount --bind "/persist/dirs/${d}" "${workspacePath}/${d}"
                  fi
                  chown 1000:1000 "${workspacePath}/${d}"
                '') persistDirs}

                ${lib.optionalString (hasProfile "sailfish") ''
                  # Copy SDK key from 9p share to enforce strict SSH permissions
                  install -m 600 -o 1000 -g 1000 ${sailfishSdkMount}/vmshare/ssh/private_keys/sdk \
                    /persist/home-dev/.ssh/sailfish-sdk \
                    || echo "sandbox-setup: missing SDK key in ${sailfishSdkMount}/vmshare/ssh/private_keys" >&2
                ''}
              '';
            };
          })
        ];
      };
      runner = vmSystem.config.microvm.declaredRunner;
      lib = nixpkgs.lib;

      # Host side, run as root: hands the GPU to vfio-pci and back. Not needed for non-GPU profiles.
      gpuScript = pkgs.writeShellScriptBin "microvm-gpu" ''
        set -euo pipefail
        user="''${SUDO_USER:-$(id -un)}"
        case "''${1:-}" in
          bind)
            ${pkgs.kmod}/bin/modprobe vfio-pci
            ${lib.concatMapStrings (dev: ''
              cd /sys/bus/pci/devices/${dev}
              if [ "$(basename "$(readlink -f driver 2>/dev/null)")" != vfio-pci ]; then
                [ -e driver ] && echo ${dev} > driver/unbind
                echo vfio-pci > driver_override
                echo ${dev} > /sys/bus/pci/drivers_probe
              fi
              group=$(basename "$(readlink iommu_group)")
              for member in iommu_group/devices/*; do
                case " ${toString nvidiaConfig.pciDevices} " in
                  *" $(basename "$member") "*) ;;
                  *) echo "microvm-gpu: $(basename "$member") shares IOMMU group $group, add it to nvidia.pciDevices" >&2 ;;
                esac
              done
              chown "$user" /dev/vfio/"$group"
              echo "${dev} -> vfio-pci (/dev/vfio/$group for $user)"
            '') nvidiaConfig.pciDevices}
            ;;
          release)
            ${lib.concatMapStrings (dev: ''
              cd /sys/bus/pci/devices/${dev}
              [ -e driver ] && echo ${dev} > driver/unbind
              echo > driver_override
              echo ${dev} > /sys/bus/pci/drivers_probe
              if [ -e driver ]; then echo "${dev} -> $(basename "$(readlink -f driver)")"; else echo "${dev} -> no driver"; fi
            '') nvidiaConfig.pciDevices}
            ;;
          *)
            echo "usage: sudo microvm-gpu bind|release   (stop all host GPU users before bind, e.g. nvidia-persistenced)" >&2
            exit 1
            ;;
        esac
      '';

      runScript = pkgs.writeShellScriptBin "run-microvm" ''
        mkdir -p .microvm-state
        # Record host project path (guest only sees ${workspacePath})
        pwd -P > .microvm-state/host-workspace
        ${lib.concatMapStrings (s: ''
          src="''${${s.envVar}:-}"
          if [ -z "$src" ] && [ -f .env ]; then
            src=$(grep -E "^[[:space:]]*${s.envVar}=" .env | tail -n 1 | cut -d= -f2- | tr -d "\r\"'")
          fi
          src="''${src:-${s.default}}"
          src="''${src//\$HOME/$HOME}"
          link=.microvm-state/shares/${s.tag}
          mkdir -p .microvm-state/shares
          if [ -L "$link" ]; then rm "$link"; elif [ -d "$link" ]; then rmdir "$link"; fi
          if [ -n "$src" ] && [ -d "$src" ]; then
            ln -s "$(realpath "$src")" "$link"
          ${if s.required then ''
          else
            echo "run-microvm: ${s.tag} not found at '$src' -- set ${s.envVar}" >&2
            exit 1
          '' else ''
          else
            echo "run-microvm: ${s.tag} not found at '$src' (${s.envVar}), mounting an empty dir" >&2
            mkdir "$link"
          ''}
          fi
        '') hostShareList}
        ${lib.optionalString (hasProfile "nvidia") ''
          for dev in ${toString nvidiaConfig.pciDevices}; do
            if [ "$(basename "$(readlink -f /sys/bus/pci/devices/$dev/driver 2>/dev/null)")" != vfio-pci ]; then
              echo "run-microvm: $dev is not bound to vfio-pci -- run: sudo ${gpuScript}/bin/microvm-gpu bind" >&2
              exit 1
            fi
          done
          # VFIO pins all guest RAM
          if [ "$(ulimit -l)" != unlimited ] && [ "$(ulimit -l)" -lt $((${toString mem} * 1024)) ]; then
            echo "run-microvm: memlock limit $(ulimit -l) KiB < ${toString mem} MiB guest RAM -- raise it (limits.conf / ulimit -l)" >&2
            exit 1
          fi
        ''}
        ${lib.optionalString (hasProfile "sailfish") ''
          sdk="''${SAILFISH_SDK_PATH:-}"
          if [ -z "$sdk" ] && [ -f .env ]; then
            sdk=$(grep -E "^[[:space:]]*SAILFISH_SDK_PATH=" .env | tail -n 1 | cut -d= -f2- | tr -d "\r\"'")
          fi
          sdk="''${sdk:-$HOME/SailfishOS}"
          sdk="''${sdk//\$HOME/$HOME}"
          if [ ! -d "$sdk/vmshare" ]; then
            echo "run-microvm: Sailfish SDK not found at $sdk -- set SAILFISH_SDK_PATH" >&2
            exit 1
          fi
          ln -sfn "$(realpath "$sdk")" .microvm-state/sailfish-sdk
        ''}
        exec ${runner}/bin/microvm-run "$@"
      '';
    in
      if hasProfile "nvidia" then
        pkgs.symlinkJoin {
          name = "run-microvm";
          paths = [ runScript gpuScript ];
          meta.mainProgram = "run-microvm";
        }
      else runScript;
  };
}
