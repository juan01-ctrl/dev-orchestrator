defmodule DevOrchestrator.Intake.Inbox do
  alias DevOrchestrator.Store

  @max_body_bytes 65_536

  def normalize_linear(headers, raw_body) when is_map(headers) and is_binary(raw_body) do
    with true <- byte_size(raw_body) in 1..@max_body_bytes,
         {:ok, %{"type" => "Issue", "action" => action, "organizationId" => org_id} = body}
         when action in ["create", "update", "remove"] and is_binary(org_id) <-
           Jason.decode(raw_body),
         issue_id when is_binary(issue_id) <- get_in(body, ["data", "id"]),
         delivery_id when is_binary(delivery_id) and byte_size(delivery_id) in 1..200 <-
           headers["linear-delivery"] do
      {:ok, org_id, %{"type" => "Issue", "action" => action, "issue_id" => issue_id}, delivery_id}
    else
      false -> {:error, :payload_too_large}
      {:ok, _} -> {:error, :unsupported_event}
      {:error, _} -> {:error, :invalid_payload}
      _ -> {:error, :invalid_delivery}
    end
  end

  def normalize_linear(_, _), do: {:error, :invalid_payload}

  def accept_linear(headers, raw_body) when is_map(headers) and is_binary(raw_body) do
    result =
      with {:ok, org_id, event, delivery_id} <- normalize_linear(headers, raw_body) do
        case Store.one(
               "INSERT INTO webhook_inbox(id,provider,delivery_id,organization_external_id,event) VALUES($1,'linear',$2,$3,$4) ON CONFLICT(provider,delivery_id) DO NOTHING RETURNING id",
               [Store.id(), delivery_id, org_id, event]
             ) do
          %{"id" => _} -> {:ok, :accepted}
          nil -> {:ok, :duplicate}
        end
      else
        {:error, _} = error -> error
      end

    :telemetry.execute(
      [:dev_orchestrator, :linear, :webhook],
      %{count: 1},
      %{outcome: webhook_outcome(result)}
    )

    result
  end

  def accept_linear(_, _), do: {:error, :invalid_payload}

  defp webhook_outcome({:ok, :accepted}), do: "accepted"
  defp webhook_outcome({:ok, :duplicate}), do: "duplicate"
  defp webhook_outcome(_), do: "rejected"

  def claim do
    Store.transaction(fn ->
      row =
        Store.one(
          "SELECT * FROM webhook_inbox WHERE (state='pending' AND next_attempt_at<=now()) OR (state='processing' AND claimed_at<now()-interval '2 minutes') ORDER BY received_at FOR UPDATE SKIP LOCKED LIMIT 1"
        )

      if row do
        Store.one(
          "UPDATE webhook_inbox SET state='processing',claimed_at=now(),attempts=attempts+1 WHERE id=$1 RETURNING *",
          [row["id"]]
        )
      end
    end)
  end

  def complete(id),
    do:
      Store.exec(
        "UPDATE webhook_inbox SET state='processed',processed_at=now(),claimed_at=NULL,last_error_category=NULL WHERE id=$1",
        [id]
      )

  def fail(id, attempts, category) do
    if attempts >= 8 do
      Store.exec(
        "UPDATE webhook_inbox SET state='failed',claimed_at=NULL,last_error_category=$2 WHERE id=$1",
        [id, category]
      )
    else
      delay = min(round(:math.pow(2, attempts)), 300)

      Store.exec(
        "UPDATE webhook_inbox SET state='pending',claimed_at=NULL,next_attempt_at=now()+($2 * interval '1 second'),last_error_category=$3 WHERE id=$1",
        [id, delay, category]
      )
    end
  end

  def process_one do
    case claim() do
      {:ok, nil} -> :empty
      {:ok, row} -> process(row)
      {:error, _} = error -> error
    end
  end

  defp process(row) do
    connections =
      Store.rows(
        "SELECT * FROM connections WHERE provider='linear' AND external_id=$1 AND revoked_at IS NULL ORDER BY created_at",
        [row["organization_external_id"]]
      )

    cond do
      connections == [] ->
        complete(row["id"])
        :ignored

      Enum.all?(connections, &process_connection(row, &1)) ->
        complete(row["id"])
        :processed

      true ->
        fail(row["id"], row["attempts"], "linear_unavailable")
        :retry
    end
  end

  defp process_connection(row, connection) do
    projects =
      Store.rows(
        "SELECT DISTINCT p.* FROM projects p JOIN connection_grants g ON g.project_id=p.id AND g.organization_id=p.organization_id WHERE g.connection_id=$1 AND g.organization_id=$2 ORDER BY p.created_at",
        [connection["id"], connection["organization_id"]]
      )

    if row["event"]["action"] == "remove" do
      Enum.each(
        projects,
        &DevOrchestrator.Runs.Lifecycle.remove_issue(&1, row["event"]["issue_id"])
      )

      true
    else
      process_visible_issue(row, connection, projects)
    end
  end

  defp process_visible_issue(row, connection, projects) do
    with {:ok, token} <- DevOrchestrator.Connections.credential(connection),
         {:ok, %{"data" => %{"issue" => issue}}} <-
           DevOrchestrator.Connections.Linear.query(
             token,
             "query($id:String!){issue(id:$id){id identifier title description url state{name} team{id} project{id}}}",
             %{"id" => row["event"]["issue_id"]}
           ) do
      if is_map(issue),
        do:
          Enum.each(projects, fn project ->
            DevOrchestrator.Runs.Lifecycle.apply_issue(project, issue, %{
              "linear_connection_id" => connection["id"]
            })
          end),
        else:
          Enum.each(
            projects,
            &DevOrchestrator.Runs.Lifecycle.remove_issue(&1, row["event"]["issue_id"])
          )

      true
    else
      _ -> false
    end
  end
end
