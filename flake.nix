{
  description = "Babel Sync: live-syncing Obsidian vaults (Phoenix server, Obsidian plugin, MCP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nix2container,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        beam = pkgs.beam28Packages;

        release =
          packages: beamPackages:
          packages.callPackage ./nix/package.nix {
            revision = self.shortRev or self.dirtyShortRev or "unknown";
            beamPackages = beamPackages.overrideScope (
              final: previous: { elixir = previous.elixir_1_20; }
            );
          };

        linux = import nixpkgs { system = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux"; };
      in
      {
        packages = {
          default = release pkgs pkgs.beam28Packages;

          container = pkgs.callPackage ./nix/container.nix {
            inherit (nix2container.packages.${system}) nix2container;
            babelsync = release linux linux.beamMinimal28Packages;
            architecture = linux.go.GOARCH;
            inherit (linux) cacert coreutils;
            inherit (linux) runCommand writeShellApplication;
          };
        };

        devShells.default = pkgs.mkShell {
          packages =
            [
              beam.elixir_1_20
              beam.erlang
              pkgs.nodejs_24
              pkgs.rustc
              pkgs.cargo
              pkgs.sqlite
              pkgs.postgresql_18
              pkgs.versitygw
              pkgs.git
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.inotify-tools ];

          shellHook = ''
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"
            export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$HEX_HOME/bin:$PATH"
            export ERL_AFLAGS="-kernel shell_history enabled"
            export LANG="''${LANG:-en_US.UTF-8}"

            export PGPORT="''${PGPORT:-54329}"

            if [ -d .git ] && [ "$(git config --local core.hooksPath)" != ".githooks" ]; then
              git config --local core.hooksPath .githooks
            fi
          '';
        };
      }
    );
}
