# MicroVM Dev Sandbox

Central Nix Flake for isolated QEMU MicroVM development environments. The project directory is shared via 9p to `/workspaces/<name>`. Heavy directories (`node_modules`, `target`, `.godot`, `pb_data`) and `/home/dev` are bind-mounted onto a persistent image (`.microvm-state/persistent.img`) to avoid 9p performance overhead.

## Usage in Project Flake

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sandbox.url = "git+ssh://git@example.com/org/dev-sandbox.git";
  };

  outputs = { self, nixpkgs, sandbox }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system}.default = sandbox.lib.mkDevSandbox {
      name = "project-alpha";
      hostAddress = "127.0.10.13";
      sshPort = 2200;
      ports = [ 3000 8090 ];
      profiles = [ "solid" "pocketbase" "playwright" ];
    };
  };
}
```

Run the sandbox from the project root:

```bash
# optional: update flake
nix flake update
nix run
```

## Environment Setup (`.env`)

On startup, the VM reads `.env` from the project workspace to configure access and Git identity:

```ini
DEV_SSH_PUBKEY="ssh-ed25519 AAAA..."
GIT_USER_NAME="Jane Doe"
GIT_USER_EMAIL="jane@example.com"
SAILFISH_SDK_PATH="/home/user/SailfishOS" # Optional: only for sailfish profile
```

## Profiles & Host Requirements

| Profile | Included Tools & Behavior | Host / Runtime Requirements |
| :--- | :--- | :--- |
| `solid` | Node.js, pnpm (`node_modules` persisted) | - |
| `pocketbase` | PocketBase (`backend/pb_data` persisted) | - |
| `playwright` | Nix browsers (`chromium`, `firefox`) + system libs | - |
| `tauri` | Rust toolchain, WebKitGTK, `cargo-tauri` (`target` persisted) | - |
| `rustup` | Replaces Nix Rust with `rustup` (use with `tauri` for cross-targets) | - |
| `desktop` | `Xvfb` on `:99`, D-Bus, keyring (`ssh -X` takes precedence over `:99`) | X11 Server on host for `ssh -X` |
| `android` | Android SDK/NDK, Emulator, JDK 21 | Nested KVM enabled (`kvm_intel`/`kvm_amd` `nested=1`) |
| `flatpak` | `flatpak`, `flatpak-builder`, XDG GTK portal | - |
| `sailfish` | `qmllint`, RPM/SSH tools, SDK mounted RO at `/opt/sailfish-sdk` | Sailfish SDK (Docker build engine / VBox emulator) running on host |
| `godot` | Official Godot binary (via `nix-ld`), Mesa software rendering (`.godot` persisted) | Combine with `desktop` for GUI via `ssh -X` or headless Xvfb |

### Notes on Specific Profiles

* **SailfishOS (`sailfish`):** The SDK itself remains on the host. `run-microvm` symlinks the host's `$SAILFISH_SDK_PATH` (defaults to `~/SailfishOS`) into `.microvm-state/sailfish-sdk` and mounts it read-only at `/opt/sailfish-sdk`. The guest connects to the host's build engine (default port `2222`) and emulator (default port `2223`) via SLiRP gateway `10.0.2.2`. Ensure the VM's `sshPort` does not collide with the SDK ports.
* **Godot (`godot`):** Uses the official upstream release binary instead of nixpkgs to guarantee matching hashes with official GitHub export templates. Renders via Mesa `llvmpipe`/`lavapipe` (no GPU passthrough required).
* **Android (`android`):** Automatically overrides Gradle's Maven `aapt2` with the Nix SDK binary via `GRADLE_OPTS`.

## Network & SSH Configuration

Assigning unique loopback addresses from `127.0.0.0/8` via `hostAddress` allows running multiple VMs simultaneously on identical ports without collisions.

Add to `~/.ssh/config` on the host:

```sshconfig
Host project-alpha-vm
    HostName 127.0.10.13
    Port 2200

Host project-beta-vm
    HostName 127.0.10.14
    Port 2200

Host *-vm
    HostName 127.0.0.1
    Port 2200
    User dev
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    IdentityFile ~/.ssh/id_ed25519
    ConnectTimeout 5
    ForwardX11 yes
    ForwardX11Trusted yes
```