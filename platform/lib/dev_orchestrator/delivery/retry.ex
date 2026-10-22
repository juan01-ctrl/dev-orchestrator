defmodule DevOrchestrator.Delivery.Retry do
  @moduledoc false

  @retry_delays [5, 30, 120, 600]

  def result(attempts, :ok), do: %{state: "sent", delay_seconds: nil, category: nil}
  def result(_attempts, :not_configured), do: %{state: "not_configured", delay_seconds: nil, category: nil}
  def result(_attempts, :ambiguous), do: %{state: "ambiguous", delay_seconds: nil, category: "delivery_ambiguous"}

  def result(attempts, :rejected) when is_integer(attempts) and attempts > 0 do
    case Enum.at(@retry_delays, attempts - 1) do
      nil -> %{state: "failed", delay_seconds: nil, category: "provider_rejected"}
      delay -> %{state: "pending", delay_seconds: delay, category: "provider_rejected"}
    end
  end

  def result(_, _), do: %{state: "failed", delay_seconds: nil, category: "delivery_failed"}
end
