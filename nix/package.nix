{
  lib,
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
}:

let
  version = "0.1.0";

  sources =
    files:
    lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions files;
    };

  manifest = [
    ../mix.exs
    ../mix.lock
    ../config
  ];

  packages = [
    ../package.json
    ../package-lock.json
    ../assets/package.json
    ../js/core/package.json
    ../plugin/package.json
  ];

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "babel_sync-mix-deps";
    inherit version;
    src = sources manifest;
    hash = "sha256-/z3gqwiFIhe7RVHQpd2NKgdCcLQq9MKQ1jgO8MbttsU=";
  };

  crates =
    {
      name,
      path,
      hash,
    }:
    rustPlatform.fetchCargoVendor {
      name = "${name}-crates";
      src = "${mixFodDeps}/${path}";
      inherit hash;
    };

  nifs = [
    {
      path = "y_ex/native/yex";
      vendor = crates {
        name = "yex";
        path = "y_ex/native/yex";
        hash = "sha256-y4kmCbkjrZbwGHXcDH+tl8uk3Z+79TDfDA/pBiPKJdc=";
      };
    }
    {
      path = "mdex_native/native/mdex_native_nif";
      vendor = crates {
        name = "mdex_native_nif";
        path = "mdex_native/native/mdex_native_nif";
        hash = "sha256-oCTNstM214IHsqPEaLllP8VZrzGotqyudMJdXtuK2/I=";
      };
    }
  ];

  buildOnly = [
    tailwindcss_4
    esbuild
  ]
  ++ map (nif: nif.vendor) nifs;

  useVendoredCrates = lib.concatMapStrings (nif: ''
    mkdir -p "$MIX_DEPS_PATH/${nif.path}/.cargo"
    substitute ${nif.vendor}/.cargo/config.toml "$MIX_DEPS_PATH/${nif.path}/.cargo/config.toml" \
      --subst-var-by vendor ${nif.vendor}
  '') nifs;
in
beamPackages.mixRelease {
  pname = "babel_sync";
  inherit version mixFodDeps;

  src = sources (
    manifest
    ++ packages
    ++ [
      ../lib
      ../priv
      ../assets
      ../js/core/src
      ../js/core/tsconfig.json
    ]
  );

  npmDeps = fetchNpmDeps {
    name = "babel_sync-npm-deps";
    src = sources packages;
    hash = "sha256-7kcR/jiQXG2DBMXq5OqcDmemxndr/aEm+hHolCoHHYc=";
  };

  nativeBuildInputs = [
    cargo
    rustc
    nodejs_24
    npmHooks.npmConfigHook
    removeReferencesTo
  ];

  env = {
    MDEX_NATIVE_BUILD = "1";
    EXQLITE_FORCE_BUILD = "1";
    CARGO_NET_OFFLINE = "true";
    MIX_TAILWIND_PATH = lib.getExe tailwindcss_4;
    MIX_ESBUILD_PATH = lib.getExe esbuild;
  };

  preConfigure = useVendoredCrates;

  postBuild = ''
    mix do deps.loadpaths --no-deps-check + assets.deploy
  '';

  postInstall = ''
    remove-references-to ${lib.concatMapStringsSep " " (path: "-t ${path}") buildOnly} \
      $out/releases/*/sys.config $out/lib/*/priv/native/*.so
  '';

  disallowedReferences = buildOnly;

  passthru = { inherit mixFodDeps nifs; };

  meta = {
    description = "Self-hosted live sync server for Obsidian vaults";
    mainProgram = "babel_sync";
    platforms = lib.platforms.unix;
  };
}
