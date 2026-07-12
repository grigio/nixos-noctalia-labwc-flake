# NixOS + Noctalia + Labwc Flake

![demo](demo.gif)

Backup of the system flake config at `/etc/nixos`. You need to use your `/etc/nixos/hardware-configuration.nix`

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

1. Change `users.users.g` to `users.users.<newname>` (line ~258).
2. Update the `initial_session.user` in `services.greetd.settings` (line ~164) from `"g"` to `"<newname>"`.
3. Rebuild with `sudo nixos-rebuild switch` and reboot.
4. The old home directory `/home/g` will remain — either symlink it or move contents.

## Notes

-   `--accept-flake-config` is required to trust the `noctalia.cachix.org` binary cache.
-   Noctalia is pinned via the `cachix` branch (always points to the latest cached commit).
-   Bootloader: Limine.
-   `noctalia-labwc-color-sync` (from `github:grigio/noctalia-labwc-color-sync`) syncs Noctalia V5 theme colors to labwc window decorations via `noctalia-labwc-theme-sync`. Installed as a system package and auto-triggered via systemd path unit.
