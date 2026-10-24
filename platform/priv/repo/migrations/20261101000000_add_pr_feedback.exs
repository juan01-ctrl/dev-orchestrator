defmodule DevOrchestrator.Repo.Migrations.AddPRFeedback do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add(:pr_feedback_enabled, :boolean, null: false, default: false)
    end

    alter table(:runs) do
      add(:repair_count, :integer, null: false, default: 0)
      add(:pr_observation, :map)
    end

    create table(:pr_feedback_receipts, primary_key: false) do
      add(:organization_id, :text, null: false)
      add(:run_id, :text, primary_key: true)
      add(:head, :text, primary_key: true)
      add(:fingerprint, :text, primary_key: true)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    execute(
      "ALTER TABLE pr_feedback_receipts ADD CONSTRAINT pr_feedback_run_scope FOREIGN KEY(organization_id,run_id) REFERENCES runs(organization_id,id) ON DELETE CASCADE",
      "ALTER TABLE pr_feedback_receipts DROP CONSTRAINT pr_feedback_run_scope"
    )
  end
end
