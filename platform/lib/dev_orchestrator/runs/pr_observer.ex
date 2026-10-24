defmodule DevOrchestrator.Runs.PRObserver do
  alias DevOrchestrator.{Connections, Store}
  alias DevOrchestrator.Connections.GitHub
  alias DevOrchestrator.Runs.PRFeedback

  def tick do
    Store.rows(
      "SELECT r.* FROM runs r JOIN projects p ON p.id=r.project_id AND p.organization_id=r.organization_id WHERE p.pr_feedback_enabled=true AND r.state='succeeded' AND r.mode='implement' AND r.snapshot->>'workflow_version'='2' AND r.result->>'pr_url' IS NOT NULL AND r.updated_at>now()-interval '7 days' AND r.updated_at<now()-interval '90 seconds' ORDER BY COALESCE(r.pr_observation->>'observed_at','') LIMIT 5"
    )
    |> Enum.each(&observe/1)
  end

  def observe(run) do
    repository = run["snapshot"]["repository"]
    url = run["result"]["pr_url"]

    with true <-
           is_binary(url) and
             Regex.match?(
               ~r{\Ahttps://github\.com/#{Regex.escape(repository)}/pull/[0-9]+\z},
               url
             ),
         connection when is_map(connection) <-
           Connections.for_project(run["organization_id"], run["project_id"], "github"),
         {:ok, token} <- Connections.credential(connection),
         number = List.last(String.split(url, "/")),
         {:ok, pr} <- GitHub.api(:get, "/repos/#{repository}/pulls/#{number}", token),
         head = run["result"]["commit"],
         :ok <- identity(pr, run, head),
         {:ok, checks} <-
           GitHub.api(:get, "/repos/#{repository}/commits/#{head}/check-runs?per_page=100", token),
         true <-
           is_list(checks["check_runs"]) and
             (checks["total_count"] || 0) <= length(checks["check_runs"]),
         {:ok, reviews} <- pages(repository, number, token, "reviews", 1, []),
         {:ok, comments} <- pages(repository, number, token, "comments", 1, []) do
      case PRFeedback.classify(pr, checks["check_runs"], reviews, head, comments) do
        {:ok, feedback} -> queue_repair(run, feedback)
        {:ignore, status} -> save_status(run, status)
      end
    else
      {:ignore, status} -> save_status(run, status)
      _ -> save_status(run, "observation_unavailable")
    end
  rescue
    _ -> save_status(run, "observation_unavailable")
  end

  def identity(pr, run, head) do
    snapshot = run["snapshot"]

    cond do
      pr["state"] != "open" ->
        {:ignore, "closed"}

      get_in(pr, ["head", "sha"]) != head ->
        {:ignore, "head_changed"}

      get_in(pr, ["head", "ref"]) != snapshot["task_branch"] or
        get_in(pr, ["base", "ref"]) != snapshot["base_branch"] or
        get_in(pr, ["head", "repo", "full_name"]) != snapshot["repository"] or
          get_in(pr, ["base", "repo", "full_name"]) != snapshot["repository"] ->
        {:ignore, "identity_changed"}

      true ->
        :ok
    end
  end

  defp pages(_repo, _number, _token, _resource, page, _) when page > 5,
    do: {:error, :review_limit}

  defp pages(repo, number, token, resource, page, acc) do
    case GitHub.api(
           :get,
           "/repos/#{repo}/pulls/#{number}/#{resource}?per_page=100&page=#{page}",
           token
         ) do
      {:ok, rows} when is_list(rows) ->
        if length(rows) < 100,
          do: {:ok, acc ++ rows},
          else: pages(repo, number, token, resource, page + 1, acc ++ rows)

      _ ->
        {:error, :provider_unavailable}
    end
  end

  @doc false
  def queue_repair(run, feedback) do
    Store.transaction(fn ->
      current =
        Store.one(
          "SELECT r.* FROM runs r JOIN projects p ON p.id=r.project_id AND p.organization_id=r.organization_id WHERE r.id=$1 AND r.organization_id=$2 AND p.pr_feedback_enabled=true FOR UPDATE OF r",
          [run["id"], run["organization_id"]]
        )

      cond do
        is_nil(current) or current["state"] != "succeeded" or
            get_in(current, ["result", "commit"]) != feedback["head"] ->
          :stale

        current["repair_count"] >= 3 ->
          save_status(current, "repair_limit_reached")

        true ->
          receipt =
            Store.one(
              "INSERT INTO pr_feedback_receipts(organization_id,run_id,head,fingerprint) VALUES($1,$2,$3,$4) ON CONFLICT(run_id,head,fingerprint) DO NOTHING RETURNING run_id",
              [run["organization_id"], run["id"], feedback["head"], feedback["fingerprint"]]
            )

          if receipt do
            snapshot =
              current["snapshot"]
              |> Map.put("continuation", feedback)
              |> Map.put("resume_remaining_ms", 1_200_000)
              |> Map.put("resume_head", feedback["head"])
              |> Map.put(
                "resume_candidate",
                Map.take(current["result"], ~w(repository branch base_branch commit pr_url))
              )
              |> Map.delete("execution_deadline_at_ms")

            Store.exec(
              "UPDATE runs SET state='queued',generation=generation+1,sequence=0,repair_count=repair_count+1,snapshot=$3,pr_observation=$4,updated_at=now() WHERE id=$1 AND organization_id=$2",
              [run["id"], run["organization_id"], snapshot, observation("repair_queued")]
            )

            :queued
          else
            save_status(current, "already_processed")
          end
      end
    end)
  end

  defp observation(status),
    do: %{"status" => status, "observed_at" => DateTime.to_iso8601(DateTime.utc_now())}

  defp save_status(run, status),
    do:
      Store.exec(
        "UPDATE runs SET pr_observation=$3 WHERE id=$1 AND organization_id=$2 AND state='succeeded'",
        [run["id"], run["organization_id"], observation(status)]
      )
end
