defmodule DevOrchestrator.FailureBudgetTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Runs.FailureBudget

  test "the execution deadline survives automatic retries but resets for a new lifecycle" do
    deadline = FailureBudget.deadline(%{"lifecycle" => 1}, 1_000)

    run = %{
      "lifecycle" => 1,
      "snapshot" => %{"execution_lifecycle" => 1, "execution_deadline_at_ms" => deadline}
    }

    assert FailureBudget.deadline(run, 50_000) == deadline
    assert FailureBudget.deadline(Map.put(run, "lifecycle", 2), 50_000) == 1_250_000
  end

  test "three equivalent native command failures exhaust the task budget immediately" do
    {_, exhausted?} =
      FailureBudget.record(%{}, %{"fingerprint" => String.duplicate("a", 64), "occurrences" => 3})

    assert exhausted?
  end

  test "three failures exhaust the lifecycle even if the error changes" do
    error = %{"fingerprint" => String.duplicate("a", 64), "category" => "publication_failed"}
    {history, false} = FailureBudget.record(%{}, error)
    {history, false} = FailureBudget.record(history, error)
    {_history, true} = FailureBudget.record(history, error)

    {_history, true} =
      FailureBudget.record(history, %{error | "fingerprint" => String.duplicate("b", 64)})

    refute inspect(history) =~ "token-private"
  end
end
