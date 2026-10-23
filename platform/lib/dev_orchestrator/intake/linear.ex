defmodule DevOrchestrator.Intake.Linear do
  alias DevOrchestrator.{Store, Connections}
  alias DevOrchestrator.Connections.Linear, as: Client

  def receive_issue(connection, payload, delivery_id) do
    if payload["organizationId"] == connection["external_id"] and payload["type"] == "Issue" and
         payload["action"] in ~w(create update) do
      Store.transaction(fn ->
        inserted =
          Store.one(
            "INSERT INTO webhook_receipts(connection_id,delivery_id) VALUES($1,$2) ON CONFLICT DO NOTHING RETURNING delivery_id",
            [connection["id"], delivery_id]
          )

        if inserted do
          with {:ok, token} <- Connections.credential(connection),
               {:ok, %{"data" => %{"issue" => issue}}} when is_map(issue) <-
                 Client.query(
                   token,
                   "query($id:String!){issue(id:$id){id identifier title description url state{name} team{id} project{id}}}",
                   %{"id" => get_in(payload, ["data", "id"])}
                 ) do
            projects =
              Store.rows(
                "SELECT p.* FROM projects p JOIN connection_grants g ON g.project_id=p.id AND g.organization_id=p.organization_id WHERE g.connection_id=$1 AND g.organization_id=$2",
                [connection["id"], connection["organization_id"]]
              )

            Enum.each(projects, &accept(&1, issue, connection["id"]))
            :accepted
          else
            _ -> Store.halt(:provider_unavailable)
          end
        else
          :duplicate
        end
      end)
    else
      {:ok, :ignored}
    end
  end

  def accept(project, issue, connection_id \\ nil) do
    DevOrchestrator.Runs.Lifecycle.apply_issue(project, issue, %{
      "linear_connection_id" => connection_id
    })
  end
end
