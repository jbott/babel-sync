defmodule BabelSync.Connectors.CookiesTest do
  use ExUnit.Case, async: true

  alias BabelSync.Connectors.Cookies

  @url "https://www.fixture.example/items/details"
  @cookie %{"name" => "fixture", "value" => "old", "domain" => "fixture.example", "path" => "/"}

  test "import accepts only cookies scoped to a declared host" do
    assert {:ok, [_]} = Cookies.validate([@cookie], ["www.fixture.example"])
    assert {:error, :invalid_session} = Cookies.validate([@cookie], ["unrelated.example"])

    assert {:error, :invalid_session} =
             Cookies.validate([Map.put(@cookie, "hostOnly", true)], ["www.fixture.example"])
  end

  test "rotated and deleted cookies replace the canonical domain identity" do
    jar =
      Cookies.receive_cookies([@cookie], ["fixture=new; Domain=.fixture.example; Path=/"], @url)

    assert length(jar) == 1
    assert Cookies.header(jar, @url) == "fixture=new"

    deleted =
      Cookies.receive_cookies(jar, ["fixture=; Domain=fixture.example; Path=/; Max-Age=0"], @url)

    assert Cookies.header(deleted, @url) == ""
  end

  test "paths respect slash boundaries and a missing path uses the request directory" do
    nested = Map.put(@cookie, "path", "/items//")
    assert Cookies.header([nested], @url) == ""
    assert Cookies.header([nested], "https://www.fixture.example/items//details") == "fixture=old"

    specific = Map.merge(@cookie, %{"path" => "/items", "value" => "specific"})
    expired = Map.merge(@cookie, %{"name" => "expired", "expirationDate" => 0})
    assert Cookies.header([@cookie, expired, specific], @url) == "fixture=specific; fixture=old"

    jar = Cookies.receive_cookies([], [" fixture = new ; Path=invalid"], @url)
    assert Cookies.header(jar, @url) == "fixture=new"
    assert Cookies.header(jar, "https://www.fixture.example/itemss/orders") == ""
    assert Cookies.header(jar, "https://fixture.example/items/orders") == ""
  end
end
