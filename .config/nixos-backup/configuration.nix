{ config, pkgs, lib, ... }:

let
  userHome = config.users.users.g.home;

  waitForWayland = pkgs.writeShellScriptBin "wait-for-wayland" ''
    while [ ! -S "$XDG_RUNTIME_DIR/''${WAYLAND_DISPLAY-wayland-0}" ]; do
      sleep 0.2
    done
  '';

  # Wrapper that sources /etc/profile before exec'ing Noctalia.
  # NixOS adds Environment=PATH=<minimal> to all user services,
  # which overrides the manager environment and causes Noctalia's
  # dock-launched apps (via fork/execvp) to inherit a PATH that
  # lacks /run/current-system/sw/bin and Nix profile paths.
  # Sourcing /etc/profile restores the full user environment
  # inside the Noctalia process regardless of the systemd unit's
  # Environment= override.
  noctaliaWrapper = pkgs.writeShellScript "noctalia-wrapper" ''
    . /etc/profile
    exec ${pkgs.noctalia}/bin/noctalia "$@"
  '';

  labwcSession = pkgs.writeShellScript "labwc-session" ''
    for i in $(seq 20); do
      if systemctl --user is-system-running >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
    # Source the system profile so all NixOS session variables
    # (PATH, XDG_SESSION_TYPE, XDG_DATA_DIRS, etc.) are set in
    # this process before we import them into systemd.
    # This is the general fix for Noctalia dock launchers and any
    # other systemd-user-spawned process that needs the NixOS env.
    [ -r /etc/profile ] && . /etc/profile
    systemctl --user import-environment PATH XDG_SESSION_TYPE XDG_DATA_DIRS WAYLAND_DISPLAY XDG_CURRENT_DESKTOP WAYLAND_SESSION XDG_SESSION_ID
    # Also sync D-Bus activation environment so apps launched via
    # D-Bus (not just fork/exec) inherit the same variables.
    ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd 2>/dev/null || true
    # Start services explicitly (graphical-session.target has
    # RefuseManualStart=yes so it can't be started directly).
    # Services use wait-for-wayland ExecStartPre so they poll for
    # the Wayland socket (created once labwc execs below).
    systemctl --user start --no-block noctalia.service voxtype.service polkit-gnome.service kanshi.service clipman.service 2>/dev/null || true
    systemctl --user start --no-block noctalia-labwc-sync.path 2>/dev/null || true
    exec ${pkgs.labwc}/bin/labwc
  '';

  greeterTheme = pkgs.writeText "tuigreet-theme.toml" ''
    [theme]
    name = "NixOS Blue"

    [theme.container]
    border = "#4c8dff"

    [theme.input]
    background = "#1e1e2e"
    foreground = "#cdd6f4"

    [theme.text]
    prompt = "#89b4fa"

    [theme.button]
    foreground = "#cdd6f4"
    background = "#1e1e2e"
    border = "#4c8dff"

    [theme.button_focused]
    foreground = "#1e1e2e"
    background = "#4c8dff"
    border = "#4c8dff"
  '';

  # Declarative base Whisper model (~142 MB, multilingual)
  voxtypeBaseModel = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin";
    hash = "sha256-YO1bw90U7qhWST0zQ0m0BXgt3K8AKNS130CINF+6Lv4=";
    name = "ggml-base.bin";
  };
  voxtypeToml = pkgs.formats.toml { };
  voxtypeConfig = voxtypeToml.generate "voxtype-config.toml" {
    state_file = "auto";
    hotkey = {
      enabled = true;
      key = "RIGHTALT";
      modifiers = [ ];
    };
    audio = {
      device = "default";
      sample_rate = 16000;
      max_duration_secs = 60;
    };
    whisper = {
      model = toString voxtypeBaseModel;
      language = "auto";
      translate = false;
      on_demand_loading = false;
    };
    output = {
      mode = "type";
      fallback_to_clipboard = true;
      type_delay_ms = 5;
      pre_type_delay_ms = 200;
    };
    output.notification = {
      on_recording_start = false;
      on_recording_stop = false;
      on_transcription = true;
    };
    text = {
      spoken_punctuation = false;
      replacements = { };
    };
    status = {
      icon_theme = "emoji";
    };
  };

  noctaliaLabwcSyncSrc = pkgs.fetchFromGitHub {
    owner = "grigio";
    repo = "noctalia-labwc-color-sync";
    rev = "master";
    hash = "sha256-VgqxdAdL1vwLY7O8YHMi7QL3NxyKpanKbdx5YKbdmkM=";
  };
  noctaliaLabwcSync = pkgs.callPackage "${noctaliaLabwcSyncSrc}/default.nix" { };

  # Wrapper that adds noctalia and labwc to PATH for the sync script
  noctaliaLabwcSyncWrapper = pkgs.writeShellScript "noctalia-labwc-theme-sync" ''
    export PATH="/run/current-system/sw/bin:${pkgs.labwc}/bin:$PATH"
    exec ${noctaliaLabwcSync}/bin/noctalia-labwc-theme-sync "$@"
  '';

  # Wrapper that adds labwc to PATH for the reconfigure script
  noctaliaLabwcReconfigure = pkgs.writeShellScript "noctalia-labwc-reconfigure" ''
    export PATH="${pkgs.labwc}/bin:$PATH"
    exec ${noctaliaLabwcSync}/bin/noctalia-labwc-reconfigure
  '';

  # LD_PRELOAD shim for GNOME Snapshot: replaces pw_context_connect_fd with
  # pw_context_connect to avoid crash when the portal returns a stale PipeWire fd
  # (the portal steals the fd via pw_core_steal_fd, destroys the remote, then the
  # daemon disconnects the client — the dup'd fd the app receives belongs to a
  # disconnected session). The shim closes the portal fd and creates a fresh
  # connection from scratch.
  snapshotPwFixSrc = ./snapshot-pw-fix.c;
  snapshotPwFix = pkgs.stdenv.mkDerivation {
    name = "snapshot-pw-fix";
    src = snapshotPwFixSrc;
    dontUnpack = true;
    buildPhase = ''
      ${pkgs.gcc}/bin/gcc -shared -fPIC -o snapshot-pw-fix.so $src -ldl
    '';
    installPhase = ''
      mkdir -p $out/lib
      cp snapshot-pw-fix.so $out/lib/
    '';
  };
  snapshotPwWrapped = pkgs.symlinkJoin {
    name = "snapshot-wrapped-${pkgs.snapshot.version}";
    paths = [
      (pkgs.writeShellScriptBin "snapshot" ''
        export LD_PRELOAD=${snapshotPwFix}/lib/snapshot-pw-fix.so''${LD_PRELOAD:+:$LD_PRELOAD}
        exec ${pkgs.snapshot}/bin/snapshot "$@"
      '')
      pkgs.snapshot
    ];
  };

in {
  imports = lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix;

  # Boot
  boot.loader.limine = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.loader.efi.canTouchEfiVariables = false;

  # Kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [ "quiet" "nowatchdog" ];

  # Allow rootless Podman to bind port 80 (needed by traefik reverse proxy)
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;
  boot.kernel.sysctl."vm.swappiness" = 10;
  boot.initrd.systemd.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  boot.initrd.luks.devices."luks-1c9217e1-b8ed-47a7-8c70-b576ff25b915" = {
    allowDiscards = true;
  };

  # Networking
  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 9090 53317 ];
    allowedUDPPorts = [ 53317 ];
  };

  # Security
  security.sudo.extraRules = [
    {
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
      groups = [ "wheel" ];
    }
  ];

  security.polkit.enable = true;
  security.pam.services.greetd.enableGnomeKeyring = true;

  # Environment
  environment = {
    variables = {
      PATH = [ "$HOME/.npm-global/bin" ];
    };
    systemPackages = with pkgs; [
      nodejs
      git
      alacritty
      wget
      curl
      ripgrep
      file
      jq
      nushell
      unzip
      zip
      gparted
      gnome-disk-utility
      ntfs3g
      nautilus
      file-roller
      localsend
      loupe
      gnome-text-editor
      adwaita-icon-theme
      gsettings-desktop-schemas
      lshw
      pciutils
      usbutils
      eza
      fd
      fzf
      herdr
      zoxide
      bubblewrap
      bat
      htop
      btop
      fastfetch
      opencode
      brave
      vscodium
      brightnessctl
      fuse3
      sshfs
      telegram-desktop
      grim
      libsecret
      micro
      nano
      ncdu
      #       obs-studio is installed via programs.obs-studio.enable
      obs-cmd
      playerctl
      psmisc
      python3
      satty
      smartmontools
      snapshotPwWrapped
      slurp
      voxtype-vulkan
      vulkan-loader
      wl-clipboard
      virt-viewer
      podman-compose
      dive
      buildah
      skopeo
      wsdd
      cockpit-podman
      kexec-tools
      noctalia
      noctaliaLabwcSync
      clipman
      sushi
      kanshi
      kooha
      gnome-boxes
      hardinfo2
      scrcpy
      tor-browser
    ];
    pathsToLink = [ "/share/icons" "/share/cockpit" "/share/gsettings-schemas" "/share/glib-2.0/schemas" ];
    sessionVariables = {
      WLR_XWAYLAND = "";
      NPM_CONFIG_PREFIX = "$HOME/.npm-global";
      XDG_SESSION_TYPE = "wayland";
      WAYLAND_SESSION = "labwc";
      XDG_CURRENT_DESKTOP = "labwc:wlroots";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      FONTCONFIG_PATH = "/etc/fonts";
      XKB_DEFAULT_OPTIONS = "compose:caps";
      EDITOR = "micro";
      VISUAL = "micro";
      QT_QPA_PLATFORM = "wayland;xcb";
      __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
    };
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  nixpkgs.config.allowUnfree = true;

  environment.etc."voxtype/config.toml".source = voxtypeConfig;

  # Nix config
  nix = {
    package = pkgs.nixVersions.latest;
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = false;
      warn-dirty = false;
      min-free = 2000000000;
      max-free = 5000000000;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    optimise = {
      automatic = true;
      dates = [ "03:00" ];
    };
  };

  # Dotfiles symlink merge on rebuild
  system.activationScripts.dotfiles = {
      text = ''
        ${pkgs.coreutils}/bin/mkdir -p '${userHome}'
        if [ -d '${userHome}/dotfiles' ]; then
            cd '${userHome}/dotfiles'
            shopt -s dotglob
            for item in *; do
              [ "$item" = "DOTFILES_ACTIVE" ] && continue
              [ "$item" = ".git" ] && continue
              target="${userHome}/$item"
              if [ -d "$item" ]; then
                ${pkgs.coreutils}/bin/mkdir -p "$target"
                ${pkgs.coreutils}/bin/chown '${config.users.users.g.name}:users' "$target"
                ${pkgs.findutils}/bin/find "$item" -type f -o -type l | while read -r f; do
                  rel="$f"
                  dir="${userHome}/$(dirname "$rel")"
                  ${pkgs.coreutils}/bin/mkdir -p "$dir"
                ${pkgs.coreutils}/bin/chown '${config.users.users.g.name}:users' "$dir"
                if [ -e "${userHome}/$rel" ] && [ ! -L "${userHome}/$rel" ]; then
                  mv "${userHome}/$rel" "${userHome}/$rel.bak.$(date +%s)"
                fi
                ln -sf "${userHome}/dotfiles/$rel" "${userHome}/$rel"
              done
            else
              if [ -e "$target" ] && [ ! -L "$target" ]; then
                mv "$target" "$target.bak.$(date +%s)"
              fi
              ln -sf "${userHome}/dotfiles/$item" "$target"
            fi
          done
        fi
      '';
      deps = [ ];
  };

  # Time & locale
  time.timeZone = "Europe/Rome";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "it_IT.UTF-8";
    LC_IDENTIFICATION = "it_IT.UTF-8";
    LC_MEASUREMENT = "it_IT.UTF-8";
    LC_MONETARY = "it_IT.UTF-8";
    LC_NAME = "it_IT.UTF-8";
    LC_NUMERIC = "it_IT.UTF-8";
    LC_PAPER = "it_IT.UTF-8";
    LC_TELEPHONE = "it_IT.UTF-8";
    LC_TIME = "it_IT.UTF-8";
  };

  # Display server & WM (pure Wayland via labwc, no X11)
  services.greetd = {
    enable = true;
    restart = true;
    settings = {
      initial_session = {
        command = "${labwcSession}";
        user = "g";
      };
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --asterisks --remember --greeting 'Welcome to NixOS' --greet-align center --window-padding 1 --container-padding 4 --prompt-padding 1 --power-shutdown 'loginctl poweroff' --power-reboot 'loginctl reboot' --theme ${greeterTheme} --cmd ${labwcSession}";
        user = "greeter";
      };
    };
  };

  systemd.user.services.noctalia = {
    description = "Noctalia desktop shell";
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "3";
      ExecStartPre = [ "${waitForWayland}/bin/wait-for-wayland" ];
      ExecStart = "${noctaliaWrapper}";
      Environment = [ "WAYLAND_DISPLAY=wayland-0" ];
    };
  };

  systemd.user.services.noctalia-labwc-sync = {
    description = "Sync Noctalia colors to labwc themerc-override";
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${noctaliaLabwcSyncWrapper}";
      ExecStartPost = "${noctaliaLabwcReconfigure}";
    };
  };

  systemd.user.paths.noctalia-labwc-sync = {
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    pathConfig = {
      PathChanged = "%h/.local/state/noctalia/settings.toml";
    };
  };

  programs.nix-ld = {
    enable = true;
  };

  programs.obs-studio = {
    enable = true;
  };

  programs.xwayland.enable = false;
  programs.dconf.enable = true;

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      character.success_symbol = "[➜](bold green)";
      character.error_symbol = "[➜](bold red)";
    };
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    enableBashCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    interactiveShellInit = "eval \"$(starship init zsh)\"";
  };

  services.gvfs.enable = true;

  services.udisks2.enable = true; # removable-media mounting for nautilus

  services.smartd.enable = true;

  # GNOME Keyring for credential storage
  services.gnome.gnome-keyring.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-wlr pkgs.xdg-desktop-portal-gtk pkgs.xdg-desktop-portal-gnome ];
    configPackages = [ pkgs.labwc ];
    config.common = {
      default = [ "wlr" ];
      "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
      "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
      "org.freedesktop.impl.portal.Camera" = [ "gnome" ];
    };
  };

  # Suppress dbus-broker "Ignoring duplicate name" noise (logged at LOG_ERR by
  # dbus-broker when multiple packages provide the same D-Bus service file).
  # This is harmless — it just means the same service name appears in both
  # /run/current-system/sw/share/dbus-1/services/ and individual package paths.
  # LogLevelMax=2 caps output to LOG_CRIT and above, dropping the ERR-level
  # duplicate messages (only EMERG/ALERT/CRIT pass through).
  systemd.services.dbus-broker.serviceConfig = {
    LogLevelMax = 2;
  };
  systemd.user.services.dbus-broker.serviceConfig = {
    LogLevelMax = 2;
  };

  # Audio (PipeWire)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
    extraConfig.pipewire = {
      "context.properties"."module.x11.bell" = false;
    };
  };
  security.rtkit.enable = true;

  systemd.user.services.polkit-gnome = {
    after = [ "graphical-session.target" ];
    bindsTo = [ "graphical-session.target" ];
    description = "PolicyKit authentication agent (GNOME)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "3";
      ExecStartPre = "${waitForWayland}/bin/wait-for-wayland";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    };
  };

  systemd.user.services.voxtype = {
    description = "Voxtype voice-to-text daemon";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "pipewire.service" "pipewire-pulse.service" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "5";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'mkdir -p %h/.config/voxtype && ln -sfT /etc/voxtype/config.toml %h/.config/voxtype/config.toml'";
      ExecStart = "${pkgs.voxtype-vulkan}/bin/voxtype";
    };
  };

  # Hardware & power
  # Set by hardware-configuration.nix on AMD systems
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "2G";
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
    settings.OOM = {
      DefaultMemoryPressureDuration = "5s";
      SwapUsedLimitPercent = "20%";
    };
  };
  hardware.bluetooth.enable = true;
  systemd.services.bluetooth.wantedBy = lib.mkForce [];
  services.power-profiles-daemon.enable = false;
  services.auto-cpufreq.enable = true;
  services.upower.enable = true;
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandlePowerKey = "ignore";
  };
  services.fstrim.enable = true;

  # services.acpid.enable = true;  # redundant — logind handles lid/power events, power button generates no OS events
  swapDevices = [{
    device = "/swapfile";
    size = 8192;
  }];

  zramSwap = {
    enable = true;
    memoryPercent = 30;
    algorithm = "zstd";
  };

  # Automatic display profile management (kanshi)
  systemd.user.services.kanshi = {
    description = "Kanshi display profile manager";
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "3";
      ExecStartPre = "${waitForWayland}/bin/wait-for-wayland";
      ExecStart = "${pkgs.kanshi}/bin/kanshi";
    };
  };

  # Clipboard manager
  systemd.user.services.clipman = {
    description = "Clipman clipboard manager";
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStartPre = "${waitForWayland}/bin/wait-for-wayland";
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.clipman}/bin/clipman store --no-notify";
      Restart = "on-failure";
      RestartSec = "3";
    };
  };

  # Cockpit web management
  services.cockpit = {
    enable = false;
    port = 9090;
  };

  # Virtualisation

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
  };
  virtualisation.libvirtd.enable = true;

  # Docker Compose services (user-level with lingering for rootless Podman)
  systemd.user.services.traefik = {
    description = "Traefik reverse proxy";
    after = [ "default.target" ];
    wantedBy = [ ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "%h/Apps/traefik";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'while [ ! -S /run/docker.sock ]; do sleep 0.5; done'";
      ExecStart = "${pkgs.podman-compose}/bin/podman-compose up -d";
      ExecStop = "${pkgs.podman-compose}/bin/podman-compose down";
      Environment = "PATH=/run/current-system/sw/bin";
    };
  };

  # Increase I/O queue depth on external USB SSDs (many have tiny defaults like 60)
  systemd.services.usbssd-tune = {
    description = "Increase USB SSD I/O queue depth";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '
        for dev in /dev/disk/by-id/usb-*; do
          [ -e \"$dev\" ] || continue
          block=$(basename \"$(readlink -f \"$dev\")\")
          rot=$(cat /sys/block/$block/queue/rotational 2>/dev/null) || continue
          [ \"$rot\" = \"0\" ] || continue
          echo 512 > /sys/block/$block/queue/nr_requests 2>/dev/null || true
        done
      '";
    };
  };

  systemd.user.services.searxng = {
    description = "SearXNG meta search engine";
    after = [ "default.target" ];
    wantedBy = [ ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "%h/Apps/searxng";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'while [ ! -S /run/docker.sock ]; do sleep 0.5; done'";
      ExecStart = "${pkgs.podman-compose}/bin/podman-compose up -d";
      ExecStop = "${pkgs.podman-compose}/bin/podman-compose down";
      Environment = "PATH=/run/current-system/sw/bin";
    };
  };

  # User accounts

  users.manageLingering = true;

  users.users.g = {
    linger = true;
    isNormalUser = true;
    description = "user";
    extraGroups = [ "networkmanager" "wheel" "podman" "input" "video" "libvirtd" "fuse" ];
    shell = pkgs.zsh;
  };

  fonts.packages = with pkgs; [
    noto-fonts
    fira-code
    nerd-fonts.iosevka
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.11"; # Did you read the comment?
}
