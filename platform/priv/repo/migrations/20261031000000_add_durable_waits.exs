defmodule DevOrchestrator.Repo.Migrations.AddDurableWaits do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE runs DROP CONSTRAINT runs_state_check")

    execute(
      "ALTER TABLE runs ADD CONSTRAINT runs_state_check CHECK(state IN ('queued','leased','running','waiting_for_executor','awaiting_input','blocked','succeeded','failed','cancelled'))"
    )
  end

  def down do
    execute("ALTER TABLE runs DROP CONSTRAINT runs_state_check")

    execute(
      "ALTER TABLE runs ADD CONSTRAINT runs_state_check CHECK(state IN ('queued','leased','running','waiting_for_executor','blocked','succeeded','failed','cancelled'))"
    )
  end
end
