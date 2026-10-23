defmodule DevOrchestrator.DeliveryRetryTest do
  use ExUnit.Case, async: true

  alias DevOrchestrator.Delivery.Retry
  alias DevOrchestrator.Connections.Linear

  test "known provider rejections use bounded backoff and eventually dead-letter" do
    assert Retry.result(1, :rejected).delay_seconds == 5
    assert Retry.result(2, :rejected).delay_seconds == 30
    assert Retry.result(4, :rejected).delay_seconds == 600
    assert Retry.result(5, :rejected).state == "failed"
  end

  test "ambiguous sends are not retried automatically" do
    assert Retry.result(1, :ambiguous).state == "ambiguous"
    assert Retry.result(1, :ambiguous).delay_seconds == nil
  end

  test "extracts the Linear issue id without its activation suffix" do
    issue_id = "b5821c01-c4fa-43fd-bdb8-07e02c59b765"

    assert Linear.issue_id_from_source_key("linear:" <> issue_id <> ":3") == {:ok, issue_id}
    assert Linear.issue_id_from_source_key("linear:" <> issue_id <> ":0") == :error
    assert Linear.issue_id_from_source_key("linear:" <> issue_id <> ":3:extra") == :error
    assert Linear.issue_id_from_source_key("manual:" <> issue_id <> ":3") == :error
  end
end
