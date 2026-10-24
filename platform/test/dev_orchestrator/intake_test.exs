defmodule DevOrchestrator.IntakeTest do
  use ExUnit.Case, async: true

  test "text revisions retain an accepted audio correction until it is incorporated" do
    alias DevOrchestrator.Intake.SlackDrafts

    assert SlackDrafts.revision_file_id(%{"state" => "received", "file_id" => "F-AUDIO"}, nil) ==
             "F-AUDIO"

    assert SlackDrafts.revision_file_id(%{"state" => "processing", "file_id" => "F-AUDIO"}, nil) ==
             "F-AUDIO"

    assert SlackDrafts.revision_file_id(
             %{"state" => "awaiting_confirmation", "file_id" => "F-AUDIO"},
             nil
           ) == nil
  end

  alias DevOrchestrator.Intake.Inbox

  test "generic Linear deliveries normalize to minimal provider-independent routing data" do
    body =
      Jason.encode!(%{
        "type" => "Issue",
        "action" => "update",
        "organizationId" => "org-1",
        "webhookTimestamp" => 1_700_000_000_000,
        "data" => %{"id" => "issue-1", "title" => "must not persist"}
      })

    assert {:ok, "org-1", %{"type" => "Issue", "action" => "update", "issue_id" => "issue-1"},
            "delivery-1"} =
             Inbox.normalize_linear(%{"linear-delivery" => "delivery-1"}, body)
  end

  test "unsupported events, missing delivery IDs, malformed bodies, and oversized payloads fail closed" do
    assert {:error, :unsupported_event} =
             Inbox.normalize_linear(
               %{"linear-delivery" => "delivery-1"},
               ~s({"type":"Project","action":"update"})
             )

    assert {:error, :invalid_delivery} =
             Inbox.normalize_linear(
               %{},
               ~s({"type":"Issue","action":"create","organizationId":"org","data":{"id":"issue"}})
             )

    assert {:error, :invalid_payload} =
             Inbox.normalize_linear(%{"linear-delivery" => "x"}, "not json")

    assert {:error, :payload_too_large} =
             Inbox.normalize_linear(%{"linear-delivery" => "x"}, :binary.copy("x", 65_537))
  end

  test "Slack mention normalization retains only bounded routing data" do
    event = %{
      "type" => "event_callback",
      "event_id" => "Ev-1",
      "team_id" => "T1",
      "event" => %{
        "type" => "app_mention",
        "user" => "U1",
        "channel" => "C1",
        "ts" => "123.456",
        "text" => "<@BOT> please fix this",
        "files" => [%{"id" => "F1", "url_private" => "https://secret.example/file"}]
      }
    }

    assert {:ok, normalized} = DevOrchestrator.Intake.Slack.normalize_event(event)
    assert normalized["workspace_id"] == "T1"
    assert normalized["channel_id"] == "C1"
    assert normalized["requester_slack_user_id"] == "U1"
    assert normalized["thread_ts"] == "123.456"
    assert normalized["text"] == "please fix this"
    assert normalized["file_ids"] == ["F1"]
    refute inspect(normalized) =~ "url_private"
    refute inspect(normalized) =~ "secret.example"
  end

  test "Slack bot messages and unsupported events are ignored" do
    assert {:ignore, :bot_message} =
             DevOrchestrator.Intake.Slack.normalize_event(%{
               "type" => "event_callback",
               "event_id" => "Ev-2",
               "team_id" => "T1",
               "event" => %{"type" => "app_mention", "bot_id" => "B1"}
             })

    assert {:ignore, :unsupported_event} =
             DevOrchestrator.Intake.Slack.normalize_event(%{"type" => "url_verification"})
  end

  test "Slack task input accepts text without files and retains the audio path with optional text" do
    alias DevOrchestrator.Intake.Slack

    assert {:ok, nil} =
             Slack.task_file_id(%{"text" => "Corregir el botón de guardar", "file_ids" => []})

    assert {:ok, "F1"} = Slack.task_file_id(%{"text" => "", "file_ids" => ["F1"]})

    assert {:ok, "F1"} =
             Slack.task_file_id(%{"text" => "Para el formulario", "file_ids" => ["F1"]})

    for event <- [
          %{"text" => " \n\t", "file_ids" => []},
          %{"text" => nil, "file_ids" => []},
          %{"text" => "A task", "file_ids" => ["F1", "F2"]},
          %{"text" => "A task", "file_ids" => [""]},
          %{"text" => "A task", "file_ids" => nil}
        ] do
      assert {:error, :input_required} = Slack.task_file_id(event)
    end
  end

  test "direct-message mentions are outside the initial task intake scope" do
    assert {:ignore, :unsupported_channel} =
             DevOrchestrator.Intake.Slack.normalize_event(%{
               "type" => "event_callback",
               "event_id" => "Ev-dm",
               "team_id" => "T1",
               "event" => %{
                 "type" => "app_mention",
                 "user" => "U1",
                 "channel" => "D123",
                 "channel_type" => "im",
                 "ts" => "1.2"
               }
             })
  end

  test "Slack action normalization excludes response URLs and accepts only our button IDs" do
    payload = %{
      "type" => "block_actions",
      "team" => %{"id" => "T1"},
      "channel" => %{"id" => "C1"},
      "user" => %{"id" => "U1"},
      "message" => %{"ts" => "2.3"},
      "response_url" => "https://secret.invalid/callback",
      "actions" => [%{"action_id" => "create_linear_task", "value" => "draft-id"}]
    }

    assert {:ok, action} = DevOrchestrator.Connections.Slack.normalize_action(payload)
    assert action["draft_id"] == "draft-id"
    assert action["revision"] == 1

    assert {:ok, %{"draft_id" => "draft-id", "revision" => 3}} =
             DevOrchestrator.Connections.Slack.normalize_action(
               put_in(payload, ["actions", Access.at(0), "value"], "draft-id:3")
             )

    refute inspect(action) =~ "response_url"
    refute inspect(action) =~ "secret.invalid"

    assert {:error, :invalid_action} =
             DevOrchestrator.Connections.Slack.normalize_action(
               put_in(payload, ["actions", Access.at(0), "action_id"], "other_action")
             )
  end
end
