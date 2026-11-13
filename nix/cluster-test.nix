{ babelsync }:
{ lib, pkgs, ... }:

let
  settings = name: {
    PHX_SERVER = "true";
    PORT = "4000";
    BABELSYNC_MODE = "single";
    BABELSYNC_STORAGE = "remote";
    BABELSYNC_AUTH = "none";
    BABELSYNC_BIND = "all";
    BABELSYNC_TRUST_NETWORK = "true";
    BABELSYNC_DATA_DIR = "/var/lib/babelsync";
    BABELSYNC_S3_ENDPOINT = "http://db:7070";
    BABELSYNC_S3_BUCKET = "babelsync";
    BABELSYNC_S3_REGION = "us-east-1";
    BABELSYNC_S3_ACCESS_KEY_ID = "babelsync";
    BABELSYNC_S3_SECRET_ACCESS_KEY = "babelsyncsecret";
    DATABASE_URL = "ecto://babelsync@db/babelsync";
    SECRET_KEY_BASE = lib.concatStrings (lib.replicate 8 "clustertest");
    RELEASE_DISTRIBUTION = "sname";
    RELEASE_NODE = "babelsync@${name}";
    RELEASE_COOKIE = "clustertest";
    RELEASE_TMP = "/tmp";
    HOME = "/var/lib/babelsync";
    LANG = "C.UTF-8";
  };

  server =
    name:
    { ... }:
    {
      networking.firewall.enable = false;
      environment.systemPackages = [
        pkgs.curl
        pkgs.iptables
        (pkgs.writeShellScriptBin "babelsync-rpc" ''
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}") (settings name))}
          exec ${lib.getExe babelsync} rpc "$1"
        '')
      ];

      systemd.services.babelsync = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = settings name;
        serviceConfig = {
          ExecStart = "${lib.getExe babelsync} start";
          StateDirectory = "babelsync";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
    };
in
{
  name = "babelsync-cluster";

  nodes = {
    db =
      { ... }:
      {
        networking.firewall.enable = false;

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_18;
          enableTCPIP = true;
          ensureDatabases = [ "babelsync" ];
          ensureUsers = [
            {
              name = "babelsync";
              ensureDBOwnership = true;
            }
          ];
          authentication = ''
            host all all 0.0.0.0/0 trust
            host all all ::/0 trust
          '';
        };

        systemd.services.s3 = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            StateDirectory = "s3";
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/s3/babelsync";
            ExecStart = "${lib.getExe pkgs.versitygw} --access babelsync --secret babelsyncsecret --port :7070 posix /var/lib/s3";
          };
        };
      };

    one = server "one";
    two = server "two";
  };

  testScript = ''
    import json
    import shlex
    import time

    HEADERS = (
        "-H 'content-type: application/json' "
        "-H 'accept: application/json, text/event-stream' "
    )


    def post(server, body, session=None):
        headers = HEADERS
        if session:
            headers += f"-H 'mcp-session-id: {session}' -H 'mcp-protocol-version: 2025-06-18' "
        return server.succeed(
            f"curl -sS --max-time 30 -D /tmp/headers {headers} "
            f"http://localhost:4000/mcp -d {shlex.quote(json.dumps(body))}"
        )


    def open_session(server):
        post(server, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "cluster-test", "version": "1"},
            },
        })
        session = server.succeed(
            "grep -i '^mcp-session-id' /tmp/headers | tr -d '\\r' | cut -d' ' -f2"
        ).strip()
        assert session, "no session id"
        post(server, {"jsonrpc": "2.0", "method": "notifications/initialized"}, session)
        return session


    def call(server, session, tool, arguments):
        out = post(server, {
            "jsonrpc": "2.0", "id": int(time.time() * 1000), "method": "tools/call",
            "params": {"name": tool, "arguments": arguments},
        }, session)
        data = [line[6:] for line in out.splitlines() if line.startswith("data: ")]
        assert data, f"no reply from {tool}: {out}"
        result = json.loads(data[-1])["result"]
        text = "\n".join(part.get("text", "") for part in result["content"])
        assert not result.get("isError"), f"{tool} failed: {text}"
        return text


    def read(server, session):
        return call(server, session, "read_file", {"path": "shared.md"})


    def eventually(what, check, seconds):
        deadline = time.time() + seconds
        while True:
            if check():
                return
            assert time.time() < deadline, f"timed out waiting for {what}"
            time.sleep(1)


    def sees(server, other):
        return f"babelsync@{other}" in server.succeed("babelsync-rpc 'IO.inspect(Node.list())'")


    def cut(server, other, rule):
        server.succeed(f"iptables -{rule} INPUT -s {other} -j DROP")
        server.succeed(f"iptables -{rule} OUTPUT -d {other} -j DROP")


    start_all()
    db.wait_for_unit("postgresql.service")
    db.wait_for_open_port(5432)
    db.wait_for_open_port(7070)

    for server in [one, two]:
        server.wait_until_succeeds("curl -sf http://localhost:4000/health", timeout=180)

    with subtest("the servers find each other through the database"):
        eventually("one to see two", lambda: sees(one, "two"), 60)
        eventually("two to see one", lambda: sees(two, "one"), 60)

    with subtest("two servers asked for the owner at once agree on one"):
        one.succeed("curl -sf http://localhost:4000/ -o /dev/null & curl -sf http://two:4000/ -o /dev/null; wait")
        one.succeed(
            "babelsync-rpc '1 = BabelSync.Repo.aggregate(BabelSync.Accounts.User, :count)'"
        )

    one.succeed(
        "babelsync-rpc '{:ok, _} = BabelSync.Vaults.create_vault("
        "BabelSync.Accounts.single_user!(), %{name: \"Shared\"})'"
    )
    session = open_session(one)

    with subtest("a session opened on one server is served by the other"):
        call(one, session, "write_file", {"path": "shared.md", "content": "written through one\n"})
        call(two, session, "append_file", {"path": "shared.md", "content": "added through two\n"})

    with subtest("an edit taken by one server shows in the note open on the other"):
        eventually(
            "one to show what two added",
            lambda: "added through two" in read(one, session), 10,
        )
        call(one, session, "append_file", {"path": "shared.md", "content": "added through one\n"})
        eventually(
            "two to show what one added",
            lambda: "added through one" in read(two, session), 10,
        )

    with subtest("servers that cannot see each other still end with the same text"):
        cut(one, "two", "I")
        cut(two, "one", "I")
        call(one, session, "append_file", {"path": "shared.md", "content": "one, cut off\n"})
        call(two, session, "append_file", {"path": "shared.md", "content": "two, cut off\n"})
        for server in [one, two]:
            eventually(
                "a cut-off server to read the other's edit from the database",
                lambda: all(
                    line in read(server, session) for line in ["one, cut off", "two, cut off"]
                ),
                120,
            )
        cut(one, "two", "D")
        cut(two, "one", "D")
        eventually("one to see two again", lambda: sees(one, "two"), 120)
        call(one, session, "append_file", {"path": "shared.md", "content": "together again\n"})
        eventually(
            "two to show an edit made after the cut healed",
            lambda: "together again" in read(two, session), 60,
        )

    with subtest("one server restarts while the other carries on"):
        one.succeed("systemctl stop babelsync")
        call(two, session, "append_file", {"path": "shared.md", "content": "while one was down\n"})
        one.succeed("systemctl start babelsync")
        one.wait_until_succeeds("curl -sf http://localhost:4000/health", timeout=180)
        eventually("one to rejoin", lambda: sees(two, "one"), 60)
        text = read(one, session)
        for line in [
            "written through one", "added through two", "added through one",
            "one, cut off", "two, cut off", "together again", "while one was down",
        ]:
            assert text.count(line) == 1, f"{line!r} appears {text.count(line)} times in:\n{text}"

    with subtest("both servers hold the same text and a sane history"):
        eventually("the texts to match", lambda: read(one, session) == read(two, session), 60)
        print(call(two, session, "file_history", {"path": "shared.md"}))
  '';
}
