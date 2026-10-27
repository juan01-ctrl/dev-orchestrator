defmodule DevOrchestrator.LinearReviewContinuationTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Store, Runs.Lifecycle}

  setup do
    scope = owner("review-continuation@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "Eval", "repository" => "acme/eval"})

    {:ok, project} =
      Projects.update_project(scope, project.id, %{
        "linear_team" => "team",
        "linear_project" => "project",
        "review_state" => "In Review"
      })

    issue = %{
      "id" => "issue",
      "identifier" => "EVAL-1",
      "title" => "Original task",
      "description" => "Create marker",
      "team" => %{"id" => "team"},
      "project" => %{"id" => "project"},
      "state" => %{"name" => "Todo"}
    }

    {:ok, %{run_id: id}} = Lifecycle.apply_issue(project.data, issue)
    head = String.duplicate("a", 40)
    result = %{"commit" => head, "pr_url" => "https://github.com/acme/eval/pull/1"}

    snapshot = %{
      "workflow_version" => 2,
      "continuation" => %{"kind" => "slack_followup"},
      "resume_head" => head,
      "resume_candidate" => result
    }

    Store.exec("UPDATE runs SET state='queued',snapshot=$2,result=$3 WHERE id=$1", [
      id,
      snapshot,
      result
    ])

    %{
      scope: scope,
      project: project.data,
      issue: issue,
      run_id: id,
      snapshot: snapshot,
      result: result
    }
  end

  test "review-state reconciliation preserves approved PR continuations without creating another task",
       ctx do
    for kind <- ["slack_followup", "pr_feedback"] do
      snapshot = put_in(ctx.snapshot, ["continuation", "kind"], kind)
      Store.exec("UPDATE runs SET snapshot=$2 WHERE id=$1", [ctx.run_id, snapshot])
      review = put_in(ctx.issue, ["state", "name"], "In Review")
      assert {:ok, %{result: :unchanged}} = Lifecycle.apply_issue(ctx.project, review)
      run = Store.one("SELECT * FROM runs WHERE id=$1", [ctx.run_id])
      assert run["state"] == "queued"
      assert run["result"] == ctx.result
      assert Store.one("SELECT count(*) AS n FROM runs")["n"] == 1
      assert Store.one("SELECT count(*) AS n FROM outbox")["n"] == 0
    end
  end

  test "review continuations still cancel for removed, cancelled or differently scoped Linear issues",
       ctx do
    for issue <- [
          put_in(ctx.issue, ["state", "name"], "Cancelled"),
          ctx.issue |> put_in(["state", "name"], "In Review") |> put_in(["team", "id"], "other"),
          ctx.issue
          |> put_in(["state", "name"], "In Review")
          |> put_in(["project", "id"], "other")
        ] do
      Store.exec("UPDATE runs SET state='queued',result=$2 WHERE id=$1", [ctx.run_id, ctx.result])
      assert {:ok, %{result: :cancelled}} = Lifecycle.apply_issue(ctx.project, issue)
    end

    Store.exec("UPDATE runs SET state='queued',result=$2 WHERE id=$1", [ctx.run_id, ctx.result])
    assert {:ok, %{result: :cancelled}} = Lifecycle.remove_issue(ctx.project, "issue")
  end

  test "ordinary or unverified work does not bypass inactive Linear state cancellation", ctx do
    for snapshot <- [
          Map.delete(ctx.snapshot, "continuation"),
          Map.delete(ctx.snapshot, "resume_candidate"),
          put_in(ctx.snapshot, ["resume_head"], "different-head")
        ] do
      Store.exec("UPDATE runs SET state='queued',snapshot=$2,result=$3 WHERE id=$1", [
        ctx.run_id,
        snapshot,
        ctx.result
      ])

      assert {:ok, %{result: :cancelled}} =
               Lifecycle.apply_issue(
                 ctx.project,
                 put_in(ctx.issue, ["state", "name"], "In Review")
               )
    end
  end

  test "approval and denial preserve an existing PR followup through reconciliation", ctx do
    alias DevOrchestrator.{Executors, Runs}
    {:ok, code} = Executors.create_enrollment(ctx.scope)
    {:ok, %{token: token}} = Executors.enroll(code, %{"name" => "Runner"})
    {:ok, executor} = Executors.authenticate(token)
    :ok = Executors.bind(ctx.scope, executor["id"], ctx.project["id"])

    for choice <- ["Approve", "Deny"] do
      snapshot =
        ctx.snapshot
        |> Map.put("execution_deadline_at_ms", System.system_time(:millisecond) + 1_200_000)

      Store.exec(
        "UPDATE runs SET state='running',generation=1,executor_id=$2,lease_expires_at=now()+interval '90 seconds',snapshot=$3,result=$4 WHERE id=$1",
        [ctx.run_id, executor["id"], snapshot, ctx.result]
      )

      lease = %{"id" => ctx.run_id, "lifecycle" => 1, "generation" => 1}

      questions = [
        %{
          "id" => "scope",
          "header" => "Scope",
          "question" => "Approve the proposed material scope change?",
          "options" => [
            %{"label" => "Approve", "description" => "Expand scope"},
            %{"label" => "Deny", "description" => "Keep original scope"}
          ]
        }
      ]

      assert {:ok, %{id: id, status: "awaiting_input"}} =
               Runs.request_clarification(executor, lease, %{
                 "questions" => questions,
                 "turnId" => choice,
                 "durable" => true
               })

      assert :ok = Runs.answer_clarification(ctx.scope, id, %{"answers" => %{"scope" => choice}})

      assert {:ok, %{result: :unchanged}} =
               Lifecycle.apply_issue(
                 ctx.project,
                 put_in(ctx.issue, ["state", "name"], "In Review")
               )

      run = Store.one("SELECT * FROM runs WHERE id=$1", [ctx.run_id])
      assert run["state"] == "queued"
      assert get_in(run, ["snapshot", "continuation", "origin", "kind"]) == "slack_followup"

      assert get_in(run, ["snapshot", "continuation", "answer", "answers", "scope", "answers"]) ==
               [choice]
    end
  end
end
