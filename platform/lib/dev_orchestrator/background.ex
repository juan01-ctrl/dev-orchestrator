defmodule DevOrchestrator.Background do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    jobs = [
      {:leases, 5_000, &DevOrchestrator.Runs.expire_leases/0},
      {:inbox, 1_000, &DevOrchestrator.Intake.Inbox.process_one/0},
      {:slack_drafts, 1_000, &DevOrchestrator.Intake.SlackDrafts.process_one/0},
      {:slack_creations, 1_000, &DevOrchestrator.Intake.SlackDrafts.create_one/0},
      {:slack_expiry, 5_000, &DevOrchestrator.Intake.SlackDrafts.expire/0},
      {:outbox, 1_000, &DevOrchestrator.Delivery.Worker.drain/0},
      {:reconciliation, 60_000, &DevOrchestrator.Intake.Reconciler.tick_all/0},
      {:pr_feedback, 60_000, &DevOrchestrator.Runs.PRObserver.tick/0}
    ]

    children =
      [{Task.Supervisor, name: DevOrchestrator.BackgroundTasks}] ++
        Enum.map(jobs, fn {id, interval, operation} ->
          {DevOrchestrator.Background.Worker,
           id: id,
           interval: interval,
           initial_delay: 3_000,
           task_supervisor: DevOrchestrator.BackgroundTasks,
           operation: operation}
        end)

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
