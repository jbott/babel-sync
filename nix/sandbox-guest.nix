{
  pkgsCross,
  fetchzip,
}:

let
  quickjs = fetchzip {
    url = "https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0/quickjs-amalgam.zip";
    hash = "sha256-dT7aTz36HI5TXPBWP6+w8esPwxojmauLD7GpUF6g800=";
    stripRoot = false;
  };
in
pkgsCross.wasi32.stdenv.mkDerivation {
  pname = "babel_sync-sandbox-guest";
  version = "0.1.0";

  src = ../native/sandbox/guest.c;

  dontUnpack = true;
  dontConfigure = true;
  dontFixup = true;
  hardeningDisable = [ "all" ];

  buildPhase = ''
    $CC -O2 -DNDEBUG -mexec-model=reactor \
      -I${quickjs} \
      -Wl,-z,stack-size=2097152 -Wl,--stack-first -Wl,--strip-debug \
      -o guest.wasm $src ${quickjs}/quickjs-amalgam.c
  '';

  installPhase = ''
    mkdir -p $out
    cp guest.wasm $out/guest.wasm
  '';

  meta.description = "QuickJS built for WebAssembly, the interpreter Babel Sync runs sources in";
}
