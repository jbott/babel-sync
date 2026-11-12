{
  lib,
  nix2container,
  runCommand,
  writeShellApplication,
  coreutils,
  cacert,
  babelsync,
  architecture,
}:

let
  account = 1000;

  start = writeShellApplication {
    name = "babelsync";
    runtimeInputs = [ coreutils ];
    text = ''
      secret() {
        if [ ! -s "$1" ]; then
          mkdir -p "$(dirname "$1")"
          (umask 077 && head -c 48 /dev/urandom | base64 -w 0 > "$1")
        fi
        cat "$1"
      }

      export SECRET_KEY_BASE="''${SECRET_KEY_BASE:-$(secret "$BABELSYNC_DATA_DIR/secret_key_base")}"
      export RELEASE_COOKIE="''${RELEASE_COOKIE:-$(head -c 32 /dev/urandom | base64 -w 0)}"

      if [ "$#" -eq 0 ]; then set -- start; fi
      exec ${lib.getExe babelsync} "$@"
    '';
  };

  root = runCommand "babelsync-root" { } ''
    mkdir -p $out/data $out/tmp $out/etc/ssl/certs
    echo "babelsync:x:${toString account}:${toString account}:Babel Sync:/data:/sbin/nologin" > $out/etc/passwd
    echo "babelsync:x:${toString account}:" > $out/etc/group
    ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
  '';
in
nix2container.buildImage {
  name = "babelsync";
  tag = babelsync.version;
  arch = architecture;

  copyToRoot = [ root ];

  perms = [
    {
      path = root;
      regex = "/data";
      mode = "0750";
      uid = account;
      gid = account;
    }
    {
      path = root;
      regex = "/tmp";
      mode = "1777";
    }
  ];

  layers = [
    (nix2container.buildLayer { deps = [ babelsync ]; })
  ];

  config = {
    Entrypoint = [ (lib.getExe start) ];
    User = "${toString account}:${toString account}";
    WorkingDir = "/data";
    ExposedPorts."4000/tcp" = { };
    Volumes."/data" = { };
    Env = [
      "PHX_SERVER=true"
      "PORT=4000"
      "BABELSYNC_DATA_DIR=/data"
      "BABELSYNC_BIND=all"
      "BABELSYNC_AUTH=passkey"
      "RELEASE_DISTRIBUTION=none"
      "RELEASE_TMP=/tmp"
      "HOME=/data"
      "LANG=C.UTF-8"
    ];
    Labels = {
      "org.opencontainers.image.title" = "Babel Sync";
      "org.opencontainers.image.description" = babelsync.meta.description;
      "org.opencontainers.image.version" = babelsync.version;
    };
  };
}
