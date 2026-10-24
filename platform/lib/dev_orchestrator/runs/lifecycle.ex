defmodule DevOrchestrator.Runs.Lifecycle do
  alias DevOrchestrator.Store

  @active_run_states ~w(queued leased running waiting_for_executor awaiting_input)

  def apply_issue(project, issue, source_context \\ %{}) do
    issue_id = issue["id"]
    state = get_in(issue, ["state", "name"])

    if is_binary(issue_id) and is_binary(state) do
      Store.transaction(fn ->
        eligible? = eligible?(project, issue)

        lifecycle =
          Store.one(
            "SELECT * FROM linear_issue_lifecycles WHERE project_id=$1 AND issue_id=$2 FOR UPDATE",
            [project["id"], issue_id]
          )

        if eligible? do
          activate(project, issue, lifecycle, source_context)
        else
          deactivate(project, issue, lifecycle)
        end
      end)
    else
      {:error, :invalid_issue}
    end
  end

  def eligible?(project, issue) do
    is_binary(project["linear_team"]) and project["linear_team"] == get_in(issue, ["team", "id"]) and
      (is_nil(project["linear_project"]) or
         project["linear_project"] == get_in(issue, ["project", "id"])) and
      get_in(issue, ["state", "name"]) in (project["active_states"] || ["Todo", "In Progress"])
  end

  def remove_issue(project, issue_id) when is_binary(issue_id) do
    Store.transaction(fn ->
      lifecycle =
        Store.one(
          "SELECT * FROM linear_issue_lifecycles WHERE project_id=$1 AND issue_id=$2 FOR UPDATE",
          [project["id"], issue_id]
        )

      deactivate(
        project,
        %{"id" => issue_id, "state" => %{"name" => "Removed"}},
        lifecycle
      )
    end)
  end

  defp activate(project, issue, nil, source_context) do
    create_activation(project, issue, 1, source_context)
  end

  defp activate(project, issue, %{"is_active" => true} = previous, source_context) do
    Store.exec(
      "UPDATE linear_issue_lifecycles SET issue_state=$3,updated_at=now() WHERE project_id=$1 AND issue_id=$2",
      [project["id"], issue["id"], get_in(issue, ["state", "name"])]
    )

    {title, prompt, private_context} = task_context(issue, source_context)

    Store.exec(
      "UPDATE runs SET title=$3,prompt=$4,issue_url=$5,source_context=$6,updated_at=now() WHERE id=$1 AND organization_id=$2 AND ((state='queued' AND executor_id IS NULL) OR state IN ('blocked','failed','cancelled'))",
      [
        previous["run_id"],
        project["organization_id"],
        title,
        prompt,
        issue["url"],
        private_context
      ]
    )

    %{result: :unchanged, activation: previous["activation"]}
  end

  defp activate(project, issue, previous, source_context) do
    create_activation(project, issue, previous["activation"] + 1, source_context)
  end

  defp create_activation(project, issue, activation, source_context) do
    {title, prompt, private_context} = task_context(issue, source_context)

    source_key = "linear:" <> issue["id"] <> ":" <> Integer.to_string(activation)

    run =
      Store.one(
        "INSERT INTO runs(id,organization_id,project_id,source_key,title,prompt,issue_url,source_context) VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(project_id,source_key) DO UPDATE SET source_key=excluded.source_key RETURNING *",
        [
          Store.id(),
          project["organization_id"],
          project["id"],
          source_key,
          title,
          prompt,
          issue["url"],
          private_context
        ]
      )

    Store.exec(
      "INSERT INTO linear_issue_lifecycles(project_id,issue_id,activation,is_active,issue_state,run_id,updated_at) VALUES($1,$2,$3,true,$4,$5,now()) ON CONFLICT(project_id,issue_id) DO UPDATE SET activation=EXCLUDED.activation,is_active=true,issue_state=EXCLUDED.issue_state,run_id=EXCLUDED.run_id,updated_at=now()",
      [project["id"], issue["id"], activation, get_in(issue, ["state", "name"]), run["id"]]
    )

    %{
      result: if(activation == 1, do: :created, else: :rework),
      run_id: run["id"],
      activation: activation
    }
  end

  defp task_context(issue, source_context) do
    title_text = DevOrchestrator.Intake.LinearAssets.sanitize_description(issue["title"] || "")

    description =
      DevOrchestrator.Intake.LinearAssets.sanitize_description(issue["description"] || "")

    prompt = String.slice(title_text <> "\n\n" <> description, 0, 8_000)

    title =
      String.slice(
        (issue["identifier"] || "Issue") <> " — " <> (title_text || "Development task"),
        0,
        240
      )

    extracted =
      DevOrchestrator.Intake.LinearAssets.extract(
        issue["description"] || "",
        get_in(issue, ["attachments", "nodes"]) || []
      )

    private_context = %{
      "linear_connection_id" => source_context["linear_connection_id"],
      "assets" => extracted.assets,
      "skipped_count" => extracted.skipped_count
    }

    {title, prompt, private_context}
  end

  defp deactivate(_project, _issue, nil), do: %{result: :unchanged, activation: 0}

  defp deactivate(project, issue, lifecycle) do
    Store.exec(
      "UPDATE linear_issue_lifecycles SET is_active=false,issue_state=$3,updated_at=now() WHERE project_id=$1 AND issue_id=$2",
      [project["id"], issue["id"], get_in(issue, ["state", "name"])]
    )

    run =
      Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
        lifecycle["run_id"],
        project["organization_id"]
      ])

    if run && run["state"] in @active_run_states do
      result = %{"summary" => "Cancelled because the Linear issue left an active workflow state."}

      cancelled =
        Store.one(
          "UPDATE runs SET state='cancelled',result=$2,lease_expires_at=NULL,updated_at=now() WHERE id=$1 RETURNING *",
          [run["id"], result]
        )

      DevOrchestrator.Delivery.Outbox.enqueue(cancelled, "cancelled", result)
      %{result: :cancelled, run_id: run["id"], activation: lifecycle["activation"]}
    else
      %{result: :unchanged, activation: lifecycle["activation"]}
    end
  end
end
