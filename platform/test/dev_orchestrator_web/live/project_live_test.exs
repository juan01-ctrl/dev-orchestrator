defmodule DevOrchestratorWeb.ProjectLiveTest do
  use DevOrchestrator.DataCase
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint DevOrchestratorWeb.Endpoint

  setup do
    old_github = Application.get_env(:dev_orchestrator, :github)

    on_exit(fn ->
      if old_github,
        do: Application.put_env(:dev_orchestrator, :github, old_github),
        else: Application.delete_env(:dev_orchestrator, :github)
    end)

    :ok
  end

  test "anonymous visitors are redirected away from project screens" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/app")
  end

  test "executor page provides copyable pairing and run commands" do
    scope = owner("executor-commands@example.test")
    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, view, _html} = live(conn, "/app/executors")

    view |> element("button[phx-click='pair']") |> render_click()

    pairing_html = render(view)
    assert pairing_html =~ "npx --yes dev-orchestrator-connector@0.2.0 pair"
    assert pairing_html =~ "aria-label=\"Copy pairing command\""

    {:ok, enrollment_code} = DevOrchestrator.Executors.create_enrollment(scope)

    {:ok, %{token: executor_token}} =
      DevOrchestrator.Executors.enroll(enrollment_code, %{"name" => "Commands runner"})

    assert {:ok, _executor} = DevOrchestrator.Executors.authenticate(executor_token)

    {:ok, _view, html} = live(conn, "/app/executors")
    assert html =~ "npx --yes dev-orchestrator-connector@0.2.0 run"
    assert html =~ "aria-label=\"Copy start command\""
  end

  test "run details show safe execution activity and identify the current stage" do
    scope = owner("activity@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "Activity", "repository" => "acme/activity"})

    {:ok, run} =
      DevOrchestrator.Runs.create(scope, project.id, %{
        "title" => "Add a file",
        "prompt" => "Create it"
      })

    {:ok, code} = DevOrchestrator.Executors.create_enrollment(scope)

    {:ok, %{token: token}} =
      DevOrchestrator.Executors.enroll(code, %{"name" => "Activity runner"})

    {:ok, executor} = DevOrchestrator.Executors.authenticate(token)
    :ok = DevOrchestrator.Executors.bind(scope, executor["id"], project.id)
    {:ok, lease} = DevOrchestrator.Runs.claim(executor)

    {:ok, _} =
      DevOrchestrator.Runs.append_event(executor, lease, %{
        "sequence" => 1,
        "kind" => "started",
        "data" => %{}
      })

    {:ok, _} =
      DevOrchestrator.Runs.append_event(executor, lease, %{
        "sequence" => 2,
        "kind" => "progress",
        "data" => %{"stage" => "editing", "message" => "private command output"}
      })

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, view, html} = live(conn, "/app/runs/" <> run["id"])

    assert html =~ "What’s happening"
    assert html =~ "Project files are being updated"
    assert html =~ "The agent reported a file change in the task workspace."
    assert html =~ ~s(id="activity-stream")
    assert html =~ ~s(phx-hook="ActivityStream")
    assert html =~ "aria-current=\"step\""
    refute render(view) =~ "private command output"
  end

  test "run details present an open clarification with owner response fields" do
    scope = owner("clarification-live@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "Context", "repository" => "acme/context"})

    {:ok, run} =
      DevOrchestrator.Runs.create(scope, project.id, %{
        "title" => "Build a feature",
        "prompt" => "Implement"
      })

    {:ok, code} = DevOrchestrator.Executors.create_enrollment(scope)

    {:ok, %{token: executor_token}} =
      DevOrchestrator.Executors.enroll(code, %{"name" => "Context runner"})

    {:ok, executor} = DevOrchestrator.Executors.authenticate(executor_token)
    :ok = DevOrchestrator.Executors.bind(scope, executor["id"], project.id)
    {:ok, lease} = DevOrchestrator.Runs.claim(executor)

    {:ok, _} =
      DevOrchestrator.Runs.append_event(executor, lease, %{
        "sequence" => 1,
        "kind" => "started",
        "data" => %{}
      })

    {:ok, %{id: _id}} =
      DevOrchestrator.Runs.request_clarification(executor, lease, %{
        "turnId" => "turn-1",
        "questions" => [
          %{
            "id" => "framework",
            "header" => "Framework",
            "question" => "Which framework should the project use?"
          }
        ]
      })

    {:ok, session_token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: session_token})
    {:ok, _view, html} = live(conn, "/app/runs/" <> run["id"])

    assert html =~ "Additional context"
    assert html =~ "Which framework should the project use?"
    assert html =~ "Send context"
    assert html =~ "answers[framework]"
  end

  test "accepted run events broadcast after persistence to an authorized subscriber" do
    scope = owner("activity-stream@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "Stream", "repository" => "acme/stream"})

    {:ok, run} =
      DevOrchestrator.Runs.create(scope, project.id, %{"title" => "Task", "prompt" => "Work"})

    {:ok, code} = DevOrchestrator.Executors.create_enrollment(scope)
    {:ok, %{token: token}} = DevOrchestrator.Executors.enroll(code, %{"name" => "Runner"})
    {:ok, executor} = DevOrchestrator.Executors.authenticate(token)
    :ok = DevOrchestrator.Executors.bind(scope, executor["id"], project.id)
    {:ok, lease} = DevOrchestrator.Runs.claim(executor)
    assert :ok = DevOrchestrator.Runs.subscribe(scope, run["id"])

    assert {:ok, %{state: "running"}} =
             DevOrchestrator.Runs.append_event(executor, lease, %{
               "sequence" => 1,
               "kind" => "activity",
               "data" => %{
                 "event" => %{"kind" => "warning", "message" => "Validation needs attention."}
               }
             })

    assert_receive {:run_updated, run_id}
    assert run_id == run["id"]

    assert [
             %{
               "kind" => "activity",
               "data" => %{"event" => %{"message" => "Validation needs attention."}}
             }
           ] =
             DevOrchestrator.Runs.events(scope, run_id)
  end

  test "repository access blockers point to the project setup action without exposing provider details" do
    scope = owner("repository-blocker@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {:ok, run} =
      DevOrchestrator.Runs.create(scope, project.id, %{"title" => "Task", "prompt" => "Edit"})

    {:ok, code} = DevOrchestrator.Executors.create_enrollment(scope)

    {:ok, %{token: executor_token}} =
      DevOrchestrator.Executors.enroll(code, %{"name" => "Runner"})

    {:ok, executor} = DevOrchestrator.Executors.authenticate(executor_token)
    :ok = DevOrchestrator.Executors.bind(scope, executor["id"], project.id)
    {:ok, lease} = DevOrchestrator.Runs.claim(executor)

    {:ok, %{state: "blocked"}} =
      DevOrchestrator.Runs.append_event(executor, lease, %{
        "sequence" => 1,
        "kind" => "blocked",
        "data" => %{
          "category" => "github_installation_required",
          "fingerprint" => String.duplicate("a", 64),
          "provider_body" => "sensitive provider details"
        }
      })

    {:ok, session_token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: session_token})
    {:ok, view, html} = live(conn, "/app/runs/" <> run["id"])

    assert html =~ "GitHub App access is not set up for this repository"

    assert render(view) =~
             "Install the configured GitHub App for this repository, then retry the task."

    refute render(view) =~ "sensitive provider details"
  end

  test "authenticated UI creates and displays a real project" do
    scope = owner("ui@example.test")
    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, view, html} = live(conn, "/app")
    assert html =~ "Start with one project"
    assert html =~ ~s(href="/templates/instructions.md" download="instructions.md")
    assert html =~ "Project instructions (optional)"
    assert html =~ "If you skip it, the default template is used."
    refute has_element?(view, "input[name='instructions'][required]")
    assert html =~ "Create project"
    refute html =~ "PR ready"

    upload =
      file_input(view, "#new-project", :instructions, [
        %{name: "instructions.md", content: "# Project rules\n"}
      ])

    render_upload(upload, "instructions.md")

    view
    |> form("#new-project", %{
      "name" => "New app",
      "repository" => "acme/new-app",
      "base_branch" => "main"
    })
    |> render_submit()

    [project] = Projects.list(scope)
    assert_redirect(view, "/app/projects/" <> project.id)
    assert {:ok, project} = Projects.get_project(scope, project.id)
    assert project.data["instructions"] == "# Project rules\n"
  end

  test "executor screen provides a copyable command to start a paired connector" do
    scope = owner("executor-copy@example.test")
    {:ok, code} = DevOrchestrator.Executors.create_enrollment(scope)
    {:ok, %{token: token}} = DevOrchestrator.Executors.enroll(code, %{"name" => "Runner"})
    {:ok, _executor} = DevOrchestrator.Executors.authenticate(token)

    {:ok, _project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {:ok, session_token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: session_token})

    {:ok, _view, html} = live(conn, "/app/executors")

    assert html =~ "dev-orchestrator-connector@0.2.0 run --config"
    assert html =~ "Copy start command"
    assert html =~ "Pair this computer"
    assert html =~ "Start the connector"
    assert html =~ "Authorize a project"
    assert html =~ "<details"
  end

  test "project creation uses the default instructions template when no file is uploaded" do
    scope = owner("optional-upload@example.test")
    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, view, _html} = live(conn, "/app")

    view
    |> form("#new-project", %{
      "name" => "Default instructions",
      "repository" => "acme/default-instructions",
      "base_branch" => "main"
    })
    |> render_submit()

    [project] = Projects.list(scope)
    assert_redirect(view, "/app/projects/" <> project.id)
    assert {:ok, project} = Projects.get_project(scope, project.id)
    assert project.data["instructions"] =~ "## Project context"
    assert project.data["instructions"] =~ "## Validation"
  end

  test "project rules can replace instructions but invalid uploads preserve the saved version" do
    scope = owner("replace-upload@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{
        "name" => "Existing",
        "repository" => "acme/existing",
        "instructions" => "# Original\n"
      })

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, view, html} = live(conn, "/app/projects/" <> project.id)
    assert html =~ "Saved instructions stay in place unless you upload a replacement."
    assert html =~ "Slack report channel"
    assert html =~ "Connect Slack below to choose this project&#39;s report channel."
    refute html =~ "Refresh Slack channels"

    upload =
      file_input(view, "#project-rules", :instructions, [
        %{name: "rules.md", content: "# Untrusted replacement\n"}
      ])

    render_upload(upload, "rules.md")

    view
    |> form("#project-rules", %{
      "name" => "Existing",
      "repository" => "acme/existing",
      "base_branch" => "main"
    })
    |> render_submit()

    assert render(view) =~ "Choose the file named instructions.md."
    assert {:ok, saved} = Projects.get_project(scope, project.id)
    assert saved.data["instructions"] == "# Original\n"

    valid_upload =
      file_input(view, "#project-rules", :instructions, [
        %{name: "instructions.md", content: "# Updated\n"}
      ])

    render_upload(valid_upload, "instructions.md")

    view
    |> form("#project-rules", %{
      "name" => "Existing",
      "repository" => "acme/existing",
      "base_branch" => "main"
    })
    |> render_submit()

    assert {:ok, saved} = Projects.get_project(scope, project.id)
    assert saved.data["instructions"] == "# Updated\n"
  end

  test "unconfigured provider auth actions stay visible with the required server setup" do
    scope = owner("provider-setup@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{
        "name" => "Connected app",
        "repository" => "acme/connected-app"
      })

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/projects/" <> project.id)

    assert html =~ "Connect GitHub"
    assert html =~ "Connect Linear"
    assert html =~ "Connect Slack"
    assert html =~ "Server setup required"
    assert html =~ "GITHUB_CLIENT_ID"
    assert html =~ "LINEAR_CLIENT_ID"
    assert html =~ "SLACK_CLIENT_ID"
  end

  test "GitHub project setup asks to install the app before connecting OAuth" do
    configure_github_app()
    scope = owner("github-install-ui@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/projects/" <> project.id)

    assert html =~ "Install GitHub App"
    assert html =~ ~s(action="/connections/github/install/start")
    refute html =~ ~s(action="/connections/github/start")
  end

  test "verified installation changes the GitHub action to Connect" do
    configure_github_app()
    scope = owner("github-installed-ui@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    DevOrchestrator.Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [scope.organization_id, project.id, "acme/app", 42, "acme"]
    )

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/projects/" <> project.id)

    assert html =~ ~s(action="/connections/github/start")
    assert html =~ "Connect GitHub"
    refute html =~ "Install GitHub App"
  end

  test "an existing GitHub connection is shown as connected and offers reconnect" do
    configure_github_app()
    scope = owner("github-connected-ui@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    DevOrchestrator.Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [scope.organization_id, project.id, "acme/app", 42, "acme"]
    )

    connection_id = DevOrchestrator.Store.id()

    DevOrchestrator.Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,'github','GitHub · acme',decode('','hex'),'42')",
      [connection_id, scope.organization_id]
    )

    DevOrchestrator.Store.exec("INSERT INTO connection_grants VALUES($1,$2,$3)", [
      scope.organization_id,
      project.id,
      connection_id
    ])

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/projects/" <> project.id)

    assert html =~ "GitHub connected"
    assert html =~ ~s(action="/connections/github/start")
    assert html =~ "Reconnect GitHub"
    refute html =~ "Install GitHub App"
  end

  test "project connections show connected status for GitHub, Linear, and Slack" do
    configure_github_app()
    scope = owner("all-connections-ui@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    DevOrchestrator.Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [scope.organization_id, project.id, "acme/app", 42, "acme"]
    )

    for {provider, label, external_id} <- [
          {"github", "GitHub · acme", "42"},
          {"linear", "Linear · Team", "team-1"},
          {"slack", "Slack · Workspace", "workspace-1"}
        ] do
      connection_id = DevOrchestrator.Store.id()

      DevOrchestrator.Store.exec(
        "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,$3,$4,decode('','hex'),$5)",
        [connection_id, scope.organization_id, provider, label, external_id]
      )

      DevOrchestrator.Store.exec("INSERT INTO connection_grants VALUES($1,$2,$3)", [
        scope.organization_id,
        project.id,
        connection_id
      ])
    end

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/projects/" <> project.id)

    assert html =~ "GitHub connected"
    assert html =~ "Linear connected"
    assert html =~ "Slack connected"
  end

  test "the connections page labels active provider accounts as connected" do
    scope = owner("connections-list-status@example.test")
    connection_id = DevOrchestrator.Store.id()

    DevOrchestrator.Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,'linear','Linear · Team',decode('','hex'),'team-1')",
      [connection_id, scope.organization_id]
    )

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/connections")

    assert html =~ "Linear · Team"
    assert html =~ "Connected"
  end

  test "installation verified for an old repository does not unlock GitHub OAuth" do
    configure_github_app()
    scope = owner("github-changed-repo-ui@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/current"})

    DevOrchestrator.Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [scope.organization_id, project.id, "acme/previous", 42, "acme"]
    )

    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/projects/" <> project.id)

    assert html =~ "Install GitHub App"
    refute html =~ ~s(action="/connections/github/start")
  end

  test "a non-owner cannot start installation from the project UI" do
    configure_github_app()
    scope = owner("github-member-ui@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    DevOrchestrator.Store.exec(
      "UPDATE memberships SET role='member' WHERE organization_id=$1 AND user_id=$2",
      [scope.organization_id, scope.user_id]
    )

    {:ok, member_scope} = DevOrchestrator.Accounts.scope(scope.user_id)
    {:ok, token} = Accounts.login(member_scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, _view, html} = live(conn, "/app/projects/" <> project.id)

    assert html =~ "Workspace owner required"
    refute html =~ ~s(action="/connections/github/install/start")
  end

  defp configure_github_app do
    Application.put_env(:dev_orchestrator, :github,
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      app_id: "12345",
      app_slug: "test-app",
      private_key_path: "/unused/test-key.pem"
    )
  end
end
