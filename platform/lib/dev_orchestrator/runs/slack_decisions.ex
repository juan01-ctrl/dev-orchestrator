defmodule DevOrchestrator.Runs.SlackDecisions do
  @moduledoc false
  alias DevOrchestrator.{Store, Connections}
  alias DevOrchestrator.Connections.{Slack, Linear}

  def binding(run) do
    project =
      Store.one(
        "SELECT slack_workspace_id,slack_channel FROM projects WHERE id=$1 AND organization_id=$2",
        [run["project_id"], run["organization_id"]]
      )

    connection = Connections.for_project(run["organization_id"], run["project_id"], "slack")

    with %{} <- project,
         %{} <- connection,
         true <- project["slack_workspace_id"] == connection["external_id"],
         channel when is_binary(channel) <- project["slack_channel"],
         true <- channel == get_in(run, ["snapshot", "slack_channel"]),
         user when is_binary(user) <- requester(run) || Connections.slack_installer_id(connection) do
      %{
        "connection_id" => connection["id"],
        "workspace_id" => connection["external_id"],
        "channel_id" => channel,
        "user_id" => user
      }
    else
      _ -> nil
    end
  end

  defp requester(run) do
    with {:ok, issue} <- Linear.issue_id_from_source_key(run["source_key"]),
         %{"requester_slack_user_id" => user} <-
           Store.one(
             "SELECT requester_slack_user_id FROM slack_task_drafts WHERE organization_id=$1 AND project_id=$2 AND linear_issue_id=$3 AND target_run_id IS NULL ORDER BY created_at LIMIT 1",
             [run["organization_id"], run["project_id"], issue]
           ),
         do: user,
         else: (_ -> nil)
  end

  def deliver(row, connection, token) do
    payload = row["payload"]

    current =
      Store.one(
        "SELECT * FROM run_clarifications WHERE id=$1 AND organization_id=$2 AND run_id=$3",
        [payload["clarification_id"], row["organization_id"], row["run_id"]]
      )

    binding = current && current["slack_binding"]

    project =
      Store.one(
        "SELECT slack_workspace_id,slack_channel FROM projects WHERE id=$1 AND organization_id=$2",
        [row["project_id"], row["organization_id"]]
      )

    channel = get_in(payload, ["snapshot", "slack_channel"])

    if is_map(project) and is_binary(channel) and Regex.match?(~r/\A[CG][A-Z0-9]+\z/, channel) and
         project["slack_channel"] == channel and
         project["slack_workspace_id"] == connection["external_id"] do
      message =
        Slack.clarification(
          Map.put(
            payload,
            "decision",
            is_map(binding) and binding["connection_id"] == connection["id"]
          ),
          channel
        )
        |> Map.put(:client_msg_id, row["id"])

      if binding do
        case Slack.deliver_with_receipt(token, message) do
          {:ok, ts} ->
            Store.exec(
              "UPDATE run_clarifications SET slack_binding=jsonb_set(slack_binding,'{message_ts}',to_jsonb($2::text)) WHERE id=$1 AND organization_id=$3 AND slack_binding->>'connection_id'=$4",
              [current["id"], ts, row["organization_id"], connection["id"]]
            )

            :ok

          result ->
            result
        end
      else
        Slack.deliver(token, message)
      end
    else
      :not_configured
    end
  rescue
    _ -> :ambiguous
  end

  # Called only inside Runs' answer transaction. Proof comes from the signed
  # Slack callback and persisted binding, never from an asserted organization ID.
  def lock_action!(action) do
    scope =
      Store.one("SELECT run_id,organization_id FROM run_clarifications WHERE id=$1", [
        action["draft_id"]
      ]) || Store.halt(:clarification_not_found)

    run =
      Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
        scope["run_id"],
        scope["organization_id"]
      ]) || Store.halt(:clarification_not_found)

    clarification =
      Store.one(
        "SELECT * FROM run_clarifications WHERE id=$1 AND organization_id=$2 AND run_id=$3 FOR UPDATE",
        [action["draft_id"], scope["organization_id"], run["id"]]
      ) || Store.halt(:clarification_not_found)

    binding = clarification["slack_binding"] || %{}

    project =
      Store.one(
        "SELECT slack_workspace_id,slack_channel FROM projects WHERE id=$1 AND organization_id=$2",
        [clarification["project_id"], clarification["organization_id"]]
      )

    connection =
      Connections.for_project(
        clarification["organization_id"],
        clarification["project_id"],
        "slack"
      )

    if not is_map(connection) or not is_map(project) or
         connection["id"] != binding["connection_id"] or
         connection["external_id"] != binding["workspace_id"] or
         project["slack_workspace_id"] != binding["workspace_id"] or
         project["slack_channel"] != binding["channel_id"] or
         binding["workspace_id"] != action["workspace_id"] or
         binding["channel_id"] != action["channel_id"] or
         binding["user_id"] != action["user_id"] or not is_binary(binding["message_ts"]) or
         binding["message_ts"] != action["message_ts"],
       do: Store.halt(:forbidden)

    {run, clarification}
  end
end
