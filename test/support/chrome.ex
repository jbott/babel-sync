defmodule BabelSync.Chrome do
  @moduledoc false

  @applications [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]

  @commands ~w(chromium google-chrome google-chrome-stable chromium-browser)

  @spec path() :: String.t() | nil
  def path do
    System.get_env("CHROME_BIN") ||
      Enum.find_value(@commands, &System.find_executable/1) ||
      Enum.find(@applications, &File.exists?/1)
  end
end
