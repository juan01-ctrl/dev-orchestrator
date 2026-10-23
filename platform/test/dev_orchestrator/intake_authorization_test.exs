defmodule DevOrchestrator.IntakeAuthorizationTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Runs, Store}
  alias DevOrchestrator.Connections.SecretBox
  alias DevOrchestrator.Intake.Inbox

  test "a Linear webhook authorizes the issue separately for every destination connection" do
    privileged = owner("linear-privileged@example.test")
    restricted = owner("linear-restricted@example.test")

    {:ok, privileged_project} =
      Projects.create_project(privileged, %{
        "name" => "Privileged",
        "repository" => "acme/privileged",
        "linear_team" => "team-private"
      })

    {:ok, restricted_project} =
      Projects.create_project(restricted, %{
        "name" => "Restricted",
        "repository" => "acme/restricted",
        "linear_team" => "team-private"
      })

    connect_linear(privileged, privileged_project.id, "connection-privileged", "token-privileged")
    connect_linear(restricted, restricted_project.id, "connection-restricted", "token-restricted")

    Store.exec(
      "INSERT INTO webhook_inbox(id,provider,delivery_id,organization_external_id,event) VALUES($1,'linear',$2,$3,$4)",
      [Store.id(), "delivery-private", "linear-workspace", %{"issue_id" => "issue-private"}]
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
                   "description" => "Restricted details",
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
