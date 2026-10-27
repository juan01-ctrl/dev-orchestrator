defmodule DevOrchestrator.SlackDecisionTest do
  use DevOrchestrator.DataCase
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  alias DevOrchestrator.{Store, Runs, Executors}
  alias DevOrchestrator.Connections.SecretBox
  @endpoint DevOrchestratorWeb.Endpoint

  setup ctx do
    scope = owner("decision-owner@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    connection = Store.id()

    secret =
      SecretBox.seal(
        Jason.encode!(
          if(ctx[:installer] == false,
            do: %{"access_token" => "test-token"},
            else: %{"access_token" => "test-token", "authed_user" => %{"id" => "UOWNER"}}
          )
        ),
        scope.organization_id,
        Application.fetch_env!(:dev_orchestrator, :encryption_key)
      )

    Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,'slack','Slack',$3,'TWORK')",
      [connection, scope.organization_id, secret]
    )

    Store.exec("INSERT INTO connection_grants VALUES($1,$2,$3)", [
      scope.organization_id,
      project.id,
      connection
    ])

    Store.exec(
      "UPDATE projects SET slack_workspace_id='TWORK',slack_channel='C123' WHERE id=$1",
      [project.id]
    )

    {:ok, code} = Executors.create_enrollment(scope)
    {:ok, %{token: token}} = Executors.enroll(code, %{"name" => "Runner"})
    {:ok, executor} = Executors.authenticate(token)
    executor = Map.put(executor, "capabilities", %{"workflow_version" => 2})
    :ok = Executors.bind(scope, executor["id"], project.id)

    {:ok, run} =
      Runs.create(scope, project.id, %{
        "title" => "Important decision",
        "prompt" => "Keep changes scoped"
      })

    {:ok, lease} = Runs.claim(executor)

    questions = [
      %{
        "id" => "retention",
        "header" => "Data",
        "question" =>
          "Approve removing archived records? This permanently removes their history.",
        "options" => [
          %{"label" => "Approve", "description" => "Remove specified records"},
          %{"label" => "Deny", "description" => "Preserve records"}
        ]
      }
    ]

    {:ok, %{id: question, status: "awaiting_input"}} =
      Runs.request_clarification(executor, lease, %{
        "questions" => questions,
        "turnId" => "decision-turn",
        "durable" => true
      })

    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    old_slack = Application.get_env(:dev_orchestrator, :slack)
    parent = self()
    Application.put_env(:dev_orchestrator, :slack, signing_secret: "decision-secret")

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      send(parent, {:slack_message, opts[:json]})
      {:ok, %{status: 200, body: %{"ok" => true, "ts" => "100.200"}}}
    end)

    on_exit(fn ->
      Application.put_env(:dev_orchestrator, :provider_transport, old_transport)
      Application.put_env(:dev_orchestrator, :slack, old_slack)
    end)

    %{scope: scope, project: project, connection: connection, run: run, question: question}
  end

  test "important Slack approvals resume the exact paused task and duplicate clicks are harmless",
       ctx do
    DevOrchestrator.Delivery.Worker.tick()
    assert_received {:slack_message, message}
    buttons = Enum.flat_map(message[:blocks], &Map.get(&1, :elements, []))
    assert Enum.any?(buttons, &(&1[:action_id] == "approve_task_decision"))
    assert json_response(action(ctx, "approve_task_decision"), 200)["replace_original"] == true
    run = Store.one("SELECT * FROM runs WHERE id=$1", [ctx.run["id"]])
    assert run["state"] == "queued"
    assert run["generation"] == 2

    assert get_in(run, ["snapshot", "continuation", "answer", "answers", "retention", "answers"]) ==
             ["Approve"]

    assert json_response(action(ctx, "approve_task_decision"), 200)["replace_original"] == true

    assert Store.one("SELECT generation FROM runs WHERE id=$1", [ctx.run["id"]])["generation"] ==
             2

    action(ctx, "deny_task_decision")

    assert Store.one("SELECT answer FROM run_clarifications WHERE id=$1", [ctx.question])[
             "answer"
           ]["answers"]["retention"]["answers"] == ["Approve"]
  end

  test "denial is recorded explicitly and never converted to approval", ctx do
    DevOrchestrator.Delivery.Worker.tick()
    action(ctx, "deny_task_decision")
    run = Store.one("SELECT * FROM runs WHERE id=$1", [ctx.run["id"]])
    assert run["state"] == "queued"

    assert get_in(run, ["snapshot", "continuation", "answer", "answers", "retention", "answers"]) ==
             ["Deny"]
  end

  test "an answered button cannot act on a later execution generation", ctx do
    DevOrchestrator.Delivery.Worker.tick()
    action(ctx, "approve_task_decision")
    Store.exec("UPDATE runs SET generation=generation+1 WHERE id=$1", [ctx.run["id"]])
    response = json_response(action(ctx, "approve_task_decision"), 200)
    refute response["replace_original"] == true
  end

  test "wrong identity or destination cannot answer a decision", ctx do
    DevOrchestrator.Delivery.Worker.tick()

    for override <- [
          %{"user" => %{"id" => "UOTHER"}},
          %{"team" => %{"id" => "TOTHER"}},
          %{"channel" => %{"id" => "COTHER"}},
          %{"message" => %{"ts" => "999.0"}}
        ] do
      action(ctx, "approve_task_decision", override)

      assert Store.one("SELECT status FROM run_clarifications WHERE id=$1", [ctx.question])[
               "status"
             ] == "open"
    end
  end

  test "revoked, expired and stale decision buttons never resume work", ctx do
    DevOrchestrator.Delivery.Worker.tick()
    Store.exec("UPDATE connections SET revoked_at=now() WHERE id=$1", [ctx.connection])
    action(ctx, "approve_task_decision")

    assert Store.one("SELECT status FROM run_clarifications WHERE id=$1", [ctx.question])[
             "status"
           ] == "open"

    Store.exec("UPDATE connections SET revoked_at=NULL WHERE id=$1", [ctx.connection])

    Store.exec("UPDATE run_clarifications SET expires_at=now()-interval '1 second' WHERE id=$1", [
      ctx.question
    ])

    action(ctx, "approve_task_decision")

    assert Store.one("SELECT state FROM runs WHERE id=$1", [ctx.run["id"]])["state"] ==
             "awaiting_input"

    Store.exec("UPDATE run_clarifications SET expires_at=now()+interval '1 hour' WHERE id=$1", [
      ctx.question
    ])

    Store.exec("UPDATE runs SET generation=generation+1 WHERE id=$1", [ctx.run["id"]])
    action(ctx, "approve_task_decision")

    assert Store.one("SELECT status FROM run_clarifications WHERE id=$1", [ctx.question])[
             "status"
           ] == "open"
  end

  @tag installer: false
  test "unknown Slack identity gets an authenticated dashboard link without approval buttons",
       ctx do
    DevOrchestrator.Delivery.Worker.tick()
    assert_received {:slack_message, message}
    buttons = Enum.flat_map(message[:blocks], &Map.get(&1, :elements, []))

    refute Enum.any?(
             buttons,
             &(&1[:action_id] in ["approve_task_decision", "deny_task_decision"])
           )

    assert Enum.any?(buttons, &is_binary(&1[:url]))
    action(ctx, "approve_task_decision")

    assert Store.one("SELECT state FROM runs WHERE id=$1", [ctx.run["id"]])["state"] ==
             "awaiting_input"
  end

  test "changed project destinations and revoked grants invalidate delivered decisions", ctx do
    DevOrchestrator.Delivery.Worker.tick()
    Store.exec("UPDATE projects SET slack_channel='COTHER' WHERE id=$1", [ctx.project.id])
    action(ctx, "approve_task_decision")

    assert Store.one("SELECT status FROM run_clarifications WHERE id=$1", [ctx.question])[
             "status"
           ] == "open"

    Store.exec("UPDATE projects SET slack_channel='C123' WHERE id=$1", [ctx.project.id])

    Store.exec("DELETE FROM connection_grants WHERE project_id=$1 AND connection_id=$2", [
      ctx.project.id,
      ctx.connection
    ])

    action(ctx, "approve_task_decision")

    assert Store.one("SELECT status FROM run_clarifications WHERE id=$1", [ctx.question])[
             "status"
           ] == "open"
  end

  defp action(ctx, id, override \\ %{}) do
    payload =
      Map.merge(
        %{
          "type" => "block_actions",
          "team" => %{"id" => "TWORK"},
          "channel" => %{"id" => "C123"},
          "user" => %{"id" => "UOWNER"},
          "message" => %{"ts" => "100.200"},
          "actions" => [%{"action_id" => id, "value" => ctx.question}]
        },
        override
      )

    body = URI.encode_query(%{"payload" => Jason.encode!(payload)})
    timestamp = Integer.to_string(System.system_time(:second))

    signature =
      "v0=" <>
        Base.encode16(
          :crypto.mac(:hmac, :sha256, "decision-secret", "v0:" <> timestamp <> ":" <> body),
          case: :lower
        )

    build_conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-slack-signature", signature)
    |> put_req_header("x-slack-request-timestamp", timestamp)
    |> post("/api/v1/webhooks/slack", body)
  end
end
