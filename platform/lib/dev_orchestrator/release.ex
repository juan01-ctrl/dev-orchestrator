defmodule DevOrchestrator.Release do
  @moduledoc "Run migrations explicitly before starting a release."
  def migrate do
    Application.load(:dev_orchestrator)

    for repo <- Application.fetch_env!(:dev_orchestrator, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
