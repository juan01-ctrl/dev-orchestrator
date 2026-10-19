defmodule DevOrchestrator.RateLimit do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(state), do: {:ok, state}
  def check(key, limit \\ 20), do: GenServer.call(__MODULE__, {:check, key, limit})

  def handle_call({:check, key, limit}, _from, state) do
    now = System.monotonic_time(:second)
    state = Map.reject(state, fn {_key, {_count, expiry}} -> expiry <= now end)
    {count, expiry} = Map.get(state, key, {0, now + 60})

    {:reply, if(count < limit, do: :ok, else: {:error, :rate_limited}),
     Map.put(state, key, {count + 1, expiry})}
  end
end
