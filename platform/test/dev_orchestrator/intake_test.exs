defmodule DevOrchestrator.IntakeTest do
  use ExUnit.Case, async: true
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
end
