defmodule DevOrchestrator.Intake.LinearAssets do
  @moduledoc false

  @max_assets 10
  @url_regex ~r/https:\/\/[^\s<>"']+/u
  @markdown_link_regex ~r/!?\[([^\]]*)\]\((https:\/\/[^\s<>"']+)\)/u

  def extract(markdown, attachments \\ [])

  def extract(markdown, attachments) when is_binary(markdown) and is_list(attachments) do
    markdown_labels =
      Regex.scan(@markdown_link_regex, markdown, capture: :all_but_first)
      |> Map.new(fn [label, url] -> {clean_url(url), label} end)

    attachment_labels =
      Map.new(attachments, fn
        %{"url" => url, "title" => title} when is_binary(url) and is_binary(title) ->
          {clean_url(url), title}

        %{"url" => url} when is_binary(url) ->
          {clean_url(url), nil}

        _ ->
          {nil, nil}
      end)
      |> Map.delete(nil)

    labels = Map.merge(attachment_labels, markdown_labels)

    markdown_urls =
      Regex.scan(@url_regex, markdown, capture: :first)
      |> Enum.map(fn [url] -> clean_url(url) end)

    attachment_urls = Map.keys(attachment_labels)

    urls =
      (markdown_urls ++ attachment_urls)
      |> Enum.uniq()
      |> Enum.filter(&linear_upload_url?/1)

    accepted = Enum.take(urls, @max_assets)

    %{
      assets:
        Enum.map(accepted, fn url ->
          %{
            "id" => opaque_id(),
            "source_url" => url,
            "filename_hint" => filename_hint(url, Map.get(labels, url))
          }
        end),
      skipped_count: max(length(urls) - @max_assets, 0)
    }
  end

  def extract(_, _), do: %{assets: [], skipped_count: 0}

  def sanitize_description(description) when is_binary(description) do
    Regex.replace(~r/https?:\/\/[^\s<>"']+/u, description, fn raw ->
      if linear_upload_host?(clean_url(raw)) do
        "[Linear attachment]" <> String.replace_prefix(raw, clean_url(raw), "")
      else
        raw
      end
    end)
  end

  def sanitize_description(_), do: ""

  def linear_upload_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: "uploads.linear.app",
        userinfo: nil,
        port: port,
        fragment: nil,
        path: path
      }
      when port in [nil, 443] and is_binary(path) and path != "/" ->
        true

      _ ->
        false
    end
  end

  def linear_upload_url?(_), do: false

  defp linear_upload_host?(url) do
    case URI.parse(url) do
      %URI{host: "uploads.linear.app"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp opaque_id do
    <<hex::binary-size(32)>> = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    String.slice(hex, 0, 8) <>
      "-" <>
      String.slice(hex, 8, 4) <>
      "-" <>
      String.slice(hex, 12, 4) <>
      "-" <> String.slice(hex, 16, 4) <> "-" <> String.slice(hex, 20, 12)
  end

  defp clean_url(url) do
    Regex.replace(~r/[.,;!?)}\]]+$/u, url, "")
  end

  defp filename_hint(url, label) do
    from_path =
      case URI.parse(url).path do
        path when is_binary(path) -> path |> Path.basename() |> URI.decode()
        _ -> ""
      end

    candidate = if Path.extname(from_path) == "" and is_binary(label), do: label, else: from_path

    candidate
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
    |> Path.basename()
    |> String.replace(~r/[^\p{L}\p{N}._ -]/u, "_")
    |> String.trim()
    |> String.slice(0, 120)
    |> case do
      "" -> "linear-file"
      name -> name
    end
  rescue
    _ -> "linear-file"
  end
end
