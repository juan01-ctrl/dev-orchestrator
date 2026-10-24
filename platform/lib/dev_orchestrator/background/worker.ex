defmodule DevOrchestrator.Background.Worker do
  use GenServer
  require Logger

  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :id)}, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    Process.flag(:trap_exit, true)
    state = Map.new(opts) |> Map.put(:task, nil) |> Map.put_new(:timeout, 300_000)
    Process.send_after(self(), :tick, Keyword.get(opts, :initial_delay, 0))
    {:ok, state}
  end

  def handle_info(:tick, %{task: nil} = state) do
    task = Task.Supervisor.async(state.task_supervisor, state.operation)
    timer = Process.send_after(self(), {:job_timeout, task.ref}, state.timeout)
    {:noreply, %{state | task: {task, timer}}}
  end

  def handle_info({ref, _result}, %{task: {%Task{ref: ref}, timer}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)
    {:noreply, schedule(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{task: {%Task{ref: ref}, timer}} = state
      ) do
    Process.cancel_timer(timer)
    Logger.warning("Background job exited; retained durable state. worker=#{state.id}")
    {:noreply, schedule(state)}
  end

  def handle_info({:job_timeout, ref}, %{task: {%Task{ref: ref} = task, _}} = state) do
    Task.shutdown(task, :brutal_kill)
    Logger.warning("Background job timed out; retained durable state. worker=#{state.id}")
    {:noreply, schedule(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, %{task: {%Task{} = task, _}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp schedule(state) do
    Process.send_after(self(), :tick, state.interval)
    %{state | task: nil}
  end
end
