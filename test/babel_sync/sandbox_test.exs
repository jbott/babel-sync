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

  describe "a module" do
    defp files(files) do
      fn
        "module", name -> Map.fetch(files, name) |> or_missing(name)
        "say", text -> {:ok, text}
      end
    end

    defp or_missing({:ok, code}, _name), do: {:ok, code}
    defp or_missing(:error, name), do: {:error, "no file #{name}"}

    test "finds what the setup script put in place" do
      setup = ~s|const said = []; const say = (text) => { said.push(__host("say", text)) }|

      assert {:ok, ""} =
               Sandbox.run_module(setup, "main.js", ~s|say("hello")|, files(%{}))
    end

    test "imports others, each named from beside the one importing it" do
      files = %{
        "Data/lib/words.js" =>
          ~s|import { loud } from "./shout.js"; export const word = loud("hi")|,
        "Data/lib/shout.js" => ~s|export const loud = (text) => text.toUpperCase()|
      }

      main = ~s|import { word } from "../lib/words.js"; if (word !== "HI") throw new Error(word)|

      assert {:ok, ""} = Sandbox.run_module("", "Data/Github/Stars.js", main, files(files))
    end

    test "that imports what the handler refuses reports why" do
      assert {:error, {:script, message}} =
               Sandbox.run_module("", "Data/a.js", ~s|import "./gone.js"|, files(%{}))

      assert message =~ "no file Data/gone.js"
    end

    test "that throws reports the message and the line it was on" do
      main = ~s|const one = 1\nthrow new Error("no good")\n|

      assert {:error, {:script, message}} = Sandbox.run_module("", "Data/a.js", main, files(%{}))
      assert message =~ "no good"
      assert message =~ "Data/a.js:2"
    end

    test "that fails while waiting reports it" do
      main = ~s|await Promise.reject(new Error("later"))|

      assert {:error, {:script, message}} = Sandbox.run_module("", "a.js", main, files(%{}))
      assert message =~ "later"
    end

    test "that waits on what never comes is ended" do
      assert {:error, {:script, message}} =
               Sandbox.run_module("", "a.js", "await new Promise(() => {})", files(%{}))

      assert message =~ "never come"
    end

    test "is not run when its setup fails" do
      assert {:error, {:script, message}} =
               Sandbox.run_module(
                 "throw new Error('setup')",
                 "a.js",
                 ~s|__host("say", "x")|,
                 fn _, _ ->
                   raise "ran"
                 end
               )

      assert message =~ "setup"
    end

    test "that never ends is stopped like any script" do
      assert {:error, :out_of_fuel} =
               Sandbox.run_module("", "a.js", "for (;;) {}", files(%{}), fuel: 50_000_000)
    end
  end
end
