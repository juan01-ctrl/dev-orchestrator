defmodule DevOrchestrator.Connections.Slack do
  require Logger
  alias DevOrchestrator.Connections.HTTP

  @channel_page_limit 200
  @max_channel_pages 100
  @max_audio_bytes 25 * 1_024 * 1_024
  @audio_types ~w(mp3 mp4 mpeg mpga m4a wav webm)

  def with_audio(token, file_id, callback)
      when is_binary(token) and token != "" and is_binary(file_id) and is_function(callback, 2) do
    with {:ok, %{"ok" => true, "file" => file}} <-
           HTTP.request(:get, "https://slack.com/api/files.info",
             headers: [{"authorization", "Bearer " <> token}],
             params: [file: file_id]
           ),
         {:ok, metadata} <- validate_audio_metadata(file),
         true <- trusted_file_url?(metadata.url) do
      download_audio(token, metadata, callback)
    else
      false ->
        {:error, :invalid_file_url}

      {:ok, %{"ok" => false, "error" => "missing_scope"}} ->
        {:error, :provider_authentication}

      {:ok, %{"ok" => false}} ->
        {:error, :provider_rejected}

      {:ok, _} ->
        {:error, :unsupported_file}

      {:error, _} = error ->
        error
    end
  rescue
    exception ->
      Logger.warning(
        "File processing failed; provider=slack stage=audio_download_or_processing " <>
          "exception=#{inspect(exception.__struct__)}"
      )

      {:error, :provider_unavailable}
  end

  def with_audio(_, _, _), do: {:error, :invalid_file}

  defp validate_audio_metadata(file) when is_map(file) do
    type = file["filetype"]
    size = file["size"]
    url = file["url_private_download"] || file["url_private"]

    cond do
      file["mode"] != "hosted" ->
        {:error, :unsupported_file}

      not is_binary(type) or type not in @audio_types ->
        {:error, :unsupported_file}

      not is_integer(size) or size < 1 ->
        {:error, :unsupported_file}

      size > @max_audio_bytes ->
        {:error, :file_too_large}

      not is_binary(url) ->
        {:error, :invalid_file_url}

      true ->
        {:ok,
         %{
           type: type,
           size: size,
           url: url,
           name: safe_audio_name(file["name"], type),
           native_audio: file["subtype"] == "slack_audio"
         }}
    end
  end

  defp validate_audio_metadata(_), do: {:error, :unsupported_file}

  defp trusted_file_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port}
      when host in ["slack.com", "files.slack.com"] and port in [nil, 443] ->
        true

      _ ->
        false
    end
  end

  defp download_audio(token, metadata, callback) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dev-orchestrator-audio-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      :ok = File.chmod(path, 0o600)

      collector = fn {:data, chunk}, {request, response} ->
        response_private = response.private || %{}
        size = Map.get(response_private, :slack_audio_size, 0) + byte_size(chunk)

        if size > @max_audio_bytes do
          {:halt,
           {request,
            %{response | private: Map.put(response_private, :slack_audio_too_large, true)}}}
        else
          :ok = IO.binwrite(io, chunk)
          prefix = Map.get(response_private, :slack_audio_prefix, "")
          remaining = 64 - byte_size(prefix)
          prefix = prefix <> binary_part(chunk, 0, min(remaining, byte_size(chunk)))

          response_private =
            response_private
            |> Map.put(:slack_audio_size, size)
            |> Map.put(:slack_audio_prefix, prefix)

          {:cont, {request, %{response | private: response_private}}}
        end
      end

      result =
        with {:ok, response} <-
               HTTP.request_response(:get, metadata.url,
                 headers: [{"authorization", "Bearer " <> token}, {"accept-encoding", "identity"}],
                 into: collector,
                 raw: true
               ),
             {:ok, downloaded_metadata} <- validate_audio_download(response, metadata) do
          :ok = :file.sync(io)
          callback.(path, Map.drop(downloaded_metadata, [:url, :native_audio]))
        else
          {:error, _} = error -> error
        end

      result
    after
      File.close(io)
      File.rm(path)
    end
  end

  defp validate_audio_download(response, metadata) do
    private = response.private || %{}
    received_size = Map.get(private, :slack_audio_size, 0)
    expected_size = metadata.size
    native_mp4 = native_mp4?(response, metadata)
    download_size = if native_mp4, do: received_size, else: expected_size

    cond do
      Map.get(private, :slack_audio_too_large, false) ->
        {:error, :file_too_large}

      response.status != 200 ->
        invalid_audio_download(response, expected_size, received_size, "unexpected_status")

      received_size != expected_size and not native_mp4 ->
        invalid_audio_download(response, expected_size, received_size, "size_mismatch")

      verify_audio_content_length(response.headers || %{}, download_size) != :ok ->
        invalid_audio_download(
          response,
          expected_size,
          received_size,
          "content_length_mismatch"
        )

      true ->
        if native_mp4 do
          {:ok,
           %{
             metadata
             | type: "mp4",
               size: received_size,
               name: Path.rootname(metadata.name) <> ".mp4"
           }}
        else
          {:ok, metadata}
        end
    end
  end

  defp native_mp4?(response, metadata) do
    content_type =
      (response.headers || %{}) |> Map.get("content-type", []) |> List.wrap() |> List.first()

    media_type =
      if is_binary(content_type),
        do:
          content_type
          |> String.split(";", parts: 2)
          |> hd()
          |> String.trim()
          |> String.downcase()

    prefix = Map.get(response.private || %{}, :slack_audio_prefix, "")

    metadata.native_audio and media_type in ["audio/mp4", "video/mp4", "audio/x-m4a"] and
      audio_format(prefix) == "mp4"
  end

  defp invalid_audio_download(response, expected_size, received_size, reason) do
    prefix = Map.get(response.private || %{}, :slack_audio_prefix, "")

    content_type =
      (response.headers || %{}) |> Map.get("content-type", []) |> List.wrap() |> List.first()

    media_type =
      case content_type do
        "audio/" <> _ -> "audio"
        "video/" <> _ -> "video"
        "text/html" <> _ -> "html"
        "application/json" <> _ -> "json"
        "application/octet-stream" -> "binary"
        nil -> "missing"
        _ -> "other"
      end

    Logger.warning(
      "File processing failed; provider=slack stage=audio_download reason=#{reason} " <>
        "status=#{response.status} expected_bytes=#{expected_size} received_bytes=#{received_size} " <>
        "media_type=#{media_type} detected_format=#{audio_format(prefix)}"
    )

    {:error, :invalid_provider_response}
  end

  defp audio_format(<<_::32, "ftyp", _::binary>>), do: "mp4"
  defp audio_format(<<"RIFF", _::32, "WAVE", _::binary>>), do: "wav"
  defp audio_format(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "webm"
  defp audio_format(<<"ID3", _::binary>>), do: "mp3"
  defp audio_format(<<0x1F, 0x8B, _::binary>>), do: "gzip"

  defp audio_format(prefix) do
    if Regex.match?(~r/^\s*<(?:!doctype\b|html\b|head\b|body\b)/i, prefix),
      do: "html",
      else: "unknown"
  end

  defp verify_audio_content_length(headers, size) do
    length =
      headers
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(to_string(key)) == "content-length", do: List.first(List.wrap(value))
      end)

    case length do
      nil ->
        :ok

      value ->
        if to_string(value) == Integer.to_string(size),
          do: :ok,
          else: {:error, :invalid_provider_response}
    end
  end

  defp safe_audio_name(name, type) when is_binary(name) do
    filename = Path.basename(name)
    if Path.extname(filename) == "", do: filename <> "." <> type, else: filename
  end

  defp safe_audio_name(_, type), do: "audio." <> type

  def channels(token) when is_binary(token) and token != "" do
    fetch_channels(token, nil, [], MapSet.new(), 0)
  end

  def channels(_), do: {:error, :invalid_token}

  def post_message(token, payload) when is_binary(token) and token != "" and is_map(payload) do
    case HTTP.request(:post, "https://slack.com/api/chat.postMessage",
           headers: [{"authorization", "Bearer " <> token}],
           json: payload
         ) do
      {:ok, %{"ok" => true, "ts" => ts}} when is_binary(ts) -> {:ok, ts}
      {:ok, %{"ok" => false, "error" => "ratelimited"}} -> {:error, :provider_rate_limit}
      {:ok, %{"ok" => false, "error" => "missing_scope"}} -> {:error, :provider_authentication}
      {:ok, %{"ok" => false}} -> {:error, :provider_rejected}
      {:ok, _} -> {:error, :invalid_provider_response}
      {:error, _} = error -> error
    end
  end

  def post_message(_, _), do: {:error, :provider_authentication}

  def update_message(token, payload) when is_binary(token) and token != "" and is_map(payload) do
    case HTTP.request(:post, "https://slack.com/api/chat.update",
           headers: [{"authorization", "Bearer " <> token}],
           json: payload
         ) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, %{"ok" => false, "error" => "ratelimited"}} -> {:error, :provider_rate_limit}
      {:ok, %{"ok" => false, "error" => "missing_scope"}} -> {:error, :provider_authentication}
      {:ok, %{"ok" => false}} -> {:error, :provider_rejected}
      {:ok, _} -> {:error, :invalid_provider_response}
      {:error, _} = error -> error
    end
  end

  def update_message(_, _), do: {:error, :provider_authentication}

  def normalize_action(%{
        "type" => "block_actions",
        "team" => %{"id" => workspace_id},
        "channel" => %{"id" => channel_id},
        "user" => %{"id" => user_id},
        "message" => %{"ts" => message_ts},
        "actions" => [%{"action_id" => action_id, "value" => draft_id} | _]
      })
      when action_id in [
             "create_linear_task",
             "cancel_linear_task",
             "apply_pr_followup",
             "cancel_pr_followup"
           ] and is_binary(draft_id) and
             is_binary(workspace_id) and is_binary(channel_id) and is_binary(user_id) and
             is_binary(message_ts) do
    case String.split(draft_id, ":", parts: 2) do
      [id] ->
        normalized_action(action_id, id, 1, workspace_id, channel_id, user_id, message_ts)

      [id, revision] ->
        case Integer.parse(revision) do
          {number, ""} when number > 0 ->
            normalized_action(
              action_id,
              id,
              number,
              workspace_id,
              channel_id,
              user_id,
              message_ts
            )

          _ ->
            {:error, :invalid_action}
        end
    end
  end

  def normalize_action(_), do: {:error, :invalid_action}

  defp normalized_action(
         action_id,
         draft_id,
         revision,
         workspace_id,
         channel_id,
         user_id,
         message_ts
       ) do
    {:ok,
     %{
       "action_id" => action_id,
       "draft_id" => draft_id,
       "revision" => revision,
       "workspace_id" => workspace_id,
       "channel_id" => channel_id,
       "user_id" => user_id,
       "message_ts" => message_ts
     }}
  end

  defp fetch_channels(_token, _cursor, _channels, _seen_cursors, page)
       when page >= @max_channel_pages,
       do: {:error, :provider_response_too_large}

  defp fetch_channels(token, cursor, channels, seen_cursors, page) do
    params = [
      types: "public_channel,private_channel",
      exclude_archived: "true",
      limit: @channel_page_limit
    ]

    params = if cursor, do: Keyword.put(params, :cursor, cursor), else: params

    case HTTP.request(:get, "https://slack.com/api/conversations.list",
           headers: [{"authorization", "Bearer " <> token}],
           params: params
         ) do
      {:ok, %{"ok" => true, "channels" => listed} = body} when is_list(listed) ->
        visible = Enum.flat_map(listed, &select_channel/1)
        next_cursor = get_in(body, ["response_metadata", "next_cursor"])

        cond do
          not is_binary(next_cursor) or next_cursor == "" ->
            {:ok, Enum.sort_by(channels ++ visible, &String.downcase(&1.name))}

          MapSet.member?(seen_cursors, next_cursor) ->
            {:error, :invalid_provider_response}

          true ->
            fetch_channels(
              token,
              next_cursor,
              channels ++ visible,
              MapSet.put(seen_cursors, next_cursor),
              page + 1
            )
        end

      {:ok, %{"ok" => false} = body} ->
        if body["error"] == "missing_scope",
          do: {:error, :missing_scope},
          else: {:error, :provider_rejected}

      {:ok, _} ->
        {:error, :invalid_provider_response}

      error ->
        error
    end
  end

  defp select_channel(%{"id" => id, "name" => name, "is_member" => true} = channel)
       when is_binary(id) and is_binary(name) do
    if String.starts_with?(id, ["C", "G"]) and channel["is_archived"] != true,
      do: [%{id: id, name: name}],
      else: []
  end

  defp select_channel(_), do: []

  def deliver(token, payload), do: deliver_result(token, payload, false)
  def deliver_with_receipt(token, payload), do: deliver_result(token, payload, true)

  defp deliver_result(token, payload, receipt?) do
    case HTTP.request(:post, "https://slack.com/api/chat.postMessage",
           headers: [{"authorization", "Bearer " <> token}],
           json: payload
         ) do
      {:ok, %{"ok" => true} = response} ->
        cond do
          not receipt? -> :ok
          is_binary(response["ts"]) and response["ts"] != "" -> {:ok, response["ts"]}
          true -> :ambiguous
        end

      {:ok, %{"ok" => false}} ->
        :rejected

      {:error, reason}
      when reason in [:provider_rejected, :provider_authentication, :provider_rate_limit] ->
        :rejected

      _ ->
        :ambiguous
    end
  end

  def report(payload, channel) do
    result = payload["result"]

    text =
      String.slice(payload["title"], 0, 240) <>
        "\nResult: " <> payload["state"] <> "\n" <> (result["summary"] || "Task finished.")

    blocks = [%{type: "section", text: %{type: "plain_text", text: text}}]

    checks =
      Enum.map_join(result["validation"] || [], "\n", fn check ->
        check["status"] <> ": " <> check["command"]
      end)

    detail =
      Enum.filter(
        [if(checks != "", do: "Validation\n" <> checks), result["question"]],
        &(is_binary(&1) and &1 != "")
      )
      |> Enum.join("\n\n")
      |> String.slice(0, 2_900)

    blocks =
      if detail != "",
        do: blocks ++ [%{type: "section", text: %{type: "plain_text", text: detail}}],
        else: blocks

    blocks =
      if result["pr_url"],
        do:
          blocks ++
            [
              %{
                type: "section",
                text: %{type: "mrkdwn", text: "<" <> result["pr_url"] <> "|Review pull request>"}
              }
            ],
        else: blocks

    %{channel: channel, text: text, blocks: blocks, unfurl_links: false, unfurl_media: false}
  end

  def clarification(payload, channel) do
    question_text =
      payload["questions"]
      |> Enum.map_join("\n", fn question ->
        options =
          case question["options"] do
            values when is_list(values) and values != [] ->
              "\nOptions: " <> Enum.map_join(values, ", ", & &1["label"])

            _ ->
              ""
          end

        "• *" <> question["header"] <> "* — " <> question["question"] <> options
      end)
      |> String.slice(0, 2_500)

    text = "A task needs your input: " <> String.slice(payload["title"] || "Task", 0, 200)

    %{
      channel: channel,
      text: text,
      blocks: [
        %{type: "section", text: %{type: "plain_text", text: text <> "\n" <> question_text}},
        %{
          type: "actions",
          elements: [
            %{
              type: "button",
              text: %{type: "plain_text", text: "Provide context"},
              url: payload["url"],
              action_id: "open_clarification"
            }
          ]
        }
      ],
      unfurl_links: false,
      unfurl_media: false
    }
  end
end
