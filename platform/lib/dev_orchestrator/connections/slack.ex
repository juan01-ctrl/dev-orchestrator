defmodule DevOrchestrator.Connections.Slack do
  alias DevOrchestrator.Connections.HTTP

  @channel_page_limit 200
  @max_channel_pages 100

  def channels(token) when is_binary(token) and token != "" do
    fetch_channels(token, nil, [], MapSet.new(), 0)
  end

  def channels(_), do: {:error, :invalid_token}

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

  def deliver(token, payload) do
    case HTTP.request(:post, "https://slack.com/api/chat.postMessage",
           headers: [{"authorization", "Bearer " <> token}],
           json: payload
         ) do
      {:ok, %{"ok" => true}} ->
        :ok

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
