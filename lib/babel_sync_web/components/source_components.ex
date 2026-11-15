defmodule BabelSyncWeb.SourceComponents do
  @moduledoc """
  How a source's standing and its runs are worded and shown, wherever
  they appear.
  """

  use BabelSyncWeb, :html

  alias BabelSync.Sources.Source

  def status_label(%{status: :invalid}), do: "Cannot be read"
  def status_label(%{status: :new}), do: "Not approved"
  def status_label(%{status: :changed}), do: "Changed since approval"
  def status_label(%{source: %Source{enabled: false}}), do: "Paused"
  def status_label(%{status: :approved}), do: "Approved"

  def status_class(%{status: :invalid}), do: "border-danger/50 text-danger"

  def status_class(%{status: status}) when status in [:new, :changed],
    do: "border-warn/60 text-ink"

  def status_class(%{source: %Source{enabled: false}}), do: nil
  def status_class(_approved), do: "border-added/60 text-ink"

  def run_dot(:done), do: "bg-added"
  def run_dot(:failed), do: "bg-danger"
  def run_dot(_waiting), do: "animate-pulse bg-warn"

  def run_label(%{status: :queued}), do: "Waiting to run"
  def run_label(%{status: :running}), do: "Running"
  def run_label(%{status: :done, trigger: trigger}), do: "Ran #{started_by(trigger)}"
  def run_label(%{status: :failed, trigger: trigger}), do: "Failed #{started_by(trigger)}"

  defp started_by("schedule"), do: "on schedule"
  defp started_by("manual"), do: "by hand"
  defp started_by(other), do: "(#{other})"

  def logged?(run), do: is_binary(run.error) or run.log != ""

  def outcome(%{created: 0, changed: 0, unchanged: 0}), do: "Looked at no notes."

  def outcome(%{created: created, changed: changed, unchanged: unchanged}) do
    looked = created + changed + unchanged

    changes =
      for {count, what} <- [{created, "new"}, {changed, "updated"}],
          count > 0,
          do: "#{count} #{what}"

    "Looked at #{looked} #{if looked == 1, do: "note", else: "notes"}: " <>
      case changes do
        [] -> "nothing to change."
        some -> Enum.join(some, ", ") <> ", #{unchanged} left as they were."
      end
  end

  attr :id, :string, required: true
  attr :at, DateTime, required: true

  def local_time(assigns) do
    ~H"""
    <time id={@id} datetime={DateTime.to_iso8601(@at)} phx-hook=".LocalTime" class="text-faint">
      {at(@at)}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() { this.show() },
        updated() { this.show() },
        show() {
          const at = new Date(this.el.dateTime)
          if (Number.isNaN(at.getTime())) return
          this.el.textContent = at.toLocaleString(undefined, {
            day: "numeric", month: "short", hour: "numeric", minute: "2-digit"
          })
        }
      }
    </script>
    """
  end

  defp at(%DateTime{} = time), do: Calendar.strftime(time, "%-d %b %H:%M UTC")
end
