# NixOS + Noctalia + Labwc Flake

![demo](demo.gif)

Declarative NixOS 26.11 flake for a modern Wayland desktop — **labwc** compositor + **Noctalia V5** AI desktop shell + **Voxtype** voice-to-text.

Designed for AMD hardware (GPU + CPU microcode) with pure Wayland (no XWayland). Drop your `hardware-configuration.nix` alongside the flake and rebuild.

## Features

- **Labwc** — lightweight Wayland compositor, 4 virtual desktops, multi-monitor (DP-2 + eDP-1)
- **Noctalia V5** — AI-powered shell (panel, launcher, session, OSD recommender)
- **Voxtype** — offline voice-to-text via Whisper.cpp (ggml-base multilingual, ~142 MB), triggered by Right Alt
- **Color sync** — `noctalia-labwc-theme-sync` reads Noctalia's palette → WCAG-contrast window decorations → `labwc --reconfigure`
- **greetd + tuigreet** — auto-login TUI greeter with NixOS Blue theme
- **PipeWire** — audio with ALSA + PulseAudio compat, WirePlumber session manager
- **Screen capture** — Print screen → `grim` + `slurp` region select → `satty` annotation editor
- **Night light** — `W-n` toggles `wlsunset` (2500K), `W-S-n` kills it
- **OBS-cmd** — scene switching (`Alt-1..5`, `Alt-e`) and recording toggle (`Alt-r`)
- **Bluetooth** — enabled (no power-on-boot)
- **ZRAM** — 50% of RAM, zstd compression
- **AMD fine-tuning** — `amdgpu.runpm=0` (fixes PSP LOAD_TA), microcode updates, `spectre_v2=on`
- **GNOME Keyring** + **polkit-gnome** — credential storage and privilege escalation
- **Nix GC** — automatic weekly, deletes generations older than 7 days
- **GDK/icon fixes** — Adwaita icon theme linked, Trash icon visible in Nautilus
- **Compose key** — Caps Lock as compose key (Wayland-native)
- **XKB: Caps Lock** as compose key
- **SSH** — OpenSSH server enabled

## Usage

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nixos --accept-flake-config
```

## Upgrade

```bash
cd /etc/nixos
nix flake update             # update flake.lock to latest inputs
sudo nixos-rebuild switch --flake .#nixos --accept-flake-config
```

## Change the user name

The current user is `g`. To rename it, edit `configuration.nix`:

1. Change `users.users.g` to `users.users.<newname>` (line ~300).
2. Update the `initial_session.user` in `services.greetd.settings` (line ~186) from `"g"` to `"<newname>"`.
3. Rebuild with `sudo nixos-rebuild switch` and reboot.
4. The old home directory `/home/g` will remain — either symlink it or move contents.

## Notes

- `--accept-flake-config` is required to trust the `noctalia.cachix.org` binary cache.
- Noctalia is pinned via the `cachix` branch (always points to the latest cached commit).
- Bootloader: **Limine** (not systemd-boot).
- `hardware-configuration.nix` is **not** in the repo — generate it with `nixos-generate-config` on your machine.
