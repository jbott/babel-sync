defmodule BabelSync.Blobs.Store.S3 do
  @moduledoc """
  Blob bytes in an S3-compatible bucket, using multipart uploads.

  A small client over Req, which signs requests itself, in place of the
  ex_aws family: only seven S3 calls are needed.
  """
  @behaviour BabelSync.Blobs.Store

  @impl true
  def start_upload(key) do
    with {:ok, %{status: 200, body: body}} <- request(:post, key, params: [uploads: ""]),
         [_, ref] <- Regex.run(~r|<UploadId>([^<]+)</UploadId>|, body) do
      {:ok, ref}
    else
      other -> failure(other)
    end
  end

  @impl true
  def put_part(key, ref, number, data) do
    case request(:put, key, params: [partNumber: number, uploadId: ref], body: data) do
      {:ok, %{status: 200} = response} ->
        {:ok, response |> Req.Response.get_header("etag") |> hd()}

      other ->
        failure(other)
    end
  end

  @impl true
  def finish_upload(key, ref, parts) do
    listing =
      for {number, tag} <- Enum.sort(parts), into: "" do
        "<Part><PartNumber>#{number}</PartNumber><ETag>#{escape(tag)}</ETag></Part>"
      end

    body = "<CompleteMultipartUpload>#{listing}</CompleteMultipartUpload>"

    case request(:post, key, params: [uploadId: ref], body: body) do
      {:ok, %{status: 200, body: response}} ->
        if response =~ "<Error>", do: {:error, {:s3, response}}, else: :ok

      other ->
        failure(other)
    end
  end

  @impl true
  def abort_upload(key, ref) do
    request(:delete, key, params: [uploadId: ref])
    :ok
  end

  @impl true
  def stream(key, range) do
    headers =
      case range do
        nil -> []
        {first, last} -> [{"range", "bytes=#{first}-#{last}"}]
      end

    Stream.flat_map([key], fn key ->
      {:ok, %{status: status, body: body}} =
        request(:get, key, headers: headers, into: :self, receive_timeout: 60_000)

      if status not in [200, 206], do: raise("S3 GET #{key} returned #{status}")
      body
    end)
  end

  @impl true
  def delete(key) do
    request(:delete, key, [])
    :ok
  end

  @impl true
  def reachable? do
    match?(
      {:ok, %{status: 200}},
      request(:head, "", retry: false, receive_timeout: 3_000, connect_options: [timeout: 3_000])
    )
  end

  defp request(method, key, options) do
    config = Application.fetch_env!(:babel_sync, __MODULE__)

    [
      method: method,
      url: object_url(config, key),
      retry: :transient,
      decode_body: false,
      aws_sigv4: [
        service: :s3,
        region: config[:region],
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key]
      ]
    ]
    |> Keyword.merge(options)
    |> Req.request()
  end

  defp object_url(config, key) do
    encoded =
      key
      |> String.split("/")
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    "#{String.trim_trailing(config[:endpoint], "/")}/#{config[:bucket]}/#{encoded}"
  end

  defp escape(text) do
    text |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;")
  end

  defp failure({:ok, %{status: status, body: body}}), do: {:error, {:s3, status, body}}
  defp failure({:error, reason}), do: {:error, reason}
  defp failure(other), do: {:error, {:s3, other}}
end
