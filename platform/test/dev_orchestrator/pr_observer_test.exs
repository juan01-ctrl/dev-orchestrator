defmodule DevOrchestrator.PRObserverTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Runs, Store, Executors}
  alias DevOrchestrator.Runs.PRObserver
  alias DevOrchestrator.Delivery.Outbox

  test "current-head feedback queues once, preserves executor affinity and obeys the repair limit" do
    scope = owner("pr-observer@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {:ok, _} = Projects.update_project(scope, project.id, %{"pr_feedback_enabled" => true})
    {:ok, code} = Executors.create_enrollment(scope)
    {:ok, %{token: token}} = Executors.enroll(code, %{"name" => "Runner"})
    {:ok, executor} = Executors.authenticate(token)
    executor = Map.put(executor, "capabilities", %{"workflow_version" => 2})
    :ok = Executors.bind(scope, executor["id"], project.id)
    {:ok, run} = Runs.create(scope, project.id, %{"title" => "Fix", "prompt" => "Implement"})
    {:ok, lease} = Runs.claim(executor)
    head = String.duplicate("a", 40)
    result = %{"commit" => head, "pr_url" => "https://github.com/acme/app/pull/1"}

    Store.exec("UPDATE runs SET state='succeeded',result=$2,lease_expires_at=NULL WHERE id=$1", [
      run["id"],
      result
    ])

    current = Store.one("SELECT * FROM runs WHERE id=$1", [run["id"]])

    feedback = %{
      "kind" => "pr_feedback",
      "head" => head,
      "fingerprint" => "batch-1",
      "feedback" => [%{"kind" => "ci", "name" => "test", "detail" => "Failed"}]
    }

    assert {:ok, :stale} = PRObserver.queue_repair(current, %{feedback | "head" => "old"})
    assert {:ok, :queued} = PRObserver.queue_repair(current, feedback)
    assert {:ok, :stale} = PRObserver.queue_repair(current, feedback)
    queued = Store.one("SELECT * FROM runs WHERE id=$1", [run["id"]])
    assert queued["repair_count"] == 1
    assert queued["executor_id"] == executor["id"]
    assert queued["snapshot"]["task_branch"] == lease["snapshot"]["task_branch"]
    assert queued["snapshot"]["resume_head"] == head
    Outbox.enqueue(current, "succeeded", result)
    Outbox.enqueue(queued, "succeeded", result)
    assert length(Outbox.list(scope, run["id"])) == 4
    Store.exec("UPDATE runs SET state='succeeded' WHERE id=$1", [run["id"]])
    assert {:ok, _} = PRObserver.queue_repair(current, feedback)

    assert Store.one("SELECT repair_count FROM runs WHERE id=$1", [run["id"]])["repair_count"] ==
             1

    Store.exec("UPDATE runs SET repair_count=3 WHERE id=$1", [run["id"]])
    assert {:ok, _} = PRObserver.queue_repair(current, %{feedback | "fingerprint" => "batch-2"})

    assert Store.one("SELECT state,pr_observation FROM runs WHERE id=$1", [run["id"]])[
             "pr_observation"
           ]["status"] == "repair_limit_reached"
  end
end
