{
  lib,
  beamPackages,
  cmake,
  extend,
  lexbor,
  fetchFromGitHub,
  oniguruma,
  overrides ? (x: y: { }),
  overrideFenixOverlay ? null,
  rustlerPrecompiledOverrides ? { },
  stdenv,
  pkg-config,
  sqlite,
  vips,
  writeText,
}:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;

  workarounds = {
    portCompiler = _unusedArgs: old: {
      buildPlugins = [ beamPackages.pc ];
    };

    rustlerPrecompiled =
      {
        toolchain ? null,
        buildInputs ? [ ],
        nativeBuildInputs ? [ ],
        env ? { },
        ...
      }:
      old:
      let
        extendedPkgs = extend fenixOverlay;
        fenixOverlay =
          if overrideFenixOverlay == null then
            import "${
              fetchTarball {
                url = "https://github.com/nix-community/fenix/archive/6399553b7a300c77e7f07342904eb696a5b6bf9d.tar.gz";
                sha256 = "sha256-C6tT7K1Lx6VsYw1BY5S3OavtapUvEnDQtmQB5DSgbCc=";
              }
            }/overlay.nix"
          else
            overrideFenixOverlay;
        nativeDir = "${old.src}/native/${with builtins; head (attrNames (readDir "${old.src}/native"))}";
        fenix =
          if toolchain == null then
            extendedPkgs.fenix.stable
          else
            extendedPkgs.fenix.fromToolchainName toolchain;
        native =
          (
            (extendedPkgs.makeRustPlatform {
              inherit (fenix) cargo rustc;
            }).buildRustPackage
            {
              inherit env buildInputs;
              pname = "${old.beamModuleName}-native";
              version = old.version;
              src = nativeDir;
              cargoLock = {
                lockFile = "${nativeDir}/Cargo.lock";
              };
              nativeBuildInputs = [ extendedPkgs.cmake ] ++ nativeBuildInputs;
              doCheck = false;
            }
          ).overrideAttrs
            rustlerPrecompiledOverrides.${old.beamModuleName} or { };

      in
      {
        nativeBuildInputs = [ extendedPkgs.cargo ];

        env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
        env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "unused-but-required";

        preConfigure = ''
          mkdir -p priv/native
          for lib in ${native}/lib/*
          do
            dest="$(basename "$lib")"
            if [[ "''${dest##*.}" = "dylib" ]]
            then
              dest="''${dest%.dylib}.so"
            fi
            dest="''${dest#lib}"
            ln -s "$lib" "priv/native/$dest"
          done
        '';

        preBuild = ''
          suggestion() {
            echo "***********************************************"
            echo "                 deps_nix                      "
            echo
            echo " Rust dependency build failed.                 "
            echo
            echo " If you saw network errors, you might need     "
            echo " to disable compilation on the appropriate     "
            echo " RustlerPrecompiled module in your             "
            echo " application config.                           "
            echo
            echo " We think you need this:                       "
            echo
            echo -n " "
            grep -Rl 'use RustlerPrecompiled' lib \
              | xargs grep 'defmodule' \
              | sed 's/defmodule \(.*\) do/config :${old.beamModuleName}, \1, skip_compilation?: true/'
            echo "***********************************************"
            exit 1
          }
          trap suggestion ERR
        '';
      };

    elixirMake = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';
    };

    lazyHtml = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';

      postPatch = ''
        substituteInPlace mix.exs \
          --replace-fail "Fine.include_dir()" '"${packages.fine}/src/c_include"' \
          --replace-fail '@lexbor_git_sha "244b84956a6dc7eec293781d051354f351274c46"' '@lexbor_git_sha ""'
      '';

      preBuild = ''
        install -Dm644           -t _build/c/third_party/lexbor/$LEXBOR_GIT_SHA/build           ${lexbor}/lib/liblexbor_static.a
      '';
    };
  };

  defaultOverrides = (
    final: prev:

    let
      apps = {
        crc32cer = [
          {
            name = "portCompiler";
          }
        ];
        explorer = [
          {
            name = "rustlerPrecompiled";
            toolchain = {
              name = "nightly-2025-06-23";
              sha256 = "sha256-UAoZcxg3iWtS+2n8TFNfANFt/GmkuOMDf7QAE0fRxeA=";
            };
          }
        ];
        snappyer = [
          {
            name = "portCompiler";
          }
        ];
      };

      applyOverrides =
        appName: drv:
        let
          allOverridesForApp = builtins.foldl' (
            acc: workaround: acc // (workarounds.${workaround.name} workaround) drv
          ) { } apps.${appName};

        in
        if builtins.hasAttr appName apps then drv.override allOverridesForApp else drv;

    in
    builtins.mapAttrs applyOverrides prev
  );

  self = packages // (defaultOverrides self packages) // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {

      anubis_mcp =
        let
          version = "2.2.0";
          drv = buildMix {
            inherit version;
            name = "anubis_mcp";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "anubis_mcp";
              sha256 = "073c1226a6787c85793261dd5037349b86c817e12b9fc14a06e927af090990db";
            };

            beamDeps = [
              finch
              jose
              peri
              plug
              telemetry
            ];
          };
        in
        drv;

      asn1_compiler =
        let
          version = "0.1.1";
          drv = buildMix {
            inherit version;
            name = "asn1_compiler";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "asn1_compiler";
              sha256 = "c250d24c22f1a3f305d88864400f9ac2df55c6886e1e3a030e2946efeb94695e";
            };
          };
        in
        drv;

      bandit =
        let
          version = "1.15.0";
          drv = buildMix {
            inherit version;
            name = "bandit";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "e3b29c4a5107f4bf7dfaa263c50b9b97ddcc132622197c110e2e10a921641c44";
            };

            beamDeps = [
              hpax
              plug
              telemetry
              thousand_island
              websock
            ];
          };
        in
        drv;

      cbor =
        let
          version = "1.0.2";
          drv = buildMix {
            inherit version;
            name = "cbor";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "cbor";
              sha256 = "edbc9b4a16eb93a582437b9b249c340a75af03958e338fb43d8c1be9fc65b864";
            };
          };
        in
        drv;

      cc_precompiler =
        let
          version = "0.1.11";
          drv = buildMix {
            inherit version;
            name = "cc_precompiler";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "cc_precompiler";
              sha256 = "3427232caf0835f94680e5bcf082408a70b48ad68a5f5c0b02a3bea9f3a075b9";
            };

            beamDeps = [
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

      db_connection =
        let
          version = "2.10.2";
          drv = buildMix {
            inherit version;
            name = "db_connection";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      decimal =
        let
          version = "3.2.0";
          drv = buildMix {
            inherit version;
            name = "decimal";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "190bca80580ce61aa69bb0eacadd7677710205c770225c2c2c07e32a5c31b234";
            };
          };
        in
        drv;

      ecto =
        let
          version = "3.14.3";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "da2548bd3ced0f56c27d54255389bbbb8f110150ce15cffc95ec0cafa364465c";
            };

            beamDeps = [
              decimal
              jason
              telemetry
            ];
          };
        in
        drv;

      ecto_sql =
        let
          version = "3.14.0";
          drv = buildMix {
            inherit version;
            name = "ecto_sql";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto_sql";
              sha256 = "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949";
            };

            beamDeps = [
              db_connection
              decimal
              ecto
              postgrex
              telemetry
            ];
          };
        in
        drv;

      ecto_sqlite3 =
        let
          version = "0.26.0";
          drv = buildMix {
            inherit version;
            name = "ecto_sqlite3";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "ecto_sqlite3";
              sha256 = "e04d69e185f27a604dd116144a1bad36595666546d753e9341a3f3736ee64772";
            };

            beamDeps = [
              decimal
              ecto
              ecto_sql
              exqlite
            ];
          };
        in
        drv;

      elixir_make =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "elixir_make";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "elixir_make";
              sha256 = "ce1eaa234bc87f0279718e793fd6f8ad35b4e8ee8d412329e3879eee8d40adba";
            };
          };
        in
        drv;

      esbuild =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "esbuild";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "esbuild";
              sha256 = "890f251330052dcacafa40c409769e7c42e3876fb0ae450707bde831be7b34ea";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      expo =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "expo";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "expo";
              sha256 = "5fb308b9cb359ae200b7e23d37c76978673aa1b06e2b3075d814ce12c5811640";
            };
          };
        in
        drv;

      exqlite =
        let
          version = "0.43.0";
          drv = buildMix {
            inherit version;
            name = "exqlite";
            appConfigPath = ../config;

            env.EXQLITE_USE_SYSTEM = "1";

            buildInputs = [
              sqlite
            ];

            src = fetchHex {
              inherit version;
              pkg = "exqlite";
              sha256 = "aa9996f5f582b01f641076632a03bfe139655606b2ba2c86bf528656adf22a5a";
            };

            beamDeps = [
              cc_precompiler
              db_connection
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

      finch =
        let
          version = "0.25.0";
          drv = buildMix {
            inherit version;
            name = "finch";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "9fd9a2c47a9033f4d70fad6e7d656948c08bc6652699de20e609a5917c0bb0a5";
            };

            beamDeps = [
              mime
              mint
              nimble_options
              nimble_pool
              telemetry
            ];
          };
        in
        drv;

      fine =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "fine";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "fine";
              sha256 = "6f69a9e8dadbfd017b27f611b000362870683ae65f28aec904f36ec4c5058db5";
            };
          };
        in
        drv;

      gen_smtp =
        let
          version = "1.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "gen_smtp";

            src = fetchHex {
              inherit version;
              pkg = "gen_smtp";
              sha256 = "0b73fbf069864ecbce02fe653b16d3f35fd889d0fdd4e14527675565c39d84e6";
            };

            beamDeps = [
              ranch
            ];
          };
        in
        drv;

      gettext =
        let
          version = "1.0.2";
          drv = buildMix {
            inherit version;
            name = "gettext";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "gettext";
              sha256 = "eab805501886802071ad290714515c8c4a17196ea76e5afc9d06ca85fb1bfeb3";
            };

            beamDeps = [
              expo
            ];
          };
        in
        drv;

      heroicons = stdenv.mkDerivation {
        name = "heroicons";
        src = fetchFromGitHub {
          owner = "tailwindlabs";
          repo = "heroicons";
          rev = "0435d4ca364a608cc75e2f8683d374e55abbae26";
          hash = "sha256-Jcxr1fSbmXO9bZKeg39Z/zVN0YJp17TX3LH5Us4lsZU=";
        };
        buildPhase = ''
          mkdir $out
          ln -sv $src $out/src
        '';
      };

      hpax =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "hpax";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "0b8d0f05832f55571d65ac720f79bf8994138ffbb133209dc4685eae0ad456a8";
            };
          };
        in
        drv;

      idna =
        let
          version = "8.0.0";
          drv = buildRebar3 {
            inherit version;
            name = "idna";

            src = fetchHex {
              inherit version;
              pkg = "idna";
              sha256 = "e0c5ce7846f14515af66142a55b8097d5f46d10df9235e781f168bef5622bcf9";
            };
          };
        in
        drv;

      jason =
        let
          version = "1.4.5";
          drv = buildMix {
            inherit version;
            name = "jason";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "jason";
              sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
            };

            beamDeps = [
              decimal
            ];
          };
        in
        drv;

      jose =
        let
          version = "1.11.13";
          drv = buildMix {
            inherit version;
            name = "jose";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "jose";
              sha256 = "15d8bd0f01ab29d1771e8da1f60f9c98725b23a17f7312cdd40e8e2757bd98c7";
            };
          };
        in
        drv;

      lazy_html =
        let
          version = "0.1.14";
          drv = buildMix {
            inherit version;
            name = "lazy_html";
            appConfigPath = ../config;

            buildInputs = [
              lexbor
            ];

            src = fetchHex {
              inherit version;
              pkg = "lazy_html";
              sha256 = "99210889b0cc591398d006def761f2faef438d1ac77d045a527791733571dc0c";
            };

            beamDeps = [
              cc_precompiler
              elixir_make
              fine
            ];
          };
        in
        drv.override (workarounds.lazyHtml { } drv);

      mdex =
        let
          version = "0.14.6";
          drv = buildMix {
            inherit version;
            name = "mdex";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "mdex";
              sha256 = "43d90e75c5e9c3c7317b8db1dcd344f72d4336a4f225ec259d42aa3deb5b122e";
            };

            beamDeps = [
              jason
              mdex_native
              nimble_options
              nimble_parsec
              phoenix_live_view
            ];
          };
        in
        drv;

      mdex_native =
        let
          version = "0.3.1";
          drv = buildMix {
            inherit version;
            name = "mdex_native";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "mdex_native";
              sha256 = "9354f08278d0f557d6eeabade28190360a9494511bb4637dc19fce53a636fe6d";
            };

            beamDeps = [
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      mime =
        let
          version = "2.0.7";
          drv = buildMix {
            inherit version;
            name = "mime";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "mime";
              sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
            };
          };
        in
        drv;

      mint =
        let
          version = "1.11.0";
          drv = buildMix {
            inherit version;
            name = "mint";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "c6279ba2d6aa3a383a1d4cfbe7b59f42e6efd400f58d8e2acfeac48a438693ab";
            };

            beamDeps = [
              hpax
            ];
          };
        in
        drv;

      nimble_options =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "nimble_options";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_options";
              sha256 = "3a784a75ef9e407619c8c9e98239b1acd29216deb737044a8c1063e2671ce6d9";
            };
          };
        in
        drv;

      nimble_parsec =
        let
          version = "1.4.2";
          drv = buildMix {
            inherit version;
            name = "nimble_parsec";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_parsec";
              sha256 = "4b21398942dda052b403bbe1da991ccd03a053668d147d53fb8c4e0efe09c973";
            };
          };
        in
        drv;

      nimble_pool =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "nimble_pool";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_pool";
              sha256 = "bc442e72578c21842589fa8e5886b6175fa5245fdbbad35fc08db277ac2b2c0d";
            };
          };
        in
        drv;

      oidcc =
        let
          version = "3.9.2";
          drv = buildMix {
            inherit version;
            name = "oidcc";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "oidcc";
              sha256 = "e469213a2518904e805ff4f8325a405ac740a74a381e711968d32636c10d9c9b";
            };

            beamDeps = [
              jose
              telemetry
              telemetry_registry
            ];
          };
        in
        drv;

      peri =
        let
          version = "0.11.3";
          drv = buildMix {
            inherit version;
            name = "peri";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "peri";
              sha256 = "de4500dccafea6102a5429d8419249e48fe8d1ea505c2da078b693915135d474";
            };

            beamDeps = [
              ecto
              jason
              phoenix_html
            ];
          };
        in
        drv;

      phoenix =
        let
          version = "1.8.16";
          drv = buildMix {
            inherit version;
            name = "phoenix";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "e7355c35889305bc539eb09dae2393abcbaf0f65f6874a3f0dcb5f0ec53737fe";
            };

            beamDeps = [
              bandit
              jason
              phoenix_pubsub
              phoenix_template
              plug
              plug_crypto
              telemetry
              websock_adapter
            ];
          };
        in
        drv;

      phoenix_ecto =
        let
          version = "4.7.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_ecto";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_ecto";
              sha256 = "1d75011e4254cb4ddf823e81823a9629559a1be93b4321a6a5f11a5306fbf4cc";
            };

            beamDeps = [
              ecto
              phoenix_html
              plug
              postgrex
            ];
          };
        in
        drv;

      phoenix_html =
        let
          version = "4.4.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_html";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html";
              sha256 = "94832038da7ab8f86d4c0d36f7797a269fd06fe611f25c69f55108c075505228";
            };
          };
        in
        drv;

      phoenix_live_dashboard =
        let
          version = "0.8.7";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_dashboard";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_dashboard";
              sha256 = "3a8625cab39ec261d48a13b7468dc619c0ede099601b084e343968309bd4d7d7";
            };

            beamDeps = [
              ecto
              mime
              phoenix_live_view
              telemetry_metrics
            ];
          };
        in
        drv;

      phoenix_live_view =
        let
          version = "1.2.14";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "1ca75ed52d3916f93299de990f152f3f49202d12849e526bf5f9b89b4ccf25f2";
            };

            beamDeps = [
              jason
              lazy_html
              phoenix
              phoenix_html
              phoenix_template
              plug
              telemetry
            ];
          };
        in
        drv;

      phoenix_pubsub =
        let
          version = "2.4.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "352fba7a87bf61395b6e97da66944ad9b1bfe5459e5981039f60d68270bd9700";
            };
          };
        in
        drv;

      phoenix_template =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_template";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_template";
              sha256 = "eba70070de79b2c3501ef205a74a69f98ab352f3785aa15da9ed161f9fe0fd5d";
            };

            beamDeps = [
              phoenix_html
            ];
          };
        in
        drv;

      plug =
        let
          version = "1.20.4";
          drv = buildMix {
            inherit version;
            name = "plug";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "96ee42c0b8b35bcb14e3e65afb85abe9bb7745a8576e8c602802bbb01e5acf72";
            };

            beamDeps = [
              mime
              plug_crypto
              telemetry
            ];
          };
        in
        drv;

      plug_crypto =
        let
          version = "2.2.1";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "4417ccbd8f85e627321cd07d2ab9c4b621f1fd883b9905af241f9b4b780b94b6";
            };
          };
        in
        drv;

      postgrex =
        let
          version = "0.22.4";
          drv = buildMix {
            inherit version;
            name = "postgrex";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "4aae45a2d60e35b04eea2602440be152fae332901f1fc7a60fc7cb7f0f9a9c5a";
            };

            beamDeps = [
              db_connection
              decimal
              jason
            ];
          };
        in
        drv;

      ranch =
        let
          version = "2.4.0";
          drv = buildRebar3 {
            inherit version;
            name = "ranch";

            src = fetchHex {
              inherit version;
              pkg = "ranch";
              sha256 = "64d98b8c61d39b7b9a2e2cf92ae659b8623a69766f415ae13dc726864ec04ab9";
            };
          };
        in
        drv;

      req =
        let
          version = "0.7.5";
          drv = buildMix {
            inherit version;
            name = "req";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "576853c4bf403faa3c1fa5d093e0759227083b78f8a6864c67d62c0a9c45514d";
            };

            beamDeps = [
              finch
              jason
              mime
              plug
            ];
          };
        in
        drv;

      rustler =
        let
          version = "0.38.0";
          drv = buildMix {
            inherit version;
            name = "rustler";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "rustler";
              sha256 = "704c03c1bf66be12b031c5a389347b91c81c5cb819a24b068b0de36fe4a5652a";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      rustler_precompiled =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "rustler_precompiled";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "rustler_precompiled";
              sha256 = "0efa66bc2a4206aec64a2c422ca0b1d69bdc411c7b359ec928feb889357b4abb";
            };

            beamDeps = [
              rustler
            ];
          };
        in
        drv;

      swoosh =
        let
          version = "1.30.0";
          drv = buildMix {
            inherit version;
            name = "swoosh";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "swoosh";
              sha256 = "d1b553f5264ae39fb299e0da12e01e33aaba49c2509757065ca3aef06e659b0c";
            };

            beamDeps = [
              bandit
              finch
              gen_smtp
              idna
              jason
              mime
              plug
              req
              telemetry
            ];
          };
        in
        drv;

      tailwind =
        let
          version = "0.5.2";
          drv = buildMix {
            inherit version;
            name = "tailwind";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "tailwind";
              sha256 = "e0e5fd9799fb9231b97e52ce074d9ff509043d1946713a71fbc608e81eff7e66";
            };
          };
        in
        drv;

      telemetry =
        let
          version = "1.4.3";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "17a63581cf2e832a238287f5fe6811e8ca1f333249f1376ad653164a3c4770d4";
            };
          };
        in
        drv;

      telemetry_metrics =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "telemetry_metrics";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "telemetry_metrics";
              sha256 = "71dde12fc29b58b9c77ec17ec319109e5ca848d010fc1965ed4463bba1837c07";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      telemetry_poller =
        let
          version = "1.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry_poller";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_poller";
              sha256 = "51f18bed7128544a50f75897db9974436ea9bfba560420b646af27a9a9b35211";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      telemetry_registry =
        let
          version = "0.3.2";
          drv = buildMix {
            inherit version;
            name = "telemetry_registry";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "telemetry_registry";
              sha256 = "e7ed191eb1d115a3034af8e1e35e4e63d5348851d556646d46ca3d1b4e16bab9";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      thousand_island =
        let
          version = "1.6.0";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "4d4720470f091fc21a1311777c2ac66916c43621bffc068590c9f9bb3cd057a3";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      wasmex =
        let
          version = "0.16.0";
          drv = buildMix {
            inherit version;
            name = "wasmex";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "wasmex";
              sha256 = "80818435de82651162923d173f7ee01c2b96203b1a6b83c2816aa0bc2b861fda";
            };

            beamDeps = [
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      wax_ =
        let
          version = "0.7.0";
          drv = buildMix {
            inherit version;
            name = "wax_";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "wax_";
              sha256 = "473b3378608418747e67746b7164576f1690a4ed1e044a4c8085a754269d21ce";
            };

            beamDeps = [
              asn1_compiler
              cbor
              jason
              x509
            ];
          };
        in
        drv;

      websock =
        let
          version = "0.5.3";
          drv = buildMix {
            inherit version;
            name = "websock";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "websock";
              sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
            };
          };
        in
        drv;

      websock_adapter =
        let
          version = "0.7.2";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "f9e80710008783864177c81e9d8418d05769ce10a26e9e538f5ed72e283f7358";
            };

            beamDeps = [
              bandit
              plug
              websock
            ];
          };
        in
        drv;

      x509 =
        let
          version = "0.9.2";
          drv = buildMix {
            inherit version;
            name = "x509";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "x509";
              sha256 = "4c5ede75697e565d4b0f5be04c3b71bb1fd3a090ea243af4bd7dae144e48cfc7";
            };
          };
        in
        drv;

      y_ex =
        let
          version = "0.13.0";
          drv = buildMix {
            inherit version;
            name = "y_ex";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "y_ex";
              sha256 = "92a90c9ad6cac6ea52f8a2eca279ca03c35fa6e900020896a0efc833b26cf691";
            };

            beamDeps = [
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      yamerl =
        let
          version = "0.10.0";
          drv = buildRebar3 {
            inherit version;
            name = "yamerl";

            src = fetchHex {
              inherit version;
              pkg = "yamerl";
              sha256 = "346adb2963f1051dc837a2364e4acf6eb7d80097c0f53cbdc3046ec8ec4b4e6e";
            };
          };
        in
        drv;

      yaml_elixir =
        let
          version = "2.12.2";
          drv = buildMix {
            inherit version;
            name = "yaml_elixir";
            appConfigPath = ../config;

            src = fetchHex {
              inherit version;
              pkg = "yaml_elixir";
              sha256 = "e7c1b10122f973e6558462d51c39026ba0e14afbc6745318e990ea82cfe9e159";
            };

            beamDeps = [
              yamerl
            ];
          };
        in
        drv;

    };
in
self
