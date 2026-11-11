defmodule BabelSyncWeb.BlobSender do
  @moduledoc """
  Sends a blob as an HTTP response, honouring a single byte range.

  Uploaded files are untrusted, so the response is sandboxed: a browser
  will display or download it but never run it with the site's origin.
  """

  import Plug.Conn

  alias BabelSync.Blobs
  alias BabelSync.Blobs.Blob

  @spec send_blob(Plug.Conn.t(), Blob.t(), String.t()) :: Plug.Conn.t()
  def send_blob(conn, %Blob{} = blob, content_type) do
    conn =
      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("etag", ~s("#{blob.hash}"))
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "content-security-policy",
        "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:; media-src data:"
      )

    case range(conn, blob.size) do
      :whole ->
        conn |> put_resp_header("content-length", "#{blob.size}") |> deliver(200, blob, nil)

      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{blob.size}")
        |> put_resp_header("content-length", "#{last - first + 1}")
        |> deliver(206, blob, {first, last})

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{blob.size}")
        |> send_resp(416, "")
    end
  end

  defp deliver(conn, status, %Blob{size: 0}, _range), do: send_resp(conn, status, "")

  defp deliver(conn, status, blob, range) do
    case Blobs.local_path(blob) do
      nil -> stream(conn, status, blob, range)
      path -> send_local(conn, status, path, range)
    end
  end

  defp send_local(conn, status, path, nil), do: send_file(conn, status, path)

  defp send_local(conn, status, path, {first, last}) do
    send_file(conn, status, path, first, last - first + 1)
  end

  defp stream(conn, status, blob, range) do
    conn = send_chunked(conn, status)

    Enum.reduce_while(Blobs.stream(blob, range), conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  defp range(conn, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] -> parse(String.split(spec, "-"), size)
      _none -> :whole
    end
  end

  defp parse(["", suffix], size) do
    case Integer.parse(suffix) do
      {count, ""} when count > 0 and size > 0 -> {:ok, max(size - count, 0), size - 1}
      _invalid -> :unsatisfiable
    end
  end

  defp parse([first, last], size) do
    with {first, ""} <- Integer.parse(first),
         {:ok, last} <- last(last, size),
         true <- first <= last and first < size do
      {:ok, first, min(last, size - 1)}
    else
      _invalid -> :unsatisfiable
    end
  end

  defp parse(_other, _size), do: :unsatisfiable

  defp last("", size), do: {:ok, size - 1}

  defp last(text, _size) do
    case Integer.parse(text) do
      {last, ""} -> {:ok, last}
      _invalid -> :error
    end
  end
end
