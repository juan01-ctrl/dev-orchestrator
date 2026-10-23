defmodule DevOrchestrator.Connections.Linear do
  alias DevOrchestrator.Connections.HTTP

  @max_file_bytes 10 * 1_024 * 1_024

  @allowed_types %{
    "image/png" => {".png", :png},
    "image/jpeg" => {".jpg", :jpeg},
    "image/gif" => {".gif", :gif},
    "image/webp" => {".webp", :webp},
    "text/csv" => {".csv", :text},
    "application/csv" => {".csv", :text},
    "text/tab-separated-values" => {".tsv", :text},
    "text/plain" => {".txt", :text},
    "text/markdown" => {".md", :text},
    "application/json" => {".json", :text},
    "application/yaml" => {".yaml", :text},
    "text/yaml" => {".yaml", :text},
    "application/xml" => {".xml", :text},
    "text/xml" => {".xml", :text},
    "application/pdf" => {".pdf", :pdf}
  }

  def issue_id_from_source_key("linear:" <> value) do
    case String.split(value, ":") do
      [issue_id, activation] when issue_id != "" ->
        case Integer.parse(activation) do
          {number, ""} when number > 0 -> {:ok, issue_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def issue_id_from_source_key(_), do: :error

  def query(token, query, variables) when is_binary(token) do
    case HTTP.request(:post, "https://api.linear.app/graphql",
           headers: [{"authorization", "Bearer " <> token}],
           json: %{query: query, variables: variables}
         ) do
      {:ok, %{"errors" => _}} -> {:error, :provider_rejected}
      other -> other
    end
  end

  def download_file(token, source_url, opts \\ [])

  def download_file(token, source_url, opts) when is_binary(token) and is_binary(source_url) do
    if not DevOrchestrator.Intake.LinearAssets.linear_upload_url?(source_url) do
      {:error, :invalid_file_url}
    else
      request_download(token, source_url, opts)
    end
  end

  def download_file(_, _, _), do: {:error, :invalid_file_url}

  defp request_download(token, source_url, opts) do
    collector = fn {:data, chunk}, {request, response} ->
      chunks = Map.get(response.private, :linear_asset_chunks, [])
      size = Map.get(response.private, :linear_asset_size, 0) + byte_size(chunk)

      if size > @max_file_bytes do
        {:halt,
         {request,
          %{response | private: Map.put(response.private, :linear_asset_too_large, true)}}}
      else
        {:cont,
         {request,
          %{
            response
            | private:
                response.private
                |> Map.put(:linear_asset_chunks, [chunk | chunks])
                |> Map.put(:linear_asset_size, size)
          }}}
      end
    end

    with {:ok, %{status: 200} = response} <-
           HTTP.request_response(:get, source_url,
             headers: [{"authorization", "Bearer " <> token}, {"accept-encoding", "identity"}],
             into: collector,
             decode_body: false,
             decompress_body: false
           ),
         false <- Map.get(response.private || %{}, :linear_asset_too_large, false),
         body <-
           response.private
           |> Map.get(:linear_asset_chunks, [])
           |> Enum.reverse()
           |> IO.iodata_to_binary(),
         :ok <- verify_content_length(response.headers || %{}, byte_size(body)),
         {:ok, media_type, extension} <- validate_file(body, response.headers || %{}) do
      filename =
        opts
        |> Keyword.get(:filename_hint, "linear-file")
        |> safe_filename(extension)

      {:ok,
       %{
         body: body,
         filename: filename,
         media_type: media_type,
         sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
       }}
    else
      true -> {:error, :file_too_large}
      {:error, :file_too_large} -> {:error, :file_too_large}
      {:error, :provider_rejected} -> {:error, :unsupported_file}
      {:error, _} = error -> error
      _ -> {:error, :unsupported_file}
    end
  rescue
    _ -> {:error, :provider_unavailable}
  end

  defp validate_file(body, headers) when is_binary(body) do
    media_type =
      header(headers, "content-type") |> String.split(";", parts: 2) |> hd() |> String.downcase()

    case Map.get(@allowed_types, media_type) do
      {extension, kind} ->
        if valid_signature?(body, kind),
          do: {:ok, media_type, extension},
          else: {:error, :unsupported_file}

      _ ->
        {:error, :unsupported_file}
    end
  end

  defp valid_signature?(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, :png), do: true
  defp valid_signature?(<<0xFF, 0xD8, 0xFF, _::binary>>, :jpeg), do: true
  defp valid_signature?(<<"GIF87a", _::binary>>, :gif), do: true
  defp valid_signature?(<<"GIF89a", _::binary>>, :gif), do: true
  defp valid_signature?(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>, :webp), do: true
  defp valid_signature?(<<"%PDF-", _::binary>>, :pdf), do: true

  defp valid_signature?(body, :text) do
    String.valid?(body) and not String.contains?(body, <<0>>) and
      not Regex.match?(~r/^\s*(?:<!doctype\s+html|<html\b|<svg\b)/i, body)
  end

  defp valid_signature?(_, _), do: false

  defp verify_content_length(headers, actual_size) do
    case Integer.parse(header(headers, "content-length")) do
      {size, ""} when size == actual_size and size <= @max_file_bytes ->
        :ok

      {size, ""} when size > @max_file_bytes ->
        {:error, :file_too_large}

      {size, ""} when size >= 0 ->
        {:error, :provider_rejected}

      _ ->
        if header(headers, "content-length") == "",
          do: :ok,
          else: {:error, :provider_rejected}
    end
  end

  defp header(headers, name) do
    headers
    |> Enum.find_value("", fn {key, value} ->
      if is_binary(key) and String.downcase(key) == name,
        do: List.wrap(value) |> List.first(),
        else: nil
    end)
    |> to_string()
  end

  defp safe_filename(name, extension) do
    base =
      name
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
      |> String.replace(~r/[^\p{L}\p{N}._ -]/u, "_")
      |> String.trim()
      |> String.slice(0, 100)

    base = if base == "" or base in [".", ".."], do: "linear-file", else: base
    if String.downcase(Path.extname(base)) == extension, do: base, else: base <> extension
  end
end
