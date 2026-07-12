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

**labwc-session wrapper (`initial_session.command`):**
The `initial_session` does NOT launch labwc directly. It launches a
`labwc-session` shell script that:
1. Starts user services with `--no-block` (avoids deadlock since labwc
   creates the Wayland socket moments later): `noctalia.service`,
   `polkit-gnome.service`, `voxtype.service`, `noctalia-labwc-sync.service`.
2. Then `exec labwc`.

This means services that depend on `graphical-session.target` are started
immediately rather than when labwc sets up the session — the `--no-block`
flag is crucial to prevent systemd waiting for the Wayland socket before
labwc has created it.

User services with Wayland socket wait loops (polkit-gnome, voxtype, noctalia)
use an `ExecStartPre` helper (`waitForWayland` in the let block)
to poll for `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` before starting,
preventing the "cannot open display" / "no peercred" failures.

The config is at `/etc/nixos/configuration.nix`. Relevant sections:
- `services.greetd` — greetd display manager configuration
- `systemd.user.services.polkit-gnome` — depends on graphical-session.target + socket wait
- `systemd.user.services.voxtype` — depends on graphical-session.target + socket wait
- `systemd.user.services.noctalia` — ExecStartPre socket wait
- `systemd.user.services.noctalia-labwc-sync` — ExecStart + ExecStartPost

# Flake structure

- **`flake.nix`**: 3 inputs — `nixpkgs` (unstable), `noctalia` (cachix branch),
  `noctalia-labwc-color-sync` (non-flake). Single `nixos` config for `x86_64-linux`.
  `noctalia-labwc-color-sync` passed via `specialArgs`. Dev shell provides
  `nixpkgs-fmt` + `nixos-rebuild`. Formatter: `nixpkgs-fmt`.
- **`configuration.nix`**: 366 lines. Includes `./hardware-configuration.nix`
  (not in repo — must be generated per-machine via `nixos-generate-config`).

## Flake operations

### Rebuild

```bash
echo "password" | sudo -S nixos-rebuild switch --flake /etc/nixos#nixos --accept-flake-config
```

`--accept-flake-config` is needed to trust the `noctalia.cachix.org` binary cache
setting from `flake.nix`'s `nixConfig`.

### Check for updates & metadata

```bash
nix flake metadata    # show current lock state, from /etc/nixos
nix flake update      # update flake.lock to latest (no output = already up to date)
nixos-rebuild list-generations | tail -5   # show recent system generations
```

### Nix optimizations

Configured in `configuration.nix`:
- `nix.settings.auto-optimise-store = true` — deduplicates store at build time.
- `nix.gc.automatic = true`, `weekly`, `--delete-old --delete-older-than 7d`.
- `nix.settings.experimental-features = [ "nix-command" "flakes" ]`.

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
- **systemd integration:** `systemd.enable = true`; `ExecStartPre` waits for Wayland socket.
- **User session services started by `labwc-session`:** `noctalia.service` launched
  immediately at login (not via `graphical-session.target`).

# Voxtype (voice-to-text daemon)

Configured declaratively in `configuration.nix` as a systemd user service:
- **Hotkey:** Right Alt (tap to record, tap again to transcribe + type).
- **Whisper model:** `ggml-base.bin` (~142 MB, multilingual, fetched at build from
  HuggingFace with a pinned hash). Language: auto-detect.
- **Config:** Declarative TOML at `/etc/voxtype/config.toml` (generated at build via
  `pkgs.formats.toml`). Output mode: type (direct keyboard emulation), fallback to clipboard.
- **Notifications:** Only on transcription (no record-start/stop notifications).
- **OSD:** Disabled.
- **Service deps:** `graphical-session.target`, `pipewire.service`, `pipewire-pulse.service`.
- **ExecStartPre:** `waitForWayland` socket poll.
- **ExecStart:** `${pkgs.voxtype-vulkan}/bin/voxtype` (Vulkan-accelerated).
- **Restart:** on-failure, 5s delay.
- **XDG_CONFIG_HOME:** set to `/etc` so it reads the declarative config.
- **Package:** `voxtype-vulkan` + `vulkan-loader` in `environment.systemPackages`.

# Polkit-gnome (auth agent)

Systemd user service, `Type=simple`, restart on-failure (3s).
- Depends on / binds to `graphical-session.target`.
- `ExecStartPre`: `waitForWayland` socket poll.
- `ExecStart`: `${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1`.

# Kernel parameters & hardware tuning

Configured in `configuration.nix` via `boot.kernelParams`:

- **`amdgpu.runpm=0`** — disables AMD GPU runtime power management.
  Fixes "AMD PSP LOAD_TA" firmware errors on some AMD GPUs.
- **`spectre_v2=on`** — enables STIBP/Spectre v2 mitigation.
  Relevant for VMSCAPE / multi-tenant workloads.
- **`systemd.unified_cgroup_hierarchy=1`** — forces cgroup v2 (unified hierarchy).

Bootloader: **Limine** (not systemd-boot). `boot.loader.efi.canTouchEfiVariables = true`.
Kernel: `linuxPackages_7_1` (matching NixOS 26.11).
Boot temps: `tmpfs` on `/tmp`, 2 GB size.

# AMD CPU & GPU

- **AMD microcode:** `hardware.cpu.amd.updateMicrocode = true`.
- **AMD graphics:** `hardware.graphics.enable = true`.
- **amdgpu.runpm=0** kernel param (see above).

# ZRAM (compressed RAM swap)

```nix
zramSwap = {
  enable = true;
  memoryPercent = 50;
  algorithm = "zstd";
};
```
50% of physical RAM, zstd compression. No disk swap configured (swapDevice is commented out).

# Audio (PipeWire)

Configured:
```nix
services.pipewire = {
  enable = true;
  alsa.enable = true;
  alsa.support32Bit = true;
  pulse.enable = true;
  wireplumber.enable = true;
};
security.rtkit.enable = true;
```
Full ALSA + PulseAudio compatibility. WirePlumber as session manager. rtkit for real-time
audio scheduling.

# XDG Desktop Portals

```nix
xdg.portal = {
  enable = true;
  extraPortals = [ pkgs.xdg-desktop-portal-wlr pkgs.xdg-desktop-portal-gtk ];
  configPackages = [ pkgs.labwc ];
  config.common = {
    default = [ "wlr" ];
    "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
    "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
  };
};
```
Screenshot and screencast routed through `xdg-desktop-portal-wlr` for Wayland-native
screen sharing.

# GNOME Keyring & desktop services

- **GNOME Keyring:** `services.gnome.gnome-keyring.enable = true`.
- **gvfs:** `services.gvfs.enable = true` (trash, mounts for Nautilus).
- **udisks2:** `services.udisks2.enable = true` (removable media).
- **DConf:** `programs.dconf.enable = true`.

# Bluetooth

```nix
hardware.bluetooth = {
  enable = true;
  powerOnBoot = false;
};
```
Adapter powers on automatically when needed (no forced power-on at boot).

# Power management

- **power-profiles-daemon:** enabled.
- **upower:** enabled.
- **Lid switch:** suspend (`HandleLidSwitch = suspend`).
- **fstrim:** enabled (weekly SSD TRIM).
- **ZRAM:** 50% zstd (already covered above).

# Labwc keybindings (rc.xml)

Defined in `/etc/labwc/rc.xml` (deployed via `environment.etc`):

| Key | Action |
|---|---|
| `W-Return` | Launch kitty |
| `W-w` | Close window |
| `W-Space` | Noctalia launcher panel |
| `W-S-w` | Noctalia session panel |
| `W-Up` / `W-Down` | Toggle maximize |
| `W-[1-4]` | Go to desktop N |
| `C-W-Left` / `C-W-Right` | Previous/next desktop |
| `W-S-Left` / `W-S-Right` | Send window to desktop |
| `W-A-r` | `labwc --reconfigure` |
| `Print` | Screenshot: grim+slurp → satty clipboard |
| `W-n` | Enable wlsunset night light (2500K) |
| `W-S-n` | Disable wlsunset |
| `A-1..5` / `A-e` | OBS scene switch |
| `A-r` | OBS recording toggle |
| `XF86AudioPlay/Pause` | playerctl play-pause |

Touchpad: tap-and-drag, drag-lock, natural scroll (no three-finger drag).
Desktop: 4 virtual desktops, multi-monitor (DP-2: desktops 1-2, eDP-1: 3-4).

# Wayland: no XWayland

`programs.xwayland.enable = false`. Pure Wayland session — all apps must support
Wayland natively (labwc, kitty, Noctalia, Nautilus, etc.).

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
  `~/.config/labwc/themerc-override` with WCAG contrast-guaranteed colors.
- `noctalia-labwc-reconfigure` — calls `labwc --reconfigure`.
- Systemd user units (`noctalia-labwc-sync.service`, `noctalia-labwc-sync.path`)
  installed under `$out/lib/systemd/user/`, available when package is in
  `environment.systemPackages`.
- The service unit is **directly defined** in `configuration.nix` (not auto-enabled):
  ```nix
  systemd.user.services.noctalia-labwc-sync = {
    path = [ pkgs.labwc ];
    serviceConfig = {
      ExecStart = [ "" "${noctaliaColorSyncPkg}/bin/noctalia-labwc-theme-sync" ];
      ExecStartPost = [ "" "${noctaliaColorSyncPkg}/bin/noctalia-labwc-reconfigure" ];
    };
  };
  ```
  The path unit watches `~/.local/state/noctalia/settings.toml` and triggers
  sync on every theme/mode change. Enable with:
  ```bash
  systemctl --user enable --now noctalia-labwc-sync.path
  ```
- `ExecStartPost` ensures `labwc --reconfigure` runs **after** the theme override is written.
- Dependencies: Python 3.11+ (stdlib only), `noctalia` CLI, `labwc`.

# Compose key on Caps Lock

Configured via two mechanisms:
1. `environment.sessionVariables = { XKB_DEFAULT_OPTIONS = "compose:caps"; }` in
   `configuration.nix` — picked up by labwc (Wayland-native, no X11 dependency).
2. `/etc/labwc/environment` (deployed via `environment.etc`) contains
   `XKB_DEFAULT_OPTIONS=compose:caps` as a fallback for the labwc session.
