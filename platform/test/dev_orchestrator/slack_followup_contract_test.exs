defmodule DevOrchestrator.SlackFollowupContractTest do
  use ExUnit.Case, async: false
  alias DevOrchestrator.Connections.Slack
  alias DevOrchestrator.Intake.TaskDraft

  setup do
    previous = Application.get_env(:dev_orchestrator, :provider_transport)
    openai = Application.get_env(:dev_orchestrator, :openai)

    on_exit(fn ->
      Application.put_env(:dev_orchestrator, :provider_transport, previous)
      Application.put_env(:dev_orchestrator, :openai, openai)
    end)

    :ok
  end

  test "structuring receives bounded existing task context without retranscribing text" do
    Application.put_env(:dev_orchestrator, :openai, api_key: "test-key", task_model: "test-model")

    draft = %{
      "title" => "Adjust",
      "context" => "Existing PR",
      "objective" => "Move button",
      "scope" => [],
      "acceptance_criteria" => [],
      "constraints_or_open_questions" => []
    }

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:url] == "https://api.openai.com/v1/responses"
      input = Jason.decode!(opts[:json][:input])
      assert input["purpose"] == "pr_followup"
      assert input["task_context"]["title"] == "Existing task"
      assert String.length(input["task_context"]["original_request"]) == 4_000
      assert input["message"] == "Move button"

      {:ok,
       %{
         status: 200,
         body: %{
           "output" => [
             %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(draft)}]}
           ]
         }
       }}
    end)

    assert {:ok, ^draft} =
             DevOrchestrator.Connections.OpenAI.structure_task(%{
               purpose: "pr_followup",
               message: "Move button",
               task_context: %{
                 "title" => "Existing task",
                 "original_request" => String.duplicate("x", 8_000)
               }
             })
  end

  test "report delivery returns the acknowledged root and keeps ambiguous sends ambiguous" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn _ ->
      {:ok, %{status: 200, body: %{"ok" => true, "ts" => "1.2"}}}
    end)

    assert {:ok, "1.2"} = Slack.deliver_with_receipt("test-token", %{channel: "C1", text: "Done"})

    Application.put_env(:dev_orchestrator, :provider_transport, fn _ ->
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end)

    assert :ambiguous = Slack.deliver_with_receipt("test-token", %{})
    Application.put_env(:dev_orchestrator, :provider_transport, fn _ -> {:error, :timeout} end)
    assert :ambiguous = Slack.deliver_with_receipt("test-token", %{})

    Application.put_env(:dev_orchestrator, :provider_transport, fn _ ->
      {:ok, %{status: 200, body: %{"ok" => false}}}
    end)

    assert :rejected = Slack.deliver_with_receipt("test-token", %{})
  end

  test "PR proposals have distinct versioned approval actions, not Linear creation buttons" do
    draft = %{
      "title" => "Move the button",
      "context" => "Existing PR",
      "objective" => "Fix placement",
      "scope" => ["Move button"],
      "acceptance_criteria" => ["Button is above form"],
      "constraints_or_open_questions" => []
    }

    blocks = TaskDraft.to_slack_blocks(draft, "draft-1", 2, :pr_followup)
    actions = List.last(blocks).elements
    assert Enum.map(actions, & &1.action_id) == ["apply_pr_followup", "cancel_pr_followup"]
    assert hd(actions).value == "draft-1:2"
    assert hd(actions).text.text == "Apply to PR"

    payload = %{
      "type" => "block_actions",
      "team" => %{"id" => "T1"},
      "channel" => %{"id" => "C1"},
      "user" => %{"id" => "U1"},
      "message" => %{"ts" => "2.3"},
      "actions" => [%{"action_id" => "apply_pr_followup", "value" => "draft-1:2"}]
    }

    assert {:ok, %{"action_id" => "apply_pr_followup", "revision" => 2}} =
             Slack.normalize_action(payload)
  end

  test "follow-up eligibility freezes the delivered lifecycle and head and requires a live executor" do
    alias DevOrchestrator.Runs.SlackFollowups

    run = %{
      "state" => "succeeded",
      "mode" => "implement",
      "lifecycle" => 1,
      "snapshot" => %{"workflow_version" => 2, "repository" => "acme/app"},
      "result" => %{
        "commit" => String.duplicate("a", 40),
        "pr_url" => "https://github.com/acme/app/pull/1"
      },
      "updated_at" => DateTime.utc_now(),
      "executor_available" => true,
      "current_repository" => "acme/app"
    }

    row = %{"target_lifecycle" => 1, "target_commit" => String.duplicate("a", 40)}
    assert :ok = SlackFollowups.eligible(run, row)
    assert {:error, :pr_changed} = SlackFollowups.eligible(%{run | "lifecycle" => 2}, row)

    assert {:error, :pr_changed} =
             SlackFollowups.eligible(
               put_in(run, ["result", "commit"], String.duplicate("b", 40)),
               row
             )

    assert {:error, :pr_busy} = SlackFollowups.eligible(%{run | "state" => "running"}, row)

    assert {:error, :executor_unavailable} =
             SlackFollowups.eligible(%{run | "executor_available" => false}, row)

    assert {:error, :context_expired} =
             SlackFollowups.eligible(
               %{run | "updated_at" => DateTime.add(DateTime.utc_now(), -8 * 86_400)},
               row
             )
  end
end
