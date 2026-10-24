defmodule DevOrchestrator.ReconcilerTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Store, Connections.SecretBox}
  alias DevOrchestrator.Intake.{Reconciler, Inbox}

  setup do
    scope = owner("reconciler@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {:ok, _} = Projects.update_project(scope, project.id, %{"linear_team" => "team-1"})
    id = Store.id()

    secret =
      SecretBox.seal(
        Jason.encode!(%{"access_token" => "test-token"}),
        scope.organization_id,
        Application.fetch_env!(:dev_orchestrator, :encryption_key)
      )

    Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,'linear','Linear',$3,'workspace')",
      [id, scope.organization_id, secret]
    )

    Store.exec(
      "INSERT INTO connection_grants(organization_id,project_id,connection_id) VALUES($1,$2,$3)",
      [scope.organization_id, project.id, id]
    )

    old = Application.get_env(:dev_orchestrator, :provider_transport)
    on_exit(fn -> Application.put_env(:dev_orchestrator, :provider_transport, old) end)
    %{connection: id}
  end

  test "returned application errors leave the inbox receipt and scan cursor retryable", ctx do
    invalid = %{"id" => "issue-1", "state" => nil}

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      body =
        if String.contains?(opts[:json][:query], "issue(id:"),
          do: %{"issue" => invalid},
          else: %{"issues" => %{"nodes" => [invalid], "pageInfo" => %{"hasNextPage" => false}}}

      {:ok, %{status: 200, body: %{"data" => body}}}
    end)

    receipt = Store.id()

    Store.exec(
      "INSERT INTO webhook_inbox(id,provider,delivery_id,organization_external_id,event) VALUES($1,'linear','bad-issue','workspace',$2)",
      [receipt, %{"action" => "update", "issue_id" => "issue-1"}]
    )

    assert :retry = Inbox.process_one()

    assert Store.one("SELECT state FROM webhook_inbox WHERE id=$1", [receipt])["state"] ==
             "pending"

    assert {:error, :invalid_issue} = Reconciler.tick(ctx.connection)

    assert Store.one("SELECT * FROM linear_reconciliation_cursors WHERE connection_id=$1", [
             ctx.connection
           ]) == nil
  end

  test "a multi-tick scan retains the maximum watermark from all earlier pages", ctx do
    latest = "2026-10-24T10:00:00Z"

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      after_cursor = opts[:json][:variables]["after"]
      page = if after_cursor, do: String.to_integer(after_cursor) + 1, else: 1

      issue = %{
        "id" => "issue-#{page}",
        "updatedAt" => if(page == 1, do: latest, else: "2026-10-23T10:00:00Z"),
        "state" => %{"name" => "Done"}
      }

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [issue],
               "pageInfo" => %{"hasNextPage" => page < 11, "endCursor" => to_string(page)}
             }
           }
         }
       }}
    end)

    assert :ok = Reconciler.tick(ctx.connection)

    first =
      Store.one("SELECT * FROM linear_reconciliation_cursors WHERE connection_id=$1", [
        ctx.connection
      ])

    assert first["page_cursor"] == "10"

    assert DateTime.compare(
             Reconciler.cursor(first).watermark,
             DateTime.from_iso8601(latest) |> elem(1)
           ) == :eq

    assert :ok = Reconciler.tick(ctx.connection)

    final =
      Store.one("SELECT * FROM linear_reconciliation_cursors WHERE connection_id=$1", [
        ctx.connection
      ])

    assert final["page_cursor"] == nil
    assert final["scan_updated_at_cursor"] == nil

    assert DateTime.compare(
             Reconciler.cursor(final).updated_at,
             DateTime.from_iso8601(latest) |> elem(1)
           ) == :eq
  end
end
