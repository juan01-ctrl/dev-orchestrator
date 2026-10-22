defmodule DevOrchestrator.Background do
  use GenServer
  require Logger
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(state) do
    Process.send_after(self(), :tick, 5_000)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    try do
      DevOrchestrator.Runs.expire_leases()
      DevOrchestrator.Intake.Inbox.process_one()
      DevOrchestrator.Delivery.Worker.tick()
    rescue
      _ -> Logger.warning("Background operation failed; retained durable state for recovery.")
    after
      Process.send_after(self(), :tick, 5_000)
    end

    {:noreply, state}
  end
end
