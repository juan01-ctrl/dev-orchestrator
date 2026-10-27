defmodule DevOrchestrator.BackgroundWorkerTest do
  use ExUnit.Case, async: true

  test "killing a worker kills its owned job before restarted work overlaps" do
    supervisor = start_supervised!({Task.Supervisor, []})
    owner = self()

    worker =
      start_supervised!(
        {DevOrchestrator.Background.Worker,
         id: :owned,
         task_supervisor: supervisor,
         interval: 10,
         operation: fn ->
           send(owner, {:job, self()})
           Process.sleep(:infinity)
         end}
      )

    assert_receive {:job, job}
    ref = Process.monitor(job)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^job, _}, 500
    assert_receive {:job, replacement}, 500
    assert replacement != job
    refute Process.alive?(job)
  end

  test "independent jobs continue when another provider job stalls or exits" do
    supervisor = start_supervised!({Task.Supervisor, []})
    owner = self()

    slow =
      start_supervised!(
        {DevOrchestrator.Background.Worker,
         id: :slow,
         task_supervisor: supervisor,
         interval: 10,
         timeout: 30,
         operation: fn ->
           send(owner, :slow_started)
           Process.sleep(:infinity)
         end}
      )

    fast =
      start_supervised!(
        {DevOrchestrator.Background.Worker,
         id: :fast,
         task_supervisor: supervisor,
         interval: 10,
         timeout: 100,
         operation: fn -> send(owner, :swept) end}
      )

    # Assert eventual recovery without treating a busy scheduler as a 100ms SLA.
    assert_receive :slow_started, 1_000
    assert_receive :swept, 1_000
    assert_receive :swept, 1_000
    assert_receive :slow_started, 1_000
    assert Process.alive?(slow)
    assert Process.alive?(fast)
  end
end
