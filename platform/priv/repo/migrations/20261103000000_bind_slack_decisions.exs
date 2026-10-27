defmodule DevOrchestrator.Repo.Migrations.BindSlackDecisions do
  use Ecto.Migration

  def change do
    alter table(:run_clarifications) do
      add(:slack_binding, :map)
    end
  end
end
