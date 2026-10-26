defmodule DevOrchestrator.WebhookTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Intake.Signature

  test "signature and timestamp both authenticate the exact Linear body" do
    body = ~s({"webhookTimestamp":1700000000000,"data":{"id":"issue-1"}})
    signature = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode16(case: :lower)

    assert Signature.valid_linear?(
             body,
             signature,
             "secret",
             1_700_000_000_000,
             1_700_000_000_000
           )

    refute Signature.valid_linear?(
             body <> " ",
             signature,
             "secret",
             1_700_000_000_000,
             1_700_000_000_000
           )

    refute Signature.valid_linear?(
             body,
             signature,
             "secret",
             1_700_000_000_000,
             1_700_000_120_000
           )

    refute Signature.valid_linear?(body, signature, nil, 1_700_000_000_000, 1_700_000_000_000)
  end

  test "Slack signatures authenticate the exact body within a five-minute window" do
    body = ~s({"event_id":"Ev-1"})
    timestamp = "1700000000"
    base = "v0:" <> timestamp <> ":" <> body

    signature =
      "v0=" <> (:crypto.mac(:hmac, :sha256, "secret", base) |> Base.encode16(case: :lower))

    assert Signature.valid_slack?(body, signature, timestamp, "secret", 1_700_000_000)
    refute Signature.valid_slack?(body <> " ", signature, timestamp, "secret", 1_700_000_000)
    refute Signature.valid_slack?(body, signature, timestamp, "secret", 1_700_000_301)
    refute Signature.valid_slack?(body, "v0=bad", timestamp, "secret", 1_700_000_000)
    refute Signature.valid_slack?(body, signature, "not-a-time", "secret", 1_700_000_000)
  end
end
