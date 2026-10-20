defmodule DevOrchestrator.RunsTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Executors, Runs, Store}

  setup do
    scope = owner("runs@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {:ok, code} = Executors.create_enrollment(scope)
    {:ok, %{token: token}} = Executors.enroll(code, %{"name" => "Runner"})
    {:ok, executor} = Executors.authenticate(token)
    :ok = Executors.bind(scope, executor["id"], project.id)
    %{scope: scope, project: project, executor: executor}
  end

  test "claim snapshots rules and respects project concurrency", ctx do
    {:ok, run} =
      Runs.create(ctx.scope, ctx.project.id, %{
        "title" => "First",
        "prompt" => "Create a test file"
      })

    {:ok, _} =
      Runs.create(ctx.scope, ctx.project.id, %{
        "title" => "Second",
        "prompt" => "Create another file"
      })

    assert {:ok, lease} = Runs.claim(ctx.executor)
    assert lease["id"] == run["id"]
    assert lease["snapshot"]["base_branch"] == "main"
    {:ok, _} = Projects.update_project(ctx.scope, ctx.project.id, %{"base_branch" => "develop"})
    assert {:ok, nil} = Runs.claim(ctx.executor)
    assert lease["snapshot"]["base_branch"] == "main"
  end

  test "active leases keep their instructions snapshot while later runs get updates", ctx do
    {:ok, _} =
      Projects.update_project(ctx.scope, ctx.project.id, %{
        "concurrency" => 2,
        "instructions" => "# First version\n"
      })

    {:ok, _} = Runs.create(ctx.scope, ctx.project.id, %{"title" => "First", "prompt" => "One"})
    assert {:ok, first_lease} = Runs.claim(ctx.executor)
    assert first_lease["snapshot"]["instructions"] == "# First version\n"

    {:ok, _} =
      Projects.update_project(ctx.scope, ctx.project.id, %{"instructions" => "# Second version\n"})

    {:ok, _} = Runs.create(ctx.scope, ctx.project.id, %{"title" => "Second", "prompt" => "Two"})
    assert {:ok, second_lease} = Runs.claim(ctx.executor)

    assert first_lease["snapshot"]["instructions"] == "# First version\n"
    assert second_lease["snapshot"]["instructions"] == "# Second version\n"
  end

  test "duplicate events are idempotent and stale generations cannot finalize", ctx do
    {:ok, _} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "First", "prompt" => "Create a file"})

    {:ok, lease} = Runs.claim(ctx.executor)
    event = %{"sequence" => 1, "kind" => "started", "data" => %{}}
    assert {:ok, _} = Runs.append_event(ctx.executor, lease, event)
    assert {:ok, :duplicate} = Runs.append_event(ctx.executor, lease, event)

    assert {:error, :stale_lease} =
             Runs.append_event(ctx.executor, Map.put(lease, "generation", 0), %{
               event
               | "sequence" => 2
             })

    Store.exec("UPDATE runs SET lease_expires_at=now()-interval '1 second' WHERE id=$1", [
      lease["id"]
    ])

    assert {:error, :stale_lease} = Runs.renew(ctx.executor, lease)
    assert {:ok, nil} = Runs.claim(ctx.executor)
  end
end
