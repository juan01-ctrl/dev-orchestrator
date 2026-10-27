defmodule DevOrchestrator.Delivery.Outbox do
  alias DevOrchestrator.Store

  def enqueue(run, state, result) do
    snapshot =
      run["snapshot"] ||
        Store.one(
          "SELECT slack_channel,review_state FROM projects WHERE organization_id=$1 AND id=$2",
          [run["organization_id"], run["project_id"]]
        ) || %{}

    payload = %{
      "title" => run["title"],
      "source_key" => run["source_key"],
      "state" => state,
      "result" => result,
      "snapshot" => snapshot,
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
          provider <>
            ":" <>
            state <>
            if((run["repair_count"] || 0) > 0, do: ":repair#{run["repair_count"]}", else: "") <>
            if((run["followup_count"] || 0) > 0,
              do: ":followup#{run["followup_count"]}",
              else: ""
            ),
          payload
        ]
      )
    end

    :ok
  end

  def enqueue_clarification(run, clarification) do
    payload = %{
      "title" => run["title"],
      "run_id" => run["id"],
      "clarification_id" => clarification["id"],
      "questions" => clarification["questions"],
      "decision" => is_map(clarification["slack_binding"]),
      "snapshot" => run["snapshot"] || %{},
      "url" => Application.fetch_env!(:dev_orchestrator, :public_url) <> "/app/runs/" <> run["id"]
    }

    Store.exec(
      "INSERT INTO outbox(id,organization_id,project_id,run_id,lifecycle,kind,payload) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(run_id,lifecycle,kind) DO NOTHING",
      [
        Store.id(),
        run["organization_id"],
        run["project_id"],
        run["id"],
        run["lifecycle"],
        "slack:clarification:" <> clarification["id"],
        payload
      ]
    )

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
          "SELECT * FROM outbox WHERE state='pending' AND next_attempt_at<=now() ORDER BY next_attempt_at,created_at FOR UPDATE SKIP LOCKED LIMIT 1"
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
    outcome = DevOrchestrator.Delivery.Retry.result(row["attempts"], result)

    Store.exec(
      "UPDATE outbox SET state=$2,last_error_category=$3,next_attempt_at=CASE WHEN $4::integer IS NULL THEN next_attempt_at ELSE now()+($4::text||' seconds')::interval END WHERE id=$1",
      [row["id"], outcome.state, outcome.category, outcome.delay_seconds]
    )
  end

  def list(scope, run_id),
    do:
      Store.rows(
        "SELECT id,kind,state,attempts,last_error_category FROM outbox WHERE run_id=$1 AND organization_id=$2 ORDER BY created_at",
        [run_id, scope.organization_id]
      )

  def retry_failed(scope, id) do
    case Store.one(
           "UPDATE outbox SET state='pending',attempts=0,last_error_category=NULL,next_attempt_at=now(),claimed_at=NULL WHERE id=$1 AND organization_id=$2 AND state='failed' RETURNING id",
           [id, scope.organization_id]
         ) do
      nil -> {:error, :not_retryable}
      _ -> :ok
    end
  end

  def acknowledge_ambiguous(scope, id) do
    case Store.one(
           "UPDATE outbox SET state='acknowledged',last_error_category=NULL WHERE id=$1 AND organization_id=$2 AND state='ambiguous' RETURNING id",
           [id, scope.organization_id]
         ) do
      nil -> {:error, :not_acknowledgeable}
      _ -> :ok
    end
  end
end
