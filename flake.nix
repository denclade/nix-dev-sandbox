{
  description = "Zentrale MicroVM Sandbox für SolidJS, Rust/Tauri & SailfishOS";

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
      sshPort ? 2222,
      ports ? [],
      vcpu ? 4,
      mem ? 4096,
      diskSize ? 16384,
      profiles ? [ "solid" ],
      extraPackages ? (pkgs: []),
      extraEnv ? {}
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      workspacePath = "/workspaces/${name}";
      hasProfile = p: builtins.elem p profiles;
      needsNode = (hasProfile "solid") || (hasProfile "tauri");

      vmSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.microvm
          ({ config, lib, pkgs, ... }: {
            networking.hostName = hostname;
            system.stateVersion = "24.11";

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
              ];

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

              forwardPorts = [
                { from = "host"; host.port = sshPort; guest.port = 22; }
              ] ++ (map (p: { from = "host"; host.port = p; guest.port = p; }) ports);
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
              extraGroups = [ "wheel" ];
              shell = pkgs.bashInteractive;
            };
            security.sudo.wheelNeedsPassword = false;

            services.openssh = {
              enable = true;
              settings.PasswordAuthentication = false;
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
            ++ lib.optionals (hasProfile "playwright") [ playwright-driver.browsers ]
            ++ lib.optionals (hasProfile "tauri") [
              rustc cargo rustfmt clippy rust-analyzer pkg-config cargo-tauri
              glib gtk3 webkitgtk_4_1 libsoup_3 cairo pango gdk-pixbuf atk
              libappindicator librsvg openssl
            ]
            ++ lib.optionals (hasProfile "sailfish") [
              cmake ninja gcc gdb pkg-config rpm
              qt5.qtbase qt5.qtdeclarative qt5.qtquickcontrols2 qt5.qttools
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
              PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.webkitgtk_4_1.dev}/lib/pkgconfig:${pkgs.gtk3.dev}/lib/pkgconfig:${pkgs.libsoup_3.dev}/lib/pkgconfig";
            }
            // extraEnv;

            environment.interactiveShellInit = ''
              export PATH="${workspacePath}/node_modules/.bin:/home/dev/.local/bin:$PATH"
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
                RequiresMountsFor = [ "/persist" workspacePath "/home/dev" ];
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
              '';
            };
          })
        ];
      };
      runner = vmSystem.config.microvm.declaredRunner;
    in
      pkgs.writeShellScriptBin "run-microvm" ''
        mkdir -p .microvm-state
        exec ${runner}/bin/microvm-run "$@"
      '';
  };
}
