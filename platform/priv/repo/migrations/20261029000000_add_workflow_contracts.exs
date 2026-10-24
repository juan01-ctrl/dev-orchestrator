defmodule DevOrchestrator.Repo.Migrations.AddWorkflowContracts do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add(:mode, :text, null: false, default: "implement")
    end

    create(constraint(:runs, :runs_mode_check, check: "mode IN ('implement','investigate')"))

    alter table(:linear_reconciliation_cursors) do
      add(:scan_updated_at_cursor, :utc_datetime_usec)
    end
  end
end
