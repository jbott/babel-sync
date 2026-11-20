defmodule BabelSync.Sources.ScriptTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sources.Script

  @source """
  /* source
  schedule: every 6h
  hosts:
    - api.github.com
  secrets:
    github: { host: api.github.com, header: "Authorization: Bearer {}" }
  reads: [People]
  params:
    user: jbott
  */
  log("hello")
  """

  @path "Data/Github/Stars.js"

  test "is the file whole, with what it may do in the opening comment" do
    assert {:ok, script} = Script.parse(@source, @path)
    assert script.code == @source
    assert script.schedule == 21_600
    assert script.hosts == ["api.github.com"]
    assert script.reads == ["People"]
    assert script.params == %{"user" => "jbott"}

    assert script.secrets == %{
             "github" => %{host: "api.github.com", header: "Authorization", template: "Bearer {}"}
           }
  end

  test "writes in the folder beside it that has its name" do
    assert {:ok, %Script{writes: ["Data/Github/Stars"]}} = Script.parse(@source, @path)
    assert Script.name(@path, "Data") == "Github/Stars"
  end

  test "is a file in the sources folder whose name ends in .js" do
    assert Script.file?("Data/Github/Stars.js", "Data")
    assert Script.file?("data/Stars.JS", "Data")
    refute Script.file?("Data/Github/Stars.md", "Data")
    refute Script.file?("Database/Stars.js", "Data")
    refute Script.file?("Data.js", "Data")
    refute Script.file?("Data/Stars.js", nil)
  end

  test "is told from a file to import by how it opens" do
    assert Script.source?(@source)
    assert Script.source?("\n/* source */")
    refute Script.source?("export const one = 1\n")
    refute Script.source?("/* sources of truth */\n")
  end

  test "comes back the same from the manifest it is stored as" do
    {:ok, script} = Script.parse(@source, @path)

    assert Script.from_manifest(Script.manifest(script), script.code) == script
  end

  test "what it may do changes with the comment and with where it is, not with the code" do
    {:ok, script} = Script.parse(@source, @path)
    {:ok, recoded} = Script.parse(String.replace(@source, "hello", "goodbye"), @path)
    {:ok, regranted} = Script.parse(String.replace(@source, "People", "Places"), @path)
    {:ok, moved} = Script.parse(@source, "Data/Github/Mine.js")

    assert Script.manifest(recoded) == Script.manifest(script)
    refute Script.hash(recoded) == Script.hash(script)
    refute Script.manifest(regranted) == Script.manifest(script)
    refute Script.manifest(moved) == Script.manifest(script)
  end

  test "is gated when it is given a secret" do
    {:ok, script} = Script.parse(@source, @path)
    {:ok, open} = Script.parse("/* source\nhosts: [api.github.com]\n*/\n", @path)

    assert Script.gated?(script)
    refute Script.gated?(open)
  end

  test "connection grants require code approval and preserve existing manifests" do
    legacy =
      """
      {
        "schedule": null,
        "hosts": [],
        "secrets": {},
        "writes": [
          "Data/Account"
        ],
        "reads": [],
        "params": {}
      }
      """
      |> String.trim_trailing()

    old = Script.from_manifest(legacy, "log(1)")
    assert old.connections == []
    assert Script.manifest(old) == legacy
    refute Script.gated?(old)

    id = Ecto.UUID.generate()

    code =
      ~s|/* source\nconnections: [#{id}]\n*/\nconnections.get(#{Jason.encode!(id)}, "https://fixture.example/account")|

    assert {:ok, script} = Script.parse(code, "Data/Account.js")
    assert script.connections == [id]
    assert Script.gated?(script)
    assert Script.from_manifest(Script.manifest(script), code) == script
    refute Script.hash(script) == Script.hash(%{script | connections: []})

    assert {:error, ["connections is a list of connection UUIDs"]} =
             Script.parse("/* source\nconnections: [invalid]\n*/\n", @path)
  end

  test "without the comment is a problem" do
    assert {:error, [problem]} = Script.parse("log(1)\n", @path)
    assert problem =~ "/* source"
  end

  test "lists everything wrong with what it asks for" do
    source = """
    /* source
    schedule: every 10s
    hosts: [GitHub.com, "https://x.com/path"]
    reads: [".obsidian/plugins", "../up"]
    */
    """

    assert {:error, problems} = Script.parse(source, @path)
    assert length(problems) == 3
  end

  test "refuses a property it does not know rather than ignore it" do
    assert {:error, ["host is not something a source can be given"]} =
             Script.parse("/* source\nhost: x\n*/\n", @path)
  end

  test "says where a source writes when it is told where to" do
    assert {:error, [problem]} = Script.parse("/* source\nwrites: [Stars]\n*/\n", @path)
    assert problem =~ "folder beside it"
  end

  test "refuses a secret for a host the source may not reach" do
    source = """
    /* source
    hosts: [api.github.com]
    secrets:
      token: { host: evil.example, header: "Authorization: {}" }
    */
    """

    assert {:error, [problem]} = Script.parse(source, @path)
    assert problem =~ "evil.example"
  end
end
