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
end
