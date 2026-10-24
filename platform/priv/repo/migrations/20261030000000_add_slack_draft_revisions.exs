defmodule DevOrchestrator.Repo.Migrations.AddSlackDraftRevisions do
  use Ecto.Migration

  def change do
    alter table(:slack_task_drafts) do
      add(:revision, :integer, null: false, default: 1)
    end

    create table(:slack_draft_inputs, primary_key: false) do
      add(:event_id, :text, primary_key: true)

      add(:draft_id, references(:slack_task_drafts, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end
  end
end
