defmodule DevOrchestrator.Repo.Migrations.CreateSlackTaskDrafts do
  use Ecto.Migration

  def change do
    create table(:slack_task_drafts, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:event_id, :text, null: false)

      add(:organization_id, references(:organizations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:project_id, :text, null: false)
      add(:slack_connection_id, :text, null: false)
      add(:requester_slack_user_id, :text, null: false)
      add(:channel_id, :text, null: false)
      add(:thread_ts, :text, null: false)
      add(:file_id, :text)
      add(:message_text, :text, null: false, default: "")
      add(:state, :text, null: false, default: "received")
      add(:transcript, :text)
      add(:task_draft, :map)
      add(:slack_progress_message_ts, :text)
      add(:slack_message_ts, :text)
      add(:buttons_removed_at, :utc_datetime_usec)
      add(:linear_issue_id, :text)
      add(:linear_identifier, :text)
      add(:linear_url, :text)
      add(:attempts, :integer, null: false, default: 0)
      add(:claimed_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:expires_at, :utc_datetime_usec)
      add(:error_category, :text)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(unique_index(:slack_task_drafts, [:event_id]))
    create(index(:slack_task_drafts, [:state, :next_attempt_at, :created_at]))
    create(index(:slack_task_drafts, [:state, :expires_at]))

    execute("""
    ALTER TABLE slack_task_drafts
    ADD CONSTRAINT slack_task_drafts_project_tenant_fk
    FOREIGN KEY (organization_id, project_id) REFERENCES projects(organization_id, id) ON DELETE CASCADE,
    ADD CONSTRAINT slack_task_drafts_slack_grant_fk
    FOREIGN KEY (project_id, slack_connection_id) REFERENCES connection_grants(project_id, connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT slack_task_drafts_state_check
    CHECK (state IN ('received','processing','awaiting_confirmation','creating','created','cancelled','failed','creation_ambiguous'))
    """)
  end
end
