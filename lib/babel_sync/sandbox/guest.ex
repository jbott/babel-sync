defmodule BabelSync.Sandbox.Guest do
  @moduledoc """
  The interpreter every sandbox runs: QuickJS, built for WebAssembly by
  `nix/sandbox-guest.nix` and compiled to machine code once on each
  server, the first time a script runs there.
  """

  @spec compiled() :: {Wasmex.Engine.t(), Wasmex.Module.t()}
  def compiled do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> compile()
      compiled -> compiled
    end
  end

  @spec path() :: Path.t()
  def path do
    Application.get_env(:babel_sync, :sandbox_guest) ||
      Application.app_dir(:babel_sync, "priv/sandbox/guest.wasm")
  end

  defp compile do
    {:ok, engine} =
      Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true, wasm_component_model: false})

    {:ok, store} = Wasmex.Store.new(nil, engine)
    {:ok, module} = Wasmex.Module.compile(store, File.read!(path()))
    :persistent_term.put(__MODULE__, {engine, module})
    {engine, module}
  end
end
