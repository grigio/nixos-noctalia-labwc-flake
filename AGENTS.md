# System doc for agents — keep updated with non-trivial short system info


# System Password

The system password is `password`.

# Operating System & Process Structure

This system runs **NixOS 26.11 (Zokor)** with Linux kernel `7.1.3` on `x86_64`. The OS is
built declaratively via the Nix package manager (`nix-daemon` runs as root). The session
manager is **labwc** (a Wayland compositor), running on **kitty** terminal emulator.
Key background services include **systemd** (init, journald, udevd, timesyncd),
**NetworkManager**, **wireplumber** (audio session manager), **pipewire** (audio server),
and **xdg-desktop-portal** (desktop integration). At the time of profiling, the most
memory-intensive user process is **opencode** itself (~705MB RSS, 10% of 16GB),
followed by **noctalia** (~160MB), **kitty** (~131MB), **labwc** (~115MB), and
**voxtype** (~110MB). All userland binaries are sourced from the Nix store under
`/nix/store/...`, confirming a fully immutable, reproducible system root.

# Display manager & session startup

Labwc is launched by **greetd** via `initial_session`:
the display manager auto-logs user `g` into `labwc`
on VT1. A fallback greeter is configured as `default_session`
for manual login if `initial_session` is removed.

**greetd + Wayland greeter (gotcha, fixed):**
`greetd-mini-wl-greeter` is a Wayland *client*, NOT a standalone
compositor, and renders a blank/unusable screen — avoid it.
Use **`tuigreet`** (a TUI greeter that runs directly on the tty,
no compositor needed) as the `default_session`:
```nix
default_session = {
  command = "${pkgs.tuigreet}/bin/tuigreet --time --asterisks --remember --greeting 'Welcome to NixOS' --greet-align center --window-padding 1 --container-padding 4 --prompt-padding 1 --power-shutdown 'loginctl poweroff' --power-reboot 'loginctl reboot' --theme ${greeterTheme} --cmd ${pkgs.labwc}/bin/labwc";
  user = "greeter";
};
```
`--cmd` tells tuigreet what to launch after login (here: `labwc`).
`greeterTheme` is a `pkgs.writeText "tuigreet-theme.toml"` TOML
color theme defined in the `let` block (no `--date` flag in 0.9.1;
`--time` already shows date+time). The greeter runs as user `greeter`
(in `video`/`input` groups).
Do NOT use `cage`+`greetd-mini-wl-greeter` — it shows a blank screen
and never accepts input.

User services with Wayland socket wait loops (polkit-gnome, voxtype)
use an `ExecStartPre` helper (`waitForWayland` in the let block)
to poll for `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` before starting,
preventing the "cannot open display" / "no peercred" failures.

The config is at `/etc/nixos/configuration.nix`. Relevant sections:
- `services.greetd` — greetd display manager configuration
- `systemd.user.services.polkit-gnome` — depends on graphical-session.target + socket wait
- `systemd.user.services.voxtype` — depends on graphical-session.target + socket wait

# Flake operations

## Rebuild

```bash
echo "password" | sudo -S nixos-rebuild switch --flake /etc/nixos#nixos --accept-flake-config
```

`--accept-flake-config` is needed to trust the `noctalia.cachix.org` binary cache
setting from `flake.nix`'s `nixConfig`.

## Check for updates & metadata

```bash
nix flake metadata    # show current lock state, from /etc/nixos
nix flake update      # update flake.lock to latest (no output = already up to date)
nixos-rebuild list-generations | tail -5   # show recent system generations
```

# Noctalia (from flake + binary cache)

Noctalia v5 is pinned via flake input in `/etc/nixos/flake.nix`:
- **Source:** `github:noctalia-dev/noctalia/cachix` — the `cachix` branch always
  points to the latest commit that has already been cached upstream.
- **Binary cache:** `https://noctalia.cachix.org` (key `noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=`)
  configured in both `flake.nix`'s `nixConfig` and `configuration.nix`'s `nix.settings`.
- **Cache requirement:** The `noctalia` input deliberately does **not** follow
  `nixpkgs` — following would change the derivation hash and cause cache misses.
- **NixOS module:** Imported via `noctalia.nixosModules.default` in the flake
  outputs. The `programs.noctalia` block in `configuration.nix` sets
  `enable = true` + `recommendedServices.enable = true`.

# Nautilus missing icons (e.g. Trash)

Add `adwaita-icon-theme` and `gsettings-desktop-schemas` to
`environment.systemPackages`, add `"/share/icons"` to
`environment.pathsToLink`, then `nixos-rebuild switch` and
`dconf write /org/gnome/desktop/interface/icon-theme "'Adwaita'"`.

# NixOS generation cleanup & bootloader

To remove old NixOS generations (keep last N):
```bash
echo "password" | sudo -S nix-env --delete-generations +N -p /nix/var/nix/profiles/system
echo "password" | sudo -S nix-collect-garbage
```

`--delete-generations +N` keeps the last N generations. After cleanup,
rebuild the bootloader so old entries disappear from the menu:
```bash
echo "password" | sudo -S nixos-rebuild boot
```

Bootloader is **Limine** (not systemd-boot).

# noctalia-labwc-color-sync

Pinned as flake input (`github:grigio/noctalia-labwc-color-sync`, `flake = false`)
in `flake.nix` and installed via `pkgs.callPackage` into `environment.systemPackages`.
Provides:
- `noctalia-labwc-theme-sync` — reads Noctalia's active palette and generates
  `~/.config/labwc/themerc-override` with WCAG contrast-guaranteed colors, then calls
  `labwc --reconfigure`.
- `noctalia-labwc-reconfigure` — calls `labwc --reconfigure`.
- Systemd user units (`noctalia-labwc-sync.service`, `noctalia-labwc-sync.path`)
  installed under `$out/lib/systemd/user/`, available when package is in
  `environment.systemPackages`. Enable with:
  ```bash
  systemctl --user enable --now noctalia-labwc-sync.path
  ```
  The path unit watches `~/.local/state/noctalia/settings.toml` and triggers
  sync on every theme/mode change.

Dependencies: Python 3.11+ (stdlib only), `noctalia` CLI, `labwc`.

# Compose key on Caps Lock

Configured via `environment.sessionVariables = { XKB_DEFAULT_OPTIONS = "compose:caps"; }` in `/etc/nixos/configuration.nix`. Wayland-native — labwc picks it up from the env var, no X11 dependency.
