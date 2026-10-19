defmodule DevOrchestrator.Application do
  use Application

  def start(_type, _args) do
    children = [
      DevOrchestrator.Repo,
      {Phoenix.PubSub, name: DevOrchestrator.PubSub},
      DevOrchestrator.RateLimit,
      DevOrchestratorWeb.Endpoint
    ]

    children =
      if Application.get_env(:dev_orchestrator, :background_workers, false),
        do: children ++ [DevOrchestrator.Background],
        else: children

    Supervisor.start_link(children, strategy: :one_for_one, name: DevOrchestrator.Supervisor)
  end

  def config_change(changed, _new, removed),
    do: DevOrchestratorWeb.Endpoint.config_change(changed, removed)
end
