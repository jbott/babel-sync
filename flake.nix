{
  description = "BabelSync: live-syncing Obsidian vaults (Phoenix server, Obsidian plugin, MCP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        beam = pkgs.beam28Packages;
      in
      {
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
