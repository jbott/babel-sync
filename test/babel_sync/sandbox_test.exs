defmodule BabelSync.SandboxTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sandbox

  defp refuse(_op, _payload), do: {:error, "nothing to call"}

  test "gives back what the script evaluates to" do
    assert {:ok, "42"} = Sandbox.run("6 * 7", &refuse/2)
  end

  test "hands host calls to the handler and returns its answer" do
    echo = fn op, payload -> {:ok, op <> ":" <> String.upcase(payload)} end

    assert {:ok, "greet:HELLO"} = Sandbox.run(~s|__host("greet", "hello")|, echo)
  end

  test "carries text of every size and script through a host call" do
    large = String.duplicate("häßlich ☃ ", 100_000)

    assert {:ok, ^large} =
             Sandbox.run(~s|__host("read", "")|, fn "read", "" -> {:ok, large} end)
  end

  test "a refused host call is an error the script can catch" do
    script = ~s|try { __host("x", "") } catch (error) { "caught " + error.message }|

    assert {:ok, "caught nothing to call"} = Sandbox.run(script, &refuse/2)
  end

  test "a handler that raises is an error in the script, not a crash" do
    script = ~s|try { __host("x", "") } catch (error) { "caught " + error.message }|

    assert {:ok, "caught boom"} = Sandbox.run(script, fn _op, _payload -> raise "boom" end)
  end

  test "a script that throws reports its message" do
    assert {:error, {:script, message}} = Sandbox.run(~s|throw new Error("no good")|, &refuse/2)
    assert message =~ "no good"
  end

  test "offers nothing but the language and the host call" do
    script = """
    ["std", "os", "process", "require", "fetch", "console", "setTimeout", "WebAssembly"]
      .filter(name => typeof globalThis[name] !== "undefined").join(",")
    """

    assert {:ok, ""} = Sandbox.run(script, &refuse/2)
  end

  test "stops a script that never ends when its fuel runs out" do
    assert {:error, :out_of_fuel} =
             Sandbox.run("while (true) {}", &refuse/2, fuel: 50_000_000)
  end

  test "stops a script that never ends at its deadline" do
    started = System.monotonic_time(:millisecond)

    assert {:error, :out_of_time} = Sandbox.run("while (true) {}", &refuse/2, deadline: 300)
    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  test "stops a handler that never answers at the deadline" do
    waiting = fn _op, _payload ->
      receive do
        :never -> {:ok, ""}
      end
    end

    assert {:error, :out_of_time} = Sandbox.run(~s|__host("wait", "")|, waiting, deadline: 300)
  end

  test "a script that takes all the memory it may is told so" do
    script = "const all = []; while (true) all.push(new Array(100000).fill(1))"

    assert {:error, {:script, message}} = Sandbox.run(script, &refuse/2, memory: 16 * 1024 * 1024)
    assert message =~ "out of memory"
  end

  test "endless recursion ends the script" do
    assert {:error, {:script, _message}} = Sandbox.run("const f = () => f(); f()", &refuse/2)
  end

  test "one run cannot see what another left behind" do
    assert {:ok, "1"} = Sandbox.run("globalThis.kept = 1; kept", &refuse/2)
    assert {:ok, "undefined"} = Sandbox.run("typeof kept", &refuse/2)
  end
end
