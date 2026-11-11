defmodule BabelSyncWeb.OriginTest do
  use ExUnit.Case, async: true

  alias BabelSyncWeb.Origin

  test "the server's own pages and the Obsidian shells may connect" do
    assert Origin.allowed?(URI.parse("http://localhost:4002"))
    assert Origin.allowed?(URI.parse("app://obsidian.md"))
    assert Origin.allowed?(URI.parse("capacitor://localhost"))
  end

  test "other sites may not" do
    refute Origin.allowed?(URI.parse("https://evil.example"))
  end
end
