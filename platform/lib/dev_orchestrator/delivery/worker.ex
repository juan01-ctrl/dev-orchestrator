defmodule DevOrchestrator.Delivery.Worker do
  alias DevOrchestrator.Connections
  alias DevOrchestrator.Connections.{Linear, Slack}
  alias DevOrchestrator.Delivery.Outbox

  def tick do
    case Outbox.claim() do
      {:ok, row} when is_map(row) -> Outbox.delivery_result(row, deliver(row))
      _ -> :ok
    end
  end

  defp deliver(row) do
    [provider, _state] = String.split(row["kind"], ":")
    connection = Connections.for_project(row["organization_id"], row["project_id"], provider)

    if connection do
      case Connections.credential(connection) do
        {:ok, token} -> send_report(provider, token, row["payload"])
        _ -> :rejected
      end
    else
      :not_configured
    end
  end

  defp send_report("slack", token, payload) do
    channel = payload["snapshot"]["slack_channel"]

    if is_binary(channel) and Regex.match?(~r/\A[CG][A-Z0-9]+\z/, channel),
      do: Slack.deliver(token, Slack.report(payload, channel)),
      else: :not_configured
  end

  defp send_report("linear", token, payload) do
    if String.starts_with?(payload["source_key"], "linear:") and payload["state"] == "succeeded" and
         payload["result"]["pr_url"] do
      id = String.replace_prefix(payload["source_key"], "linear:", "")

      query =
        "query($id:String!){issue(id:$id){team{states{nodes{id name}}} attachments{nodes{url}}}}"

      with {:ok, %{"data" => %{"issue" => issue}}} when is_map(issue) <-
             Linear.query(token, query, %{"id" => id}),
           target when is_map(target) <-
             Enum.find(
               get_in(issue, ["team", "states", "nodes"]),
               &(&1["name"] == payload["snapshot"]["review_state"])
             ),
           {:ok, _} <-
             Linear.query(
               token,
               "mutation($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success}}",
               %{"id" => id, "input" => %{"stateId" => target["id"]}}
             ) do
        unless Enum.any?(
                 get_in(issue, ["attachments", "nodes"]),
                 &(&1["url"] == payload["result"]["pr_url"])
               ) do
          case Linear.query(
                 token,
                 "mutation($input:AttachmentCreateInput!){attachmentCreate(input:$input){success}}",
                 %{
                   "input" => %{
                     "issueId" => id,
                     "url" => payload["result"]["pr_url"],
                     "title" => "Verified pull request"
                   }
                 }
               ) do
            {:ok, _} -> :ok
            _ -> :rejected
          end
        else
          :ok
        end
      else
        _ -> :rejected
      end
    else
      :not_configured
    end
  end
end
