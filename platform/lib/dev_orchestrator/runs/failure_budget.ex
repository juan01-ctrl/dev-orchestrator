defmodule DevOrchestrator.Runs.FailureBudget do
  @moduledoc "Persistent, secret-free counters for equivalent task errors."
  def record(history, %{"fingerprint" => fingerprint} = error) when is_binary(fingerprint) do
    key =
      if Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
        do: fingerprint,
        else: "invalid-error-fingerprint"

    occurrences = if error["occurrences"] in [1, 2, 3], do: error["occurrences"], else: 1
    count = min(Map.get(history, key, 0) + occurrences, 3)
    {Map.put(history, key, count), count >= 3}
  end

  def record(history, _), do: record(history, %{"fingerprint" => "invalid-error-fingerprint"})
end
