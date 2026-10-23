defmodule DevOrchestrator.SlackIntakeTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Intake.Inbox, Intake.SlackDrafts, Store}

  setup do
    scope = owner("slack-intake-#{System.unique_integer([:positive])}@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "Slack project", "repository" => "acme/slack"})

    slack_id = connection(scope, project.id, "slack", "T1", "slack-connection")
    linear_id = connection(scope, project.id, "linear", "L1", "linear-connection")

    {:ok, _} =
      Projects.update_project(scope, project.id, %{
        "slack_channel" => "C1",
        "linear_team" => "team-1",
        "linear_project" => "project-1"
      })

    %{
      scope: scope,
      project: project,
      slack_connection_id: slack_id,
      linear_connection_id: linear_id
    }
  end

  test "signed Slack delivery acceptance deduplicates by event ID", _context do
    body = Jason.encode!(slack_payload("Ev-1", "T1", "C1", ["F1"]))
    assert {:ok, :accepted} = Inbox.accept_slack(body)
    assert {:ok, :duplicate} = Inbox.accept_slack(body)

    assert Store.one("SELECT count(*) AS count FROM webhook_inbox WHERE provider='slack'")[
             "count"
           ] == 1
  end

  test "a mentioned channel routes only to its exact bound project and workspace", %{
    project: project
  } do
    event = %{
      "event_id" => "Ev-route-1",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "requester_slack_user_id" => "U1",
      "message_ts" => "1.2",
      "thread_ts" => "1.2",
      "text" => "Create a task",
      "file_ids" => ["F1"]
    }

    assert {:ok, :created} = SlackDrafts.accept(event)
    assert {:ok, :duplicate} = SlackDrafts.accept(event)

    assert Store.one("SELECT project_id FROM slack_task_drafts WHERE event_id='Ev-route-1'")[
             "project_id"
           ] == project.id

    assert {:ok, :ignored} =
             SlackDrafts.accept(%{event | "event_id" => "Ev-other", "workspace_id" => "T-other"})

    assert Store.one("SELECT count(*) AS count FROM slack_task_drafts")["count"] == 1
  end

  test "mentions with zero or multiple attachments persist a safe usage reply state", _context do
    base = %{
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "requester_slack_user_id" => "U1",
      "message_ts" => "1.2",
      "thread_ts" => "1.2",
      "text" => "Make a task"
    }

    assert {:ok, :created} =
             SlackDrafts.accept(Map.merge(base, %{"event_id" => "Ev-none", "file_ids" => []}))

    assert {:ok, :created} =
             SlackDrafts.accept(
               Map.merge(base, %{"event_id" => "Ev-many", "file_ids" => ["F1", "F2"]})
             )

    assert Store.one(
             "SELECT count(*) AS count FROM slack_task_drafts WHERE error_category='audio_required'"
           )["count"] == 2
  end

  test "a project without a Linear destination receives a durable actionable failure", %{
    scope: scope,
    project: project
  } do
    assert {:ok, _} =
             Projects.update_project(scope, project.id, %{
               "linear_team" => "",
               "linear_project" => ""
             })

    event = %{
      "event_id" => "Ev-no-linear",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "requester_slack_user_id" => "U1",
      "message_ts" => "1.2",
      "thread_ts" => "1.2",
      "text" => "Make a task",
      "file_ids" => ["F1"]
    }

    assert {:ok, :created} = SlackDrafts.accept(event)

    assert Store.one(
             "SELECT state,error_category FROM slack_task_drafts WHERE event_id='Ev-no-linear'"
           ) == %{
             "state" => "received",
             "error_category" => "linear_not_configured"
           }
  end

  test "only the original requester can confirm and repeated clicks queue one creation",
       context do
    draft_id = insert_confirmation_draft(context)

    assert {:error, :forbidden} = SlackDrafts.confirm(action(draft_id, "U2"))

    assert Store.one("SELECT state FROM slack_task_drafts WHERE id=$1", [draft_id])["state"] ==
             "awaiting_confirmation"

    assert {:ok, :queued} = SlackDrafts.confirm(action(draft_id, "U1"))
    assert {:ok, :already_handled} = SlackDrafts.confirm(action(draft_id, "U1"))

    assert Store.one("SELECT state FROM slack_task_drafts WHERE id=$1", [draft_id])["state"] ==
             "creating"
  end

  test "confirming the wrong message or workspace cannot mutate the draft", context do
    draft_id = insert_confirmation_draft(context)

    assert {:error, :forbidden} =
             SlackDrafts.confirm(%{action(draft_id, "U1") | "message_ts" => "9.9"})

    assert {:error, :forbidden} =
             SlackDrafts.confirm(%{action(draft_id, "U1") | "workspace_id" => "T2"})

    assert Store.one("SELECT state FROM slack_task_drafts WHERE id=$1", [draft_id])["state"] ==
             "awaiting_confirmation"
  end

  test "requester cancellation is terminal and repeated cancellation is idempotent", context do
    draft_id = insert_confirmation_draft(context)

    assert {:ok, :cancelled} = SlackDrafts.cancel(action(draft_id, "U1", "cancel_linear_task"))

    assert {:ok, :already_handled} =
             SlackDrafts.cancel(action(draft_id, "U1", "cancel_linear_task"))

    assert Store.one("SELECT state FROM slack_task_drafts WHERE id=$1", [draft_id])["state"] ==
             "cancelled"
  end

  test "an ambiguous Linear mutation becomes terminal and is never sent a second time", context do
    previous_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    store_token(context.scope, context.slack_connection_id, "slack-token")
    store_token(context.scope, context.linear_connection_id, "linear-token")
    draft_id = insert_confirmation_draft(context)
    assert {:ok, :queued} = SlackDrafts.confirm(action(draft_id, "U1"))
    mutations = Agent.start_link(fn -> 0 end) |> elem(1)

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      case opts[:url] do
        "https://api.linear.app/graphql" ->
          query = opts[:json][:query]

          cond do
            String.contains?(query, "mutation CreateIssue") ->
              Agent.update(mutations, &(&1 + 1))
              {:error, :timeout}

            String.contains?(query, "query Team") ->
              {:ok,
               %{
                 status: 200,
                 body: %{
                   "data" => %{
                     "team" => %{
                       "id" => "team-1",
                       "states" => %{"nodes" => [%{"id" => "state-1", "name" => "Todo"}]}
                     }
                   }
                 }
               }}

            true ->
              {:ok,
               %{
                 status: 200,
                 body: %{
                   "data" => %{
                     "project" => %{
                       "id" => "project-1",
                       "teams" => %{"nodes" => [%{"id" => "team-1"}]}
                     }
                   }
                 }
               }}
          end

        "https://slack.com/api/chat.update" ->
          {:ok, %{status: 200, body: %{"ok" => true}}}
      end
    end)

    assert SlackDrafts.create_one() == :updated

    assert Store.one("SELECT state,error_category FROM slack_task_drafts WHERE id=$1", [draft_id]) ==
             %{
               "state" => "creation_ambiguous",
               "error_category" => "creation_ambiguous"
             }

    assert Agent.get(mutations, & &1) == 1
    assert :empty = SlackDrafts.create_one()
    assert Agent.get(mutations, & &1) == 1
    Agent.stop(mutations)

    if previous_transport,
      do: Application.put_env(:dev_orchestrator, :provider_transport, previous_transport),
      else: Application.delete_env(:dev_orchestrator, :provider_transport)
  end

  defp connection(scope, project_id, provider, external_id, id) do
    Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,$3,$3,decode('','hex'),$4)",
      [id, scope.organization_id, provider, external_id]
    )

    Store.exec("INSERT INTO connection_grants VALUES($1,$2,$3)", [
      scope.organization_id,
      project_id,
      id
    ])

    id
  end

  defp slack_payload(event_id, workspace, channel, files) do
    %{
      "type" => "event_callback",
      "event_id" => event_id,
      "team_id" => workspace,
      "event" => %{
        "type" => "app_mention",
        "user" => "U1",
        "channel" => channel,
        "ts" => "1.2",
        "text" => "<@BOT> Create a task",
        "files" =>
          Enum.map(files, &%{"id" => &1, "url_private" => "https://not-retained.invalid"})
      }
    }
  end

  defp insert_confirmation_draft(%{
         scope: scope,
         project: project,
         slack_connection_id: connection_id
       }) do
    id = Store.id()

    Store.exec(
      "INSERT INTO slack_task_drafts(id,event_id,organization_id,project_id,slack_connection_id,requester_slack_user_id,channel_id,thread_ts,file_id,state,task_draft,slack_message_ts,expires_at) VALUES($1,$2,$3,$4,$5,'U1','C1','1.2','F1','awaiting_confirmation',$6,'2.3',now()+interval '1 hour')",
      [
        id,
        "Ev-confirm-" <> id,
        scope.organization_id,
        project.id,
        connection_id,
        %{
          "title" => "A task",
          "context" => "Context",
          "objective" => "Goal",
          "scope" => [],
          "acceptance_criteria" => [],
          "constraints_or_open_questions" => []
        }
      ]
    )

    id
  end

  defp action(id, user, action_id \\ "create_linear_task") do
    %{
      "draft_id" => id,
      "action_id" => action_id,
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "user_id" => user,
      "message_ts" => "2.3"
    }
  end

  defp store_token(scope, connection_id, token) do
    key = Application.fetch_env!(:dev_orchestrator, :encryption_key)

    secret =
      DevOrchestrator.Connections.SecretBox.seal(
        Jason.encode!(%{"access_token" => token}),
        scope.organization_id,
        key
      )

    Store.exec("UPDATE connections SET secret=$2 WHERE id=$1", [connection_id, secret])
  end
end
