{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Neovim nightly from master
    neovim-nightly-overlay = {
      url = "github:nix-community/neovim-nightly-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, neovim-nightly-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # nightly nvim package from the overlay (built from Neovim master)
        nvimNightly = neovim-nightly-overlay.packages.${system}.default;

        # One meta-package with everything you listed
        env = pkgs.buildEnv {
          name = "my-env";
          paths = [
            # shells & editors
            pkgs.fish nvimNightly pkgs.tmux
	    pkgs.lazygit

            # CLI utils
            pkgs.ripgrep pkgs.fzf pkgs.fd pkgs.jq pkgs.yq-go pkgs.htop pkgs.bat

            # DB & clients
            pkgs.sqlite pkgs.pgcli

            # Containers
            pkgs.podman

            # WebAssembly runtime
            pkgs.wasmtime

            # Go toolchain + LSP
            pkgs.go_1_25 pkgs.gopls

            # Rust toolchain & tools (from nixpkgs)
            pkgs.rustc pkgs.cargo pkgs.rustfmt pkgs.clippy pkgs.rust-analyzer

            # JS/TS
            pkgs.nodejs_24 pkgs.pnpm

            # JVM & build
            pkgs.jdk25 pkgs.kotlin pkgs.gradle
          ];
        };
        # Helper so `nix run .#sync` installs/upgrades the env
	sync = pkgs.writeShellApplication {
	  name = "sync";
	  runtimeInputs = [ pkgs.nix ];
	  text = ''
	    set -euo pipefail
	    nix --extra-experimental-features 'nix-command flakes' \
	      profile install "path:${self}#env"
	    echo
	    echo "Synced ${self}#env into this user's profile."
	    nix profile list
	  '';
	};
      in {
        packages.env = env;
        apps.sync = { type = "app"; program = "${sync}/bin/sync"; };
      });
}

