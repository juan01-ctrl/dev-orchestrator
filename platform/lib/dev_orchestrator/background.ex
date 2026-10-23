defmodule DevOrchestrator.Background do
  use GenServer
  require Logger
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(state) do
    Process.send_after(self(), :tick, 5_000)
    Process.send_after(self(), :reconcile_linear, 3_000)

    {:ok,
     Map.merge(
       %{last_linear_reconcile: 0, maintenance_running: false, reconciliation_running: false},
       if(is_map(state), do: state, else: %{})
     )}
  end

  def handle_info(:tick, %{maintenance_running: false} = state) do
    owner = self()

    Task.start(fn ->
      try do
        DevOrchestrator.Runs.expire_leases()
        DevOrchestrator.Intake.Inbox.process_one()
        DevOrchestrator.Delivery.Worker.drain()
      rescue
        _ -> Logger.warning("Background operation failed; retained durable state for recovery.")
      after
        send(owner, :maintenance_finished)
      end
    end)

    Process.send_after(self(), :tick, 5_000)
    {:noreply, %{state | maintenance_running: true}}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 5_000)
    {:noreply, state}
  end

  def handle_info(:maintenance_finished, state),
    do: {:noreply, %{state | maintenance_running: false}}

  def handle_info(:reconcile_linear, %{reconciliation_running: false} = state) do
    owner = self()

    Task.start(fn ->
      try do
        DevOrchestrator.Intake.Reconciler.tick_all()
      rescue
        _ -> Logger.warning("Linear reconciliation failed; the saved cursor will be retried.")
      after
        send(owner, :reconciliation_finished)
      end
    end)

    Process.send_after(self(), :reconcile_linear, 60_000)

    {:noreply,
     %{
       state
       | reconciliation_running: true,
         last_linear_reconcile: System.monotonic_time(:millisecond)
     }}
  end

  def handle_info(:reconcile_linear, state) do
    Process.send_after(self(), :reconcile_linear, 60_000)
    {:noreply, state}
  end

  def handle_info(:reconciliation_finished, state),
    do: {:noreply, %{state | reconciliation_running: false}}
end