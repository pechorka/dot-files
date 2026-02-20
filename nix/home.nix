{ config, pkgs, lib, nvimNightly, ... }:

let
  # For standalone Home Manager on Linux, we can pull these from the environment.
  # NOTE: home-manager is run with --impure by the sync script.
  username = builtins.getEnv "USER";
  homeDir  = builtins.getEnv "HOME";
  nixGLIntel = pkgs.nixgl.nixGLIntel;
  swayNixGL = pkgs.writeShellScriptBin "sway" ''
    exec ${nixGLIntel}/bin/nixGLIntel ${pkgs.sway}/bin/sway "$@"
  '';

  screenshotArea = pkgs.writeShellApplication {
    name = "screenshot-area";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.grim
      pkgs.slurp
      pkgs.wl-clipboard
    ];
    text = ''
      set -euo pipefail
      dir="$HOME/Pictures/Screenshots"
      mkdir -p "$dir"
      file="$dir/$(date +%Y-%m-%d_%H-%M-%S).png"

      grim -g "$(slurp)" "$file"
      wl-copy < "$file"

      echo "Saved: $file"
      echo "(Copied to clipboard)"
    '';
  };
in
{
  # Required on non-NixOS
  home.username = username;
  home.homeDirectory = homeDir;

  # Pick the first Home Manager version you use and keep it stable.
  home.stateVersion = "25.11";

  targets.genericLinux.enable = true;
  programs.home-manager.enable = true;

  # Useful env vars (Wayland + sane defaults)
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    TERMINAL = "ghostty";

    # Electron/Chromium apps on Wayland (harmless if unused).
    NIXOS_OZONE_WL = "1";
  };

  # Packages you asked for (plus the sway stack + tray helpers)
  home.packages = with pkgs; [
    # shells & editors
    fish
    nvimNightly
    tmux
    lazygit

    # CLI utils
    ripgrep fzf fd jq yq-go htop bat

    # DB & clients
    sqlite pgcli

    # Containers
    podman

    # WebAssembly runtime
    wasmtime

    # Go toolchain + LSP
    go gopls

    # Rust toolchain & tools
    rustc cargo rustfmt clippy rust-analyzer

    # JS/TS
    nodejs pnpm

    # JVM & build
    jdk kotlin gradle

    # --- No-DE Wayland desktop bits ---
    waybar
    wofi
    ghostty

    # For running X11/GTK apps under Wayland (nm-applet, blueman, pavucontrol, etc.)
    xwayland

    # Applets / GUIs (you manage “DE stuff” via these)
    networkmanagerapplet   # provides nm-applet + nm-connection-editor :contentReference[oaicite:3]{index=3}
    blueman
    pavucontrol

    # Notifications
    mako

    # Screenshot deps
    grim slurp wl-clipboard

    # Media / brightness key helpers
    brightnessctl
    playerctl
    pamixer

    # Icon + font basics (fix missing tray icons / glyphs)
    adwaita-icon-theme
    hicolor-icon-theme
    gsettings-desktop-schemas
    font-awesome

    # Polkit agent (auth dialogs)
    polkit_gnome
  ] ++ [
    screenshotArea
  ];

  # Notifications
  services.mako = {
    enable = true;
    settings = {
      default-timeout = 5000;
      background-color = "#1e1e2e";
      text-color = "#cdd6f4";
      border-color = "#89b4fa";
      border-size = 2;
      padding = 10;
    };
  };

  # Tray helper for legacy XEmbed icons (nm-applet can need this under Wayland).
  # Home Manager provides this module. :contentReference[oaicite:4]{index=4}
  services.xembed-sni-proxy = {
    enable = true;
    # Avoid an old alias pitfall by using the explicit Qt6 package set.
    package = pkgs.kdePackages.plasma-workspace;
  };

  programs.waybar = {
    enable = true;
    systemd.enable = true;

    settings = [
      {
        layer = "top";
        position = "top";

        "modules-left" = [ "sway/workspaces" "sway/mode" ];
        "modules-center" = [ "sway/window" ];

        # These three are your “always visible” GUI launch buttons.
        # Even if tray icons misbehave, you can still click these.
        "modules-right" = [
          "custom/nm"
          "custom/bt"
          "custom/pavu"
          "tray"
          "pulseaudio"
          "clock"
        ];

        "custom/nm" = {
          format = "";
          tooltip = true;
          tooltip-format = "Network";
          on-click = "${pkgs.networkmanagerapplet}/bin/nm-connection-editor";
        };

        "custom/bt" = {
          format = "";
          tooltip = true;
          tooltip-format = "Bluetooth";
          on-click = "${pkgs.blueman}/bin/blueman-manager";
        };

        "custom/pavu" = {
          format = "";
          tooltip = true;
          tooltip-format = "Audio";
          on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
        };

        tray = {
          spacing = 8;
        };

        pulseaudio = {
          format = "{icon} {volume}%";
          "format-icons" = [ "" "" "" ];
          scroll-step = 5;
          # Waybar supports on-click for pulseaudio. :contentReference[oaicite:5]{index=5}
          on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
        };

        clock = {
          format = " {:%Y-%m-%d %H:%M}";
          tooltip = true;
          tooltip-format = "{:%A, %B %d, %Y}";
        };
      }
    ];

    style = ''
      * {
        font-family: FontAwesome, sans-serif;
        font-size: 12pt;
      }

      #waybar {
        background: rgba(20, 20, 25, 0.85);
      }

      #custom-nm, #custom-bt, #custom-pavu {
        padding: 0 10px;
        margin: 4px 3px;
        border-radius: 6px;
        background: rgba(255, 255, 255, 0.06);
      }

      #tray, #pulseaudio, #clock {
        padding: 0 10px;
        margin: 4px 3px;
      }
    '';
  };

  wayland.windowManager.sway = {
    enable = true;
    package = swayNixGL;

    # This improves the Wayland “session” experience under systemd (services start at the right time, env imported, etc.). :contentReference[oaicite:6]{index=6}
    systemd.enable = true;

    # Needed for nm-applet / pavucontrol / many GTK apps
    xwayland = true;

    config = {
      modifier = "Mod4"; # Super
      terminal = "${pkgs.ghostty}/bin/ghostty";
      menu = "${pkgs.wofi}/bin/wofi --show drun";

      # Makes keybindings work even when you're in the RU layout. :contentReference[oaicite:7]{index=7}
      bindkeysToCode = true;

      # We use Waybar, not swaybar.
      bars = [ ];

      # Keyboard:
      # - EN/RU layouts
      # - Right Alt toggles layout
      # - CapsLock is Control
      input = {
        "*" = {
          xkb_layout = "us,ru";
          xkb_options = "grp:ralt_toggle,ctrl:nocaps";
        };
      };

      startup = [
        # Polkit agent for auth prompts (mounts, NM edits, etc.)
        { command = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"; }

        # System applets you want instead of a full DE
        # nm-applet needs a tray implementation. :contentReference[oaicite:8]{index=8}
        { command = "${pkgs.networkmanagerapplet}/bin/nm-applet --indicator"; }
        { command = "${pkgs.blueman}/bin/blueman-applet"; }
        { command = "${pkgs.waybar}/bin/waybar"; }
      ];

      keybindings = lib.mkOptionDefault {
        # Your screenshot binding:
        # Alt+P -> select area -> save + copy to clipboard
        "Mod1+p" = "exec ${screenshotArea}/bin/screenshot-area";

        # Brightness keys
        "XF86MonBrightnessUp" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set +10%";
        "XF86MonBrightnessDown" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 10%-";

        # Volume keys
        "XF86AudioRaiseVolume" = "exec ${pkgs.pamixer}/bin/pamixer -i 5";
        "XF86AudioLowerVolume" = "exec ${pkgs.pamixer}/bin/pamixer -d 5";
        "XF86AudioMute" = "exec ${pkgs.pamixer}/bin/pamixer -t";
        "XF86AudioMicMute" = "exec ${pkgs.pamixer}/bin/pamixer --default-source -t";

        # Media keys (playerctl)
        "XF86AudioPlay" = "exec ${pkgs.playerctl}/bin/playerctl play-pause";
        "XF86AudioNext" = "exec ${pkgs.playerctl}/bin/playerctl next";
        "XF86AudioPrev" = "exec ${pkgs.playerctl}/bin/playerctl previous";
      };
    };
  };

  # Auto-start Sway on TTY1 after login (fits your “reboot and that's it” flow).
  # - avoids SSH sessions
  # - avoids nested sessions
  xdg.configFile."fish/conf.d/99-sway-autostart.fish".text = ''
    if status is-login
      if test -z "$WAYLAND_DISPLAY" -a -z "$DISPLAY"
        if not set -q SSH_CONNECTION
          if test (tty) = "/dev/tty1"
            exec ${swayNixGL}/bin/sway
          end
        end
      end
    end
  '';
}
