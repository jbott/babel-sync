defmodule BabelSync.MCP.Files do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias Anubis.Server.Component.Tool
  alias BabelSync.{Agent, Blobs, Transfers}
  alias BabelSync.MCP.Reply
  alias BabelSync.Vaults.Path

  @extension "io.modelcontextprotocol/files"
  @file_properties %{
    "id" => %{type: "string", minLength: 1, maxLength: 128},
    "name" => %{type: "string"},
    "mimeType" => %{type: "string"},
    "size" => %{type: "integer", minimum: 0},
    "digest" => %{
      type: "object",
      properties: %{algorithm: %{const: "sha-256"}, value: %{type: "string"}},
      required: ["algorithm", "value"]
    }
  }

  @spec supports?(Frame.t(), String.t()) :: boolean()
  def supports?(
        %{context: %{protocol_version: "2026-07-28", client_capabilities: capabilities}},
        feature
      ) do
    case capabilities do
      %{"extensions" => %{@extension => %{} = files}} ->
        not Map.has_key?(files, "revision") and is_map(files[feature])

      _other ->
        false
    end
  end

  def supports?(_frame, _feature), do: false

  @spec tool() :: Tool.t()
  def tool do
    max_size = Blobs.max_size()

    %Tool{
      name: "save_file",
      title: "Save a file to the vault",
      description:
        "Save a file provided by a client with native uploads enabled. For a local file accessible from a shell, upload_file gives a curl command. Accepts up to #{max_size} bytes, or 8 MiB for a note. Replacing a file requires overwrite.",
      annotations: %{
        title: "Save a file to the vault",
        readOnlyHint: false,
        destructiveHint: true
      },
      input_schema: %{
        type: "object",
        required: ["path", "file"],
        additionalProperties: false,
        properties: %{
          vault: %{
            type: "string",
            description: "Vault name or id. Optional when only one vault is available."
          },
          path: %{
            type: "string",
            description: "Destination path in the vault, including the filename."
          },
          overwrite: %{type: "boolean"},
          file: %{
            "x-mcp-file" => %{maxSize: max_size},
            type: "object",
            required: ["id", "mimeType", "size"],
            properties: @file_properties
          }
        }
      }
    }
  end

  @spec call(map(), Frame.t()) :: {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def call(%{"arguments" => %{"file" => %{"size" => size} = file} = args} = params, frame)
      when is_number(size) and size == trunc(size) do
    file = %{file | "size" => trunc(size)}
    args = %{args | "file" => file}

    case save(params, args, file, frame) do
      {:upload, result} ->
        {:reply, result, frame}

      {:error, :invalid_state} ->
        invalid(frame)

      {:error, :unsupported} ->
        {:error,
         Error.missing_required_client_capability(%{
           "extensions" => %{@extension => %{"upload" => %{}}}
         }), frame}

      {:error, :invalid_params} ->
        invalid(frame)

      result ->
        {:reply, response, frame} = Reply.run(frame, fn _scope -> result end)
        {:reply, Response.to_protocol(response), frame}
    end
  end

  def call(_params, frame), do: invalid(frame)

  defp save(%{"requestState" => state}, args, _file, frame) when is_binary(state) do
    with true <- supports?(frame, "upload") || {:error, :unsupported},
         {:ok, blob} <-
           Transfers.confirm_upload(state, arguments_hash(args), frame.assigns.current_scope) do
      place(frame.assigns.current_scope, blob, args)
    end
  end

  defp save(%{"requestState" => _invalid}, _args, _file, _frame), do: {:error, :invalid_state}

  defp save(_params, args, file, frame) do
    with :ok <- validate(args, file),
         {:ok, digest} <- expected_digest(file),
         :ok <- accepts_transfer(file, frame),
         {:ok, attrs} <-
           Agent.prepare_upload(
             frame.assigns.current_scope,
             args["vault"],
             args["path"],
             file["size"],
             args["overwrite"] == true
           ) do
      if file["size"] == 0 do
        save_empty(frame.assigns.current_scope, attrs, digest)
      else
        {:upload, Transfers.request_upload(attrs, arguments_hash(args), file["id"], digest)}
      end
    end
  end

  defp validate(
         %{"path" => path} = args,
         %{"id" => id, "mimeType" => type, "size" => size} = file
       )
       when is_binary(path) and is_binary(id) and is_binary(type) and size >= 0 do
    if byte_size(id) in 1..512 and length(String.codepoints(id)) <= 128 and
         is_binary(Map.get(file, "name", "")) and is_binary(Map.get(args, "vault", "")) and
         is_boolean(Map.get(args, "overwrite", false)) and
         Map.keys(args) -- ~w(path vault file overwrite) == [],
       do: :ok,
       else: {:error, :invalid_params}
  end

  defp validate(_args, _file), do: {:error, :invalid_params}

  defp expected_digest(%{"digest" => %{"algorithm" => "sha-256", "value" => value}})
       when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<_::256>> = digest} -> {:ok, digest}
      _invalid -> {:error, :invalid_params}
    end
  end

  defp expected_digest(%{"digest" => _other}), do: {:error, :invalid_params}
  defp expected_digest(_file), do: {:ok, nil}

  defp accepts_transfer(%{"size" => 0, "data" => ""}, _frame), do: :ok
  defp accepts_transfer(%{"data" => _inline}, _frame), do: {:error, :inline_unsupported}
  defp accepts_transfer(%{"size" => 0}, _frame), do: :ok

  defp accepts_transfer(_file, frame),
    do: if(supports?(frame, "upload"), do: :ok, else: {:error, :unsupported})

  defp save_empty(scope, attrs, digest) do
    if is_nil(digest) or digest == :crypto.hash(:sha256, "") do
      writer =
        if Path.kind_for(attrs.path) == :doc, do: &Agent.write_file/5, else: &Agent.write_binary/5

      with {:ok, placed} <-
             writer.(scope, attrs.vault_id, attrs.path, "", overwrite: attrs.overwrite),
           do: {:ok, "Saved #{placed.path}."}
    else
      {:error, :digest_mismatch}
    end
  end

  defp place(scope, blob, args) do
    path = Path.normalize(args["path"])

    case Agent.place_staged(scope, blob.vault_id, path, blob, args["overwrite"] == true) do
      {:ok, placed} -> {:ok, "Saved #{placed.path}."}
      {:error, reason} -> {:error, {:placement_failed, reason}}
    end
  end

  defp arguments_hash(args) do
    :crypto.hash(:sha256, Jason.encode_to_iodata!(["save_file", canonical(args)]))
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, item} -> {key, canonical(item)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_float(value) and value == trunc(value), do: trunc(value)
  defp canonical(value), do: value

  defp invalid(frame),
    do:
      {:error,
       Error.protocol(:invalid_params, %{
         message: "Invalid file arguments or upload requestState."
       }), frame}
end
