defmodule DevOrchestrator.Repo.Migrations.CreateLinearWebhookInbox do
  use Ecto.Migration

  def change do
    create table(:webhook_inbox, primary_key: false) do
      add :id, :text, primary_key: true
      add :provider, :text, null: false
      add :delivery_id, :text, null: false
      add :organization_external_id, :text, null: false
      add :event, :map, null: false
      add :state, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :claimed_at, :utc_datetime_usec
      add :last_error_category, :text
      add :received_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :processed_at, :utc_datetime_usec
    end

    create unique_index(:webhook_inbox, [:provider, :delivery_id])
    create index(:webhook_inbox, [:state, :next_attempt_at, :received_at])
  end
end
