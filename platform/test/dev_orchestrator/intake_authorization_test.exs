defmodule DevOrchestrator.IntakeAuthorizationTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Runs, Store, Executors}
  alias DevOrchestrator.Connections.SecretBox
  alias DevOrchestrator.Intake.Inbox
  alias DevOrchestrator.Runs.Lifecycle

  test "a Linear webhook authorizes the issue separately for every destination connection" do
    privileged = owner("linear-privileged@example.test")
    restricted = owner("linear-restricted@example.test")

    {:ok, privileged_project} =
      Projects.create_project(privileged, %{
        "name" => "Privileged",
        "repository" => "acme/privileged"
      })

    {:ok, privileged_project} =
      Projects.update_project(privileged, privileged_project.id, %{
        "linear_team" => "team-private"
      })

    {:ok, restricted_project} =
      Projects.create_project(restricted, %{
        "name" => "Restricted",
        "repository" => "acme/restricted"
      })

    {:ok, restricted_project} =
      Projects.update_project(restricted, restricted_project.id, %{
        "linear_team" => "team-private"
      })

    connect_linear(privileged, privileged_project.id, "connection-privileged", "token-privileged")
    connect_linear(restricted, restricted_project.id, "connection-restricted", "token-restricted")

    Store.exec(
      "INSERT INTO webhook_inbox(id,provider,delivery_id,organization_external_id,event) VALUES($1,'linear',$2,$3,$4)",
      [
        Store.id(),
        "delivery-private",
        "linear-workspace",
        %{"action" => "create", "issue_id" => "issue-private"}
      ]
    )

    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      authorization = List.keyfind(opts[:headers], "authorization", 0)

      case authorization do
        {"authorization", "Bearer token-privileged"} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "id" => "issue-private",
                   "identifier" => "SEC-1",
                   "title" => "Private issue",
                   "description" =>
                     "Restricted details\n\n![diagram](https://uploads.linear.app/team/diagram.png?signature=private)",
                   "url" => "https://linear.app/issue/SEC-1",
                   "state" => %{"name" => "Todo"},
                   "team" => %{"id" => "team-private"},
                   "project" => nil
                 }
               }
             }
           }}

        {"authorization", "Bearer token-restricted"} ->
          {:ok, %{status: 200, body: %{"data" => %{"issue" => nil}}}}
      end
    end)

    on_exit(fn ->
      Application.put_env(:dev_orchestrator, :provider_transport, old_transport)
    end)

    assert :processed = Inbox.process_one()
    assert [%{"title" => "SEC-1 — Private issue"}] = Runs.list(privileged)
    assert [] = Runs.list(restricted)

    stored =
      Store.one("SELECT source_context FROM runs WHERE project_id=$1", [privileged_project.id])

    assert stored["source_context"]["linear_connection_id"] == "connection-privileged"
    assert [asset] = stored["source_context"]["assets"]
    assert asset["source_url"] == "https://uploads.linear.app/team/diagram.png?signature=private"
    refute stored["prompt"] =~ "signature=private"
    refute stored["prompt"] =~ "uploads.linear.app"
    refute inspect(Runs.list(privileged)) =~ "signature=private"

    updated_issue = %{
      "id" => "issue-private",
      "identifier" => "SEC-1",
      "title" => "Private issue",
      "description" => "Updated context\n\n[data.csv](https://uploads.linear.app/team/data.csv)",
      "url" => "https://linear.app/issue/SEC-1",
      "state" => %{"name" => "Todo"},
      "team" => %{"id" => "team-private"},
      "project" => nil
    }

    assert %{result: :unchanged} =
             Lifecycle.apply_issue(privileged_project.data, updated_issue, %{
               "linear_connection_id" => "connection-privileged"
             })

    updated =
      Store.one("SELECT prompt,source_context FROM runs WHERE project_id=$1", [
        privileged_project.id
      ])

    assert updated["prompt"] =~ "Updated context"
    refute updated["prompt"] =~ "uploads.linear.app"
    assert [%{"filename_hint" => "data.csv"}] = updated["source_context"]["assets"]
  end

  test "task asset downloads require the active lease and the run project's Linear grant" do
    scope = owner("asset-owner@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "Assets", "repository" => "acme/assets"})

    connect_linear(scope, project.id, "asset-linear", "asset-linear-token")
    {:ok, code} = Executors.create_enrollment(scope)

    {:ok, %{token: token, executor: %{id: executor_id}}} =
      Executors.enroll(code, %{"name" => "Local"})

    {:ok, executor} = Executors.authenticate(token)
    asset_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    run_id = Store.id()

    context = %{
      "linear_connection_id" => "asset-linear",
      "assets" => [
        %{
          "id" => asset_id,
          "source_url" => "https://uploads.linear.app/file.csv?signature=private",
          "filename_hint" => "data.csv"
        }
      ]
    }

    Store.exec(
      "INSERT INTO runs(id,organization_id,project_id,source_key,title,prompt,state,lifecycle,generation,executor_id,lease_expires_at,source_context) VALUES($1,$2,$3,$4,'Assets','Read file','leased',1,1,$5,now()+interval '1 minute',$6)",
      [run_id, scope.organization_id, project.id, "asset-run", executor_id, context]
    )

    assert :ok = Executors.bind(scope, executor_id, project.id)
    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    body = "id,name\n1,alpha\n"

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:url] == "https://uploads.linear.app/file.csv?signature=private"
      assert {"authorization", "Bearer asset-linear-token"} in opts[:headers]
      response = %{status: 200, headers: %{"content-type" => ["text/csv"]}, private: %{}}
      {:cont, {_request, response}} = opts[:into].({:data, body}, {%{}, response})
      {:ok, response}
    end)

    on_exit(fn ->
      if old_transport,
        do: Application.put_env(:dev_orchestrator, :provider_transport, old_transport),
        else: Application.delete_env(:dev_orchestrator, :provider_transport)
    end)

    lease = %{"id" => run_id, "generation" => 1, "lifecycle" => 1}
    assert {:ok, %{body: ^body, filename: "data.csv"}} = Runs.asset(executor, lease, asset_id)

    assert {:error, :not_found} =
             Runs.asset(executor, lease, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")

    assert {:error, :stale_lease} = Runs.asset(executor, %{lease | "generation" => 2}, asset_id)

    assert {:error, :unauthorized} =
             Runs.asset(
               %{"id" => "other", "organization_id" => scope.organization_id},
               lease,
               asset_id
             )
  end

  defp connect_linear(scope, project_id, id, token) do
    key = Application.fetch_env!(:dev_orchestrator, :encryption_key)
    secret = SecretBox.seal(Jason.encode!(%{"access_token" => token}), scope.organization_id, key)

    Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,'linear','Linear',$3,'linear-workspace')",
      [id, scope.organization_id, secret]
    )

    Store.exec(
      "INSERT INTO connection_grants(organization_id,project_id,connection_id) VALUES($1,$2,$3)",
      [scope.organization_id, project_id, id]
    )
  end
end
