defmodule BabelSync.Sources.ScriptTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sources.Script

  @note """
  ---
  type: source
  schedule: every 6h
  hosts:
    - api.github.com
  secrets:
    github: { host: api.github.com, header: "Authorization: Bearer {}" }
  writes:
    - Github/Stars
  params:
    user: jbott
  ---
  Keeps one note per star.

  ```js
  log("hello")
  ```

  ```js
  log("not this one")
  ```
  """

  test "reads the manifest and the first js block" do
    assert {:ok, script} = Script.parse(@note)
    assert script.code == ~s|log("hello")\n|
    assert script.schedule == 21_600
    assert script.hosts == ["api.github.com"]
    assert script.writes == ["Github/Stars"]
    assert script.params == %{"user" => "jbott"}

    assert script.secrets == %{
             "github" => %{host: "api.github.com", header: "Authorization", template: "Bearer {}"}
           }
  end

  test "comes back the same from the manifest it is stored as" do
    {:ok, script} = Script.parse(@note)

    assert Script.from_manifest(Script.manifest(script), script.code) == script
  end

  test "its hash changes with the code and with what it may do, not with the prose" do
    {:ok, script} = Script.parse(@note)
    {:ok, reworded} = Script.parse(String.replace(@note, "Keeps one note", "Makes a note"))
    {:ok, recoded} = Script.parse(String.replace(@note, "hello", "goodbye"))
    {:ok, regranted} = Script.parse(String.replace(@note, "Github/Stars", "Places"))

    assert Script.hash(reworded) == Script.hash(script)
    refute Script.hash(recoded) == Script.hash(script)
    refute Script.hash(regranted) == Script.hash(script)
  end

  test "a note that is not a source is told so" do
    refute Script.source?("# just a note")
    assert Script.source?(@note)
    assert {:error, [_problem]} = Script.parse("---\ntype: recipe\n---\n```js\n1\n```\n")
  end

  test "lists everything wrong with a manifest" do
    note = """
    ---
    type: source
    schedule: every 10s
    hosts: [GitHub.com, "https://x.com/path"]
    writes: [".obsidian/plugins", "../up"]
    ---
    ```js
    1
    ```
    """

    assert {:error, problems} = Script.parse(note)
    assert length(problems) == 3
  end

  test "refuses a property it does not know rather than ignore it" do
    note = "---\ntype: source\nhost: api.github.com\n---\n```js\n1\n```\n"

    assert {:error, ["host is not something a source can be given"]} = Script.parse(note)
  end

  test "refuses a secret for a host the source may not reach" do
    note = """
    ---
    type: source
    hosts: [api.github.com]
    secrets:
      token: { host: evil.example, header: "Authorization: {}" }
    ---
    ```js
    1
    ```
    """

    assert {:error, [problem]} = Script.parse(note)
    assert problem =~ "evil.example"
  end

  test "a note without code is a problem" do
    assert {:error, ["the note has no js code block"]} = Script.parse("---\ntype: source\n---\n")
  end
end
