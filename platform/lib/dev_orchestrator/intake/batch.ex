defmodule DevOrchestrator.Intake.Batch do
  @moduledoc "Apply idempotent intake changes without discarding returned failures."

  def apply(items, operation) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case operation.(item) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_application_result}}
      end
    end)
  end
end
