defmodule DevOrchestrator.Delivery.SlackReports do
  @moduledoc false
  alias DevOrchestrator.{Store, Connections.Slack}

  def deliver(row, connection, token) do
    channel = row["payload"]["snapshot"]["slack_channel"]

    project =
      Store.one(
        "SELECT slack_workspace_id,slack_channel FROM projects WHERE id=$1 AND organization_id=$2",
        [row["project_id"], row["organization_id"]]
      )

    if is_map(project) and is_binary(channel) and Regex.match?(~r/\A[CG][A-Z0-9]+\z/, channel) and
         project["slack_channel"] == channel and
         project["slack_workspace_id"] == connection["external_id"] do
      root =
        Store.one(
          "SELECT thread_ts FROM slack_run_threads WHERE organization_id=$1 AND run_id=$2 AND lifecycle=$3 AND workspace_id=$4 AND channel_id=$5 ORDER BY created_at,thread_ts LIMIT 1",
          [
            row["organization_id"],
            row["run_id"],
            row["lifecycle"],
            connection["external_id"],
            channel
          ]
        )

      message = Slack.report(row["payload"], channel) |> Map.put(:client_msg_id, row["id"])
      message = if root, do: Map.put(message, :thread_ts, root["thread_ts"]), else: message

      message =
        Map.update!(
          message,
          :blocks,
          &(&1 ++
              [
                %{
                  type: "context",
                  elements: [
                    %{
                      type: "plain_text",
                      text:
                        "To request PR changes, reply in this thread and mention me with text or one audio file. I will ask for confirmation."
                    }
                  ]
                }
              ])
        )

      case Slack.deliver_with_receipt(token, message) do
        {:ok, ts} ->
          requester = original_requester(row)

          Store.exec(
            "INSERT INTO slack_run_threads(organization_id,project_id,run_id,lifecycle,workspace_id,channel_id,thread_ts,requester_slack_user_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT DO NOTHING",
            [
              row["organization_id"],
              row["project_id"],
              row["run_id"],
              row["lifecycle"],
              connection["external_id"],
              channel,
              if(root, do: root["thread_ts"], else: ts),
              requester
            ]
          )

          :ok

        result ->
          result
      end
    else
      :not_configured
    end
  rescue
    # Slack may have accepted the message before local persistence failed.
    _ -> :ambiguous
  end

  defp original_requester(row) do
    case DevOrchestrator.Connections.Linear.issue_id_from_source_key(row["payload"]["source_key"]) do
      {:ok, issue_id} ->
        case Store.one(
               "SELECT requester_slack_user_id FROM slack_task_drafts WHERE organization_id=$1 AND project_id=$2 AND linear_issue_id=$3 AND target_run_id IS NULL ORDER BY created_at LIMIT 1",
               [row["organization_id"], row["project_id"], issue_id]
             ) do
          %{"requester_slack_user_id" => user} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
