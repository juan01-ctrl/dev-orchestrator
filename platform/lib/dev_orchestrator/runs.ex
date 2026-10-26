defmodule DevOrchestrator.Runs do
  alias DevOrchestrator.{Store, Projects, Accounts}
  alias DevOrchestrator.Connections.{GitHub, OAuth}
  alias DevOrchestrator.Runs.FailureBudget
  alias DevOrchestrator.Runs.Clarification

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
      run -> {:ok, Map.delete(run, "source_context")}
    end
  end

  def events(scope, id),
    do:
      Store.rows(
        "SELECT kind,data,created_at FROM (SELECT kind,data,created_at,sequence FROM run_events WHERE run_id=$1 AND organization_id=$2 ORDER BY created_at DESC,sequence DESC LIMIT 200) recent ORDER BY created_at,sequence",
        [id, scope.organization_id]
      )

  def clarifications(scope, id) do
    with {:ok, _run} <- get(scope, id) do
      rows =
        Store.rows(
          "SELECT c.id,CASE WHEN c.status='open' AND (c.expires_at<=now() OR r.state NOT IN ('running','leased','waiting_for_executor','awaiting_input')) THEN 'expired' ELSE c.status END AS status,c.questions,c.answer,c.created_at FROM run_clarifications c JOIN runs r ON r.id=c.run_id AND r.organization_id=c.organization_id WHERE c.run_id=$1 AND c.organization_id=$2 ORDER BY c.created_at DESC LIMIT 10",
          [id, scope.organization_id]
        )

      {:ok, rows}
    end
  end

  def request_clarification(executor, lease, params) when is_map(params) do
    result =
      Store.transaction(fn ->
        run = leased_run!(executor, lease)

        questions =
          case Clarification.normalize_questions(params) do
            {:ok, normalized} -> normalized
            {:error, reason} -> Store.halt(reason)
          end

        turn_id = params["turnId"] || params["turn_id"] || ""

        request_key =
          :crypto.hash(:sha256, Jason.encode!([turn_id, questions]))
          |> Base.encode16(case: :lower)

        existing =
          Store.one(
            "SELECT * FROM run_clarifications WHERE run_id=$1 AND lifecycle=$2 AND generation=$3 AND request_key=$4",
            [run["id"], run["lifecycle"], run["generation"], request_key]
          )

        if existing do
          clarification_response(existing)
        else
          durable =
            params["durable"] == true and get_in(run, ["snapshot", "workflow_version"]) == 2

          Store.exec(
            "UPDATE run_clarifications SET status='expired' WHERE run_id=$1 AND lifecycle=$2 AND generation=$3 AND status='open' AND expires_at<=now()",
            [run["id"], run["lifecycle"], run["generation"]]
          )

          if Store.one(
               "SELECT id FROM run_clarifications WHERE run_id=$1 AND lifecycle=$2 AND generation=$3 AND status='open'",
               [run["id"], run["lifecycle"], run["generation"]]
             ),
             do: Store.halt(:clarification_already_open)

          clarification =
            Store.one(
              "INSERT INTO run_clarifications(id,organization_id,project_id,run_id,lifecycle,generation,request_key,questions,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,now()+($9 * interval '1 second')) RETURNING *",
              [
                Store.id(),
                run["organization_id"],
                run["project_id"],
                run["id"],
                run["lifecycle"],
                run["generation"],
                request_key,
                questions,
                if(durable, do: 86_400, else: 1_200)
              ]
            )

          DevOrchestrator.Delivery.Outbox.enqueue_clarification(run, clarification)

          if durable do
            remaining =
              max(
                0,
                min(
                  1_200_000,
                  run["snapshot"]["execution_deadline_at_ms"] - System.system_time(:millisecond)
                )
              )

            snapshot =
              run["snapshot"]
              |> Map.delete("execution_deadline_at_ms")
              |> Map.put("execution_remaining_ms", remaining)
              |> Map.put("pending_clarification_id", clarification["id"])

            Store.exec(
              "UPDATE runs SET state='awaiting_input',lease_expires_at=NULL,snapshot=$2,updated_at=now() WHERE id=$1",
              [run["id"], snapshot]
            )

            %{id: clarification["id"], status: "awaiting_input"}
          else
            clarification_response(clarification)
          end
        end
      end)

    broadcast_clarification(lease["id"], result)
    result
  end

  def request_clarification(_, _, _), do: {:error, :invalid_clarification}

  def clarification_status(executor, lease, id) when is_binary(id) do
    Store.transaction(fn ->
      run = leased_run!(executor, lease)

      clarification =
        Store.one(
          "SELECT * FROM run_clarifications WHERE id=$1 AND run_id=$2 AND organization_id=$3 AND lifecycle=$4 AND generation=$5 FOR UPDATE",
          [id, run["id"], run["organization_id"], run["lifecycle"], run["generation"]]
        ) || Store.halt(:clarification_not_found)

      if clarification["status"] == "open" and
           DateTime.compare(clarification["expires_at"], DateTime.utc_now()) != :gt do
        Store.exec("UPDATE run_clarifications SET status='expired' WHERE id=$1", [id])
        %{status: "expired"}
      else
        clarification_response(clarification)
      end
    end)
  end

  def clarification_status(_, _, _), do: {:error, :clarification_not_found}

  def answer_clarification(scope, id, params) when is_binary(id) and is_map(params) do
    result =
      with true <- Accounts.owner?(scope),
           {:ok, row} <-
             Store.transaction(fn ->
               run =
                 Store.one(
                   "SELECT * FROM runs WHERE id=(SELECT run_id FROM run_clarifications WHERE id=$1 AND organization_id=$2) AND organization_id=$2 FOR UPDATE",
                   [id, scope.organization_id]
                 ) || Store.halt(:clarification_not_found)

               clarification =
                 Store.one(
                   "SELECT * FROM run_clarifications WHERE id=$1 AND organization_id=$2 AND run_id=$3 FOR UPDATE",
                   [id, scope.organization_id, run["id"]]
                 ) || Store.halt(:clarification_not_found)

               if clarification["status"] != "open" or
                    run["state"] not in [
                      "running",
                      "leased",
                      "waiting_for_executor",
                      "awaiting_input"
                    ],
                  do: Store.halt(:clarification_not_open)

               if DateTime.compare(clarification["expires_at"], DateTime.utc_now()) != :gt do
                 Store.halt(:clarification_expired)
               end

               answer =
                 case Clarification.normalize_answers(
                        clarification["questions"],
                        params["answers"]
                      ) do
                   {:ok, normalized} -> normalized
                   {:error, reason} -> Store.halt(reason)
                 end

               if run["state"] == "awaiting_input" do
                 if get_in(run, ["snapshot", "pending_clarification_id"]) != id,
                   do: Store.halt(:clarification_not_open)

                 continuation = %{
                   "kind" => "human_answer",
                   "question_id" => id,
                   "questions" => clarification["questions"],
                   "answer" => answer
                 }

                 snapshot =
                   run["snapshot"]
                   |> Map.put("continuation", continuation)
                   |> Map.put("resume_remaining_ms", run["snapshot"]["execution_remaining_ms"])
                   |> Map.delete("pending_clarification_id")

                 Store.exec(
                   "UPDATE runs SET state='queued',generation=generation+1,sequence=0,snapshot=$2,lease_expires_at=now()+interval '90 seconds',updated_at=now() WHERE id=$1",
                   [run["id"], snapshot]
                 )
               end

               Store.one(
                 "UPDATE run_clarifications SET status='answered',answer=$2,answered_at=now() WHERE id=$1 RETURNING run_id",
                 [id, answer]
               )
             end) do
        Phoenix.PubSub.broadcast(
          DevOrchestrator.PubSub,
          "run:" <> row["run_id"],
          {:run_updated, row["run_id"]}
        )

        :ok
      else
        false -> {:error, :forbidden}
        error -> error
      end

    result
  end

  def answer_clarification(_, _, _), do: {:error, :invalid_clarification_answer}

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
             is_binary(attrs["prompt"]) and byte_size(attrs["prompt"]) in 1..32_000 and
             Map.get(attrs, "mode", "implement") in ["implement", "investigate"] do
      source = attrs["source_key"] || "manual:" <> Store.id()

      {:ok,
       Store.one(
         "INSERT INTO runs(id,organization_id,project_id,source_key,title,prompt,issue_url,mode) VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(project_id,source_key) DO UPDATE SET source_key=excluded.source_key RETURNING *",
         [
           Store.id(),
           scope.organization_id,
           project_id,
           source,
           attrs["title"],
           attrs["prompt"],
           attrs["issue_url"],
           Map.get(attrs, "mode", "implement")
         ]
       )}
    else
      false -> {:error, :invalid_task}
      error -> error
    end
  end

  def claim(executor) do
    result =
      Store.transaction(fn ->
        live_executor!(executor)
        expire_leases()

        project =
          Store.one(
            """
              SELECT p.* FROM projects p JOIN executor_bindings b ON b.project_id=p.id AND b.organization_id=p.organization_id
              WHERE b.executor_id=$1 AND b.organization_id=$2
              AND EXISTS(SELECT 1 FROM runs r WHERE r.project_id=p.id AND r.state='queued' AND (r.lease_expires_at IS NULL OR r.lease_expires_at<=now()) AND (r.executor_id IS NULL OR r.executor_id=$1) AND ($3 OR (r.lifecycle=1 AND r.mode='implement' AND COALESCE(r.snapshot->>'workflow_version','1')='1' AND r.snapshot->'continuation' IS NULL AND COALESCE(r.snapshot->>'task_branch','task/'||r.id)='task/'||r.id)))
              AND (SELECT count(*) FROM runs r WHERE r.project_id=p.id AND r.state IN ('leased','running','waiting_for_executor'))<p.concurrency
              ORDER BY p.created_at FOR UPDATE OF p SKIP LOCKED LIMIT 1
            """,
            [executor["id"], executor["organization_id"], workflow_capable?(executor)]
          )

        if project do
          run =
            Store.one(
              "SELECT * FROM runs WHERE project_id=$1 AND organization_id=$2 AND state='queued' AND (lease_expires_at IS NULL OR lease_expires_at<=now()) AND (executor_id IS NULL OR executor_id=$4) AND ($3 OR (lifecycle=1 AND mode='implement' AND COALESCE(snapshot->>'workflow_version','1')='1' AND snapshot->'continuation' IS NULL AND COALESCE(snapshot->>'task_branch','task/'||id)='task/'||id)) ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1",
              [
                project["id"],
                executor["organization_id"],
                workflow_capable?(executor),
                executor["id"]
              ]
            )

          if run do
            snapshot = attempt_snapshot(project, run, executor)

            leased =
              Store.one(
                "UPDATE runs SET executor_id=$2,state='leased',generation=generation+1,sequence=0,snapshot=$3,lease_expires_at=now()+interval '90 seconds',updated_at=now() WHERE id=$1 RETURNING *",
                [run["id"], executor["id"], snapshot]
              )

            {:claimed, lease_payload(leased), queue_wait_ms(run["created_at"])}
          end
        end
      end)

    case result do
      {:ok, {:claimed, lease, wait_ms}} ->
        :telemetry.execute(
          [:dev_orchestrator, :runs, :lease],
          %{count: 1, queue_wait_ms: wait_ms},
          %{outcome: "claimed"}
        )

        {:ok, lease}

      {:ok, nil} ->
        :telemetry.execute([:dev_orchestrator, :runs, :lease], %{count: 1}, %{outcome: "empty"})
        {:ok, nil}

      {:error, _} = error ->
        :telemetry.execute([:dev_orchestrator, :runs, :lease], %{count: 1}, %{outcome: "rejected"})

        error
    end
  end

  defp queue_wait_ms(%DateTime{} = created_at),
    do: max(DateTime.diff(DateTime.utc_now(), created_at, :millisecond), 0)

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
    allowed = fn ->
      run = leased_run!(executor, lease)

      if purpose == :publish and get_in(run, ["snapshot", "mode"]) == "investigate",
        do: Store.halt(:invalid_purpose)

      if purpose == :publish and get_in(run, ["snapshot", "review_policy", "version"]) == 1 and
           get_in(executor, ["capabilities", "review_version"]) != 1,
         do: Store.halt(:connector_upgrade_required)

      github_token_access!(executor, lease)
    end

    with {:ok, access} <- Store.transaction(allowed),
         {:ok, token} <-
           GitHub.installation_token(access.installation_id, access.repository, purpose),
         {:ok, _} <-
           Store.transaction(fn ->
             allowed.()
             github_token_access!(executor, lease, access)
           end) do
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

  def asset(executor, lease, asset_id),
    do: DevOrchestrator.Runs.Assets.fetch(executor, lease, asset_id)

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
        """
        SELECT i.installation_id
        FROM github_app_installations i
        JOIN connection_grants g
          ON g.organization_id=i.organization_id AND g.project_id=i.project_id
        JOIN connections c
          ON c.organization_id=g.organization_id AND c.id=g.connection_id
        WHERE i.organization_id=$1 AND i.project_id=$2 AND i.repository=$3
          AND c.provider='github' AND c.revoked_at IS NULL
          AND c.external_id=i.installation_id::text
        ORDER BY c.created_at DESC LIMIT 1
        """,
        [executor["organization_id"], run["project_id"], repository]
      ) || Store.halt(:github_installation_required)

    %{repository: repository, installation_id: installation["installation_id"]}
  end

  def append_event(executor, lease, %{"sequence" => sequence, "kind" => kind} = event)
      when is_integer(sequence) and sequence > 0 and
             kind in ~w(started progress activity failure blocked candidate no_changes report) do
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

          previous_text =
            if kind == "activity" do
              case Store.one(
                     "SELECT data->'event'->>'text' AS text FROM run_events WHERE run_id=$1 AND lifecycle=$2 AND generation=$3 AND kind='activity' AND data->'event'->>'kind'='message_delta' ORDER BY sequence DESC LIMIT 1",
                     [run["id"], run["lifecycle"], run["generation"]]
                   ) do
                %{"text" => text} when is_binary(text) -> text
                _ -> ""
              end
            else
              ""
            end

          data =
            case DevOrchestrator.Runs.Event.sanitize(
                   run,
                   kind,
                   Map.get(event, "data", %{}),
                   previous_text
                 ) do
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

          if kind == "candidate",
            do: {:verify_candidate, run, data},
            else: transition(run, kind, data)
        end
      end)
      |> finalize_candidate_event()

    :telemetry.execute(
      [:dev_orchestrator, :runs, :event],
      %{count: 1},
      %{kind: kind, outcome: event_outcome(result)}
    )

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

  defp finalize_candidate_event({:ok, {:verify_candidate, run, data}}) do
    verification = DevOrchestrator.Delivery.Verification.verify(run, data)

    Store.transaction(fn ->
      current =
        Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
          run["id"],
          run["organization_id"]
        ]) || Store.halt(:stale_lease)

      if current["lifecycle"] != run["lifecycle"] or
           current["generation"] != run["generation"] or
           current["sequence"] != run["sequence"] + 1 or
           current["executor_id"] != run["executor_id"] or
           current["state"] not in ~w(leased running),
         do: Store.halt(:stale_lease)

      apply_candidate_verification(current, data, verification)
    end)
  end

  defp finalize_candidate_event(result), do: result

  defp event_outcome({:ok, :duplicate}), do: "duplicate"
  defp event_outcome({:ok, _}), do: "accepted"
  defp event_outcome(_), do: "rejected"

  def reconcile(executor, lease, journal) do
    Store.transaction(fn ->
      live_executor!(executor)

      run =
        Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
          lease["id"],
          executor["organization_id"]
        ]) || Store.halt(:stale_lease)

      binding =
        Store.one(
          "SELECT project_id FROM executor_bindings WHERE executor_id=$1 AND project_id=$2 AND organization_id=$3",
          [executor["id"], run["project_id"], executor["organization_id"]]
        )

      if is_nil(binding), do: Store.halt(:unauthorized)

      superseded? =
        run["executor_id"] != executor["id"] or run["generation"] != lease["generation"] or
          run["lifecycle"] != lease["lifecycle"]

      cond do
        run["executor_id"] == executor["id"] and run["lifecycle"] == lease["lifecycle"] and
          run["generation"] == lease["generation"] + 1 and run["state"] == "queued" and
            get_in(run, ["snapshot", "continuation", "kind"]) == "human_answer" ->
          %{action: "pause", state: "queued"}

        superseded? ->
          %{action: "archive", state: run["state"], reason: "superseded"}

        run["state"] == "awaiting_input" ->
          %{action: "pause", state: "awaiting_input"}

        run["state"] in ~w(succeeded failed cancelled blocked queued) ->
          %{action: "acknowledge", state: run["state"]}

        journal["pending_event"] != nil ->
          Store.exec(
            "UPDATE runs SET state='running',lease_expires_at=now()+interval '90 seconds' WHERE id=$1",
            [run["id"]]
          )

          %{action: "replay", expires_in_ms: 90_000}

        resumable_thread_id?(journal["thread_id"]) or
            get_in(run, ["result", "outcome"]) == "verification_pending" ->
          Store.exec(
            "UPDATE runs SET state='running',lease_expires_at=now()+interval '90 seconds' WHERE id=$1",
            [run["id"]]
          )

          %{action: "resume", state: "running", expires_in_ms: 90_000}

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
             "UPDATE runs SET state='queued',lifecycle=lifecycle+1,generation=generation+1,failures='{}',result=NULL,snapshot=NULL,executor_id=NULL,lease_expires_at=NULL,sequence=0,repair_count=0,pr_observation=NULL WHERE id=$1 AND organization_id=$2 AND state IN ('blocked','failed','cancelled') RETURNING id",
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

  def expire_leases do
    Store.transaction(fn ->
      Store.rows(
        "SELECT r.* FROM runs r JOIN run_clarifications c ON c.id=r.snapshot->>'pending_clarification_id' WHERE r.state='awaiting_input' AND c.expires_at<=now() FOR UPDATE OF r SKIP LOCKED"
      )
      |> Enum.each(fn run ->
        finish(run, "cancelled", %{
          "summary" =>
            "The human response window expired. Preserved work can be reviewed before starting a fresh attempt.",
          "category" => "missing_context"
        })
      end)

      Store.rows(
        "SELECT * FROM runs WHERE state IN ('queued','leased','running','waiting_for_executor') AND (snapshot->>'execution_deadline_at_ms')::bigint <= $1 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 100",
        [System.system_time(:millisecond)]
      )
      |> Enum.each(fn run ->
        result =
          Map.merge(run["result"] || %{}, %{
            "summary" =>
              "Execution stopped after its twenty-minute budget. Existing files and pull requests are preserved.",
            "category" => "execution_timeout"
          })

        finish(run, "cancelled", result)
      end)

      Store.exec(
        "UPDATE runs SET state='waiting_for_executor',updated_at=now() WHERE state IN ('running','leased') AND lease_expires_at<=now()"
      )
    end)
  end

  def executor_revoked(executor) do
    Store.rows(
      "SELECT * FROM runs WHERE organization_id=$1 AND executor_id=$2 AND state IN ('queued','leased','running','waiting_for_executor','awaiting_input') FOR UPDATE",
      [executor["organization_id"], executor["id"]]
    )
    |> Enum.each(fn run ->
      finish(run, "blocked", %{
        "summary" =>
          "The assigned executor was revoked. Existing workspace files are preserved; retry after pairing another executor.",
        "category" => "authentication_required"
      })
    end)

    :ok
  end

  defp live_executor!(executor) do
    Store.one(
      "SELECT id FROM executors WHERE id=$1 AND organization_id=$2 AND revoked_at IS NULL",
      [executor["id"], executor["organization_id"]]
    ) || Store.halt(:unauthorized)
  end

  defp workflow_capable?(executor),
    do: get_in(executor, ["capabilities", "workflow_version"]) == 2

  defp attempt_snapshot(project, run, executor) do
    if is_map(run["snapshot"]) do
      snapshot = Map.put_new(run["snapshot"], "task_branch", "task/#{run["id"]}")

      if is_integer(snapshot["resume_remaining_ms"]),
        do:
          snapshot
          |> Map.put(
            "execution_deadline_at_ms",
            System.system_time(:millisecond) + snapshot["resume_remaining_ms"]
          )
          |> Map.delete("resume_remaining_ms"),
        else: snapshot
    else
      Projects.snapshot(%{data: project})
      |> Map.put("workflow_version", if(workflow_capable?(executor), do: 2, else: 1))
      |> Map.put(
        "review_policy",
        if(
          get_in(executor, ["capabilities", "review_version"]) == 1 and
            (run["mode"] || "implement") == "implement",
          do: %{"version" => 1},
          else: nil
        )
      )
      |> Map.put("mode", run["mode"] || "implement")
      |> Map.put("execution_policy", DevOrchestrator.ExecutionPolicy.for_task(project, run))
      |> Map.put("execution_lifecycle", run["lifecycle"])
      |> Map.put(
        "execution_deadline_at_ms",
        FailureBudget.deadline(run, System.system_time(:millisecond))
      )
      |> Map.put("task_assets", lease_assets(run["source_context"]))
      |> Map.put("task_assets_skipped", get_in(run, ["source_context", "skipped_count"]) || 0)
      |> Map.put(
        "task_branch",
        if(workflow_capable?(executor),
          do: "task-attempts/#{run["id"]}/attempt-#{run["lifecycle"]}",
          else: "task/#{run["id"]}"
        )
      )
    end
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
          "Execution cancelled after three failed attempts. Files and commits are preserved.",
        "category" => data["category"],
        "validation" => data["validation"] || [],
        "detail" => data["summary"]
      })
    else
      resumable = data["resumable"] == true and get_in(run, ["snapshot", "workflow_version"]) == 2

      snapshot =
        if resumable,
          do: Map.put(run["snapshot"], "continuation", %{"kind" => "execution_retry"}),
          else: run["snapshot"]

      Store.exec(
        "UPDATE runs SET state='queued',executor_id=CASE WHEN $2 THEN executor_id ELSE NULL END,lease_expires_at=NULL,snapshot=$3 WHERE id=$1",
        [run["id"], resumable, snapshot]
      )

      %{state: "queued"}
    end
  end

  defp transition(run, "blocked", data),
    do:
      finish(
        run,
        "blocked",
        Map.put(
          data,
          "summary",
          data["summary"] ||
            "Executor blocked: " <>
              data["category"] <> ". Review local prerequisites and project configuration."
        )
      )

  defp transition(run, "no_changes", data) do
    finish(
      run,
      "succeeded",
      Map.merge(data, %{
        "summary" =>
          data["summary"] || "Completed without code changes; no pull request was created.",
        "outcome" => "completed_no_changes"
      })
    )
  end

  defp transition(run, "report", data) do
    finish(run, "succeeded", Map.merge(data, %{"outcome" => "investigation_complete"}))
  end

  defp transition(run, _, _) do
    Store.exec("UPDATE runs SET state='running' WHERE id=$1", [run["id"]])
    %{state: "running"}
  end

  defp apply_candidate_verification(run, data, verification) do
    case verification do
      {:ok, result} ->
        finish(run, "succeeded", result)

      {:error, reason} ->
        if DevOrchestrator.Delivery.Verification.retryable?(reason) do
          result = Map.put(data, "outcome", "verification_pending")
          Store.exec("UPDATE runs SET state='running',result=$2 WHERE id=$1", [run["id"], result])
          %{state: "running", verification: "pending"}
        else
          finish(
            run,
            "blocked",
            Map.merge(data, %{
              "category" => "publication_failed",
              "summary" =>
                "Pull request verification failed (#{reason}). Review the existing PR and GitHub connection before retrying; implementation was not restarted."
            })
          )
        end
    end
  end

  defp resumable_thread_id?(thread_id) when is_binary(thread_id) do
    byte_size(thread_id) in 1..256 and not String.match?(thread_id, ~r/[\x00-\x1f\x7f]/)
  end

  defp resumable_thread_id?(_), do: false

  defp clarification_response(row),
    do: %{id: row["id"], status: row["status"], answer: row["answer"]}

  defp broadcast_clarification(run_id, {:ok, _}) do
    Phoenix.PubSub.broadcast(
      DevOrchestrator.PubSub,
      "run:" <> run_id,
      {:run_updated, run_id}
    )
  end

  defp broadcast_clarification(_, _), do: :ok

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

  defp lease_assets(source_context) when is_map(source_context) do
    source_context
    |> Map.get("assets", [])
    |> Enum.filter(fn asset ->
      is_map(asset) and is_binary(asset["id"]) and is_binary(asset["filename_hint"])
    end)
    |> Enum.map(&Map.take(&1, ["id", "filename_hint"]))
  end

  defp lease_assets(_), do: []
end
