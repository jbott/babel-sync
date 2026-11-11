defmodule BabelSyncWeb.ErrorHTML do
  @moduledoc """
  Renders the page shown when a request ends in an error.

  Error pages are rendered without the root layout, so the page is a whole
  document. It follows the system colour scheme, since the script that
  applies a chosen theme lives in the root layout.
  """
  use BabelSyncWeb, :html

  def render(template, assigns) do
    assigns
    |> Map.new()
    |> Map.put(:message, Phoenix.Controller.status_message_from_template(template))
    |> Map.put(:code, Path.rootname(template))
    |> Map.put(:hint, hint(template))
    |> page()
  end

  defp hint("404" <> _format),
    do: "Nothing lives at this address. It may have been moved or deleted."

  defp hint("403" <> _format), do: "You are not allowed to open this."
  defp hint("5" <> _rest), do: "The server could not finish this request. Try again in a moment."
  defp hint(_template), do: "The request could not be completed."

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@message} · BabelSync</title>
        <link rel="icon" type="image/svg+xml" href={~p"/images/favicon.svg"} />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body>
        <main class="grid min-h-dvh place-items-center px-6 py-16">
          <div class="max-w-sm text-center">
            <.logo class="mx-auto size-12 text-accent" />
            <p class="mt-6 font-mono text-xs tracking-[0.2em] text-faint">{@code}</p>
            <h1 id="error-message" class="mt-1 font-serif text-2xl font-bold tracking-tight text-ink">
              {@message}
            </h1>
            <p class="mt-3 text-muted">{@hint}</p>
            <div class="mt-7">
              <.button href={~p"/"}>
                <.icon name="hero-arrow-left-mini" class="size-4" /> Back to your notes
              </.button>
            </div>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
