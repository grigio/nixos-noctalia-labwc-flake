{ config, pkgs, lib, ... }:

let

  waitForWayland = pkgs.writeShellScriptBin "wait-for-wayland" ''
    while [ ! -S "$XDG_RUNTIME_DIR/''${WAYLAND_DISPLAY-wayland-0}" ]; do
      sleep 0.2
    done
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
      type_delay_ms = 0;
      pre_type_delay_ms = 0;
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
    osd = {
      enabled = false;
    };
  };


in

{
  imports = [
    ./hardware-configuration.nix
  ];

  #swapDevices = [{
  #  device = "/swapfile";
  #  size = 4096; #mb
  #}];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [ "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=" ];
    auto-optimise-store = true;
  };
  # system.autoUpgrade.enable = true;  # disabled: consumes CPU/RAM on single-core VM

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-old --delete-older-than 7d";
  };

  # Bootloader & kernel
  #boot.loader.systemd-boot.enable = true;
  # Limine: modern, fast bootloader with great EFI support
  boot.loader.limine.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_7_1;
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "2G";
  # Fix AMD PSP LOAD_TA failure, enable STIBP for VMSCAPE, force cgroup v2
  boot.kernelParams = [
    "amdgpu.runpm=0"
    "spectre_v2=on"
    "systemd.unified_cgroup_hierarchy=1"
  ];

  # Networking
  networking.hostName = "nixos";
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  #networking.firewall.enable = true;
  #networking.firewall.allowedTCPPorts = [ 3000 ];
  #networking.firewall.allowedUDPPorts = [ 137 138 5353 ];

  # Bluetooth
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false; # adapter powers on automatically
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
        command = "${pkgs.labwc}/bin/labwc";
        user = "g";
      };
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --asterisks --remember --greeting 'Welcome to NixOS' --greet-align center --window-padding 1 --container-padding 4 --prompt-padding 1 --power-shutdown 'loginctl poweroff' --power-reboot 'loginctl reboot' --theme ${greeterTheme} --cmd ${pkgs.labwc}/bin/labwc";
        user = "greeter";
      };
    };
  };



  programs.noctalia = {
    enable = true;
    systemd.enable = true;
    recommendedServices.enable = true;
  };

  systemd.user.services.noctalia.serviceConfig.ExecStartPre = [
    "${waitForWayland}/bin/wait-for-wayland"
  ];

  environment.etc = {
    "labwc/rc.xml".source = ./labwc/rc.xml;
    "labwc/menu.xml".source = ./labwc/menu.xml;
    "labwc/autostart".source = ./labwc/autostart;
    "labwc/environment".source = ./labwc/environment;
    "labwc/shutdown".source = ./labwc/shutdown;
    "labwc/themerc-override".source = ./labwc/themerc-override;
  };

  programs.xwayland.enable = false;
  programs.dconf.enable = true;

  services.gvfs.enable = true;

  services.udisks2.enable = true; # removable-media mounting for nautilus

  # GNOME Keyring for credential storage
  services.gnome.gnome-keyring.enable = true;

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

  # Audio (PipeWire)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
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
      Environment = "XDG_CONFIG_HOME=/etc";
      ExecStartPre = "${waitForWayland}/bin/wait-for-wayland";
      ExecStart = "${pkgs.voxtype-vulkan}/bin/voxtype";
    };
  };

  # Hardware & power
  hardware.cpu.amd.updateMicrocode = true;
  hardware.graphics.enable = true;
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  services.logind.settings.Login.HandleLidSwitch = "suspend";
  services.fstrim.enable = true;
  zramSwap = {
    enable = true;
    memoryPercent = 50;
    algorithm = "zstd";
  };

  # User accounts

  users.users.g = {
    isNormalUser = true;
    description = "user";
    extraGroups = [ "networkmanager" "wheel" "docker" "input" "video" ];
  };

  users.users.greeter.extraGroups = [ "video" "input" ];

  fonts.packages = with pkgs; [
    noto-fonts
    fira-code
  ];
  # fontconfig 48-guessfamily.conf has invalid XML in this nixpkgs rev — harmless warnings

  environment.systemPackages = with pkgs; [
    curl
    bash
    python3
    git
    unzip
    zip
    gzip

    voxtype-vulkan
    vulkan-loader

    wl-clipboard

    wlr-randr
    kitty
    micro
    htop
    fzf
    ncdu
    fastfetch
    nano
    nautilus
    brave
    opencode
    gnome-text-editor
    fuse3
    psmisc

    adwaita-icon-theme
    libsecret
    gsettings-desktop-schemas

    brightnessctl
    satty
    slurp
    grim
    obs-studio
  ];

  # Add /share/icons so icon themes (Adwaita) are linked into the system profile.
  environment.pathsToLink = [ "/share/icons" ];

  # Declarative VoxType config (reads base model from the Nix store)
  environment.etc."voxtype/config.toml".source = voxtypeConfig;
  nixpkgs.config.allowUnfree = true;

  # Wayland keyboard: Caps Lock as Compose key
  environment.sessionVariables = {
    XKB_DEFAULT_OPTIONS = "compose:caps";
  };

  system.stateVersion = "26.11";
}
