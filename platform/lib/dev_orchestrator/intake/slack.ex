defmodule DevOrchestrator.Intake.Slack do
  @max_text_bytes 4_000
  @max_file_ids 5

  def normalize_event(%{
        "type" => "event_callback",
        "event_id" => event_id,
        "team_id" => workspace_id,
        "event" => %{"type" => "app_mention"} = event
      })
      when is_binary(event_id) and byte_size(event_id) in 1..200 and is_binary(workspace_id) do
    cond do
      is_binary(event["bot_id"]) or event["subtype"] in ["bot_message", "message_changed"] ->
        {:ignore, :bot_message}

      event["channel_type"] in ["im", "mpim"] or String.starts_with?(event["channel"] || "", "D") ->
        {:ignore, :unsupported_channel}

      not valid_string?(event["user"]) or not valid_string?(event["channel"]) or
          not valid_string?(event["ts"]) ->
        {:error, :invalid_event}

      true ->
        {:ok,
         %{
           "event_id" => event_id,
           "workspace_id" => workspace_id,
           "channel_id" => event["channel"],
           "requester_slack_user_id" => event["user"],
           "message_ts" => event["ts"],
           "thread_ts" => event["thread_ts"] || event["ts"],
           "text" => normalize_text(event["text"]),
           "file_ids" => file_ids(event["files"])
         }}
    end
  end

  def normalize_event(%{"type" => "event_callback", "event" => %{"type" => "app_mention"}}),
    do: {:error, :invalid_event}

  def normalize_event(%{"type" => "event_callback"}), do: {:ignore, :unsupported_event}
  def normalize_event(_), do: {:ignore, :unsupported_event}

  def task_file_id(%{"file_ids" => [id]}) when is_binary(id) and id != "",
    do: {:ok, id}

  def task_file_id(%{"file_ids" => [], "text" => text}) when is_binary(text) do
    if String.trim(text) == "", do: {:error, :input_required}, else: {:ok, nil}
  end

  def task_file_id(_), do: {:error, :input_required}

  defp valid_string?(value), do: is_binary(value) and value != "" and byte_size(value) <= 200

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<@[A-Z0-9]+>/, "")
    |> String.trim()
    |> String.slice(0, @max_text_bytes)
  end

  defp normalize_text(_), do: ""

  defp file_ids(files) when is_list(files) do
    files
    |> Enum.take(@max_file_ids)
    |> Enum.flat_map(fn
      %{"id" => id} when is_binary(id) and byte_size(id) in 1..200 -> [id]
      _ -> []
    end)
  end

  defp file_ids(_), do: []
end
