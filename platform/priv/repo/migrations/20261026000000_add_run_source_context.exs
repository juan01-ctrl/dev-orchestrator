defmodule DevOrchestrator.Repo.Migrations.AddRunSourceContext do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE runs ADD COLUMN source_context jsonb NOT NULL DEFAULT '{}'")
  end

  def down do
    execute("ALTER TABLE runs DROP COLUMN source_context")
  end
end
