defmodule DevOrchestrator.EvalFormatter do
  @moduledoc false
  use GenServer

  def init(_opts), do: {:ok, nil}

  def handle_cast({:test_finished, test}, state) do
    status =
      case test.state do
        nil -> "passed"
        {:skipped, _} -> "skipped"
        {:excluded, _} -> "skipped"
        _ -> "failed"
      end

    record = %{
      name: inspect(test.module) <> "::" <> Atom.to_string(test.name),
      status: status,
      duration_ms: (test.time || 0) / 1_000
    }

    IO.puts("EVAL_RECORD " <> Jason.encode!(record))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
