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

  test "automatic retries share one deadline and expire with a single final report", ctx do
    {:ok, run} = Runs.create(ctx.scope, ctx.project.id, %{"title" => "Budget", "prompt" => "Run"})
    {:ok, first} = Runs.claim(ctx.executor)
    deadline = first["snapshot"]["execution_deadline_at_ms"]
    assert is_integer(deadline)

    assert {:ok, %{state: "queued"}} =
             Runs.append_event(ctx.executor, first, %{
               "sequence" => 1,
               "kind" => "failure",
               "data" => %{"category" => "execution_failed"}
             })

    {:ok, second} = Runs.claim(ctx.executor)
    assert second["snapshot"]["execution_deadline_at_ms"] == deadline

    expired =
      Map.put(
        second["snapshot"],
        "execution_deadline_at_ms",
        System.system_time(:millisecond) - 1
      )

    Store.exec("UPDATE runs SET snapshot=$2 WHERE id=$1", [run["id"], expired])
    Runs.expire_leases()
    Runs.expire_leases()

    assert {:ok, %{"state" => "cancelled", "result" => %{"category" => "execution_timeout"}}} =
             Runs.get(ctx.scope, run["id"])

    assert length(DevOrchestrator.Delivery.Outbox.list(ctx.scope, run["id"])) == 2
    assert :ok = Runs.retry(ctx.scope, run["id"])
    {:ok, restarted} = Runs.claim(ctx.executor)
    assert restarted["lifecycle"] == second["lifecycle"] + 1
    assert restarted["snapshot"]["execution_deadline_at_ms"] > System.system_time(:millisecond)
  end

  test "structured blocker details reach the final result and reports", ctx do
    {:ok, run} = Runs.create(ctx.scope, ctx.project.id, %{"title" => "Check", "prompt" => "Run"})
    {:ok, lease} = Runs.claim(ctx.executor)

    assert {:ok, %{state: "blocked"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 1,
               "kind" => "blocked",
               "data" => %{
                 "category" => "environment_setup_failed",
                 "summary" => "npm ci failed: registry unavailable",
                 "validation" => [%{"command" => "npm ci", "status" => "failed"}]
               }
             })

    assert {:ok, %{"result" => result}} = Runs.get(ctx.scope, run["id"])
    assert result["summary"] == "npm ci failed: registry unavailable"
    assert result["validation"] == [%{"command" => "npm ci", "status" => "failed"}]
  end

  test "verification cannot queue implementation again when GitHub is not connected", ctx do
    {:ok, run} = Runs.create(ctx.scope, ctx.project.id, %{"title" => "Verify", "prompt" => "Run"})
    {:ok, lease} = Runs.claim(ctx.executor)

    candidate = %{
      "repository" => "acme/app",
      "base_branch" => "main",
      "branch" => "task/" <> run["id"],
      "commit" => String.duplicate("a", 40),
      "pr_url" => "https://github.com/acme/app/pull/1"
    }

    assert {:ok, %{state: "blocked"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 1,
               "kind" => "candidate",
               "data" => candidate
             })

    assert {:ok, %{"result" => result}} = Runs.get(ctx.scope, run["id"])
    assert result["pr_url"] == candidate["pr_url"]
    assert {:ok, nil} = Runs.claim(ctx.executor)
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

  test "safe progress events are persisted in order while the task remains running", ctx do
    {:ok, run} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "Progress", "prompt" => "Edit a file"})

    {:ok, lease} = Runs.claim(ctx.executor)

    assert {:ok, %{state: "running"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 1,
               "kind" => "started",
               "data" => %{}
             })

    assert {:ok, %{state: "running"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 2,
               "kind" => "progress",
               "data" => %{"stage" => "editing", "message" => "private command output"}
             })

    assert [
             %{"kind" => "started", "data" => %{}},
             %{"kind" => "progress", "data" => %{"stage" => "editing"}}
           ] = Runs.events(ctx.scope, run["id"])
  end

  test "reconciles an active Codex thread without converting it into a blocker", ctx do
    {:ok, _} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "Resume", "prompt" => "Continue"})

    {:ok, lease} = Runs.claim(ctx.executor)

    assert {:ok, %{state: "running"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 1,
               "kind" => "started",
               "data" => %{}
             })

    assert {:ok, %{action: "resume", state: "running", expires_in_ms: 90_000}} =
             Runs.reconcile(ctx.executor, lease, %{
               "pending_event" => nil,
               "thread_id" => "codex-thread-123",
               "workspace" => "/connector/runtime/workspaces/run",
               "baseline" => String.duplicate("a", 40)
             })
  end

  test "does not resume an active run without a valid Codex thread", ctx do
    {:ok, _} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "No thread", "prompt" => "Continue"})

    {:ok, lease} = Runs.claim(ctx.executor)

    assert {:ok, %{state: "running"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 1,
               "kind" => "started",
               "data" => %{}
             })

    assert {:ok, %{action: "acknowledge", state: "blocked"}} =
             Runs.reconcile(ctx.executor, lease, %{"pending_event" => nil, "thread_id" => ""})
  end

  test "superseded executor journals receive an explicit archive acknowledgement", ctx do
    {:ok, run} =
      Runs.create(ctx.scope, ctx.project.id, %{
        "title" => "Old generation",
        "prompt" => "Continue"
      })

    {:ok, old_lease} = Runs.claim(ctx.executor)
    assert :ok = Runs.cancel(ctx.scope, run["id"])
    assert :ok = Runs.retry(ctx.scope, run["id"])

    assert {:ok, %{action: "archive", reason: "superseded", state: "queued"}} =
             Runs.reconcile(ctx.executor, old_lease, %{"pending_event" => nil})
  end

  test "persists one clarification, notifies delivery, and returns the owner's answer", ctx do
    {:ok, run} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "Choose stack", "prompt" => "Build it"})

    {:ok, lease} = Runs.claim(ctx.executor)

    assert {:ok, %{state: "running"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 1,
               "kind" => "started",
               "data" => %{}
             })

    request = %{
      "turnId" => "turn-1",
      "questions" => [
        %{"id" => "framework", "header" => "Framework", "question" => "Which framework?"}
      ]
    }

    assert {:ok, %{id: clarification_id, status: "open"}} =
             Runs.request_clarification(ctx.executor, lease, request)

    assert {:ok, %{id: ^clarification_id, status: "open"}} =
             Runs.request_clarification(ctx.executor, lease, request)

    assert [%{"kind" => delivery_kind, "state" => "pending"}] =
             DevOrchestrator.Delivery.Outbox.list(ctx.scope, run["id"])

    assert delivery_kind == "slack:clarification:" <> clarification_id

    assert :ok =
             Runs.answer_clarification(ctx.scope, clarification_id, %{
               "answers" => %{"framework" => "Phoenix"}
             })

    assert {:ok,
            %{
              status: "answered",
              answer: %{"answers" => %{"framework" => %{"answers" => ["Phoenix"]}}}
            }} = Runs.clarification_status(ctx.executor, lease, clarification_id)
  end

  test "rejects secret clarification requests", ctx do
    {:ok, _run} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "Choose stack", "prompt" => "Build it"})

    {:ok, lease} = Runs.claim(ctx.executor)

    assert {:ok, %{state: "running"}} =
             Runs.append_event(ctx.executor, lease, %{
               "sequence" => 1,
               "kind" => "started",
               "data" => %{}
             })

    assert {:error, :invalid_clarification} =
             Runs.request_clarification(ctx.executor, lease, %{
               "questions" => [
                 %{"id" => "secret", "question" => "What is the token?", "isSecret" => true}
               ]
             })
  end

  test "issues a scoped GitHub credential only for the executor's live project lease", ctx do
    {:ok, _} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "Publish", "prompt" => "Make change"})

    {:ok, lease} = Runs.claim(ctx.executor)

    Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [ctx.scope.organization_id, ctx.project.id, "acme/app", 42, "acme"]
    )

    connection_id = Store.id()

    Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,'github','GitHub',decode('00','hex'),'42')",
      [connection_id, ctx.scope.organization_id]
    )

    Store.exec(
      "INSERT INTO connection_grants(organization_id,project_id,connection_id) VALUES($1,$2,$3)",
      [ctx.scope.organization_id, ctx.project.id, connection_id]
    )

    old_github = Application.get_env(:dev_orchestrator, :github)
    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    key_path =
      Path.join(System.tmp_dir!(), "runs-github-#{System.unique_integer([:positive])}.pem")

    File.write!(key_path, pem)

    Application.put_env(:dev_orchestrator, :github,
      app_id: "12345",
      app_slug: "test-app",
      private_key_path: key_path
    )

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:url] == "https://api.github.com/app/installations/42/access_tokens"

      assert opts[:json] == %{
               repositories: ["acme/app"],
               permissions: %{contents: "read"}
             }

      {:ok,
       %{
         status: 201,
         body: %{"token" => "temporary-secret-token", "expires_at" => "2099-01-01T00:00:00Z"}
       }}
    end)

    on_exit(fn ->
      if old_github,
        do: Application.put_env(:dev_orchestrator, :github, old_github),
        else: Application.delete_env(:dev_orchestrator, :github)

      if old_transport,
        do: Application.put_env(:dev_orchestrator, :provider_transport, old_transport),
        else: Application.delete_env(:dev_orchestrator, :provider_transport)

      File.rm(key_path)
    end)

    assert {:ok,
            %{
              token: "temporary-secret-token",
              author_name: "test-app[bot]",
              author_email: "12345+test-app[bot]@users.noreply.github.com"
            }} = Runs.github_token(ctx.executor, lease, :checkout)

    assert {:ok, run} = Runs.get(ctx.scope, lease["id"])
    refute Jason.encode!(run) =~ "temporary-secret-token"
  end

  test "does not issue GitHub credentials for a provisional installation without user authorization",
       ctx do
    {:ok, _} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "Publish", "prompt" => "Make change"})

    {:ok, lease} = Runs.claim(ctx.executor)

    Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [ctx.scope.organization_id, ctx.project.id, "acme/app", 42, "acme"]
    )

    assert {:error, :github_installation_required} =
             Runs.github_token(ctx.executor, lease, :checkout)
  end

  test "does not issue credentials for an expired or stale lease", ctx do
    {:ok, _} = Runs.create(ctx.scope, ctx.project.id, %{"title" => "Expired", "prompt" => "Run"})
    {:ok, lease} = Runs.claim(ctx.executor)

    Store.exec("UPDATE runs SET lease_expires_at=now()-interval '1 second' WHERE id=$1", [
      lease["id"]
    ])

    assert {:error, :stale_lease} = Runs.github_token(ctx.executor, lease, :checkout)

    Store.exec("UPDATE runs SET lease_expires_at=now()+interval '90 seconds' WHERE id=$1", [
      lease["id"]
    ])

    assert {:error, :stale_lease} =
             Runs.github_token(ctx.executor, Map.put(lease, "generation", -1), :checkout)
  end

  test "does not issue credentials when the project repository changes after leasing", ctx do
    {:ok, _} =
      Runs.create(ctx.scope, ctx.project.id, %{"title" => "Changed repo", "prompt" => "Run"})

    {:ok, lease} = Runs.claim(ctx.executor)
    {:ok, _} = Projects.update_project(ctx.scope, ctx.project.id, %{"repository" => "acme/other"})

    assert {:error, :repository_changed} = Runs.github_token(ctx.executor, lease, :checkout)
  end

  test "does not issue credentials without an installation, binding, or live executor", ctx do
    {:ok, _} = Runs.create(ctx.scope, ctx.project.id, %{"title" => "Unbound", "prompt" => "Run"})
    {:ok, lease} = Runs.claim(ctx.executor)

    assert {:error, :github_installation_required} =
             Runs.github_token(ctx.executor, lease, :checkout)

    Store.exec("DELETE FROM executor_bindings WHERE executor_id=$1 AND project_id=$2", [
      ctx.executor["id"],
      ctx.project.id
    ])

    assert {:error, :unauthorized} = Runs.github_token(ctx.executor, lease, :checkout)

    Store.exec(
      "INSERT INTO executor_bindings(organization_id,executor_id,project_id) VALUES($1,$2,$3)",
      [ctx.scope.organization_id, ctx.executor["id"], ctx.project.id]
    )

    Store.exec("UPDATE executors SET revoked_at=now() WHERE id=$1", [ctx.executor["id"]])
    assert {:error, :unauthorized} = Runs.github_token(ctx.executor, lease, :checkout)
  end
end