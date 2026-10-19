defmodule DevOrchestrator.Delivery.Outbox do
  alias DevOrchestrator.Store

  def enqueue(run, state, result) do
    payload = %{
      "title" => run["title"],
      "source_key" => run["source_key"],
      "state" => state,
      "result" => result,
      "snapshot" => run["snapshot"] || %{},
      "issue_url" => run["issue_url"]
    }

    for provider <- ~w(slack linear) do
      Store.exec(
        "INSERT INTO outbox(id,organization_id,project_id,run_id,lifecycle,kind,payload) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(run_id,lifecycle,kind) DO NOTHING",
        [
          Store.id(),
          run["organization_id"],
          run["project_id"],
          run["id"],
          run["lifecycle"],
          provider <> ":" <> state,
          payload
        ]
      )
    end

    :ok
  end

  def claim do
    Store.transaction(fn ->
      # A prior worker may have sent the Slack request before it stopped.
      Store.exec(
        "UPDATE outbox SET state='ambiguous' WHERE state='sending' AND claimed_at<now()-interval '2 minutes'"
      )

      row =
        Store.one(
          "SELECT * FROM outbox WHERE state='pending' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1"
        )

      if row,
        do:
          Store.one(
            "UPDATE outbox SET state='sending',attempts=attempts+1,claimed_at=now() WHERE id=$1 RETURNING *",
            [row["id"]]
          )
    end)
  end

  def delivery_result(row, result) do
    state =
      case result do
        :ok -> "sent"
        :not_configured -> "not_configured"
        :ambiguous -> "ambiguous"
        :rejected -> if row["attempts"] < 2, do: "pending", else: "failed"
        _ -> "failed"
      end

    Store.exec("UPDATE outbox SET state=$2 WHERE id=$1", [row["id"], state])
  end

  def list(scope, run_id),
    do:
      Store.rows(
        "SELECT kind,state,attempts FROM outbox WHERE run_id=$1 AND organization_id=$2 ORDER BY created_at",
        [run_id, scope.organization_id]
      )
end
