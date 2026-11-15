defmodule BabelSync.Sources.FetchTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sources.Fetch

  defmodule Site do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(%Plug.Conn{request_path: "/echo"} = conn, _options) do
      {:ok, body, conn} = read_body(conn)
      token = conn |> get_req_header("authorization") |> List.first()

      conn
      |> put_resp_header("x-method", conn.method)
      |> send_resp(200, "#{token}|#{conn.query_string}|#{body}")
    end

    def call(%Plug.Conn{request_path: "/away"} = conn, _options) do
      conn |> put_resp_header("location", "/echo?moved") |> send_resp(302, "")
    end

    def call(%Plug.Conn{request_path: "/elsewhere"} = conn, _options) do
      conn |> put_resp_header("location", "https://elsewhere.example/") |> send_resp(302, "")
    end

    def call(%Plug.Conn{request_path: "/round"} = conn, _options) do
      conn |> put_resp_header("location", "/round") |> send_resp(302, "")
    end

    def call(%Plug.Conn{request_path: "/large"} = conn, _options) do
      send_resp(conn, 200, String.duplicate("x", 20_000))
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: Site, scheme: :http, port: 0, ip: :loopback})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    %{
      site: "http://127.0.0.1:#{port}",
      grant: [hosts: ["127.0.0.1"], private_hosts: ["127.0.0.1"]]
    }
  end

  test "reaches a granted host and returns what it answered", %{site: site, grant: grant} do
    assert {:ok, %{status: 200, body: "|a=1|", headers: %{"x-method" => "GET"}}} =
             Fetch.request(%{url: site <> "/echo?a=1"}, grant)
  end

  test "sends a body with the method asked for", %{site: site, grant: grant} do
    assert {:ok, %{body: "||sent", headers: %{"x-method" => "POST"}}} =
             Fetch.request(%{url: site <> "/echo", method: "post", body: "sent"}, grant)
  end

  test "refuses a host the source was not approved for", %{site: site} do
    assert {:error, message} = Fetch.request(%{url: site <> "/echo"}, hosts: ["api.github.com"])
    assert message =~ "not a host this source may reach"
  end

  test "refuses a private address the operator has not named", %{site: site} do
    assert {:error, message} =
             Fetch.request(%{url: String.replace(site, "http:", "https:") <> "/echo"},
               hosts: ["127.0.0.1"]
             )

    assert message =~ "private network"
  end

  test "refuses a name that leads to this machine" do
    assert {:error, message} = Fetch.request(%{url: "https://localhost/"}, hosts: ["localhost"])
    assert message =~ "private network"
  end

  test "refuses plain http to anything but a host the operator named" do
    assert {:error, message} =
             Fetch.request(%{url: "http://example.com/"}, hosts: ["example.com"])

    assert message =~ "https"
  end

  test "refuses addresses that are not for the web" do
    for url <- [
          "file:///etc/passwd",
          "ftp://example.com/",
          "nonsense",
          "https://user:pw@example.com/"
        ] do
      assert {:error, _message} = Fetch.request(%{url: url}, hosts: ["example.com"])
    end
  end

  test "follows a redirect within what was granted", %{site: site, grant: grant} do
    assert {:ok, %{status: 200, body: "|moved|", url: url}} =
             Fetch.request(%{url: site <> "/away"}, grant)

    assert url =~ "/echo?moved"
  end

  test "does not follow a redirect to a host it was not granted", %{site: site, grant: grant} do
    assert {:error, message} = Fetch.request(%{url: site <> "/elsewhere"}, grant)
    assert message =~ "elsewhere.example is not a host"
  end

  test "gives up on a redirect that goes round", %{site: site, grant: grant} do
    assert {:error, "redirected too many times"} = Fetch.request(%{url: site <> "/round"}, grant)
  end

  test "adds a secret for its host and blanks it in the answer", %{site: site, grant: grant} do
    secret = %{host: "127.0.0.1", header: "Authorization", value: "Bearer hunter2"}

    assert {:ok, %{body: "[secret]||"}} =
             Fetch.request(
               %{url: site <> "/echo", headers: %{"authorization" => "mine"}},
               [secrets: [secret]] ++ grant
             )
  end

  test "keeps a secret from every other host", %{site: site, grant: grant} do
    secret = %{host: "api.github.com", header: "Authorization", value: "Bearer hunter2"}

    assert {:ok, %{body: "||"}} =
             Fetch.request(%{url: site <> "/echo"}, [secrets: [secret]] ++ grant)
  end

  test "stops reading an answer larger than it may read", %{site: site, grant: grant} do
    assert {:error, message} = Fetch.request(%{url: site <> "/large"}, [most: 1_000] ++ grant)
    assert message =~ "more than this source may read"
  end
end
