defmodule DevOrchestrator.SlackPRFollowupsTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.{Connections, Executors, Runs, Store}
  alias DevOrchestrator.Connections.SecretBox
  alias DevOrchestrator.Intake.SlackDrafts
  alias DevOrchestrator.Delivery.{Outbox, SlackReports}

  @draft %{
    "title" => "Move the button",
    "context" => "The delivered PR needs an adjustment",
    "objective" => "Place it above the form",
    "scope" => ["Move the existing button"],
    "acceptance_criteria" => ["The button is above the form"],
    "constraints_or_open_questions" => []
  }
  @wav <<"RIFF", 40::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
         8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", 4::little-32,
         0::little-16, 0::little-16>>

  setup do
    scope = owner("slack-pr-followups@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    slack_id = connect(scope, project.id, "slack", "T1", %{"access_token" => "slack-test-token"})
    connect(scope, project.id, "github", "123", %{"installation_id" => 123})
    {:ok, _} = Projects.update_project(scope, project.id, %{"slack_channel" => "C1"})
    {:ok, code} = Executors.create_enrollment(scope)
    {:ok, %{token: token}} = Executors.enroll(code, %{"name" => "Runner"})
    {:ok, executor} = Executors.authenticate(token)
    executor = Map.put(executor, "capabilities", %{"workflow_version" => 2})
    :ok = Executors.bind(scope, executor["id"], project.id)

    {:ok, run} =
      Runs.create(scope, project.id, %{
        "title" => "Original task",
        "prompt" => "Implement the form"
      })

    {:ok, lease} = Runs.claim(executor)
    head = String.duplicate("a", 40)

    result = %{
      "repository" => "acme/app",
      "branch" => lease["snapshot"]["task_branch"],
      "base_branch" => "main",
      "commit" => head,
      "pr_url" => "https://github.com/acme/app/pull/17",
      "summary" => "Implemented the form"
    }

    Store.exec("UPDATE runs SET state='succeeded',result=$2,lease_expires_at=NULL WHERE id=$1", [
      run["id"],
      result
    ])

    run = Store.one("SELECT * FROM runs WHERE id=$1", [run["id"]])

    previous =
      Map.new(
        [:github, :openai, :provider_transport],
        &{&1, Application.get_env(:dev_orchestrator, &1)}
      )

    key_path =
      Path.join(
        System.tmp_dir!(),
        "slack-followup-key-#{System.unique_integer([:positive])}.fixture"
      )

    key = :public_key.generate_key({:rsa, 2048, 65_537})

    File.write!(
      key_path,
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    )

    File.chmod!(key_path, 0o600)

    Application.put_env(:dev_orchestrator, :github,
      app_id: "123",
      app_slug: "test-app",
      private_key_path: key_path
    )

    Application.put_env(:dev_orchestrator, :openai,
      api_key: "test-openai",
      task_model: "test-model",
      transcription_model: "test-transcription"
    )

    owner = self()

    pr = %{
      "state" => "open",
      "head" => %{
        "sha" => head,
        "ref" => result["branch"],
        "repo" => %{"full_name" => "acme/app"}
      },
      "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/app"}}
    }

    transport = fn opts ->
      case opts[:url] do
        "https://api.github.com/app/installations/123/access_tokens" ->
          response(%{"token" => "test-github-token"})

        "https://api.github.com/repos/acme/app/pulls/17" ->
          response(pr)

        "https://slack.com/api/chat.postMessage" ->
          send(owner, {:slack_post, opts[:json]})

          ts =
            cond do
              is_nil(opts[:json][:thread_ts]) -> "10.1"
              opts[:json][:blocks] -> "20.2"
              true -> "20.1"
            end

          response(%{"ok" => true, "ts" => ts})

        "https://slack.com/api/chat.update" ->
          send(owner, {:slack_update, opts[:json]})
          response(%{"ok" => true})

        "https://api.openai.com/v1/responses" ->
          send(owner, {:structured_input, Jason.decode!(opts[:json][:input])})

          response(%{
            "output" => [
              %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(@draft)}]}
            ]
          })

        "https://slack.com/api/files.info" ->
          response(%{
            "ok" => true,
            "file" => %{
              "mode" => "hosted",
              "filetype" => "wav",
              "size" => byte_size(@wav),
              "name" => "correction.wav",
              "url_private_download" => "https://files.slack.com/followup.wav"
            }
          })

        "https://files.slack.com/followup.wav" ->
          {:cont, {_, streamed}} =
            opts[:into].(
              {:data, @wav},
              {%{}, %Req.Response{status: 200, headers: %{"content-type" => ["audio/wav"]}}}
            )

          {:ok, streamed}

        "https://api.openai.com/v1/audio/transcriptions" ->
          response(%{"text" => "Move the button above the form"})

        url ->
          flunk("Unexpected provider operation: #{url}")
      end
    end

    Application.put_env(:dev_orchestrator, :provider_transport, transport)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        Application.put_env(:dev_orchestrator, key, value)
      end)

      File.rm(key_path)
    end)

    Outbox.enqueue(run, "succeeded", result)

    outbox =
      Store.one("SELECT * FROM outbox WHERE run_id=$1 AND kind='slack:succeeded'", [run["id"]])

    connection = Connections.for_project(scope.organization_id, project.id, "slack")
    assert :ok = SlackReports.deliver(outbox, connection, "slack-test-token")

    Store.exec("UPDATE slack_run_threads SET requester_slack_user_id='U1' WHERE run_id=$1", [
      run["id"]
    ])

    %{
      scope: scope,
      project: project,
      executor: executor,
      run: run,
      lease: lease,
      head: head,
      result: result,
      connection: connection,
      slack_id: slack_id,
      transport: transport,
      pr: pr
    }
  end

  test "a confirmed text adjustment resumes the same PR without another Linear issue and reports in the original thread",
       ctx do
    assert {:ok, :created} = SlackDrafts.accept(event("Ev-followup"))
    assert :processed = SlackDrafts.process_one()

    assert_receive {:structured_input,
                    %{
                      "purpose" => "pr_followup",
                      "task_context" => %{"last_result" => "Implemented the form"}
                    }}

    draft = Store.one("SELECT * FROM slack_task_drafts WHERE event_id='Ev-followup'")
    assert draft["target_run_id"] == ctx.run["id"]
    assert draft["target_commit"] == ctx.head
    assert {:error, :forbidden} = SlackDrafts.confirm(%{action(draft) | "user_id" => "U2"})

    assert {:error, :invalid_action} =
             SlackDrafts.confirm(%{action(draft) | "action_id" => "create_linear_task"})

    assert {:ok, :queued} = SlackDrafts.confirm(action(draft))
    assert {:ok, :already_handled} = SlackDrafts.confirm(action(draft))
    SlackDrafts.create_one()
    run = Store.one("SELECT * FROM runs WHERE id=$1", [ctx.run["id"]])
    assert run["state"] == "queued"
    assert run["followup_count"] == 1
    assert run["repair_count"] == 0
    assert run["executor_id"] == ctx.executor["id"]
    assert run["snapshot"]["continuation"]["kind"] == "slack_followup"
    assert run["snapshot"]["task_branch"] == ctx.lease["snapshot"]["task_branch"]
    assert run["snapshot"]["resume_candidate"]["pr_url"] == ctx.result["pr_url"]
    assert Store.one("SELECT count(*) AS n FROM runs")["n"] == 1

    assert Store.one(
             "SELECT count(*) AS n FROM slack_task_drafts WHERE linear_issue_id IS NOT NULL"
           )["n"] == 0

    assert {:ok, resumed} = Runs.claim(ctx.executor)
    assert resumed["generation"] > ctx.lease["generation"]
    result = %{ctx.result | "commit" => String.duplicate("b", 40), "summary" => "Updated button"}
    Store.exec("UPDATE runs SET state='succeeded',result=$2 WHERE id=$1", [run["id"], result])
    updated = Store.one("SELECT * FROM runs WHERE id=$1", [run["id"]])
    Outbox.enqueue(updated, "succeeded", result)

    report =
      Store.one("SELECT * FROM outbox WHERE run_id=$1 AND kind='slack:succeeded:followup1'", [
        run["id"]
      ])

    assert :ok = SlackReports.deliver(report, ctx.connection, "slack-test-token")

    assert_receive {:slack_post,
                    %{thread_ts: "10.1", text: "Original task\nResult: succeeded\nUpdated button"}}

    assert {:ok, :created} = SlackDrafts.accept(event("Ev-followup-next"))
    assert {:ok, :duplicate} = SlackDrafts.accept(event("Ev-followup"))
  end

  test "audio plus a quick text correction retains the audio and rejects other users and unknown threads",
       _ctx do
    assert {:ok, :ignored} =
             SlackDrafts.accept(%{event("Ev-other") | "requester_slack_user_id" => "U2"})

    assert {:ok, :ignored} = SlackDrafts.accept(%{event("Ev-unknown") | "thread_ts" => "99.1"})

    assert {:ok, :ignored} =
             SlackDrafts.accept(%{event("Ev-wrong-workspace") | "workspace_id" => "T2"})

    assert {:ok, :created} =
             SlackDrafts.accept(%{event("Ev-audio") | "file_ids" => ["F1"], "text" => ""})

    assert {:ok, :revised} =
             SlackDrafts.accept(%{
               event("Ev-text-correction")
               | "text" => "Keep the existing colors"
             })

    draft = Store.one("SELECT * FROM slack_task_drafts WHERE event_id='Ev-audio'")
    assert draft["revision"] == 2
    assert draft["file_id"] == "F1"

    assert {:ok, :duplicate} =
             SlackDrafts.accept(%{event("Ev-audio") | "file_ids" => ["F1"], "text" => ""})

    assert :processed = SlackDrafts.process_one()

    assert_receive {:structured_input,
                    %{
                      "purpose" => "pr_followup",
                      "transcript" => "Move the button above the form"
                    }}

    assert {:error, :stale_draft} = SlackDrafts.confirm(%{action(draft) | "revision" => 1})
  end

  test "a PR closed after proposal cannot enqueue or create a replacement task", ctx do
    prepared = prepare("Ev-closed")
    assert {:ok, :queued} = SlackDrafts.confirm(action(prepared))

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      if opts[:url] == "https://api.github.com/repos/acme/app/pulls/17",
        do: response(%{ctx.pr | "state" => "closed"}),
        else: ctx.transport.(opts)
    end)

    SlackDrafts.create_one()

    assert Store.one("SELECT state FROM runs WHERE id=$1", [ctx.run["id"]])["state"] ==
             "succeeded"

    assert Store.one("SELECT state,error_category FROM slack_task_drafts WHERE id=$1", [
             prepared["id"]
           ]) == %{"state" => "failed", "error_category" => "pr_closed"}

    SlackDrafts.update_terminal_messages()

    assert_receive {:slack_update, %{text: "The pull request is closed or merged." <> _}}
  end

  test "a changed delivered head or revoked binding invalidates an approved follow-up", ctx do
    prepared = prepare("Ev-stale")
    assert {:ok, :queued} = SlackDrafts.confirm(action(prepared))

    Store.exec(
      "UPDATE runs SET result=jsonb_set(result,'{commit}',to_jsonb($2::text)) WHERE id=$1",
      [ctx.run["id"], String.duplicate("b", 40)]
    )

    SlackDrafts.create_one()

    assert Store.one("SELECT error_category FROM slack_task_drafts WHERE id=$1", [prepared["id"]])[
             "error_category"
           ] == "pr_changed"

    Store.exec("UPDATE runs SET result=$2 WHERE id=$1", [ctx.run["id"], ctx.result])
    prepared = prepare("Ev-revoked")
    assert {:ok, :queued} = SlackDrafts.confirm(action(prepared))
    Store.exec("DELETE FROM executor_bindings WHERE executor_id=$1", [ctx.executor["id"]])
    SlackDrafts.create_one()

    assert Store.one("SELECT followup_count FROM runs WHERE id=$1", [ctx.run["id"]])[
             "followup_count"
           ] == 0

    assert Store.one("SELECT error_category FROM slack_task_drafts WHERE id=$1", [prepared["id"]])[
             "error_category"
           ] == "executor_unavailable"
  end

  defp prepare(id) do
    assert {:ok, :created} = SlackDrafts.accept(event(id))
    assert :processed = SlackDrafts.process_one()
    Store.one("SELECT * FROM slack_task_drafts WHERE event_id=$1", [id])
  end

  defp connect(scope, project, provider, external_id, secret) do
    id = Store.id()

    encrypted =
      SecretBox.seal(
        Jason.encode!(secret),
        scope.organization_id,
        Application.fetch_env!(:dev_orchestrator, :encryption_key)
      )

    Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,$3,$3,$4,$5)",
      [id, scope.organization_id, provider, encrypted, external_id]
    )

    Store.exec(
      "INSERT INTO connection_grants(organization_id,project_id,connection_id) VALUES($1,$2,$3)",
      [scope.organization_id, project, id]
    )

    id
  end

  defp event(id),
    do: %{
      "event_id" => id,
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "requester_slack_user_id" => "U1",
      "message_ts" => "11.1",
      "thread_ts" => "10.1",
      "text" => "Move the button",
      "file_ids" => []
    }

  defp action(draft),
    do: %{
      "action_id" => "apply_pr_followup",
      "draft_id" => draft["id"],
      "revision" => draft["revision"],
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "user_id" => "U1",
      "message_ts" => "20.2"
    }

  defp response(body), do: {:ok, %{status: 200, body: body}}
end
