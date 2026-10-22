defmodule DevOrchestrator.Runs do
  alias DevOrchestrator.{Store, Projects, Accounts}
  alias DevOrchestrator.Connections.{GitHub, OAuth}
  alias DevOrchestrator.Runs.FailureBudget

  def list(scope),
    do:
      Store.rows(
        "SELECT id,project_id,title,state,generation,lifecycle,result,created_at FROM runs WHERE organization_id=$1 ORDER BY created_at DESC LIMIT 100",
        [scope.organization_id]
      )

  def get(scope, id) do
    case Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2", [
           id,
           scope.organization_id
         ]) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  def events(scope, id),
    do:
      Store.rows(
        "SELECT kind,data,created_at FROM (SELECT kind,data,created_at,sequence FROM run_events WHERE run_id=$1 AND organization_id=$2 ORDER BY created_at DESC,sequence DESC LIMIT 200) recent ORDER BY created_at,sequence",
        [id, scope.organization_id]
      )

  def subscribe(scope, id) do
    with {:ok, _run} <- get(scope, id) do
      Phoenix.PubSub.subscribe(DevOrchestrator.PubSub, "run:" <> id)
      :ok
    end
  end

  def create(scope, project_id, attrs) do
    with {:ok, _} <- Projects.get_project(scope, project_id),
         true <-
           is_binary(attrs["title"]) and byte_size(attrs["title"]) in 1..240 and
             is_binary(attrs["prompt"]) and byte_size(attrs["prompt"]) in 1..32_000 do
      source = attrs["source_key"] || "manual:" <> Store.id()

      {:ok,
       Store.one(
         "INSERT INTO runs(id,organization_id,project_id,source_key,title,prompt,issue_url) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(project_id,source_key) DO UPDATE SET source_key=excluded.source_key RETURNING *",
         [
           Store.id(),
           scope.organization_id,
           project_id,
           source,
           attrs["title"],
           attrs["prompt"],
           attrs["issue_url"]
         ]
       )}
    else
      false -> {:error, :invalid_task}
      error -> error
    end
  end

  def claim(executor) do
    Store.transaction(fn ->
      live_executor!(executor)
      expire_leases()

      project =
        Store.one(
          """
            SELECT p.* FROM projects p JOIN executor_bindings b ON b.project_id=p.id AND b.organization_id=p.organization_id
            WHERE b.executor_id=$1 AND b.organization_id=$2
            AND EXISTS(SELECT 1 FROM runs r WHERE r.project_id=p.id AND r.state='queued')
            AND (SELECT count(*) FROM runs r WHERE r.project_id=p.id AND r.state IN ('leased','running','waiting_for_executor'))<p.concurrency
            ORDER BY p.created_at FOR UPDATE OF p SKIP LOCKED LIMIT 1
          """,
          [executor["id"], executor["organization_id"]]
        )

      if project do
        run =
          Store.one(
            "SELECT * FROM runs WHERE project_id=$1 AND organization_id=$2 AND state='queued' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1",
            [project["id"], executor["organization_id"]]
          )

        if run do
          snapshot =
            Projects.snapshot(%{data: project})
            |> Map.put("execution_policy", DevOrchestrator.ExecutionPolicy.for_task(project, run))

          Store.one(
            "UPDATE runs SET executor_id=$2,state='leased',generation=generation+1,sequence=0,snapshot=$3,lease_expires_at=now()+interval '90 seconds',updated_at=now() WHERE id=$1 RETURNING *",
            [run["id"], executor["id"], snapshot]
          )
          |> lease_payload()
        end
      end
    end)
  end

  def renew(executor, lease) do
    Store.transaction(fn ->
      run = leased_run!(executor, lease)

      Store.exec(
        "UPDATE runs SET lease_expires_at=now()+interval '90 seconds',updated_at=now() WHERE id=$1",
        [run["id"]]
      )

      %{expires_in_ms: 90_000}
    end)
  end

  def github_token(executor, lease, purpose) when purpose in [:checkout, :publish] do
    with {:ok, access} <- Store.transaction(fn -> github_token_access!(executor, lease) end),
         {:ok, token} <-
           GitHub.installation_token(access.installation_id, access.repository, purpose),
         {:ok, _} <- Store.transaction(fn -> github_token_access!(executor, lease, access) end) do
      config = OAuth.config("github")
      app_id = config[:app_id]
      app_slug = config[:app_slug]

      if is_binary(app_id) and is_binary(app_slug) do
        {:ok,
         Map.merge(token, %{
           author_name: app_slug <> "[bot]",
           author_email: app_id <> "+" <> app_slug <> "[bot]@users.noreply.github.com"
         })}
      else
        {:error, :github_not_configured}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :github_installation_required}
    end
  end

  def github_token(_, _, _), do: {:error, :invalid_purpose}

  defp github_token_access!(executor, lease) do
    run = leased_run!(executor, lease)
    repository = get_in(run, ["snapshot", "repository"])

    project =
      Store.one(
        "SELECT repository FROM projects WHERE id=$1 AND organization_id=$2",
        [run["project_id"], executor["organization_id"]]
      ) || Store.halt(:github_installation_required)

    if not is_binary(repository) or project["repository"] != repository,
      do: Store.halt(:repository_changed)

    github_token_access!(executor, lease, repository)
  end

  defp github_token_access!(executor, lease, %{repository: repository, installation_id: id}) do
    current = github_token_access!(executor, lease, repository)
    if current.installation_id != id, do: Store.halt(:github_installation_required)
    current
  end

  defp github_token_access!(executor, lease, repository) when is_binary(repository) do
    run = leased_run!(executor, lease)

    installation =
      Store.one(
        "SELECT installation_id FROM github_app_installations WHERE organization_id=$1 AND project_id=$2 AND repository=$3",
        [executor["organization_id"], run["project_id"], repository]
      ) || Store.halt(:github_installation_required)

    %{repository: repository, installation_id: installation["installation_id"]}
  end

  def append_event(executor, lease, %{"sequence" => sequence, "kind" => kind} = event)
      when is_integer(sequence) and sequence > 0 and
             kind in ~w(started progress activity failure blocked candidate no_changes) do
    result =
      Store.transaction(fn ->
        live_executor!(executor)

        run =
          Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
            lease["id"],
            executor["organization_id"]
          ]) || Store.halt(:stale_lease)

        valid_generation!(run, executor, lease)

        if sequence <= run["sequence"] do
          :duplicate
        else
          if sequence != run["sequence"] + 1, do: Store.halt(:sequence_gap)
          if run["state"] not in ~w(leased running) or expired?(run), do: Store.halt(:stale_lease)

          data =
            case DevOrchestrator.Runs.Event.sanitize(run, kind, Map.get(event, "data", %{})) do
              {:ok, safe} -> safe
              {:error, reason} -> Store.halt(reason)
            end

          Store.exec("INSERT INTO run_events VALUES($1,$2,$3,$4,$5,$6,$7,now())", [
            run["organization_id"],
            run["id"],
            run["lifecycle"],
            run["generation"],
            sequence,
            kind,
            data
          ])

          Store.exec("UPDATE runs SET sequence=$2,updated_at=now() WHERE id=$1", [
            run["id"],
            sequence
          ])

          transition(run, kind, data)
        end
      end)

    case result do
      {:ok, :duplicate} ->
        result

      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          DevOrchestrator.PubSub,
          "run:" <> lease["id"],
          {:run_updated, lease["id"]}
        )

        result

      _ ->
        result
    end
  end

  def append_event(_, _, _), do: {:error, :invalid_event}

  def reconcile(executor, lease, journal) do
    Store.transaction(fn ->
      live_executor!(executor)

      run =
        Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
          lease["id"],
          executor["organization_id"]
        ]) || Store.halt(:stale_lease)

      valid_generation!(run, executor, lease)

      cond do
        run["state"] in ~w(succeeded failed cancelled blocked queued) ->
          %{action: "acknowledge", state: run["state"]}

        journal["pending_event"] != nil ->
          Store.exec(
            "UPDATE runs SET state='running',lease_expires_at=now()+interval '90 seconds' WHERE id=$1",
            [run["id"]]
          )

          %{action: "replay", expires_in_ms: 90_000}

        true ->
          finish(run, "blocked", %{
            "summary" =>
              "Executor stopped before final delivery. Review preserved work before retrying."
          })

          %{action: "acknowledge", state: "blocked"}
      end
    end)
  end

  def retry(scope, id) do
    with true <- Accounts.owner?(scope), {:ok, _} <- get(scope, id) do
      case Store.one(
             "UPDATE runs SET state='queued',lifecycle=lifecycle+1,generation=generation+1,failures='{}',result=NULL,executor_id=NULL,lease_expires_at=NULL,sequence=0 WHERE id=$1 AND organization_id=$2 AND state IN ('blocked','failed','cancelled') RETURNING id",
             [id, scope.organization_id]
           ) do
        nil -> {:error, :not_retryable}
        _ -> :ok
      end
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def cancel(scope, id) do
    with true <- Accounts.owner?(scope), {:ok, _} <- get(scope, id) do
      Store.transaction(fn ->
        run =
          Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
            id,
            scope.organization_id
          ])

        if run["state"] in ~w(succeeded failed cancelled), do: Store.halt(:not_cancellable)

        finish(run, "cancelled", %{
          "summary" => "Cancelled by workspace owner. Files are preserved."
        })
      end)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def expire_leases,
    do:
      Store.exec(
        "UPDATE runs SET state='waiting_for_executor',updated_at=now() WHERE state IN ('running','leased') AND lease_expires_at<=now()"
      )

  defp live_executor!(executor) do
    Store.one(
      "SELECT id FROM executors WHERE id=$1 AND organization_id=$2 AND revoked_at IS NULL",
      [executor["id"], executor["organization_id"]]
    ) || Store.halt(:unauthorized)
  end

  defp leased_run!(executor, lease) do
    live_executor!(executor)

    run =
      Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
        lease["id"],
        executor["organization_id"]
      ]) || Store.halt(:stale_lease)

    valid_generation!(run, executor, lease)
    if run["state"] not in ~w(leased running) or expired?(run), do: Store.halt(:stale_lease)
    run
  end

  defp valid_generation!(run, executor, lease) do
    if run["executor_id"] != executor["id"] or run["generation"] != lease["generation"] or
         run["lifecycle"] != lease["lifecycle"],
       do: Store.halt(:stale_lease)

    binding =
      Store.one(
        "SELECT project_id FROM executor_bindings WHERE executor_id=$1 AND project_id=$2 AND organization_id=$3",
        [executor["id"], run["project_id"], executor["organization_id"]]
      )

    if is_nil(binding), do: Store.halt(:unauthorized)
  end

  defp expired?(run), do: DateTime.compare(run["lease_expires_at"], DateTime.utc_now()) != :gt

  defp transition(run, "failure", data) do
    {history, exhausted?} = FailureBudget.record(run["failures"], data)
    Store.exec("UPDATE runs SET failures=$2 WHERE id=$1", [run["id"], history])

    if exhausted? do
      finish(run, "cancelled", %{
        "summary" =>
          "Execution cancelled after three equivalent failures. Files and commits are preserved."
      })
    else
      Store.exec(
        "UPDATE runs SET state='queued',executor_id=NULL,lease_expires_at=NULL WHERE id=$1",
        [run["id"]]
      )

      %{state: "queued"}
    end
  end

  defp transition(run, "blocked", data),
    do:
      finish(run, "blocked", %{
        "summary" =>
          "Executor blocked: " <>
            data["category"] <> ". Review local prerequisites and project configuration."
      })

  defp transition(run, "candidate", data) do
    case DevOrchestrator.Delivery.Verification.verify(run, data) do
      {:ok, result} ->
        finish(run, "succeeded", result)

      {:error, reason} ->
        transition(run, "failure", %{
          "fingerprint" => Store.digest("verification:" <> to_string(reason))
        })
    end
  end

  defp transition(run, "no_changes", _) do
    finish(run, "succeeded", %{
      "summary" => "Completed without code changes; no pull request was created.",
      "outcome" => "completed_no_changes"
    })
  end

  defp transition(run, _, _) do
    Store.exec("UPDATE runs SET state='running' WHERE id=$1", [run["id"]])
    %{state: "running"}
  end

  defp finish(run, state, result) do
    Store.exec(
      "UPDATE runs SET state=$2,result=$3,lease_expires_at=NULL,updated_at=now() WHERE id=$1",
      [run["id"], state, result]
    )

    DevOrchestrator.Delivery.Outbox.enqueue(run, state, result)
    %{state: state}
  end

  defp lease_payload(run),
    do:
      Map.take(
        run,
        ~w(id project_id title prompt source_key issue_url generation lifecycle snapshot sequence)
      )
      |> Map.put("expires_in_ms", 90_000)
end
