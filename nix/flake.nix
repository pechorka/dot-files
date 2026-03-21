{
  description = "pechorka dev environment — layered profiles for host and VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    neovim-nightly-overlay = {
      url = "github:nix-community/neovim-nightly-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, neovim-nightly-overlay, ... }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      nvimNightly = neovim-nightly-overlay.packages.${system}.default;

      # =====================================================================
      # Screenshot helper script
      # =====================================================================
      screenshotArea = pkgs.writeShellApplication {
        name = "screenshot-area";
        runtimeInputs = with pkgs; [ coreutils grim slurp wl-clipboard ];
        text = ''
          set -euo pipefail
          dir="$HOME/Pictures/Screenshots"
          mkdir -p "$dir"
          file="$dir/$(date +%Y-%m-%d_%H-%M-%S).png"
          grim -g "$(slurp)" "$file"
          wl-copy < "$file"
          echo "Saved: $file (copied to clipboard)"
        '';
      };

      # =====================================================================
      # Package layers
      # =====================================================================

      # Common: shared by host and all VMs (~80% of packages)
      commonPackages = with pkgs; [
        # Shells & editors
        fish
        nvimNightly
        tmux
        lazygit

        # CLI utils
        ripgrep
        fzf
        fd
        jq
        yq-go
        htop
        bat
        curl
        wget

        # SSH
        keychain

        # Go
        go
        gopls

        # Rust
        rustc
        cargo
        rustfmt
        clippy
        rust-analyzer

        # JS/TS
        nodejs
        pnpm

        # JVM
        jdk
        kotlin
        gradle

        # DB clients
        sqlite
        pgcli

        # Containers
        podman

        # WebAssembly
        wasmtime

        # Nix/fish integration
        nix-your-shell
      ];

      # Host: desktop/GUI packages (on top of common)
      hostPackages = with pkgs; [
        # Browsers
        firefox
        chromium

        # Terminal
        ghostty

        # Wayland desktop
        waybar
        wofi
        mako
        xwayland

        # Screenshots
        grim
        slurp
        wl-clipboard
        screenshotArea

        # Media/brightness controls
        brightnessctl
        playerctl
        pamixer

        # System applets
        networkmanagerapplet
        blueman
        pavucontrol

        # Auth dialogs
        polkit_gnome

        # Icons & fonts
        adwaita-icon-theme
        hicolor-icon-theme
        gsettings-desktop-schemas
        font-awesome
        noto-fonts
        noto-fonts-color-emoji
        liberation_ttf
        fontconfig
      ];

      # VM base: headless tools for dev VMs (on top of common)
      vmBasePackages = with pkgs; [
        # Headless browser for agent testing
        chromium

        # Playwright deps
        playwright-driver.browsers
      ];

    in
    {
      # =================================================================
      # Installable profiles: nix profile install .#<name>
      # =================================================================
      packages.${system} = {

        # Host profile: common + host desktop
        host = pkgs.buildEnv {
          name = "profile-host";
          paths = commonPackages ++ hostPackages;
        };

        # VM personal: common + vm base
        vm-personal = pkgs.buildEnv {
          name = "profile-vm-personal";
          paths = commonPackages ++ vmBasePackages;
        };

        # VM work: common + vm base (extend with work-specific packages below)
        vm-work = pkgs.buildEnv {
          name = "profile-vm-work";
          paths = commonPackages ++ vmBasePackages;
        };
      };
    };
}
