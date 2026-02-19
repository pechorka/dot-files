{
  description = "pechorka dot-files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Home Manager (standalone, not NixOS module)
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Neovim nightly from master
    neovim-nightly-overlay = {
      url = "github:nix-community/neovim-nightly-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, home-manager, neovim-nightly-overlay, ... }:
    let
      system = builtins.currentSystem;

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      nvimNightly = neovim-nightly-overlay.packages.${system}.default;

      hm = home-manager.packages.${system}.home-manager;

      # `nix run .#sync`:
      #   - git pull the repo in ~/.config
      #   - home-manager switch (impure so it can read $USER/$HOME for username/homeDir)
      sync = pkgs.writeShellApplication {
        name = "sync";
        runtimeInputs = [ pkgs.git ];
        text = ''
          set -euo pipefail

          DOTFILES="${XDG_CONFIG_HOME:-$HOME/.config}"

          if [ -d "$DOTFILES/.git" ]; then
            echo "==> Updating dotfiles repo (git pull --ff-only)..."
            git -C "$DOTFILES" pull --ff-only
          else
            echo "WARNING: $DOTFILES is not a git repo; skipping git pull."
          fi

          echo "==> Applying Home Manager config..."
          exec "${hm}/bin/home-manager" switch --impure --flake "$DOTFILES#default"
        '';
      };
    in
    {
      # Home Manager configuration:
      # - reads $USER/$HOME inside home.nix (so sync calls home-manager with --impure)
      homeConfigurations.default = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
        ];
        extraSpecialArgs = {
          inherit nvimNightly;
        };
      };

      apps.${system}.sync = {
        type = "app";
        program = "${sync}/bin/sync";
      };

      # Allow: `nix run .` as shorthand
      apps.${system}.default = self.apps.${system}.sync;
    };
}
