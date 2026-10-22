defmodule DevOrchestrator.Repo.Migrations.CreateLinearReconciliationCursors do
  use Ecto.Migration

  def change do
    create table(:linear_reconciliation_cursors, primary_key: false) do
      add(:connection_id, references(:connections, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:updated_at_cursor, :utc_datetime_usec)
      add(:page_cursor, :text)
      add(:last_success_at, :utc_datetime_usec)
      add(:last_error_category, :text)
    end
  end
end
