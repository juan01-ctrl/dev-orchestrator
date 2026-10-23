defmodule DevOrchestrator.Repo.Migrations.HardenOutboxRetries do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE outbox ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT now()")
    execute("ALTER TABLE outbox ADD COLUMN last_error_category text")
    execute("CREATE INDEX outbox_due ON outbox(next_attempt_at,created_at) WHERE state='pending'")
  end

  def down do
    execute("DROP INDEX outbox_due")
    execute("ALTER TABLE outbox DROP COLUMN last_error_category")
    execute("ALTER TABLE outbox DROP COLUMN next_attempt_at")
  end
end
