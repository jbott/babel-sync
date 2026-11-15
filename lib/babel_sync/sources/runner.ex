defmodule BabelSync.Sources.Runner do
  @moduledoc """
  Runs a source's script once, within what was approved, and records
  how it went.

  The script writes with the authority of whoever approved it and no
  more: should that person leave the vault, the source stops being able
  to write. What the script asked to remember is saved only when it ran
  to its end, so one that fails part way starts again from where the
  last good run left off, and since every write it makes is one that
  does nothing the second time, running it again is safe.
  """

  import Ecto.Query

  alias BabelSync.Accounts
  alias BabelSync.Accounts.Scope
  alias BabelSync.{Repo, Sandbox, Sources, Vaults}
  alias BabelSync.Sources.{Host, Run, Script, Secrets, Source}

  @spec run(Run.t(), Source.t()) :: Run.t()
  def run(%Run{} = run, %Source{} = source) do
    kept = :ets.new(__MODULE__, [:public])

    outcome =
      with {:ok, source} <- current(source),
           {:ok, scope} <- scope(source) do
        script = Script.from_manifest(source.manifest, source.code)
        state = Jason.decode!(source.state)
        :ets.insert(kept, {:state, state})

        held = %{
          source: source,
          script: script,
          scope: scope,
          folder: Vaults.get_vault(source.vault_id).sources_folder,
          kept: kept,
          limits: Sources.limits(),
          secrets: secrets(source, script)
        }

        Sandbox.run_module(
          Host.setup(script, state, run.trigger),
          Host.file(script),
          script.code,
          Host.handler(held),
          deadline: Sources.limits()[:deadline]
        )
      end

    seen = Map.new(:ets.tab2list(kept))
    :ets.delete(kept)
    finish(run, source, outcome, seen)
  end

  defp current(%Source{} = source) do
    with {:error, message} <- Sources.current(source), do: {:error, {:script, message}}
  end

  defp scope(%Source{approved_by_id: approver, vault_id: vault_id, name: name}) do
    with %Accounts.User{} = user <- approver && Accounts.get_user(approver),
         :ok <- Vaults.authorize(user, vault_id, :write) do
      {:ok, Scope.for_user(user, app: "source: " <> name, vault_ids: [vault_id])}
    else
      _gone ->
        {:error, {:script, "whoever approved this source can no longer write to the vault"}}
    end
  end

  defp secrets(source, script) do
    held = Secrets.open(source)

    for {name, %{host: host, header: header, template: template}} <- script.secrets,
        value = held[name],
        do: %{host: host, header: header, value: String.replace(template, "{}", value)}
  end

  defp finish(run, source, outcome, seen) do
    now = DateTime.utc_now()
    done? = match?({:ok, _result}, outcome)

    changes =
      [
        attention: seen[:attention] && Jason.encode!(seen[:attention]),
        running_until: nil,
        updated_at: now
      ] ++
        if(done?, do: [state: Jason.encode!(seen[:state] || %{})], else: [])

    Repo.update_all(from(s in Source, where: s.id == ^source.id), set: changes)

    run
    |> Ecto.Changeset.change(
      status: if(done?, do: :done, else: :failed),
      finished_at: now,
      error: problem(outcome),
      log: seen[:log] || "",
      created: seen[:created] || 0,
      changed: seen[:changed] || 0,
      unchanged: (seen[:unchanged] || 0) + (seen[:gone] || 0)
    )
    |> Repo.update!()
  end

  defp problem({:ok, _result}), do: nil
  defp problem({:error, {:script, message}}), do: message
  defp problem({:error, :out_of_time}), do: "ran longer than a source may"
  defp problem({:error, :out_of_fuel}), do: "did more work than a source may"

  defp problem({:error, {:crashed, reason}}),
    do: "stopped unexpectedly: #{inspect(reason, limit: 5)}"
end
