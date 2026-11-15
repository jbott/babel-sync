defmodule BabelSync.Sandbox do
  @moduledoc """
  Runs a script that nobody has reason to trust.

  The script is JavaScript, interpreted by QuickJS compiled to
  WebAssembly. It has no clock to wait on, no files and no network: the
  one thing it can do besides compute is call `__host(op, payload)`,
  which hands two strings to the `handler` given here and returns the
  string it answers with, or throws the error. Code it imports is asked
  of the same handler.

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
  def run(source, handler, limits \\ []), do: within(limits, &evaluate([source], handler, &1))

  @doc """
  Runs `code` as a module called `name`, after `setup` has run as a plain
  script to put in place whatever the module is to find.

  A module may import others. Each is asked of the handler as the op
  `module`, with the name it resolves to as the payload: a name that
  starts with a dot is taken from beside the module importing it. The
  handler answers with that module's code.
  """
  @spec run_module(String.t(), String.t(), String.t(), handler(), keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def run_module(setup, name, code, handler, limits \\ []),
    do: within(limits, &evaluate([setup, {name, code}], handler, &1))

  defp within(limits, work) do
    limits = Keyword.merge(@defaults, limits)
    caller = self()

    {runner, monitor} =
      spawn_monitor(fn -> send(caller, {:ran, self(), work.(limits)}) end)

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

  defp evaluate(steps, handler, limits) do
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
    held = %{guest: guest, store: store, memory: memory, deadline: limits[:deadline]}

    with {:ok, []} <- Wasmex.call_function(guest, "_initialize", []),
         {:ok, [0]} <- Wasmex.call_function(guest, "sb_init", [0, @stack]) do
      Enum.reduce_while(steps, {:ok, ""}, fn step, _done ->
        case step(held, step) do
          {:ok, text} -> {:cont, {:ok, text}}
          stopped -> {:halt, stopped}
        end
      end)
    else
      {:error, reason} -> {:error, trapped(reason)}
      other -> {:error, {:crashed, other}}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :out_of_time}
    :exit, reason -> {:error, {:crashed, reason}}
  end

  defp step(held, source) when is_binary(source) do
    with {:ok, at} <- placed(held, source),
         do: finished(held, "sb_eval", [at, byte_size(source)])
  end

  defp step(held, {name, code}) do
    with {:ok, name_at} <- placed(held, name),
         {:ok, code_at} <- placed(held, code),
         do: finished(held, "sb_module", [name_at, byte_size(name), code_at, byte_size(code)])
  end

  defp placed(%{guest: guest, store: store, memory: memory}, text) do
    with {:ok, [at]} <- Wasmex.call_function(guest, "sb_alloc", [byte_size(text)]),
         :ok <- Wasmex.Memory.write_binary(store, memory, at, text) do
      {:ok, at}
    else
      {:error, reason} -> {:error, trapped(reason)}
    end
  end

  defp finished(%{guest: guest, store: store, memory: memory, deadline: deadline}, call, given) do
    case Wasmex.call_function(guest, call, given, deadline) do
      {:ok, [status]} ->
        {:ok, [result]} = Wasmex.call_function(guest, "sb_result_ptr", [])
        {:ok, [length]} = Wasmex.call_function(guest, "sb_result_len", [])
        text = Wasmex.Memory.read_binary(store, memory, result, length)
        if status == 0, do: {:ok, text}, else: {:error, {:script, text}}

      {:error, reason} ->
        {:error, trapped(reason)}
    end
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
