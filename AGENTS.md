# System doc for agents — keep updated with non-trivial short system info

# Operating System & Process Structure

This system runs **NixOS** (latest stable). All userland binaries are sourced from
the Nix store under `/nix/store/...`, confirming a fully immutable, reproducible system root.
The session manager is **labwc** (a Wayland compositor), running on **alacritty** terminal
emulator. Key background services include **systemd** (init, journald, udevd, timesyncd),
**NetworkManager**, **wireplumber** (audio session manager), **pipewire** (audio server),
and **xdg-desktop-portal** (desktop integration).

**Notable:**
- Bootloader: **Limine** (EFI removable).
- **OOMD:** active, with user-slice monitoring.
- **tmpfs on /tmp:** 2GB.
- **No XWayland** (attempted at policy level, but labwc 0.20.1 starts it anyway).

# Display manager & session startup

Labwc is launched by **greetd** via `initial_session`:
the display manager auto-logs user `g` into `labwc`
on VT1. A fallback greeter is configured as `default_session`
for manual login if `initial_session` fails.

**greetd + Wayland greeter (gotcha, fixed):**
\`greetd-mini-wl-greeter\` is a Wayland *client*, NOT a standalone
compositor, and renders a blank/unusable screen — avoid it.
Use **`tuigreet`** (a TUI greeter that runs directly on the tty,
no compositor needed) as the `default_session`:
```nix
default_session = {
  command = "${pkgs.tuigreet}/bin/tuigreet --time --asterisks --remember --greeting 'Welcome to NixOS' --greet-align center --window-padding 1 --container-padding 4 --prompt-padding 1 --power-shutdown 'loginctl poweroff' --power-reboot 'loginctl reboot' --theme ${greeterTheme} --cmd ${labwcSession}";
  user = "greeter";
};
```
`--cmd` tells tuigreet what to launch after login. **Must use `${labwcSession}`, not bare labwc** —
otherwise user services (noctalia, voxtype, polkit-gnome) are never started.
`greeterTheme` is a `pkgs.writeText "tuigreet-theme.toml"` TOML
color theme defined in the `let` block. The greeter runs as user `greeter`
(in `video`/`input` groups).
Do NOT use `cage`+`greetd-mini-wl-greeter` — it shows a blank screen
and never accepts input.

User services that depend on Wayland (noctalia, polkit-gnome, voxtype)
use an `ExecStartPre` helper (`waitForWayland` in the let block)
to poll for `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` before starting,
preventing the "cannot open display" / "no peercred" failures.
The `noctalia-labwc-sync.service` (oneshot) does NOT need this because
its reconfigure script has its own Wayland socket wait loop.

All services (plus `noctalia-labwc-sync.path`) have `wantedBy = [ "graphical-session.target" ]` and
`PartOf=graphical-session.target`, but `graphical-session.target` has
`RefuseManualStart=yes` (systemd default for targets), so it cannot be
started directly. Instead, a **`labwcSession`** wrapper (defined in the
`let` block) is used as both greetd's `initial_session.command` and
tuigreet's `--cmd`. It waits for the user systemd instance to be ready,
then starts services via `systemctl --user start --no-block ...`,
then `exec`s labwc. This replaces the old `~/.config/labwc/autostart`.

Services started by `labwcSession`: `gnome-keyring-daemon.service`,
`noctalia.service`, `voxtype.service`, `polkit-gnome.service`,
`noctalia-labwc-sync.path`.

**Key gotchas:**
- **Must use `--no-block`** for all `systemctl --user start` calls in `labwcSession`.
  Without it, services with `wait-for-wayland` ExecStartPre deadlock: systemctl waits
  for the service to start, but the service waits for the Wayland socket, which labwc
  hasn't created yet (it's exec'd after the systemctl call). With `--no-block`,
  systemctl returns immediately, labwc starts, creates the socket, and the service's
  `wait-for-wayland` pre-exec eventually succeeds in the background.
- **`systemctl --user is-system-running`** during early boot may print "degraded" to
  stdout. Always redirect both streams: `>/dev/null 2>&1`.
- **greetd has `X-RestartIfChanged=false`** — after `nixos-rebuild switch`, you must
  manually: `systemctl daemon-reload && systemctl restart greetd.service`.
  (The rebuild output says "NOT restarting greetd.service" due to this flag.)
- **DO NOT use `set -e`** — a service failure must never abort the session.
- `|| true` on the service start so labwc always launches even if a service fails.

Config location: `.config/nixos-backup/configuration.nix`. Relevant sections:
- `services.greetd` — greetd display manager configuration
- `labwcSession` (in `let` block) — session wrapper that starts user services before labwc
- `systemd.user.services.noctalia` — `wantedBy = [ "graphical-session.target" ]`, `ExecStartPre` for wait-for-wayland
- `systemd.user.services.polkit-gnome` — depends on graphical-session.target + socket wait
- `systemd.user.services.voxtype` — depends on graphical-session.target + socket wait
- `systemd.user.services.noctalia-labwc-sync` — oneshot, no wait-for-wayland needed
- `systemd.user.paths.noctalia-labwc-sync` — watches settings.toml, triggers sync service

# GNOME Snapshot camera — PipeWire fd crash

GNOME Snapshot (and other camera apps using `org.freedesktop.portal.Camera`) segfaults
(SIGSEGV, exit 139) at `process_remote` in `libpipewire-module-protocol-native.so` after
calling `OpenPipeWireRemote`. Portal frontend, portal-gnome backend, and Snapshot all
use the **same** pipewire build.

**Root cause:** The portal creates a full PipeWire connection, steals the fd via
`pw_core_steal_fd`, then destroys its remote. The daemon receives a DISCONNECT for
that client. The dup'd fd Snapshot receives belongs to a now-disconnected client.
Snapshot's `pw_context_connect_fd()` tries to re-register on it → protocol state
confusion → null‑ptr deref.

**Fix:** LD_PRELOAD shim that intercepts `pw_context_connect_fd`, closes the
portal fd, and calls `pw_context_connect()` instead (fresh connection from
scratch). The shim is compiled as a Nix package (`snapshotPwFix`) and Snapshot is
wrapped (`snapshotPwWrapped`) with `LD_PRELOAD` set.

Notable: `dlsym(RTLD_NEXT, "pw_context_connect")` fails from the LD_PRELOAD shim.
Must use `dlopen("libpipewire-0.3.so.0", RTLD_LAZY | RTLD_NOLOAD)` + `dlsym(handle, ...)`
to find `pw_context_connect`.

Config:
- `snapshotPwFixSrc` + `snapshotPwFix` (let block) — builds shim .so from `./snapshot-pw-fix.c`
- `snapshotPwWrapped` (let block) — shell script wrapper setting LD_PRELOAD
- `snapshotPwWrapped` replaces `snapshot` in `environment.systemPackages`
- Source file: `./snapshot-pw-fix.c`

Note: `xdg-desktop-portal-gnome` is also needed as a Camera portal backend —
the GTK portal does NOT implement the Camera interface. Already configured:
`extraPortals` includes `pkgs.xdg-desktop-portal-gnome`,
`config.common."org.freedesktop.impl.portal.Camera" = [ "gnome" ]`.

# Flake operations

## Rebuild

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nixos --accept-flake-config
```

`--accept-flake-config` is needed to trust the `noctalia.cachix.org` binary cache
setting from `flake.nix`'s `nixConfig`.

## Check for updates & metadata

```bash
nix flake metadata                                     # current lock state, local
nix flake metadata github:NixOS/nixpkgs                # latest upstream nixpkgs
nix flake metadata <input-url>                         # latest upstream for any input
nixos-rebuild list-generations | tail -5               # recent system generations
```

## Update all inputs & rebuild

```bash
cd /etc/nixos/.config/nixos-backup
sudo nix flake update                     # update flake.lock (root-owned)
sudo nixos-rebuild switch --flake /etc/nixos#nixos --accept-flake-config
```

# Noctalia (from nixpkgs, not flake)

Noctalia is currently installed from `nixpkgs-unstable` via `environment.systemPackages`,
NOT from a dedicated flake input. The `flake.nix` only has `nixpkgs` as input.

**To add the noctalia flake input for binary cache support**, add to `flake.nix`:
```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  noctalia.url = "github:noctalia-dev/noctalia/cachix";
};
```
Then import the module and enable via `programs.noctalia` in `configuration.nix`.

**Binary cache:** `https://noctalia.cachix.org` (key `noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=`).

# Nautilus missing icons (e.g. Trash)

Add `adwaita-icon-theme` and `gsettings-desktop-schemas` to
`environment.systemPackages`, add `"/share/icons"` to
`environment.pathsToLink`, then `nixos-rebuild switch` and
`dconf write /org/gnome/desktop/interface/icon-theme "'Adwaita'"`.

# NixOS generation cleanup & bootloader

To remove old NixOS generations (keep last N):
```bash
sudo nix-env --delete-generations +N -p /nix/var/nix/profiles/system
sudo nix-collect-garbage
```

After cleanup, rebuild the bootloader:
```bash
sudo nixos-rebuild boot
```

Bootloader is **Limine** (not systemd-boot).

# Compose key on Caps Lock

Configured via `environment.sessionVariables = { XKB_DEFAULT_OPTIONS = "compose:caps"; }` in `configuration.nix`. Wayland-native — labwc picks it up from the env var, no X11 dependency.

# Noctalia-labwc-color-sync

Synced from `github:grigio/noctalia-labwc-color-sync` via `pkgs.fetchFromGitHub` in
`configuration.nix`. Package: `noctaliaLabwcSync`. The systemd path unit
`noctalia-labwc-sync.path` watches `~/.local/state/noctalia/settings.toml` and fires
the `noctalia-labwc-sync.service` (oneshot) which generates `~/.config/labwc/themerc-override`
and runs `labwc --reconfigure`.

Started in `labwcSession` via `systemctl --user start --no-block noctalia-labwc-sync.path`.
The service unit does NOT need `wait-for-wayland` pre-exec because `noctalia-labwc-reconfigure`
has its own Wayland socket wait loop inside it.

**Critical PATH gotcha:** Systemd user services in NixOS get a minimal PATH containing
only coreutils, findutils, grep, sed, and systemd — NOT `/run/current-system/sw/bin`
(where `noctalia` lives) and NOT `${pkgs.labwc}/bin`. Both must be injected via wrapper
scripts. Two wrappers are defined in the `let` block:
- `noctaliaLabwcSyncWrapper` — wraps `noctalia-labwc-theme-sync`, prepends
  `/run/current-system/sw/bin` (for `noctalia msg templates-apply`) and
  `${pkgs.labwc}/bin` (for the Python script's inline `labwc_reconfigure()`)
- `noctaliaLabwcReconfigure` — wraps `noctalia-labwc-reconfigure`, prepends
  `${pkgs.labwc}/bin` (for `exec labwc --reconfigure`)

Without these, the service falls back to hardcoded blue default colors instead of
the user's actual Noctalia palette.

**Preferred path:** The sync script first tries `noctalia msg templates-apply` (Noctalia's
own template engine). If that succeeds, it returns immediately — no Python fallback needed.
Only if it fails does it fall back to reading `~/.config/noctalia/colors.json` (which may
not exist) and then to hardcoded defaults. The wrapper ensures `noctalia` is in PATH so
`templates-apply` works from the systemd unit.

Config location: `.config/nixos-backup/configuration.nix`. Relevant section:
- `noctaliaLabwcSyncSrc`, `noctaliaLabwcSync` — fetch & build the package
- `noctaliaLabwcSyncWrapper`, `noctaliaLabwcReconfigure` — PATH-fixing wrappers
- `systemd.user.services.noctalia-labwc-sync` — oneshot service
- `systemd.user.paths.noctalia-labwc-sync` — watches `settings.toml`

# Dotfiles symlink merge

On every `nixos-rebuild switch`, `~/dotfiles/` contents are symlink-merged into `~` via
`system.activationScripts.dotfiles` in `configuration.nix`. Behavior:
- **Directories** in `~/dotfiles/` are stowed recursively: real dirs are created under `~`,
  only leaf files/symlinks are linked back (GNU Stow style).
- **Files** at the top level of `~/dotfiles/` are symlinked directly into `~`.
- Existing non-symlink files at the target are renamed to `<name>.bak.<timestamp>`
  before replacement, preventing data loss.
- `DOTFILES_ACTIVE` in `~/dotfiles/` is ignored (marker file).

# XDG_SESSION_TYPE for Electron/Wayland detection

`XDG_SESSION_TYPE=wayland` is set globally via `environment.sessionVariables` in
`configuration.nix`. Greetd+labwc doesn't set it automatically, but
modern Electron 39+ apps (Codium, Brave) rely on it to auto-detect Wayland.
Without it, these apps fall back to X11, which fails since XWayland is disabled.

`NIXOS_OZONE_WL` is **not used** — Electron 39+ auto-detects Wayland from
`XDG_SESSION_TYPE` alone, and the `NIXOS_OZONE_WL` wrapper injects an obsolete
`--ozone-platform-hint=auto` flag that causes warnings on modern Electron.

# Noctalia dock launchers (Brave, Nautilus, etc.) don't start — double fix

**Root cause (two levels):**

1. **Manager level (first fix):** Noctalia runs as a `systemd --user` service.
   Systemd user services inherit a minimal PATH lacking `/run/current-system/sw/bin`.
   The original fix in `labwcSession` sources `/etc/profile` and runs
   `systemctl --user import-environment` + `dbus-update-activation-environment`
   to push the full PATH into the manager environment before starting services.

2. **Service unit level (second fix):** Even with the manager
   environment fixed, NixOS **also** injects `Environment=PATH=<minimal>` into
   the systemd unit file of **every** user service. This `Environment=` directive
   **overrides** the manager's PATH for that specific service, so Noctalia's
   process still sees the minimal PATH. When Noctalia spawns apps from the dock
   via `fork/execvp`, child processes inherit this minimal PATH and can't find
   `brave`, `nautilus`, etc.

**Fix:**

Wrapped the Noctalia binary in a shell script (`noctaliaWrapper` in the `let`
block of `configuration.nix`) that sources `/etc/profile` **inside the service
process** before exec'ing Noctalia. This sets the full NixOS user environment
(PATH, XDG_SESSION_TYPE, QT_QPA_PLATFORM, etc.) regardless of what the unit's
`Environment=` directive contains.

```nix
noctaliaWrapper = pkgs.writeShellScript "noctalia-wrapper" ''
  . /etc/profile
  exec ${pkgs.noctalia}/bin/noctalia "$@"
'';
```

The service's `ExecStart` points to this wrapper instead of the bare binary.

The manager-level fix (`labwcSession`) is still kept — it benefits other
services (voxtype, polkit-gnome, clipman) that don't have their own wrapper.

**Relevant config sections:**
- `noctaliaWrapper` in the `let` block of `configuration.nix`
- `systemd.user.services.noctalia` → `serviceConfig.ExecStart` uses the wrapper

# XWayland is always started by labwc 0.20.1

Despite `programs.xwayland.enable = false` and `<xwayland>no</xwayland>` in `rc.xml`,
**Xwayland is still running**. Reason: labwc 0.20.1 removed the `<xwayland>` config option
entirely. The only xwayland-related setting is `<xwaylandPersistence>` (default: `no`),
which controls whether Xwayland exits when idle — not whether it starts at all. The
`<xwayland>no</xwayland>` entry is silently ignored.

`programs.xwayland.enable = false` only disables systemd socket activation, but
labwc spawns Xwayland directly via wlroots. pipewire connects to Xwayland via the
X11 socket, keeping it alive.

To fully remove Xwayland, rebuild labwc with `-Dxwayland=disabled` in NixOS overlays.

# System tweaks applied

- **`auto-optimise-store` disabled** — replaced with `nix.optimise.automatic` timer at 03:00
- **`nowatchdog`** added to kernel params (reduces timer interrupt overhead)
- **LUKS `allowDiscards`** enabled for SSD TRIM passthrough
- **Clipboard manager** (`clipman`) added as user service
- **Voxtype delays** added: `pre_type_delay_ms = 200`, `type_delay_ms = 5`
- **Kanshi** added for automatic display profile management
- **dbus-broker LogLevelMax=2** to suppress duplicate D-Bus service name noise
- **auto-cpufreq** enabled (replaces power-profiles-daemon) for dynamic CPU frequency tuning

# Power button workaround

On some laptops the physical power button does not generate OS-visible events
(firmware/EC-level limitation common with Modern Standby laptops).

**Workaround:** labwc keybinding `W-Escape` (`Super+Escape`) runs `noctalia msg session lock-and-suspend`.
A `XF86PowerOff` binding is also defined in `~/.config/labwc/rc.xml` in case the power button ever generates a keysym.

# D-Bus broker duplicate name noise

dbus-broker logs "Ignoring duplicate name" at LOG_ERR level for every D-Bus
service file that appears in multiple locations. This happens because NixOS
pulls service files into both `/run/current-system/sw/share/dbus-1/` (the
merged system-path) and from individual package store paths. Harmless but noisy.

**Fix:** `systemd.services.dbus-broker.serviceConfig.LogLevelMax = 2` and
`systemd.user.services.dbus-broker.serviceConfig.LogLevelMax = 2` caps
log output to LOG_CRIT and above, suppressing these ERR-level duplicates
(only EMERG/ALERT/CRIT pass through). No genuine errors are lost because
dbus-broker has no other reason to log at ERR level during normal operation.

**Telegram** (Qt app, not Electron): set `QT_QPA_PLATFORM=wayland;xcb` globally
in `environment.sessionVariables` so Qt apps prefer Wayland with XCB fallback
(already done in the config). Avoids wrapping each Qt binary individually.

# opencode v2 (opencode2)

Installed via npm at `~/.npm-global/bin/opencode2` (symlink to
`@opencode-ai/cli/bin/opencode2.exe`). The binary is a generic Linux ELF; NixOS
compatibility is provided by `programs.nix-ld.enable = true` in the NixOS config.

Config:
- `programs.nix-ld.enable = true` added to `configuration.nix`
- `nodejs` added to `environment.systemPackages`
- `NPM_CONFIG_PREFIX = "$HOME/.npm-global"` in `environment.sessionVariables`
- `PATH` extended with `$HOME/.npm-global/bin` in `environment.variables`

The binary is called `opencode2` during beta. To upgrade:
```bash
npm install -g @opencode-ai/cli@next
```
