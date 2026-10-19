defmodule DevOrchestrator.FailureBudgetTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Runs.FailureBudget

  test "three equivalent native command failures exhaust the task budget immediately" do
    {_, exhausted?} =
      FailureBudget.record(%{}, %{"fingerprint" => String.duplicate("a", 64), "occurrences" => 3})

    assert exhausted?
  end

  test "third equivalent error cancels while distinct errors have independent budgets" do
    error = %{"fingerprint" => String.duplicate("a", 64), "category" => "publication_failed"}
    {history, false} = FailureBudget.record(%{}, error)
    {history, false} = FailureBudget.record(history, error)
    {_history, true} = FailureBudget.record(history, error)

    {_history, false} =
      FailureBudget.record(history, %{error | "fingerprint" => String.duplicate("b", 64)})

    refute inspect(history) =~ "token-private"
  end
end
