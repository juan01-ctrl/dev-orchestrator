defmodule DevOrchestrator.DeliveryRetryTest do
  use ExUnit.Case, async: true

  alias DevOrchestrator.Delivery.Retry

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
end
