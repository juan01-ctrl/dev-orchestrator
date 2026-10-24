defmodule DevOrchestrator.BatchTest do
  use ExUnit.Case, async: true

  test "a returned application failure is propagated instead of acknowledging the batch" do
    assert {:error, :invalid_issue} =
             DevOrchestrator.Intake.Batch.apply([1, 2, 3], fn item ->
               send(self(), {:applied, item})
               if item == 2, do: {:error, :invalid_issue}, else: {:ok, %{result: :created}}
             end)

    assert_receive {:applied, 1}
    assert_receive {:applied, 2}
    refute_receive {:applied, 3}
    assert :ok = DevOrchestrator.Intake.Batch.apply([], fn _ -> flunk("empty batch") end)
  end
end
