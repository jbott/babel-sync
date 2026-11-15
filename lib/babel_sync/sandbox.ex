defmodule BabelSync.Sandbox do
  @moduledoc """
  Runs a script that nobody has reason to trust.

  The script is JavaScript, interpreted by QuickJS compiled to
  WebAssembly. It has no clock to wait on, no files, no network and no
  way to load code: the one thing it can do besides compute is call
  `__host(op, payload)`, which hands two strings to the `handler` given
  here and returns the string it answers with, or throws the error.

  Three things stop a script that will not stop by itself. The
  interpreter is given a budget of instructions and a ceiling on memory;
  the call into it is given a deadline; and the process that owns it is
  killed at that deadline, which also ends a handler that is waiting on
  something. The call's own deadline matters even then: without it the
  interpreter would go on spinning on a thread of its own after its
  owner was gone.
  """

  alias BabelSync.Sandbox.Guest

  @type handler :: (op :: String.t(), payload :: String.t() ->
                      {:ok, String.t()} | {:error, String.t()})
  @type refusal ::
          {:script, String.t()} | :out_of_time | :out_of_fuel | {:crashed, term()}

  @defaults [deadline: 60_000, fuel: 20_000_000_000, memory: 64 * 1024 * 1024]
  @stack 1024 * 1024
  @no_such_file 8

  @spec run(String.t(), handler(), keyword()) :: {:ok, String.t()} | {:error, refusal()}
  def run(source, handler, limits \\ []) do
    limits = Keyword.merge(@defaults, limits)
    caller = self()

    {runner, monitor} =
      spawn_monitor(fn -> send(caller, {:ran, self(), evaluate(source, handler, limits)}) end)

    receive do
      {:ran, ^runner, outcome} ->
        Process.demonitor(monitor, [:flush])
        outcome

      {:DOWN, ^monitor, :process, ^runner, reason} ->
        {:error, {:crashed, reason}}
    after
      limits[:deadline] ->
        Process.exit(runner, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^runner, _killed} -> {:error, :out_of_time}
        end
    end
  end

  defp evaluate(source, handler, limits) do
    Process.flag(:trap_exit, true)
    {engine, module} = Guest.compiled()

    {:ok, store} =
      Wasmex.Store.new(
        %Wasmex.StoreLimits{memory_size: limits[:memory], instances: 1, tables: 1, memories: 1},
        engine
      )

    :ok = Wasmex.StoreOrCaller.set_fuel(store, limits[:fuel])
    {:ok, guest} = Wasmex.start_link(%{store: store, module: module, imports: imports(handler)})
    {:ok, memory} = Wasmex.memory(guest)

    with {:ok, []} <- Wasmex.call_function(guest, "_initialize", []),
         {:ok, [0]} <- Wasmex.call_function(guest, "sb_init", [0, @stack]),
         {:ok, [at]} <- Wasmex.call_function(guest, "sb_alloc", [byte_size(source)]),
         :ok <- Wasmex.Memory.write_binary(store, memory, at, source),
         {:ok, [status]} <-
           Wasmex.call_function(guest, "sb_eval", [at, byte_size(source)], limits[:deadline]) do
      {:ok, [result]} = Wasmex.call_function(guest, "sb_result_ptr", [])
      {:ok, [length]} = Wasmex.call_function(guest, "sb_result_len", [])
      text = Wasmex.Memory.read_binary(store, memory, result, length)
      if status == 0, do: {:ok, text}, else: {:error, {:script, text}}
    else
      {:error, reason} -> {:error, trapped(reason)}
      other -> {:error, {:crashed, other}}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :out_of_time}
    :exit, reason -> {:error, {:crashed, reason}}
  end

  defp trapped(reason) when is_binary(reason) do
    cond do
      reason =~ "fuel" -> :out_of_fuel
      reason =~ "interrupt" -> :out_of_time
      reason =~ "call stack exhausted" -> {:script, "too much recursion"}
      true -> {:crashed, reason}
    end
  end

  defp trapped(reason), do: {:crashed, reason}

  defp imports(handler) do
    %{
      "host" => %{
        "call" =>
          {:fn, [:i32, :i32, :i32, :i32], [:i32],
           fn %{memory: memory, caller: caller}, op, op_length, payload, payload_length ->
             op = Wasmex.Memory.read_binary(caller, memory, op, op_length)
             payload = Wasmex.Memory.read_binary(caller, memory, payload, payload_length)

             case answer(handler, op, payload) do
               {:ok, reply} ->
                 Process.put(__MODULE__, reply)
                 byte_size(reply)

               {:error, message} ->
                 Process.put(__MODULE__, message)
                 -(byte_size(message) + 1)
             end
           end},
        "take" =>
          {:fn, [:i32], [],
           fn %{memory: memory, caller: caller}, at ->
             :ok = Wasmex.Memory.write_binary(caller, memory, at, Process.delete(__MODULE__))
             nil
           end}
      },
      "wasi_snapshot_preview1" => %{
        "clock_time_get" =>
          {:fn, [:i32, :i64, :i32], [:i32],
           fn %{memory: memory, caller: caller}, _clock, _precision, at ->
             now = System.os_time(:nanosecond)
             :ok = Wasmex.Memory.write_binary(caller, memory, at, <<now::little-64>>)
             0
           end},
        "fd_close" => {:fn, [:i32], [:i32], fn _context, _fd -> @no_such_file end},
        "fd_fdstat_get" =>
          {:fn, [:i32, :i32], [:i32], fn _context, _fd, _at -> @no_such_file end},
        "fd_seek" =>
          {:fn, [:i32, :i64, :i32, :i32], [:i32],
           fn _context, _fd, _offset, _whence, _at -> @no_such_file end},
        "fd_write" =>
          {:fn, [:i32, :i32, :i32, :i32], [:i32],
           fn _context, _fd, _vectors, _count, _written -> @no_such_file end}
      }
    }
  end

  defp answer(handler, op, payload) do
    handler.(op, payload)
  rescue
    error -> {:error, Exception.message(error)}
  end
end
