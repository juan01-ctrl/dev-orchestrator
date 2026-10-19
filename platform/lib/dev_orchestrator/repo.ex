defmodule DevOrchestrator.Repo do
  use Ecto.Repo, otp_app: :dev_orchestrator, adapter: Ecto.Adapters.Postgres
end
