{
  lib,
  callPackages,
  beamPackages,
  rustPlatform,
  cargo,
  rustc,
  nodejs_24,
  fetchNpmDeps,
  npmHooks,
  tailwindcss_4,
  esbuild,
  removeReferencesTo,
  revision ? "unknown",
}:

let
  version = "0.1.0";

  sources =
    files:
    lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions files;
    };

  packages = [
    ../package.json
    ../package-lock.json
    ../assets/package.json
    ../js/core/package.json
    ../plugin/package.json
  ];

  builtFromVendoredCrates =
    {
      crate,
      hash,
      env ? { },
      jason,
    }:
    dependency:
    let
      crates = rustPlatform.fetchCargoVendor {
        name = "${crate}-crates";
        src = "${dependency.src}/native/${crate}";
        inherit hash;
      };
    in
    dependency.override (inherited: {
      beamDeps = inherited.beamDeps ++ [ jason ];
      mixCompileFlags = [ "--no-prune-code-paths" ];

      nativeBuildInputs = [
        cargo
        rustc
        removeReferencesTo
      ];

      env = env // {
        CARGO_NET_OFFLINE = "true";
      };

      preConfigure = ''
        export CARGO_HOME="$TMPDIR/cargo"
        mkdir -p native/${crate}/.cargo
        substitute ${crates}/.cargo/config.toml native/${crate}/.cargo/config.toml \
          --subst-var-by vendor ${crates}
      '';

      preBuild = "";

      postInstall = ''
        remove-references-to -t ${crates} $out/lib/erlang/lib/*/priv/native/*.so
      '';

      passthru = { inherit crates; };
    });

  mixNixDeps = callPackages ./deps.nix {
    inherit beamPackages;

    overrides = final: previous: {
      y_ex = builtFromVendoredCrates {
        inherit (final) jason;
        crate = "yex";
        hash = "sha256-y4kmCbkjrZbwGHXcDH+tl8uk3Z+79TDfDA/pBiPKJdc=";
      } previous.y_ex;

      mdex_native = builtFromVendoredCrates {
        inherit (final) jason;
        crate = "mdex_native_nif";
        hash = "sha256-oCTNstM214IHsqPEaLllP8VZrzGotqyudMJdXtuK2/I=";
        env.MDEX_NATIVE_BUILD = "1";
      } previous.mdex_native;

      exqlite = previous.exqlite.override {
        env.EXQLITE_FORCE_BUILD = "1";
        buildInputs = [ ];
      };
    };
  };

  buildOnly = [
    tailwindcss_4
    esbuild
    mixNixDeps.y_ex.crates
    mixNixDeps.mdex_native.crates
  ];
in
beamPackages.mixRelease {
  pname = "babel_sync";
  inherit version mixNixDeps;

  src = sources (
    packages
    ++ [
      ../mix.exs
      ../mix.lock
      ../config
      ../lib
      ../priv
      ../assets
      ../js/core/src
      ../js/core/tsconfig.json
      ../plugin/src
      ../plugin/esbuild.config.mjs
      ../plugin/manifest.json
      ../plugin/tsconfig.json
    ]
  );

  npmDeps = fetchNpmDeps {
    name = "babel_sync-npm-deps";
    src = sources packages;
    hash = "sha256-EHd3oa3cWKxWE5N+L9yPYCY2L1uKFby5xGtwdvGAEIo=";
  };

  nativeBuildInputs = [
    nodejs_24
    npmHooks.npmConfigHook
    removeReferencesTo
  ];

  env = {
    BABELSYNC_REVISION = revision;
    MIX_TAILWIND_PATH = lib.getExe tailwindcss_4;
    MIX_ESBUILD_PATH = lib.getExe esbuild;
  };

  postBuild = ''
    mix do deps.loadpaths --no-deps-check + assets.deploy
  '';

  postInstall = ''
    remove-references-to ${lib.concatMapStringsSep " " (path: "-t ${path}") buildOnly} \
      $out/releases/*/sys.config $out/lib/*/priv/native/*.so
  '';

  disallowedReferences = buildOnly;

  passthru = { inherit mixNixDeps; };

  meta = {
    description = "Self-hosted live sync server for Obsidian vaults";
    mainProgram = "babel_sync";
    platforms = lib.platforms.unix;
  };
}
