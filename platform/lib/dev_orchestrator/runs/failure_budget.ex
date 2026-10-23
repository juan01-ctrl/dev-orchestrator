defmodule DevOrchestrator.Runs.FailureBudget do
  @moduledoc "Persistent, secret-free counters for equivalent task errors."

  def deadline(run, now_ms) do
    previous = run["snapshot"] || %{}

    if previous["execution_lifecycle"] == run["lifecycle"] and
         is_integer(previous["execution_deadline_at_ms"]),
       do: previous["execution_deadline_at_ms"],
       else: now_ms + 20 * 60_000
  end

  def record(history, %{"fingerprint" => fingerprint} = error) when is_binary(fingerprint) do
    key =
      if Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
        do: fingerprint,
        else: "invalid-error-fingerprint"

    occurrences = if error["occurrences"] in [1, 2, 3], do: error["occurrences"], else: 1
    count = min(Map.get(history, key, 0) + occurrences, 3)
    history = Map.put(history, key, count)
    {history, Enum.sum(Map.values(history)) >= 3}
  end

  def record(history, _), do: record(history, %{"fingerprint" => "invalid-error-fingerprint"})
end
