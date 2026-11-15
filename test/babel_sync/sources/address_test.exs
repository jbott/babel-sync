defmodule BabelSync.Sources.AddressTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sources.Address

  defp private?(text) do
    {:ok, address} = :inet.parse_address(String.to_charlist(text))
    Address.private?(address)
  end

  test "addresses that mean something only from here are private" do
    for address <- ~w(127.0.0.1 10.1.2.3 172.20.0.1 192.168.1.10 169.254.169.254 100.100.100.100
                      0.0.0.0 224.0.0.1 255.255.255.255 ::1 :: ::ffff:10.0.0.1 ::ffff:127.0.0.1
                      fd7a:115c:a1e0::1 fe80::1 ff02::1 64:ff9b::a00:1 2002:a00:1::1) do
      assert private?(address), address
    end
  end

  test "addresses on the open internet are not" do
    for address <- ~w(8.8.8.8 140.82.112.6 172.32.0.1 100.128.0.1 2606:4700::1111 ::ffff:8.8.8.8
                      64:ff9b::808:808) do
      refute private?(address), address
    end
  end

  test "an address written out resolves to itself" do
    assert Address.resolve("127.0.0.1") == [{127, 0, 0, 1}]
    assert Address.resolve("::1") == [{0, 0, 0, 0, 0, 0, 0, 1}]
  end
end
