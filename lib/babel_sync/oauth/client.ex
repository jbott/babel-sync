defmodule BabelSync.OAuth.Client do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  @app_schemes ~w(obsidian vscode vscode-insiders cursor windsurf claude)
  @uri_bytes 2000
  @loopback ~w(localhost 127.0.0.1 ::1)

  schema "oauth_clients" do
    field :name, :string
    field :redirect_uris, {:array, :string}
    field :approved_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [:name, :redirect_uris])
    |> update_change(:name, &String.slice(String.trim(&1), 0, 100))
    |> validate_required([:name, :redirect_uris])
    |> validate_length(:redirect_uris, min: 1, max: 10)
    |> validate_change(:redirect_uris, fn :redirect_uris, uris ->
      if Enum.all?(uris, &redirect_uri?/1), do: [], else: [redirect_uris: "is not allowed"]
    end)
  end

  @spec redirect_uri?(String.t()) :: boolean()
  def redirect_uri?(uri) when byte_size(uri) > @uri_bytes, do: false

  def redirect_uri?(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme, fragment: nil} = parsed} when is_binary(scheme) ->
        allowed_scheme?(String.downcase(scheme), parsed)

      _invalid ->
        false
    end
  end

  @spec loopback?(URI.t()) :: boolean()
  def loopback?(%URI{scheme: "http", host: host}), do: host in @loopback
  def loopback?(%URI{}), do: false

  defp allowed_scheme?("https", %URI{host: host}), do: host not in [nil, ""]
  defp allowed_scheme?("http", uri), do: loopback?(uri)
  defp allowed_scheme?(scheme, _uri), do: scheme in @app_schemes or String.contains?(scheme, ".")
end
