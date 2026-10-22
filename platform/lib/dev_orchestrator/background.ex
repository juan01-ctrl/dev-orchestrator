defmodule DevOrchestrator.Background do
  use GenServer
  require Logger
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(state) do
    Process.send_after(self(), :tick, 5_000)
    Process.send_after(self(), :reconcile_linear, 3_000)
    {:ok, Map.merge(%{last_linear_reconcile: 0}, if(is_map(state), do: state, else: %{}))}
  end

  def handle_info(:tick, state) do
    try do
      DevOrchestrator.Runs.expire_leases()
      DevOrchestrator.Intake.Inbox.process_one()
      DevOrchestrator.Delivery.Worker.drain()
    rescue
      _ -> Logger.warning("Background operation failed; retained durable state for recovery.")
    after
      Process.send_after(self(), :tick, 5_000)
    end

    {:noreply, state}
  end

  def handle_info(:reconcile_linear, state) do
    try do
      DevOrchestrator.Intake.Reconciler.tick_all()
    rescue
      _ -> Logger.warning("Linear reconciliation failed; the saved cursor will be retried.")
    after
      Process.send_after(self(), :reconcile_linear, 60_000)
    end

    {:noreply, %{state | last_linear_reconcile: System.monotonic_time(:millisecond)}}
  end
end
