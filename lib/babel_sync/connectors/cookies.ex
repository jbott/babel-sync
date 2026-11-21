defmodule BabelSync.Connectors.Cookies do
  @moduledoc false

  @name ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @value ~r/\A("?)[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*\1\z/

  @spec validate(term(), [String.t()]) :: {:ok, [map()]} | {:error, :invalid_session}
  def validate(cookies, hosts) when is_list(cookies) and length(cookies) in 1..200 do
    if Enum.all?(
         cookies,
         &(valid?(&1) and Enum.any?(hosts, fn host -> domain_matches?(&1, host) end))
       ) and byte_size(Jason.encode!(cookies)) <= 100_000,
       do:
         {:ok,
          Enum.map(
            cookies,
            &Map.take(&1, ~w(name value domain path hostOnly httpOnly expirationDate))
          )},
       else: {:error, :invalid_session}
  end

  def validate(_cookies, _hosts), do: {:error, :invalid_session}

  defp valid?(%{"name" => name, "value" => value, "domain" => domain, "path" => path} = cookie)
       when is_binary(name) and is_binary(value) and is_binary(domain) and is_binary(path) do
    Regex.match?(~r/\A\.?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/, domain) and byte_size(name) <= 256 and
      byte_size(value) <= 8192 and
      Regex.match?(@name, name) and Regex.match?(@value, value) and
      String.starts_with?(path, "/") and byte_size(path) <= 2048 and
      is_boolean(Map.get(cookie, "hostOnly", false)) and
      is_boolean(Map.get(cookie, "httpOnly", true)) and
      (is_nil(cookie["expirationDate"]) or is_number(cookie["expirationDate"]))
  end

  defp valid?(_cookie), do: false

  @spec header([map()], String.t()) :: String.t()
  def header(cookies, url) do
    uri = URI.parse(url)

    cookies
    |> Enum.filter(&matches?(&1, uri))
    |> Enum.sort_by(&(-byte_size(&1["path"])))
    |> Enum.map_join("; ", &(&1["name"] <> "=" <> &1["value"]))
  end

  defp matches?(cookie, uri) do
    host? = domain_matches?(cookie, uri.host)

    path = cookie["path"]

    request_path = uri.path || "/"
    prefix = if String.ends_with?(path, "/"), do: path, else: path <> "/"
    path? = request_path == path or String.starts_with?(request_path, prefix)

    expiry = cookie["expirationDate"]
    host? and path? and (is_nil(expiry) or expiry > System.system_time(:second))
  end

  defp domain_matches?(cookie, host) do
    domain = String.trim_leading(cookie["domain"], ".")
    host == domain or (cookie["hostOnly"] != true and String.ends_with?(host, "." <> domain))
  end

  @spec receive_cookies([map()], [String.t()], String.t()) :: [map()]
  def receive_cookies(cookies, headers, url) do
    Enum.reduce(headers, cookies, fn header, jar ->
      case received(header, URI.parse(url)) do
        nil -> jar
        cookie -> [cookie | Enum.reject(jar, &(identity(&1) == identity(cookie)))]
      end
    end)
  end

  defp identity(cookie),
    do: {cookie["name"], String.trim_leading(cookie["domain"], "."), cookie["path"]}

  defp received(header, uri) do
    [pair | attributes] = String.split(header, ";")

    attributes =
      Map.new(attributes, fn part ->
        case String.split(String.trim(part), "=", parts: 2) do
          [name, value] -> {String.downcase(name), value}
          [name] -> {String.downcase(name), ""}
        end
      end)

    case String.split(pair, "=", parts: 2) do
      [name, value] ->
        domain = attributes["domain"]

        cookie = %{
          "name" => String.trim(name),
          "value" => String.trim(value),
          "domain" =>
            if(domain,
              do: "." <> String.trim_leading(String.downcase(domain), "."),
              else: uri.host
            ),
          "path" => received_path(attributes["path"], uri.path),
          "hostOnly" => is_nil(domain),
          "httpOnly" => Map.has_key?(attributes, "httponly"),
          "expirationDate" => expires(attributes)
        }

        if valid?(cookie) and domain_matches?(cookie, uri.host), do: cookie

      _invalid ->
        nil
    end
  end

  defp received_path("/" <> _rest = path, _request_path), do: path
  defp received_path(_path, nil), do: "/"

  defp received_path(_path, request_path) do
    {last, _size} = request_path |> :binary.matches("/") |> List.last({0, 1})
    if last == 0, do: "/", else: binary_part(request_path, 0, last)
  end

  defp expires(%{"max-age" => age} = attributes) do
    case Integer.parse(age) do
      {seconds, ""} -> System.system_time(:second) + seconds
      _invalid -> expires(Map.delete(attributes, "max-age"))
    end
  end

  defp expires(%{"expires" => date}) do
    case Req.Utils.parse_http_date(date) do
      {:ok, time} -> DateTime.to_unix(time)
      _invalid -> nil
    end
  end

  defp expires(_attributes), do: nil
end
