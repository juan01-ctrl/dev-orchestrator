defmodule DevOrchestrator.Runs.SlackFollowups do
  @moduledoc false
  alias DevOrchestrator.{Store, Connections}
  alias DevOrchestrator.Connections.GitHub
  alias DevOrchestrator.Runs.PRObserver

  def target(project, event) do
    Store.one(
      "SELECT t.*,r.result->>'commit' AS commit FROM slack_run_threads t JOIN runs r ON r.id=t.run_id AND r.organization_id=t.organization_id AND r.project_id=t.project_id WHERE t.organization_id=$1 AND t.project_id=$2 AND t.workspace_id=$3 AND t.channel_id=$4 AND t.thread_ts=$5 FOR UPDATE OF r",
      [
        project["organization_id"],
        project["id"],
        event["workspace_id"],
        event["channel_id"],
        event["thread_ts"]
      ]
    )
  end

  def eligible(nil, _), do: {:error, :pr_unavailable}

  def eligible(run, row) do
    cond do
      run["lifecycle"] != row["target_lifecycle"] or
          get_in(run, ["result", "commit"]) != row["target_commit"] ->
        {:error, :pr_changed}

      run["state"] != "succeeded" ->
        {:error, :pr_busy}

      run["mode"] != "implement" or get_in(run, ["snapshot", "workflow_version"]) != 2 ->
        {:error, :connector_upgrade_required}

      not is_binary(get_in(run, ["result", "pr_url"])) ->
        {:error, :pr_unavailable}

      run["current_repository"] != get_in(run, ["snapshot", "repository"]) ->
        {:error, :pr_changed}

      run["executor_available"] != true ->
        {:error, :executor_unavailable}

      not recent?(run["updated_at"]) ->
        {:error, :context_expired}

      true ->
        :ok
    end
  end

  def context(row) do
    run = load_run(row, false)

    with :ok <- eligible(run, row),
         :ok <- slack_access(row),
         :ok <- verify_pr(run) do
      {:ok, run}
    end
  end

  def queue(row) do
    # Never hold a run/draft lock during provider calls.
    with {:ok, _} <- context(row) do
      Store.transaction(fn ->
        # Match revocation's executor -> run lock order. A concurrent revocation
        # must either precede this queue or observe and block the queued run.
        Store.one(
          "SELECT e.id FROM executors e JOIN runs r ON r.executor_id=e.id AND r.organization_id=e.organization_id WHERE r.id=$1 AND r.organization_id=$2 AND r.project_id=$3 AND e.revoked_at IS NULL FOR UPDATE OF e",
          [row["target_run_id"], row["organization_id"], row["project_id"]]
        ) || Store.halt(:executor_unavailable)

        run = load_run(row, true)

        with :ok <- eligible(run, row), :ok <- slack_access(row) do
          draft =
            Store.one(
              "SELECT * FROM slack_task_drafts WHERE id=$1 AND organization_id=$2 FOR UPDATE",
              [row["id"], row["organization_id"]]
            )

          cond do
            is_nil(draft) ->
              Store.halt(:state_changed)

            draft["state"] == "created" ->
              :already_queued

            draft["state"] != "creating" or draft["revision"] != row["revision"] ->
              Store.halt(:state_changed)

            true ->
              input = %{
                "kind" => "slack_followup",
                "draft_id" => draft["id"],
                "revision" => draft["revision"],
                "request" => draft["task_draft"]
              }

              snapshot =
                run["snapshot"]
                |> Map.put("continuation", input)
                |> Map.put("resume_remaining_ms", 1_200_000)
                |> Map.put("resume_head", draft["target_commit"])
                |> Map.put(
                  "resume_candidate",
                  Map.take(run["result"], ~w(repository branch base_branch commit pr_url))
                )
                |> Map.delete("execution_deadline_at_ms")

              Store.exec(
                "UPDATE runs SET state='queued',generation=generation+1,sequence=0,followup_count=followup_count+1,snapshot=$3,failures='{}',lease_expires_at=NULL,updated_at=now() WHERE id=$1 AND organization_id=$2",
                [run["id"], run["organization_id"], snapshot]
              )

              Store.exec(
                "UPDATE slack_task_drafts SET state='created',claimed_at=NULL,error_category=NULL,updated_at=now() WHERE id=$1",
                [draft["id"]]
              )

              :queued
          end
        else
          {:error, reason} -> Store.halt(reason)
        end
      end)
    end
  end

  defp load_run(row, lock?) do
    sql =
      "SELECT r.*,p.repository AS current_repository,EXISTS(SELECT 1 FROM executors e JOIN executor_bindings b ON b.executor_id=e.id AND b.organization_id=e.organization_id WHERE e.id=r.executor_id AND e.organization_id=r.organization_id AND e.revoked_at IS NULL AND b.project_id=r.project_id) AS executor_available FROM runs r JOIN projects p ON p.id=r.project_id AND p.organization_id=r.organization_id WHERE r.id=$1 AND r.organization_id=$2 AND r.project_id=$3"

    Store.one(sql <> if(lock?, do: " FOR UPDATE OF r", else: ""), [
      row["target_run_id"],
      row["organization_id"],
      row["project_id"]
    ])
  end

  defp slack_access(row) do
    connection = Connections.for_project(row["organization_id"], row["project_id"], "slack")

    project =
      Store.one(
        "SELECT slack_workspace_id,slack_channel FROM projects WHERE id=$1 AND organization_id=$2",
        [row["project_id"], row["organization_id"]]
      )

    if connection && project && connection["id"] == row["slack_connection_id"] &&
         connection["external_id"] == project["slack_workspace_id"] &&
         row["channel_id"] == project["slack_channel"],
       do: :ok,
       else: {:error, :provider_authentication}
  end

  defp verify_pr(run) do
    repo = run["snapshot"]["repository"]
    url = run["result"]["pr_url"]

    with true <-
           is_binary(url) and
             Regex.match?(~r{\Ahttps://github\.com/#{Regex.escape(repo)}/pull/[0-9]+\z}, url),
         connection when is_map(connection) <-
           Connections.for_project(run["organization_id"], run["project_id"], "github"),
         {:ok, token} <- Connections.credential(connection),
         {:ok, pr} <-
           GitHub.api(:get, "/repos/#{repo}/pulls/#{List.last(String.split(url, "/"))}", token) do
      case PRObserver.identity(pr, run, run["result"]["commit"]) do
        :ok -> :ok
        {:ignore, "closed"} -> {:error, :pr_closed}
        _ -> {:error, :pr_changed}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :pr_unavailable}
    end
  end

  defp recent?(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at) < 7 * 86_400
  defp recent?(_), do: false
end
